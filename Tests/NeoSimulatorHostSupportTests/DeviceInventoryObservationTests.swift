import Foundation
@testable import NeoSimulatorDeviceIO
@testable import NeoSimulatorHostSupport
@testable import NeoSimulatorKit
@testable import NeoSimulatorPresentationAdapters
import Observation
import Testing

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
        #expect(changes == 3)
        await observation.stop()
        #expect(source.finished)
        source.events.yield(true)
        #expect(changes == 3)
        await observation.stop()
    }

    @Test func streamFailureReachesTheCallerWithoutReplacingTheError() async throws {
        let source = TestInventoryChanges()
        let observation = DeviceInventoryObservation(source: source)
        let failure = InventoryStreamFailure.disconnected("service interrupted")
        var ready = false
        observation.onReady = { ready = true }
        try await observation.start()
        #expect(ready)
        let received: any Error = await withCheckedContinuation { continuation in
            observation.onError = { continuation.resume(returning: $0) }
            source.events.finish(throwing: failure)
        }
        #expect(received as? InventoryStreamFailure == failure)
        await observation.stop()
        #expect(source.finished)
    }

    @Test(.timeLimit(.minutes(1))) func subscribingRefreshesTheInventoryAfterTheObservationGap() async throws {
        let source = TestInventoryChanges()
        let (began, signal) = AsyncStream<Void>.makeStream()
        let (released, release) = AsyncStream<Void>.makeStream()
        source.beforeSubscribe = {
            signal.yield(())
            for await _ in released {}
        }
        let observation = DeviceInventoryObservation(source: source)
        var changes = 0
        observation.onChange = { changes += 1 }
        let starting = Task { try await observation.start() }
        var waiting = began.makeAsyncIterator()
        await waiting.next()
        #expect(changes == 0)
        release.finish()
        try await starting.value
        #expect(changes == 1)
        await observation.stop()
    }
}

@MainActor
@Suite struct DeviceInventoryObservationDelayTests {
    @Test(.timeLimit(.minutes(1)))
    func aServiceThatOutlivesItsLimitStillGetsObservedWhenItFinishes() async throws {
        let source = TestInventoryChanges()
        let delay = DeviceOperationFailure.noAnswer(operation: "finish CoreDevice's initialization", limit: .seconds(60))
        source.initializations = [delay, delay]
        let observation = DeviceInventoryObservation(source: source)
        var errors: [DeviceOperationFailure] = []
        var changes = 0
        observation.onError = { errors.append($0 as! DeviceOperationFailure) }
        observation.onChange = { changes += 1 }
        try await observation.start()
        #expect(errors == [delay, delay])
        #expect(source.initializations.isEmpty)
        #expect(changes == 1)
        await observation.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func aFailedInitializationIsNotAskedAgain() async throws {
        let source = TestInventoryChanges()
        let refused = DeviceOperationFailure.notSent(operation: "a", heldBy: "b")
        source.initializations = [refused, refused]
        let observation = DeviceInventoryObservation(source: source)
        await #expect(throws: refused) { try await observation.start() }
        #expect(source.initializations.count == 1)
        await observation.stop()
    }
}

@MainActor
@Suite struct DeviceActiveStateObservationTests {
    @Test func valuesFollowCoreDeviceIdentityAndStopEndsTheirUpdates() async throws {
        // A simulator's CoreDevice identifier can equal its UDID, which a custom-set clone also has.
        let phoneID = UUID(), simulatorID = UUID(), udid = simulatorID.uuidString
        let payload = try JSONSerialization.data(withJSONObject: ["result": ["devices": [
            ["identifier": phoneID.uuidString, "properties": ["hardware": ["fidelity": "physical"]]],
            ["identifier": udid, "properties": ["hardware": ["fidelity": "simulated", "udid": udid]]],
        ]]])
        let simulators = [nil, "/testing"].map { path in
            InventoryDevice.simulator(SimulatorHostDevice(identifier: udid, name: "Phone", descriptiveName: "Phone",
                runtimeIdentifier: "runtime", runtimeName: "iOS", productFamily: "iPhone", state: "Booted", deviceSetPath: path))
        }
        let snapshot = try await DeviceInventoryReader(readSimulators: {
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

    @Test func limitedValuesFollowTheRequestedDevicesAndStopEndsTheirUpdates() async throws {
        let canvasID = UUID(), otherID = UUID()
        let source = TestActiveStateSource(values: [canvasID: true, otherID: true])
        source.requested = [canvasID]
        let observation = DeviceActiveStateObservation(source: source, limitedTo: { source.requested })
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
        // DeviceKit has a value for the other device, but it was not requested.
        #expect(reports.last == DeviceActiveStates([canvasID: true]))
        await withCheckedContinuation { continuation in
            reported = continuation
            source.requested.insert(otherID)
        }
        #expect(reports.last == DeviceActiveStates([canvasID: true, otherID: true]))
        await withCheckedContinuation { continuation in
            reported = continuation
            source.values[canvasID] = false
        }
        #expect(reports.last == DeviceActiveStates([canvasID: false, otherID: true]))
        await observation.stop()
        source.requested = [canvasID]
        await Task { @MainActor in }.value
        #expect(reports.count == 3)
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
    /// The devices that a limited observation requests, standing in for the app's screens.
    var requested: Set<UUID> = []
    @ObservationIgnored private let preparationError: (any Error)?

    init(values: [UUID: Bool] = [:], preparationError: (any Error)? = nil) {
        self.values = values
        self.preparationError = preparationError
    }

    func prepare() async throws {
        if let preparationError { throw preparationError }
    }

    func read(_ identifiers: Set<UUID>?) throws -> [UUID: Bool] {
        guard let identifiers else { return values }
        return values.filter { identifiers.contains($0.key) }
    }
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

    /// What each call to `initialize()` throws, until there are no more.
    var initializations: [any Error] = []
    var beforeSubscribe: (() async -> Void)?

    init() { (stream, events) = AsyncThrowingStream.makeStream() }
    func initialize() async throws {
        if !initializations.isEmpty { throw initializations.removeFirst() }
    }

    func follow(onReady: @escaping @MainActor () -> Void, onChange: @escaping @MainActor () -> Void) async throws {
        defer { finished = true }
        await beforeSubscribe?()
        try Task.checkCancellation()
        onReady()
        for try await _ in stream { onChange() }
    }
}
