import AppKit
import ImageIO
import NeoSimulatorDeviceIO

/// Owns untagged native frame requests separately from their cancellable callers.
@MainActor
package final class RemoteScreenFrameCapture {
    package typealias Request = @MainActor () async throws -> Void
    package typealias ScheduleTimeout = @MainActor (Duration, @escaping @MainActor () -> Void) -> () -> Void
    package typealias Decode = @Sendable (Data) async throws -> CGImage

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
    private let decode: Decode
    private var outstanding: NativeRequest?
    private var queued: Caller?
    /// Callers whose reply has arrived and is being decoded off the main actor.
    private var decoding: [UUID: Caller] = [:]
    private var requiresReconnect = false

    package init(timeout: Duration = .seconds(10), scheduleTimeout: @escaping ScheduleTimeout = RemoteScreenFrameCapture.scheduleDeadline,
                 decode: @escaping Decode = RemoteScreenFrameCapture.decodeImage) {
        self.timeout = timeout
        self.scheduleTimeout = scheduleTimeout
        self.decode = decode
    }

    /// Reserves the startup frame request before the connected state exposes capture controls.
    package func requestInitialFrame(request: @escaping Request) throws {
        try checkAvailable()
        guard outstanding == nil else { throw busyError() }
        begin(request: request, caller: nil)
    }

    package func capture(request: @escaping Request) async throws -> CGImage {
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

    package func receive(_ data: Data) {
        guard let current = outstanding else { return }
        outstanding = nil
        current.task?.cancel()
        current.cancelTimeout?()
        if let caller = current.caller {
            decoding[caller.identifier] = caller
            let decode = decode
            Task { [self] in
                let result: Result<CGImage, any Error>
                do { result = .success(try await decode(data)) } catch { result = .failure(error) }
                finishDecoding(caller.identifier, result)
            }
        }
        // A startup or canceled caller's reply is drained, never given to its successor.
        if let next = queued {
            queued = nil
            begin(request: next.request, caller: next)
        }
    }

    package func fail(_ error: any Error) {
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

    private func finishDecoding(_ identifier: UUID, _ result: Result<CGImage, any Error>) {
        decoding.removeValue(forKey: identifier)?.continuation.resume(with: result)
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
        } else {
            finishDecoding(identifier, .failure(CancellationError()))
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

    /// Decodes fully here, because a lazily decoded image would otherwise be decoded where it is first drawn.
    private static func decodeImage(_ data: Data) async throws -> CGImage {
        try await performBlockingIO {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
                throw CLIError.io("remote-screen-image", "The remote screen supplied an image that could not be decoded.")
            }
            return image
        }
    }

    private static func scheduleDeadline(_ duration: Duration, action: @escaping @MainActor () -> Void) -> () -> Void {
        let task = Task {
            do { try await Task.sleep(for: duration) } catch { return }
            action()
        }
        return { task.cancel() }
    }
}
