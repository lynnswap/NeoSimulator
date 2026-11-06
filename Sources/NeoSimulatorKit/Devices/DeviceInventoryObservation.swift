import Foundation
import NeoSimulatorDeviceIO

/// Reports changes to connected devices so the caller can reload its inventory.
@MainActor
package final class DeviceInventoryObservation {
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
            let wasDelayed = try await self.initializeSource()
            try Task.checkCancellation()
            guard !self.stopping else { throw CancellationError() }
            self.observationTask = Task { [weak self, source = self.source] in
                do {
                    try await source.follow { [weak self] in
                        guard let self, !self.stopping, !Task.isCancelled else { return }
                        self.onChange?()
                    }
                } catch {
                    guard let self, !self.stopping, !Task.isCancelled else { return }
                    self.onError?(error)
                }
            }
            // What changed while the service was not answering was not observed.
            if wasDelayed { self.onChange?() }
        }
        startTask = task
        defer { startTask = nil }
        try await task.value
    }

    /// Reports a service that outlives a caller's limit and asks again, which waits on the same initialization, since
    /// nothing else would start the observation when it finishes. Returns whether that happened.
    private func initializeSource() async throws -> Bool {
        var wasDelayed = false
        while true {
            do {
                try await source.initialize()
                return wasDelayed
            } catch let failure as DeviceOperationFailure {
                guard case .noAnswer = failure, !stopping else { throw failure }
                wasDelayed = true
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
