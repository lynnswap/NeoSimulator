import Dispatch
import Foundation
import NeoSimulatorDeviceIO
import NeoSimulatorKit
import Synchronization
import Testing

/// A device set's reads, as raw calls on the set's worker that stay blocked until they are released.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DeviceSetLaneTests {
    /// One value per read, each of which can be held.
    private final class Reads: Sendable {
        private let state = Mutex<(count: Int, gates: [Int: Gate])>((0, [:]))
        var count: Int { state.withLock { $0.count } }

        func hold(read number: Int) -> Gate {
            let gate = Gate()
            state.withLock { $0.gates[number] = gate }
            return gate
        }

        func read() -> Int {
            let (number, gate) = state.withLock { state in
                state.count += 1
                return (state.count, state.gates[state.count])
            }
            gate?.pass()
            return number
        }
    }

    private func setChannel(_ hub: DeviceIOHub = DeviceIOHub()) -> SimulatorDeviceChannel {
        hub.channel(for: .deviceSet(DeviceSetAddress(developerDirectory: "/Xcode/Developer", path: nil)))
    }

    private func makeRead(_ reads: Reads, channel: SimulatorDeviceChannel? = nil,
                          limit: Duration = .seconds(30)) -> CoalescedChannelRead<Int> {
        CoalescedChannelRead(channel: channel ?? setChannel(), operation: "read the device set", limit: limit) { reads.read() }
    }

    private func waitForHealth(of channel: SimulatorDeviceChannel, _ health: @Sendable (DeviceChannelHealth) -> Bool) async {
        for await current in channel.healthChanges() where health(current) { return }
    }

    @Test func aHeldFirstOpenBlocksOnlyItsRawWorker() async throws {
        let hub = DeviceIOHub()
        let channel = setChannel(hub)
        let gate = Gate()
        defer { gate.release() }
        let wasSwiftJob = Mutex<Bool?>(nil)
        let read = CoalescedChannelRead(channel: channel, operation: "open the device set", limit: .seconds(30)) { () -> Int in
            wasSwiftJob.withLock { $0 = Thread.isMainThread || withUnsafeCurrentTask { $0 != nil } }
            gate.pass()
            return 1
        }
        let open = Task { try await read.refresh() }
        await gate.waitUntilEntered()

        // This test runs on the main actor, which keeps running. So do the channel's state and a device's own channel.
        #expect(read.latest == nil)
        #expect(await channel.unresolvedOperations().map(\.state) == [.running])
        let device = hub.channel(for: .device(DeviceAddress(identifier: "device", deviceSetPath: nil)))
        #expect(try await device.read("read another device") { 7 } == 7)
        #expect(wasSwiftJob.withLock { $0 } == false)

        gate.release()
        #expect(try await open.value == 1)
        #expect(read.latest == 1)
        #expect(await channel.unresolvedOperations().isEmpty)
    }

    @Test func rescansShareOneRunningReadAndOneMore() async throws {
        let reads = Reads()
        let first = reads.hold(read: 1)
        defer { first.release() }
        let read = makeRead(reads)
        var published: [Int] = []
        read.onRead = { published.append($0) }
        let earliest = Task.immediate { try await read.refresh() }
        await first.waitUntilEntered()
        let later = (0..<20).map { _ in Task.immediate { try await read.refresh() } }
        // Their requests are in, and none reached the worker.
        #expect(reads.count == 1)
        first.release()

        // The read that was running when they asked began too early to answer them.
        #expect(try await earliest.value == 1)
        for task in later { #expect(try await task.value == 2) }
        #expect(reads.count == 2)
        #expect(published == [1, 2])
        #expect(read.latest == 2)
    }

    @Test func aHeldRescanKeepsTheLastSnapshotAndGrowsNoQueue() async throws {
        let channel = setChannel()
        let reads = Reads()
        let held = reads.hold(read: 2)
        defer { held.release() }
        let read = makeRead(reads, channel: channel, limit: .milliseconds(50))
        #expect(try await read.refresh() == 1)

        await #expect(throws: DeviceOperationFailure.noAnswer(operation: "read the device set", limit: .milliseconds(50))) {
            try await read.refresh()
        }
        for _ in 0..<20 {
            await #expect(throws: DeviceOperationFailure.notSent(operation: "read the device set", heldBy: "read the device set")) {
                try await read.refresh()
            }
        }
        #expect(read.latest == 1)
        #expect(reads.count == 2)
        #expect(await channel.unresolvedOperations().count == 1)
        if case .unresponsive = await channel.currentHealth {} else { Issue.record("A held read left the channel ready.") }

        // Only the call's own return makes the channel ready, and its value arrives too late to answer anyone.
        held.release()
        await waitForHealth(of: channel) { $0 == .ready }
        #expect(read.latest == 1)
        #expect(try await read.refresh() == 3)
        #expect(read.latest == 3)
    }

    @Test func aCallerThatStopsWaitingLeavesTheReadRunning() async throws {
        let reads = Reads()
        let gate = reads.hold(read: 1)
        defer { gate.release() }
        let read = makeRead(reads)
        var published: [Int] = []
        read.onRead = { published.append($0) }

        await #expect(throws: DeviceOperationFailure.noAnswer(operation: "read the device set", limit: .milliseconds(20))) {
            try await read.refresh(waitingAtMost: .milliseconds(20))
        }
        let cancelled = Task.immediate { try await read.refresh() }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(published.isEmpty)
        #expect(reads.count == 1)

        let waiting = Task.immediate { try await read.refresh() }
        gate.release()
        #expect(try await waiting.value == 2)
        #expect(published == [1, 2])
    }

    /// A registration's retry goes out as soon as the channel reports that its call returned, and has to find the late
    /// registration already removed.
    @Test func aRetryWhenTheChannelAnswersAgainFollowsTheLateRegistrationsRemoval() async throws {
        let channel = setChannel()
        let handlers = Mutex<(next: Int, active: Set<Int>, most: Int)>((0, [], 0))
        @Sendable func register() -> Int {
            handlers.withLock { handlers in
                handlers.next += 1
                handlers.active.insert(handlers.next)
                handlers.most = max(handlers.most, handlers.active.count)
                return handlers.next
            }
        }
        let gate = Gate()
        defer { gate.release() }
        await #expect(throws: DeviceOperationFailure.noAnswer(operation: "observe the device set", limit: .milliseconds(20))) {
            try await channel.read("observe the device set", limit: .milliseconds(20), lateCompletion: { (result: Result<Int, any Error>) in
                if case .success(let token) = result { _ = handlers.withLock { $0.active.remove(token) } }
            }) {
                gate.pass()
                return register()
            }
        }
        gate.release()
        await waitForHealth(of: channel) { $0 == .ready }

        let retry = try await channel.read("observe the device set", limit: .seconds(30)) { register() }
        #expect(retry == 2)
        #expect(handlers.withLock { $0.active } == [2])
        #expect(handlers.withLock { $0.most } == 1)
    }

    // MARK: CoreDevice's initialization

    @Test func aPendingInitializationBoundsItsCallersAndIsNeverReplaced() async throws {
        let gate = Gate()
        defer { gate.release() }
        var started = 0
        var delays: [Bool] = []
        let (delayChanges, delayChanged) = AsyncStream.makeStream(of: Void.self)
        CoreDeviceRuntime.onInitializationDelayChanged = {
            delays.append($0)
            if $0 { delayChanged.finish() }
        }
        defer { CoreDeviceRuntime.onInitializationDelayChanged = nil }
        let (delay, passDelay) = AsyncStream.makeStream(of: Void.self)
        let initialization = CoreDeviceRuntime.makeInitialization(waitUntilDelayed: { for await _ in delay { return } }) {
            started += 1
            // A native call that keeps a thread until it returns.
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    gate.pass()
                    continuation.resume()
                }
            }
        }

        let limit = Duration.milliseconds(20)
        let timedOut = DeviceOperationFailure.noAnswer(operation: "finish CoreDevice's initialization", limit: limit)
        await #expect(throws: timedOut) { try await initialization.value(limit: limit) }
        await gate.waitUntilEntered()
        passDelay.yield()
        for await _ in delayChanges {}
        await #expect(throws: timedOut) { try await initialization.value(limit: limit) }
        let cancelled = Task.immediate { try await initialization.value() }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(started == 1)
        #expect(delays == [true])

        // Who waits when it finishes gets the same run's answer, and so does who asks afterwards.
        let waiting = Task.immediate { try await initialization.value() }
        gate.release()
        try await waiting.value
        try await initialization.value(limit: limit)
        #expect(started == 1)
        #expect(delays == [true, false])
    }

    // MARK: Failing to open a screen

    @Test func aHeldLookupIsNamedWhenNoScreenAppears() async throws {
        let hub = DeviceIOHub()
        let held = hub.channel(for: .device(DeviceAddress(identifier: "HELD", deviceSetPath: nil)))
        let gate = Gate()
        defer { gate.release() }
        let lookup = Task { try await held.read("look up the device's IndigoHID service", limit: .seconds(30)) { gate.pass() } }
        await gate.waitUntilEntered()

        let failure = await IntegratedScreenUnavailable(
            deviceName: "Phone B", lastFailure: SimulatorError.operation("The screen adapter failed."), hub: hub)
        let message = try #require(failure.errorDescription)
        #expect(message.contains("No integrated screen became available for Phone B."))
        #expect(message.contains("The screen adapter failed."))
        #expect(message.contains("HELD: the request to look up the device's IndigoHID service has not returned."))

        gate.release()
        try await lookup.value
        let afterwards = await IntegratedScreenUnavailable(deviceName: "Phone B", lastFailure: nil, hub: hub)
        #expect(afterwards.errorDescription == "No integrated screen became available for Phone B.")
    }
}

/// Blocks the thread that passes it until ``release()``, as a native call blocks its worker.
private final class Gate: Sendable {
    private let released = DispatchSemaphore(value: 0)
    private let state = Mutex<(entered: Bool, isReleased: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, false, []))

    func pass() {
        let waiters = state.withLock { state in
            state.entered = true
            defer { state.waiters = [] }
            return state.waiters
        }
        waiters.forEach { $0.resume() }
        released.wait()
        released.signal()
    }

    func waitUntilEntered() async {
        await withCheckedContinuation { continuation in
            let entered = state.withLock { state in
                if !state.entered { state.waiters.append(continuation) }
                return state.entered
            }
            if entered { continuation.resume() }
        }
    }

    func release() {
        let first = state.withLock { state in
            defer { state.isReleased = true }
            return !state.isReleased
        }
        if first { released.signal() }
    }
}
