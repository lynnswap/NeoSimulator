import AppKit
import Metal

/// Shows a USB-connected device's primary display from its chosen screen-capture source,
/// and sends input to the same CoreDevice device through its HID services.
@MainActor
final class CoreDeviceCaptureTransport: RemoteScreenTransport {
    private let remote: CoreDeviceRemoteScreenDevice
    private let input: CoreDeviceScreenInput
    private let capabilityObservation: RemoteScreenInputCapabilityObservation
    private let displayGeometry: CoreDeviceDisplayGeometry
    private let video = CAMetalLayer()
    private let framebuffer: RemoteScreenFramebuffer
    private let stream: RemoteScreenCaptureStream
    private let contentView: NSView
    private let source: RemoteScreenCaptureSource
    private var events: (@MainActor (RemoteScreenTransportEvent) -> Void)?
    private var observation: Task<Void, Never>?
    private var disconnecting: Task<Void, any Error>?
    private var attributes: RemoteDeviceVideoAttributes?
    private var frameSize: CGSize?
    private var stopped = false
    private var finished = false
    private var failure: (any Error)?
    var inputCapabilities: Set<RemoteDeviceInputKind> {
        framebuffer.isReady ? capabilityObservation.capabilities : capabilityObservation.capabilities.subtracting([.pointer, .digitizer])
    }
    var canCaptureScreenshot: Bool { !stopped && !finished && frameSize != nil }
    private(set) var canRecordScreen = false

    init(remote: CoreDeviceRemoteScreenDevice, source: RemoteScreenCaptureSource, contentView: NSView) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw CLIError.unavailable("remote-screen-metal", "This Mac has no Metal device to show the device screen.")
        }
        self.remote = remote
        self.source = source
        self.contentView = contentView
        let input = CoreDeviceScreenInput(remote: remote)
        self.input = input
        capabilityObservation = RemoteScreenInputCapabilityObservation(source: try CoreDeviceInputCapabilitySource(remote: remote),
            read: { try input.capabilities() }, invalidateInputs: { input.discardInputs(for: $0) })
        displayGeometry = try CoreDeviceDisplayGeometry(remote: remote)
        video.device = device
        video.pixelFormat = .bgra8Unorm
        // Frames are copied into the drawable rather than rendered as an attachment.
        video.framebufferOnly = false
        // Two drawables, rather than the default three, leave fewer older frames queued ahead of
        // the newest one, so the live screen falls less far behind the device.
        video.maximumDrawableCount = 2
        video.isOpaque = true
        video.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        stream = try RemoteScreenCaptureStream(target: .init(layer: video), device: device)
        framebuffer = RemoteScreenFramebuffer(frame: .zero, video: video)
        framebuffer.autoresizingMask = [.width, .height]
    }

    func start(events: @escaping @MainActor (RemoteScreenTransportEvent) -> Void) async throws {
        try checkConnection()
        self.events = events
        try await RemoteScreenCaptureStream.authorize()
        try Task.checkCancellation()
        try checkConnection()
        try capabilityObservation.start(update: { [weak self] removed in
            self?.events?(removed.isEmpty ? .inputGeometryChanged : .inputCapabilitiesLost(removed))
        }, failure: { [weak self] error in
            Task { @MainActor [weak self] in await self?.finish(error) }
        })
        canRecordScreen = try remote.supports("com.apple.coredevice.feature.screenrecording")
        framebuffer.frame = contentView.bounds
        contentView.addSubview(framebuffer)
        try await displayGeometry.start { [weak self] result in
            guard let self, !self.stopped else { return }
            switch result {
            case .success(let display):
                self.framebuffer.update(display: display)
                self.updateAttributes()
                self.events?(.inputGeometryChanged)
            case .failure(let error):
                self.framebuffer.update(display: nil)
                Task { @MainActor [weak self] in await self?.finish(error) }
            }
        }
        try checkConnection()
        observation = Task { [weak self, stream] in
            for await event in stream.events {
                guard let self, !self.stopped else { return }
                await self.receive(event)
            }
        }
        try await stream.start(sourceID: source.uniqueID)
        try Task.checkCancellation()
        try checkConnection()
        // A running capture session establishes the screen; a delivered frame separately proves pixels arrived.
        events(.connected)
    }

    func captureScreenshot() async throws -> CGImage {
        guard !stopped, !finished else {
            throw CLIError.unavailable("remote-screen-connection", "Connect the device screen before capturing it.")
        }
        return try await stream.snapshot()
    }

    func send(_ input: RemoteScreenInput) async throws { try await self.input.send(input) }
    func startRecording(displayUniqueID: String?) async throws -> any RemoteScreenRecordingHandle {
        try await remote.startRecording(displayUniqueID: displayUniqueID)
    }
    func releaseInputs() async throws { try await input.releaseInputs() }
    func inputLocations(atWindowPoint point: CGPoint, clampingToDisplay: Bool) -> RemoteDeviceInputLocations? {
        framebuffer.inputLocations(at: contentView.convert(point, from: nil), from: contentView,
                                   clampingToDisplay: clampingToDisplay)
    }

    func stop() async throws {
        stopped = true
        displayGeometry.stop()
        events = nil
        await capabilityObservation.stop()
        canRecordScreen = false
        defer { framebuffer.removeFromSuperview() }
        var failure: (any Error)?
        do { try await disconnect() } catch { failure = error }
        // Stopping the stream finishes its events, which ends the observation.
        let task = observation
        observation = nil
        await task?.value
        if let failure { throw failure }
    }

    private func receive(_ event: RemoteScreenCaptureStream.Event) async {
        switch event {
        case .frameSize(let size):
            frameSize = size
            framebuffer.withoutAnimations { video.drawableSize = size }
            await stream.acceptDrawableSize(size)
            guard !stopped else { return }
            updateAttributes()
            events?(.frameReceived)
        case .failure(let error):
            await finish(error)
        }
    }

    private func updateAttributes() {
        guard let frameSize else { return }
        let value = Self.videoAttributes(frame: frameSize, display: framebuffer.display)
        guard value != attributes else { return }
        attributes = value
        framebuffer.update(attributes: value)
        events?(.attributes(value))
    }

    /// Describes a whole captured frame in the framebuffer's video terms.
    ///
    /// Screen-capture frames follow the interface orientation, as the media stream's reported
    /// orientation does. A frame that keeps the display's native shape during a quarter turn
    /// is still unrotated, so it is shown without counter-rotation.
    static func videoAttributes(frame: CGSize, display: RemoteScreenFramebuffer.Display?) -> RemoteDeviceVideoAttributes {
        var orientation = RemoteDeviceOrientation.portrait
        if let display {
            let turns = ((Int((display.angle / 90).rounded()) % 4) + 4) % 4
            let keepsNativeShape = (frame.width > frame.height) == (display.size.width > display.size.height)
            switch turns {
            case 1 where !keepsNativeShape: orientation = .landscapeLeft
            case 2: orientation = .portraitUpsideDown
            case 3 where !keepsNativeShape: orientation = .landscapeRight
            default: break
            }
        }
        return RemoteDeviceVideoAttributes(aspectRatio: frame, contentsRect: CGRect(x: 0, y: 0, width: 1, height: 1),
            scaleFactor: display.map { Float(max(frame.width, frame.height) / max($0.size.width, $0.size.height)) } ?? 1,
            orientation: orientation)
    }

    private func finish(_ error: any Error) async {
        guard !stopped, !finished else { return }
        finished = true
        failure = error
        await capabilityObservation.stop()
        displayGeometry.stop()
        var failure = error
        do { try await disconnect() }
        catch { failure = RemoteDeviceScreenSession.combining(failure, cleanup: error) }
        self.failure = failure
        events?(.failure(failure))
    }

    private func checkConnection() throws {
        if stopped { throw CancellationError() }
        if finished {
            throw failure ?? CLIError.unavailable("remote-screen-disconnected", "The remote screen connection ended.")
        }
    }

    private func disconnect() async throws {
        if let disconnecting { try await disconnecting.value; return }
        let task = Task { [self] in
            await stream.stop()
            try await input.stop()
        }
        disconnecting = task
        defer { disconnecting = nil }
        try await task.value
    }
}
