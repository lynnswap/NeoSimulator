import Foundation
import NeoSimulatorDeviceIO

/// Reports changes to connected devices so the caller can reload its inventory.
@MainActor
package final class DeviceInventoryObservation {
    /// Fires after the change stream is subscribed, before its initial inventory refresh.
    package var onReady: (() -> Void)?
    package var onChange: (() -> Void)?
    package var onError: ((any Error) -> Void)?

    private let source: any DeviceInventoryChangeSource
    private var startTask: Task<Void, any Error>?
    private var observationTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var stopping = false

    package convenience init() throws {
        self.init(source: CoreDeviceInventoryChangeSource())
    }

    package init(source: any DeviceInventoryChangeSource) { self.source = source }

    deinit {
        startTask?.cancel()
        observationTask?.cancel()
    }

    /// Initializes the device service and starts observing its connected-device changes.
    package func start() async throws {
        guard !stopping else { throw CancellationError() }
        if let startTask { try await startTask.value; return }
        guard observationTask == nil else { return }
        let task = Task { [self] in
            try await self.initializeSource()
            try Task.checkCancellation()
            guard !self.stopping else { throw CancellationError() }
            let (ready, readiness) = AsyncThrowingStream<Void, any Error>.makeStream()
            self.observationTask = Task { [weak self, source = self.source] in
                var subscribed = false
                defer { readiness.finish() }
                do {
                    try await source.follow(onReady: { [weak self] in
                        guard let self, !self.stopping, !Task.isCancelled else { return }
                        subscribed = true
                        self.onReady?()
                        // Cover changes between the earlier inventory read and subscribing.
                        self.onChange?()
                        readiness.yield(())
                        readiness.finish()
                    }, onChange: { [weak self] in
                        guard let self, !self.stopping, !Task.isCancelled else { return }
                        self.onChange?()
                    })
                } catch {
                    guard let self, !self.stopping, !Task.isCancelled else { return }
                    if subscribed { self.onError?(error) }
                    else { readiness.finish(throwing: error) }
                }
            }
            for try await _ in ready { break }
            try Task.checkCancellation()
        }
        startTask = task
        defer { startTask = nil }
        try await task.value
    }

    /// Reports an initialization timeout and rejoins the shared task so observation can start
    /// when it finishes.
    private func initializeSource() async throws {
        while true {
            do {
                try await source.initialize()
                return
            } catch let failure as DeviceOperationFailure {
                guard case .noAnswer = failure, !stopping else { throw failure }
                onError?(failure)
            }
        }
    }

    /// Cancels observation and waits until no further callbacks can be delivered.
    package func stop() async {
        if let stopTask { await stopTask.value; return }
        stopping = true
        let starting = startTask
        let observing = observationTask
        starting?.cancel()
        observing?.cancel()
        let task = Task {
            _ = await starting?.result
            await observing?.value
        }
        stopTask = task
        await task.value
        startTask = nil
        observationTask = nil
    }
}
