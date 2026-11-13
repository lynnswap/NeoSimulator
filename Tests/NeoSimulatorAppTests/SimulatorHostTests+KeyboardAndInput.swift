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
    @Test(.timeLimit(.minutes(1)))
    func releasingAScreenWaitsForItsNativeInputRemovalAndRetriesAFailedOne() async throws {
        let display = TestDisplay()
        display.holdsStop = true
        let controller = try makeController(display)
        // Hosts release and quit by invalidating the window, which starts the removal, then stopping its session.
        controller.invalidate()
        #expect(display.disconnectCount == 1 && display.stopCount == 1 && display.heldStop != nil)
        var stopped = false
        let failing = Task.immediate {
            try await controller.session.stop()
            stopped = true
        }
        #expect(display.stopCount == 1 && !stopped)
        display.completeStop(throwing: SimulatorError.operation("Could not remove the native keyboard services"))
        await #expect(throws: SimulatorError.self) { try await failing.value }
        // Stopping again removes what remained instead of reporting the earlier attempt.
        let retrying = Task.immediate {
            try await controller.session.stop()
            stopped = true
        }
        #expect(display.stopCount == 2 && display.heldStop != nil && !stopped)
        display.completeStop()
        try await retrying.value
    }

    @Test func embeddedAndCompactPresentationsKeepOneSessionAndInputOwner() async throws {
        _ = NSApplication.shared
        let display = TestDisplay()
        let preferences = MemoryPreferences()
        let screens = NSScreen.screens.map(\.frame)
        let visible = try #require(NSScreen.main?.visibleFrame)
        let savedCenter = NSPoint(x: visible.midX, y: visible.midY)
        preferences.setWindowGeometry(center: savedCenter, scale: 0.5, forDevice: "test-device", screens: screens)
        var closes = 0
        var compactPresentations = 0
        var shutdownRequests = 0
        let controller = try makeController(display, features: [DeviceCapabilities.keyboard], preferences: preferences,
            presentCompactWindow: { _ in compactPresentations += 1 }, onClose: { _, _ in closes += 1 },
            onShutDown: { _ in shutdownRequests += 1 })
        defer { controller.invalidate() }
        let controls = DeviceCanvasControls()
        controls.update(supports: { _ in true }, isEnabled: { _ in true }, recordingTitle: "Record Screen")
        controller.canvasControls = controls
        let compactRoot = try #require(controller.window?.contentView)
        let session = controller.session
        let parent = NSViewController()
        parent.view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        let window = KeyPresentationWindow(contentRect: parent.view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = parent
        defer { window.close() }
        controller.embed(in: parent)
        let untouched = preferences.windowGeometry(forDevice: "test-device", screens: screens)
        #expect(untouched.center == savedCenter && untouched.scale == 0.5)
        parent.view.layoutSubtreeIfNeeded()
        #expect(controller.presentationViewController.parent === parent)
        #expect(controller.presentationWindow === window)
        #expect(DeviceWindowController.deviceWindow(for: window) === controller)
        let screenshot = NSMenuItem(title: "Save Screenshot", action: #selector(DeviceWindowController.saveScreenshot(_:)), keyEquivalent: "")
        #expect(controller.presentationViewController.supplementalTarget(forAction: screenshot.action!, sender: screenshot)
            as AnyObject? === controller)
        #expect(controller.validateMenuItem(screenshot))
        #expect(display.view.isDescendant(of: controller.presentationViewController.view))
        controller.focusInput()
        #expect(window.firstResponder === display.inputView && display.trackpad.last == true)
        #expect(controller.session === session && display.disconnectCount == 0)
        #expect(DeviceCommand.command(.fitScreen).isEnabled(controller))
        #expect(!DeviceCommand.command(.stayOnTop).isEnabled(controller))
        controller.perform(.stayOnTop)
        #expect(controller.window?.level == .normal)
        controller.perform(.shutDown)
        #expect(shutdownRequests == 1 && display.isBooted && session.isConnected)
        parent.view.setFrameSize(NSSize(width: 300, height: 480))
        parent.view.layoutSubtreeIfNeeded()
        let content = controller.presentationViewController.view
        #expect(controller.window?.contentView === compactRoot)
        #expect(!content.isDescendant(of: compactRoot))
        #expect(content.bounds.contains(display.view.convert(display.view.bounds, to: content)))
        let accessory = DeviceCanvasAccessoryViewController()
        var minimumWidth: CGFloat = 0
        accessory.onMinimumWidthChange = { minimumWidth = $0 }
        parent.view.addSubview(accessory.view)
        accessory.setControls(controls)
        controller.onSessionChange = { accessory.refresh() }
        #expect(controls.isDescendant(of: accessory.view))
        controller.detachPresentation()
        #expect(controller.presentationViewController.parent == nil && content.superview == nil)
        try controller.validatePresentationMove()
        // Moving the screen ends its trackpad gestures, which the next presentation's window takes again.
        #expect(display.disconnectCount == 0 && closes == 0 && display.trackpad.last == false)
        controller.showCompactWindow()
        #expect(!controller.isEmbedded && compactPresentations == 1)
        let compactWindow = try #require(controller.window)
        #expect(abs(compactWindow.frame.midX - savedCenter.x) < 1 && abs(compactWindow.frame.midY - savedCenter.y) < 1)
        #expect(DeviceCommand.command(.fitScreen).isEnabled(controller))
        #expect(DeviceCommand.command(.stayOnTop).isEnabled(controller))
        controller.perform(.stayOnTop)
        #expect(controller.window?.level == .floating)
        controller.perform(.stayOnTop)
        #expect(controller.window?.level == .normal)
        #expect(controller.window?.contentView === compactRoot && content.superview === compactRoot)
        #expect(content.frame == compactRoot.bounds && controls.superview === content)
        controller.setScale(.physicalSize)
        let compactScale = display.renderScale
        compactWindow.setFrameOrigin(NSPoint(x: visible.minX + 20, y: visible.minY + 20))
        let movedCenter = NSPoint(x: compactWindow.frame.midX, y: compactWindow.frame.midY)
        controller.embed(in: parent)
        parent.view.layoutSubtreeIfNeeded()
        controller.detachPresentation()
        controller.embed(in: parent)
        controller.showCompactWindow()
        #expect(WindowScale.matches(display.renderScale, compactScale))
        #expect(abs(compactWindow.frame.midX - movedCenter.x) < 1 && abs(compactWindow.frame.midY - movedCenter.y) < 1)
        controller.embed(in: parent)
        #expect(controller.session === session && display.disconnectCount == 0 && closes == 0)
        let search = NSSearchField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        parent.view.addSubview(search)
        #expect(window.makeFirstResponder(search))
        let editor = window.firstResponder
        #expect(editor !== display.inputView)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        #expect(window.firstResponder === editor)
        controller.focusInput()
        accessory.setControls(controls)
        #expect(!accessory.isHidden && minimumWidth > 0)
        await controller.prepareForRestart()
        let replacement = TestDisplay()
        let replacementSession = try makeSession(replacement, features: [DeviceCapabilities.keyboard])
        controller.reconnect(replacementSession, present: false)
        #expect(controller.isEmbedded && controller.presentationViewController.parent === parent)
        #expect(controller.session === replacementSession && compactPresentations == 2)
        #expect(controller.window?.contentView === compactRoot)
        #expect(replacement.disconnectCount == 0 && display.disconnectCount == 1 && closes == 0)
        #expect(controller.canvasControls === controls && controls.window === window)
        #expect(controls.isDescendant(of: accessory.view) && !accessory.isHidden && minimumWidth > 0)
        #expect(window.firstResponder === replacement.inputView && replacement.keyboard.last == true)
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                             styleMask: .titled, backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        let originalAnimation = window.animationBehavior
        window.animationBehavior = .none
        sheet.animationBehavior = .none
        let (endedSheets, sheetEnded) = AsyncStream<NSApplication.ModalResponse>.makeStream()
        defer {
            if window.attachedSheet === sheet { window.endSheet(sheet, returnCode: .cancel) }
            sheet.orderOut(nil)
            sheet.close()
            window.animationBehavior = originalAnimation
        }
        window.beginSheet(sheet) { response in
            sheetEnded.yield(response)
            sheetEnded.finish()
        }
        #expect(window.attachedSheet === sheet)
        #expect(throws: SimulatorError.self) { try controller.validatePresentationMove() }
        replacement.onDisconnect = { #expect(window.attachedSheet == nil) }
        controller.invalidate()
        #expect(window.attachedSheet == nil)
        if window.attachedSheet === sheet { window.endSheet(sheet, returnCode: .cancel) }
        var ended = endedSheets.makeAsyncIterator()
        #expect(await ended.next() == .cancel)
        #expect(replacement.disconnectCount == 1 && display.disconnectCount == 1 && closes == 0)
        let saved = preferences.windowGeometry(forDevice: session.device.identity.preferenceIdentifier, screens: NSScreen.screens.map(\.frame))
        #expect(saved.scale.map { WindowScale.matches($0, compactScale) } == true)
        #expect(saved.center == movedCenter)
    }

    @Test func commandsAndActivationRestoreTheNativeInputOwner() throws {
        _ = NSApplication.shared
        let display = TestDisplay()
        let controller = try makeController(display)
        let window = try #require(controller.window)
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
        #expect(window.firstResponder === display.inputView)
        #expect(display.keyboard.last == true)
        #expect(display.input.modifiers.count == 1)
        #expect(display.input.modifiers.last?.modifierFlags == NSEvent.modifierFlags)
        for command in [DeviceCommand.ID.home, .lock, .toggleSoftwareKeyboard] {
            window.makeFirstResponder(window)
            controller.perform(command)
            #expect(window.firstResponder === display.inputView)
        }
        #expect(display.buttons == [.home, .lock, .softwareKeyboard])
        #expect(display.input.modifiers.count == 4)
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: window))
        #expect(display.keyboard.last == false)
        controller.invalidate()
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        #expect(display.keyboard.last == false)
        #expect(display.input.modifiers.count == 4)
        #expect(display.disconnectCount == 1)
    }

    @Test func theToolbarsButtonsShowTheirOptionAlternatesWhileThePointerIsOverTheToolbar() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("arguments"), devicectl = directory.appendingPathComponent("devicectl")
        try """
            #!/bin/sh
            printf '%s\\n' "$*" >> "\(log.path)"
            printf '{"result":{"deviceOrientation":"portrait","deviceOrientationNonFlat":"portrait"}}'
            """.write(to: devicectl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: devicectl.path)
        let controller = try makeController(TestDisplay(), devicectl: devicectl)
        defer { controller.invalidate() }
        let pointer = try ToolbarPointer(controller)
        func rotation() async throws -> String? {
            for _ in 0..<300 where controller.session.isBusy { try await Task.sleep(for: .milliseconds(10)) }
            let rotate = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").last { $0.contains(" rotate ") }
            return rotate?.split(separator: " ").dropLast().last.map(String.init)
        }
        #expect(pointer.faces == ButtonFace.normal)
        pointer.hold(.option)
        #expect(pointer.faces == ButtonFace.normal)
        pointer.hold([])
        pointer.enter()
        #expect(pointer.faces == ButtonFace.normal)
        pointer.hold(.option)
        #expect(pointer.faces == ButtonFace.optionAlternates)
        pointer.hold([.option, .shift])
        #expect(pointer.faces == ButtonFace.optionAlternates)
        pointer.hold(.shift)
        #expect(pointer.faces == ButtonFace.normal)
        pointer.hold(.option)
        #expect(try pointer.click(.rotateRight))
        #expect(try await rotation() == "left")
        pointer.exit()
        #expect(pointer.faces == ButtonFace.normal)
        pointer.hold([])
        pointer.hold(.option)
        #expect(pointer.faces == ButtonFace.normal)
        #expect(try pointer.click(.rotateRight))
        #expect(try await rotation() == "right")
        pointer.enter()
        #expect(pointer.faces == ButtonFace.optionAlternates)
        pointer.hold([])
        #expect(pointer.faces == ButtonFace.normal)
    }

    @Test func refusedFocusDoesNotSendModifierEvents() throws {
        let display = TestDisplay()
        let controller = try makeController(display)
        let refusing = RefusingResponder()
        controller.window?.makeFirstResponder(refusing)
        controller.focusInput()
        #expect(controller.window?.firstResponder === refusing)
        #expect(display.input.modifiers.isEmpty)
        controller.invalidate()
    }

    @Test func keyboardInputAndModifiersFollowTheKeyWindow() throws {
        _ = NSApplication.shared
        let first = TestDisplay()
        let second = TestDisplay()
        let a = try makeController(first)
        let b = try makeController(second)
        defer { a.invalidate(); b.invalidate() }
        var events: [(flags: NSEvent.ModifierFlags, keyboards: [[Bool]])] = []
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            events.append((event.modifierFlags, [first.keyboard, second.keyboard]))
            return event
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        let flags = NSEvent.modifierFlags
        a.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: a.window))
        a.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: a.window))
        b.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: b.window))
        #expect(first.keyboard == [true, false])
        #expect(second.keyboard == [true])
        // The key window's screen also takes trackpad gestures; losing focus ends them.
        #expect(first.trackpad == [true, false] && second.trackpad == [true])
        #expect(events.map(\.flags) == [flags, [], flags])
        #expect(events.map(\.keyboards) == [[[true], []], [[true], []], [[true, false], [true]]])
        a.invalidate()
        a.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
        a.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        #expect(first.keyboard == [true, false] && first.trackpad == [true, false])
        #expect(events.count == 3)
    }

    @Test func deactivatingReleasesTheKeyboardsModifiersWithoutTheDigitizer() throws {
        _ = NSApplication.shared
        let display = TestDisplay()
        let controller = try makeController(display)
        defer { controller.invalidate() }
        let window = try #require(controller.window)
        // AppKit passes key events to the app's key window, which stays this
        // window while the app deactivates.
        window.makeKeyAndOrderFront(nil)
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
        #expect(window.firstResponder === display.inputView)
        let seen = display.input.modifiers.count
        var released: [NSEvent.ModifierFlags] = []
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            released.append(event.modifierFlags)
            return event
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: window))
        // SimulatorKit's keyboard monitor still takes the release, while the
        // digitizer keeps a gesture in progress.
        #expect(released == [[]])
        #expect(display.input.modifiers.count == seen)
        #expect(display.keyboard == [true, false])
        #expect(window.firstResponder === display.inputView)
    }

    @Test func editMenuLeavesEditingKeysToTheFocusedSimulator() throws {
        _ = NSApplication.shared
        MenuController(application: nil).install()
        defer { NSApp.mainMenu = nil }
        let display = TestDisplay()
        let controller = try makeController(display)
        defer { controller.invalidate() }
        let window = try #require(controller.window)
        window.makeKeyAndOrderFront(nil)
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
        #expect(window.firstResponder === display.inputView)
        let editing = try [("z", 6), ("x", 7), ("c", 8), ("v", 9)].map { key, code in
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: UInt16(code)))
        }
        for event in editing { NSApp.sendEvent(event) }
        #expect(display.input.keyDowns.map(\.keyCode) == [6, 7, 8, 9])
        window.makeFirstResponder(window)
        #expect(NSApp.mainMenu?.performKeyEquivalent(with: editing[3]) == true)
        let externalDisplay = TestDisplay()
        let external = try ExternalDisplayWindowController(session: controller.session, display: externalDisplay,
            state: ExternalScreenState(isPoweredOn: true, pixelSize: CGSize(width: 720, height: 480), scale: 1),
            deviceWindow: controller, preferences: MemoryPreferences(), onClose: {})
        defer { external.invalidate() }
        let externalWindow = try #require(external.window)
        #expect(externalWindow.makeFirstResponder(externalDisplay.inputView))
        #expect(externalWindow.firstResponder === externalDisplay.inputView)
        #expect(DeviceWindowController.deviceWindow(for: externalWindow) === controller)
        let editMenu = try #require(NSApp.mainMenu?.items.first { $0.title == "Edit" }?.submenu as? EditMenu)
        for event in editing {
            let characters = try #require(event.characters)
            let charactersIgnoringModifiers = try #require(event.charactersIgnoringModifiers)
            let externalEvent = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: externalWindow.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: charactersIgnoringModifiers,
                isARepeat: false, keyCode: event.keyCode))
            #expect(externalEvent.window === externalWindow)
            #expect(!editMenu.performKeyEquivalent(with: externalEvent))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func testingDevicesHiddenDuringAReadAreNotInWhatItReturns() async throws {
        let (host, device, channel, cleanUp) = try await makeHostWithListedTestingDevice()
        defer { cleanUp() }
        #expect(try await host.readAvailableDevices().contains { $0.identity == device })

        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let holding = Task { try await channel.read("hold the set", limit: .seconds(30)) { release.wait() } }
        try await waitForStates(of: channel, [.running])
        let reading = Task { try await host.readAvailableDevices() }
        try await waitForStates(of: channel, [.running, .waiting])
        host.toggleShowTestingDevices()
        release.signal()
        try await holding.value
        #expect(try await !reading.value.contains { $0.identity == device })
        try await host.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func hidingTestingDevicesEndsTheirStateWaitsWithoutADeviceEvent() async throws {
        let (host, device, _, cleanUp) = try await makeHostWithListedTestingDevice()
        defer { cleanUp() }
        let (reads, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        let waiting = Task {
            try await host.waitForDevice(device, until: { _ in continuation.yield(()); return false },
                                         deadline: .now + .seconds(30))
        }
        defer { waiting.cancel() }
        var iterator = reads.makeAsyncIterator()
        await iterator.next()
        host.toggleShowTestingDevices()
        #expect(try await waiting.value == nil)
        try await host.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func aTestingDeviceHiddenWhileItIsReadDoesNotOpen() async throws {
        let (host, device, channel, cleanUp) = try await makeHostWithListedTestingDevice()
        defer { cleanUp() }

        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let holding = Task { try await channel.read("hold the set", limit: .seconds(30)) { release.wait() } }
        try await waitForStates(of: channel, [.running])
        let opening = Task {
            try await host.openSimulatorLocally(withIdentifier: device, bootIfNeeded: false, presents: false)
        }
        try await waitForStates(of: channel, [.running, .waiting])
        host.toggleShowTestingDevices()
        release.signal()
        try await holding.value
        let failure = await #expect(throws: SimulatorError.self) { try await opening.value }
        #expect(failure?.localizedDescription == "The selected simulator is no longer available")
        // What the read found would claim the device, and start it if it were not running, before anything read it again.
        #expect(!host.ownedDeviceIdentifiers.contains(device))
        try await host.stop()
    }

    @Test func commandHeldKeyUpReachesTheNativeInputUntilTheWindowCloses() throws {
        let display = TestDisplay()
        let controller = try makeController(display)
        defer { controller.invalidate() }
        let window = try #require(controller.window)
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
        let keyUp = try #require(NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9))
        NSApp.sendEvent(keyUp)
        #expect(display.input.keyUps.count == 1)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
        NSApp.sendEvent(keyUp)
        #expect(display.input.keyUps.count == 1)
    }

    @Test func nativeDisplayKeepsInputIdentityAndChromeActivation() async throws {
        _ = NSApplication.shared
        let runtime = try await makeRuntime()
        let display = runtime.display
        let type = try #require(NSClassFromString("SimulatorKit.SimDisplayView") as? NSView.Type)
        let view = type.init(frame: .zero)
        #expect(object_getIvar(view, display.keyboardDelegate) == nil)
        let input = try unsafe display.digitizerView.unsafeInvoke(on: view)
        #expect(input.isDescendant(of: view))
        #expect(input.nextResponder === view)
        for _ in 0..<100 {
            #expect(try unsafe display.digitizerView.unsafeInvoke(on: view) === input)
        }
        // The native trackpad places its gestures within the framebuffer's view, which the digitizer does not contain.
        let framebuffer = try unsafe display.renderableView.unsafeInvoke(on: view)
        #expect(String(describing: Swift.type(of: framebuffer)) == "SimDisplayRenderableView")
        #expect(framebuffer.isDescendant(of: view) && !framebuffer.isDescendant(of: input))
        let chrome = try unsafe display.chromeView.unsafeInvoke(on: view)
        try unsafe display.setRenderScale.unsafeInvoke(on: view, 0.75)
        #expect(try unsafe display.renderScale.unsafeInvoke(on: view) == 0.75)
        let renderView = try #require(chrome.subviews.first {
            String(describing: Swift.type(of: $0)) == "SimDisplayChromeRenderView"
        })
        for active in [true, false, true] {
            let value = try display.chromeState.makeEnumCase(named: active ? "active" : "inactive")
            try unsafe display.setChromeState.unsafeInvoke(on: chrome, value)
            let state = try #require(Mirror(reflecting: renderView).children.first { $0.label == "state" })
            #expect(String(describing: state.value) == (active ? "active" : "inactive"))
        }
        try unsafe display.disconnect.unsafeInvoke(on: view, NativeSwiftClosure {})
    }

    @Test func simulatorKitInputPassesKeysButNotModifiersToTheNativeKeyboard() async throws {
        _ = NSApplication.shared
        let runtime = try await makeRuntime()
        let display = runtime.display
        let type = try #require(NSClassFromString("SimulatorKit.SimDisplayView") as? NSView.Type)
        let view = type.init(frame: .zero)
        defer { _ = try? unsafe display.disconnect.unsafeInvoke(on: view, NativeSwiftClosure {}) }
        let input = try unsafe display.digitizerView.unsafeInvoke(on: view)
        // A connected display's digitizer is enabled. Only then does it check an event against the events it handles,
        // which would take any key it does not also ignore.
        let digitizer = try await ABIRuntime.shared.resolve(.swift(.type("SimulatorKit.SimDigitizerInputView")))
        let isEnabled = try await digitizer.resolve(.swift(.getter("isEnabled", as: (() -> Bool).self)))
        let isPaused = try await digitizer.resolve(.swift(.getter("isPaused", as: (() -> Bool).self)))
        try unsafe await digitizer.resolve(.swift(.setter("isEnabled", as: ((Bool) -> Void).self))).unsafeInvoke(on: input, true)
        #expect(try unsafe isEnabled.unsafeInvoke(on: input) && !isPaused.unsafeInvoke(on: input))
        var handled: [(NSEvent.EventType, NSEvent.ModifierFlags)] = []
        let responder = NativeKeyboardResponder { event in
            handled.append((event.type, event.modifierFlags))
            return true
        }
        responder.attach(after: input)
        responder.attach(after: input)
        #expect(input.nextResponder === responder && responder.nextResponder === view)
        // AppKit delivers Command key-downs here only after menus decline them; DisplayKeyboardInput forwards Command key-ups.
        for (type, flags) in [(NSEvent.EventType.keyDown, NSEvent.ModifierFlags()), (.keyUp, []), (.keyDown, .command),
                              (.keyUp, .command), (.flagsChanged, .shift)] {
            let event = try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: 0, context: nil, characters: type == .flagsChanged ? "" : "a",
                charactersIgnoringModifiers: type == .flagsChanged ? "" : "a", isARepeat: false, keyCode: type == .flagsChanged ? 56 : 0))
            switch type {
            case .keyDown: input.keyDown(with: event)
            case .keyUp: input.keyUp(with: event)
            default: input.flagsChanged(with: event)
            }
        }
        // The native keyboard observes modifier changes app-wide instead, as SimulatorKit's keyboard does.
        #expect(handled.map(\.0) == [.keyDown, .keyUp, .keyDown, .keyUp])
        #expect(handled.map { $0.1.contains(.command) } == [false, false, true, true])
        responder.detach()
        #expect(input.nextResponder === view)
    }

    @Test func nativeTouchDelegatePassesTheDigitizersOtherCallbacksToItsOwnDelegateUntilRestored() async throws {
        _ = NSApplication.shared
        let runtime = try await makeRuntime()
        let display = runtime.display
        let interface = try await runtime.touchInterface()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 600), styleMask: .titled,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let type = try #require(NSClassFromString("SimulatorKit.SimDisplayView") as? NSView.Type)
        let view = type.init(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        window.contentView = view
        defer { _ = try? unsafe display.disconnect.unsafeInvoke(on: view, NativeSwiftClosure {}) }
        let input = try unsafe display.digitizerView.unsafeInvoke(on: view)
        // The digitizer measures edge touches in its unflipped bounds, which SimulatorTouchInterface.edge(_:) assumes.
        #expect(!input.isFlipped)
        func delegate() throws -> AnyObject? {
            try unsafe interface.delegate.unsafeInvoke(on: input).map { try $0.withCopy { $0 as AnyObject } }
        }
        // A display that is not connected to a device has no delegate, so the digitizer gets one that records its
        // first-responder requests, as its own.
        #expect(try delegate() == nil)
        final class Requests: Sendable { let values = Mutex<[Bool]>([]) }
        let requests = Requests()
        let own = try ABIRuntime.shared.makeSwiftProtocolValueAndWait(SimulatorTouchInterface.delegateProtocol, methods: [
            try NativeSwiftProtocolMethod("simDigitizerInputView(_:touchEvent:)") { (_: NativeSwiftBorrowedValue, _: NativeSwiftBorrowedValue) in },
            try NativeSwiftProtocolMethod("simDigitizerInputView(_:wantsMouseMovedEvents:)") { (_: NativeSwiftBorrowedValue, _: Bool) in },
            try NativeSwiftProtocolMethod("simDigitizerInputView(_:wantsFirstResponder:)") { (_: NativeSwiftBorrowedValue, wants: Bool) in
                requests.values.withLock { $0.append(wants) }
            },
            try NativeSwiftProtocolMethod("simDigitizerInputView(_:pressureEvent:)") { (_: NativeSwiftBorrowedValue, _: NativeSwiftBorrowedValue) in },
            try NativeSwiftProtocolMethod("simDigitizerInputView(_:scrollEvent:)") { (_: NativeSwiftBorrowedValue, _: NativeSwiftBorrowedValue) in },
        ], valueABIs: interface.eventABIs)
        try unsafe interface.setDelegate.unsafeInvoke(on: input, own.copy())
        let ownDelegate = try #require(try delegate())

        // The native delegate replaces it. A call of its first-responder requirement, as the digitizer makes, reaches the
        // digitizer's own delegate.
        var received: [NativeDigitizerTouch] = []
        let touches = try await NativeDigitizerTouches(digitizer: input, interface: interface) { received.append($0) }
        // Preparing them leaves the digitizer as it was, so a touch that starts meanwhile stays with its own delegate.
        #expect(try delegate() === ownDelegate)
        try touches.install()
        weak let replacement = try delegate()
        #expect(replacement != nil && replacement !== ownDelegate)
        do {
            let installed = try #require(try unsafe interface.delegate.unsafeInvoke(on: input)).copyUnderlyingValue()
            let wantsFirstResponder = try installed.type.resolveAndWait(.swift(.method(
                SimulatorTouchInterface.delegateProtocol + ".simDigitizerInputView(_:wantsFirstResponder:)",
                as: ((NativeSwiftValue, Bool) -> Void).self)))
            let displayType = try await ABIRuntime.shared.resolve(.swift(.type("SimulatorKit.SimDisplayView")))
            let digitizer = try unsafe await displayType.resolve(.swift(.getter(
                "digitizerView.getter : SimulatorKit.SimDigitizerInputView", as: (() -> NativeSwiftValue).self))).unsafeInvoke(on: view)
            try unsafe wantsFirstResponder.unsafeInvoke(on: installed, digitizer, true)
        }
        #expect(requests.values.withLock { $0 } == [true])
        // A click on the enabled digitizer reaches the native touchscreen as a touch that begins and then ends. The
        // digitizer marks a click's start and end by the event's type, not by its phase.
        try unsafe await ABIRuntime.shared.resolve(.swift(.type("SimulatorKit.SimDigitizerInputView")))
            .resolve(.swift(.setter("isEnabled", as: ((Bool) -> Void).self))).unsafeInvoke(on: input, true)
        view.layoutSubtreeIfNeeded()
        try #require(!input.bounds.isEmpty)
        let center = input.convert(NSPoint(x: input.bounds.midX, y: input.bounds.midY), to: nil)
        for eventType in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let click = try #require(NSEvent.mouseEvent(with: eventType, location: center, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: eventType == .leftMouseDown ? 1 : 0))
            if eventType == .leftMouseDown { input.mouseDown(with: click) } else { input.mouseUp(with: click) }
        }
        #expect(received.map(\.phase) == [.began, .ended])
        // Restoring gives the digitizer its own delegate back. The digitizer keeps its delegate weakly, so the restored
        // replacement no longer exists.
        try touches.restore()
        #expect(try delegate() === ownDelegate)
        #expect(replacement == nil)
    }

    @Test func trackpadGesturesThatBeginOverTheFramebufferReachTheNativeTrackpadInsteadOfTheDigitizer() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 600), styleMask: .titled,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        // A window's CGEvent holds its location both globally and from the window's top-left corner, and
        // NSEvent(cgEvent:) reads either one, depending on the event and the macOS release. Both are the same while the
        // window's top-left corner is the global origin, the top-left corner of the screen with the menu bar.
        let screen = try #require(NSScreen.screens.first)
        window.setFrameTopLeftPoint(NSPoint(x: screen.frame.minX, y: screen.frame.maxY))
        let content = try #require(window.contentView)
        // The canvas pans and magnifies the display, whose digitizer also covers the bezel around the framebuffer.
        // In the window, the framebuffer spans x 60–300 and y 80–480.
        let canvas = NSView(frame: content.bounds)
        canvas.bounds = NSRect(x: 40, y: 60, width: 200, height: 300)
        content.addSubview(canvas)
        let display = NSView(frame: NSRect(x: 50, y: 70, width: 160, height: 260))
        canvas.addSubview(display)
        let framebuffer = NSView(frame: NSRect(x: 20, y: 30, width: 120, height: 200))
        display.addSubview(framebuffer)
        #expect(NativeDeviceTrackpad.contentScale(of: framebuffer, renderScale: 1) == 2)
        #expect(NativeDeviceTrackpad.contentScale(of: framebuffer, renderScale: 2) == 4)
        display.addSubview(NSView(frame: display.bounds))
        // A bar above the canvas covers the framebuffer's lower edge.
        content.addSubview(NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 140)))
        var sent: [(event: NSEvent, transform: CGAffineTransform)] = []
        var ends = 0
        let input = NativeTrackpadInput(display: display, framebuffer: framebuffer,
                                        send: { sent.append(($0, $1)) }, endGestures: { ends += 1 })
        func event(_ type: CGEventType, at point: NSPoint, flags: CGEventFlags = [],
                   _ configure: (CGEvent) throws -> Void) throws -> NSEvent {
            let mouse = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
            let event = try #require(mouse.cgEvent)
            event.type = type
            event.flags = flags
            try configure(event)
            let made = try #require(NSEvent(cgEvent: event))
            try #require(made.window === window)
            try #require(made.locationInWindow == point)
            return made
        }
        func scroll(_ phase: CGScrollPhase?, momentum: CGMomentumScrollPhase = .none, at point: NSPoint,
                    flags: CGEventFlags = []) throws -> NSEvent {
            try event(.scrollWheel, at: point, flags: flags) {
                $0.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase?.rawValue ?? 0))
                $0.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue))
            }
        }
        /// A trackpad's magnify event with its gesture phase: 1 began, 2 changed, 4 ended.
        func pinch(_ phase: Int64, at point: NSPoint) throws -> NSEvent {
            try event(try #require(CGEventType(rawValue: 29)), at: point) {
                $0.setIntegerValueField(try #require(CGEventField(rawValue: 110)), value: 8)
                $0.setIntegerValueField(try #require(CGEventField(rawValue: 132)), value: phase)
            }
        }
        let inside = NSPoint(x: 180, y: 300), beside = NSPoint(x: 40, y: 300), underBar = NSPoint(x: 180, y: 100)
        // Until the screen's window gives it the gestures, AppKit delivers them to the digitizer.
        NSApp.sendEvent(try scroll(.began, at: inside))
        input.isEnabled = true
        // A scroll that begins over the framebuffer reaches the device until its momentum ends, also once the pointer
        // leaves the framebuffer, and so does a pinch; each event of a mouse wheel stands alone. AppKit delivers the
        // others, which begin beside the framebuffer, over the bar, or with Option, which pans the canvas.
        let taken = try [scroll(.began, at: inside), scroll(.changed, at: beside), scroll(.ended, at: beside),
                         scroll(nil, momentum: .begin, at: beside), scroll(nil, momentum: .end, at: beside),
                         scroll(nil, at: inside), pinch(1, at: inside), pinch(2, at: beside), pinch(4, at: beside)]
        let passed = try [scroll(.began, at: beside), scroll(.changed, at: inside), scroll(.began, at: inside, flags: .maskAlternate),
                          pinch(1, at: beside), pinch(2, at: inside), scroll(.began, at: underBar), pinch(1, at: underBar)]
        for event in taken + passed { NSApp.sendEvent(event) }
        #expect(sent.map { ObjectIdentifier($0.event) } == taken.map(ObjectIdentifier.init))

        // A mouse movement over the framebuffer places the trackpad's gestures. Its transform maps window locations
        // through the canvas's pan and magnification to the framebuffer's unit coordinates from its top-left corner.
        func mouseMoved(to point: NSPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        }
        let moved = try mouseMoved(to: inside)
        input.mouseMoved(with: moved)
        input.mouseMoved(with: try mouseMoved(to: beside))
        try #require(sent.count == taken.count + 1 && sent.last?.event === moved)
        let transform = try #require(sent.last?.transform)
        for (point, unit) in [(NSPoint(x: 60, y: 480), CGPoint.zero), (NSPoint(x: 300, y: 80), CGPoint(x: 1, y: 1)),
                              (inside, CGPoint(x: 0.5, y: 0.45))] {
            let mapped = point.applying(transform)
            #expect(abs(mapped.x - unit.x) < 0.001 && abs(mapped.y - unit.y) < 0.001, "\(point) -> \(mapped)")
        }

        // Losing the gestures ends a pinch in progress, whose remaining steps no longer reach the device.
        NSApp.sendEvent(try pinch(1, at: inside))
        input.isEnabled = false
        NSApp.sendEvent(try pinch(2, at: inside))
        input.isEnabled = true
        NSApp.sendEvent(try pinch(4, at: inside))
        #expect(ends == 1 && sent.count == taken.count + 2)
        input.isEnabled = false
    }

    @Test func aUserInterfacePluginGivesTheWindowItsToolbarAndTakesTheInput() throws {
        let display = TestDisplay()
        let overlay = InputView()
        display.view.addSubview(overlay)
        let toolbar = NSToolbar(identifier: "PluginToolbar")
        let pluginDelegate = TestPluginToolbarDelegate()
        toolbar.delegate = pluginDelegate
        toolbar.insertItem(withItemIdentifier: .flexibleSpace, at: 0)
        toolbar.insertItem(withItemIdentifier: TestPluginToolbarDelegate.itemIdentifier, at: 1)
        // SimulatorKit loads the Apple Vision Pro plugin before opening its window.
        display.plugin = SimulatorUserInterfacePlugin(overlayView: overlay, toolbar: toolbar)
        let controller = try makeController(display, family: .vision, features: [], userInterfacePlugin: true)
        defer { controller.invalidate() }
        let window = try #require(controller.window)
        #expect(window.toolbar === toolbar)
        var mainWindowRequests = 0
        controller.onShowInMainWindow = { mainWindowRequests += 1 }
        let mainWindowItem = try #require(toolbar.items.first { $0.itemIdentifier.rawValue == "ShowInMainWindow" })
        #expect(toolbar.items.first?.itemIdentifier == .flexibleSpace)
        #expect(toolbar.items.contains { $0.itemIdentifier == TestPluginToolbarDelegate.itemIdentifier })
        #expect(toolbar.delegate?.toolbarSelectableItemIdentifiers?(toolbar) == [TestPluginToolbarDelegate.itemIdentifier])
        #expect(NSApp.sendAction(try #require(mainWindowItem.action), to: mainWindowItem.target, from: mainWindowItem))
        #expect(mainWindowRequests == 1)
        controller.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification, object: window))
        mainWindowItem.validate()
        #expect(!mainWindowItem.isEnabled)
        controller.showInMainWindow(nil)
        #expect(mainWindowRequests == 1)
        controller.windowDidFailToEnterFullScreen(window)
        mainWindowItem.validate()
        #expect(mainWindowItem.isEnabled)
        controller.onShowInMainWindow = nil
        #expect(!toolbar.items.contains { $0.itemIdentifier.rawValue == "ShowInMainWindow" })
        #expect(toolbar.items.contains { $0.itemIdentifier == TestPluginToolbarDelegate.itemIdentifier })
        controller.focusInput()
        #expect(window.firstResponder === overlay)
        #expect(!overlay.modifiers.isEmpty && display.input.modifiers.isEmpty)
        #expect(overlay.tryToPerform(NSSelectorFromString("homeButtonPressed:"), with: nil))
        #expect(display.buttons == [.home])
    }

    @Test func unsupportedCommandsAreHiddenFromMenusAndToolbar() throws {
        _ = NSApplication.shared
        let menus = MenuController(application: nil)
        menus.install()
        defer { NSApp.mainMenu = nil }
        let controller = try makeController(TestDisplay(), features: [])
        defer { controller.invalidate() }
        let toolbar = try #require(controller.window?.toolbar)
        #expect(toolbar.items.compactMap { DeviceCommand.ID(rawValue: $0.itemIdentifier.rawValue) } ==
            [.home, .saveScreen])
        let device = try #require(NSApp.mainMenu?.items.first { $0.title == "Device" }?.submenu)
        menus.updateVisibility(in: device, for: controller.session.capabilities)
        let visible = device.items.filter { !$0.isHidden }
        #expect(visible.map { $0.isSeparatorItem ? "-" : $0.title } ==
            ["Restart", "Shut Down", "-", "Erase All Content and Settings…", "-", "Home", "Re-Center Open Apps", "Lock",
             "Shake", "App Switcher", "-", "Trigger Screenshot"])
        controller.perform(.rotateRight)
        #expect(!controller.session.isBusy)
    }

    @Test func showingOrHidingTheBezelKeepsTheScaleAndResizesTheWindow() throws {
        let display = TestDisplay()
        display.naturalSize = NSSize(width: 360, height: 400)
        display.bezel = NSSize(width: 40, height: 60)
        display.bezelPadding = NSSize(width: 10, height: 9)
        let controller = try makeController(display)
        defer { controller.invalidate() }
        controller.showWindow(nil)
        let window = try #require(controller.window)
        // iPad artwork has 9 points of top padding and a 1-point header gap.
        func showsDisplay(_ size: NSSize, below gap: CGFloat) -> Bool {
            display.view.frame.size == size
                && window.contentLayoutRect.size == NSSize(width: size.width, height: size.height + gap)
        }
        controller.perform(.pointAccurate)
        #expect(showsDisplay(NSSize(width: 400, height: 460), below: 1))
        let origin = window.frame.origin
        // Simulator.app preserves scale and the bottom-left corner when hiding the bezel.
        controller.setDeviceBezelVisible(false)
        #expect(display.renderScale == 1)
        #expect(DeviceCommand.command(.pointAccurate).state?(controller) == .on)
        #expect(showsDisplay(NSSize(width: 360, height: 400), below: 0))
        #expect(window.frame.origin == origin)
        #expect(window.styleMask.contains(.resizable))
        controller.perform(.pointAccurate)
        controller.setDeviceBezelVisible(true)
        #expect(display.renderScale == 1)
        #expect(showsDisplay(NSSize(width: 400, height: 460), below: 1))
        #expect(window.frame.origin == origin)
        #expect(window.styleMask.contains(.resizable))
        let visible = try #require(window.screen?.visibleFrame)
        display.screenScale = 2 * (window.screen?.backingScaleFactor ?? 1)
        controller.perform(.pixelAccurate)
        #expect(display.renderScale == 2)
        window.setFrameOrigin(NSPoint(x: window.frame.minX, y: visible.maxY - window.frame.height + 100))
        #expect(window.frame.maxY == visible.maxY + 18)
        controller.setDeviceBezelVisible(false)
        window.setFrameOrigin(NSPoint(x: window.frame.minX, y: visible.maxY - window.frame.height + 100))
        #expect(window.frame.maxY <= visible.maxY)
    }

    @Test func aPressOnTheBezelOutsideItsCornersMovesTheWindow() throws {
        var drags: [(window: NSWindow, event: NSEvent)] = []
        let (controller, display) = try makeBezelController { drags.append(($0, $1)) }
        defer { controller.invalidate() }
        let window = try #require(controller.window)
        let view = display.view, scale = display.renderScale
        // The digitizer covers the screen and adjacent bezel; bezel buttons consume their own presses.
        display.input.frame = view.bounds.insetBy(dx: 3 * scale, dy: 3 * scale)
        let button = TestButton(frame: NSRect(x: view.bounds.maxX - 10 * scale, y: view.bounds.midY,
                                              width: 10 * scale, height: 30 * scale))
        view.addSubview(button)
        // Unhandled bezel presses reach the window's drag handling.
        let edge = view.convert(NSPoint(x: 1.5 * scale, y: view.bounds.midY), to: nil)
        #expect(try press(window, at: edge) === view)
        display.input.passesOnPresses = true
        let nextToScreen = view.convert(NSPoint(x: 6 * scale, y: view.bounds.midY), to: nil)
        #expect(try press(window, at: nextToScreen) === display.input)
        display.input.passesOnPresses = false
        #expect(drags.map(\.window) == [window, window])
        #expect(drags.map(\.event.locationInWindow) == [edge, nextToScreen])
        let screen = try press(window, at: view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil))
        let pressedButton = try press(window, at: view.convert(NSPoint(x: button.frame.midX, y: button.frame.midY), to: nil))
        #expect(screen === display.input && display.input.presses.count == 2)
        #expect(pressedButton === button && button.presses.count == 1)
        let corner = window.convertPoint(fromScreen: try point(of: .lowerLeft, in: display))
        try drag(window, from: window.convertPoint(toScreen: corner), by: NSSize(width: -30, height: -55)) {
            #expect(!display.isResizing)
        }
        // No view consumes the header gap, so its presses reach window dragging.
        let content = controller.presentationViewController.view
        let gap = content.convert(NSPoint(
            x: view.frame.midX, y: view.frame.maxY + WindowScale.displayGap(bezelPadding: display.chromePadding) / 2), to: nil)
        #expect(try press(window, at: gap) === content)
        #expect(drags.map(\.event.locationInWindow) == [edge, nextToScreen, corner, gap])
    }

    @Test func aPressOnTheBezelMovesNothingInFullScreen() throws {
        var drags = 0
        let (controller, display) = try makeBezelController { _, _ in drags += 1 }
        defer { controller.invalidate() }
        let window = try #require(controller.window)
        controller.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification, object: window))
        _ = try press(window, at: try pointOnBezel(of: display))
        #expect(drags == 0)
        controller.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: window))
        _ = try press(window, at: try pointOnBezel(of: display))
        #expect(drags == 1)
    }

    @Test func timedInputsKeepSimulatorAppDelays() async throws {
        let display = TestDisplay()
        let controller = try makeController(display)
        defer { controller.invalidate() }
        let clock = ContinuousClock()
        let start = clock.now
        controller.send(.pressTwice(.button(.home), interval: .milliseconds(150)))
        controller.send(.hold(.button(.actionStaccato), for: .milliseconds(500)))
        #expect(display.events.map(\.state) == [.down, .up, .down])
        while display.events.count < 6, clock.now - start < .seconds(5) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(clock.now - start >= .milliseconds(500))
        #expect(display.events.map(\.input) == [
            .button(.home), .button(.home), .button(.actionStaccato), .button(.home), .button(.home),
            .button(.actionStaccato),
        ])
        #expect(display.events.map(\.state) == [.down, .up, .down, .down, .up, .up])
    }

    @Test func closingTheWindowReleasesHeldInputsAndCancelsLaterSteps() async throws {
        let display = TestDisplay()
        let controller = try makeController(display)
        controller.send(.hold(.button(.actionStaccato), for: .milliseconds(200)))
        controller.send(.pressTwice(.button(.home), interval: .milliseconds(200)))
        controller.invalidate()
        let sent = display.events.count
        #expect(display.events.last.map { $0.input == .button(.actionStaccato) && $0.state == .up } == true)
        try await Task.sleep(for: .milliseconds(400))
        #expect(display.events.count == sent)
    }

    @Test func aHeldInputIsReleasedDuringAShutdown() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Keep shutdown pending past the hold before failing.
        let simctl = directory.appendingPathComponent("simctl")
        try "#!/bin/sh\nsleep 1\nexit 1\n".write(to: simctl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: simctl.path)
        let display = TestDisplay()
        let controller = try makeController(display, simctl: simctl)
        defer { controller.invalidate() }
        let session = controller.session
        var releasedDuringShutdown = false
        display.onSend = { [weak session] in
            if session?.canPerformCommands == false { releasedDuringShutdown = true }
        }
        controller.send(.hold(.button(.actionStaccato), for: .milliseconds(10)))
        session.run({ try await session.shutDown() }, failure: { _ in })
        for _ in 0..<3000 where session.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        #expect(releasedDuringShutdown)
        #expect(display.events.map(\.state) == [.down, .up])
        #expect(session.canPerformCommands)
    }

    @Test func aLaterHoldReleasesAnInputWhoseReleaseFailed() async throws {
        let display = TestDisplay()
        display.undeliveredStates = [.up]
        let controller = try makeController(display)
        controller.session.send(.hold(.button(.actionStaccato), for: .milliseconds(10))) { _ in }
        for _ in 0..<300 where display.events.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        display.undeliveredStates = []
        controller.session.send(.hold(.button(.actionStaccato), for: .milliseconds(10))) { _ in }
        for _ in 0..<300 where display.events.count < 4 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(display.events.map(\.state) == [.down, .up, .down, .up])
        controller.invalidate()
        #expect(display.events.count == 4)
    }

    @Test func anEarlierDeliveryKeepsALaterPressTracked() async throws {
        let display = TestDisplay()
        display.deferCompletions = true
        display.undeliveredEvents = [3]
        let controller = try makeController(display)
        controller.session.send(.pressTwice(.button(.home), interval: .milliseconds(10))) { _ in }
        for _ in 0..<300 where display.events.count < 4 { try await Task.sleep(for: .milliseconds(10)) }
        display.pendingCompletions.forEach { $0() }
        controller.invalidate()
        #expect(display.events.map(\.state) == [.down, .up, .down, .up, .up])
    }

    @Test func aFailedInputReportsOneError() throws {
        let display = TestDisplay()
        display.deliveryError = SimulatorError.operation("delivery failed")
        let controller = try makeController(display)
        defer { controller.invalidate() }
        var failures: [Error] = []
        controller.session.send(.press(.button(.siri))) { failures.append($0) }
        #expect(display.events.count == 2)
        #expect(failures.count == 1)
    }

    @Test func keyboardAndTouchPressureMenusFollowSimulatorApp() throws {
        _ = NSApplication.shared
        let menus = MenuController(application: nil)
        menus.install()
        defer { NSApp.mainMenu = nil }
        let io = try #require(NSApp.mainMenu?.items.first { $0.title == "I/O" }?.submenu)
        func visible(_ features: Set<String>) -> [String] {
            menus.updateVisibility(in: io, for: DeviceCapabilities(family: .iPhone, runtimeVersion: 0x1B_00_00,
                                                                   supportsFeature: { features.contains($0) }))
            return io.items.filter { !$0.isHidden }.map { $0.isSeparatorItem ? "-" : $0.title }
        }
        #expect(visible([DeviceCapabilities.keyboard, DeviceCapabilities.touchPressure])
            == ["Keyboard", "Touch Pressure", "-", "Audio Input", "Audio Output", "-", "Open URL…"])
        #expect(visible([DeviceCapabilities.touchPressure])
            == ["Touch Pressure", "-", "Audio Input", "Audio Output", "-", "Open URL…"])
        #expect(visible([]) == ["Audio Input", "Audio Output", "-", "Open URL…"])
        func items(_ title: String) throws -> [NSMenuItem] {
            try #require(io.items.first { $0.title == title }?.submenu).items
        }
        let keyboard = try items("Keyboard"), pressure = try items("Touch Pressure")
        #expect(keyboard.map(\.title) == ["Use the Same Keyboard Language as macOS", "Connect Hardware Keyboard",
                                          "Capture Keyboard", "Toggle Software Keyboard"])
        #expect(pressure.map(\.title) == ["Use Trackpad Force", "Shallow Press", "Deep Press"])
        let shortcuts = (keyboard + pressure).filter { !$0.keyEquivalent.isEmpty }
        #expect(shortcuts.map(\.title) == ["Connect Hardware Keyboard", "Toggle Software Keyboard", "Shallow Press",
                                           "Deep Press"])
        #expect(shortcuts.map(\.keyEquivalent) == ["k", "k", "1", "2"])
        #expect(shortcuts.map(\.keyEquivalentModifierMask) == [[.command, .shift], .command, [.command, .shift],
                                                                [.command, .shift]])
    }

    @Test func connectHardwareKeyboardIsEachDevicesChoiceAndKeepsTheMacsKeyboardWithIt() async throws {
        let preferences = MemoryPreferences()
        let first = TestDisplay(), second = TestDisplay()
        let a = try makeController(first, device: "A", preferences: preferences)
        let b = try makeController(second, device: "B", preferences: preferences)
        defer { a.invalidate(); b.invalidate() }
        let connect = DeviceCommand.command(.connectHardwareKeyboard)
        let software = DeviceCommand.command(.toggleSoftwareKeyboard)
        a.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: a.window))
        #expect(connect.state?(a) == .on && first.keyboard == [true])

        a.perform(.connectHardwareKeyboard)
        try await wait { !first.hardwareKeyboard.isEmpty }
        #expect(first.hardwareKeyboard == [false])
        #expect(!preferences.connectsHardwareKeyboard(forDevice: "A"))
        #expect(connect.state?(a) == .off && connect.state?(b) == .on)
        #expect(first.keyboard == [true, false])
        a.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: a.window))
        a.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: a.window))
        #expect(first.keyboard == [true, false])
        // Trackpad gestures do not need the hardware keyboard.
        #expect(first.trackpad == [true, false, true])
        #expect(!software.isEnabled(a) && software.isEnabled(b))
        a.perform(.toggleSoftwareKeyboard)
        #expect(first.events.isEmpty)
        #expect(second.hardwareKeyboard.isEmpty)

        a.perform(.connectHardwareKeyboard)
        try await wait { first.hardwareKeyboard.count >= 2 }
        #expect(first.hardwareKeyboard == [false, true] && first.keyboard == [true, false, true])
        #expect(connect.state?(a) == .on && software.isEnabled(a))
    }

    @Test func aFailedHardwareKeyboardChangeIsReportedAndKept() async throws {
        let preferences = MemoryPreferences()
        let display = TestDisplay()
        display.hardwareKeyboardError = SimulatorError.operation("keyboard failed")
        let controller = try makeController(display, preferences: preferences)
        defer { controller.invalidate() }
        controller.showWindow(nil)
        let window = try #require(controller.window)
        controller.perform(.connectHardwareKeyboard)
        try await wait { window.attachedSheet != nil }
        #expect(try #require(window.attachedSheet).isVisible)
        // Simulator.app saves before applying; a failed choice remains available for retry.
        #expect(!preferences.connectsHardwareKeyboard(forDevice: "test-device"))
        window.endSheet(try #require(window.attachedSheet))
    }

    @Test func connectingAppliesTheDevicesKeyboardChoiceAndTheMacsLanguage() async throws {
        func apply(_ preferences: MemoryPreferences, device: String = "A", language: String? = "ja",
                   failing display: TestDisplay = TestDisplay()) async throws -> (TestDisplay, [String]) {
            let session = try makeSession(display, device: device, preferences: preferences,
                                          keyboardLanguage: { language })
            var failures: [String] = []
            await session.applyKeyboardSettings { failures.append($0.localizedDescription) }
            return (display, failures)
        }
        var (display, failures) = try await apply(MemoryPreferences())
        #expect(display.hardwareKeyboard == [true] && display.keyboardLanguages == ["ja"] && failures.isEmpty)
        let preferences = MemoryPreferences()
        preferences.setConnectsHardwareKeyboard(false, forDevice: "A")
        preferences.set(true, forKey: HostPreferences.connectHardwareKeyboard)
        (display, _) = try await apply(preferences)
        #expect(display.hardwareKeyboard == [false])
        preferences.set(false, forKey: HostPreferences.connectHardwareKeyboard)
        (display, _) = try await apply(preferences, device: "B")
        #expect(display.hardwareKeyboard == [false])
        preferences.setConnectsHardwareKeyboard(true, forDevice: "B")
        (display, _) = try await apply(preferences, device: "B")
        #expect(display.hardwareKeyboard == [true])

        preferences.set(false, forKey: HostPreferences.enableKeyboardSync)
        (display, failures) = try await apply(preferences)
        #expect(display.keyboardLanguages.isEmpty && failures.isEmpty)

        (display, failures) = try await apply(MemoryPreferences(), language: nil)
        #expect(display.hardwareKeyboard == [true] && display.keyboardLanguages.isEmpty && failures.count == 1)
        let failing = TestDisplay()
        failing.hardwareKeyboardError = SimulatorError.operation("keyboard failed")
        failing.keyboardLanguageError = SimulatorError.operation("language failed")
        (display, failures) = try await apply(MemoryPreferences(), failing: failing)
        #expect(display.hardwareKeyboard == [true] && display.keyboardLanguages == ["ja"])
        #expect(failures == ["keyboard failed", "language failed"])
    }

    @Test(.timeLimit(.minutes(1))) func theMacsInputSourceReachesTheKeyDeviceWhileLanguageSyncIsOn() async throws {
        let preferences = MemoryPreferences()
        var language = "en"
        let first = TestDisplay(), second = TestDisplay()
        let languageChanges = AsyncStream<String>.makeStream()
        first.keyboardLanguageDidChange = { languageChanges.continuation.yield($0) }
        second.keyboardLanguageDidChange = { languageChanges.continuation.yield($0) }
        var appliedLanguages = languageChanges.stream.makeAsyncIterator()
        let a = try makeController(first, device: "A", preferences: preferences, keyboardLanguage: { language })
        let b = try makeController(second, device: "B", preferences: preferences, keyboardLanguage: { language })
        defer { a.invalidate(); b.invalidate(); languageChanges.continuation.finish() }
        func changeInputSource(to new: String) {
            language = new
            NotificationCenter.default.post(name: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil)
        }
        changeInputSource(to: "en")
        #expect(first.keyboardLanguages.isEmpty && second.keyboardLanguages.isEmpty)
        a.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: a.window))
        changeInputSource(to: "ja")
        #expect(await appliedLanguages.next() == "ja")
        #expect(first.keyboardLanguages == ["ja"] && second.keyboardLanguages.isEmpty)
        a.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: a.window))
        b.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: b.window))
        changeInputSource(to: "de")
        #expect(await appliedLanguages.next() == "de")
        #expect(first.keyboardLanguages == ["ja"] && second.keyboardLanguages == ["de"])

        // Simulator.app changes only the app-wide preference.
        let sync = DeviceCommand.command(.syncKeyboardLanguage)
        #expect(sync.state?(a) == .on)
        b.perform(.syncKeyboardLanguage)
        #expect(preferences.values[HostPreferences.enableKeyboardSync] as? Bool == false)
        #expect(sync.state?(a) == .off && sync.state?(b) == .off)
        // Task.immediate returns at the disabled-sync guard before reaching the display await.
        changeInputSource(to: "fr")
        #expect(second.keyboardLanguages == ["de"])
        b.perform(.syncKeyboardLanguage)
        #expect(second.keyboardLanguages == ["de"])
        b.invalidate()
        changeInputSource(to: "it")
        #expect(second.keyboardLanguages == ["de"])
    }

    @Test func touchPressureFollowsTheAppsSettingsInEveryWindowThatTakesIt() async throws {
        let preferences = MemoryPreferences()
        var trackpad = true
        let touchPressure = TouchPressure(preferences: preferences, forceTouchTrackpad: { trackpad })
        let pressure: Set = [DeviceCapabilities.touchPressure]
        let watch = TestDisplay(), phone = TestDisplay(), other = TestDisplay(), external = TestDisplay()
        external.displayClass = 1
        func controller(_ display: TestDisplay, family: DeviceCapabilities.Family,
                        features: Set<String>) throws -> DeviceWindowController {
            try makeController(display, family: family, features: features, preferences: preferences,
                               touchPressure: touchPressure)
        }
        let w = try controller(watch, family: .watch, features: pressure)
        let p = try controller(phone, family: .iPhone, features: pressure)
        let o = try controller(other, family: .iPhone, features: [])
        let e = try controller(external, family: .iPhone, features: pressure)
        defer { for c in [w, p, o, e] { c.invalidate() } }
        // Simulator.app uses the device screen's pressure support and the Mac trackpad's Force Touch support.
        #expect([watch, phone, other, external].map(\.supportsTouchPressure) == [[true], [true], [false], [false]])
        #expect(watch.usesTrackpadForce == [true] && watch.touchModes == [.shallow])

        let force = DeviceCommand.command(.useTrackpadForce)
        #expect(force.isEnabled(p) && force.state?(p) == .on)
        p.perform(.useTrackpadForce)
        #expect(preferences.values[HostPreferences.useTrackpadForce] as? Bool == false)
        #expect(force.state?(w) == .off)
        #expect(watch.usesTrackpadForce == [true, false] && phone.usesTrackpadForce == [true, false])
        #expect(other.usesTrackpadForce == [true])
        p.perform(.useTrackpadForce)
        #expect(force.state?(p) == .on)
        trackpad = false
        #expect(!force.isEnabled(p) && force.state?(p) == .off)

        let shallow = DeviceCommand.command(.shallowPress), deep = DeviceCommand.command(.deepPress)
        #expect(shallow.isEnabled(w) && deep.isEnabled(w) && !deep.isEnabled(p))
        #expect(shallow.state?(w) == .on && deep.state?(w) == .off && shallow.state?(p) == .off)
        p.perform(.deepPress)
        #expect(watch.touchModes.last == .shallow)
        w.perform(.deepPress)
        #expect(watch.touchModes.last == .deep && phone.touchModes.last == .deep && other.touchModes == [.shallow])
        #expect(shallow.state?(w) == .off && deep.state?(w) == .on && deep.state?(p) == .off)
        let later = TestDisplay()
        let l = try controller(later, family: .watch, features: pressure)
        defer { l.invalidate() }
        #expect(later.touchModes == [.deep] && later.usesTrackpadForce == [false])
        await w.prepareForRestart()
        let restarted = TestDisplay()
        w.reconnect(try makeSession(restarted, family: .watch, features: pressure, preferences: preferences))
        #expect(restarted.supportsTouchPressure == [true] && restarted.touchModes == [.deep])
        w.perform(.shallowPress)
        #expect(restarted.touchModes == [.deep, .shallow] && watch.touchModes.last == .deep)
    }

    @Test func aForceTouchTrackpadConnectedLaterReachesOpenWindows() throws {
        let preferences = MemoryPreferences()
        var trackpad = false
        var trackpadsChanged: (@MainActor () -> Void)?
        let touchPressure = TouchPressure(preferences: preferences, forceTouchTrackpad: { trackpad },
                                          observeTrackpads: { trackpadsChanged = $0; return nil })
        let display = TestDisplay()
        let controller = try makeController(display, features: Self.defaultFeatures.union([DeviceCapabilities.touchPressure]),
                                            preferences: preferences, touchPressure: touchPressure)
        defer { controller.invalidate() }
        #expect(display.usesTrackpadForce == [false])
        trackpad = true
        trackpadsChanged?()
        #expect(display.usesTrackpadForce == [false, true])
        #expect(DeviceCommand.command(.useTrackpadForce).state?(controller) == .on)
        trackpadsChanged?()
        #expect(display.usesTrackpadForce == [false, true])
        trackpad = false
        trackpadsChanged?()
        #expect(display.usesTrackpadForce == [false, true, false])
    }

    @Test func theDigitizerTakesScrollingForADigitalCrownOrDialAndWithoutABezel() async throws {
        func makeDisplay() -> TestDisplay {
            let display = TestDisplay()
            display.bezelPadding = NSSize(width: 9, height: 0)
            return display
        }
        let preferences = MemoryPreferences()
        let watch = makeDisplay(), vision = makeDisplay(), phone = makeDisplay()
        let crown: Set<String> = [DeviceCapabilities.digitalCrown]
        let w = try makeController(watch, family: .watch, features: crown, device: "watch", preferences: preferences)
        let v = try makeController(vision, family: .vision, features: [DeviceCapabilities.digitalDial], device: "vision",
                                   preferences: preferences)
        let p = try makeController(phone, device: "phone", preferences: preferences)
        defer { for controller in [w, v, p] { controller.invalidate() } }
        // Scrolling controls a watch's Digital Crown and Apple Vision Pro's Digital Dial.
        #expect(watch.supportsScrolling.last == true && vision.supportsScrolling.last == true)
        #expect(phone.supportsScrolling.last == false)
        p.setDeviceBezelVisible(false)
        #expect(phone.supportsScrolling.last == true)
        p.setDeviceBezelVisible(true)
        #expect(phone.supportsScrolling.last == false)
        await w.prepareForRestart()
        let restarted = makeDisplay()
        w.reconnect(try makeSession(restarted, family: .watch, features: crown, device: "watch", preferences: preferences))
        #expect(restarted.supportsScrolling.last == true)
    }

    @Test func theGuestLearnsWhetherEdgeSwipesStartOnTheBezel() async throws {
        func makeDisplay() -> TestDisplay {
            let display = TestDisplay()
            display.bezelPadding = NSSize(width: 9, height: 0)
            return display
        }
        let preferences = MemoryPreferences()
        let phone = makeDisplay(), vision = TestDisplay()
        let p = try makeController(phone, device: "phone", preferences: preferences)
        let v = try makeController(vision, family: .vision, features: [], device: "vision", preferences: preferences)
        defer { for controller in [p, v] { controller.invalidate() } }
        // Simulator.app enables guest edge swipes whenever the bezel is visible.
        #expect(phone.wantsEdgeSwipes == [true] && vision.wantsEdgeSwipes == [false])
        p.setDeviceBezelVisible(false)
        #expect(phone.wantsEdgeSwipes.last == false)
        p.setDeviceBezelVisible(true)
        #expect(phone.wantsEdgeSwipes.last == true)
        await p.prepareForRestart()
        let restarted = makeDisplay()
        p.reconnect(try makeSession(restarted, device: "phone", preferences: preferences))
        #expect(restarted.wantsEdgeSwipes == [true])
    }

    @Test func touchIndicatorsFollowTheirPreferencesInEveryOpenWindow() async throws {
        let preferences = MemoryPreferences()
        let first = TestDisplay(), second = TestDisplay(), elsewhere = TestDisplay()
        let a = try makeController(first, device: "A", preferences: preferences)
        let b = try makeController(second, device: "B", preferences: preferences)
        let c = try makeController(elsewhere, device: "C")
        defer { for controller in [a, b, c] { controller.invalidate() } }
        #expect(first.touchIndicators == [.pinches] && elsewhere.touchIndicators == [.pinches])

        preferences.set(true, forKey: HostPreferences.showSingleTouches)
        preferences.set(false, forKey: HostPreferences.showPinches)
        preferences.set(true, forKey: HostPreferences.highlightEdgeGestures)
        NotificationCenter.default.post(name: TouchIndicator.didChangeNotification, object: preferences)
        #expect(first.touchIndicators == [.singleTouches, .edgeGestures])
        #expect(second.touchIndicators == [.singleTouches, .edgeGestures])
        #expect(elsewhere.touchIndicators == [.pinches])

        await a.prepareForRestart()
        let restarted = TestDisplay()
        a.reconnect(try makeSession(restarted, device: "A", preferences: preferences))
        #expect(restarted.touchIndicators == [.singleTouches, .edgeGestures])
        b.invalidate()
        preferences.set(true, forKey: HostPreferences.showPinchPivotPoint)
        NotificationCenter.default.post(name: TouchIndicator.didChangeNotification, object: preferences)
        #expect(restarted.touchIndicators == [.singleTouches, .pinchPivotPoint, .edgeGestures])
        #expect(second.touchIndicators == [.singleTouches, .edgeGestures])
    }

    @Test func settingsOpenTheManager() throws {
        _ = NSApplication.shared
        let controller = MenuController(application: nil)
        controller.install()
        defer {
            NSApp.mainMenu = nil
            withExtendedLifetime(controller) {}
        }
        let app = try #require(NSApp.mainMenu?.items.first?.submenu)
        let settings = try #require(app.items.first { $0.title == "Settings…" })
        #expect(settings.keyEquivalent == "," && settings.keyEquivalentModifierMask == .command)
        #expect(settings.target is MenuController)
        #expect(!app.items.contains { $0.title == "Device Settings…" })
        #expect(!app.items.contains { $0.title == "Display Host" })
    }
}
