import Foundation
import Observation
@_spi(NeoSimulator) import XcodeSimulatorHost

struct SimulatorScreenRestoration: Equatable {
    enum Presentation: String {
        case hidden, compact, main
        var restorationOrder: Int {
            switch self { case .hidden: 0; case .compact: 1; case .main: 2 }
        }
    }
    let device: SimulatorDeviceIdentifier
    let xcodeURL: URL
    let presentation: Presentation
    var deviceID: DeviceInventoryID { .simulator(udid: device.identifier, deviceSetPath: device.deviceSetPath) }

    var url: URL {
        var items = [URLQueryItem(name: "udid", value: device.identifier),
                     URLQueryItem(name: "xcode", value: xcodeURL.path),
                     URLQueryItem(name: "presentation", value: presentation.rawValue)]
        if let path = device.deviceSetPath { items.append(URLQueryItem(name: "deviceSetPath", value: path)) }
        return URL(string: "neosimulator://restore-screen")!.appending(queryItems: items)
    }

    init(device: SimulatorDeviceIdentifier, xcodeURL: URL, presentation: Presentation) {
        self.device = device
        self.xcodeURL = xcodeURL
        self.presentation = presentation
    }

    init?(url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let udid = items.first(where: { $0.name == "udid" })?.value,
              let xcode = items.first(where: { $0.name == "xcode" })?.value,
              let name = items.first(where: { $0.name == "presentation" })?.value,
              let presentation = Presentation(rawValue: name) else { return nil }
        self.init(device: SimulatorDeviceIdentifier(udid, deviceSetPath: items.first(where: { $0.name == "deviceSetPath" })?.value),
                  xcodeURL: URL(fileURLWithPath: xcode, isDirectory: true), presentation: presentation)
    }
}

@MainActor @Observable
final class UIFrameworkSettings {
    static let preferenceKey = "UIFrameworkXcodePath"
    private let defaults: UserDefaults
    private let selectionAtLaunch: URL?
    private(set) var selectedXcodeURL: URL?
    private(set) var installations: [SimulatorXcode] = []
    private(set) var isLoading = false
    private(set) var issue: String?
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private let discover: () async throws -> [SimulatorXcode]

    static func selection(in defaults: UserDefaults) -> URL? {
        defaults.string(forKey: preferenceKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    init(defaults: UserDefaults = .standard, discover: @escaping () async throws -> [SimulatorXcode]) {
        self.defaults = defaults
        self.discover = discover
        let selection = Self.selection(in: defaults)
        selectedXcodeURL = selection
        selectionAtLaunch = selection
    }

    var needsRestart: Bool { selectedXcodeURL != selectionAtLaunch }

    func select(_ url: URL?) {
        selectedXcodeURL = url
        if let url { defaults.set(url.path, forKey: Self.preferenceKey) }
        else { defaults.removeObject(forKey: Self.preferenceKey) }
    }

    func reload() {
        guard loading == nil else { return }
        isLoading = true
        issue = nil
        loading = Task { [weak self, discover] in
            defer { self?.isLoading = false; self?.loading = nil }
            do {
                let installations = try await discover()
                try Task.checkCancellation()
                self?.installations = installations
            } catch is CancellationError {}
            catch { self?.issue = error.localizedDescription }
        }
    }

    isolated deinit { loading?.cancel() }
}

protocol SimulatorManagerSource: DeviceSettingsSource {
    func status() async throws -> SimulatorHostStatus
    func inventory() async -> DeviceInventorySnapshot
    func xcodeURL(forDevice deviceID: DeviceInventoryID) async throws -> URL
    func installedXcodes() async throws -> [SimulatorXcode]
    func selectHost(_ host: SimulatorHost, xcodeURL: URL?) async throws
    nonisolated func makeScreenOpenRequest(for deviceID: DeviceInventoryID) -> SimulatorScreenOpenRequest
    func openDevice(_ request: SimulatorScreenOpenRequest, xcodeURL: URL?) async throws
    func closeDevice(_ deviceID: DeviceInventoryID, keepingDeviceRunning: Bool) async throws
    func creationCatalog() async throws -> SimulatorCreationContext
    func creationCatalog(for deviceID: DeviceInventoryID) async throws -> SimulatorCreationContext
    func createSimulator(named name: String, deviceType: String, runtime: String, context: SimulatorCreationContext) async throws -> String
    func pairSimulators(watch: String, phone: String, context: SimulatorCreationContext) async throws
    func manage(_ action: DeviceManagementAction, devices: [InventoryDevice],
                preparingDisplay: (@isolated(any) @Sendable (InventoryDevice) async throws -> Void)?) async -> DeviceManagementReport
    func inspector(for device: InventoryDevice) async throws -> DeviceInspector
    func restore(force: Bool) async throws
    func synchronizeXcodeConnections() async throws -> Bool
    func testingDeviceVisibilityDidChange() async throws
    func quitRenderer(keepingDevicesRunning: Bool?) async throws
}

extension SimulatorHostController: SimulatorManagerSource {}

@MainActor @Observable
final class SimulatorManagerModel {
    @ObservationIgnored private let controller: any SimulatorManagerSource
    private(set) var status: SimulatorHostStatus?
    private(set) var inventory: [InventoryDevice] = []
    var devices: [SimulatorHostDevice] {
        inventory.compactMap { item in
            guard case .simulator(let device) = item, device.isAvailable else { return nil }
            return device
        }
    }
    var managingDeviceIDs: Set<DeviceInventoryID> {
        Set(managementRequests.values.flatMap(\.identifiers))
    }
    private struct ManagementRequest {
        let action: DeviceManagementAction?
        let identifiers: Set<DeviceInventoryID>
        var task: Task<Void, Never>?
    }
    private var managementRequests: [UUID: ManagementRequest] = [:]
    private(set) var isBusy = false
    private(set) var activity = ""
    private(set) var backgroundIssue: String?
    let settings: DeviceSettingsModel
    private(set) var devicePostures: [DeviceInventoryID: DevicePostureModel] = [:]
    @ObservationIgnored private var postureStarts: [DeviceInventoryID: Task<Void, Never>] = [:]
    @ObservationIgnored private var postureStops: [DeviceInventoryID: Task<Void, Never>] = [:]
    @ObservationIgnored private var openDeviceScreens: Set<DeviceInventoryID> = []
    @ObservationIgnored private let makeDevicePosture: @MainActor (DeviceInventoryID) -> DevicePostureModel
    let frameworks: UIFrameworkSettings
    @ObservationIgnored var onError: ((any Error) -> Void)?
    @ObservationIgnored var onDeviceOpenRequested: ((DeviceInventoryID) -> Void)?
    @ObservationIgnored var onOpenRemoteDevice: ((CoreDeviceDevice) async throws -> Void)?
    @ObservationIgnored var beforeStoppingScreens: (() async throws -> Void)?
    @ObservationIgnored var beforeManagingRemoteDevices: ((Set<DeviceInventoryID>) async throws -> Void)?
    @ObservationIgnored var beforeManagingSimulators: ((DeviceManagementAction, [InventoryDevice]) async throws -> Void)?
    @ObservationIgnored var afterManagingSimulators: ((DeviceManagementAction, [InventoryDevice]) async throws -> Void)?
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var refreshWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var statusRefreshTask: Task<Void, Never>?
    private var statusIssue: (any Error)?
    private var observationIssue: String?
    private var inventoryIssues: [DeviceInventoryIssue] = []
    var isRemoteInventoryComplete: Bool { !inventoryIssues.contains { $0.source == .coreDevice } }
    @ObservationIgnored private var synchronizing = false
    @ObservationIgnored private var inventoryRefreshRequested = false
    @ObservationIgnored private var stopping = false
    @ObservationIgnored private var operationTask: Task<Void, Never>?
    private struct PendingOperation {
        let activity: String
        let refreshCatalog: Bool
        let openDevice: SimulatorScreenOpenRequest?
        let run: @MainActor () async throws -> Void
    }
    private(set) var openingDeviceIDs: Set<DeviceInventoryID> = []
    @ObservationIgnored private var activeOpen: (request: SimulatorScreenOpenRequest, task: Task<Void, any Error>)?
    @ObservationIgnored private var pendingOperations: [PendingOperation] = []

    func cancelOpening(_ identifier: DeviceInventoryID) {
        pendingOperations.removeAll { operation in
            guard operation.openDevice?.deviceID == identifier else { return false }
            operation.openDevice?.cancel()
            return true
        }
        if activeOpen?.request.deviceID == identifier {
            activeOpen?.request.cancel()
            activeOpen?.task.cancel()
        } else { openingDeviceIDs.remove(identifier) }
    }

    func cancelPendingOpens() {
        for identifier in openingDeviceIDs { cancelOpening(identifier) }
    }

    init(rendererApplicationURL: URL,
         presentSimulator: (@MainActor @Sendable (SimulatorPresentationContext) async throws -> Void)? = nil) {
        let controller = SimulatorHostController(rendererApplicationURL: rendererApplicationURL, presentSimulator: presentSimulator)
        self.controller = controller
        makeDevicePosture = { DevicePostureModel(deviceID: $0) }
        frameworks = UIFrameworkSettings { try await controller.installedXcodes() }
        settings = DeviceSettingsModel(source: controller)
    }

    init(source: any SimulatorManagerSource,
         makeDevicePosture: @escaping @MainActor (DeviceInventoryID) -> DevicePostureModel = { DevicePostureModel(deviceID: $0) }) {
        controller = source
        self.makeDevicePosture = makeDevicePosture
        frameworks = UIFrameworkSettings { try await source.installedXcodes() }
        settings = DeviceSettingsModel(source: source)
    }

    func start() {
        perform("Loading devices…") {
            let status = try await self.controller.status()
            self.status = status
        }
    }

    func select(_ host: SimulatorHost) {
        perform("Switching simulator app…") {
            if host == .deviceHub { try await self.beforeStoppingScreens?() }
            try await self.controller.selectHost(host, xcodeURL: nil)
        }
    }

    func artworkXcodeURLs(for device: InventoryDevice) async -> [URL] {
        if case .simulator(let simulator) = device {
            if let owner = simulator.ownerXcodeURL { return [owner] }
            if let url = try? await controller.xcodeURL(forDevice: device.id) { return [url] }
            return []
        }
        return (try? await controller.installedXcodes())?.map(\.url) ?? []
    }

    func openDevice(_ identifier: DeviceInventoryID) {
        guard !stopping, !openingDeviceIDs.contains(identifier) else { return }
        onDeviceOpenRequested?(identifier)
        openingDeviceIDs.insert(identifier)
        let request = controller.makeScreenOpenRequest(for: identifier)
        perform("Opening simulator…", openDevice: request) {
            try await self.controller.openDevice(request, xcodeURL: nil)
            try Task.checkCancellation()
            await self.deviceScreenDidConnect(identifier)
        }
    }

    func restoreScreen(_ restoration: SimulatorScreenRestoration,
                       present: @escaping @MainActor () async throws -> Void) {
        guard !stopping else { return }
        if restoration.presentation == .main { onDeviceOpenRequested?(restoration.deviceID) }
        openingDeviceIDs.insert(restoration.deviceID)
        let request = controller.makeScreenOpenRequest(for: restoration.deviceID)
        perform("Restoring simulator…", openDevice: request) {
            await self.refreshCatalog()
            try await self.controller.openDevice(request, xcodeURL: restoration.xcodeURL)
            try Task.checkCancellation()
            await self.deviceScreenDidConnect(restoration.deviceID)
            try await present()
        }
    }

    func closeDevice(_ identifier: DeviceInventoryID, keepingDeviceRunning: Bool, after finishing: Task<Void, Never>) {
        // Accept the close before waiting, so a later open cannot overtake it.
        perform("Closing simulator…") {
            await self.stopDevicePosture(for: identifier)
            await finishing.value
            try await self.controller.closeDevice(identifier, keepingDeviceRunning: keepingDeviceRunning)
        }
    }

    func openScreen(for device: InventoryDevice) {
        guard !stopping, !managingDeviceIDs.contains(device.id) else { return }
        switch device {
        case .simulator(let simulator): openDevice(simulator.inventoryID)
        case .remote:
            onDeviceOpenRequested?(device.id)
            perform("Opening device screen…") {
                guard !self.managingDeviceIDs.contains(device.id),
                      case .remote(let current)? = self.inventory.first(where: { $0.id == device.id }) else { return }
                try await self.onOpenRemoteDevice?(current)
            }
        }
    }

    func setOpenDeviceScreens(_ identifiers: Set<DeviceInventoryID>) {
        openDeviceScreens = identifiers
        reconcileDevicePostures()
    }

    func deviceScreenDidConnect(_ identifier: DeviceInventoryID) async {
        guard openDeviceScreens.contains(identifier), devicePostures[identifier]?.state == .failed else { return }
        await stopDevicePosture(for: identifier)
        reconcileDevicePostures()
    }

    private func reconcileDevicePostures() {
        for identifier in Array(devicePostures.keys) where !openDeviceScreens.contains(identifier) {
            beginStoppingDevicePosture(for: identifier)
        }
        for identifier in openDeviceScreens { observeDevicePosture(for: identifier) }
    }

    private func observeDevicePosture(for identifier: DeviceInventoryID) {
        guard !stopping, !isBusy, !managingDeviceIDs.contains(identifier),
              postureStops[identifier] == nil, devicePostures[identifier] == nil,
              let device = inventory.first(where: { $0.id == identifier }),
              DevicePostureModel.canInspect(capabilities: device.capabilities) else { return }
        let posture = makeDevicePosture(identifier)
        devicePostures[identifier] = posture
        postureStarts[identifier] = Task { [weak self, posture] in
            do { try await posture.start() }
            catch is CancellationError {}
            catch {
                if self?.devicePostures[identifier] === posture { self?.onError?(error) }
            }
        }
    }

    /// Retire the old owner synchronously, then drain its observation and commands
    /// before allowing another owner for the same screen identity.
    private func beginStoppingDevicePosture(for identifier: DeviceInventoryID) {
        guard postureStops[identifier] == nil,
              let posture = devicePostures.removeValue(forKey: identifier) else { return }
        let starting = postureStarts.removeValue(forKey: identifier)
        starting?.cancel()
        postureStops[identifier] = Task { [weak self, posture] in
            await posture.stop()
            await starting?.value
            guard let self else { return }
            self.postureStops.removeValue(forKey: identifier)
            self.reconcileDevicePostures()
        }
    }

    private func stopDevicePosture(for identifier: DeviceInventoryID) async {
        beginStoppingDevicePosture(for: identifier)
        await postureStops[identifier]?.value
    }

    func stopDevicePostures() async {
        openDeviceScreens.removeAll()
        for identifier in Array(devicePostures.keys) { beginStoppingDevicePosture(for: identifier) }
        for task in Array(postureStops.values) { await task.value }
    }

    func creationCatalog() async throws -> SimulatorCreationContext {
        try await controller.creationCatalog()
    }

    func creationCatalog(for deviceID: DeviceInventoryID) async throws -> SimulatorCreationContext {
        try await controller.creationCatalog(for: deviceID)
    }

    func activePairedDevice(for identifier: DeviceInventoryID) -> SimulatorHostDevice? {
        guard case .simulator(let device)? = inventory.first(where: { $0.id == identifier }),
              device.state == "Booted", let pairedID = device.activePairedDeviceID,
              case .simulator(let paired)? = inventory.first(where: { $0.id == pairedID }) else { return nil }
        return paired
    }

    func openActivePairedDevice(for identifier: DeviceInventoryID) {
        guard let paired = activePairedDevice(for: identifier) else { return }
        openScreen(for: .simulator(paired))
    }

    func canAddPairing(for device: SimulatorHostDevice) -> Bool {
        device.isAvailable && (device.productFamily == "iPhone" ||
            (device.productFamily == "Apple Watch" && device.pairIdentifiers.isEmpty))
    }

    /// Device Hub pairs opposite roles exposed by CoreDevice; a Watch can have only one phone.
    func pairingCandidates(for device: SimulatorHostDevice) -> [SimulatorHostDevice] {
        let feature = "com.apple.coredevice.feature.companiondevicepairing"
        guard canAddPairing(for: device), device.capabilities.contains(feature) else { return [] }
        let family = device.productFamily == "iPhone" ? "Apple Watch" : "iPhone"
        return devices.filter { candidate in
            candidate.productFamily == family && candidate.deviceSetPath == device.deviceSetPath
                && (candidate.productFamily != "Apple Watch" || candidate.pairIdentifiers.isEmpty)
                && candidate.capabilities.contains(feature)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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

    func canManage(_ action: DeviceManagementAction, deviceIDs: Set<DeviceInventoryID>) -> Bool {
        guard !stopping, !deviceIDs.isEmpty else { return false }
        let overlapping = managementRequests.values.filter { !$0.identifiers.isDisjoint(with: deviceIDs) }
        if overlapping.isEmpty { return !isBusy }
        guard action == .forceShutdown, overlapping.count == 1, let shutdown = overlapping.first,
              shutdown.action == DeviceManagementAction.shutdown, deviceIDs.isSubset(of: shutdown.identifiers) else { return false }
        return shutdown.identifiers.allSatisfy { if case .simulator = $0 { true } else { false } }
    }

    func manage(_ action: DeviceManagementAction, devices: [InventoryDevice]) {
        var identifiers = Set<DeviceInventoryID>()
        let targets = devices.filter { identifiers.insert($0.id).inserted }
        guard canManage(action, deviceIDs: identifiers) else { return }
        let request = UUID()
        managementRequests[request] = ManagementRequest(action: action, identifiers: identifiers)
        let task = Task {
            defer {
                self.managementRequests.removeValue(forKey: request)
                self.reconcileDevicePostures()
            }
            do {
                let preparesOwnedShutdown = action == .shutdown && targets.allSatisfy {
                    if case .simulator = $0 { true } else { false }
                }
                if action != .forceShutdown && !preparesOwnedShutdown {
                    switch action {
                    case .restart, .erase, .shutdown, .remove, .unpair, .pause:
                        for device in targets where device.supports(action) { await self.stopDevicePosture(for: device.id) }
                    default: break
                    }
                    let remoteIDs = Set(targets.filter { self.managementDisconnectsScreen(action, for: $0) }.map(\.id))
                    if !remoteIDs.isEmpty { try await self.beforeManagingRemoteDevices?(remoteIDs) }
                    try await self.beforeManagingSimulators?(action, targets)
                }
                let preparation: (@isolated(any) @Sendable (InventoryDevice) async throws -> Void)?
                if preparesOwnedShutdown || action == .forceShutdown {
                    preparation = { @MainActor target in
                        if target.supports(action) { await self.stopDevicePosture(for: target.id) }
                        switch target {
                        case .simulator: try await self.beforeManagingSimulators?(action, [target])
                        case .remote: try await self.beforeManagingRemoteDevices?([target.id])
                        }
                    }
                } else { preparation = nil }
                let report = await self.controller.manage(action, devices: targets, preparingDisplay: preparation)
                var presentationError: (any Error)?
                do { try await self.afterManagingSimulators?(action, targets) }
                catch { presentationError = error }
                if !self.stopping { await self.refreshCatalog() }
                if report.results.contains(where: { $0.error != nil }) || presentationError != nil {
                    self.onError?(DeviceManagementFailure(devices: targets, report: report, presentationError: presentationError))
                }
            } catch { self.onError?(error) }
        }
        managementRequests[request]?.task = task

    }

    private func managementDisconnectsScreen(_ action: DeviceManagementAction, for device: InventoryDevice) -> Bool {
        guard case .remote = device, device.supports(action) else { return false }
        switch action {
        case .shutdown, .forceShutdown, .restart, .erase, .remove, .unpair, .pause: return true
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
        let request = UUID()
        managementRequests[request] = ManagementRequest(action: nil, identifiers: [device.id])
        let task = Task {
            defer {
                self.managementRequests.removeValue(forKey: request)
                self.reconcileDevicePostures()
            }
            do { try await operation() }
            catch { self.onError?(InspectorOperationFailure(deviceName: device.name, error: error)) }
            if !self.stopping {
                await self.refreshCatalog()
                completion()
            }
        }
        managementRequests[request]?.task = task

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
            settings.requestRefresh()
            if refreshWaiters.isEmpty { refreshing = false }
            else { refreshWaiters.removeFirst().resume() }
        }
        repeat {
            inventoryRefreshRequested = false
            refreshHostStatus()
            let snapshot = await controller.inventory()
            inventory = snapshot.devices
            reconcileDevicePostures()
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
        observationIssue = "Live device updates are unavailable. The list will update when you return to NeoSimulator."
        updateInventoryIssue()

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

        }
    }

    func rendererDevicesDidChange(testingVisibilityChanged: Bool) async {
        guard !stopping else { return }
        if testingVisibilityChanged {
            do { try await controller.testingDeviceVisibilityDidChange() }
            catch {
                reportBackgroundError(error)

            }
        }
        await refresh()
    }

    func setLocation(latitude: Double, longitude: Double, for identifier: DeviceInventoryID) {
        setDeviceSetting(.location(latitude: latitude, longitude: longitude), for: identifier)
    }

    func setDeviceSetting(_ setting: SimulatorDeviceSetting, for identifier: DeviceInventoryID) {
        guard !stopping, !managingDeviceIDs.contains(identifier), let device = inventory.first(where: { $0.id == identifier }) else { return }
        let edit = settings.accept(setting, for: device)
        perform("Updating device settings…", refreshCatalog: false) {
            try await self.settings.apply(edit)
        }
    }

    func prepareForQuit() async throws {
        stopping = true
        let opening = activeOpen?.task
        cancelPendingOpens()
        settings.stopReading()
        await stopDevicePostures()
        statusRefreshTask?.cancel()
        await operationTask?.value
        for task in managementRequests.values.compactMap(\.task) { await task.value }
        await statusRefreshTask?.value
        await settings.finishReading()
        if let opening, case .failure(let error) = await opening.result, !(error is CancellationError) {
            throw error
        }
    }

    func quitRenderer(keepingDevicesRunning: Bool?) async throws {
        do {
            try await prepareForQuit()
            try await controller.quitRenderer(keepingDevicesRunning: keepingDevicesRunning)
        } catch { resumeAfterCancelledQuit(); throw error }
    }

    func resumeAfterCancelledQuit() {
        stopping = false
        settings.resumeReading()
    }

    private func reportBackgroundError(_ error: any Error) {
        let message = error.localizedDescription
        if backgroundIssue != message {
            NSLog("NeoSimulator: %@", (error as? SimulatorHostFailure)?.technicalDetails ?? String(describing: error))
        }
        backgroundIssue = message
    }

    private func perform(_ activity: String, refreshCatalog: Bool = true, openDevice: SimulatorScreenOpenRequest? = nil,
                         operation: @escaping @MainActor () async throws -> Void) {
        guard !stopping else { return }
        pendingOperations.append(.init(activity: activity, refreshCatalog: refreshCatalog, openDevice: openDevice, run: operation))
        if refreshCatalog { isBusy = true }
        guard operationTask == nil else {
            return
        }
        settings.setReadingSuspended(true)
        operationTask = Task {
            defer {
                self.operationTask = nil
                self.isBusy = false
                self.reconcileDevicePostures()
                self.activity = ""
                self.settings.setReadingSuspended(false)
            }
            while !self.pendingOperations.isEmpty {
                let next = self.pendingOperations.removeFirst()
                self.isBusy = next.refreshCatalog || self.pendingOperations.contains { $0.refreshCatalog }
                self.activity = next.activity
                var failure: (any Error)?
                if let request = next.openDevice {
                    let task = Task {
                        try await next.run()
                        try Task.checkCancellation()
                        if next.refreshCatalog, !self.stopping { await self.refreshCatalog() }
                    }
                    self.activeOpen = (request, task)
                    do { try await task.value }
                    catch is CancellationError {}
                    catch { failure = error }
                    self.activeOpen = nil
                    self.openingDeviceIDs.remove(request.deviceID)
                } else {
                    do { try await next.run() }
                    catch { failure = error }
                }
                if !self.stopping, self.inventoryRefreshRequested || (next.openDevice == nil && next.refreshCatalog) {
                    await self.refreshCatalog()
                }
                if let failure, next.openDevice == nil || !self.stopping { self.onError?(failure) }
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
    var presentationError: (any Error)? = nil

    var errorDescription: String? { "Some device operations could not be completed." }

    var recoverySuggestion: String? {
        let failures = report.results.compactMap { result -> String? in
            guard let error = result.error else { return nil }
            let name = devices.first { $0.id == result.deviceID }?.name ?? "Device"
            let completed = result.completedSteps.isEmpty ? "" : "\nCompleted: \(result.completedSteps.joined(separator: ", "))."
            return "\(name): \(error.localizedDescription)\(completed)"
        }
        return (failures + [presentationError?.localizedDescription].compactMap { $0 }).joined(separator: "\n\n")
    }
}

struct InspectorOperationFailure: LocalizedError {
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
