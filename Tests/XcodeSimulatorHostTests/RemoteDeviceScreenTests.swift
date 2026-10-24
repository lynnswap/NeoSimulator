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
        session.onStateChange = {
            if session.state == .connecting && session.nativeInputView != nil { exposedInputWhileConnecting = true }
        }
        try await session.start()
        #expect(exposedInputWhileConnecting)
        #expect(receivedID == "command-identifier")
        #expect(session.deviceID == .coreDevice("command-identifier"))
        #expect(session.state == .connected && !session.hasReceivedFrame)
        #expect(session.canCaptureScreenshot)
        let screenshot = try await session.captureScreenshot()
        #expect(screenshot.width == 1 && screenshot.height == 1)
        transport.emit(.attributes(RemoteDeviceVideoAttributes(aspectRatio: CGSize(width: 2, height: 1),
            contentsRect: CGRect(x: 0, y: 0, width: 1, height: 1), scaleFactor: 2, orientation: .landscapeRight)))
        #expect(session.videoAttributes?.orientation == .landscapeRight)
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
        let capture = RemoteScreenFrameCapture()
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

        let waiting = Task { try await capture.capture { capture.fail(ScreenFixtureError.stream) } }
        do { _ = try await waiting.value; Issue.record("The stream failure was lost") }
        catch { #expect(error as? ScreenFixtureError == .stream) }

        var pendingCapture: Task<CGImage, any Error>?
        await withCheckedContinuation { (started: CheckedContinuation<Void, Never>) in
            pendingCapture = Task { try await capture.capture { started.resume() } }
        }
        let task = try #require(pendingCapture)
        task.cancel()
        do { _ = try await task.value; Issue.record("Capture cancellation was lost") }
        catch { #expect(error is CancellationError) }
        let retry = try await capture.capture { capture.receive(data as Data) }
        #expect(retry.width == 2)

        let expired = RemoteScreenFrameCapture(timeout: .milliseconds(1))
        do { _ = try await expired.capture {}; Issue.record("A missing frame never timed out") }
        catch { #expect((error as? CLIError)?.identifier == "remote-screen-capture-timeout") }
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
    let inputCapabilities: Set<RemoteDeviceInputKind> = [.keyboard]
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
    private(set) var downKeys: Set<UInt16> = []
    private var events: (@MainActor (RemoteScreenTransportEvent) -> Void)?
    private var pendingStart: CheckedContinuation<Void, any Error>?
    private var waitingForStart: CheckedContinuation<Void, Never>?
    private var didStart = false

    init(suspendStart: Bool = false, failCleanup: Bool = false) {
        self.suspendStart = suspendStart
        self.failCleanup = failCleanup
    }

    func start(events: @escaping @MainActor (RemoteScreenTransportEvent) -> Void) async throws {
        self.events = events
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
        if case .key(let key, let state) = input {
            if state == .down { downKeys.insert(key) } else { downKeys.remove(key) }
        }
    }

    func releaseInputs() async throws {
        if failCleanup { throw ScreenFixtureError.cleanup }
        downKeys = []
    }

    func stop() async throws {
        let continuation = pendingStart
        pendingStart = nil
        continuation?.resume(throwing: CancellationError())
        try await releaseInputs()
        closed = true
    }

    func emit(_ event: RemoteScreenTransportEvent) { events?(event) }
}
