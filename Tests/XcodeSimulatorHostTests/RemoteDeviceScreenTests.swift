import AppKit
import ImageIO
import UniformTypeIdentifiers
import Testing
import IOKit
import ABIBridge
@_spi(NeoSimulator) @testable import XcodeSimulatorHost

@MainActor
@Suite
struct RemoteDeviceScreenTests {
    @Test func postureCommandsUseIOKitSerializationAndConfirmedAngleThresholds() throws {
        for posture in DevicePosture.allCases {
            let data = try DevicePosturePayload.serialize(posture)
            let value = try data.withUnsafeBytes { bytes in
                let base = try #require(bytes.baseAddress)
                return IOCFUnserializeBinary(base.assumingMemoryBound(to: CChar.self), bytes.count, nil, 0, nil)
            }
            let dictionary = try #require(value as? [String: Any])
            #expect(dictionary["provider"] as? String == "com.apple.Virtualization.VirtualMachines")
            #expect(dictionary["source"] as? String == "hinge-slider-control")
            #expect(dictionary["type"] as? String == "range")
            #expect(dictionary["value"] as? Double == posture.degrees)
        }
        #expect(DevicePosture.confirmed(angle: 0) == .closed)
        #expect(DevicePosture.confirmed(angle: 15) == .partiallyOpen)
        #expect(DevicePosture.confirmed(angle: 175) == .partiallyOpen)
        #expect(DevicePosture.confirmed(angle: 180) == .open)
        #expect(DevicePosture.confirmed(angle: nil) == nil && DevicePosture.confirmed(angle: .nan) == nil)
        #expect(DevicePosturePayload.supports(hardwareModel: "V68AP", features: DevicePosturePayload.features))
        #expect(!DevicePosturePayload.supports(hardwareModel: "v68ap", features: DevicePosturePayload.features.subtracting(["com.apple.coredevice.feature.monitormotion"])))
        #expect(!DevicePosturePayload.supports(hardwareModel: "v99", features: DevicePosturePayload.features))
    }

    @Test func postureSelectionFollowsFeedbackAndPreservesSendFailures() async throws {
        let source = PostureFixtureTransport()
        let id = DeviceInventoryID.coreDevice("command-id-differs-from-udid")
        var receivedID: DeviceInventoryID?
        let model = DevicePostureModel(deviceID: id) { identifier in receivedID = identifier; return source }
        try await model.start()
        await source.waitForObservation()
        #expect(receivedID == id && model.confirmedPosture == nil && model.isSupported)
        await source.emit(0)
        source.holdsSend = true
        let sending = Task { try await model.select(.open) }
        await source.waitForSend()
        #expect(model.confirmedPosture == .closed && !model.canSelect)
        await source.emit(130)
        source.finishSend()
        try await sending.value
        #expect(model.confirmedPosture == .partiallyOpen && model.canSelect)
        await source.emit(180)
        #expect(model.confirmedPosture == .open)
        source.holdsSend = false
        source.sendError = ScreenFixtureError.stream
        await #expect(throws: ScreenFixtureError.self) { try await model.select(.closed) }
        #expect(model.lastError is ScreenFixtureError && model.confirmedPosture == .open && model.canSelect)
        await source.emit(nil)
        #expect(model.confirmedPosture == nil)
        source.updates.finish(throwing: ScreenFixtureError.stream)
        await source.waitForFinish()
        #expect(model.state == .failed && model.lastError is ScreenFixtureError && !model.canSelect)
        await model.stop()
        #expect(source.finished && model.state == .stopped && !model.canSelect)
        source.updates.yield(0)
        #expect(model.confirmedPosture == nil)
    }

    @Test func stoppingPostureControlsDrainsACommandAndItsObservation() async throws {
        let source = PostureFixtureTransport()
        let model = DevicePostureModel(deviceID: .simulator(udid: "simulator-udid", deviceSetPath: nil)) { _ in source }
        try await model.start()
        await source.waitForObservation()
        source.holdsSend = true
        let sending = Task { try await model.select(.open) }
        await source.waitForSend()
        let stopping = Task { await model.stop() }
        await source.waitForFinish()
        source.finishSend()
        await #expect(throws: CancellationError.self) { try await sending.value }
        await stopping.value
        #expect(model.state == .stopped && !model.isSending && source.sent.isEmpty)
    }

    @Test func cancellingPostureStartupDoesNotSubscribeToALateTransport() async throws {
        let source = PostureFixtureTransport()
        let began = AsyncStream<Void>.makeStream()
        var resume: CheckedContinuation<(any DevicePostureTransport)?, Never>?
        let model = DevicePostureModel(deviceID: .coreDevice("command-id")) { _ in
            await withCheckedContinuation { resume = $0; began.continuation.yield(()) }
        }
        let starting = Task { try await model.start() }
        var events = began.stream.makeAsyncIterator()
        await events.next()
        starting.cancel()
        resume?.resume(returning: source)
        await #expect(throws: CancellationError.self) { try await starting.value }
        #expect(model.state == .stopped && !model.canSelect && !source.didBegin)
        await model.stop()
    }

    @Test func retainsCommandIdentityAndReportsPixelsSeparatelyFromAnActiveTransport() async throws {
        let transport = ScreenFixtureTransport()
        let device = try device()
        var receivedID: String?
        let session = RemoteDeviceScreenSession(device: device) { target, _, _ in
            receivedID = target.identifier
            return transport
        }
        var exposedInputWhileConnecting = false
        var observedCapabilities: Set<RemoteDeviceInputKind> = []
        var lostServices: [Set<RemoteDeviceInputKind>] = []
        session.onInputCapabilitiesLost = { lostServices.append($0) }
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
        #expect(observedCapabilities == [.keyboard] && lostServices.isEmpty)
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
        let session = RemoteDeviceScreenSession(device: try device()) { _, _, _ in transport }
        var visible: Set<RemoteDeviceInputKind> = []
        var lostServices: [Set<RemoteDeviceInputKind>] = []
        session.onInputCapabilitiesLost = { lostServices.append($0) }
        session.onStateChange = { visible = session.inputCapabilities }
        try await session.start()
        #expect(visible.isEmpty)
        await source.change(to: [.keyboard, .digitizer, .pointer, .button])
        #expect(session.nativeInputView != nil && visible == [.keyboard, .digitizer, .pointer, .button])
        try await session.sendKey(4, state: .down)
        try await session.sendButton(usagePage: 12, usage: 48, state: .down)
        #expect(transport.pressed.buttons.count == 1)
        try await session.sendTouch(at: CGPoint(x: 0.5, y: 0.5), phase: .began)
        try await session.sendPointerButton(0, phase: .down, at: CGPoint(x: 0.2, y: 0.3))
        #expect(transport.pressed.touch != nil && transport.pressed.pointerButtons.count == 1)
        await source.change(to: [.keyboard, .pointer])
        #expect(visible == [.keyboard, .pointer] && transport.pressed.touch == nil && transport.pressed.buttons.isEmpty)
        #expect(lostServices == [[.digitizer, .button]])
        #expect(transport.downKeys == [4] && transport.pressed.pointerButtons.count == 1)
        await source.change(to: [.keyboard, .digitizer, .pointer, .button])
        #expect(visible.contains(.digitizer) && visible.contains(.button))
        #expect(transport.pressed.touch == nil && transport.pressed.buttons.isEmpty && lostServices == [[.digitizer, .button]])
        let restored: Set<RemoteDeviceInputKind> = [.keyboard, .digitizer, .pointer, .button]
        await source.change(to: restored)
        #expect(lostServices == [[.digitizer, .button]] && transport.downKeys == [4])
        await source.buffer(snapshots: [[], restored])
        #expect(try source.read() == restored && visible == restored)
        #expect(lostServices == [[.digitizer, .button], restored])
        #expect(transport.downKeys.isEmpty && transport.pressed.pointerButtons.isEmpty)
        try await session.stop()
        #expect(source.finished && transport.downKeys.isEmpty && transport.pressed.pointerButtons.isEmpty)
        let reads = source.reads
        source.lateChange()
        #expect(source.reads == reads && session.state == .stopped && session.inputCapabilities.isEmpty)
    }

    @Test func capabilitySnapshotFailureReachesTheSessionAndStoppingDrainsTheObserver() async throws {
        let source = ScreenCapabilityFixtureSource()
        let transport = ScreenFixtureTransport(capabilitySource: source)
        let session = RemoteDeviceScreenSession(device: try device()) { _, _, _ in transport }
        try await session.start()
        let error: any Error = await withCheckedContinuation { received in
            session.onStateChange = {
                if let error = session.lastError { received.resume(returning: error) }
            }
            source.malformedSnapshot = true
            source.events.yield([.keyboard])
        }
        #expect((error as? CLIError)?.identifier == "remote-input-snapshot" && session.state == .failed)
        session.onStateChange = nil
        try await session.stop()
        #expect(source.finished)
    }

    @Test func cancellationDisconnectsAStartThatCompletesAfterTheWindowStops() async throws {
        let source = ScreenCapabilityFixtureSource()
        let transport = ScreenFixtureTransport(suspendStart: true, capabilitySource: source)
        let session = RemoteDeviceScreenSession(device: try device()) { _, _, _ in transport }
        let start = Task { try await session.start() }
        await transport.waitUntilStarting()
        try await session.stop()
        do { try await start.value; Issue.record("A stopped start completed successfully") }
        catch { #expect(error is CancellationError) }
        #expect(transport.closed && session.state == .stopped && source.finished)
        let reads = source.reads
        source.lateChange()
        #expect(source.reads == reads)
        transport.emit(.connected)
        #expect(session.state == .stopped)
    }

    @Test func callerCancellationAndCleanupFailureRemainVisibleTogether() async throws {
        let transport = ScreenFixtureTransport(suspendStart: true, failCleanup: true)
        let session = RemoteDeviceScreenSession(device: try device()) { _, _, _ in transport }
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
        let session = RemoteDeviceScreenSession(device: try device()) { _, _, _ in
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

    @Test func appResizeReplacesOneTransportAndRetiresOldFramesAndInputs() async throws {
        let primary = ScreenFixtureTransport()
        let dedicated = ScreenFixtureTransport()
        dedicated.automaticFrames = true
        dedicated.inputCapabilities = [.digitizer]
        let restored = ScreenFixtureTransport()
        let resize = ScreenResizeFixtureTransport()
        var targets: [String?] = []
        let session = RemoteDeviceScreenSession(device: try device(), makeResizeTransport: { _ in resize }) { _, _, target in
            targets.append(target)
            return targets.count == 1 ? primary : target == nil ? restored : dedicated
        }
        try await session.start()
        await wait(session) { session.canResizeApp }
        try await session.sendKey(4, state: .down)
        try await session.startAppResize(size: CGSize(width: 400, height: 600))
        #expect(primary.closed && primary.downKeys.isEmpty)
        #expect(targets == [nil, resize.assertion.displayUniqueID])
        #expect(session.isResizingApp && session.hasReceivedFrame && session.canResizeApp)
        primary.emit(.attributes(RemoteDeviceVideoAttributes(aspectRatio: .zero, contentsRect: .zero, scaleFactor: 0, orientation: nil)))
        primary.emit(.failure(ScreenFixtureError.stream))
        #expect(session.state == .connected && session.videoAttributes?.scaleFactor == 2)
        try await session.sendTouch(at: CGPoint(x: 0.2, y: 0.7), phase: .began)
        #expect(dedicated.pressed.touch != nil && primary.pressed.touch == nil)
        session.resizeApp(to: CGSize(width: 900, height: 100))
        var adjustments = resize.assertion.adjusted.stream.makeAsyncIterator()
        #expect(await adjustments.next() == CGSize(width: 800, height: 200))
        resize.assertion.emit(size: CGSize(width: 700, height: 300))
        await wait(session) { session.appResizeGeometry?.resolvedSize == CGSize(width: 700, height: 300) }
        resize.assertion.adjustmentError = ScreenFixtureError.stream
        session.resizeApp(to: CGSize(width: 400, height: 400))
        await wait(session) { session.lastError is ScreenFixtureError }
        #expect(session.state == .connected && session.isResizingApp)
        try await session.stopAppResize()
        #expect(dedicated.closed && dedicated.pressed.touch == nil && resize.assertion.invalidated)
        #expect(targets == [nil, resize.assertion.displayUniqueID, nil])
        #expect(session.state == .connected && !session.isResizingApp && !session.hasReceivedFrame && session.videoAttributes == nil)
        dedicated.emit(.frameReceived)
        #expect(!session.hasReceivedFrame)
        try await session.stop()
    }

    @Test func resizeWaitsForDecodedPixelsAndAcceptedCaptureBeforeReplacingTheDisplay() async throws {
        let primary = ScreenFixtureTransport()
        let dedicated = ScreenFixtureTransport()
        let resize = ScreenResizeFixtureTransport()
        let capture = ScreenFixtureGate()
        primary.onCapture = { await capture.hold() }
        let session = RemoteDeviceScreenSession(device: try device(), makeResizeTransport: { _ in resize }) { _, _, target in
            target == nil ? primary : dedicated
        }
        try await session.start()
        await wait(session) { session.canResizeApp }
        let screenshot = Task { try await session.captureScreenshot() }
        await capture.wait()
        let switching = Task { try await session.startAppResize(size: CGSize(width: 400, height: 600)) }
        await wait(session) { session.isChangingDisplay }
        #expect(!primary.closed && !session.canCaptureScreenshot && session.inputCapabilities.isEmpty)
        capture.resume()
        _ = try await screenshot.value
        await dedicated.waitUntilStarting()
        #expect(session.isChangingDisplay && !session.canRecordScreen)
        dedicated.emit(.frameReceived)
        #expect(session.isChangingDisplay)
        dedicated.emit(.attributes(.init(aspectRatio: CGSize(width: 400, height: 600), contentsRect: CGRect(x: 0, y: 0, width: 1, height: 1), scaleFactor: 2, orientation: .portrait)))
        try await switching.value
        #expect(!session.isChangingDisplay && session.hasReceivedFrame)
        try await session.stop()
    }

    @Test func recordingUsesTheResizeIdentityAndBlocksBothExplicitSwitches() async throws {
        let primary = ScreenFixtureTransport()
        let dedicated = ScreenFixtureTransport()
        dedicated.automaticFrames = true
        let restored = ScreenFixtureTransport()
        let handle = ScreenResizeRecordingHandle()
        primary.recordingHandle = handle
        dedicated.recordingHandle = handle
        let resize = ScreenResizeFixtureTransport()
        var count = 0
        let session = RemoteDeviceScreenSession(device: try device(), makeResizeTransport: { _ in resize }) { _, _, target in
            count += 1
            return count == 1 ? primary : target == nil ? restored : dedicated
        }
        try await session.start()
        await wait(session) { session.canResizeApp }
        try await session.startRecording()
        await #expect(throws: CLIError.self) { try await session.startAppResize(size: CGSize(width: 400, height: 600)) }
        #expect(!primary.closed && handle.stops == 0)
        try await session.stopRecording()
        session.discardCompletedRecording()
        try await session.startAppResize(size: CGSize(width: 400, height: 600))
        await #expect(throws: CLIError.self) { try await session.startRecording(displayUniqueID: "another-display") }
        try await session.startRecording()
        #expect(dedicated.recordedDisplay == resize.assertion.displayUniqueID && !session.canResizeApp)
        await #expect(throws: CLIError.self) { try await session.stopAppResize() }
        #expect(!dedicated.closed && handle.stops == 1)
        handle.failStop = true
        let drain = ScreenFixtureGate()
        session.prepareForDisplayChange = { await drain.hold() }
        let releases = dedicated.releases
        resize.assertion.guestInvalidates()
        await drain.wait()
        #expect(session.isChangingDisplay && !dedicated.closed && dedicated.releases == releases && handle.stops == 1)
        drain.resume()
        await wait(session) { session.state == .failed && !session.isChangingDisplay }
        #expect(session.hasUnfinishedRecording && !dedicated.closed)
        session.prepareForDisplayChange = nil
        handle.failStop = false
        try await session.stopRecording()
        try await session.stopAppResize()
        #expect(!session.hasUnfinishedRecording && session.completedRecording != nil && dedicated.closed)
        try await session.stop()
    }

    @Test func failedResizeCleanupKeepsTheAssertionAndTransportUntilRetry() async throws {
        let primary = ScreenFixtureTransport()
        let dedicated = ScreenFixtureTransport()
        let restored = ScreenFixtureTransport()
        let resize = ScreenResizeFixtureTransport()
        dedicated.failStart = true
        dedicated.failCleanup = true
        var count = 0
        let session = RemoteDeviceScreenSession(device: try device(), makeResizeTransport: { _ in resize }) { _, _, target in
            count += 1
            return count == 1 ? primary : target == nil ? restored : dedicated
        }
        try await session.start()
        await wait(session) { session.canResizeApp }
        do {
            try await session.startAppResize(size: CGSize(width: 400, height: 600))
            Issue.record("Failed dedicated startup was accepted")
        } catch {
            #expect(error.localizedDescription.contains("fixture stream failed") && error.localizedDescription.contains("fixture cleanup failed"))
        }
        #expect(session.state == .failed && session.isResizingApp && !resize.assertion.invalidated && count == 2)
        dedicated.failCleanup = false
        try await session.stopAppResize()
        #expect(dedicated.closed && resize.assertion.invalidated && session.state == .connected && count == 3)
        try await session.stop()
    }

    @Test func cancellationAfterAssertionAcquisitionUnwindsAndRestoresPrimary() async throws {
        let primary = ScreenFixtureTransport()
        let dedicated = ScreenFixtureTransport(suspendStart: true)
        let restored = ScreenFixtureTransport()
        let resize = ScreenResizeFixtureTransport()
        var count = 0
        let session = RemoteDeviceScreenSession(device: try device(), makeResizeTransport: { _ in resize }) { _, _, target in
            count += 1
            return count == 1 ? primary : target == nil ? restored : dedicated
        }
        try await session.start()
        await wait(session) { session.canResizeApp }
        let switching = Task { try await session.startAppResize(size: CGSize(width: 400, height: 600)) }
        await dedicated.waitUntilStarting()
        switching.cancel()
        dedicated.finishStarting()
        await #expect(throws: CancellationError.self) { try await switching.value }
        #expect(dedicated.closed && resize.assertion.invalidated && session.state == .connected && !session.isResizingApp)
        try await session.stop()
    }

    @Test func screenShutdownCancelsAndDrainsADedicatedTransportThatIsStillStarting() async throws {
        let primary = ScreenFixtureTransport()
        let dedicated = ScreenFixtureTransport(suspendStart: true)
        let resize = ScreenResizeFixtureTransport()
        let session = RemoteDeviceScreenSession(device: try device(), makeResizeTransport: { _ in resize }) { _, _, target in
            target == nil ? primary : dedicated
        }
        try await session.start()
        await wait(session) { session.canResizeApp }
        let switching = Task { try await session.startAppResize(size: CGSize(width: 400, height: 600)) }
        await dedicated.waitUntilStarting()
        try await session.stop()
        await #expect(throws: CancellationError.self) { try await switching.value }
        #expect(dedicated.closed && resize.assertion.invalidated && session.state == .stopped && !session.isResizingApp)
    }

    @Test func aFailedPrimaryRestorationDoesNotReportTheScreenAsConnected() async throws {
        let primary = ScreenFixtureTransport()
        let dedicated = ScreenFixtureTransport()
        dedicated.automaticFrames = true
        let restored = ScreenFixtureTransport()
        restored.failStart = true
        let resize = ScreenResizeFixtureTransport()
        var count = 0
        let session = RemoteDeviceScreenSession(device: try device(), makeResizeTransport: { _ in resize }) { _, _, target in
            count += 1
            return count == 1 ? primary : target == nil ? restored : dedicated
        }
        try await session.start()
        await wait(session) { session.canResizeApp }
        try await session.startAppResize(size: CGSize(width: 400, height: 600))
        await #expect(throws: ScreenFixtureError.self) { try await session.stopAppResize() }
        #expect(session.state == .failed && !session.isResizingApp && dedicated.closed && resize.assertion.invalidated)
        #expect(session.inputCapabilities.isEmpty && !session.canCaptureScreenshot)
        try await session.stop()
        #expect(restored.closed && session.state == .stopped)
    }

    @Test(arguments: [false, true])
    func shutdownReclaimsAPrimaryTransportReturnedAfterCancellation(failCleanup: Bool) async throws {
        let primary = ScreenFixtureTransport()
        let dedicated = ScreenFixtureTransport(suspendStart: true)
        let restored = ScreenFixtureTransport(failCleanup: failCleanup)
        let resize = ScreenResizeFixtureTransport()
        let restoration = ScreenFixtureGate()
        var count = 0
        let session = RemoteDeviceScreenSession(device: try device(), makeResizeTransport: { _ in resize }) { _, _, target in
            count += 1
            if count == 1 { return primary }
            if target != nil { return dedicated }
            await restoration.hold()
            return restored
        }
        try await session.start()
        await wait(session) { session.canResizeApp }
        let switching = Task { try await session.startAppResize(size: CGSize(width: 400, height: 600)) }
        await dedicated.waitUntilStarting()
        switching.cancel()
        dedicated.finishStarting()
        await restoration.wait()
        let shutdown = Task { try await session.stop() }
        await wait(session) { session.state == .stopping }
        restoration.resume()
        if failCleanup {
            do { try await shutdown.value; Issue.record("Cleanup failure was lost") }
            catch {
                #expect(error.localizedDescription.contains("fixture cleanup failed"))
                #expect(error.localizedDescription.contains(CancellationError().localizedDescription))
            }
        } else {
            try await shutdown.value
            #expect(session.state == .stopped)
        }
        await #expect(throws: CancellationError.self) { try await switching.value }
        #expect(restored.releases > 0)
        if failCleanup {
            #expect(session.state == .failed && !restored.closed && session.nativeInputView != nil)
            #expect(session.lastError?.localizedDescription.contains("fixture cleanup failed") == true)
            restored.failCleanup = false
            try await session.stop()
        }
        #expect(session.state == .stopped && restored.closed && session.nativeInputView == nil)
        restored.emit(.connected)
        #expect(session.state != .connected && session.nativeInputView == nil)
    }

    @Test(arguments: [false, true])
    func optionalResizePreparationFailureKeepsThePrimaryScreen(observationFailure: Bool) async throws {
        let primary = ScreenFixtureTransport()
        let resize = ScreenResizeFixtureTransport()
        resize.eligibilityError = ScreenFixtureError.stream
        let session = RemoteDeviceScreenSession(device: try device(), makeResizeTransport: { _ in
            if !observationFailure { throw ScreenFixtureError.stream }
            return resize
        }) { _, _, _ in primary }
        try await session.start()
        #expect(session.state == .connected && !primary.closed && session.canCaptureScreenshot)
        #expect(session.inputCapabilities == [.keyboard] && !session.supportsAppResize)
        #expect(session.lastError is ScreenFixtureError)
        if session.state == .connected {
            try await session.sendKey(4, state: .down)
            _ = try await session.captureScreenshot()
            #expect(primary.downKeys == [4])
        }
        try await session.stop()
    }

    @Test func reconnectSubscribesToTheNewResizeEligibilitySource() async throws {
        let first = ScreenResizeFixtureTransport()
        let next = ScreenResizeFixtureTransport()
        next.initialEligibility = .unavailable
        var connections = 0
        let session = RemoteDeviceScreenSession(device: try device(), makeResizeTransport: { _ in
            connections += 1
            return connections == 1 ? first : next
        }) { _, _, _ in ScreenFixtureTransport() }
        try await session.start()
        await wait(session) { session.canResizeApp }
        try await session.stop()
        #expect(!session.supportsAppResize && !session.canResizeApp)
        try await session.start()
        #expect(connections == 2 && session.supportsAppResize && !session.canResizeApp)
        next.eligibilityUpdates.continuation.yield(.eligible)
        await wait(session) { session.canResizeApp }
        try await session.stop()
    }

    @Test func nativeTouchscreenDescriptorsPreserveANonLegacyDisplayIdentity() async throws {
        try CoreDeviceRemoteScreenDevice.load("/Library/Developer/PrivateFrameworks/CoreDeviceUtilities.framework/Versions/A/CoreDeviceUtilities")
        let runtime = ABIRuntime.shared
        let descriptor = try await CoreDeviceDisplayInput.descriptor(displayID: 0x35, uniqueID: "resized-app-display", runtime: runtime)
        let descriptorType = try runtime.resolveAndWait(.swift(.type("CoreDevice.HIDServiceDescriptor")))
        let serviceIDType = try runtime.resolveAndWait(.swift(.type("CoreDevice.HIDServiceID")))
        let abis: [NativeSwiftType: NativeType] = [descriptorType: try .opaque(named: descriptorType.name),
            serviceIDType: try .opaque(named: serviceIDType.name)]
        let serviceID = try descriptorType.resolveAndWait(.swift(.getter("serviceID", as: (() -> NativeSwiftValue).self,
            valueABIs: abis, receiverABI: abis[descriptorType])))
        let uniqueID = try descriptorType.resolveAndWait(.swift(.getter("displayIdentifier", as: (() -> String?).self,
            valueABIs: abis, receiverABI: abis[descriptorType])))
        let displayID = try serviceIDType.resolveAndWait(.swift(.getter("touchscreenDisplayID", as: (() -> UInt32?).self,
            valueABIs: abis, receiverABI: abis[serviceIDType])))
        let actual = try unsafe displayID.unsafeInvoke(on: serviceID.unsafeInvoke(on: descriptor))
        #expect(actual == 0x35, "Actual display ID: \(String(describing: actual))")
        #expect(try unsafe uniqueID.unsafeInvoke(on: descriptor) == "resized-app-display")
    }

    @Test func dedicatedReportsRoundTripThroughTheInstalledUniversalHIDValueAPIs() throws {
        let runtime = ABIRuntime.shared
        let builder = try CoreDeviceDigitizerReports(runtime: runtime)
        let digitizer = try runtime.resolveAndWait(.swift(.type("UniversalHID.DigitizerReport")))
        let contact = try runtime.resolveAndWait(.swift(.type("UniversalHID.DigitizerContact")))
        let abis = builder.abis
        let make = try digitizer.resolveAndWait(.swift(.initializer("init(_report:)", as: ((NativeSwiftValue) -> NativeSwiftValue).self, valueABIs: abis)))
        let receiver = abis[digitizer]!
        let count = try digitizer.resolveAndWait(.swift(.getter("contactCount", as: (() -> UInt8).self, valueABIs: abis, receiverABI: receiver)))
        let readContact = try digitizer.resolveAndWait(.swift(.method("contact(atIndex:)", as: ((Int) -> NativeSwiftValue).self, valueABIs: abis, receiverABI: receiver)))
        let contactReceiver = abis[contact]!
        let x = try contact.resolveAndWait(.swift(.getter("x", as: (() -> Double).self, valueABIs: abis, receiverABI: contactReceiver)))
        let y = try contact.resolveAndWait(.swift(.getter("y", as: (() -> Double).self, valueABIs: abis, receiverABI: contactReceiver)))
        let touch = try contact.resolveAndWait(.swift(.getter("touch", as: (() -> Bool).self, valueABIs: abis, receiverABI: contactReceiver)))
        let range = try contact.resolveAndWait(.swift(.getter("range", as: (() -> Bool).self, valueABIs: abis, receiverABI: contactReceiver)))
        let indexValue = try contact.resolveAndWait(.swift(.getter("index", as: (() -> Int).self, valueABIs: abis, receiverABI: contactReceiver)))
        let identity = try digitizer.resolveAndWait(.swift(.method("contactIdentity(atIndex:)", as: ((Int) -> UInt8?).self, valueABIs: abis, receiverABI: receiver)))
        let edge = try digitizer.resolveAndWait(.swift(.method("contactSwipeLeft(atIndex:)", as: ((Int) -> Bool?).self, valueABIs: abis, receiverABI: receiver)))
        for phase in [RemoteDeviceTouchPhase.began, .ended] {
            let payload = try builder.make(point: CGPoint(x: 0.25, y: 0.75), second: CGPoint(x: 0.8, y: 0.2), phase: phase, edge: .left)
            let value = try unsafe make.unsafeInvoke(payload)
            #expect(try unsafe count.unsafeInvoke(on: value) == 2)
            for index in 0..<2 {
                let valueContact = try unsafe readContact.unsafeInvoke(on: value, index)
                let expected = index == 0 ? CGPoint(x: 0.25, y: 0.75) : CGPoint(x: 0.8, y: 0.2)
                #expect(abs(try unsafe x.unsafeInvoke(on: valueContact) - Double(expected.x)) < 0.001)
                #expect(abs(try unsafe y.unsafeInvoke(on: valueContact) - Double(expected.y)) < 0.001)
                #expect(try unsafe touch.unsafeInvoke(on: valueContact) == (phase != .ended))
                #expect(try unsafe range.unsafeInvoke(on: valueContact) == (phase != .ended))
                #expect(try unsafe indexValue.unsafeInvoke(on: valueContact) == index + 1)
                #expect(try unsafe identity.unsafeInvoke(on: value, index) == UInt8(index + 1))
                #expect(try unsafe edge.unsafeInvoke(on: value, index) == true)
            }
        }
    }

    @Test func failedHIDServiceRemovalKeepsTheOwnedServiceForCleanupRetry() async throws {
        var removes = 0
        var resets = 0
        let service = CoreDeviceDisplayInput(send: { _, _, _, _ in }, reset: {
            resets += 1
            if resets == 1 { throw ScreenFixtureError.stream }
        }, remove: {
            removes += 1
            if removes == 1 { throw ScreenFixtureError.cleanup }
        })
        do { try await service.stop(); Issue.record("Cleanup failure was lost") }
        catch { #expect(error.localizedDescription.contains("fixture stream failed") && error.localizedDescription.contains("fixture cleanup failed")) }
        try await service.stop()
        #expect(removes == 2 && resets == 2)
        #expect(throws: CLIError.self) { try service.send(.zero, second: nil, phase: .began, edge: .none) }
        try await service.stop()
        #expect(removes == 2)
    }

    private func wait(_ session: RemoteDeviceScreenSession, until condition: @escaping @MainActor () -> Bool) async {
        if condition() { return }
        await withCheckedContinuation { continuation in
            session.onStateChange = {
                if condition() { session.onStateChange = nil; continuation.resume() }
            }
        }
    }

    private func device() throws -> CoreDeviceDevice {
        let data = Data(#"{"result":{"devices":[{"identifier":"command-identifier","properties":{"hardware":{"reality":"physical","udid":"hardware-identifier"},"state":{"name":"Fixture Device"},"connection":{"state":"connected"}},"capabilities":[]}]}}"#.utf8)
        return try #require(CoreDeviceInventoryDecoder.decode(data).first)
    }
}

@MainActor
private final class PostureFixtureTransport: DevicePostureTransport {
    private let stream: AsyncThrowingStream<Double?, any Error>
    let updates: AsyncThrowingStream<Double?, any Error>.Continuation
    private var began: CheckedContinuation<Void, Never>?
    private(set) var didBegin = false
    private var sentEvent: CheckedContinuation<Void, Never>?
    private var didSend = false
    private var didFinish: CheckedContinuation<Void, Never>?
    private var processed: CheckedContinuation<Void, Never>?
    private var pendingSend: CheckedContinuation<Void, Never>?
    var holdsSend = false
    var sendError: (any Error)?
    private(set) var sent: [DevicePosture] = []
    private(set) var finished = false

    init() { (stream, updates) = AsyncThrowingStream.makeStream() }

    func observe(_ update: @escaping @MainActor (Double?) -> Void) async throws {
        didBegin = true
        began?.resume(); began = nil
        defer { finished = true; didFinish?.resume(); didFinish = nil }
        for try await angle in stream {
            update(angle)
            processed?.resume(); processed = nil
        }
    }

    func send(_ posture: DevicePosture) async throws {
        didSend = true
        sentEvent?.resume(); sentEvent = nil
        if holdsSend { await withCheckedContinuation { pendingSend = $0 } }
        try Task.checkCancellation()
        if let sendError { throw sendError }
        sent.append(posture)
    }

    func emit(_ angle: Double?) async { await withCheckedContinuation { processed = $0; updates.yield(angle) } }
    func waitForObservation() async { if !didBegin { await withCheckedContinuation { began = $0 } } }
    func waitForSend() async { if !didSend { await withCheckedContinuation { sentEvent = $0 } } }
    func waitForFinish() async { if !finished { await withCheckedContinuation { didFinish = $0 } } }
    func finishSend() { pendingSend?.resume(); pendingSend = nil }
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
    var automaticFrames = false
    var failStart = false
    var onCapture: (() async -> Void)?
    var recordingHandle: ScreenResizeRecordingHandle?
    var canRecordScreen: Bool { recordingHandle != nil }
    private(set) var recordedDisplay: String?
    func startRecording(displayUniqueID: String?) async throws -> any RemoteScreenRecordingHandle {
        recordedDisplay = displayUniqueID
        return try #require(recordingHandle)
    }
    func captureScreenshot() async throws -> CGImage {
        await onCapture?()
        let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try #require(context.makeImage())
    }
    private let suspendStart: Bool
    var failCleanup: Bool
    private(set) var closed = false
    private(set) var releases = 0
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
            try observation.start(update: { [weak self] removed in
                guard let self else { return }
                self.inputCapabilities = self.capabilityObservation?.capabilities ?? []
                self.events?(removed.isEmpty ? .inputGeometryChanged : .inputCapabilitiesLost(removed))
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
        waitingForStart?.resume()
        waitingForStart = nil
        if failStart { throw ScreenFixtureError.stream }
        events(.connected)
        if automaticFrames {
            events(.attributes(.init(aspectRatio: CGSize(width: 400, height: 600), contentsRect: CGRect(x: 0, y: 0, width: 1, height: 1), scaleFactor: 2, orientation: .portrait)))
            events(.frameReceived)
        }
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
        releases += 1
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

private enum ScreenCapabilityFixture: Hashable {
    case hid(RemoteDeviceInputKind), unrelated
}

@MainActor
private final class ScreenCapabilityFixtureSource: RemoteScreenInputCapabilitySource {
    private let stream: AsyncThrowingStream<Set<RemoteDeviceInputKind>, any Error>
    let events: AsyncThrowingStream<Set<RemoteDeviceInputKind>, any Error>.Continuation
    private var values: Set<RemoteDeviceInputKind> = []
    private var changed: CheckedContinuation<Void, Never>?
    private var pendingChanges = 0
    private var onChange: (@MainActor (Set<RemoteDeviceInputKind>) -> Void)?
    var malformedSnapshot = false
    private(set) var reads = 0
    private(set) var finished = false

    init() { (stream, events) = AsyncThrowingStream.makeStream() }
    func read() throws -> Set<RemoteDeviceInputKind> {
        reads += 1
        return values
    }
    func follow(onSubscribed: @escaping @MainActor () throws -> Void,
                onChange: @escaping @MainActor (Set<RemoteDeviceInputKind>) -> Void) async throws {
        self.onChange = onChange
        defer { finished = true }
        try onSubscribed()
        for try await snapshot in stream {
            defer {
                if pendingChanges > 0 {
                    pendingChanges -= 1
                    if pendingChanges == 0 { changed?.resume(); changed = nil }
                }
            }
            let raw: Any = malformedSnapshot ? [0] : Set(snapshot.map(ScreenCapabilityFixture.hid)).union([.unrelated])
            let values = try CoreDeviceInputCapabilitySource.hashableCapabilities(in: raw)
            let kinds = Set(CoreDeviceScreenInput.features.keys.filter { values.contains(AnyHashable(ScreenCapabilityFixture.hid($0))) })
            onChange(kinds)
        }
    }
    func change(to value: Set<RemoteDeviceInputKind>) async { await buffer(snapshots: [value]) }
    func buffer(snapshots: [Set<RemoteDeviceInputKind>]) async {
        values = snapshots.last ?? values
        await withCheckedContinuation { continuation in
            changed = continuation
            pendingChanges = snapshots.count
            for snapshot in snapshots { events.yield(snapshot) }
        }
    }
    func lateChange() { onChange?([]) }
}

@MainActor
private final class ScreenResizeFixtureTransport: AppResizeTransport {
    let assertion = ScreenResizeFixtureSession()
    let eligibilityUpdates = AsyncThrowingStream<AppResizeEligibility, any Error>.makeStream()
    var initialEligibility = AppResizeEligibility.eligible
    var eligibilityError: (any Error)?
    func eligibility() async throws -> AsyncThrowingStream<AppResizeEligibility, any Error> {
        if let eligibilityError { throw eligibilityError }
        eligibilityUpdates.continuation.yield(initialEligibility)
        return eligibilityUpdates.stream
    }
    func start(size: CGSize, cornerRadius: CGFloat) async throws -> any AppResizeSession { assertion }
}

@MainActor
private final class ScreenResizeFixtureSession: AppResizeSession {
    let displayUniqueID = "dedicated-non-primary-display"
    var geometry = AppResizeGeometry(minimumSize: CGSize(width: 200, height: 200), maximumSize: CGSize(width: 800, height: 1000), preferredSize: CGSize(width: 400, height: 600), resolvedSize: CGSize(width: 400, height: 600), cornerRadius: 12)
    private let stream: AsyncThrowingStream<AppResizeGeometry, any Error>
    private let continuation: AsyncThrowingStream<AppResizeGeometry, any Error>.Continuation
    private var invalidation: CheckedContinuation<Void, Never>?
    private(set) var invalidated = false
    let adjusted = AsyncStream<CGSize>.makeStream()
    var adjustmentError: (any Error)?
    init() { (stream, continuation) = AsyncThrowingStream.makeStream() }
    func updates() throws -> AsyncThrowingStream<AppResizeGeometry, any Error> { stream }
    func adjust(size: CGSize, cornerRadius: CGFloat) async throws {
        if let adjustmentError { throw adjustmentError }
        adjusted.continuation.yield(size)
    }
    func emit(size: CGSize) { geometry.resolvedSize = size; continuation.yield(geometry) }
    func awaitInvalidation() async throws {
        if !invalidated { await withCheckedContinuation { invalidation = $0 } }
    }
    func invalidate() throws {
        invalidated = true
        continuation.finish()
        invalidation?.resume(); invalidation = nil
    }
    func guestInvalidates() { try? invalidate() }
}

@MainActor
private final class ScreenResizeRecordingHandle: RemoteScreenRecordingHandle {
    var failStop = false
    private(set) var stops = 0
    func stop() async throws -> RemoteDeviceRecording {
        stops += 1
        if failStop { throw ScreenFixtureError.cleanup }
        return RemoteDeviceRecording(data: Data([1]), duration: 3, codec: "fixture")
    }
}

@MainActor
private final class ScreenFixtureGate {
    private var entered = false
    private var entering: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    func hold() async {
        await withCheckedContinuation {
            entered = true; release = $0; entering?.resume(); entering = nil
        }
    }
    func wait() async { if !entered { await withCheckedContinuation { entering = $0 } } }
    func resume() { release?.resume(); release = nil }
}
