import AppKit
import NeoSimulatorDeviceIO
import NeoSimulatorHostSupport
import NeoSimulatorKit
import NeoSimulatorUI
import Observation
import ObservationBridge
import NeoSimulatorManager
import NeoSimulatorCompactWindow

/// Indexes open screens by inventory identity and owns their contexts and remote connections.
/// `SimulatorScreens` owns simulator screen lifetimes; this registry owns remote lifetimes.
/// `insert(_:)` and `remove(_:)` publish the open set to posture observation.
@MainActor @Observable
package final class DeviceScreens {
    private var entries: [DeviceInventoryID: DeviceScreen] = [:]
    private var compactEntries: [DeviceInventoryID: DeviceScreen] = [:]
    private var pendingCompactWindows: [DeviceInventoryID: PendingCompactWindowController] = [:]
    private var connectingCompactWindows: [DeviceInventoryID: PendingCompactWindowController] = [:]
    private struct CompactOpening {
        let pending: PendingCompactWindowController
        let task: Task<Void, any Error>
    }
    private var compactOpenings: [DeviceInventoryID: CompactOpening] = [:]
    private struct ContextKey: Hashable {
        let xcodeURL: URL
        let compact: Bool
    }
    /// The Xcode whose SimulatorKit UI toolkit the manager loaded, which also supplies device artwork.
    package private(set) var displayXcodeURL: URL?
    @ObservationIgnored private var displayXcodeLocation: Task<Void, Never>?
    @ObservationIgnored private let model: SimulatorManagerModel
    @ObservationIgnored private let allowsDeviceHub: @Sendable (pid_t, URL?) -> Bool
    @ObservationIgnored private var contexts: [ContextKey: SimulatorScreens] = [:]
    /// Invalidated contexts remain available until their native resources have finished closing.
    @ObservationIgnored private var retiredContexts: [SimulatorContext] = []
    @ObservationIgnored private lazy var hostTakeovers = HostTakeovers<SimulatorContext>(didBegin: { [weak self] in
        self?.model.cancelPendingSimulatorOpens()
    }, report: { [weak self] error in
        self?.onError?(error)
    })
    /// Set while the app quits, until a cancelled quit resumes.
    @ObservationIgnored package private(set) var isQuitting = false
    @ObservationIgnored private var locationObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var remoteDevicesObservation: PortableObservationTracking.Token?
    @ObservationIgnored private var lastRemoteHost: SimulatorHost?
    @ObservationIgnored private var remoteHostCleanup: Task<Void, Never>?
    @ObservationIgnored package var onError: ((any Error) -> Void)?
    @ObservationIgnored package var onShowInMainWindow: ((DeviceInventoryID) -> Void)?
    @ObservationIgnored package var onCompactWindowClosed: ((DeviceInventoryID) -> Void)?
    @ObservationIgnored package var makeCompactPreview: ((InventoryDevice) -> NSViewController)?
    @ObservationIgnored package var makeCompactDeviceMenu: ((InventoryDevice, NSWindow) -> NSMenu)?
    /// Edit ▸ Automatically Sync Pasteboard for every simulator screen, whichever host presents it.
    @ObservationIgnored package private(set) lazy var pasteboardSync = PasteboardSync { [weak self] in
        self?.simulatorControllers.map(\.session) ?? []
    }

    package init(
        model: SimulatorManagerModel, allowsDeviceHub: @escaping @Sendable (pid_t, URL?) -> Bool = { _, _ in false }
    ) {
        self.model = model
        self.allowsDeviceHub = allowsDeviceHub
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

    package var identifiers: Set<DeviceInventoryID> { Set(entries.keys).union(compactEntries.keys) }

    private var allScreens: [DeviceScreen] { Array(entries.values) + Array(compactEntries.values) }
    package func compactScreen(for identifier: DeviceInventoryID) -> DeviceScreen? { compactEntries[identifier] }

    package func compactWindow(for identifier: DeviceInventoryID) -> NSWindow? {
        if let screen = compactEntries[identifier] {
            return switch screen.controller {
            case .simulator(let controller): controller.window
            case .remote(let controller): controller.window
            }
        }
        return pendingCompactWindows[identifier]?.preparedWindow
    }

    package func prepareCompactWindow(for device: InventoryDevice) {
        if let window = compactWindow(for: device.id) {
            window.makeKeyAndOrderFront(nil)
        } else {
            pendingCompactWindow(for: device).preparedWindow.makeKeyAndOrderFront(nil)
        }
    }

    private func pendingCompactWindow(for device: InventoryDevice) -> PendingCompactWindowController {
        if let pending = pendingCompactWindows[device.id] { return pending }
        let pending = PendingCompactWindowController(
            device: device, preview: makeCompactPreview?(device),
            showMain: { [weak self] in
                self?.showInMainWindow(device.id, closingCompact: true)
            }, deviceMenu: { [weak self] window in self?.makeCompactDeviceMenu?(device, window) ?? NSMenu() })
        pending.onClose = { [weak self, weak pending] in
            guard let self, let pending, self.pendingCompactWindows[device.id] === pending else { return }
            if self.compactOpenings[device.id]?.pending === pending { self.compactOpenings[device.id]?.task.cancel() }
            self.pendingCompactWindows.removeValue(forKey: device.id)
            self.onCompactWindowClosed?(device.id)
        }
        pendingCompactWindows[device.id] = pending
        return pending
    }

    package func showCompactWindowFailure(_ error: any Error, for identifier: DeviceInventoryID) {
        pendingCompactWindows[identifier]?.showFailure(error)
    }

    private func showInMainWindow(_ identifier: DeviceInventoryID, closingCompact: Bool) {
        onShowInMainWindow?(identifier)
        if closingCompact {
            Task { [weak self] in
                do { try await self?.closeCompactScreen(for: identifier) } catch { self?.onError?(error) }
            }
        }
    }

    package func closeCompactScreen(for identifier: DeviceInventoryID) async throws {
        if let compact = compactEntries[identifier] {
            switch compact.controller {
            case .simulator(let controller):
                let device = controller.session.device.identity
                for context in contexts.values where context.screen(for: device)?.controller === controller {
                    try await context.context.releaseSession(device)
                }
            case .remote(let controller): try await controller.stopAndClose()
            }
        } else {
            pendingCompactWindows[identifier]?.preparedWindow.close()
        }
    }

    package func contains(_ screen: DeviceScreen) -> Bool {
        entries[screen.id] === screen || compactEntries[screen.id] === screen
    }

    package func screen(for identifier: DeviceInventoryID) -> DeviceScreen? { entries[identifier] }

    /// CoreDevice identifiers of open native canvases. Evaluating DeviceKit activity for
    /// other devices can start their native HID services and interfere with SimulatorKit input.
    package var nativeCanvasDeviceIdentifiers: Set<UUID> {
        Set(
            allScreens.filter(\.usesNativeCanvas).compactMap { screen in
            guard case .simulator(let simulator) = model.inventory.first(where: { $0.id == screen.id }) else { return nil }
            return simulator.coreDevice.flatMap { UUID(uuidString: $0.identifier) }
        })
    }

    // MARK: Registration

    @discardableResult
    private func attach(_ presentation: SimulatorScreen, as identifier: DeviceInventoryID, compact: Bool = false) throws
        -> DeviceScreen
    {
        guard !presentation.isClosed else { throw CancellationError() }
        let controller = presentation.controller
        let screen = attach(controller, as: identifier, compact: compact)
        presentation.onEnd = { [weak self, weak controller] _ in
            guard let self, let controller,
                case .simulator(let current) = (compact ? self.compactEntries[identifier] : self.entries[identifier])?
                    .controller,
                  current === controller else { return }
            self.remove([identifier], compact: compact)
        }
        return screen
    }

    /// Registers a simulator presentation's controller, or returns its existing screen.
    @discardableResult
    package func attach(_ controller: DeviceWindowController, as identifier: DeviceInventoryID, compact: Bool = false)
        -> DeviceScreen
    {
        if let screen = compact ? compactEntries[identifier] : entries[identifier],
            case .simulator(let current) = screen.controller, current === controller
        {
            return screen
        }
        let screen = DeviceScreen(id: identifier, controller: .simulator(controller), model: model, screens: self)
        controller.onShowInMainWindow = { [weak self] in self?.showInMainWindow(identifier, closingCompact: compact) }
        insert(screen, compact: compact)
        return screen
    }

    /// Registers a remote screen until its controller closes.
    @discardableResult
    package func attach(_ controller: RemoteDeviceWindowController, compact: Bool = false) -> DeviceScreen {
        let identifier = DeviceInventoryID.coreDevice(controller.device.identifier)
        let screen = DeviceScreen(id: identifier, controller: .remote(controller), model: model, screens: self)
        controller.onClose = { [weak self, weak screen] in
            guard let self, let screen, self.contains(screen) else { return }
            self.remove([identifier], compact: compact)
        }
        controller.onShowInMainWindow = { [weak self] in self?.showInMainWindow(identifier, closingCompact: compact) }
        controller.onConnect = { [weak self, weak screen] in
            guard let self, let screen, self.contains(screen) else { return }
            await self.model.deviceScreenDidConnect(identifier)
        }
        controller.canInstallApplications = { [weak self] in self?.model.canInstallApplications(on: identifier) == true }
        controller.installApplications = { [weak self] urls in
            self?.model.installApplications(at: urls, on: identifier)
        }
        insert(screen, compact: compact)
        return screen
    }

    private func insert(_ screen: DeviceScreen, compact: Bool) {
        if compact {
            compactEntries.updateValue(screen, forKey: screen.id)?.stopObserving()
        } else {
            entries.updateValue(screen, forKey: screen.id)?.stopObserving()
        }
        screen.startObserving()
        publishOpenScreens()
    }

    private func remove(_ identifiers: [DeviceInventoryID], compact: Bool = false) {
        let removed = identifiers.compactMap {
            compact ? compactEntries.removeValue(forKey: $0) : entries.removeValue(forKey: $0)
        }
        guard !removed.isEmpty else { return }
        for screen in removed { screen.stopObserving() }
        publishOpenScreens()
        if compact {
            for identifier in identifiers {
                if let pending = pendingCompactWindows[identifier],
                    !removed.contains(where: { screen in
                        guard screen.id == identifier else { return false }
                        return switch screen.controller {
                        case .simulator(let controller): controller.window === pending.preparedWindow
                        case .remote(let controller): controller.window === pending.preparedWindow
                        }
                    })
                {
                    continue
                }
                pendingCompactWindows.removeValue(forKey: identifier)
                onCompactWindowClosed?(identifier)
            }
        }
    }

    private func publishOpenScreens() {
        model.setOpenDeviceScreens(isQuitting ? [] : identifiers)
    }

    private var simulatorIdentifiers: [DeviceInventoryID] {
        allScreens.compactMap { screen in
            if case .simulator = screen.controller { screen.id } else { nil }
        }
    }

    private var simulatorControllers: [DeviceWindowController] {
        allScreens.compactMap { screen in
            if case .simulator(let controller) = screen.controller { controller } else { nil }
        }
    }

    private var remoteControllers: [RemoteDeviceWindowController] {
        allScreens.compactMap { screen in
            if case .remote(let controller) = screen.controller { controller } else { nil }
        }
    }

    // MARK: Simulator screens

    /// Opens a screen in its Xcode context, releasing any previous context's presentation first.
    /// The backend serializes requests for the same device through cancellation cleanup.
    package func openSimulatorScreen(_ request: SimulatorPresentationContext,
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
        for (key, previous) in contexts where key.xcodeURL != sourceURL {
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

    private func simulatorScreens(for sourceURL: URL, compact: Bool = false) async throws -> SimulatorScreens {
        let key = ContextKey(xcodeURL: sourceURL, compact: compact)
        if let current = contexts[key] {
            if !current.context.isStopped { return current }
            contexts.removeValue(forKey: key)
            retiredContexts.append(current.context)
        }
        // A failed cleanup must finish before another context attaches input to the same devices.
        for retired in retiredContexts where retired.xcodeURL == sourceURL {
            try await invalidate(retired)
            retiredContexts.removeAll { $0 === retired }
        }

        var configuration = SimulatorContextConfiguration()
        configuration.pasteboardSync = pasteboardSync
        configuration.deviceRegistry = model.registry
        configuration.offersLifetimeChoice = !compact
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
        configuration.guestLifetime = ManagedGuestLifetime(windowClosed: { [weak self] device, choice, finishing in
            guard let self else { return }
                if compact {
                    Task {
                        do { try await finishing.value } catch { self.onError?(error) }
                    }
                    return
                }
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
        do {
            screens = try await SimulatorScreens(
                context: created,
                allowsDeviceHub: allowsDeviceHub,
                makeWindow: { [weak self] device in
                    compact ? self?.connectingCompactWindows[device.identity.inventoryID]?.takeWindow() : nil
                })
        }
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
        if let current = contexts[key], !current.context.isStopped {
            try await retire(created)
            return current
        }
        if let stopped = contexts.removeValue(forKey: key) { retiredContexts.append(stopped.context) }
        contexts[key] = screens
        return screens
    }


    /// Reports unsaved capture locations, then acknowledges them so subsequent cleanup can proceed.
    private func invalidate(_ context: SimulatorContext) async throws {
        do { try await context.invalidate() }
        catch {
            context.acknowledgeCaptureFailures()
            throw error
        }
    }

    private func retire(_ context: SimulatorContext) async throws {
        retiredContexts.append(context)
        try await invalidate(context)
        retiredContexts.removeAll { $0 === context }
    }

    /// Prepares screens before stopping or restarting simulators, retaining booted screens for
    /// restart. On failure, finishes already-prepared restarts.
    package func prepareSimulatorManagement(_ action: DeviceManagementAction, devices: [InventoryDevice]) async throws {
        var prepared: [InventoryDevice] = []
        do {
            for device in devices {
                guard case .simulator(let simulator) = device, device.supports(action), entries[device.id] != nil,
                      case .simulator(let udid, let path) = device.id.destination else { continue }
                let identifier = SimulatorDeviceIdentifier(udid, deviceSetPath: path)
                let presentations = contexts.values.filter {
                    !$0.context.isStopped && $0.screen(for: identifier) != nil
                }
                if action == .restart || action == .erase, !presentations.isEmpty { prepared.append(device) }
                for screens in presentations {
                switch action {
                case .restart, .erase:
                    if simulator.state == "Booted" {
                        try await screens.context.prepareForManagedRestart(identifier)
                    } else {
                        try await screens.screen(for: identifier)?.close()
                    }
                case .shutdown, .forceShutdown, .remove:
                    try await screens.screen(for: identifier)?.close()
                default: break
                }
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
    package func finishSimulatorManagement(_ action: DeviceManagementAction, devices: [InventoryDevice]) async throws {
        guard action == .restart || action == .erase else { return }
        var failures: [String] = []
        for device in devices {
            guard case .simulator(let udid, let path) = device.id.destination else { continue }
            let identifier = SimulatorDeviceIdentifier(udid, deviceSetPath: path)
            for screens in contexts.values where !screens.context.isStopped && screens.screen(for: identifier) != nil {
                do { try await screens.context.finishManagedRestart(identifier) } catch is CancellationError {} catch {
                    failures.append("\(device.name): \(error.localizedDescription)")
                }
            }
        }
        if !failures.isEmpty { throw SimulatorError.operation(failures.joined(separator: "\n")) }
    }

    /// The open simulator screens to reopen after relaunching, ordered so the main window's screen opens last.
    package func restorations() -> [SimulatorScreenRestoration] {
        contexts.filter { !$0.key.compact }.flatMap { key, context in
            context.openScreens.compactMap { presentation -> SimulatorScreenRestoration? in
                let device = presentation.device.id
                guard let screen = entries[device.inventoryID] else { return nil }
                return SimulatorScreenRestoration(
                    device: device, xcodeURL: key.xcodeURL, presentation: screen.presentation)
            }
        }.sorted { $0.presentation.restorationOrder < $1.presentation.restorationOrder }
    }

    package func setDeviceBezelsVisible(_ visible: Bool) {
        for controller in simulatorControllers { controller.setDeviceBezelVisible(visible) }
    }

    /// Opens a second interactive presentation in the window already shown for this request.
    package func showCompactWindow(for identifier: DeviceInventoryID, while isCurrent: @escaping @MainActor () -> Bool)
        async throws
    {
        guard !isQuitting, isCurrent(), let main = entries[identifier] else { return }
        if let compact = compactEntries[identifier] {
            try await compact.showCompactWindow()
            return
        }
        let device: InventoryDevice =
            switch main.controller {
            case .simulator(let controller):
                .simulator(SimulatorHostDevice(presenting: controller.session.device, ownerXcodeURL: nil))
            case .remote(let controller): .remote(controller.device)
            }
        let pending = pendingCompactWindow(for: device)
        pending.showLoading()
        pending.preparedWindow.makeKeyAndOrderFront(nil)
        let task: Task<Void, any Error>
        if let opening = compactOpenings[identifier], opening.pending === pending {
            task = opening.task
        } else {
            let previous = compactOpenings[identifier]?.task
            task = Task { [self] in
                _ = await previous?.result
                try Task.checkCancellation()
                guard pendingCompactWindows[identifier] === pending, isCurrent() else { return }
                try await connectCompactWindow(for: main, in: pending, while: isCurrent)
            }
            compactOpenings[identifier] = CompactOpening(pending: pending, task: task)
        }
        defer {
            if compactOpenings[identifier]?.pending === pending { compactOpenings.removeValue(forKey: identifier) }
        }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func connectCompactWindow(
        for main: DeviceScreen, in pending: PendingCompactWindowController,
        while isCurrent: @escaping @MainActor () -> Bool
    ) async throws {
        let identifier = main.id
        do {
            let compact: DeviceScreen
            switch main.controller {
            case .simulator(let controller):
                let device = controller.session.device.identity
                guard
                    let key = contexts.first(where: {
                        !$0.key.compact && $0.value.screen(for: device)?.controller === controller
                    })?.key
                else { throw SimulatorError.operation("The simulator's presentation context is unavailable.") }
                let presenter = try await simulatorScreens(for: key.xcodeURL, compact: true)
                guard pendingCompactWindows[identifier] === pending, isCurrent() else { return }
                connectingCompactWindows[identifier] = pending
                defer { connectingCompactWindows.removeValue(forKey: identifier) }
                do {
                    let presentation = try await presenter.open(device)
                    try Task.checkCancellation()
                    compact = try attach(presentation, as: identifier, compact: true)
                } catch {
                    do { try await presenter.context.releaseSession(device) } catch let cleanupError {
                        throw SimulatorError.operation(
                            "\(error.localizedDescription) Closing the compact screen also failed: \(cleanupError.localizedDescription)"
                        )
                    }
                    throw error
                }
            case .remote(let controller):
                let additional = controller.makeAdditionalWindow(in: pending.takeWindow())
                compact = attach(additional, compact: true)
                additional.connectIfNeeded()
            }
            guard !isQuitting, isCurrent(), entries[identifier] === main, pendingCompactWindows[identifier] === pending
            else {
                try await closeCompactScreen(for: identifier)
                return
            }
            try await compact.showCompactWindow()
            pendingCompactWindows.removeValue(forKey: identifier)
        } catch {
            if pendingCompactWindows[identifier] === pending { pending.showFailure(error) }
            throw error
        }
    }

    // MARK: Remote screens

    /// Opens or reconnects the device's remote screen unless the device is being managed or the app is quitting.
    package func openRemoteScreen(for device: CoreDeviceDevice) -> DeviceScreen? {
        let identifier = DeviceInventoryID.coreDevice(device.identifier)
        guard !isQuitting, !model.managingDeviceIDs.contains(identifier) else { return nil }
        let screen = entries[identifier] ?? attach(RemoteDeviceWindowController(device: device))
        if case .remote(let controller) = screen.controller { controller.connectIfNeeded() }
        locateDisplayXcode()
        return screen
    }

    /// A remote screen's controls draw their artwork from the same Xcode as a simulator screen's, which only
    /// opening a simulator screen locates. Without it the controls show their titles.
    private func locateDisplayXcode() {
        guard displayXcodeURL == nil, displayXcodeLocation == nil else { return }
        displayXcodeLocation = Task { [weak self] in
            let url = try? await CoreDeviceRuntime.uiXcodeURL()
            guard let self else { return }
            self.displayXcodeLocation = nil
            if let url, self.displayXcodeURL == nil { self.displayXcodeURL = url }
        }
    }

    /// Follows the inventory and the selected host, which can make remote screens unavailable.
    package func observeRemoteDevices() {
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
            for controller in remoteControllers {
                controller.updateInventory(model.inventory.first { $0.id == .coreDevice(controller.device.identifier) })
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
    package func waitForRemoteHostCleanup() async {
        await remoteHostCleanup?.value
    }

    /// Stops and closes remote screens, all of them by default. One screen's failure does not keep the others open;
    /// a cancellation leaves the remaining screens open.
    package func stopRemoteScreens(for identifiers: Set<DeviceInventoryID>? = nil) async throws {
        var failures: [String] = []
        let targets = remoteControllers.filter { identifiers?.contains(.coreDevice($0.device.identifier)) ?? true }
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
    package func beginQuitting() { isQuitting = true }

    package func resumeAfterCancelledQuit() {
        isQuitting = false
        publishOpenScreens()
    }

    /// Disconnects all screens without stopping guests. Screens still open after a failure
    /// resume posture observation.
    package func stopAll() async throws {
        do {
            let pending = Array(pendingCompactWindows.values)
            pendingCompactWindows.removeAll()
            let opening = Array(compactOpenings.values)
            for request in opening { request.task.cancel() }
            connectingCompactWindows.removeAll()
            for window in pending { window.preparedWindow.close() }
            for request in opening { _ = await request.task.result }
            compactOpenings.removeAll()
            await model.stopDevicePostures()
            retiredContexts.append(contentsOf: contexts.values.map(\.context))
            contexts.removeAll()
            var failures: [String] = []
            for context in retiredContexts {
                do {
                    try await invalidate(context)
                    retiredContexts.removeAll { $0 === context }
                } catch { failures.append(error.localizedDescription) }
            }
            let simulatorIDs = simulatorIdentifiers
            remove(simulatorIDs)
            remove(simulatorIDs, compact: true)
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

@MainActor
private final class PendingCompactWindowController: NSWindowController, NSToolbarDelegate, NSMenuDelegate {
    let preparedWindow: DeviceWindow
    var onClose: (() -> Void)?
    private let progress = NSProgressIndicator()
    private let loadingView = NSView()
    private let previewRoot = NSViewController()
    private let status = NSTextField(wrappingLabelWithString: "")
    private var closeObservation: (any NSObjectProtocol)?
    private let showMain: () -> Void
    private let deviceMenu: (NSWindow) -> NSMenu
    init(
        device: InventoryDevice, preview: NSViewController?, showMain: @escaping () -> Void,
        deviceMenu: @escaping (NSWindow) -> NSMenu
    ) {
        self.showMain = showMain
        self.deviceMenu = deviceMenu
        let size: NSSize =
            switch device.family {
            case "iPad": NSSize(width: 460, height: 620)
            case "Apple TV", "Apple Vision", "Mac": NSSize(width: 620, height: 460)
            case "Apple Watch": NSSize(width: 300, height: 400)
            default: NSSize(width: 300, height: 620)
            }
        preparedWindow = DeviceWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered,
            defer: false)
        super.init(window: preparedWindow)
        preparedWindow.title = device.name
        preparedWindow.titleVisibility = .hidden
        preparedWindow.appearance = NSAppearance(named: .darkAqua)
        preparedWindow.isReleasedWhenClosed = false
        preparedWindow.tabbingMode = .disallowed
        preparedWindow.toolbarStyle = .unified
        preparedWindow.titlebarSeparatorStyle = .none
        let toolbar = NSToolbar(identifier: "CompactDevicePreview.\(UUID().uuidString)")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        preparedWindow.toolbar = toolbar
        closeObservation = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: preparedWindow, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onClose?() }
        }
        let preview = preview ?? NSViewController()
        previewRoot.addChild(preview)
        status.alignment = .center
        status.textColor = .secondaryLabelColor
        status.isHidden = true
        let stack = NSStackView(views: [preview.view, status])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.translatesAutoresizingMaskIntoConstraints = false
        previewRoot.view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: previewRoot.view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: previewRoot.view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: previewRoot.view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: previewRoot.view.bottomAnchor),
        ])
        progress.style = .spinning
        progress.translatesAutoresizingMaskIntoConstraints = false
        loadingView.addSubview(progress)
        NSLayoutConstraint.activate([
            progress.centerXAnchor.constraint(equalTo: loadingView.centerXAnchor),
            progress.centerYAnchor.constraint(equalTo: loadingView.centerYAnchor),
        ])
        preparedWindow.contentViewController = previewRoot
        preparedWindow.setContentSize(size)
        preparedWindow.center()
    }

    required init?(coder: NSCoder) { nil }

    isolated deinit {
        if let closeObservation { NotificationCenter.default.removeObserver(closeObservation) }
    }

    func takeWindow() -> DeviceWindow {
        window = nil
        return preparedWindow
    }

    func showFailure(_ error: any Error) {
        progress.stopAnimation(nil)
        status.stringValue = error.localizedDescription
        status.isHidden = false
        preparedWindow.contentViewController = previewRoot
    }

    func showLoading() {
        status.isHidden = true
        preparedWindow.contentViewController = nil
        preparedWindow.contentView = loadingView
        progress.startAnimation(nil)
    }

    @objc private func returnToMain(_ sender: Any?) { showMain() }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, NSToolbarItem.Identifier("ShowInMainWindow"), NSToolbarItem.Identifier("DeviceActions")]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar: Bool
    ) -> NSToolbarItem? {
        if identifier.rawValue == "ShowInMainWindow" {
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "Show in Main Window"
            item.image = NSImage(
                systemSymbolName: "arrow.down.backward.and.arrow.up.forward", accessibilityDescription: item.label)
            item.target = self
            item.action = #selector(returnToMain(_:))
            return item
        }
        guard identifier.rawValue == "DeviceActions" else { return nil }
        let item = NSMenuToolbarItem(itemIdentifier: identifier)
        item.label = "More Actions"
        item.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: item.label)
        item.showsIndicator = false
        item.menu = NSMenu(title: "Device Actions")
        item.menu.autoenablesItems = false
        item.menu.delegate = self
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(NSMenuItem(title: "", action: nil, keyEquivalent: ""))
        let source = deviceMenu(preparedWindow)
        for item in source.items {
            source.removeItem(item)
            menu.addItem(item)
        }
    }
}
