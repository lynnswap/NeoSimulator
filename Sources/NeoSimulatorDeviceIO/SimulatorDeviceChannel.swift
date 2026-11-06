import Dispatch
import Foundation
import os
import Synchronization

/// A simulator's whole identity: its UDID within the device set that holds it. Every path to the same device
/// resolves to the same address, and so to the same channel.
package struct DeviceAddress: Hashable, Sendable {
    package let identifier: String
    /// Nil denotes the default device set.
    package let deviceSetPath: String?

    package init(identifier: String, deviceSetPath: String?) {
        self.identifier = identifier.uppercased()
        self.deviceSetPath = deviceSetPath.map(Self.normalized(setPath:))
    }

    package static func normalized(setPath path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}

/// How a request ended without the device's own answer. A native call cannot be cancelled, so none of these say
/// that it stopped: the channel only stopped waiting for it.
package enum DeviceOperationFailure: LocalizedError, Equatable {
    package enum Abandonment: Equatable, Sendable {
        case cancelled
        case timedOut(Duration)
    }

    /// The request was refused because an earlier call has not returned. Nothing was sent.
    case notSent(operation: String, heldBy: String)
    /// A change reached the device and its caller stopped waiting before the native call returned, so what it
    /// changed is unknown. It is not sent again.
    case outcomeUnknown(operation: String, cause: Abandonment)
    /// A read did not answer in time. A read changes nothing, so only its value is missing.
    case noAnswer(operation: String, limit: Duration)

    /// Whether the caller's cancellation ended it, rather than the device's silence.
    package var wasCancelled: Bool { self == .outcomeUnknown(operation: operation, cause: .cancelled) }

    /// What was requested.
    package var operation: String {
        switch self {
        case .notSent(let operation, _), .outcomeUnknown(let operation, _), .noAnswer(let operation, _): operation
        }
    }

    package var errorDescription: String? {
        switch self {
        case .notSent(let operation, let call):
            "Could not \(operation): the device has not answered an earlier request to \(call), so this one was not sent."
        case .outcomeUnknown(let operation, .cancelled):
            "The request to \(operation) was stopped while the device was handling it, so what it changed is unknown."
        case .outcomeUnknown(let operation, .timedOut(let limit)):
            "The device did not finish the request to \(operation) within \(limit.formatted(.units(width: .wide))), so what it changed is unknown."
        case .noAnswer(let operation, let limit):
            "The device did not answer the request to \(operation) within \(limit.formatted(.units(width: .wide)))."
        }
    }
}

/// Whether a device's worker can take requests.
package enum DeviceChannelHealth: Equatable, Sendable {
    case ready
    /// A native call has outlived its deadline. It stays unresponsive until that call actually returns.
    case unresponsive(call: String, since: ContinuousClock.Instant)
}

/// A request a device's channel still holds.
package struct UnresolvedDeviceOperation: Equatable, Sendable {
    package enum State: Equatable, Sendable { case running, waiting, cleanup }

    package let device: DeviceAddress
    package let operation: String
    package let changesDevice: Bool
    package let state: State

    /// What the owner of a quit should say about it.
    package var description: String {
        let name = "\(device.identifier)\(device.deviceSetPath.map { " in \($0)" } ?? "")"
        return switch state {
        case .running where changesDevice:
            "\(name): the request to \(operation) has not returned, so what it changed is unknown."
        case .running: "\(name): the request to \(operation) has not returned."
        case .waiting: "\(name): the request to \(operation) was not sent."
        case .cleanup: "\(name): could not \(operation) before quitting."
        }
    }
}

/// The one owner of a device's native requests: their order, deadlines, queued cancellation and what is still in
/// flight. The channel never runs a native call on its own queue, so it stays able to answer while one is held. The
/// calls run one at a time on a serial worker, and a held call is never given a replacement thread. Being unresponsive
/// ends only when the held call returns, whose late result then gets its cleanup.
package actor SimulatorDeviceChannel {
    package nonisolated let address: DeviceAddress
    private let queue: DispatchSerialQueue
    private let worker: DispatchQueue

    package nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private nonisolated static let logger = Logger(subsystem: "dev.lynnswap.NeoSimulator", category: "DeviceIO")

    private var running: DeviceRequest?
    private var waiting: [DeviceRequest] = []
    private var cleanups: [DeviceRequest] = []
    private var health = DeviceChannelHealth.ready
    private var observers: [UUID: AsyncStream<DeviceChannelHealth>.Continuation] = [:]

    package init(address: DeviceAddress) {
        self.address = address
        queue = DispatchSerialQueue(label: "dev.lynnswap.NeoSimulator.device-channel", autoreleaseFrequency: .workItem)
        worker = DispatchQueue(label: "dev.lynnswap.NeoSimulator.device-worker.\(address.identifier)",
                               qos: .userInitiated, autoreleaseFrequency: .workItem)
    }

    // MARK: Requests

    /// Runs a call that changes nothing on the worker. Stopping a read needs no accounting, so cancelling one ends it
    /// as `CancellationError`, whether it was running or waiting. Requests are queued before suspending, so a caller's
    /// requests keep the order it made them in.
    ///
    /// `lateCompletion` receives the result of a call whose caller stopped waiting, on the worker, so that what the call
    /// created still has an owner.
    package nonisolated(nonsending) func read<Value: Sendable>(
        _ operation: String, limit: Duration = DeviceOperationLimit.bridge,
        lateCompletion: (@Sendable (Result<Value, any Error>) -> Void)? = nil,
        _ body: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await perform(operation, changesDevice: false, limit: limit, lateCompletion: lateCompletion, body)
    }

    /// Runs one step that changes the device on the worker, with everything that must not interleave with another
    /// request in `body`. Cancelling it before it starts ends it as `CancellationError` without sending anything;
    /// afterwards it ends as ``DeviceOperationFailure/outcomeUnknown(operation:cause:)``.
    package nonisolated(nonsending) func change<Value: Sendable>(
        _ operation: String, limit: Duration = DeviceOperationLimit.bridge,
        lateCompletion: (@Sendable (Result<Value, any Error>) -> Void)? = nil,
        _ body: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await perform(operation, changesDevice: true, limit: limit, lateCompletion: lateCompletion, body)
    }

    /// Releases what a native resource's owner left behind, on the worker, once no call holds it. Unlike a request it
    /// is not refused while the channel is unresponsive, and nothing waits for it. What has not run by the end of the
    /// process is in ``unresolvedOperations()``.
    package nonisolated func cleanUp(_ operation: String, _ body: @escaping @Sendable () -> Void) {
        let request = DeviceRequest(cleanup: operation, body: body)
        queue.async { self.assumeIsolated { $0.accept(cleanup: request) } }
    }

    private nonisolated(nonsending) func perform<Value: Sendable>(
        _ operation: String, changesDevice: Bool, limit: Duration,
        lateCompletion: (@Sendable (Result<Value, any Error>) -> Void)?,
        _ body: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        let request = DeviceRequest(operation: operation, changesDevice: changesDevice, limit: limit)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, any Error>) in
                request.prepare(body, continuation: continuation, lateCompletion: lateCompletion)
                queue.async { self.assumeIsolated { $0.accept(request) } }
            }
        } onCancel: {
            queue.async { self.assumeIsolated { $0.cancel(request) } }
        }
    }

    // MARK: State

    /// The current health, then each change. Only a native call's actual return moves it back to ready.
    package nonisolated func healthChanges() -> AsyncStream<DeviceChannelHealth> {
        let (stream, continuation) = AsyncStream.makeStream(of: DeviceChannelHealth.self)
        let identifier = UUID()
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            queue.async { self.assumeIsolated { _ = $0.observers.removeValue(forKey: identifier) } }
        }
        queue.async {
            self.assumeIsolated {
                $0.observers[identifier] = continuation
                continuation.yield($0.health)
            }
        }
        return stream
    }

    package var currentHealth: DeviceChannelHealth { health }

    /// What has not finished. This answers at once, also while a native call is held.
    package func unresolvedOperations() -> [UnresolvedDeviceOperation] {
        func unresolved(_ request: DeviceRequest, _ state: UnresolvedDeviceOperation.State) -> UnresolvedDeviceOperation {
            UnresolvedDeviceOperation(device: address, operation: request.operation,
                                      changesDevice: request.changesDevice, state: state)
        }
        return (running.map { [unresolved($0, $0.isCleanup ? .cleanup : .running)] } ?? [])
            + waiting.map { unresolved($0, .waiting) } + cleanups.map { unresolved($0, .cleanup) }
    }

    private func set(_ health: DeviceChannelHealth) {
        self.health = health
        for observer in observers.values { observer.yield(health) }
    }

    // MARK: Queue

    private func accept(_ request: DeviceRequest) {
        if request.isCancelled { return request.answer(throwing: CancellationError()) }
        if case .unresponsive(let call, _) = health {
            return request.answer(throwing: DeviceOperationFailure.notSent(operation: request.operation, heldBy: call))
        }
        waiting.append(request)
        startNext()
    }

    private func accept(cleanup request: DeviceRequest) {
        cleanups.append(request)
        startNext()
    }

    private func startNext() {
        guard running == nil else { return }
        let next: DeviceRequest
        if !cleanups.isEmpty { next = cleanups.removeFirst() }
        else if !waiting.isEmpty { next = waiting.removeFirst() }
        else { return }
        running = next
        // The deadline outlives its caller: a cancelled call that stays held still makes the channel unresponsive.
        let deadline = DispatchWorkItem { [weak self] in self?.assumeIsolated { $0.deadlinePassed(next) } }
        next.deadline = deadline
        let (seconds, attoseconds) = next.limit.components
        queue.asyncAfter(deadline: .now() + Double(seconds) + Double(attoseconds) / 1e18, execute: deadline)
        worker.async {
            let completion = next.run()
            self.queue.async { self.assumeIsolated { $0.finish(next, completion) } }
        }
    }

    /// The native call has returned, which is the only thing that makes the channel ready again.
    private func finish(_ request: DeviceRequest, _ completion: DeviceRequest.Completion) {
        request.deadline?.cancel()
        running = nil
        if request.isAnswered {
            if !request.isCleanup {
                if let failure = completion.failure {
                    Self.logger.error("The request to \(request.operation, privacy: .public) returned late: \(failure.localizedDescription, privacy: .public)")
                } else {
                    Self.logger.notice("The request to \(request.operation, privacy: .public) returned late.")
                }
            }
            if let cleanUp = completion.lateCleanup {
                cleanups.append(DeviceRequest(cleanup: "finish the request to \(request.operation)", body: cleanUp))
            }
        } else {
            request.isAnswered = true
            completion.answer()
        }
        if health != .ready { set(.ready) }
        startNext()
    }

    private func deadlinePassed(_ request: DeviceRequest) {
        guard running === request else { return }
        if !request.isAnswered {
            let failure: DeviceOperationFailure = request.changesDevice
                ? .outcomeUnknown(operation: request.operation, cause: .timedOut(request.limit))
                : .noAnswer(operation: request.operation, limit: request.limit)
            request.answer(throwing: failure)
        }
        set(.unresponsive(call: request.operation, since: .now))
        let refused = waiting
        waiting.removeAll()
        for queued in refused {
            queued.answer(throwing: DeviceOperationFailure.notSent(operation: queued.operation, heldBy: request.operation))
        }
    }

    private func cancel(_ request: DeviceRequest) {
        if let index = waiting.firstIndex(where: { $0 === request }) {
            waiting.remove(at: index)
            request.answer(throwing: CancellationError())
        } else if running === request {
            guard !request.isAnswered else { return }
            request.answer(throwing: request.changesDevice
                ? DeviceOperationFailure.outcomeUnknown(operation: request.operation, cause: .cancelled)
                : CancellationError())
        } else {
            // Cancellation can overtake the request on its way to this queue.
            request.isCancelled = true
        }
    }
}

/// One request and what its caller is told. Its mutable state belongs to the channel's queue.
private final class DeviceRequest: @unchecked Sendable {
    /// What a returned native call still has to do, which the channel chooses between once it has seen the call return.
    struct Completion: Sendable {
        let failure: (any Error)?
        let answer: @Sendable () -> Void
        let lateCleanup: (@Sendable () -> Void)?
    }

    let operation: String
    let changesDevice: Bool
    let limit: Duration
    let isCleanup: Bool
    private(set) var run: @Sendable () -> Completion
    private var fail: (@Sendable (any Error) -> Void)?
    var isCancelled = false
    var isAnswered: Bool
    var deadline: DispatchWorkItem?

    init(operation: String, changesDevice: Bool, limit: Duration) {
        self.operation = operation
        self.changesDevice = changesDevice
        self.limit = limit
        isCleanup = false
        isAnswered = false
        run = { preconditionFailure("A request is prepared before it is queued.") }
    }

    /// A cleanup has no caller to answer. It has a deadline, since a call that holds the worker holds later requests.
    init(cleanup operation: String, body: @escaping @Sendable () -> Void) {
        self.operation = operation
        changesDevice = true
        limit = DeviceOperationLimit.bridge
        isCleanup = true
        isAnswered = true
        run = {
            body()
            return Completion(failure: nil, answer: {}, lateCleanup: nil)
        }
    }

    func prepare<Value: Sendable>(_ body: @escaping @Sendable () throws -> Value,
                                  continuation: CheckedContinuation<Value, any Error>,
                                  lateCompletion: (@Sendable (Result<Value, any Error>) -> Void)?) {
        fail = { continuation.resume(throwing: $0) }
        run = {
            let result: Result<Value, any Error>
            do { result = .success(try body()) } catch { result = .failure(error) }
            let failure: (any Error)? = if case .failure(let error) = result { error } else { nil }
            let lateCleanup: (@Sendable () -> Void)? = if let lateCompletion { { lateCompletion(result) } } else { nil }
            return Completion(failure: failure, answer: { continuation.resume(with: result) }, lateCleanup: lateCleanup)
        }
    }

    func answer(throwing error: any Error) {
        isAnswered = true
        fail?(error)
        fail = nil
    }
}

extension Task where Failure == Never {
    /// Waits for the task until `deadline`, and returns whether it ended. It is not stopped; waiting for its value could
    /// not be given up.
    package func ends(before deadline: ContinuousClock.Instant) async -> Bool {
        await waitUntil(deadline) { _ = await self.value }
    }
}

extension Task where Failure == any Error {
    /// Waits for the task until `deadline`, and returns whether it ended. It is not stopped; waiting for its value could
    /// not be given up.
    package func ends(before deadline: ContinuousClock.Instant) async -> Bool {
        await waitUntil(deadline) { _ = await self.result }
    }
}

private func waitUntil(_ deadline: ContinuousClock.Instant, _ wait: @escaping @Sendable () async -> Void) async -> Bool {
    await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
        let waiting = Mutex<CheckedContinuation<Bool, Never>?>(continuation)
        let answer: @Sendable (Bool) -> Void = { ended in waiting.withLock { $0.take() }?.resume(returning: ended) }
        let timer = Task {
            try? await Task.sleep(until: deadline)
            answer(false)
        }
        Task {
            await wait()
            answer(true)
            timer.cancel()
        }
    }
}

/// The channel of each device this process has used. A channel lives as long as the process, so that an object made
/// again for the same device finds the worker, and any held call, of the first.
package final class DeviceIOHub: Sendable {
    package static let shared = DeviceIOHub()

    private let channels = Mutex<[DeviceAddress: SimulatorDeviceChannel]>([:])

    package init() {}

    package func channel(for address: DeviceAddress) -> SimulatorDeviceChannel {
        channels.withLock { channels in
            if let channel = channels[address] { return channel }
            let channel = SimulatorDeviceChannel(address: address)
            channels[address] = channel
            return channel
        }
    }

    /// What no channel has finished. It waits for no native call, so a quit can report what it leaves behind.
    package func unresolvedOperations() async -> [UnresolvedDeviceOperation] {
        var unresolved: [UnresolvedDeviceOperation] = []
        for channel in channels.withLock({ Array($0.values) }) {
            unresolved += await channel.unresolvedOperations()
        }
        return unresolved
    }
}
