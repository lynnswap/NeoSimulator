import AppKit
@_spi(NeoSimulator) import XcodeSimulatorHost

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let rendererURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Applications/NeoSimulatorRenderer.app")
    lazy var model = SimulatorManagerModel(rendererApplicationURL: rendererURL, presentSimulator: { [weak self] context in
        try await self?.openSimulatorPresentation(context)
    })
    private(set) lazy var screens: DeviceScreens = {
        let screens = DeviceScreens(model: self.model)
        screens.onError = { [weak self] error in self?.present(error) }
        screens.onShowInMainWindow = { [weak self] identifier in self?.prepareMainWindow().showDevice(identifier) }
        screens.onApplicationsChange = { [weak self] identifier in self?.mainWindow?.applicationsChanged(on: identifier) }
        return screens
    }()
    private(set) var mainWindow: ManagerWindowController?
    private var settingsWindow: SettingsWindowController?
    private var newSimulatorWindows: [DeviceInventoryID?: NewSimulatorWindowController] = [:]
    private var preparingNewSimulators: Set<DeviceInventoryID?> = []
    private var quitting = false
    private var rendererDevicesObserver: NSObjectProtocol?
    private var workspaceObserver: NSObjectProtocol?
    private var connectionTimer: Timer?
    private var inventoryObservation: DeviceInventoryObservation?
    private var inventoryObservationTask: Task<Void, Never>?
    private var activeStateObservation: DeviceActiveStateObservation?
    private var quitKeepingDevicesRunning: Bool?
    private var restartsAfterQuitting = false
    private lazy var simulatorMenus = MenuController(application: nil,
        gpuPolicy: UserDefaults(suiteName: GPUPolicy.suiteName).map(GPUPolicy.init), pasteboardSync: screens.pasteboardSync)

    private func openSimulatorPresentation(_ context: SimulatorPresentationContext) async throws {
        let mainWindow = prepareMainWindow()
        try await screens.openSimulatorScreen(context) { previousPresentation in
            try await mainWindow.presentConnectedScreen(context.deviceID, purpose: context.purpose,
                                                        preserving: previousPresentation)
        }
    }

    /// Lets accepted screen moves finish before the screens stop.
    private func stopScreens() async throws {
        await mainWindow?.deviceScreenViewController.waitForScreenMoves()
        try await screens.stopAll()
    }

    @discardableResult func prepareMainWindow() -> ManagerWindowController {
        if let mainWindow { return mainWindow }
        let controller = ManagerWindowController(model: model, screens: screens, menus: simulatorMenus)
        controller.onError = { [weak self] error in self?.present(error) }
        model.onOpenRemoteDevice = { [weak self] device in try await self?.openRemoteScreen(device) }
        model.onDeviceOpenRequested = { [weak controller] identifier in controller?.showDevice(identifier) }
        controller.onNewCompanion = { [weak self] device in self?.showNewSimulator(pairingWith: device) }
        mainWindow = controller
        return controller
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
            self?.screens.setDeviceBezelsVisible(shows)
        }
        installMenu()
        screens.observeRemoteDevices()
        model.beforeStoppingScreens = { [weak self] in try await self?.stopScreens() }
        model.beforeManagingRemoteDevices = { [weak self] identifiers in
            try await self?.screens.stopRemoteScreens(for: identifiers)
        }
        model.beforeManagingSimulators = { [weak self] action, devices in
            try await self?.screens.prepareSimulatorManagement(action, devices: devices)
        }
        model.afterManagingSimulators = { [weak self] action, devices in
            try await self?.screens.finishSimulatorManagement(action, devices: devices)
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
        if activeStateObservation == nil {
            let observation = DeviceActiveStateObservation()
            observation.onChange = { [weak self] in self?.model.activeStatesDidChange($0) }
            observation.onError = { [weak self] in self?.model.activeStateObservationFailed($0) }
            activeStateObservation = observation
            observation.start()
        }
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
        quitting = true
        screens.beginQuitting()
        let preparation = Task.immediate { try await model.prepareForQuit() }
        let restoring = restartsAfterQuitting ? screens.restorations() : []
        Task {
            do {
                mainWindow?.stopInspectorReads()
                try await preparation.value
                try await mainWindow?.finishInspectorPreviews()
                inventoryObservationTask?.cancel()
                await inventoryObservation?.stop()
                await inventoryObservationTask?.value
                inventoryObservation = nil
                await activeStateObservation?.stop()
                activeStateObservation = nil
                await screens.waitForRemoteHostCleanup()
                try await stopScreens()
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
                screens.resumeAfterCancelledQuit()
                mainWindow?.resumeInspectorAfterCancelledQuit()
                startInventoryObservation()
                if !(error is CancellationError) { present(error) }
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        prepareMainWindow()
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
                mainWindow?.restoreScreen(restoration)
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

    private func openRemoteScreen(_ device: CoreDeviceDevice) async throws {
        guard let screen = screens.openRemoteScreen(for: device) else { return }
        try await mainWindow?.presentConnectedScreen(screen.id, purpose: .requested)
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

    private func showNewSimulator(pairingWith device: SimulatorHostDevice?) {
        guard !quitting else { return }
        let creationID = device?.inventoryID
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
                let existingDevice: NewSimulatorWindowController.ExistingDevice?
                if let device {
                    guard let type = device.deviceTypeIdentifier else {
                        throw HostError.operation("The selected simulator's device type is unavailable.")
                    }
                    context = try await self.model.creationCatalog(for: device.inventoryID)
                    existingDevice = .init(identifier: device.identifier, name: device.name, productFamily: device.productFamily,
                                           deviceType: type, runtime: device.runtimeIdentifier)
                } else {
                    context = try await self.model.creationCatalog()
                    existingDevice = nil
                }
                let snapshot = try await SimulatorCatalog.Snapshot.decode(context.data)
                guard !self.quitting else { return }
                let form = NewSimulatorWindowController(catalog: snapshot.catalog(), pairingWith: existingDevice, create: { [model = self.model] name, type, runtime in
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
        guard !quitting else { return }
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
        let device = simulatorMenus.addDeviceMenus(to: main, managementMenu: SelectedDeviceMenu { [weak self] in
            self?.mainWindow?.menuForSelectedDevices()
        })
        // A remote screen and its frame can cover the canvas, whose context menu also offers this command.
        device.insertItem(NSMenuItem(title: "Choose Screen Source…",
            action: #selector(RemoteDeviceWindowController.chooseCaptureSource(_:)), keyEquivalent: ""), at: 1)
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
