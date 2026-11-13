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
    @Test func simulatorKeyboardKeepsCapturedReleasesWithTheirOriginalInput() throws {
        _ = NSApplication.shared
        let view = InputView()
        let input = SimulatorKeyboardInput()
        input.start(for: view)
        defer { input.stop() }
        func event(_ type: NSEvent.EventType, _ code: UInt16) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a",
                isARepeat: false, keyCode: code))
        }

        // Capture Keyboard submits directly to the input view, bypassing application event monitors.
        input.send(try event(.keyDown, 0), to: view)
        input.send(try event(.keyDown, 1), to: view)
        input.send(try event(.keyUp, 0), to: view)
        #expect(input.hasPressedKeys)
        input.stop()
        #expect(!input.hasPressedKeys && view.keyUps.map(\.keyCode) == [0, 1])
    }

    @Test func recordingWaitsForThePendingAppDisplayConnectionAndCapturesTheShownDisplay() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("arguments")
        let simctl = directory.appendingPathComponent("simctl")
        try """
        #!/bin/sh
        printf '%s\n' "$@" > "\(log.path).pending"
        mv "\(log.path).pending" "\(log.path)"
        for output; do :; done
        : > "$output"
        trap 'exit 0' INT
        echo 'Recording started' >&2
        while :; do sleep 0.05; done
        """.write(to: simctl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: simctl.path)
        let primary = TestDisplay(), app = TestDisplay()
        primary.captureDisplayID = 1
        app.captureDisplayID = 47
        primary.appDisplay = app
        primary.holdsAppDisplayConnection = true
        let transport = TestAppResizeTransport()
        let controller = try makeController(primary, simctl: simctl, appResizeTransport: { transport })
        defer { controller.invalidate() }
        let session = controller.session
        try await wait { session.canResizeApp }
        controller.toggleAppResize()
        try await wait { primary.appDisplayConnection != nil }
        for id in [DeviceCommand.ID.recordScreen, .recordScreenAs] {
            #expect(!DeviceCommand.command(id).isEnabled(controller))
        }
        await #expect(throws: SimulatorError.self) {
            try await session.startRecording(to: .file(directory.appendingPathComponent("pending.mov")), mask: .ignored)
        }
        if let unexpected = session.recording { unexpected.stop(); try await unexpected.waitUntilFinished() }
        #expect(session.recording == nil && !FileManager.default.fileExists(atPath: log.path))
        primary.completeAppDisplayConnection()
        try await wait { session.isResizingApp }
        #expect(DeviceCommand.command(.recordScreen).isEnabled(controller))
        try await session.startRecording(to: .file(directory.appendingPathComponent("app.mov")), mask: .ignored)
        let recording = try #require(session.recording)
        try await wait { FileManager.default.fileExists(atPath: log.path) }
        #expect(try String(contentsOf: log, encoding: .utf8).split(separator: "\n").contains("--display=47"))
        recording.stop()
        try await recording.waitUntilFinished()
    }

    @Test func exclusiveKeyboardCaptureFollowsTheDisplayedSessionAndReleasesKeys() throws {
        _ = NSApplication.shared
        let display = TestDisplay()
        let tap = TestKeyboardEventTap()
        let controller = try makeController(display, keyboardCaptureTap: tap, applicationIsActive: { true })
        let parent = NSViewController()
        parent.view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        let window = KeyPresentationWindow(contentRect: parent.view.frame, styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = parent
        defer { controller.invalidate(); window.close() }
        controller.embed(in: parent)
        controller.perform(.captureKeyboard)
        #expect(controller.capturesKeyboard && tap.starts == 1)
        #expect(DeviceCommand.command(.captureKeyboard).state?(controller) == .on)
        let digitizerModifiers = display.input.modifiers.count
        var keyboardModifiers: [NSEvent] = []
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            keyboardModifiers.append(event)
            return nil
        }
        defer { monitor.map(NSEvent.removeMonitor) }
        #expect(try tap.key(.flagsChanged, code: 55, flags: .maskCommand))
        #expect(try tap.key(.keyDown, code: 0, flags: .maskCommand))
        #expect(display.input.keyDowns.map(\.keyCode) == [0])
        #expect(keyboardModifiers.map(\.keyCode) == [55])
        #expect(keyboardModifiers.last?.modifierFlags.contains(.command) == true)
        #expect(display.input.modifiers.count == digitizerModifiers)
        controller.detachPresentation()
        #expect(!controller.capturesKeyboard && tap.stops == 1)
        #expect(display.input.keyUps.map(\.keyCode) == [0])
        #expect(display.input.keyUps.last?.modifierFlags.contains(.command) == false)
        #expect(controller.session.isConnected && display.disconnectCount == 0)
        #expect(DeviceCommand.command(.captureKeyboard).state?(controller) == .off)
    }

    @Test func capturePassesHostEventsAfterFocusLossAndReportsTapFailure() throws {
        let tap = TestKeyboardEventTap()
        var eligible = true
        var received: [NSEvent] = []
        var released: [NSEvent] = []
        var failures: [String] = []
        let capture = KeyboardCapture(tap: tap, isEligible: { eligible }, forward: { received.append($0) },
                                      releaseModifiers: { released += $0 }, initialModifierFlags: { .shift })
        capture.failure = { failures.append($0.localizedDescription) }
        try capture.start()
        #expect(try tap.key(.flagsChanged, code: 55, flags: .maskCommand))
        #expect(try tap.key(.keyDown, code: 0, flags: .maskCommand))
        eligible = false
        #expect(try !tap.key(.keyDown, code: 1))
        #expect(!capture.isCapturing && received.map(\.type) == [.flagsChanged, .keyDown, .keyUp])
        #expect(Set(released.map(\.keyCode)) == [55, 56, 60] && released.allSatisfy { $0.modifierFlags.isEmpty })
        eligible = true
        try capture.start()
        #expect(try !tap.key(.tapDisabledByTimeout, code: 0))
        #expect(!capture.isCapturing && tap.stops == 2 && failures.count == 1)
        tap.startError = SimulatorError.operation("Permission denied")
        #expect(throws: SimulatorError.self) { try capture.start() }
        #expect(!capture.isCapturing)
        tap.startError = nil
        try capture.start()
        NotificationCenter.default.post(name: NSApplication.willResignActiveNotification, object: NSApp)
        #expect(!capture.isCapturing && tap.stops == 3)
    }

    @Test(arguments: [kIOHIDAccessTypeUnknown, kIOHIDAccessTypeDenied, kIOHIDAccessTypeGranted])
    func captureReportsActualAuthorizationWhenTapCreationFails(access: IOHIDAccessType) throws {
        var checks = 0
        var requests = 0
        let tap = SystemKeyboardEventTap(applicationName: "Fixture App", access: { checks += 1; return access },
            requestAccess: { requests += 1 },
                                        createTap: { _, _, _ in nil })
        let capture = KeyboardCapture(tap: tap, isEligible: { true }, forward: { _ in
            Issue.record("Failed capture forwarded an event")
        }, releaseModifiers: { _ in })
        do {
            try capture.start()
            Issue.record("Captured without an event tap")
        } catch {
            let failure = try #require(error as? any LocalizedError)
            #expect(failure.recoverySuggestion?.contains("Fixture App") == true)
            #expect(failure.recoverySuggestion?.contains("focused device screen") == true)
            if access == kIOHIDAccessTypeGranted {
                #expect(failure.errorDescription == "Unable to Create Keyboard Event Tap.")
                #expect(failure.recoverySuggestion?.contains("System Settings") == false)
            } else {
                #expect(failure.errorDescription == (access == kIOHIDAccessTypeDenied
                    ? "Keyboard Capture Access Was Denied." : "Keyboard Capture Access Is Not Authorized."))
                if #available(macOS 27, *) {
                    #expect(
                        failure.recoverySuggestion?.contains(
                            "System Settings > Privacy & Security > Device Control and Data Access") == true)
                } else {
                    #expect(
                        failure.recoverySuggestion?.contains("System Settings > Privacy & Security > Accessibility")
                            == true)
                }
            }
        }
        #expect(checks == 1 && !capture.isCapturing)
        #expect(requests == (access == kIOHIDAccessTypeGranted ? 0 : 1))
        #expect(!capture.stop())
    }

    @Test func escapeHoldReleasesCaptureAndShortEscapeStillReachesTheGuest() async throws {
        for hold in [false, true] {
            let tap = TestKeyboardEventTap()
            let entered = AsyncStream<Void>.makeStream()
            let delay = AsyncStream<Void>.makeStream()
            let returned = AsyncStream<Void>.makeStream()
            let stopped = AsyncStream<Void>.makeStream()
            var received: [NSEvent.EventType] = []
            let capture = KeyboardCapture(tap: tap, isEligible: { true }, forward: { received.append($0.type) },
                releaseModifiers: { _ in }, waitForEscapeHold: {
                    entered.continuation.yield(())
                    defer { returned.continuation.yield(()) }
                    var iterator = delay.stream.makeAsyncIterator()
                    _ = await iterator.next()
                })
            capture.didStop = { stopped.continuation.yield(()) }
            defer {
                capture.stop()
                entered.continuation.finish(); delay.continuation.finish()
                returned.continuation.finish(); stopped.continuation.finish()
            }
            try capture.start()
            #expect(try tap.key(.keyDown, code: 53))
            var starting = entered.stream.makeAsyncIterator()
            _ = await starting.next()
            if hold {
                delay.continuation.yield(())
                var ending = stopped.stream.makeAsyncIterator()
                _ = await ending.next()
                #expect(!capture.isCapturing && tap.stops == 1)
            } else {
                #expect(try tap.key(.keyUp, code: 53))
                var ending = returned.stream.makeAsyncIterator()
                _ = await ending.next()
                #expect(capture.isCapturing && tap.stops == 0)
            }
            #expect(received == [.keyDown, .keyUp])
        }
    }

    @Test(arguments: [false, true])
    func compactCanvasControlsKeepTheRecordingAndDeviceActions(startInCompact: Bool) async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let devicectl = directory.appendingPathComponent("devicectl")
        try """
            #!/bin/sh
            printf '{"result":{"deviceOrientation":"portrait","deviceOrientationNonFlat":"portrait"}}'
            """.write(to: devicectl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: devicectl.path)
        let display = TestDisplay()
        display.naturalSize = NSSize(width: 160, height: 320)
        display.bezel = NSSize(width: 20, height: 20)
        display.bezelPadding = NSSize(width: 9, height: 0)
        let controller = try makeController(display, devicectl: devicectl,
            recordingProcess: { _, _ in Self.recorder(then: "while :; do sleep 0.05; done") },
            presentCompactWindow: { _ in })
        defer { controller.invalidate() }
        let controls = DeviceCanvasControls()
        controller.canvasControls = controls
        let session = controller.session
        func updateControls() {
            controls.update(supports: { ["home", "capture", "record", "rotate"].contains($0) },
                            isEnabled: { _ in session.canPerformCommands },
                            recordingTitle: session.recording == nil ? "Record Screen" : "Stop Recording",
                            recordingStartDate: session.recording?.startDate)
        }
        func checkControls() throws {
            let content = controller.presentationViewController.view
            content.layoutSubtreeIfNeeded()
            let window = try #require(controller.presentationWindow)
            #expect(display.view.frame.size == display.size(for: display.renderScale))
            let available = try #require((content as? any DisplayContentView)?.availableDisplaySize)
            let displayRect = display.view.convert(display.view.bounds, to: content)
            #expect(displayRect.width <= available.width + 1 && displayRect.height <= available.height + 1)
            #expect(abs(displayRect.midX - content.bounds.midX) < 1)
            let viewport = try #require(content.layoutGuides.first { $0.identifier.rawValue == "DeviceCanvasViewport" }).frame
            #expect(abs(displayRect.midY - viewport.midY) < 1)
            #expect(controls.frame.maxY <= displayRect.minY + 1)
            let bar = controls.convert(controls.bounds, to: content)
            #expect(content.bounds.insetBy(dx: -1, dy: -1).contains(bar))
            let center = controls.convert(NSPoint(x: controls.bounds.midX, y: controls.bounds.midY), to: nil)
            #expect(window.contentView?.superview?.hitTest(center)?.isDescendant(of: controls) == true)
        }
        func shrinkCompactWindow() throws {
            controller.setScale(.pointAccurate)
            let window = try #require(controller.window)
            let before = window.convertToScreen(display.view.convert(display.view.bounds, to: nil))
            try drag(window, from: try point(of: .lowerRight, in: display),
                     by: NSSize(width: -1000, height: 1000)) {
                let after = window.convertToScreen(display.view.convert(display.view.bounds, to: nil))
                #expect(abs(after.minX - before.minX) < 0.001 && abs(after.maxY - before.maxY) < 0.001)
            }
            try checkControls()
        }
        updateControls()
        let parent = NSViewController()
        parent.view = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 700))
        let main = KeyPresentationWindow(contentRect: parent.view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        main.isReleasedWhenClosed = false
        main.contentViewController = parent
        defer { main.close() }
        controller.embed(in: parent)
        if startInCompact {
            controller.showCompactWindow()
            controller.setScale(.pointAccurate)
        }
        let orientationRead = AsyncStream<Void>.makeStream()
        withObservationTracking { _ = session.isBusy } onChange: {
            orientationRead.continuation.yield(())
            orientationRead.continuation.finish()
        }
        if session.isBusy {
            var readings = orientationRead.stream.makeAsyncIterator()
            #expect(await readings.next() != nil)
        }
        try #require(session.canStartRecording)
        let idleControlsSize = controls.fittingSize
        controller.perform(.recordScreen)
        try await wait { session.recording != nil }
        let recording = try #require(session.recording)
        let firstFrame = AsyncStream<Void>.makeStream()
        withObservationTracking { _ = recording.hasStarted } onChange: {
            firstFrame.continuation.yield(())
            firstFrame.continuation.finish()
        }
        if !recording.hasStarted {
            var frames = firstFrame.stream.makeAsyncIterator()
            #expect(await frames.next() != nil)
        }
        try #require(recording.hasStarted)
        let startedAt = try #require(recording.startDate)
        updateControls()
        #expect(controls.fittingSize.width > idleControlsSize.width)
        #expect(controls.fittingSize.height == idleControlsSize.height)
        try checkControls()
        if startInCompact { try shrinkCompactWindow() }
        if startInCompact { controller.embed(in: parent) } else { controller.showCompactWindow() }
        if !startInCompact { try shrinkCompactWindow() }
        controller.presentationViewController.view.layoutSubtreeIfNeeded()
        #expect(controls.window === controller.presentationWindow && controls.superview === controller.presentationViewController.view)
        #expect(controller.canvasControls === controls && session.recording === recording && recording.startDate == startedAt)
        #expect(controls.fittingSize.width > idleControlsSize.width)
        #expect(display.disconnectCount == 0 && controller.session === session)
        let toolbar = try #require(controller.window?.toolbar)
        #expect(toolbar.items.filter { ["home", "saveScreen", "rotateRight"].contains($0.itemIdentifier.rawValue) }
            .allSatisfy { $0.isHidden })
        controller.perform(.stopRecording)
        #expect(recording.isStopping)
        try await recording.waitUntilFinished()
        if startInCompact { controller.showCompactWindow() } else { controller.embed(in: parent) }
        #expect(controller.canvasControls === controls && controls.window === controller.presentationWindow)
        #expect(controller.session === session && display.disconnectCount == 0)
    }

    @Test func theSaveScreenButtonStopsARecordingAsInSimulatorApp() async throws {
        // The first recorder delays finalization after SIGINT; the second fails.
        var recordings = 0
        let controller = try makeController(TestDisplay()) { _, _ in
            recordings += 1
            return Self.recorder(then: recordings == 1 ? "trap 'sleep 0.5; exit 0' INT; while :; do sleep 0.05; done"
                                                       : "sleep 0.3; exit 1")
        }
        defer { controller.invalidate() }
        let toolbar = try #require(controller.window?.toolbar)
        let items = toolbar.items.map(\.itemIdentifier.rawValue)
        #expect(items == ["NSToolbarFlexibleSpaceItem", "captureKeyboard", "home", "saveScreen", "rotateRight", "NSToolbarFlexibleSpaceItem"])
        let item = try #require(toolbar.items.first { $0.itemIdentifier.rawValue == "saveScreen" })
        func shows(_ symbol: String, _ label: String) -> Bool {
            item.toolTip == label && item.image?.accessibilityDescription == label && item.image?.tiffRepresentation
                == NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.tiffRepresentation
        }
        #expect(shows("camera.on.rectangle", "Save Screen"))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await controller.session.startRecording(to: .file(directory.appendingPathComponent("Recording.mov")), mask: .ignored)
        let recording = try #require(controller.session.recording)
        try await wait { shows("stop.circle", "Stop Recording") }
        #expect(shows("stop.circle", "Stop Recording"))
        #expect(item.label == "Save Screen")
        #expect(item.isEnabled)
        #expect(toolbar.items.map(\.itemIdentifier.rawValue) == items)
        #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
        try #require(recording.isStopping)
        // Restore the button before movie finalization completes.
        try await wait { shows("camera.on.rectangle", "Save Screen") }
        #expect(shows("camera.on.rectangle", "Save Screen"))
        #expect(controller.session.recording === recording)
        #expect(item.isEnabled)
        try await recording.waitUntilFinished()
        try await wait { controller.session.recording == nil }
        #expect(shows("camera.on.rectangle", "Save Screen"))
        #expect(toolbar.items.map(\.itemIdentifier.rawValue) == items)

        try await controller.session.startRecording(to: .file(directory.appendingPathComponent("Failed.mov")), mask: .ignored)
        try await wait { shows("stop.circle", "Stop Recording") }
        #expect(shows("stop.circle", "Stop Recording"))
        try await wait { controller.session.recording == nil }
        #expect(controller.session.recording == nil)
        try await wait { shows("camera.on.rectangle", "Save Screen") }
        #expect(shows("camera.on.rectangle", "Save Screen"))
    }

    @Test func aRecordingThatIsStartingBlocksAnotherAndIsFoundByWhatFinishesIt() async throws {
        var recordings = 0
        let display = TestDisplay()
        let controller = try makeController(display) { _, _ in
            recordings += 1
            return Self.recorder(then: "while :; do sleep 0.05; done")
        }
        defer { controller.invalidate() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = controller.session
        let destination = directory.appendingPathComponent("Recording.mov")
        let start = Task.immediate { try await session.startRecording(to: .file(destination), mask: .ignored) }
        // It is reserved before the first wait, while there is no recording to stop yet.
        #expect(session.recording == nil && !session.canStartRecording)
        try await session.startRecording(to: .file(directory.appendingPathComponent("Second.mov")), mask: .ignored)
        try await session.finishRecording()
        try await start.value
        try await wait { session.recording == nil }
        #expect(recordings == 1)
        #expect(display.announcedRecordings == [true, false])
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("Second.mov").path))
    }

    @Test func aRecordingThatStartsAfterItsSessionDisconnectsStopsAtOnce() async throws {
        let display = TestDisplay()
        let controller = try makeController(display) { _, _ in
            Self.recorder(then: "while :; do sleep 0.05; done")
        }
        defer { controller.invalidate() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = controller.session
        let start = Task.immediate {
            try await session.startRecording(to: .file(directory.appendingPathComponent("Recording.mov")), mask: .ignored)
        }
        session.disconnect()
        try await start.value
        let recording = try #require(try await session.activeRecording())
        #expect(recording.isStopping)
        try await session.finishRecording()
        try await wait { session.recording == nil }
    }

    @Test func finishingARecordingThatDoesNotStartGivesUpWhileTheStartGoesOnAndStopsItself() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lane = HeldCaptureLane(passing: 1)
        let store = RecordingStore(lane: lane)
        store.onError = { _ in }
        let session = try makeSession(TestDisplay(), recordingProcess: { _, _ in
            Self.recorder(then: "while :; do sleep 0.05; done")
        }, recordings: store)
        let start = Task.immediate {
            try await session.startRecording(to: .file(directory.appendingPathComponent("Held.mov")), mask: .ignored)
        }
        await lane.untilHeld(1)
        await #expect(throws: SimulatorError.self) { try await session.finishRecording(startLimit: .milliseconds(50)) }
        #expect(store.hasActiveRecordings)
        session.disconnect()
        lane.open()
        try await start.value
        #expect(session.recording?.isStopping == true)
        try await session.finishRecording()
        try await wait { session.recording == nil && !store.hasActiveRecordings }
    }

    /// A real host in this process, with no device and no window. It stops as a public context's does.
    @Test(.enabled("Another host would refuse this one.") { await noOtherHostIsDisplaying() })
    func stoppingDoesNotWaitOnAHeldRecordingOutlivesItWithItsFilesNamedAndTheNextStopReturnsItsLateFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lane = HeldCaptureLane(passing: 1)
        let store = RecordingStore(lane: lane, finishLimit: .milliseconds(50))
        let host = try SimulatorScreenHost(runtime: try await makeRuntime().io, conflicts: HostConflictMonitor(), inProcess: true,
                                           recordings: store)
        var reported: [String] = []
        host.onError = { reported.append($0.localizedDescription) }
        let destination = directory.appendingPathComponent("Held.mov")
        // It exits without a frame, so the recording fails once it has been let go.
        let start = Task.immediate {
            try await store.start(to: .file(destination), process: { _ in Self.recorder(then: "exit 0") }, onFinished: {})
        }
        await lane.untilHeld(1)
        do {
            try await host.stop(keepingDevicesRunning: true)
            Issue.record("Expected the stop to report the unfinished recording")
        } catch {
            #expect(error.localizedDescription.contains(destination.path))
            #expect(error.localizedDescription.contains("\(directory.path)/.neo-simulator-"))
        }
        #expect(store.hasActiveRecordings && reported.isEmpty && host.isStopped)
        lane.open()
        let recording = try await start.value
        #expect(recording.isStopping)
        try await wait { !store.hasActiveRecordings }
        #expect(reported.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        await #expect(throws: SimulatorError.self) { try await host.stop(keepingDevicesRunning: true) }
        try await host.stop(keepingDevicesRunning: true)
        #expect(reported.count == 1)
    }

    @Test func aRecordingKeepsSaveScreenAsStopRecordingWhateverOptionDoes() async throws {
        let controller = try makeController(TestDisplay()) { _, _ in
            Self.recorder(then: "trap 'sleep 0.3; exit 0' INT; while :; do sleep 0.05; done")
        }
        defer { controller.invalidate() }
        let pointer = try ToolbarPointer(controller)
        pointer.enter()
        pointer.hold(.option)
        #expect(pointer.faces == ButtonFace.optionAlternates)
        #expect(try pointer.click(.saveScreen))
        try await wait { controller.session.recording != nil }
        let recording = try #require(controller.session.recording)
        try await wait { pointer.faces[2] == .stopRecording }
        #expect(pointer.faces == [.captureKeyboard, .home, .stopRecording, .rotateLeft])
        pointer.hold([])
        #expect(pointer.faces == [.captureKeyboard, .home, .stopRecording, .rotate])
        pointer.exit()
        pointer.hold(.option)
        pointer.enter()
        #expect(pointer.faces == [.captureKeyboard, .home, .stopRecording, .rotateLeft])
        #expect(try pointer.click(.saveScreen))
        #expect(recording.isStopping)
        try await wait { pointer.faces[2] == .recordScreen }
        #expect(pointer.faces == ButtonFace.optionAlternates)
        pointer.hold([])
        #expect(pointer.faces == ButtonFace.normal)
        recording.stop()  // Does nothing unless the click failed to stop it.
        try await recording.waitUntilFinished()
        try await wait { controller.session.recording == nil }
        pointer.hold(.option)
        #expect(pointer.faces == ButtonFace.optionAlternates)
        #expect(try pointer.item(.saveScreen).isEnabled)
    }

    @Test func quickSaveScreenUsesTheScreenshotFolderAndMaskPreference() async throws {
        #expect(DeviceCommand.command(.saveScreen).key.isEmpty)
        let menus = MenuController(application: nil)
        let file = NSMenu(title: "File")
        menus.addScreenshotDestinationCommand(to: file)
        let destination = try #require(file.items.first)
        #expect(destination.representedObject as? String == DeviceCommand.ID.saveScreenAs.rawValue)
        #expect(destination.keyEquivalent == "s" && destination.keyEquivalentModifierMask == [.command, .option])
        #expect(destination.isAlternate && destination.target === menus && destination.action != nil)
        let chooseDestination = DeviceCommand.command(.saveScreenAs)
        #expect(!chooseDestination.validate(destination, for: nil))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("arguments"), simctl = directory.appendingPathComponent("simctl")
        try """
            #!/bin/sh
            printf '%s\\n' "$*" >> "\(log.path)"
            for last; do :; done
            printf '\\211PNG\\r\\n\\032\\n' > "$last"
            """.write(to: simctl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: simctl.path)
        let folder = directory.appendingPathComponent("Screenshots")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let keys = [HostPreferences.screenShotSaveLocation, HostPreferences.screenShotUseMask]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) } }
        UserDefaults.standard.set(folder.path, forKey: HostPreferences.screenShotSaveLocation)
        UserDefaults.standard.set(true, forKey: HostPreferences.screenShotUseMask)

        func lastScreenshot() throws -> String? {
            try String(contentsOf: log, encoding: .utf8).split(separator: "\n").last.map(String.init)
        }
        for framebufferMask in [true, false] {
            let controller = try makeController(TestDisplay(), framebufferMask: framebufferMask, simctl: simctl)
            defer { controller.invalidate() }
            #expect(chooseDestination.validate(destination, for: controller))
            #expect(controller.session.reserve())
            #expect(!chooseDestination.validate(destination, for: controller))
            controller.session.release()
            controller.perform(.saveScreen)
            while controller.session.isBusy {
                await withCheckedContinuation { continuation in
                    withObservationTracking { _ = controller.session.isBusy } onChange: { continuation.resume() }
                }
            }
            #expect(try lastScreenshot()?.contains("--mask=\(framebufferMask ? "alpha" : "ignored")") == true)
            _ = try await controller.session.screenPNG()
            #expect(try lastScreenshot()?.contains("--mask=ignored") == true)
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(names.count == 2)
        #expect(names.allSatisfy { $0.hasPrefix("Simulator Screenshot - Test iPhone - ") && $0.hasSuffix(".png") })
    }

    /// Only reads. Every message here is one the real set's workers send, against whatever devices this Mac has.
    @Test(.timeLimit(.minutes(1)))
    func nativeDeviceSetCapturesItsDevicesAndCatalogOnItsWorker() async throws {
        let runtime = try await makeRuntime()
        let set = runtime.io.openDeviceSet()
        #expect(runtime.io.openDeviceSet() === set)
        #expect(try await !set.resolvedPath().isEmpty)
        let devices = try await set.refresh()
        #expect(set.devices.map(\.identifier) == devices.map(\.identifier))
        let catalog = try await set.readCatalog()
        let lookup = catalog.catalog()
        for pairing in catalog.pairings.prefix(1) {
            #expect(lookup.canPair(pairing.watchType, pairing.watchRuntime, pairing.phoneType, pairing.phoneRuntime))
        }
        #expect(!lookup.canPair("no watch", "no runtime", "no phone", "no runtime"))
    }

    @Test func recordingsAreAnnouncedAsInSimulatorApp() async throws {
        let display = TestDisplay()
        let overlay = InputView()
        display.view.addSubview(overlay)
        display.plugin = SimulatorUserInterfacePlugin(overlayView: overlay, toolbar: nil)
        var recordings = 0
        let controller = try makeController(display, family: .vision, features: [], recordingProcess: { _, _ in
            recordings += 1
            return Self.recorder(then: recordings == 1 ? "while :; do sleep 0.05; done" : "sleep 0.1; exit 1")
        }, userInterfacePlugin: true)
        defer { controller.invalidate() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await controller.session.startRecording(to: .file(directory.appendingPathComponent("Recording.mov")), mask: .ignored)
        let recording = try #require(controller.session.recording)
        #expect(display.announcedRecordings == [true])
        // Simulator.app's plugin uses toggleVideoRecording: to stop recording.
        #expect(overlay.tryToPerform(NSSelectorFromString("toggleVideoRecording:"), with: nil))
        #expect(recording.isStopping)
        try await recording.waitUntilFinished()
        try await wait { controller.session.recording == nil }
        #expect(display.announcedRecordings == [true, false])
        try await controller.session.startRecording(to: .file(directory.appendingPathComponent("Failed.mov")), mask: .ignored)
        try await wait { controller.session.recording == nil }
        #expect(display.announcedRecordings == [true, false, true, false])
    }

    @Test func aRecordingKeepsTheToolbarsButtonsAndStyle() async throws {
        let threshold = Self.unifiedWidth()
        let display = TestDisplay()
        display.naturalSize = NSSize(width: threshold, height: 300)
        let controller = try makeController(display, recordingProcess: { _, _ in
            Self.recorder(then: "while :; do sleep 0.05; done")
        })
        defer { controller.invalidate() }
        controller.showWindow(nil)
        let window = try #require(controller.window)
        let toolbar = try #require(window.toolbar)
        func buttons() -> [DeviceCommand.ID]? {
            window.layoutIfNeeded()
            return toolbar.visibleItems?.compactMap { DeviceCommand.ID(rawValue: $0.itemIdentifier.rawValue) }
        }
        controller.perform(.pointAccurate)
        #expect(window.toolbarStyle == .unified)
        #expect(buttons() == [.captureKeyboard, .home, .saveScreen, .rotateRight])

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await controller.session.startRecording(to: .file(directory.appendingPathComponent("Recording.mov")), mask: .ignored)
        let recording = try #require(controller.session.recording)
        let saveScreen = try #require(toolbar.items.first { $0.itemIdentifier.rawValue == "saveScreen" })
        for _ in 0..<200 where saveScreen.toolTip != "Stop Recording" { try await Task.sleep(for: .milliseconds(10)) }
        #expect(saveScreen.toolTip == "Stop Recording")
        // Simulator.app preserves the toolbar measurement while the recording button changes.
        controller.setDeviceBezelVisible(false)
        #expect(window.toolbarStyle == .unified)
        #expect(buttons() == [.captureKeyboard, .home, .saveScreen, .rotateRight])
        recording.stop()
        try await recording.waitUntilFinished()
    }

    @Test func aRestartFinishesTheRecordingBeforeDisconnecting() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stopping = directory.appendingPathComponent("stopping"), finish = directory.appendingPathComponent("finish")
        try #require(mkfifo(stopping.path, 0o600) == 0 && mkfifo(finish.path, 0o600) == 0)
        let stoppingDescriptor = open(stopping.path, O_RDWR)
        try #require(stoppingDescriptor >= 0)
        let stoppingHandle = FileHandle(fileDescriptor: stoppingDescriptor, closeOnDealloc: true)
        let finishDescriptor = open(finish.path, O_RDWR)
        try #require(finishDescriptor >= 0)
        let finishHandle = FileHandle(fileDescriptor: finishDescriptor, closeOnDealloc: true)
        let (acknowledgements, acknowledgement) = AsyncStream<Void>.makeStream()
        stoppingHandle.readabilityHandler = { handle in
            if !handle.availableData.isEmpty { acknowledgement.yield(()) }
        }
        defer {
            stoppingHandle.readabilityHandler = nil
            acknowledgement.finish()
            try? stoppingHandle.close()
            try? finishHandle.close()
        }
        let display = TestDisplay()
        var recorder: Process?
        let controller = try makeController(display, recordingProcess: { _, _ in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", """
                exec 3<> "\(finish.path)"
                exec 4<> "\(stopping.path)"
                trap 'printf stopping >&4; IFS= read -r token <&3; exit 0' INT
                echo 'Recording started' >&2
                while :; do IFS= read -r token <&3; done
                """]
            recorder = process
            return process
        })
        defer { controller.invalidate() }
        try await controller.session.startRecording(to: .file(directory.appendingPathComponent("Recording.mov")), mask: .ignored)
        // SIGINT is safe only after the first-frame acknowledgement.
        let recording = try #require(controller.session.recording)
        while !recording.hasStarted {
            await withCheckedContinuation { continuation in
                withObservationTracking { _ = recording.hasStarted } onChange: { continuation.resume() }
            }
        }
        var recordingAtDisconnect: Bool?
        display.onDisconnect = { recordingAtDisconnect = recorder?.isRunning }
        let restart = Task { await controller.prepareForRestart() }
        var iterator = acknowledgements.makeAsyncIterator()
        try #require(await iterator.next() != nil)
        #expect(recordingAtDisconnect == nil && display.disconnectCount == 0)
        try finishHandle.write(contentsOf: Data("finish\n".utf8))
        await restart.value
        #expect(recordingAtDisconnect == false)
    }
}
