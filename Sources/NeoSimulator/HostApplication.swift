import AppKit

@MainActor
final class HostApplication: NSObject, NSApplicationDelegate, DeviceBrowserSource {
    private let runtime: SimulatorRuntime
    private let conflicts: HostConflictMonitor
    private let deviceSet: SimulatorDeviceSet
    private let recordings = RecordingStore()
    private var isTerminating = false
    private var recordingTerminationErrors: [Error] = []
    private var notificationToken: UInt64?
    /// Xcode's parallel testing device set, once it exists.
    private var testingSet: SimulatorDeviceSet?
    private var testingNotificationToken: UInt64?
    /// Watches for Xcode to create the parallel testing set.
    private var testingSetWatcher: DispatchSourceFileSystemObject?
    private var sessions: [String: DeviceWindowController] = [:]
    private var connections: [String: Task<Void, Never>] = [:]
    private var bootOperations: [String: DeviceTools] = [:]
    /// Running restarts. Their windows stay open while the device is down
    /// and reconnect only after the restart finishes.
    private var restarting: [String: Task<Void, Never>] = [:]
    /// Windows that reconnect when their restarted device boots.
    private var awaitingReconnect: [String: DeviceWindowController] = [:]
    private var suppressed: Set<String> = []
    /// Shutdowns of devices whose windows closed, which quitting waits for.
    private var closingShutdowns: [String: Task<Void, Never>] = [:]
    /// The changes sent to each device's external display, which the
    /// device's successive sessions share and quitting waits for, also those
    /// of a session whose window closed.
    private var externalDisplayQueues: [String: (name: String, changes: ExternalDisplayChanges)] = [:]
    /// Whether another simulator host took over, which leaves devices running.
    private var yieldedToAnotherHost = false
    /// Quitting's device shutdowns, which another host appearing cancels.
    private var terminationShutdowns: [Task<String?, Never>] = []
    /// SIGTERM is how `xcode-simulator-host` ends the host when it switches
    /// simulator hosts, handing the devices over. It stays until the process
    /// exits, so a handover also ends a quit that waits on an alert.
    private var handoverSignal: DispatchSourceSignal?
    private static weak var handoverTarget: HostApplication?
    /// Whether the command-line tool asked for a handover; the host then
    /// ends without waiting on alerts.
    private var handoverRequested = false
    /// The choice Quit NeoSimulator… made, which takes precedence over the
    /// default quit action.
    private var quitChoice: DeviceLifetimeChoice?
    private var reportedFailures: Set<String> = []
    private var browser: DeviceBrowserWindowController?
    private var newSimulator: NewSimulatorWindowController?
    private var menu: MenuController?
    private var stopped = false
    /// Where the next device window without a saved center cascades from,
    /// app-wide as Simulator.app keeps it; zero until a window cascades.
    private var nextWindowPosition = NSPoint.zero
    /// I/O ▸ Touch Pressure's settings, which every device window shares.
    private let touchPressure = TouchPressure()
    /// Window ▸ Show Apple TV Remote's panel, which every device window shares.
    private let tvRemote = TVRemoteController()
    /// Edit ▸ Automatically Sync Pasteboard, for the devices that have windows.
    private lazy var pasteboardSync = PasteboardSync { [weak self] in
        self?.sessions.values.map(\.session) ?? []
    }
    /// Reports changes to the touch indicator preferences, from Settings or
    /// `defaults write`, to the device windows.
    private var touchIndicatorObservation: DefaultsObservation?

    init(runtime: SimulatorRuntime, conflicts: HostConflictMonitor) throws {
        try conflicts.check()
        self.runtime = runtime
        self.conflicts = conflicts
        deviceSet = try runtime.openDeviceSet()
        HostPreferences.registerDefaults()
        super.init()
        recordings.onError = { [weak self] error in
            guard let self else { return }
            if self.isTerminating || self.stopped { self.recordingTerminationErrors.append(error) }
            else { self.report(error) }
        }
        CaptureThumbnail.reportDetached = { [weak self] error in
            guard let self else { return }
            if self.isTerminating || self.stopped { self.recordingTerminationErrors.append(error) }
            else { self.report(error) }
        }
        conflicts.onConflict = { [weak self] in self?.handleHostConflict() }
    }

    func start() throws {
        try conflicts.check()
        menu = MenuController(application: self,
                              gpuPolicy: UserDefaults(suiteName: GPUPolicy.suiteName).map(GPUPolicy.init),
                              pasteboardSync: pasteboardSync)
        menu?.install()
        touchIndicatorObservation = DefaultsObservation(
            .standard, keys: TouchIndicator.allCases.map(\.preferenceKey)) {
            NotificationCenter.default.post(name: TouchIndicator.didChangeNotification, object: UserDefaults.standard)
        }
        notificationToken = try deviceSet.observe { [weak self] in self?.rescan() }
        signal(SIGTERM, SIG_IGN)
        Self.handoverTarget = self
        let handover = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        handover.setEventHandler {
            // An alert shown from a main-queue block keeps the main queue busy,
            // but its modal loop still runs main run-loop blocks.
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
                MainActor.assumeIsolated {
                    Self.handoverTarget?.handoverRequested = true
                    Self.handoverTarget?.yieldToAnotherHost()
                    Self.requestTermination()
                }
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        handover.resume()
        handoverSignal = handover
        openTestingSet()
        // Like Simulator.app, devices already booted get windows only with
        // AttachBootedOnStart; those booted later always do. Booted testing
        // devices follow only Show Parallel Testing Devices, as there.
        let defaults = UserDefaults.standard
        let attachesBooted = defaults.bool(forKey: HostPreferences.attachBootedOnStart)
        if !attachesBooted { suppressed.formUnion(try readDevices().filter { $0.state == 3 }.map(\.identifier)) }
        try conflicts.check()
        try scanDevices()
        let attached = attachesBooted && !(sessions.isEmpty && connections.isEmpty)
        if !attached, defaults.bool(forKey: HostPreferences.sessionOnLaunch),
           defaults.bool(forKey: HostPreferences.startLastDeviceOnLaunch),
           let device = Self.initialDevice(in: try availableSimulatorDevices(),
                                           current: defaults.string(forKey: HostPreferences.currentDeviceUDID)) {
            Task {
                do { try await openSimulator(withIdentifier: device.identifier) } catch is CancellationError {
                } catch {
                    NSAlert(error: error).runModal()
                    showDeviceBrowser()
                }
            }
        } else if sessions.isEmpty {
            // A pending connection can still end without a window.
            showDeviceBrowser()
        }
    }

    /// The device launching starts: the last chosen one when it is available,
    /// otherwise, like Simulator.app, the last iPhone in CoreSimulator's order
    /// or the first device.
    static func initialDevice(in devices: [AvailableDevice], current: String?) -> AvailableDevice? {
        if let current = current.flatMap(UUID.init(uuidString:)),
           let device = devices.first(where: { UUID(uuidString: $0.identifier) == current }) {
            return device
        }
        return devices.last { $0.productFamily == 1 && $0.deviceTypeName.contains("iPhone") } ?? devices.first
    }

    func availableSimulatorDevices() throws -> [AvailableDevice] {
        try readDevices().map(Self.describe)
    }

    func hasVisibleWindow(forDevice identifier: String) -> Bool {
        sessions[identifier]?.window?.isVisible == true
    }

    /// The set's devices that Neo hosts: those of the product families whose
    /// commands it defines, iPhone, iPad, Apple TV, Apple Watch, and Apple
    /// Vision, as Simulator.app hosts them.
    private func readDevices(in set: SimulatorDeviceSet? = nil) throws -> [SimulatorDevice] {
        try (set ?? deviceSet).readDevices().filter { DeviceCapabilities.Family(rawValue: $0.productFamily) != nil }
    }

    /// Window ▸ Show Device Bezels. Like Simulator.app, it changes the
    /// app-wide preference and every open device window, including one whose
    /// device is restarting; windows that open later follow the preference.
    func toggleShowDeviceBezels() {
        let shows = !UserDefaults.standard.showsDeviceBezels
        UserDefaults.standard.set(shows, forKey: HostPreferences.showChrome)
        for controller in sessions.values { controller.setDeviceBezelVisible(shows) }
    }

    // MARK: Parallel testing devices

    var showsTestingDevices: Bool { UserDefaults.standard.bool(forKey: HostPreferences.showTestingDevices) }

    /// Debug ▸ Show Parallel Testing Devices. Hiding closes the testing
    /// devices' windows without shutting the devices down.
    func toggleShowTestingDevices() {
        let show = !showsTestingDevices
        UserDefaults.standard.set(show, forKey: HostPreferences.showTestingDevices)
        if show {
            // Like Simulator.app, showing attaches every booted testing device,
            // including those whose windows were closed.
            if let testingSet, let devices = try? readDevices(in: testingSet) {
                suppressed.subtract(devices.map(\.identifier))
            }
        } else {
            let hadDeviceWindows = !sessions.isEmpty
            // A restart keeps running without its window.
            for (identifier, controller) in sessions where controller.session.tools.deviceSetPath != nil {
                sessions.removeValue(forKey: identifier)
                awaitingReconnect.removeValue(forKey: identifier)
                controller.invalidate()
            }
            if hadDeviceWindows && sessions.isEmpty { showDeviceBrowser() }
        }
        rescan()
    }

    /// Opens Xcode's parallel testing device set, as Simulator.app does: the
    /// `TestingDeviceSetPath` default, or `~/Library/Developer/XCTestDevices`.
    /// A missing set is not created; the host waits for Xcode to create it.
    private func openTestingSet() {
        guard !stopped, testingSet == nil else { return }
        let path = UserDefaults.standard.string(forKey: HostPreferences.testingDeviceSetPath)
            .map { NSString(string: $0).expandingTildeInPath }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Developer/XCTestDevices").path
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url != URL(fileURLWithPath: deviceSet.path).standardizedFileURL else {
            hostLog("TestingDeviceSetPath names the default device set; parallel testing devices are not shown")
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            watchForTestingSet(at: url)
            return
        }
        testingSetWatcher?.cancel()
        testingSetWatcher = nil
        do {
            let set = try runtime.openDeviceSet(at: url.path)
            testingNotificationToken = try set.observe { [weak self] in self?.rescan() }
            testingSet = set
        } catch {
            hostLog("Could not open the parallel testing device set: \(error.localizedDescription)")
        }
    }

    /// Watches the set's nearest existing ancestor, moving down as Xcode
    /// creates the directories, until the set exists.
    private func watchForTestingSet(at url: URL) {
        func nearestAncestor() -> URL {
            var ancestor = url.deletingLastPathComponent()
            while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
                ancestor.deleteLastPathComponent()
            }
            return ancestor
        }
        let ancestor = nearestAncestor()
        testingSetWatcher?.cancel()
        testingSetWatcher = nil
        let descriptor = open(ancestor.path, O_EVTONLY)
        guard descriptor >= 0 else {
            hostLog("Cannot watch \(ancestor.path) for the parallel testing device set")
            return
        }
        let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write,
                                                                queue: .main)
        watcher.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.testingSetDirectoryChanged() }
        }
        watcher.setCancelHandler { close(descriptor) }
        testingSetWatcher = watcher
        watcher.resume()
        // A directory created before the watcher started sends no event.
        if FileManager.default.fileExists(atPath: url.path) || nearestAncestor() != ancestor {
            testingSetDirectoryChanged()
        }
    }

    private func testingSetDirectoryChanged() {
        guard testingSet == nil else { return }
        openTestingSet()
        if testingSet != nil { rescan() }
    }

    private static func describe(_ device: SimulatorDevice) -> AvailableDevice {
        AvailableDevice(identifier: device.identifier, name: device.name, descriptiveName: device.descriptiveName,
                        runtimeIdentifier: device.runtimeIdentifier, runtimeName: device.runtimeName,
                        productFamily: device.productFamily, deviceTypeName: device.deviceTypeName,
                        state: device.state)
    }

    private static func capabilities(of device: SimulatorDevice) -> DeviceCapabilities {
        DeviceCapabilities(family: DeviceCapabilities.Family(rawValue: device.productFamily),
                           runtimeVersion: device.runtimeVersion,
                           supportsFeature: { [device] in device.supportsFeature($0) },
                           controlsOrientation: device.deviceSetPath == nil,
                           hasFramebufferMask: device.hasFramebufferMask,
                           screenCornerRadius: device.screenCornerRadius,
                           screenPointsPerInch: device.screenPointsPerInch,
                           hasUserInterfacePlugin: device.hasUserInterfacePlugin,
                           supportsEnhancedMultitasking: device.supportsEnhancedMultitasking)
    }

    func openSimulator(withIdentifier identifier: String) async throws {
        // A restart boots the device itself, and a closed window shuts it
        // down; opening waits for either instead of acting on the device meanwhile.
        while let pending = restarting[identifier] ?? closingShutdowns[identifier] { await pending.value }
        // A quitting host opens nothing; callers do not report the cancellation.
        guard !stopped, !isTerminating else { throw CancellationError() }
        try conflicts.check()
        guard let device = try readDevices().first(where: { $0.identifier == identifier }) else {
            throw HostError.operation("The selected simulator is no longer available")
        }
        suppressed.remove(identifier)
        reportedFailures.remove(identifier)
        // Launching starts this device next time.
        UserDefaults.standard.set(identifier, forKey: HostPreferences.currentDeviceUDID)
        // Like Simulator.app, a device that is already booting is attached
        // once it boots instead of being booted again.
        if device.state != 2, device.state != 3, bootOperations[identifier] == nil {
            let tools = try DeviceTools(identifier: identifier, xcodeURL: runtime.xcodeURL)
            bootOperations[identifier] = tools
            defer { bootOperations.removeValue(forKey: identifier) }
            try await tools.boot()
        }
        rescan()
        guard let controller = sessions[identifier] else { return }
        // Like Simulator.app, choosing a connected device tells its
        // pasteboard connection again whether to synchronize.
        controller.session.updatePasteboardSync()
        controller.showAndActivate()
    }

    private func rescan() {
        do { try scanDevices() }
        catch let error as HostError {
            if case .conflict = error { handleHostConflict() }
            else { report(error) }
        } catch { report(error) }
    }

    private func scanDevices() throws {
        guard !stopped, !isTerminating else { return }
        try conflicts.check()
        var devices = try readDevices()
        if showsTestingDevices, let testingSet { devices += try readDevices(in: testingSet) }
        let booted = devices.filter { $0.state == 3 }
        let identifiers = Set(booted.map(\.identifier))
        let hadDeviceWindows = !sessions.isEmpty
        for identifier in sessions.keys where !identifiers.contains(identifier) && restarting[identifier] == nil {
            sessions.removeValue(forKey: identifier)?.invalidate()
            awaitingReconnect.removeValue(forKey: identifier)
        }
        for identifier in connections.keys where !identifiers.contains(identifier) {
            connections[identifier]?.cancel()
        }
        // A restart's boot is not a new boot, so a window closed during the
        // restart stays closed.
        suppressed.formIntersection(identifiers.union(restarting.keys))
        reportedFailures.formIntersection(identifiers)
        // A restarting device connects only after its restart ends, also when
        // its window was hidden meanwhile.
        for device in booted where restarting[device.identifier] == nil
            && (sessions[device.identifier] == nil || awaitingReconnect[device.identifier] != nil)
            && connections[device.identifier] == nil
            && !suppressed.contains(device.identifier)
            && !reportedFailures.contains(device.identifier) {
            connect(device)
        }
        if hadDeviceWindows && sessions.isEmpty { showDeviceBrowser() }
        browser?.refresh()
    }

    private func connect(_ device: SimulatorDevice) {
        let identifier = device.identifier
        connections[identifier] = Task { [weak self] in
            guard let self else { return }
            defer {
                // Keep cancellation tracked until this task unwinds, so a new
                // boot cannot replace its entry before cleanup.
                connections.removeValue(forKey: identifier)
                rescan()
            }
            do {
                // CoreSimulator reports Booted before its integrated screen is ready.
                for _ in 0..<40 {
                    try Task.checkCancellation()
                    guard !stopped, !isTerminating, !suppressed.contains(identifier) else { return }
                    try conflicts.check()
                    if let screen = runtime.display.defaultScreen(of: device) {
                        let connection = try SimulatorConnection(device: device, screen: screen, runtime: runtime)
                        let session = DeviceSession(
                            device: Self.describe(device), capabilities: Self.capabilities(of: device),
                            display: connection,
                            tools: try DeviceTools(identifier: identifier, xcodeURL: runtime.xcodeURL,
                                                   deviceSetPath: device.deviceSetPath),
                            recordings: recordings, pasteboardSync: pasteboardSync,
                            externalDisplayChanges: externalDisplayChanges(of: device))
                        do { try session.applyDebugSettings() } catch {
                            hostLog("Could not apply debug settings to \(device.name): \(error.localizedDescription)")
                        }
                        if let controller = awaitingReconnect.removeValue(forKey: identifier) {
                            try conflicts.check()
                            controller.reconnect(session)
                            applyKeyboardSettings(of: session)
                            restoreLocation(of: session)
                            connectAudioRoutes(of: session)
                            session.startPasteboardSync()
                            connectExternalDisplay(of: session)
                            return
                        }
                        let controller = try DeviceWindowController(
                            session: session, touchPressure: touchPressure, tvRemote: tvRemote, onClose: { [weak self] in
                                self?.deviceWindowClosed($0, choice: $1)
                            }, onRestart: { [weak self] in self?.restartDevice($0, erasing: $1) })
                        try conflicts.check()
                        sessions[identifier] = controller
                        controller.showNewWindow(cascadingFrom: &nextWindowPosition)
                        applyKeyboardSettings(of: session)
                        restoreLocation(of: session)
                        connectAudioRoutes(of: session)
                        session.startPasteboardSync()
                        connectExternalDisplay(of: session)
                        return
                    }
                    try await Task.sleep(for: .milliseconds(250))
                }
                throw HostError.unavailable("No integrated screen became available for \(device.name)")
            } catch is CancellationError {
            } catch {
                reportedFailures.insert(identifier)
                report(error)
            }
        }
    }

    /// Applies the keyboard settings to a new connection, also after a
    /// restart, without waiting for them. Simulator.app ignores their
    /// failures; they are logged.
    private func applyKeyboardSettings(of session: DeviceSession) {
        Task.immediate {
            await session.applyKeyboardSettings { error in
                hostLog("Could not apply keyboard settings to \(session.device.name): \(error.localizedDescription)")
            }
        }
    }

    /// Applies the saved Features ▸ Location choice to a new connection, also
    /// after a restart, without waiting for it. Like Simulator.app, which
    /// ignores the result, a failure is not shown; it is logged.
    private func restoreLocation(of session: DeviceSession) {
        Task {
            do { try await session.restoreLocation() } catch {
                hostLog("Could not restore the simulated location of \(session.device.name): \(error.localizedDescription)")
            }
        }
    }

    /// Routes a new connection's audio to the app's recent routes, also
    /// after a restart, and keeps following the device's audio port. Like
    /// Simulator.app, which only logs them, these failures are logged.
    private func connectAudioRoutes(of session: DeviceSession) {
        let name = session.device.name
        session.connectAudioRoutes { error in
            hostLog("Could not route the audio of \(name): \(error.localizedDescription)")
        }
    }

    /// The changes sent to `device`'s external display, which every session of
    /// the device shares.
    private func externalDisplayChanges(of device: SimulatorDevice) -> ExternalDisplayChanges {
        let changes = externalDisplayQueues[device.identifier]?.changes ?? ExternalDisplayChanges()
        externalDisplayQueues[device.identifier] = (device.name, changes)
        return changes
    }

    /// Connects a new connection to its device's external display and
    /// restores the device's External Displays choice, also after a restart.
    /// Like Simulator.app, which only logs them, these failures are logged.
    private func connectExternalDisplay(of session: DeviceSession) {
        session.connectExternalDisplay { error in hostLog(error.localizedDescription) }
    }

    // MARK: Closing and quitting

    /// A user closed a device window. Like Simulator.app, the device shuts
    /// down unless the close chose to keep it running or `DetachOnWindowClose`
    /// is on, including a device Xcode booted.
    private func deviceWindowClosed(_ controller: DeviceWindowController, choice: DeviceLifetimeChoice?) {
        let identifier = controller.session.device.id
        sessions.removeValue(forKey: identifier)
        awaitingReconnect.removeValue(forKey: identifier)
        // A device left running keeps its window closed until it shuts down.
        suppressed.insert(identifier)
        let keepsRunning = choice.map { $0 == .keepRunning }
            ?? UserDefaults.standard.bool(forKey: HostPreferences.detachOnWindowClose)
        if !keepsRunning { shutDownClosedDevice(controller.session) }
        if sessions.isEmpty { showDeviceBrowser() }
    }

    /// Shuts down a device whose window closed once its recording is saved,
    /// abandoning a restart in progress.
    private func shutDownClosedDevice(_ session: DeviceSession) {
        let identifier = session.device.id
        // The restart stays tracked until it unwinds, so opening waits for it.
        let restart = restarting[identifier]
        restart?.cancel()
        bootOperations[identifier]?.cancel()
        guard closingShutdowns[identifier] == nil else { return }
        let tools: DeviceTools
        do {
            tools = try DeviceTools(identifier: identifier, xcodeURL: runtime.xcodeURL,
                                    deviceSetPath: session.tools.deviceSetPath)
        } catch {
            hostLog("Could not shut down \(identifier): \(error.localizedDescription)")
            return
        }
        closingShutdowns[identifier] = Task { [weak self] in
            await restart?.value
            await session.finishRecording()
            guard let self, !self.yieldedToAnotherHost,
                  self.isRunning(identifier, deviceSetPath: tools.deviceSetPath) else {
                self?.closingShutdowns.removeValue(forKey: identifier)
                return
            }
            do { try await tools.shutdown() } catch is CancellationError {
            } catch {
                hostLog("Could not shut down \(identifier): \(error.localizedDescription)")
            }
            self.closingShutdowns.removeValue(forKey: identifier)
        }
    }

    /// Another host owns the devices now, so they keep running: no pending or
    /// later shutdown runs.
    private func yieldToAnotherHost() {
        yieldedToAnotherHost = true
        for shutdown in closingShutdowns.values { shutdown.cancel() }
        for shutdown in terminationShutdowns { shutdown.cancel() }
    }

    /// Terminates from a run-loop callback rather than a main-queue block, and
    /// after ending a modal alert: AppKit's termination loop inside either one
    /// waits forever for the main-actor work that termination needs.
    private static func requestTermination() {
        RunLoop.main.perform(inModes: [.common]) {
            if NSApp.modalWindow != nil {
                NSApp.abortModal()
                // The modal loop notices the abort after its next event.
                if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                                                  timestamp: 0, windowNumber: 0, context: nil, subtype: 0,
                                                  data1: 0, data2: 0) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
            RunLoop.main.perform(inModes: [.default]) { NSApp.terminate(nil) }
        }
    }

    /// Whether a device still needs shutting down. Like Simulator.app's close,
    /// a device that is shut down or shutting down is left alone, for example
    /// one a restart had shut down for erasing.
    private func isRunning(_ identifier: String, deviceSetPath: String?) -> Bool {
        guard let set = deviceSetPath == nil ? deviceSet : testingSet,
              let device = try? set.readDevices().first(where: { $0.identifier == identifier }) else { return false }
        return device.state != 1 && device.state != 4
    }

    /// Quit NeoSimulator…: asks whether to shut the devices down, and quits
    /// unless the choice is Cancel.
    func quitAsking() {
        let alert = DeviceLifetimeChoice.alert(
            quitting: true, keepsRunningByDefault: UserDefaults.standard.bool(forKey: HostPreferences.detachOnAppQuit))
        guard let choice = DeviceLifetimeChoice.choice(
            for: alert.runModal(), of: alert, rememberingAs: HostPreferences.detachOnAppQuit) else { return }
        quitChoice = choice
        NSApp.terminate(nil)
    }

    /// Waits, within `TerminationTimeout`, for every device's external display
    /// changes to complete, including the power-offs of the windows that
    /// closed, as Simulator.app waits for its windows to disconnect, and
    /// returns the displays that did not. Their power-off failures are logged.
    private func finishExternalDisplayChanges() async -> [String] {
        let timeout = UserDefaults.standard.double(forKey: HostPreferences.terminationTimeout)
        let deadline = ContinuousClock.now + .seconds(timeout)
        var failures: [String] = []
        for (name, changes) in externalDisplayQueues.values {
            guard await !changes.idle(before: deadline) else { continue }
            failures.append("The external display of \(name) did not turn off within \(Int(timeout)) seconds of quitting.")
        }
        return failures
    }

    /// Shuts down the devices that have windows, as Simulator.app does when
    /// quitting, and returns the failures. Each shutdown, and those of closed
    /// windows, must finish within `TerminationTimeout`.
    private func shutDownForTermination(_ devices: [(identifier: String, deviceSetPath: String?)]) async -> [String] {
        // Ownership is checked when the shutdowns start, after any wait.
        guard !yieldedToAnotherHost else { return [] }
        var failures: [String] = []
        var shutdowns = Array(closingShutdowns.values).map { shutdown in
            Task { () -> String? in await shutdown.value; return nil }
        }
        for device in devices where isRunning(device.identifier, deviceSetPath: device.deviceSetPath) {
            do {
                let tools = try DeviceTools(identifier: device.identifier, xcodeURL: runtime.xcodeURL,
                                            deviceSetPath: device.deviceSetPath)
                shutdowns.append(Task {
                    do { try await tools.shutdown() } catch is CancellationError {
                    } catch { return error.localizedDescription }
                    return nil
                })
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        let timeout = UserDefaults.standard.double(forKey: HostPreferences.terminationTimeout)
        let started = shutdowns
        terminationShutdowns = started
        let deadline = Task { () -> Bool in
            do { try await Task.sleep(for: .seconds(timeout)) } catch { return false }
            for shutdown in started { shutdown.cancel() }
            for shutdown in self.closingShutdowns.values { shutdown.cancel() }
            return true
        }
        for shutdown in shutdowns { if let failure = await shutdown.value { failures.append(failure) } }
        deadline.cancel()
        if await deadline.value {
            failures.insert("Devices did not shut down within \(Int(timeout)) seconds of quitting.", at: 0)
        }
        return failures
    }

    // MARK: Restart

    /// Restarts a device in Simulator.app's order, keeping its window: the
    /// window disconnects, the device shuts down, is erased when requested,
    /// and boots, and the window reconnects.
    private func restartDevice(_ controller: DeviceWindowController, erasing: Bool) {
        let identifier = controller.session.device.id
        guard !stopped, sessions[identifier] === controller, restarting[identifier] == nil,
              bootOperations[identifier] == nil else { return }
        let tools: DeviceTools
        do {
            tools = try DeviceTools(identifier: identifier, xcodeURL: runtime.xcodeURL,
                                    deviceSetPath: controller.session.tools.deviceSetPath)
        } catch {
            controller.present(error)
            return
        }
        // Holding the operation slot disables other device commands while
        // an active recording finishes.
        guard controller.session.reserve() else { return }
        awaitingReconnect[identifier] = controller
        bootOperations[identifier] = tools
        restarting[identifier] = Task { [weak self] in
            await controller.prepareForRestart()
            var failure: Error?
            do {
                try Task.checkCancellation()
                try await tools.restart(erasing: erasing)
            } catch { failure = error }
            guard let self else { return }
            self.bootOperations.removeValue(forKey: identifier)
            self.restarting.removeValue(forKey: identifier)
            // A window whose device is still down closes; a booted device reconnects.
            self.rescan()
            guard let failure, !(failure is CancellationError), !self.stopped else { return }
            if self.sessions[identifier] === controller { controller.present(failure) } else { self.report(failure) }
        }
    }

    /// File ▸ New Simulator…. Like Simulator.app, an open form is brought to
    /// the front instead of opening another.
    func showNewSimulator() {
        guard !stopped else { return }
        if newSimulator == nil {
            let catalog: SimulatorCatalog
            do { catalog = try deviceSet.readCatalog() } catch {
                report(error)
                return
            }
            let xcodeURL = runtime.xcodeURL
            newSimulator = NewSimulatorWindowController(catalog: catalog, create: { name, deviceType, runtime in
                try await DeviceTools.createDevice(named: name, deviceType: deviceType, runtime: runtime,
                                                   xcodeURL: xcodeURL)
            }, pair: { watch, phone in
                try await DeviceTools.pairDevices(watch: watch, phone: phone, xcodeURL: xcodeURL)
            }, onClose: { [weak self] in self?.newSimulator = nil })
        }
        newSimulator?.showWindow(nil)
        newSimulator?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func showDeviceBrowser() {
        guard !stopped else { return }
        if browser == nil { browser = DeviceBrowserWindowController(source: self) }
        browser?.show()
    }

    private func report(_ error: Error) {
        hostLog(error.localizedDescription)
        showDeviceBrowser()
        browser?.report(error)
    }

    private func handleHostConflict() {
        guard !stopped, let name = conflicts.conflictingHostName else { return }
        hostLog("\(name) appeared; disconnecting simulators and exiting")
        CaptureThumbnail.savesImmediately = true
        recordingTerminationErrors += CaptureThumbnail.finishAll()
        yieldToAnotherHost()
        shutdown()
        // A conflict can arrive on the main dispatch queue. Finish recordings
        // before terminating.
        Task {
            await recordings.finishAll()
            guard !isTerminating else { return }
            // A handover ends the host without waiting on alerts.
            for error in recordingTerminationErrors where !handoverRequested { NSAlert(error: error).runModal() }
            recordingTerminationErrors.removeAll()
            Self.requestTermination()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if sessions.isEmpty { showDeviceBrowser() }
        else { for session in sessions.values { session.showAndActivate() } }
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    /// Quitting finishes recordings, then, like Simulator.app, disconnects the
    /// windows, waits for their external displays to turn off, and shuts down
    /// the devices that have windows unless the quit chose to keep them running
    /// or `DetachOnAppQuit` is on. Devices another host takes over keep running.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        // Pending captures are saved now, and those that recordings finish
        // while quitting are saved without a thumbnail.
        CaptureThumbnail.savesImmediately = true
        let captureFailures = CaptureThumbnail.finishAll()
        let keepsRunning = quitChoice.map { $0 == .keepRunning }
            ?? UserDefaults.standard.bool(forKey: HostPreferences.detachOnAppQuit)
        let devices = keepsRunning ? [] : sessions.values.map {
            (identifier: $0.session.device.id, deviceSetPath: $0.session.tools.deviceSetPath)
        }
        guard recordings.hasActiveRecordings || !devices.isEmpty || !closingShutdowns.isEmpty
                || sessions.values.contains(where: { $0.session.hasExternalDisplay })
                || externalDisplayQueues.values.contains(where: { $0.changes.isBusy }) else {
            if !captureFailures.isEmpty, !handoverRequested { Self.alert(captureFailures) }
            return .terminateNow
        }
        isTerminating = true
        recordingTerminationErrors += captureFailures
        // No window opens while quitting; its device would not be shut down.
        for connection in connections.values { connection.cancel() }
        Task {
            await recordings.finishAll()
            // A handover ends the host without waiting on alerts.
            for error in recordingTerminationErrors where !handoverRequested { NSAlert(error: error).runModal() }
            recordingTerminationErrors.removeAll()
            // A restart could boot its device again, so it ends first.
            let restarts = Array(restarting.values)
            for restart in restarts { restart.cancel() }
            for tools in bootOperations.values { tools.cancel() }
            for restart in restarts { await restart.value }
            // Windows disconnect before their devices shut down. Host conflicts
            // are still handled meanwhile and cancel the shutdowns.
            for session in sessions.values { session.invalidate() }
            sessions.removeAll()
            awaitingReconnect.removeAll()
            let displayFailures = await finishExternalDisplayChanges()
            let failures = await shutDownForTermination(devices)
            shutdown()
            if !displayFailures.isEmpty || !failures.isEmpty, !handoverRequested {
                let alert = NSAlert()
                alert.messageText = failures.isEmpty
                    ? "Some external displays could not be turned off."
                    : "Some simulated devices could not be shut down."
                alert.informativeText = (displayFailures + failures).joined(separator: "\n")
                alert.runModal()
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) {
        CaptureThumbnail.savesImmediately = true
        CaptureThumbnail.finishAll()
        shutdown()
    }

    private static func alert(_ captureFailures: [Error]) {
        let alert = NSAlert()
        alert.messageText = "Some captures could not be saved."
        alert.informativeText = captureFailures.map(\.localizedDescription).joined(separator: "\n")
        alert.runModal()
    }

    func shutdown() {
        guard !stopped else { return }
        stopped = true
        conflicts.onConflict = nil
        touchIndicatorObservation = nil
        if let notificationToken {
            do { try deviceSet.stopObserving(notificationToken) }
            catch { hostLog("Could not unregister simulator notifications: \(error.localizedDescription)") }
        }
        notificationToken = nil
        if let testingSet, let testingNotificationToken {
            do { try testingSet.stopObserving(testingNotificationToken) }
            catch { hostLog("Could not unregister testing device notifications: \(error.localizedDescription)") }
        }
        testingNotificationToken = nil
        testingSetWatcher?.cancel()
        testingSetWatcher = nil
        for task in connections.values { task.cancel() }
        connections.removeAll()
        for tools in bootOperations.values { tools.cancel() }
        bootOperations.removeAll()
        for task in restarting.values { task.cancel() }
        restarting.removeAll()
        awaitingReconnect.removeAll()
        for session in sessions.values { session.invalidate() }
        sessions.removeAll()
        browser?.close()
        newSimulator?.close()
        browser = nil
    }
}
