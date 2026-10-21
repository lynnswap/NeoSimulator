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
    /// The choice Quit NeoSimulator… made, which takes precedence over the
    /// default quit action.
    private var quitChoice: DeviceLifetimeChoice?
    private var reportedFailures: Set<String> = []
    private var browser: DeviceBrowserWindowController?
    private var newSimulator: NewSimulatorWindowController?
    private var menu: MenuController?
    private var stopped = false
    private var nextWindowPosition = NSPoint.zero

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
        conflicts.onConflict = { [weak self] in self?.handleHostConflict() }
    }

    func start() throws {
        try conflicts.check()
        menu = MenuController(application: self)
        menu?.install()
        notificationToken = try deviceSet.observe { [weak self] in self?.rescan() }
        openTestingSet()
        // Like Simulator.app, devices already booted get windows only with
        // AttachBootedOnStart; those booted later always do.
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
                do { try await openSimulator(withIdentifier: device.identifier) } catch {
                    NSAlert(error: error).runModal()
                    showDeviceBrowser()
                }
            }
        } else if sessions.isEmpty && connections.isEmpty {
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

    private func readDevices(in set: SimulatorDeviceSet? = nil) throws -> [SimulatorDevice] {
        try (set ?? deviceSet).readDevices().filter { $0.platformIdentifier == "com.apple.platform.iphonesimulator" }
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
                           controlsOrientation: device.deviceSetPath == nil)
    }

    func openSimulator(withIdentifier identifier: String) async throws {
        // A restart boots the device itself; opening waits instead of booting
        // during its shutdown or erase.
        while let restart = restarting[identifier] { await restart.value }
        guard !stopped else { throw HostError.operation("NeoSimulator is shutting down") }
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
        sessions[identifier]?.showAndActivate()
    }

    private func rescan() {
        do { try scanDevices() }
        catch let error as HostError {
            if case .conflict = error { handleHostConflict() }
            else { report(error) }
        } catch { report(error) }
    }

    private func scanDevices() throws {
        guard !stopped else { return }
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
                    guard !stopped, !suppressed.contains(identifier) else { return }
                    try conflicts.check()
                    if let screen = runtime.display.defaultScreen(of: device) {
                        let connection = try SimulatorConnection(device: device, screen: screen, runtime: runtime)
                        let session = DeviceSession(
                            device: Self.describe(device), capabilities: Self.capabilities(of: device),
                            display: connection,
                            tools: try DeviceTools(identifier: identifier, xcodeURL: runtime.xcodeURL,
                                                   deviceSetPath: device.deviceSetPath),
                            recordings: recordings)
                        if let controller = awaitingReconnect.removeValue(forKey: identifier) {
                            try conflicts.check()
                            controller.reconnect(session)
                            return
                        }
                        let deviceSetPath = device.deviceSetPath
                        let controller = try DeviceWindowController(session: session, onClose: { [weak self] in
                            self?.deviceWindowClosed($0, choice: $1, deviceSetPath: deviceSetPath)
                        }, onRestart: { [weak self] in self?.restartDevice($0, erasing: $1) })
                        try conflicts.check()
                        sessions[identifier] = controller
                        if let window = controller.window {
                            nextWindowPosition = window.cascadeTopLeft(from: nextWindowPosition)
                        }
                        controller.showAndActivate()
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

    // MARK: Closing and quitting

    /// A user closed a device window. Like Simulator.app, the device shuts
    /// down unless the close chose to keep it running or `DetachOnWindowClose`
    /// is on, including a device Xcode booted.
    private func deviceWindowClosed(_ identifier: String, choice: DeviceLifetimeChoice?, deviceSetPath: String?) {
        sessions.removeValue(forKey: identifier)
        awaitingReconnect.removeValue(forKey: identifier)
        // A device left running keeps its window closed until it shuts down.
        suppressed.insert(identifier)
        let keepsRunning = choice.map { $0 == .keepRunning }
            ?? UserDefaults.standard.bool(forKey: HostPreferences.detachOnWindowClose)
        if !keepsRunning { shutDownClosedDevice(identifier, deviceSetPath: deviceSetPath) }
        if sessions.isEmpty { showDeviceBrowser() }
    }

    /// Shuts down a device whose window closed, abandoning a restart in progress.
    private func shutDownClosedDevice(_ identifier: String, deviceSetPath: String?) {
        restarting.removeValue(forKey: identifier)?.cancel()
        bootOperations.removeValue(forKey: identifier)?.cancel()
        guard closingShutdowns[identifier] == nil else { return }
        let tools: DeviceTools
        do {
            tools = try DeviceTools(identifier: identifier, xcodeURL: runtime.xcodeURL, deviceSetPath: deviceSetPath)
        } catch {
            hostLog("Could not shut down \(identifier): \(error.localizedDescription)")
            return
        }
        closingShutdowns[identifier] = Task { [weak self] in
            do { try await tools.shutdown() } catch is CancellationError {
            } catch {
                hostLog("Could not shut down \(identifier): \(error.localizedDescription)")
            }
            self?.closingShutdowns.removeValue(forKey: identifier)
        }
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

    /// Shuts down the devices that have windows, as Simulator.app does when
    /// quitting, and returns the failures. Each shutdown, and those of closed
    /// windows, must finish within `TerminationTimeout`.
    private func shutDownForTermination(_ devices: [(identifier: String, deviceSetPath: String?)]) async -> [String] {
        var failures: [String] = []
        var shutdowns = Array(closingShutdowns.values).map { shutdown in
            Task { () -> String? in await shutdown.value; return nil }
        }
        for device in devices {
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
        shutdown()
        // A conflict can arrive on the main dispatch queue. Finish recordings
        // before terminate() enters AppKit's termination run loop from that queue.
        Task {
            await recordings.finishAll()
            guard !isTerminating else { return }
            for error in recordingTerminationErrors { NSAlert(error: error).runModal() }
            recordingTerminationErrors.removeAll()
            NSApp.terminate(nil)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if sessions.isEmpty { showDeviceBrowser() }
        else { for session in sessions.values { session.showAndActivate() } }
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    /// Quitting finishes recordings, then, like Simulator.app, shuts down the
    /// devices that have windows unless the quit chose to keep them running or
    /// `DetachOnAppQuit` is on. A host stopped by a conflict leaves them running.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        let keepsRunning = stopped || (quitChoice.map { $0 == .keepRunning }
            ?? UserDefaults.standard.bool(forKey: HostPreferences.detachOnAppQuit))
        let devices = keepsRunning ? [] : sessions.values.map {
            (identifier: $0.session.device.id, deviceSetPath: $0.session.tools.deviceSetPath)
        }
        guard recordings.hasActiveRecordings || !devices.isEmpty || !closingShutdowns.isEmpty else {
            return .terminateNow
        }
        isTerminating = true
        Task {
            await recordings.finishAll()
            for error in recordingTerminationErrors { NSAlert(error: error).runModal() }
            recordingTerminationErrors.removeAll()
            // Windows disconnect before their devices shut down.
            shutdown()
            let failures = await shutDownForTermination(devices)
            if !failures.isEmpty {
                let alert = NSAlert()
                alert.messageText = "Some simulated devices could not be shut down."
                alert.informativeText = failures.joined(separator: "\n")
                alert.runModal()
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) { shutdown() }

    func shutdown() {
        guard !stopped else { return }
        stopped = true
        conflicts.onConflict = nil
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
