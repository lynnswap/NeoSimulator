import AppKit

@MainActor
final class HostApplication: NSObject, NSApplicationDelegate, DeviceBrowserSource {
    private let runtime: SimulatorRuntime
    private let conflicts: HostConflictMonitor
    private let deviceSet: SimulatorDeviceSet
    private let recordings = RecordingStore()
    private let isManaged: Bool
    private let sessionIdentifier = UUID().uuidString
    private var ownedDeviceIdentifiers: Set<String> = []
    private var releasingDevices: Set<String> = []
    private var requestObserver: NSObjectProtocol?
    private var locationObserver: NSObjectProtocol?
    private var registrationErrorReported = false
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
    /// Per-device queues outlive individual sessions; quitting waits for all of them.
    private var externalDisplayQueues: [String: (name: String, changes: ExternalDisplayChanges)] = [:]
    /// Whether another simulator host took over, which leaves devices running.
    private var yieldedToAnotherHost = false
    /// Quitting's device shutdowns, which another host appearing cancels.
    private var terminationShutdowns: [Task<String?, Never>] = []
    /// SIGTERM hands devices to another host and must interrupt a quit waiting on an alert.
    private var handoverSignal: DispatchSourceSignal?
    private static weak var handoverTarget: HostApplication?
    /// Whether the manager asked for a handover; the host then
    /// ends without waiting on alerts.
    private var handoverRequested = false
    private var managerRequestedQuit = false
    /// The choice Quit NeoSimulator… made, which takes precedence over the
    /// default quit action.
    private var quitChoice: DeviceLifetimeChoice?
    private var connectionFailures: [String: Error] = [:]
    private var openingDevices: Set<String> = []
    private var browser: DeviceBrowserWindowController?
    private var newSimulator: NewSimulatorWindowController?
    private var menu: MenuController?
    private var stopped = false
    /// Shared cascade position; zero until the first window cascades.
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
    private var testingDevicesObservation: DefaultsObservation?

    init(runtime: SimulatorRuntime, conflicts: HostConflictMonitor, isManaged: Bool = false) throws {
        try conflicts.check()
        self.runtime = runtime
        self.conflicts = conflicts
        self.isManaged = isManaged
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

    func start(initialDeviceIdentifier: String? = nil) throws {
        try conflicts.check()
        if isManaged {
            if let initialDeviceIdentifier { ownedDeviceIdentifiers.insert(initialDeviceIdentifier) }
            try writeRegistration()
            requestObserver = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("dev.lynnswap.NeoSimulator.RendererRequest"),
                object: sessionIdentifier, queue: .main
            ) { [weak self] notification in
                let action = notification.userInfo?["action"] as? String
                let identifier = notification.userInfo?["udid"] as? String
                let requestIdentifier = notification.userInfo?["requestIdentifier"] as? String
                let keepRunning = notification.userInfo?["keepRunning"] as? Bool
                MainActor.assumeIsolated {
                    self?.receiveManagerRequest(action: action, identifier: identifier, requestIdentifier: requestIdentifier,
                                                keepRunning: keepRunning)
                }
            }
        }
        menu = MenuController(application: self,
                              gpuPolicy: UserDefaults(suiteName: GPUPolicy.suiteName).map(GPUPolicy.init),
                              pasteboardSync: pasteboardSync)
        menu?.install()
        touchIndicatorObservation = DefaultsObservation(
            .standard, keys: TouchIndicator.allCases.map(\.preferenceKey)) {
            NotificationCenter.default.post(name: TouchIndicator.didChangeNotification, object: UserDefaults.standard)
        }
        testingDevicesObservation = DefaultsObservation(.standard, keys: [HostPreferences.showTestingDevices]) { [weak self] in
            self?.applyTestingDeviceVisibility()
        }
        notificationToken = try deviceSet.observe { [weak self] in self?.rescan() }
        locationObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("dev.lynnswap.NeoSimulator.DeviceLocationChanged"),
            object: nil, queue: .main
        ) { [weak self] notification in
            let identifier = notification.object as? String
            MainActor.assumeIsolated {
                guard let identifier, let session = self?.sessions[identifier]?.session else { return }
                do { try session.refreshLocationSelection() }
                catch { self?.report(error) }
            }
        }
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
        if isManaged {
            if let initialDeviceIdentifier { openRequestedSimulator(initialDeviceIdentifier) }
            return
        }
        // Existing booted devices require AttachBootedOnStart; later boots always attach.
        // Testing devices follow Show Parallel Testing Devices independently.
        let defaults = UserDefaults.standard
        let attachesBooted = defaults.bool(forKey: HostPreferences.attachBootedOnStart)
        if !attachesBooted { suppressed.formUnion(try readDevices().filter { $0.state == 3 }.map(\.identifier)) }
        try conflicts.check()
        try scanDevices()
        let attached = attachesBooted && !(sessions.isEmpty && connections.isEmpty)
        if let initialDeviceIdentifier {
            openRequestedSimulator(initialDeviceIdentifier)
        } else if !attached, defaults.bool(forKey: HostPreferences.sessionOnLaunch),
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

    private func openRequestedSimulator(_ identifier: String, requestIdentifier: String? = nil) {
        Task {
            var result = ["udid": identifier]
            defer {
                if let requestIdentifier {
                    DistributedNotificationCenter.default().postNotificationName(
                        Notification.Name("dev.lynnswap.NeoSimulator.RendererOpened"), object: requestIdentifier,
                        userInfo: result, deliverImmediately: true)
                }
            }
            do { try await openSimulatorLocally(withIdentifier: identifier) }
            catch {
                result["error"] = error.localizedDescription
                if sessions[identifier] == nil && connections[identifier] == nil {
                    ownedDeviceIdentifiers.remove(identifier)
                    updateRegistration()
                }
                if requestIdentifier == nil, !(error is CancellationError) {
                    NSAlert(error: error).runModal()
                    showDeviceBrowser()
                }
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            do {
                switch try RendererRequest(url: url) {
                case .openDevice(let identifier): openRequestedSimulator(identifier)
                case .quit(let asks):
                    if asks { quitAsking() }
                    else { Self.requestTermination() }
                case .activate: activateWindows()
                case .showBrowser: showDeviceBrowser()
                }
            } catch { NSAlert(error: error).runModal() }
        }
    }

    private func receiveManagerRequest(action: String?, identifier: String?, requestIdentifier: String?, keepRunning: Bool?) {
        switch action {
        case "open-device":
            if let identifier { openRequestedSimulator(identifier, requestIdentifier: requestIdentifier) }
        case "release-device":
            guard let identifier, let requestIdentifier else { return }
            Task {
                var result = ["udid": identifier]
                do { try await releaseDevice(identifier) }
                catch { result["error"] = error.localizedDescription }
                DistributedNotificationCenter.default().postNotificationName(
                    Notification.Name("dev.lynnswap.NeoSimulator.RendererReleased"), object: requestIdentifier,
                    userInfo: result, deliverImmediately: true)
            }
        case "activate": activateWindows()
        case "show-browser": showDeviceBrowser()
        case "quit":
            managerRequestedQuit = true
            if let keepRunning { quitChoice = keepRunning ? .keepRunning : .shutDown }
            Self.requestTermination()
        default: break
        }
    }

    private func releaseDevice(_ identifier: String) async throws {
        guard ownedDeviceIdentifiers.contains(identifier) || sessions[identifier] != nil
                || connections[identifier] != nil || closingShutdowns[identifier] != nil else { return }
        guard !releasingDevices.contains(identifier) else {
            throw HostError.operation("This simulator is already being handed over.")
        }
        releasingDevices.insert(identifier)
        defer { releasingDevices.remove(identifier) }
        suppressed.insert(identifier)
        let connection = connections[identifier]
        let restart = restarting[identifier]
        let closing = closingShutdowns[identifier]
        connection?.cancel()
        restart?.cancel()
        closing?.cancel()
        bootOperations[identifier]?.cancel()
        await connection?.value
        await restart?.value
        await closing?.value
        if let controller = sessions[identifier] {
            if let recording = controller.session.recording {
                recording.stop()
                try await recording.waitUntilFinished()
            }
            controller.invalidate()
            sessions.removeValue(forKey: identifier)
        }
        awaitingReconnect.removeValue(forKey: identifier)
        if let changes = externalDisplayQueues[identifier]?.changes {
            let deadline = ContinuousClock.now + .seconds(UserDefaults.standard.double(forKey: HostPreferences.terminationTimeout))
            guard await changes.idle(before: deadline) else {
                throw HostError.operation("The simulator's external displays did not finish disconnecting.")
            }
            externalDisplayQueues.removeValue(forKey: identifier)
        }
        ownedDeviceIdentifiers.remove(identifier)
        releasingDevices.remove(identifier)
        do { try writeRegistration() }
        catch {
            ownedDeviceIdentifiers.insert(identifier)
            throw HostError.operation("The simulator disconnected, but its ownership could not be updated: \(error.localizedDescription)")
        }
    }

    private func activateWindows() {
        if sessions.isEmpty { showDeviceBrowser() }
        else { for controller in sessions.values { controller.showAndActivate() } }
    }

    private struct Registration: Codable {
        let processIdentifier: Int32
        let applicationPath: String
        let xcodePath: String
        let sessionIdentifier: String
        let deviceIdentifiers: [String]
    }

    private var registrationURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NeoSimulator/renderers")
            .appendingPathComponent("\(ProcessInfo.processInfo.processIdentifier).json")
    }

    private func writeRegistration(testingVisibilityChanged: Bool = false) throws {
        let url = registrationURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let registration = Registration(processIdentifier: ProcessInfo.processInfo.processIdentifier,
                                        applicationPath: Bundle.main.bundleURL.standardizedFileURL.path,
                                        xcodePath: runtime.xcodeURL.standardizedFileURL.path,
                                        sessionIdentifier: sessionIdentifier,
                                        deviceIdentifiers: ownedDeviceIdentifiers.union(closingShutdowns.keys).union(releasingDevices).sorted())
        try JSONEncoder().encode(registration).write(to: url, options: .atomic)
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("dev.lynnswap.NeoSimulator.RendererDevicesDidChange"),
            object: sessionIdentifier,
            userInfo: testingVisibilityChanged ? ["testingVisibilityChanged": true] : nil,
            deliverImmediately: true)
    }

    private func updateRegistration(testingVisibilityChanged: Bool = false) {
        guard isManaged, !stopped else { return }
        do { try writeRegistration(testingVisibilityChanged: testingVisibilityChanged) }
        catch {
            if !registrationErrorReported {
                registrationErrorReported = true
                hostLog("Could not update simulator ownership: \(error.localizedDescription)")
            }
        }
    }

    func showManagerSettings() { openManager(command: "settings") }

    private func openManager(command: String, queryItems: [URLQueryItem] = []) {
        var components = URLComponents()
        components.scheme = "neosimulator"
        components.host = command
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else { return }
        let managerURL = Bundle.main.bundleURL.deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        Task {
            do {
                try await openManagerURL(url, at: managerURL)
            } catch { NSAlert(error: error).runModal() }
        }
    }

    private func openManagerURL(_ url: URL, at managerURL: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.allowsRunningApplicationSubstitution = false
        try await NSWorkspace.shared.open([url], withApplicationAt: managerURL, configuration: configuration)
    }

    /// Prefers the saved device, then the last iPhone in catalog order, then the first device.
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

    /// Reads supported product families from a device set.
    private func readDevices(in set: SimulatorDeviceSet? = nil) throws -> [SimulatorDevice] {
        try (set ?? deviceSet).readDevices().filter { DeviceCapabilities.Family(rawValue: $0.productFamily) != nil }
    }

    /// Updates the preference and every open window, including restarting devices.
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
        UserDefaults.standard.set(!showsTestingDevices, forKey: HostPreferences.showTestingDevices)
    }

    private func applyTestingDeviceVisibility() {
        guard !stopped, !isTerminating else { return }
        if showsTestingDevices {
            // Reattach every booted testing device, including previously closed windows.
            if let testingSet, let devices = try? readDevices(in: testingSet) {
                suppressed.subtract(devices.map(\.identifier))
            }
        } else {
            let hadDeviceWindows = !sessions.isEmpty
            if let testingSet {
                do { ownedDeviceIdentifiers.subtract(try readDevices(in: testingSet).map(\.identifier)) }
                catch { report(error) }
            }
            // A restart keeps running without its window.
            for (identifier, controller) in sessions where controller.session.tools.deviceSetPath != nil {
                sessions.removeValue(forKey: identifier)
                awaitingReconnect.removeValue(forKey: identifier)
                ownedDeviceIdentifiers.remove(identifier)
                controller.invalidate()
            }
            if hadDeviceWindows && sessions.isEmpty { showDeviceBrowser() }
        }
        rescan(testingVisibilityChanged: true)
    }

    /// Opens TestingDeviceSetPath or ~/Library/Developer/XCTestDevices if it exists.
    /// Waits for Xcode to create a missing set.
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
        if isManaged {
            openManager(command: "open-device", queryItems: [URLQueryItem(name: "udid", value: identifier)])
            return
        }
        try await openSimulatorLocally(withIdentifier: identifier)
    }

    private func openSimulatorLocally(withIdentifier identifier: String) async throws {
        guard !releasingDevices.contains(identifier) else { throw CancellationError() }
        openingDevices.insert(identifier)
        defer { openingDevices.remove(identifier) }
        // A restart boots the device itself, and a closed window shuts it
        // down; opening waits for either instead of acting on the device meanwhile.
        while let pending = restarting[identifier] ?? closingShutdowns[identifier] { await pending.value }
        // A quitting host opens nothing; callers do not report the cancellation.
        guard !stopped, !isTerminating else { throw CancellationError() }
        try conflicts.check()
        var devices = try readDevices()
        if showsTestingDevices, let testingSet { devices += try readDevices(in: testingSet) }
        guard let device = devices.first(where: { $0.identifier == identifier }) else {
            throw HostError.operation("The selected simulator is no longer available")
        }
        ownedDeviceIdentifiers.insert(identifier)
        if isManaged { try writeRegistration() }
        suppressed.remove(identifier)
        connectionFailures.removeValue(forKey: identifier)
        // Launching starts this device next time.
        UserDefaults.standard.set(identifier, forKey: HostPreferences.currentDeviceUDID)
        // Attach an already booting device when it finishes; avoid a second boot.
        if device.state != 2, device.state != 3, bootOperations[identifier] == nil {
            let tools = try DeviceTools(identifier: identifier, xcodeURL: runtime.xcodeURL,
                                        deviceSetPath: device.deviceSetPath)
            bootOperations[identifier] = tools
            defer { bootOperations.removeValue(forKey: identifier) }
            try await tools.boot()
        }
        let deadline = ContinuousClock.now + .seconds(120)
        while sessions[identifier] == nil {
            try Task.checkCancellation()
            guard !stopped, !isTerminating, !releasingDevices.contains(identifier),
                  !isManaged || ownedDeviceIdentifiers.contains(identifier) else { throw CancellationError() }
            try scanDevices()
            if let pending = connections[identifier] { await pending.value }
            if let failure = connectionFailures[identifier] { throw failure }
            if sessions[identifier] != nil { break }
            guard ContinuousClock.now < deadline else { throw HostError.unavailable("The simulator did not finish opening.") }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let controller = sessions[identifier] else { throw CancellationError() }
        // Refresh synchronization when a connected device is selected again.
        controller.session.updatePasteboardSync()
        controller.showAndActivate()
    }

    private func rescan(testingVisibilityChanged: Bool = false) {
        do { try scanDevices(testingVisibilityChanged: testingVisibilityChanged) }
        catch let error as HostError {
            if case .conflict = error { handleHostConflict() }
            else { report(error) }
        } catch { report(error) }
    }

    private func scanDevices(testingVisibilityChanged: Bool = false) throws {
        guard !stopped, !isTerminating else { return }
        defer { updateRegistration(testingVisibilityChanged: testingVisibilityChanged) }
        try conflicts.check()
        var devices = try readDevices()
        if showsTestingDevices, let testingSet { devices += try readDevices(in: testingSet) }
        let booted = devices.filter { $0.state == 3 && (!isManaged || ownedDeviceIdentifiers.contains($0.identifier)) }
        let identifiers = Set(booted.map(\.identifier))
        let hadDeviceWindows = !sessions.isEmpty
        for identifier in sessions.keys where !identifiers.contains(identifier) && restarting[identifier] == nil {
            sessions.removeValue(forKey: identifier)?.invalidate()
            awaitingReconnect.removeValue(forKey: identifier)
            ownedDeviceIdentifiers.remove(identifier)
        }
        for identifier in connections.keys where !identifiers.contains(identifier) {
            connections[identifier]?.cancel()
        }
        // A restart's boot is not a new boot, so a window closed during the
        // restart stays closed.
        suppressed.formIntersection(identifiers.union(restarting.keys))
        connectionFailures = connectionFailures.filter { identifiers.contains($0.key) }
        // A restarting device connects only after its restart ends, also when
        // its window was hidden meanwhile.
        for device in booted where restarting[device.identifier] == nil
            && (sessions[device.identifier] == nil || awaitingReconnect[device.identifier] != nil)
            && connections[device.identifier] == nil
            && !releasingDevices.contains(device.identifier)
            && !suppressed.contains(device.identifier)
            && connectionFailures[device.identifier] == nil {
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
                connectionFailures[identifier] = error
                if !openingDevices.contains(identifier) { report(error) }
            }
        }
    }

    /// Applies keyboard settings asynchronously on each connection; logs failures.
    private func applyKeyboardSettings(of session: DeviceSession) {
        Task.immediate {
            await session.applyKeyboardSettings { error in
                hostLog("Could not apply keyboard settings to \(session.device.name): \(error.localizedDescription)")
            }
        }
    }

    /// Restores location asynchronously on each connection; logs failures.
    private func restoreLocation(of session: DeviceSession) {
        Task {
            do { try await session.restoreLocation() } catch {
                hostLog("Could not restore the simulated location of \(session.device.name): \(error.localizedDescription)")
            }
        }
    }

    /// Applies recent audio routes and observes the port; logs failures.
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

    /// Connects the external display and restores its saved choice; logs failures.
    private func connectExternalDisplay(of session: DeviceSession) {
        session.connectExternalDisplay { error in hostLog(error.localizedDescription) }
    }

    // MARK: Closing and quitting

    /// Closes the device unless this close or DetachOnWindowClose requests keeping it booted.
    private func deviceWindowClosed(_ controller: DeviceWindowController, choice: DeviceLifetimeChoice?) {
        let identifier = controller.session.device.id
        sessions.removeValue(forKey: identifier)
        awaitingReconnect.removeValue(forKey: identifier)
        ownedDeviceIdentifiers.remove(identifier)
        // A device left running keeps its window closed until it shuts down.
        suppressed.insert(identifier)
        let keepsRunning = choice.map { $0 == .keepRunning }
            ?? UserDefaults.standard.bool(forKey: HostPreferences.detachOnWindowClose)
        if !keepsRunning { shutDownClosedDevice(controller.session) }
        updateRegistration()
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
                  !Task.isCancelled,
                  self.isRunning(identifier, deviceSetPath: tools.deviceSetPath) else {
                self?.closingShutdowns.removeValue(forKey: identifier)
                self?.updateRegistration()
                return
            }
            do { try await tools.shutdown() } catch is CancellationError {
            } catch {
                hostLog("Could not shut down \(identifier): \(error.localizedDescription)")
            }
            self.closingShutdowns.removeValue(forKey: identifier)
            self.updateRegistration()
        }
    }

    /// Another host owns the devices now, so they keep running: no pending or
    /// later shutdown runs.
    private func yieldToAnotherHost() {
        yieldedToAnotherHost = true
        for shutdown in closingShutdowns.values { shutdown.cancel() }
        for shutdown in terminationShutdowns { shutdown.cancel() }
    }

    /// Terminate from a run-loop callback after dismissing modal alerts.
    /// AppKit termination inside a main-queue block or modal loop deadlocks pending main-actor work.
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

    /// Whether shutdown is needed; stopped and already stopping devices need no action.
    private func isRunning(_ identifier: String, deviceSetPath: String?) -> Bool {
        guard let set = deviceSetPath == nil ? deviceSet : testingSet,
              let device = try? set.readDevices().first(where: { $0.identifier == identifier }) else { return false }
        return device.state != 1 && device.state != 4
    }

    /// Quit NeoSimulator…: asks whether to shut the devices down, and quits
    /// unless the choice is Cancel.
    func quitAsking() {
        if isManaged {
            openManager(command: "quit", queryItems: [URLQueryItem(name: "ask", value: "true")])
            return
        }
        let alert = DeviceLifetimeChoice.alert(
            quitting: true, keepsRunningByDefault: UserDefaults.standard.bool(forKey: HostPreferences.detachOnAppQuit))
        guard let choice = DeviceLifetimeChoice.choice(
            for: alert.runModal(), of: alert, rememberingAs: HostPreferences.detachOnAppQuit) else { return }
        quitChoice = choice
        NSApp.terminate(nil)
    }

    /// Waits up to TerminationTimeout for every external-display queue, including closed windows.
    /// Returns unfinished devices and logs power-off failures.
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

    /// Shuts down windowed devices and waits for closed-window shutdowns within TerminationTimeout.
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

    /// Disconnects, shuts down, optionally erases, boots, and reconnects the existing window.
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

    /// Brings the existing creation form forward or opens one.
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
        if isManaged {
            openManager(command: "devices")
            return
        }
        if browser == nil { browser = DeviceBrowserWindowController(source: self) }
        browser?.show()
    }

    private func report(_ error: Error) {
        hostLog(error.localizedDescription)
        if isManaged {
            NSAlert(error: error).runModal()
            return
        }
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
        activateWindows()
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    /// Finalizes recordings, disconnects windows, waits for external-display cleanup, then shuts down.
    /// Explicit detach choices, DetachOnAppQuit, and handover preserve booted devices.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isManaged, !managerRequestedQuit, !handoverRequested, !yieldedToAnotherHost {
            openManager(command: "quit")
            return .terminateCancel
        }
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
        if let requestObserver {
            DistributedNotificationCenter.default().removeObserver(requestObserver)
            self.requestObserver = nil
        }
        if let locationObserver {
            DistributedNotificationCenter.default().removeObserver(locationObserver)
            self.locationObserver = nil
        }
        if isManaged {
            do { try FileManager.default.removeItem(at: registrationURL) }
            catch where (error as NSError).code == NSFileNoSuchFileError {}
            catch { hostLog("Could not remove simulator ownership: \(error.localizedDescription)") }
        }
        conflicts.onConflict = nil
        touchIndicatorObservation = nil
        testingDevicesObservation = nil
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
