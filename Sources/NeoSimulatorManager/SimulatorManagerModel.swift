import Foundation
import Observation
import XcodeSimulatorHost

protocol SimulatorManagerSource: DeviceSettingsSource {
    func status() async throws -> SimulatorHostStatus
    func inventory() async -> DeviceInventorySnapshot
    func selectHost(_ host: SimulatorHost, xcodeURL: URL?) async throws
    func openDevice(_ deviceID: DeviceInventoryID, xcodeURL: URL?) async throws
    func closeDevice(_ deviceID: DeviceInventoryID, keepingDeviceRunning: Bool) async throws
    func creationCatalog() async throws -> SimulatorCreationContext
    func createSimulator(named name: String, deviceType: String, runtime: String, context: SimulatorCreationContext) async throws -> String
    func pairSimulators(watch: String, phone: String, context: SimulatorCreationContext) async throws
    func manage(_ action: DeviceManagementAction, devices: [InventoryDevice]) async -> DeviceManagementReport
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
    private(set) var managingDeviceIDs: Set<DeviceInventoryID> = []
    private(set) var isBusy = false
    private(set) var activity = ""
    private(set) var backgroundIssue: String?
    let settings: DeviceSettingsModel
    @ObservationIgnored var onError: ((any Error) -> Void)?
    @ObservationIgnored var onOpenRemoteDevice: ((CoreDeviceDevice) -> Void)?
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
    @ObservationIgnored private var managementTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var pendingOperations: [(activity: String, refreshCatalog: Bool, run: @MainActor () async throws -> Void)] = []

    init(rendererApplicationURL: URL,
         presentSimulator: (@MainActor @Sendable (SimulatorPresentationContext) async throws -> Void)? = nil) {
        let controller = SimulatorHostController(rendererApplicationURL: rendererApplicationURL, presentSimulator: presentSimulator)
        self.controller = controller
        settings = DeviceSettingsModel(source: controller)
    }

    init(source: any SimulatorManagerSource) {
        controller = source
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

    func openDevice(_ identifier: DeviceInventoryID) {
        perform("Opening simulator…") { try await self.controller.openDevice(identifier, xcodeURL: nil) }
    }

    func closeDevice(_ identifier: DeviceInventoryID, keepingDeviceRunning: Bool, after finishing: Task<Void, Never>) {
        // Accept the close before waiting, so a later open cannot overtake it.
        perform("Closing simulator…") {
            await finishing.value
            try await self.controller.closeDevice(identifier, keepingDeviceRunning: keepingDeviceRunning)
        }
    }

    func openScreen(for device: InventoryDevice) {
        guard !managingDeviceIDs.contains(device.id) else { return }
        switch device {
        case .simulator(let simulator): openDevice(simulator.inventoryID)
        case .remote:
            perform("Opening device screen…") {
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
            }
            do {
                let remoteIDs = Set(targets.filter { self.managementDisconnectsScreen(action, for: $0) }.map(\.id))
                if !remoteIDs.isEmpty { try await self.beforeManagingRemoteDevices?(remoteIDs) }
                try await self.beforeManagingSimulators?(action, targets)
                let report = await self.controller.manage(action, devices: targets)
                var presentationError: (any Error)?
                do { try await self.afterManagingSimulators?(action, targets) }
                catch { presentationError = error }
                if !self.stopping { await self.refreshCatalog() }
                if report.results.contains(where: { $0.error != nil }) || presentationError != nil {
                    self.onError?(DeviceManagementFailure(devices: targets, report: report, presentationError: presentationError))
                }
            } catch { self.onError?(error) }
        }

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
        managingDeviceIDs.insert(device.id)
        let request = UUID()
        managementTasks[request] = Task {
            defer {
                self.managingDeviceIDs.remove(device.id)
                self.managementTasks.removeValue(forKey: request)
            }
            do { try await operation() }
            catch { self.onError?(InspectorOperationFailure(deviceName: device.name, error: error)) }
            if !self.stopping {
                await self.refreshCatalog()
                completion()
            }
        }

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
        guard !managingDeviceIDs.contains(identifier), let device = inventory.first(where: { $0.id == identifier }) else { return }
        perform("Updating device settings…", refreshCatalog: false) {
            try await self.settings.apply(setting, to: device)
        }
    }

    func quitRenderer(keepingDevicesRunning: Bool?) async throws {
        stopping = true
        pendingOperations.removeAll { $0.refreshCatalog }
        settings.stopReading()
        statusRefreshTask?.cancel()
        await operationTask?.value
        for task in Array(managementTasks.values) { await task.value }
        await statusRefreshTask?.value
        await settings.finishReading()
        do { try await controller.quitRenderer(keepingDevicesRunning: keepingDevicesRunning) }
        catch { stopping = false; settings.resumeReading(); throw error }
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
        guard operationTask == nil else {
            return
        }
        settings.setReadingSuspended(true)
        operationTask = Task {
            defer {
                self.operationTask = nil
                self.isBusy = false
                self.activity = ""
                self.settings.setReadingSuspended(false)
            }
            while !self.pendingOperations.isEmpty {
                let next = self.pendingOperations.removeFirst()
                self.isBusy = next.refreshCatalog || self.pendingOperations.contains { $0.refreshCatalog }
                self.activity = next.activity
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
