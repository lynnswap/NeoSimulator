import AppKit
import Foundation
@testable import NeoSimulatorApp
@testable import NeoSimulatorDeviceIO
@testable import NeoSimulatorHostSupport
@testable import NeoSimulatorKit
@testable import NeoSimulatorPresentationAdapters
@testable import NeoSimulatorService
import Observation
import SwiftUI
import Synchronization
import Testing
import IOSurface
@testable import NeoSimulatorManager
@testable import NeoSimulatorCompactWindow
@testable import NeoSimulatorDeviceScreens
@testable import NeoSimulatorInspector
@testable import NeoSimulatorDeviceDisplay
@testable import NeoSimulatorSidebar

@MainActor final class ThumbnailTestSource: DeviceThumbnailSource {
    var stops = 0
    func stop() { stops += 1 }
}

struct ServiceChangeSource: DeviceStateSource {
    let device: InventoryDevice
    let backend: SimulatorBackgroundServiceBackend
    func inventory() -> DeviceInventorySnapshot { DeviceInventorySnapshot(devices: [device], issues: []) }
    func readSettings(_ groups: Set<DeviceSettingsGroup>, of device: InventoryDevice,
                      publish: @escaping @concurrent @Sendable (DeviceSettingsGroupRead) async -> Void) async {}
    func write(_ change: DeviceSettingChange, to device: InventoryDevice) async throws {}
    func backgroundServices(for device: InventoryDevice, catalog: BackgroundServiceCatalog) async throws
        -> SimulatorBackgroundServices
    { try await backend(catalog).read() }
    func setBackgroundServices(_ targets: [SimulatorBackgroundServiceTarget], enabled: Bool,
        catalog: BackgroundServiceCatalog, for device: InventoryDevice
    ) async throws
        -> SimulatorBackgroundServicesUpdate
    {
        try await backend(catalog).update(targets, enabled: enabled)
    }
    private func backend(_ catalog: BackgroundServiceCatalog) -> SimulatorBackgroundServiceBackend {
        var backend = backend
        backend.catalog = catalog
        return backend
    }
    func inspector(for device: InventoryDevice) -> DeviceInspector { DeviceInspector(device: device, simulatorXcodeURL: nil) }
    func stopReads() {}
    func resumeReads() {}
}

actor ManagerModelSource: SimulatorManagerSource {
    private var failsSessionStart = false
    private var failsSessionEnd = false
    private(set) var sessionEvents: [String] = []
    func failSessionStart() { failsSessionStart = true }
    func beginSession() throws {
        sessionEvents.append("begin")
        if failsSessionStart { throw Failure.unavailable }
    }
    func failNextSessionEnd() { failsSessionEnd = true }
    func endSession() throws {
        sessionEvents.append("end")
        if failsSessionEnd { failsSessionEnd = false; throw Failure.unavailable }
    }
    private nonisolated let cancelledOpens = Mutex<Set<DeviceInventoryID>>([])
    nonisolated var cancelledOpenIDs: Set<DeviceInventoryID> { cancelledOpens.withLock { $0 } }
    enum Event: Equatable, Sendable {
        case cancelledServiceRead(DeviceInventoryID), deviceHub, read(DeviceInventoryID), write(DeviceInventoryID),
            open(DeviceInventoryID), close(DeviceInventoryID), inspect(DeviceInventoryID), inventory, synchronize, quit,
            manage(DeviceManagementAction, [DeviceInventoryID]), readServices(DeviceInventoryID), changeServices(
                DeviceInventoryID)
    }
    struct ServiceChange: Equatable, Sendable {
        let targets: [SimulatorBackgroundServiceTarget]
        let enabled: Bool
    }
    enum Failure: LocalizedError {
        case unavailable, native
        var errorDescription: String? { self == .native ? "Native shutdown failed" : "Unavailable" }
    }
    nonisolated let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private var devices: [InventoryDevice]
    private var inspectorResponse: String?
    private var holdsInspectorReads = false
    private var inspectorReads: [(device: DeviceInventoryID, finished: CheckedContinuation<CommandOutput, any Error>)] = []
    private(set) var inspectorCommands: [DeviceInspectorCommand] = []
    private var holdsInventoryReads = false
    private var inventoryRead: CheckedContinuation<Void, Never>?
    private var holdsManagement = false
    private var failsClose = false
    private var immediateRead: SimulatorDeviceSettings?
    private var skipsSettingsReads = false
    /// A batch of settings reads that a test holds, and answers whole or a group at a time.
    private struct HeldRead {
        let device: DeviceInventoryID
        var groups: Set<DeviceSettingsGroup>
        let publish: @concurrent @Sendable (DeviceSettingsGroupRead) async -> Void
        let finished: CheckedContinuation<Void, Never>
    }
    private var heldReads: [HeldRead] = []
    private var openContinuations: [(DeviceInventoryID, CheckedContinuation<Void, any Error>)] = []
    private var heldWrites: [(device: DeviceInventoryID, finished: CheckedContinuation<Void, any Error>)] = []
    private(set) var writtenChanges: [DeviceSettingChange] = []
    private var holdsServiceReads = false
    private var reportsServiceReadCancellation = false
    private var serviceReads: [(device: DeviceInventoryID, finished: CheckedContinuation<SimulatorBackgroundServices, any Error>)] = []
    /// The categories that the last read or change covered, which the states it answers with cover.
    private var serviceCatalog = BackgroundServiceCatalog.builtIn
    private var serviceChange: CheckedContinuation<SimulatorBackgroundServicesUpdate, any Error>?
    private(set) var serviceChanges: [ServiceChange] = []
    private(set) var readCount = 0
    /// Settings groups read, however they were batched.
    private(set) var groupReadCount = 0
    private(set) var quitCount = 0
    private(set) var lastOpenXcodeURL: URL?
    private(set) var lastOpenBootIfNeeded: Bool?
    private(set) var artworkXcodeRequests: [DeviceInventoryID] = []
    private(set) var installedXcodeReadCount = 0
    private(set) var managementRequests = 0
    private(set) var preparationRequests = 0
    private let managementFailureID: DeviceInventoryID?
    private var failingSimulatorCommand: String?
    private var managementWaiters: [(DeviceManagementAction, [DeviceInventoryID], CheckedContinuation<Void, Never>)] = []
    private var admittedManagement: Set<UUID> = []

    init(devices: [InventoryDevice], managementFailureID: DeviceInventoryID? = nil, holdsManagement: Bool = false,
         inspectorResponse: String? = nil) {
        self.managementFailureID = managementFailureID
        self.holdsManagement = holdsManagement
        self.devices = devices
        self.inspectorResponse = inspectorResponse
        (events, continuation) = AsyncStream.makeStream()
    }

    func xcodeURL(forDevice deviceID: DeviceInventoryID) -> URL {
        artworkXcodeRequests.append(deviceID)
        return URL(fileURLWithPath: "/Applications/Test Xcode.app")
    }
    func installedXcodes() -> [SimulatorXcode] {
        installedXcodeReadCount += 1
        return [SimulatorXcode(url: URL(fileURLWithPath: "/Applications/Test Xcode.app"), version: "27.1", name: "Test Xcode")]
    }
    func setDevices(_ devices: [InventoryDevice]) { self.devices = devices }
    private nonisolated let reads = CommandReads()
    private var heldRead: SystemCommand?
    nonisolated func stopReads() { reads.stop() }
    nonisolated func resumeReads() { reads.resume() }
    /// Inventory and management catalog reads wait for this command, through the production read boundary.
    func holdReads(in command: SystemCommand?) { heldRead = command }
    private func readThroughHeldCommand() async throws {
        if let heldRead { _ = try await reads.run(heldRead) }
    }
    func inventory() async throws -> DeviceInventorySnapshot {
        try await readThroughHeldCommand()
        if holdsInventoryReads {
            await withCheckedContinuation { waiting in
                inventoryRead = waiting
                continuation.yield(.inventory)
            }
        }
        return DeviceInventorySnapshot(devices: devices, issues: [])
    }
    func holdInventoryReads() { holdsInventoryReads = true }
    func completeInventoryRead() {
        holdsInventoryReads = false
        inventoryRead?.resume()
        inventoryRead = nil
    }
    func status() -> SimulatorHostStatus {
        sessionEvents.append("status")
        return SimulatorHostStatus(
            host: failsSessionStart ? .deviceHub : .neo,
                                   restorationAvailable: false, rendererRunning: false)
    }
    func readSettings(_ groups: Set<DeviceSettingsGroup>, of device: InventoryDevice,
                      publish: @escaping @concurrent @Sendable (DeviceSettingsGroupRead) async -> Void) async {
        if skipsSettingsReads { return }
        readCount += 1
        groupReadCount += groups.count
        if let immediateRead {
            self.immediateRead = nil
            continuation.yield(.read(device.id))
            for group in groups { await publish(.values(group) { $0.replace(group, with: immediateRead) }) }
            return
        }
        await withCheckedContinuation { waiting in
            heldReads.append(HeldRead(device: device.id, groups: groups, publish: publish, finished: waiting))
            continuation.yield(.read(device.id))
        }
    }
    func returnOnNextRead(_ settings: SimulatorDeviceSettings) { immediateRead = settings }
    /// For a test of something else: settings reads answer nothing, at once and without an event.
    func skipSettingsReads() { skipsSettingsReads = true }
    /// Answers what the oldest held read of `device` still waits for.
    func completeRead(_ settings: SimulatorDeviceSettings, for device: DeviceInventoryID? = nil) async {
        guard let index = heldReads.firstIndex(where: { device == nil || $0.device == device }) else { return }
        let read = heldReads.remove(at: index)
        for group in read.groups { await read.publish(.values(group) { $0.replace(group, with: settings) }) }
        read.finished.resume()
    }
    /// Answers one group of the oldest held read that has it, which ends once nothing is left to answer.
    func publishRead(_ result: DeviceSettingsGroupRead) async {
        guard let index = heldReads.firstIndex(where: { $0.groups.contains(result.group) }) else { return }
        heldReads[index].groups.remove(result.group)
        let read = heldReads[index]
        if read.groups.isEmpty { heldReads.remove(at: index) }
        await read.publish(result)
        if read.groups.isEmpty { read.finished.resume() }
    }
    /// What each held read still waits for, oldest first.
    var heldReadGroups: [Set<DeviceSettingsGroup>] { heldReads.map(\.groups) }
    func write(_ change: DeviceSettingChange, to device: InventoryDevice) async throws {
        writtenChanges.append(change)
        switch change {
        case .appearance, .contentSize, .boldText, .showBorders, .reduceTransparency,
             .audioOutputDevice, .audioInputDevice, .displayZoom, .clearLocation, .locationScenario: break
        default: throw Failure.unavailable
        }
        try await withCheckedThrowingContinuation { waiting in
            heldWrites.append((device.id, waiting))
            continuation.yield(.write(device.id))
        }
    }
    func completeWrite(for device: DeviceInventoryID? = nil) {
        guard let index = heldWrites.firstIndex(where: { device == nil || $0.device == device }) else { return }
        heldWrites.remove(at: index).finished.resume()
    }
    func failWrite() {
        guard !heldWrites.isEmpty else { return }
        heldWrites.removeFirst().finished.resume(throwing: Failure.unavailable)
    }
    /// Background service reads return no overrides at once unless a test holds them.
    func holdServiceReads(_ held: Bool = true) { holdsServiceReads = held }
    func observeServiceReadCancellation() { reportsServiceReadCancellation = true }
    func backgroundServices(for device: InventoryDevice, catalog: BackgroundServiceCatalog) async throws
        -> SimulatorBackgroundServices
    {
        serviceCatalog = catalog
        guard holdsServiceReads else { return services(disabled: []) }
        let cancellation = reportsServiceReadCancellation ? continuation : nil
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiting in
                serviceReads.append((device.id, waiting))
                continuation.yield(.readServices(device.id))
            }
        } onCancel: {
            cancellation?.yield(.cancelledServiceRead(device.id))
        }
    }
    func completeServiceRead(disabled: Set<String>, loaded: Set<String> = [], for device: DeviceInventoryID? = nil) {
        guard let index = serviceReads.firstIndex(where: { device == nil || $0.device == device }) else { return }
        serviceReads.remove(at: index).finished.resume(returning: services(disabled: disabled, loaded: loaded))
    }
    func failServiceRead() {
        guard !serviceReads.isEmpty else { return }
        serviceReads.removeFirst().finished.resume(throwing: Failure.unavailable)
    }
    func setBackgroundServices(_ targets: [SimulatorBackgroundServiceTarget], enabled: Bool,
        catalog: BackgroundServiceCatalog, for device: InventoryDevice
    ) async throws
        -> SimulatorBackgroundServicesUpdate
    {
        serviceCatalog = catalog
        serviceChanges.append(ServiceChange(targets: targets, enabled: enabled))
        return try await withCheckedThrowingContinuation { waiting in
            serviceChange = waiting
            continuation.yield(.changeServices(device.id))
        }
    }
    func completeServiceChange(disabled: Set<String>, notStarted: [String] = []) {
        let waiting = serviceChange
        serviceChange = nil
        waiting?.resume(returning: SimulatorBackgroundServicesUpdate(
                services: services(disabled: disabled), stillEnabledLabels: [], notStartedLabels: notStarted))
    }
    func failServiceChange(disabled: Set<String>?, loaded: Set<String> = [], mayHaveChanged: Bool = true) {
        let waiting = serviceChange
        serviceChange = nil
        waiting?.resume(throwing: SimulatorBackgroundServicesUpdateFailure(
                services: disabled.map { services(disabled: $0, loaded: loaded) }, mayHaveChanged: mayHaveChanged,
            underlyingError: SimulatorHostFailure(Failure.unavailable)))
    }
    private func services(disabled: Set<String>, loaded: Set<String> = []) -> SimulatorBackgroundServices {
        SimulatorBackgroundServices(
            disabled: disabled, loaded: loaded, productFamily: "iPhone", catalog: serviceCatalog)
    }
    func quitRenderer(keepingDevicesRunning: Bool?) { sessionEvents.append("quit"); quitCount += 1; continuation.yield(.quit) }
    private(set) var selectedHosts: [SimulatorHost] = []
    func selectHost(_ host: SimulatorHost, xcodeURL: URL?) { selectedHosts.append(host) }
    func openDeviceHub(xcodeURL: URL, requestURL: URL?) { continuation.yield(.deviceHub) }
    func deviceHubDidExit(xcodeURL: URL) { sessionEvents.append("resume") }
    nonisolated func makeScreenOpenRequest(for deviceID: DeviceInventoryID) -> SimulatorScreenOpenRequest {
        SimulatorScreenOpenRequest(deviceID: deviceID) { _ = self.cancelledOpens.withLock { $0.insert(deviceID) } }
    }
    func openDevice(_ request: SimulatorScreenOpenRequest, xcodeURL: URL?, bootIfNeeded: Bool) async throws {
        let deviceID = request.deviceID
        lastOpenXcodeURL = xcodeURL
        lastOpenBootIfNeeded = bootIfNeeded
        try await withCheckedThrowingContinuation { waiting in
            openContinuations.append((deviceID, waiting))
            continuation.yield(.open(deviceID))
        }
    }
    func completeOpen(for deviceID: DeviceInventoryID? = nil) {
        guard let index = openContinuations.firstIndex(where: { deviceID == nil || $0.0 == deviceID }) else { return }
        openContinuations.remove(at: index).1.resume()
    }
    func failOpen() {
        guard !openContinuations.isEmpty else { return }
        openContinuations.removeFirst().1.resume(throwing: Failure.unavailable)
    }
    func closeDevice(_ deviceID: DeviceInventoryID, keepingDeviceRunning: Bool) throws {
        continuation.yield(.close(deviceID))
        if failsClose { throw Failure.native }
    }
    func failClose() { failsClose = true }
    func creationCatalog() throws -> SimulatorCreationContext { throw Failure.unavailable }
    func creationCatalog(for deviceID: DeviceInventoryID) throws -> SimulatorCreationContext { throw Failure.unavailable }
    func createSimulator(named name: String, deviceType: String, runtime: String, context: SimulatorCreationContext) throws -> String { throw Failure.unavailable }
    func pairSimulators(watch: String, phone: String, context: SimulatorCreationContext) throws { throw Failure.unavailable }
    func holdManagement() { holdsManagement = true }
    func failSimulatorCommand(_ command: String) { failingSimulatorCommand = command }
    func manage(_ action: DeviceManagementAction, devices: [InventoryDevice],
                preparingDisplay: (@isolated(any) @Sendable (InventoryDevice) async throws -> Void)?) async -> DeviceManagementReport {
        let request = UUID()
        let preparation: (@isolated(any) @Sendable (InventoryDevice) async throws -> Void)?
        if let preparingDisplay {
            preparation = { target in
                await self.recordPreparation()
                try await preparingDisplay(target)
            }
        } else { preparation = nil }
        let backend = DeviceManagementBackend(context: { device, _ in
            try await self.readThroughHeldCommand()
            return DeviceManagementContext(device: device, xcodeURL: URL(fileURLWithPath: "/Fixture.app"), renderer: nil)
        }, renderer: { _ in nil }, readPairs: { _, _ in
            await self.beginManagement(request, action: action, devices: devices)
            return Data()
        }, runSimctl: { _, arguments, _ in
            await self.beginManagement(request, action: action, devices: devices)
            if arguments.first == (await self.failingSimulatorCommand) { throw Failure.native }
            return Data()
        }, runDevicectl: { _ in
            await self.beginManagement(request, action: action, devices: devices)
            return Data()
        }, shutdownSimulator: { _, _, _ in
            await self.beginManagement(request, action: action, devices: devices)
        }, manageCoreDevice: { _, identifier in
            await self.beginManagement(request, action: action, devices: devices)
            if self.managementFailureID == identifier { throw Failure.native }
        }, release: { _, _ in }, restart: { _, _, _ in false }, attach: { _, _ in })
        return await backend.manage(action, devices: devices, preparingDisplay: preparation)
    }
    private func recordPreparation() { preparationRequests += 1 }
    private func beginManagement(_ request: UUID, action: DeviceManagementAction, devices: [InventoryDevice]) async {
        guard admittedManagement.insert(request).inserted else { return }
        managementRequests += 1
        if holdsManagement {
            await withCheckedContinuation { waiting in
                managementWaiters.append((action, devices.map(\.id), waiting))
                continuation.yield(.manage(action, devices.map(\.id)))
            }
        } else { continuation.yield(.manage(action, devices.map(\.id))) }
    }
    func completeManagement(_ action: DeviceManagementAction, for device: DeviceInventoryID? = nil) {
        guard let index = managementWaiters.firstIndex(where: { waiter in
            waiter.0 == action && (device.map { waiter.1.contains($0) } ?? true)
        }) else { return }
        managementWaiters.remove(at: index).2.resume()
        holdsManagement = false
    }
    func inspector(for device: InventoryDevice) throws -> DeviceInspector {
        guard inspectorResponse != nil else { throw Failure.unavailable }
        return DeviceInspector(device: device, simulatorXcodeURL: URL(fileURLWithPath: "/Fixture.app"),
            transport: .init(run: { command in try await self.readInspector(device.id, command: command) }))
    }
    private func readInspector(_ identifier: DeviceInventoryID, command: DeviceInspectorCommand) async throws -> CommandOutput {
        inspectorCommands.append(command)
        if holdsInspectorReads {
            return try await withCheckedThrowingContinuation { waiting in
                inspectorReads.append((identifier, waiting))
                continuation.yield(.inspect(identifier))
            }
        }
        continuation.yield(.inspect(identifier))
        return CommandOutput(terminationStatus: 0, stdout: Data((inspectorResponse ?? "").utf8), stderr: Data())
    }
    func holdInspectorReads() { holdsInspectorReads = true }
    func setInspectorResponse(_ response: String) { inspectorResponse = response }
    /// Answers `device`'s oldest held read, or every held read and those that follow when no device is named.
    func completeInspectorRead(_ response: String? = nil, of device: DeviceInventoryID? = nil) {
        if let response { inspectorResponse = response }
        let output = CommandOutput(terminationStatus: 0, stdout: Data((inspectorResponse ?? "").utf8), stderr: Data())
        for waiting in takeInspectorReads(of: device) { waiting.resume(returning: output) }
    }
    func failInspectorRead(with error: any Error = Failure.unavailable, of device: DeviceInventoryID? = nil) {
        for waiting in takeInspectorReads(of: device) { waiting.resume(throwing: error) }
    }
    private func takeInspectorReads(of device: DeviceInventoryID?) -> [CheckedContinuation<CommandOutput, any Error>] {
        guard let device else {
            holdsInspectorReads = false
            defer { inspectorReads = [] }
            return inspectorReads.map(\.finished)
        }
        guard let index = inspectorReads.firstIndex(where: { $0.device == device }) else { return [] }
        return [inspectorReads.remove(at: index).finished]
    }
    func restore() throws { throw Failure.unavailable }
    private(set) var synchronizationRequests = 0
    private var failsSynchronization = false
    func failNextSynchronization() { failsSynchronization = true }
    func synchronizeXcodeConnections() throws -> Bool {
        synchronizationRequests += 1
        continuation.yield(.synchronize)
        if failsSynchronization { failsSynchronization = false; throw HostOperationError.temporary("connection", "Try again") }
        return false
    }
}

@MainActor
final class SettingsWindowFrameSamples: NSObject {
    var frames: [NSRect] = []
    @objc func resized(_ notification: Notification) {
        if let window = notification.object as? NSWindow { frames.append(window.frame) }
    }
}

@MainActor
final class ManagerPostureConnections {
    enum Event: Equatable { case observing(DeviceInventoryID), stopped(DeviceInventoryID) }
    let events = AsyncStream<Event>.makeStream()
    private(set) var identifiers: [DeviceInventoryID] = []
    private var current: ManagerPostureTransport?
    var startFailure: (any Error)?
    func failCurrentObservation() { current?.fail() }
    func model(_ identifier: DeviceInventoryID) -> DevicePostureModel {
        DevicePostureModel(deviceID: identifier) { [self] id in
            identifiers.append(id)
            if let startFailure { throw startFailure }
            let transport = ManagerPostureTransport(identifier: id, events: events.continuation)
            current = transport
            return transport
        }
    }
}

@MainActor
final class ManagerPostureTransport: DevicePostureTransport {
    let identifier: DeviceInventoryID
    let events: AsyncStream<ManagerPostureConnections.Event>.Continuation
    private let lifetime = AsyncThrowingStream<Void, any Error>.makeStream()
    init(identifier: DeviceInventoryID, events: AsyncStream<ManagerPostureConnections.Event>.Continuation) {
        self.identifier = identifier
        self.events = events
    }
    func observe(_ update: @escaping @MainActor (Double?) -> Void) async throws {
        update(0)
        events.yield(.observing(identifier))
        defer { events.yield(.stopped(identifier)) }
        for try await _ in lifetime.stream { }
    }
    func fail() { lifetime.continuation.finish(throwing: ManagerModelSource.Failure.unavailable) }
    func send(_ posture: DevicePosture) async throws { }
}
