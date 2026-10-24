import Foundation
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
