import AppKit
import XcodeSimulatorHost

@MainActor
final class SimulatorManagerModel {
    private let controller: SimulatorHostController
    private(set) var status: SimulatorHostStatus?
    private(set) var devices: [SimulatorHostDevice] = []
    private(set) var isBusy = false
    private(set) var activity = ""
    private(set) var backgroundIssue: String?
    private(set) var deviceSettings: SimulatorDeviceSettings?
    private(set) var settingsIssue: String?
    private(set) var inspectedDeviceIdentifier: String?
    private var inspectedState: String?
    var onChange: (() -> Void)?
    var onError: ((any Error) -> Void)?
    private var refreshing = false
    private var refreshWaiters: [CheckedContinuation<Void, Never>] = []
    private var synchronizing = false
    private var stopping = false
    private var pendingOperations: [(activity: String, run: @MainActor () async throws -> Void)] = []

    init(rendererApplicationURL: URL) {
        controller = SimulatorHostController(rendererApplicationURL: rendererApplicationURL)
    }

    func start() {
        perform("Starting simulators…") {
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
        let identifier = try await controller.createSimulator(named: name, deviceType: deviceType, runtime: runtime,
                                                               context: context)
        await refresh()
        return identifier
    }

    func pairSimulators(watch: String, phone: String, context: SimulatorCreationContext) async throws {
        try await controller.pairSimulators(watch: watch, phone: phone, context: context)
        await refresh()
    }

    func restoreDefaults(force: Bool = false) {
        perform("Restoring original settings…") { try await self.controller.restore(force: force) }
    }

    func refresh() async {
        guard !isBusy, !refreshing else { return }
        await refreshCatalog()
    }

    private func refreshCatalog() async {
        if refreshing { await withCheckedContinuation { refreshWaiters.append($0) } }
        else { refreshing = true }
        defer {
            inspectedState = nil
            onChange?()
            if refreshWaiters.isEmpty { refreshing = false }
            else { refreshWaiters.removeFirst().resume() }
        }
        do {
            status = try await controller.status()
            var merged: [SimulatorHostDevice] = []
            var identifiers = Set<String>()
            var firstError: (any Error)?
            for xcode in try await controller.installedXcodes() {
                do {
                    for device in try await controller.devices(xcodeURL: xcode.url) where identifiers.insert(device.identifier).inserted {
                        merged.append(device)
                    }
                } catch { if firstError == nil { firstError = error } }
            }
            if merged.isEmpty, let firstError { throw firstError }
            devices = merged
            if let firstError { reportBackgroundError(firstError) }
            else { backgroundIssue = nil }
        } catch { reportBackgroundError(error) }
    }

    func synchronizeConnections() async {
        guard !synchronizing, !refreshing, !isBusy else { return }
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
        let state = devices.first { $0.identifier == identifier }?.state
        guard inspectedDeviceIdentifier != identifier || inspectedState != state else { return }
        inspectedDeviceIdentifier = identifier
        inspectedState = state
        deviceSettings = nil
        settingsIssue = nil
        onChange?()
        guard let identifier else { return }
        do {
            let settings = try await controller.deviceSettings(identifier: identifier)
            guard inspectedDeviceIdentifier == identifier, inspectedState == state else { return }
            deviceSettings = settings
            if !settings.issues.isEmpty {
                NSLog("NeoSimulator settings: %@", settings.issues.joined(separator: "\n"))
            }
            onChange?()
        } catch {
            guard inspectedDeviceIdentifier == identifier, inspectedState == state else { return }
            settingsIssue = error.localizedDescription
            NSLog("NeoSimulator settings: %@", (error as? SimulatorHostFailure)?.technicalDetails ?? String(describing: error))
            onChange?()
        }
    }

    func setAppearance(_ value: String, for identifier: String) { set(.appearance(value), identifier: identifier) }
    func setContentSize(_ value: String, for identifier: String) { set(.contentSize(value), identifier: identifier) }
    func setIncreaseContrast(_ enabled: Bool, for identifier: String) { set(.increaseContrast(enabled), identifier: identifier) }
    func setLocation(latitude: Double, longitude: Double, for identifier: String) {
        set(.location(latitude: latitude, longitude: longitude), identifier: identifier)
    }
    func clearLocation(for identifier: String) { set(.clearLocation, identifier: identifier) }

    private func set(_ setting: SimulatorDeviceSetting, identifier: String) {
        perform("Updating simulator settings…") {
            try await self.controller.setDeviceSetting(setting, identifier: identifier)
            self.inspectedState = nil
        }
    }

    func quitRenderer(keepingDevicesRunning: Bool?) async throws {
        stopping = true
        pendingOperations.removeAll()
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

    private func perform(_ activity: String, operation: @escaping @MainActor () async throws -> Void) {
        guard !stopping else { return }
        pendingOperations.append((activity, operation))
        guard !isBusy else { return }
        isBusy = true
        Task {
            while !stopping, !pendingOperations.isEmpty {
                let next = pendingOperations.removeFirst()
                self.activity = next.activity
                onChange?()
                var failure: (any Error)?
                do { try await next.run() }
                catch { failure = error }
                await refreshCatalog()
                if let failure { onError?(failure) }
            }
            isBusy = false
            self.activity = ""
            onChange?()
        }
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
        connectionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.quitting else { return }
                await self.model.synchronizeConnections()
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
                try await model.quitRenderer(keepingDevicesRunning: quitKeepingDevicesRunning)
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                quitting = false
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
        addItem("Show Simulators", action: #selector(showDevices(_:)), to: menu)
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

    @objc private func showNewSimulator(_ sender: Any?) {
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
        let view = addSubmenu("View", to: main)
        addItem("Show Simulators", action: #selector(showDevices(_:)), to: view)
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
final class ManagerWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate,
                                     NSSearchFieldDelegate, NSToolbarDelegate {
    private let model: SimulatorManagerModel
    private let splitController = NSSplitViewController()
    private let table = NSTableView()
    private let search = NSSearchField()
    private let deviceImage = NSImageView()
    private let deviceName = NSTextField(labelWithString: "Select a Simulator")
    private let deviceRuntime = NSTextField(labelWithString: "")
    private let deviceState = NSTextField(labelWithString: "")
    private let viewScreen = NSButton(title: "View Screen", target: nil, action: nil)
    private let activity = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let appearancePopup = NSPopUpButton()
    private let textSize = NSSlider(value: 3, minValue: 0, maxValue: 11, target: nil, action: nil)
    private let textSizeDescription = NSTextField(wrappingLabelWithString: "")
    private let contrast = NSButton(checkboxWithTitle: "Increase Contrast", target: nil, action: nil)
    private let locationPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private let settingsMessage = NSTextField(wrappingLabelWithString: "Select a simulator to change its settings.")
    private var updatingSelection = false
    private var filteredDevices: [SimulatorHostDevice] = []
    private var selectedIdentifier: String?
    private var refreshItem: NSToolbarItem?
    private let refreshIdentifier = NSToolbarItem.Identifier("RefreshSimulators")

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
        let previous = selectedIdentifier
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        filteredDevices = model.devices.filter {
            query.isEmpty || $0.name.localizedStandardContains(query) || $0.runtimeName.localizedStandardContains(query)
        }.sorted {
            let nameOrder = $0.name.localizedStandardCompare($1.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            let versionOrder = $0.runtimeName.compare($1.runtimeName, options: .numeric)
            return versionOrder == .orderedSame ? $0.identifier < $1.identifier : versionOrder == .orderedDescending
        }
        updatingSelection = true
        table.reloadData()
        if let previous, let index = filteredDevices.firstIndex(where: { $0.identifier == previous }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else {
            selectedIdentifier = nil
            table.deselectAll(nil)
        }
        updatingSelection = false
        updateSelection()
        refreshItem?.isEnabled = !model.isBusy
        activity.stringValue = model.isBusy ? model.activity : (model.backgroundIssue ?? "")
        activity.toolTip = activity.stringValue
        activity.isHidden = activity.stringValue.isEmpty
        progress.isHidden = !model.isBusy
        if model.isBusy { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
    }

    private func buildSidebar() {
        let controller = NSViewController()
        let view = NSView()
        controller.view = view
        search.placeholderString = "Search Simulators"
        search.delegate = self
        search.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(search)
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Device")))
        table.headerView = nil
        table.style = .sourceList
        table.rowHeight = 52
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.backgroundColor = .clear
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelectedDevice(_:))
        table.setAccessibilityLabel("Simulators")
        scroll.documentView = table
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            search.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            search.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        let sidebar = NSSplitViewItem(sidebarWithViewController: controller)
        sidebar.minimumThickness = 220
        sidebar.maximumThickness = 360
        sidebar.preferredThicknessFraction = 0.26
        splitController.addSplitViewItem(sidebar)
    }

    private func buildDevicePane() {
        let controller = NSViewController()
        let view = NSView()
        controller.view = view
        deviceImage.contentTintColor = .tertiaryLabelColor
        deviceImage.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 72, weight: .ultraLight)
        deviceImage.imageScaling = .scaleProportionallyUpOrDown
        deviceImage.translatesAutoresizingMaskIntoConstraints = false
        deviceImage.setAccessibilityHidden(true)
        deviceName.font = .systemFont(ofSize: 23, weight: .semibold)
        deviceName.alignment = .center
        deviceName.lineBreakMode = .byTruncatingTail
        deviceRuntime.font = .systemFont(ofSize: 13)
        deviceRuntime.textColor = .secondaryLabelColor
        deviceRuntime.alignment = .center
        deviceRuntime.lineBreakMode = .byTruncatingTail
        deviceState.font = .systemFont(ofSize: 12)
        deviceState.textColor = .secondaryLabelColor
        viewScreen.bezelStyle = .rounded
        viewScreen.controlSize = .large
        viewScreen.target = self
        viewScreen.action = #selector(openSelectedDevice(_:))
        viewScreen.keyEquivalent = "\r"
        let stack = NSStackView(views: [deviceImage, deviceName, deviceRuntime, deviceState, viewScreen])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(24, after: deviceImage)
        stack.setCustomSpacing(20, after: deviceState)
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
            deviceImage.widthAnchor.constraint(equalToConstant: 110),
            deviceImage.heightAnchor.constraint(equalToConstant: 130),
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
        let controller = NSViewController()
        let view = NSView()
        controller.view = view
        let title = NSTextField(labelWithString: "Device Settings")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        appearancePopup.addItems(withTitles: ["Light", "Dark"])
        appearancePopup.target = self
        appearancePopup.action = #selector(changeAppearance(_:))
        appearancePopup.setAccessibilityLabel("Appearance")
        textSize.numberOfTickMarks = SimulatorDeviceSettings.contentSizes.count
        textSize.allowsTickMarkValuesOnly = true
        textSize.isContinuous = false
        textSize.target = self
        textSize.action = #selector(changeTextSize(_:))
        textSize.setAccessibilityLabel("Text Size")
        textSizeDescription.font = .systemFont(ofSize: 11)
        textSizeDescription.textColor = .secondaryLabelColor
        contrast.target = self
        contrast.action = #selector(changeContrast(_:))
        locationPopup.addItems(withTitles: ["Set Location", "None", "Custom…"])
        locationPopup.target = self
        locationPopup.action = #selector(changeLocation(_:))
        locationPopup.setAccessibilityLabel("Location")
        settingsMessage.font = .systemFont(ofSize: 11)
        settingsMessage.textColor = .secondaryLabelColor
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 22
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(title)
        for (label, fields) in [("Appearance", [appearancePopup as NSView]),
                                ("Text Size", [textSize as NSView, textSizeDescription as NSView]),
                                ("Accessibility", [contrast as NSView]),
                                ("Location", [locationPopup as NSView])] {
            let caption = NSTextField(labelWithString: label)
            caption.font = .systemFont(ofSize: 11)
            caption.textColor = .secondaryLabelColor
            let group = NSStackView(views: [caption] + fields)
            group.orientation = .vertical
            group.alignment = .leading
            group.spacing = 7
            stack.addArrangedSubview(group)
            group.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            for field in fields { field.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true }
        }
        stack.addArrangedSubview(settingsMessage)
        settingsMessage.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let document = ManagerInspectorDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 22),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -22),
        ])
        let inspector = NSSplitViewItem(inspectorWithViewController: controller)
        inspector.minimumThickness = 250
        inspector.maximumThickness = 320
        inspector.canCollapse = false
        splitController.addSplitViewItem(inspector)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filteredDevices.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard filteredDevices.indices.contains(row) else { return nil }
        let device = filteredDevices[row]
        let identifier = NSUserInterfaceItemIdentifier("SimulatorRow")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? SimulatorSidebarCellView
            ?? SimulatorSidebarCellView()
        cell.identifier = identifier
        cell.textField?.stringValue = device.name
        cell.subtitle.stringValue = "Simulator"
        cell.version.stringValue = device.runtimeName.split(separator: " ").first { $0.first?.isNumber == true }.map(String.init) ?? ""
        cell.imageView?.image = NSImage(systemSymbolName: symbolName(for: device), accessibilityDescription: nil)
        cell.setAccessibilityLabel("\(device.name), \(device.runtimeName), \(stateLabel(device.state))")
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updatingSelection else { return }
        selectedIdentifier = filteredDevices.indices.contains(table.selectedRow) ? filteredDevices[table.selectedRow].identifier : nil
        updateSelection()
    }

    func controlTextDidChange(_ notification: Notification) { update() }

    private var selectedDevice: SimulatorHostDevice? {
        guard let selectedIdentifier else { return nil }
        return model.devices.first { $0.identifier == selectedIdentifier }
    }

    private func updateSelection() {
        let device = selectedDevice
        deviceName.stringValue = device?.name ?? "Select a Simulator"
        deviceRuntime.stringValue = device?.runtimeName ?? "Choose a device in the sidebar to view its screen."
        deviceState.stringValue = device.map { stateLabel($0.state) } ?? ""
        deviceImage.image = NSImage(systemSymbolName: device.map(symbolName(for:)) ?? "iphone", accessibilityDescription: nil)
        deviceImage.contentTintColor = device == nil ? .tertiaryLabelColor : .secondaryLabelColor
        viewScreen.isHidden = device == nil
        viewScreen.isEnabled = !model.isBusy && device.map { ["Booted", "Shutdown"].contains($0.state) } == true
        updateDeviceSettings()
        Task { await model.inspectDevice(selectedIdentifier) }
    }

    private func updateDeviceSettings() {
        let settings = model.inspectedDeviceIdentifier == selectedIdentifier ? model.deviceSettings : nil
        let enabled = !model.isBusy && selectedDevice?.state == "Booted"
        appearancePopup.isEnabled = enabled && settings?.appearance != nil
        appearancePopup.selectItem(at: settings?.appearance == nil ? -1 : settings?.appearance == "dark" ? 1 : 0)
        if let value = settings?.contentSize,
           let index = SimulatorDeviceSettings.contentSizes.firstIndex(of: value) {
            textSize.doubleValue = Double(index)
            textSizeDescription.stringValue = value.split(separator: "-").map { $0.capitalized }.joined(separator: " ")
        } else {
            textSize.doubleValue = 0
            textSizeDescription.stringValue = settings == nil ? "" : "Unavailable"
        }
        textSize.isEnabled = enabled && settings?.contentSize != nil
        contrast.isEnabled = enabled && settings?.increaseContrast != nil
        contrast.allowsMixedState = settings?.increaseContrast == nil
        contrast.state = settings?.increaseContrast.map { $0 ? .on : .off } ?? .mixed
        locationPopup.isEnabled = enabled && settings?.locationAvailable == true
        if selectedDevice == nil { settingsMessage.stringValue = "Select a simulator to change its settings." }
        else if selectedDevice?.state != "Booted" { settingsMessage.stringValue = "Start this simulator to change its settings." }
        else if model.settingsIssue != nil || settings?.issues.isEmpty == false {
            settingsMessage.stringValue = "Some settings could not be loaded. Refresh to try again."
        } else if settings == nil { settingsMessage.stringValue = "Loading settings…" }
        else { settingsMessage.stringValue = "" }
        settingsMessage.toolTip = model.settingsIssue ?? settings?.issues.joined(separator: "\n")
        settingsMessage.isHidden = settingsMessage.stringValue.isEmpty
    }

    @objc private func changeAppearance(_ sender: NSPopUpButton) {
        guard let identifier = selectedIdentifier else { return }
        model.setAppearance(sender.indexOfSelectedItem == 1 ? "dark" : "light", for: identifier)
    }

    @objc private func changeTextSize(_ sender: NSSlider) {
        guard let identifier = selectedIdentifier else { return }
        let index = Int(sender.doubleValue.rounded())
        guard SimulatorDeviceSettings.contentSizes.indices.contains(index) else { return }
        model.setContentSize(SimulatorDeviceSettings.contentSizes[index], for: identifier)
    }

    @objc private func changeContrast(_ sender: NSButton) {
        guard let identifier = selectedIdentifier else { return }
        model.setIncreaseContrast(sender.state == .on, for: identifier)
    }

    @objc private func changeLocation(_ sender: NSPopUpButton) {
        guard let identifier = selectedIdentifier else { return }
        if sender.indexOfSelectedItem == 1 { model.clearLocation(for: identifier) }
        else if sender.indexOfSelectedItem == 2 { presentLocationEditor(for: identifier) }
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

    private func symbolName(for device: SimulatorHostDevice) -> String {
        switch device.productFamily {
        case "iPad": "ipad"
        case "Apple TV": "appletv"
        case "Apple Watch": "applewatch"
        case "Apple Vision": "visionpro"
        default: "iphone"
        }
    }

    private func stateLabel(_ state: String) -> String { state == "Shutdown" ? "Shut Down" : state }

    @objc private func openSelectedDevice(_ sender: Any?) {
        guard let device = selectedDevice, !model.isBusy, ["Booted", "Shutdown"].contains(device.state) else { return }
        model.openDevice(device.identifier)
    }

    @objc private func refresh(_ sender: Any?) { Task { await model.refresh() } }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, refreshIdentifier, .inspectorTrackingSeparator]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard itemIdentifier == refreshIdentifier else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = "Refresh"
        item.toolTip = "Refresh Simulators"
        item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
        item.target = self
        item.action = #selector(refresh(_:))
        item.autovalidates = false
        item.isEnabled = !model.isBusy
        refreshItem = item
        return item
    }
}

@MainActor
private final class SimulatorSidebarCellView: NSTableCellView {
    let subtitle = NSTextField(labelWithString: "Simulator")
    let version = NSTextField(labelWithString: "")

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
        let labels = NSStackView(views: [name, subtitle])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        labels.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        addSubview(labels)
        addSubview(version)
        imageView = icon
        textField = name
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 25),
            icon.heightAnchor.constraint(equalToConstant: 30),
            labels.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
            labels.trailingAnchor.constraint(equalTo: version.leadingAnchor, constant: -10),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.widthAnchor.constraint(equalTo: labels.widthAnchor),
            subtitle.widthAnchor.constraint(equalTo: labels.widthAnchor),
            version.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            version.centerYAnchor.constraint(equalTo: centerYAnchor),
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
private final class ManagerInspectorDocumentView: NSView {
    override var isFlipped: Bool { true }
}
