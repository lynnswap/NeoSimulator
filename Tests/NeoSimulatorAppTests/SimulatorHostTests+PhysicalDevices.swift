import ABIBridge
import AppKit
import Darwin
import IOKit.hidsystem
@testable import NeoSimulatorApp
@testable import NeoSimulatorDeviceIO
@testable import NeoSimulatorHostSupport
@testable import NeoSimulatorKit
@testable import NeoSimulatorPresentationAdapters
@testable import NeoSimulatorService
@testable import NeoSimulatorUI
import Observation
import Synchronization
import Testing
import SwiftUI
import Combine
import XCTest
import XPC
@testable import NeoSimulatorManager
@testable import NeoSimulatorInspector
@testable import NeoSimulatorDeviceDisplay
@testable import NeoSimulatorCompactWindow
@testable import NeoSimulatorDeviceScreens

extension SimulatorHostTests {
    @Test func remoteKeyboardForwardsJISLanguageKeysAndTheirReleases() async throws {
        _ = NSApplication.shared
        let data = Data(#"{"result":{"devices":[{"identifier":"fixture-command","properties":{"hardware":{"fidelity":"physical"},"state":{"name":"Fixture"}}}]}}"#.utf8)
        let device = try #require(CoreDeviceInventoryDecoder.decode(data).first)
        let transport = TestRemoteScreenTransport()
        transport.inputCapabilities = [.keyboard]
        let session = RemoteDeviceScreenSession(device: device) { _, _, _ in transport }
        try await session.start()
        let input = RemoteDeviceInputView(session: session)
        input.isInputEnabled = true
        var operations: [@MainActor () async throws -> Void] = []
        input.enqueue = { operations.append($0) }
        for code in [UInt16(0x66), 0x68, 0] {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let event = try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                    timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                    isARepeat: false, keyCode: code))
                if type == .keyDown { input.keyDown(with: event) }
                else { input.keyUp(with: event) }
            }
        }
        input.releaseFocus()
        for operation in operations { try await operation() }
        #expect(transport.keys.map(\.usage) == [0x91, 0x91, 0x90, 0x90, 4, 4])
        #expect(transport.keys.map(\.state) == [.down, .up, .down, .up, .down, .up])
        #expect(transport.inputReleases == 1)
        try await session.stop()
    }

    @Test func remoteScreenForwardsScrollingWithoutLimitingItToTheTouchscreenEdges() async throws {
        _ = NSApplication.shared
        let data = Data(#"{"result":{"devices":[{"identifier":"fixture-command","properties":{"hardware":{"fidelity":"physical"},"state":{"name":"Fixture"}}}]}}"#.utf8)
        let device = try #require(CoreDeviceInventoryDecoder.decode(data).first)
        let transport = TestRemoteScreenTransport()
        transport.inputCapabilities = [.digitizer, .gesture]
        let session = RemoteDeviceScreenSession(device: device) { _, _, _ in transport }
        try await session.start()
        let viewport = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        let input = RemoteDeviceInputView(session: session)
        input.frame = viewport.bounds
        viewport.addSubview(input)
        input.isInputEnabled = true
        var operations: [@MainActor () async throws -> Void] = []
        input.enqueue = { operations.append($0) }
        let display = CGRect(x: 100, y: 100, width: 200, height: 400)
        transport.locate = { point, clamping in
            clamping || display.contains(point) ? RemoteDeviceInputLocations(touch: point, pointer: point, pointerTransform: .identity) : nil
        }
        #expect(input.hitTest(NSPoint(x: 50, y: 300)) == nil)
        #expect(input.hitTest(NSPoint(x: 200, y: 300)) === input)
        transport.locate = { point, _ in RemoteDeviceInputLocations(touch: point, pointer: point, pointerTransform: .identity) }
        func scroll(_ phase: CGScrollPhase?, momentum: CGMomentumScrollPhase = .none, dx: Int32 = 0) throws -> NSEvent {
            let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: dx, wheel3: 0))
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase?.rawValue ?? 0))
            event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue))
            return try #require(NSEvent(cgEvent: event))
        }
        func send() async throws {
            for operation in operations { try await operation() }
            operations.removeAll()
        }
        // A long swipe exceeds the visible screen, and its momentum continues after the fingers lift.
        let events = try [scroll(.began, dx: 2), scroll(.changed, dx: 1200), scroll(.ended),
                          scroll(nil, momentum: .begin, dx: 40), scroll(nil, momentum: #require(CGMomentumScrollPhase(rawValue: 2)), dx: 20),
                          scroll(nil, momentum: .end)]
        for event in events { input.scrollWheel(with: event) }
        try await send()
        #expect(transport.trackpadEvents.map(ObjectIdentifier.init) == events.map(ObjectIdentifier.init))
        #expect(transport.touches.isEmpty)

        // Losing focus ends the device's gesture and excludes its remaining events.
        let unfocused = try scroll(.began, dx: -2)
        input.scrollWheel(with: unfocused)
        try await send()
        input.releaseFocus()
        for event in try [scroll(.changed, dx: -1000), scroll(.ended), scroll(nil, momentum: .end)] {
            input.scrollWheel(with: event)
        }
        try await send()
        #expect(transport.trackpadEvents.count == events.count + 1)
        #expect(transport.inputReleases == 1)

        let lost = try scroll(.began, dx: 2)
        input.scrollWheel(with: lost)
        try await send()
        input.invalidateInputs(for: [.gesture])
        for event in try [scroll(.changed, dx: 1000), scroll(.ended)] { input.scrollWheel(with: event) }
        try await send()
        #expect(transport.trackpadEvents.map(ObjectIdentifier.init) == (events + [unfocused, lost]).map(ObjectIdentifier.init))
        try await session.stop()
    }

    @Test func aTrackpadPinchOverTheRemoteScreenPinchesTheDeviceUntilItEndsOrTheScreenLosesInput() async throws {
        _ = NSApplication.shared
        let data = Data(#"{"result":{"devices":[{"identifier":"fixture-command","properties":{"hardware":{"fidelity":"physical"},"state":{"name":"Fixture"}}}]}}"#.utf8)
        let device = try #require(CoreDeviceInventoryDecoder.decode(data).first)
        let transport = TestRemoteScreenTransport()
        transport.inputCapabilities = [.digitizer, .gesture]
        let session = RemoteDeviceScreenSession(device: device) { _, _, _ in transport }
        try await session.start()
        let canvas = MagnifyingCanvasFixture(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        let input = RemoteDeviceInputView(session: session)
        input.frame = canvas.bounds
        canvas.addSubview(input)
        input.isInputEnabled = true
        var operations: [@MainActor () async throws -> Void] = []
        input.enqueue = { operations.append($0) }
        func pinch(_ phase: TrackpadPinchPhase, by magnification: Double = 0) throws -> NSEvent {
            try trackpadPinchEvent(phase, magnification: magnification)
        }
        func send() async throws {
            for operation in operations { try await operation() }
            operations.removeAll()
        }
        // A pinch that begins beside the display magnifies the canvas.
        transport.locate = { _, _ in nil }
        let beside = try [pinch(.began), pinch(.changed, by: 0.2), pinch(.ended)]
        for event in beside { input.magnify(with: event) }

        // Over the display, the device performs the trackpad's pinch until it ends or is cancelled.
        transport.locate = { point, _ in RemoteDeviceInputLocations(touch: point, pointer: point, pointerTransform: .identity) }
        let ended = try [pinch(.began), pinch(.changed, by: 0.25), pinch(.changed, by: -0.1), pinch(.ended)]
        input.magnify(with: ended[0])
        for event in ended.dropFirst() { input.magnify(with: event) }
        let cancelled = try [pinch(.began), pinch(.cancelled)]
        // Losing focus releases a pinch in progress, and the rest of it reaches neither the device nor the canvas.
        let unfocused = try [pinch(.began), pinch(.changed, by: 0.3)]
        for event in cancelled + unfocused { input.magnify(with: event) }
        try await send()
        input.releaseFocus()
        for event in try [pinch(.changed, by: 0.1), pinch(.ended)] { input.magnify(with: event) }
        try await send()
        #expect(transport.inputReleases == 1)
        // Losing the device's gesture input ends a pinch in progress the same way.
        let lost = try pinch(.began)
        input.magnify(with: lost)
        try await send()
        input.invalidateInputs(for: [.gesture])
        for event in try [pinch(.changed, by: 0.1), pinch(.ended)] { input.magnify(with: event) }
        // Without gesture input, a pinch over the display magnifies the canvas.
        transport.inputCapabilities = [.digitizer]
        let unsupported = try [pinch(.began), pinch(.ended)]
        for event in unsupported { input.magnify(with: event) }
        try await send()

        #expect(transport.trackpadEvents.map(ObjectIdentifier.init) == (ended + cancelled + unfocused + [lost]).map(ObjectIdentifier.init))
        #expect(canvas.magnified.map(ObjectIdentifier.init) == (beside + unsupported).map(ObjectIdentifier.init))
        #expect(transport.touches.isEmpty)
        try await session.stop()
    }

    @Test func mouseMovementsOverTheRemoteScreenMoveItsPointerOrThePointerWhereItsPinchesHappen() async throws {
        _ = NSApplication.shared
        let data = Data(#"{"result":{"devices":[{"identifier":"fixture-command","properties":{"hardware":{"fidelity":"physical"},"state":{"name":"Fixture"}}}]}}"#.utf8)
        let device = try #require(CoreDeviceInventoryDecoder.decode(data).first)
        let transport = TestRemoteScreenTransport()
        let session = RemoteDeviceScreenSession(device: device) { _, _, _ in transport }
        try await session.start()
        let viewport = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        let input = RemoteDeviceInputView(session: session)
        input.frame = viewport.bounds
        viewport.addSubview(input)
        input.isInputEnabled = true
        var operations: [@MainActor () async throws -> Void] = []
        input.enqueue = { operations.append($0) }
        func send() async throws {
            for operation in operations { try await operation() }
            operations.removeAll()
        }
        // The screen's geometry turns, scales, and moves window locations within its display into pointer coordinates.
        let display = CGRect(x: 100, y: 100, width: 200, height: 400)
        let transform = CGAffineTransform(a: 0, b: 1.0 / 200, c: -1.0 / 400, d: 0, tx: 1.25, ty: -0.5)
        transport.locate = { point, clamping in
            guard clamping || display.contains(point) else { return nil }
            let mapped = point.applying(transform)
            let pointer = CGPoint(x: min(max(mapped.x, 0), 1), y: min(max(mapped.y, 0), 1))
            return RemoteDeviceInputLocations(touch: point, pointer: pointer, pointerTransform: transform)
        }
        func mouseMoved(to point: CGPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                            context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        }
        let inside = try mouseMoved(to: CGPoint(x: 150, y: 200)), beside = try mouseMoved(to: CGPoint(x: 50, y: 200))

        // Without a pointer connection, as on a dedicated display, a movement over the display moves the pointer where the
        // trackpad's gestures happen, with the geometry that places it; a movement beside the display moves nothing.
        transport.inputCapabilities = [.digitizer, .gesture]
        for event in [inside, beside] { input.mouseMoved(with: event) }
        try await send()
        #expect(transport.gesturePointers.map { ObjectIdentifier($0.event) } == [ObjectIdentifier(inside)])
        #expect(transport.gesturePointers.map(\.transform) == [transform])
        // With UniversalHID available, movements still use reports instead of asynchronous pointer requests.
        transport.inputCapabilities = [.pointer, .digitizer, .gesture]
        for event in [inside, beside] { input.mouseMoved(with: event) }
        try await send()
        #expect(transport.pointerMoves.isEmpty && transport.gesturePointers.count == 2)
        func buttonEvents(_ types: [NSEvent.EventType], button: Int64) throws -> [NSEvent] {
            try types.map {
                let location = $0 == types[0] ? inside.locationInWindow : CGPoint(x: 400, y: 700)
                let event = try #require(
                    NSEvent.mouseEvent(
                        with: $0, location: location, modifierFlags: [], timestamp: 0,
                        windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)?.cgEvent)
                event.setIntegerValueField(.mouseEventButtonNumber, value: button)
                return try #require(NSEvent(cgEvent: event))
            }
        }
        let buttons = try buttonEvents([.rightMouseDown, .rightMouseDragged, .rightMouseUp], button: 1)
        input.rightMouseDown(with: buttons[0])
        input.rightMouseDragged(with: buttons[1])
        input.rightMouseUp(with: buttons[2])
        try await send()
        #expect(
            transport.gesturePointers.suffix(3).map { ObjectIdentifier($0.event) } == buttons.map(ObjectIdentifier.init)
        )
        #expect(transport.pointerButtons.isEmpty)
        #expect(
            transport.gesturePointers.suffix(2).allSatisfy {
                $0.event.locationInWindow.applying($0.transform) == CGPoint(x: 0, y: 1)
            })
        // Additional mouse buttons keep their original numbers through the pointer capability.
        let additional = try buttonEvents([.otherMouseDown, .otherMouseDragged, .otherMouseUp], button: 3)
        let nativePointers = transport.gesturePointers.count
        input.otherMouseDown(with: additional[0])
        input.otherMouseDragged(with: additional[1])
        input.otherMouseUp(with: additional[2])
        try await send()
        #expect(
            transport.pointerButtons == [.down, .dragged, .up] && transport.gesturePointers.count == nativePointers)
        // A display without a pointer capability still leaves secondary mouse buttons unavailable.
        transport.inputCapabilities = [.digitizer, .gesture]
        let sentPointers = transport.gesturePointers.count
        input.rightMouseDown(with: buttons[0])
        input.rightMouseUp(with: buttons[2])
        try await send()
        #expect(transport.gesturePointers.count == sentPointers)
        // Devices without UniversalHID retain their pointer capability route.
        transport.inputCapabilities = [.pointer, .digitizer]
        for event in [inside, beside] { input.mouseMoved(with: event) }
        try await send()
        #expect(transport.pointerMoves == [inside.locationInWindow.applying(transform)])
        // Neither touches the screen.
        #expect(transport.touches.isEmpty)
        try await session.stop()
    }

    @Test(arguments: ["search", "screen-to-search", "screen"])
    func remoteAppResizeRestoresOnlyUnchangedScreenFocus(_ focus: String) async throws {
        _ = NSApplication.shared
        let data = Data(#"{"result":{"devices":[{"identifier":"fixture-command","properties":{"hardware":{"fidelity":"physical"},"state":{"name":"Fixture"}}}]}}"#.utf8)
        let device = try #require(CoreDeviceInventoryDecoder.decode(data).first)
        let resize = TestAppResizeTransport()
        let primary = TestRemoteScreenTransport(), dedicated = TestRemoteScreenTransport()
        primary.nativeInputView = InputView()
        dedicated.nativeInputView = InputView()
        let session = RemoteDeviceScreenSession(device: device, makeResizeTransport: { _ in resize }) { _, content, target in
            let transport = target == nil ? primary : dedicated
            if let input = transport.nativeInputView { content.addSubview(input) }
            return transport
        }
        let controller = RemoteDeviceWindowController(device: device, session: session, presentCompactWindow: { _ in })
        let parent = NSViewController()
        parent.view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        let window = KeyPresentationWindow(contentRect: parent.view.frame, styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = parent
        defer { window.close() }
        try await controller.embed(in: parent)
        try await session.start()
        try await wait { session.canResizeApp }
        let search = NSSearchField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        parent.view.addSubview(search)
        try #require(window.makeFirstResponder(search))
        let editor = try #require(window.firstResponder)
        if focus != "search" { try #require(window.makeFirstResponder(primary.nativeInputView)) }
        resize.holdsStart = true
        defer { resize.completeStart() }
        controller.performScreenAction("resizeApp")
        try await wait { resize.startContinuation != nil }
        try #require(resize.startContinuation != nil)
        if focus == "screen-to-search" { try #require(window.makeFirstResponder(search)) }
        resize.completeStart()
        try await wait { session.isResizingApp && controller.isScreenActionEnabled("resizeApp") }
        try #require(session.isResizingApp && controller.isScreenActionEnabled("resizeApp"))
        #expect(window.firstResponder === (focus == "screen" ? dedicated.nativeInputView : editor))
        try await controller.stopAndClose()
    }

    @Test func remoteControlsReturnFromAnAccessoryToTheSameCompactScreen() async throws {
        _ = NSApplication.shared
        let data = Data(#"{"result":{"devices":[{"identifier":"fixture-command","properties":{"hardware":{"fidelity":"physical"},"state":{"name":"Fixture"}}}]}}"#.utf8)
        let device = try #require(CoreDeviceInventoryDecoder.decode(data).first)
        let transport = TestRemoteScreenTransport()
        let session = RemoteDeviceScreenSession(device: device) { _, _, _ in transport }
        let controller = RemoteDeviceWindowController(device: device, session: session, presentCompactWindow: { _ in })
        let controls = DeviceCanvasControls()
        controls.update(supports: { _ in true }, isEnabled: { _ in true }, recordingTitle: "Record Screen")
        controller.canvasControls = controls
        let parent = NSViewController()
        parent.view = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 700))
        let accessory = DeviceCanvasAccessoryViewController()
        var minimumWidth: CGFloat = 0
        accessory.onMinimumWidthChange = { minimumWidth = $0 }
        parent.view.addSubview(accessory.view)
        try await session.start()
        try await controller.embed(in: parent)
        accessory.setControls(controls)
        controller.onChange = { accessory.refresh() }
        #expect(controller.canvasControls === controls && controls.isDescendant(of: accessory.view))
        try await controller.showCompactWindow()
        #expect(accessory.isHidden && minimumWidth == 0)
        accessory.setControls(nil)
        #expect(controller.canvasControls === controls && controls.isDescendant(of: controller.presentationViewController.view))
        #expect(controls.window === controller.window && session.state == .connected)
        let container = try #require(controls.superview)
        container.layoutSubtreeIfNeeded()
        #expect(abs(controls.frame.maxY - container.bounds.maxY) < 1)
        try await controller.embed(in: parent)
        accessory.setControls(controls)
        try await controller.detachPresentation()
        try await controller.showCompactWindow()
        #expect(controller.canvasControls === controls && controls.window === controller.window)
        try await controller.stopAndClose()
    }

    @Test func remoteScreenTakesDroppedAppBundlesAcrossMovesAndReconnects() async throws {
        _ = NSApplication.shared
        let data = Data(#"{"result":{"devices":[{"identifier":"fixture-command","properties":{"hardware":{"fidelity":"physical"},"state":{"name":"Fixture"}}}]}}"#.utf8)
        let device = try #require(CoreDeviceInventoryDecoder.decode(data).first)
        let transport = TestRemoteScreenTransport()
        var connections = 0
        let session = RemoteDeviceScreenSession(device: device) { _, _, _ in
            connections += 1
            return transport
        }
        let controller = RemoteDeviceWindowController(device: device, session: session, presentCompactWindow: { _ in })
        var installable = true
        var installs: [[URL]] = []
        controller.canInstallApplications = { installable }
        controller.installApplications = { installs.append($0) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let application = directory.appendingPathComponent("Fixture.app", isDirectory: true)
        let notes = directory.appendingPathComponent("Notes.txt")
        try FileManager.default.createDirectory(at: application, withIntermediateDirectories: true)
        try Data().write(to: notes)
        defer { try? FileManager.default.removeItem(at: directory) }
        func destination() throws -> NSView {
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let views = descendants(controller.presentationViewController.view).filter { $0.registeredDraggedTypes.contains(.fileURL) }
            try #require(views.count == 1)
            #expect(session.contentView.isDescendant(of: views[0]))
            return views[0]
        }
        func drop(_ urls: [URL], on view: NSView) -> (NSDragOperation, Bool) {
            let info = TestDraggingInfo(urls)
            defer { info.draggingPasteboard.releaseGlobally() }
            return (view.draggingEntered(info), view.performDragOperation(info))
        }
        let parent = NSViewController()
        parent.view = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 700))
        try await session.start()
        try await controller.embed(in: parent)
        let screen = try destination()
        #expect(screen.isDescendant(of: parent.view))
        #expect(drop([application], on: screen) == (.copy, true))
        try await controller.showCompactWindow()
        #expect(try destination() === screen && screen.window === controller.window)
        #expect(drop([application, notes], on: screen) == ([], false))
        installable = false
        #expect(drop([application], on: screen) == ([], false))
        installable = true
        controller.performScreenAction("reconnect")
        try await wait { connections == 2 && session.state == .connected }
        try #require(connections == 2 && session.state == .connected)
        try await controller.embed(in: parent)
        #expect(try destination() === screen && screen.isDescendant(of: parent.view))
        #expect(drop([application], on: screen) == (.copy, true))
        #expect(installs == [[application], [application]])
        try await controller.stopAndClose()
    }

    /// DeviceKit's device view of a folding device brings the rotation and posture controls of its action bar.
    @Test func aRemoteScreenOffersThePoseControlsOfItsConnectedTransport() async throws {
        _ = NSApplication.shared
        let data = Data(#"{"result":{"devices":[{"identifier":"fixture-command","properties":{"hardware":{"fidelity":"physical"},"state":{"name":"Fixture"}}}]}}"#.utf8)
        let device = try #require(CoreDeviceInventoryDecoder.decode(data).first)
        let transport = TestRemoteScreenTransport()
        let poses = NativeDevicePoseControls { _ in }
        transport.nativePoseControls = poses
        let session = RemoteDeviceScreenSession(device: device) { _, _, _ in transport }
        let model = SimulatorManagerModel(source: ManagerModelSource(devices: []))
        model.registry.stopReading()
        let screens = DeviceScreens(model: model)
        let screen = screens.attach(RemoteDeviceWindowController(device: device, session: session, presentCompactWindow: { _ in }))
        #expect(screen.nativePoseControls == nil)
        try await session.start()
        #expect(screen.nativePoseControls === poses)
        try await screens.stopAll()
        #expect(screen.nativePoseControls == nil)
    }

    @Test func stopAllPreservesRemoteCancellationAndCanRetry() async throws {
        _ = NSApplication.shared
        let data = Data(#"{"result":{"devices":[{"identifier":"fixture-command","properties":{"hardware":{"fidelity":"physical"},"state":{"name":"Fixture"}}}]}}"#.utf8)
        let device = try #require(CoreDeviceInventoryDecoder.decode(data).first)
        let transport = TestRemoteScreenTransport()
        let session = RemoteDeviceScreenSession(device: device) { _, _, _ in transport }
        try await session.start()
        let model = SimulatorManagerModel(source: ManagerModelSource(devices: []))
        model.registry.stopReading()
        let screens = DeviceScreens(model: model)
        screens.attach(RemoteDeviceWindowController(device: device, session: session, presentCompactWindow: { _ in }))
        transport.onReleaseInputs = { throw CancellationError() }
        await #expect(throws: CancellationError.self) { try await screens.stopAll() }
        #expect(!screens.identifiers.isEmpty)
        transport.onReleaseInputs = nil
        try await screens.stopAll()
        #expect(screens.identifiers.isEmpty)
    }

    @Test func remoteCaptureSourceChoiceWaitsForTheCurrentConnectionToEnd() async throws {
        _ = NSApplication.shared
        let data = Data(#"{"result":{"devices":[{"identifier":"fixture-command","properties":{"hardware":{"fidelity":"physical"},"state":{"name":"Fixture"}}}]}}"#.utf8)
        let device = try #require(CoreDeviceInventoryDecoder.decode(data).first)
        let suite = "NeoSimulatorTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = ScreenCaptureSourceCatalog(defaults: defaults)
        let current = RemoteScreenCaptureSource(name: "Fixture", uniqueID: "current-capture-identity")
        let chosen = RemoteScreenCaptureSource(name: "Fixture", uniqueID: "chosen-capture-identity")
        catalog.choose(current, for: device.identifier)
        let transport = TestRemoteScreenTransport()
        // Like the capture transport, each connection shows the source chosen when it opens.
        var shownSources: [RemoteScreenCaptureSource?] = []
        let session = RemoteDeviceScreenSession(device: device, captureSources: catalog) { _, _, _ in
            shownSources.append(catalog.chosenSource(for: device.identifier))
            return transport
        }
        let controller = RemoteDeviceWindowController(device: device, session: session, presentCompactWindow: { _ in })
        try await session.start()
        func select(_ source: RemoteScreenCaptureSource) {
            let item = NSMenuItem()
            item.representedObject = source
            #expect(NSApp.sendAction(NSSelectorFromString("captureSourceSelected:"), to: controller, from: item))
        }
        // Cancelling a pending capture's save prompt cancels the disconnect in the same way.
        transport.onReleaseInputs = {
            transport.onReleaseInputs = nil
            throw CancellationError()
        }
        select(chosen)
        try await wait { transport.inputReleases == 1 && controller.isScreenActionEnabled("reconnect") }
        #expect(session.state == .connected && session.captureSource == current && shownSources == [current])
        select(chosen)
        try await wait { shownSources.count == 2 && session.state == .connected }
        #expect(shownSources == [current, chosen] && session.captureSource == chosen)
        try await controller.stopAndClose()
    }

    @Test func anUnavailableRemoteScreenShowsItsFailureOnceAndRetriesFromTheScreen() async throws {
        _ = NSApplication.shared
        let data = Data(#"{"result":{"devices":[{"identifier":"fixture-command","properties":{"hardware":{"fidelity":"physical"},"state":{"name":"Fixture"}}}]}}"#.utf8)
        let device = try #require(CoreDeviceInventoryDecoder.decode(data).first)
        let failure = RemoteScreenCaptureSourceError(reason: .disconnected)
        let transport = TestRemoteScreenTransport()
        var connections = 0
        let session = RemoteDeviceScreenSession(device: device) { _, _, _ in
            connections += 1
            if connections == 1 { throw failure }
            return transport
        }
        let controller = RemoteDeviceWindowController(device: device, session: session, presentCompactWindow: { _ in })
        func shown<View: NSView>(_ type: View.Type) -> [View] {
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            return descendants(controller.presentationViewController.view)
                .compactMap { $0 as? View }.filter { !$0.isHiddenOrHasHiddenAncestor }
        }
        controller.connectIfNeeded()
        try await wait { session.state == .failed && shown(NSButton.self).contains { $0.title == "Try Again" } }
        let text = shown(NSTextField.self).map(\.stringValue).joined(separator: "\n")
        let message = try #require(failure.errorDescription), suggestion = try #require(failure.recoverySuggestion)
        #expect(text.components(separatedBy: message).count == 2 && text.contains(suggestion), "Shown: \(text)")
        let retry = try #require(shown(NSButton.self).first { $0.title == "Try Again" })
        #expect(shown(NSButton.self).contains { $0.title == "Choose Screen Source…" })
        retry.performClick(nil)
        try await wait { connections == 2 && session.state == .connected && shown(NSTextField.self).isEmpty }
        #expect(session.state == .connected && shown(NSTextField.self).isEmpty && shown(NSButton.self).isEmpty)
        try await controller.stopAndClose()
    }

    @Test func aFailedRemoteScreenKeepsItsStatusReadableOverTheLastFrame() async throws {
        _ = NSApplication.shared
        let data = Data(#"{"result":{"devices":[{"identifier":"fixture-command","properties":{"hardware":{"fidelity":"physical"},"state":{"name":"Fixture"}}}]}}"#.utf8)
        let device = try #require(CoreDeviceInventoryDecoder.decode(data).first)
        let transport = TestRemoteScreenTransport()
        // Like the capture transport's last drawable, a failed connection's last frame stays in the screen.
        let lastFrame = NSImageView(image: NSImage(size: NSSize(width: 4, height: 4), flipped: false) {
            NSColor.white.setFill()
            $0.fill()
            return true
        })
        lastFrame.imageScaling = .scaleAxesIndependently
        lastFrame.autoresizingMask = [.width, .height]
        var connections = 0
        let session = RemoteDeviceScreenSession(device: device) { _, content, _ in
            connections += 1
            lastFrame.frame = content.bounds
            content.addSubview(lastFrame)
            return transport
        }
        let controller = RemoteDeviceWindowController(device: device, session: session, presentCompactWindow: { _ in })
        let root = controller.presentationViewController.view
        // The luminance of each pixel AppKit draws in a rectangle of the root view.
        func luminances(in rect: NSRect) throws -> [CGFloat] {
            root.layoutSubtreeIfNeeded()
            let image = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: image)
            let scale = CGFloat(image.pixelsWide) / root.bounds.width
            let pixels = rect.intersection(root.bounds).insetBy(dx: 1, dy: 1)
            return stride(from: pixels.minX, to: pixels.maxX, by: 1 / scale).flatMap { x in
                stride(from: pixels.minY, to: pixels.maxY, by: 1 / scale).compactMap { y in
                    image.colorAt(x: Int(x * scale), y: Int((root.bounds.height - y) * scale))?.usingColorSpace(.sRGB).map {
                        $0.alphaComponent * (0.2126 * $0.redComponent + 0.7152 * $0.greenComponent + 0.0722 * $0.blueComponent)
                    }
                }
            }
        }
        try await session.start()
        let failure = RemoteScreenCaptureSourceError(reason: .disconnected)
        transport.emit(.failure(failure))
        root.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let title = try #require(descendants(root).compactMap { $0 as? NSTextField }.first {
            !$0.isHiddenOrHasHiddenAncestor && $0.stringValue == failure.errorDescription
        })
        // Text drawn over the bright frame's own color cannot be read.
        let text = try luminances(in: title.convert(title.bounds, to: root)).sorted()
        let background = text[text.count / 2], strokes = try #require(text.last)
        #expect(background < 0.4 && strokes - background > 0.4, "Title \(strokes) over \(background)")
        #expect(!session.contentView.isHiddenOrHasHiddenAncestor && !lastFrame.isHiddenOrHasHiddenAncestor)
        let retry = try #require(descendants(root).compactMap { $0 as? NSButton }.first {
            !$0.isHiddenOrHasHiddenAncestor && $0.title == "Try Again"
        })
        retry.performClick(nil)
        try await wait {
            connections == 2 && session.state == .connected && !descendants(root).contains {
                ($0 is NSTextField || $0 is NSProgressIndicator) && !$0.isHiddenOrHasHiddenAncestor
            }
        }
        // Reconnected, the whole screen shows its frames again.
        let screen = try luminances(in: NSRect(x: root.bounds.midX - 60, y: root.bounds.midY - 60, width: 120, height: 120))
        #expect(screen.allSatisfy { $0 > 0.9 })
        try await controller.stopAndClose()
    }

    @Test func coreDevicePasteboardCarriesTransfersInsteadOfSimPasteboardPlus() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.lynnswap.NeoSimulatorTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let display = TestDisplay()
        let transport = TestPasteboardTransport()
        let session = try makeSession(display, features: [DeviceCapabilities.pasteboard], pasteboard: pasteboard,
                                      pasteboardTransport: transport)
        defer { session.disconnect() }
        var failures: [String] = []
        func transfer(_ transfer: PasteboardTransfer) {
            session.transferPasteboard(transfer) { failures.append($0.localizedDescription) }
        }

        // SimPasteboardPlus's sends no longer replace an iOS 27.2 guest's pasteboard, so it stays unconnected.
        transfer(.send)
        transfer(.get)
        try await wait { transport.transfers.count == 2 }
        #expect(transport.transfers == [.send, .get])
        #expect(display.pasteboards.isEmpty)

        // A failed send reaches Send Pasteboard, not the Get that follows it.
        transport.sendError = SimulatorError.operation("pasteboard communication failure")
        transfer(.send)
        transfer(.get)
        try await wait { transport.transfers.count == 4 }
        #expect(failures == ["Could not send the pasteboard to the simulator: pasteboard communication failure"])
    }

    @Test func coreDevicePasteboardSynchronizesOnlyWhileTurnedOn() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.lynnswap.NeoSimulatorTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        var sessions: [DeviceSession] = []
        let sync = PasteboardSync(preferences: MemoryPreferences()) { sessions }
        let transport = TestPasteboardTransport()
        let session = try makeSession(TestDisplay(), features: [DeviceCapabilities.pasteboard], pasteboard: pasteboard,
                                      pasteboardSync: sync, pasteboardTransport: transport)
        sessions.append(session)
        defer { session.disconnect() }
        session.transferPasteboard(.send) { Issue.record($0) }
        try await wait { transport.transfers == [.send] }

        // Turning synchronization on observes both pasteboards and sends nothing until a change.
        sync.toggle()
        try await wait { transport.observations == 2 }
        var changes: [PasteboardTransfer] = []
        let deviceChange = try #require(transport.reportDeviceChange)
        let macChange = try #require(transport.reportMacChange)
        deviceChange { _ in changes.append(.get); return pasteboard.changeCount }
        try await wait { changes == [.get] }
        macChange { changes.append(.send) }
        try await wait { changes.count == 2 }
        #expect(changes == [.get, .send])
        #expect(transport.transfers == [.send])

        // Turning it off ends both observations, and a change reported through them afterward does not transfer.
        sync.toggle()
        try await wait { transport.observations == 0 }
        #expect(transport.observations == 0)
        deviceChange { _ in changes.append(.get); return 2 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(changes == [.get, .send])

        // Closing the device's window ends the observations that turning synchronization on again starts.
        sync.toggle()
        try await wait { transport.observations == 2 }
        session.disconnect()
        try await wait { transport.observations == 0 }
        #expect(transport.observations == 0)
        #expect(transport.transfers == [.send])
    }

    @Test func aFailedCoreDevicePasteboardObservationWaitsForSynchronizationToBeUpdated() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.lynnswap.NeoSimulatorTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let preferences = MemoryPreferences()
        preferences.values[HostPreferences.pasteboardAutomaticSync] = true
        var sessions: [DeviceSession] = []
        let sync = PasteboardSync(preferences: preferences) { sessions }
        let transport = TestPasteboardTransport()
        let session = try makeSession(TestDisplay(), features: [DeviceCapabilities.pasteboard], pasteboard: pasteboard,
                                      pasteboardSync: sync, pasteboardTransport: transport)
        sessions.append(session)
        defer { session.disconnect() }
        session.startPasteboardSync()
        try await wait { transport.observations == 2 && transport.transfers == [.send] }

        // A failed observation ends both without restarting, and a change it reported no longer transfers. The
        // synchronization choice stays on.
        let deviceChange = try #require(transport.reportDeviceChange)
        transport.endDeviceObservation(throwing: SimulatorError.operation("The device closed the pasteboard monitor."))
        try await wait { transport.observations == 0 }
        var changes: [PasteboardTransfer] = []
        deviceChange { _ in changes.append(.get); return 1 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(transport.observations == 0 && transport.deviceObservations == 1)
        #expect(changes.isEmpty)
        #expect(sync.isOn)

        // Selecting the device again starts both observations, without a transfer.
        session.updatePasteboardSync()
        try await wait { transport.observations == 2 }
        #expect(transport.observations == 2 && transport.deviceObservations == 2)

        // An observation that ends without an error stops both the same way, and turning synchronization off and on
        // starts them again. Turning it off also drops a send that another device's copy queued after they ended,
        // behind one in progress, but not the send requested next.
        transport.endMacObservation()
        try await wait { transport.observations == 0 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(transport.observations == 0 && transport.deviceObservations == 2)
        transport.holdsSends = true
        session.sendSynchronizedPasteboard()
        try await wait { transport.heldSends == 1 }
        try #require(transport.heldSends == 1)
        session.sendSynchronizedPasteboard()
        sync.toggle()
        session.transferPasteboard(.send) { Issue.record($0) }
        transport.holdsSends = false
        transport.completeSend()
        try await wait { transport.transfers == [.send, .send, .send] }
        try await Task.sleep(for: .milliseconds(50))
        sync.toggle()
        try await wait { transport.observations == 2 }
        #expect(transport.observations == 2 && transport.deviceObservations == 3)
        #expect(transport.transfers == [.send, .send, .send])
    }

    @Test func automaticCoreDevicePasteboardTransfersLeaveRequestedTransfersTheirOwnResults() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.lynnswap.NeoSimulatorTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let preferences = MemoryPreferences()
        preferences.values[HostPreferences.pasteboardAutomaticSync] = true
        var sessions: [DeviceSession] = []
        let sync = PasteboardSync(preferences: preferences) { sessions }
        let (connecting, sending, receiving) = (TestPasteboardTransport(), TestPasteboardTransport(), TestPasteboardTransport())
        connecting.holdsSends = true
        for (name, transport) in [("connecting", connecting), ("sending", sending), ("receiving", receiving)] {
            sessions.append(try makeSession(TestDisplay(), features: [DeviceCapabilities.pasteboard], device: name,
                                            pasteboard: pasteboard, pasteboardSync: sync, pasteboardTransport: transport))
        }
        defer { sessions.forEach { $0.disconnect() } }
        sessions.forEach { $0.startPasteboardSync() }
        try await wait {
            connecting.heldSends == 1 && sending.transfers == [.send] && receiving.transfers == [.send]
                && [connecting, sending, receiving].allSatisfy { $0.observations == 2 }
        }

        // A device copy whose write leaves a later Mac change in place replaces nothing, and a Get requested behind it
        // while synchronization is off keeps its own result. The copy reaches no other device even though
        // synchronization is on again when the write ends.
        var resumeSuperseded: CheckedContinuation<Void, Never>?
        let supersededChange = try #require(receiving.reportDeviceChange)
        supersededChange { _ in
            await withCheckedContinuation { resumeSuperseded = $0 }
            return nil
        }
        try await wait { resumeSuperseded != nil }
        sync.toggle()
        try await wait { [connecting, sending, receiving].allSatisfy { $0.observations == 0 } }
        var gets: [String] = []
        receiving.readError = SimulatorError.operation("requested get failure")
        sessions[2].transferPasteboard(.get) { gets.append($0.localizedDescription) }
        sync.toggle()
        try await wait { [connecting, sending, receiving].allSatisfy { $0.observations == 2 } }
        resumeSuperseded?.resume()
        try await wait { gets.count == 1 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(gets == ["Could not get the simulator's pasteboard: requested get failure"] && sending.transfers == [.send])
        receiving.readError = nil

        // A device's automatic copy reaches the other devices and is not sent back to it.
        let deviceChange = try #require(receiving.reportDeviceChange)
        func copyOnDevice() -> Int {
            pasteboard.clearContents()
            pasteboard.setString("device", forType: .string)
            return pasteboard.changeCount
        }
        deviceChange { shouldReplace in shouldReplace() ? copyOnDevice() : nil }
        try await wait { sending.transfers == [.send, .send] }
        sessions[2].sendSynchronizedPasteboard()
        try await Task.sleep(for: .milliseconds(50))
        #expect(sending.transfers == [.send, .send] && receiving.transfers == [.send, .get])

        // Automatic transfers that started before synchronization turned off finish after the transfers requested
        // next: the connecting device's first send, a send of a Mac change, and a write of a device change.
        var resumeSend: CheckedContinuation<Void, Never>?
        var resumeWrite: CheckedContinuation<Void, Never>?
        let macChange = try #require(sending.reportMacChange)
        macChange {
            await withCheckedContinuation { resumeSend = $0 }
            throw SimulatorError.operation("automatic send failure")
        }
        deviceChange { shouldReplace in
            await withCheckedContinuation { resumeWrite = $0 }
            return shouldReplace() ? copyOnDevice() : nil
        }
        try await wait { resumeSend != nil && resumeWrite != nil }
        sync.toggle()

        // Each requested transfer reports its own failure, and no automatic transfer reports one.
        var failures: [String] = []
        connecting.holdsSends = false
        for transport in [connecting, sending] { transport.sendError = SimulatorError.operation("requested send failure") }
        receiving.readError = SimulatorError.operation("requested get failure")
        for (name, session, transfer) in [("connecting", sessions[0], PasteboardTransfer.send), ("sending", sessions[1], .send),
                                          ("receiving", sessions[2], .get)] {
            session.transferPasteboard(transfer) { failures.append("\(name): \($0.localizedDescription)") }
        }
        connecting.completeSend()
        resumeSend?.resume()
        resumeWrite?.resume()
        try await wait { failures.count == 3 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(failures.sorted() == [
            "connecting: Could not send the pasteboard to the simulator: requested send failure",
            "receiving: Could not get the simulator's pasteboard: requested get failure",
            "sending: Could not send the pasteboard to the simulator: requested send failure",
        ])
        // The copy queued for the connecting device behind its first send does not transfer.
        #expect(connecting.transfers == [.send, .send])
    }

    @Test func queuedAutomaticCoreDevicePasteboardTransfersGiveWayToLaterChanges() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.lynnswap.NeoSimulatorTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let preferences = MemoryPreferences()
        preferences.values[HostPreferences.pasteboardAutomaticSync] = true
        var sessions: [DeviceSession] = []
        let sync = PasteboardSync(preferences: preferences) { sessions }
        let transport = TestPasteboardTransport()
        transport.holdsSends = true
        let session = try makeSession(TestDisplay(), features: [DeviceCapabilities.pasteboard], pasteboard: pasteboard,
                                      pasteboardSync: sync, pasteboardTransport: transport)
        sessions.append(session)
        defer { session.disconnect() }
        session.startPasteboardSync()
        try await wait { transport.observations == 2 && transport.heldSends == 1 }
        try #require(transport.observations == 2 && transport.heldSends == 1)

        // The device's pasteboard, which a Mac change's send replaces with the Mac pasteboard it captured.
        var device = ""
        let deviceChange = try #require(transport.reportDeviceChange)
        let macChange = try #require(transport.reportMacChange)
        func mac() -> String? { pasteboard.string(forType: .string) }
        func replaceMac(with text: String) -> Int {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return pasteboard.changeCount
        }
        func copyOnDevice(_ text: String) {
            device = text
            deviceChange { shouldReplace in shouldReplace() ? replaceMac(with: text) : nil }
        }

        // A device copy queued behind a send does not replace a later Mac copy, even when its turn comes before the
        // Mac's observation reports that copy, which then reaches the device.
        copyOnDevice("device copy")
        _ = replaceMac(with: "Mac copy")
        transport.holdsSends = false
        transport.completeSend()
        try await Task.sleep(for: .milliseconds(50))
        macChange { device = "Mac copy" }
        try await wait { device == "Mac copy" }
        #expect(mac() == "Mac copy" && device == "Mac copy")

        // A Mac copy queued behind a send is not sent once the device copies after it, and the device copy reaches
        // the Mac instead.
        transport.holdsSends = true
        session.sendSynchronizedPasteboard()
        try await wait { transport.heldSends == 1 }
        try #require(transport.heldSends == 1)
        _ = replaceMac(with: "later Mac copy")
        macChange { device = "later Mac copy" }
        copyOnDevice("later device copy")
        transport.holdsSends = false
        transport.completeSend()
        try await wait { mac() == "later device copy" }
        #expect(mac() == "later device copy" && device == "later device copy")

        // A device copy observed while the connection writes the one before it replaces the Mac pasteboard, and the
        // earlier write, ready only after it, leaves the Mac pasteboard to it.
        var resumeWrite: CheckedContinuation<Void, Never>?
        deviceChange { shouldReplace in
            await withCheckedContinuation { resumeWrite = $0 }
            return shouldReplace() ? replaceMac(with: "first device copy") : nil
        }
        try await wait { resumeWrite != nil }
        try #require(resumeWrite != nil)
        copyOnDevice("second device copy")
        resumeWrite?.resume()
        try await wait { mac() == "second device copy" }
        #expect(mac() == "second device copy")

        // A Mac copy that its observation reports only after a later device copy does not stop that copy's write. The
        // Mac copy's send, queued behind the write, then finds the Mac pasteboard changed, as the CoreDevice transport
        // checks before it sends, and both pasteboards keep the device copy.
        let reported = replaceMac(with: "Mac copy reported late")
        transport.holdsSends = true
        session.sendSynchronizedPasteboard()
        try await wait { transport.heldSends == 1 }
        try #require(transport.heldSends == 1)
        copyOnDevice("device copy after it")
        var lateSendRan = false
        macChange {
            lateSendRan = true
            if pasteboard.changeCount == reported { device = "Mac copy reported late" }
        }
        transport.holdsSends = false
        transport.completeSend()
        try await wait { lateSendRan }
        #expect(mac() == "device copy after it" && device == "device copy after it")
    }

    @Test func theRemotesTouchSurfaceTouchesWhileOptionIsHeldAsInSimulatorApp() throws {
        _ = NSApplication.shared
        let display = TestDisplay(), other = TestDisplay()
        let target = RemoteTarget()
        let remote = TVRemoteController(target: { target.controller })
        let tv = try makeController(display, family: .tv, features: [DeviceCapabilities.tvRemote], tvRemote: remote)
        let otherTV = try makeController(other, family: .tv, features: [DeviceCapabilities.tvRemote], tvRemote: remote)
        defer {
            tv.invalidate()
            otherTV.invalidate()
            remote.close()
        }
        target.controller = tv
        remote.showWindow(nil)
        let window = try #require(remote.window)
        let surface = try #require(window.contentView?.subviews.compactMap { $0 as? TVRemoteTouchSurface }.first)
        // Coordinates are normalized from the touch surface's top-left corner.
        func event(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat, option: Bool) throws -> NSEvent {
            let location = surface.convert(NSPoint(x: x * surface.bounds.width, y: (1 - y) * surface.bounds.height), to: nil)
            let flags: NSEvent.ModifierFlags = option ? .option : []
            if type == .mouseEntered || type == .mouseExited {
                return try #require(NSEvent.enterExitEvent(
                    with: type, location: location, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
            }
            return try #require(NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        }
        func touch(_ phase: TVRemoteTouch.Phase, _ x: CGFloat, _ y: CGFloat) -> TVRemoteTouch {
            TVRemoteTouch(phase: phase, point: CGPoint(x: x, y: y))
        }
        surface.mouseEntered(with: try event(.mouseEntered, 0.5, 0.25, option: false))
        surface.mouseMoved(with: try event(.mouseMoved, 0.5, 0.5, option: false))
        #expect(display.remoteTouches.isEmpty)
        surface.mouseMoved(with: try event(.mouseMoved, 0.5, 0.25, option: true))
        surface.mouseMoved(with: try event(.mouseMoved, 0.75, 0.5, option: true))
        surface.optionChanged(isDown: true)
        surface.optionChanged(isDown: false)
        surface.optionChanged(isDown: true)
        surface.mouseDragged(with: try event(.leftMouseDragged, 0.25, 0.75, option: true))
        surface.mouseMoved(with: try event(.mouseMoved, 0.25, 0.5, option: false))
        #expect(display.remoteTouches == [touch(.began, 0.5, 0.25), touch(.moved, 0.75, 0.5), touch(.ended, 0.75, 0.5),
                                          touch(.began, 0.75, 0.5), touch(.moved, 0.25, 0.75), touch(.ended, 0.25, 0.5)])
        surface.optionChanged(isDown: true)
        surface.mouseExited(with: try event(.mouseExited, 1, 0.5, option: true))
        surface.optionChanged(isDown: false)
        surface.optionChanged(isDown: true)
        #expect(display.remoteTouches.suffix(2) == [touch(.began, 0.25, 0.5), touch(.ended, 1, 0.5)])
        surface.mouseEntered(with: try event(.mouseEntered, 0.5, 0.5, option: true))
        target.controller = otherTV
        surface.mouseMoved(with: try event(.mouseMoved, 0.5, 0.75, option: true))
        #expect(display.remoteTouches.suffix(2) == [touch(.began, 0.5, 0.5), touch(.ended, 0.5, 0.75)])
        #expect(other.remoteTouches == [touch(.began, 0.5, 0.75)])
        remote.close()
        #expect(other.remoteTouches.last == touch(.ended, 0.5, 0.75))
        remote.showWindow(nil)
        target.controller = tv
        surface.mouseEntered(with: try event(.mouseEntered, 0.25, 0.25, option: true))
        tv.session.disconnect()
        surface.mouseExited(with: try event(.mouseExited, 0, 0.25, option: true))
        #expect(display.remoteTouches.suffix(2) == [touch(.began, 0.25, 0.25), touch(.ended, 0.25, 0.25)])
        #expect(display.remoteTouches.count == 12)
    }

    @Test func aDragOffTheRemotesTouchSurfaceEndsTheTouchAtItsEdge() throws {
        _ = NSApplication.shared
        let display = TestDisplay()
        let target = RemoteTarget()
        let remote = TVRemoteController(target: { target.controller })
        let tv = try makeController(display, family: .tv, features: [DeviceCapabilities.tvRemote], tvRemote: remote)
        defer {
            tv.invalidate()
            remote.close()
        }
        target.controller = tv
        remote.showWindow(nil)
        let window = try #require(remote.window)
        let content = try #require(window.contentView)
        let surface = try #require(content.subviews.compactMap { $0 as? TVRemoteTouchSurface }.first)
        let menu = try #require(content.subviews.first { $0.accessibilityLabel() == "Menu" })
        func event(_ type: NSEvent.EventType, at location: NSPoint) throws -> NSEvent {
            if type == .mouseEntered {
                return try #require(NSEvent.enterExitEvent(
                    with: type, location: location, modifierFlags: .option, timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
            }
            return try #require(NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: .option, timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        func onSurface(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            surface.convert(NSPoint(x: x * surface.bounds.width, y: (1 - y) * surface.bounds.height), to: nil)
        }
        // Drag beyond the touch surface onto Menu before releasing.
        let onMenu = menu.convert(NSPoint(x: menu.bounds.midX, y: menu.bounds.midY), to: nil)
        surface.mouseEntered(with: try event(.mouseEntered, at: onSurface(0.3, 0.5)))
        surface.mouseDown(with: try event(.leftMouseDown, at: onSurface(0.3, 0.5)))
        surface.mouseDragged(with: try event(.leftMouseDragged, at: onSurface(0.3, 0.75)))
        surface.mouseDragged(with: try event(.leftMouseDragged, at: onMenu))
        surface.mouseDragged(with: try event(.leftMouseDragged, at: NSPoint(x: onMenu.x, y: onMenu.y - 20)))
        surface.mouseUp(with: try event(.leftMouseUp, at: onMenu))
        let x = onMenu.x / surface.bounds.width
        #expect(display.remoteTouches == [TVRemoteTouch(phase: .began, point: CGPoint(x: 0.3, y: 0.5)),
                                          TVRemoteTouch(phase: .moved, point: CGPoint(x: 0.3, y: 0.75)),
                                          TVRemoteTouch(phase: .ended, point: CGPoint(x: x, y: 1))])
        #expect(display.events.map(\.input) == [.tvRemote(.select), .tvRemote(.select)])
        #expect(display.events.map(\.state) == [.down, .up])
        surface.mouseDown(with: try event(.leftMouseDown, at: onSurface(0.5, 0.5)))
        surface.mouseDragged(with: try event(.leftMouseDragged, at: onMenu))
        surface.mouseDragged(with: try event(.leftMouseDragged, at: onSurface(0.5, 0.25)))
        surface.mouseUp(with: try event(.leftMouseUp, at: onSurface(0.5, 0.25)))
        #expect(display.remoteTouches.suffix(2) == [TVRemoteTouch(phase: .ended, point: CGPoint(x: x, y: 1)),
                                                    TVRemoteTouch(phase: .began, point: CGPoint(x: 0.5, y: 0.25))])
    }

    @Test func aRemoteReleaseThatIsNotDeliveredIsSentAgainAsAHeldInputsIs() throws {
        _ = NSApplication.shared
        let display = TestDisplay()
        let target = RemoteTarget()
        let remote = TVRemoteController(target: { target.controller })
        let tv = try makeController(display, family: .tv, features: [DeviceCapabilities.tvRemote], tvRemote: remote)
        defer {
            tv.invalidate()
            remote.close()
        }
        target.controller = tv
        remote.showWindow(nil)
        let window = try #require(remote.window)
        let content = try #require(window.contentView)
        let surface = try #require(content.subviews.compactMap { $0 as? TVRemoteTouchSurface }.first)
        let menu = try #require(content.subviews.first { $0.accessibilityLabel() == "Menu" })
        func event(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) throws -> NSEvent {
            let location = surface.convert(NSPoint(x: x * surface.bounds.width, y: (1 - y) * surface.bounds.height), to: nil)
            if type == .mouseEntered || type == .mouseExited {
                return try #require(NSEvent.enterExitEvent(
                    with: type, location: location, modifierFlags: .option, timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
            }
            return try #require(NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        func touch(_ phase: TVRemoteTouch.Phase, _ x: CGFloat, _ y: CGFloat) -> TVRemoteTouch {
            TVRemoteTouch(phase: phase, point: CGPoint(x: x, y: y))
        }
        // Failed delivery leaves Menu potentially held; closing must retry its release.
        display.undeliveredEvents = [1]
        menu.mouseDown(with: try event(.leftMouseDown, 0, 0))
        menu.mouseUp(with: try event(.leftMouseUp, 0, 0))
        remote.close()
        #expect(display.events.map(\.input) == [.tvRemote(.menu), .tvRemote(.menu), .tvRemote(.menu)])
        #expect(display.events.map(\.state) == [.down, .up, .up])
        // Pending delivery must not trigger a duplicate release.
        remote.showWindow(nil)
        display.deferCompletions = true
        menu.mouseDown(with: try event(.leftMouseDown, 0, 0))
        menu.mouseUp(with: try event(.leftMouseUp, 0, 0))
        remote.close()
        #expect(display.events.map(\.state).suffix(2) == [.down, .up] && display.events.count == 5)
        display.pendingCompletions.forEach { $0() }
        display.pendingCompletions.removeAll()
        display.deferCompletions = false
        remote.showWindow(nil)
        display.undeliveredTouches = 1
        surface.mouseEntered(with: try event(.mouseEntered, 0.5, 0.5))
        surface.mouseExited(with: try event(.mouseExited, 1, 0.5))
        remote.close()
        remote.showWindow(nil)
        remote.close()
        #expect(display.remoteTouches == [touch(.began, 0.5, 0.5), touch(.ended, 1, 0.5), touch(.ended, 1, 0.5)])
        remote.showWindow(nil)
        display.undeliveredTouches = 1
        surface.mouseEntered(with: try event(.mouseEntered, 0.25, 0.25))
        surface.mouseExited(with: try event(.mouseExited, 0, 0.25))
        tv.session.disconnect()
        #expect(display.remoteTouches.suffix(3) == [touch(.began, 0.25, 0.25), touch(.ended, 0, 0.25),
                                                    touch(.ended, 0, 0.25)])
        #expect(display.events.count == 5)
    }

    @Test func theRemotesMessagesAreSimulatorAppsForThisSimulatorKit() async throws {
        let input = try await makeRuntime().input
        func fields(_ message: OpaquePointer, _ offsets: [Int]) -> [UInt32] {
            offsets.map { UnsafeRawPointer(message).load(fromByteOffset: $0, as: UInt32.self) }
        }
        // Remote buttons use values 1/0 at the remote target; device buttons use 1/2 at the screen.
        for (state, value) in [(HIDState.down, UInt32(1)), (.up, 0)] {
            let message = try input.message(.tvRemote(.siri), state, target: 7).take()
            defer { free(UnsafeMutableRawPointer(message)) }
            #expect(fields(message, [0x30, 0x34, 0x38]) == [0x3f2, value, 0x15])
        }
        let home = try input.message(.button(.home), .up, target: 7).take()
        defer { free(UnsafeMutableRawPointer(home)) }
        #expect(fields(home, [0x30, 0x34, 0x38]) == [0, 2, 7])
        // Match Simulator.app's touchStarted/touchEnded masks and flags.
        let expected: [(TVRemoteTouch.Phase, [UInt32])] = [
            (.began, [0x23, 1, 1, 3, 1, 1]), (.moved, [4, 1, 1, 4, 1, 1]), (.ended, [0x21, 0, 0, 1, 0, 0]),
        ]
        for (phase, values) in expected {
            let message = try input.message(for: TVRemoteTouch(phase: phase, point: CGPoint(x: 0.25, y: 0.75)))
            defer { free(UnsafeMutableRawPointer(message)) }
            #expect(fields(message, [0x38, 0x64, 0x68, 0xd8, 0x104, 0x108]) == values, "\(phase)")
            let raw = UnsafeRawPointer(message)
            #expect(raw.loadUnaligned(fromByteOffset: 0x3c, as: Double.self) == 0.25)
            #expect(raw.loadUnaligned(fromByteOffset: 0x44, as: Double.self) == 0.75)
            #expect(fields(message, [0x6c]) == [0x16])
        }
    }
}
