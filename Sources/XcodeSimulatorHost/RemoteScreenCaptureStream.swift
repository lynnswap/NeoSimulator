import AVFoundation
import CoreVideo
import Metal
import QuartzCore

/// Receives one capture source's video frames and presents the latest through Metal.
///
/// The capture output, Metal texture cache and GPU submissions share this actor's serial
/// queue. A frame's IOSurface-backed pixel buffer stays retained until the GPU finishes copying
/// it into a drawable; frames that arrive while two copies are in flight replace the waiting one.
actor RemoteScreenCaptureStream {
    enum Event: Sendable {
        /// The first frame, or a frame whose pixel size differs from the previous one.
        case frameSize(CGSize)
        case failure(any Error)
    }

    /// The main actor owns the layer's geometry and drawable size; the stream only acquires
    /// and presents its drawables, and checks each drawable's size before copying into it.
    struct Target: @unchecked Sendable {
        let layer: CAMetalLayer
    }

    /// Releases a frame's texture and pixel buffer only after the GPU has finished reading them.
    private struct FrameLease: @unchecked Sendable {
        let texture: CVMetalTexture
        let buffer: CVPixelBuffer
    }

    static let maximumFramesInFlight = 2
    nonisolated let events: AsyncStream<Event>
    private nonisolated let queue: DispatchSerialQueue
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
    private let continuation: AsyncStream<Event>.Continuation
    private let target: Target
    private let commands: any MTLCommandQueue
    private let textures: CVMetalTextureCache
    private let delegate = SampleBufferDelegate()
    private var session: AVCaptureSession?
    private var observers: [any NSObjectProtocol] = []
    private var current: CVPixelBuffer?
    private var frameSize: CGSize?
    private var drawableSize: CGSize?
    private var needsPresentation = false
    private var framesInFlight = 0
    private var lastSubmission: (any MTLCommandBuffer)?
    private var stopped = false
    private var failed = false

    init(target: Target, device: any MTLDevice) throws {
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
        textures = cache
        queue = DispatchSerialQueue(label: "dev.lynnswap.NeoSimulator.RemoteScreenCapture", qos: .userInteractive)
        // Only size changes and failures are events, so a short buffer keeps every one in practice.
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(8))
    }

    /// Requests camera access, which macOS also applies to device screen-capture sources.
    @MainActor
    static func authorize() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return
        case .notDetermined: if await AVCaptureDevice.requestAccess(for: .video) { return }
        default: break
        }
        throw CLIError(category: .unavailable, identifier: "remote-screen-camera-access",
                       message: "NeoSimulator is not allowed to capture the device’s screen.",
                       recoverySuggestion: "Allow NeoSimulator in System Settings > Privacy & Security > Camera, then reconnect the screen.")
    }

    /// Starts video-only capture from the source; its audio is never connected.
    func start(sourceID: String) throws {
        guard !stopped else { throw CancellationError() }
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
        delegate.stream = self
        output.setSampleBufferDelegate(delegate, queue: queue)
        observe(session, device: device)
        session.startRunning()
        guard session.isRunning else {
            throw CLIError.io("remote-screen-capture-start", "The device’s capture source did not start.")
        }
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

    private func observe(_ session: AVCaptureSession, device: AVCaptureDevice) {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] notification in
                let error: any Error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
                    ?? CLIError.io("remote-screen-capture-runtime", "The device’s screen capture failed.")
                self?.enqueue { $0.fail(error) }
            },
            center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] _ in
                self?.enqueue { $0.fail(CLIError.unavailable("remote-screen-capture-interrupted", "Another app or macOS interrupted the device’s screen capture.")) }
            },
            center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil) { [weak self] _ in
                self?.enqueue { $0.fail(CLIError.unavailable("remote-screen-capture-disconnected", "The device’s capture source disconnected.")) }
            },
        ]
    }

    /// Accepts the drawable size that the main actor applied for the current frame size.
    func acceptDrawableSize(_ size: CGSize) {
        drawableSize = size
        needsPresentation = current != nil
        presentIfPossible()
    }

    /// Copies the current frame's pixels, without rendering the local view hierarchy.
    func snapshot() throws -> CGImage {
        guard !stopped, let current else {
            throw CLIError.unavailable("remote-screen-image", "The capture source has not supplied a frame to capture.")
        }
        return try Self.image(from: current)
    }

    /// Ends capture, drops queued frames and waits for GPU copies that still read a frame.
    func stop() {
        guard !stopped else { return }
        stopped = true
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        if let session {
            session.stopRunning()
            for case let output as AVCaptureVideoDataOutput in session.outputs { output.setSampleBufferDelegate(nil, queue: nil) }
            session.beginConfiguration()
            for input in session.inputs { session.removeInput(input) }
            for output in session.outputs { session.removeOutput(output) }
            session.commitConfiguration()
        }
        session = nil
        current = nil
        needsPresentation = false
        // One command queue completes its submissions in commit order.
        lastSubmission?.waitUntilCompleted()
        lastSubmission = nil
        CVMetalTextureCacheFlush(textures, 0)
        continuation.finish()
    }

    func receive(_ buffer: CVPixelBuffer) {
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
        guard let submission = commands.makeCommandBuffer(), let copy = submission.makeBlitCommandEncoder() else {
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
        lastSubmission = submission
    }

    private func didCompleteFrame(failure: (any Error)?) {
        framesInFlight -= 1
        if framesInFlight == 0 {
            lastSubmission = nil
            // Drops cached textures for pool buffers that no submission still reads.
            CVMetalTextureCacheFlush(textures, 0)
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
    static func image(from buffer: CVPixelBuffer) throws -> CGImage {
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
