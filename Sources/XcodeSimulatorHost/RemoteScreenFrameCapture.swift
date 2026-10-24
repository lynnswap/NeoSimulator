import AppKit
import ImageIO

/// Owns untagged native frame requests separately from their cancellable callers.
@MainActor
final class RemoteScreenFrameCapture {
    typealias Request = @MainActor () async throws -> Void
    typealias ScheduleTimeout = @MainActor (Duration, @escaping @MainActor () -> Void) -> () -> Void

    private struct Caller {
        let identifier: UUID
        let continuation: CheckedContinuation<CGImage, any Error>
        let request: Request
    }
    private struct NativeRequest {
        let identifier: UUID
        var caller: Caller?
        var task: Task<Void, Never>?
        var cancelTimeout: (() -> Void)?
    }
    private let timeout: Duration
    private let scheduleTimeout: ScheduleTimeout
    private var outstanding: NativeRequest?
    private var queued: Caller?
    private var requiresReconnect = false

    init(timeout: Duration = .seconds(10), scheduleTimeout: @escaping ScheduleTimeout = RemoteScreenFrameCapture.scheduleDeadline) {
        self.timeout = timeout
        self.scheduleTimeout = scheduleTimeout
    }

    /// Reserves the startup frame request before the connected state exposes capture controls.
    func requestInitialFrame(request: @escaping Request) throws {
        try checkAvailable()
        guard outstanding == nil else { throw busyError() }
        begin(request: request, caller: nil)
    }

    func capture(request: @escaping Request) async throws -> CGImage {
        try checkAvailable()
        guard outstanding?.caller == nil, queued == nil else { throw busyError() }
        let identifier = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let caller = Caller(identifier: identifier, continuation: continuation, request: request)
                if outstanding != nil { queued = caller }
                else { begin(request: request, caller: caller) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelCaller(identifier) }
        }
    }

    func receive(_ data: Data) {
        guard let current = outstanding else { return }
        outstanding = nil
        current.task?.cancel()
        current.cancelTimeout?()
        if let caller = current.caller {
            if let source = CGImageSourceCreateWithData(data as CFData, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                caller.continuation.resume(returning: image)
            } else {
                caller.continuation.resume(throwing: CLIError.io("remote-screen-image", "The remote screen supplied an image that could not be decoded."))
            }
        }
        // A startup or canceled caller's reply is drained, never given to its successor.
        if let next = queued {
            queued = nil
            begin(request: next.request, caller: next)
        }
    }

    func fail(_ error: any Error) {
        requiresReconnect = true
        let current = outstanding
        let waiting = queued
        outstanding = nil
        queued = nil
        current?.task?.cancel()
        current?.cancelTimeout?()
        current?.caller?.continuation.resume(throwing: error)
        waiting?.continuation.resume(throwing: error)
    }

    private func begin(request: @escaping Request, caller: Caller?) {
        let identifier = UUID()
        outstanding = NativeRequest(identifier: identifier, caller: caller)
        let cancel = scheduleTimeout(timeout) { [weak self] in
            self?.requestFailed(identifier, error: CLIError.io("remote-screen-capture-timeout",
                "The remote screen did not supply a screenshot in time. Reconnect the screen before capturing it again."))
        }
        guard outstanding?.identifier == identifier else { cancel(); return }
        outstanding?.cancelTimeout = cancel
        outstanding?.task = Task { [weak self] in
            do { try await request() }
            catch { self?.requestFailed(identifier, error: error) }
        }
    }

    private func requestFailed(_ identifier: UUID, error: any Error) {
        guard outstanding?.identifier == identifier else { return }
        // There is no native request ID or cancel acknowledgement with which to reject a late reply.
        fail(error)
    }

    private func cancelCaller(_ identifier: UUID) {
        if let caller = outstanding?.caller, caller.identifier == identifier {
            outstanding?.caller = nil
            caller.continuation.resume(throwing: CancellationError())
        } else if let caller = queued, caller.identifier == identifier {
            queued = nil
            caller.continuation.resume(throwing: CancellationError())
        }
    }

    private func checkAvailable() throws {
        if requiresReconnect {
            throw CLIError.unavailable("remote-screen-capture-reconnect", "Reconnect the screen before taking another screenshot.")
        }
    }

    private func busyError() -> CLIError {
        CLIError.unavailable("remote-screen-capture-busy", "A screenshot is already being captured.")
    }

    private static func scheduleDeadline(_ duration: Duration, action: @escaping @MainActor () -> Void) -> () -> Void {
        let task = Task {
            do { try await Task.sleep(for: duration) } catch { return }
            action()
        }
        return { task.cancel() }
    }
}
