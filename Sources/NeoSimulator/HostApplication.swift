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
    private var sessions: [String: DeviceWindowController] = [:]
    private var connections: [String: Task<Void, Never>] = [:]
    private var bootOperations: [String: DeviceTools] = [:]
    /// Running restarts. Their windows stay open while the device is down
    /// and reconnect only after the restart finishes.
    private var restarting: [String: Task<Void, Never>] = [:]
    /// Windows that reconnect when their restarted device boots.
    private var awaitingReconnect: [String: DeviceWindowController] = [:]
    private var suppressed: Set<String> = []
    private var reportedFailures: Set<String> = []
    private var browser: DeviceBrowserWindowController?
    private var menu: MenuController?
    private var stopped = false
    private var nextWindowPosition = NSPoint.zero

    init(runtime: SimulatorRuntime, conflicts: HostConflictMonitor) throws {
        try conflicts.check()
        self.runtime = runtime
        self.conflicts = conflicts
        deviceSet = try runtime.openDeviceSet()
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
        try conflicts.check()
        try scanDevices()
        if sessions.isEmpty { showDeviceBrowser() }
    }

    func availableSimulatorDevices() throws -> [AvailableDevice] {
        try readDevices().map(Self.describe)
    }

    private func readDevices() throws -> [SimulatorDevice] {
        try deviceSet.readDevices().filter { $0.platformIdentifier == "com.apple.platform.iphonesimulator" }
    }

    private static func describe(_ device: SimulatorDevice) -> AvailableDevice {
        AvailableDevice(identifier: device.identifier, name: device.name, runtimeName: device.runtimeName, state: device.state)
    }

    private static func capabilities(of device: SimulatorDevice) -> DeviceCapabilities {
        DeviceCapabilities(family: DeviceCapabilities.Family(rawValue: device.productFamily),
                           runtimeVersion: device.runtimeVersion,
                           supportsFeature: { [device] in device.supportsFeature($0) })
    }

    func openSimulator(withIdentifier identifier: String) async throws {
        guard !stopped else { throw HostError.operation("NeoSimulator is shutting down") }
        try conflicts.check()
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
        try conflicts.check()
        let booted = try readDevices().filter { $0.state == 3 }
        let identifiers = Set(booted.map(\.identifier))
        let hadDeviceWindows = !sessions.isEmpty
        for identifier in sessions.keys where !identifiers.contains(identifier) && restarting[identifier] == nil {
            sessions.removeValue(forKey: identifier)?.invalidate()
            awaitingReconnect.removeValue(forKey: identifier)
        }
        for identifier in connections.keys where !identifiers.contains(identifier) {
            connections[identifier]?.cancel()
        }
        suppressed.formIntersection(identifiers)
        reportedFailures.formIntersection(identifiers)
        for device in booted where (sessions[device.identifier] == nil
                || (awaitingReconnect[device.identifier] != nil && restarting[device.identifier] == nil))
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
                            tools: try DeviceTools(identifier: identifier, xcodeURL: runtime.xcodeURL),
                            recordings: recordings)
                        if let controller = awaitingReconnect.removeValue(forKey: identifier) {
                            try conflicts.check()
                            controller.reconnect(session)
                            return
                        }
                        let controller = try DeviceWindowController(session: session, onClose: { [weak self] identifier in
                            self?.sessions.removeValue(forKey: identifier)
                            self?.awaitingReconnect.removeValue(forKey: identifier)
                            self?.suppressed.insert(identifier)
                            if self?.sessions.isEmpty == true { self?.showDeviceBrowser() }
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

    // MARK: Restart

    /// Restarts a device in Simulator.app's order, keeping its window: the
    /// window disconnects, the device shuts down, is erased when requested,
    /// and boots, and the window reconnects.
    private func restartDevice(_ controller: DeviceWindowController, erasing: Bool) {
        let identifier = controller.session.device.id
        guard !stopped, sessions[identifier] === controller, restarting[identifier] == nil,
              bootOperations[identifier] == nil else { return }
        let tools: DeviceTools
        do { tools = try DeviceTools(identifier: identifier, xcodeURL: runtime.xcodeURL) } catch {
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
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard recordings.hasActiveRecordings else { return .terminateNow }
        guard !isTerminating else { return .terminateLater }
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
        conflicts.onConflict = nil
        if let notificationToken {
            do { try deviceSet.stopObserving(notificationToken) }
            catch { hostLog("Could not unregister simulator notifications: \(error.localizedDescription)") }
        }
        notificationToken = nil
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
        browser = nil
    }
}
