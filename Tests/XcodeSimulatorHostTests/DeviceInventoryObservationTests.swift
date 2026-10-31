import Foundation
import Observation
import Testing
@testable import XcodeSimulatorHost

@MainActor
@Suite struct DeviceInventoryObservationTests {
    @Test func connectionChangesReloadTheInventoryAndStopDrainsObservation() async throws {
        let source = TestInventoryChanges()
        let observation = DeviceInventoryObservation(source: source)
        var changes = 0
        var changed: CheckedContinuation<Void, Never>?
        observation.onChange = {
            changes += 1
            changed?.resume()
            changed = nil
        }
        try await observation.start()
        for event in [true, false] {
            await withCheckedContinuation { continuation in
                changed = continuation
                source.events.yield(event)
            }
        }
        #expect(changes == 2)
        await observation.stop()
        #expect(source.finished)
        source.events.yield(true)
        #expect(changes == 2)
        await observation.stop()
    }

    @Test func streamFailureReachesTheCallerWithoutReplacingTheError() async throws {
        let source = TestInventoryChanges()
        let observation = DeviceInventoryObservation(source: source)
        let failure = InventoryStreamFailure.disconnected("service interrupted")
        try await observation.start()
        let received: any Error = await withCheckedContinuation { continuation in
            observation.onError = { continuation.resume(returning: $0) }
            source.events.finish(throwing: failure)
        }
        #expect(received as? InventoryStreamFailure == failure)
        await observation.stop()
        #expect(source.finished)
    }
}

@MainActor
@Suite struct DeviceActiveStateObservationTests {
    @Test func valuesFollowCoreDeviceIdentityAndStopEndsTheirUpdates() async throws {
        // A simulator's CoreDevice identifier can equal its UDID, which a custom-set clone also has.
        let phoneID = UUID(), simulatorID = UUID(), udid = simulatorID.uuidString
        let payload = try JSONSerialization.data(withJSONObject: ["result": ["devices": [
            ["identifier": phoneID.uuidString, "properties": ["hardware": ["reality": "physical"]]],
            ["identifier": udid, "properties": ["hardware": ["reality": "simulated", "udid": udid]]],
        ]]])
        let simulators = [nil, "/testing"].map { path in
            InventoryDevice.simulator(SimulatorHostDevice(identifier: udid, name: "Phone", descriptiveName: "Phone",
                runtimeIdentifier: "runtime", runtimeName: "iOS", productFamily: "iPhone", state: "Booted", deviceSetPath: path))
        }
        let snapshot = await DeviceInventoryReader(readSimulators: {
            DeviceInventorySnapshot(devices: simulators, issues: [])
        }, readCoreDevices: { payload }).read()
        let phone = try #require(snapshot.devices.first { $0.id == .coreDevice(phoneID.uuidString) })
        let joined = try #require(snapshot.devices.first { $0.id == .simulator(udid: udid, deviceSetPath: nil) })
        let clone = try #require(snapshot.devices.first { $0.id == .simulator(udid: udid, deviceSetPath: "/testing") })
        let source = TestActiveStateSource(values: [simulatorID: true])
        let observation = DeviceActiveStateObservation(source: source)
        var reports: [DeviceActiveStates] = []
        var reported: CheckedContinuation<Void, Never>?
        observation.onChange = {
            reports.append($0)
            reported?.resume()
            reported = nil
        }
        await withCheckedContinuation { continuation in
            reported = continuation
            observation.start()
        }
        // The clone has no CoreDevice record, so it has no value; neither has an unreported device.
        #expect(reports.last?.isActive(joined) == true)
        #expect(reports.last?.isActive(clone) == nil)
        #expect(reports.last?.isActive(phone) == nil)
        await withCheckedContinuation { continuation in
            reported = continuation
            source.values[phoneID] = false
        }
        #expect(reports.last?.isActive(phone) == false)
        await observation.stop()
        source.values[phoneID] = true
        // A change before stop schedules its reread on MainActor ahead of this task.
        await Task { @MainActor in }.value
        #expect(reports.count == 2)
    }

    /// Resolution reads no DeviceKit singleton, so no device observation or coordinator starts.
    @Test func deviceKitBindingsResolveWithoutReadingItsDevices() async throws {
        try await CoreDeviceDisplayGeometry.loadRuntime()
        _ = try await DeviceKitActiveStateSource.Bindings(runtime: .shared)
    }

    @Test func preparationFailureReachesTheCallerWithoutValues() async {
        let failure = ActiveStatePreparationFailure(declaration: "SidebarModel.shouldRenderAsActive(_:)")
        let observation = DeviceActiveStateObservation(source: TestActiveStateSource(preparationError: failure))
        var reports = 0
        observation.onChange = { _ in reports += 1 }
        let received: any Error = await withCheckedContinuation { continuation in
            observation.onError = { continuation.resume(returning: $0) }
            observation.start()
        }
        #expect(received as? ActiveStatePreparationFailure == failure)
        #expect(reports == 0)
        await observation.stop()
    }
}

@MainActor @Observable
private final class TestActiveStateSource: DeviceActiveStateSource {
    var values: [UUID: Bool]
    @ObservationIgnored private let preparationError: (any Error)?

    init(values: [UUID: Bool] = [:], preparationError: (any Error)? = nil) {
        self.values = values
        self.preparationError = preparationError
    }

    func prepare() async throws {
        if let preparationError { throw preparationError }
    }

    func read() throws -> [UUID: Bool] { values }
}

private struct ActiveStatePreparationFailure: Error, Equatable {
    let declaration: String
}

private enum InventoryStreamFailure: Error, Equatable {
    case disconnected(String)
}

@MainActor
private final class TestInventoryChanges: DeviceInventoryChangeSource {
    private let stream: AsyncThrowingStream<Bool, any Error>
    let events: AsyncThrowingStream<Bool, any Error>.Continuation
    private(set) var finished = false

    init() { (stream, events) = AsyncThrowingStream.makeStream() }
    func initialize() async throws {}

    func follow(onChange: @escaping @MainActor () -> Void) async throws {
        defer { finished = true }
        for try await _ in stream { onChange() }
    }
}
