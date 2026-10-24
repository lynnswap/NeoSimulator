import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XcodeSimulatorHost

@MainActor
final class SimulatorManagerModel {
    private let controller: SimulatorHostController
    private(set) var status: SimulatorHostStatus?
    private(set) var inventory: [InventoryDevice] = []
    var devices: [SimulatorHostDevice] {
        inventory.compactMap { item in
            guard case .simulator(let device) = item, device.isAvailable else { return nil }
            return device
        }
    }
    private(set) var managingDeviceIDs: Set<DeviceInventoryID> = []
    private(set) var isBusy = false
    private(set) var activity = ""
    private(set) var backgroundIssue: String?
    private(set) var deviceSettings: SimulatorDeviceSettings?
    private(set) var settingsIssue: String?
    private(set) var inspectedDeviceIdentifier: String?
    private var inspectedState: String?
    private var settingsRefreshRequested = false
    private var inspectionGeneration = 0
    private var inspectionTask: Task<Void, Never>?
    var onChange: (() -> Void)?
    var onError: ((any Error) -> Void)?
    private var refreshing = false
    private var refreshWaiters: [CheckedContinuation<Void, Never>] = []
    private var synchronizing = false
    private var inventoryRefreshRequested = false
    private var stopping = false
    private var operationTask: Task<Void, Never>?
    private var managementTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingOperations: [(activity: String, refreshCatalog: Bool, run: @MainActor () async throws -> Void)] = []

    init(rendererApplicationURL: URL) {
        controller = SimulatorHostController(rendererApplicationURL: rendererApplicationURL)
    }

    func start() {
        perform("Loading devices…") {
            let status = try await self.controller.status()
            self.status = status
            if status.restorationAvailable { try await self.controller.selectHost(status.host) }
        }
    }

    func select(_ host: SimulatorHost) {
        perform("Switching simulator app…") { try await self.controller.selectHost(host) }
    }

    func openDevice(_ identifier: String) {
        perform("Opening simulator…") { try await self.controller.openDevice(identifier: identifier) }
    }

    func creationCatalog() async throws -> SimulatorCreationContext {
        try await controller.creationCatalog()
    }

    func createSimulator(named name: String, deviceType: String, runtime: String,
                         context: SimulatorCreationContext) async throws -> String {
        guard !stopping else { throw CancellationError() }
        let identifier = try await controller.createSimulator(named: name, deviceType: deviceType, runtime: runtime,
                                                               context: context)
        await refresh()
        return identifier
    }

    func pairSimulators(watch: String, phone: String, context: SimulatorCreationContext) async throws {
        guard !stopping else { throw CancellationError() }
        try await controller.pairSimulators(watch: watch, phone: phone, context: context)
        await refresh()
    }

    func manage(_ action: DeviceManagementAction, devices: [InventoryDevice]) {
        guard !stopping else { return }
        var identifiers = Set<DeviceInventoryID>()
        let targets = devices.filter { identifiers.insert($0.id).inserted }
        guard !targets.isEmpty, managingDeviceIDs.isDisjoint(with: identifiers) else { return }
        managingDeviceIDs.formUnion(identifiers)
        let request = UUID()
        managementTasks[request] = Task {
            defer {
                self.managingDeviceIDs.subtract(identifiers)
                self.managementTasks.removeValue(forKey: request)
                self.onChange?()
            }
            let report = await self.controller.manage(action, devices: targets)
            if !self.stopping { await self.refreshCatalog() }
            if report.results.contains(where: { $0.error != nil }) {
                self.onError?(DeviceManagementFailure(devices: targets, report: report))
            }
        }
        onChange?()
    }

    func restoreDefaults(force: Bool = false) {
        perform("Restoring original settings…") { try await self.controller.restore(force: force) }
    }

    func refresh() async {
        guard !stopping, !isBusy, !refreshing else { return }
        await refreshCatalog()
    }

    private func refreshCatalog() async {
        if refreshing { await withCheckedContinuation { refreshWaiters.append($0) } }
        else { refreshing = true }
        defer {
            settingsRefreshRequested = true
            onChange?()
            if refreshWaiters.isEmpty { refreshing = false }
            else { refreshWaiters.removeFirst().resume() }
        }
        repeat {
            inventoryRefreshRequested = false
            var statusError: (any Error)?
            do { status = try await controller.status() }
            catch { statusError = error }
            let snapshot = await controller.inventory()
            inventory = snapshot.devices
            if snapshot.issues.isEmpty, statusError == nil { backgroundIssue = nil }
            else {
                reportBackgroundError(InventoryReadError(issues: snapshot.issues, statusError: statusError))
            }
        } while inventoryRefreshRequested && !stopping
    }

    func inventoryDidChange() async {
        guard !stopping else { return }
        inventoryRefreshRequested = true
        await refresh()
    }

    func inventoryObservationFailed(_ error: any Error) {
        guard !stopping else { return }
        NSLog("NeoSimulator automatic device updates: %@", String(describing: error))
        backgroundIssue = "Automatic device updates are unavailable. Use Refresh to update the device list."
        onChange?()
    }

    func synchronizeConnections() async {
        guard !stopping, !synchronizing, !refreshing, !isBusy else { return }
        synchronizing = true
        defer { synchronizing = false }
        do {
            if try await controller.synchronizeXcodeConnections() { await refresh() }
        } catch {
            await refresh()
            reportBackgroundError(error)
            onChange?()
        }
    }

    func rendererDevicesDidChange(testingVisibilityChanged: Bool) async {
        guard !stopping else { return }
        if testingVisibilityChanged {
            do { try await controller.testingDeviceVisibilityDidChange() }
            catch {
                reportBackgroundError(error)
                onChange?()
            }
        }
        await refresh()
    }

    func inspectDevice(_ identifier: String?) async {
        guard !stopping else { return }
        let state = devices.first { $0.identifier == identifier }?.state
        if inspectedDeviceIdentifier != identifier || inspectedState != state {
            inspectedDeviceIdentifier = identifier
            inspectedState = state
            inspectionGeneration += 1
            settingsRefreshRequested = true
            deviceSettings = nil
            settingsIssue = nil
            onChange?()
        }
        guard identifier != nil else { settingsRefreshRequested = false; return }
        if let inspectionTask { await inspectionTask.value; return }
        guard settingsRefreshRequested else { return }
        inspectionTask = Task {
            defer { self.inspectionTask = nil }
            while !self.stopping, !Task.isCancelled, self.settingsRefreshRequested,
                  let identifier = self.inspectedDeviceIdentifier {
                self.settingsRefreshRequested = false
                let generation = self.inspectionGeneration
                do {
                    let settings = try await self.controller.deviceSettings(identifier: identifier)
                    guard !self.stopping, !Task.isCancelled, self.inspectionGeneration == generation else { continue }
                    self.deviceSettings = settings
                    self.settingsIssue = nil
                    if !settings.issues.isEmpty {
                        NSLog("NeoSimulator settings: %@", settings.issues.joined(separator: "\n"))
                    }
                } catch {
                    guard !self.stopping, !Task.isCancelled, self.inspectionGeneration == generation else { continue }
                    self.settingsIssue = error.localizedDescription
                    NSLog("NeoSimulator settings: %@", (error as? SimulatorHostFailure)?.technicalDetails ?? String(describing: error))
                }
                self.onChange?()
            }
        }
        await inspectionTask?.value
    }

    private func refreshInspectedSettings(for identifier: String) async {
        guard !stopping, inspectedDeviceIdentifier == identifier else { return }
        inspectionGeneration += 1
        settingsRefreshRequested = true
        await inspectDevice(identifier)
    }

    func setAppearance(_ value: String, for identifier: String) { set(.appearance(value), identifier: identifier) }
    func setContentSize(_ value: String, for identifier: String) { set(.contentSize(value), identifier: identifier) }
    func setIncreaseContrast(_ enabled: Bool, for identifier: String) { set(.increaseContrast(enabled), identifier: identifier) }
    func setLocation(latitude: Double, longitude: Double, for identifier: String) {
        set(.location(latitude: latitude, longitude: longitude), identifier: identifier)
    }
    func clearLocation(for identifier: String) { set(.clearLocation, identifier: identifier) }

    func setDeviceSetting(_ setting: SimulatorDeviceSetting, for identifier: String) {
        set(setting, identifier: identifier)
    }

    private func set(_ setting: SimulatorDeviceSetting, identifier: String) {
        guard !managingDeviceIDs.contains(where: { id in
            if case .simulator(let udid, _) = id { return udid == identifier }
            return false
        }) else { return }
        perform("Updating simulator settings…", refreshCatalog: false) {
            do { try await self.controller.setDeviceSetting(setting, identifier: identifier) }
            catch {
                await self.refreshInspectedSettings(for: identifier)
                throw error
            }
            await self.refreshInspectedSettings(for: identifier)
        }
    }

    func quitRenderer(keepingDevicesRunning: Bool?) async throws {
        stopping = true
        pendingOperations.removeAll { $0.refreshCatalog }
        inspectionTask?.cancel()
        await operationTask?.value
        for task in Array(managementTasks.values) { await task.value }
        do { try await controller.quitRenderer(keepingDevicesRunning: keepingDevicesRunning) }
        catch { stopping = false; throw error }
    }

    private func reportBackgroundError(_ error: any Error) {
        let message = error.localizedDescription
        if backgroundIssue != message {
            NSLog("NeoSimulator: %@", (error as? SimulatorHostFailure)?.technicalDetails ?? String(describing: error))
        }
        backgroundIssue = message
    }

    private func perform(_ activity: String, refreshCatalog: Bool = true,
                         operation: @escaping @MainActor () async throws -> Void) {
        guard !stopping else { return }
        pendingOperations.append((activity, refreshCatalog, operation))
        if refreshCatalog { isBusy = true }
        guard operationTask == nil else { onChange?(); return }
        operationTask = Task {
            defer {
                self.operationTask = nil
                self.isBusy = false
                self.activity = ""
                self.onChange?()
            }
            while !self.pendingOperations.isEmpty {
                let next = self.pendingOperations.removeFirst()
                self.isBusy = next.refreshCatalog || self.pendingOperations.contains { $0.refreshCatalog }
                self.activity = next.activity
                self.onChange?()
                var failure: (any Error)?
                do { try await next.run() }
                catch { failure = error }
                if (next.refreshCatalog || self.inventoryRefreshRequested), !self.stopping { await self.refreshCatalog() }
                if let failure { self.onError?(failure) }
            }
        }
    }

}

private struct InventoryReadError: LocalizedError {
    let issues: [DeviceInventoryIssue]
    let statusError: (any Error)?

    var errorDescription: String? {
        let messages = issues.map { issue in
            let source: String = switch issue.source {
            case .coreDevice: "Devices"
            case .rendererOwnership: "Open Screens"
            case .simulators(let xcode, _): xcode?.deletingPathExtension().lastPathComponent ?? "Simulators"
            }
            return "\(source): \(issue.error.localizedDescription)"
        }
        return (messages + [statusError?.localizedDescription].compactMap { $0 }).joined(separator: "\n")
    }
}

private struct DeviceManagementFailure: LocalizedError {
    let devices: [InventoryDevice]
    let report: DeviceManagementReport

    var errorDescription: String? { "Some device operations could not be completed." }

    var recoverySuggestion: String? {
        report.results.compactMap { result -> String? in
            guard let error = result.error else { return nil }
            let name = devices.first { $0.id == result.deviceID }?.name ?? "Device"
            let completed = result.completedSteps.isEmpty ? "" : "\nCompleted: \(result.completedSteps.joined(separator: ", "))."
            return "\(name): \(error.localizedDescription)\(completed)"
        }.joined(separator: "\n\n")
    }
}

@MainActor
private final class SimulatorDevicesMenu: NSMenu, NSMenuDelegate {
    private let model: SimulatorManagerModel

    init(model: SimulatorManagerModel, title: String) {
        self.model = model
        super.init(title: title)
        delegate = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.items = SimulatorDeviceMenu.items(for: model.devices.map { device in
            let state: UInt = switch device.state {
            case "Booted": 3
            case "Booting": 2
            case "Shutdown": 1
            case "Shutting Down": 4
            default: 0
            }
            return SimulatorMenuDevice(identifier: device.identifier, name: device.name,
                descriptiveName: device.descriptiveName, runtimeIdentifier: device.runtimeIdentifier,
                runtimeName: device.runtimeName, state: state)
        }, hasWindow: { identifier in model.devices.first { $0.identifier == identifier }?.ownerXcodeURL != nil },
           action: #selector(openDevice(_:)), target: self)
        if menu.items.isEmpty {
            let item = NSMenuItem(title: model.isBusy ? model.activity : "No Simulators", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
    }

    @objc private func openDevice(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String else { return }
        model.openDevice(identifier)
    }
}

@MainActor
private final class SelectedDeviceMenu: NSMenu, NSMenuDelegate {
    private let actions: () -> NSMenu?

    init(actions: @escaping () -> NSMenu?) {
        self.actions = actions
        super.init(title: "Device")
        delegate = self
        autoenablesItems = false
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func menuNeedsUpdate(_ menu: NSMenu) {
        removeAllItems()
        if let source = actions() {
            let items = source.items
            source.removeAllItems()
            for item in items { addItem(item) }
        }
        if items.isEmpty {
            let item = NSMenuItem(title: "Select a Device", action: nil, keyEquivalent: "")
            item.isEnabled = false
            addItem(item)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let rendererURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Applications/NeoSimulatorRenderer.app")
    private lazy var model = SimulatorManagerModel(rendererApplicationURL: rendererURL)
    private var mainWindow: ManagerWindowController?
    private var settingsWindow: SettingsWindowController?
    private var newSimulatorWindow: NewSimulatorWindowController?
    private var preparingNewSimulator: Task<Void, Never>?
    private var quitting = false
    private var rendererDevicesObserver: NSObjectProtocol?
    private var workspaceObserver: NSObjectProtocol?
    private var connectionTimer: Timer?
    private var inventoryObservation: DeviceInventoryObservation?
    private var inventoryObservationTask: Task<Void, Never>?
    private var quitKeepingDevicesRunning: Bool?

    func applicationDidFinishLaunching(_ notification: Notification) {
        SimulatorPreferences.migrateStandalonePreferences()
        installMenu()
        model.onChange = { [weak self] in self?.mainWindow?.update(); self?.settingsWindow?.update() }
        model.onError = { [weak self] error in self?.present(error) }
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
        Task {
            do {
                inventoryObservationTask?.cancel()
                await inventoryObservation?.stop()
                await inventoryObservationTask?.value
                inventoryObservation = nil
                try await model.quitRenderer(keepingDevicesRunning: quitKeepingDevicesRunning)
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                quitting = false
                startInventoryObservation()
                present(error)
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
                model.openDevice(identifier)
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

    @objc private func showDevices(_ sender: Any?) {
        if mainWindow == nil { mainWindow = ManagerWindowController(model: model) }
        mainWindow?.showWindow(nil)
        mainWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @objc private func showSettings(_ sender: Any?) {
        if settingsWindow == nil { settingsWindow = SettingsWindowController(model: model) }
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @objc func showNewSimulator(_ sender: Any?) {
        guard !quitting else { return }
        if let newSimulatorWindow {
            newSimulatorWindow.showWindow(nil)
            newSimulatorWindow.window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        guard preparingNewSimulator == nil else { return }
        preparingNewSimulator = Task { [weak self] in
            guard let self else { return }
            defer { self.preparingNewSimulator = nil }
            do {
                let context = try await self.model.creationCatalog()
                let snapshot = try JSONDecoder().decode(SimulatorCatalog.Snapshot.self, from: context.data)
                guard !self.quitting else { return }
                let form = NewSimulatorWindowController(catalog: snapshot.catalog(), create: { [model = self.model] name, type, runtime in
                    try await model.createSimulator(named: name, deviceType: type, runtime: runtime, context: context)
                }, pair: { [model = self.model] watch, phone in
                    try await model.pairSimulators(watch: watch, phone: phone, context: context)
                }, onClose: { [weak self] in
                    self?.newSimulatorWindow = nil
                })
                self.newSimulatorWindow = form
                form.showWindow(nil)
                form.window?.makeKeyAndOrderFront(nil)
                NSApp.activate()
            } catch { self.present(error) }
        }
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
        alert.informativeText = (error as? any LocalizedError)?.recoverySuggestion ?? ""
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
        addItem("Close Window", action: #selector(NSWindow.performClose(_:)), key: "w", to: file).target = nil
        let edit = addSubmenu("Edit", to: main)
        addItem("Undo", action: Selector("undo:"), key: "z", to: edit).target = nil
        let redo = addItem("Redo", action: Selector("redo:"), key: "z", to: edit)
        redo.target = nil
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        for (title, selector, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            addItem(title, action: Selector(selector), key: key, to: edit).target = nil
        }
        let device = NSMenuItem(title: "Device", action: nil, keyEquivalent: "")
        device.submenu = SelectedDeviceMenu { [weak self] in self?.mainWindow?.menuForSelectedDevices() }
        main.addItem(device)
        let view = addSubmenu("View", to: main)
        addItem("Show Devices", action: #selector(showDevices(_:)), to: view)
        let window = addSubmenu("Window", to: main)
        addItem("Minimize", action: #selector(NSWindow.performMiniaturize(_:)), key: "m", to: window).target = nil
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

@main
enum NeoSimulatorApplication {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}


@MainActor
final class ManagerWindowController: NSWindowController, NSOutlineViewDataSource, NSOutlineViewDelegate,
                                     NSSearchFieldDelegate, NSToolbarDelegate, NSMenuDelegate {
    private let model: SimulatorManagerModel
    private let splitController = NSSplitViewController()
    private let table = NSOutlineView()
    private let search = NSSearchField()
    private let deviceImage = NSImageView()
    private let deviceName = NSTextField(labelWithString: "Select a Device")
    private let deviceRuntime = NSTextField(labelWithString: "")
    private let viewScreen = NSButton(title: "View Screen", target: nil, action: nil)
    private let activity = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private var inspectorHost: NSHostingController<AnyView>?
    private var updatingSelection = false
    private var rows: [DeviceRow] = []
    private var selectedIdentifiers = Set<DeviceInventoryID>()
    private let availableGroup = AvailabilityGroup(available: true)
    private let unavailableGroup = AvailabilityGroup(available: false)
    private var expandedGroups: Set<Bool> = [true, false]
    private var loadedRows = false
    private var groupByAvailability = true
    private let deviceMenu = NSMenu(title: "Device Actions")
    private var refreshItem: NSToolbarItem?
    private let refreshIdentifier = NSToolbarItem.Identifier("RefreshSimulators")
    private let newSimulatorIdentifier = NSToolbarItem.Identifier("NewSimulator")
    private let filterIdentifier = NSToolbarItem.Identifier("FilterSimulators")
    private var filterItem: NSMenuToolbarItem?
    private var kindFilter = DeviceKindFilter.all
    private var availabilityFilter = DeviceAvailabilityFilter.all
    private var familyFilter: String?
    private var sortOrder = DeviceSortOrder.name

    private final class DeviceRow: NSObject {
        let id: DeviceInventoryID
        init(id: DeviceInventoryID) { self.id = id }
    }

    private final class AvailabilityGroup: NSObject {
        let available: Bool
        var title: String { available ? "Available" : "Unavailable" }
        init(available: Bool) { self.available = available }
    }

    private enum DeviceKindFilter: Int, CaseIterable {
        case all, simulators, physical, virtualMachines

        var title: String {
            switch self {
            case .all: "All Devices"
            case .simulators: "Simulators"
            case .physical: "Physical Devices"
            case .virtualMachines: "Virtual Machines"
            }
        }

        func includes(_ device: InventoryDevice) -> Bool {
            switch self {
            case .all: true
            case .simulators: device.kind == .simulator
            case .physical: device.kind == .physical
            case .virtualMachines: device.kind == .virtualMachine
            }
        }
    }

    private enum DeviceAvailabilityFilter: Int, CaseIterable {
        case all, available, unavailable

        var title: String {
            switch self {
            case .all: "All Availability"
            case .available: "Available"
            case .unavailable: "Unavailable"
            }
        }

        func includes(_ device: InventoryDevice) -> Bool {
            switch self {
            case .all: true
            case .available: device.isAvailable
            case .unavailable: !device.isAvailable
            }
        }
    }

    private enum DeviceSortOrder: Int, CaseIterable {
        case availability, recent, name, fidelity, platform, operatingSystem

        var title: String {
            switch self {
            case .availability: "Availability"
            case .recent: "Recent"
            case .name: "Name"
            case .fidelity: "Fidelity"
            case .platform: "Platform"
            case .operatingSystem: "Operating System"
            }
        }
    }

    init(model: SimulatorManagerModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "NeoSimulator"
        window.minSize = NSSize(width: 800, height: 480)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        super.init(window: window)
        buildSidebar()
        buildDevicePane()
        buildInspector()
        window.contentViewController = splitController
        let toolbar = NSToolbar(identifier: "NeoSimulatorDevices")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.center()
        window.setFrameAutosaveName("NeoSimulatorDevices")
        update()
    }

    required init?(coder: NSCoder) { nil }

    func update() {
        selectedIdentifiers.formIntersection(Set(model.inventory.map(\.id)))
        if groupByAvailability, loadedRows {
            for group in availabilityGroups where table.row(forItem: group) >= 0 {
                if table.isItemExpanded(group) { expandedGroups.insert(group.available) }
                else { expandedGroups.remove(group.available) }
            }
        }
        rows = filteredDevices.map { DeviceRow(id: $0.id) }
        updatingSelection = true
        table.reloadData()
        if groupByAvailability {
            for group in availabilityGroups where expandedGroups.contains(group.available) { table.expandItem(group) }
        }
        restoreVisibleSelection()
        updatingSelection = false
        loadedRows = true
        updateSelection()
        updateFilterItem()
        refreshItem?.isEnabled = !model.isBusy
        activity.stringValue = model.isBusy ? model.activity : (model.backgroundIssue ?? "")
        activity.toolTip = activity.stringValue
        activity.isHidden = activity.stringValue.isEmpty
        progress.isHidden = !model.isBusy
        if model.isBusy { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
    }

    private var filteredDevices: [InventoryDevice] {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.inventory.filter {
            kindFilter.includes($0) && availabilityFilter.includes($0)
                && (familyFilter == nil || family(of: $0) == familyFilter)
                && (query.isEmpty || $0.name.localizedStandardContains(query)
                    || ($0.operatingSystem?.localizedStandardContains(query) ?? false)
                    || (modelName(of: $0)?.localizedStandardContains(query) ?? false))
        }.sorted(by: precedes)
    }

    private func precedes(_ lhs: InventoryDevice, _ rhs: InventoryDevice) -> Bool {
        switch sortOrder {
        case .availability:
            if lhs.isAvailable != rhs.isAvailable { return lhs.isAvailable }
        case .recent:
            let a = lhs.lastActivityDate ?? .distantPast, b = rhs.lastActivityDate ?? .distantPast
            if a != b { return a > b }
        case .fidelity:
            let a = fidelity(of: lhs), b = fidelity(of: rhs)
            if a != b { return a < b }
        case .platform:
            let order = platform(of: lhs).localizedStandardCompare(platform(of: rhs))
            if order != .orderedSame { return order == .orderedAscending }
        case .operatingSystem:
            let order = (lhs.operatingSystem ?? "").compare(rhs.operatingSystem ?? "", options: .numeric)
            if order != .orderedSame { return order == .orderedDescending }
        case .name: break
        }
        let names = lhs.name.localizedStandardCompare(rhs.name)
        if names != .orderedSame { return names == .orderedAscending }
        let versions = version(of: lhs).compare(version(of: rhs), options: .numeric)
        if versions != .orderedSame { return versions == .orderedDescending }
        return stableKey(lhs.id) < stableKey(rhs.id)
    }

    private var availabilityGroups: [AvailabilityGroup] {
        [availableGroup, unavailableGroup].filter { group in
            switch availabilityFilter {
            case .all: true
            case .available: group.available
            case .unavailable: !group.available
            }
        }
    }

    private func device(for row: DeviceRow) -> InventoryDevice? { model.inventory.first { $0.id == row.id } }

    private func children(of group: AvailabilityGroup) -> [DeviceRow] {
        rows.filter { device(for: $0)?.isAvailable == group.available }
    }

    private func restoreVisibleSelection() {
        let indexes = IndexSet((0..<table.numberOfRows).filter { index in
            (table.item(atRow: index) as? DeviceRow).map { selectedIdentifiers.contains($0.id) } ?? false
        })
        table.selectRowIndexes(indexes, byExtendingSelection: false)
    }

    private func buildSidebar() {
        let controller = NSViewController()
        search.placeholderString = "Search Devices"
        search.delegate = self
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Device"))
        table.addTableColumn(column)
        table.outlineTableColumn = column
        table.headerView = nil
        table.style = .sourceList
        table.rowHeight = 52
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.backgroundColor = .clear
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelectedDevice(_:))
        table.setAccessibilityLabel("Devices")
        deviceMenu.delegate = self
        deviceMenu.autoenablesItems = false
        table.menu = deviceMenu
        scroll.documentView = table
        controller.view = scroll
        let sidebar = NSSplitViewItem(sidebarWithViewController: controller)
        sidebar.minimumThickness = 260
        sidebar.maximumThickness = 360
        sidebar.preferredThicknessFraction = 0.26
        let searchAccessory = NSSplitViewItemAccessoryViewController()
        searchAccessory.automaticallyAppliesContentInsets = false
        searchAccessory.preferredScrollEdgeEffectStyle = .soft
        let searchContainer = NSStackView(views: [search])
        searchContainer.orientation = .vertical
        searchContainer.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        search.widthAnchor.constraint(equalTo: searchContainer.widthAnchor, constant: -24).isActive = true
        searchContainer.frame.size = NSSize(width: 260, height: search.fittingSize.height + 20)
        searchAccessory.view = searchContainer
        sidebar.addTopAlignedAccessoryViewController(searchAccessory)
        splitController.addSplitViewItem(sidebar)
    }

    private func buildDevicePane() {
        let controller = NSViewController()
        let view = NSView()
        controller.view = view
        deviceImage.imageScaling = .scaleProportionallyUpOrDown
        deviceImage.translatesAutoresizingMaskIntoConstraints = false
        deviceImage.setAccessibilityHidden(true)
        deviceName.font = .systemFont(ofSize: 17, weight: .semibold)
        deviceName.alignment = .center
        deviceName.lineBreakMode = .byTruncatingTail
        deviceRuntime.font = .systemFont(ofSize: 13)
        deviceRuntime.textColor = .secondaryLabelColor
        deviceRuntime.alignment = .center
        deviceRuntime.lineBreakMode = .byTruncatingTail
        viewScreen.bezelStyle = .rounded
        viewScreen.controlSize = .large
        viewScreen.image = NSImage(systemSymbolName: "rectangle.badge.person.crop", accessibilityDescription: nil)
        viewScreen.imagePosition = .imageLeading
        viewScreen.target = self
        viewScreen.action = #selector(openSelectedDevice(_:))
        viewScreen.keyEquivalent = "\r"
        let stack = NSStackView(views: [deviceImage, deviceName, deviceRuntime, viewScreen])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(24, after: deviceImage)
        stack.setCustomSpacing(20, after: deviceRuntime)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        activity.font = .systemFont(ofSize: 12)
        activity.textColor = .secondaryLabelColor
        activity.lineBreakMode = .byTruncatingTail
        let activityStack = NSStackView(views: [progress, activity])
        activityStack.orientation = .horizontal
        activityStack.alignment = .centerY
        activityStack.spacing = 7
        activityStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(activityStack)
        NSLayoutConstraint.activate([
            deviceImage.widthAnchor.constraint(equalToConstant: 192),
            deviceImage.heightAnchor.constraint(equalToConstant: 192),
            viewScreen.widthAnchor.constraint(greaterThanOrEqualToConstant: 112),
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -24),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
            deviceName.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            deviceRuntime.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            activityStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -22),
            activityStack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 12),
            activityStack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -12),
        ])
        let content = NSSplitViewItem(viewController: controller)
        content.minimumThickness = 280
        content.holdingPriority = .defaultLow
        splitController.addSplitViewItem(content)
    }

    private func buildInspector() {
        let host = NSHostingController(rootView: makeDeviceSettingsView())
        inspectorHost = host
        let inspector = NSSplitViewItem(inspectorWithViewController: host)
        inspector.minimumThickness = 280
        inspector.maximumThickness = 360
        inspector.canCollapse = false
        splitController.addSplitViewItem(inspector)
    }

    private func makeDeviceSettingsView() -> AnyView {
        guard selectedDevices.count == 1, let selection = selectedDevices.first else {
            return inspectorMessage(selectedDevices.isEmpty ? "Select a Device" : "Multiple Devices Selected",
                                    description: "Select one simulator to adjust its settings.")
        }
        guard case .simulator(let device) = selection else {
            return inspectorMessage("Settings Unavailable", description:
                "This inspector currently supports simulator settings. Settings for \(kindTitle(selection).lowercased()) devices are not supported yet.")
        }
        guard device.isAvailable else {
            return inspectorMessage("Simulator Unavailable", description:
                "The simulator’s runtime is unavailable. Install a compatible runtime to use its settings.")
        }
        guard !isSimulatorRouteAmbiguous(device) else {
            return inspectorMessage("Simulator Identifier Is Ambiguous", description:
                "More than one simulator set contains this device identifier. Screen and settings access cannot distinguish the selected device yet.")
        }
        let inspectingSelection = model.inspectedDeviceIdentifier == device.identifier
        return AnyView(ManagerDeviceSettingsView(device: device,
            settings: inspectingSelection ? model.deviceSettings : nil,
            isBusy: model.isBusy || model.managingDeviceIDs.contains(selection.id),
            issue: inspectingSelection ? model.settingsIssue : nil, apply: { [weak self] setting in
                self?.model.setDeviceSetting(setting, for: device.identifier)
            }, customLocation: { [weak self] in
                self?.presentLocationEditor(for: device.identifier)
            }))
    }

    private func inspectorMessage(_ title: String, description: String) -> AnyView {
        AnyView(ContentUnavailableView(title, systemImage: "slider.horizontal.3", description: Text(description)))
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let group = item as? AvailabilityGroup { return children(of: group).count }
        return item == nil ? (groupByAvailability ? availabilityGroups.count : rows.count) : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let group = item as? AvailabilityGroup { return children(of: group)[index] }
        return groupByAvailability ? availabilityGroups[index] as Any : rows[index] as Any
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { item is AvailabilityGroup }
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { item is AvailabilityGroup }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { item is DeviceRow }
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        item is AvailabilityGroup ? 26 : 52
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let group = item as? AvailabilityGroup {
            let identifier = NSUserInterfaceItemIdentifier("DeviceAvailabilityGroup")
            let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
            cell.identifier = identifier
            if cell.textField == nil {
                let label = NSTextField(labelWithString: "")
                label.font = .systemFont(ofSize: 11, weight: .semibold)
                label.textColor = .secondaryLabelColor
                label.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(label)
                cell.textField = label
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
                    label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }
            cell.textField?.stringValue = group.title
            return cell
        }
        guard let row = item as? DeviceRow, let device = device(for: row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("DeviceRow")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? SimulatorSidebarCellView
            ?? SimulatorSidebarCellView()
        cell.identifier = identifier
        cell.textField?.stringValue = device.name
        cell.subtitle.stringValue = device.kind == .simulator ? "Simulator" : (modelName(of: device) ?? "")
        cell.subtitle.isHidden = cell.subtitle.stringValue.isEmpty
        cell.version.stringValue = version(of: device)
        cell.imageView?.image = NSImage(systemSymbolName: symbolName(for: device), accessibilityDescription: nil)
        let managing = model.managingDeviceIDs.contains(device.id)
        cell.progress.isHidden = !managing
        if managing { cell.progress.startAnimation(nil) } else { cell.progress.stopAnimation(nil) }
        cell.alphaValue = device.isAvailable ? 1 : 0.6
        cell.setAccessibilityLabel("\(device.name), \(device.operatingSystem ?? kindTitle(device)), \(device.isAvailable ? "Available" : "Unavailable")")
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !updatingSelection else { return }
        selectedIdentifiers = Set(table.selectedRowIndexes.compactMap { (table.item(atRow: $0) as? DeviceRow)?.id })
        updateSelection()
    }

    func controlTextDidChange(_ notification: Notification) { update() }

    private var selectedDevices: [InventoryDevice] {
        let visibleSelection = Set(table.selectedRowIndexes.compactMap { (table.item(atRow: $0) as? DeviceRow)?.id })
        return model.inventory.filter { visibleSelection.contains($0.id) }.sorted(by: precedes)
    }

    private var selectedSimulator: SimulatorHostDevice? {
        guard selectedDevices.count == 1, case .simulator(let device) = selectedDevices[0] else { return nil }
        return device
    }

    private func updateSelection() {
        let selections = selectedDevices
        if selections.count == 1, let device = selections.first {
            deviceName.stringValue = device.name
            if case .simulator(let simulator) = device { deviceRuntime.stringValue = "\(simulator.runtimeName) Simulator" }
            else {
                deviceRuntime.stringValue = [device.operatingSystem, modelName(of: device), kindTitle(device)]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            }
            deviceImage.image = devicePreview(for: device)
        } else if selections.isEmpty {
            deviceName.stringValue = "Select a Device"
            deviceRuntime.stringValue = "Choose a device in the sidebar to view its details."
            deviceImage.image = nil
        } else {
            deviceName.stringValue = "\(selections.count) Devices"
            deviceRuntime.stringValue = "Select one device to view its details."
            deviceImage.image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: nil)
        }
        deviceImage.contentTintColor = nil
        let simulator = selectedSimulator
        viewScreen.isHidden = simulator == nil
        viewScreen.isEnabled = !model.isBusy && simulator.map {
            $0.isAvailable && !isSimulatorRouteAmbiguous($0) && ["Booted", "Shutdown"].contains($0.state)
                && !model.managingDeviceIDs.contains(.simulator(udid: $0.identifier, deviceSetPath: $0.deviceSetPath))
        } == true
        viewScreen.toolTip = simulator.map { isSimulatorRouteAmbiguous($0) } == true
            ? "Screen access cannot distinguish simulators with the same identifier in different sets." : nil
        updateDeviceSettings()
        Task { [weak self] in
            guard let self else { return }
            let identifier = self.selectedSimulator.flatMap {
                $0.isAvailable && !self.isSimulatorRouteAmbiguous($0) ? $0.identifier : nil
            }
            await self.model.inspectDevice(identifier)
        }
    }

    private func updateDeviceSettings() {
        inspectorHost?.rootView = makeDeviceSettingsView()
    }

    private func presentLocationEditor(for identifier: String, latitude: String = "0", longitude: String = "0") {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Set Location"
        alert.informativeText = "Enter a latitude and longitude for the selected simulator."
        alert.addButton(withTitle: "Set Location")
        alert.addButton(withTitle: "Cancel")
        let latitudeField = NSTextField(string: latitude)
        let longitudeField = NSTextField(string: longitude)
        for field in [latitudeField, longitudeField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 190).isActive = true
        }
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Latitude:"), latitudeField],
            [NSTextField(labelWithString: "Longitude:"), longitudeField],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing
        grid.frame.size = grid.fittingSize
        alert.accessoryView = grid
        alert.window.initialFirstResponder = latitudeField
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            guard let latitude = Double(latitudeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let longitude = Double(longitudeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
                  (-90...90).contains(latitude), (-180...180).contains(longitude) else {
                let invalid = NSAlert()
                invalid.messageText = "Enter valid coordinates."
                invalid.informativeText = "Latitude must be between −90 and 90. Longitude must be between −180 and 180."
                invalid.runModal()
                self.presentLocationEditor(for: identifier, latitude: latitudeField.stringValue, longitude: longitudeField.stringValue)
                return
            }
            self.model.setLocation(latitude: latitude, longitude: longitude, for: identifier)
        }
    }

    private func devicePreview(for device: InventoryDevice) -> NSImage? {
        if let modelIdentifier = device.modelIdentifier,
           let type = UTType.types(tag: modelIdentifier,
                                   tagClass: UTTagClass(rawValue: "com.apple.device-model-code"),
                                   conformingTo: nil).first(where: \.isDeclared) {
            return NSWorkspace.shared.icon(for: type)
        }
        return NSImage(systemSymbolName: symbolName(for: device), accessibilityDescription: nil)
    }

    private func modelName(of device: InventoryDevice) -> String? {
        if case .remote(let remote) = device { return remote.modelName }
        return nil
    }

    private func family(of device: InventoryDevice) -> String {
        if case .simulator(let simulator) = device { return simulator.productFamily }
        let identifier = device.modelIdentifier ?? ""
        if identifier.hasPrefix("iPad") { return "iPad" }
        if identifier.hasPrefix("iPhone") { return "iPhone" }
        if identifier.hasPrefix("Watch") { return "Apple Watch" }
        if identifier.hasPrefix("AppleTV") { return "Apple TV" }
        if identifier.hasPrefix("Reality") { return "Apple Vision" }
        if platform(of: device).localizedCaseInsensitiveContains("mac") { return "Mac" }
        return platform(of: device).isEmpty ? "Other" : platform(of: device)
    }

    private func symbolName(for device: InventoryDevice) -> String {
        switch family(of: device) {
        case "iPad": "ipad"
        case "Apple TV": "appletv"
        case "Apple Watch": "applewatch"
        case "Apple Vision", "visionOS": "visionpro"
        case "Mac": "desktopcomputer"
        case "iPhone": "iphone"
        default: device.kind == .virtualMachine ? "desktopcomputer" : "externaldrive"
        }
    }

    private func platform(of device: InventoryDevice) -> String {
        switch device {
        case .simulator(let simulator): simulator.runtimeName.split(separator: " ").first.map(String.init) ?? ""
        case .remote(let remote): remote.platform ?? ""
        }
    }

    private func version(of device: InventoryDevice) -> String {
        switch device {
        case .simulator(let simulator):
            simulator.runtimeName.split(separator: " ").first { $0.first?.isNumber == true }.map(String.init) ?? ""
        case .remote(let remote): remote.osVersion ?? ""
        }
    }

    private func kindTitle(_ device: InventoryDevice) -> String {
        switch device.kind {
        case .simulator: "Simulator"
        case .physical: "Physical"
        case .virtualMachine: "Virtual Machine"
        case .other: "Other"
        }
    }

    private func fidelity(of device: InventoryDevice) -> Int {
        switch device.kind {
        case .physical: 0
        case .virtualMachine: 1
        case .simulator: 2
        case .other: 3
        }
    }

    private func stableKey(_ identifier: DeviceInventoryID) -> String {
        switch identifier {
        case .simulator(let udid, let path): "simulator:\(udid):\(path.map { "set:\($0)" } ?? "default")"
        case .coreDevice(let identifier): "coredevice:\(identifier)"
        }
    }

    private func isSimulatorRouteAmbiguous(_ device: SimulatorHostDevice) -> Bool {
        let paths = model.inventory.compactMap { item -> SimulatorHostDevice? in
            guard case .simulator(let simulator) = item, simulator.identifier == device.identifier else { return nil }
            return simulator
        }.map(\.deviceSetPath)
        return Set(paths).count > 1
    }

    @objc private func openSelectedDevice(_ sender: Any?) {
        guard let device = selectedSimulator, device.isAvailable, !isSimulatorRouteAmbiguous(device), !model.isBusy,
              !model.managingDeviceIDs.contains(.simulator(udid: device.identifier, deviceSetPath: device.deviceSetPath)),
              ["Booted", "Shutdown"].contains(device.state) else { return }
        model.openDevice(device.identifier)
    }

    @objc private func refresh(_ sender: Any?) { Task { await model.refresh() } }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .flexibleSpace, newSimulatorIdentifier, filterIdentifier, .sidebarTrackingSeparator,
         .flexibleSpace, refreshIdentifier, .inspectorTrackingSeparator]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if itemIdentifier == newSimulatorIdentifier {
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "New Simulator"
            item.toolTip = "New Simulator"
            item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Simulator")
            item.target = NSApp.delegate
            item.action = #selector(AppDelegate.showNewSimulator(_:))
            item.visibilityPriority = .high
            return item
        }
        if itemIdentifier == filterIdentifier {
            let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Filter"
            item.toolTip = "Filter and Sort Devices"
            item.showsIndicator = false
            item.visibilityPriority = .high
            item.menu = NSMenu(title: "Filter and Sort Devices")
            item.menu.delegate = self
            filterItem = item
            updateFilterItem()
            return item
        }
        guard itemIdentifier == refreshIdentifier else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = "Refresh"
        item.toolTip = "Refresh Devices"
        item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
        item.target = self
        item.action = #selector(refresh(_:))
        item.autovalidates = false
        item.isEnabled = !model.isBusy
        refreshItem = item
        return item
    }

    private struct ManagementRequest {
        let action: DeviceManagementAction
        let identifiers: Set<DeviceInventoryID>
    }

    func menuForSelectedDevices() -> NSMenu {
        let menu = NSMenu(title: "Device")
        menu.autoenablesItems = false
        populateDeviceMenu(menu, devices: selectedDevices)
        return menu
    }

    private func updateDeviceMenu() {
        if table.clickedRow >= 0 {
            guard let row = table.item(atRow: table.clickedRow) as? DeviceRow else {
                deviceMenu.removeAllItems()
                return
            }
            if !selectedIdentifiers.contains(row.id) {
                selectedIdentifiers = [row.id]
                updatingSelection = true
                restoreVisibleSelection()
                updatingSelection = false
                updateSelection()
            }
        }
        populateDeviceMenu(deviceMenu, devices: selectedDevices)
    }

    private func populateDeviceMenu(_ menu: NSMenu, devices: [InventoryDevice]) {
        menu.removeAllItems()
        let identifiers = Set(devices.map(\.id))
        let idle = !model.isBusy && identifiers.isDisjoint(with: model.managingDeviceIDs)
        if devices.count == 1, case .simulator(let simulator) = devices[0], simulator.isAvailable,
           !isSimulatorRouteAmbiguous(simulator),
           ["Booted", "Shutdown"].contains(simulator.state) {
            let item = NSMenuItem(title: "View Screen", action: #selector(openDeviceFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = devices[0].id
            item.isEnabled = idle
            menu.addItem(item)
        }
        let name = devices.first?.name ?? ""
        let operations: [(String, DeviceManagementAction)] = [
            ("Rename…", .rename(name)), ("Clone…", .clone("\(name) Copy")),
            ("Start", .start), ("Shut Down", .shutdown), ("Restart", .restart),
            ("Pause", .pause), ("Resume", .resume),
            ("Pair Simulators", .pair), ("Unpair", .unpair),
            ("Erase Content and Settings…", .erase), ("Remove…", .remove),
        ]
        for (title, action) in operations where supports(action, devices: devices) {
            if !menu.items.isEmpty, case .rename = action { menu.addItem(.separator()) }
            if case .erase = action, !menu.items.isEmpty { menu.addItem(.separator()) }
            let item = NSMenuItem(title: title, action: #selector(performManagement(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ManagementRequest(action: action, identifiers: identifiers)
            item.isEnabled = idle
            menu.addItem(item)
        }
        if menu.items.isEmpty {
            let item = NSMenuItem(title: devices.isEmpty ? "No Devices Selected" : "No Actions Available", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
    }

    private func supports(_ action: DeviceManagementAction, devices: [InventoryDevice]) -> Bool {
        guard !devices.isEmpty, devices.allSatisfy({ $0.supports(action) }) else { return false }
        switch action {
        case .rename, .clone: return devices.count == 1
        case .pair:
            guard devices.count == 2,
                  case .simulator(let first) = devices[0], case .simulator(let second) = devices[1] else { return false }
            return Set([first.productFamily, second.productFamily]) == Set(["iPhone", "Apple Watch"])
                && first.deviceSetPath == second.deviceSetPath
        default: return true
        }
    }

    @objc private func openDeviceFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? DeviceInventoryID,
              let item = model.inventory.first(where: { $0.id == id }),
              case .simulator(let device) = item, device.isAvailable, !isSimulatorRouteAmbiguous(device),
              !model.isBusy, !model.managingDeviceIDs.contains(id), ["Booted", "Shutdown"].contains(device.state) else { return }
        model.openDevice(device.identifier)
    }

    @objc private func performManagement(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? ManagementRequest else { return }
        let devices = model.inventory.filter { request.identifiers.contains($0.id) }
        guard devices.count == request.identifiers.count, supports(request.action, devices: devices), !model.isBusy,
              request.identifiers.isDisjoint(with: model.managingDeviceIDs) else { return }
        switch request.action {
        case .rename: presentNameEditor(for: devices[0], cloning: false)
        case .clone: presentNameEditor(for: devices[0], cloning: true)
        case .erase, .remove: confirmManagement(request.action, devices: devices)
        default: model.manage(request.action, devices: devices)
        }
    }

    private func presentNameEditor(for device: InventoryDevice, cloning: Bool) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = cloning ? "Clone \(device.name)" : "Rename \(device.name)"
        alert.informativeText = cloning ? "Enter a name for the new simulator." : "Enter a new device name."
        alert.addButton(withTitle: cloning ? "Clone" : "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: cloning ? "\(device.name) Copy" : device.name)
        field.frame.size = NSSize(width: 300, height: field.fittingSize.height)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let submit = alert.buttons[0]
        let observer = NotificationCenter.default.addObserver(forName: NSControl.textDidChangeNotification,
            object: field, queue: .main) { _ in
                MainActor.assumeIsolated { submit.isEnabled = !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            }
        alert.beginSheetModal(for: window) { [weak self] response in
            NotificationCenter.default.removeObserver(observer)
            guard response == .alertFirstButtonReturn, let self else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, let current = self.model.inventory.first(where: { $0.id == device.id }) else { return }
            self.model.manage(cloning ? .clone(name) : .rename(name), devices: [current])
        }
    }

    private func confirmManagement(_ action: DeviceManagementAction, devices: [InventoryDevice]) {
        guard let window else { return }
        let removing: Bool
        if case .remove = action { removing = true } else { removing = false }
        let subject = devices.count == 1 ? "“\(devices[0].name)”" : "\(devices.count) devices"
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = removing ? "Remove \(subject)?" : "Erase \(subject)?"
        if removing {
            alert.informativeText = devices.contains { $0.kind == .virtualMachine }
                ? "The selected devices and their stored data will be permanently removed. Removing a virtual machine also deletes its associated assets. This cannot be undone."
                : "The selected devices and their data will be permanently removed. This cannot be undone."
        } else {
            alert.informativeText = "All content and settings on the selected devices will be permanently erased. This cannot be undone."
        }
        alert.addButton(withTitle: removing ? "Remove" : "Erase")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let identifiers = Set(devices.map(\.id))
            let current = self.model.inventory.filter { identifiers.contains($0.id) }
            guard current.count == identifiers.count else { return }
            self.model.manage(action, devices: current)
        }
    }

    private func updateFilterItem() {
        let active = kindFilter != .all || availabilityFilter != .all || familyFilter != nil
        filterItem?.image = NSImage(systemSymbolName: active ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease",
                                   accessibilityDescription: active ? "Filter, active" : "Filter")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === deviceMenu { updateDeviceMenu(); return }
        guard menu === filterItem?.menu else { return }
        menu.removeAllItems()
        menu.addItem(.sectionHeader(title: "Devices"))
        for filter in DeviceKindFilter.allCases {
            let item = NSMenuItem(title: filter.title, action: #selector(filterKind(_:)), keyEquivalent: "")
            item.target = self
            item.tag = filter.rawValue
            item.state = kindFilter == filter ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Availability"))
        for filter in DeviceAvailabilityFilter.allCases {
            let item = NSMenuItem(title: filter.title, action: #selector(filterAvailability(_:)), keyEquivalent: "")
            item.target = self
            item.tag = filter.rawValue
            item.state = availabilityFilter == filter ? .on : .off
            menu.addItem(item)
        }
        let grouping = NSMenuItem(title: "Group by Availability", action: #selector(toggleAvailabilityGroups(_:)), keyEquivalent: "")
        grouping.target = self
        grouping.state = groupByAvailability ? .on : .off
        menu.addItem(grouping)
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Device Family"))
        let allTypes = NSMenuItem(title: "All Families", action: #selector(filterFamily(_:)), keyEquivalent: "")
        allTypes.target = self
        allTypes.state = familyFilter == nil ? .on : .off
        menu.addItem(allTypes)
        for family in Set(model.inventory.map { family(of: $0) }).sorted() {
            let item = NSMenuItem(title: family, action: #selector(filterFamily(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = family
            item.state = familyFilter == family ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Sort By"))
        for order in DeviceSortOrder.allCases {
            let item = NSMenuItem(title: order.title, action: #selector(sortDevices(_:)), keyEquivalent: "")
            item.target = self
            item.tag = order.rawValue
            item.state = sortOrder == order ? .on : .off
            menu.addItem(item)
        }
    }

    @objc private func filterKind(_ sender: NSMenuItem) {
        guard let filter = DeviceKindFilter(rawValue: sender.tag) else { return }
        kindFilter = filter
        update()
    }

    @objc private func filterAvailability(_ sender: NSMenuItem) {
        guard let filter = DeviceAvailabilityFilter(rawValue: sender.tag) else { return }
        availabilityFilter = filter
        update()
    }

    @objc private func toggleAvailabilityGroups(_ sender: Any?) {
        if groupByAvailability {
            for group in availabilityGroups {
                if table.isItemExpanded(group) { expandedGroups.insert(group.available) }
                else { expandedGroups.remove(group.available) }
            }
        }
        groupByAvailability.toggle()
        loadedRows = false
        update()
    }

    @objc private func filterFamily(_ sender: NSMenuItem) {
        familyFilter = sender.representedObject as? String
        update()
    }

    @objc private func sortDevices(_ sender: NSMenuItem) {
        guard let order = DeviceSortOrder(rawValue: sender.tag) else { return }
        sortOrder = order
        update()
    }

}

@MainActor
private final class SimulatorSidebarCellView: NSTableCellView {
    let subtitle = NSTextField(labelWithString: "Simulator")
    let version = NSTextField(labelWithString: "")
    let progress = NSProgressIndicator()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.contentTintColor = .secondaryLabelColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        let name = NSTextField(labelWithString: "")
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        version.font = .systemFont(ofSize: 12)
        version.textColor = .secondaryLabelColor
        version.alignment = .right
        version.translatesAutoresizingMaskIntoConstraints = false
        version.setContentCompressionResistancePriority(.required, for: .horizontal)
        version.setContentHuggingPriority(.required, for: .horizontal)
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.isHidden = true
        let trailing = NSStackView(views: [progress, version])
        trailing.spacing = 6
        trailing.translatesAutoresizingMaskIntoConstraints = false
        let labels = NSStackView(views: [name, subtitle])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        labels.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        addSubview(labels)
        addSubview(trailing)
        imageView = icon
        textField = name
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 25),
            icon.heightAnchor.constraint(equalToConstant: 30),
            labels.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
            labels.trailingAnchor.constraint(equalTo: trailing.leadingAnchor, constant: -10),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.widthAnchor.constraint(equalTo: labels.widthAnchor),
            subtitle.widthAnchor.constraint(equalTo: labels.widthAnchor),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    private let model: SimulatorManagerModel
    private let preferences = UserDefaults(suiteName: "dev.lynnswap.NeoSimulator.Renderer")
    private let hostPopup = NSPopUpButton()
    private let restore = NSButton(title: "Restore Original Settings…", target: nil, action: nil)
    private let gifSize = NSPopUpButton()
    private let gifRate = NSPopUpButton()
    private var toggles: [String: NSButton] = [:]

    init(model: SimulatorManagerModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 380),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "NeoSimulator Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        preferences?.register(defaults: [
            "StartLastDeviceOnLaunch": true, "SessionOnLaunch": true,
            "DetachOnWindowClose": false, "DetachOnAppQuit": false,
            "ShowSingleTouches": false, "ShowPinches": true, "ScreenShotUseMask": false,
            "GifMaxFrameSize": 640, "GifMaxFramerate": 10,
        ])
        let content = NSView()
        window.contentView = content
        let tabs = NSTabView()
        tabs.translatesAutoresizingMaskIntoConstraints = false
        let general = NSTabViewItem(identifier: "General")
        general.label = "General"
        general.view = generalPane()
        tabs.addTabViewItem(general)
        let capture = NSTabViewItem(identifier: "Capture")
        capture.label = "Capture"
        capture.view = capturePane()
        tabs.addTabViewItem(capture)
        content.addSubview(tabs)
        restore.bezelStyle = .rounded
        restore.target = self
        restore.action = #selector(restoreDefaults(_:))
        restore.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(restore)
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            tabs.bottomAnchor.constraint(equalTo: restore.topAnchor, constant: -14),
            restore.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            restore.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
        ])
        window.center()
        update()
    }

    required init?(coder: NSCoder) { nil }

    func update() {
        hostPopup.selectItem(at: model.status?.host == .deviceHub ? 1 : 0)
        hostPopup.isEnabled = !model.isBusy && model.status != nil
        restore.isEnabled = !model.isBusy && model.status?.restorationAvailable == true
        for (key, button) in toggles {
            let enabled = preferences?.bool(forKey: key) == true
            let startsSession = key != "StartLastDeviceOnLaunch" || preferences?.bool(forKey: "SessionOnLaunch") == true
            button.state = enabled && startsSession ? .on : .off
            button.isEnabled = preferences != nil
        }
        selectValue(preferences?.integer(forKey: "GifMaxFrameSize"), in: gifSize)
        selectValue(preferences?.integer(forKey: "GifMaxFramerate"), in: gifRate)
        gifSize.isEnabled = preferences != nil
        gifRate.isEnabled = preferences != nil
    }

    private func generalPane() -> NSView {
        hostPopup.addItems(withTitles: ["NeoSimulator", "Device Hub"])
        hostPopup.target = self
        hostPopup.action = #selector(selectHost(_:))
        hostPopup.setAccessibilityLabel("Display Host")
        let stack = formStack()
        stack.addArrangedSubview(popupRow("Display Host:", popup: hostPopup))
        stack.addArrangedSubview(separator())
        addToggle("Start the last used simulator on launch", key: "StartLastDeviceOnLaunch", to: stack)
        addToggle("Keep simulators running when closing a window", key: "DetachOnWindowClose", to: stack)
        addToggle("Keep simulators running when quitting NeoSimulator", key: "DetachOnAppQuit", to: stack)
        stack.addArrangedSubview(separator())
        addToggle("Show single touches", key: "ShowSingleTouches", to: stack)
        addToggle("Show pinch gestures", key: "ShowPinches", to: stack)
        return pane(containing: stack)
    }

    private func capturePane() -> NSView {
        let stack = formStack()
        addToggle("Include device mask in screenshots and videos", key: "ScreenShotUseMask", to: stack)
        stack.addArrangedSubview(separator())
        for (title, value) in [("Small (320 px)", 320), ("Medium (640 px)", 640), ("Large (1280 px)", 1280)] {
            gifSize.addItem(withTitle: title)
            gifSize.lastItem?.tag = value
        }
        gifSize.target = self
        gifSize.action = #selector(changeGifSize(_:))
        gifSize.setAccessibilityLabel("GIF Image Size")
        for (title, value) in [("For smaller file size", 10), ("For smoother animation", 15)] {
            gifRate.addItem(withTitle: title)
            gifRate.lastItem?.tag = value
        }
        gifRate.target = self
        gifRate.action = #selector(changeGifRate(_:))
        gifRate.setAccessibilityLabel("Optimize GIFs")
        stack.addArrangedSubview(popupRow("GIF Image Size:", popup: gifSize))
        stack.addArrangedSubview(popupRow("Optimize GIFs:", popup: gifRate))
        return pane(containing: stack)
    }

    private func formStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func pane(containing stack: NSStackView) -> NSView {
        let view = NSView()
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -20),
        ])
        return view
    }

    private func popupRow(_ title: String, popup: NSPopUpButton) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 120).isActive = true
        popup.widthAnchor.constraint(equalToConstant: 230).isActive = true
        let row = NSStackView(views: [label, popup])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 12
        return row
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 500).isActive = true
        return box
    }

    private func addToggle(_ title: String, key: String, to stack: NSStackView) {
        let button = NSButton(checkboxWithTitle: title, target: self, action: #selector(togglePreference(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(key)
        toggles[key] = button
        stack.addArrangedSubview(button)
    }

    private func selectValue(_ value: Int?, in popup: NSPopUpButton) {
        if let value, let item = popup.itemArray.first(where: { $0.tag == value }) { popup.select(item) }
        else { popup.selectItem(at: -1) }
    }

    private func save(_ value: Any, for key: String) {
        guard let preferences else { return }
        preferences.set(value, forKey: key)
        if key == "StartLastDeviceOnLaunch" { preferences.set(value, forKey: "SessionOnLaunch") }
        if !preferences.synchronize() {
            let alert = NSAlert()
            alert.messageText = "The simulator setting could not be saved."
            alert.informativeText = "Try changing the setting again."
            if let window { alert.beginSheetModal(for: window) }
        }
        update()
    }

    @objc private func togglePreference(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        save(sender.state == .on, for: key)
    }

    @objc private func changeGifSize(_ sender: NSPopUpButton) {
        guard let value = sender.selectedItem?.tag else { return }
        save(value, for: "GifMaxFrameSize")
    }

    @objc private func changeGifRate(_ sender: NSPopUpButton) {
        guard let value = sender.selectedItem?.tag else { return }
        save(value, for: "GifMaxFramerate")
    }

    @objc private func selectHost(_ sender: NSPopUpButton) { model.select(sender.indexOfSelectedItem == 1 ? .deviceHub : .neo) }

    @objc private func restoreDefaults(_ sender: Any?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Restore original settings?"
        alert.informativeText = "Restore the routing settings saved before NeoSimulator first changed them. Your simulator devices are kept."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.model.restoreDefaults() }
        }
    }
}

@MainActor
private struct ManagerDeviceSettingsView: View {
    let device: SimulatorHostDevice?
    let settings: SimulatorDeviceSettings?
    let isBusy: Bool
    let issue: String?
    let apply: (SimulatorDeviceSetting) -> Void
    let customLocation: () -> Void

    private struct Choice: Identifiable {
        let id: String
        let title: String
    }

    var body: some View {
        Form {
            if device?.state == "Booted", settings == nil, issue == nil {
                ProgressView("Loading settings…")
            } else {
                if device != nil {
                    Section {
                        appearanceRows
                        accessibilityRows
                    }
                    locationSection
                    soundSection
                }
                if let message {
                    Section {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help(issue ?? settings?.issues.joined(separator: "\n") ?? "")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .labelStyle(.titleAndIcon)
        .disabled(isBusy || device?.state != "Booted")
    }

    private var appearanceRows: some View {
        Group {
            picker("Appearance", symbol: "circle.lefthalf.filled", value: settings?.appearance,
                   choices: [Choice(id: "light", title: "Light"), Choice(id: "dark", title: "Dark")]) {
                apply(.appearance($0))
            }
            slider("Liquid Glass", symbol: "drop.halffull", value: settings?.liquidGlassOpacity, range: 0...1) {
                apply(.liquidGlassOpacity($0))
            }
            picker("Color Filter", symbol: "camera.filters", value: settings?.colorFilter?.rawValue,
                   choices: SimulatorColorFilter.allCases.map { Choice(id: $0.rawValue, title: filterTitle($0)) }) {
                if let value = SimulatorColorFilter(rawValue: $0) { apply(.colorFilter(value)) }
            }
            if let filter = settings?.colorFilter, filter != .none, filter != .grayscale {
                slider("Intensity", symbol: "slider.horizontal.3", value: settings?.colorFilterIntensity, range: 0.25...1) {
                    apply(.colorFilter(filter, intensity: $0))
                }
            }
            slider("Text Size", symbol: "textformat.size", value: textSizeIndex, range: 0...11,
                   tickMarks: SimulatorDeviceSettings.contentSizes.count, help: textSizeDescription) {
                let index = Int($0.rounded())
                guard SimulatorDeviceSettings.contentSizes.indices.contains(index) else { return }
                apply(.contentSize(SimulatorDeviceSettings.contentSizes[index]))
            }
        }
    }

    private var accessibilityRows: some View {
        Group {
            toggle("Reduce Motion", symbol: "figure.walk.motion", value: settings?.reduceMotion, setting: SimulatorDeviceSetting.reduceMotion)
            toggle("Increase Contrast", symbol: "circle.lefthalf.striped.horizontal", value: settings?.increaseContrast, setting: SimulatorDeviceSetting.increaseContrast)
            toggle("Show Borders", symbol: "square.dashed", value: settings?.showBorders, setting: SimulatorDeviceSetting.showBorders)
            toggle("Reduce Transparency", symbol: "square.on.square", value: settings?.reduceTransparency, setting: SimulatorDeviceSetting.reduceTransparency)
            toggle("VoiceOver", symbol: "person.wave.2", value: settings?.voiceOver, setting: SimulatorDeviceSetting.voiceOver)
        }
    }

    private var locationSection: some View {
        Section {
            LabeledContent {
                Menu(locationTitle) {
                    Button("None") { apply(.clearLocation) }
                    Button("Custom…", action: customLocation)
                    if settings?.locationScenarios.isEmpty == false { Divider() }
                    ForEach(settings?.locationScenarios ?? [], id: \.name) { scenario in
                        Button(scenario.displayName) { apply(.locationScenario(scenario.name)) }
                    }
                }
                .disabled(settings?.locationAvailable != true)
            } label: {
                Label("Location", systemImage: "location")
            }
        }
    }

    private var soundSection: some View {
        Section {
            slider("Sound", symbol: "speaker.wave.2", value: settings?.volume.map(Double.init), range: 0...100) {
                apply(.volume(Int($0.rounded())))
            }
            picker("Output", symbol: "speaker", value: settings?.audioOutputDevice,
                   choices: (settings?.audioOutputDevices ?? []).map { Choice(id: $0.identifier, title: $0.name) }) {
                apply(.audioOutputDevice($0))
            }
            picker("Input", symbol: "mic", value: settings?.audioInputDevice,
                   choices: (settings?.audioInputDevices ?? []).map { Choice(id: $0.identifier, title: $0.name) }) {
                apply(.audioInputDevice($0))
            }
        }
    }

    @ViewBuilder
    private func picker(_ title: String, symbol: String, value: String?, choices: [Choice], action: @escaping (String) -> Void) -> some View {
        if let value {
            Picker(selection: Binding(get: { value }, set: action)) {
                if !choices.contains(where: { $0.id == value }) { Text("Unavailable").tag(value) }
                ForEach(choices) { Text($0.title).tag($0.id) }
            } label: {
                Label(title, systemImage: symbol)
            }
            .disabled(choices.isEmpty)
            .buttonStyle(.borderless)
        } else {
            unavailable(title, symbol: symbol)
        }
    }

    @ViewBuilder
    private func toggle(_ title: String, symbol: String, value: Bool?, setting: @escaping (Bool) -> SimulatorDeviceSetting) -> some View {
        if let value {
            Toggle(isOn: Binding(get: { value }, set: { apply(setting($0)) })) {
                Label(title, systemImage: symbol)
            }
            .toggleStyle(.switch)
        } else {
            unavailable(title, symbol: symbol)
        }
    }

    @ViewBuilder
    private func slider(_ title: String, symbol: String, value: Double?, range: ClosedRange<Double>, tickMarks: Int = 0,
                        help: String = "", action: @escaping (Double) -> Void) -> some View {
        if let value {
            LabeledContent {
                ManagerSettingSlider(value: value, range: range, tickMarks: tickMarks, label: title, changed: action)
                    .frame(minWidth: 90, maxWidth: .infinity, minHeight: 22)
                    .help(help)
            } label: {
                Label(title, systemImage: symbol)
                    .layoutPriority(1)
            }
        } else {
            unavailable(title, symbol: symbol)
        }
    }

    private func unavailable(_ title: String, symbol: String) -> some View {
        LabeledContent {
            Text("Unavailable").foregroundStyle(.secondary)
        } label: {
            Label(title, systemImage: symbol)
        }
    }

    private var textSizeIndex: Double? {
        settings?.contentSize.flatMap { SimulatorDeviceSettings.contentSizes.firstIndex(of: $0) }.map(Double.init)
    }

    private var textSizeDescription: String {
        settings?.contentSize?.split(separator: "-").map { $0.capitalized }.joined(separator: " ") ?? ""
    }

    private var locationTitle: String {
        switch settings?.locationMode {
        case "none": "None"
        case "custom": "Custom"
        case "scenario": settings?.locationScenarios.first { $0.name == settings?.locationScenario }?.displayName ?? "Unavailable"
        default: "Set Location"
        }
    }

    private var message: String? {
        guard let device else { return "Select a simulator to change its settings." }
        guard device.state == "Booted" else { return "Start this simulator to change its settings." }
        if issue != nil || settings?.issues.isEmpty == false { return "Some settings could not be loaded for this simulator." }
        return settings == nil ? "Loading settings…" : nil
    }

    private func filterTitle(_ filter: SimulatorColorFilter) -> String {
        switch filter {
        case .none: "None"
        case .grayscale: "Grayscale"
        case .protanopia: "Protanopia"
        case .deuteranopia: "Deuteranopia"
        case .tritanopia: "Tritanopia"
        }
    }
}

@MainActor
private struct ManagerSettingSlider: NSViewRepresentable {
    let value: Double
    let range: ClosedRange<Double>
    let tickMarks: Int
    let label: String
    let changed: (Double) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(changed: changed) }

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider()
        slider.isContinuous = false
        slider.controlSize = .regular
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.change(_:))
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.changed = changed
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.doubleValue = value
        slider.numberOfTickMarks = tickMarks
        slider.allowsTickMarkValuesOnly = tickMarks > 0
        slider.isEnabled = context.environment.isEnabled
        slider.setAccessibilityLabel(label)
    }

    final class Coordinator: NSObject {
        var changed: (Double) -> Void
        init(changed: @escaping (Double) -> Void) { self.changed = changed }
        @objc func change(_ sender: NSSlider) { changed(sender.doubleValue) }
    }
}
