import AppKit
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import XcodeSimulatorHost

@MainActor
@Suite
struct RemoteDeviceScreenTests {
    @Test func retainsCommandIdentityAndReportsPixelsSeparatelyFromAnActiveTransport() async throws {
        let transport = ScreenFixtureTransport()
        let device = try device()
        var receivedID: String?
        let session = RemoteDeviceScreenSession(device: device) { target, _ in
            receivedID = target.identifier
            return transport
        }
        var exposedInputWhileConnecting = false
        var observedCapabilities: Set<RemoteDeviceInputKind> = []
        session.onStateChange = {
            if session.state == .connecting && session.nativeInputView != nil { exposedInputWhileConnecting = true }
            observedCapabilities = session.inputCapabilities
        }
        try await session.start()
        #expect(exposedInputWhileConnecting)
        #expect(receivedID == "command-identifier")
        #expect(session.deviceID == .coreDevice("command-identifier"))
        #expect(session.state == .connected && !session.hasReceivedFrame)
        #expect(session.canCaptureScreenshot)
        let screenshot = try await session.captureScreenshot()
        #expect(screenshot.width == 1 && screenshot.height == 1)
        transport.inputCapabilities = [.keyboard, .pointer, .digitizer]
        transport.emit(.attributes(RemoteDeviceVideoAttributes(aspectRatio: CGSize(width: 2, height: 1),
            contentsRect: CGRect(x: 0, y: 0, width: 1, height: 1), scaleFactor: 2, orientation: .landscapeRight)))
        #expect(session.videoAttributes?.orientation == .landscapeRight)
        #expect(observedCapabilities == [.keyboard, .pointer, .digitizer])
        transport.inputCapabilities = [.keyboard]
        transport.emit(.inputGeometryChanged)
        #expect(observedCapabilities == [.keyboard])
        transport.emit(.frameReceived)
        #expect(session.hasReceivedFrame)
        try await session.sendKey(4, state: .down)
        #expect(transport.downKeys == [4])
        try await session.releaseInputs()
        #expect(transport.downKeys.isEmpty && !transport.closed && session.state == .connected)
        try await session.sendKey(4, state: .down)
        try await session.stop()
        #expect(transport.downKeys.isEmpty && transport.closed)
        #expect(session.state == .stopped && session.inputCapabilities.isEmpty && !session.canCaptureScreenshot)
        transport.emit(.failure(ScreenFixtureError.stream))
        #expect(session.state == .stopped && session.lastError == nil)
    }

    @Test func nativeCapabilityChangesReachTheSessionAndRetireOnlyTheLostInputService() async throws {
        let source = ScreenCapabilityFixtureSource()
        let transport = ScreenFixtureTransport(capabilitySource: source)
        let session = RemoteDeviceScreenSession(device: try device()) { _, _ in transport }
        var visible: Set<RemoteDeviceInputKind> = []
        session.onStateChange = { visible = session.inputCapabilities }
        try await session.start()
        #expect(visible.isEmpty)
        await source.change(to: [.keyboard, .digitizer, .pointer])
        #expect(visible == [.keyboard, .digitizer, .pointer])
        try await session.sendKey(4, state: .down)
        try await session.sendTouch(at: CGPoint(x: 0.5, y: 0.5), phase: .began)
        try await session.sendPointerButton(0, phase: .down, at: CGPoint(x: 0.2, y: 0.3))
        #expect(transport.pressed.touch != nil && transport.pressed.pointerButtons.count == 1)
        await source.change(to: [.keyboard, .pointer])
        #expect(visible == [.keyboard, .pointer] && transport.pressed.touch == nil)
        #expect(transport.downKeys == [4] && transport.pressed.pointerButtons.count == 1)
        await source.change(to: [.keyboard, .digitizer, .pointer])
        #expect(visible.contains(.digitizer) && transport.pressed.touch == nil)
        try await session.stop()
        #expect(source.finished && transport.downKeys.isEmpty && transport.pressed.pointerButtons.isEmpty)
        let reads = source.reads
        try source.lateChange()
        #expect(source.reads == reads && session.state == .stopped && session.inputCapabilities.isEmpty)
    }

    @Test func capabilityReadFailureReachesTheSessionAndStoppingDrainsTheObserver() async throws {
        let source = ScreenCapabilityFixtureSource()
        let transport = ScreenFixtureTransport(capabilitySource: source)
        let session = RemoteDeviceScreenSession(device: try device()) { _, _ in transport }
        try await session.start()
        let error: any Error = await withCheckedContinuation { received in
            session.onStateChange = {
                if let error = session.lastError { received.resume(returning: error) }
            }
            source.failRead = true
            source.events.yield([.keyboard])
        }
        #expect(error as? ScreenFixtureError == .stream && session.state == .failed)
        session.onStateChange = nil
        try await session.stop()
        #expect(source.finished)
    }

    @Test func cancellationDisconnectsAStartThatCompletesAfterTheWindowStops() async throws {
        let transport = ScreenFixtureTransport(suspendStart: true)
        let session = RemoteDeviceScreenSession(device: try device()) { _, _ in transport }
        let start = Task { try await session.start() }
        await transport.waitUntilStarting()
        try await session.stop()
        do { try await start.value; Issue.record("A stopped start completed successfully") }
        catch { #expect(error is CancellationError) }
        #expect(transport.closed && session.state == .stopped)
        transport.emit(.connected)
        #expect(session.state == .stopped)
    }

    @Test func callerCancellationAndCleanupFailureRemainVisibleTogether() async throws {
        let transport = ScreenFixtureTransport(suspendStart: true, failCleanup: true)
        let session = RemoteDeviceScreenSession(device: try device()) { _, _ in transport }
        let start = Task { try await session.start() }
        await transport.waitUntilStarting()
        start.cancel()
        transport.finishStarting()
        do { try await start.value; Issue.record("Cancellation was lost") }
        catch {
            #expect(error.localizedDescription.contains("fixture cleanup failed"))
            #expect(session.state == .failed)
        }
        transport.failCleanup = false
        try await session.stop()
        #expect(transport.closed && session.state == .stopped)
    }

    @Test func retryClosesTheFailedTransportBeforeOpeningItsReplacement() async throws {
        let old = ScreenFixtureTransport()
        let replacement = ScreenFixtureTransport()
        var attempts = 0
        let session = RemoteDeviceScreenSession(device: try device()) { _, _ in
            attempts += 1
            if attempts > 1 { #expect(old.closed) }
            return attempts == 1 ? old : replacement
        }
        try await session.start()
        old.emit(.failure(ScreenFixtureError.stream))
        #expect(session.state == .failed)
        try await session.start()
        #expect(session.state == .connected && session.lastError == nil && old.closed)
        try await session.stop()
        #expect(replacement.closed)
    }

    @Test func frameCaptureDecodesImageIODataAndReleasesWaitersOnFailureOrCancellation() async throws {
        let noDeadline: RemoteScreenFrameCapture.ScheduleTimeout = { _, _ in {} }
        let capture = RemoteScreenFrameCapture(scheduleTimeout: noDeadline)
        let context = try #require(CGContext(data: nil, width: 2, height: 3, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        let image = try await capture.capture { capture.receive(data as Data) }
        #expect(image.width == 2 && image.height == 3)
        do {
            _ = try await capture.capture { capture.receive(Data([0, 1])) }
            Issue.record("Invalid image data was accepted")
        } catch { #expect((error as? CLIError)?.identifier == "remote-screen-image") }

        let interrupted = RemoteScreenFrameCapture(scheduleTimeout: noDeadline)
        let waiting = Task { try await interrupted.capture { interrupted.fail(ScreenFixtureError.stream) } }
        do { _ = try await waiting.value; Issue.record("The stream failure was lost") }
        catch { #expect(error as? ScreenFixtureError == .stream) }

        let canceled = RemoteScreenFrameCapture(scheduleTimeout: noDeadline)
        var pendingCapture: Task<CGImage, any Error>?
        await withCheckedContinuation { (started: CheckedContinuation<Void, Never>) in
            pendingCapture = Task { try await canceled.capture { started.resume() } }
        }
        let task = try #require(pendingCapture)
        task.cancel()
        do { _ = try await task.value; Issue.record("Capture cancellation was lost") }
        catch { #expect(error is CancellationError) }
        let retry = Task.immediate { try await canceled.capture { canceled.receive(data as Data) } }
        canceled.receive(data as Data)
        #expect(try await retry.value.width == 2)
    }

    @Test func startupAndCanceledRepliesDrainBeforeANewCaptureRequestIsSent() async throws {
        let capture = RemoteScreenFrameCapture(scheduleTimeout: { _, _ in {} })
        func png(width: Int) throws -> Data {
            let context = try #require(CGContext(data: nil, width: width, height: 1, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            let data = NSMutableData()
            let output = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(output, try #require(context.makeImage()), nil)
            #expect(CGImageDestinationFinalize(output))
            return data as Data
        }
        var sends: [String] = []
        try await withCheckedThrowingContinuation { (started: CheckedContinuation<Void, any Error>) in
            do {
                try capture.requestInitialFrame { sends.append("startup"); started.resume() }
            } catch { started.resume(throwing: error) }
        }
        let startupReply = try png(width: 1)
        let canceledReply = try png(width: 3)
        var firstSent: CheckedContinuation<Void, Never>?
        let first = Task.immediate { try await capture.capture { sends.append("first"); firstSent?.resume() } }
        #expect(sends == ["startup"])
        await withCheckedContinuation { sent in
            firstSent = sent
            capture.receive(startupReply)
        }
        capture.receive(try png(width: 2))
        #expect(try await first.value.width == 2)

        var canceling: Task<CGImage, any Error>?
        await withCheckedContinuation { (sent: CheckedContinuation<Void, Never>) in
            canceling = Task.immediate { try await capture.capture { sends.append("canceled"); sent.resume() } }
        }
        let canceled = try #require(canceling)
        canceled.cancel()
        do { _ = try await canceled.value; Issue.record("Capture cancellation was lost") }
        catch { #expect(error is CancellationError) }
        var retrySent: CheckedContinuation<Void, Never>?
        let retry = Task.immediate { try await capture.capture { sends.append("retry"); retrySent?.resume() } }
        await withCheckedContinuation { sent in
            retrySent = sent
            capture.receive(canceledReply)
        }
        capture.receive(try png(width: 4))
        #expect(try await retry.value.width == 4)
        #expect(sends == ["startup", "first", "canceled", "retry"])
    }

    @Test func aNativeTimeoutRequiresReconnectBeforeRetryingOnTheSameStream() async throws {
        var deadline: (@MainActor () -> Void)?
        let capture = RemoteScreenFrameCapture(scheduleTimeout: { _, action in
            deadline = action
            return { deadline = nil }
        })
        var sends = 0
        var waiting: Task<CGImage, any Error>?
        await withCheckedContinuation { (sent: CheckedContinuation<Void, Never>) in
            waiting = Task.immediate { try await capture.capture { sends += 1; sent.resume() } }
        }
        let pending = try #require(waiting)
        let expire = try #require(deadline)
        expire()
        do { _ = try await pending.value; Issue.record("A missing frame never timed out") }
        catch { #expect((error as? CLIError)?.identifier == "remote-screen-capture-timeout") }
        capture.receive(Data())
        do {
            _ = try await capture.capture { sends += 1 }
            Issue.record("A late untagged reply could be reused after a timeout")
        } catch { #expect((error as? CLIError)?.identifier == "remote-screen-capture-reconnect") }
        #expect(sends == 1)
    }

    @Test func sharedFramebufferConvertsTheDisplayedSurfaceWithoutTreatingVideoCropAsHIDRegion() throws {
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 600, height: 600))
        let framebuffer = RemoteScreenFramebuffer(frame: container.bounds)
        container.addSubview(framebuffer)
        framebuffer.update(display: .init(size: CGSize(width: 200, height: 400), angle: 90))
        #expect(framebuffer.inputLocations(at: CGPoint(x: 60, y: 420), from: container, clampingToDisplay: false) == nil)
        framebuffer.update(attributes: RemoteDeviceVideoAttributes(aspectRatio: CGSize(width: 800, height: 400),
            contentsRect: CGRect(x: 0.125, y: 0.25, width: 0.5, height: 0.5), scaleFactor: 2, orientation: .landscapeLeft))
        // The landscape display occupies x=0...600, y=150...450. AppKit's container is not flipped.
        let topLeft = try #require(framebuffer.inputLocations(at: CGPoint(x: 60, y: 420), from: container,
                                                             clampingToDisplay: false))
        #expect(abs(topLeft.touch.x - 0.1) < 0.0001)
        #expect(abs(topLeft.touch.y - 0.9) < 0.0001)
        #expect(abs(topLeft.pointer.x - 0.1) < 0.0001)
        #expect(abs(topLeft.pointer.y - 0.1) < 0.0001)
        #expect(framebuffer.inputLocations(at: CGPoint(x: 300, y: 550), from: container, clampingToDisplay: false) == nil)
        let release = try #require(framebuffer.inputLocations(at: CGPoint(x: 300, y: 550), from: container,
                                                             clampingToDisplay: true))
        #expect(abs(release.pointer.y) < 0.0001)
        framebuffer.update(display: .init(size: CGSize(width: 200, height: 400), angle: 0))
        let portrait = try #require(framebuffer.inputLocations(at: CGPoint(x: 180, y: 540), from: container,
                                                              clampingToDisplay: false))
        #expect(abs(portrait.touch.x - 0.1) < 0.0001)
        #expect(abs(portrait.touch.y - 0.1) < 0.0001)
        #expect(portrait.pointer == portrait.touch)
        framebuffer.update(display: nil)
        #expect(framebuffer.inputLocations(at: CGPoint(x: 300, y: 300), from: container, clampingToDisplay: true) == nil)
    }

    private func device() throws -> CoreDeviceDevice {
        let data = Data(#"{"result":{"devices":[{"identifier":"command-identifier","properties":{"hardware":{"reality":"physical","udid":"hardware-identifier"},"state":{"name":"Fixture Device"},"connection":{"state":"connected"}},"capabilities":[]}]}}"#.utf8)
        return try #require(CoreDeviceInventoryDecoder.decode(data).first)
    }
}

private enum ScreenFixtureError: LocalizedError {
    case stream, cleanup
    var errorDescription: String? { self == .stream ? "fixture stream failed" : "fixture cleanup failed" }
}

@MainActor
private final class ScreenFixtureTransport: RemoteScreenTransport {
    var inputCapabilities: Set<RemoteDeviceInputKind> = [.keyboard]
    let nativeInputView: NSView? = NSView()
    var canCaptureScreenshot: Bool { !closed }
    func captureScreenshot() async throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try #require(context.makeImage())
    }
    private let suspendStart: Bool
    var failCleanup: Bool
    private(set) var closed = false
    private(set) var pressed = RemoteScreenPressedInputs()
    var downKeys: Set<UInt16> { pressed.keys }
    private let capabilitySource: ScreenCapabilityFixtureSource?
    private var capabilityObservation: RemoteScreenInputCapabilityObservation?
    private var events: (@MainActor (RemoteScreenTransportEvent) -> Void)?
    private var pendingStart: CheckedContinuation<Void, any Error>?
    private var waitingForStart: CheckedContinuation<Void, Never>?
    private var didStart = false

    init(suspendStart: Bool = false, failCleanup: Bool = false, capabilitySource: ScreenCapabilityFixtureSource? = nil) {
        self.suspendStart = suspendStart
        self.failCleanup = failCleanup
        self.capabilitySource = capabilitySource
        if capabilitySource != nil { inputCapabilities = [] }
    }

    func start(events: @escaping @MainActor (RemoteScreenTransportEvent) -> Void) async throws {
        self.events = events
        if let source = capabilitySource {
            let observation = RemoteScreenInputCapabilityObservation(source: source, read: { try source.read() },
                invalidateInputs: { [weak self] in self?.pressed.discard(for: $0) })
            capabilityObservation = observation
            try observation.start(update: { [weak self] in
                guard let self else { return }
                self.inputCapabilities = self.capabilityObservation?.capabilities ?? []
                self.events?(.inputGeometryChanged)
            }, failure: { [weak self] in self?.events?(.failure($0)) })
        }
        didStart = true
        if suspendStart {
            try await withCheckedThrowingContinuation { continuation in
                pendingStart = continuation
                waitingForStart?.resume()
                waitingForStart = nil
            }
        }
        events(.connected)
    }

    func waitUntilStarting() async {
        if didStart { return }
        await withCheckedContinuation { waitingForStart = $0 }
    }

    func finishStarting() {
        let continuation = pendingStart
        pendingStart = nil
        continuation?.resume()
    }

    func send(_ input: RemoteScreenInput) async throws {
        pressed.record(input)
    }

    func releaseInputs() async throws {
        if failCleanup { throw ScreenFixtureError.cleanup }
        pressed = RemoteScreenPressedInputs()
    }

    func stop() async throws {
        await capabilityObservation?.stop()
        let continuation = pendingStart
        pendingStart = nil
        continuation?.resume(throwing: CancellationError())
        try await releaseInputs()
        closed = true
    }

    func emit(_ event: RemoteScreenTransportEvent) { events?(event) }
}

@MainActor
private final class ScreenCapabilityFixtureSource: RemoteScreenInputCapabilitySource {
    private let stream: AsyncThrowingStream<Set<RemoteDeviceInputKind>, any Error>
    let events: AsyncThrowingStream<Set<RemoteDeviceInputKind>, any Error>.Continuation
    private var values: Set<RemoteDeviceInputKind> = []
    private var changed: CheckedContinuation<Void, Never>?
    private var onChange: (@MainActor () throws -> Void)?
    var failRead = false
    private(set) var reads = 0
    private(set) var finished = false

    init() { (stream, events) = AsyncThrowingStream.makeStream() }
    func read() throws -> Set<RemoteDeviceInputKind> {
        reads += 1
        if failRead { throw ScreenFixtureError.stream }
        return values
    }
    func follow(onChange: @escaping @MainActor () throws -> Void) async throws {
        self.onChange = onChange
        defer { finished = true }
        try onChange()
        for try await value in stream {
            values = value
            defer { changed?.resume(); changed = nil }
            try onChange()
        }
    }
    func change(to value: Set<RemoteDeviceInputKind>) async {
        await withCheckedContinuation { changed = $0; events.yield(value) }
    }
    func lateChange() throws { try onChange?() }
}
