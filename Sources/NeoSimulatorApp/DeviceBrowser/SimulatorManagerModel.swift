import Foundation
import NeoSimulatorDeviceIO
import NeoSimulatorHostSupport
import NeoSimulatorKit
import NeoSimulatorPresentationAdapters
import Observation

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

protocol SimulatorManagerSource: DeviceStateSource {
    func status() async throws -> SimulatorHostStatus
    func beginSession() async throws
    func endSession() async throws
    func xcodeURL(forDevice deviceID: DeviceInventoryID) async throws -> URL
    func installedXcodes() async throws -> [SimulatorXcode]
    func selectHost(_ host: SimulatorHost, xcodeURL: URL?) async throws
    nonisolated func makeScreenOpenRequest(for deviceID: DeviceInventoryID) -> SimulatorScreenOpenRequest
    func openDevice(_ request: SimulatorScreenOpenRequest, xcodeURL: URL?, bootIfNeeded: Bool) async throws
    func closeDevice(_ deviceID: DeviceInventoryID, keepingDeviceRunning: Bool) async throws
    func creationCatalog() async throws -> SimulatorCreationContext
    func creationCatalog(for deviceID: DeviceInventoryID) async throws -> SimulatorCreationContext
    func createSimulator(named name: String, deviceType: String, runtime: String, context: SimulatorCreationContext) async throws -> String
    func pairSimulators(watch: String, phone: String, context: SimulatorCreationContext) async throws
    func manage(_ action: DeviceManagementAction, devices: [InventoryDevice],
                preparingDisplay: (@isolated(any) @Sendable (InventoryDevice) async throws -> Void)?) async -> DeviceManagementReport
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
    /// The devices the registry lists, as the inventory last described them.
    var inventory: [InventoryDevice] { registry.devices.map(\.inventory) }
    /// DeviceKit's sidebar Active values in this process; a device without one is unknown.
    private(set) var activeStates = DeviceActiveStates()
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
    /// Whether queued work holds later edits of every device. A running device's screen that is attaching does not.
    private(set) var holdsAllEdits = false
    /// The devices whose later edits queued work holds.
    private var heldEditDeviceIDs: Set<DeviceInventoryID> = []
    /// The devices that queued work concerns, including one whose screen is only attaching.
    private(set) var queuedDeviceIDs: Set<DeviceInventoryID> = []
    private(set) var activity = ""
    private(set) var backgroundIssue: String?
    /// What is known of each device, which this process's screens also use.
    let registry: DeviceRegistry
    let selection = ManagerSelection()
    let serviceProfiles: ServiceProfileStore
    private(set) var devicePostures: [DeviceInventoryID: DevicePostureModel] = [:]
    @ObservationIgnored private var postureStarts: [DeviceInventoryID: Task<Void, Never>] = [:]
    @ObservationIgnored private var postureStops: [DeviceInventoryID: Task<Void, Never>] = [:]
    @ObservationIgnored private var openDeviceScreens: Set<DeviceInventoryID> = []
    @ObservationIgnored private let makeDevicePosture: @MainActor (DeviceInventoryID) -> DevicePostureModel
    let frameworks: UIFrameworkSettings
    @ObservationIgnored var onError: ((any Error) -> Void)?
    @ObservationIgnored var onDeviceOpenRequested: ((DeviceInventoryID) -> Void)?
    @ObservationIgnored var onOpenRemoteDevice: ((CoreDeviceDevice) async throws -> Void)?
    @ObservationIgnored var requestHostPreferenceAccess: (() async throws -> Void)?
    @ObservationIgnored var beforeStoppingScreens: (() async throws -> Void)?
    @ObservationIgnored var beforeManagingRemoteDevices: ((Set<DeviceInventoryID>) async throws -> Void)?
    @ObservationIgnored var beforeManagingSimulators: ((DeviceManagementAction, [InventoryDevice]) async throws -> Void)?
    @ObservationIgnored var afterManagingSimulators: ((DeviceManagementAction, [InventoryDevice]) async throws -> Void)?
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var refreshWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var statusRefreshTask: Task<Void, Never>?
    private var statusIssue: (any Error)?
    private var observationIssue: String?
    private var activeStateIssue: String?
    private var inventoryIssues: [DeviceInventoryIssue] = []
    var isRemoteInventoryComplete: Bool { !inventoryIssues.contains { $0.source == .coreDevice } }
    @ObservationIgnored private var synchronizing = false
    @ObservationIgnored private var inventoryRefreshRequested = false
    @ObservationIgnored private var stopping = false
    /// The wait for accepted work that the first step of a quit starts and later steps join, until the quit is cancelled.
    @ObservationIgnored private var quitPreparation: Task<(any Error)?, Never>?
    /// How long accepted work has before a quit stops it. Nil uses `TerminationTimeout`.
    @ObservationIgnored var terminationLimit: Duration?
    /// How long what quitting stopped has to finish.
    @ObservationIgnored var terminationGrace = DeviceOperationLimit.terminationGrace
    @ObservationIgnored var uninterruptedCommands = UninterruptedCommands.shared
    @ObservationIgnored private var operationTask: Task<Void, Never>?
    private struct PendingOperation {
        let id = UUID()
        let activity: String
        /// The device whose changes this follows and holds; nil means every device's.
        let deviceID: DeviceInventoryID?
        let openDevice: SimulatorScreenOpenRequest?
        /// Whether the open only attaches the screen, without booting, if the device is running when the queue admits it.
        /// Other opens and settings that do not depend on the connection can run alongside it.
        var attachesRunningDevice = false
        /// The accepted changes that this must follow.
        var followsWrites: [Task<Void, any Error>] = []
        /// Receives whether the admitted open only attaches.
        let run: @MainActor (_ attaches: Bool) async throws -> Void
    }
    /// A change accepted for one device, which runs in that device's order.
    private struct AcceptedWrite {
        let write: DeviceWrite
        let activity: String
        let deviceID: DeviceInventoryID
    }
    @ObservationIgnored private var acceptedWrites: [AcceptedWrite] = []
    /// Changes that a quit stopped before their turn.
    @ObservationIgnored private var abandonedWrites: Set<UUID> = []
    /// Accepted operations that have not ended, with what waits for them.
    @ObservationIgnored private var unfinishedOperations: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private(set) var openingDeviceIDs: Set<DeviceInventoryID> = []
    private struct ActiveDeviceOperation {
        let id: UUID
        /// The screen open that this operation is, which can be cancelled.
        let request: SimulatorScreenOpenRequest?
        var task: Task<Void, any Error>?
        let activity: String
        let attaches: Bool
    }
    @ObservationIgnored private var activeDeviceOperations: [DeviceInventoryID: ActiveDeviceOperation] = [:]
    @ObservationIgnored private var pendingOperations: [PendingOperation] = []
    @ObservationIgnored private var runningOperation: PendingOperation?
    @ObservationIgnored private var operationsChanged: CheckedContinuation<Void, Never>?

    func cancelOpening(_ identifier: DeviceInventoryID) {
        pendingOperations.removeAll { operation in
            guard operation.openDevice?.deviceID == identifier else { return false }
            operation.openDevice?.cancel()
            finishOperation(operation.id)
            return true
        }
        if let active = activeDeviceOperations[identifier], let request = active.request, let task = active.task {
            request.cancel()
            task.cancel()
        } else { openingDeviceIDs.remove(identifier) }
        // A withdrawn open can uncover an operation that may run beside the attaching screen.
        resumeOperations()
    }

    func cancelPendingOpens() {
        for identifier in openingDeviceIDs { cancelOpening(identifier) }
    }

    func cancelPendingSimulatorOpens() {
        for identifier in openingDeviceIDs where identifier.isSimulator { cancelOpening(identifier) }
    }

    init(rendererApplicationURL: URL,
         presentSimulator: (@MainActor @Sendable (SimulatorPresentationContext) async throws -> Void)? = nil,
         serviceProfiles: ServiceProfileStore = ServiceProfileStore()) {
        let controller = SimulatorHostController(rendererApplicationURL: rendererApplicationURL, presentSimulator: presentSimulator)
        self.controller = controller
        makeDevicePosture = { DevicePostureModel(deviceID: $0) }
        frameworks = UIFrameworkSettings { try await controller.installedXcodes() }
        registry = DeviceRegistry(source: controller)
        self.serviceProfiles = serviceProfiles
    }

    init(source: any SimulatorManagerSource,
         makeDevicePosture: @escaping @MainActor (DeviceInventoryID) -> DevicePostureModel = { DevicePostureModel(deviceID: $0) },
         serviceProfiles: ServiceProfileStore = ServiceProfileStore()) {
        controller = source
        self.makeDevicePosture = makeDevicePosture
        frameworks = UIFrameworkSettings { try await source.installedXcodes() }
        registry = DeviceRegistry(source: source)
        self.serviceProfiles = serviceProfiles
    }

    func start() {
        perform("Loading devices…") {
            do {
                try await self.requestHostPreferenceAccess?()
                try await self.controller.beginSession()
            }
            catch {
                self.status = try? await self.controller.status()
                throw error
            }
            let status = try await self.controller.status()
            self.status = status
        }
    }

    func select(_ host: SimulatorHost) {
        perform("Switching simulator app…") {
            try await self.requestHostPreferenceAccess?()
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
        enqueue(PendingOperation(activity: "Opening simulator…", deviceID: identifier, openDevice: request,
                                 attachesRunningDevice: true) { attaches in
            try await self.controller.openDevice(request, xcodeURL: nil, bootIfNeeded: !attaches)
            try Task.checkCancellation()
            await self.deviceScreenDidConnect(identifier)
        })
    }

    func restoreScreen(_ restoration: SimulatorScreenRestoration,
                       present: @escaping @MainActor () async throws -> Void) {
        guard !stopping else { return }
        if restoration.presentation == .main { onDeviceOpenRequested?(restoration.deviceID) }
        openingDeviceIDs.insert(restoration.deviceID)
        let request = controller.makeScreenOpenRequest(for: restoration.deviceID)
        perform("Restoring simulator…", device: restoration.deviceID, openDevice: request) {
            await self.refreshCatalog()
            try await self.controller.openDevice(request, xcodeURL: restoration.xcodeURL, bootIfNeeded: true)
            try Task.checkCancellation()
            await self.deviceScreenDidConnect(restoration.deviceID)
            try await present()
        }
    }

    func closeDevice(_ identifier: DeviceInventoryID, keepingDeviceRunning: Bool, after finishing: Task<Void, any Error>) {
        // Accept the close before waiting, so a later open cannot overtake it.
        perform("Closing simulator…", device: identifier) {
            await self.stopDevicePosture(for: identifier)
            // The screen is already gone, so the device closes even when its cleanup failed, which is reported then.
            let cleanup = await finishing.result
            do { try await self.controller.closeDevice(identifier, keepingDeviceRunning: keepingDeviceRunning) }
            catch {
                guard case .failure(let cleanupError) = cleanup else { throw error }
                throw SimulatorError.operation([error.localizedDescription, cleanupError.localizedDescription].joined(separator: "\n"))
            }
            try cleanup.get()
        }
    }

    func openScreen(for device: InventoryDevice) {
        guard !stopping, !managingDeviceIDs.contains(device.id) else { return }
        switch device {
        case .simulator(let simulator): openDevice(simulator.inventoryID)
        case .remote:
            onDeviceOpenRequested?(device.id)
            perform("Opening device screen…", device: device.id) {
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

    /// Whether the device's screen can open now, or is opening and can be cancelled.
    func canViewScreen(_ device: InventoryDevice) -> Bool {
        if openingDeviceIDs.contains(device.id) { return true }
        guard !managingDeviceIDs.contains(device.id) else { return false }
        switch device {
        case .simulator(let simulator):
            return simulator.isAvailable && ["Booted", "Shutdown"].contains(simulator.state)
        case .remote(let remote):
            return !holdsAllEdits && !queuedDeviceIDs.contains(device.id) && remote.isAvailable
                && (remote.kind == .virtualMachine || remote.capabilities.contains("com.apple.coredevice.feature.viewdevicescreen"))
        }
    }

    /// Whether `action` applies to this selection, whatever is running now.
    func supports(_ action: DeviceManagementAction, devices: [InventoryDevice]) -> Bool {
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

    func canManage(_ action: DeviceManagementAction, deviceIDs: Set<DeviceInventoryID>) -> Bool {
        guard !stopping, !deviceIDs.isEmpty else { return false }
        // A background service change spans many launchctl calls; only Force Shut Down may interrupt it.
        guard action == .forceShutdown || !deviceIDs.contains(where: { registry.device(for: $0)?.backgroundServices.isChanging == true }) else { return false }
        let overlapping = managementRequests.values.filter { !$0.identifiers.isDisjoint(with: deviceIDs) }
        // Work on another device does not stop this one, unlike work that concerns every device.
        if overlapping.isEmpty { return !holdsAllEdits && queuedDeviceIDs.isDisjoint(with: deviceIDs) }
        guard action == .forceShutdown, overlapping.count == 1, let shutdown = overlapping.first,
              shutdown.action == DeviceManagementAction.shutdown, deviceIDs.isSubset(of: shutdown.identifiers) else { return false }
        return shutdown.identifiers.allSatisfy(\.isSimulator)
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
                self.applyPendingServiceProfiles()
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
                if action == .remove {
                    for result in report.results where result.error == nil {
                        do { try self.serviceProfiles.removeBinding(for: result.deviceID) }
                        catch { self.onError?(error) }
                    }
                }
                if action == .restart || action == .erase {
                    for result in report.results where result.error == nil { self.registry.device(for: result.deviceID)?.deviceRestarted() }
                }
                var presentationError: (any Error)?
                do { try await self.afterManagingSimulators?(action, targets) }
                catch { presentationError = error }
                if !self.stopping { await self.refreshCatalog() }
                let failed = report.results.contains { $0.error != nil }
                if failed || presentationError != nil {
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

    /// Queues an inspector change for `device`, marks it busy, then invalidates `groups`.
    /// Quit reports a change that has not started as not run.
    func performInspectorChange(on device: DeviceModel, affecting groups: DeviceStateGroups,
                                operation: @escaping @Sendable (DeviceInspector) async throws -> Void) {
        guard !stopping, !managingDeviceIDs.contains(device.id) else { return }
        let request = UUID()
        managementRequests[request] = ManagementRequest(action: nil, identifiers: [device.id])
        let task = Task {
            defer {
                self.managementRequests.removeValue(forKey: request)
                self.reconcileDevicePostures()
            }
            do {
                try await device.inspection.change(affecting: groups, prepare: {
                    if self.stopping { throw QuitOutcome.notRun("The change to \(device.name)") }
                }, perform: operation)
            } catch { self.onError?(InspectorOperationFailure(deviceName: device.name, error: error)) }
            if !self.stopping { await self.refreshCatalog() }
        }
        managementRequests[request]?.task = task

    }

    /// Whether the Apps inspector's installer can accept applications for the device now.
    func canInstallApplications(on identifier: DeviceInventoryID) -> Bool {
        guard !stopping, !managingDeviceIDs.contains(identifier) else { return false }
        return inventory.first { $0.id == identifier }?.canInstallApplications == true
    }

    /// Installs applications requested outside the inspector, such as by a screen drop.
    func installApplications(at urls: [URL], on identifier: DeviceInventoryID) {
        guard canInstallApplications(on: identifier), let device = registry.device(for: identifier) else { return }
        performInspectorChange(on: device, affecting: .applications) { inspector in
            try await SimulatorFileImport.perform(urls) { url, _ in try await inspector.installApplication(at: url) }
        }
    }

    func restoreDefaults(force: Bool = false) {
        perform("Restoring original settings…") {
            try await self.requestHostPreferenceAccess?()
            try await self.beforeStoppingScreens?()
            try await self.controller.restore(force: force)
        }
    }

    func refresh() async {
        guard !stopping else { return }
        if isBusy || refreshing {
            inventoryRefreshRequested = true
            return
        }
        await refreshCatalog()
    }

    private func refreshCatalog() async {
        if refreshing { await withCheckedContinuation { refreshWaiters.append($0) } }
        else { refreshing = true }
        defer {
            if refreshWaiters.isEmpty {
                refreshing = false
                applyPendingServiceProfiles()
            }
            else { refreshWaiters.removeFirst().resume() }
        }
        repeat {
            inventoryRefreshRequested = false
            refreshHostStatus()
            do { try await registry.refresh() }
            catch {
                // What is published stays until a read completes, which a cancelled quit starts again.
                inventoryRefreshRequested = true
                return
            }
            reconcileDevicePostures()
            inventoryIssues = registry.inventoryIssues
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
        if inventoryIssues.isEmpty, statusIssue == nil, observationIssue == nil, activeStateIssue == nil { backgroundIssue = nil }
        else {
            reportBackgroundError(InventoryReadError(issues: inventoryIssues, statusError: statusIssue,
                                                     observationIssue: observationIssue, activeStateIssue: activeStateIssue))
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

    // Unlike the inventory callbacks, these also apply while quitting. The observation reports only changes, so a
    // value dropped during a quit that is then cancelled would not arrive again.
    func activeStatesDidChange(_ states: DeviceActiveStates) {
        activeStates = states
        if activeStateIssue != nil {
            activeStateIssue = nil
            updateInventoryIssue()
        }
    }

    /// Earlier values could be stale, so every device becomes unknown.
    func activeStateObservationFailed(_ error: any Error) {
        NSLog("NeoSimulator active device states: %@", String(describing: error))
        activeStates = DeviceActiveStates()
        activeStateIssue = "Active devices are unavailable. The list does not show which devices are active."
        updateInventoryIssue()
    }

    func synchronizeConnections() async {
        guard !stopping, !synchronizing, !refreshing, !isBusy else { return }
        synchronizing = true
        defer { synchronizing = false }
        do {
            if try await controller.synchronizeXcodeConnections() { await refresh() }
        } catch is CancellationError {
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

    /// Shows which device the manager window presents. `device` comes from the current inventory.
    func inspect(_ device: InventoryDevice?, selectionCount: Int) {
        selection.select(device.flatMap { registry.device(for: $0.id) }, count: selectionCount)
    }

    /// Marks what is known of every device as out of date, when something outside NeoSimulator may have changed it without a signal.
    func revalidateDevices() {
        guard !stopping else { return }
        registry.revalidate()
    }

    func setDeviceSetting(_ setting: DeviceSettingChange, for identifier: DeviceInventoryID) {
        guard !stopping, !managingDeviceIDs.contains(identifier), inventory.contains(where: { $0.id == identifier }),
              let device = registry.device(for: identifier) else { return }
        do {
            let write = try device.settings.accept(setting, after: hold(of: identifier, waitsForAttach: setting.waitsForScreenAttach))
            track(write, activity: "Updating device settings…", on: identifier)
        } catch { onError?(error) }
    }

    func setBackgroundServices(_ targets: [SimulatorBackgroundServiceTarget], enabled: Bool, for identifier: DeviceInventoryID) {
        guard !stopping, !managingDeviceIDs.contains(identifier), let device = inventory.first(where: { $0.id == identifier }),
              let model = registry.device(for: identifier) else { return }
        do {
            try serviceProfiles.record(targets, enabled: enabled, for: identifier,
                productFamily: device.serviceProductFamily, currentConfiguration: model.backgroundServices.configuration)
            let write = try model.backgroundServices.accept(.services(targets, enabled: enabled), after: hold(of: identifier, waitsForAttach: false))
            track(write, activity: "Updating background services…", on: identifier)
        } catch { onError?(error) }
    }

    func canEditSettings(for identifier: DeviceInventoryID) -> Bool {
        !stopping && !holdsAllEdits && !heldEditDeviceIDs.contains(identifier) && !managingDeviceIDs.contains(identifier)
    }

    func selectServiceProfile(_ profileID: UUID, for identifier: DeviceInventoryID) {
        guard !stopping, !managingDeviceIDs.contains(identifier),
              let device = inventory.first(where: { $0.id == identifier }), case .simulator = device else { return }
        do {
            let binding = try serviceProfiles.assign(profileID, to: identifier, pending: !device.canInspectBackgroundServices)
            if device.canInspectBackgroundServices { enqueueServiceConfiguration(binding, for: device) }
        } catch { onError?(error) }
    }

    func revertServiceProfile(for identifier: DeviceInventoryID) {
        guard !stopping, !managingDeviceIDs.contains(identifier),
              let device = inventory.first(where: { $0.id == identifier }) else { return }
        let profileID = serviceProfiles.binding(for: identifier)?.profileID ?? ServiceProfile.default.id
        do {
            let binding = try serviceProfiles.assign(profileID, to: identifier,
                pending: !device.canInspectBackgroundServices, preservingOverrides: false)
            if device.canInspectBackgroundServices { enqueueServiceConfiguration(binding, for: device) }
        } catch { onError?(error) }
    }

    private func enqueueServiceConfiguration(_ binding: DeviceServiceProfile, for device: InventoryDevice) {
        guard let model = registry.device(for: device.id) else { return }
        do {
            let write = try model.backgroundServices.accept(.configuration(binding.configuration),
                after: hold(of: device.id, waitsForAttach: false)) {
                try self.serviceProfiles.beginApplication(for: device.id, requestID: binding.requestID)
            }
            track(write, activity: "Applying service profile…", on: device.id)
        } catch { onError?(error) }
    }

    private func applyPendingServiceProfiles() {
        guard !stopping else { return }
        for device in inventory where device.canInspectBackgroundServices && !managingDeviceIDs.contains(device.id)
            && registry.device(for: device.id)?.backgroundServices.isChanging != true {
            if let binding = serviceProfiles.binding(for: device.id), binding.pendingApplication {
                enqueueServiceConfiguration(binding, for: device)
            }
        }
    }

    /// Waits for earlier global work and conflicting work on this device.
    /// An attaching screen blocks only operations that restore or disturb its state.
    private func hold(of identifier: DeviceInventoryID, waitsForAttach: Bool) -> Task<Void, Never>? {
        func holds(_ deviceID: DeviceInventoryID?, attaches: Bool) -> Bool {
            deviceID == nil || (deviceID == identifier && (waitsForAttach || !attaches))
        }
        var operations = Set(activeDeviceOperations.filter { holds($0.key, attaches: $0.value.attaches) }.values.map(\.id))
        if let runningOperation { operations.insert(runningOperation.id) }
        for operation in pendingOperations where holds(operation.deviceID, attaches: attachesOnAdmission(operation)) {
            operations.insert(operation.id)
        }
        guard !operations.isEmpty else { return nil }
        return Task {
            for operation in operations where self.unfinishedOperations[operation] != nil {
                await withCheckedContinuation { self.unfinishedOperations[operation]?.append($0) }
            }
        }
    }

    private func finishOperation(_ identifier: UUID) {
        unfinishedOperations.removeValue(forKey: identifier)?.forEach { $0.resume() }
    }

    /// Reports the outcome of an accepted change, which later host work waits for in its device's order.
    private func track(_ write: DeviceWrite, activity: String, on identifier: DeviceInventoryID) {
        acceptedWrites.append(AcceptedWrite(write: write, activity: activity, deviceID: identifier))
        publishQueueState()
        Task {
            let result = await write.task.result
            self.acceptedWrites.removeAll { $0.write.id == write.id }
            self.publishQueueState()
            if self.abandonedWrites.remove(write.id) != nil {
                self.onError?(QuitOutcome.notRun(activity))
            } else if case .failure(let error) = result {
                self.onError?(error)
            }
        }
    }

    func prepareForQuit() async throws {
        stopping = true
        let openings = activeDeviceOperations.values.filter { $0.request != nil }.compactMap(\.task)
        cancelPendingOpens()
        registry.stopReading()
        // Accepted changes finish below, but no child that only reads state can hold them or this wait.
        controller.stopReads()
        defer { controller.resumeReads() }
        statusRefreshTask?.cancel()
        let preparation = quitPreparation ?? Task { await self.finishAcceptedWork(openings: openings) }
        quitPreparation = preparation
        if let failure = await preparation.value { throw failure }
    }

    /// Waits up to `TerminationTimeout` for accepted work, then rejects queued work and stops
    /// running commands. Transactions and rollbacks finish within the remaining grace period;
    /// unfinished outcomes are reported as unknown. Later commands are bounded too.
    /// Returns any opening failure.
    private func finishAcceptedWork(openings: [Task<Void, any Error>]) async -> (any Error)? {
        let limit = terminationLimit ?? HostPreferences.terminationLimit
        let deadline = ContinuousClock.now + limit
        let postures = Task { await self.stopDevicePostures() }
        var finished = await postures.ends(before: deadline)
        if let operationTask, await !operationTask.ends(before: deadline) { finished = false }
        for accepted in acceptedWrites where await !accepted.write.task.ends(before: deadline) { finished = false }
        for task in managementRequests.values.compactMap(\.task) where await !task.ends(before: deadline) { finished = false }
        var heldOpenings: Set<Task<Void, any Error>> = []
        for opening in openings where await !opening.ends(before: deadline) {
            heldOpenings.insert(opening)
            finished = false
        }
        uninterruptedCommands.stopForTermination()
        if !finished {
            let unstarted = pendingOperations
            pendingOperations.removeAll()
            for operation in unstarted { finishOperation(operation.id) }
            publishQueueState()
            resumeOperations()
            for operation in unstarted { onError?(QuitOutcome.notRun(operation.activity)) }
            for accepted in acceptedWrites where registry.device(for: accepted.deviceID)?.isUnstarted(accepted.write) == true {
                abandonedWrites.insert(accepted.write.id)
                accepted.write.task.cancel()
            }
            heldOpenings = await waitForStoppedWork(openings: heldOpenings, before: .now + terminationGrace)
        }
        let reads = Task {
            await self.statusRefreshTask?.value
            await self.registry.finishReading()
        }
        if await !reads.ends(before: .now + terminationGrace) {
            NSLog("NeoSimulator: Reads of device state had not stopped when quitting went on.")
        }
        for opening in openings where !heldOpenings.contains(opening) {
            if case .failure(let error) = await opening.result, !(error is CancellationError) { return error }
        }
        return nil
    }

    /// Returns the openings that are still held at `deadline`.
    private func waitForStoppedWork(openings: Set<Task<Void, any Error>>, before deadline: ContinuousClock.Instant) async
        -> Set<Task<Void, any Error>> {
        let activity = runningOperation?.activity ?? activeDeviceOperations.values.first { $0.request == nil }?.activity
        if let operationTask, await !operationTask.ends(before: deadline) { onError?(QuitOutcome.unknown(activity ?? "A change")) }
        for accepted in acceptedWrites where !abandonedWrites.contains(accepted.write.id) {
            if await !accepted.write.task.ends(before: deadline) { onError?(QuitOutcome.unknown(accepted.activity)) }
        }
        for request in managementRequests.values {
            if let task = request.task, await !task.ends(before: deadline) {
                onError?(QuitOutcome.unknown(request.action.map { "\($0)" } ?? "An inspector change"))
            }
        }
        var held: Set<Task<Void, any Error>> = []
        for opening in openings where await !opening.ends(before: deadline) {
            held.insert(opening)
            onError?(QuitOutcome.unknown("Opening a device"))
        }
        return held
    }

    func quitRenderer(keepingDevicesRunning: Bool?, beforeEndingSession: () async throws -> Void = {}) async throws {
        do {
            try await prepareForQuit()
            try await controller.quitRenderer(keepingDevicesRunning: keepingDevicesRunning)
            try await beforeEndingSession()
            try await controller.endSession()
        } catch { resumeAfterCancelledQuit(); throw error }
    }

    func resumeAfterCancelledQuit() {
        stopping = false
        quitPreparation = nil
        uninterruptedCommands.resumeAfterCancelledQuit()
        registry.resumeReading()
        if inventoryRefreshRequested { Task { await refresh() } }
    }

    private func reportBackgroundError(_ error: any Error) {
        let message = error.localizedDescription
        if backgroundIssue != message {
            NSLog("NeoSimulator: %@", (error as? SimulatorHostFailure)?.technicalDetails ?? String(describing: error))
        }
        backgroundIssue = message
    }

    /// `device` is the one device the operation concerns; without one, it follows and holds the changes of every device.
    private func perform(_ activity: String, device: DeviceInventoryID? = nil, openDevice: SimulatorScreenOpenRequest? = nil,
                         operation: @escaping @MainActor () async throws -> Void) {
        enqueue(PendingOperation(activity: activity, deviceID: device, openDevice: openDevice) { _ in try await operation() })
    }

    /// Orders work per device while allowing different devices to proceed together.
    /// Global operations wait for all prior work and block all later work.
    private func enqueue(_ operation: PendingOperation) {
        guard !stopping else { return }
        var operation = operation
        operation.followsWrites = registry.writeTasks(for: operation.deviceID)
        unfinishedOperations[operation.id] = []
        pendingOperations.append(operation)
        publishQueueState()
        guard operationTask == nil else {
            resumeOperations()
            return
        }
        operationTask = Task {
            defer {
                self.operationTask = nil
                self.publishQueueState()
                self.reconcileDevicePostures()
            }
            while !self.pendingOperations.isEmpty || !self.activeDeviceOperations.isEmpty {
                guard let index = self.nextAdmissibleOperation() else {
                    self.publishQueueState()
                    await withCheckedContinuation { self.operationsChanged = $0 }
                    continue
                }
                let next = self.pendingOperations.remove(at: index)
                // Earlier operations, such as a close that shut the device down, have left the inventory that decides
                // this open. The host rejects an attach to a device that stops later instead of booting it.
                let attaches = self.attachesOnAdmission(next)
                if let device = next.deviceID {
                    let task = Task {
                        for write in next.followsWrites { _ = await write.result }
                        try await next.run(attaches)
                        try Task.checkCancellation()
                    }
                    self.activeDeviceOperations[device] = ActiveDeviceOperation(id: next.id, request: next.openDevice, task: task,
                                                                                activity: next.activity, attaches: attaches)
                    self.publishQueueState()
                    Task { await self.finishDeviceOperation(on: device, task) }
                } else {
                    self.runningOperation = next
                    self.publishQueueState()
                    defer { self.runningOperation = nil }
                    var failure: (any Error)?
                    for write in next.followsWrites { _ = await write.result }
                    do { try await next.run(false) }
                    catch { failure = error }
                    if !self.stopping { await self.refreshCatalog() }
                    self.finishOperation(next.id)
                    if let failure { self.onError?(failure) }
                }
            }
        }
    }

    private func finishDeviceOperation(on device: DeviceInventoryID, _ task: Task<Void, any Error>) async {
        let opens = activeDeviceOperations[device]?.request != nil
        defer {
            if let operation = activeDeviceOperations.removeValue(forKey: device) { finishOperation(operation.id) }
            publishQueueState()
            resumeOperations()
        }
        var failure: (any Error)?
        var refreshesCatalog = true
        do { try await task.value }
        catch {
            refreshesCatalog = !opens
            if !opens || !(error is CancellationError) { failure = error }
        }
        // Presentation and owned cleanup have finished, so the refresh below is not part of the cancellable open.
        activeDeviceOperations[device]?.task = nil
        if opens { openingDeviceIDs.remove(device) }
        if !stopping, refreshesCatalog || inventoryRefreshRequested { await refreshCatalog() }
        // A quit throws an opening's failure from its task.
        if let failure, !opens || !stopping { onError?(failure) }
    }

    private func publishQueueState() {
        isBusy = !activeDeviceOperations.isEmpty || runningOperation != nil || !pendingOperations.isEmpty
        holdsAllEdits = runningOperation != nil || pendingOperations.contains { $0.deviceID == nil }
        heldEditDeviceIDs = Set(pendingOperations.filter { !attachesOnAdmission($0) }.compactMap(\.deviceID))
            .union(activeDeviceOperations.filter { !$0.value.attaches }.keys)
        queuedDeviceIDs = Set(activeDeviceOperations.keys).union(pendingOperations.compactMap(\.deviceID))
        activity = runningOperation?.activity ?? activeDeviceOperations.values.first?.activity ?? pendingOperations.first?.activity
            ?? acceptedWrites.first?.activity ?? ""
    }

    /// The earliest pending operation that nothing running or accepted before it holds.
    private func nextAdmissibleOperation() -> Int? {
        let held = Set(activeDeviceOperations.keys)
        for (index, operation) in pendingOperations.enumerated() {
            guard let device = operation.deviceID else { return held.isEmpty ? index : nil }
            if !held.contains(device) { return index }
        }
        return nil
    }

    /// Whether admitting `operation` now would only attach the screen of its running device.
    private func attachesOnAdmission(_ operation: PendingOperation) -> Bool {
        guard operation.attachesRunningDevice, let request = operation.openDevice else { return false }
        return devices.contains { $0.inventoryID == request.deviceID && $0.state == "Booted" }
    }

    private func resumeOperations() {
        operationsChanged?.resume()
        operationsChanged = nil
    }

}

private extension DeviceSettingChange {
    /// A connecting screen restores the device's saved audio routes and location, and Display Zoom changes the
    /// framebuffer and relaunches the guest's interface, so these writes wait for a screen that is attaching.
    var waitsForScreenAttach: Bool {
        switch self {
        case .displayZoom, .audioInputDevice, .audioOutputDevice, .location, .locationScenario, .clearLocation: true
        case .appearance, .contentSize, .boldText, .increaseContrast, .lookAndFeel, .liquidGlassOpacity, .colorFilter,
             .reduceMotion, .showBorders, .reduceTransparency, .voiceOver, .volume: false
        }
    }
}

private struct InventoryReadError: LocalizedError {
    let issues: [DeviceInventoryIssue]
    let statusError: (any Error)?
    let observationIssue: String?
    let activeStateIssue: String?

    var errorDescription: String? {
        let messages = issues.map { issue in
            let source: String = switch issue.source {
            case .coreDevice: "Devices"
            case .rendererOwnership: "Open Screens"
            case .simulators(let xcode, _): xcode?.deletingPathExtension().lastPathComponent ?? "Simulators"
            }
            return "\(source): \(issue.error.localizedDescription)"
        }
        return (messages + [statusError?.localizedDescription, observationIssue, activeStateIssue].compactMap { $0 })
            .joined(separator: "\n")
    }
}

/// What became of work accepted before a quit that did not finish in the time the quit had.
private enum QuitOutcome: LocalizedError {
    case notRun(String)
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .notRun(let activity): "\(activity) did not run, because NeoSimulator quit first."
        case .unknown(let activity): "\(activity) had not finished when NeoSimulator quit, so what it changed is unknown."
        }
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
            let reason: String
            if error is CancellationError {
                reason = result.completedSteps.isEmpty
                    ? "The operation was stopped before the requested change was applied."
                    : "The operation was stopped."
            } else {
                reason = error.localizedDescription
            }
            return "\(name): \(reason)\(completed)"
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
