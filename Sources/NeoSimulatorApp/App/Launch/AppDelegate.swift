import AppKit
import NeoSimulatorDeviceIO
import NeoSimulatorHostSupport
import NeoSimulatorKit
import NeoSimulatorUI
import ObservationBridge
import SwiftUI

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
        return screens
    }()
    private(set) var mainWindow: ManagerWindowController?
    private(set) var onboardingWindow: OnboardingWindowController?
    private var startupTask: Task<Void, Never>?
    private let preferences = SimulatorPreferences()
    private let hostPreferenceAccess: HostPreferenceAccess
    private var settingsWindow: SettingsWindowController?
    private var newSimulatorWindows: [DeviceInventoryID?: NewSimulatorWindowController] = [:]
    private var preparingNewSimulators: Set<DeviceInventoryID?> = []
    private var quitting = false
    /// What went wrong with the operations that a quit waits for. A modal alert here would hold the wait, so a quit
    /// reports them when it ends.
    private var quitFailures: [any Error] = []
    private var hasStarted = false
    private var launchURLs: [URL] = []
    private var rendererDevicesObserver: NSObjectProtocol?
    private var workspaceObserver: NSObjectProtocol?
    private let processObservation = SimulatorProcessObservation()
    private var inventoryObservation: DeviceInventoryObservation?
    private var inventoryObservationTask: Task<Void, Never>?
    private var observationRetryTask: Task<Void, Never>?
    private var coreDeviceInitializationPanel: NSPanel?
    private var activeStateObservation: DeviceActiveStateObservation?
    private var quitKeepingDevicesRunning: Bool?
    private var restartsAfterQuitting = false
    private lazy var simulatorMenus = MenuController(application: nil,
        gpuPolicy: UserDefaults(suiteName: GPUPolicy.suiteName).map(GPUPolicy.init), pasteboardSync: screens.pasteboardSync)

    private let makeLicenses: () -> NSViewController
    private let splitViewAutosaveName: NSSplitView.AutosaveName?

    init(makeLicenses: @escaping () -> NSViewController,
         hostPreferenceAccess: HostPreferenceAccess = HostPreferenceAccess(),
         splitViewAutosaveName: NSSplitView.AutosaveName? = nil) {
        self.makeLicenses = makeLicenses
        self.hostPreferenceAccess = hostPreferenceAccess
        self.splitViewAutosaveName = splitViewAutosaveName
        super.init()
    }

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

    @discardableResult func prepareMainWindow(defaults: UserDefaults = .standard) -> ManagerWindowController {
        if let mainWindow { return mainWindow }
        let controller = ManagerWindowController(model: model, screens: screens, menus: simulatorMenus, defaults: defaults,
                                                 splitViewAutosaveName: splitViewAutosaveName)
        controller.onError = { [weak self] error in self?.present(error) }
        model.onOpenRemoteDevice = { [weak self] device in try await self?.openRemoteScreen(device) }
        model.onDeviceOpenRequested = { [weak controller] identifier in controller?.showDevice(identifier) }
        controller.onNewCompanion = { [weak self] device in self?.showNewSimulator(pairingWith: device) }
        controller.onShowServiceProfile = { [weak self] in self?.showSettings(selectingServiceProfile: $0) }
        mainWindow = controller
        return controller
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        CoreDeviceRuntime.onInitializationDelayChanged = { [weak self] delayed in
            self?.updateCoreDeviceInitializationNotice(delayed)
        }
        model.requestHostPreferenceAccess = { [weak self] in
            try await self?.requestHostPreferenceAccess()
        }
        model.retryDeviceObservation = { [weak self] in await self?.retryDeviceObservation() }
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
            guard let self, !(error is CancellationError) else { return }
            if quitting { quitFailures.append(error) } else { present(error) }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        rendererDevicesObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("dev.lynnswap.NeoSimulator.RendererDevicesDidChange"), object: nil, queue: .main
        ) { [weak self] notification in
            let testingVisibilityChanged = notification.userInfo?["testingVisibilityChanged"] as? Bool == true
            Task { @MainActor in
                self?.processObservation.refresh()
                await self?.model.rendererDevicesDidChange(testingVisibilityChanged: testingVisibilityChanged)
            }
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  ["dev.lynnswap.NeoSimulator", "com.apple.dt.Xcode", "com.apple.dt.Devices"].contains(app.bundleIdentifier ?? "") else { return }
            Task { @MainActor in
                self?.processObservation.refresh()
                if app == NSRunningApplication.current { self?.model.revalidateDevices() }
                await self?.model.refresh()
            }
        }
        startManager()
        startInventoryObservation()
        processObservation.onChange = { [weak self] in
            guard let self, !self.quitting else { return }
            Task { await self.model.synchronizeConnections() }
        }
        processObservation.onError = { [weak self] in self?.model.processObservationFailed($0) }
        processObservation.onReady = { [weak self] in self?.model.processObservationRecovered() }
    }

    /// Completes access setup before starting the session or opening restored screens.
    func startManager() {
        guard startupTask == nil, !hasStarted else { return }
        startupTask = Task { [weak self] in
            guard let self else { return }
            defer { self.startupTask = nil }
            do {
                try await PortableObservationTracking.prepare()
                try await self.requestHostPreferenceAccess()
                try Task.checkCancellation()
                self.screens.observeRemoteDevices()
                self.hasStarted = true
                self.showDevices(nil)
                self.model.start()
                self.processObservation.start()
                let urls = self.launchURLs
                self.launchURLs.removeAll()
                if !urls.isEmpty { self.application(NSApp, open: urls) }
            } catch is CancellationError {
            } catch {
                self.present(error)
            }
        }
    }

    private func requestHostPreferenceAccess() async throws {
        if hostPreferenceAccess.restore() { return }
        let controller = OnboardingWindowController { [hostPreferenceAccess] window in
            try await hostPreferenceAccess.request(presenting: window)
        }
        onboardingWindow = controller
        defer {
            controller.close()
            onboardingWindow = nil
        }
        try await controller.run()
    }

    private func startInventoryObservation() {
        if activeStateObservation == nil {
            let observation = DeviceActiveStateObservation(limitedTo: { [screens] in screens.nativeCanvasDeviceIdentifiers })
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
                observation.onReady = { [weak self] in self?.model.inventoryObservationRecovered() }
                observation.onChange = { [weak self] in
                    // Preserve source-event order before the asynchronous inventory read.
                    self?.model.inventoryObservationRecovered()
                    self?.processObservation.refresh()
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

    private func retryDeviceObservation() async {
        if let observationRetryTask { await observationRetryTask.value; return }
        guard !quitting else { return }
        let task = Task { [self] in
            let starting = inventoryObservationTask
            starting?.cancel()
            await inventoryObservation?.stop()
            await starting?.value
            await activeStateObservation?.stop()
            processObservation.stop()
            inventoryObservation = nil
            activeStateObservation = nil
            guard !quitting, !Task.isCancelled else { return }
            startInventoryObservation()
            if hasStarted { processObservation.start() }
            await inventoryObservationTask?.value
        }
        observationRetryTask = task
        await task.value
        observationRetryTask = nil
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
        startupTask?.cancel()
        onboardingWindow?.close()
        updateCoreDeviceInitializationNotice(false)
        screens.beginQuitting()
        let timeout = HostPreferences.terminationLimit
        let preparation = Task.immediate {
            if let startupTask, await !startupTask.ends(before: .now + timeout) {
                TerminationAccount.shared.note("NeoSimulator's startup had not finished when it quit.")
            }
            try await model.prepareForQuit()
        }
        let restoring = restartsAfterQuitting ? screens.restorations() : []
        var answered = false
        let answer: @MainActor (Bool) -> Void = { terminates in
            guard !answered else { return }
            answered = true
            sender.reply(toApplicationShouldTerminate: terminates)
        }
        let finishing = Task {
            var relaunchProcess: Process?
            do {
                mainWindow?.stopInspectorReads()
                try await preparation.value
                try await mainWindow?.finishInspectorPreviews()
                observationRetryTask?.cancel()
                await observationRetryTask?.value
                inventoryObservationTask?.cancel()
                await inventoryObservation?.stop()
                await inventoryObservationTask?.value
                inventoryObservation = nil
                await activeStateObservation?.stop()
                activeStateObservation = nil
                processObservation.stop()
                await screens.waitForRemoteHostCleanup()
                try await stopScreens()
                try await model.quitRenderer(keepingDevicesRunning: quitKeepingDevicesRunning) {
                    if self.restartsAfterQuitting {
                        let urls = restoring.map(\.url)
                        let helper = self.rendererURL.appendingPathComponent("Contents/MacOS/NeoSimulatorRenderer")
                        relaunchProcess = try await ManagerRelaunch(processIdentifier: ProcessInfo.processInfo.processIdentifier,
                            applicationURL: Bundle.main.bundleURL, deviceURLs: urls).schedule(using: helper)
                    }
                }
                await reportQuitOutcome()
                answer(true)
            } catch {
                if let relaunchProcess, relaunchProcess.isRunning { relaunchProcess.terminate() }
                quitting = false
                if restartsAfterQuitting { quitKeepingDevicesRunning = nil }
                restartsAfterQuitting = false
                model.resumeAfterCancelledQuit()
                screens.resumeAfterCancelledQuit()
                if hasStarted { processObservation.start() }
                mainWindow?.resumeInspectorAfterCancelledQuit()
                startInventoryObservation()
                _ = TerminationAccount.shared.take()
                let failures = quitFailures
                quitFailures = []
                failures.forEach { present($0) }
                if !(error is CancellationError) { present(error) }
                answer(false)
            }
        }
        // Each step that waits on a device has its own bound. This one is for whichever step no bound reaches, such as a
        // renderer that stopped answering: a quit that was accepted ends, and says what it left.
        Task {
            let limit = timeout * 2 + DeviceOperationLimit.terminationGrace * 3
            guard await !finishing.ends(before: .now + limit) else { return }
            TerminationAccount.shared.note("NeoSimulator stopped waiting for quitting to finish after \(limit.formatted(.units(width: .wide))).")
            await reportQuitOutcome()
            answer(true)
        }
        return .terminateLater
    }

    /// Logs what the quit leaves unfinished and says so for a limited time, because nobody may be there to answer.
    private func reportQuitOutcome() async {
        var notes = quitFailures.map { error in
            let failure = error as? any LocalizedError
            return [error.localizedDescription, failure?.failureReason, failure?.recoverySuggestion]
                .compactMap { $0 }.joined(separator: "\n")
        }
        quitFailures = []
        notes += TerminationAccount.shared.take()
        notes += await DeviceIOHub.shared.unresolvedOperations().map(\.description)
        QuitReport.present(notes)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard hasStarted else { launchURLs.append(contentsOf: urls); return }
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
        if let onboardingWindow {
            onboardingWindow.showWindow(nil)
            onboardingWindow.window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        guard hasStarted else { startManager(); return }
        prepareMainWindow()
        mainWindow?.showWindow(nil)
        mainWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @objc func showSettings(_ sender: Any?) {
        Task {
            do {
                try await PortableObservationTracking.prepare()
                showSettings(selectingServiceProfile: nil)
            } catch { present(error) }
        }
    }

    private func showSettings(selectingServiceProfile profileID: UUID?) {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(makeLicenses: makeLicenses, model: model,
                restart: { [weak self] in self?.restartForFrameworkChange() },
                makeSimulator: { [weak self] in
                    guard let self else { throw CancellationError() }
                    return try await self.makeNewSimulatorModel(pairingWith: nil)
                }, preferences: preferences, reportFailure: { [weak self] error in self?.present(error) })
            #if DEBUG
            settingsWindow?.settings.resetOnboarding = { [weak self] in self?.resetOnboarding() }
            #endif
        }
        if let profileID { settingsWindow?.settings.selectServiceProfile(profileID) }
        model.frameworks.reload()
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    #if DEBUG
    private func resetOnboarding() {
        guard !model.isBusy, !quitting, onboardingWindow == nil else { return }
        hostPreferenceAccess.reset()
        settingsWindow?.close()
        Task {
            do { try await requestHostPreferenceAccess() }
            catch is CancellationError {}
            catch { present(error) }
        }
    }
    #endif

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
                try await PortableObservationTracking.prepare()
                let content = try await self.makeNewSimulatorModel(pairingWith: device)
                guard !self.quitting else { return }
                let form = NewSimulatorWindowController(model: content, reportFailure: { [weak self] error in
                    self?.present(error)
                }, onClose: { [weak self] in
                    self?.newSimulatorWindows[creationID] = nil
                })
                self.newSimulatorWindows[creationID] = form
                form.showWindow(nil)
                form.window?.makeKeyAndOrderFront(nil)
                NSApp.activate()
            } catch is CancellationError {
            } catch { self.present(error) }
        }
    }

    private func makeNewSimulatorModel(pairingWith device: SimulatorHostDevice?) async throws -> NewSimulatorModel {
        let context: SimulatorCreationContext
        let existingDevice: NewSimulatorModel.ExistingDevice?
        if let device {
            guard let type = device.deviceTypeIdentifier else {
                throw SimulatorError.operation("The selected simulator's device type is unavailable.")
            }
            context = try await model.creationCatalog(for: device.inventoryID)
            existingDevice = .init(identifier: device.identifier, name: device.name, productFamily: device.productFamily,
                                   deviceType: type, runtime: device.runtimeIdentifier)
        } else {
            context = try await model.creationCatalog()
            existingDevice = nil
        }
        let snapshot = try await SimulatorCatalog.Snapshot.decode(context.data)
        try Task.checkCancellation()
        return NewSimulatorModel(catalog: snapshot.catalog(), pairingWith: existingDevice,
            create: { [model] name, type, runtime in
                try await model.createSimulator(named: name, deviceType: type, runtime: runtime, context: context)
            }, pair: { [model] watch, phone in
                try await model.pairSimulators(watch: watch, phone: phone, context: context)
            }, preferences: preferences)
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

    private func updateCoreDeviceInitializationNotice(_ delayed: Bool) {
        guard delayed, !quitting else {
            coreDeviceInitializationPanel?.close()
            coreDeviceInitializationPanel = nil
            return
        }
        guard coreDeviceInitializationPanel == nil else { return }
        let content = CoreDeviceRecoveryView(copyCommand: { [weak self] in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(CoreDeviceRecoveryView.recoveryCommand, forType: .string)
            self?.updateCoreDeviceInitializationNotice(false)
        }, keepWaiting: { [weak self] in self?.updateCoreDeviceInitializationNotice(false) })
        let panel = NSPanel(contentViewController: NSHostingController(rootView: content))
        panel.title = "Device Service Recovery"
        panel.styleMask = [.titled, .closable]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        coreDeviceInitializationPanel = panel
        panel.center()
        panel.makeKeyAndOrderFront(nil)
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
                    confirmation.addButton(withTitle: "Restore").hasDestructiveAction = true
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
        addItem("About NeoSimulator", action: #selector(NSApplication.orderFrontNeoSimulatorAboutPanel(_:)), to: app, target: NSApp)
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
        addItem("Record Screen", action: #selector(RemoteDeviceWindowController.recordScreen(_:)), key: "r", to: file).target = nil
        let recordTo = addItem("Record Screen…", action: #selector(RemoteDeviceWindowController.recordScreenTo(_:)), key: "r", to: file)
        recordTo.target = nil
        recordTo.keyEquivalentModifierMask = [.command, .option]
        recordTo.isAlternate = true
        addItem("Stop Recording", action: #selector(RemoteDeviceWindowController.stopScreenRecording(_:)), to: file).target = nil
        addItem("Save Recording…", action: #selector(RemoteDeviceWindowController.saveScreenRecording(_:)), to: file).target = nil
        file.addItem(.separator())
        addItem("Discard Screenshot…", action: #selector(RemoteDeviceWindowController.discardScreenshot(_:)), to: file).target = nil
        addItem("Discard Recording…", action: #selector(RemoteDeviceWindowController.discardScreenRecording(_:)), to: file).target = nil
        let edit = EditMenu(title: "Edit")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        main.addItem(editItem)
        addItem("Undo", action: NSSelectorFromString("undo:"), key: "z", to: edit).target = nil
        let redo = addItem("Redo", action: NSSelectorFromString("redo:"), key: "z", to: edit)
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

struct CoreDeviceRecoveryView: View {
    static let recoveryCommand = "killall CoreDeviceService"
    let copyCommand: () -> Void
    let keepWaiting: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("The device service is taking longer than expected.")
                .font(.headline)
            Text("NeoSimulator will keep waiting. To restart CoreDeviceService, run this command in Terminal. This briefly interrupts Xcode’s device connections.")
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: Self.recoveryCommand)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Spacer()
                Button("Keep Waiting", action: keepWaiting)
                    .keyboardShortcut(.cancelAction)
                Button("Copy Command", action: copyCommand)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}
