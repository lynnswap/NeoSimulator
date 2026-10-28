import AppKit
import Observation
@_spi(NeoSimulator) import XcodeSimulatorHost

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let rendererURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Applications/NeoSimulatorRenderer.app")
    private lazy var model = SimulatorManagerModel(rendererApplicationURL: rendererURL, presentSimulator: { [weak self] context in
        try await self?.openSimulatorPresentation(context)
    })
    private var mainWindow: ManagerWindowController?
    private var settingsWindow: SettingsWindowController?
    private var newSimulatorWindows: [DeviceInventoryID?: NewSimulatorWindowController] = [:]
    private var preparingNewSimulators: Set<DeviceInventoryID?> = []
    private var quitting = false
    private var rendererDevicesObserver: NSObjectProtocol?
    private var workspaceObserver: NSObjectProtocol?
    private var connectionTimer: Timer?
    private var inventoryObservation: DeviceInventoryObservation?
    private var inventoryObservationTask: Task<Void, Never>?
    private var quitKeepingDevicesRunning: Bool?
    private var restartsAfterQuitting = false
    private var remoteWindows: [DeviceInventoryID: RemoteDeviceWindowController] = [:] {
        didSet { updateDevicePostureScreens(); mainWindow?.reloadDeviceArtwork() }
    }
    private var simulatorHosts: [URL: HostApplication] = [:]
    private var simulatorWindows: [DeviceInventoryID: DeviceWindowController] = [:] {
        didSet { updateDevicePostureScreens(); mainWindow?.reloadDeviceArtwork() }
    }
    private func updateDevicePostureScreens() {
        model.setOpenDeviceScreens(quitting ? [] : Set(simulatorWindows.keys).union(remoteWindows.keys))
    }
    private var displayXcodeURL: URL?
    private var presentationTask: Task<Void, any Error>?
    private var presentationGeneration = 0
    private var remoteHostCleanup: Task<Void, Never>?
    private var lastRemoteHost: SimulatorHost?
    private lazy var pasteboardSync = PasteboardSync { [weak self] in
        self?.simulatorWindows.values.map(\.session) ?? []
    }
    private lazy var simulatorMenus = MenuController(application: nil,
        gpuPolicy: UserDefaults(suiteName: GPUPolicy.suiteName).map(GPUPolicy.init), pasteboardSync: pasteboardSync)

    @MainActor private enum Screen {
        case simulator(DeviceWindowController)
        case remote(RemoteDeviceWindowController)

        var commandTarget: NSResponder {
            switch self {
            case .simulator(let controller): controller
            case .remote(let controller): controller
            }
        }

        var canControlDevice: Bool {
            switch self {
            case .simulator(let controller): controller.session.canPerformCommands
            case .remote(let controller): controller.session.state == .connected
            }
        }

        var canvasControls: DeviceCanvasControls? {
            switch self {
            case .simulator(let controller): controller.canvasControls
            case .remote(let controller): controller.canvasControls
            }
        }

        var nativePoseControls: NativeDevicePoseControls? {
            switch self {
            case .simulator(let controller): controller.session.display.nativePoseControls
            case .remote: nil
            }
        }

        func validatePresentationMove() throws {
            let canMove: Bool
            switch self {
            case .simulator(let controller): canMove = controller.canMovePresentation
            case .remote(let controller): canMove = controller.canMovePresentation
            }
            guard canMove else {
                throw HostError.operation("Close the device's dialog or leave full screen before moving its screen.")
            }
        }

        func preparePresentationMove() async throws {
            switch self {
            case .simulator: try validatePresentationMove()
            case .remote(let controller): try await controller.preparePresentationMove()
            }
        }

        private func simulatorCommand(_ identifier: String, for controller: DeviceWindowController) -> DeviceCommand.ID? {
            switch identifier {
            case "home": .home
            case "lock": .lock
            case "rotate": DeviceCommand.canvasRotation(modifierFlags: NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags)
            case "resizeApp": .resizeApp
            case "capture": .saveScreen
            case "record": controller.session.recording == nil ? .recordScreen : .stopRecording
            case "captureKeyboard": .captureKeyboard
            default: nil
            }
        }

        func supports(_ identifier: String) -> Bool {
            if CanvasZoom.Action(rawValue: identifier) != nil {
                if case .simulator = self { return true }
                return false
            }
            switch self {
            case .simulator(let controller):
                guard let id = simulatorCommand(identifier, for: controller) else { return false }
                return id == .resizeApp ? controller.session.supportsAppResize : DeviceCommand.command(id).isSupported(controller.session.capabilities)
            case .remote: return identifier != "rotate" && identifier != "resizeApp"
            }
        }

        func isEnabled(_ identifier: String) -> Bool {
            if let action = CanvasZoom.Action(rawValue: identifier), case .simulator(let controller) = self {
                return controller.canPerformCanvasZoom(action)
            }
            switch self {
            case .simulator(let controller):
                guard let id = simulatorCommand(identifier, for: controller) else { return false }
                return DeviceCommand.command(id).isEnabled(controller)
            case .remote(let controller): return controller.isScreenActionEnabled(identifier)
            }
        }

        func perform(_ identifier: String) {
            if let action = CanvasZoom.Action(rawValue: identifier), case .simulator(let controller) = self {
                controller.performCanvasZoom(action)
                return
            }
            switch self {
            case .simulator(let controller):
                if let id = simulatorCommand(identifier, for: controller) { controller.perform(id) }
            case .remote(let controller): controller.performScreenAction(identifier)
            }
        }

        var resizingApp: Bool {
            if case .simulator(let controller) = self { return controller.session.isResizingApp || controller.session.isStartingAppResize }
            return false
    }

        func canvasZoomIsSelected(_ identifier: String) -> Bool {
            guard let action = CanvasZoom.Action(rawValue: identifier), case .simulator(let controller) = self else { return false }
            return controller.canvasZoomIsSelected(action)
        }

        var recordingTitle: String {
            switch self {
            case .simulator(let controller): controller.session.recording == nil ? "Record Screen" : "Stop Recording"
            case .remote(let controller): controller.screenActionPresentation("record")?.title ?? "Record Screen"
            }
        }

        var recordingStartDate: Date? {
            switch self {
            case .simulator(let controller): controller.session.recording?.startDate
            case .remote(let controller): controller.session.recordingStartDate
            }
        }

        var capturesKeyboard: Bool {
            switch self {
            case .simulator(let controller): controller.capturesKeyboard
            case .remote(let controller): controller.capturesKeyboard
            }
        }

        func embed(in parent: NSViewController) async throws {
            switch self {
            case .simulator(let controller): try await controller.embed(in: parent)
            case .remote(let controller): try await controller.embed(in: parent)
            }
        }
        func showCompactWindow() async throws {
            switch self {
            case .simulator(let controller): try await controller.showCompactWindow()
            case .remote(let controller): try await controller.showCompactWindow()
            }
        }
        func detach() async throws {
            switch self {
            case .simulator(let controller): try await controller.detachPresentation()
            case .remote(let controller): try await controller.detachPresentation()
            }
        }
    }

    private func screen(for identifier: DeviceInventoryID) -> Screen? {
        if let controller = simulatorWindows[identifier] { return .simulator(controller) }
        if let controller = remoteWindows[identifier] { return .remote(controller) }
        return nil
    }

    private func transitionPresentation(_ operation: @escaping @MainActor () async throws -> Void) async throws {
        let previous = presentationTask
        presentationGeneration += 1
        let generation = presentationGeneration
        let task = Task { @MainActor in
            _ = await previous?.result
            try Task.checkCancellation()
            try await operation()
        }
        presentationTask = task
        defer { if presentationGeneration == generation { presentationTask = nil } }
        try await task.value
    }

    private func showScreenInMainWindow(_ identifier: DeviceInventoryID) {
        Task { [weak self] in
            guard let self else { return }
            do { try await self.embedScreen(identifier, selectDevice: true) }
            catch is CancellationError {}
            catch { self.present(error) }
        }
    }

    private func embedScreen(_ identifier: DeviceInventoryID, selectDevice: Bool) async throws {
        try await transitionPresentation { [self] in
            guard !quitting, let screen = screen(for: identifier) else { return }
            prepareMainWindow()
            guard let mainWindow else { return }
            if mainWindow.liveDeviceIdentifier == identifier {
                if selectDevice { mainWindow.selectDevice(identifier) }
                mainWindow.showWindow(nil)
                mainWindow.window?.makeKeyAndOrderFront(nil)
                return
            }
            try await screen.preparePresentationMove()
            let previousResponder = selectDevice ? nil : mainWindow.window?.firstResponder
            let previous = mainWindow.liveDeviceIdentifier.flatMap { self.screen(for: $0) }
            try await previous?.preparePresentationMove()
            try screen.validatePresentationMove()
            try previous?.validatePresentationMove()
            try await previous?.detach()
            do { try await screen.embed(in: mainWindow.liveScreenContainer) }
            catch {
                if let previous {
                    do { try await previous.embed(in: mainWindow.liveScreenContainer) }
                    catch let restorationError {
                        if let current = mainWindow.liveDeviceIdentifier {
                            mainWindow.showDevicePreview(ifDisplaying: current)
                        }
                        throw HostError.operation([error.localizedDescription,
                            "Could not restore the previous device screen: \(restorationError.localizedDescription)"].joined(separator: "\n"))
                    }
                }
                if let previousResponder { mainWindow.window?.makeFirstResponder(previousResponder) }
                throw error
            }
            if selectDevice { mainWindow.selectDevice(identifier) }
            mainWindow.activeScreenCommandTarget = screen.commandTarget
            mainWindow.showLiveScreen(for: identifier)
            updateScreenToolbar()
            mainWindow.showWindow(nil)
            mainWindow.window?.makeKeyAndOrderFront(nil)
            if let previousResponder { mainWindow.window?.makeFirstResponder(previousResponder) }
        }
    }

    private func showCompactScreen(_ identifier: DeviceInventoryID) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.transitionPresentation {
                    guard !self.quitting, let screen = self.screen(for: identifier) else { return }
                    try await screen.preparePresentationMove()
                    try await screen.showCompactWindow()
                    self.mainWindow?.showDevicePreview(ifDisplaying: identifier)
                    self.mainWindow?.window?.orderOut(nil)
                }
            } catch is CancellationError {}
            catch { self.present(error) }
        }
    }

    private func selectedDeviceChanged(_ identifier: DeviceInventoryID?) {
        Task { [weak self] in
            guard let self else { return }
            do {
                if let identifier, self.screen(for: identifier) != nil {
                    try await self.embedScreen(identifier, selectDevice: false)
                } else {
                    try await self.transitionPresentation {
                        if let current = self.mainWindow?.liveDeviceIdentifier {
                            if let screen = self.screen(for: current) {
                                try await screen.preparePresentationMove()
                                try await screen.detach()
                            }
                            self.mainWindow?.showDevicePreview(ifDisplaying: current)
                        }
                    }
                }
            } catch is CancellationError {}
            catch { self.present(error) }
        }
    }

    private func openSimulatorPresentation(_ context: SimulatorPresentationContext) async throws {
        guard !quitting else { throw CancellationError() }
        let displayURL = try await CoreDeviceRuntime.uiXcodeURL()
        displayXcodeURL = displayURL
        let sourceURL = context.xcodeURL.standardizedFileURL.resolvingSymlinksInPath()
        let host: HostApplication
        if let existing = simulatorHosts[sourceURL] { host = existing }
        else {
            let runtime = try await SimulatorRuntime.load(xcodeURL: sourceURL, uiXcodeURL: displayURL)
            host = try HostApplication(runtime: runtime, conflicts: HostConflictMonitor(), inProcess: true, pasteboardSync: pasteboardSync)
            host.onError = { [weak self] error in self?.present(error) }
            host.onChange = { [weak self] in self?.simulatorPresentationsChanged() }
            host.onClose = { [weak self] identifier, choice, finishing in
                guard let self else { return }
                let id = DeviceInventoryID.simulator(udid: identifier.identifier, deviceSetPath: identifier.deviceSetPath)
                self.simulatorWindows.removeValue(forKey: id)
                self.mainWindow?.showDevicePreview(ifDisplaying: id)
                let keepRunning = choice == .keepRunning || (choice == nil && HostPreferences.defaults.bool(forKey: HostPreferences.detachOnWindowClose))
                self.model.closeDevice(id, keepingDeviceRunning: keepRunning, after: finishing)
            }
            host.onRestart = { [weak self] identifier, erasing in
                guard let self, let device = self.model.inventory.first(where: {
                    $0.id == .simulator(udid: identifier.identifier, deviceSetPath: identifier.deviceSetPath)
                }) else { return }
                self.model.manage(erasing ? .erase : .restart, devices: [device])
            }
            host.onShutDown = { [weak self] identifier in
                guard let self, let device = self.model.inventory.first(where: {
                    $0.id == .simulator(udid: identifier.identifier, deviceSetPath: identifier.deviceSetPath)
                }) else { return }
                self.model.manage(.shutdown, devices: [device])
            }
            try host.start()
            simulatorHosts[sourceURL] = host
        }
        guard case .simulator(let udid, let path) = context.deviceID else { return }
        let identifier = SimulatorDeviceIdentifier(udid, deviceSetPath: path)
        for (url, previous) in simulatorHosts where url != sourceURL && previous.openedDeviceIdentifiers.contains(identifier) {
            try await previous.releasePresentation(for: identifier)
            simulatorWindows.removeValue(forKey: context.deviceID)
            mainWindow?.showDevicePreview(ifDisplaying: context.deviceID)
        }
        let controller = try await host.openPresentation(for: identifier, bootIfNeeded: false)
        controller.onShowInMainWindow = { [weak self] in self?.showScreenInMainWindow(context.deviceID) }
        let isNew = simulatorWindows[context.deviceID] !== controller
        simulatorWindows[context.deviceID] = controller
        if isNew {
            configureCanvasControls(for: context.deviceID, screen: .simulator(controller))
            observeScreenState(context.deviceID)
        }
        try await embedScreen(context.deviceID, selectDevice: true)
    }

    private func simulatorPresentationsChanged() {
        for (url, host) in simulatorHosts where host.isStopped { simulatorHosts.removeValue(forKey: url) }
        let opened = Set(simulatorHosts.values.flatMap(\.openedDeviceIdentifiers).map {
            DeviceInventoryID.simulator(udid: $0.identifier, deviceSetPath: $0.deviceSetPath)
        })
        for identifier in simulatorWindows.keys where !opened.contains(identifier) {
            simulatorWindows.removeValue(forKey: identifier)
            mainWindow?.showDevicePreview(ifDisplaying: identifier)
        }
        updateScreenToolbar()
    }

    private func stopSimulatorPresentations() async throws {
        _ = await presentationTask?.result
        await model.stopDevicePostures()
        for host in simulatorHosts.values { try await host.stop(keepingDevicesRunning: true) }
        simulatorHosts.removeAll()
        simulatorWindows.removeAll()
        if let current = mainWindow?.liveDeviceIdentifier { mainWindow?.showDevicePreview(ifDisplaying: current) }
    }

    private func prepareSimulatorManagement(_ action: DeviceManagementAction, devices: [InventoryDevice]) async throws {
        var prepared: [InventoryDevice] = []
        do {
            for device in devices {
                guard case .simulator(let simulator) = device, device.supports(action), simulatorWindows[device.id] != nil,
                      case .simulator(let udid, let path) = device.id else { continue }
                let identifier = SimulatorDeviceIdentifier(udid, deviceSetPath: path)
                guard let host = simulatorHosts.values.first(where: { $0.openedDeviceIdentifiers.contains(identifier) }) else { continue }
                switch action {
                case .restart, .erase:
                    if simulator.state == "Booted" {
                        try await host.preparePresentationForRestart(for: identifier)
                        prepared.append(device)
                    } else {
                        try await host.releasePresentation(for: identifier)
                        simulatorWindows.removeValue(forKey: device.id)
                        mainWindow?.showDevicePreview(ifDisplaying: device.id)
                    }
                case .shutdown, .forceShutdown, .remove:
                    try await host.releasePresentation(for: identifier)
                    simulatorWindows.removeValue(forKey: device.id)
                    mainWindow?.showDevicePreview(ifDisplaying: device.id)
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

    private func finishSimulatorManagement(_ action: DeviceManagementAction, devices: [InventoryDevice]) async throws {
        guard action == .restart || action == .erase else { return }
        var failures: [String] = []
        for device in devices {
            guard case .simulator(let udid, let path) = device.id else { continue }
            let identifier = SimulatorDeviceIdentifier(udid, deviceSetPath: path)
            guard let host = simulatorHosts.values.first(where: { $0.openedDeviceIdentifiers.contains(identifier) }) else { continue }
            do { try await host.finishPresentationRestart(for: identifier) }
            catch { failures.append("\(device.name): \(error.localizedDescription)") }
        }
        simulatorPresentationsChanged()
        if !failures.isEmpty { throw HostError.operation(failures.joined(separator: "\n")) }
    }

    private func prepareMainWindow() {
        guard mainWindow == nil else { return }
        let controller = ManagerWindowController(model: model)
        controller.isDeviceActivated = { [weak self] identifier in self?.screen(for: identifier) != nil }
        controller.preferredArtworkXcodeURL = { [weak self] in self?.displayXcodeURL }
        controller.onShowCompactWindow = { [weak self] identifier in self?.showCompactScreen(identifier) }
        controller.onSelectionChange = { [weak self] identifier in self?.selectedDeviceChanged(identifier) }
        controller.onNewWatch = { [weak self] phone in self?.showNewSimulator(pairingWith: phone) }
        controller.onScreenAction = { [weak self] action in
            guard let self, let identifier = self.mainWindow?.liveDeviceIdentifier else { return }
            self.performScreenAction(action, for: identifier)
        }
        mainWindow = controller
    }

    private func configureCanvasControls(for identifier: DeviceInventoryID, screen: Screen) {
        let controls = DeviceCanvasControls()
        controls.onAction = { [weak self] action in self?.performScreenAction(action, for: identifier) }
        switch screen {
        case .simulator(let controller):
            controller.canvasControls = controls
            controller.onSessionChange = { [weak self] in self?.observeScreenState(identifier) }
        case .remote(let controller): controller.canvasControls = controls
        }
    }

    private func performScreenAction(_ action: String, for identifier: DeviceInventoryID) {
        guard let screen = screen(for: identifier) else { return }
        if action.hasPrefix("posture."), let posture = DevicePosture(rawValue: String(action.dropFirst("posture.".count))),
           let source = model.devicePostures[identifier], screen.canControlDevice,
           !model.managingDeviceIDs.contains(identifier) {
            Task { [weak self] in
                do { try await source.select(posture) }
                catch is CancellationError {}
                catch { self?.present(error) }
            }
            if case .simulator(let controller) = screen { controller.focusInput() }
            updateScreenToolbar()
            return
        }
        guard screen.supports(action), screen.isEnabled(action) else { return }
        screen.perform(action)
        updateScreenToolbar()
    }

    private func updateCanvasControls(for identifier: DeviceInventoryID) {
        guard let screen = screen(for: identifier), let controls = screen.canvasControls else { return }
        let posture = model.devicePostures[identifier]
        let enabled = screen.canControlDevice && !model.managingDeviceIDs.contains(identifier)
        controls.xcodeURL = displayXcodeURL
        controls.update(supports: { action in
            action == "rotate" && posture?.isSupported == true ? false : screen.supports(action)
        }, isEnabled: screen.isEnabled, recordingTitle: screen.recordingTitle,
                        recordingStartDate: screen.recordingStartDate, nativePoses: screen.nativePoseControls,
                        nativePosesEnabled: enabled)
        let available = model.inventory.first { $0.id == identifier }
            .map { DevicePostureModel.canInspect(capabilities: $0.capabilities) } ?? false
        controls.updatePosture(posture, isEnabled: enabled, available: available)
        if mainWindow?.liveDeviceIdentifier == identifier {
            mainWindow?.updateCanvasMinimumWidth(controls.isHidden ? 0 : controls.fittingSize.width + 24)
        }
    }

    private func updateScreenToolbar() {
        for identifier in Array(simulatorWindows.keys) + Array(remoteWindows.keys) { updateCanvasControls(for: identifier) }
        guard let identifier = mainWindow?.liveDeviceIdentifier, let screen = screen(for: identifier) else { return }
        simulatorMenus.updateKeyEquivalents(for: (screen.commandTarget as? DeviceWindowController)?.session.capabilities)
        mainWindow?.updateScreenToolbar(supports: screen.supports, isEnabled: screen.isEnabled,
                                       resizingApp: screen.resizingApp, capturesKeyboard: screen.capturesKeyboard)
        mainWindow?.updateCanvasZoom(supports: screen.supports, isEnabled: screen.isEnabled, isSelected: screen.canvasZoomIsSelected)
    }

    private func observeScreenState(_ identifier: DeviceInventoryID) {
        guard let screen = screen(for: identifier) else { return }
        let owner = screen.commandTarget
        let session = (owner as? DeviceWindowController)?.session
        withObservationTracking {
            updateCanvasControls(for: identifier)
            // These controls return to the main toolbar with the same screen.
            _ = screen.capturesKeyboard
            _ = screen.resizingApp
            for action in ["resizeApp", "captureKeyboard"] {
                _ = screen.supports(action)
                _ = screen.isEnabled(action)
            }
            if let controller = owner as? DeviceWindowController {
                _ = controller.canvasZoom.scale
                _ = controller.canvasZoom.fitScale
                _ = controller.canvasZoom.mode
            }
            if mainWindow?.liveDeviceIdentifier == identifier { updateScreenToolbar() }
        } onChange: { [weak self, weak owner, weak session] in
            Task { @MainActor in
                guard let self, let owner, self.screen(for: identifier)?.commandTarget === owner else { return }
                if let controller = owner as? DeviceWindowController, controller.session !== session { return }
                self.observeScreenState(identifier)
            }
        }
    }

    private func observeRemoteDevices() {
        withObservationTracking {
            _ = model.inventory
            _ = model.status?.host
            _ = model.isRemoteInventoryComplete
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateRemoteWindows()
                self?.observeRemoteDevices()
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        SimulatorPreferences.migrateStandalonePreferences()
        CaptureThumbnail.reportDetached = { [weak self] error in self?.present(error) }
        simulatorMenus.toggleTestingDevices = {
            let defaults = HostPreferences.defaults
            defaults.set(!defaults.bool(forKey: HostPreferences.showTestingDevices), forKey: HostPreferences.showTestingDevices)
        }
        simulatorMenus.toggleDeviceBezels = { [weak self] in
            let defaults = HostPreferences.defaults
            let shows = !defaults.showsDeviceBezels
            defaults.set(shows, forKey: HostPreferences.showChrome)
            self?.simulatorWindows.values.forEach { $0.setDeviceBezelVisible(shows) }
        }
        installMenu()
        observeRemoteDevices()
        model.onOpenRemoteDevice = { [weak self] device in self?.openRemoteScreen(device) }
        model.beforeStoppingScreens = { [weak self] in
            do {
                try await self?.stopSimulatorPresentations()
                try await self?.stopRemoteScreens()
            } catch {
                self?.updateDevicePostureScreens()
                throw error
            }
        }
        model.beforeManagingRemoteDevices = { [weak self] identifiers in
            try await self?.stopRemoteScreens(for: identifiers)
        }
        model.beforeManagingSimulators = { [weak self] action, devices in
            try await self?.prepareSimulatorManagement(action, devices: devices)
        }
        model.afterManagingSimulators = { [weak self] action, devices in
            try await self?.finishSimulatorManagement(action, devices: devices)
        }
        model.onError = { [weak self] error in
            if !(error is CancellationError) { self?.present(error) }
        }
        rendererDevicesObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("dev.lynnswap.NeoSimulator.RendererDevicesDidChange"), object: nil, queue: .main
        ) { [weak self] notification in
            let testingVisibilityChanged = notification.userInfo?["testingVisibilityChanged"] as? Bool == true
            Task { @MainActor in
                await self?.model.rendererDevicesDidChange(testingVisibilityChanged: testingVisibilityChanged)
            }
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  ["dev.lynnswap.NeoSimulator", "com.apple.dt.Xcode", "com.apple.dt.Devices"].contains(app.bundleIdentifier ?? "") else { return }
            Task { @MainActor in await self?.model.refresh() }
        }
        showDevices(nil)
        model.start()
        startInventoryObservation()
        connectionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.quitting else { return }
                await self.model.synchronizeConnections()
            }
        }
    }

    private func startInventoryObservation() {
        guard inventoryObservationTask == nil, inventoryObservation == nil else { return }
        inventoryObservationTask = Task { [weak self] in
            guard let self else { return }
            defer { self.inventoryObservationTask = nil }
            do {
                let observation = try DeviceInventoryObservation()
                self.inventoryObservation = observation
                observation.onChange = { [weak self] in
                    // Preserve source-event order before the asynchronous inventory read.
                    self?.model.inventoryObservationRecovered()
                    Task { await self?.model.inventoryDidChange() }
                }
                observation.onError = { [weak self] error in
                    self?.model.inventoryObservationFailed(error)
                }
                try await observation.start()
            } catch is CancellationError {
                await self.inventoryObservation?.stop()
            } catch {
                self.inventoryObservation = nil
                self.model.inventoryObservationFailed(error)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showDevices(nil)
        Task { await model.refresh() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !quitting else { return .terminateLater }
        guard !model.isBusy else {
            let alert = NSAlert()
            alert.messageText = "A simulator operation is still running."
            alert.informativeText = "Wait for the operation to finish, then quit NeoSimulator."
            alert.runModal()
            return .terminateCancel
        }
        quitting = true
        let restoring: [SimulatorScreenRestoration] = restartsAfterQuitting ? simulatorHosts.flatMap { xcode, host in
            host.openedDeviceIdentifiers.compactMap { device in
                let id = DeviceInventoryID.simulator(udid: device.identifier, deviceSetPath: device.deviceSetPath)
                guard let controller = simulatorWindows[id] else { return nil as SimulatorScreenRestoration? }
                let presentation: SimulatorScreenRestoration.Presentation = controller.isEmbedded ? .main
                    : controller.window?.isVisible == true ? .compact : .hidden
                return SimulatorScreenRestoration(device: device, xcodeURL: xcode, presentation: presentation)
            }
        }.sorted { $0.presentation.restorationOrder < $1.presentation.restorationOrder } : []
        Task {
            do {
                mainWindow?.stopInspectorReads()
                try await mainWindow?.finishInspectorPreviews()
                inventoryObservationTask?.cancel()
                await inventoryObservation?.stop()
                await inventoryObservationTask?.value
                inventoryObservation = nil
                await remoteHostCleanup?.value
                try await stopSimulatorPresentations()
                try await stopRemoteScreens()
                try await model.quitRenderer(keepingDevicesRunning: quitKeepingDevicesRunning)
                if restartsAfterQuitting {
                    let urls = restoring.map(\.url)
                    let helper = rendererURL.appendingPathComponent("Contents/MacOS/NeoSimulatorRenderer")
                    try await ManagerRelaunch(processIdentifier: ProcessInfo.processInfo.processIdentifier,
                        applicationURL: Bundle.main.bundleURL, deviceURLs: urls).schedule(using: helper)
                }
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                quitting = false
                if restartsAfterQuitting { quitKeepingDevicesRunning = nil }
                restartsAfterQuitting = false
                model.resumeAfterCancelledQuit()
                updateDevicePostureScreens()
                mainWindow?.resumeInspectorAfterCancelledQuit()
                startInventoryObservation()
                if !(error is CancellationError) { present(error) }
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "neosimulator" {
            switch url.host {
            case "settings": showSettings(nil)
            case "devices": showDevices(nil)
            case "open-device":
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                guard let identifier = query.first(where: { $0.name == "udid" })?.value else { continue }
                model.openDevice(.simulator(udid: identifier, deviceSetPath: query.first(where: { $0.name == "deviceSetPath" })?.value))
            case "restore-screen":
                guard let restoration = SimulatorScreenRestoration(url: url) else { continue }
                model.restoreScreen(restoration) { [weak self] in
                    guard let self, let screen = self.screen(for: restoration.deviceID) else { return }
                    try await self.transitionPresentation {
                        switch restoration.presentation {
                        case .main: break // Opening the screen already embeds it in the main window.
                        case .compact:
                            try await screen.showCompactWindow()
                            self.mainWindow?.showDevicePreview(ifDisplaying: restoration.deviceID)
                            self.mainWindow?.window?.orderOut(nil)
                        case .hidden:
                            try await screen.detach()
                            self.mainWindow?.showDevicePreview(ifDisplaying: restoration.deviceID)
                        }
                    }
                }
            case "quit":
                if URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                    .first(where: { $0.name == "ask" })?.value == "true" {
                    quitAsking(nil)
                } else { NSApp.terminate(nil) }
            case "select-host":
                if let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                    .first(where: { $0.name == "mode" })?.value,
                   let host = SimulatorHost(rawValue: raw) { model.select(host) }
            default: break
            }
        }
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        addDevicesMenu("Device", to: menu)
        menu.addItem(.separator())
        addItem("Show Devices", action: #selector(showDevices(_:)), to: menu)
        addItem("Settings…", action: #selector(showSettings(_:)), to: menu)
        Task { await model.refresh() }
        return menu
    }

    private func openRemoteScreen(_ device: CoreDeviceDevice) {
        let id = DeviceInventoryID.coreDevice(device.identifier)
        guard !quitting, !model.managingDeviceIDs.contains(id) else { return }
        let controller: RemoteDeviceWindowController
        if let existing = remoteWindows[id] { controller = existing }
        else {
            controller = RemoteDeviceWindowController(device: device)
            controller.onClose = { [weak self, weak controller] in
                guard self?.remoteWindows[id] === controller else { return }
                self?.remoteWindows.removeValue(forKey: id)
                self?.mainWindow?.showDevicePreview(ifDisplaying: id)
            }
            controller.onShowInMainWindow = { [weak self] in self?.showScreenInMainWindow(id) }
            controller.onConnect = { [weak self, weak controller] in
                guard let self, self.remoteWindows[id] === controller else { return }
                await self.model.deviceScreenDidConnect(id)
            }
            controller.onChange = { [weak self] in self?.updateScreenToolbar() }
            remoteWindows[id] = controller
            configureCanvasControls(for: id, screen: .remote(controller))
            observeScreenState(id)
        }
        controller.connectIfNeeded()
        showScreenInMainWindow(id)
    }

    private func updateRemoteWindows() {
        if model.isRemoteInventoryComplete {
            for (id, controller) in remoteWindows {
                let current = model.inventory.first { $0.id == id }
                controller.updateInventory(current)
            }
        }
        let host = model.status?.host
        let changedToDeviceHub = host == .deviceHub && lastRemoteHost != .deviceHub
        if let host { lastRemoteHost = host }
        if changedToDeviceHub, !remoteWindows.isEmpty, remoteHostCleanup == nil {
            remoteHostCleanup = Task { [weak self] in
                guard let self else { return }
                defer { self.remoteHostCleanup = nil }
                do { try await self.stopRemoteScreens() }
                catch is CancellationError {}
                catch { self.present(error) }
            }
        }
    }

    private func stopRemoteScreens(for identifiers: Set<DeviceInventoryID>? = nil) async throws {
        var failures: [String] = []
        let targets = remoteWindows.filter { identifiers?.contains($0.key) ?? true }.map(\.value)
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

    @objc private func showDevices(_ sender: Any?) {
        prepareMainWindow()
        mainWindow?.showWindow(nil)
        mainWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @objc private func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(model: model, restart: { [weak self] in self?.restartForFrameworkChange() })
        }
        model.frameworks.reload()
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @objc func showNewSimulator(_ sender: Any?) {
        showNewSimulator(pairingWith: nil)
    }

    private func showNewSimulator(pairingWith phone: SimulatorHostDevice?) {
        guard !quitting else { return }
        let creationID = phone?.inventoryID
        if let newSimulatorWindow = newSimulatorWindows[creationID] {
            newSimulatorWindow.showWindow(nil)
            newSimulatorWindow.window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        guard preparingNewSimulators.insert(creationID).inserted else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { self.preparingNewSimulators.remove(creationID) }
            do {
                let context: SimulatorCreationContext
                let existingPhone: NewSimulatorWindowController.ExistingPhone?
                if let phone {
                    guard let type = phone.deviceTypeIdentifier else {
                        throw HostError.operation("The selected iPhone's simulator device type is unavailable.")
                    }
                    context = try await self.model.creationCatalog(for: phone.inventoryID)
                    existingPhone = .init(identifier: phone.identifier, name: phone.name,
                                          deviceType: type, runtime: phone.runtimeIdentifier)
                } else {
                    context = try await self.model.creationCatalog()
                    existingPhone = nil
                }
                let snapshot = try await SimulatorCatalog.Snapshot.decode(context.data)
                guard !self.quitting else { return }
                let form = NewSimulatorWindowController(catalog: snapshot.catalog(), pairingWith: existingPhone, create: { [model = self.model] name, type, runtime in
                    try await model.createSimulator(named: name, deviceType: type, runtime: runtime, context: context)
                }, pair: { [model = self.model] watch, phone in
                    try await model.pairSimulators(watch: watch, phone: phone, context: context)
                }, onClose: { [weak self] in
                    self?.newSimulatorWindows[creationID] = nil
                })
                self.newSimulatorWindows[creationID] = form
                form.showWindow(nil)
                form.window?.makeKeyAndOrderFront(nil)
                NSApp.activate()
            } catch { self.present(error) }
        }
    }

    private func restartForFrameworkChange() {
        guard !model.isBusy, !quitting, model.frameworks.needsRestart else { return }
        restartsAfterQuitting = true
        quitKeepingDevicesRunning = true
        NSApp.terminate(nil)
    }

    @objc private func quitAsking(_ sender: Any?) {
        guard !model.isBusy, !quitting else { return }
        let defaults = UserDefaults(suiteName: "dev.lynnswap.NeoSimulator.Renderer") ?? .standard
        let alert = NSAlert()
        alert.messageText = "Do you want to shut down the simulated devices?"
        alert.informativeText = "You can shut down the devices shown in NeoSimulator or keep them running after quitting."
        alert.addButton(withTitle: "Shut Down")
        alert.addButton(withTitle: "Keep Running")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Remember as the default quit action."
        if defaults.bool(forKey: "DetachOnAppQuit") {
            alert.buttons[0].keyEquivalent = ""
            alert.buttons[1].keyEquivalent = "\r"
        }
        switch alert.runModal() {
        case .alertFirstButtonReturn: quitKeepingDevicesRunning = false
        case .alertSecondButtonReturn: quitKeepingDevicesRunning = true
        default: return
        }
        if alert.suppressionButton?.state == .on { defaults.set(quitKeepingDevicesRunning, forKey: "DetachOnAppQuit") }
        NSApp.terminate(nil)
    }

    private func present(_ error: any Error) {
        let alert = NSAlert()
        alert.messageText = error.localizedDescription
        let failure = error as? any LocalizedError
        alert.informativeText = [failure?.failureReason, failure?.recoverySuggestion].compactMap { $0 }.joined(separator: "\n\n")
        alert.addDiagnosticDetails((error as? SimulatorHostFailure)?.technicalDetails)
        if let failure = error as? SimulatorHostFailure {
            NSLog("NeoSimulator: %@", failure.technicalDetails)
            if failure.kind == .preferencesChanged, model.status?.restorationAvailable == true {
                alert.addButton(withTitle: "Restore Saved Values…")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn {
                    let confirmation = NSAlert()
                    confirmation.alertStyle = .warning
                    confirmation.messageText = "Restore the saved Xcode settings?"
                    confirmation.informativeText = "Your current simulator routing settings will be replaced with the original values saved by NeoSimulator. Your devices are kept."
                    confirmation.addButton(withTitle: "Restore")
                    confirmation.addButton(withTitle: "Cancel")
                    if confirmation.runModal() == .alertFirstButtonReturn { model.restoreDefaults(force: true) }
                }
                return
            }
        }
        alert.addButton(withTitle: "OK")
        if error is SimulatorHostFailure { alert.addButton(withTitle: "Copy Details") }
        if alert.runModal() == .alertSecondButtonReturn, let failure = error as? SimulatorHostFailure {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(failure.technicalDetails, forType: .string)
        }
    }

    private func installMenu() {
        let main = NSMenu()
        let app = addSubmenu("NeoSimulator", to: main)
        addItem("About NeoSimulator", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), to: app, target: NSApp)
        app.addItem(.separator())
        addItem("Settings…", action: #selector(showSettings(_:)), key: ",", to: app)
        app.addItem(.separator())
        let services = addSubmenu("Services", to: app)
        NSApp.servicesMenu = services
        app.addItem(.separator())
        addItem("Hide NeoSimulator", action: #selector(NSApplication.hide(_:)), key: "h", to: app, target: NSApp)
        let hideOthers = addItem("Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), key: "h", to: app, target: NSApp)
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        addItem("Show All", action: #selector(NSApplication.unhideAllApplications(_:)), to: app, target: NSApp)
        app.addItem(.separator())
        addItem("Quit NeoSimulator", action: #selector(NSApplication.terminate(_:)), key: "q", to: app, target: NSApp)
        let quitWithChoice = addItem("Quit NeoSimulator…", action: #selector(quitAsking(_:)), key: "q", to: app)
        quitWithChoice.keyEquivalentModifierMask = [.command, .option]
        quitWithChoice.isAlternate = true
        let file = addSubmenu("File", to: main)
        addItem("New Simulator…", action: #selector(showNewSimulator(_:)), key: "n", to: file)
        addDevicesMenu("Open Simulator", to: file)
        simulatorMenus.addCloseWindowCommands(to: file)
        file.addItem(.separator())
        addItem("Save Screenshot…", action: #selector(RemoteDeviceWindowController.saveScreenshot(_:)), key: "s", to: file).target = nil
        simulatorMenus.addScreenshotDestinationCommand(to: file)
        addItem("Discard Screenshot…", action: #selector(RemoteDeviceWindowController.discardScreenshot(_:)), to: file).target = nil
        addItem("Record Screen", action: #selector(RemoteDeviceWindowController.recordScreen(_:)), key: "r", to: file).target = nil
        let recordTo = addItem("Record Screen…", action: #selector(RemoteDeviceWindowController.recordScreenTo(_:)), key: "r", to: file)
        recordTo.target = nil
        recordTo.keyEquivalentModifierMask = [.command, .option]
        recordTo.isAlternate = true
        addItem("Stop Recording", action: #selector(RemoteDeviceWindowController.stopScreenRecording(_:)), to: file).target = nil
        addItem("Save Recording…", action: #selector(RemoteDeviceWindowController.saveScreenRecording(_:)), to: file).target = nil
        addItem("Discard Recording…", action: #selector(RemoteDeviceWindowController.discardScreenRecording(_:)), to: file).target = nil
        let edit = EditMenu(title: "Edit")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        main.addItem(editItem)
        addItem("Undo", action: Selector("undo:"), key: "z", to: edit).target = nil
        let redo = addItem("Redo", action: Selector("redo:"), key: "z", to: edit)
        redo.target = nil
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        for (title, selector, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            addItem(title, action: Selector(selector), key: key, to: edit).target = nil
        }
        simulatorMenus.addDeviceMenus(to: main, managementMenu: SelectedDeviceMenu { [weak self] in
            self?.mainWindow?.menuForSelectedDevices()
        })
        let view = addSubmenu("View", to: main)
        addItem("Show Devices", action: #selector(showDevices(_:)), to: view)
        simulatorMenus.addScreenCommands(file: file, edit: edit, view: view)
        let window = addSubmenu("Window", to: main)
        addItem("Minimize", action: #selector(NSWindow.performMiniaturize(_:)), key: "m", to: window).target = nil
        addItem("Show Tab Bar", action: #selector(NSWindow.toggleTabBar(_:)), to: window).target = nil
        addItem("Move Tab to New Window", action: #selector(NSWindow.moveTabToNewWindow(_:)), to: window).target = nil
        addItem("Merge All Windows", action: #selector(NSWindow.mergeAllWindows(_:)), to: window).target = nil
        window.addItem(.separator())
        addItem("Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), to: window, target: NSApp)
        NSApp.windowsMenu = window
        NSApp.mainMenu = main
    }

    private func addDevicesMenu(_ title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = SimulatorDevicesMenu(model: model, title: title)
        menu.addItem(item)
    }

    @discardableResult private func addSubmenu(_ title: String, to parent: NSMenu, delegate: (any NSMenuDelegate)? = nil) -> NSMenu {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        menu.delegate = delegate
        item.submenu = menu
        parent.addItem(item)
        return menu
    }

    @discardableResult private func addItem(_ title: String, action: Selector, key: String = "", to menu: NSMenu,
                                            target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target ?? self
        menu.addItem(item)
        return item
    }
}
