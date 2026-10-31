import AppKit
import Carbon
import CoreVideo
import ImageIO
import Metal
import UniformTypeIdentifiers
import Testing
import IOKit
import XPC
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
        // UniversalHIDKit places the pointer of a mouse movement by mapping its location with the transform, as the
        // display's pointer input places it.
        func expectPointerTransform(of locations: RemoteDeviceInputLocations, _ pointers: [(CGPoint, CGPoint)]) {
            for (point, pointer) in pointers {
                let mapped = point.applying(locations.pointerTransform)
                #expect(abs(mapped.x - pointer.x) < 0.0001 && abs(mapped.y - pointer.y) < 0.0001, "\(point): \(mapped)")
            }
        }
        expectPointerTransform(of: topLeft, [(CGPoint(x: 60, y: 420), CGPoint(x: 0.1, y: 0.1)),
                                             (CGPoint(x: 60, y: 180), CGPoint(x: 0.1, y: 0.9)),
                                             (CGPoint(x: 540, y: 180), CGPoint(x: 0.9, y: 0.9))])
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
        // The portrait display occupies x=150...450, y=0...600.
        expectPointerTransform(of: portrait, [(CGPoint(x: 180, y: 540), CGPoint(x: 0.1, y: 0.1)),
                                              (CGPoint(x: 420, y: 60), CGPoint(x: 0.9, y: 0.9))])
        framebuffer.update(display: nil)
        #expect(framebuffer.inputLocations(at: CGPoint(x: 300, y: 300), from: container, clampingToDisplay: true) == nil)
    }

    @Test func capturedFramesInTheInterfaceOrientationStayUprightOnTheRotatedDisplay() throws {
        // The rotated 200×400 display fills 600×300 of the container, or 300×600 upside down.
        let cases: [(angle: CGFloat, frame: CGSize, topLeft: CGPoint)] = [
            (90, CGSize(width: 800, height: 400), CGPoint(x: 0, y: 450)),
            (270, CGSize(width: 800, height: 400), CGPoint(x: 0, y: 450)),
            (180, CGSize(width: 400, height: 800), CGPoint(x: 150, y: 600)),
        ]
        for (angle, frame, topLeft) in cases {
            let container = NSView(frame: CGRect(x: 0, y: 0, width: 600, height: 600))
            let video = CALayer()
            let framebuffer = RemoteScreenFramebuffer(frame: container.bounds, video: video)
            container.addSubview(framebuffer)
            let display = RemoteScreenFramebuffer.Display(size: CGSize(width: 200, height: 400), angle: angle)
            framebuffer.update(display: display)
            framebuffer.update(attributes: CoreDeviceCaptureTransport.videoAttributes(frame: frame, display: display))
            let corner = try #require(framebuffer.layer).convert(CGPoint(x: 0, y: frame.height), from: video)
            #expect(abs(corner.x - topLeft.x) < 0.001 && abs(corner.y - topLeft.y) < 0.001, "Angle \(angle): \(corner)")
        }
        // A frame still in the display's native shape is not counter-rotated during a quarter turn.
        let turning = RemoteScreenFramebuffer.Display(size: CGSize(width: 200, height: 400), angle: 90)
        #expect(CoreDeviceCaptureTransport.videoAttributes(frame: CGSize(width: 400, height: 800), display: turning).orientation == .portrait)
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: RemoteDeviceChromeResources.deviceKitDirectory.appendingPathComponent("chrome_map.plist").path),
                   "Requires DeviceKit's installed device chrome"))
    func theDeviceFrameSurroundsAnUnavailableScreenAndKeepsItsInputAlignedWhenTurned() async throws {
        try await CoreDeviceDisplayGeometry.loadRuntime()
        // An iPhone Air reports the chrome that DeviceKit's map also gives its product type.
        let reported = RemoteDeviceDisplay(pixelSize: CGSize(width: 1260, height: 2736), scale: 3,
            chromeIdentifier: "com.apple.dt.devicekit.chrome.phone12", maskIdentifier: "1506CF9E-8F5F-48D9-91CA-E852368519A5")
        let unreported = RemoteDeviceDisplay(pixelSize: reported.pixelSize, scale: reported.scale, chromeIdentifier: nil, maskIdentifier: nil)
        let resources = try #require(try RemoteDeviceChromeResources(display: reported, productType: nil))
        #expect(try RemoteDeviceChromeResources(display: unreported, productType: "iPhone18,4") == resources)
        // Its side button sends the same consumer usage as the screen's Lock control.
        #expect(resources.mask != nil && resources.buttons["power"] == RemoteDeviceChromeButton(usagePage: 0x0c, usage: 0x30))
        let session = RemoteDeviceScreenSession(device: try device(), readDisplay: { _ in reported }) { _, _, _ in
            throw RemoteScreenCaptureSourceError(reason: .disconnected)
        }
        let frame = try #require(session.contentView as? RemoteDeviceFrameView)
        frame.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        await #expect(throws: RemoteScreenCaptureSourceError.self) { try await session.start() }
        await wait(session) { frame.chrome != nil }
        // Apps dropped on the frame reach the presentation that installs them.
        #expect(frame.chrome?.view.registeredDraggedTypes.isEmpty == true)
        let framebuffer = RemoteScreenFramebuffer(frame: frame.screen.bounds)
        framebuffer.autoresizingMask = [.width, .height]
        frame.screen.addSubview(framebuffer)
        for angle: CGFloat in [0, 90] {
            frame.angle = angle
            frame.layoutSubtreeIfNeeded()
            let display = RemoteScreenFramebuffer.Display(size: CGSize(width: 420, height: 912), angle: angle)
            framebuffer.update(display: display)
            framebuffer.update(attributes: CoreDeviceCaptureTransport.videoAttributes(
                frame: angle == 0 ? CGSize(width: 1260, height: 2736) : CGSize(width: 2736, height: 1260), display: display))
            let screen = frame.screen.frame
            #expect(frame.chrome?.view.isHidden == false && frame.screen.layer?.mask != nil)
            #expect(abs(screen.width / screen.height - (angle == 0 ? 1260.0 / 2736 : 2736.0 / 1260)) < 0.001)
            #expect(frame.bounds.insetBy(dx: 8, dy: 8).contains(screen), "Angle \(angle): \(screen) has no bezel in \(frame.bounds)")
            // The display's top-left corner is wherever the device frame turned it, and the frame itself takes no touches.
            // Input reaches within a quarter point of the display's edges, which fall between backing pixels.
            let corner = angle == 0 ? CGPoint(x: screen.minX + 0.25, y: screen.maxY - 0.25)
                : CGPoint(x: screen.maxX - 0.25, y: screen.maxY - 0.25)
            let origin = try #require(framebuffer.inputLocations(at: corner, from: frame, clampingToDisplay: false))
            #expect(origin.touch.x < 0.01 && origin.touch.y < 0.01, "Angle \(angle): \(origin.touch)")
            #expect(framebuffer.inputLocations(at: CGPoint(x: screen.minX - 2, y: screen.midY), from: frame, clampingToDisplay: false) == nil)
        }
        try await session.stop()
    }

    @Test func captureStreamCapturesItsCurrentIOSurfaceFrameAndDropsFramesAfterStopping() async throws {
        let gpu = try #require(MTLCreateSystemDefaultDevice())
        let layer = CAMetalLayer()
        layer.device = gpu
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        let stream = try RemoteScreenCaptureStream(target: .init(layer: layer), device: gpu)
        var events = stream.events.makeAsyncIterator()
        await #expect(throws: CLIError.self) { try await stream.snapshot() }
        await stream.receive(try capturedFrame(width: 4, height: 2, bgra: [0x10, 0x20, 0x30, 0xFF]))
        guard case .frameSize(let size)? = await events.next() else { Issue.record("The first frame was not reported"); return }
        #expect(size == CGSize(width: 4, height: 2))
        layer.drawableSize = size
        await stream.acceptDrawableSize(size)
        await stream.receive(try capturedFrame(width: 4, height: 2, bgra: [0x40, 0x50, 0x60, 0xFF]))
        let image = try await stream.snapshot()
        let pixels = try #require(image.dataProvider?.data as Data?)
        #expect(image.width == 4 && image.height == 2 && Array(pixels.prefix(3)) == [0x40, 0x50, 0x60])
        await stream.stop()
        await stream.receive(try capturedFrame(width: 8, height: 2, bgra: [0, 0, 0, 0xFF]))
        await #expect(throws: CLIError.self) { try await stream.snapshot() }
        // A failure, or the late frame's new size, would be an event before the stream ended.
        #expect(await events.next() == nil)

        let copying = try RemoteScreenCaptureStream(target: .init(layer: CAMetalLayer()), device: gpu)
        var failures = copying.events.makeAsyncIterator()
        await copying.receive(try capturedFrame(width: 4, height: 2, bgra: [0, 0, 0, 0xFF], ioSurface: false))
        guard case .failure(let error)? = await failures.next() else { Issue.record("A CPU-only frame was accepted"); return }
        #expect((error as? CLIError)?.identifier == "remote-screen-frame-surface")
        await #expect(throws: CLIError.self) { try await copying.snapshot() }
        await copying.stop()
    }

    @Test func aCaptureSourceChoiceBelongsToOneCoreDeviceAndIsRequiredBeforeConnecting() async throws {
        let suite = "dev.lynnswap.NeoSimulator.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = ScreenCaptureSourceCatalog(defaults: defaults)
        let transport = ScreenFixtureTransport()
        var attempts = 0
        let session = RemoteDeviceScreenSession(device: try device(), captureSources: catalog) { _, _, _ in
            attempts += 1
            if attempts == 1 { throw RemoteScreenCaptureSourceError(reason: .unchosen) }
            return transport
        }
        #expect(session.captureSource == nil)
        await #expect(throws: RemoteScreenCaptureSourceError.self) { try await session.start() }
        #expect(session.state == .failed && session.needsCaptureSource)
        let source = RemoteScreenCaptureSource(name: "Fixture Device", uniqueID: "opaque-capture-identity")
        session.chooseCaptureSource(source)
        #expect(session.captureSource == source && catalog.chosenSource(for: "hardware-identifier") == nil)
        try await session.start()
        #expect(session.state == .connected && !session.needsCaptureSource)
        let other = RemoteDeviceScreenSession(device: try device(identifier: "other-command-identifier"), captureSources: catalog) { _, _, _ in
            ScreenFixtureTransport()
        }
        other.chooseCaptureSource(source)
        #expect(other.captureSource == source && session.captureSource == nil)
        try await session.stop()
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
    func shutdownReleasesAResourceAcquiredInsideLateStartup(failCleanup: Bool) async throws {
        let primary = ScreenFixtureTransport(), dedicated = ScreenFixtureTransport()
        let resize = ScreenResizeFixtureTransport()
        let acquisition = ScreenFixtureGate()
        let resource = ScreenFixtureResource()
        resource.failRelease = failCleanup
        dedicated.acquireResource = { await acquisition.hold(); return resource }
        let session = RemoteDeviceScreenSession(device: try device(), makeResizeTransport: { _ in resize }) { _, _, target in
            target == nil ? primary : dedicated
        }
        try await session.start()
        await wait(session) { session.canResizeApp }
        let switching = Task { try await session.startAppResize(size: CGSize(width: 400, height: 600)) }
        await acquisition.wait()
        var stops = dedicated.stopEvents.stream.makeAsyncIterator()
        let shutdown = Task { try await session.stop() }
        await stops.next()
        #expect(dedicated.ownedResource == nil && !resource.released)
        acquisition.resume()
        if failCleanup {
            do { try await shutdown.value; Issue.record("Late resource cleanup failure was lost") }
            catch {
                #expect(error.localizedDescription.contains("fixture cleanup failed"))
                #expect(error.localizedDescription.contains(CancellationError().localizedDescription))
            }
            #expect(session.state == .failed && session.nativeInputView != nil)
            #expect(dedicated.ownedResource === resource && !resource.released)
            resource.failRelease = false
            try await session.stop()
        } else {
            try await shutdown.value
        }
        await #expect(throws: CancellationError.self) { try await switching.value }
        #expect(resource.released && dedicated.ownedResource == nil)
        #expect(session.state == .stopped && session.nativeInputView == nil)
    }

    @Test func aCancelledPrimaryFactoryRetainsItsFailedCleanupOwner() async throws {
        let connection = ScreenFixtureTransport()
        let resource = ScreenFixtureResource()
        resource.failRelease = true
        connection.ownedResource = resource
        let factory = ScreenFixtureGate()
        let session = RemoteDeviceScreenSession(device: try device()) { _, _, _ in
            await factory.hold()
            return connection
        }
        let starting = Task { try await session.start() }
        await factory.wait()
        starting.cancel()
        factory.resume()
        do { try await starting.value; Issue.record("Cancelled startup cleanup failure was lost") }
        catch {
            #expect(error.localizedDescription.contains("fixture cleanup failed"))
            #expect(error.localizedDescription.contains(CancellationError().localizedDescription))
        }
        #expect(session.nativeInputView != nil && connection.ownedResource === resource && !resource.released)
        resource.failRelease = false
        try await session.stop()
        #expect(resource.released && connection.ownedResource == nil)
        #expect(session.state == .stopped && session.nativeInputView == nil)
    }

    @Test func duplicateGuestEventsJoinTheRestoreWaitingForRecording() async throws {
        let primary = ScreenFixtureTransport(), dedicated = ScreenFixtureTransport(), restored = ScreenFixtureTransport()
        dedicated.automaticFrames = true
        let resize = ScreenResizeFixtureTransport()
        let recording = ScreenResizeRecordingHandle()
        let finishing = ScreenFixtureGate()
        recording.stopGate = finishing
        dedicated.recordingHandle = recording
        var primaryConnections = 0
        let session = RemoteDeviceScreenSession(device: try device(), makeResizeTransport: { _ in resize }) { _, _, target in
            if target != nil { return dedicated }
            primaryConnections += 1
            return primaryConnections == 1 ? primary : restored
        }
        try await session.start()
        await wait(session) { session.canResizeApp }
        try await session.startAppResize(size: CGSize(width: 400, height: 600))
        try await session.startRecording()
        dedicated.emit(.disconnected)
        await finishing.wait()
        #expect(session.isChangingDisplay && session.hasUnfinishedRecording)
        dedicated.emit(.disconnected)
        var invalidations = resize.assertion.invalidationReturns.stream.makeAsyncIterator()
        resize.assertion.guestInvalidates()
        await invalidations.next()
        finishing.resume()
        await wait(session) { !session.isChangingDisplay }
        #expect(session.state == .connected && primaryConnections == 2)
        #expect(session.nativeInputView === restored.nativeInputView && !session.isResizingApp)
        #expect(session.completedRecording != nil && !session.hasUnfinishedRecording && recording.stops == 1)
        try await session.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func aFailedResizeSessionIsReportedOnceThePrimaryDisplayReturns() async throws {
        let primary = ScreenFixtureTransport(), dedicated = ScreenFixtureTransport(), restored = ScreenFixtureTransport()
        dedicated.automaticFrames = true
        let resize = ScreenResizeFixtureTransport()
        var primaryConnections = 0
        let session = RemoteDeviceScreenSession(device: try device(), makeResizeTransport: { _ in resize }) { _, _, target in
            if target != nil { return dedicated }
            primaryConnections += 1
            return primaryConnections == 1 ? primary : restored
        }
        // A report while the display is still changing would describe a screen that is not shown yet.
        var reports: [(error: any Error, restored: Bool)] = []
        let reported = AsyncStream<Void>.makeStream()
        session.onAppResizeFailure = { [unowned session] in
            reports.append(($0, session.state == .connected && !session.isChangingDisplay && !session.isResizingApp))
            reported.continuation.yield()
        }
        try await session.start()
        await wait(session) { session.canResizeApp }
        try await session.startAppResize(size: CGSize(width: 400, height: 600))
        resize.assertion.failUpdates(ScreenFixtureError.stream)
        var arrivals = reported.stream.makeAsyncIterator()
        await arrivals.next()
        #expect(primaryConnections == 2 && session.lastError is ScreenFixtureError)
        try await session.stop()
        #expect(reports.count == 1 && reports.first?.error is ScreenFixtureError && reports.first?.restored == true)
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
        var failures: [any Error] = []
        session.onAppResizeFailure = { failures.append($0) }
        try await session.start()
        #expect(session.state == .connected && !primary.closed && session.canCaptureScreenshot)
        #expect(session.inputCapabilities == [.keyboard] && !session.supportsAppResize)
        #expect(session.lastError is ScreenFixtureError && failures.count == 1 && failures.first is ScreenFixtureError)
        if session.state == .connected {
            try await session.sendKey(4, state: .down)
            _ = try await session.captureScreenshot()
            #expect(primary.downKeys == [4])
        }
        try await session.stop()
    }

    @Test func reconnectSubscribesToTheNewResizeEligibilitySource() async throws {
        let first = ScreenResizeFixtureTransport()
        let startingObservation = ScreenFixtureGate()
        first.eligibilityGate = startingObservation
        let next = ScreenResizeFixtureTransport()
        next.initialEligibility = .unavailable
        let primary = ScreenFixtureTransport()
        var connections = 0
        let session = RemoteDeviceScreenSession(device: try device(), makeResizeTransport: { _ in
            connections += 1
            return connections == 1 ? first : next
        }) { _, _, _ in connections == 0 ? primary : ScreenFixtureTransport() }
        let startup = Task { try await session.start() }
        await startingObservation.wait()
        var stops = primary.stopEvents.stream.makeAsyncIterator()
        let shutdown = Task { try await session.stop() }
        await stops.next()
        startingObservation.resume()
        await #expect(throws: CancellationError.self) { try await startup.value }
        try await shutdown.value
        #expect(!session.supportsAppResize && !session.canResizeApp)
        try await session.start()
        #expect(connections == 2 && session.supportsAppResize && !session.canResizeApp)
        next.eligibilityUpdates.yield(.eligible)
        await wait(session) { session.canResizeApp }
        if case .terminated = first.eligibilityUpdates.yield(.unavailable) {}
        else { Issue.record("A cancelled startup left its old eligibility observer alive") }
        first.eligibilityUpdates.finish(throwing: ScreenFixtureError.stream)
        #expect(session.supportsAppResize && session.canResizeApp && session.lastError == nil)
        try await session.stop()
    }

    @Test func optionalBindingDiagnosticsPreserveFailuresAndUnverifiedBoundaries() async throws {
        typealias Preparation = NativeRuntimeValidationReport.Preparation
        let unchecked = ["device capability and service I/O"]
        let prepared = await Preparation.check("prepared", unverified: unchecked, load: {}, prepare: {})
        let missing = await Preparation.check("missing", unverified: unchecked, load: {}, prepare: {
            throw ABIResolutionError.imageNotLoaded
        })
        var attemptedPreparation = false
        let failed = await Preparation.check("failed", unverified: unchecked, load: {
            throw ScreenFixtureError.stream
        }, prepare: { attemptedPreparation = true })
        #expect(!attemptedPreparation)
        #expect(prepared.status == .prepared && prepared.detail == nil)
        #expect(missing.status == .unavailable && missing.stage == .preparingBindings && missing.detail != nil)
        #expect(failed.status == .failed && failed.stage == .loadingFramework && failed.detail != nil)
        let report = NativeRuntimeValidationReport(optionalBindings: [prepared, missing, failed])
        let decoded = try JSONDecoder().decode(NativeRuntimeValidationReport.self, from: JSONEncoder().encode(report))
        #expect(decoded == report && decoded.optionalBindings.allSatisfy { $0.unverified == unchecked })
    }

    @Test func resizeGeometryBindingsPrepareWithoutADeviceOrAssertion() throws {
        try CoreDeviceRemoteScreenDevice.load("/Library/Developer/PrivateFrameworks/CoreDeviceUtilities.framework/Versions/A/CoreDeviceUtilities")
        let bindings = try CoreDeviceAppResizeTransport.Bindings(runtime: .shared)
        _ = try CoreDeviceAppResizeTransport.GeometryBindings(type: bindings.sceneType, abis: bindings.abis)
    }

    @Test(.timeLimit(.minutes(1)))
    func pasteboardBindingsCaptureWriteAndObserveMacPasteboardsWithoutADevice() async throws {
        try CoreDeviceRemoteScreenDevice.load(MacHIDServiceLookup.coreDeviceUtilitiesPath)
        let bindings = try CoreDevicePasteboardTransport.Bindings(runtime: .shared)
        let source = NSPasteboard(name: NSPasteboard.Name("dev.lynnswap.NeoSimulatorTests.\(UUID().uuidString)"))
        let destination = NSPasteboard(name: NSPasteboard.Name("dev.lynnswap.NeoSimulatorTests.\(UUID().uuidString)"))
        defer { source.releaseGlobally(); destination.releaseGlobally() }
        source.clearContents()
        source.setString("copied", forType: .string)
        // Captures, observations, and device reads all pass the same data policy.
        _ = try await bindings.capture(source)
        let snapshot = try await bindings.capture(source)
        #expect(!bindings.policy.isConsumed)
        // The snapshot keeps the change count it was captured at, and its data, after the source changes again.
        let captured = Int64(source.changeCount)
        source.clearContents()
        source.setString("later", forType: .string)
        #expect(try bindings.version(snapshot)?.changeCount == captured && Int64(source.changeCount) != captured)
        #expect(try bindings.write(snapshot, destination) == destination.changeCount)
        #expect(destination.string(forType: .string) == "copied")
        // The destination keeps the source's origin, so that its change does not go back.
        let received = try await bindings.capture(destination)
        #expect(try bindings.isTransferred(received))
        // A pasteboard that relays a restored change to a device holds the change's items as its own change, without
        // the origin the change named.
        let relay = NSPasteboard(name: NSPasteboard.Name("dev.lynnswap.NeoSimulatorTests.\(UUID().uuidString)"))
        defer { relay.releaseGlobally() }
        _ = try bindings.write(bindings.unstampedCopy(received), relay)
        let relayed = try await bindings.capture(relay)
        #expect(try !bindings.isTransferred(relayed) && bindings.version(relayed)?.changeCount == Int64(relay.changeCount))
        #expect(relay.string(forType: .string) == "copied")
        // The observation reports a copy made on the Mac as the Mac's own, which goes to the device, with the change
        // count that the copy left. Copying repeats until the first report because the framework decides when its
        // observation starts.
        var changeCounts = [source.changeCount]
        let copying = Task {
            while true {
                try await Task.sleep(for: .milliseconds(100))
                source.clearContents()
                source.setString("copied", forType: .string)
                changeCounts.append(source.changeCount)
            }
        }
        defer { copying.cancel() }
        var transferred: Bool?
        var reported: Int64?
        do {
            try await bindings.macSnapshots.forEach(bindings.changes(source)) { change in
                transferred = try bindings.isTransferred(change)
                reported = try bindings.version(change)?.changeCount
                throw CancellationError()
            }
        } catch is CancellationError {}
        #expect(transferred == false)
        #expect(reported.map { changeCounts.contains(Int($0)) } == true)
    }

    @Test func displayGeometryBindingsReadDeviceKitPointSizesWithoutADevice() async throws {
        try await CoreDeviceDisplayGeometry.loadRuntime()
        let runtime = ABIRuntime.shared
        let bindings = try CoreDeviceDisplayGeometry.Bindings(runtime: runtime)
        let sizeType = try runtime.resolveAndWait(.swift(.type("DeviceKit.DisplaySize")))
        let makeSize = try sizeType.resolveAndWait(.swift(.initializer("init(pixelSize:uiScale:)",
            as: ((CGSize, CGFloat) -> NativeSwiftValue).self, valueABIs: bindings.abis)))
        let size = try unsafe makeSize.unsafeInvoke(CGSize(width: 300, height: 600), 2)
        #expect(try unsafe bindings.pointSize.unsafeInvoke(on: size) == CGSize(width: 150, height: 300))
        // The device frame reads the same size in DeviceKit's pixel and scale terms.
        let frame = try CoreDeviceDisplayGeometry.FrameBindings(runtime: runtime, abis: bindings.abis)
        #expect(try unsafe frame.pixelSize.unsafeInvoke(on: size) == CGSize(width: 300, height: 600))
        #expect(try unsafe frame.scale.unsafeInvoke(on: size) == 2)
    }

    @Test func nativeTouchscreenDescriptorsPreserveANonLegacyDisplayIdentity() async throws {
        try CoreDeviceRemoteScreenDevice.load("/Library/Developer/PrivateFrameworks/CoreDeviceUtilities.framework/Versions/A/CoreDeviceUtilities")
        let runtime = ABIRuntime.shared
        let descriptor = try await CoreDeviceHIDService.touchscreenDescriptor(displayID: 0x35, uniqueID: "resized-app-display", runtime: runtime)
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
        let systemURL = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/UniversalHID.framework/Versions/A/UniversalHID")
        let coreDeviceURL = URL(fileURLWithPath: "/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/Frameworks/UniversalHID.framework/Versions/A/UniversalHID")
        try CoreDeviceRemoteScreenDevice.load(systemURL.path)
        try CoreDeviceRemoteScreenDevice.load(coreDeviceURL.path)
        let systemImage = try #require(runtime.resolveImagesAndWait(matching: .path(systemURL)).first)
        let image = try #require(runtime.resolveImagesAndWait(matching: .path(coreDeviceURL)).first)
        try #require(image != systemImage)
        let builder = try CoreDeviceDigitizerReports(runtime: runtime)
        let digitizer = try runtime.resolveAndWait(.swift(.type("UniversalHID.DigitizerReport")), in: image, loading: .loadedOnly)
        let contact = try runtime.resolveAndWait(.swift(.type("UniversalHID.DigitizerContact")), in: image, loading: .loadedOnly)
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
            #expect(payload.type.image == image)
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

    @Test func trackpadPinchesBecomeScaleReportsForAServiceThatCarriesTheirTrackpad() async throws {
        let runtime = ABIRuntime.shared
        let bindings = try await NativeTrackpadBindings(runtime: runtime)
        // The properties a Mac trackpad's HID service lists, as the built-in and Magic Trackpad drivers do.
        let descriptor = try bindings.descriptor(serviceID: 0x1234, properties: [
            "PrimaryUsagePage": 1, "PrimaryUsage": 2, "Product": "Fixture Trackpad", "DeviceUsagePairs": [
                ["DeviceUsagePage": 1, "DeviceUsage": 2], ["DeviceUsagePage": 1, "DeviceUsage": 1],
                ["DeviceUsagePage": 13, "DeviceUsage": 5], ["DeviceUsagePage": 65280, "DeviceUsage": 12],
            ],
        ])
        // The guest service carries the trackpad under its registry ID, and hides its pointer while clicks touch the screen.
        let service = try GuestPointerService(descriptor)
        #expect(service.serviceID == 0x1234 && service.isPointer && service.hidesPointer == true)
        #expect(service.routesPastShellPolicy == true)
        // A synthesized pinch has no sender, so it reaches no trackpad's service.
        #expect(try bindings.lookup.sender(of: trackpadPinch(.began, sender: nil)) == 0)

        let translator = try bindings.makeTranslator()
        let report = try CoreDeviceHIDService.reportABI(runtime: runtime)
        let scale = try CoreDeviceHIDService.universalHIDType("ScaleReport", runtime: runtime)
        let pointer = try CoreDeviceHIDService.universalHIDType("AbsolutePointerReport", runtime: runtime)
        let reportID = try CoreDeviceHIDService.universalHIDType("ReportID", runtime: runtime)
        let phase = try CoreDeviceHIDService.universalHIDType("HIDEventPhase", runtime: runtime)
        let abis: [NativeSwiftType: NativeType] = [
            report.type: report.abi,
            scale: try .structure(named: scale.name, fields: [.uint64, .uint64]),
            pointer: try .structure(named: pointer.name, fields: [.uint64, .uint64]),
            reportID: try .structure(named: reportID.name, fields: [.uint8]),
            phase: try .structure(named: phase.name, fields: [.uint8]),
        ]
        let rawID = try reportID.resolveAndWait(.swift(.getter("rawValue", as: (() -> UInt8).self, valueABIs: abis, receiverABI: abis[reportID])))
        let readID = try report.type.resolveAndWait(.swift(.getter("reportID", as: (() -> NativeSwiftValue).self, valueABIs: abis, receiverABI: report.abi)))

        // A mouse movement moves the service's hidden pointer, where its pinches happen, to the location that the screen's
        // transform maps the event's window location to; this transform turns, scales, and moves it.
        let pointerID = try pointer.resolveAndWait(.swift(.staticGetter("reportID", as: (() -> NativeSwiftValue).self, valueABIs: abis)))
        let makePointer = try pointer.resolveAndWait(.swift(.initializer("init(_report:)", as: ((NativeSwiftValue) -> NativeSwiftValue).self, valueABIs: abis)))
        let pointerX = try pointer.resolveAndWait(.swift(.getter("x", as: (() -> Double).self, valueABIs: abis, receiverABI: abis[pointer])))
        let pointerY = try pointer.resolveAndWait(.swift(.getter("y", as: (() -> Double).self, valueABIs: abis, receiverABI: abis[pointer])))
        let movement = try mouseMovement(sender: 0x1234)
        #expect(try bindings.lookup.sender(of: movement) == 0x1234)
        let location = movement.locationInWindow, target = CGPoint(x: 0.3, y: 0.8)
        let turn = CGAffineTransform(a: 0, b: 1 / 600, c: -1 / 300, d: 0, tx: 0, ty: 0)
        let moved = location.applying(turn)
        let transform = turn.concatenating(CGAffineTransform(translationX: target.x - moved.x, y: target.y - moved.y))
        let movements = try translator.reports(for: movement, coordinateTransform: transform)
        let placed = try #require(movements.first)
        let movementIDs = try movements.map { try unsafe rawID.unsafeInvoke(on: readID.unsafeInvoke(on: $0)) }
        #expect(try unsafe movementIDs == [rawID.unsafeInvoke(on: pointerID.unsafeInvoke())], "Report IDs \(movementIDs)")
        let position = try unsafe makePointer.unsafeInvoke(placed)
        #expect(abs(try unsafe pointerX.unsafeInvoke(on: position) - target.x) < 0.001)
        #expect(abs(try unsafe pointerY.unsafeInvoke(on: position) - target.y) < 0.001)

        // The trackpad's pinches still reach the device as scale reports alone.
        let scaleID = try scale.resolveAndWait(.swift(.staticGetter("reportID", as: (() -> NativeSwiftValue).self, valueABIs: abis)))
        let makeScale = try scale.resolveAndWait(.swift(.initializer("init(_report:)", as: ((NativeSwiftValue) -> NativeSwiftValue).self, valueABIs: abis)))
        let z = try scale.resolveAndWait(.swift(.getter("z", as: (() -> Double).self, valueABIs: abis, receiverABI: abis[scale])))
        let readPhase = try scale.resolveAndWait(.swift(.getter("phase", as: (() -> NativeSwiftValue).self, valueABIs: abis, receiverABI: abis[scale])))
        let rawPhase = try phase.resolveAndWait(.swift(.getter("rawValue", as: (() -> UInt8).self, valueABIs: abis, receiverABI: abis[phase])))
        func expected(_ name: String) throws -> UInt8 {
            let read = try phase.resolveAndWait(.swift(.staticGetter(name, as: (() -> NativeSwiftValue).self, valueABIs: abis)))
            return try unsafe rawPhase.unsafeInvoke(on: read.unsafeInvoke())
        }
        for (gesturePhase, name, magnification) in [(TrackpadPinchPhase.began, "began", 0.0), (.changed, "changed", 0.25),
                                                    (.changed, "changed", -0.125), (.ended, "ended", 0), (.cancelled, "canceled", 0)] {
            let pinch = try trackpadPinch(gesturePhase, magnification: magnification, sender: 0x1234)
            try #require(pinch.type == .magnify)
            // Each step goes to the service of the trackpad that sent it.
            #expect(try bindings.lookup.sender(of: pinch) == 0x1234)
            let reports = try translator.reports(for: pinch)
            // Each step reaches the device as one scale report in CoreDevice's own UniversalHID module.
            let value = try #require(reports.first)
            #expect(reports.count == 1 && value.type == report.type)
            #expect(try unsafe rawID.unsafeInvoke(on: readID.unsafeInvoke(on: value)) == rawID.unsafeInvoke(on: scaleID.unsafeInvoke()))
            let scaled = try unsafe makeScale.unsafeInvoke(value)
            #expect(abs(try unsafe z.unsafeInvoke(on: scaled) - magnification) < 0.001, "\(name) \(magnification)")
            #expect(try unsafe rawPhase.unsafeInvoke(on: readPhase.unsafeInvoke(on: scaled)) == expected(name), "\(name)")
        }
    }

    @Test(.enabled(if: !macTrackpads.isEmpty, "Requires a Mac trackpad"))
    func trackpadServicesCarryEachMacTrackpadAsAHiddenPointer() async throws {
        let bindings = try await NativeTrackpadBindings(runtime: .shared)
        for serviceID in macTrackpads {
            // Without the trackpad's properties, its pinches would reach no service.
            let properties = try #require(try bindings.lookup.properties(ofHIDService: serviceID))
            let service = try GuestPointerService(bindings.descriptor(serviceID: serviceID, properties: properties))
            #expect(service.serviceID == serviceID && service.isPointer && service.hidesPointer == true,
                    "Registry entry 0x\(String(serviceID, radix: 16))")
        }
    }

    @Test func eachMacTrackpadsPinchesReachTheServiceThatCarriesThatTrackpad() async throws {
        let transport = TrackpadFixtureTransport(bindings: try await NativeTrackpadBindings(runtime: .shared))
        let gestures = NativeTrackpadGestures { transport }
        // Each trackpad's first event creates its service: a mouse movement moves the service's hidden pointer, and the
        // trackpad's pinches happen there. A synthesized event, and one whose sender is not a Mac HID service, reach no
        // service, and no trackpad is made up for them.
        let onScreen = CGAffineTransform(scaleX: 1 / 2000, y: 1 / 2000)
        try await gestures.movePointer(mouseMovement(sender: 0xA), coordinateTransform: onScreen)
        for pinch in try [trackpadPinch(.began, sender: 0xA), trackpadPinch(.changed, magnification: 0.2, sender: 0xA),
                          trackpadPinch(.began, sender: 0xB), trackpadPinch(.ended, sender: 0xA), trackpadPinch(.began, sender: nil),
                          trackpadPinch(.began, sender: 0x99), trackpadPinch(.changed, magnification: 0.2, sender: 0x99)] {
            try await gestures.send(pinch)
        }
        try await gestures.movePointer(mouseMovement(sender: nil), coordinateTransform: onScreen)
        try await gestures.movePointer(mouseMovement(sender: 0x99), coordinateTransform: onScreen)
        #expect(transport.services.map(\.sender) == [0xA, 0xB] && transport.services.map(\.reports) == [4, 1])
        #expect(transport.lookups == [0xA, 0xB, 0x99])
        // Releasing input resets every service, so the pinch that one trackpad holds after another's ended also ends.
        try gestures.resetGestures()
        #expect(transport.services.map(\.resets) == [1, 1])
        // The device invalidates the services with its gesture capability, so the trackpad's next pinch creates another.
        gestures.discardServices()
        try await gestures.send(trackpadPinch(.began, sender: 0xA))
        #expect(transport.services.map(\.sender) == [0xA, 0xB, 0xA] && transport.services.map(\.reports) == [4, 1, 1])
        try await gestures.stop()
        #expect(transport.services.last?.removes == 1)
    }

    @Test func trackpadServicesCreatedWhileGestureInputEndsAreNotKept() async throws {
        let transport = TrackpadFixtureTransport(bindings: try await NativeTrackpadBindings(runtime: .shared))
        let preparing = ScreenFixtureGate()
        var holdsPreparation = true
        let gestures = NativeTrackpadGestures {
            if holdsPreparation { holdsPreparation = false; await preparing.hold() }
            return transport
        }
        // The device can invalidate the services while the first pinch prepares the transport; that pinch is not sent.
        let stale = Task { try await gestures.send(trackpadPinch(.began, sender: 0xA)) }
        await preparing.wait()
        gestures.discardServices()
        preparing.resume()
        try await #require(throws: CLIError.self) { try await stale.value }
        // A service that the device invalidates while it is created is not used; the trackpad's next pinch creates another.
        let invalidating = ScreenFixtureGate()
        transport.connecting = invalidating
        let invalidated = Task { try await gestures.send(trackpadPinch(.began, sender: 0xA)) }
        await invalidating.wait()
        gestures.discardServices()
        invalidating.resume()
        await #expect(throws: CLIError.self) { try await invalidated.value }
        transport.connecting = nil
        try await gestures.send(trackpadPinch(.began, sender: 0xA))
        #expect(transport.services.map(\.reports) == [0, 1])

        // Stopping removes the services. The pinch that creates one meanwhile removes it, and a removal that fails is
        // retried by the next stop; after stopping, pinches create no service.
        let stopping = ScreenFixtureGate()
        transport.connecting = stopping
        transport.services[1].removeFailures = 1
        let created = Task { try await gestures.send(trackpadPinch(.began, sender: 0xB)) }
        await stopping.wait()
        await #expect(throws: CLIError.self) { try await gestures.stop() }
        stopping.resume()
        await #expect(throws: CLIError.self) { try await created.value }
        try await gestures.stop()
        await #expect(throws: CLIError.self) { try await gestures.send(trackpadPinch(.began, sender: 0xA)) }
        #expect(transport.services.map(\.sender) == [0xA, 0xA, 0xB] && transport.services.map(\.reports) == [0, 1, 0])
        #expect(transport.services.dropFirst().map(\.removes) == [2, 1])
    }

    @Test func trackpadScrollsBecomeScrollReportsLikeTheirPinches() async throws {
        let runtime = ABIRuntime.shared
        let bindings = try await NativeTrackpadBindings(runtime: runtime)
        let translator = try bindings.makeTranslator()
        let report = try CoreDeviceHIDService.reportABI(runtime: runtime)
        let scroll = try CoreDeviceHIDService.universalHIDType("ScrollReport", runtime: runtime)
        let reportID = try CoreDeviceHIDService.universalHIDType("ReportID", runtime: runtime)
        let abis: [NativeSwiftType: NativeType] = [report.type: report.abi, reportID: try .structure(named: reportID.name, fields: [.uint8])]
        let rawID = try reportID.resolveAndWait(.swift(.getter("rawValue", as: (() -> UInt8).self, valueABIs: abis, receiverABI: abis[reportID])))
        let readID = try report.type.resolveAndWait(.swift(.getter("reportID", as: (() -> NativeSwiftValue).self, valueABIs: abis, receiverABI: report.abi)))
        let scrollID = try unsafe rawID.unsafeInvoke(on: scroll.resolveAndWait(.swift(.staticGetter("reportID",
            as: (() -> NativeSwiftValue).self, valueABIs: abis))).unsafeInvoke())
        // Each step of a trackpad's scroll, through its momentum, and each event of a mouse wheel reaches the device as a
        // scroll report for the service of the Mac HID service that sent it, as each step of a pinch does as a scale report.
        for event in try [trackpadScroll(.began, delta: -12, sender: 0x1234), trackpadScroll(.changed, delta: -30, sender: 0x1234),
                          trackpadScroll(.ended, sender: 0x1234), trackpadScroll(nil, momentum: .begin, delta: -20, sender: 0x1234),
                          trackpadScroll(nil, momentum: .end, sender: 0x1234), trackpadScroll(nil, units: .line, delta: -3, sender: 0x1234)] {
            #expect(try bindings.lookup.sender(of: event) == 0x1234)
            let ids = try translator.reports(for: event).map { try unsafe rawID.unsafeInvoke(on: readID.unsafeInvoke(on: $0)) }
            #expect(ids == [scrollID], "phase \(event.phase.rawValue), momentum \(event.momentumPhase.rawValue)")
        }
    }

    @Test func nativeTrackpadSendsEventsInOrderAndDropsThoseOfEndedGestures() async throws {
        let transport = TrackpadFixtureTransport(bindings: try await NativeTrackpadBindings(runtime: .shared))
        let trackpad = NativeDeviceTrackpad(gestures: NativeTrackpadGestures { transport })
        var failures: [String] = []
        trackpad.onFailure = { failures.append($0.localizedDescription) }
        let onScreen = CGAffineTransform(scaleX: 1 / 400, y: 1 / 600)
        // A trackpad's first event waits for the device to create its service. The events after it wait too, instead of
        // creating another service or reaching the device first.
        let creating = ScreenFixtureGate()
        transport.connecting = creating
        for event in try [mouseMovement(sender: 0xA), trackpadScroll(.began, delta: -10, sender: 0xA), trackpadPinch(.began, sender: 0xA)] {
            trackpad.handle(event, coordinateTransform: onScreen)
        }
        await creating.wait()
        #expect(transport.lookups == [0xA] && transport.services.isEmpty)
        transport.connecting = nil
        creating.resume()

        // Ending the gestures, as losing focus does, while another trackpad's service is created ends those the services
        // hold and drops the events not yet sent. The service is kept for that trackpad's next gesture.
        let ending = ScreenFixtureGate()
        transport.connecting = ending
        trackpad.handle(try trackpadScroll(.began, delta: -10, sender: 0xB), coordinateTransform: onScreen)
        await ending.wait()
        #expect(transport.services.map(\.reports) == [5])
        trackpad.handle(try trackpadPinch(.changed, magnification: 0.2, sender: 0xA), coordinateTransform: onScreen)
        trackpad.endGestures()
        #expect(transport.services.map(\.resets) == [1])
        transport.connecting = nil
        ending.resume()
        trackpad.handle(try trackpadScroll(.began, delta: -10, sender: 0xB), coordinateTransform: onScreen)

        // A step that fails ends the gestures, so its remaining steps are dropped, and the failure is reported.
        try #require(transport.services.first).sendFailures = 1
        for event in try [trackpadPinch(.began, sender: 0xA), trackpadPinch(.changed, magnification: 0.2, sender: 0xA)] {
            trackpad.handle(event, coordinateTransform: onScreen)
        }
        // Stopping removes the services after the events before it; later events reach none.
        try await trackpad.stop()
        trackpad.handle(try trackpadPinch(.began, sender: 0xA), coordinateTransform: onScreen)
        #expect(transport.lookups == [0xA, 0xB] && transport.services.map(\.sender) == [0xA, 0xB])
        #expect(transport.services.map(\.reports) == [5, 2] && failures == ["fixture stream failed"])
        #expect(transport.services.map(\.resets) == [3, 2] && transport.services.map(\.removes) == [1, 1])
    }

    @Test func nativeScreenInputSendsAcceptedTouchesAndButtonsInOrderBeforeItStops() async throws {
        let transport = ScreenFixtureTransport()
        let input = NativeDeviceScreenInput(input: transport)
        var failures: [String] = []
        input.onFailure = { failures.append($0.localizedDescription) }
        var results: [String?] = []
        // The first touch waits inside the transport. The touches and buttons accepted after it wait as well, rather
        // than reaching the device first, and a button's result reaches its caller.
        let sending = ScreenFixtureGate()
        transport.holdingSend = sending
        input.sendTouch(at: CGPoint(x: 0.5, y: 0.5), secondPoint: nil, phase: .began, edge: .bottom)
        input.sendTouch(at: CGPoint(x: 0.5, y: 0.4), secondPoint: CGPoint(x: 0.4, y: 0.4), phase: .moved, edge: .bottom)
        try input.sendButton(usagePage: 0x0c, usage: 0x40, state: .down) { results.append($0?.localizedDescription) }
        input.sendTouch(at: CGPoint(x: 0.5, y: 0.3), secondPoint: nil, phase: .ended, edge: .bottom)
        try input.sendButton(usagePage: 0x0c, usage: 0x40, state: .up) { results.append($0?.localizedDescription) }
        await sending.wait()
        // The next touch and button fail: the touch's failure is reported, the button's goes to its caller, and the
        // input after them is still sent.
        transport.sendFailures = 2

        // Stopping waits for the accepted input before it releases what the device holds. Input after it is not sent.
        let stopping = Task.immediate { try await input.stop() }
        input.sendTouch(at: CGPoint(x: 0.5, y: 0.5), secondPoint: nil, phase: .began, edge: .none)
        #expect(throws: CLIError.self) { try input.sendButton(usagePage: 0x0c, usage: 0x40, state: .down) { _ in } }
        #expect(transport.releases == 0)
        sending.resume()
        try await stopping.value
        #expect(transport.deliveries == ["touch began", "touch ended", "button up", "release"])
        #expect(failures == ["fixture stream failed"] && results == ["fixture stream failed", nil])
        #expect(transport.closed)
    }

    @Test(.timeLimit(.minutes(1)))
    func guestScreenInputSendsCoreDevicesIndigoEventsToEachGuestServiceAndReleasesWhatTheyHold() async throws {
        let runtime = ABIRuntime.shared
        let peers = GuestHIDPeerFixture()
        let codec = try await GuestHIDCodec(runtime: runtime)
        let input = try NativeDeviceScreenInput.connect(guest: SimulatorGuestHID(codec: codec, connect: peers.connect))
        let digitizer = try #require(CoreDeviceScreenInput.features[.digitizer])
        let button = try #require(CoreDeviceScreenInput.features[.button])
        #expect(peers.lookUps == [digitizer, button])
        var results: [String?] = []
        input.sendTouch(at: CGPoint(x: 0.25, y: 0.5), secondPoint: nil, phase: .began, edge: .left)
        input.sendTouch(at: CGPoint(x: 0.25, y: 0.4), secondPoint: CGPoint(x: 0.75, y: 0.6), phase: .moved, edge: .left)
        try input.sendButton(usagePage: 0x0c, usage: 0x40, state: .down) { results.append($0?.localizedDescription) }
        try await input.stop()
        let touches = await peers.messages(to: digitizer, count: 3)
        let buttons = await peers.messages(to: button, count: 2)
        withExtendedLifetime(input) {}

        // Each service receives CoreDevice's events in order. Stopping ends the held touch where it last was and
        // releases the held button.
        let events = try IndigoFixtureEvents(runtime: runtime)
        let moved = (CGPoint(x: 0.25, y: 0.4), CGPoint(x: 0.75, y: 0.6))
        let expectedTouches = try [
            events.touch(CGPoint(x: 0.25, y: 0.5), nil, "start", edge: "left"),
            events.touch(moved.0, moved.1, "position", edge: "left"),
            events.touch(moved.0, moved.1, "end", edge: "left"),
        ].map { try codec.message(.digitizerEvent, to: digitizer, payload: $0) }
        let expectedButtons = try [events.button(0x0c, 0x40, "down"), events.button(0x0c, 0x40, "up")]
            .map { try codec.message(.buttonEvent, to: button, payload: $0) }
        #expect(touches.count == 3 && zip(touches, expectedTouches).allSatisfy { xpc_equal($0, $1) })
        #expect(buttons.count == 2 && zip(buttons, expectedButtons).allSatisfy { xpc_equal($0, $1) })
        #expect(results == [nil])
    }

    @Test(.timeLimit(.minutes(1)))
    func guestKeyboardCreatesItsServiceWithCoreDevicesRequestsAndRetriesOneThatTheGuestRefused() async throws {
        let runtime = ABIRuntime.shared
        let peers = GuestHIDPeerFixture()
        let codec = try await GuestHIDCodec(runtime: runtime)
        let wire = try UniversalHIDFixtureMessages(runtime: runtime)
        // The guest refuses the first service with its own error and then creates service 7.
        let refusal = NSError(domain: "dev.lynnswap.NeoSimulator.fixture", code: 5)
        var refusals = 1
        peers.reply = { reply in
            if refusals > 0 { refusals -= 1; try wire.refuse(reply, with: refusal) } else { try wire.create(reply, id: 7) }
        }
        let keyboard = try await NativeDeviceKeyboard.connect(guest: SimulatorGuestHID(codec: codec, connect: peers.connect))
        let universalHID = CoreDeviceScreenInput.universalHIDFeature
        #expect(peers.lookUps == [universalHID])
        var failures: [NSError] = []
        keyboard.onFailure = { failures.append($0 as NSError) }
        let keys = try [NSEvent.EventType.keyDown, .keyUp].map { type in
            try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 1, windowNumber: 0,
                context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        }
        for key in keys { keyboard.handle(key) }
        // Removing the services waits for the keys' reports.
        try await keyboard.removeServices()

        // The guest's error reaches the keyboard's failures as the guest sent it. The key-up creates the main keyboard's
        // service again and sends its reports there, and removal resets and removes that service.
        #expect(failures.map(\.domain) == [refusal.domain] && failures.map(\.code) == [refusal.code])
        let bindings = try await NativeKeyboardBindings(runtime: runtime)
        let translator = try bindings.makeTranslator()
        _ = try translator.reports(for: keys[0])
        var requests: [NativeSwiftValue] = []
        for _ in 0..<2 { requests.append(try await wire.createService(bindings.mainKeyboardDescriptor())) }
        requests += try translator.reports(for: keys[1]).map { try wire.send($0, to: 7) }
        requests += try [wire.request("resetGestureState", service: 7), wire.request("removeService", service: 7)]
        let expected = try requests.map { try codec.message(.request, to: universalHID, payload: $0) }
        let messages = await peers.messages(to: universalHID, count: expected.count)
        withExtendedLifetime(keyboard) {}
        #expect(messages.count == expected.count && zip(messages, expected).allSatisfy { xpc_equal($0, $1) })
    }

    @Test func nativeTrackpadGesturesBeginWhereTheScreenNowShowsTheStillPointer() async throws {
        let runtime = ABIRuntime.shared
        let transport = TrackpadFixtureTransport(bindings: try await NativeTrackpadBindings(runtime: runtime))
        let trackpad = NativeDeviceTrackpad(gestures: NativeTrackpadGestures { transport })
        var failures: [String] = []
        trackpad.onFailure = { failures.append($0.localizedDescription) }
        let placement = try GuestPointerReports(runtime: runtime).placement

        // A mouse movement places the trackpad's hidden pointer. The canvas then moves the screen under the still Mac
        // pointer, so a scroll, a pinch, and each of a mouse wheel's events first move the hidden pointer to what the
        // screen now shows under the Mac pointer. A gesture's later steps, including its momentum, stay where it began
        // even when the canvas moves meanwhile.
        trackpad.handle(try mouseMovement(sender: 0xA), coordinateTransform: CGAffineTransform(scaleX: 1 / 2000, y: 1 / 2000))
        let scroll = try trackpadScroll(.began, delta: -10, sender: 0xA)
        let pinch = try trackpadPinch(.began, sender: 0xA)
        let wheel = try trackpadScroll(nil, units: .line, delta: -3, sender: 0xA)
        let panned = showing(CGPoint(x: 0.3, y: 0.8), at: scroll), zoomed = showing(CGPoint(x: 0.6, y: 0.2), at: pinch)
        for (event, transform) in try [(scroll, panned), (trackpadScroll(.changed, delta: -30, sender: 0xA), zoomed),
                                       (trackpadScroll(nil, momentum: .begin, delta: -20, sender: 0xA), zoomed), (pinch, zoomed),
                                       (trackpadPinch(.changed, magnification: 0.2, sender: 0xA), panned),
                                       (wheel, showing(CGPoint(x: 0.5, y: 0.4), at: wheel))] {
            trackpad.handle(event, coordinateTransform: transform)
        }
        try await trackpad.stop()
        let placements = try #require(transport.services.first).sent.dropFirst().map(placement)
        #expect(placements == [CGPoint(x: 0.3, y: 0.8), nil, nil, nil, CGPoint(x: 0.6, y: 0.2), nil, nil, CGPoint(x: 0.5, y: 0.4), nil],
                "Failures \(failures)")
    }

    @Test func remotePinchesBeginWhereTheScreenNowShowsTheStillPointer() async throws {
        let trackpads = TrackpadFixtureTransport(bindings: try await NativeTrackpadBindings(runtime: .shared))
        let transport = ScreenFixtureTransport()
        transport.gestures = NativeTrackpadGestures { trackpads }
        let session = RemoteDeviceScreenSession(device: try device()) { _, _, _ in transport }
        try await session.start()
        let placement = try GuestPointerReports(runtime: .shared).placement

        // Without a pointer connection, as on a resized app's dedicated display, a mouse movement places the trackpad's
        // hidden pointer. The canvas then moves the screen under the still Mac pointer, so a pinch first moves the hidden
        // pointer to what the screen shows there as the pinch begins. Its later steps stay where it began.
        transport.inputCapabilities = [.digitizer, .gesture]
        let movement = try mouseMovement(sender: 0xA)
        transport.pointerTransform = CGAffineTransform(scaleX: 1 / 2000, y: 1 / 2000)
        try await session.moveGesturePointer(with: movement,
                                             at: #require(session.inputLocations(atWindowPoint: movement.locationInWindow)))
        let pinch = try trackpadPinch(.began, sender: 0xA)
        transport.pointerTransform = showing(CGPoint(x: 0.6, y: 0.2), at: pinch)
        try await session.sendPinch(pinch)
        transport.pointerTransform = showing(CGPoint(x: 0.3, y: 0.8), at: pinch)
        for event in try [trackpadPinch(.changed, magnification: 0.2, sender: 0xA), trackpadPinch(.ended, sender: 0xA)] {
            try await session.sendPinch(event)
        }
        // On a screen with a pointer connection, mouse movements move that pointer instead, and pinches leave the hidden one.
        transport.inputCapabilities.insert(.pointer)
        try await session.sendPinch(trackpadPinch(.began, sender: 0xA))
        try await session.stop()
        let placements = try #require(trackpads.services.first).sent.dropFirst().map(placement)
        #expect(placements == [CGPoint(x: 0.6, y: 0.2), nil, nil, nil, nil])
    }

    @Test func failedHIDServiceRemovalKeepsTheOwnedServiceForCleanupRetry() async throws {
        var removes = 0
        var resets = 0
        let service = CoreDeviceHIDService(send: { _ in }, reset: {
            resets += 1
            throw ScreenFixtureError.stream
        }, remove: {
            removes += 1
            if removes == 1 { throw ScreenFixtureError.cleanup }
        })
        do { try await service.stop(); Issue.record("Cleanup failure was lost") }
        catch { #expect(error.localizedDescription.contains("fixture stream failed") && error.localizedDescription.contains("fixture cleanup failed")) }
        #expect(!service.isRemoved)
        await #expect(throws: ScreenFixtureError.stream) { try await service.stop() }
        #expect(service.isRemoved && removes == 2 && resets == 2)
        let report = try CoreDeviceDigitizerReports(runtime: .shared).make(point: .zero, second: nil, phase: .began, edge: .none)
        #expect(throws: CLIError.self) { try service.send(report) }
        try await service.stop()
        #expect(removes == 2 && resets == 2)
    }

    @Test func keyboardServicesCarryTheMacKeyboardLayoutAndReportsInCoreDevicesModule() async throws {
        let runtime = ABIRuntime.shared
        let bindings = try await NativeKeyboardBindings(runtime: runtime)
        for (standardType, countryCode) in [(2, 15), (0, 33)] {
            let descriptor = try bindings.descriptor(serviceID: 0x1234, properties: [
                "PrimaryUsagePage": 1, "PrimaryUsage": 6, "DeviceUsagePairs": [["DeviceUsagePage": 1, "DeviceUsage": 6]],
                "StandardType": standardType, "CountryCode": countryCode, "Product": "Fixture Keyboard",
            ])
            let identity = try bindings.identity(of: descriptor)
            #expect(identity.standardType == UInt8(standardType) && identity.countryCode == UInt8(countryCode))
            #expect(identity.isHardwareKeyboard && identity.product == "Fixture Keyboard")
        }
        let main = try bindings.identity(of: bindings.mainKeyboardDescriptor())
        #expect(main.isHardwareKeyboard && main.standardType == nil, "\(main)")
        let report = try CoreDeviceHIDService.reportABI(runtime: runtime)
        let data = try runtime.resolveAndWait(.swift(.type("Foundation.Data")))
        let readData = try report.type.resolveAndWait(.swift(.getter("data", as: (() -> Data).self,
            valueABIs: [report.type: report.abi, data: try .structure(named: data.name, fields: [.uint64, .uint64])],
            receiverABI: report.abi)))
        let translator = try bindings.makeTranslator()
        // Eisu exists only on JIS keyboards; its press and release must both reach CoreDevice's keyboard service.
        let reports = try [NSEvent.EventType.keyDown, .keyUp].map { type in
            let event = try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 1, windowNumber: 0,
                context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(kVK_JIS_Eisu)))
            #expect(try bindings.lookup.sender(of: event) == 0)
            let values = try translator.reports(for: event)
            #expect(values.count == 1 && values.allSatisfy { $0.type == report.type })
            return try values.map { try unsafe readData.unsafeInvoke(on: $0) }
        }
        #expect(reports[0] != reports[1])
    }

    @Test(.enabled(if: !macKeyboardLayouts.isEmpty, "Requires a Mac keyboard whose HID service publishes StandardType"))
    func keyboardServicesCarryTheLayoutEachMacKeyboardPublishes() async throws {
        let bindings = try await NativeKeyboardBindings(runtime: .shared)
        for layout in macKeyboardLayouts {
            let properties = try #require(try bindings.lookup.properties(ofHIDService: layout.serviceID))
            let identity = try bindings.identity(of: bindings.descriptor(serviceID: layout.serviceID, properties: properties))
            #expect(identity.standardType == layout.standardType, "Registry entry 0x\(String(layout.serviceID, radix: 16)): \(identity)")
        }
    }

    @Test func nativeKeyboardKeepsEachMacKeyboardsServiceAndSendsSynthesizedReleasesToEachOne() async throws {
        _ = NSApplication.shared
        let transport = KeyboardFixtureTransport()
        let keyboard = NativeDeviceKeyboard(transport: transport)
        var failures: [String] = []
        keyboard.onFailure = { failures.append($0.localizedDescription) }
        let display = NSObject()
        var events: [NSEvent] = []
        func key(_ type: NSEvent.EventType, sender: UInt64 = 0, repeating: Bool = false) throws -> NSEvent {
            let event = try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, characters: type == .flagsChanged ? "" : "a", charactersIgnoringModifiers: type == .flagsChanged ? "" : "a",
                isARepeat: repeating, keyCode: 0))
            // Retaining each event keeps its identity unique.
            events.append(event)
            transport.senders[ObjectIdentifier(event)] = sender
            return event
        }
        keyboard.setEnabled(true, for: display)
        // Before any Mac keyboard sends input, synthesized input, such as automation's, uses the main keyboard.
        let typed = try key(.keyDown)
        keyboard.handle(typed)
        // The main keyboard's removal fails once while the next removal waits for it, which retries it.
        try #require(transport.keyboards.first).stopFailures = 1
        let unknown = try key(.keyUp, sender: 0x99)
        keyboard.handle(unknown)
        // The first Mac keyboard input removes the main keyboard and then receives synthesized input.
        let builtIn = try key(.keyDown, sender: 0xA)
        keyboard.handle(builtIn)
        keyboard.handle(try key(.keyDown, sender: 0xA, repeating: true))
        let syntheticUp = try key(.keyUp)
        keyboard.handle(syntheticUp)
        let external = try key(.keyDown, sender: 0xB)
        keyboard.handle(external)
        // A synthesized release also reaches the keyboards that are no longer active.
        let release = try key(.flagsChanged)
        NSApp.sendEvent(release)
        keyboard.setEnabled(false, for: display)
        NSApp.sendEvent(try key(.flagsChanged))
        try await keyboard.removeServices()
        #expect(transport.keyboards.map(\.sender) == [nil, 0xA, 0xB])
        // Losing the last display releases the key 0xB still holds.
        let keyRelease = try #require(transport.keyboards.last?.events.last)
        #expect(keyRelease.type == .keyUp && keyRelease.keyCode == external.keyCode)
        #expect(transport.keyboards.map { $0.events.map(ObjectIdentifier.init) }
            == [[typed, unknown], [builtIn, syntheticUp, release], [external, release, keyRelease]].map { $0.map(ObjectIdentifier.init) })
        #expect(transport.keyboards.map(\.stops) == [2, 1, 1])

        // After reconnection, synthesized input recreates the active Mac keyboard with released state.
        // Its failures are reported, and a service that could not be removed is removed by the next attempt.
        keyboard.handle(try key(.keyDown))
        let recreated = try #require(transport.keyboards.last)
        recreated.sendFailures = 1
        recreated.stopFailures = 1
        let released = try key(.keyUp, sender: 0xB)
        keyboard.handle(released)
        await #expect(throws: CLIError.self) { try await keyboard.removeServices() }
        try await keyboard.stop()
        #expect(transport.keyboards.map(\.sender) == [nil, 0xA, 0xB, 0xB])
        #expect(recreated.events.map(ObjectIdentifier.init) == [ObjectIdentifier(released)] && recreated.stops == 2)
        #expect(failures == ["fixture cleanup failed", "fixture stream failed"])
        keyboard.handle(try key(.keyDown, sender: 0xA))
        try await keyboard.removeServices()
        #expect(transport.keyboards.count == 4)
    }

    @Test func nativeKeyboardModifiersStayWithTheKeyboardsThatHoldThem() async throws {
        let runtime = ABIRuntime.shared
        let bindings = try await NativeKeyboardBindings(runtime: runtime)
        let report = try CoreDeviceHIDService.reportABI(runtime: runtime)
        let data = try runtime.resolveAndWait(.swift(.type("Foundation.Data")))
        let readData = try report.type.resolveAndWait(.swift(.getter("data", as: (() -> Data).self,
            valueABIs: [report.type: report.abi, data: try .structure(named: data.name, fields: [.uint64, .uint64])],
            receiverABI: report.abi)))
        let translation = {
            let translator = try bindings.makeTranslator()
            return { (event: NSEvent) throws -> [Data] in try translator.reports(for: event).map { try unsafe readData.unsafeInvoke(on: $0) } }
        }
        let transport = KeyboardFixtureTransport()
        transport.makeTranslation = translation
        let keyboard = NativeDeviceKeyboard(transport: transport)
        var failures: [String] = []
        keyboard.onFailure = { failures.append($0.localizedDescription) }
        var events: [NSEvent] = []
        func key(_ type: NSEvent.EventType, _ code: Int, sender: UInt64 = 0, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            let event = try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                context: nil, characters: type == .flagsChanged ? "" : "a", charactersIgnoringModifiers: type == .flagsChanged ? "" : "a",
                isARepeat: false, keyCode: UInt16(code)))
            // Retaining each event keeps its identity unique.
            events.append(event)
            transport.senders[ObjectIdentifier(event)] = sender
            return event
        }
        // Focus synchronizes a Shift held before any Mac keyboard typed, which the main keyboard takes.
        let focus = try key(.flagsChanged, 0, flags: .shift)
        // The first Mac keyboard's key carries Shift, a modifier change its observer has not seen.
        let shifted = [try key(.keyDown, kVK_ANSI_A, sender: 0xA, flags: .shift), try key(.keyUp, kVK_ANSI_A, sender: 0xA, flags: .shift)]
        // Another keyboard types while the first one holds Shift, and then focus is lost.
        let other = [try key(.keyDown, kVK_ANSI_B, sender: 0xB, flags: .shift), try key(.keyUp, kVK_ANSI_B, sender: 0xB, flags: .shift)]
        let lostFocus = try key(.flagsChanged, 0)
        for event in [focus] + shifted + other + [lostFocus] { keyboard.handle(event) }
        try await keyboard.removeServices()

        // The keyboard holding Shift types a shifted key and releases Shift; the other one leaves Shift to it.
        func reports(_ events: [NSEvent]) throws -> [Data] {
            let translate = try translation()
            return try events.flatMap { try translate($0) }
        }
        let expected = [try reports([focus]), try reports([focus] + shifted + [lostFocus]), try reports(other)]
        #expect(transport.keyboards.map(\.sender) == [nil, 0xA, 0xB])
        #expect(transport.keyboards.map(\.reports) == expected)

        // A modifier change carries the modifiers of every Mac keyboard. A modifier one keyboard releases is released on
        // the others too: B types Command-A after A releases Shift, and nothing stays held after B releases Command.
        let commandA = [try key(.keyDown, kVK_ANSI_A, sender: 0xB, flags: .command), try key(.keyUp, kVK_ANSI_A, sender: 0xB, flags: .command)]
        let changes = [try key(.flagsChanged, kVK_Shift, sender: 0xA, flags: .shift),
                       try key(.flagsChanged, kVK_Command, sender: 0xB, flags: [.shift, .command]),
                       try key(.flagsChanged, kVK_Shift, sender: 0xA, flags: .command)]
            + commandA + [try key(.flagsChanged, kVK_Command, sender: 0xB)]
        for event in changes { keyboard.handle(event) }
        try await keyboard.removeServices()
        func holding(_ flags: NSEvent.ModifierFlags) throws -> NSEvent { try key(.flagsChanged, 0, flags: flags) }
        let released = [
            try reports([holding(.shift), holding(.command), holding([])]),
            try reports([holding([.shift, .command]), holding(.command)] + commandA + [holding([])]),
        ]
        #expect(transport.keyboards.dropFirst(3).map(\.reports) == released)
        #expect(failures.isEmpty)
    }

    @Test func nativeKeyboardReleasesHeldKeysWhenTheLastDisplayLosesTheKeyboard() async throws {
        let runtime = ABIRuntime.shared
        let bindings = try await NativeKeyboardBindings(runtime: runtime)
        let report = try CoreDeviceHIDService.reportABI(runtime: runtime)
        let data = try runtime.resolveAndWait(.swift(.type("Foundation.Data")))
        let readData = try report.type.resolveAndWait(.swift(.getter("data", as: (() -> Data).self,
            valueABIs: [report.type: report.abi, data: try .structure(named: data.name, fields: [.uint64, .uint64])],
            receiverABI: report.abi)))
        let translation = {
            let translator = try bindings.makeTranslator()
            return { (event: NSEvent) throws -> [Data] in try translator.reports(for: event).map { try unsafe readData.unsafeInvoke(on: $0) } }
        }
        let transport = KeyboardFixtureTransport()
        transport.makeTranslation = translation
        let keyboard = NativeDeviceKeyboard(transport: transport)
        var failures: [String] = []
        keyboard.onFailure = { failures.append($0.localizedDescription) }
        var events: [NSEvent] = []
        func key(_ type: NSEvent.EventType, _ code: Int, sender: UInt64 = 0, timestamp: TimeInterval = 0) throws -> NSEvent {
            let event = try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: timestamp, windowNumber: 0,
                context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: UInt16(code)))
            // Retaining each event keeps its identity unique.
            events.append(event)
            transport.senders[ObjectIdentifier(event)] = sender
            return event
        }
        let display = NSObject()
        let otherDisplay = NSObject()
        keyboard.setEnabled(true, for: display)
        keyboard.setEnabled(true, for: otherDisplay)
        let held = [try key(.keyDown, kVK_ANSI_A, sender: 0xA), try key(.keyDown, kVK_ANSI_B, sender: 0xB)]
        for event in held { keyboard.handle(event) }
        // While another display has the keyboard, key-ups still arrive there, so the keys stay held.
        keyboard.setEnabled(false, for: otherDisplay)
        let typed = [try key(.keyDown, kVK_ANSI_C, sender: 0xA), try key(.keyUp, kVK_ANSI_C, sender: 0xA)]
        for event in typed { keyboard.handle(event) }
        // The held keys' key-ups reach another window once the last display loses the keyboard.
        keyboard.setEnabled(false, for: display)
        keyboard.setEnabled(true, for: display)
        let next = try key(.keyDown, kVK_ANSI_D, sender: 0xA)
        keyboard.handle(next)
        try await keyboard.removeServices()

        func reports(_ events: [NSEvent]) throws -> [Data] {
            let translate = try translation()
            return try events.flatMap { try translate($0) }
        }
        try #require(transport.keyboards.map(\.sender) == [0xA, 0xB])
        // A report carries its event's time, and each synthesized key-up has the time of the release.
        let releaseTimes = try transport.keyboards.map { service in
            try #require(service.events.first { received in !events.contains { $0 === received } }).timestamp
        }
        // Each keyboard releases its keys and keeps its guest service; the next key is pressed alone.
        let expected = [
            try reports([held[0]] + typed + [key(.keyUp, kVK_ANSI_A, timestamp: releaseTimes[0]), next]),
            try reports([held[1], key(.keyUp, kVK_ANSI_B, timestamp: releaseTimes[1])]),
        ]
        #expect(transport.keyboards.map(\.reports) == expected)
        #expect(transport.keyboards.map(\.stops) == [1, 1])
        #expect(failures.isEmpty)
    }

    private func wait(_ session: RemoteDeviceScreenSession, until condition: @escaping @MainActor () -> Bool) async {
        if condition() { return }
        await withCheckedContinuation { continuation in
            session.onStateChange = {
                if condition() { session.onStateChange = nil; continuation.resume() }
            }
        }
    }

    private func device(identifier: String = "command-identifier") throws -> CoreDeviceDevice {
        let data = Data(#"{"result":{"devices":[{"identifier":"\#(identifier)","properties":{"hardware":{"reality":"physical","udid":"hardware-identifier"},"state":{"name":"Fixture Device"},"connection":{"state":"connected"}},"capabilities":[]}]}}"#.utf8)
        return try #require(CoreDeviceInventoryDecoder.decode(data).first)
    }
}

/// Builds a BGRA frame like the capture output's, optionally without IOSurface backing.
private func capturedFrame(width: Int, height: Int, bgra: [UInt8], ioSurface: Bool = true) throws -> sending CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let attributes: [String: Any] = ioSurface ? [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] : [:]
    let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
    let frame = try #require(buffer, "CoreVideo status \(status)")
    #expect((CVPixelBufferGetIOSurface(frame) != nil) == ioSurface)
    #expect(CVPixelBufferLockBaseAddress(frame, []) == kCVReturnSuccess)
    defer { CVPixelBufferUnlockBaseAddress(frame, []) }
    let base = try #require(CVPixelBufferGetBaseAddress(frame)).assumingMemoryBound(to: UInt8.self)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(frame)
    for row in 0..<height {
        for column in 0..<width {
            for (channel, value) in bgra.enumerated() { base[row * bytesPerRow + column * 4 + channel] = value }
        }
    }
    return frame
}

/// The layouts the Mac's keyboard HID services publish in their registry entries, independently of the HID event
/// system, which withholds them from some clients. CountryCode is left out: the HID event system, which Device Hub
/// also reads, can report 0 (not localized) where the registry has a country, and the guest takes the layout from StandardType.
private let macKeyboardLayouts: [(serviceID: UInt64, standardType: UInt8)] = {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDEventService"), &iterator) == KERN_SUCCESS
    else { return [] }
    defer { IOObjectRelease(iterator) }
    var layouts: [(serviceID: UInt64, standardType: UInt8)] = []
    while case let entry = IOIteratorNext(iterator), entry != IO_OBJECT_NULL {
        defer { IOObjectRelease(entry) }
        func property(_ key: String) -> Int? {
            IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
        }
        var serviceID: UInt64 = 0
        guard property(kIOHIDPrimaryUsagePageKey) == kHIDPage_GenericDesktop, property(kIOHIDPrimaryUsageKey) == kHIDUsage_GD_Keyboard,
              let standardType = property(kIOHIDStandardTypeKey).flatMap(UInt8.init(exactly:)),
              IORegistryEntryGetRegistryEntryID(entry, &serviceID) == KERN_SUCCESS else { continue }
        layouts.append((serviceID, standardType))
    }
    return layouts
}()

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
private final class KeyboardFixtureTransport: NativeKeyboardTransport {
    final class Keyboard: NativeKeyboardService {
        /// Nil for the main keyboard.
        let sender: UInt64?
        /// The real translation into report bytes, when the fixture has one.
        let translate: ((NSEvent) throws -> [Data])?
        /// Retained, so that the synthesized events the test does not retain also keep unique identities.
        var events: [NSEvent] = []
        var reports: [Data] = []
        private(set) var modifierFlags: NSEvent.ModifierFlags = []
        private(set) var heldKeyCodes: Set<UInt16> = []
        var stops = 0
        var sendFailures = 0
        var stopFailures = 0
        init(sender: UInt64?, translate: ((NSEvent) throws -> [Data])?) {
            self.sender = sender
            self.translate = translate
        }
        func send(_ event: NSEvent) async throws {
            if sendFailures > 0 { sendFailures -= 1; throw ScreenFixtureError.stream }
            events.append(event)
            if let translate { reports += try translate(event) }
            switch event.type {
            case .flagsChanged: modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            case .keyDown: heldKeyCodes.insert(event.keyCode)
            case .keyUp: heldKeyCodes.remove(event.keyCode)
            default: break
            }
        }
        func stop() async throws {
            stops += 1
            if stopFailures > 0 { stopFailures -= 1; throw ScreenFixtureError.cleanup }
        }
    }

    /// Synthesized events have no sender, as AppKit creates them.
    var senders: [ObjectIdentifier: UInt64] = [:]
    let macSenders: Set<UInt64> = [0xA, 0xB]
    /// Gives each keyboard its own translation, as each real keyboard has its own observer.
    var makeTranslation: (() throws -> (NSEvent) throws -> [Data])?
    var keyboards: [Keyboard] = []

    func sender(of event: NSEvent) throws -> UInt64 { senders[ObjectIdentifier(event)] ?? 0 }

    func makeKeyboard(forSender sender: UInt64) throws -> (any NativeKeyboardService)? {
        guard macSenders.contains(sender) else { return nil }
        let keyboard = Keyboard(sender: sender, translate: try makeTranslation?())
        keyboards.append(keyboard)
        return keyboard
    }

    func makeMainKeyboard() throws -> any NativeKeyboardService {
        let keyboard = Keyboard(sender: nil, translate: try makeTranslation?())
        keyboards.append(keyboard)
        return keyboard
    }
}

/// Stands in for the device's service creation; the senders and gesture translation are UniversalHIDKit's own.
@MainActor
private final class TrackpadFixtureTransport: NativeTrackpadTransport {
    final class Service {
        let sender: UInt64
        /// The reports the device received, in order.
        var sent: [NativeSwiftValue] = []
        var reports: Int { sent.count }
        var sendFailures = 0
        var resets = 0
        var removes = 0
        var removeFailures = 0
        init(sender: UInt64) { self.sender = sender }
    }

    private let bindings: NativeTrackpadBindings
    /// The registry IDs of the Mac's HID services.
    let macSenders: Set<UInt64> = [0xA, 0xB]
    /// Holds a service's creation, whose reply the device sends after other input can arrive.
    var connecting: ScreenFixtureGate?
    private(set) var lookups: [UInt64] = []
    private(set) var services: [Service] = []

    init(bindings: NativeTrackpadBindings) { self.bindings = bindings }

    func sender(of event: NSEvent) throws -> UInt64 { try bindings.lookup.sender(of: event) }

    func connect(sender: UInt64) async throws -> NativeTrackpadGestures.Service? {
        lookups.append(sender)
        guard macSenders.contains(sender) else { return nil }
        await connecting?.hold()
        let record = Service(sender: sender)
        services.append(record)
        let service = CoreDeviceHIDService(send: { report in
            if record.sendFailures > 0 { record.sendFailures -= 1; throw ScreenFixtureError.stream }
            record.sent.append(report)
        }, reset: { record.resets += 1 }, remove: {
            record.removes += 1
            if record.removeFailures > 0 { record.removeFailures -= 1; throw ScreenFixtureError.cleanup }
        })
        return (service, try bindings.makeTranslator())
    }
}

/// The registry IDs of the trackpad services that the HID event system lists, where a trackpad's multitouch device
/// rather than its registry event driver is the touch pad.
private let macTrackpads: [UInt64] = {
    let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
    let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []
    return services.filter { IOHIDServiceClientConformsTo($0, UInt32(kHIDPage_Digitizer), UInt32(kHIDUsage_Dig_TouchPad)) != 0 }
        .compactMap { (IOHIDServiceClientGetRegistryID($0) as? NSNumber)?.uint64Value }
}()

/// What a guest service descriptor tells the guest about the service and its pointer.
@MainActor
private struct GuestPointerService {
    let serviceID: UInt64
    let isPointer: Bool
    let hidesPointer: Bool?
    let routesPastShellPolicy: Bool?

    init(_ descriptor: NativeSwiftValue) throws {
        let runtime = ABIRuntime.shared
        let descriptorType = try runtime.resolveAndWait(.swift(.type("CoreDevice.HIDServiceDescriptor")))
        let serviceIDType = try runtime.resolveAndWait(.swift(.type("CoreDevice.HIDServiceID")))
        let abis: [NativeSwiftType: NativeType] = [descriptorType: try .opaque(named: descriptorType.name),
                                                   serviceIDType: try .opaque(named: serviceIDType.name)]
        func read<Value>(_ name: String, as _: Value.Type) throws -> Value {
            let getter = try descriptorType.resolveAndWait(.swift(.getter(name, as: (() -> Value).self,
                valueABIs: abis, receiverABI: abis[descriptorType])))
            return try unsafe getter.unsafeInvoke(on: descriptor)
        }
        let readID = try serviceIDType.resolveAndWait(.swift(.getter("id", as: (() -> UInt64).self,
            valueABIs: abis, receiverABI: abis[serviceIDType])))
        serviceID = try unsafe readID.unsafeInvoke(on: read("serviceID", as: NativeSwiftValue.self))
        isPointer = try read("isBackBoardPointer", as: Bool.self)
        hidesPointer = try read("suppressMousePointer", as: Bool?.self)
        routesPastShellPolicy = try read("routeEventsIgnoringSystemShellPolicy", as: Bool?.self)
    }
}

/// Reads where the reports that a guest trackpad service receives move its hidden pointer.
private struct GuestPointerReports {
    private let pointerID: UInt8
    private let rawID: NativeSwiftMethod<() -> UInt8>
    private let readID: NativeSwiftMethod<() -> NativeSwiftValue>
    private let makePointer: NativeSwiftFunction<(NativeSwiftValue) -> NativeSwiftValue>
    private let pointerX: NativeSwiftMethod<() -> Double>
    private let pointerY: NativeSwiftMethod<() -> Double>

    @MainActor init(runtime: ABIRuntime) throws {
        let report = try CoreDeviceHIDService.reportABI(runtime: runtime)
        let pointer = try CoreDeviceHIDService.universalHIDType("AbsolutePointerReport", runtime: runtime)
        let reportID = try CoreDeviceHIDService.universalHIDType("ReportID", runtime: runtime)
        let abis: [NativeSwiftType: NativeType] = [
            report.type: report.abi,
            pointer: try .structure(named: pointer.name, fields: [.uint64, .uint64]),
            reportID: try .structure(named: reportID.name, fields: [.uint8]),
        ]
        rawID = try reportID.resolveAndWait(.swift(.getter("rawValue", as: (() -> UInt8).self, valueABIs: abis, receiverABI: abis[reportID])))
        readID = try report.type.resolveAndWait(.swift(.getter("reportID", as: (() -> NativeSwiftValue).self, valueABIs: abis, receiverABI: report.abi)))
        pointerID = try unsafe rawID.unsafeInvoke(on: pointer.resolveAndWait(.swift(.staticGetter("reportID",
            as: (() -> NativeSwiftValue).self, valueABIs: abis))).unsafeInvoke())
        makePointer = try pointer.resolveAndWait(.swift(.initializer("init(_report:)", as: ((NativeSwiftValue) -> NativeSwiftValue).self, valueABIs: abis)))
        pointerX = try pointer.resolveAndWait(.swift(.getter("x", as: (() -> Double).self, valueABIs: abis, receiverABI: abis[pointer])))
        pointerY = try pointer.resolveAndWait(.swift(.getter("y", as: (() -> Double).self, valueABIs: abis, receiverABI: abis[pointer])))
    }

    /// Where `report` moves the service's hidden pointer, to the nearest thousandth, or nil for a gesture's report.
    func placement(_ report: NativeSwiftValue) throws -> CGPoint? {
        guard try unsafe rawID.unsafeInvoke(on: readID.unsafeInvoke(on: report)) == pointerID else { return nil }
        let position = try unsafe makePointer.unsafeInvoke(report)
        return try unsafe CGPoint(x: (pointerX.unsafeInvoke(on: position) * 1000).rounded() / 1000,
                                  y: (pointerY.unsafeInvoke(on: position) * 1000).rounded() / 1000)
    }
}

/// Anonymous XPC listeners that stand in for the guest's HID services, one for each Mach service name that is looked up.
/// The production connections reach them as they reach the guest's own services.
@MainActor
private final class GuestHIDPeerFixture {
    /// The Mach service names looked up, in order.
    private(set) var lookUps: [String] = []
    /// Fills the reply to each message that expects one, before the service sends it.
    var reply: (@MainActor (xpc_object_t) throws -> Void)?
    private var connections: [xpc_connection_t] = []
    private var received: [String: [xpc_object_t]] = [:]
    private var waiters: [(name: String, count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    isolated deinit { connections.forEach(xpc_connection_cancel) }

    /// A connection, not yet activated, to a new listener for the service `name`.
    func connect(_ name: String) throws -> xpc_connection_t {
        lookUps.append(name)
        let listener = xpc_connection_create(nil, .main)
        xpc_connection_set_event_handler(listener) { [weak self] peer in
            guard xpc_get_type(peer) == XPC_TYPE_CONNECTION else { return }
            nonisolated(unsafe) let connection = peer
            MainActor.assumeIsolated { self?.accept(connection, for: name) }
        }
        xpc_connection_activate(listener)
        connections.append(listener)
        return xpc_connection_create_from_endpoint(xpc_endpoint_create(listener))
    }

    /// The messages that the service `name` received, once it has received `count`.
    func messages(to name: String, count: Int) async -> [xpc_object_t] {
        if received[name, default: []].count < count {
            await withCheckedContinuation { waiters.append((name, count, $0)) }
        }
        return received[name, default: []]
    }

    private func accept(_ peer: xpc_connection_t, for name: String) {
        connections.append(peer)
        xpc_connection_set_target_queue(peer, .main)
        xpc_connection_set_event_handler(peer) { [weak self] message in
            guard xpc_get_type(message) == XPC_TYPE_DICTIONARY else { return }
            nonisolated(unsafe) let received = message
            MainActor.assumeIsolated { self?.receive(received, for: name) }
        }
        xpc_connection_activate(peer)
    }

    private func receive(_ message: xpc_object_t, for name: String) {
        received[name, default: []].append(message)
        if let response = xpc_dictionary_create_reply(message), let peer = xpc_dictionary_get_remote_connection(message) {
            do { try reply?(response) } catch { Issue.record(error) }
            xpc_connection_send_message(peer, response)
        }
        let count = received[name, default: []].count
        let ready = waiters.filter { $0.name == name && $0.count <= count }
        waiters.removeAll { $0.name == name && $0.count <= count }
        ready.forEach { $0.continuation.resume() }
    }
}

/// The UniversalHID requests that CoreDevice sends the guest, made from CoreDeviceUtilities' cases, and the replies that
/// the guest sends, written with Mercury's encoder in the form that CoreDevice decodes.
@MainActor
private struct UniversalHIDFixtureMessages {
    private let requestType: NativeSwiftType
    private let errorKey: String
    private let makeServiceID: NativeSwiftFunction<(UInt64) -> NativeSwiftValue>
    private let makeCreated: NativeSwiftFunction<(NativeSwiftValue) -> NativeSwiftValue>
    private let makeErrorContainer: NativeSwiftFunction<(NSError) -> NativeSwiftValue>
    private let encodeCreated: (NativeSwiftValue, xpc_object_t) throws -> Void
    private let encodeError: (NativeSwiftValue) throws -> xpc_object_t
    private let readData: NativeSwiftMethod<() -> Data>

    init(runtime: ABIRuntime) throws {
        requestType = try runtime.resolveAndWait(.swift(.type("CoreDeviceUtilities.DDIUniversalHIDServicePayload.Request")))
        let event = try runtime.resolveAndWait(.swift(.type("CoreDeviceUtilities.HIDXPCServiceEvent")))
        errorKey = try unsafe event.resolveAndWait(.swift(.staticGetter("errorFieldName", as: (() -> String).self))).unsafeInvoke()
        let serviceID = try runtime.resolveAndWait(.swift(.type("CoreDevice.HIDServiceID")))
        let created = try runtime.resolveAndWait(.swift(.type("CoreDeviceUtilities.DDIUniversalHIDServicePayload.CreatedServiceID")))
        let container = try runtime.resolveAndWait(.swift(.type("Mercury.NSErrorContainer")))
        let abis = try Dictionary(uniqueKeysWithValues: [serviceID, created, container].map { ($0, try NativeType.opaque(named: $0.name)) })
        makeServiceID = try serviceID.resolveAndWait(.swift(.initializer("init(id:)", as: ((UInt64) -> NativeSwiftValue).self,
            valueABIs: abis)))
        makeCreated = try created.resolveAndWait(.swift(.initializer("init(serviceID:)",
            as: ((NativeSwiftValue) -> NativeSwiftValue).self, valueABIs: abis)))
        makeErrorContainer = try container.resolveAndWait(.swift(.initializer("init(rawValue:)",
            as: ((NSError) -> NativeSwiftValue).self, valueABIs: abis)))
        let encoder = try runtime.resolveAndWait(.swift(.type("Mercury.XPCObjectEncoder")))
        let makeEncoder = try encoder.resolveAndWait(.swift(.initializer("init()", as: (() -> NativeSwiftValue).self)))
        let encodeInto = try encoder.resolveAndWait(.swift(.method(
            "Mercury.XPCObjectEncoder.encode<A where A: Swift.Encodable>(_: A, into: __C.OS_xpc_object) throws -> ()",
            as: ((NativeSwiftValue, xpc_object_t) throws -> Void).self, genericArguments: [.type(created)])))
        let encode = try encoder.resolveAndWait(.swift(.method(
            "Mercury.XPCObjectEncoder.encode<A where A: Swift.Encodable>(A) throws -> __C.OS_xpc_object",
            as: ((NativeSwiftValue) throws -> xpc_object_t).self, genericArguments: [.type(container)])))
        encodeCreated = { value, reply in try unsafe encodeInto.unsafeInvoke(on: makeEncoder.unsafeInvoke(), value, reply) }
        encodeError = { value in try unsafe encode.unsafeInvoke(on: makeEncoder.unsafeInvoke(), value) }
        let report = try CoreDeviceHIDService.reportABI(runtime: runtime)
        let data = try runtime.resolveAndWait(.swift(.type("Foundation.Data")))
        readData = try report.type.resolveAndWait(.swift(.getter("data", as: (() -> Data).self,
            valueABIs: [report.type: report.abi, data: try .structure(named: data.name, fields: [.uint64, .uint64])],
            receiverABI: report.abi)))
    }

    /// Fills `reply` with the ID of the service it created, which CoreDevice decodes from the reply itself.
    func create(_ reply: xpc_object_t, id: UInt64) throws {
        let value = try unsafe makeCreated.unsafeInvoke(makeServiceID.unsafeInvoke(id))
        try encodeCreated(value, reply)
    }

    /// Fills `reply` with the guest's `error`, which CoreDevice decodes from the reply's error field.
    func refuse(_ reply: xpc_object_t, with error: NSError) throws {
        let container = try unsafe makeErrorContainer.unsafeInvoke(error)
        let encoded = try encodeError(container)
        xpc_dictionary_set_value(reply, errorKey, encoded)
    }

    func createService(_ descriptor: NativeSwiftValue) async throws -> NativeSwiftValue {
        try await requestType.makeEnumCase(named: "createService", payload: descriptor)
    }

    /// The request that sends `report`, a report of CoreDevice's UniversalHID module, to the service `id`.
    func send(_ report: NativeSwiftValue, to id: UInt64) throws -> NativeSwiftValue {
        let data = try unsafe readData.unsafeInvoke(on: report)
        let serviceID = try unsafe makeServiceID.unsafeInvoke(id)
        return try requestType.makeEnumCaseAndWait(named: "send", associatedValues: data, serviceID)
    }

    /// The request of the case `name` whose only associated value is the service `id`.
    func request(_ name: String, service id: UInt64) throws -> NativeSwiftValue {
        let serviceID = try unsafe makeServiceID.unsafeInvoke(id)
        return try requestType.makeEnumCaseAndWait(named: name, payload: serviceID)
    }
}

/// The Indigo events that CoreDevice's digitizer and button services send, made with CoreDeviceUtilities' initializers
/// from the names of their native cases.
@MainActor
private struct IndigoFixtureEvents {
    private let eventType: NativeSwiftType
    private let edge: NativeSwiftType
    private let target: NativeSwiftType
    private let state: NativeSwiftType
    private let makePoint: NativeSwiftFunction<(CGFloat, CGFloat) -> NativeSwiftValue>
    private let makeTouch: NativeSwiftFunction<(NativeSwiftValue, NativeSwiftValue?, NativeSwiftValue, NativeSwiftValue, NativeSwiftValue) -> NativeSwiftValue>
    private let makeButton: NativeSwiftFunction<(UInt16, UInt16, NativeSwiftValue) -> NativeSwiftValue>

    init(runtime: ABIRuntime) throws {
        let point = try runtime.resolveAndWait(.swift(.type("CoreDevice.DigitizerPoint")))
        let touch = try runtime.resolveAndWait(.swift(.type("CoreDeviceUtilities.IndigoDigitizerEvent")))
        let button = try runtime.resolveAndWait(.swift(.type("CoreDeviceUtilities.IndigoButtonEvent")))
        eventType = try runtime.resolveAndWait(.swift(.type("CoreDevice.DigitizerEventType")))
        edge = try runtime.resolveAndWait(.swift(.type("CoreDevice.DigitizerEdge")))
        target = try runtime.resolveAndWait(.swift(.type("CoreDevice.DigitizerTarget")))
        state = try runtime.resolveAndWait(.swift(.type("CoreDevice.HIDButtonState")))
        let abis = try Dictionary(uniqueKeysWithValues: [point, touch, button, eventType, edge, target, state]
            .map { ($0, try NativeType.opaque(named: $0.name)) })
        makePoint = try point.resolveAndWait(.swift(.initializer("init(x:y:)", as: ((CGFloat, CGFloat) -> NativeSwiftValue).self,
            valueABIs: abis)))
        makeTouch = try touch.resolveAndWait(.swift(.initializer("init(pointOne:pointTwo:eventType:edge:target:)",
            as: ((NativeSwiftValue, NativeSwiftValue?, NativeSwiftValue, NativeSwiftValue, NativeSwiftValue) -> NativeSwiftValue).self,
            valueABIs: abis)))
        makeButton = try button.resolveAndWait(.swift(.initializer("init(usagePage:usageCode:state:)",
            as: ((UInt16, UInt16, NativeSwiftValue) -> NativeSwiftValue).self, valueABIs: abis)))
    }

    /// A touch on the integrated screen.
    func touch(_ point: CGPoint, _ second: CGPoint?, _ type: String, edge side: String) throws -> NativeSwiftValue {
        try unsafe makeTouch.unsafeInvoke(makePoint.unsafeInvoke(point.x, point.y),
            second.map { try unsafe makePoint.unsafeInvoke($0.x, $0.y) }, eventType.makeEnumCase(named: type),
            edge.makeEnumCase(named: side), target.makeEnumCase(named: "mainScreen"))
    }

    func button(_ page: UInt16, _ usage: UInt16, _ buttonState: String) throws -> NativeSwiftValue {
        try unsafe makeButton.unsafeInvoke(page, usage, state.makeEnumCase(named: buttonState))
    }
}

/// The pointer transform of a screen that the canvas turned, scaled, and moved so that it shows `target` at `event`'s
/// window location.
@MainActor
private func showing(_ target: CGPoint, at event: NSEvent) -> CGAffineTransform {
    let turn = CGAffineTransform(a: 0, b: 1 / 600, c: -1 / 300, d: 0, tx: 0, ty: 0)
    let turned = event.locationInWindow.applying(turn)
    return turn.concatenating(CGAffineTransform(translationX: target.x - turned.x, y: target.y - turned.y))
}

/// The gesture phases of a trackpad's magnify events.
private enum TrackpadPinchPhase: Int64 { case began = 1, changed = 2, ended = 4, cancelled = 8 }

/// AppKit makes a trackpad's magnify event from a zoom gesture, IOHIDEvent type 8, with its phase and magnification.
/// UniversalHIDKit reads the event's sender, the registry ID of the Mac HID service that sent it, from CGEvent field 87;
/// a synthesized event leaves it 0.
private func trackpadPinch(_ phase: TrackpadPinchPhase, magnification: Double = 0, sender: UInt64?) throws -> NSEvent {
    let event = try #require(CGEvent(source: nil))
    event.type = try #require(CGEventType(rawValue: 29))
    event.setIntegerValueField(try #require(CGEventField(rawValue: 110)), value: 8)
    event.setIntegerValueField(try #require(CGEventField(rawValue: 132)), value: phase.rawValue)
    event.setDoubleValueField(try #require(CGEventField(rawValue: 113)), value: magnification)
    if let sender { event.setIntegerValueField(try #require(CGEventField(rawValue: 87)), value: Int64(sender)) }
    return try #require(NSEvent(cgEvent: event))
}

/// A trackpad's two-finger scroll step, or with no phases a mouse wheel's, whose sender UniversalHIDKit reads as it does a pinch's.
private func trackpadScroll(_ phase: CGScrollPhase?, momentum: CGMomentumScrollPhase = .none, units: CGScrollEventUnit = .pixel,
                            delta: Int32 = 0, sender: UInt64?) throws -> NSEvent {
    let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: units, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0))
    event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase?.rawValue ?? 0))
    event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue))
    if let sender { event.setIntegerValueField(try #require(CGEventField(rawValue: 87)), value: Int64(sender)) }
    return try #require(NSEvent(cgEvent: event))
}

/// A mouse movement, whose sender UniversalHIDKit reads as it does a pinch's.
private func mouseMovement(sender: UInt64?) throws -> NSEvent {
    let event = try #require(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: 120, y: 200),
                                     mouseButton: .left))
    if let sender { event.setIntegerValueField(try #require(CGEventField(rawValue: 87)), value: Int64(sender)) }
    return try #require(NSEvent(cgEvent: event))
}

@MainActor
private final class ScreenFixtureTransport: RemoteScreenTransport {
    var inputCapabilities: Set<RemoteDeviceInputKind> = [.keyboard]
    let nativeInputView: NSView? = NSView()
    var canCaptureScreenshot: Bool { !closed }
    var automaticFrames = false
    var failStart = false
    var onCapture: (() async -> Void)?
    var acquireResource: (() async -> ScreenFixtureResource)?
    var ownedResource: ScreenFixtureResource?
    let stopEvents = AsyncStream<Void>.makeStream()
    var recordingHandle: ScreenResizeRecordingHandle?
    var canRecordScreen: Bool { recordingHandle != nil }
    /// The screen's window-to-pointer transform; without one the screen has no input locations.
    var pointerTransform: CGAffineTransform?
    /// Receives the gesture input that CoreDeviceScreenInput sends to the trackpads' services.
    var gestures: NativeTrackpadGestures?
    /// Holds the next input inside `send(_:)` until the gate resumes.
    var holdingSend: ScreenFixtureGate?
    var sendFailures = 0
    /// The touches and buttons that reached the transport, and its releases, in order.
    private(set) var deliveries: [String] = []
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
        if let acquireResource {
            ownedResource = await acquireResource()
            try Task.checkCancellation()
        }
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
        if sendFailures > 0 { sendFailures -= 1; throw ScreenFixtureError.stream }
        if let holdingSend { self.holdingSend = nil; await holdingSend.hold() }
        pressed.record(input)
        switch input {
        case .pinch(let event, let transform): try await gestures?.send(event, coordinateTransform: transform)
        case .gesturePointer(let event, let transform): try await gestures?.movePointer(event, coordinateTransform: transform)
        case .touch(_, _, let phase, _): deliveries.append("touch \(phase.rawValue)")
        case .button(_, _, let state): deliveries.append("button \(state.rawValue)")
        default: break
        }
    }

    func inputLocations(atWindowPoint point: CGPoint, clampingToDisplay: Bool) -> RemoteDeviceInputLocations? {
        pointerTransform.map { RemoteDeviceInputLocations(touch: point.applying($0), pointer: point.applying($0), pointerTransform: $0) }
    }

    func releaseInputs() async throws {
        releases += 1
        deliveries.append("release")
        if failCleanup { throw ScreenFixtureError.cleanup }
        pressed = RemoteScreenPressedInputs()
    }

    func stop() async throws {
        defer { stopEvents.continuation.yield(()) }
        await capabilityObservation?.stop()
        let continuation = pendingStart
        pendingStart = nil
        continuation?.resume(throwing: CancellationError())
        try await releaseInputs()
        try ownedResource?.release()
        ownedResource = nil
        closed = true
    }

    func emit(_ event: RemoteScreenTransportEvent) { events?(event) }
}

extension ScreenFixtureTransport: NativeScreenInputTransport {}

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
    private var eligibilityStream: AsyncThrowingStream<AppResizeEligibility, any Error>?
    let eligibilityUpdates: AsyncThrowingStream<AppResizeEligibility, any Error>.Continuation
    var initialEligibility = AppResizeEligibility.eligible
    var eligibilityError: (any Error)?
    var eligibilityGate: ScreenFixtureGate?
    init() { (eligibilityStream, eligibilityUpdates) = AsyncThrowingStream.makeStream() }
    func eligibility() async throws -> AsyncThrowingStream<AppResizeEligibility, any Error> {
        guard let stream = eligibilityStream else { throw ScreenFixtureError.stream }
        eligibilityStream = nil
        await eligibilityGate?.hold()
        if let eligibilityError { throw eligibilityError }
        eligibilityUpdates.yield(initialEligibility)
        return stream
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
    let invalidationReturns = AsyncStream<Void>.makeStream()
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
    func failUpdates(_ error: any Error) { continuation.finish(throwing: error) }
    func awaitInvalidation() async throws {
        defer { invalidationReturns.continuation.yield(()) }
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
    var stopGate: ScreenFixtureGate?
    private(set) var stops = 0
    func stop() async throws -> RemoteDeviceRecording {
        stops += 1
        await stopGate?.hold()
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

@MainActor
private final class ScreenFixtureResource {
    var failRelease = false
    private(set) var released = false
    func release() throws {
        if failRelease { throw ScreenFixtureError.cleanup }
        released = true
    }
}
