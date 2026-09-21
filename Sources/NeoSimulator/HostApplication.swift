import AppKit

@MainActor
final class HostApplication: NSObject, NSApplicationDelegate, DeviceBrowserSource {
    static var conflictingHostName: String? {
        for (identifier, name) in [("com.apple.dt.Devices", "Device Hub"), ("com.apple.iphonesimulator", "Simulator")] {
            if !NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty { return name }
        }
        return nil
    }

    private let runtime: SimulatorRuntime
    private let deviceSet: XSHDeviceSetHandle
    private let recordings = RecordingStore()
    private var isTerminating = false
    private var recordingTerminationErrors: [Error] = []
    private var notificationToken: UInt64?
    private var workspaceObserver: (any NSObjectProtocol)?
    private var sessions: [String: DeviceWindowController] = [:]
    private var connections: [String: Task<Void, Never>] = [:]
    private var bootOperations: [String: DeviceTools] = [:]
    private var suppressed: Set<String> = []
    private var reportedFailures: Set<String> = []
    private var browser: DeviceBrowserWindowController?
    private var menu: MenuController?
    private var stopped = false
    private var nextWindowPosition = NSPoint.zero
    private var observedConflict: String?

    init(runtime: SimulatorRuntime) throws {
        if let name = Self.conflictingHostName {
            throw HostError.conflict("\(name) is running; close it before opening NeoSimulator")
        }
        self.runtime = runtime
        deviceSet = try runtime.openDeviceSet()
        super.init()
        recordings.onError = { [weak self] error in
            guard let self else { return }
            if self.isTerminating { self.recordingTerminationErrors.append(error) }
            else { self.report(error) }
        }
    }

    func start() throws {
        try checkForConflict()
        menu = MenuController(application: self)
        menu?.install()
        notificationToken = try deviceSet.observe { [weak self] in
            MainActor.assumeIsolated { self?.rescan() }
        }.uint64Value
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let name = Self.conflictName(for: application.bundleIdentifier) else { return }
            MainActor.assumeIsolated {
                self?.observedConflict = name
                self?.handleHostConflict()
            }
        }
        try checkForConflict()
        try scanDevices()
        if sessions.isEmpty { showDeviceBrowser() }
    }

    nonisolated private static func conflictName(for identifier: String?) -> String? {
        switch identifier {
        case "com.apple.dt.Devices": "Device Hub"
        case "com.apple.iphonesimulator": "Simulator"
        default: nil
        }
    }

    private func checkForConflict() throws {
        if let name = observedConflict ?? Self.conflictingHostName {
            throw HostError.conflict("\(name) is running; close it before opening NeoSimulator")
        }
    }

    func availableSimulatorDevices() throws -> [AvailableDevice] {
        try readDevices().map(Self.describe)
    }

    private func readDevices() throws -> [XSHDeviceHandle] {
        try deviceSet.readDevices().filter { $0.platformIdentifier == "com.apple.platform.iphonesimulator" }
    }

    private static func describe(_ device: XSHDeviceHandle) -> AvailableDevice {
        AvailableDevice(identifier: device.identifier, name: device.name, runtimeName: device.runtimeName, state: device.state)
    }

    func openSimulator(withIdentifier identifier: String) async throws {
        guard !stopped else { throw HostError.operation("NeoSimulator is shutting down") }
        try checkForConflict()
        guard let device = try readDevices().first(where: { $0.identifier == identifier }) else {
            throw HostError.operation("The selected simulator is no longer available")
        }
        suppressed.remove(identifier)
        reportedFailures.remove(identifier)
        if device.state != 3 {
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
        try checkForConflict()
        let booted = try readDevices().filter { $0.state == 3 }
        let identifiers = Set(booted.map(\.identifier))
        let hadDeviceWindows = !sessions.isEmpty
        for identifier in sessions.keys where !identifiers.contains(identifier) {
            sessions.removeValue(forKey: identifier)?.invalidate()
        }
        for identifier in connections.keys where !identifiers.contains(identifier) {
            connections[identifier]?.cancel()
        }
        suppressed.formIntersection(identifiers)
        reportedFailures.formIntersection(identifiers)
        for device in booted where sessions[device.identifier] == nil
            && connections[device.identifier] == nil
            && !suppressed.contains(device.identifier)
            && !reportedFailures.contains(device.identifier) {
            connect(device)
        }
        if hadDeviceWindows && sessions.isEmpty { showDeviceBrowser() }
        browser?.refresh()
    }

    private func connect(_ device: XSHDeviceHandle) {
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
                    try checkForConflict()
                    if let screen = XSHFindDefaultScreen(runtime.screenClass, device) {
                        let connection = try SimulatorConnection(device: device, screenID: screen.uint32Value, runtime: runtime)
                        let controller = try DeviceWindowController(
                            device: Self.describe(device), display: connection,
                            tools: try DeviceTools(identifier: identifier, xcodeURL: runtime.xcodeURL),
                            recordings: recordings
                        ) { [weak self] identifier in
                            self?.sessions.removeValue(forKey: identifier)
                            self?.suppressed.insert(identifier)
                            if self?.sessions.isEmpty == true { self?.showDeviceBrowser() }
                        }
                        try checkForConflict()
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
        guard !stopped, let name = observedConflict ?? Self.conflictingHostName else { return }
        hostLog("\(name) appeared; disconnecting simulators and exiting")
        shutdown()
        NSApp.terminate(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if sessions.isEmpty { showDeviceBrowser() }
        else { for session in sessions.values { session.showAndActivate() } }
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        guard recordings.hasActiveRecordings else { return .terminateNow }
        isTerminating = true
        Task {
            await recordings.finishAll()
            for error in recordingTerminationErrors { NSAlert(error: error).runModal() }
            recordingTerminationErrors.removeAll()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) { shutdown() }

    func shutdown() {
        guard !stopped else { return }
        stopped = true
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
        workspaceObserver = nil
        if let notificationToken {
            do { try deviceSet.stopObserving(notificationToken) }
            catch { hostLog("Could not unregister simulator notifications: \(error.localizedDescription)") }
        }
        notificationToken = nil
        for task in connections.values { task.cancel() }
        connections.removeAll()
        for tools in bootOperations.values { tools.cancel() }
        bootOperations.removeAll()
        for session in sessions.values { session.invalidate() }
        sessions.removeAll()
        browser?.close()
        browser = nil
    }
}
