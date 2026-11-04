import AppKit
@_spi(NeoSimulator) import XcodeSimulatorHost

/// Composes the renderer's application lifecycle around the reusable simulator engine.
@MainActor
final class HostApplication: NSObject, NSApplicationDelegate, DeviceBrowserSource {
    private let runtime: SimulatorRuntime
    private let engine: SimulatorScreenHost
    private let isManaged: Bool
    private let isHeadless: Bool
    private let owner: RendererOwnerIdentity?
    private let sessionIdentifier = UUID().uuidString
    private var requestObserver: NSObjectProtocol?
    private var locationObserver: NSObjectProtocol?
    private var handoverSignal: DispatchSourceSignal?
    private static weak var handoverTarget: HostApplication?
    private var handoverRequested = false
    private var managerRequestedQuit = false
    private var ownerExitRequested = false
    private var quitChoice: DeviceLifetimeChoice?
    private var terminationTask: Task<Void, Never>?
    private var browser: DeviceBrowserWindowController?
    private var newSimulator: NewSimulatorWindowController?
    private let creationPreferences = SimulatorPreferences()
    private var menu: MenuController?
    private var openRequests: [String: (device: SimulatorDeviceIdentifier, preservesOwnership: Bool, task: Task<Void, Never>)] = [:]
    var isStopped: Bool { engine.isStopped }

    init(runtime: SimulatorRuntime, conflicts: HostConflictMonitor, isManaged: Bool = false,
         owner: RendererOwnerIdentity? = nil, headless: Bool = false) throws {
        self.runtime = runtime
        self.isManaged = isManaged
        self.isHeadless = headless
        self.owner = owner
        engine = try SimulatorScreenHost(runtime: runtime, conflicts: conflicts, isManaged: isManaged, headless: headless)
        super.init()
        engine.onOpen = { identifier in
            HostPreferences.defaults.set(identifier.identifier, forKey: HostPreferences.currentDeviceUDID)
            HostPreferences.defaults.set(identifier.deviceSetPath, forKey: "CurrentDeviceSetPath")
        }
        engine.onOwnershipChange = { [weak self] changed in
            guard let self, self.isManaged, !self.engine.isStopped else { return }
            try self.writeRegistration(testingVisibilityChanged: changed)
        }
        engine.onNoScreens = { [weak self] in self?.showDeviceBrowser() }
        engine.onChange = { [weak self] in self?.browser?.refresh() }
        engine.onError = { [weak self] in self?.report($0) }
        engine.onConflict = { [weak self] name, failure in
            guard let self else { return }
            hostLog("\(name) appeared; simulator presentations have disconnected")
            if let failure {
                if self.ownerExitRequested || self.handoverRequested { hostLog(failure.localizedDescription) }
                else { NSAlert(presenting: failure).runModal() }
            }
            Self.requestTermination()
        }
    }

    func start(initialDeviceIdentifier: String? = nil, initialDeviceSetPath: String? = nil) throws {
        let initialDevice = initialDeviceIdentifier.map { SimulatorDeviceIdentifier($0, deviceSetPath: initialDeviceSetPath) }
        if isManaged {
            if let initialDevice { engine.adopt(initialDevice) }
            try writeRegistration()
            requestObserver = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("dev.lynnswap.NeoSimulator.RendererRequest"),
                object: sessionIdentifier, queue: .main
            ) { [weak self] notification in
                let action = notification.userInfo?["action"] as? String
                let udid = notification.userInfo?["udid"] as? String
                let path = notification.userInfo?["deviceSetPath"] as? String
                let identifier = udid.map { SimulatorDeviceIdentifier($0, deviceSetPath: path) }
                let requestIdentifier = notification.userInfo?["requestIdentifier"] as? String
                let keepRunning = (notification.userInfo?["keepRunning"] as? Bool)
                    ?? (notification.userInfo?["keepRunning"] as? String).flatMap(Bool.init)
                MainActor.assumeIsolated {
                    self?.receiveManagerRequest(action: action, identifier: identifier,
                        requestIdentifier: requestIdentifier, keepRunning: keepRunning)
                }
            }
        }
        if !isHeadless {
            menu = MenuController(application: self,
                gpuPolicy: UserDefaults(suiteName: GPUPolicy.suiteName).map(GPUPolicy.init),
                pasteboardSync: engine.pasteboardSynchronization)
            menu?.install()
        }
        locationObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("dev.lynnswap.NeoSimulator.DeviceLocationChanged"),
            object: nil, queue: .main
        ) { [weak self] notification in
            let udid = notification.object as? String
            let path = notification.userInfo?["deviceSetPath"] as? String
            let identifier = udid.map { SimulatorDeviceIdentifier($0, deviceSetPath: path) }
            MainActor.assumeIsolated {
                guard let self, let identifier else { return }
                do { try self.engine.refreshLocationSelection(for: identifier) }
                catch { self.report(error) }
            }
        }
        Self.handoverTarget = self
        handoverSignal = Self.observeHandoverSignal {
            Self.handoverTarget?.handoverRequested = true
            Self.handoverTarget?.engine.yieldToAnotherHost()
            Self.requestTermination()
        }
        let defaults = HostPreferences.defaults
        let attachesBooted = defaults.bool(forKey: HostPreferences.attachBootedOnStart)
        try engine.start(attachingBootedDevices: attachesBooted)
        if isManaged {
            if let initialDevice { openRequestedSimulator(initialDevice) }
            return
        }
        let attached = attachesBooted && engine.hasPresentations
        if let initialDevice {
            openRequestedSimulator(initialDevice)
        } else if !attached, defaults.bool(forKey: HostPreferences.sessionOnLaunch),
                  defaults.bool(forKey: HostPreferences.startLastDeviceOnLaunch),
                  let device = Self.initialDevice(in: try availableSimulatorDevices(),
                      current: defaults.string(forKey: HostPreferences.currentDeviceUDID).map {
                          SimulatorDeviceIdentifier($0, deviceSetPath: defaults.string(forKey: "CurrentDeviceSetPath"))
                      }) {
            openRequestedSimulator(device.identity)
        } else if !engine.hasPresentations {
            showDeviceBrowser()
        }
    }

    func availableSimulatorDevices() throws -> [AvailableDevice] { try engine.availableSimulatorDevices() }
    func hasVisibleWindow(forDevice identifier: SimulatorDeviceIdentifier) -> Bool {
        engine.hasVisibleWindow(forDevice: identifier)
    }
    func openSimulator(withIdentifier identifier: SimulatorDeviceIdentifier) async throws {
        if isManaged { openManager(command: "open-device", queryItems: identifier.queryItems) }
        else { try await engine.openSimulator(withIdentifier: identifier) }
    }
    func toggleShowDeviceBezels() { engine.toggleShowDeviceBezels() }
    var showsTestingDevices: Bool { engine.showsTestingDevices }
    func toggleShowTestingDevices() { engine.toggleShowTestingDevices() }

    private func activateWindows() {
        guard !isHeadless else { return }
        if engine.windowControllers.isEmpty { showDeviceBrowser() }
        else { for controller in engine.windowControllers { controller.showAndActivate() } }
    }

    private func openRequestedSimulator(_ identifier: SimulatorDeviceIdentifier, requestIdentifier: String? = nil, bootIfNeeded: Bool = true) {
        guard terminationTask == nil, !isStopped else { return }
        let preservesOwnership = engine.ownedDeviceIdentifiers.contains(identifier) || engine.controller(for: identifier) != nil
        let task = Task {
            var result = ["udid": identifier.identifier]
            if let path = identifier.deviceSetPath { result["deviceSetPath"] = path }
            defer {
                if let requestIdentifier {
                    openRequests.removeValue(forKey: requestIdentifier)
                    DistributedNotificationCenter.default().postNotificationName(
                        Notification.Name("dev.lynnswap.NeoSimulator.RendererOpened"), object: requestIdentifier,
                        userInfo: result, deliverImmediately: true)
                }
            }
            do {
                try await withScreenOpenCleanup(preservingExisting: preservesOwnership, operation: {
                    try await self.engine.openSimulatorLocally(withIdentifier: identifier, bootIfNeeded: bootIfNeeded)
                }, cleanup: { try await self.engine.releaseDevice(identifier) })
            } catch {
                if !(error is CancellationError) { result["error"] = error.localizedDescription }
                if requestIdentifier == nil, !(error is CancellationError) {
                    NSAlert(presenting: error).runModal()
                    showDeviceBrowser()
                }
            }
        }
        if let requestIdentifier { openRequests[requestIdentifier] = (identifier, preservesOwnership, task) }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            do {
                switch try RendererRequest(url: url) {
                case .openDevice(let identifier):
                    if isManaged { openManager(command: "open-device", queryItems: identifier.queryItems) }
                    else { openRequestedSimulator(identifier) }
                case .quit(let asks):
                    if asks { quitAsking() }
                    else { Self.requestTermination() }
                case .activate: activateWindows()
                case .showBrowser: showDeviceBrowser()
                }
            } catch { NSAlert(presenting: error).runModal() }
        }
    }

    private func receiveManagerRequest(action: String?, identifier: SimulatorDeviceIdentifier?, requestIdentifier: String?, keepRunning: Bool?) {
        switch action {
        case "open-device":
            if let identifier { openRequestedSimulator(identifier, requestIdentifier: requestIdentifier) }
        case "attach-device":
            if let identifier {
                openRequestedSimulator(identifier, requestIdentifier: requestIdentifier, bootIfNeeded: false)
            }
        case "cancel-open":
            guard let identifier, let requestIdentifier,
                  let request = openRequests[requestIdentifier], request.device == identifier else { return }
            request.task.cancel()
            if !request.preservesOwnership { engine.cancelOpeningResources(identifier) }
        case "release-device":
            guard let identifier, let requestIdentifier else { return }
            Task {
                var result = ["udid": identifier.identifier]
                if let path = identifier.deviceSetPath { result["deviceSetPath"] = path }
                do { try await engine.releaseDevice(identifier) }
                catch { result["error"] = error.localizedDescription }
                DistributedNotificationCenter.default().postNotificationName(
                    Notification.Name("dev.lynnswap.NeoSimulator.RendererReleased"), object: requestIdentifier,
                    userInfo: result, deliverImmediately: true)
            }
        case "close-device":
            guard let identifier, let requestIdentifier else { return }
            Task {
                var result = ["udid": identifier.identifier]
                if let path = identifier.deviceSetPath { result["deviceSetPath"] = path }
                do {
                    let keepsRunning = keepRunning ?? HostPreferences.defaults.bool(forKey: HostPreferences.detachOnWindowClose)
                    if !keepsRunning {
                        let tools = try DeviceTools(identifier: identifier.identifier, xcodeURL: runtime.xcodeURL,
                                                    deviceSetPath: identifier.deviceSetPath)
                        try await tools.shutdown()
                    }
                    try await engine.releaseDevice(identifier)
                } catch { result["error"] = error.localizedDescription }
                DistributedNotificationCenter.default().postNotificationName(
                    Notification.Name("dev.lynnswap.NeoSimulator.RendererClosed"), object: requestIdentifier,
                    userInfo: result, deliverImmediately: true)
            }
        case "restart-device", "erase-device":
            guard let identifier, let requestIdentifier else { return }
            Task {
                var result: [String: Any] = ["udid": identifier.identifier, "handled": false]
                if let path = identifier.deviceSetPath { result["deviceSetPath"] = path }
                if let controller = engine.controller(for: identifier) {
                    result["handled"] = true
                    do {
                        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                            engine.restartDevice(controller, erasing: action == "erase-device") { failure in
                                if let failure { continuation.resume(throwing: failure) }
                                else { continuation.resume() }
                            }
                        }
                    } catch { result["error"] = error.localizedDescription }
                } else if isHeadless, engine.ownedDeviceIdentifiers.contains(identifier) {
                    result["handled"] = true
                    do { try await engine.restartHeadlessDevice(identifier, erasing: action == "erase-device") }
                    catch { result["error"] = error.localizedDescription }
                }
                DistributedNotificationCenter.default().postNotificationName(
                    Notification.Name("dev.lynnswap.NeoSimulator.RendererManaged"), object: requestIdentifier,
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

    private struct Registration: Codable {
        let processIdentifier: Int32
        let ownerProcessIdentifier: Int32?
        let ownerLaunchDate: Date?
        let applicationPath: String
        let xcodePath: String
        let sessionIdentifier: String
        let deviceIdentifiers: [SimulatorDeviceIdentifier]
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
                                        ownerProcessIdentifier: owner?.processIdentifier,
                                        ownerLaunchDate: owner?.launchDate,
                                        applicationPath: Bundle.main.bundleURL.standardizedFileURL.path,
                                        xcodePath: runtime.xcodeURL.standardizedFileURL.path,
                                        sessionIdentifier: sessionIdentifier,
                                        deviceIdentifiers: engine.registrationDeviceIdentifiers)
        try JSONEncoder().encode(registration).write(to: url, options: .atomic)
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("dev.lynnswap.NeoSimulator.RendererDevicesDidChange"),
            object: sessionIdentifier,
            userInfo: testingVisibilityChanged ? ["testingVisibilityChanged": true] : nil,
            deliverImmediately: true)
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
            } catch { NSAlert(presenting: error).runModal() }
        }
    }

    private func openManagerURL(_ url: URL, at managerURL: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.allowsRunningApplicationSubstitution = false
        try await NSWorkspace.shared.open([url], withApplicationAt: managerURL, configuration: configuration)
    }

    /// Prefers the saved identity, then the last iPhone or first device across the available catalog.
    static func initialDevice(in devices: [AvailableDevice], current: SimulatorDeviceIdentifier?) -> AvailableDevice? {
        if let current, let identifier = UUID(uuidString: current.identifier),
           let device = devices.first(where: { $0.identity.deviceSetPath == current.deviceSetPath && UUID(uuidString: $0.identifier) == identifier }) {
            return device
        }
        return devices.last { $0.productFamily == 1 && $0.deviceTypeName.contains("iPhone") } ?? devices.first
    }

    static func observeHandoverSignal(_ onHandover: @escaping @MainActor @Sendable () -> Void) -> DispatchSourceSignal {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        // DispatchSourceHandler is not Sendable, so make this worker callback's isolation explicit.
        source.setEventHandler { @Sendable in
            // An alert shown from a main-queue block keeps the main queue busy,
            // but its modal loop still runs main run-loop blocks.
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
                MainActor.assumeIsolated { onHandover() }
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        source.resume()
        return source
    }

    nonisolated static func requestTerminationAfterOwnerExit() {
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
            MainActor.assumeIsolated {
                guard let target = handoverTarget else { exit(EX_OK) }
                // No manager remains to answer dialogs. The saved normal quit policy still applies.
                target.ownerExitRequested = true
                requestTermination()
            }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    /// Terminate from a run-loop callback after dismissing modal alerts.
    /// AppKit termination inside a main-queue block or modal loop deadlocks pending main-actor work.
    private static func requestTermination() {
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated {
                if NSApp.modalWindow != nil {
                    NSApp.abortModal()
                    // The modal loop notices the abort after its next event.
                    if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                                                      timestamp: 0, windowNumber: 0, context: nil, subtype: 0,
                                                      data1: 0, data2: 0) {
                        NSApp.postEvent(event, atStart: false)
                    }
                }
                RunLoop.main.perform(inModes: [.default]) {
                    MainActor.assumeIsolated { NSApp.terminate(nil) }
                }
            }
        }
    }

    /// Quit NeoSimulator…: asks whether to shut the devices down, and quits
    /// unless the choice is Cancel.
    func quitAsking() {
        if isManaged {
            openManager(command: "quit", queryItems: [URLQueryItem(name: "ask", value: "true")])
            return
        }
        let alert = DeviceLifetimeChoice.alert(
            quitting: true, keepsRunningByDefault: HostPreferences.defaults.bool(forKey: HostPreferences.detachOnAppQuit))
        guard let choice = DeviceLifetimeChoice.choice(
            for: alert.runModal(), of: alert, rememberingAs: HostPreferences.detachOnAppQuit) else { return }
        quitChoice = choice
        NSApp.terminate(nil)
    }

    /// Brings the existing creation form forward or opens one.
    func showNewSimulator() {
        guard !isStopped else { return }
        if newSimulator == nil {
            let catalog: SimulatorCatalog
            do { catalog = try engine.creationCatalog() } catch {
                report(error)
                return
            }
            let xcodeURL = runtime.xcodeURL
            let model = NewSimulatorModel(catalog: catalog, create: { name, deviceType, runtime in
                try await DeviceTools.createDevice(named: name, deviceType: deviceType, runtime: runtime,
                                                   xcodeURL: xcodeURL)
            }, pair: { watch, phone in
                try await DeviceTools.pairDevices(watch: watch, phone: phone, xcodeURL: xcodeURL)
            }, preferences: creationPreferences)
            newSimulator = NewSimulatorWindowController(model: model, reportFailure: { [weak self] error in
                self?.report(error)
            }, onClose: { [weak self] in self?.newSimulator = nil })
        }
        newSimulator?.showWindow(nil)
        newSimulator?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func showDeviceBrowser() {
        guard !isStopped else { return }
        if isHeadless { return }
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
            NSAlert(presenting: error).runModal()
            return
        }
        showDeviceBrowser()
        browser?.report(error)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        activateWindows()
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isManaged, !managerRequestedQuit, !handoverRequested, !ownerExitRequested {
            openManager(command: "quit")
            return .terminateCancel
        }
        guard terminationTask == nil else { return .terminateLater }
        CaptureThumbnail.savesImmediately = true
        let keepsRunning = handoverRequested || quitChoice == .keepRunning
            || (quitChoice == nil && HostPreferences.defaults.bool(forKey: HostPreferences.detachOnAppQuit))
        terminationTask = Task {
            let requests = openRequests.values.map(\.task)
            requests.forEach { $0.cancel() }
            for request in requests { await request.value }
            do { try await engine.stop(keepingDevicesRunning: keepsRunning) }
            catch {
                if ownerExitRequested || handoverRequested { hostLog(error.localizedDescription) }
                else { NSAlert(presenting: error).runModal() }
            }
            shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        CaptureThumbnail.savesImmediately = true
        CaptureThumbnail.finishAll()
        shutdown()
    }

    func shutdown() {
        engine.shutdown()
        if let requestObserver {
            DistributedNotificationCenter.default().removeObserver(requestObserver)
            self.requestObserver = nil
        }
        if let locationObserver {
            DistributedNotificationCenter.default().removeObserver(locationObserver)
            self.locationObserver = nil
        }
        handoverSignal?.cancel()
        handoverSignal = nil
        browser?.close()
        newSimulator?.close()
        browser = nil
        if isManaged {
            do { try FileManager.default.removeItem(at: registrationURL) }
            catch where (error as NSError).code == NSFileNoSuchFileError {}
            catch { hostLog("Could not remove simulator ownership: \(error.localizedDescription)") }
        }
    }
}
