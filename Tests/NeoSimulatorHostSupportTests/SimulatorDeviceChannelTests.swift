import Dispatch
import Foundation
import NeoSimulatorDeviceIO
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(1)))
struct SimulatorDeviceChannelTests {
    private func makeChannel(_ identifier: String = "device") -> SimulatorDeviceChannel {
        SimulatorDeviceChannel(scope: .device(DeviceAddress(identifier: identifier, deviceSetPath: nil)))
    }

    @Test func aCallThatOutlivesItsDeadlineLeavesItsOutcomeUnknownAndTheQueuedRequestsUnsent() async throws {
        let channel = makeChannel()
        let call = HeldCall()
        defer { call.release() }
        let sent = Mutex(0)
        let held = Task {
            try await channel.change("hold", limit: .milliseconds(50)) { call.hold() }
        }
        await call.waitUntilHeld()
        let queued = Task {
            try await channel.change("queued") { sent.withLock { $0 += 1 } }
        }
        await #expect(throws: DeviceOperationFailure.outcomeUnknown(operation: "hold", cause: .timedOut(.milliseconds(50)))) {
            try await held.value
        }
        await #expect(throws: DeviceOperationFailure.notSent(operation: "queued", heldBy: "hold")) { try await queued.value }
        call.release()
        try await wait(for: channel, toBe: .ready)
        #expect(sent.withLock { $0 } == 0)
    }

    @Test func requestsWhileUnresponsiveStartNothingQueueNothingAndAreNotReplayedOnRecovery() async throws {
        let channel = makeChannel()
        let call = HeldCall()
        defer { call.release() }
        let started = Mutex(0)
        await #expect(throws: DeviceOperationFailure.noAnswer(operation: "hold", limit: .milliseconds(20))) {
            try await channel.read("hold", limit: .milliseconds(20)) {
                started.withLock { $0 += 1 }
                call.hold()
            }
        }
        guard case .unresponsive(let held, _) = await channel.currentHealth else {
            Issue.record("The channel stayed ready behind a held call.")
            return
        }
        #expect(held == "hold")
        for _ in 0..<100 {
            await #expect(throws: DeviceOperationFailure.notSent(operation: "write", heldBy: "hold")) {
                try await channel.change("write") { started.withLock { $0 += 1 } }
            }
        }
        #expect(started.withLock { $0 } == 1)
        #expect(await channel.unresolvedOperations().map(\.operation) == ["hold"])
        call.release()
        try await wait(for: channel, toBe: .ready)
        #expect(await channel.unresolvedOperations().isEmpty)
        #expect(started.withLock { $0 } == 1)
        // Recovery only makes new requests possible.
        try await channel.change("write") { started.withLock { $0 += 1 } }
        #expect(started.withLock { $0 } == 2)
    }

    @Test func aLateResultGetsItsCleanupAndOnlyTheHeldCallsReturnRecovers() async throws {
        let channel = makeChannel()
        let call = HeldCall()
        defer { call.release() }
        let cleaned = Mutex<[Result<String, DeviceCleanupFixture>]>([])
        await #expect(throws: DeviceOperationFailure.noAnswer(operation: "connect", limit: .milliseconds(20))) {
            _ = try await channel.read("connect", limit: .milliseconds(20), lateCompletion: { result in
                cleaned.withLock { $0.append(result.mapError { _ in DeviceCleanupFixture() }) }
            }) {
                call.hold()
                return "resource"
            }
        }
        // Waiting longer does not end it, and nothing owns the result yet.
        try await Task.sleep(for: .milliseconds(100))
        if case .ready = await channel.currentHealth { Issue.record("The deadline alone recovered the channel.") }
        #expect(cleaned.withLock { $0.isEmpty })
        call.release()
        try await wait(for: channel, toBe: .ready)
        for _ in 0..<100 where cleaned.withLock({ $0.isEmpty }) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(cleaned.withLock { $0 } == [.success("resource")])
    }

    @Test func aRequestReleasesWhatItCapturedOnceItsCallHasReturned() async throws {
        let channel = makeChannel()
        // A deadline this far away cannot be what releases anything.
        let limit = Duration.seconds(3600)
        weak var answered: CapturedResource?
        do {
            let resource = CapturedResource()
            answered = resource
            try await channel.read("read", limit: limit) { withExtendedLifetime(resource) {} }
        }
        weak var late: CapturedResource?
        let call = HeldCall()
        defer { call.release() }
        do {
            let resource = CapturedResource()
            late = resource
            let stopped = Task {
                try await channel.read("connect", limit: limit, lateCompletion: { _ in withExtendedLifetime(resource) {} }) {
                    withExtendedLifetime(resource) { call.hold() }
                }
            }
            await call.waitUntilHeld()
            stopped.cancel()
            await #expect(throws: CancellationError.self) { try await stopped.value }
            #expect(late != nil)
            call.release()
        }
        weak var cleanedUp: CapturedResource?
        do {
            let resource = CapturedResource()
            cleanedUp = resource
            channel.cleanUp("release") { withExtendedLifetime(resource) {} }
        }
        for _ in 0..<500 where answered != nil || late != nil || cleanedUp != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(answered == nil)
        #expect(late == nil)
        #expect(cleanedUp == nil)
    }

    @Test func aCleanupIsNotRefusedAndRunsWhenTheHeldCallReturns() async throws {
        let channel = makeChannel()
        let call = HeldCall()
        defer { call.release() }
        await #expect(throws: DeviceOperationFailure.self) {
            try await channel.change("hold", limit: .milliseconds(20)) { call.hold() }
        }
        let released = Mutex(false)
        channel.cleanUp("release") { released.withLock { $0 = true } }
        #expect(await channel.unresolvedOperations().map(\.state) == [.running, .cleanup])
        #expect(!released.withLock { $0 })
        call.release()
        for _ in 0..<100 where !released.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(released.withLock { $0 })
    }

    @Test func cancellingAQueuedRequestSendsNothingAndCancellingARunningOneSaysWhatItLeaves() async throws {
        let channel = makeChannel()
        let call = HeldCall()
        defer { call.release() }
        let sent = Mutex(0)
        let change = Task { try await channel.change("change") { call.hold() } }
        await call.waitUntilHeld()
        let queued = Task { try await channel.change("queued") { sent.withLock { $0 += 1 } } }
        let read = Task { try await channel.read("read") { sent.withLock { $0 += 1 } } }
        try await waitUntilUnresolved(channel, count: 3)
        queued.cancel()
        read.cancel()
        await #expect(throws: CancellationError.self) { try await queued.value }
        await #expect(throws: CancellationError.self) { try await read.value }
        change.cancel()
        await #expect(throws: DeviceOperationFailure.outcomeUnknown(operation: "change", cause: .cancelled)) { try await change.value }
        // Stopping the wait stopped nothing: the call still holds the worker.
        #expect(await channel.unresolvedOperations().map(\.operation) == ["change"])
        call.release()
        for _ in 0..<100 where await !channel.unresolvedOperations().isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(sent.withLock { $0 } == 0)
    }

    @Test func aHeldCallLeavesOtherDevicesTheMainActorAndItsChannelAnswering() async throws {
        let channel = makeChannel()
        let other = makeChannel("other")
        let call = HeldCall()
        defer { call.release() }
        let held = Task { try await channel.change("hold") { call.hold() } }
        await call.waitUntilHeld()
        #expect(try await other.read("read") { "answered" } == "answered")
        #expect(await Task { @MainActor in true }.value)
        #expect(await channel.currentHealth == .ready)
        #expect(await channel.unresolvedOperations().map(\.state) == [.running])
        call.release()
        try await held.value
    }

    /// Requests made in order run in that order, each with everything it needs in one step, however their callers interleave.
    @Test func compoundRequestsKeepTheirCallersOrderWithoutInterleaving() async throws {
        let channel = makeChannel()
        let state = Mutex<(value: Int, order: [Int])>((0, []))
        await withThrowingTaskGroup(of: Void.self) { group in
            for caller in 0..<4 {
                group.addTask {
                    for step in 0..<25 {
                        try await channel.change("toggle") {
                            let read = state.withLock { $0.value }
                            usleep(100)
                            state.withLock {
                                $0.value = read + 1
                                $0.order.append(caller * 100 + step)
                            }
                        }
                    }
                }
            }
        }
        let (value, order) = state.withLock { $0 }
        #expect(value == 100)
        for caller in 0..<4 {
            let steps = order.filter { $0 / 100 == caller }
            #expect(steps == steps.sorted())
        }
    }

    @Test func everyPathToADeviceFindsTheSameChannel() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let link = directory.appendingPathExtension("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
        defer { try? FileManager.default.removeItem(at: link) }
        let hub = DeviceIOHub()
        let channel = hub.channel(for: .device(DeviceAddress(identifier: "abc", deviceSetPath: directory.path)))
        #expect(hub.channel(for: .device(DeviceAddress(identifier: "ABC", deviceSetPath: link.path + "/"))) === channel)
        #expect(hub.channel(for: .device(DeviceAddress(identifier: "ABC", deviceSetPath: nil))) !== channel)
        #expect(hub.channel(for: .device(DeviceAddress(identifier: "OTHER", deviceSetPath: directory.path))) !== channel)
    }

    @Test func everyPathToADeviceSetFindsTheSameChannelWithinItsDeveloperDirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let link = directory.appendingPathExtension("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
        defer { try? FileManager.default.removeItem(at: link) }
        func set(_ developerDirectory: String, _ path: String?) -> DeviceChannelScope {
            .deviceSet(DeviceSetAddress(developerDirectory: developerDirectory, path: path))
        }
        let hub = DeviceIOHub()
        let channel = hub.channel(for: set("/Xcode/Developer", directory.path))
        #expect(hub.channel(for: set("/Xcode/Developer/", link.path + "/")) === channel)
        #expect(hub.channel(for: set("/Other/Developer", directory.path)) !== channel)
        #expect(hub.channel(for: set("/Xcode/Developer", nil)) !== channel)
    }

    @Test func waitingForATaskCanBeGivenUp() async throws {
        let held = HeldCall()
        defer { held.release() }
        let task = Task.detached { held.hold() }
        await held.waitUntilHeld()
        #expect(await !task.ends(before: .now + .milliseconds(20)))
        held.release()
        #expect(await task.ends(before: .now + .seconds(30)))
    }

    @Test func quittingStopsARunningUninterruptedChildAndBoundsThoseThatStartLater() async throws {
        let commands = UninterruptedCommands()
        let runner = SystemCommandRunner(uninterrupted: commands)
        let sleep = SystemCommand(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["300"], policy: .uninterrupted)
        let stalled = Task { try await runner.run(sleep) }
        try await Task.sleep(for: .milliseconds(100))
        // A cancelled caller keeps waiting, so only the quit stops it.
        stalled.cancel()
        commands.stopForTermination()
        do {
            _ = try await stalled.value
            Issue.record("The stalled child ran to its end.")
        } catch let failure as CommandFailure {
            #expect(failure.interruption == .terminating)
            #expect(!failure.isCancellation)
        }
        // A rollback still runs after that.
        let rollback = try await runner.run(SystemCommand(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["rolled back"], policy: .uninterrupted))
        #expect(rollback.stdoutText == "rolled back")
        commands.resumeAfterCancelledQuit()
    }

    private func wait(for channel: SimulatorDeviceChannel, toBe health: DeviceChannelHealth) async throws {
        for await current in channel.healthChanges() where current == health { return }
    }

    private func waitUntilUnresolved(_ channel: SimulatorDeviceChannel, count: Int) async throws {
        for _ in 0..<500 where await channel.unresolvedOperations().count < count { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await channel.unresolvedOperations().count == count)
    }
}

private struct DeviceCleanupFixture: Error, Equatable {}

private final class CapturedResource: Sendable {}

/// Blocks the thread that calls ``hold()`` until ``release()``, as a native call blocks its worker.
private final class HeldCall: Sendable {
    private let released = DispatchSemaphore(value: 0)
    private let started = Mutex<(isHeld: Bool, isReleased: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, false, []))

    func hold() {
        let waiters = started.withLock { state in
            state.isHeld = true
            defer { state.waiters = [] }
            return state.waiters
        }
        waiters.forEach { $0.resume() }
        released.wait()
        released.signal()
    }

    func waitUntilHeld() async {
        await withCheckedContinuation { continuation in
            let isHeld = started.withLock { state in
                if !state.isHeld { state.waiters.append(continuation) }
                return state.isHeld
            }
            if isHeld { continuation.resume() }
        }
    }

    func release() {
        let first = started.withLock { state in
            defer { state.isReleased = true }
            return !state.isReleased
        }
        if first { released.signal() }
    }
}
