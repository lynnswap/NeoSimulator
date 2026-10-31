import AppKit
import Observation
@_spi(NeoSimulator) import XcodeSimulatorHost

/// The device screens open in the manager, the in-process host that presents each Xcode's simulators, and the
/// connections of remote screens.
///
/// Each `HostApplication` stays authoritative for its simulator sessions; this registry indexes their controllers
/// by inventory identity. Remote screens have no other owner, so the registry also owns their lifetimes. Screens
/// enter and leave only through `insert(_:)` and `remove(_:)`, which publish the open set to posture observation.
@MainActor @Observable
final class DeviceScreens {
    private var entries: [DeviceInventoryID: DeviceScreen] = [:]
    /// The Xcode whose SimulatorKit UI toolkit the manager loaded, which also supplies device artwork.
    private(set) var displayXcodeURL: URL?
    @ObservationIgnored private let model: SimulatorManagerModel
    @ObservationIgnored private var hosts: [URL: HostApplication] = [:]
    /// Hosts that stopped while the app kept running, after a host conflict or a failed quit. Stopping the screens
    /// stops them again, which retries the native input they could not remove.
    @ObservationIgnored private var stoppedHosts: [HostApplication] = []
    /// Set while the app quits, until a cancelled quit resumes.
    @ObservationIgnored private(set) var isQuitting = false
    @ObservationIgnored private var lastRemoteHost: SimulatorHost?
    @ObservationIgnored private var remoteHostCleanup: Task<Void, Never>?
    @ObservationIgnored var onError: ((any Error) -> Void)?
    @ObservationIgnored var onShowInMainWindow: ((DeviceInventoryID) -> Void)?
    /// A screen's import or application drop changed the device's installed applications.
    @ObservationIgnored var onApplicationsChange: ((DeviceInventoryID) -> Void)?
    /// Edit ▸ Automatically Sync Pasteboard for every simulator screen, whichever host presents it.
    @ObservationIgnored private(set) lazy var pasteboardSync = PasteboardSync { [weak self] in
        self?.simulatorControllers.map(\.session) ?? []
    }

    init(model: SimulatorManagerModel) {
        self.model = model
    }

    var identifiers: Set<DeviceInventoryID> { Set(entries.keys) }

    func screen(for identifier: DeviceInventoryID) -> DeviceScreen? { entries[identifier] }

    /// The CoreDevice identifiers of the open screens that show DeviceKit's native device canvas. DeviceKit's Active
    /// value depends on its views, and evaluating it for another device can start that device's native HID services.
    var nativeCanvasDeviceIdentifiers: Set<UUID> {
        Set(entries.values.filter(\.usesNativeCanvas).compactMap { screen in
            guard case .simulator(let simulator) = model.inventory.first(where: { $0.id == screen.id }) else { return nil }
            return simulator.coreDevice.flatMap { UUID(uuidString: $0.identifier) }
        })
    }

    // MARK: Registration

    /// Registers a host's simulator presentation, or returns its screen when the controller is already registered.
    @discardableResult
    func attach(_ controller: DeviceWindowController, as identifier: DeviceInventoryID) -> DeviceScreen {
        if let screen = entries[identifier], case .simulator(let current) = screen.controller, current === controller {
            return screen
        }
        let screen = DeviceScreen(id: identifier, controller: .simulator(controller), model: model, screens: self)
        controller.onShowInMainWindow = { [weak self] in self?.onShowInMainWindow?(identifier) }
        insert(screen)
        return screen
    }

    /// Registers a remote screen until its controller closes.
    @discardableResult
    func attach(_ controller: RemoteDeviceWindowController) -> DeviceScreen {
        let identifier = DeviceInventoryID.coreDevice(controller.device.identifier)
        let screen = DeviceScreen(id: identifier, controller: .remote(controller), model: model, screens: self)
        controller.onClose = { [weak self, weak screen] in
            guard let self, let screen, self.entries[identifier] === screen else { return }
            self.remove([identifier])
        }
        controller.onShowInMainWindow = { [weak self] in self?.onShowInMainWindow?(identifier) }
        controller.onConnect = { [weak self, weak screen] in
            guard let self, let screen, self.entries[identifier] === screen else { return }
            await self.model.deviceScreenDidConnect(identifier)
        }
        controller.canInstallApplications = { [weak self] in self?.model.canInstallApplications(on: identifier) == true }
        controller.installApplications = { [weak self] urls in
            self?.model.installApplications(at: urls, on: identifier) { self?.onApplicationsChange?(identifier) }
        }
        insert(screen)
        return screen
    }

    private func insert(_ screen: DeviceScreen) {
        entries.updateValue(screen, forKey: screen.id)?.stopObserving()
        screen.startObserving()
        publishOpenScreens()
    }

    private func remove(_ identifiers: [DeviceInventoryID]) {
        let removed = identifiers.compactMap { entries.removeValue(forKey: $0) }
        guard !removed.isEmpty else { return }
        for screen in removed { screen.stopObserving() }
        publishOpenScreens()
    }

    private func publishOpenScreens() {
        model.setOpenDeviceScreens(isQuitting ? [] : Set(entries.keys))
    }

    private var simulatorIdentifiers: [DeviceInventoryID] {
        entries.compactMap { identifier, screen in
            if case .simulator = screen.controller { identifier } else { nil }
        }
    }

    private var simulatorControllers: [DeviceWindowController] {
        entries.values.compactMap { screen in
            if case .simulator(let controller) = screen.controller { controller } else { nil }
        }
    }

    private var remoteControllers: [DeviceInventoryID: RemoteDeviceWindowController] {
        entries.compactMapValues { screen in
            if case .remote(let controller) = screen.controller { controller } else { nil }
        }
    }

    // MARK: Simulator screens

    /// Opens the simulator's screen in the host for its source Xcode, moving it from another host first, and lets
    /// `present` place it with the presentation it replaces. A cancelled open releases a screen it attached.
    func openSimulatorScreen(_ context: SimulatorPresentationContext,
                             present: (SimulatorScreenRestoration.Presentation?) async throws -> Void) async throws {
        guard !isQuitting else { throw CancellationError() }
        let displayURL = try await CoreDeviceRuntime.uiXcodeURL()
        try Task.checkCancellation()
        if displayXcodeURL != displayURL { displayXcodeURL = displayURL }
        let sourceURL = context.xcodeURL.standardizedFileURL.resolvingSymlinksInPath()
        let host = try await host(for: sourceURL, displayXcodeURL: displayURL)
        guard case .simulator(let udid, let path) = context.deviceID else { return }
        let identifier = SimulatorDeviceIdentifier(udid, deviceSetPath: path)
        var previousPresentation: SimulatorScreenRestoration.Presentation?
        for (url, previous) in hosts where url != sourceURL && previous.openedDeviceIdentifiers.contains(identifier) {
            try await previous.releasePresentation(for: identifier) { controller in
                previousPresentation = .init(isEmbedded: controller.isEmbedded, window: controller.window)
            }
            remove([context.deviceID])
        }
        let preservesPresentation = host.openedDeviceIdentifiers.contains(identifier)
        var attached = false
        do {
            let controller = try await host.openPresentation(for: identifier, bootIfNeeded: false)
            attached = true
            try Task.checkCancellation()
            if let current = entries[context.deviceID] { previousPresentation = current.presentation }
            attach(controller, as: context.deviceID)
            try await present(previousPresentation)
        } catch {
            if Task.isCancelled, attached, !preservesPresentation {
                try await Task { try await host.releasePresentation(for: identifier) }.value
            }
            throw error
        }
    }

    private func host(for sourceURL: URL, displayXcodeURL: URL) async throws -> HostApplication {
        if let host = hosts[sourceURL] { return host }
        let runtime = try await SimulatorRuntime.load(xcodeURL: sourceURL, uiXcodeURL: displayXcodeURL)
        try Task.checkCancellation()
        let host = try HostApplication(runtime: runtime, conflicts: HostConflictMonitor(), inProcess: true,
                                       pasteboardSync: pasteboardSync)
        host.onError = { [weak self] error in self?.onError?(error) }
        host.onChange = { [weak self] in self?.hostsChanged() }
        host.onClose = { [weak self] device, choice, finishing in
            guard let self else { return }
            let identifier = device.inventoryID
            self.remove([identifier])
            let keepRunning = choice == .keepRunning || (choice == nil && HostPreferences.defaults.bool(forKey: HostPreferences.detachOnWindowClose))
            self.model.closeDevice(identifier, keepingDeviceRunning: keepRunning, after: finishing)
        }
        host.onRestart = { [weak self] device, erasing in
            guard let self, let current = self.model.inventory.first(where: { $0.id == device.inventoryID }) else { return }
            self.model.manage(erasing ? .erase : .restart, devices: [current])
        }
        host.onShutDown = { [weak self] device in
            guard let self, let current = self.model.inventory.first(where: { $0.id == device.inventoryID }) else { return }
            self.model.manage(.shutdown, devices: [current])
        }
        host.onApplicationsChange = { [weak self] device in self?.onApplicationsChange?(device.inventoryID) }
        try host.start()
        hosts[sourceURL] = host
        return host
    }

    /// Releases the screens whose sessions their host ended, and retires the hosts that stopped.
    private func hostsChanged() {
        for (url, host) in hosts where host.isStopped {
            hosts.removeValue(forKey: url)
            stoppedHosts.append(host)
        }
        let opened = Set(hosts.values.flatMap(\.openedDeviceIdentifiers).map(\.inventoryID))
        remove(simulatorIdentifiers.filter { !opened.contains($0) })
    }

    /// Prepares the open screens of simulators that a management action stops or restarts. A booted simulator keeps
    /// its screen through a restart; the others release it. A failure finishes the restarts it already prepared.
    func prepareSimulatorManagement(_ action: DeviceManagementAction, devices: [InventoryDevice]) async throws {
        var prepared: [InventoryDevice] = []
        do {
            for device in devices {
                guard case .simulator(let simulator) = device, device.supports(action), entries[device.id] != nil,
                      case .simulator(let udid, let path) = device.id else { continue }
                let identifier = SimulatorDeviceIdentifier(udid, deviceSetPath: path)
                guard let host = hosts.values.first(where: { $0.openedDeviceIdentifiers.contains(identifier) }) else { continue }
                switch action {
                case .restart, .erase:
                    if simulator.state == "Booted" {
                        try await host.preparePresentationForRestart(for: identifier)
                        prepared.append(device)
                    } else {
                        try await host.releasePresentation(for: identifier)
                        remove([device.id])
                    }
                case .shutdown, .forceShutdown, .remove:
                    try await host.releasePresentation(for: identifier)
                    remove([device.id])
                default: break
                }
            }
        } catch {
            do { try await finishSimulatorManagement(action, devices: prepared) }
            catch let cleanupError {
                throw HostError.operation([error.localizedDescription, cleanupError.localizedDescription].joined(separator: "\n"))
            }
            throw error
        }
    }

    /// Reconnects the screens that a restart or erase kept, reporting each simulator that could not reconnect.
    func finishSimulatorManagement(_ action: DeviceManagementAction, devices: [InventoryDevice]) async throws {
        guard action == .restart || action == .erase else { return }
        var failures: [String] = []
        for device in devices {
            guard case .simulator(let udid, let path) = device.id else { continue }
            let identifier = SimulatorDeviceIdentifier(udid, deviceSetPath: path)
            guard let host = hosts.values.first(where: { $0.openedDeviceIdentifiers.contains(identifier) }) else { continue }
            do { try await host.finishPresentationRestart(for: identifier) }
            catch { failures.append("\(device.name): \(error.localizedDescription)") }
        }
        hostsChanged()
        if !failures.isEmpty { throw HostError.operation(failures.joined(separator: "\n")) }
    }

    /// The open simulator screens to reopen after relaunching, ordered so the main window's screen opens last.
    func restorations() -> [SimulatorScreenRestoration] {
        hosts.flatMap { xcode, host in
            host.openedDeviceIdentifiers.compactMap { device -> SimulatorScreenRestoration? in
                guard let screen = entries[device.inventoryID] else { return nil }
                return SimulatorScreenRestoration(device: device, xcodeURL: xcode, presentation: screen.presentation)
            }
        }.sorted { $0.presentation.restorationOrder < $1.presentation.restorationOrder }
    }

    func setDeviceBezelsVisible(_ visible: Bool) {
        for controller in simulatorControllers { controller.setDeviceBezelVisible(visible) }
    }

    // MARK: Remote screens

    /// Opens or reconnects the device's remote screen unless the device is being managed or the app is quitting.
    func openRemoteScreen(for device: CoreDeviceDevice) -> DeviceScreen? {
        let identifier = DeviceInventoryID.coreDevice(device.identifier)
        guard !isQuitting, !model.managingDeviceIDs.contains(identifier) else { return nil }
        let screen = entries[identifier] ?? attach(RemoteDeviceWindowController(device: device))
        if case .remote(let controller) = screen.controller { controller.connectIfNeeded() }
        return screen
    }

    /// Follows the inventory and the selected host, which can make remote screens unavailable.
    func observeRemoteDevices() {
        withObservationTracking {
            _ = model.inventory
            _ = model.status?.host
            _ = model.isRemoteInventoryComplete
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateRemoteScreens()
                self?.observeRemoteDevices()
            }
        }
    }

    private func updateRemoteScreens() {
        if model.isRemoteInventoryComplete {
            for (identifier, controller) in remoteControllers {
                controller.updateInventory(model.inventory.first { $0.id == identifier })
            }
        }
        let host = model.status?.host
        let changedToDeviceHub = host == .deviceHub && lastRemoteHost != .deviceHub
        if let host { lastRemoteHost = host }
        if changedToDeviceHub, !remoteControllers.isEmpty, remoteHostCleanup == nil {
            remoteHostCleanup = Task { [weak self] in
                guard let self else { return }
                defer { self.remoteHostCleanup = nil }
                do { try await self.stopRemoteScreens() }
                catch is CancellationError {}
                catch { self.onError?(error) }
            }
        }
    }

    /// Waits for the remote screens that switching to Device Hub is closing.
    func waitForRemoteHostCleanup() async {
        await remoteHostCleanup?.value
    }

    /// Stops and closes remote screens, all of them by default. One screen's failure does not keep the others open;
    /// a cancellation leaves the remaining screens open.
    func stopRemoteScreens(for identifiers: Set<DeviceInventoryID>? = nil) async throws {
        var failures: [String] = []
        let targets = remoteControllers.filter { identifiers?.contains($0.key) ?? true }.map(\.value)
        for controller in targets {
            do { try await controller.stopAndClose() }
            catch is CancellationError {
                if !failures.isEmpty { throw RemoteDeviceWindowError.cleanup(failures) }
                throw CancellationError()
            }
            catch { failures.append("\(controller.device.name): \(error.localizedDescription)") }
        }
        if !failures.isEmpty { throw RemoteDeviceWindowError.cleanup(failures) }
    }

    // MARK: Stopping

    /// Refuses new screens while the app quits, and keeps later registry changes from restarting posture observation.
    func beginQuitting() { isQuitting = true }

    func resumeAfterCancelledQuit() {
        isQuitting = false
        publishOpenScreens()
    }

    /// Stops every screen without shutting devices down: in-process hosts leave guest lifetime to the backend, and
    /// remote screens end only their connections. Screens left open by a failure resume posture observation.
    func stopAll() async throws {
        do {
            await model.stopDevicePostures()
            for host in stoppedHosts + hosts.values { try await host.stop(keepingDevicesRunning: true) }
            hosts.removeAll()
            stoppedHosts.removeAll()
            remove(simulatorIdentifiers)
            try await stopRemoteScreens()
        } catch {
            publishOpenScreens()
            throw error
        }
    }
}

private extension SimulatorDeviceIdentifier {
    var inventoryID: DeviceInventoryID { .simulator(udid: identifier, deviceSetPath: deviceSetPath) }
}
