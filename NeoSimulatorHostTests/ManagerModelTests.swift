import Foundation
import Testing
@testable import XcodeSimulatorHost

@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor
struct ManagerModelTests {
    @Test func openingASimulatorRetriesItsFailedPostureAfterPresentationSucceeds() async throws {
        guard case .simulator(let simulator) = simulator(deviceSet: "/custom-device-set") else { return }
        let device = InventoryDevice.simulator(simulator.inventoryCopy(ownerXcodeURL: nil, capabilities: DevicePosturePayload.features))
        let source = ManagerModelSource(devices: [device])
        let postures = ManagerPostureConnections()
        var events = source.events.makeAsyncIterator()
        var postureEvents = postures.events.stream.makeAsyncIterator()
        let failures = AsyncStream<Void>.makeStream()
        var failureEvents = failures.stream.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source, makeDevicePosture: postures.model)
        manager.onError = { _ in failures.continuation.yield(()) }
        await manager.refresh()
        manager.openDevice(device.id)
        #expect(await events.next() == .open(device.id))
        manager.setOpenDeviceScreens([device.id])
        #expect(manager.isBusy && manager.devicePostures.isEmpty)
        await source.completeOpen()
        #expect(await postureEvents.next() == .observing(device.id))
        #expect(!manager.isBusy)
        let failed = try #require(manager.devicePostures[device.id])
        postures.failCurrentObservation()
        #expect(await postureEvents.next() == .stopped(device.id))
        try #require(failed.state == .failed)

        manager.openDevice(device.id)
        #expect(await events.next() == .open(device.id))
        #expect(manager.devicePostures[device.id] === failed)
        await source.failOpen()
        _ = await failureEvents.next()
        #expect(manager.devicePostures[device.id] === failed && failed.state == .failed)

        manager.openDevice(device.id)
        #expect(await events.next() == .open(device.id))
        #expect(manager.devicePostures[device.id] === failed)
        await source.completeOpen()
        for _ in 0..<200 where manager.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        try #require(!manager.isBusy && manager.devicePostures[device.id] !== failed)
        #expect(await postureEvents.next() == .observing(device.id))
        #expect(failed.state == .stopped && manager.devicePostures[device.id]?.canSelect == true)
        #expect(postures.identifiers == [device.id, device.id])
        await manager.stopDevicePostures()
        #expect(await postureEvents.next() == .stopped(device.id))
    }

    @Test func connectingAScreenReplacesItsFailedPostureOwnerAfterDrainingIt() async throws {
        let features = DevicePosturePayload.features
        let data = try JSONSerialization.data(withJSONObject: ["result": ["devices": [[
            "identifier": "remote-command", "properties": ["hardware": ["reality": "physical", "hardwareModel": "V68AP"],
                "state": ["name": "Duo"], "connection": ["state": "connected"]],
            "capabilities": features.sorted().map { ["featureIdentifier": $0] }]]]])
        let device = InventoryDevice.remote(try #require(CoreDeviceInventoryDecoder.decode(data).first))
        let postures = ManagerPostureConnections()
        var events = postures.events.stream.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: ManagerModelSource(devices: [device]), makeDevicePosture: postures.model)
        await manager.refresh()
        manager.setOpenDeviceScreens([device.id])
        #expect(await events.next() == .observing(device.id))
        let failed = try #require(manager.devicePostures[device.id])
        await manager.deviceScreenDidConnect(device.id)
        #expect(manager.devicePostures[device.id] === failed)
        postures.failCurrentObservation()
        #expect(await events.next() == .stopped(device.id))
        #expect(failed.state == .failed && !failed.canSelect)
        await manager.deviceScreenDidConnect(device.id)
        #expect(await events.next() == .observing(device.id))
        #expect(failed.state == .stopped)
        #expect(manager.devicePostures[device.id] !== failed && manager.devicePostures[device.id]?.canSelect == true)
        #expect(postures.identifiers == [device.id, device.id])
        await manager.stopDevicePostures()
        #expect(await events.next() == .stopped(device.id))
    }

    @Test func restartingAnOpenSimulatorReplacesPostureObservationAfterManagementFinishes() async throws {
        guard case .simulator(let simulator) = simulator(deviceSet: "/custom-device-set") else { return }
        let device = InventoryDevice.simulator(simulator.inventoryCopy(ownerXcodeURL: nil, capabilities: DevicePosturePayload.features))
        let source = ManagerModelSource(devices: [device])
        let postures = ManagerPostureConnections()
        var events = source.events.makeAsyncIterator()
        var postureEvents = postures.events.stream.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source, makeDevicePosture: postures.model)
        var failures: [any Error] = []
        manager.onError = { failures.append($0) }
        await manager.refresh()
        manager.setOpenDeviceScreens([device.id])
        #expect(await postureEvents.next() == .observing(device.id))
        #expect(manager.devicePostures[device.id]?.canSelect == true)

        await source.holdManagement()
        manager.manage(.restart, devices: [device])
        #expect(await postureEvents.next() == .stopped(device.id))
        #expect(await events.next() == .management)
        // Inventory still advertises the old booted simulator during restart.
        await manager.inventoryDidChange()
        manager.setOpenDeviceScreens([device.id])
        #expect(manager.devicePostures[device.id] == nil)
        #expect(postures.identifiers == [device.id])
        await source.completeManagement()
        #expect(await postureEvents.next() == .observing(device.id))
        #expect(postures.identifiers == [device.id, device.id])
        #expect(manager.devicePostures[device.id]?.canSelect == true)
        #expect(failures.isEmpty)

        // A presentation-preparation failure must restore controls for a screen
        // that remains open, even though the backend management never started.
        manager.beforeManagingSimulators = { _, _ in throw ManagerModelSource.Failure.unavailable }
        manager.manage(.restart, devices: [device])
        #expect(await postureEvents.next() == .stopped(device.id))
        #expect(await postureEvents.next() == .observing(device.id))
        #expect(postures.identifiers.count == 3 && failures.count == 1)
        manager.setOpenDeviceScreens([])
        manager.closeDevice(device.id, keepingDeviceRunning: true, after: Task {})
        await manager.inventoryDidChange()
        #expect(await postureEvents.next() == .stopped(device.id))
        #expect(await events.next() == .close(device.id))
        #expect(manager.devicePostures.isEmpty && postures.identifiers.count == 3)
        await manager.stopDevicePostures()
    }

    @Test func aRemoteScreenUsesItsCommandIdentityAndClosingDuringManagementPreventsResubscription() async throws {
        let features = DevicePosturePayload.features.union(["com.apple.coredevice.feature.rebootdevice"])
        let data = try JSONSerialization.data(withJSONObject: ["result": ["devices": [[
            "identifier": "coredevice-command-id", "properties": [
                "hardware": ["reality": "physical", "udid": "different-hardware-udid", "hardwareModel": "V68AP"],
                "state": ["name": "Remote Duo"], "connection": ["state": "connected"]],
            "capabilities": features.sorted().map { ["featureIdentifier": $0] }]]]])
        let device = InventoryDevice.remote(try #require(CoreDeviceInventoryDecoder.decode(data).first))
        let source = ManagerModelSource(devices: [device])
        let postures = ManagerPostureConnections()
        var events = source.events.makeAsyncIterator()
        var postureEvents = postures.events.stream.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source, makeDevicePosture: postures.model)
        await manager.refresh()
        manager.setOpenDeviceScreens([device.id])
        #expect(await postureEvents.next() == .observing(.coreDevice("coredevice-command-id")))
        #expect(manager.devicePostures[device.id]?.confirmedPosture == .closed)
        manager.beforeManagingRemoteDevices = { identifiers in
            #expect(identifiers == [device.id])
            // stopAndClose removes the actual remote session before management.
            manager.setOpenDeviceScreens([])
        }
        await source.holdManagement()
        manager.manage(.restart, devices: [device])
        #expect(await postureEvents.next() == .stopped(device.id))
        #expect(await events.next() == .management)
        await manager.inventoryDidChange()
        #expect(manager.devicePostures.isEmpty && postures.identifiers == [device.id])
        await source.completeManagement()
        for _ in 0..<200 where !manager.managingDeviceIDs.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(manager.managingDeviceIDs.isEmpty)
        #expect(manager.devicePostures.isEmpty && postures.identifiers == [device.id])
        manager.setOpenDeviceScreens([device.id])
        #expect(await postureEvents.next() == .observing(device.id))
        #expect(postures.identifiers == [device.id, device.id])
        await manager.stopDevicePostures()
        #expect(await postureEvents.next() == .stopped(device.id))
    }

    @Test func acceptedEditsMergeSnapshotsAndDrainBeforeQuit() async throws {
        let device = simulator()
        let source = ManagerModelSource(devices: [device])
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source)
        await manager.refresh()
        manager.settings.inspect(device, selectionCount: 1)
        #expect(await events.next() == .read(device.id))
        await source.completeRead(settings(appearance: "light", contentSize: "medium"))
        await manager.settings.finishReading()

        manager.setDeviceSetting(.appearance("dark"), for: device.id)
        manager.setDeviceSetting(.contentSize("large"), for: device.id)
        #expect(await events.next() == .write(device.id))
        await source.completeWrite()
        #expect(await events.next() == .write(device.id))
        let inputs = await source.writeInputs
        #expect(inputs.count == 2)
        #expect(inputs[1]?.appearance == "dark")
        #expect(inputs[1]?.contentSize == "medium")

        let beganQuitting = AsyncStream<Void>.makeStream()
        var quitEvents = beganQuitting.stream.makeAsyncIterator()
        let quitting = Task {
            beganQuitting.continuation.yield(())
            try await manager.quitRenderer(keepingDevicesRunning: true)
        }
        await quitEvents.next()
        await source.completeWrite()
        #expect(await events.next() == .quit)
        try await quitting.value
        #expect(manager.settings.settings?.appearance == "dark")
        #expect(manager.settings.settings?.contentSize == "large")
        #expect(await source.readCount == 1)
    }

    @Test func editingDuringRefreshStillReadsExternalChanges() async throws {
        let device = simulator()
        let source = ManagerModelSource(devices: [device])
        var events = source.events.makeAsyncIterator()
        let model = DeviceSettingsModel(source: source)
        model.inspect(device, selectionCount: 1)
        #expect(await events.next() == .read(device.id))
        await source.completeRead(settings(appearance: "light", contentSize: "medium"))
        await model.finishReading()

        model.requestRefresh()
        #expect(await events.next() == .read(device.id))
        let beganApplying = AsyncStream<Void>.makeStream()
        var applyEvents = beganApplying.stream.makeAsyncIterator()
        let applying = Task {
            beganApplying.continuation.yield(())
            try await model.apply(.contentSize("large"), to: device)
        }
        await applyEvents.next()
        await source.completeRead(settings(appearance: "dark", contentSize: "medium"))
        #expect(await events.next() == .write(device.id))
        await source.returnOnNextRead(settings(appearance: "dark", contentSize: "large"))
        await source.completeWrite()
        try await applying.value
        await model.finishReading()

        #expect(model.settings?.appearance == "dark")
        #expect(model.settings?.contentSize == "large")
    }

    @Test func switchingDeviceSetsDiscardsTheCancelledResult() async throws {
        let first = simulator(deviceSet: "/first")
        let second = simulator(deviceSet: "/second")
        let source = ManagerModelSource(devices: [first, second])
        var events = source.events.makeAsyncIterator()
        let model = DeviceSettingsModel(source: source)
        model.inspect(first, selectionCount: 1)
        #expect(await events.next() == .read(first.id))
        model.inspect(second, selectionCount: 1)
        // The source deliberately completes even after cancellation, as an in-flight IPC can.
        await source.completeRead(settings(appearance: "dark"))
        #expect(await events.next() == .read(second.id))
        #expect(model.settings == nil)
        await source.completeRead(settings(appearance: "light"))
        await model.finishReading()
        #expect(model.device?.id == second.id)
        #expect(model.settings?.appearance == "light")
    }

    @Test func clearingSelectionDiscardsTheCancelledResult() async throws {
        let device = simulator()
        let source = ManagerModelSource(devices: [device])
        var events = source.events.makeAsyncIterator()
        let model = DeviceSettingsModel(source: source)
        model.inspect(device, selectionCount: 1)
        #expect(await events.next() == .read(device.id))
        model.inspect(nil, selectionCount: 0)
        await source.completeRead(settings(appearance: "dark"))
        await model.finishReading()
        #expect(model.device == nil)
        #expect(model.settings == nil)
        #expect(model.issue == nil)
        #expect(!model.isLoading)
    }

    @Test func failedEditRefreshesTheSelectedDevice() async throws {
        let device = simulator()
        let source = ManagerModelSource(devices: [device])
        var events = source.events.makeAsyncIterator()
        let model = DeviceSettingsModel(source: source)
        model.inspect(device, selectionCount: 1)
        #expect(await events.next() == .read(device.id))
        await source.completeRead(settings(appearance: "light"))
        await model.finishReading()

        let applying = Task { try await model.apply(.appearance("dark"), to: device) }
        #expect(await events.next() == .write(device.id))
        await source.failWrite()
        do { try await applying.value; Issue.record("The source failure must reach the caller.") }
        catch { #expect(error is ManagerModelSource.Failure) }
        #expect(await events.next() == .read(device.id))
        await source.completeRead(settings(appearance: "dark"))
        await model.finishReading()
        #expect(model.settings?.appearance == "dark")
        #expect(model.issue == nil)
    }

    private func simulator(deviceSet: String? = nil) -> InventoryDevice {
        .simulator(SimulatorHostDevice(identifier: "same-udid", name: "Test Phone", descriptiveName: "Test Phone",
            runtimeIdentifier: "test-runtime", runtimeName: "iOS", productFamily: "iPhone", state: "Booted",
            deviceSetPath: deviceSet))
    }

    private func settings(appearance: String, contentSize: String? = nil) -> SimulatorDeviceSettings {
        SimulatorDeviceSettings(appearance: appearance, contentSize: contentSize)
    }
}

private actor ManagerModelSource: SimulatorManagerSource {
    enum Event: Equatable, Sendable { case read(DeviceInventoryID), write(DeviceInventoryID), open(DeviceInventoryID), close(DeviceInventoryID), quit, management }
    enum Failure: Error { case unavailable }
    nonisolated let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private let devices: [InventoryDevice]
    private var holdsManagement = false
    private var managementContinuation: CheckedContinuation<Void, Never>?
    private var immediateRead: SimulatorDeviceSettings?
    private var readContinuation: CheckedContinuation<SimulatorDeviceSettings, any Error>?
    private var openContinuation: CheckedContinuation<Void, any Error>?
    private var writeContinuation: CheckedContinuation<SimulatorDeviceSettings, any Error>?
    private var pendingWrite: SimulatorDeviceSettings?
    private(set) var writeInputs: [SimulatorDeviceSettings?] = []
    private(set) var readCount = 0

    init(devices: [InventoryDevice]) {
        self.devices = devices
        (events, continuation) = AsyncStream.makeStream()
    }

    func inventory() -> DeviceInventorySnapshot { DeviceInventorySnapshot(devices: devices, issues: []) }
    func status() -> SimulatorHostStatus { SimulatorHostStatus(host: .neo, restorationAvailable: false, rendererRunning: false) }
    func deviceSettings(for device: InventoryDevice) async throws -> SimulatorDeviceSettings {
        readCount += 1
        if let immediateRead {
            self.immediateRead = nil
            continuation.yield(.read(device.id))
            return immediateRead
        }
        return try await withCheckedThrowingContinuation { waiting in
            readContinuation = waiting
            continuation.yield(.read(device.id))
        }
    }
    func returnOnNextRead(_ settings: SimulatorDeviceSettings) { immediateRead = settings }
    func completeRead(_ settings: SimulatorDeviceSettings) {
        let waiting = readContinuation
        readContinuation = nil
        waiting?.resume(returning: settings)
    }
    func setDeviceSetting(_ setting: SimulatorDeviceSetting, for device: InventoryDevice) async throws {
        _ = try await write(setting, device: device, updating: nil)
    }
    func setDeviceSetting(_ setting: SimulatorDeviceSetting, for device: InventoryDevice,
                          updating settings: SimulatorDeviceSettings) async throws -> SimulatorDeviceSettings {
        try await write(setting, device: device, updating: settings)
    }
    private func write(_ setting: SimulatorDeviceSetting, device: InventoryDevice,
                       updating snapshot: SimulatorDeviceSettings?) async throws -> SimulatorDeviceSettings {
        writeInputs.append(snapshot)
        var updated = snapshot ?? SimulatorDeviceSettings()
        switch setting {
        case .appearance(let appearance): updated.appearance = appearance
        case .contentSize(let size): updated.contentSize = size
        default: throw Failure.unavailable
        }
        pendingWrite = updated
        return try await withCheckedThrowingContinuation { waiting in
            writeContinuation = waiting
            continuation.yield(.write(device.id))
        }
    }
    func completeWrite() {
        let waiting = writeContinuation
        let updated = pendingWrite
        writeContinuation = nil
        pendingWrite = nil
        if let updated { waiting?.resume(returning: updated) }
    }
    func failWrite() {
        let waiting = writeContinuation
        writeContinuation = nil
        pendingWrite = nil
        waiting?.resume(throwing: Failure.unavailable)
    }
    func quitRenderer(keepingDevicesRunning: Bool?) { continuation.yield(.quit) }
    func selectHost(_ host: SimulatorHost, xcodeURL: URL?) throws { throw Failure.unavailable }
    func openDevice(_ deviceID: DeviceInventoryID, xcodeURL: URL?) async throws {
        try await withCheckedThrowingContinuation { waiting in
            openContinuation = waiting
            continuation.yield(.open(deviceID))
        }
    }
    func completeOpen() { openContinuation?.resume(); openContinuation = nil }
    func failOpen() { openContinuation?.resume(throwing: Failure.unavailable); openContinuation = nil }
    func closeDevice(_ deviceID: DeviceInventoryID, keepingDeviceRunning: Bool) { continuation.yield(.close(deviceID)) }
    func creationCatalog() throws -> SimulatorCreationContext { throw Failure.unavailable }
    func createSimulator(named name: String, deviceType: String, runtime: String, context: SimulatorCreationContext) throws -> String { throw Failure.unavailable }
    func pairSimulators(watch: String, phone: String, context: SimulatorCreationContext) throws { throw Failure.unavailable }
    func holdManagement() { holdsManagement = true }
    func completeManagement() { managementContinuation?.resume(); managementContinuation = nil; holdsManagement = false }
    func manage(_ action: DeviceManagementAction, devices: [InventoryDevice]) async -> DeviceManagementReport {
        if holdsManagement {
            await withCheckedContinuation { waiting in
                managementContinuation = waiting
                continuation.yield(.management)
            }
        }
        return DeviceManagementReport(results: [])
    }
    func inspector(for device: InventoryDevice) throws -> DeviceInspector { throw Failure.unavailable }
    func restore(force: Bool) throws { throw Failure.unavailable }
    func synchronizeXcodeConnections() -> Bool { false }
    func testingDeviceVisibilityDidChange() {}
}

@MainActor
private final class ManagerPostureConnections {
    enum Event: Equatable { case observing(DeviceInventoryID), stopped(DeviceInventoryID) }
    let events = AsyncStream<Event>.makeStream()
    private(set) var identifiers: [DeviceInventoryID] = []
    private var current: ManagerPostureTransport?
    func failCurrentObservation() { current?.fail() }
    func model(_ identifier: DeviceInventoryID) -> DevicePostureModel {
        DevicePostureModel(deviceID: identifier) { [self] id in
            identifiers.append(id)
            let transport = ManagerPostureTransport(identifier: id, events: events.continuation)
            current = transport
            return transport
        }
    }
}

@MainActor
private final class ManagerPostureTransport: DevicePostureTransport {
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
