import ABIBridge
import AppKit
import Testing

@Suite(.serialized) @MainActor
struct InputFocusTests {
    @Test func commandsAndActivationRestoreTheNativeInputOwner() throws {
        _ = NSApplication.shared
        let display = TestDisplay()
        let controller = try makeController(display)
        let window = try #require(controller.window)
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
        #expect(window.firstResponder === display.inputView)
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
        #expect(display.activations == [true, false])
        controller.invalidate()
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        #expect(display.activations == [true, false])
        #expect(display.input.modifiers.count == 4)
        #expect(display.disconnectCount == 1)
    }

    @Test func nativeToolbarPreservesDeviceCommandsAndBusyState() async throws {
        let display = TestDisplay()
        let controller = try makeController(display)
        defer { controller.invalidate() }
        let window = try #require(controller.window)
        #expect(window.title == "Test iPhone")
        #expect(window.subtitle == "iOS")
        #expect(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        let toolbar = try #require(window.toolbar)
        let commands = toolbar.items.filter { DeviceCommand.ID(rawValue: $0.itemIdentifier.rawValue) != nil }
        #expect(commands.filter { !$0.isHidden }.map(\.itemIdentifier.rawValue) ==
            ["home", "saveScreen", "rotateRight"])
        let home = try #require(commands.first { $0.itemIdentifier.rawValue == "home" })
        #expect(NSApp.sendAction(try #require(home.action), to: home.target, from: home))
        #expect(display.buttons == [.home])
        #expect(controller.session.reserve())
        await Task.yield()
        #expect(home.isEnabled)
        #expect(commands.filter { ["saveScreen", "rotateRight"].contains($0.itemIdentifier.rawValue) }
            .allSatisfy { !$0.isEnabled })
        controller.session.disconnect()
        await Task.yield()
        #expect(commands.allSatisfy { !$0.isEnabled })
    }

    @Test func toolbarShowsRecordingStopAndHidesItAfterCompletion() async throws {
        let controller = try makeController(TestDisplay()) { _, _ in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", """
                trap 'exit 0' INT
                echo 'Recording started' >&2
                while :; do sleep 0.05; done
                """]
            return process
        }
        defer { controller.invalidate() }
        let toolbar = try #require(controller.window?.toolbar)
        let item = try #require(toolbar.items.first { $0.itemIdentifier.rawValue == "stopRecording" })
        #expect(item.isHidden)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try controller.session.startRecording(to: .file(directory.appendingPathComponent("Recording.mov")), mask: .ignored)
        let recording = try #require(controller.session.recording)
        for _ in 0..<100 where item.isHidden { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!item.isHidden)
        #expect(item.isEnabled)
        #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
        for _ in 0..<100 where item.isEnabled { try await Task.sleep(for: .milliseconds(10)) }
        #expect(recording.isStopping)
        #expect(!item.isEnabled)
        try await recording.waitUntilFinished()
        for _ in 0..<100 where !item.isHidden { try await Task.sleep(for: .milliseconds(10)) }
        #expect(item.isHidden)
    }

    @Test func quickSaveScreenUsesTheScreenshotFolderAndMaskPreference() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // A simctl stand-in that logs its arguments and writes a PNG signature to the last one.
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
            controller.perform(.saveScreen)
            for _ in 0..<200 where controller.session.isBusy { try await Task.sleep(for: .milliseconds(10)) }
            // A device without a mask has nothing to apply.
            #expect(try lastScreenshot()?.contains("--mask=\(framebufferMask ? "alpha" : "ignored")") == true)
            // Copy Screen never applies the mask.
            _ = try await controller.session.screenPNG()
            #expect(try lastScreenshot()?.contains("--mask=ignored") == true)
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(names.count == 2)
        #expect(names.allSatisfy { $0.hasPrefix("Simulator Screenshot - Test iPhone - ") && $0.hasSuffix(".png") })
    }

    @Test func displayStaysBelowTheNativeToolbarWhenResized() throws {
        let controller = try makeController(TestDisplay())
        defer { controller.invalidate() }
        let window = try #require(controller.window)
        for size in [NSSize(width: 360, height: 780), NSSize(width: 800, height: 420)] {
            window.setContentSize(size)
            controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
            let content = try #require(window.contentView)
            let frame = controller.session.display.view.frame
            #expect(frame.minX >= 0)
            #expect(frame.minY >= 0)
            #expect(frame.maxX <= content.bounds.maxX)
            #expect(frame.maxY <= window.contentLayoutRect.maxY - 12)
            #expect(try #require(window.standardWindowButton(.closeButton)).isHidden == false)
        }
    }

    @Test func deviceToolPathsAreValidatedBeforeOperations() throws {
        #expect(FileManager.default.isExecutableFile(atPath: DeviceTools.simctl.path))
        #expect(FileManager.default.isExecutableFile(atPath: DeviceTools.devicectl.path))
        _ = try DeviceTools(identifier: "test-device", xcodeURL: URL(fileURLWithPath: "/Applications/Xcode.app"))
    }

    @Test func shutdownStatePreventsFurtherDeviceCommands() throws {
        let display = TestDisplay()
        let controller = try makeController(display)
        display.isBooted = false
        controller.perform(.home)
        controller.perform(.lock)
        #expect(!controller.session.canPerformCommands)
        #expect(!controller.session.canPerformToolOperation)
        #expect(display.buttons.isEmpty)
        controller.invalidate()
    }

    @Test func failedShutdownLeavesTheBootedDeviceUsable() async throws {
        let controller = try makeController(TestDisplay())
        defer { controller.invalidate() }
        var failure: Error?
        controller.session.run({ try await controller.session.shutDown() }, failure: { failure = $0 })
        for _ in 0..<3000 where controller.session.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        #expect(failure != nil)
        #expect(controller.session.canPerformCommands)
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
        #expect(events.map(\.flags) == [flags, [], flags])
        #expect(events.map(\.keyboards) == [[[true], []], [[true], []], [[true, false], [true]]])
        a.invalidate()
        a.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
        a.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        #expect(first.keyboard == [true, false])
        #expect(events.count == 3)
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

    @Test func nativeDisplayKeepsInputIdentityAndChromeActivation() throws {
        _ = NSApplication.shared
        let selection = Process()
        let output = Pipe()
        selection.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        selection.arguments = ["-p"]
        selection.standardOutput = output
        try selection.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        selection.waitUntilExit()
        let developerPath = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
            ?? String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let xcode = URL(fileURLWithPath: developerPath).deletingLastPathComponent().deletingLastPathComponent()
        let runtime = try SimulatorRuntime(xcodeURL: xcode)
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

    @Test func unsupportedCommandsAreHiddenFromMenusAndToolbar() throws {
        _ = NSApplication.shared
        let menus = MenuController(application: nil)
        menus.install()
        defer { NSApp.mainMenu = nil }
        let controller = try makeController(TestDisplay(), features: [])
        defer { controller.invalidate() }
        let toolbar = try #require(controller.window?.toolbar)
        #expect(toolbar.items.compactMap { DeviceCommand.ID(rawValue: $0.itemIdentifier.rawValue) } ==
            [.home, .saveScreen, .stopRecording])
        let device = try #require(NSApp.mainMenu?.items.first { $0.title == "Device" }?.submenu)
        menus.updateVisibility(in: device, for: controller.session.capabilities)
        let visible = device.items.filter { !$0.isHidden }
        #expect(visible.map { $0.isSeparatorItem ? "-" : $0.title } ==
            ["Restart", "Erase All Content and Settings…", "Shut Down", "-", "Home", "Lock", "Shake",
             "App Switcher", "-", "Trigger Screenshot"])
        controller.perform(.rotateRight)
        #expect(!controller.session.isBusy)
    }

    @Test func orientationReadingsKeepTheUprightAngleWhileFlat() throws {
        func reading(_ physical: String, _ nonFlat: String) throws -> (DeviceOrientation, Double) {
            let reading = try OrientationReading(devicectlOutput: Data("""
                {"info": {"outcome": "success"}, "result": {"deviceIdentifier": "test-device",
                 "deviceIsOrientationLocked": false, "deviceOrientation": "\(physical)",
                 "deviceOrientationNonFlat": "\(nonFlat)"}}
                """.utf8))
            return (reading.physical, reading.displayAngle)
        }
        #expect(try reading("unknown", "portrait") == (.portrait, 0))
        // A device turned counterclockwise is shown turned counterclockwise.
        #expect(try reading("landscapeLeft", "landscapeLeft") == (.landscapeLeft, 90))
        #expect(try reading("landscapeRight", "landscapeRight") == (.landscapeRight, -90))
        #expect(try reading("faceUp", "landscapeLeft") == (.faceUp, 90))
        #expect(throws: HostError.self) { try reading("faceDown", "faceDown") }
    }

    @Test func orientationCommandsAreShownWithDisplayRotation() throws {
        _ = NSApplication.shared
        let menus = MenuController(application: nil)
        menus.install()
        defer { NSApp.mainMenu = nil }
        let controller = try makeController(TestDisplay())
        defer { controller.invalidate() }
        let device = try #require(NSApp.mainMenu?.items.first { $0.title == "Device" }?.submenu)
        menus.updateVisibility(in: device, for: controller.session.capabilities)
        let orientation = try #require(device.items.first { $0.title == "Orientation" })
        #expect(!orientation.isHidden)
        #expect(orientation.submenu?.items.map { $0.isSeparatorItem ? "-" : $0.title } == [
            "Portrait", "Landscape Right", "Portrait Upside Down", "Landscape Left", "-", "Face Up", "Face Down",
        ])
    }

    @Test func theWindowFollowsGuestRotationWhenEnabled() throws {
        let display = TestDisplay()
        let controller = try makeController(display)
        defer { controller.invalidate() }
        let key = HostPreferences.rotateWindowWhenSignaledByGuest
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        let window = try #require(controller.window)
        func isLandscape() -> Bool { window.contentLayoutRect.width > window.contentLayoutRect.height }
        UserDefaults.standard.set(false, forKey: key)
        display.guestInterfaceAngle = 90
        display.naturalSize = NSSize(width: 844, height: 390)
        display.onPropertiesChange?()
        #expect(!isLandscape())
        #expect(display.rotations.isEmpty)
        controller.perform(.rotateDeviceAutomatically)
        #expect(UserDefaults.standard.bool(forKey: key))
        display.onPropertiesChange?()
        #expect(isLandscape())
        #expect(display.rotations == [90])
        // Other property changes, after a resize or a bezel change, keep the window size.
        window.setContentSize(NSSize(width: 600, height: 400))
        controller.toggleDeviceBezel()
        let chosen = window.frame.size
        display.onPropertiesChange?()
        #expect(window.frame.size == chosen)
        #expect(display.rotations == [90])
    }

    @Test func resumingGuestFollowAppliesTheNextGuestRotation() throws {
        let display = TestDisplay()
        // Small enough to fit the screen at Point Accurate in either orientation.
        display.naturalSize = NSSize(width: 200, height: 400)
        let controller = try makeController(display)
        defer { controller.invalidate() }
        let key = HostPreferences.rotateWindowWhenSignaledByGuest
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        let window = try #require(controller.window)
        func isLandscape() -> Bool { window.contentLayoutRect.width > window.contentLayoutRect.height }
        let portrait = display.naturalSize
        let landscape = NSSize(width: portrait.height, height: portrait.width)
        UserDefaults.standard.set(true, forKey: key)
        display.guestInterfaceAngle = 0
        display.onPropertiesChange?()
        #expect(display.rotations == [0])
        // With following off, the guest and the window turn to landscape.
        controller.perform(.rotateDeviceAutomatically)
        display.guestInterfaceAngle = 90
        display.naturalSize = landscape
        display.onPropertiesChange?()
        controller.setScale(.pointAccurate)
        #expect(isLandscape())
        // After following resumes, the guest's return to portrait is applied.
        controller.perform(.rotateDeviceAutomatically)
        display.guestInterfaceAngle = 0
        display.naturalSize = portrait
        display.onPropertiesChange?()
        #expect(display.rotations == [0, 0])
        #expect(!isLandscape())
    }

    @Test func windowScaleCommandsFollowSimulatorOrderAndShortcuts() throws {
        _ = NSApplication.shared
        let menus = MenuController(application: nil)
        menus.install()
        defer { NSApp.mainMenu = nil }
        let items = try #require(NSApp.mainMenu?.items.first { $0.title == "Window" }?.submenu).items
        let first = try #require(items.firstIndex { $0.title == "Physical Size" })
        #expect(items[first - 2].title == "Stay On Top" && items[first - 1].isSeparatorItem)
        let scales = items[first..<first + 4]
        #expect(scales.map(\.title) == ["Physical Size", "Point Accurate", "Pixel Accurate", "Fit Screen"])
        #expect(scales.map(\.keyEquivalent) == ["1", "2", "3", "4"])
        #expect(scales.allSatisfy { $0.keyEquivalentModifierMask == .command })
        #expect(items[first + 4].isSeparatorItem)
    }

    @Test func fixedScalesSetTheDisplayScaleAndCheckOnlyTheMatchingCommand() throws {
        let display = TestDisplay()
        display.naturalSize = NSSize(width: 160, height: 320)
        let controller = try makeController(display)
        defer { controller.invalidate() }
        controller.showWindow(nil)
        let window = try #require(controller.window)
        let backing = window.screen?.backingScaleFactor ?? 1
        display.screenScale = 1.5 * backing
        func checked() -> [DeviceCommand.ID] {
            [.physicalSize, .pointAccurate, .pixelAccurate, .fitScreen].filter {
                DeviceCommand.command($0).state?(controller) == .on
            }
        }
        // The window takes the display's size at the scale, 12 points below its header.
        func fitsDisplay() -> Bool {
            display.view.frame.size == display.size(for: display.renderScale)
                && window.contentLayoutRect.height - 12 == display.view.frame.height
        }
        controller.perform(.pointAccurate)
        #expect(display.renderScale == 1)
        #expect(checked() == [.pointAccurate])
        #expect(fitsDisplay())
        controller.perform(.pixelAccurate)
        #expect(display.renderScale == 1.5)
        #expect(checked() == [.pixelAccurate])
        #expect(fitsDisplay())
        // A manual size checks a fixed scale only when it matches.
        window.setContentSize(NSSize(width: 360, height: 500))
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        #expect(display.renderScale != 1 && display.renderScale != 1.5)
        #expect(checked().isEmpty)
        // A screen with another resolution changes the checkmark, not the scale.
        controller.perform(.pixelAccurate)
        display.screenScale = 1.25 * backing
        #expect(display.renderScale == 1.5)
        #expect(checked().isEmpty)
    }

    @Test func fitScreenFillsTheScreenAndCentersTheWindow() throws {
        let display = TestDisplay()
        display.naturalSize = NSSize(width: 200, height: 400)
        let controller = try makeController(display)
        defer { controller.invalidate() }
        controller.showWindow(nil)
        let window = try #require(controller.window)
        let visible = try #require((window.screen ?? NSScreen.main)?.visibleFrame)
        let above = window.frame.height - window.contentLayoutRect.height + 12
        controller.perform(.fitScreen)
        // Unlike NeoSimulator's earlier Fit Screen, the scale can exceed 1.
        let expected = min((visible.width - 20) / 200, (visible.height - above - 20) / 400)
        #expect(abs(display.renderScale - expected) < 0.000_001)
        #expect(abs(window.frame.midX - visible.midX) < 1 && abs(window.frame.midY - visible.midY) < 1)
        #expect(visible.contains(window.frame))
        #expect(DeviceCommand.command(.fitScreen).state == nil)
    }

    @Test func scaleCommandsAreValidatedAsInSimulator() throws {
        let display = TestDisplay()
        display.naturalSize = NSSize(width: 200, height: 400)
        // Every fixed scale is 1, which fits a small screen at any resolution:
        // the device is as dense as the screen the window opens on.
        let screen = try #require(NSScreen.screens.first)
        let density = WindowScale.usable(WindowScale.density(of: screen)) ?? WindowScale.defaultHostDensity
        let controller = try makeController(display, screenPointsPerInch: Double(density))
        defer { controller.invalidate() }
        controller.showWindow(nil)
        let window = try #require(controller.window)
        try #require(window.screen == screen)
        let backing = screen.backingScaleFactor
        display.screenScale = backing
        #expect(controller.scale(for: .physicalSize) == 1 && controller.scale(for: .pixelAccurate) == 1)
        func enabled() -> [DeviceCommand.ID] {
            [.physicalSize, .pointAccurate, .pixelAccurate, .fitScreen].filter {
                DeviceCommand.command($0).isEnabled(controller)
            }
        }
        #expect(enabled() == [.physicalSize, .pointAccurate, .pixelAccurate, .fitScreen])
        // Not in full screen, nor while entering or leaving it.
        controller.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification))
        #expect(enabled().isEmpty)
        controller.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification))
        #expect(enabled().count == 4)
        // Physical Size is only for the device's own screen.
        display.displayClass = 1
        #expect(enabled() == [.pointAccurate, .pixelAccurate, .fitScreen])
        display.displayClass = 0
        // A fixed scale below an iPhone's minimum of 0.4 is unavailable.
        display.screenScale = 0.39 * backing
        #expect(!enabled().contains(.pixelAccurate))
        display.screenScale = 0.41 * backing
        #expect(enabled().contains(.pixelAccurate))
        // A fixed scale must fit the screen below the window's header.
        let visible = try #require(window.screen?.visibleFrame)
        let above = window.frame.height - window.contentLayoutRect.height + 12
        display.naturalSize = NSSize(width: 200, height: visible.height - above)
        #expect(enabled().contains(.pointAccurate))
        display.naturalSize = NSSize(width: 200, height: visible.height - above + 1)
        #expect(!enabled().contains(.pointAccurate))
        display.naturalSize = NSSize(width: visible.width + 1, height: 200)
        #expect(!enabled().contains(.pointAccurate))
        #expect(enabled().contains(.fitScreen))
        controller.session.disconnect()
        #expect(enabled().isEmpty)
    }

    @Test func closingSavesTheScaleForTheDevicesNextWindow() throws {
        let preferences = MemoryPreferences()
        preferences.values[HostPreferences.devicePreferences] = ["test-device": [
            "ChromeTint": "#FFFFFF", "SimulatorWindowGeometry": ["WindowCenter": "{10, 20}"],
        ]]
        func open() throws -> (DeviceWindowController, TestDisplay) {
            let display = TestDisplay()
            display.naturalSize = NSSize(width: 160, height: 320)
            return (try makeController(display, preferences: preferences), display)
        }
        let (first, display) = try open()
        // Without a saved scale, a window opens at Point Accurate when that fits.
        #expect(display.renderScale == 1)
        display.screenScale = 1.5 * (first.window?.screen?.backingScaleFactor ?? 1)
        first.perform(.pixelAccurate)
        let frame = try #require(first.window?.frame)
        first.invalidate()
        let device = (preferences.values[HostPreferences.devicePreferences] as? [String: Any])?["test-device"]
            as? [String: Any]
        #expect(device?["ChromeTint"] as? String == "#FFFFFF")
        let geometry = device?["SimulatorWindowGeometry"] as? [String: Any]
        #expect(geometry?["WindowScale"] as? Double == 1.5)
        #expect(geometry?["WindowCenter"] as? String == NSStringFromPoint(NSPoint(x: frame.midX, y: frame.midY)))
        let (second, reopened) = try open()
        #expect(reopened.renderScale == 1.5)
        second.invalidate()
        // A saved scale that does not fit the screen is reduced to fit it.
        preferences.setWindowGeometry(center: NSPoint(x: frame.midX, y: frame.midY), scale: 100, forDevice: "test-device")
        let (third, reduced) = try open()
        defer { third.invalidate() }
        #expect(reduced.renderScale < 100)
        #expect(reduced.renderScale == third.scale(for: .fitScreen))
    }

    @Test func aDevicesWindowReopensWhereItClosedOrCascades() throws {
        let preferences = MemoryPreferences()
        func open(_ device: String) throws -> DeviceWindowController {
            let display = TestDisplay()
            display.naturalSize = NSSize(width: 160, height: 320)
            return try makeController(display, device: device, preferences: preferences)
        }
        // Without a saved center, the first window takes the center of the
        // screen, and the next cascades from it.
        var cascade = NSPoint.zero
        let first = try open("A")
        first.showNewWindow(cascadingFrom: &cascade)
        let firstWindow = try #require(first.window)
        let visible = try #require((firstWindow.screen ?? NSScreen.main)?.visibleFrame)
        #expect(abs(firstWindow.frame.midX - visible.midX) < 1)
        #expect(cascade != .zero)
        let start = cascade
        let second = try open("B")
        defer { second.invalidate() }
        second.showNewWindow(cascadingFrom: &cascade)
        let secondWindow = try #require(second.window)
        #expect(NSPoint(x: secondWindow.frame.minX, y: secondWindow.frame.maxY) == start)
        #expect(cascade != start)
        // A device's next window opens centered where its last one closed,
        // without moving the cascade.
        firstWindow.setFrameOrigin(NSPoint(x: visible.minX + 30, y: visible.minY + 40))
        let closed = firstWindow.frame
        first.invalidate()
        let reopened = try open("A")
        defer { reopened.invalidate() }
        let afterSecond = cascade
        reopened.showNewWindow(cascadingFrom: &cascade)
        let reopenedWindow = try #require(reopened.window)
        #expect(reopenedWindow.frame == closed)
        #expect(cascade == afterSecond)
        // A window whose saved center leaves it across the edge of the screen
        // moves back inside the screen.
        preferences.setWindowGeometry(center: NSPoint(x: visible.maxX - 10, y: visible.midY), scale: nil,
                                      forDevice: "C")
        let moved = try open("C")
        defer { moved.invalidate() }
        moved.showNewWindow(cascadingFrom: &cascade)
        let movedWindow = try #require(moved.window)
        let screen = try #require((movedWindow.screen ?? NSScreen.main)?.visibleFrame)
        #expect(screen.contains(movedWindow.frame))
        #expect(cascade == afterSecond)
    }

    @Test func restartsAndRotationsKeepTheWindowScale() async throws {
        let key = HostPreferences.rotateWindowWhenSignaledByGuest
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.set(true, forKey: key)
        let first = TestDisplay()
        first.naturalSize = NSSize(width: 160, height: 320)
        let controller = try makeController(first)
        defer { controller.invalidate() }
        let window = try #require(controller.window)
        first.screenScale = 1.5 * (window.screen?.backingScaleFactor ?? 1)
        controller.perform(.pixelAccurate)
        await controller.prepareForRestart()
        let second = TestDisplay()
        second.naturalSize = first.naturalSize
        controller.reconnect(try makeSession(second))
        #expect(second.renderScale == 1.5)
        second.guestInterfaceAngle = 90
        second.naturalSize = NSSize(width: 320, height: 160)
        second.onPropertiesChange?()
        #expect(second.rotations == [90])
        #expect(second.renderScale == 1.5)
        #expect(second.view.frame.size == NSSize(width: 480, height: 240))
        #expect(window.contentLayoutRect.width == 480)
    }

    @Test func rotationsBezelsAndRestartsKeepAScaleWiderThanTheScreen() async throws {
        let key = HostPreferences.rotateWindowWhenSignaledByGuest
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.set(true, forKey: key)
        let first = TestDisplay()
        first.naturalSize = NSSize(width: 200, height: 300)
        let controller = try makeController(first)
        defer { controller.invalidate() }
        controller.showWindow(nil)
        let window = try #require(controller.window)
        let visible = try #require(window.screen?.visibleFrame)
        controller.perform(.pointAccurate)
        let top = window.frame.maxY
        // Turned to landscape, the display is wider than the screen; like
        // Simulator.app, it keeps its scale below the window's top edge.
        let landscape = NSSize(width: visible.width + 100, height: 200)
        first.guestInterfaceAngle = 90
        first.naturalSize = landscape
        first.onPropertiesChange?()
        #expect(first.renderScale == 1)
        #expect(window.frame.width > visible.width)
        #expect(window.frame.maxY == top.rounded())
        // Showing a bezel keeps it too.
        first.bezel = NSSize(width: 40, height: 40)
        controller.toggleDeviceBezel()
        controller.toggleDeviceBezel()
        #expect(first.renderScale == 1)
        // So does a restart.
        await controller.prepareForRestart()
        let second = TestDisplay()
        second.naturalSize = landscape
        controller.reconnect(try makeSession(second))
        #expect(second.renderScale == 1)
        #expect(window.frame.width > visible.width)
    }

    @Test func aWindowWithABezelMayExtendPastTheScreen() throws {
        let display = TestDisplay()
        display.naturalSize = NSSize(width: 200, height: 300)
        display.bezel = NSSize(width: 20, height: 20)
        // An iPhone 17 Pro's bezel has no top padding.
        display.bezelPadding = NSSize(width: 9, height: 0)
        let controller = try makeController(display)
        defer { controller.invalidate() }
        controller.showWindow(nil)
        let window = try #require(controller.window)
        let visible = try #require(window.screen?.visibleFrame)
        // Like Simulator.app, a window with a bezel is not resizable, and
        // full screen stays available.
        #expect(!window.styleMask.contains(.resizable))
        #expect(window.collectionBehavior.contains(.fullScreenPrimary))
        // A fixed scale may make the window taller than the screen.
        display.naturalSize = NSSize(width: 200, height: visible.height)
        #expect(controller.canSetScale(.pointAccurate))
        controller.perform(.pointAccurate)
        #expect(display.renderScale == 1)
        #expect(display.view.frame.height == visible.height + 20)
        #expect(window.frame.height > visible.height)
        // Without top padding, AppKit keeps the top of the window on the screen.
        #expect(window.frame.maxY <= visible.maxY + 1)
        // Without the bezel, the window is resizable and the scale must fit.
        controller.perform(.showDeviceBezels)
        #expect(window.styleMask.contains(.resizable))
        #expect(!controller.canSetScale(.pointAccurate))
        #expect(controller.canSetScale(.fitScreen))
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
        // The window takes the display's size, 12 points below its header.
        func showsDisplay(_ size: NSSize) -> Bool {
            display.view.frame.size == size
                && window.contentLayoutRect.size == NSSize(width: size.width, height: size.height + 12)
        }
        controller.perform(.pointAccurate)
        #expect(showsDisplay(NSSize(width: 400, height: 460)))
        let origin = window.frame.origin
        // Hiding the bezel keeps the scale and the window's bottom-left
        // corner, as Simulator.app does, and shrinks the window.
        controller.perform(.showDeviceBezels)
        #expect(!controller.showsDeviceBezel)
        #expect(display.renderScale == 1)
        #expect(DeviceCommand.command(.pointAccurate).state?(controller) == .on)
        #expect(showsDisplay(NSSize(width: 360, height: 400)))
        #expect(window.frame.origin == origin)
        #expect(window.styleMask.contains(.resizable))
        // Showing it keeps a scale chosen without the bezel and grows the window.
        controller.perform(.pointAccurate)
        controller.perform(.showDeviceBezels)
        #expect(controller.showsDeviceBezel)
        #expect(display.renderScale == 1)
        #expect(showsDisplay(NSSize(width: 400, height: 460)))
        #expect(window.frame.origin == origin)
        #expect(!window.styleMask.contains(.resizable))
    }

    @Test func orientationCommandsSetTheDeviceAndKeepManualRotation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // A devicectl stand-in that remembers the orientation it was set to.
        let state = directory.appendingPathComponent("orientation")
        try "portrait".write(to: state, atomically: true, encoding: .utf8)
        let devicectl = directory.appendingPathComponent("devicectl")
        try """
            #!/bin/sh
            case "$3" in
            set) printf %s "$6" > "\(state.path)" ;;
            get) o=$(cat "\(state.path)")
                 printf '{"result":{"deviceOrientation":"%s","deviceOrientationNonFlat":"%s"}}' "$o" "$o" ;;
            esac
            """.write(to: devicectl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: devicectl.path)
        let display = TestDisplay()
        let controller = try makeController(display, devicectl: devicectl)
        defer { controller.invalidate() }
        let session = controller.session
        let key = HostPreferences.rotateWindowWhenSignaledByGuest
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.set(true, forKey: key)
        display.guestInterfaceAngle = 0
        try await session.readOrientation()
        #expect(session.orientation == .portrait)
        // The guest stays in portrait, as a portrait-only app does.
        controller.perform(.landscapeLeft)
        for _ in 0..<300 where session.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        #expect(session.orientation == .landscapeLeft)
        #expect(display.rotations == [0, 90])
        display.onPropertiesChange?()
        #expect(display.rotations == [0, 90])
    }

    @Test func restartRunsSimulatorAppStagesAndReportsTheFailedStage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // A simctl stand-in that logs each subcommand and fails the one named in `fail`.
        let log = directory.appendingPathComponent("calls"), fail = directory.appendingPathComponent("fail")
        let simctl = directory.appendingPathComponent("simctl")
        try """
            #!/bin/sh
            echo "$1" >> "\(log.path)"
            [ "$1" = "$(cat "\(fail.path)" 2>/dev/null)" ] && { echo "$1 failed" >&2; exit 1; }
            exit 0
            """.write(to: simctl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: simctl.path)
        let tools = try DeviceTools(identifier: "test-device", xcodeURL: URL(fileURLWithPath: "/Applications/Xcode.app"),
                                    simctl: simctl)
        func run(erasing: Bool, failing stage: String) async -> (calls: [String], error: String?) {
            try? FileManager.default.removeItem(at: log)
            try? stage.write(to: fail, atomically: true, encoding: .utf8)
            var message: String?
            do { try await tools.restart(erasing: erasing) } catch { message = error.localizedDescription }
            let calls = (try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
            return (calls, message)
        }
        #expect(await run(erasing: false, failing: "").calls == ["shutdown", "boot"])
        #expect(await run(erasing: true, failing: "").calls == ["shutdown", "erase", "boot"])
        let shutdown = await run(erasing: true, failing: "shutdown")
        #expect(shutdown.calls == ["shutdown"])
        #expect(shutdown.error?.hasPrefix("Erase All Content and Settings failed while shutting down") == true)
        // A failed erase still boots the device.
        let erase = await run(erasing: true, failing: "erase")
        #expect(erase.calls == ["shutdown", "erase", "boot"])
        #expect(erase.error?.contains("while erasing") == true)
        #expect(erase.error?.hasSuffix("The device was shut down and booted again.") == true)
        let boot = await run(erasing: false, failing: "boot")
        #expect(boot.calls == ["shutdown", "boot"])
        #expect(boot.error?.hasPrefix("Restart failed while booting") == true)
        #expect(boot.error?.hasSuffix("The device was shut down.") == true)
    }

    @Test func aRestartKeepsTheWindowAndReconnectsItsNewSession() async throws {
        let first = TestDisplay()
        let controller = try makeController(first)
        defer { controller.invalidate() }
        let window = try #require(controller.window)
        let title = window.subtitle
        await controller.prepareForRestart()
        #expect(!controller.session.canPerformCommands)
        #expect(window.subtitle == "Restarting…")
        let second = TestDisplay()
        let session = try makeSession(second)
        controller.reconnect(session)
        #expect(controller.session === session)
        #expect(controller.window === window && window.subtitle == title)
        #expect(second.view.window === window && first.view.window == nil)
        controller.perform(.home)
        #expect(second.events.map(\.input) == [.button(.home), .button(.home)])
        #expect(first.events.isEmpty)
    }

    @Test func aRestartFinishesTheRecordingBeforeDisconnecting() async throws {
        let display = TestDisplay()
        var recorder: Process?
        let controller = try makeController(display, recordingProcess: { _, _ in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", """
                trap 'sleep 0.2; exit 0' INT
                echo 'Recording started' >&2
                while :; do sleep 0.05; done
                """]
            recorder = process
            return process
        })
        defer { controller.invalidate() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try controller.session.startRecording(to: .file(directory.appendingPathComponent("Recording.mov")), mask: .ignored)
        // Wait for the first-frame acknowledgement, the safe point for SIGINT.
        try await Task.sleep(for: .milliseconds(300))
        var recordingAtDisconnect: Bool?
        display.onDisconnect = { recordingAtDisconnect = recorder?.isRunning }
        await controller.prepareForRestart()
        #expect(recordingAtDisconnect == false)
    }

    @Test func eraseAsksForConfirmationBeforeRestarting() async throws {
        var requests: [Bool] = []
        let controller = try makeController(TestDisplay(), onRestart: { _, erasing in requests.append(erasing) })
        defer { controller.invalidate() }
        controller.showWindow(nil)
        let window = try #require(controller.window)
        controller.perform(.eraseAllContentAndSettings)
        window.endSheet(try #require(window.attachedSheet), returnCode: .alertSecondButtonReturn)
        #expect(requests.isEmpty)
        controller.perform(.eraseAllContentAndSettings)
        window.endSheet(try #require(window.attachedSheet), returnCode: .alertFirstButtonReturn)
        #expect(requests == [true])
        controller.perform(.restart)
        #expect(requests == [true, false])
    }

    @Test func guestInterfaceOrientationsUseSimulatorKitAngles() {
        #expect([1, 2, 3, 4, 0].map(SimScreenUIOrientation.displayAngle) == [0, 180, -90, 90, 0])
    }

    @Test func hardwareCommandsFollowDeviceFeatures() throws {
        _ = NSApplication.shared
        let menus = MenuController(application: nil)
        menus.install()
        defer { NSApp.mainMenu = nil }
        let features: Set<String> = [
            DeviceCapabilities.actionButtonStaccato, DeviceCapabilities.siri,
            DeviceCapabilities.routableAudio, DeviceCapabilities.applePayAuthorization,
        ]
        let controller = try makeController(TestDisplay(), features: features)
        defer { controller.invalidate() }
        func visibleTitles(_ title: String) throws -> [String] {
            let menu = try #require(NSApp.mainMenu?.items.first { $0.title == title }?.submenu)
            menus.updateVisibility(in: menu, for: controller.session.capabilities)
            return menu.items.filter { !$0.isHidden }.map { $0.isSeparatorItem ? "-" : $0.title }
        }
        // File ▸ Open Simulator is built when it opens, so its empty submenu stays visible.
        #expect(try visibleTitles("File").prefix(3) == ["New Simulator…", "Open Simulator", "-"])
        #expect(try visibleTitles("Device") == ["Restart", "Erase All Content and Settings…", "Shut Down", "-",
                                                 "Home", "Lock", "Action Button", "Siri", "Shake",
                                                 "App Switcher", "-", "Trigger Screenshot"])
        #expect(try visibleTitles("I/O") == ["Keyboard", "-", "Increase Volume", "Decrease Volume", "-", "Open URL…"])
        #expect(try visibleTitles("Features") == ["Authorize Apple Pay", "-", "Toggle Appearance",
                                                   "Toggle In-call Status Bar", "-", "Increase Preferred Text Size",
                                                   "Decrease Preferred Text Size", "Toggle Increase Contrast", "-",
                                                   "Trigger iCloud Sync", "-", "Location"])
        #expect(try visibleTitles("Debug") == ["Show Parallel Testing Devices"])
        // Option and Control alternates ask before quitting, capturing, and closing.
        let alternates = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items).filter(\.isAlternate)
        #expect(alternates?.map(\.title) == ["Quit NeoSimulator…", "Save Screen…", "Record Screen…", "Close Window…"])
        #expect(alternates?.map(\.keyEquivalentModifierMask) == [[.command, .option], [.command, .option],
                                                                  [.command, .option], [.command, .control]])
    }

    @Test func biometricShortcutsGoToTheKeyDevicesBiometrics() throws {
        _ = NSApplication.shared
        let menus = MenuController(application: nil)
        menus.install()
        defer { NSApp.mainMenu = nil }
        let features = try #require(NSApp.mainMenu?.items.first { $0.title == "Features" }?.submenu)
        func shortcuts(_ submenu: String) throws -> [String] {
            try #require(features.items.first { $0.title == submenu }?.submenu).items.map(\.keyEquivalent)
        }
        func device(_ feature: String) -> DeviceCapabilities {
            DeviceCapabilities(family: .iPhone, runtimeVersion: 0x1B_00_00, supportsFeature: { $0 == feature })
        }
        #expect(try shortcuts("Touch ID") == ["", "m", "n"] && shortcuts("Face ID") == ["", "", ""])
        menus.updateKeyEquivalents(for: device(DeviceCapabilities.faceID))
        #expect(try shortcuts("Touch ID") == ["", "", ""] && shortcuts("Face ID") == ["", "m", "n"])
        menus.updateVisibility(in: features, for: device(DeviceCapabilities.faceID))
        #expect(features.items.filter { !$0.isHidden }.prefix(2).map { $0.isSeparatorItem ? "-" : $0.title }
                == ["Face ID", "-"])
        menus.updateKeyEquivalents(for: device(DeviceCapabilities.touchID))
        #expect(try shortcuts("Touch ID") == ["", "m", "n"] && shortcuts("Face ID") == ["", "", ""])
        // Shift-Command-I belongs to Trigger iCloud Sync, as in Simulator.app.
        let items = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items) ?? []
        #expect(items.filter { $0.keyEquivalent == "i" && $0.keyEquivalentModifierMask == [.command, .shift] }
            .map(\.title) == ["Trigger iCloud Sync"])
    }

    @Test func featureCommandsChangeTheGuestState() throws {
        let display = TestDisplay()
        let controller = try makeController(display, features: [DeviceCapabilities.faceID, DeviceCapabilities.standBy])
        defer { controller.invalidate() }
        let session = controller.session
        controller.perform(.faceIDEnrolled)
        #expect(session.isBiometricEnrolled)
        controller.perform(.faceIDMatching)
        controller.perform(.faceIDNonMatching)
        // A device without Touch ID ignores its commands.
        controller.perform(.touchIDMatching)
        controller.perform(.faceIDEnrolled)
        #expect(!session.isBiometricEnrolled)
        controller.perform(.toggleStandBy)
        #expect(DeviceCommand.command(.toggleStandBy).stateTitle?(controller) == "Hide StandBy")
        controller.perform(.toggleInCallStatusBar)
        controller.perform(.shake)
        #expect(display.postedNotifications == [
            "com.apple.BiometricKit.enrollmentChanged", "com.apple.BiometricKit_Sim.pearl.match",
            "com.apple.BiometricKit_Sim.pearl.nomatch", "com.apple.BiometricKit.enrollmentChanged",
            "com.apple.springboard.ambient.presentation", "com.apple.iphonesimulator.toggleincallstatusbar",
            "com.apple.UIKit.SimulatorShake",
        ])

        // Text size stops at the largest size; an unknown size is an error.
        display.contentSize = 11
        try session.changeTextSize(by: 1)
        try session.changeTextSize(by: 1)
        #expect(display.contentSize == 12)
        try session.changeTextSize(by: -1)
        #expect(display.contentSize == 11)
        display.contentSize = 0
        #expect(throws: (any Error).self) { try session.changeTextSize(by: -1) }
        #expect(display.contentSize == 0)

        try session.toggleIncreaseContrast()
        #expect(display.contrastMode == 2)
        try session.toggleIncreaseContrast()
        #expect(display.contrastMode == 1)
        // Toggling from an unknown mode would guess; it reports the failure instead.
        display.contrastMode = 0
        #expect(throws: (any Error).self) { try session.toggleIncreaseContrast() }
        #expect(display.contrastMode == 0)
    }

    @Test func connectingRestoresTheSavedLocationOnDevicesWithScenarios() async throws {
        let restoreDefaults = removeLocationPreferences()
        defer { restoreDefaults() }
        HostPreferences.registerDefaults()
        let defaults = UserDefaults.standard
        // Without scenarios nothing is restored, applied, or saved.
        let bare = TestDisplay()
        let bareSession = try makeSession(bare)
        try await bareSession.restoreLocation()
        #expect(bareSession.location == nil && bare.appliedLocations.isEmpty)
        #expect(defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[HostPreferences.locationMode] == nil)

        func restore() async throws -> (LocationSelection?, [AppliedLocation]) {
            let display = TestDisplay()
            display.scenarios = Self.scenarios
            let session = try makeSession(display)
            try await session.restoreLocation()
            #expect(session.locationScenarios == Self.scenarios)
            return (session.location, display.appliedLocations)
        }
        // A fresh install applies the registered coordinate.
        #expect(try await restore() == (.custom, [.coordinate(37.785834, -122.406417)]))
        defaults.set(LocationSelection.scenarioMode, forKey: HostPreferences.locationMode)
        defaults.set("Freeway Drive", forKey: HostPreferences.locationScenario)
        #expect(try await restore() == (.scenario("Freeway Drive"), [.scenario("Freeway Drive")]))
        // A scenario the runtime lacks falls back to None, keeping its name.
        defaults.set("Apple", forKey: HostPreferences.locationScenario)
        #expect(try await restore() == (LocationSelection.none, [.cleared]))
        #expect(defaults.integer(forKey: HostPreferences.locationMode) == LocationSelection.noneMode)
        #expect(defaults.string(forKey: HostPreferences.locationScenario) == "Apple")
        // Modes up to Custom's other than None and Custom are None.
        defaults.set(5000, forKey: HostPreferences.locationMode)
        #expect(try await restore() == (LocationSelection.none, [.cleared]))
    }

    @Test func aRestoreWaitingForScenariosKeepsLaterChoicesAndEndedSessions() async throws {
        let restoreDefaults = removeLocationPreferences()
        defer { restoreDefaults() }
        HostPreferences.registerDefaults()
        // Right after a boot the device lists its scenarios late. A choice
        // made meanwhile stays, and the scenarios are still listed.
        let display = TestDisplay()
        display.scenarios = Self.scenarios
        display.holdsScenarios = true
        let controller = try makeController(display)
        defer { controller.invalidate() }
        let restore = Task.immediate { try await controller.session.restoreLocation() }
        controller.selectLocation(.none)
        display.releaseScenarios()
        try await restore.value
        #expect(controller.session.location == LocationSelection.none && display.appliedLocations == [.cleared])
        #expect(controller.session.locationScenarios == Self.scenarios)

        // A session that ends meanwhile gets no scenarios and no location.
        let ended = TestDisplay()
        ended.scenarios = Self.scenarios
        ended.holdsScenarios = true
        let session = try makeSession(ended)
        let endedRestore = Task.immediate { try await session.restoreLocation() }
        session.disconnect()
        ended.releaseScenarios()
        try await endedRestore.value
        #expect(session.locationScenarios.isEmpty && session.location == nil && ended.appliedLocations.isEmpty)
    }

    @Test func locationMenuShowsTheKeyDevicesScenariosAndChoice() async throws {
        _ = NSApplication.shared
        let restoreDefaults = removeLocationPreferences()
        defer { restoreDefaults() }
        let menus = MenuController(application: nil)
        menus.install()
        defer { NSApp.mainMenu = nil }
        let features = try #require(NSApp.mainMenu?.items.first { $0.title == "Features" }?.submenu)
        let menu = try #require(features.items.last?.submenu)
        let location = try #require(menu.delegate as? LocationMenu)
        func items(for controller: DeviceWindowController?) -> [String] {
            location.update(menu, for: controller)
            return menu.items.map { "\($0.title)\($0.state == .on ? " ✓" : "")\($0.isEnabled ? "" : " (disabled)")" }
        }
        #expect(items(for: nil) == ["None (disabled)", "Custom Location… (disabled)"])

        HostPreferences.registerDefaults()
        let display = TestDisplay()
        display.scenarios = Self.scenarios
        let controller = try makeController(display)
        defer { controller.invalidate() }
        try await controller.session.restoreLocation()
        #expect(items(for: controller) == ["None", "Custom Location… ✓", "City Run", "Freeway Drive"])
        controller.selectLocation(.scenario("City Run"))
        #expect(items(for: controller) == ["None", "Custom Location…", "City Run ✓", "Freeway Drive"])
        #expect(display.appliedLocations == [.coordinate(37.785834, -122.406417), .scenario("City Run")])
        #expect(UserDefaults.standard.string(forKey: HostPreferences.locationScenario) == "City Run")
        #expect(UserDefaults.standard.integer(forKey: HostPreferences.locationMode) > LocationSelection.customMode)

        // Another device lists its own runtime's scenarios and keeps its own
        // choice. Its connection restores the choice saved last.
        let other = TestDisplay()
        other.scenarios = [LocationScenario(name: "City Run", localizedName: "Course à pied")]
        let otherController = try makeController(other)
        defer { otherController.invalidate() }
        try await otherController.session.restoreLocation()
        #expect(items(for: otherController) == ["None", "Custom Location…", "Course à pied ✓"])
        otherController.selectLocation(.none)
        #expect(items(for: otherController) == ["None ✓", "Custom Location…", "Course à pied"])
        #expect(items(for: controller) == ["None", "Custom Location…", "City Run ✓", "Freeway Drive"])
        #expect(other.appliedLocations == [.scenario("City Run"), .cleared])
        #expect(display.appliedLocations.count == 2)

        display.isBooted = false
        #expect(items(for: controller) == ["None (disabled)", "Custom Location… (disabled)", "City Run ✓ (disabled)",
                                           "Freeway Drive (disabled)"])
        controller.selectLocation(.none)
        #expect(display.appliedLocations.count == 2)
    }

    @Test func aFailedLocationChoiceIsReportedAndKept() throws {
        let restoreDefaults = removeLocationPreferences()
        defer { restoreDefaults() }
        let display = TestDisplay()
        display.locationError = HostError.operation("location failed")
        let controller = try makeController(display)
        defer { controller.invalidate() }
        controller.showWindow(nil)
        let window = try #require(controller.window)
        controller.selectLocation(.none)
        #expect(try #require(window.attachedSheet).isVisible)
        // Like Simulator.app, the choice stays and is saved; choosing it again retries.
        #expect(controller.session.location == LocationSelection.none)
        #expect(UserDefaults.standard.integer(forKey: HostPreferences.locationMode) == LocationSelection.noneMode)
        window.endSheet(try #require(window.attachedSheet))
    }

    @Test func customLocationAcceptsOnlyCoordinatesThatParse() throws {
        _ = NSApplication.shared
        var accepted: [[Double]] = []
        let dialog = CustomLocationWindowController { accepted.append([$0, $1]) }
        defer { dialog.close() }
        let window = try #require(dialog.window)
        #expect(window.title == "Custom Location")
        #expect(window.styleMask == [.titled])
        let texts = window.contentView?.subviews.flatMap { [$0] + $0.subviews }.compactMap { ($0 as? NSTextField)?.stringValue }
        #expect(texts?.contains("Enter a latitude and longitude for the location you would like to simulate.") == true)
        #expect(texts.map { Set(["Latitude:", "Longitude:"]).isSubset(of: $0) } == true)
        let cancel = try #require(window.contentView?.subviews.compactMap { $0 as? NSButton }.first { $0.title == "Cancel" })
        #expect(cancel.keyEquivalent == "\u{1b}" && dialog.okButton.keyEquivalent == "\r")

        dialog.show(latitude: 37.785834, longitude: -122.406417)
        #expect(window.isVisible && dialog.okButton.isEnabled)
        #expect(dialog.latitudeField.doubleValue == 37.785834 && dialog.longitudeField.doubleValue == -122.406417)
        // Each change is checked as it is typed. Leaving a field that does
        // not parse would show AppKit's formatter error, so each field ends valid.
        func type(_ texts: [String], in field: NSTextField) throws -> [Bool] {
            #expect(window.makeFirstResponder(field))
            let editor = try #require(field.currentEditor() as? NSTextView)
            return texts.map { text in
                editor.selectAll(nil)
                editor.insertText(text, replacementRange: editor.selectedRange())
                // Checking leaves the text as typed.
                #expect(editor.string == text)
                return dialog.okButton.isEnabled
            }
        }
        #expect(try type(["91", "x", "", "-90"], in: dialog.latitudeField) == [false, false, false, true])
        #expect(try type(["-181", "180", "-180"], in: dialog.longitudeField) == [false, true, true])
        // OK reads the text still being edited.
        dialog.okButton.performClick(nil)
        #expect(accepted == [[-90, -180]] && !window.isVisible)

        // Showing again starts from the given coordinate; Cancel changes nothing.
        dialog.show(latitude: 1, longitude: 2)
        #expect(dialog.latitudeField.doubleValue == 1 && dialog.okButton.isEnabled)
        cancel.performClick(nil)
        #expect(accepted.count == 1 && !window.isVisible)
        // Showing also checks the coordinate it starts from.
        dialog.show(latitude: 100, longitude: 0)
        #expect(!dialog.okButton.isEnabled)
    }

    @Test func customLocationSavesAndAppliesTheCoordinateForItsDevice() throws {
        _ = NSApplication.shared
        let restoreDefaults = removeLocationPreferences()
        defer { restoreDefaults() }
        HostPreferences.registerDefaults()
        let display = TestDisplay()
        let controller = try makeController(display)
        controller.selectLocation(.custom)
        let window = try #require(NSApp.windows.first { $0.title == "Custom Location" && $0.isVisible })
        let dialog = try #require(window.windowController as? CustomLocationWindowController)
        #expect(dialog.latitudeField.doubleValue == 37.785834 && dialog.longitudeField.doubleValue == -122.406417)
        // Choosing Custom Location… only asks.
        #expect(controller.session.location == nil && display.appliedLocations.isEmpty)
        dialog.latitudeField.doubleValue = 10
        dialog.longitudeField.doubleValue = -20
        dialog.okButton.performClick(nil)
        #expect(!window.isVisible)
        #expect(controller.session.location == .custom && display.appliedLocations == [.coordinate(10, -20)])
        #expect(UserDefaults.standard.double(forKey: HostPreferences.locationLatitude) == 10)
        #expect(UserDefaults.standard.double(forKey: HostPreferences.locationLongitude) == -20)
        #expect(UserDefaults.standard.integer(forKey: HostPreferences.locationMode) == LocationSelection.customMode)
        // The window opens again with the saved coordinate, not with text
        // typed before Cancel.
        controller.selectLocation(.custom)
        #expect(window.isVisible && window.makeFirstResponder(dialog.latitudeField))
        let editor = try #require(dialog.latitudeField.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText("x", replacementRange: editor.selectedRange())
        #expect(!dialog.okButton.isEnabled)
        let cancel = try #require(window.contentView?.subviews.compactMap { $0 as? NSButton }.first { $0.title == "Cancel" })
        cancel.performClick(nil)
        #expect(!window.isVisible && display.appliedLocations.count == 1)
        controller.selectLocation(.custom)
        #expect(dialog.latitudeField.doubleValue == 10 && dialog.longitudeField.doubleValue == -20)
        #expect(dialog.okButton.isEnabled)
        // It keeps its device window's level, and closes with its device window.
        controller.toggleStayOnTop()
        #expect(window.level == .floating)
        controller.toggleStayOnTop()
        #expect(window.level == .normal)
        controller.invalidate()
        #expect(!window.isVisible)
    }

    private static let scenarios = [LocationScenario(name: "City Run", localizedName: "City Run"),
                                    LocationScenario(name: "Freeway Drive", localizedName: "Freeway Drive")]

    /// Removes the saved Location preferences and returns a closure that puts
    /// back the ones that were saved.
    private func removeLocationPreferences() -> () -> Void {
        let keys = [HostPreferences.locationMode, HostPreferences.locationScenario,
                    HostPreferences.locationLatitude, HostPreferences.locationLongitude]
        let saved = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        return { for key in keys { UserDefaults.standard.set(saved?[key], forKey: key) } }
    }

    @Test func orientationCommandsNeedTheDefaultDeviceSet() throws {
        _ = NSApplication.shared
        let menus = MenuController(application: nil)
        menus.install()
        defer { NSApp.mainMenu = nil }
        let device = try #require(NSApp.mainMenu?.items.first { $0.title == "Device" }?.submenu)
        func visibleTitles(controllingOrientation: Bool) -> [String] {
            menus.updateVisibility(in: device, for: DeviceCapabilities(
                family: .iPhone, runtimeVersion: 0x1B_00_00,
                supportsFeature: { $0 == DeviceCapabilities.displayRotation },
                controlsOrientation: controllingOrientation))
            return device.items.filter { !$0.isHidden && !$0.isSeparatorItem }.map(\.title)
        }
        let rotation = ["Rotate Left", "Rotate Right", "Orientation"]
        #expect(Set(rotation).isSubset(of: visibleTitles(controllingOrientation: true)))
        // devicectl cannot reach a parallel testing device, but SimulatorKit
        // still follows the guest's rotation.
        let testing = visibleTitles(controllingOrientation: false)
        #expect(Set(rotation).isDisjoint(with: testing) && testing.contains("Rotate Device Automatically"))
    }

    @Test func openSimulatorListsDevicesBySimulatorAppRules() throws {
        let devices = [
            availableDevice("a", "iPhone 17", runtime: "iOS 27.0", state: 3),
            availableDevice("b", "iPad", runtime: "iOS 27.0", state: 2),
            availableDevice("c", "iPhone 16", runtime: "iOS 26.5", state: 1),
        ]
        func items(_ devices: [AvailableDevice]) -> [NSMenuItem] {
            OpenSimulatorMenu.items(for: devices, hasWindow: { $0 == "a" }, action: #selector(NSText.copy(_:)),
                                    target: nil)
        }
        let runtimes = items(devices)
        #expect(runtimes.map(\.title) == ["iOS 27.0", "iOS 26.5"])
        #expect(runtimes.map(\.state) == [.mixed, .off])
        let first = try #require(runtimes[0].submenu?.items)
        #expect(first.map(\.title) == ["iPhone 17", "iOS 27.0 - iPhone 17", "iPad", "iOS 27.0 - iPad"])
        #expect(first.map(\.isAlternate) == [false, true, false, true])
        #expect(first.map(\.keyEquivalentModifierMask) == [[], .option, [], .option])
        #expect(first.map(\.state) == [.on, .on, .mixed, .mixed])
        #expect(first.map { $0.representedObject as? String } == ["a", "a", "b", "b"])
        // A single runtime lists its devices directly.
        #expect(items(Array(devices.prefix(2))).map(\.title) == first.map(\.title))
    }

    @Test func lifetimeAlertsUseSimulatorAppTextAndDefaults() throws {
        _ = NSApplication.shared
        let close = DeviceLifetimeChoice.alert(quitting: false, keepsRunningByDefault: false)
        #expect(close.messageText == "Do you want to shutdown the simulated device?")
        #expect(close.informativeText == "When closing a window, you can either shut down the device or keep it running.")
        #expect(close.buttons.map(\.title) == ["Shut down", "Keep Running", "Cancel"])
        #expect(close.suppressionButton?.title == "Remember as the default close action.")
        #expect(close.buttons.map(\.keyEquivalent) == ["\r", "", "\u{1b}"])
        let quit = DeviceLifetimeChoice.alert(quitting: true, keepsRunningByDefault: true)
        #expect(quit.messageText == "Do you want to shut down the simulated devices?")
        #expect(quit.buttons.map(\.title) == ["Shut Down", "Keep Running", "Cancel"])
        #expect(quit.suppressionButton?.title == "Remember as the default quit action.")
        // Return chooses the remembered action.
        #expect(quit.buttons.map(\.keyEquivalent) == ["", "\r", "\u{1b}"])

        let key = "NeoSimulatorTestDetach-\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        #expect(DeviceLifetimeChoice.choice(for: .alertThirdButtonReturn, of: quit, rememberingAs: key) == nil)
        #expect(DeviceLifetimeChoice.choice(for: .alertSecondButtonReturn, of: quit, rememberingAs: key) == .keepRunning)
        #expect(UserDefaults.standard.object(forKey: key) == nil)
        quit.suppressionButton?.state = .on
        #expect(DeviceLifetimeChoice.choice(for: .alertSecondButtonReturn, of: quit, rememberingAs: key) == .keepRunning)
        #expect(UserDefaults.standard.bool(forKey: key))
        #expect(DeviceLifetimeChoice.choice(for: .alertFirstButtonReturn, of: quit, rememberingAs: key) == .shutDown)
        #expect(!UserDefaults.standard.bool(forKey: key))
    }

    @Test func closeWindowAsksBeforeClosing() throws {
        _ = NSApplication.shared
        var closes: [DeviceLifetimeChoice?] = []
        let controller = try makeController(TestDisplay(), onClose: { _, choice in closes.append(choice) })
        defer { controller.invalidate() }
        controller.showWindow(nil)
        let window = try #require(controller.window)
        controller.closeAsking()
        window.endSheet(try #require(window.attachedSheet), returnCode: .alertThirdButtonReturn)
        #expect(window.isVisible && closes.isEmpty)
        controller.closeAsking()
        window.endSheet(try #require(window.attachedSheet), returnCode: .alertSecondButtonReturn)
        #expect(!window.isVisible && closes == [.keepRunning])
    }

    @Test func launchStartsTheLastDeviceOrSimulatorAppsFallback() {
        let devices = [
            availableDevice("A", "iPad A", runtime: "iOS 27.0", state: 1),
            availableDevice("B", "iPhone B", runtime: "iOS 27.0", state: 1),
            availableDevice("C", "iPod touch C", runtime: "iOS 27.0", state: 1),
            availableDevice("D", "iPhone D", runtime: "iOS 27.0", state: 1),
            availableDevice("E", "iPad E", runtime: "iOS 27.0", state: 1),
        ]
        let identifier = UUID().uuidString
        let current = AvailableDevice(identifier: identifier, name: "Mine", descriptiveName: "Mine", runtimeIdentifier: "",
                                      runtimeName: "", productFamily: 2, deviceTypeName: "iPad", state: 1)
        #expect(HostApplication.initialDevice(in: devices + [current], current: identifier.lowercased())?.id == identifier)
        // The last iPhone, matched by device type, or else the first device.
        #expect(HostApplication.initialDevice(in: devices, current: identifier)?.id == "D")
        #expect(HostApplication.initialDevice(in: [devices[0], devices[4]], current: nil)?.id == "A")
        #expect(HostApplication.initialDevice(in: [], current: nil) == nil)
    }

    @Test func newSimulatorKeepsDeviceTypeAndRuntimeCompatible() async throws {
        _ = NSApplication.shared
        let catalog = SimulatorCatalog(
            deviceTypes: [.init(identifier: "a", name: "iPhone A", productFamily: 1),
                          .init(identifier: "b", name: "iPhone B", productFamily: 1),
                          .init(identifier: "x", name: "iPhone X", productFamily: 1),
                          .init(identifier: "c", name: "iPad C", productFamily: 2)],
            runtimes: [.init(identifier: "old", name: "iOS 26.0"), .init(identifier: "new", name: "iOS 27.0"),
                       .init(identifier: "empty", name: "iOS 28.0")],
            supportedDeviceTypes: ["old": ["b"], "new": ["a", "c"]])
        var created: [[String]] = []
        var failure: Error?
        let form = NewSimulatorWindowController(catalog: catalog, create: { name, deviceType, runtime in
            if let failure { throw failure }
            created.append([name, deviceType, runtime])
        })
        defer { form.close() }
        let window = try #require(form.window)
        form.showWindow(nil)
        func choose(_ title: String, in popUp: NSPopUpButton) {
            popUp.selectItem(withTitle: title)
            popUp.sendAction(popUp.action, to: popUp.target)
        }
        func selection() -> [String?] { [form.deviceTypes.titleOfSelectedItem, form.runtimes.titleOfSelectedItem] }
        #expect(form.deviceTypes.itemArray.map { $0.isSeparatorItem ? "-" : $0.title }
                == ["iPhone A", "iPhone B", "iPhone X", "-", "iPad C"])
        #expect(form.runtimes.itemTitles == ["iOS 26.0", "iOS 27.0", "iOS 28.0"])
        // The first runtime stays, and the device type becomes the first it supports.
        #expect(selection() == ["iPhone B", "iOS 26.0"])
        #expect(form.nameField.placeholderString == "iPhone B")
        choose("iPad C", in: form.deviceTypes)
        #expect(selection() == ["iPad C", "iOS 27.0"])
        choose("iOS 26.0", in: form.runtimes)
        #expect(selection() == ["iPhone B", "iOS 26.0"])
        // Without a compatible choice the other selection empties, and the next
        // compatible choice restores it.
        choose("iPhone X", in: form.deviceTypes)
        #expect(selection() == ["iPhone X", nil])
        choose("iPad C", in: form.deviceTypes)
        #expect(selection() == ["iPad C", "iOS 27.0"])
        choose("iOS 28.0", in: form.runtimes)
        #expect(selection() == [nil, "iOS 28.0"])
        choose("iOS 26.0", in: form.runtimes)
        #expect(selection() == ["iPhone B", "iOS 26.0"])

        failure = HostError.operation("creation failed")
        form.createButton.performClick(nil)
        for _ in 0..<100 where window.attachedSheet == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(window.isVisible && created.isEmpty)
        window.endSheet(try #require(window.attachedSheet))
        failure = nil
        // An empty name uses the device type's name.
        form.createButton.performClick(nil)
        for _ in 0..<100 where window.isVisible { try await Task.sleep(for: .milliseconds(10)) }
        #expect(created == [["iPhone B", "b", "old"]])
        #expect(!window.isVisible)
    }

    @Test func newSimulatorWithoutRuntimesCannotCreate() throws {
        let form = NewSimulatorWindowController(
            catalog: SimulatorCatalog(deviceTypes: [.init(identifier: "a", name: "iPhone A", productFamily: 1)],
                                      runtimes: [], supportedDeviceTypes: [:]),
            create: { _, _, _ in Issue.record("created without a runtime") })
        #expect(form.runtimes.itemTitles == ["No Runtimes Available"])
        #expect(!form.runtimes.isEnabled && !form.deviceTypes.isEnabled && !form.createButton.isEnabled)
    }

    @Test func hardwareCommandsSendSimulatorAppEvents() throws {
        let display = TestDisplay()
        let controller = try makeController(display, features: [
            DeviceCapabilities.siri, DeviceCapabilities.routableAudio, DeviceCapabilities.applePayAuthorization,
        ])
        defer { controller.invalidate() }
        for command in [DeviceCommand.ID.siri, .triggerScreenshot, .increaseVolume, .decreaseVolume, .authorizeApplePay] {
            controller.perform(command)
        }
        #expect(display.events.map(\.input) == [
            .button(.siri), .button(.siri), .screenshot, .screenshot, .volumeUp, .volumeUp,
            .volumeDown, .volumeDown, .button(.applePay), .button(.applePay),
        ])
        #expect(display.events.map(\.state) == Array(repeating: [HIDState.down, .up], count: 5).flatMap { $0 })
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

    @Test func overlappingHoldsReleaseWhenTheLastEnds() async throws {
        let display = TestDisplay()
        let controller = try makeController(display)
        defer { controller.invalidate() }
        let clock = ContinuousClock()
        let start = clock.now
        // The second hold starts well before the first ends, even on a busy runner.
        controller.send(.hold(.button(.actionStaccato), for: .milliseconds(1000)))
        try await Task.sleep(for: .milliseconds(50))
        controller.send(.hold(.button(.actionStaccato), for: .milliseconds(1000)))
        while display.events.count < 3, clock.now - start < .seconds(10) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(clock.now - start >= .milliseconds(1050))
        try await Task.sleep(for: .milliseconds(100))
        #expect(display.events.map(\.state) == [.down, .down, .up])
    }

    @Test func aHeldInputIsReleasedDuringAShutdown() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // A simctl stand-in whose shutdown outlasts the hold, then fails.
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

    @Test func aPressWhoseReleaseCannotBeCreatedSendsNothing() async throws {
        let display = TestDisplay()
        display.unavailableStates = [.up]
        let controller = try makeController(display)
        defer { controller.invalidate() }
        var failures = 0
        controller.session.send(.press(.button(.siri))) { _ in failures += 1 }
        controller.session.send(.pressTwice(.button(.home), interval: .milliseconds(10))) { _ in failures += 1 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(display.events.isEmpty)
        #expect(failures == 2)
    }

    @Test func anUndeliveredReleaseIsRetriedWhenTheWindowCloses() async throws {
        let display = TestDisplay()
        display.undeliveredStates = [.up]
        let controller = try makeController(display)
        var failures = 0
        controller.session.send(.hold(.button(.actionStaccato), for: .milliseconds(10))) { _ in failures += 1 }
        for _ in 0..<300 where display.events.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        controller.invalidate()
        #expect(display.events.map(\.state) == [.down, .up, .up])
        #expect(failures == 1)
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
        // Nothing is left to release when the window closes.
        controller.invalidate()
        #expect(display.events.count == 4)
    }

    @Test func aHoldCreatesItsReleaseWhenItEnds() async throws {
        let display = TestDisplay()
        let controller = try makeController(display)
        defer { controller.invalidate() }
        controller.session.send(.hold(.button(.actionStaccato), for: .milliseconds(50))) { _ in }
        for _ in 0..<300 where display.events.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(display.created.map(\.state) == [.down, .up])
        #expect(display.created[1].at - display.created[0].at >= .milliseconds(50))
    }

    @Test func aReleaseNotYetDeliveredIsSentAgainWhenTheWindowCloses() async throws {
        let display = TestDisplay()
        display.deferCompletions = true
        let controller = try makeController(display)
        controller.session.send(.hold(.button(.actionStaccato), for: .milliseconds(10))) { _ in }
        for _ in 0..<300 where display.events.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        controller.invalidate()
        #expect(display.events.map(\.state) == [.down, .up, .up])
    }

    @Test func anEarlierDeliveryKeepsALaterPressTracked() async throws {
        let display = TestDisplay()
        display.deferCompletions = true
        // The second Home release is not delivered.
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
        display.deliveryError = HostError.operation("delivery failed")
        let controller = try makeController(display)
        defer { controller.invalidate() }
        var failures: [Error] = []
        controller.session.send(.press(.button(.siri))) { failures.append($0) }
        #expect(display.events.count == 2)
        #expect(failures.count == 1)
    }

    private func makeController(_ display: TestDisplay,
                                features: Set<String> = [DeviceCapabilities.displayRotation],
                                framebufferMask: Bool = false,
                                simctl: URL = DeviceTools.simctl,
                                devicectl: URL = DeviceTools.devicectl,
                                recordingProcess: ((URL, DeviceTools.ScreenMask) -> Process)? = nil,
                                screenPointsPerInch: Double? = nil,
                                device identifier: String = "test-device",
                                preferences: MemoryPreferences = MemoryPreferences(),
                                onClose: @escaping (DeviceWindowController, DeviceLifetimeChoice?) -> Void = { _, _ in },
                                onRestart: @escaping (DeviceWindowController, Bool) -> Void = { _, _ in })
        throws -> DeviceWindowController {
        let session = try makeSession(display, features: features, framebufferMask: framebufferMask, simctl: simctl,
                                      devicectl: devicectl, recordingProcess: recordingProcess,
                                      screenPointsPerInch: screenPointsPerInch, device: identifier)
        return try DeviceWindowController(session: session, preferences: preferences, onClose: onClose,
                                          onRestart: onRestart)
    }

    private func makeSession(_ display: TestDisplay,
                             features: Set<String> = [DeviceCapabilities.displayRotation],
                             framebufferMask: Bool = false,
                             simctl: URL = DeviceTools.simctl,
                             devicectl: URL = DeviceTools.devicectl,
                             recordingProcess: ((URL, DeviceTools.ScreenMask) -> Process)? = nil,
                             screenPointsPerInch: Double? = nil,
                             device identifier: String = "test-device") throws -> DeviceSession {
        DeviceSession(
            device: availableDevice(identifier, "Test iPhone", runtime: "iOS", state: 3),
            capabilities: DeviceCapabilities(family: .iPhone, runtimeVersion: 0x1B_00_00,
                                             supportsFeature: { features.contains($0) },
                                             hasFramebufferMask: framebufferMask,
                                             screenPointsPerInch: screenPointsPerInch),
            display: display,
            tools: try DeviceTools(identifier: "test-device", xcodeURL: URL(fileURLWithPath: "/Applications/Xcode.app"),
                                   simctl: simctl, devicectl: devicectl),
            recordingProcess: recordingProcess)
    }
}

/// Preferences kept in memory, so that tests leave the app's defaults alone.
private final class MemoryPreferences: PreferenceStore {
    var values: [String: Any] = [:]
    func object(forKey defaultName: String) -> Any? { values[defaultName] }
    func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
}

@MainActor
private final class InputView: NSView {
    var keyDowns: [NSEvent] = []
    var keyUps: [NSEvent] = []
    var modifiers: [NSEvent] = []
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { keyDowns.append(event) }
    override func keyUp(with event: NSEvent) { keyUps.append(event) }
    override func flagsChanged(with event: NSEvent) { modifiers.append(event) }
}
@MainActor
private final class RefusingResponder: NSResponder {
    override func resignFirstResponder() -> Bool { false }
}
private enum AppliedLocation: Equatable {
    case cleared, coordinate(Double, Double), scenario(String)
}

/// A display view whose intrinsic size follows its display, as `SimDisplayView`'s does.
@MainActor
private final class TestDisplayView: NSView {
    var displaySize: () -> NSSize = { .zero }
    override var intrinsicContentSize: NSSize { displaySize() }
}

@MainActor
private final class TestDisplay: SimulatorDisplay {
    let view: NSView = TestDisplayView(frame: NSRect(x: 0, y: 0, width: 390, height: 844))
    let input = InputView()
    var inputView: NSView { input }
    /// The display's size at scale 1, without the bezel.
    var naturalSize = NSSize(width: 390, height: 844)
    private(set) var renderScale: CGFloat = 1
    var screenScale: CGFloat? = 3
    var displayClass: UInt16? = 0
    var onPropertiesChange: (() -> Void)?
    var guestInterfaceAngle: Double?
    var isBooted = true
    var events: [(input: HIDInput, state: HIDState)] = []
    /// Called for each sent event, before it is recorded.
    var onSend: () -> Void = {}
    /// Completes each sent event with this error.
    var deliveryError: Error?
    /// Completes sent events of these states with an error.
    var undeliveredStates: Set<HIDState> = []
    /// Completes the sent events at these positions with an error.
    var undeliveredEvents: Set<Int> = []
    /// Fails to create messages for events of these states.
    var unavailableStates: Set<HIDState> = []
    /// Holds completions until the test runs them, as SimulatorKit delivers later.
    var deferCompletions = false
    var pendingCompletions: [() -> Void] = []
    var created: [(state: HIDState, at: ContinuousClock.Instant)] = []
    var buttons: [DeviceButton] {
        events.compactMap { if case .button(let button) = $0.input, $0.state == .down { button } else { nil } }
    }
    var activations: [Bool] = []
    var keyboard: [Bool] = []
    var disconnectCount = 0
    var onDisconnect: () -> Void = {}
    init() {
        view.addSubview(input)
        (view as? TestDisplayView)?.displaySize = { [unowned self] in size(for: renderScale) }
    }
    func message(for input: HIDInput, _ state: HIDState) throws -> HIDMessage {
        guard !unavailableStates.contains(state) else { throw HostError.operation("No message") }
        created.append((state, ContinuousClock.now))
        return HIDMessage(input: input, state: state, pointer: OpaquePointer(malloc(1)!))
    }
    func send(_ message: HIDMessage, completion: (@MainActor (Error?) -> Void)?) throws {
        onSend()
        free(UnsafeMutableRawPointer(message.take()))
        events.append((message.input, message.state))
        let undelivered = undeliveredStates.contains(message.state) || undeliveredEvents.contains(events.count - 1)
        let error = undelivered ? HostError.operation("Undelivered") : deliveryError
        if deferCompletions {
            pendingCompletions.append { completion?(error) }
        } else {
            completion?(error)
        }
    }
    func toggleAppearance() throws {}
    /// The guest's Darwin notification states, and the names posted in order.
    var notificationStates: [String: UInt64] = [:]
    var postedNotifications: [String] = []
    var contentSize = 4
    var contrastMode = 1
    func postNotification(_ name: String) throws { postedNotifications.append(name) }
    func notificationState(_ name: String) throws -> UInt64 { notificationStates[name] ?? 0 }
    func setNotificationState(_ name: String, to state: UInt64) throws { notificationStates[name] = state }
    func contentSizeCategory() throws -> Int { contentSize }
    func setContentSizeCategory(_ category: Int) throws { contentSize = category }
    func increaseContrastMode() throws -> Int { contrastMode }
    func setIncreaseContrast(_ enabled: Bool) throws { contrastMode = enabled ? 2 : 1 }
    func triggerCloudSync() async throws {}
    /// The runtime's location routes, and each location change requested in order.
    var scenarios: [LocationScenario] = []
    var appliedLocations: [AppliedLocation] = []
    /// Fails location changes with this error after recording them.
    var locationError: Error?
    /// Holds the scenario listing until `releaseScenarios()`, as a device
    /// that has just booted lists them late.
    var holdsScenarios = false
    private var heldListing: CheckedContinuation<Void, Never>?
    func locationScenarios() async throws -> [LocationScenario] {
        if holdsScenarios { await withCheckedContinuation { heldListing = $0 } }
        return scenarios
    }
    func releaseScenarios() {
        heldListing?.resume()
        heldListing = nil
    }
    func clearSimulatedLocation() async throws { try applyLocation(.cleared) }
    func setLocation(latitude: Double, longitude: Double) async throws {
        try applyLocation(.coordinate(latitude, longitude))
    }
    func setLocationScenario(_ name: String) async throws { try applyLocation(.scenario(name)) }
    private func applyLocation(_ location: AppliedLocation) throws {
        appliedLocations.append(location)
        if let locationError { throw locationError }
    }
    /// What the bezel adds to the display's size at scale 1 while it shows.
    var bezel = NSSize.zero
    /// The padding of the bezel's images, or nil for a device type without a bezel.
    var bezelPadding: NSSize?
    var chromePadding: NSSize? { showsBezel ? bezelPadding : nil }
    private var showsBezel = true
    private var outerSize: NSSize {
        showsBezel ? NSSize(width: naturalSize.width + bezel.width, height: naturalSize.height + bezel.height) : naturalSize
    }
    func setChromeVisible(_ visible: Bool) { showsBezel = visible }
    func setRenderScale(_ scale: CGFloat) {
        renderScale = scale
        view.setFrameSize(size(for: scale))
    }
    func size(for scale: CGFloat) -> NSSize { NSSize(width: outerSize.width * scale, height: outerSize.height * scale) }
    func scale(for size: NSSize) -> CGFloat { min(size.width / outerSize.width, size.height / outerSize.height) }
    func setActive(_ active: Bool) { activations.append(active) }
    func setKeyboardEnabled(_ enabled: Bool) { keyboard.append(enabled) }
    var rotations: [Double] = []
    func setRotation(degrees: Double) { rotations.append(degrees) }
    func beginResize() {}
    func resize(to size: NSSize) { setRenderScale(scale(for: size)) }
    func endResize() {}
    func disconnect() { disconnectCount += 1; onDisconnect() }
}

@Suite @MainActor
struct HostBehaviorTests {
    @Test func physicalSizeComparesScreenDensities() {
        #expect(WindowScale.physicalSize(hostDensity: 220, deviceDensity: 440) == 0.5)
        // Simulator.app's densities stand in for missing values; NeoSimulator
        // also uses them where Simulator.app would divide by zero.
        let defaults = WindowScale.defaultHostDensity / WindowScale.defaultDeviceDensity
        #expect(defaults == CGFloat(110) / 163)
        #expect(WindowScale.physicalSize(hostDensity: nil, deviceDensity: nil) == defaults)
        #expect(WindowScale.physicalSize(hostDensity: .infinity, deviceDensity: 0) == defaults)
        #expect(WindowScale.physicalSize(hostDensity: 0, deviceDensity: 220) == 0.5)
    }

    @Test func pixelAccurateMatchesDevicePixelsToMacPixels() {
        #expect(WindowScale.pixelAccurate(screenScale: 3, backingScaleFactor: 2) == 1.5)
        #expect(WindowScale.pixelAccurate(screenScale: nil, backingScaleFactor: 2) == 0.5)
        #expect(WindowScale.pixelAccurate(screenScale: 3, backingScaleFactor: nil) == 3)
    }

    @Test func fixedScalesStopAtTheDevicesMinimum() {
        #expect(WindowScale.minimum(family: .iPhone, displayClass: 0, fitting240: 0.2) == 0.4)
        #expect(WindowScale.minimum(family: .iPad, displayClass: 0, fitting240: 0.2) == 0.25)
        #expect(WindowScale.minimum(family: .watch, displayClass: 0, fitting240: 0.2) == 0.6)
        // Elsewhere the display must stay at least 240 points across.
        #expect(WindowScale.minimum(family: .iPhone, displayClass: 1, fitting240: 0.2) == 0.2)
        #expect(WindowScale.minimum(family: .iPhone, displayClass: nil, fitting240: 0.2) == 0.2)
        #expect(WindowScale.minimum(family: .tv, displayClass: 0, fitting240: 0.2) == 0.2)
        #expect(WindowScale.matches(1.000_9, 1) && !WindowScale.matches(1.001_1, 1))
    }

    @Test func fixedScalesMoveTheWindowBackOntoItsScreen() {
        let visible = NSRect(x: 0, y: 0, width: 1000, height: 800)
        func origin(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> NSPoint {
            WindowScale.origin(of: NSRect(x: x, y: y, width: width, height: height), within: visible)
        }
        #expect(origin(10, 20, 300, 400) == NSPoint(x: 10, y: 20))
        #expect(origin(900, -100, 200, 300) == NSPoint(x: 800, y: 0))
        #expect(origin(-50, 600, 200, 300) == NSPoint(x: 0, y: 500))
        // A window larger than the screen lines up with the edge opposite the one it crossed.
        #expect(origin(-50, -100, 1200, 1000) == NSPoint(x: -200, y: -200))
        #expect(origin(100, 100, 1200, 1000) == NSPoint(x: 0, y: 0))
    }

    @Test func windowGeometryIsSavedUnderSimulatorKeys() {
        let preferences = MemoryPreferences()
        #expect(preferences.windowScale(forDevice: "A") == nil && preferences.windowCenter(forDevice: "A") == nil)
        preferences.setWindowGeometry(center: NSPoint(x: 10.5, y: -20), scale: 1.5, forDevice: "A")
        preferences.setWindowGeometry(center: NSPoint(x: 300, y: 400), scale: 0.5, forDevice: "B")
        preferences.setWindowGeometry(center: NSPoint(x: 1, y: 2), scale: nil, forDevice: "B")
        let devices = preferences.values["DevicePreferences"] as? [String: [String: [String: Any]]]
        #expect(devices?["A"]?["SimulatorWindowGeometry"]?["WindowScale"] as? Double == 1.5)
        #expect(devices?["A"]?["SimulatorWindowGeometry"]?["WindowCenter"] as? String == "{10.5, -20}")
        #expect(devices?["B"]?["SimulatorWindowGeometry"]?["WindowScale"] as? Double == 0.5)
        #expect(devices?["B"]?["SimulatorWindowGeometry"]?["WindowCenter"] as? String == "{1, 2}")
        #expect(preferences.windowScale(forDevice: "A") == 1.5)
        #expect(preferences.windowCenter(forDevice: "A") == NSPoint(x: 10.5, y: -20))
        for invalid: Any in [0, -1, "1.5", Double.nan] {
            preferences.values["DevicePreferences"] = ["A": ["SimulatorWindowGeometry": ["WindowScale": invalid]]]
            #expect(preferences.windowScale(forDevice: "A") == nil)
        }
        // Like Simulator.app, the zero point, which an unreadable string also
        // gives, is no center.
        for invalid: Any in ["{0, 0}", "center", 12] {
            preferences.values["DevicePreferences"] = ["A": ["SimulatorWindowGeometry": ["WindowCenter": invalid]]]
            #expect(preferences.windowCenter(forDevice: "A") == nil)
        }
    }

    @Test func aBezelWithTopPaddingMayReachAboveTheScreen() throws {
        let visible = NSRect(x: 0, y: 74, width: 2560, height: 1336)
        // The frame keeps its size; only the bezel, below its padding, stays below the top.
        let tall = NSRect(x: -40, y: -300, width: 900, height: 2000)
        #expect(WindowScale.frame(tall, constrainedBelow: visible, topInset: 18)
            == NSRect(x: -40, y: visible.maxY + 18 - 2000, width: 900, height: 2000))
        // A frame whose bezel is below the top keeps its place, past every other edge.
        let low = NSRect(x: 2500, y: -500, width: 900, height: 1000)
        #expect(WindowScale.frame(low, constrainedBelow: visible, topInset: 18) == low)
        let reaching = NSRect(x: 0, y: visible.maxY + 18 - 1000, width: 900, height: 1000)
        #expect(WindowScale.frame(reaching, constrainedBelow: visible, topInset: 18) == reaching)
        // A device window applies it while its bezel has top padding, and
        // otherwise leaves the frame to AppKit.
        let screen = try #require(NSScreen.screens.first)
        let mask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        let window = DeviceWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: mask,
                                  backing: .buffered, defer: true)
        let plain = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: mask,
                             backing: .buffered, defer: true)
        let frame = NSRect(x: screen.visibleFrame.minX + 10, y: screen.visibleFrame.minY - 300,
                           width: 400, height: screen.visibleFrame.height + 600)
        #expect(window.constrainFrameRect(frame, to: screen) == plain.constrainFrameRect(frame, to: screen))
        window.chromeTopPadding = 9
        window.displayScale = { 2 }
        #expect(window.constrainFrameRect(frame, to: screen)
            == WindowScale.frame(frame, constrainedBelow: screen.visibleFrame, topInset: 18))
    }

    @Test func windowTitlesFollowSimulatorNaming() {
        #expect(deviceWindowTitles(name: "iPad Pro 11-inch (M5) (16GB)", runtimeName: "iOS 27.0")
            == ("iPad Pro 11-inch (M5)", "16GB – iOS 27.0"))
        #expect(deviceWindowTitles(name: "iPhone 17", runtimeName: "iOS 26.5") == ("iPhone 17", "iOS 26.5"))
        #expect(deviceWindowTitles(name: "My iPad (16GB)", runtimeName: "iOS 27.0") == ("My iPad (16GB)", "iOS 27.0"))
    }

    @Test func launchConflictIsRetainedBeforeDeferredTeardown() {
        let center = NotificationCenter()
        let monitor = HostConflictMonitor(notificationCenter: center)
        var teardownCalled = false
        monitor.onConflict = { teardownCalled = true }
        center.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil,
            userInfo: [NSWorkspace.applicationUserInfoKey: FixtureRunningApplication()])

        #expect(monitor.conflictingHostName == "Device Hub")
        #expect(throws: HostError.self) { try monitor.check() }
        #expect(!teardownCalled)
    }

    @Test func launchConflictFromBackgroundThreadIsRetainedDuringStartup() throws {
        let center = NotificationCenter()
        let monitor = HostConflictMonitor(notificationCenter: center)
        let application = FixtureRunningApplication()
        let posted = DispatchSemaphore(value: 0)
        // Keep the posting thread independent of shared dispatch workers while
        // the main actor is deliberately unavailable, as during startup.
        Thread.detachNewThread {
            center.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil,
                userInfo: [NSWorkspace.applicationUserInfoKey: application])
            posted.signal()
        }
        try #require(posted.wait(timeout: .now() + 3) == .success)

        #expect(monitor.conflictingHostName == "Device Hub")
        #expect(throws: HostError.self) { try monitor.check() }
    }

    @Test func browserReflectsCatalogChangesAndReportsBootErrors() async throws {
        let source = TestCatalog()
        let model = DeviceBrowserModel(source: source)
        let device = try #require(model.devices.first)
        await model.open(device)?.value
        #expect(source.opened == [device.id])
        #expect(model.devices.first?.isBooted == true)
        source.failure = HostError.operation("Boot failed")
        await model.open(device)?.value
        #expect(model.errorMessage == "Boot failed")
        #expect(model.opening.isEmpty)
        source.devices = []
        model.refresh()
        #expect(model.devices.isEmpty)
    }

    @Test func captureFailurePreservesExistingDestination() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("capture.png")
        let original = Data("original".utf8)
        try original.write(to: destination)
        await #expect(throws: (any Error).self) {
            try await CaptureFile.write(to: destination, extension: "png") { temporary in
                try Data("partial".utf8).write(to: temporary)
                throw HostError.operation("Capture failed")
            }
        }
        #expect(try Data(contentsOf: destination) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["capture.png"])
    }

    @Test func neoInstallationDoesNotRequireSimulatorApplication() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let xcode = directory.appendingPathComponent("Xcode.app")
        let contents = xcode.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("Developer"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.apple.dt.Xcode"], format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        let options = try HostLaunchOptions(arguments: ["--xcode", xcode.path])
        try options.validateInstallation()
        #expect(!FileManager.default.fileExists(atPath: contents.appendingPathComponent("Developer/Applications/Simulator.app").path))
    }

    @Test func launchArgumentsRejectAmbiguousStartupRequests() {
        #expect(throws: (any Error).self) {
            try HostLaunchOptions(arguments: ["--xcode", "/Xcode.app", "--validate-runtime", "--startup-result", "/tmp/result"])
        }
        #expect(throws: (any Error).self) {
            try HostLaunchOptions(arguments: ["--xcode", "relative.app"])
        }
    }
}

@MainActor
private final class TestCatalog: DeviceBrowserSource {
    var devices = [availableDevice("phone", "Phone", runtime: "iOS 27", state: 1)]
    var opened: [String] = []
    var failure: Error?
    func availableSimulatorDevices() -> [AvailableDevice] { devices }
    func openSimulator(withIdentifier identifier: String) async throws {
        if let failure { throw failure }
        opened.append(identifier)
        devices = devices.map {
            var device = $0
            device.state = 3
            return device
        }
    }
}

private func availableDevice(_ identifier: String, _ name: String, runtime: String, state: UInt) -> AvailableDevice {
    AvailableDevice(identifier: identifier, name: name, descriptiveName: "\(runtime) - \(name)",
                    runtimeIdentifier: "runtime \(runtime)", runtimeName: runtime,
                    productFamily: name.hasPrefix("iPad") ? 2 : 1, deviceTypeName: name, state: state)
}

@Suite @MainActor
struct DeviceToolTests {
    @Test func drainsOutputAndReportsToolFailures() async throws {
        let runner = DeviceToolRunner()
        let data = try await runner.run(URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "i=0; while [ $i -lt 10000 ]; do echo stdout; echo stderr >&2; i=$((i+1)); done"])
        #expect(data.count == 70_000)
        await #expect(throws: (any Error).self) {
            try await runner.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo rejected >&2; exit 7"])
        }
        #expect(runner.process == nil)
    }

    @Test func toolsAddressADeviceOutsideTheDefaultSet() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("arguments"), simctl = directory.appendingPathComponent("simctl")
        try """
            #!/bin/sh
            printf '%s\\n' "$@" > "\(log.path)"
            """.write(to: simctl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: simctl.path)
        let tools = try DeviceTools(identifier: "test-device", xcodeURL: URL(fileURLWithPath: "/Applications/Xcode.app"),
                                    deviceSetPath: "/tmp/XCTestDevices", simctl: simctl)
        try await tools.boot()
        #expect(try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
                == ["--set", "/tmp/XCTestDevices", "boot", "test-device"])
        #expect(tools.recordingProcess(to: URL(fileURLWithPath: "/tmp/video.mov"), mask: .ignored, codec: .h264).arguments?.prefix(4)
                == ["--set", "/tmp/XCTestDevices", "io", "test-device"])
    }

    @Test func createDevicePassesNameTypeAndRuntimeToSimctl() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("arguments"), simctl = directory.appendingPathComponent("simctl")
        try """
            #!/bin/sh
            printf '%s\\n' "$DEVELOPER_DIR" "$@" > "\(log.path)"
            """.write(to: simctl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: simctl.path)
        try await DeviceTools.createDevice(named: "My Phone", deviceType: "type", runtime: "runtime",
                                           xcodeURL: URL(fileURLWithPath: "/Applications/Xcode.app"), simctl: simctl)
        #expect(try String(contentsOf: log, encoding: .utf8).split(separator: "\n") == [
            "/Applications/Xcode.app/Contents/Developer", "create", "My Phone", "type", "runtime",
        ])
    }

    @Test func timeoutAndCancellationReapTheChildProcess() async throws {
        let runner = DeviceToolRunner()
        await #expect(throws: (any Error).self) {
            try await runner.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: .milliseconds(30))
        }
        #expect(runner.process == nil)
        let task = Task { try await runner.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"]) }
        await Task.yield()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(runner.process == nil)
    }
}

// The fixture adds no mutable state to NSRunningApplication's Sendable contract.
private final class FixtureRunningApplication: NSRunningApplication, @unchecked Sendable {
    override var bundleIdentifier: String? { "com.apple.dt.Devices" }
}
