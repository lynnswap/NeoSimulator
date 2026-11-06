import Foundation

/// One operation's result for any number of callers, each of which waits only as long as it chooses. A caller that stops
/// waiting, because it was cancelled or its limit passed, leaves the operation running, and nothing waits on its behalf.
/// Whoever asks later waits on the same run and gets its result, so a pending operation is never replaced. It starts when
/// first asked for and never starts again.
@MainActor
package final class SharedTask<Value: Sendable> {
    private let name: String
    private let operation: @MainActor () async throws -> Value
    private var isStarted = false
    private var result: Result<Value, any Error>?
    private var waiters: [UUID: CheckedContinuation<Value, any Error>] = [:]

    /// `name` completes "The request to …" when a caller's limit passes.
    package init(_ name: String, operation: @escaping @MainActor () async throws -> Value) {
        self.name = name
        self.operation = operation
    }

    /// Waits for the result. Cancelling the caller ends only its wait, as `CancellationError`, and `limit` as
    /// ``DeviceOperationFailure/noAnswer(operation:limit:)``.
    package func value(limit: Duration? = nil) async throws -> Value {
        try Task.checkCancellation()
        if let result { return try result.get() }
        start()
        let waiter = UUID()
        let deadline = limit.map { limit in
            Task { [weak self] in
                guard (try? await Task.sleep(for: limit)) != nil, let self else { return }
                answer(waiter, .failure(DeviceOperationFailure.noAnswer(operation: name, limit: limit)))
            }
        }
        defer { deadline?.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiters[waiter] = $0 }
        } onCancel: {
            Task { @MainActor in self.answer(waiter, .failure(CancellationError())) }
        }
    }

    private func start() {
        guard !isStarted else { return }
        isStarted = true
        Task { [self] in
            let result: Result<Value, any Error>
            do { result = .success(try await operation()) } catch { result = .failure(error) }
            self.result = result
            let waiting = waiters.values
            waiters.removeAll()
            for waiter in waiting { waiter.resume(with: result) }
        }
    }

    private func answer(_ waiter: UUID, _ result: Result<Value, any Error>) {
        waiters.removeValue(forKey: waiter)?.resume(with: result)
    }
}

/// A value read on a channel's worker for everyone who asks, and what was last read. A read that has started answers
/// those who asked before it. Everyone who asks meanwhile shares one more, which starts when it ends, so however many
/// ask, at most one read is running and one waiting. No caller's cancellation or limit stops a read, whose channel still
/// accounts for it, and a failed read leaves what was last read in place.
@MainActor
package final class CoalescedChannelRead<Value: Sendable> {
    package private(set) var latest: Value?
    /// Called with each value as it is read, before those who asked for it get it.
    package var onRead: (@MainActor (Value) -> Void)?
    private let channel: SimulatorDeviceChannel
    private let operation: String
    private let limit: Duration
    private let read: @Sendable () throws -> Value
    private var running: SharedTask<Value>?
    private var next: SharedTask<Value>?

    package init(channel: SimulatorDeviceChannel, operation: String, limit: Duration,
                 read: @escaping @Sendable () throws -> Value) {
        self.channel = channel
        self.operation = operation
        self.limit = limit
        self.read = read
    }

    /// Returns a value read after this call began. `limit` ends only this caller's wait.
    @discardableResult
    package func refresh(waitingAtMost limit: Duration? = nil) async throws -> Value {
        try Task.checkCancellation()
        let shared: SharedTask<Value>
        if let next {
            shared = next
        } else if let running {
            shared = SharedTask(operation) { [self] in
                _ = try? await running.value()
                return try await readOnChannel()
            }
            next = shared
        } else {
            shared = SharedTask(operation) { [self] in try await readOnChannel() }
            running = shared
        }
        return try await shared.value(limit: limit)
    }

    private func readOnChannel() async throws -> Value {
        defer {
            running = next
            next = nil
        }
        let value = try await channel.read(operation, limit: limit, read)
        latest = value
        onRead?(value)
        return value
    }
}
