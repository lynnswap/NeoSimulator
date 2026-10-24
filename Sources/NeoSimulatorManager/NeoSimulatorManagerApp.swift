import AppKit
import Quartz
import Carbon
import IOKit.hid
import ImageIO
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
    private(set) var inspectedDeviceIdentifier: DeviceInventoryID?
    // Query context also invalidates pending results when connection or capabilities change.
    private var inspectedDevice: InventoryDevice?
    private var settingsRefreshRequested = false
    private var inspectionGeneration = 0
    private var inspectionTask: Task<Void, Never>?
    var onChange: (() -> Void)?
    var onError: ((any Error) -> Void)?
    var onOpenRemoteDevice: ((CoreDeviceDevice) -> Void)?
    var beforeStoppingScreens: (() async throws -> Void)?
    var beforeManagingRemoteDevices: ((Set<DeviceInventoryID>) async throws -> Void)?
    private var refreshing = false
    private var refreshWaiters: [CheckedContinuation<Void, Never>] = []
    private var statusRefreshTask: Task<Void, Never>?
    private var statusIssue: (any Error)?
    private var observationIssue: String?
    private var inventoryIssues: [DeviceInventoryIssue] = []
    var isRemoteInventoryComplete: Bool { !inventoryIssues.contains { $0.source == .coreDevice } }
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
        perform("Switching simulator app…") {
            if host == .deviceHub { try await self.beforeStoppingScreens?() }
            try await self.controller.selectHost(host)
        }
    }

    func openDevice(_ identifier: DeviceInventoryID) {
        perform("Opening simulator…") { try await self.controller.openDevice(identifier) }
    }

    func openScreen(for device: InventoryDevice) {
        guard !managingDeviceIDs.contains(device.id) else { return }
        switch device {
        case .simulator(let simulator): openDevice(simulator.inventoryID)
        case .remote:
            perform("Opening device screen…") {
                guard !self.managingDeviceIDs.contains(device.id) else { return }
                if self.status?.host != .neo {
                    try await self.controller.selectHost(.neo)
                    self.status = try await self.controller.status()
                }
                guard !self.managingDeviceIDs.contains(device.id),
                      case .remote(let current)? = self.inventory.first(where: { $0.id == device.id }) else { return }
                self.onOpenRemoteDevice?(current)
            }
        }
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
            do {
                let remoteIDs = Set(targets.filter { self.managementDisconnectsScreen(action, for: $0) }.map(\.id))
                if !remoteIDs.isEmpty { try await self.beforeManagingRemoteDevices?(remoteIDs) }
                let report = await self.controller.manage(action, devices: targets)
                if !self.stopping { await self.refreshCatalog() }
                if report.results.contains(where: { $0.error != nil }) {
                    self.onError?(DeviceManagementFailure(devices: targets, report: report))
                }
            } catch { self.onError?(error) }
        }
        onChange?()
    }

    private func managementDisconnectsScreen(_ action: DeviceManagementAction, for device: InventoryDevice) -> Bool {
        guard case .remote = device, device.supports(action) else { return false }
        switch action {
        case .shutdown, .restart, .erase, .remove, .unpair, .pause: return true
        case .rename, .clone, .start, .resume, .pair: return false
        }
    }

    func inspector(for device: InventoryDevice) async throws -> DeviceInspector {
        guard !stopping else { throw CancellationError() }
        return try await controller.inspector(for: device)
    }

    func performInspectorOperation(for device: InventoryDevice,
                                   operation: @escaping @MainActor () async throws -> Void,
                                   completion: @escaping @MainActor () -> Void) {
        guard !stopping, !managingDeviceIDs.contains(device.id) else { return }
        managingDeviceIDs.insert(device.id)
        let request = UUID()
        managementTasks[request] = Task {
            defer {
                self.managingDeviceIDs.remove(device.id)
                self.managementTasks.removeValue(forKey: request)
                self.onChange?()
            }
            do { try await operation() }
            catch { self.onError?(InspectorOperationFailure(deviceName: device.name, error: error)) }
            if !self.stopping {
                await self.refreshCatalog()
                completion()
            }
        }
        onChange?()
    }

    func restoreDefaults(force: Bool = false) {
        perform("Restoring original settings…") {
            try await self.beforeStoppingScreens?()
            try await self.controller.restore(force: force)
        }
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
            refreshHostStatus()
            let snapshot = await controller.inventory()
            inventory = snapshot.devices
            inventoryIssues = snapshot.issues
            updateInventoryIssue()
        } while inventoryRefreshRequested && !stopping
    }

    private func refreshHostStatus() {
        guard statusRefreshTask == nil else { return }
        statusRefreshTask = Task {
            defer { self.statusRefreshTask = nil }
            do {
                let status = try await self.controller.status()
                guard !self.stopping, !Task.isCancelled else { return }
                self.status = status
                self.statusIssue = nil
            } catch {
                guard !self.stopping, !Task.isCancelled else { return }
                self.statusIssue = error
            }
            self.updateInventoryIssue()
            self.onChange?()
        }
    }

    private func updateInventoryIssue() {
        if inventoryIssues.isEmpty, statusIssue == nil, observationIssue == nil { backgroundIssue = nil }
        else {
            reportBackgroundError(InventoryReadError(issues: inventoryIssues, statusError: statusIssue,
                                                     observationIssue: observationIssue))
        }
    }

    func inventoryDidChange() async {
        guard !stopping else { return }
        inventoryRefreshRequested = true
        await refresh()
    }

    func inventoryObservationRecovered() {
        guard !stopping else { return }
        observationIssue = nil
        updateInventoryIssue()
    }

    func inventoryObservationFailed(_ error: any Error) {
        guard !stopping else { return }
        NSLog("NeoSimulator automatic device updates: %@", String(describing: error))
        observationIssue = "Automatic device updates are unavailable. Use Refresh to update the device list."
        updateInventoryIssue()
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

    func inspectDevice(_ identifier: DeviceInventoryID?) async {
        guard !stopping else { return }
        let device = inventory.first { $0.id == identifier }
        if inspectedDeviceIdentifier != identifier || inspectedDevice != device {
            inspectedDeviceIdentifier = identifier
            inspectedDevice = device
            inspectionGeneration += 1
            settingsRefreshRequested = true
            deviceSettings = nil
            settingsIssue = nil
            onChange?()
        }
        guard device?.canInspectSettings == true else { settingsRefreshRequested = false; return }
        if let inspectionTask { await inspectionTask.value; return }
        guard settingsRefreshRequested else { return }
        inspectionTask = Task {
            defer { self.inspectionTask = nil }
            while !self.stopping, !Task.isCancelled, self.settingsRefreshRequested,
                  let device = self.inspectedDevice, device.canInspectSettings {
                self.settingsRefreshRequested = false
                let generation = self.inspectionGeneration
                do {
                    let settings = try await self.controller.deviceSettings(for: device)
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

    private func refreshInspectedSettings(for identifier: DeviceInventoryID) async {
        guard !stopping, inspectedDeviceIdentifier == identifier else { return }
        inspectionGeneration += 1
        settingsRefreshRequested = true
        await inspectDevice(identifier)
    }

    func setAppearance(_ value: String, for identifier: DeviceInventoryID) { set(.appearance(value), identifier: identifier) }
    func setContentSize(_ value: String, for identifier: DeviceInventoryID) { set(.contentSize(value), identifier: identifier) }
    func setIncreaseContrast(_ enabled: Bool, for identifier: DeviceInventoryID) { set(.increaseContrast(enabled), identifier: identifier) }
    func setLocation(latitude: Double, longitude: Double, for identifier: DeviceInventoryID) {
        set(.location(latitude: latitude, longitude: longitude), identifier: identifier)
    }
    func clearLocation(for identifier: DeviceInventoryID) { set(.clearLocation, identifier: identifier) }

    func setDeviceSetting(_ setting: SimulatorDeviceSetting, for identifier: DeviceInventoryID) {
        set(setting, identifier: identifier)
    }

    private func set(_ setting: SimulatorDeviceSetting, identifier: DeviceInventoryID) {
        guard !managingDeviceIDs.contains(identifier), let device = inventory.first(where: { $0.id == identifier }) else { return }
        perform("Updating device settings…", refreshCatalog: false) {
            do { try await self.controller.setDeviceSetting(setting, for: device) }
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
        statusRefreshTask?.cancel()
        await operationTask?.value
        for task in Array(managementTasks.values) { await task.value }
        await statusRefreshTask?.value
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
    let observationIssue: String?

    var errorDescription: String? {
        let messages = issues.map { issue in
            let source: String = switch issue.source {
            case .coreDevice: "Devices"
            case .rendererOwnership: "Open Screens"
            case .simulators(let xcode, _): xcode?.deletingPathExtension().lastPathComponent ?? "Simulators"
            }
            return "\(source): \(issue.error.localizedDescription)"
        }
        return (messages + [statusError?.localizedDescription, observationIssue].compactMap { $0 }).joined(separator: "\n")
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
            return SimulatorMenuDevice(identifier: device.inventoryID, name: device.name,
                descriptiveName: device.descriptiveName, runtimeIdentifier: device.runtimeIdentifier,
                runtimeName: device.runtimeName, state: state)
        }, hasWindow: { identifier in model.devices.first { $0.inventoryID == identifier }?.ownerXcodeURL != nil },
           action: #selector(openDevice(_:)), target: self)
        if menu.items.isEmpty {
            let item = NSMenuItem(title: model.isBusy ? model.activity : "No Simulators", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
    }

    @objc private func openDevice(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? DeviceInventoryID else { return }
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
    private var remoteWindows: [DeviceInventoryID: RemoteDeviceWindowController] = [:]
    private var remoteHostCleanup: Task<Void, Never>?
    private var lastRemoteHost: SimulatorHost?

    func applicationDidFinishLaunching(_ notification: Notification) {
        SimulatorPreferences.migrateStandalonePreferences()
        installMenu()
        model.onChange = { [weak self] in
            self?.mainWindow?.update()
            self?.settingsWindow?.update()
            self?.updateRemoteWindows()
        }
        model.onOpenRemoteDevice = { [weak self] device in self?.openRemoteScreen(device) }
        model.beforeStoppingScreens = { [weak self] in try await self?.stopRemoteScreens() }
        model.beforeManagingRemoteDevices = { [weak self] identifiers in
            try await self?.stopRemoteScreens(for: identifiers)
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
        Task {
            do {
                mainWindow?.stopInspectorReads()
                try await mainWindow?.finishInspectorPreviews()
                inventoryObservationTask?.cancel()
                await inventoryObservation?.stop()
                await inventoryObservationTask?.value
                inventoryObservation = nil
                await remoteHostCleanup?.value
                try await stopRemoteScreens()
                try await model.quitRenderer(keepingDevicesRunning: quitKeepingDevicesRunning)
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                quitting = false
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
        if let controller = remoteWindows[id] {
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            controller.connectIfNeeded()
            return
        }
        let controller = RemoteDeviceWindowController(device: device)
        controller.onClose = { [weak self, weak controller] in
            guard self?.remoteWindows[id] === controller else { return }
            self?.remoteWindows.removeValue(forKey: id)
        }
        remoteWindows[id] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.connectIfNeeded()
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
        file.addItem(.separator())
        addItem("Save Screenshot…", action: #selector(RemoteDeviceWindowController.saveRemoteScreenshot(_:)), key: "s", to: file).target = nil
        addItem("Discard Screenshot…", action: #selector(RemoteDeviceWindowController.discardRemoteScreenshot(_:)), to: file).target = nil
        addItem("Record Screen", action: #selector(RemoteDeviceWindowController.recordScreen(_:)), key: "r", to: file).target = nil
        let recordTo = addItem("Record Screen…", action: #selector(RemoteDeviceWindowController.recordScreenTo(_:)), key: "r", to: file)
        recordTo.target = nil
        recordTo.keyEquivalentModifierMask = [.command, .option]
        recordTo.isAlternate = true
        addItem("Stop Recording", action: #selector(RemoteDeviceWindowController.stopScreenRecording(_:)), to: file).target = nil
        addItem("Save Recording…", action: #selector(RemoteDeviceWindowController.saveScreenRecording(_:)), to: file).target = nil
        addItem("Discard Recording…", action: #selector(RemoteDeviceWindowController.discardScreenRecording(_:)), to: file).target = nil
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
    private let inspectorContainer = NSViewController()
    private lazy var deviceInspector = ManagerDeviceInspectorController(model: model)
    private var inspectorMode = 0
    private let inspectorIdentifier = NSToolbarItem.Identifier("DeviceInspector")
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
        inspectorContainer.view = NSView()
        let inspector = NSSplitViewItem(inspectorWithViewController: inspectorContainer)
        inspector.minimumThickness = 280
        inspector.maximumThickness = 440
        inspector.canCollapse = false
        splitController.addSplitViewItem(inspector)
        showInspectorController(host)
    }

    private func showInspectorController(_ controller: NSViewController) {
        guard inspectorContainer.children.first !== controller else { return }
        for child in inspectorContainer.children {
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
        inspectorContainer.addChild(controller)
        let view = controller.view
        view.translatesAutoresizingMaskIntoConstraints = false
        inspectorContainer.view.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: inspectorContainer.view.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: inspectorContainer.view.trailingAnchor),
            view.topAnchor.constraint(equalTo: inspectorContainer.view.topAnchor),
            view.bottomAnchor.constraint(equalTo: inspectorContainer.view.bottomAnchor),
        ])
    }

    @objc private func changeInspector(_ sender: NSToolbarItemGroup) {
        inspectorMode = sender.selectedIndex
        if inspectorMode == 0, let inspectorHost { showInspectorController(inspectorHost) }
        else {
            deviceInspector.setPage(inspectorMode == 1 ? .content : .info)
            showInspectorController(deviceInspector)
        }
        updateDeviceSettings()
    }

    func stopInspectorReads() { deviceInspector.stopReading() }
    func finishInspectorPreviews() async throws { try await deviceInspector.finishPreviews() }
    func resumeInspectorAfterCancelledQuit() { deviceInspector.resumeAfterCancelledQuit() }

    private func makeDeviceSettingsView() -> AnyView {
        guard selectedDevices.count == 1, let selection = selectedDevices.first else {
            return inspectorMessage(selectedDevices.isEmpty ? "Select a Device" : "Multiple Devices Selected",
                                    description: "Select one device to adjust its settings.")
        }
        let inspectingSelection = model.inspectedDeviceIdentifier == selection.id
        return AnyView(ManagerDeviceSettingsView(device: selection,
            settings: inspectingSelection ? model.deviceSettings : nil,
            isBusy: model.isBusy || model.managingDeviceIDs.contains(selection.id),
            issue: inspectingSelection ? model.settingsIssue : nil, apply: { [weak self] setting in
                self?.model.setDeviceSetting(setting, for: selection.id)
            }, customLocation: { [weak self] in
                self?.presentLocationEditor(for: selection.id)
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
        viewScreen.isHidden = selections.count != 1
        viewScreen.isEnabled = selections.count == 1 && selections.first.map(canViewScreen) == true
        viewScreen.toolTip = nil
        updateDeviceSettings()
        Task { [weak self] in
            guard let self else { return }
            let identifier = self.selectedDevices.count == 1 ? self.selectedDevices.first?.id : nil
            await self.model.inspectDevice(identifier)
        }
    }

    private func updateDeviceSettings() {
        inspectorHost?.rootView = makeDeviceSettingsView()
        let selection = selectedDevices.count == 1 ? selectedDevices.first : nil
        deviceInspector.update(device: selection, isManaging: selection.map { model.managingDeviceIDs.contains($0.id) } == true,
                               isVisible: inspectorMode != 0)
    }

    private func presentLocationEditor(for identifier: DeviceInventoryID, latitude: String = "0", longitude: String = "0") {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Set Location"
        alert.informativeText = "Enter a latitude and longitude for the selected device."
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

    private func canViewScreen(_ device: InventoryDevice) -> Bool {
        guard !model.isBusy, !model.managingDeviceIDs.contains(device.id) else { return false }
        switch device {
        case .simulator(let simulator):
            return simulator.isAvailable && ["Booted", "Shutdown"].contains(simulator.state)
        case .remote(let remote):
            return remote.isAvailable && (remote.kind == .virtualMachine || remote.capabilities.contains("com.apple.coredevice.feature.viewdevicescreen"))
        }
    }

    @objc private func openSelectedDevice(_ sender: Any?) {
        guard selectedDevices.count == 1, let device = selectedDevices.first, canViewScreen(device) else { return }
        model.openScreen(for: device)
    }

    @objc private func refresh(_ sender: Any?) { Task { await model.refresh() } }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .flexibleSpace, newSimulatorIdentifier, filterIdentifier, .sidebarTrackingSeparator,
         .flexibleSpace, refreshIdentifier, .inspectorTrackingSeparator, inspectorIdentifier]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if itemIdentifier == inspectorIdentifier {
            let images = ["slider.horizontal.3", "doc", "info.circle"].compactMap {
                NSImage(systemSymbolName: $0, accessibilityDescription: nil)
            }
            let item = NSToolbarItemGroup(itemIdentifier: itemIdentifier, images: images, selectionMode: .selectOne,
                                          labels: ["Settings", "Content", "Info"], target: self, action: #selector(changeInspector(_:)))
            item.label = "Device Inspector"
            item.selectedIndex = inspectorMode
            item.visibilityPriority = .high
            return item
        }
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
        if devices.count == 1, canViewScreen(devices[0]) {
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
              let device = model.inventory.first(where: { $0.id == id }), canViewScreen(device) else { return }
        model.openScreen(for: device)
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

private extension InventoryDevice {
    var canInspectSettings: Bool {
        switch self {
        case .simulator(let device): device.isAvailable && device.state == "Booted"
        case .remote(let device): device.isAvailable
        }
    }
}

@MainActor
private struct ManagerDeviceSettingsView: View {
    let device: InventoryDevice?
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
            if device?.canInspectSettings == true, settings == nil, issue == nil {
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
        .disabled(isBusy || device?.canInspectSettings != true)
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
        guard let device else { return "Select a device to change its settings." }
        switch device {
        case .simulator(let simulator):
            guard simulator.isAvailable else { return "Install a compatible runtime to use this simulator’s settings." }
            guard simulator.state == "Booted" else { return "Start this simulator to change its settings." }
        case .remote(let remote):
            guard remote.isAvailable else { return "Connect this device to change its settings." }
        }
        if issue != nil || settings?.issues.isEmpty == false { return "Some settings could not be loaded for this device." }
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

private struct InspectorOperationFailure: LocalizedError {
    let deviceName: String
    let error: any Error
    var errorDescription: String? { "\(deviceName): \(error.localizedDescription)" }
    var recoverySuggestion: String? {
        guard let failure = error as? DeviceInspectorFailure else { return nil }
        switch failure.partialCompletion {
        case .applicationDataDownload(let destination):
            return "The incomplete export is retained at \(destination.path)."
        case .applicationDataReplacement(_, let stopped, let modified):
            return [stopped ? "The application may have been stopped." : nil,
                    modified ? "Its data may have been partially replaced. Inspect the application before retrying." : nil]
                .compactMap { $0 }.joined(separator: " ")
        case .reportDownload(let destination, let remaining, let updated):
            return "\(updated ? "The report was saved to \(destination.path). " : "")The remaining transfer data is at \(remaining.path)."
        case nil: return nil
        }
    }
}

@MainActor
private final class ManagerDeviceInspectorController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
                                                       NSSearchFieldDelegate, NSMenuDelegate {
    enum Page { case content, info }
    private enum Content: Int, CaseIterable {
        case applications, configuration, provisioning, reports
        var title: String {
            switch self {
            case .applications: "Applications"
            case .configuration: "Configuration Profiles"
            case .provisioning: "Provisioning Profiles"
            case .reports: "Reports"
            }
        }
        var profileKind: DeviceProfileKind { self == .provisioning ? .provisioning : .configuration }
    }
    private let model: SimulatorManagerModel
    private var device: InventoryDevice?
    private var inspector: DeviceInspector?
    private var page = Page.content
    private var content = Content.applications
    private var isManaging = false
    private var isVisible = false
    private var generation = 0
    private var readTask: Task<Void, Never>?
    private var iconTask: Task<Void, Never>?
    private var applications: [DeviceApplication] = []
    private var profiles: [DeviceProfile] = []
    private var reports: [DeviceReport] = []
    private var reportRows: [DeviceReport] = []
    private let reportFilter = NSPopUpButton()
    private var reportTypeFilter: String?
    private var previewGeneration = 0
    private var activePreviewTask: Task<Void, Never>?
    private var previewWindow: ManagerReportPreviewWindowController?
    private var currentPreview: DeviceReportPreview?
    private var retainedPreviews: [URL: DeviceReportPreview] = [:]
    private var previewTasks: [UUID: Task<Void, Never>] = [:]
    private var cleanupInFlight: Set<URL> = []
    private var cleanupFailures: [URL: any Error] = [:]
    private var preparingToQuit = false
    private let previewButton = NSButton(image: NSImage(systemSymbolName: "eye", accessibilityDescription: "Quick Look")!, target: nil, action: nil)
    private let downloadButton = NSButton(image: NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: "Download Report")!, target: nil, action: nil)
    private var appRows: [DeviceApplication] = []
    private var profileRows: [DeviceProfile] = []
    private var selectedRecordID: String?
    private var reloadingTable = false
    private let contentPicker = NSPopUpButton()
    private let search = NSSearchField()
    private let table = NSTableView()
    private let listScroll = NSScrollView()
    private let detail = ManagerInspectorPropertiesController()
    private let info = ManagerInspectorPropertiesController(visibilityPreferenceKey: "DeviceInfoHiddenFields")
    private let headerImage = NSImageView()
    private let headerName = NSTextField(labelWithString: "")
    private let headerSubtitle = NSTextField(labelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let addButton = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Install")!, target: nil, action: nil)
    private let removeButton = NSButton(image: NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove")!, target: nil, action: nil)
    private let launchButton = NSButton(image: NSImage(systemSymbolName: "play", accessibilityDescription: "Launch Application")!, target: nil, action: nil)
    private let actions = NSPopUpButton(frame: .zero, pullsDown: true)
    private let reloadButton = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh Inspector")!, target: nil, action: nil)
    private let contentView = NSView()
    private let infoView = NSView()
    private var lastIssue: String?
    private var reading = false

    init(model: SimulatorManagerModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView()
        contentPicker.addItems(withTitles: Content.allCases.map(\.title))
        contentPicker.target = self
        contentPicker.action = #selector(changeContent(_:))
        contentPicker.setAccessibilityLabel("Device Content")
        search.placeholderString = "Search Applications"
        search.delegate = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Record"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .inset
        table.rowHeight = 44
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelectedRecord(_:))
        table.setAccessibilityLabel("Installed Applications, Profiles, and Reports")
        listScroll.documentView = table
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.drawsBackground = false
        let listController = NSViewController()
        listController.view = listScroll
        let detailController = NSViewController()
        let header = NSStackView(views: [headerImage, NSStackView(views: [headerName, headerSubtitle])])
        header.orientation = .horizontal
        header.spacing = 8
        header.alignment = .centerY
        if let labels = header.views.last as? NSStackView {
            labels.orientation = .vertical
            labels.alignment = .leading
            labels.spacing = 3
        }
        headerName.font = .systemFont(ofSize: 13, weight: .semibold)
        headerName.lineBreakMode = .byTruncatingTail
        headerSubtitle.font = .systemFont(ofSize: 11)
        headerSubtitle.textColor = .secondaryLabelColor
        headerSubtitle.lineBreakMode = .byTruncatingMiddle
        headerImage.imageScaling = .scaleProportionallyUpOrDown
        headerImage.widthAnchor.constraint(equalToConstant: 32).isActive = true
        headerImage.heightAnchor.constraint(equalToConstant: 32).isActive = true
        let detailStack = NSStackView(views: [header, detail.view])
        detailStack.orientation = .vertical
        detailStack.alignment = .leading
        detailStack.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false
        detail.view.translatesAutoresizingMaskIntoConstraints = false
        detailController.view = detailStack
        NSLayoutConstraint.activate([
            header.widthAnchor.constraint(equalTo: detailStack.widthAnchor),
            detail.view.widthAnchor.constraint(equalTo: detailStack.widthAnchor),
        ])
        let contentSplit = NSSplitViewController()
        contentSplit.splitView.isVertical = false
        let listItem = NSSplitViewItem(viewController: listController)
        listItem.minimumThickness = 100
        listItem.preferredThicknessFraction = 0.45
        let detailItem = NSSplitViewItem(viewController: detailController)
        detailItem.minimumThickness = 120
        contentSplit.addSplitViewItem(listItem)
        contentSplit.addSplitViewItem(detailItem)
        addChild(contentSplit)
        addChild(detail)
        addChild(info)
        reportFilter.addItem(withTitle: "All Report Types")
        reportFilter.target = self
        reportFilter.action = #selector(changeReportFilter(_:))
        reportFilter.setAccessibilityLabel("Report Type")
        let contentStack = NSStackView(views: [contentPicker, search, reportFilter, contentSplit.view])
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 8
        pin(contentStack, in: contentView)
        for child in contentStack.views { child.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true }
        pin(info.view, in: infoView)
        for button in [addButton, removeButton, launchButton, previewButton, downloadButton, reloadButton] { button.bezelStyle = .automatic; button.target = self }
        addButton.action = #selector(install(_:))
        removeButton.action = #selector(remove(_:))
        launchButton.action = #selector(launch(_:))
        previewButton.action = #selector(quickLookReport(_:))
        downloadButton.action = #selector(downloadReport(_:))
        previewButton.toolTip = "Quick Look"
        downloadButton.toolTip = "Download Report…"
        reloadButton.action = #selector(refreshInspector(_:))
        addButton.toolTip = "Install…"
        removeButton.toolTip = "Remove…"
        launchButton.toolTip = "Launch Application"
        reloadButton.toolTip = "Refresh Inspector"
        actions.addItem(withTitle: "Actions")
        actions.menu?.delegate = self
        actions.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Application Actions")
        actions.imagePosition = .imageOnly
        actions.setAccessibilityLabel("Application Actions")
        let buttons = NSStackView(views: [addButton, removeButton, launchButton, actions, previewButton, downloadButton, NSView(), reloadButton])
        buttons.orientation = .horizontal
        buttons.spacing = 6
        let footer = NSStackView(views: [progress, status])
        footer.orientation = .horizontal
        footer.alignment = .top
        footer.spacing = 6
        progress.style = .spinning
        progress.controlSize = .small
        progress.widthAnchor.constraint(equalToConstant: 16).isActive = true
        progress.heightAnchor.constraint(equalToConstant: 16).isActive = true
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.setAccessibilityLabel("Inspector Status")
        let stack = NSStackView(views: [contentView, infoView, buttons, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        pin(stack, in: view, inset: 12)
        for child in stack.views { child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        updateVisibility()
        updateControls()
    }

    private func pin(_ child: NSView, in parent: NSView, inset: CGFloat = 0) {
        child.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
            child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset),
        ])
    }

    func setPage(_ page: Page) {
        guard self.page != page else { return }
        self.page = page
        _ = view
        updateVisibility()
        reload()
    }

    func update(device: InventoryDevice?, isManaging: Bool, isVisible: Bool) {
        _ = view
        let changed = self.device != device
        let becameVisible = !self.isVisible && isVisible
        self.device = device
        self.isManaging = isManaging
        self.isVisible = isVisible
        if changed {
            dismissReportPreview()
            stopReading()
            inspector = nil
            applications = []
            profiles = []
            reports = []
            reportTypeFilter = nil
            rebuildReportFilter()
            selectedRecordID = nil
            lastIssue = nil
            info.setProperties([:])
            updateRows()
        }
        if isVisible && (changed || becameVisible) { reload() }
        else if !isVisible { stopReading(); dismissReportPreview() }
        updateControls()
    }

    func stopReading() {
        generation += 1
        readTask?.cancel()
        readTask = nil
        iconTask?.cancel()
        iconTask = nil
        reading = false
    }

    private func updateVisibility() {
        contentView.isHidden = page != .content
        infoView.isHidden = page != .info
        let showingReports = page == .content && content == .reports
        for control in [addButton, removeButton, launchButton, actions] { control.isHidden = page != .content || showingReports }
        previewButton.isHidden = !showingReports
        downloadButton.isHidden = !showingReports
        reportFilter.isHidden = !showingReports
        if page != .content { dismissReportPreview() }
    }

    private var selectedApp: DeviceApplication? { appRows.first { $0.id == selectedRecordID } }
    private var selectedProfile: DeviceProfile? { profileRows.first { $0.id == selectedRecordID } }
    private var selectedReport: DeviceReport? { reportRows.first { $0.relativePath == selectedRecordID } }
    private var simulatorIsRunning: Bool {
        guard case .simulator(let simulator) = device else { return false }
        return simulator.isAvailable && simulator.state == "Booted"
    }
    private func supports(_ feature: String) -> Bool { device?.capabilities.contains("com.apple.coredevice.feature." + feature) == true }
    private var canReadApplications: Bool { simulatorIsRunning || supports("streamapplist") }
    private var canReadProfiles: Bool {
        if case .simulator(let simulator) = device, simulator.deviceSetPath != nil { return false }
        return supports(content == .provisioning ? "provisioningprofiles" : "configurationprofiles")
    }
    private var canTransferData: Bool { selectedApp?.isContainerAccessible == true && (simulatorIsRunning || supports("transferFiles")) }
    private var canReplaceData: Bool {
        canTransferData && (simulatorIsRunning || (supports("processcontrol") && supports("streamprocesslist") && canReadApplications))
    }
    private var available: Bool { device != nil && inspector != nil && !isManaging && !reading && !preparingToQuit }

    private func updateControls() {
        let apps = content == .applications
        contentPicker.isEnabled = !isManaging
        addButton.isEnabled = available && (apps ? simulatorIsRunning || supports("installapp") : canReadProfiles)
        removeButton.isEnabled = available && (apps ? selectedApp != nil && selectedApp?.isRemovable != false && (simulatorIsRunning || supports("uninstallapp")) : selectedProfile != nil && canReadProfiles && selectedProfile?.metadata["removalDisallowed"]?.boolean != true)
        launchButton.isHidden = page != .content || !apps
        launchButton.isEnabled = available && selectedApp != nil && (simulatorIsRunning || supports("launchapplication") || supports("applicationcontrol"))
        actions.isHidden = page != .content || !apps
        actions.isEnabled = available && selectedApp != nil
        let reportTransfer = available && selectedReport?.resources.isReadable != false && inspector?.supportsReportDownload == true
        previewButton.isEnabled = reportTransfer && selectedReport != nil && selectedReport?.resources.isDirectory == false && activePreviewTask == nil
        downloadButton.isEnabled = reportTransfer && selectedReport != nil
        reportFilter.isEnabled = !reading
        reloadButton.isEnabled = device != nil && !reading && !isManaging
        progress.isHidden = !reading && !isManaging && activePreviewTask == nil
        if progress.isHidden { progress.stopAnimation(nil) } else { progress.startAnimation(nil) }
        if device == nil { status.stringValue = "Select one device to inspect it." }
        else if isManaging { status.stringValue = "An operation is in progress on this device…" }
        else if reading { status.stringValue = "Loading…" }
        else if activePreviewTask != nil { status.stringValue = "Preparing preview…" }
        else { status.stringValue = lastIssue ?? "" }
        status.isHidden = status.stringValue.isEmpty
    }

    func reload() {
        stopReading()
        guard isVisible, !preparingToQuit, let device else { updateControls(); return }
        let request = generation
        let page = self.page
        let content = self.content
        reading = true
        lastIssue = nil
        updateControls()
        readTask = Task { [weak self] in
            guard let self else { return }
            do {
                let inspector = try await model.inspector(for: device)
                guard generation == request, !Task.isCancelled else { return }
                self.inspector = inspector
                if page == .info {
                    let snapshot = await inspector.info()
                    guard generation == request, !Task.isCancelled else { return }
                    var properties = snapshot.fields
                    if properties.isEmpty {
                        properties["name"] = .string(device.name)
                        if let os = device.operatingSystem { properties["operatingSystem"] = .string(os) }
                        if let model = device.modelIdentifier { properties["modelIdentifier"] = .string(model) }
                        switch device {
                        case .simulator(let simulator):
                            properties["udid"] = .string(simulator.identifier)
                            properties["state"] = .string(simulator.state)
                        case .remote(let remote):
                            properties["identifier"] = .string(remote.identifier)
                            if let udid = remote.udid { properties["udid"] = .string(udid) }
                            if let connection = remote.connectionState { properties["connectionState"] = .string(connection) }
                        }
                    }
                    info.setProperties(properties)
                    lastIssue = snapshot.issues.map(\.localizedDescription).joined(separator: "\n")
                } else if content == .applications {
                    guard canReadApplications else {
                        throw DeviceInspectorError.unsupported(device.kind == .simulator ? "Start this simulator to inspect its applications." : "This device does not currently support application inspection. Connect and unlock it, then refresh.")
                    }
                    let apps = try await inspector.applications()
                    guard generation == request, !Task.isCancelled else { return }
                    applications = apps
                    updateRows()
                    lastIssue = apps.isEmpty ? "No applications installed." : nil
                } else if content == .reports {
                    guard inspector.supportsReportListing || device.kind == .simulator else {
                        throw DeviceInspectorError.unsupported("This device does not currently support reports. Connect and unlock it, then refresh.")
                    }
                    let snapshot = try await inspector.reports()
                    guard generation == request, !Task.isCancelled else { return }
                    reports = snapshot.reports.sorted {
                        if $0.modificationDate != $1.modificationDate { return ($0.modificationDate ?? .distantPast) > ($1.modificationDate ?? .distantPast) }
                        return $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
                    }
                    rebuildReportFilter()
                    updateRows()
                    lastIssue = snapshot.issues.isEmpty ? (reports.isEmpty ? "No reports available." : nil)
                        : "\(snapshot.issues.count) reports returned incomplete metadata. Available reports are shown."
                } else {
                    guard canReadProfiles else {
                        let message: String
                        if case .simulator(let simulator) = device, simulator.deviceSetPath != nil {
                            message = "Profiles are unavailable for simulators in custom device sets."
                        } else { message = "This device does not currently support \(content.title.lowercased())." }
                        throw DeviceInspectorError.unsupported(message)
                    }
                    let snapshot = try await inspector.profiles(kind: content.profileKind)
                    guard generation == request, !Task.isCancelled else { return }
                    profiles = snapshot.profiles
                    updateRows()
                    let partial = content == .configuration ? snapshot.partialConfigurationProfiles : snapshot.partialProvisioningProfiles
                    lastIssue = partial.isEmpty ? (profileRows.isEmpty ? "No profiles installed." : nil)
                        : "\(partial.count) profiles returned incomplete records. Available profiles are shown."
                }
            } catch {
                guard generation == request, !Task.isCancelled else { return }
                lastIssue = error.localizedDescription
            }
            guard generation == request, !Task.isCancelled else { return }
            reading = false
            readTask = nil
            updateControls()
        }
    }

    @objc private func changeContent(_ sender: NSPopUpButton) {
        dismissReportPreview()
        content = Content(rawValue: sender.indexOfSelectedItem) ?? .applications
        updateVisibility()
        selectedRecordID = nil
        profiles = []
        search.stringValue = ""
        search.placeholderString = content == .applications ? "Search Applications" : (content == .reports ? "Search Reports" : "Search Profiles")
        updateRows()
        reload()
    }
    @objc private func refreshInspector(_ sender: Any?) { reload() }
    func controlTextDidChange(_ notification: Notification) { updateRows() }

    private func updateRows() {
        let query = search.stringValue
        appRows = content == .applications ? applications.filter { query.isEmpty || $0.name.localizedStandardContains(query) || $0.bundleIdentifier.localizedStandardContains(query) } : []
        profileRows = content == .applications || content == .reports ? [] : profiles.filter { $0.kind == content.profileKind && (query.isEmpty || $0.name.localizedStandardContains(query) || $0.identifier.localizedStandardContains(query)) }
        reportRows = content == .reports ? reports.filter { report in
            (reportTypeFilter == nil || reportType(report) == reportTypeFilter) && (query.isEmpty ||
                [report.name, report.relativePath, report.type.fileExtension, report.type.recordedLogType, report.type.bugType]
                    .compactMap { $0 }.contains { $0.localizedStandardContains(query) })
        } : []
        reloadingTable = true
        table.reloadData()
        let index = content == .applications ? appRows.firstIndex { $0.id == selectedRecordID }
            : content == .reports ? reportRows.firstIndex { $0.relativePath == selectedRecordID } : profileRows.firstIndex { $0.id == selectedRecordID }
        if let index { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        else { table.deselectAll(nil); selectedRecordID = nil; dismissReportPreview() }
        reloadingTable = false
        updateDetail()
    }
    func numberOfRows(in tableView: NSTableView) -> Int {
        content == .applications ? appRows.count : (content == .reports ? reportRows.count : profileRows.count)
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("InspectorRecord")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? ManagerInspectorRecordCell ?? ManagerInspectorRecordCell()
        cell.identifier = id
        if content == .applications {
            let app = appRows[row]
            cell.title.stringValue = app.name
            cell.subtitle.stringValue = app.bundleIdentifier
            if device?.kind == .simulator, let path = app.bundlePath { cell.icon.image = NSWorkspace.shared.icon(forFile: path) }
            else { cell.icon.image = NSImage(systemSymbolName: "app", accessibilityDescription: nil) }
        } else if content == .reports {
            let report = reportRows[row]
            cell.title.stringValue = report.name
            cell.subtitle.stringValue = [report.modificationDate?.formatted(date: .abbreviated, time: .shortened),
                report.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }].compactMap { $0 }.joined(separator: " · ")
            cell.icon.image = NSImage(systemSymbolName: report.resources.isDirectory ? "folder" : "doc.text", accessibilityDescription: nil)
        } else {
            let profile = profileRows[row]
            cell.title.stringValue = profile.name
            cell.subtitle.stringValue = profile.identifier
            cell.icon.image = NSImage(systemSymbolName: "doc.badge.gearshape", accessibilityDescription: nil)
        }
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !reloadingTable else { return }
        let row = table.selectedRow
        let id = row < 0 ? nil : (content == .applications ? appRows[row].id : (content == .reports ? reportRows[row].relativePath : profileRows[row].id))
        if selectedRecordID != id { dismissReportPreview() }
        selectedRecordID = id
        updateDetail()
    }

    private func updateDetail() {
        iconTask?.cancel()
        iconTask = nil
        headerImage.image = nil
        headerName.stringValue = content == .applications ? "Select an Application" : (content == .reports ? "Select a Report" : "Select a Profile")
        headerSubtitle.stringValue = ""
        headerSubtitle.toolTip = nil
        detail.setProperties([:])
        if let app = selectedApp {
            headerName.stringValue = app.name
            headerSubtitle.stringValue = app.bundleIdentifier
            detail.setProperties(app.metadata)
            if device?.kind == .simulator, let path = app.bundlePath { headerImage.image = NSWorkspace.shared.icon(forFile: path) }
            else { headerImage.image = NSImage(systemSymbolName: "app", accessibilityDescription: nil) }
            if supports("fetchappicons"), let inspector {
                let request = generation
                iconTask = Task { [weak self] in
                    do {
                        let data = try await inspector.applicationIcon(bundleIdentifier: app.bundleIdentifier)
                        guard let self, !Task.isCancelled, generation == request, selectedApp?.id == app.id else { return }
                        if let image = NSImage(data: data) { headerImage.image = image }
                    } catch {
                        guard let self, !Task.isCancelled, generation == request, selectedApp?.id == app.id else { return }
                        if let failure = error as? DeviceInspectorFailure,
                           case .cleanupFailed = failure.error as? DeviceInspectorError {
                            lastIssue = error.localizedDescription
                            updateControls()
                        }
                    }
                }
            }
        } else if let profile = selectedProfile {
            headerName.stringValue = profile.name
            headerSubtitle.stringValue = "Installed Profile Metadata"
            headerSubtitle.toolTip = "Installed payload bodies and entitlement values are not supplied by the device's public profile list."
            headerImage.image = NSImage(systemSymbolName: "doc.badge.gearshape", accessibilityDescription: nil)
            detail.setProperties(profile.metadata)
        } else if let report = selectedReport {
            headerName.stringValue = report.name
            headerSubtitle.stringValue = report.relativePath
            headerImage.image = NSImage(systemSymbolName: report.resources.isDirectory ? "folder" : "doc.text", accessibilityDescription: nil)
            var properties = report.metadata
            properties["relativePath"] = .string(report.relativePath)
            properties["fileExtension"] = .string(report.type.fileExtension)
            if let type = report.type.recordedLogType { properties["recordedLogType"] = .string(type) }
            if let bug = report.type.bugType { properties["bugType"] = .string(bug) }
            var resources: [String: DeviceInspectorValue] = ["isDirectory": .boolean(report.resources.isDirectory)]
            if let value = report.resources.isReadable { resources["isReadable"] = .boolean(value) }
            if let value = report.resources.isHidden { resources["isHidden"] = .boolean(value) }
            if let value = report.resources.isSymbolicLink { resources["isSymbolicLink"] = .boolean(value) }
            if let value = report.resources.isWritable { resources["isWritable"] = .boolean(value) }
            properties["resources"] = .object(resources)
            detail.setProperties(properties)
        }
        updateControls()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(NSMenuItem(title: "Actions", action: nil, keyEquivalent: ""))
        let items: [(String, Selector, Bool)] = [
            ("Show Container in Finder", #selector(revealContainer(_:)), simulatorIsRunning && selectedApp?.isContainerAccessible == true),
            ("Export Data…", #selector(exportData(_:)), canTransferData),
            ("Replace Data…", #selector(importData(_:)), canReplaceData),
        ]
        for (title, action, enabled) in items {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = available && enabled
            menu.addItem(item)
        }
        menu.autoenablesItems = false
    }

    private func reportType(_ report: DeviceReport) -> String {
        if let type = report.type.recordedLogType { return "Log Type: " + type }
        return report.type.fileExtension.isEmpty ? "No File Extension" : "." + report.type.fileExtension
    }

    private func rebuildReportFilter() {
        let types = Set(reports.map(reportType)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        if let reportTypeFilter, !types.contains(reportTypeFilter) { self.reportTypeFilter = nil }
        reportFilter.removeAllItems()
        reportFilter.addItems(withTitles: ["All Report Types"] + types)
        if let reportTypeFilter { reportFilter.selectItem(withTitle: reportTypeFilter) }
    }

    @objc private func changeReportFilter(_ sender: NSPopUpButton) {
        reportTypeFilter = sender.indexOfSelectedItem == 0 ? nil : sender.titleOfSelectedItem
        updateRows()
    }

    @objc private func openSelectedRecord(_ sender: Any?) {
        if content == .reports { quickLookReport(sender) }
        else if content == .applications { launch(sender) }
    }

    @objc private func downloadReport(_ sender: Any?) {
        guard available, downloadButton.isEnabled, let report = selectedReport, let inspector, let window = view.window else { return }
        let panel = NSSavePanel()
        panel.title = "Download Report"
        panel.message = "Download \(report.name) from \(inspector.device.name)."
        panel.nameFieldStringValue = (report.relativePath as NSString).lastPathComponent
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.mutate(using: inspector) { _ = try await $0.downloadReport(report, to: url, replacingExistingFile: true) }
        }
    }

    @objc private func quickLookReport(_ sender: Any?) {
        guard available, previewButton.isEnabled, !preparingToQuit, let report = selectedReport, let inspector else { return }
        dismissReportPreview()
        let request = previewGeneration
        let taskID = UUID()
        let cache = URL.cachesDirectory.appending(path: "dev.lynnswap.NeoSimulator/ReportPreviews", directoryHint: .isDirectory)
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                previewTasks.removeValue(forKey: taskID)
                if previewGeneration == request { activePreviewTask = nil; updateControls() }
            }
            do {
                let preview = try await inspector.previewReport(report, in: cache)
                retainedPreviews[preview.url] = preview
                guard !Task.isCancelled, previewGeneration == request, !preparingToQuit,
                      device?.id == report.deviceID, selectedReport?.id == report.id else {
                    removePreview(preview)
                    return
                }
                currentPreview = preview
                let window = ManagerReportPreviewWindowController(report: report, deviceName: inspector.device.name, url: preview.url)
                window.onClose = { [weak self] in self?.dismissReportPreview(closeWindow: false) }
                previewWindow = window
                window.showWindow(nil)
            } catch {
                if let failure = error as? DeviceInspectorFailure, case .cleanupFailed(let directory, _, _) = failure.error as? DeviceInspectorError {
                    cleanupFailures[directory] = error
                    if !preparingToQuit { model.onError?(InspectorOperationFailure(deviceName: inspector.device.name, error: error)) }
                } else if !Task.isCancelled, previewGeneration == request {
                    lastIssue = error.localizedDescription
                }
            }
        }
        activePreviewTask = task
        previewTasks[taskID] = task
        updateControls()
    }

    private func dismissReportPreview(closeWindow: Bool = true) {
        previewGeneration += 1
        activePreviewTask?.cancel()
        activePreviewTask = nil
        let window = previewWindow
        previewWindow = nil
        if closeWindow { window?.close() }
        if let preview = currentPreview {
            currentPreview = nil
            removePreview(preview)
        }
        if isViewLoaded { updateControls() }
    }

    private func removePreview(_ preview: DeviceReportPreview) {
        guard cleanupInFlight.insert(preview.url).inserted else { return }
        let taskID = UUID()
        previewTasks[taskID] = Task { [weak self] in
            guard let self else { return }
            defer { cleanupInFlight.remove(preview.url); previewTasks.removeValue(forKey: taskID) }
            do {
                try await preview.removeCachedCopy()
                retainedPreviews.removeValue(forKey: preview.url)
                cleanupFailures.removeValue(forKey: preview.url)
            } catch {
                cleanupFailures[preview.url] = error
                if !preparingToQuit { model.onError?(InspectorOperationFailure(deviceName: preview.report.name, error: error)) }
            }
        }
    }

    func finishPreviews() async throws {
        preparingToQuit = true
        dismissReportPreview()
        for preview in Array(retainedPreviews.values) { removePreview(preview) }
        // A cancelled download can finish by scheduling its cache removal; drain both.
        while !previewTasks.isEmpty {
            for task in Array(previewTasks.values) { await task.value }
        }
        for (directory, original) in cleanupFailures where retainedPreviews[directory] == nil {
            do {
                try await removeFailedReportPreviewDirectory(directory)
                cleanupFailures.removeValue(forKey: directory)
            } catch {
                cleanupFailures[directory] = DeviceInspectorError.cleanupFailed(directory: directory, operationError: original, cleanupError: error)
            }
        }
        if let failure = cleanupFailures.values.first { throw failure }
    }

    func resumeAfterCancelledQuit() {
        preparingToQuit = false
        reload()
    }

    private func mutate(using inspector: DeviceInspector, operation: @escaping @Sendable (DeviceInspector) async throws -> Void) {
        let destination = inspector.device
        model.performInspectorOperation(for: destination, operation: { try await operation(inspector) }) { [weak self] in
            guard let self, self.device?.id == destination.id else { return }
            self.reload()
        }
    }

    @objc private func install(_ sender: Any?) {
        guard available, let inspector, let window = view.window else { return }
        let content = self.content
        let panel = NSOpenPanel()
        panel.message = content == .applications ? "Choose an application to install on \(inspector.device.name)." : "Choose a profile to install on \(inspector.device.name)."
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = content == .applications
            ? [UTType.applicationBundle]
            : [UTType(filenameExtension: content == .configuration ? "mobileconfig" : "mobileprovision") ?? .data]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.mutate(using: inspector) { inspector in
                if content == .applications { try await inspector.installApplication(at: url) }
                else { try await inspector.installProfile(at: url, kind: content.profileKind) }
            }
        }
    }
    @objc private func remove(_ sender: Any?) {
        guard available, removeButton.isEnabled, let inspector, let window = view.window else { return }
        let app = selectedApp
        let profile = selectedProfile
        guard app != nil || profile != nil else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove \(app?.name ?? profile!.name) from \(inspector.device.name)?"
        alert.informativeText = app != nil ? "The application and its data will be removed." : "Settings supplied by this profile will be removed."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.mutate(using: inspector) { inspector in
                if let app { try await inspector.uninstallApplication(bundleIdentifier: app.bundleIdentifier) }
                else if let profile { try await inspector.removeProfile(identifier: profile.identifier, kind: profile.kind) }
            }
        }
    }
    @objc private func launch(_ sender: Any?) {
        guard available, launchButton.isEnabled, let app = selectedApp, let inspector else { return }
        mutate(using: inspector) { try await $0.launchApplication(bundleIdentifier: app.bundleIdentifier) }
    }
    @objc private func revealContainer(_ sender: Any?) {
        guard available, simulatorIsRunning, let app = selectedApp, let inspector else { return }
        let request = generation
        readTask = Task { [weak self] in
            do {
                let url = try await inspector.applicationContainerURL(bundleIdentifier: app.bundleIdentifier)
                guard let self, generation == request, !Task.isCancelled else { return }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                guard let self, generation == request, !Task.isCancelled else { return }
                lastIssue = error.localizedDescription
                updateControls()
            }
        }
    }
    @objc private func exportData(_ sender: Any?) {
        guard available, canTransferData, let app = selectedApp, let inspector, let window = view.window else { return }
        let panel = NSSavePanel()
        panel.title = "Export Application Data"
        panel.message = "Export data for \(app.name) on \(inspector.device.name)."
        panel.nameFieldStringValue = app.bundleIdentifier + ".xcappdata"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if let type = UTType(filenameExtension: "xcappdata") { panel.allowedContentTypes = [type] }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.mutate(using: inspector) {
                try await $0.downloadApplicationData(bundleIdentifier: app.bundleIdentifier, to: url, replacingExistingFile: true)
            }
        }
    }
    @objc private func importData(_ sender: Any?) {
        guard available, canReplaceData, let app = selectedApp, let inspector, let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose application data to replace \(app.name)’s data on \(inspector.device.name)."
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Replace \(app.name)’s data on \(inspector.device.name)?"
            alert.informativeText = "The application will be stopped and its current data replaced with the selected data."
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                self?.mutate(using: inspector) { try await $0.replaceApplicationData(bundleIdentifier: app.bundleIdentifier, from: url) }
            }
        }
    }
}

@MainActor
private final class ManagerInspectorRecordCell: NSTableCellView {
    let title = NSTextField(labelWithString: "")
    let subtitle = NSTextField(labelWithString: "")
    let icon = NSImageView()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title.font = .systemFont(ofSize: 12, weight: .medium)
        subtitle.font = .systemFont(ofSize: 10)
        subtitle.textColor = .secondaryLabelColor
        title.lineBreakMode = .byTruncatingTail
        subtitle.lineBreakMode = .byTruncatingMiddle
        let labels = NSStackView(views: [title, subtitle])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        let stack = NSStackView(views: [icon, labels])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 28), icon.heightAnchor.constraint(equalToConstant: 28),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        imageView = icon
        textField = title
    }
    required init?(coder: NSCoder) { nil }
}

@MainActor
private final class ManagerInspectorPropertiesController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    private final class Property: NSObject {
        let name: String
        let value: DeviceInspectorValue
        let path: [String]
        let children: [Property]
        init(name: String, value: DeviceInspectorValue, path: [String]) {
            self.name = name
            self.value = value
            self.path = path
            switch value {
            case .object(let fields): children = Self.properties(fields, parentPath: path)
            case .array(let values): children = values.enumerated().map { Property(name: "Item \($0.offset + 1)", value: $0.element, path: path + [String($0.offset)]) }
            default: children = []
            }
        }
        private init(name: String, value: DeviceInspectorValue, path: [String], children: [Property]) {
            self.name = name
            self.value = value
            self.path = path
            self.children = children
        }
        static func properties(_ fields: [String: DeviceInspectorValue], parentPath: [String] = []) -> [Property] {
            fields.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { Property(name: $0, value: fields[$0]!, path: parentPath + [$0]) }
        }
        func visible(hiding paths: Set<[String]>) -> Property? {
            guard !paths.contains(path) else { return nil }
            let visibleChildren = children.compactMap { $0.visible(hiding: paths) }
            guard children.isEmpty || !visibleChildren.isEmpty else { return nil }
            return Property(name: name, value: value, path: path, children: visibleChildren)
        }
        var displayName: String {
            let names = ["CFBundleIdentifier": "Bundle Identifier", "CFBundleDisplayName": "Display Name", "CFBundleName": "Name",
                         "CFBundleShortVersionString": "Version", "CFBundleVersion": "Build", "IsDeveloperApp": "Developer Application",
                         "IsRemovable": "Removable", "udid": "UDID", "uuid": "UUID", "osVersion": "OS Version", "osBuild": "OS Build",
                         "hardware": "Hardware Properties", "software": "Software Properties", "connection": "Connection Properties",
                         "state": children.isEmpty ? "State" : "Device Properties", "ecid": "ECID", "cpuType": "CPU Type",
                         "osVersionNumber": "OS Version", "osBuildVersions": "OS Builds", "ddiServicesAvailable": "DDI Services",
                         "tunnelIPAddressString": "Tunnel IP Address", "rootFileSystemIsWritable": "Writable Root File System"]
            return names[name] ?? name.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).capitalized
        }
        var displayValue: String {
            switch value {
            case .object(let values): "\(values.count) properties"
            case .array(let values): "\(values.count) items"
            case .string(let string): string
            case .integer(let number): String(number)
            case .number(let number): String(number)
            case .boolean(let enabled): enabled ? "Yes" : "No"
            case .date(let date): date.formatted()
            case .data(let data): "\(data.count) bytes"
            case .null: "—"
            }
        }
    }
    private let table = NSOutlineView()
    private let visibleFields = NSPopUpButton(frame: .zero, pullsDown: true)
    private let hiddenNotice = NSTextField(wrappingLabelWithString: "All fields are hidden. Choose Visible Fields to show them.")
    private let visibilityPreferenceKey: String?
    private let defaults: UserDefaults
    private var hiddenPaths: Set<[String]>
    private var allProperties: [Property] = []
    private var properties: [Property] = []

    init(visibilityPreferenceKey: String? = nil, defaults: UserDefaults = .standard) {
        self.visibilityPreferenceKey = visibilityPreferenceKey
        self.defaults = defaults
        hiddenPaths = Set(visibilityPreferenceKey.flatMap { defaults.array(forKey: $0) as? [[String]] } ?? [])
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let name = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Property"))
        name.title = "Property"
        name.width = 130
        name.minWidth = 80
        let value = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Value"))
        value.title = "Value"
        value.width = 150
        value.minWidth = 80
        table.addTableColumn(name)
        table.addTableColumn(value)
        table.outlineTableColumn = name
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.style = .inset
        table.rowHeight = 24
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Properties")
        scroll.documentView = table
        if visibilityPreferenceKey != nil {
            visibleFields.addItem(withTitle: "Visible Fields")
            visibleFields.menu?.delegate = self
            visibleFields.setAccessibilityLabel("Visible Info Fields")
            hiddenNotice.font = .systemFont(ofSize: 11)
            hiddenNotice.textColor = .secondaryLabelColor
            let stack = NSStackView(views: [visibleFields, hiddenNotice, scroll])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 8
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            hiddenNotice.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            view = stack
        } else { view = scroll }
        updateVisibleProperties()
    }
    func setProperties(_ fields: [String: DeviceInspectorValue]) {
        _ = view
        allProperties = Property.properties(fields)
        updateVisibleProperties()
    }
    private func updateVisibleProperties() {
        properties = allProperties.compactMap { $0.visible(hiding: hiddenPaths) }
        table.reloadData()
        for property in properties where !property.children.isEmpty { table.expandItem(property) }
        visibleFields.isEnabled = !allProperties.isEmpty
        hiddenNotice.isHidden = allProperties.isEmpty || !properties.isEmpty
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        menu.addItem(NSMenuItem(title: "Visible Fields", action: nil, keyEquivalent: ""))
        let showAll = NSMenuItem(title: "Show All Fields", action: #selector(showAllFields(_:)), keyEquivalent: "")
        showAll.target = self
        menu.addItem(showAll)
        menu.addItem(.separator())
        addFieldItems(allProperties, to: menu)
    }
    private func addFieldItems(_ fields: [Property], to menu: NSMenu) {
        menu.autoenablesItems = false
        for field in fields {
            let item = NSMenuItem(title: field.displayName, action: #selector(toggleField(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = field.path
            let hiddenByAncestor = hiddenPaths.contains { field.path.starts(with: $0) }
            if hiddenByAncestor || field.visible(hiding: hiddenPaths) == nil { item.state = .off }
            else if hiddenPaths.contains(where: { $0.starts(with: field.path) }) { item.state = .mixed }
            else { item.state = .on }
            if !field.children.isEmpty {
                let submenu = NSMenu(title: field.displayName)
                let showGroup = NSMenuItem(title: "Show \(field.displayName)", action: #selector(toggleField(_:)), keyEquivalent: "")
                showGroup.target = self
                showGroup.representedObject = field.path
                showGroup.state = item.state
                submenu.addItem(showGroup)
                submenu.addItem(.separator())
                addFieldItems(field.children, to: submenu)
                item.action = nil
                item.submenu = submenu
            }
            menu.addItem(item)
        }
    }
    @objc private func toggleField(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? [String] else { return }
        if sender.state == .off {
            hiddenPaths = hiddenPaths.filter { !$0.starts(with: path) && !path.starts(with: $0) }
        } else { hiddenPaths.insert(path) }
        saveVisibility()
    }
    @objc private func showAllFields(_ sender: Any?) {
        hiddenPaths = []
        saveVisibility()
    }
    private func saveVisibility() {
        if let visibilityPreferenceKey {
            defaults.set(hiddenPaths.sorted { $0.lexicographicallyPrecedes($1) }, forKey: visibilityPreferenceKey)
        }
        updateVisibleProperties()
    }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? Property)?.children.count ?? properties.count }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { ((item as? Property)?.children ?? properties)[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { !(item as! Property).children.isEmpty }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let property = item as! Property
        let id = tableColumn!.identifier
        let label = outlineView.makeView(withIdentifier: id, owner: self) as? NSTextField ?? NSTextField(labelWithString: "")
        label.identifier = id
        label.font = .systemFont(ofSize: 11)
        label.isSelectable = true
        label.lineBreakMode = .byTruncatingMiddle
        label.stringValue = id.rawValue == "Property" ? property.displayName : property.displayValue
        label.toolTip = label.stringValue
        return label
    }
}


@MainActor
private final class ManagerReportPreviewWindowController: NSWindowController, NSWindowDelegate {
    private let previewView: QLPreviewView
    private var closed = false
    var onClose: (() -> Void)?

    init(report: DeviceReport, deviceName: String, url: URL) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = report.name
        window.subtitle = deviceName
        window.minSize = NSSize(width: 360, height: 260)
        window.isReleasedWhenClosed = false
        previewView = QLPreviewView(frame: window.contentLayoutRect, style: .normal)
        super.init(window: window)
        previewView.shouldCloseWithWindow = false
        previewView.autostarts = false
        window.contentView = previewView
        window.delegate = self
        window.center()
        previewView.previewItem = url as NSURL
    }
    required init?(coder: NSCoder) { nil }
    func windowWillClose(_ notification: Notification) {
        guard !closed else { return }
        closed = true
        previewView.close()
        onClose?()
        onClose = nil
    }
}


@concurrent private func removeFailedReportPreviewDirectory(_ directory: URL) async throws {
    do { try FileManager.default.removeItem(at: directory) }
    catch let error as CocoaError where error.code == .fileNoSuchFile {}
}

private enum RemoteDeviceWindowError: LocalizedError {
    case cleanup([String])
    case unavailable(String)
    var errorDescription: String? {
        switch self {
        case .cleanup(let failures): failures.joined(separator: "\n")
        case .unavailable(let message): message
        }
    }
}

@MainActor
private final class RemoteDeviceWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation {
    private enum RecordingDestination: Sendable {
        case automatic(URL), selected(URL)

        var url: URL {
            switch self {
            case .automatic(let url), .selected(let url): url
            }
        }
    }
    let device: CoreDeviceDevice
    let session: RemoteDeviceScreenSession
    var onClose: (() -> Void)?
    private let viewport = NSView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let retryButton = NSButton(title: "Reconnect", target: nil, action: nil)
    private let inputView: RemoteDeviceInputView
    private var connectionTask: Task<Void, Never>?
    private var stoppingTask: Task<Void, any Error>?
    private var inputTask: Task<Void, Never>?
    private var captureTask: Task<Void, any Error>?
    private var completedScreenshot: CGImage?
    private var capturePanel: NSSavePanel?
    private var recordingTask: Task<Void, any Error>?
    private var recordingTaskIdentifier: UUID?
    private var finishingRecording = false
    private var recordingPanel: NSSavePanel?
    private var recordingDestination: RecordingDestination?
    private var closing = false
    private var mayClose = false
    private var compact = false
    private var regularFrame: NSRect?
    private var inventoryAvailable = true
    private var issue: String?
    private var toolbarItems: [String: NSToolbarItem] = [:]
    private let writeImage: @MainActor (CGImage, URL) async throws -> Void
    private let presentSavePanel: @MainActor (NSSavePanel, NSWindow) async -> NSApplication.ModalResponse
    private let presentAlert: @MainActor (NSAlert, NSWindow) async -> NSApplication.ModalResponse

    init(device: CoreDeviceDevice, session: RemoteDeviceScreenSession? = nil,
         writeImage: @escaping @MainActor (CGImage, URL) async throws -> Void = { image, destination in
             try await RemoteDeviceWindowController.writeScreenshot(image, to: destination)
         },
         presentSavePanel: @escaping @MainActor (NSSavePanel, NSWindow) async -> NSApplication.ModalResponse = { panel, window in
             await withCheckedContinuation { continuation in
                 panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
             }
         },
         presentAlert: @escaping @MainActor (NSAlert, NSWindow) async -> NSApplication.ModalResponse = { alert, window in
             await withCheckedContinuation { continuation in
                 alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
             }
         }) {
        self.device = device
        let session = session ?? RemoteDeviceScreenSession(device: device)
        self.session = session
        self.writeImage = writeImage
        self.presentSavePanel = presentSavePanel
        self.presentAlert = presentAlert
        inputView = RemoteDeviceInputView(session: session)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = device.name
        window.subtitle = [device.platform, device.osVersion].compactMap { $0 }.joined(separator: " ")
        window.minSize = NSSize(width: 240, height: 280)
        window.isReleasedWhenClosed = false
        window.tabbingIdentifier = "NeoSimulatorRemoteDevice"
        window.tabbingMode = .automatic
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.acceptsMouseMovedEvents = true
        window.toolbarStyle = .unifiedCompact
        super.init(window: window)
        window.delegate = self
        let root = NSView()
        viewport.wantsLayer = true
        viewport.layer?.backgroundColor = NSColor.black.cgColor
        viewport.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(viewport)
        session.contentView.translatesAutoresizingMaskIntoConstraints = false
        viewport.addSubview(session.contentView)
        inputView.translatesAutoresizingMaskIntoConstraints = false
        viewport.addSubview(inputView)
        let footer = NSStackView(views: [progress, statusLabel, retryButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        footer.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        footer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(footer)
        progress.style = .spinning
        progress.controlSize = .small
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        retryButton.target = self
        retryButton.action = #selector(reconnect(_:))
        retryButton.controlSize = .small
        NSLayoutConstraint.activate([
            viewport.leadingAnchor.constraint(equalTo: root.leadingAnchor), viewport.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            viewport.topAnchor.constraint(equalTo: root.topAnchor), viewport.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor), footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            progress.widthAnchor.constraint(equalToConstant: 16), progress.heightAnchor.constraint(equalToConstant: 16),
            session.contentView.leadingAnchor.constraint(equalTo: viewport.leadingAnchor), session.contentView.trailingAnchor.constraint(equalTo: viewport.trailingAnchor),
            session.contentView.topAnchor.constraint(equalTo: viewport.topAnchor), session.contentView.bottomAnchor.constraint(equalTo: viewport.bottomAnchor),
            inputView.leadingAnchor.constraint(equalTo: viewport.leadingAnchor), inputView.trailingAnchor.constraint(equalTo: viewport.trailingAnchor),
            inputView.topAnchor.constraint(equalTo: viewport.topAnchor), inputView.bottomAnchor.constraint(equalTo: viewport.bottomAnchor),
        ])
        window.contentView = root
        let toolbar = NSToolbar(identifier: "NeoSimulatorRemoteScreen")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        window.toolbar = toolbar
        window.center()
        inputView.enqueue = { [weak self] operation in self?.enqueueInput(operation) }
        session.onInputCapabilitiesLost = { [weak self] kinds in self?.inputView.invalidateInputs(for: kinds) }
        session.onStateChange = { [weak self] in self?.update() }
        update()
    }
    required init?(coder: NSCoder) { nil }

    func connectIfNeeded() {
        guard !closing, connectionTask == nil, session.state != .connected else { return }
        issue = nil
        connectionTask = Task { [weak self] in
            guard let self else { return }
            defer { self.connectionTask = nil; self.update() }
            do { try await self.session.start() }
            catch is CancellationError {}
            catch { if !self.closing { self.showIssue(error) } }
        }
    }

    func updateInventory(_ snapshot: InventoryDevice?) {
        let wasAvailable = inventoryAvailable
        if case .remote(let current) = snapshot {
            window?.title = current.name
            inventoryAvailable = current.isAvailable
        } else { inventoryAvailable = false }
        if wasAvailable, !closing, !inventoryAvailable, session.state == .connected || session.state == .connecting {
            Task { [weak self] in
                do { try await self?.stop() }
                catch is CancellationError {}
                catch { self?.showIssue(error) }
            }
        }
        update()
    }

    private func update() {
        let connected = session.state == .connected && !closing
        let busy = session.state == .connecting || session.state == .stopping || captureTask != nil || recordingTask != nil
        let native = session.nativeInputView
        inputView.isHidden = native != nil
        native?.isHidden = closing
        if let native, !closing, window?.isKeyWindow == true { window?.makeFirstResponder(native) }
        inputView.isInputEnabled = connected
        for name in ["home", "lock", "volumeDown", "volumeUp"] {
            toolbarItems[name]?.isEnabled = connected && session.inputCapabilities.contains(.button)
        }
        toolbarItems["capture"]?.isEnabled = canSaveScreenshot
        toolbarItems["capture"]?.toolTip = completedScreenshot != nil ? "Save the captured screenshot…"
            : session.canCaptureScreenshot ? "Save Screenshot…" : "Screenshot capture is not available for this display yet."
        let recordingLabel: String
        let recordingSymbol: String
        if session.hasUnfinishedRecording {
            recordingLabel = "Stop Recording"
            recordingSymbol = "stop.circle"
            toolbarItems["record"]?.isEnabled = !closing && !finishingRecording && session.recordingState != .stopping
        } else if session.completedRecording != nil {
            recordingLabel = "Save Recording…"
            recordingSymbol = "square.and.arrow.down"
            toolbarItems["record"]?.isEnabled = !closing && recordingTask == nil
        } else {
            recordingLabel = "Record Screen"
            recordingSymbol = "record.circle"
            toolbarItems["record"]?.isEnabled = canStartRecording
        }
        toolbarItems["record"]?.label = recordingLabel
        toolbarItems["record"]?.toolTip = session.canRecordScreen || session.hasUnfinishedRecording || session.completedRecording != nil
            ? recordingLabel : "Screen recording is not available for this display yet."
        toolbarItems["record"]?.image = NSImage(systemSymbolName: recordingSymbol, accessibilityDescription: recordingLabel)
        toolbarItems["record"]?.menuFormRepresentation?.title = recordingLabel
        toolbarItems["reconnect"]?.isEnabled = !busy && !closing && inventoryAvailable
        retryButton.isHidden = session.state != .failed && session.state != .stopped
        retryButton.isEnabled = !closing && inventoryAvailable
        progress.isHidden = !busy
        if busy { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        if let transportIssue = session.lastError?.localizedDescription {
            statusLabel.stringValue = issue.map { $0 == transportIssue ? $0 : "\($0)\n\(transportIssue)" } ?? transportIssue
        }
        else if captureTask != nil { statusLabel.stringValue = "Saving screenshot…" }
        else if session.recordingState == .starting { statusLabel.stringValue = "Starting recording…" }
        else if session.recordingState == .stopping { statusLabel.stringValue = "Finishing recording…" }
        else if recordingTask != nil { statusLabel.stringValue = "Saving recording…" }
        else if let issue { statusLabel.stringValue = issue }
        else if session.hasUnfinishedRecording { statusLabel.stringValue = "Recording" }
        else if completedScreenshot != nil { statusLabel.stringValue = "Screenshot ready to save." }
        else if session.completedRecording != nil { statusLabel.stringValue = "Recording ready to save." }
        else if !inventoryAvailable { statusLabel.stringValue = "The device is unavailable." }
        else {
            statusLabel.stringValue = switch session.state {
            case .idle: "Ready to connect."
            case .connecting: "Connecting…"
            case .connected: session.hasReceivedFrame || native != nil ? "Connected" : "Connected. Waiting for the first frame…"
            case .stopping: "Disconnecting…"
            case .stopped: "Disconnected"
            case .failed: "The screen connection failed."
            }
        }
        statusLabel.toolTip = statusLabel.stringValue
        for item in toolbarItems.values { item.menuFormRepresentation?.isEnabled = item.isEnabled }
    }

    private func showIssue(_ error: any Error) { issue = error.localizedDescription; update() }

    private func enqueueInput(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !closing else { return }
        let preceding = inputTask
        inputTask = Task { [weak self] in
            await preceding?.value
            do { try await operation() }
            catch { self?.showIssue(error) }
        }
    }

    private func stop() async throws {
        if let stoppingTask { try await stoppingTask.value; return }
        closing = true
        capturePanel?.cancel(nil)
        capturePanel = nil
        recordingPanel?.cancel(nil)
        window?.makeFirstResponder(nil)
        connectionTask?.cancel()
        let acceptedCapture = captureTask
        let acceptedRecording = recordingTask
        update()
        let task = Task { [self] in
            await inputTask?.value
            try await session.releaseInputs()
            do { try await acceptedCapture?.value }
            catch is CancellationError {}
            catch {
                guard completedScreenshot != nil else { throw error }
                // A failed write keeps its pixels; resolve them before disconnecting below.
            }
            try await finishScreenshotBeforeDisconnect()
            try await acceptedRecording?.value
            try await finishRecordingBeforeDisconnect()
            var failure: (any Error)?
            do { try await session.stop() }
            catch {
                failure = error
            }
            await connectionTask?.value
            if let failure { throw failure }
        }
        stoppingTask = task
        defer {
            stoppingTask = nil
            closing = false
            update()
            if session.state == .connected { window?.makeFirstResponder(session.nativeInputView ?? inputView) }
        }
        do { try await task.value }
        catch is CancellationError { throw CancellationError() }
        catch { showIssue(error); throw error }
    }

    func stopAndClose() async throws {
        try await stop()
        mayClose = true
        window?.close()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if mayClose { return true }
        Task { [weak self] in
            do { try await self?.stopAndClose() }
            catch is CancellationError {}
            catch { self?.showIssue(error) }
        }
        return false
    }
    func windowWillClose(_ notification: Notification) { onClose?(); onClose = nil }
    func windowDidBecomeKey(_ notification: Notification) {
        window?.makeFirstResponder(session.nativeInputView ?? inputView)
    }
    func windowDidResignKey(_ notification: Notification) {
        window?.makeFirstResponder(nil)
        inputView.releaseFocus()
    }

    @objc private func reconnect(_ sender: Any?) {
        guard !closing, stoppingTask == nil else { return }
        Task { [weak self] in
            guard let self else { return }
            do { try await self.stop(); self.connectIfNeeded() }
            catch is CancellationError {}
            catch { self.showIssue(error) }
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        ["home", "lock", "volumeDown", "volumeUp", NSToolbarItem.Identifier.flexibleSpace.rawValue, "capture", "record", "compact", "reconnect"].map { NSToolbarItem.Identifier($0) }
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let labels: [String: (String, String)] = [
            "home": ("Home", "house"), "lock": ("Lock", "lock"),
            "volumeDown": ("Volume Down", "speaker.minus"), "volumeUp": ("Volume Up", "speaker.plus"),
            "capture": ("Save Screenshot…", "camera"), "compact": ("Compact Window", "arrow.down.right.and.arrow.up.left"),
            "record": ("Record Screen", "record.circle"),
            "reconnect": ("Reconnect", "arrow.clockwise"),
        ]
        guard let (label, symbol) = labels[itemIdentifier.rawValue] else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = label
        item.toolTip = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.target = self
        item.action = #selector(toolbarAction(_:))
        item.autovalidates = false
        let menuItem = NSMenuItem(title: label, action: #selector(toolbarAction(_:)), keyEquivalent: "")
        menuItem.target = self
        menuItem.representedObject = itemIdentifier.rawValue
        item.menuFormRepresentation = menuItem
        toolbarItems[itemIdentifier.rawValue] = item
        update()
        return item
    }
    @objc private func toolbarAction(_ sender: Any) {
        guard let identifier = (sender as? NSToolbarItem)?.itemIdentifier.rawValue ?? (sender as? NSMenuItem)?.representedObject as? String else { return }
        switch identifier {
        case "compact": toggleCompact()
        case "reconnect": reconnect(sender)
        case "capture": saveScreenshot()
        case "record":
            if session.hasUnfinishedRecording { stopScreenRecording(sender) }
            else if session.completedRecording != nil { saveScreenRecording(sender) }
            else { recordScreen(sender) }
        default:
            let usage: Int? = switch identifier {
            case "home": 0x40
            case "lock": 0x30
            case "volumeDown": 0xea
            case "volumeUp": 0xe9
            default: nil
            }
            guard let usage, session.state == .connected, session.inputCapabilities.contains(.button) else { return }
            inputView.enqueueInput(for: .button) { [session] in
                try await session.sendButton(usagePage: 0x0c, usage: usage, state: .down)
                try await session.sendButton(usagePage: 0x0c, usage: usage, state: .up)
            }
        }
    }

    private func toggleCompact() {
        guard let window else { return }
        compact.toggle()
        if compact {
            regularFrame = window.frame
            let size = NSSize(width: max(240, window.frame.width * 0.6), height: max(280, window.frame.height * 0.6))
            window.setFrame(NSRect(origin: window.frame.origin, size: size), display: true, animate: true)
            window.toolbarStyle = .unifiedCompact
        } else if let regularFrame { window.setFrame(regularFrame, display: true, animate: true) }
        toolbarItems["compact"]?.label = compact ? "Standard Window" : "Compact Window"
        toolbarItems["compact"]?.toolTip = toolbarItems["compact"]?.label
        window.makeFirstResponder(session.nativeInputView ?? inputView)
    }

    private var canStartRecording: Bool {
        !closing && inventoryAvailable && session.canRecordScreen && !session.hasUnfinishedRecording
            && session.completedRecording == nil && recordingTask == nil && recordingPanel == nil
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(saveRemoteScreenshot(_:)):
            return canSaveScreenshot
        case #selector(discardRemoteScreenshot(_:)):
            return !closing && completedScreenshot != nil && captureTask == nil && capturePanel == nil
        case #selector(recordScreen(_:)), #selector(recordScreenTo(_:)): return canStartRecording
        case #selector(stopScreenRecording(_:)):
            return !closing && !finishingRecording && session.hasUnfinishedRecording && session.recordingState != .stopping
        case #selector(saveScreenRecording(_:)), #selector(discardScreenRecording(_:)):
            return !closing && session.completedRecording != nil && recordingTask == nil
        case #selector(toolbarAction(_:)):
            guard let identifier = menuItem.representedObject as? String else { return false }
            return toolbarItems[identifier]?.isEnabled == true
        default: return true
        }
    }

    @objc func saveRemoteScreenshot(_ sender: Any?) { saveScreenshot() }

    @objc func recordScreen(_ sender: Any?) {
        guard canStartRecording else { return }
        guard let directory = captureDirectory else {
            showIssue(RemoteDeviceWindowError.unavailable("Choose a recording destination using File → Record Screen…."))
            return
        }
        startRecording(to: directory.appendingPathComponent(recordingFilename))
    }

    @objc func recordScreenTo(_ sender: Any?) {
        guard canStartRecording else { return }
        runRecordingOperation { [self] in
            let destination = try await chooseRecordingDestination()
            guard !closing, inventoryAvailable, session.canRecordScreen else { throw CancellationError() }
            recordingDestination = .selected(destination)
            try await session.startRecording()
        }
    }

    private func startRecording(to destination: URL) {
        guard canStartRecording else { return }
        recordingDestination = .automatic(destination)
        runRecordingOperation { [session] in try await session.startRecording() }
    }

    @objc func stopScreenRecording(_ sender: Any?) {
        guard !closing, !finishingRecording, session.hasUnfinishedRecording, session.recordingState != .stopping else { return }
        let acceptedStart = recordingTask
        runRecordingOperation(finishing: true) { [self] in
            try await acceptedStart?.value
            _ = try await session.stopRecording()
            if let recordingDestination { try await saveCompletedRecording(to: recordingDestination) }
            else if session.completedRecording != nil {
                let destination = try await chooseRecordingDestination()
                try await saveCompletedRecording(to: .selected(destination))
            }
        }
    }

    @objc func saveScreenRecording(_ sender: Any?) {
        guard !closing, session.completedRecording != nil, recordingTask == nil else { return }
        runRecordingOperation { [self] in
            let destination = try await chooseRecordingDestination()
            try await saveCompletedRecording(to: .selected(destination))
        }
    }

    @objc func discardScreenRecording(_ sender: Any?) {
        guard !closing, session.completedRecording != nil, recordingTask == nil else { return }
        runRecordingOperation { [self] in
            let alert = NSAlert()
            alert.messageText = "Discard the recording?"
            alert.informativeText = "The recording has not been saved. This action cannot be undone."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Discard")
            guard await response(to: alert) == .alertSecondButtonReturn else { throw CancellationError() }
            session.discardCompletedRecording()
            recordingDestination = nil
        }
    }

    private func runRecordingOperation(finishing: Bool = false, _ operation: @escaping @MainActor () async throws -> Void) {
        issue = nil
        let identifier = UUID()
        recordingTaskIdentifier = identifier
        finishingRecording = finishing
        recordingTask = Task { [self] in
            defer {
                if recordingTaskIdentifier == identifier {
                    recordingTask = nil
                    recordingTaskIdentifier = nil
                    finishingRecording = false
                    update()
                }
            }
            do { try await operation() }
            catch is CancellationError { throw CancellationError() }
            catch { showIssue(error); throw error }
        }
        update()
    }

    private func finishRecordingBeforeDisconnect() async throws {
        let wasRecording = session.hasUnfinishedRecording
        if wasRecording { _ = try await session.stopRecording() }
        guard session.completedRecording != nil else { return }
        if wasRecording, let recordingDestination {
            try await saveCompletedRecording(to: recordingDestination)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Save the recording before closing?"
        alert.informativeText = "Your recording will be lost if you don’t save it."
        alert.addButton(withTitle: "Save…")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        switch await response(to: alert) {
        case .alertFirstButtonReturn:
            let destination = try await chooseRecordingDestination()
            try await saveCompletedRecording(to: .selected(destination))
        case .alertThirdButtonReturn:
            session.discardCompletedRecording()
            recordingDestination = nil
        default: throw CancellationError()
        }
    }

    private func response(to alert: NSAlert) async -> NSApplication.ModalResponse {
        guard let window else { return .cancel }
        return await presentAlert(alert, window)
    }

    private var captureDirectory: URL? {
        let preferences = UserDefaults(suiteName: "dev.lynnswap.NeoSimulator.Renderer") ?? .standard
        if let path = preferences.string(forKey: "ScreenShotSaveLocation") {
            let expanded = NSString(string: path).expandingTildeInPath
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue {
                return URL(fileURLWithPath: expanded, isDirectory: true)
            }
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
    }

    private var recordingFilename: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let suffix = UTType.mpeg4Movie.preferredFilenameExtension ?? "mp4"
        return "Device Screen Recording - \(window?.title ?? device.name) - \(formatter.string(from: Date())).\(suffix)"
            .replacingOccurrences(of: "/", with: ".").replacingOccurrences(of: ":", with: ".")
    }

    private func chooseRecordingDestination() async throws -> URL {
        guard let window else { throw CancellationError() }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        panel.directoryURL = recordingDestination?.url.deletingLastPathComponent() ?? captureDirectory
        panel.nameFieldStringValue = recordingDestination?.url.lastPathComponent ?? recordingFilename
        recordingPanel = panel
        update()
        let result = await presentSavePanel(panel, window)
        recordingPanel = nil
        update()
        guard result == .OK, let destination = panel.url else { throw CancellationError() }
        let preferences = UserDefaults(suiteName: "dev.lynnswap.NeoSimulator.Renderer") ?? .standard
        preferences.set(destination.deletingLastPathComponent().path, forKey: "ScreenShotSaveLocation")
        return destination
    }

    private func saveCompletedRecording(to destination: RecordingDestination) async throws {
        guard let recording = session.completedRecording else { return }
        try await Self.writeRecording(recording, to: destination)
        session.discardCompletedRecording()
        recordingDestination = nil
    }

    @concurrent
    private nonisolated static func writeRecording(_ recording: RemoteDeviceRecording, to destination: RecordingDestination) async throws {
        switch destination {
        case .selected(let url):
            try recording.data.write(to: url, options: .atomic)
        case .automatic(let url):
            let manager = FileManager.default
            let folder = url.deletingLastPathComponent()
            let temporary = folder.appendingPathComponent(".NeoSimulatorRecording-\(UUID().uuidString).mp4")
            do {
                try recording.data.write(to: temporary, options: .atomic)
                let base = url.deletingPathExtension().lastPathComponent
                for number in 1...99 {
                    let candidate = number == 1 ? url : folder.appendingPathComponent("\(base) #\(number).\(url.pathExtension)")
                    do {
                        try manager.moveItem(at: temporary, to: candidate)
                        return
                    } catch CocoaError.fileWriteFileExists { continue }
                }
                throw RemoteDeviceWindowError.unavailable("Could not save \(url.lastPathComponent): names through #99 are already taken in \(folder.path).")
            } catch {
                do { try manager.removeItem(at: temporary) }
                catch let cleanup as CocoaError where cleanup.code == .fileNoSuchFile {}
                catch let cleanup {
                    throw RemoteDeviceWindowError.cleanup([error.localizedDescription,
                        "Temporary recording remains at \(temporary.path): \(cleanup.localizedDescription)"])
                }
                throw error
            }
        }
    }

    private var canSaveScreenshot: Bool {
        !closing && captureTask == nil && capturePanel == nil
            && (completedScreenshot != nil || inventoryAvailable && session.canCaptureScreenshot)
    }

    private func saveScreenshot() {
        guard canSaveScreenshot else { return }
        runCaptureOperation { [self] in
            let destination = try await chooseScreenshotDestination()
            guard !closing else { throw CancellationError() }
            try await captureAndSaveScreenshot(to: destination)
        }
    }

    private func captureScreenshot(to destination: URL) {
        guard canSaveScreenshot else { return }
        runCaptureOperation { [self] in try await captureAndSaveScreenshot(to: destination) }
    }

    private func runCaptureOperation(_ operation: @escaping @MainActor () async throws -> Void) {
        issue = nil
        captureTask = Task { [self] in
            defer { captureTask = nil; update() }
            do { try await operation() }
            catch is CancellationError { throw CancellationError() }
            catch { showIssue(error); throw error }
        }
        update()
    }

    private func captureAndSaveScreenshot(to destination: URL) async throws {
        if completedScreenshot == nil {
            completedScreenshot = try await session.captureScreenshot()
        }
        try await saveCompletedScreenshot(to: destination)
    }

    private func saveCompletedScreenshot(to destination: URL) async throws {
        guard let image = completedScreenshot else {
            throw RemoteDeviceWindowError.unavailable("There is no screenshot to save.")
        }
        try await writeImage(image, destination)
        completedScreenshot = nil
    }

    private func chooseScreenshotDestination() async throws -> URL {
        guard let window else { throw CancellationError() }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.directoryURL = captureDirectory
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        panel.nameFieldStringValue = "Device Screenshot - \(window.title) - \(formatter.string(from: Date())).png"
            .replacingOccurrences(of: "/", with: ".").replacingOccurrences(of: ":", with: ".")
        capturePanel = panel
        update()
        defer { capturePanel = nil; update() }
        guard await presentSavePanel(panel, window) == .OK, let destination = panel.url else { throw CancellationError() }
        let preferences = UserDefaults(suiteName: "dev.lynnswap.NeoSimulator.Renderer") ?? .standard
        preferences.set(destination.deletingLastPathComponent().path, forKey: "ScreenShotSaveLocation")
        return destination
    }

    @objc func discardRemoteScreenshot(_ sender: Any?) {
        guard !closing, completedScreenshot != nil, captureTask == nil, capturePanel == nil else { return }
        runCaptureOperation { [self] in
            let alert = NSAlert()
            alert.messageText = "Discard the screenshot?"
            alert.informativeText = "The screenshot has not been saved. This action cannot be undone."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Discard")
            guard await response(to: alert) == .alertSecondButtonReturn else { throw CancellationError() }
            completedScreenshot = nil
        }
    }

    private func finishScreenshotBeforeDisconnect() async throws {
        guard completedScreenshot != nil else { return }
        let alert = NSAlert()
        alert.messageText = "Save the screenshot before closing?"
        alert.informativeText = "Your screenshot will be lost if you don’t save it."
        alert.addButton(withTitle: "Save…")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        switch await response(to: alert) {
        case .alertFirstButtonReturn:
            let destination = try await chooseScreenshotDestination()
            try await saveCompletedScreenshot(to: destination)
        case .alertThirdButtonReturn: completedScreenshot = nil
        default: throw CancellationError()
        }
    }

    @concurrent
    private nonisolated static func writeScreenshot(_ image: CGImage, to destination: URL) async throws {
        let data = NSMutableData()
        guard let output = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw RemoteDeviceWindowError.unavailable("The screenshot could not be encoded as PNG.")
        }
        CGImageDestinationAddImage(output, image, nil)
        guard CGImageDestinationFinalize(output) else {
            throw RemoteDeviceWindowError.unavailable("The screenshot could not be encoded as PNG.")
        }
        try (data as Data).write(to: destination, options: .atomic)
    }
}

@MainActor
private final class RemoteDeviceInputView: NSView {
    let session: RemoteDeviceScreenSession
    var enqueue: ((@escaping @MainActor () async throws -> Void) -> Void)?
    var isInputEnabled = false {
        didSet { if oldValue && !isInputEnabled { releaseFocus() } }
    }
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    init(session: RemoteDeviceScreenSession) {
        self.session = session
        super.init(frame: .zero)
        setAccessibilityLabel("Remote Device Screen")
        setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { isInputEnabled ? super.hitTest(point) : nil }
    func releaseFocus() {
        resetMouseGestures()
        enqueue? { [session] in try await session.releaseInputs() }
    }
    override func resignFirstResponder() -> Bool { releaseFocus(); return super.resignFirstResponder() }

    override func keyDown(with event: NSEvent) {
        guard isInputEnabled, session.inputCapabilities.contains(.keyboard), !event.isARepeat,
              let usage = Self.keyUsage[event.keyCode] else { return }
        enqueueInput(for: .keyboard) { [session] in try await session.sendKey(usage, state: .down) }
    }
    override func keyUp(with event: NSEvent) {
        guard isInputEnabled, session.inputCapabilities.contains(.keyboard), let usage = Self.keyUsage[event.keyCode] else { return }
        enqueueInput(for: .keyboard) { [session] in try await session.sendKey(usage, state: .up) }
    }
    override func flagsChanged(with event: NSEvent) {
        guard isInputEnabled, session.inputCapabilities.contains(.keyboard), let usage = Self.keyUsage[event.keyCode] else { return }
        if event.keyCode == UInt16(kVK_CapsLock) {
            enqueueInput(for: .keyboard) { [session] in
                try await session.sendKey(usage, state: .down)
                try await session.sendKey(usage, state: .up)
            }
        } else {
            let state: RemoteDeviceButtonState = CGEventSource.keyState(.combinedSessionState, key: event.keyCode) ? .down : .up
            enqueueInput(for: .keyboard) { [session] in try await session.sendKey(usage, state: state) }
        }
    }

    func invalidateInputs(for kinds: Set<RemoteDeviceInputKind>) {
        for kind in kinds { capabilityGenerations[kind, default: 0] += 1 }
        mouseGestures = mouseGestures.filter { !kinds.contains($0.value.kind.capability) }
    }

    func enqueueInput(for kind: RemoteDeviceInputKind, _ operation: @escaping @MainActor () async throws -> Void) {
        let generation = capabilityGenerations[kind, default: 0]
        enqueue? { [weak self] in
            guard self?.capabilityGenerations[kind, default: 0] == generation else { return }
            try await operation()
        }
    }

    private enum MouseInputKind {
        case touch, pointer
        var capability: RemoteDeviceInputKind {
            switch self { case .touch: .digitizer; case .pointer: .pointer }
        }
    }
    private struct MouseGesture {
        let kind: MouseInputKind
        let clicks: Int
    }
    private var mouseGestures: [Int: MouseGesture] = [:]
    private var inputGeneration = 0
    private var capabilityGenerations: [RemoteDeviceInputKind: Int] = [:]
    private var pointerTracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking)
        pointerTracking = tracking
    }

    private func resetMouseGestures() {
        inputGeneration += 1
        mouseGestures.removeAll()
    }

    private func enqueueMouseInput(kind: MouseInputKind, _ operation: @escaping @MainActor () async throws -> Void) {
        let generation = inputGeneration
        let capabilityGeneration = capabilityGenerations[kind.capability, default: 0]
        enqueueInput(for: kind.capability) { [weak self, session] in
            guard self?.inputGeneration == generation else { return }
            do { try await operation() }
            catch {
                guard self?.capabilityGenerations[kind.capability, default: 0] == capabilityGeneration else { throw error }
                if self?.inputGeneration == generation { self?.resetMouseGestures() }
                do { try await session.releaseInputs() }
                catch let cleanup {
                    throw RemoteDeviceWindowError.cleanup([error.localizedDescription, cleanup.localizedDescription])
                }
                throw error
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isInputEnabled else { return }
        window?.makeFirstResponder(self)
        let kind: MouseInputKind
        if event.buttonNumber == 0, session.inputCapabilities.contains(.digitizer) { kind = .touch }
        else if session.inputCapabilities.contains(.pointer) { kind = .pointer }
        else { return }
        guard let locations = session.inputLocations(atWindowPoint: event.locationInWindow) else { return }
        let button = event.buttonNumber
        let clicks = event.clickCount
        mouseGestures[button] = MouseGesture(kind: kind, clicks: clicks)
        enqueueMouseInput(kind: kind) { [session] in
            switch kind {
            case .touch: try await session.sendTouch(at: locations.touch, phase: .began)
            case .pointer: try await session.sendPointerButton(button, phase: .down, clicks: clicks, at: locations.pointer)
            }
        }
    }
    override func rightMouseDown(with event: NSEvent) { mouseDown(with: event) }
    override func otherMouseDown(with event: NSEvent) { mouseDown(with: event) }

    override func mouseDragged(with event: NSEvent) {
        guard isInputEnabled, let gesture = mouseGestures[event.buttonNumber] else { return }
        guard let locations = session.inputLocations(atWindowPoint: event.locationInWindow, clampingToDisplay: true) else { return }
        let button = event.buttonNumber
        enqueueMouseInput(kind: gesture.kind) { [session] in
            switch gesture.kind {
            case .touch: try await session.sendTouch(at: locations.touch, phase: .moved)
            case .pointer: try await session.sendPointerButton(button, phase: .dragged, clicks: gesture.clicks, at: locations.pointer)
            }
        }
    }
    override func rightMouseDragged(with event: NSEvent) { mouseDragged(with: event) }
    override func otherMouseDragged(with event: NSEvent) { mouseDragged(with: event) }

    override func mouseUp(with event: NSEvent) {
        guard isInputEnabled, let gesture = mouseGestures.removeValue(forKey: event.buttonNumber) else { return }
        guard let locations = session.inputLocations(atWindowPoint: event.locationInWindow, clampingToDisplay: true) else {
            releaseFocus()
            return
        }
        let button = event.buttonNumber
        enqueueMouseInput(kind: gesture.kind) { [session] in
            switch gesture.kind {
            case .touch: try await session.sendTouch(at: locations.touch, phase: .ended)
            case .pointer: try await session.sendPointerButton(button, phase: .up, clicks: gesture.clicks, at: locations.pointer)
            }
        }
    }
    override func rightMouseUp(with event: NSEvent) { mouseUp(with: event) }
    override func otherMouseUp(with event: NSEvent) { mouseUp(with: event) }

    override func mouseMoved(with event: NSEvent) {
        guard isInputEnabled, session.inputCapabilities.contains(.pointer),
              let locations = session.inputLocations(atWindowPoint: event.locationInWindow) else { return }
        enqueueMouseInput(kind: .pointer) { [session] in try await session.movePointer(to: locations.pointer) }
    }

    private static let keyUsage: [UInt16: UInt16] = {
        let pairs: [(Int, Int)] = [
            (kVK_ANSI_A, kHIDUsage_KeyboardA), (kVK_ANSI_B, kHIDUsage_KeyboardB), (kVK_ANSI_C, kHIDUsage_KeyboardC),
            (kVK_ANSI_D, kHIDUsage_KeyboardD), (kVK_ANSI_E, kHIDUsage_KeyboardE), (kVK_ANSI_F, kHIDUsage_KeyboardF),
            (kVK_ANSI_G, kHIDUsage_KeyboardG), (kVK_ANSI_H, kHIDUsage_KeyboardH), (kVK_ANSI_I, kHIDUsage_KeyboardI),
            (kVK_ANSI_J, kHIDUsage_KeyboardJ), (kVK_ANSI_K, kHIDUsage_KeyboardK), (kVK_ANSI_L, kHIDUsage_KeyboardL),
            (kVK_ANSI_M, kHIDUsage_KeyboardM), (kVK_ANSI_N, kHIDUsage_KeyboardN), (kVK_ANSI_O, kHIDUsage_KeyboardO),
            (kVK_ANSI_P, kHIDUsage_KeyboardP), (kVK_ANSI_Q, kHIDUsage_KeyboardQ), (kVK_ANSI_R, kHIDUsage_KeyboardR),
            (kVK_ANSI_S, kHIDUsage_KeyboardS), (kVK_ANSI_T, kHIDUsage_KeyboardT), (kVK_ANSI_U, kHIDUsage_KeyboardU),
            (kVK_ANSI_V, kHIDUsage_KeyboardV), (kVK_ANSI_W, kHIDUsage_KeyboardW), (kVK_ANSI_X, kHIDUsage_KeyboardX),
            (kVK_ANSI_Y, kHIDUsage_KeyboardY), (kVK_ANSI_Z, kHIDUsage_KeyboardZ),
            (kVK_ANSI_1, kHIDUsage_Keyboard1), (kVK_ANSI_2, kHIDUsage_Keyboard2), (kVK_ANSI_3, kHIDUsage_Keyboard3),
            (kVK_ANSI_4, kHIDUsage_Keyboard4), (kVK_ANSI_5, kHIDUsage_Keyboard5), (kVK_ANSI_6, kHIDUsage_Keyboard6),
            (kVK_ANSI_7, kHIDUsage_Keyboard7), (kVK_ANSI_8, kHIDUsage_Keyboard8), (kVK_ANSI_9, kHIDUsage_Keyboard9), (kVK_ANSI_0, kHIDUsage_Keyboard0),
            (kVK_Return, kHIDUsage_KeyboardReturnOrEnter), (kVK_Escape, kHIDUsage_KeyboardEscape), (kVK_Delete, kHIDUsage_KeyboardDeleteOrBackspace),
            (kVK_Tab, kHIDUsage_KeyboardTab), (kVK_Space, kHIDUsage_KeyboardSpacebar), (kVK_ANSI_Minus, kHIDUsage_KeyboardHyphen),
            (kVK_ANSI_Equal, kHIDUsage_KeyboardEqualSign), (kVK_ANSI_LeftBracket, kHIDUsage_KeyboardOpenBracket),
            (kVK_ANSI_RightBracket, kHIDUsage_KeyboardCloseBracket), (kVK_ANSI_Backslash, kHIDUsage_KeyboardBackslash),
            (kVK_ANSI_Semicolon, kHIDUsage_KeyboardSemicolon), (kVK_ANSI_Quote, kHIDUsage_KeyboardQuote),
            (kVK_ANSI_Grave, kHIDUsage_KeyboardGraveAccentAndTilde), (kVK_ANSI_Comma, kHIDUsage_KeyboardComma),
            (kVK_ANSI_Period, kHIDUsage_KeyboardPeriod), (kVK_ANSI_Slash, kHIDUsage_KeyboardSlash), (kVK_CapsLock, kHIDUsage_KeyboardCapsLock),
            (kVK_F1, kHIDUsage_KeyboardF1), (kVK_F2, kHIDUsage_KeyboardF2), (kVK_F3, kHIDUsage_KeyboardF3), (kVK_F4, kHIDUsage_KeyboardF4),
            (kVK_F5, kHIDUsage_KeyboardF5), (kVK_F6, kHIDUsage_KeyboardF6), (kVK_F7, kHIDUsage_KeyboardF7), (kVK_F8, kHIDUsage_KeyboardF8),
            (kVK_F9, kHIDUsage_KeyboardF9), (kVK_F10, kHIDUsage_KeyboardF10), (kVK_F11, kHIDUsage_KeyboardF11), (kVK_F12, kHIDUsage_KeyboardF12),
            (kVK_Home, kHIDUsage_KeyboardHome), (kVK_End, kHIDUsage_KeyboardEnd), (kVK_PageUp, kHIDUsage_KeyboardPageUp),
            (kVK_PageDown, kHIDUsage_KeyboardPageDown), (kVK_ForwardDelete, kHIDUsage_KeyboardDeleteForward),
            (kVK_RightArrow, kHIDUsage_KeyboardRightArrow), (kVK_LeftArrow, kHIDUsage_KeyboardLeftArrow),
            (kVK_DownArrow, kHIDUsage_KeyboardDownArrow), (kVK_UpArrow, kHIDUsage_KeyboardUpArrow),
            (kVK_Control, kHIDUsage_KeyboardLeftControl), (kVK_Shift, kHIDUsage_KeyboardLeftShift),
            (kVK_Option, kHIDUsage_KeyboardLeftAlt), (kVK_Command, kHIDUsage_KeyboardLeftGUI),
            (kVK_RightControl, kHIDUsage_KeyboardRightControl), (kVK_RightShift, kHIDUsage_KeyboardRightShift),
            (kVK_RightOption, kHIDUsage_KeyboardRightAlt), (kVK_RightCommand, kHIDUsage_KeyboardRightGUI),
        ]
        return Dictionary(uniqueKeysWithValues: pairs.map { (UInt16($0.0), UInt16($0.1)) })
    }()
}
