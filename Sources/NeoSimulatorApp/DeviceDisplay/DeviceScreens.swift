import AppKit
import NeoSimulatorDeviceIO
import NeoSimulatorHostSupport
import NeoSimulatorKit
import NeoSimulatorUI
import Observation
import ObservationBridge

/// The device screens open in the manager and their simulator contexts and remote connections.
///
/// Each `SimulatorScreens` owns its simulator screens; this registry indexes their controllers
/// by inventory identity. Remote screens have no other owner, so the registry also owns their lifetimes. Screens
/// enter and leave only through `insert(_:)` and `remove(_:)`, which publish the open set to posture observation.
@MainActor @Observable
final class DeviceScreens {
    private var entries: [DeviceInventoryID: DeviceScreen] = [:]
    /// The Xcode whose SimulatorKit UI toolkit the manager loaded, which also supplies device artwork.
    private(set) var displayXcodeURL: URL?
    @ObservationIgnored private let model: SimulatorManagerModel
    @ObservationIgnored private var contexts: [URL: SimulatorScreens] = [:]
    /// Invalidated contexts remain available until their native resources have finished closing.
    @ObservationIgnored private var retiredContexts: [SimulatorContext] = []
    @ObservationIgnored private lazy var hostTakeovers = HostTakeovers<SimulatorContext>(didBegin: { [weak self] in
        self?.model.cancelPendingSimulatorOpens()
    }, report: { [weak self] error in
        self?.onError?(error)
    })
    /// Set while the app quits, until a cancelled quit resumes.
    @ObservationIgnored private(set) var isQuitting = false
    @ObservationIgnored private var locationObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var remoteDevicesObservation: PortableObservationTracking.Token?
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
        locationObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("dev.lynnswap.NeoSimulator.DeviceLocationChanged"),
            object: nil, queue: .main
        ) { [weak self] notification in
            let udid = notification.object as? String
            let path = notification.userInfo?["deviceSetPath"] as? String
            let identifier = udid.map { SimulatorDeviceIdentifier($0, deviceSetPath: path) }
            MainActor.assumeIsolated {
                guard let self, let identifier else { return }
                do {
                    try self.simulatorControllers.first { $0.session.device.identity == identifier }?
                        .session.refreshLocationSelection()
                } catch { self.onError?(error) }
            }
        }
    }

    isolated deinit {
        if let locationObserver { DistributedNotificationCenter.default().removeObserver(locationObserver) }
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

    @discardableResult
    private func attach(_ presentation: SimulatorScreen, as identifier: DeviceInventoryID) throws -> DeviceScreen {
        guard !presentation.isClosed else { throw CancellationError() }
        let controller = presentation.controller
        let screen = attach(controller, as: identifier)
        presentation.onEnd = { [weak self, weak controller] _ in
            guard let self, let controller,
                  case .simulator(let current) = self.entries[identifier]?.controller,
                  current === controller else { return }
            self.remove([identifier])
        }
        return screen
    }

    /// Registers a simulator presentation's controller, or returns its existing screen.
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

    /// Opens a screen in its Xcode context, releasing any previous context's presentation first.
    /// The backend serializes requests for the same device through cancellation cleanup.
    func openSimulatorScreen(_ request: SimulatorPresentationContext,
                             present: (SimulatorScreenRestoration.Presentation?) async throws -> Void) async throws {
        guard !isQuitting else { throw CancellationError() }
        let displayURL = try await CoreDeviceRuntime.uiXcodeURL()
        try Task.checkCancellation()
        if displayXcodeURL != displayURL { displayXcodeURL = displayURL }
        let sourceURL = request.xcodeURL.standardizedFileURL.resolvingSymlinksInPath()
        let screens = try await simulatorScreens(for: sourceURL)
        guard case .simulator(let udid, let path) = request.deviceID.destination else { return }
        let identifier = SimulatorDeviceIdentifier(udid, deviceSetPath: path)
        var previousPresentation: SimulatorScreenRestoration.Presentation?
        for (url, previous) in contexts where url != sourceURL {
            if let screen = previous.screen(for: identifier) {
                previousPresentation = entries[request.deviceID]?.presentation
                    ?? .init(isEmbedded: screen.controller.isEmbedded, window: screen.controller.window)
            }
            try await previous.context.releaseSession(identifier)
        }
        for retired in retiredContexts {
            try await retired.releaseSession(identifier)
        }
        let preservesPresentation = screens.screen(for: identifier) != nil
        let context = screens.context
        do {
            let screen = try await screens.open(identifier)
            try Task.checkCancellation()
            if let current = entries[request.deviceID] { previousPresentation = current.presentation }
            try attach(screen, as: request.deviceID)
            try await present(previousPresentation)
        } catch {
            if case SimulatorError.conflict = error { context.checkForHostConflict() }
            if context.isStopped { throw CancellationError() }
            if Task.isCancelled, !preservesPresentation {
                try await Task { try await context.releaseSession(identifier) }.value
            }
            throw error
        }
    }

    private func simulatorScreens(for sourceURL: URL) async throws -> SimulatorScreens {
        if let current = contexts[sourceURL] {
            if !current.context.isStopped { return current }
            contexts.removeValue(forKey: sourceURL)
            retiredContexts.append(current.context)
        }
        // A failed cleanup must finish before another context attaches input to the same devices.
        for retired in retiredContexts where retired.xcodeURL == sourceURL {
            try await retired.invalidate()
            retiredContexts.removeAll { $0 === retired }
        }

        var configuration = SimulatorContextConfiguration()
        configuration.pasteboardSync = pasteboardSync
        configuration.deviceRegistry = model.registry
        configuration.offersLifetimeChoice = true
        configuration.onOpen = { identifier in
            HostPreferences.defaults.set(identifier.identifier, forKey: HostPreferences.currentDeviceUDID)
            HostPreferences.defaults.set(identifier.deviceSetPath, forKey: "CurrentDeviceSetPath")
        }
        configuration.onError = { [weak self] error in self?.onError?(error) }
        configuration.onHostConflictBegan = { [weak self] context, name in
            guard let self else { return }
            self.hostTakeovers.begin(context, hostName: name) {
                for other in self.contexts.values.map(\.context) + self.retiredContexts where other !== context {
                    other.checkForHostConflict()
                }
            }
        }
        configuration.onHostConflictEnded = { [weak self] context, failure in
            self?.hostTakeovers.end(context, failure: failure)
        }
        configuration.onApplicationsChange = { [weak self] device in self?.onApplicationsChange?(device.inventoryID) }
        configuration.guestLifetime = ManagedGuestLifetime(windowClosed: { [weak self] device, choice, finishing in
            guard let self else { return }
            let keepRunning = choice == .keepRunning
                || (choice == nil && HostPreferences.defaults.bool(forKey: HostPreferences.detachOnWindowClose))
            self.model.closeDevice(device.inventoryID, keepingDeviceRunning: keepRunning, after: finishing)
        }, restart: { [weak self] device, erasing in
            guard let self, let current = self.model.inventory.first(where: { $0.id == device.inventoryID }) else { return }
            self.model.manage(erasing ? .erase : .restart, devices: [current])
        }, shutDown: { [weak self] device in
            guard let self, let current = self.model.inventory.first(where: { $0.id == device.inventoryID }) else { return }
            self.model.manage(.shutdown, devices: [current])
        })
        let created = try await SimulatorContext.load(xcodeURL: sourceURL, configuration: configuration)
        let screens: SimulatorScreens
        do { screens = try await SimulatorScreens(context: created) }
        catch {
            do { try await Task { try await self.retire(created) }.value }
            catch { onError?(error) }
            throw error
        }
        if Task.isCancelled || isQuitting {
            try await Task { try await self.retire(created) }.value
            throw CancellationError()
        }
        // Two devices can finish loading the same Xcode concurrently.
        if let current = contexts[sourceURL], !current.context.isStopped {
            try await retire(created)
            return current
        }
        if let stopped = contexts.removeValue(forKey: sourceURL) { retiredContexts.append(stopped.context) }
        contexts[sourceURL] = screens
        return screens
    }


    private func retire(_ context: SimulatorContext) async throws {
        retiredContexts.append(context)
        try await context.invalidate()
        retiredContexts.removeAll { $0 === context }
    }

    /// Prepares the open screens of simulators that a management action stops or restarts. A booted simulator keeps
    /// its screen through a restart; the others release it. A failure finishes the restarts it already prepared.
    func prepareSimulatorManagement(_ action: DeviceManagementAction, devices: [InventoryDevice]) async throws {
        var prepared: [InventoryDevice] = []
        do {
            for device in devices {
                guard case .simulator(let simulator) = device, device.supports(action), entries[device.id] != nil,
                      case .simulator(let udid, let path) = device.id.destination else { continue }
                let identifier = SimulatorDeviceIdentifier(udid, deviceSetPath: path)
                guard let screens = contexts.values.first(where: { !$0.context.isStopped && $0.screen(for: identifier) != nil }) else { continue }
                switch action {
                case .restart, .erase:
                    if simulator.state == "Booted" {
                        try await screens.context.prepareForManagedRestart(identifier)
                        prepared.append(device)
                    } else {
                        try await screens.screen(for: identifier)?.close()
                    }
                case .shutdown, .forceShutdown, .remove:
                    try await screens.screen(for: identifier)?.close()
                default: break
                }
            }
        } catch {
            do { try await finishSimulatorManagement(action, devices: prepared) }
            catch let cleanupError {
                throw SimulatorError.operation([error.localizedDescription, cleanupError.localizedDescription].joined(separator: "\n"))
            }
            throw error
        }
    }

    /// Reconnects the screens that a restart or erase kept, reporting each simulator that could not reconnect.
    func finishSimulatorManagement(_ action: DeviceManagementAction, devices: [InventoryDevice]) async throws {
        guard action == .restart || action == .erase else { return }
        var failures: [String] = []
        for device in devices {
            guard case .simulator(let udid, let path) = device.id.destination else { continue }
            let identifier = SimulatorDeviceIdentifier(udid, deviceSetPath: path)
            guard let screens = contexts.values.first(where: { !$0.context.isStopped && $0.screen(for: identifier) != nil }) else { continue }
            do { try await screens.context.finishManagedRestart(identifier) }
            catch is CancellationError {}
            catch { failures.append("\(device.name): \(error.localizedDescription)") }
        }
        if !failures.isEmpty { throw SimulatorError.operation(failures.joined(separator: "\n")) }
    }

    /// The open simulator screens to reopen after relaunching, ordered so the main window's screen opens last.
    func restorations() -> [SimulatorScreenRestoration] {
        contexts.flatMap { xcode, context in
            context.openScreens.compactMap { presentation -> SimulatorScreenRestoration? in
                let device = presentation.device.id
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
        remoteDevicesObservation?.cancel()
        remoteDevicesObservation = withPortableContinuousObservation { [weak self, model] event in
            _ = model.inventory
            _ = model.status?.host
            _ = model.isRemoteInventoryComplete
            guard event.kind != .initial else { return }
            Task { @MainActor [weak self] in self?.updateRemoteScreens() }
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

    /// Stops every screen without shutting devices down: simulator contexts leave guest lifetime to the backend, and
    /// remote screens end only their connections. Screens left open by a failure resume posture observation.
    func stopAll() async throws {
        do {
            await model.stopDevicePostures()
            retiredContexts.append(contentsOf: contexts.values.map(\.context))
            contexts.removeAll()
            var failures: [String] = []
            for context in retiredContexts {
                do {
                    try await context.invalidate()
                    retiredContexts.removeAll { $0 === context }
                } catch { failures.append(error.localizedDescription) }
            }
            remove(simulatorIdentifiers)
            do { try await stopRemoteScreens() }
            catch is CancellationError {
                if failures.isEmpty { throw CancellationError() }
            } catch { failures.append(error.localizedDescription) }
            if !failures.isEmpty { throw SimulatorError.operation(failures.joined(separator: "\n")) }
        } catch {
            publishOpenScreens()
            throw error
        }
    }
}

private extension SimulatorDeviceIdentifier {
    var inventoryID: DeviceInventoryID { .simulator(udid: identifier, deviceSetPath: deviceSetPath) }
}
