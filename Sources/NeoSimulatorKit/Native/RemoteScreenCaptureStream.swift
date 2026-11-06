import AVFoundation
import CoreVideo
import Metal
import NeoSimulatorDeviceIO
import QuartzCore

/// Receives one capture source's video frames and presents the latest through Metal.
///
/// The capture output, Metal texture cache and GPU submissions share this actor's serial
/// queue. A frame's IOSurface-backed pixel buffer stays retained until the GPU finishes copying
/// it into a drawable; frames that arrive while two copies are in flight replace the waiting one.
///
/// The capture session's own calls can block for seconds, so they run in order on a second queue
/// that only this stream uses, and this actor keeps answering while they do. Stopping is accepted at
/// once; what it ends stays retained until the session has closed and the GPU has finished.
actor RemoteScreenCaptureStream {
    package enum Event: Sendable {
        /// The first frame, or a frame whose pixel size differs from the previous one.
        case frameSize(CGSize)
        case failure(any Error)
    }

    /// The main actor owns the layer's geometry and drawable size; the stream only acquires
    /// and presents its drawables, and checks each drawable's size before copying into it.
    package struct Target: @unchecked Sendable {
        package let layer: CAMetalLayer
    }

    /// Releases a frame's texture and pixel buffer only after the GPU has finished reading them.
    private struct FrameLease: @unchecked Sendable {
        let texture: CVMetalTexture
        let buffer: CVPixelBuffer
    }

    /// Where a session sends its frames: to this stream, on the queue this actor runs on.
    package struct FrameOutput: @unchecked Sendable {
        let delegate: any AVCaptureVideoDataOutputSampleBufferDelegate
        let queue: DispatchQueue
    }

    /// What the stream asks of its capture session and GPU, separately from the frame and control state it owns.
    package struct Lifecycle: Sendable {
        /// Configures and starts capture. Called on the session queue, and may block there.
        var open: @Sendable (_ sourceID: String, _ output: FrameOutput, _ failure: @escaping @Sendable (any Error) -> Void) throws -> Void
        /// Ends whatever `open` began, even if it failed. Called on the session queue after `open`, and may block there.
        var close: @Sendable () -> Void
        /// Sees each frame's command buffer before the frame's copy is encoded into it.
        var encoding: @Sendable (any MTLCommandBuffer) -> Void = { _ in }

        package static func captureSession() -> Lifecycle {
            let session = CaptureSessionWork()
            return Lifecycle(open: session.open, close: session.close)
        }
    }

    package static let maximumFramesInFlight = 2
    package nonisolated let events: AsyncStream<Event>
    private nonisolated let queue: DispatchSerialQueue
    package nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
    private nonisolated let sessionQueue = DispatchQueue(label: "dev.lynnswap.NeoSimulator.RemoteScreenCapture.session", qos: .userInitiated)
    private let lifecycle: Lifecycle
    private let stopLimit: Duration
    private let continuation: AsyncStream<Event>.Continuation
    private let target: Target
    private let commands: any MTLCommandQueue
    private let textures: CVMetalTextureCache
    private let delegate = SampleBufferDelegate()
    private var starting: CheckedContinuation<Void, any Error>?
    private var current: CVPixelBuffer?
    private var frameSize: CGSize?
    private var drawableSize: CGSize?
    private var needsPresentation = false
    private var framesInFlight = 0
    private var drained: CheckedContinuation<Void, Never>?
    private var shutdown: Task<Void, Never>?
    private var stopOverran = false
    private var stopped = false
    private var failed = false

    package init(target: Target, device: any MTLDevice, lifecycle: Lifecycle = .captureSession(),
                 stopLimit: Duration = DeviceOperationLimit.captureStreamStop) throws {
        guard let commands = device.makeCommandQueue() else {
            throw CLIError.unavailable("remote-screen-metal", "Metal could not create a command queue for the device screen.")
        }
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let cache else {
            throw CLIError.unavailable("remote-screen-metal", "Metal could not create a texture cache for the device screen (CoreVideo status \(status)).")
        }
        self.target = target
        self.commands = commands
        self.lifecycle = lifecycle
        self.stopLimit = stopLimit
        textures = cache
        queue = DispatchSerialQueue(label: "dev.lynnswap.NeoSimulator.RemoteScreenCapture", qos: .userInteractive)
        // Only size changes and failures are events, so a short buffer keeps every one in practice.
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(8))
    }

    /// Requests camera access, which macOS also applies to device screen-capture sources.
    @MainActor
    package static func authorize() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return
        case .notDetermined: if await AVCaptureDevice.requestAccess(for: .video) { return }
        default: break
        }
        throw CLIError(category: .unavailable, identifier: "remote-screen-camera-access",
                       message: "NeoSimulator is not allowed to capture the device’s screen.",
                       recoverySuggestion: "Allow NeoSimulator in System Settings > Privacy & Security > Camera, then reconnect the screen.")
    }

    /// Starts video-only capture from the source. Stopping or cancelling ends this wait at once. The session's
    /// calls then finish on their queue, and only stopping the stream closes what they opened.
    package func start(sourceID: String) async throws {
        guard !stopped else { throw CancellationError() }
        try Task.checkCancellation()
        delegate.stream = self
        let output = FrameOutput(delegate: delegate, queue: queue)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (started: CheckedContinuation<Void, any Error>) in
                starting = started
                sessionQueue.async { [self, lifecycle] in
                    let result = Result {
                        try lifecycle.open(sourceID, output) { [weak self] error in self?.enqueue { $0.fail(error) } }
                    }
                    enqueue { $0.finishStart(result) }
                }
            }
        } onCancel: {
            enqueue { $0.finishStart(.failure(CancellationError())) }
        }
    }

    private func finishStart(_ result: Result<Void, any Error>) {
        let waiter = starting
        starting = nil
        waiter?.resume(with: result)
    }

    /// Accepts the drawable size that the main actor applied for the current frame size.
    package func acceptDrawableSize(_ size: CGSize) {
        drawableSize = size
        needsPresentation = current != nil
        presentIfPossible()
    }

    /// Copies the current frame's pixels, without rendering the local view hierarchy. The copy holds its
    /// frame while it runs off this queue, which keeps later frames arriving.
    package func snapshot() async throws -> CGImage {
        guard !stopped, let current else {
            throw CLIError.unavailable("remote-screen-image", "The capture source has not supplied a frame to capture.")
        }
        nonisolated(unsafe) let frame = current
        return try await performBlockingIO { try Self.image(from: frame) }
    }

    /// Ends capture and drops queued frames at once, then waits for the session to close and for GPU copies that
    /// still read a frame. A wait that reaches the stream's limit is reported; the shutdown keeps its frames and
    /// carries on, and stopping again waits for it again.
    package func stop() async throws {
        let shutdown = beginShutdown()
        guard await shutdown.ends(before: .now + stopLimit) else {
            stopOverran = true
            throw CLIError.io("remote-screen-capture-stop", "The device’s screen capture has not finished stopping. It keeps its frames until the capture session and GPU finish.")
        }
    }

    private func beginShutdown() -> Task<Void, Never> {
        if let shutdown { return shutdown }
        stopped = true
        current = nil
        needsPresentation = false
        continuation.finish()
        finishStart(.failure(CancellationError()))
        let task = Task { [self] in
            await withCheckedContinuation { (closed: CheckedContinuation<Void, Never>) in
                sessionQueue.async { [lifecycle] in
                    lifecycle.close()
                    closed.resume()
                }
            }
            if framesInFlight > 0 { await withCheckedContinuation { drained = $0 } }
            CVMetalTextureCacheFlush(textures, 0)
            if stopOverran { hostLog("The device’s screen capture finished stopping after its limit.") }
        }
        shutdown = task
        return task
    }

    package func receive(_ buffer: CVPixelBuffer) {
        guard !stopped, !failed else { return }
        guard CVPixelBufferGetIOSurface(buffer) != nil else {
            fail(CLIError.unavailable("remote-screen-frame-surface", "The capture source supplied frames without IOSurface backing, which the screen does not copy."))
            return
        }
        current = buffer
        let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        if size != frameSize {
            frameSize = size
            continuation.yield(.frameSize(size))
        }
        needsPresentation = true
        presentIfPossible()
    }

    private func presentIfPossible() {
        guard needsPresentation, !stopped, !failed, framesInFlight < Self.maximumFramesInFlight,
              let buffer = current, let size = frameSize, size == drawableSize else { return }
        needsPresentation = false
        do { try present(buffer, size: size) } catch { fail(error) }
    }

    private func present(_ buffer: CVPixelBuffer, size: CGSize) throws {
        let width = Int(size.width), height = Int(size.height)
        // A drawable from before the main actor's latest resize, or a timed-out wait, skips this frame.
        guard let drawable = target.layer.nextDrawable(),
              drawable.texture.width == width, drawable.texture.height == height else { return }
        var image: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(nil, textures, buffer, nil, .bgra8Unorm, width, height, 0, &image)
        guard status == kCVReturnSuccess, let image, let texture = CVMetalTextureGetTexture(image) else {
            throw CLIError.io("remote-screen-frame-texture", "A captured frame could not be used as a Metal texture (CoreVideo status \(status)).")
        }
        guard let submission = commands.makeCommandBuffer() else {
            throw CLIError.io("remote-screen-frame-render", "Metal could not encode the captured frame.")
        }
        lifecycle.encoding(submission)
        guard let copy = submission.makeBlitCommandEncoder() else {
            throw CLIError.io("remote-screen-frame-render", "Metal could not encode the captured frame.")
        }
        copy.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                  sourceSize: MTLSize(width: width, height: height, depth: 1), to: drawable.texture,
                  destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
        copy.endEncoding()
        submission.present(drawable)
        let lease = FrameLease(texture: image, buffer: buffer)
        submission.addCompletedHandler { [weak self] completed in
            withExtendedLifetime(lease) {}
            let failure: (any Error)? = completed.status == .error
                ? completed.error ?? CLIError.io("remote-screen-frame-render", "Metal could not copy the captured frame.")
                : nil
            self?.enqueue { $0.didCompleteFrame(failure: failure) }
        }
        framesInFlight += 1
        submission.commit()
    }

    private func didCompleteFrame(failure: (any Error)?) {
        framesInFlight -= 1
        if framesInFlight == 0 {
            // Drops cached textures for pool buffers that no submission still reads.
            CVMetalTextureCacheFlush(textures, 0)
            drained?.resume()
            drained = nil
        }
        if let failure { fail(failure) }
        presentIfPossible()
    }

    private func fail(_ error: any Error) {
        guard !stopped, !failed else { return }
        failed = true
        continuation.yield(.failure(error))
    }

    private nonisolated func enqueue(_ operation: @escaping @Sendable (isolated RemoteScreenCaptureStream) -> Void) {
        queue.async { [weak self] in self?.assumeIsolated(operation) }
    }

    nonisolated fileprivate func receiveOnQueue(_ sample: CMSampleBuffer) {
        // The capture output calls its delegate on this actor's queue and hands the buffer over.
        guard let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
        nonisolated(unsafe) let frame = buffer
        assumeIsolated { $0.receive(frame) }
    }

    /// Copies the pixels once, because the capture pool reuses the buffer for later frames.
    package static func image(from buffer: CVPixelBuffer) throws -> CGImage {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            throw CLIError.io("remote-screen-image", "The captured frame could not be read.")
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let space = CVImageBufferGetColorSpace(buffer)?.takeUnretainedValue() ?? CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(bytes: base, count: bytesPerRow * height) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                                  space: space, bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                                      | CGImageAlphaInfo.noneSkipFirst.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw CLIError.io("remote-screen-image", "The captured frame could not be read.")
        }
        return image
    }
}

private final class SampleBufferDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    weak var stream: RemoteScreenCaptureStream?

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        stream?.receiveOnQueue(sampleBuffer)
    }
}

/// A stream's capture session, used only on the stream's session queue.
private final class CaptureSessionWork: @unchecked Sendable {
    private var session: AVCaptureSession?
    private var observers: [any NSObjectProtocol] = []

    func open(sourceID: String, output frames: RemoteScreenCaptureStream.FrameOutput, failure: @escaping @Sendable (any Error) -> Void) throws {
        guard let device = AVCaptureDevice(uniqueID: sourceID), device.isConnected else {
            throw CLIError.unavailable("remote-screen-capture-source", "The device’s capture source disconnected before its screen started.")
        }
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        let session = AVCaptureSession()
        self.session = session
        session.beginConfiguration()
        do {
            try configure(session, input: input, output: output)
            session.commitConfiguration()
        } catch {
            session.commitConfiguration()
            self.session = nil
            throw error
        }
        output.setSampleBufferDelegate(frames.delegate, queue: frames.queue)
        observe(session, device: device, failure: failure)
        session.startRunning()
        guard session.isRunning else {
            throw CLIError.io("remote-screen-capture-start", "The device’s capture source did not start.")
        }
    }

    func close() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        guard let session else { return }
        session.stopRunning()
        for case let output as AVCaptureVideoDataOutput in session.outputs { output.setSampleBufferDelegate(nil, queue: nil) }
        session.beginConfiguration()
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        session.commitConfiguration()
        self.session = nil
    }

    private func configure(_ session: AVCaptureSession, input: AVCaptureDeviceInput, output: AVCaptureVideoDataOutput) throws {
        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw CLIError.unavailable("remote-screen-capture-session", "The device’s capture source cannot be used by another capture session at the same time.")
        }
        session.addInputWithNoConnections(input)
        session.addOutputWithNoConnections(output)
        guard let port = input.ports.first(where: { $0.mediaType == .video }) else {
            let types = input.ports.map(\.mediaType.rawValue).joined(separator: ", ")
            throw CLIError.unavailable("remote-screen-capture-video", "The device’s capture source supplied no video port (ports: \(types)).")
        }
        let connection = AVCaptureConnection(inputPorts: [port], output: output)
        guard session.canAddConnection(connection) else {
            throw CLIError.unavailable("remote-screen-capture-video", "The device’s capture source video cannot be received as frames.")
        }
        session.addConnection(connection)
        let format = kCVPixelFormatType_32BGRA
        guard output.availableVideoPixelFormatTypes.contains(format) else {
            let formats = output.availableVideoPixelFormatTypes.map { String(format: "0x%08X", $0) }.joined(separator: ", ")
            throw CLIError.unavailable("remote-screen-capture-format", "The device’s capture source cannot supply BGRA frames (formats: \(formats)).")
        }
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: format]
    }

    private func observe(_ session: AVCaptureSession, device: AVCaptureDevice, failure: @escaping @Sendable (any Error) -> Void) {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { notification in
                failure(notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
                    ?? CLIError.io("remote-screen-capture-runtime", "The device’s screen capture failed."))
            },
            center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { _ in
                failure(CLIError.unavailable("remote-screen-capture-interrupted", "Another app or macOS interrupted the device’s screen capture."))
            },
            center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil) { _ in
                failure(CLIError.unavailable("remote-screen-capture-disconnected", "The device’s capture source disconnected."))
            },
        ]
    }
}
