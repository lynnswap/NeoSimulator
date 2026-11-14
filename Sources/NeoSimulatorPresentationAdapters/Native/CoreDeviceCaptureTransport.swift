import AppKit
import Metal
import NeoSimulatorDeviceIO
import NeoSimulatorKit

/// Shows a physical device's primary display from CoreDevice video or a chosen Mac capture source,
/// and sends input to the same device through its HID services.
@MainActor
package final class CoreDeviceCaptureTransport: RemoteScreenTransport {
    private let remote: CoreDeviceRemoteScreenDevice
    private let input: CoreDeviceScreenInput
    private let capabilityObservation: RemoteScreenInputCapabilityObservation
    private let displayGeometry: CoreDeviceDisplayGeometry
    private let video = CAMetalLayer()
    private let framebuffer: RemoteScreenFramebuffer
    private let stream: RemoteScreenCaptureStream
    private let contentView: NSView
    private enum Source {
        case capture(RemoteScreenCaptureSource, CoreDeviceScreenConnection?)
        case media(CoreDeviceNetworkVideo)

        var connection: CoreDeviceScreenConnection? {
            switch self {
            case .capture(_, let connection): connection
            case .media(let network): network.connection
            }
        }
    }
    private let source: Source
    private var events: (@MainActor (RemoteScreenTransportEvent) -> Void)?
    /// A report that only turns the shown display of a device with several built-in displays, held because
    /// such a device turns its orientation just before its video changes to another display.
    private var heldTurn: RemoteScreenFramebuffer.Display?
    private var turnHold: Task<Void, Never>?
    /// Longer than the video took to change display after the orientation turned on an iPhone Duo (0.08 to
    /// 0.12 seconds).
    private static let turnHoldDuration = Duration.milliseconds(250)
    private var observation: Task<Void, Never>?
    private var disconnecting: Task<Void, any Error>?
    private var attributes: RemoteDeviceVideoAttributes?
    private var frameSize: CGSize?
    private var stopped = false
    private var finished = false
    private var failure: (any Error)?
    package var inputCapabilities: Set<RemoteDeviceInputKind> {
        framebuffer.isReady ? capabilityObservation.capabilities : capabilityObservation.capabilities.subtracting([.pointer, .digitizer])
    }
    package var canCaptureScreenshot: Bool { !stopped && !finished && frameSize != nil }
    /// Receives each frame of the device's own video on the receiver's queue, with the part of it that shows a
    /// display and, when the frame shows which, the built-in display that it carries. Set before `start`.
    package var decodedFrames: (@Sendable (CVPixelBuffer, _ visible: CGSize, _ display: UInt32?) -> Void)?
    /// CoreDevice's identifier of the display that the screen shows.
    package var shownDisplay: UInt32? { framebuffer.display?.identifier }
    package private(set) var canRecordScreen = false

    package convenience init(
        remote: CoreDeviceRemoteScreenDevice, capture: RemoteScreenCaptureSource,
        connection: CoreDeviceScreenConnection? = nil, contentView: NSView
    ) async throws {
        try await self.init(remote: remote, source: .capture(capture, connection), contentView: contentView)
    }

    package convenience init(
        remote: CoreDeviceRemoteScreenDevice, connection: CoreDeviceScreenConnection, contentView: NSView
    ) async throws {
        try await self.init(
            remote: remote, source: .media(CoreDeviceNetworkVideo(connection: connection)), contentView: contentView)
    }

    private init(remote: CoreDeviceRemoteScreenDevice, source: Source, contentView: NSView) async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw RemoteScreenError.unavailable("remote-screen-metal", "This Mac has no Metal device to show the device screen.")
        }
        self.remote = remote
        self.source = source
        self.contentView = contentView
        let input = CoreDeviceScreenInput(remote: remote)
        self.input = input
        capabilityObservation = RemoteScreenInputCapabilityObservation(source: try await CoreDeviceInputCapabilitySource(remote: remote),
            read: { try input.capabilities() }, invalidateInputs: { input.discardInputs(for: $0) })
        displayGeometry = try await CoreDeviceDisplayGeometry(remote: remote)
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

    package func start(events: @escaping @MainActor (RemoteScreenTransportEvent) -> Void) async throws {
        try checkConnection()
        self.events = events
        if case .capture = source { try await RemoteScreenCaptureStream.authorize() }
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
            case .success(let display): self.receive(display)
            case .failure(let error):
                self.turnHold?.cancel()
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
        switch source {
        case .capture(let source, _): try await stream.start(sourceID: source.uniqueID)
        case .media(let network):
            network.decodedFrames = decodedFrames
            try await network.start(renderer: stream, carriedDisplay: { [weak self] identifier in
                guard let self, !self.stopped, !self.finished else { return }
                self.displayGeometry.videoDisplay = identifier
            }) { [weak self] error in
                Task { @MainActor [weak self] in await self?.finish(error) }
            }
        }
        try Task.checkCancellation()
        try checkConnection()
        // An active source establishes the screen; a delivered frame separately proves pixels arrived.
        events(.connected)
    }

    package func captureScreenshot() async throws -> CGImage {
        guard !stopped, !finished else {
            throw RemoteScreenError.unavailable("remote-screen-connection", "Connect the device screen before capturing it.")
        }
        return try await stream.snapshot()
    }

    package func send(_ input: RemoteScreenInput) async throws { try await self.input.send(input) }
    package func startRecording(displayUniqueID: String?) async throws -> any RemoteScreenRecordingHandle {
        try await remote.startRecording(displayUniqueID: displayUniqueID)
    }
    package func releaseInputs() async throws { try await input.releaseInputs() }
    package func inputLocations(atWindowPoint point: CGPoint, clampingToDisplay: Bool) -> RemoteDeviceInputLocations? {
        framebuffer.inputLocations(at: point, from: nil, clampingToDisplay: clampingToDisplay)
    }

    package func stop() async throws {
        stopped = true
        turnHold?.cancel()
        displayGeometry.stop()
        events = nil
        await capabilityObservation.stop()
        canRecordScreen = false
        defer { framebuffer.removeFromSuperview() }
        var failure: (any Error)?
        do { try await disconnect() } catch { failure = error }
        // Stopping the stream finishes its events at once, which ends the observation even if its session has not closed.
        let task = observation
        observation = nil
        await task?.value
        if let failure { throw failure }
    }

    /// Takes a report of the display that the device shows. On a device with several built-in displays, a
    /// report that only turns the shown display waits for the video: when the video then changes display, that
    /// display is shown at its own angle and the first display never turns.
    private func receive(_ display: RemoteScreenFramebuffer.Display?) {
        if case .media = source, let display, display.builtIn.count > 1, let shown = framebuffer.display,
           display.identifier == shown.identifier, display.angle != shown.angle {
            heldTurn = display
            if turnHold == nil {
                turnHold = Task { [weak self] in
                    try? await Task.sleep(for: Self.turnHoldDuration)
                    guard let self, !Task.isCancelled, !self.stopped, !self.finished else { return }
                    self.turnHold = nil
                    if let held = self.heldTurn {
                        self.heldTurn = nil
                        self.show(held)
                    }
                }
            }
            return
        }
        turnHold?.cancel()
        turnHold = nil
        heldTurn = nil
        show(display)
    }

    private func show(_ display: RemoteScreenFramebuffer.Display?) {
        let previous = framebuffer.display
        if case .media(let network) = source, let pixelSize = display?.frame?.pixelSize,
           pixelSize != previous?.frame?.pixelSize || display?.builtIn != previous?.builtIn {
            network.update(displaySize: pixelSize, builtIn: display?.builtIn ?? [])
        }
        framebuffer.update(display: display)
        input.touchDisplay = display.flatMap { $0.isPrimary ? nil : $0.identifier }
        updateAttributes()
        // The angle that follows belongs to this display.
        if let shown = display?.frame, shown != previous?.frame { events?(.displayShown(shown)) }
        if let display { events?(.displayAngle(display.angle)) }
        events?(.inputGeometryChanged)
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

    /// Describes a captured frame's orientation. Capture follows the interface orientation;
    /// a frame retaining native dimensions during a quarter turn needs no counter-rotation.
    package static func videoAttributes(frame: CGSize, display: RemoteScreenFramebuffer.Display?) -> RemoteDeviceVideoAttributes {
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

    private func finish(_ error: (any Error)?) async {
        guard !stopped, !finished else { return }
        finished = true
        failure = error
        turnHold?.cancel()
        await capabilityObservation.stop()
        displayGeometry.stop()
        var failure = error
        do { try await disconnect() }
        catch { failure = failure.map { RemoteDeviceScreenSession.combining($0, cleanup: error) } ?? error }
        self.failure = failure
        if let failure { events?(.failure(failure)) } else { events?(.disconnected) }
    }

    private func checkConnection() throws {
        if stopped { throw CancellationError() }
        if finished {
            throw failure ?? RemoteScreenError.unavailable("remote-screen-disconnected", "The remote screen connection ended.")
        }
    }

    private func disconnect() async throws {
        if let disconnecting { try await disconnecting.value; return }
        let task = Task { [self] in
            var failure: (any Error)?
            if case .media(let network) = source { await network.stop() }
            do { try await stream.stop() } catch { failure = error }
            do { try await input.stop() } catch {
                failure = failure.map { RemoteDeviceScreenSession.combining($0, cleanup: error) } ?? error
            }
            do { try await source.connection?.stop() } catch {
                failure = failure.map { RemoteDeviceScreenSession.combining($0, cleanup: error) } ?? error
            }
            if let failure { throw failure }
        }
        disconnecting = task
        defer { disconnecting = nil }
        try await task.value
    }
}
