import AppKit
import ImageIO

/// Matches the media stream's uncorrelated last-frame reply to one capture request.
@MainActor
final class RemoteScreenFrameCapture {
    private struct Pending {
        let identifier: UUID
        let continuation: CheckedContinuation<CGImage, any Error>
        var request: Task<Void, Never>?
        var timeout: Task<Void, Never>?
    }
    private let timeout: Duration
    private var pending: Pending?

    init(timeout: Duration = .seconds(10)) { self.timeout = timeout }

    func capture(request: @escaping @MainActor () async throws -> Void) async throws -> CGImage {
        guard pending == nil else {
            throw CLIError.unavailable("remote-screen-capture-busy", "A screenshot is already being captured.")
        }
        let identifier = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending = Pending(identifier: identifier, continuation: continuation)
                pending?.timeout = Task { [weak self, timeout] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self?.finish(identifier, result: .failure(CLIError.io("remote-screen-capture-timeout",
                        "The remote screen did not supply a screenshot in time. Try capturing it again.")))
                }
                pending?.request = Task { [weak self] in
                    do { try await request() }
                    catch { self?.finish(identifier, result: .failure(error)) }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(identifier, result: .failure(CancellationError())) }
        }
    }

    func receive(_ data: Data) {
        guard let identifier = pending?.identifier else { return }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            finish(identifier, result: .failure(CLIError.io("remote-screen-image", "The remote screen supplied an image that could not be decoded.")))
            return
        }
        finish(identifier, result: .success(image))
    }

    func fail(_ error: any Error) {
        if let identifier = pending?.identifier { finish(identifier, result: .failure(error)) }
    }

    private func finish(_ identifier: UUID, result: Result<CGImage, any Error>) {
        guard let pending, pending.identifier == identifier else { return }
        self.pending = nil
        pending.request?.cancel()
        pending.timeout?.cancel()
        pending.continuation.resume(with: result)
    }
}
