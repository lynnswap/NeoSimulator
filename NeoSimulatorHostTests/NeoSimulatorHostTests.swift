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
        controller.setDeviceBezelVisible(false)
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
        // The window takes the display's size at the scale, 12 points below
        // its header, also when the display is narrower than a manual resize
        // can make the window.
        func fitsDisplay() -> Bool {
            display.view.frame.size == display.size(for: display.renderScale)
                && window.contentLayoutRect.size == NSSize(width: display.view.frame.width,
                                                           height: display.view.frame.height + 12)
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

    @Test func unavailableScaleCommandsKeepTheirCheckmarks() throws {
        let display = TestDisplay()
        display.naturalSize = NSSize(width: 160, height: 320)
        // Physical Size is 0.5: the device is twice as dense as the screen.
        let screen = try #require(NSScreen.screens.first)
        let density = WindowScale.usable(WindowScale.density(of: screen)) ?? WindowScale.defaultHostDensity
        let controller = try makeController(display, screenPointsPerInch: Double(density * 2))
        defer { controller.invalidate() }
        controller.showWindow(nil)
        let window = try #require(controller.window)
        try #require(window.screen == screen)
        display.screenScale = 1.5 * screen.backingScaleFactor
        let items = [DeviceCommand.ID.physicalSize, .pointAccurate, .pixelAccurate].map { ($0, NSMenuItem()) }
        func checked(for controller: DeviceWindowController?) -> [DeviceCommand.ID] {
            for (id, item) in items { _ = DeviceCommand.command(id).validate(item, for: controller) }
            return items.filter { $0.1.state == .on }.map(\.0)
        }
        controller.perform(.pixelAccurate)
        #expect(checked(for: controller) == [.pixelAccurate])
        // Like Simulator.app, the commands keep their checkmarks while they
        // are unavailable: in full screen, where the display fills the screen
        // at another scale,
        controller.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification, object: window))
        window.setContentSize(NSSize(width: 500, height: 900))
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        #expect(display.renderScale != 1.5)
        #expect(checked(for: controller) == [.pixelAccurate])
        controller.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: window))
        #expect(display.renderScale == 1.5)
        // for Physical Size on another screen than the device's own,
        controller.perform(.physicalSize)
        #expect(display.renderScale == 0.5)
        #expect(checked(for: controller) == [.physicalSize])
        display.displayClass = 1
        controller.perform(.pointAccurate)
        #expect(checked(for: controller) == [.physicalSize, .pointAccurate])
        // and without a device window, where Simulator.app does not validate them.
        display.displayClass = 0
        #expect(checked(for: nil) == [.physicalSize, .pointAccurate])
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
        let screens = NSScreen.screens.map(\.frame)
        // What the device's window saved in another arrangement of screens.
        let elsewhere = "0D7A6E4C-5F4B-4D0E-9C61-2B8C9D0A1E2F"
        preferences.values[HostPreferences.devicePreferences] = ["test-device": [
            "ChromeTint": "#FFFFFF", "SimulatorWindowGeometry": [elsewhere: ["WindowCenter": "{10, 20}"]],
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
        first.showWindow(nil)
        let frame = try #require(first.window?.frame)
        // Closed as the user closes it, through the window's delegate, the
        // window saves its center and scale for the current arrangement of
        // screens, beside what was saved for another one.
        first.window?.close()
        let device = (preferences.values[HostPreferences.devicePreferences] as? [String: Any])?["test-device"]
            as? [String: Any]
        #expect(device?["ChromeTint"] as? String == "#FFFFFF")
        let geometry = device?["SimulatorWindowGeometry"] as? [String: Any]
        #expect((geometry?[elsewhere] as? [String: Any])?["WindowCenter"] as? String == "{10, 20}")
        let saved = geometry?[preferences.screenConfiguration(for: screens)] as? [String: Any]
        #expect(saved?["WindowScale"] as? Double == 1.5)
        #expect(saved?["WindowCenter"] as? String == NSStringFromPoint(NSPoint(x: frame.midX, y: frame.midY)))
        let (second, reopened) = try open()
        #expect(reopened.renderScale == 1.5)
        second.invalidate()
        // A saved scale that does not fit the screen is reduced to fit it.
        preferences.setWindowGeometry(center: NSPoint(x: frame.midX, y: frame.midY), scale: 100,
                                      forDevice: "test-device", screens: screens)
        let (third, reduced) = try open()
        defer { third.invalidate() }
        #expect(reduced.renderScale < 100)
        #expect(reduced.renderScale == third.scale(for: .fitScreen))
    }

    @Test func aDevicesWindowReopensWhereItClosedOrCascades() throws {
        let preferences = MemoryPreferences()
        func open(_ device: String, topPadding: CGFloat? = nil) throws -> DeviceWindowController {
            let display = TestDisplay()
            display.naturalSize = NSSize(width: 160, height: 320)
            display.bezelPadding = topPadding.map { NSSize(width: 10, height: $0) }
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
        // moves back inside the screen, also with an iPad's bezel, whose top
        // padding keeps AppKit from moving the window.
        preferences.setWindowGeometry(center: NSPoint(x: visible.maxX - 10, y: visible.midY), scale: nil,
                                      forDevice: "C", screens: NSScreen.screens.map(\.frame))
        let moved = try open("C", topPadding: 9)
        defer { moved.invalidate() }
        moved.showNewWindow(cascadingFrom: &cascade)
        let movedWindow = try #require(moved.window)
        let screen = try #require((movedWindow.screen ?? NSScreen.main)?.visibleFrame)
        #expect(screen.contains(movedWindow.frame))
        #expect(cascade == afterSecond)
    }

    @Test func aWindowSavedInAnotherArrangementOfScreensOpensAsANewOne() throws {
        // Like Simulator.app, a device's window opens where it closed and at
        // the scale it closed only in the arrangement of screens it closed in,
        // here one with a screen that no Mac has.
        let elsewhere = "0D7A6E4C-5F4B-4D0E-9C61-2B8C9D0A1E2F"
        let preferences = MemoryPreferences()
        preferences.values[HostPreferences.screenConfigurations] = [elsewhere: ["{{-9000, 9000}, {640, 480}}"]]
        preferences.values[HostPreferences.devicePreferences] = ["A": ["SimulatorWindowGeometry": [
            elsewhere: ["WindowCenter": "{-8700, 9200}", "WindowScale": 0.5],
        ]]]
        let display = TestDisplay()
        display.naturalSize = NSSize(width: 160, height: 320)
        let controller = try makeController(display, device: "A", preferences: preferences)
        defer { controller.invalidate() }
        // The window opens at Point Accurate, which fits the screen, and as
        // the first window that cascades, centered with center().
        #expect(display.renderScale == 1)
        var cascade = NSPoint.zero
        controller.showNewWindow(cascadingFrom: &cascade)
        #expect(cascade != .zero)
        let window = try #require(controller.window)
        let placed = window.frame
        window.center()
        #expect(window.frame == placed)
        // The current arrangement is saved beside the other.
        let configurations = preferences.values[HostPreferences.screenConfigurations] as? [String: [String]]
        #expect(configurations?.count == 2)
        #expect(configurations?[elsewhere] == ["{{-9000, 9000}, {640, 480}}"])
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

    @Test func aRestartKeepsTheTopEdgeOfAWindowThatWasInLandscape() async throws {
        let first = TestDisplay()
        first.naturalSize = NSSize(width: 240, height: 120)
        let controller = try makeController(first)
        defer { controller.invalidate() }
        controller.showWindow(nil)
        let window = try #require(controller.window)
        let visible = try #require(window.screen?.visibleFrame)
        window.setFrameOrigin(NSPoint(x: visible.minX + 20, y: visible.minY + 400 - window.frame.height))
        let top = window.frame.maxY
        await controller.prepareForRestart()
        // The device's next connection shows the display upright. Like
        // Simulator.app, the window takes that shape below its top edge, as
        // after a rotation, instead of growing above it.
        let second = TestDisplay()
        second.naturalSize = NSSize(width: 120, height: 240)
        controller.reconnect(try makeSession(second))
        #expect(second.view.frame.size == NSSize(width: 120, height: 240))
        #expect(abs(window.frame.maxY - top) < 1)
        #expect(visible.contains(window.frame))
    }

    @Test func aWindowClosedDuringARestartSavesNothing() async throws {
        let preferences = MemoryPreferences()
        let screens = NSScreen.screens.map(\.frame)
        preferences.setWindowGeometry(center: NSPoint(x: 100, y: 200), scale: 2, forDevice: "A", screens: screens)
        // Like Simulator.app, a window that closes while its device restarts
        // keeps the geometry its device's window saved last.
        let restarting = try makeController(TestDisplay(), device: "A", preferences: preferences)
        restarting.showWindow(nil)
        await restarting.prepareForRestart()
        restarting.window?.close()
        let kept = preferences.windowGeometry(forDevice: "A", screens: screens)
        #expect(kept.center == NSPoint(x: 100, y: 200) && kept.scale == 2)
        // Once the device reconnects, closing saves again.
        let reconnected = try makeController(TestDisplay(), device: "B", preferences: preferences)
        await reconnected.prepareForRestart()
        reconnected.reconnect(try makeSession(TestDisplay(), device: "B"))
        reconnected.invalidate()
        #expect(preferences.windowGeometry(forDevice: "B", screens: screens).center != nil)
    }

    @Test func aControllerReleasedBeforeItsWindowShowsSavesNothing() throws {
        let preferences = MemoryPreferences()
        let screens = NSScreen.screens.map(\.frame)
        preferences.setWindowGeometry(center: NSPoint(x: 100, y: 200), scale: 2, forDevice: "test-device",
                                      screens: screens)
        let display = TestDisplay()
        // HostApplication releases a new controller when another host appears
        // before its window shows. That disconnects the display and keeps the
        // geometry the device's window saved last.
        try autoreleasepool { _ = try makeController(display, preferences: preferences) }
        #expect(display.disconnectCount == 1)
        let kept = preferences.windowGeometry(forDevice: "test-device", screens: screens)
        #expect(kept.center == NSPoint(x: 100, y: 200) && kept.scale == 2)
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
        controller.setDeviceBezelVisible(false)
        controller.setDeviceBezelVisible(true)
        #expect(first.renderScale == 1)
        // So does a restart.
        await controller.prepareForRestart()
        let second = TestDisplay()
        second.naturalSize = landscape
        controller.reconnect(try makeSession(second))
        #expect(second.renderScale == 1)
        #expect(window.frame.width > visible.width)
    }

    @Test func aRotatedWindowMovesBackInsideItsScreen() throws {
        let key = HostPreferences.rotateWindowWhenSignaledByGuest
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.set(true, forKey: key)
        let display = TestDisplay()
        let portrait = NSSize(width: 200, height: 300)
        display.naturalSize = portrait
        // With a bezel the window is not resizable, and AppKit leaves it past the screen.
        display.bezelPadding = NSSize(width: 10, height: 0)
        let controller = try makeController(display)
        defer { controller.invalidate() }
        controller.showWindow(nil)
        let window = try #require(controller.window)
        let visible = try #require(window.screen?.visibleFrame)
        // Turned to landscape near the right edge, the window grows past it,
        // and like Simulator.app moves back inside the screen.
        window.setFrameOrigin(NSPoint(x: visible.maxX - window.frame.width - 10, y: visible.minY + 20))
        display.guestInterfaceAngle = 90
        display.naturalSize = NSSize(width: 500, height: 200)
        display.onPropertiesChange?()
        #expect(display.rotations == [90])
        #expect(window.frame.width == 500)
        #expect(visible.contains(window.frame))
        // Turned back to portrait near the bottom edge, it grows below it.
        window.setFrameOrigin(NSPoint(x: visible.minX + 10, y: visible.minY + 10))
        display.guestInterfaceAngle = 0
        display.naturalSize = portrait
        display.onPropertiesChange?()
        #expect(display.rotations == [90, 0])
        #expect(visible.contains(window.frame))
    }

    @Test func aRotatedDeviceReopensCenteredWhereItClosed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // A devicectl stand-in for a device in landscape.
        let devicectl = directory.appendingPathComponent("devicectl")
        try """
            #!/bin/sh
            printf '{"result":{"deviceOrientation":"landscapeLeft","deviceOrientationNonFlat":"landscapeLeft"}}'
            """.write(to: devicectl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: devicectl.path)
        let preferences = MemoryPreferences()
        let portrait = NSSize(width: 240, height: 400), landscape = NSSize(width: 400, height: 240)
        func open(_ device: String) throws -> (DeviceWindowController, TestDisplay) {
            let display = TestDisplay()
            display.naturalSize = portrait
            display.onRotation = { [unowned display] in display.naturalSize = $0 == 0 ? portrait : landscape }
            return (try makeController(display, devicectl: devicectl, device: device, preferences: preferences), display)
        }
        func readOrientation(_ controller: DeviceWindowController) async throws {
            for _ in 0..<300 where controller.session.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        }
        let visible = try #require(NSScreen.screens.first?.visibleFrame)
        let center = NSPoint(x: visible.midX, y: visible.midY)
        let screens = NSScreen.screens.map(\.frame)
        var cascade = NSPoint.zero
        // Like Simulator.app, the window is centered where it closed in the
        // shape of the device's orientation, which is read after it shows.
        preferences.setWindowGeometry(center: center, scale: nil, forDevice: "A", screens: screens)
        let (reopened, display) = try open("A")
        defer { reopened.invalidate() }
        reopened.showNewWindow(cascadingFrom: &cascade)
        try await readOrientation(reopened)
        #expect(display.rotations == [90])
        let window = try #require(reopened.window)
        #expect(window.contentLayoutRect.width == landscape.width)
        #expect(abs(window.frame.midX - center.x) < 1 && abs(window.frame.midY - center.y) < 1)
        // A window moved before the reading keeps its top-left corner instead.
        preferences.setWindowGeometry(center: center, scale: nil, forDevice: "B", screens: screens)
        let (moved, _) = try open("B")
        defer { moved.invalidate() }
        moved.showNewWindow(cascadingFrom: &cascade)
        let movedWindow = try #require(moved.window)
        movedWindow.setFrameOrigin(NSPoint(x: movedWindow.frame.minX - 20, y: movedWindow.frame.minY - 20))
        let topLeft = NSPoint(x: movedWindow.frame.minX, y: movedWindow.frame.maxY)
        try await readOrientation(moved)
        #expect(movedWindow.contentLayoutRect.width == landscape.width)
        #expect(abs(movedWindow.frame.minX - topLeft.x) < 1 && abs(movedWindow.frame.maxY - topLeft.y) < 1)
        // Without a saved center, the first window that cascades is centered
        // again with center() in the shape of the device's orientation.
        let (centered, _) = try open("C")
        defer { centered.invalidate() }
        var first = NSPoint.zero
        centered.showNewWindow(cascadingFrom: &first)
        try await readOrientation(centered)
        let centeredWindow = try #require(centered.window)
        #expect(centeredWindow.contentLayoutRect.width == landscape.width)
        let placed = centeredWindow.frame
        centeredWindow.center()
        #expect(centeredWindow.frame == placed)
        // The saved scale is reduced to Fit Screen's in the shape of the
        // device's orientation, where Simulator.app chooses it: a display too
        // tall upright opens at the saved scale once it reads landscape.
        let tall = NSSize(width: 100, height: visible.height * 4)
        preferences.setWindowGeometry(center: center, scale: 0.5, forDevice: "D", screens: screens)
        let tallDisplay = TestDisplay()
        tallDisplay.naturalSize = tall
        tallDisplay.onRotation = { [unowned tallDisplay] in tallDisplay.naturalSize = $0 == 0 ? tall : landscape }
        let rescaled = try makeController(tallDisplay, devicectl: devicectl, device: "D", preferences: preferences)
        defer { rescaled.invalidate() }
        #expect(tallDisplay.renderScale < 0.5)
        rescaled.showNewWindow(cascadingFrom: &cascade)
        try await readOrientation(rescaled)
        #expect(tallDisplay.renderScale == 0.5)
        let rescaledWindow = try #require(rescaled.window)
        #expect(rescaledWindow.contentLayoutRect.width == landscape.width * 0.5)
        #expect(abs(rescaledWindow.frame.midX - center.x) < 1 && abs(rescaledWindow.frame.midY - center.y) < 1)
        // A guest rotation before the reading, with Rotate Device
        // Automatically on, is not a change to the window's placement.
        let key = HostPreferences.rotateWindowWhenSignaledByGuest
        let follows = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(follows, forKey: key) }
        UserDefaults.standard.set(true, forKey: key)
        preferences.setWindowGeometry(center: center, scale: 0.5, forDevice: "E", screens: screens)
        let guestDisplay = TestDisplay()
        guestDisplay.naturalSize = tall
        guestDisplay.onRotation = { [unowned guestDisplay] in guestDisplay.naturalSize = $0 == 0 ? tall : landscape }
        let guestRotated = try makeController(guestDisplay, devicectl: devicectl, device: "E", preferences: preferences)
        defer { guestRotated.invalidate() }
        guestRotated.showNewWindow(cascadingFrom: &cascade)
        guestDisplay.guestInterfaceAngle = 90
        guestDisplay.onPropertiesChange?()
        #expect(guestDisplay.rotations == [90] && guestRotated.session.isBusy)
        try await readOrientation(guestRotated)
        #expect(guestDisplay.renderScale == 0.5)
        let guestWindow = try #require(guestRotated.window)
        #expect(abs(guestWindow.frame.midX - center.x) < 1 && abs(guestWindow.frame.midY - center.y) < 1)
    }

    @Test func fullScreenFillsTheScreenAndRestoresTheWindowAfter() throws {
        let display = TestDisplay()
        display.naturalSize = NSSize(width: 200, height: 300)
        display.bezel = NSSize(width: 20, height: 20)
        display.bezelPadding = NSSize(width: 10, height: 9)
        let controller = try makeController(display)
        defer { controller.invalidate() }
        controller.showWindow(nil)
        let window = try #require(controller.window)
        controller.perform(.pointAccurate)
        let windowed = window.frame
        // AppKit's full screen transition fills the screen only with a
        // resizable window, so a window with a bezel becomes resizable, also
        // when the bezel changes in full screen.
        controller.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification, object: window))
        #expect(window.styleMask.contains(.resizable))
        controller.setDeviceBezelVisible(false)
        controller.setDeviceBezelVisible(true)
        #expect(window.styleMask.contains(.resizable))
        // Like Simulator.app, leaving full screen restores the display's scale
        // and the window's origin, wherever AppKit returns the window.
        window.setFrame(NSRect(x: windowed.minX + 30, y: windowed.minY + 30,
                               width: windowed.width / 2, height: windowed.height / 2), display: true)
        #expect(display.renderScale < 1)
        controller.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: window))
        #expect(!window.styleMask.contains(.resizable))
        #expect(display.renderScale == 1)
        #expect(window.frame == windowed)
        // A window that does not enter full screen keeps its bezel's rule.
        controller.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification, object: window))
        controller.windowDidFailToEnterFullScreen(window)
        #expect(!window.styleMask.contains(.resizable))
    }

    @Test func leavingFullScreenMovesTheWindowBackInsideItsScreen() throws {
        let display = TestDisplay()
        display.naturalSize = NSSize(width: 200, height: 300)
        // An iPad's bezel, whose top padding keeps AppKit from moving the window.
        display.bezelPadding = NSSize(width: 10, height: 9)
        let controller = try makeController(display)
        defer { controller.invalidate() }
        controller.showWindow(nil)
        let window = try #require(controller.window)
        let visible = try #require(window.screen?.visibleFrame)
        // The window entered full screen from a screen that is gone when it leaves.
        window.setFrameOrigin(NSPoint(x: visible.maxX + 100, y: visible.minY + 10))
        controller.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification, object: window))
        controller.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: window))
        #expect(visible.contains(window.frame))
    }

    @Test func aScreenChangeMovesTheWindowBackInsideItsScreen() throws {
        let display = TestDisplay()
        display.naturalSize = NSSize(width: 200, height: 300)
        // An iPad's bezel, whose top padding keeps AppKit from moving the window.
        display.bezelPadding = NSSize(width: 10, height: 9)
        let controller = try makeController(display)
        defer { controller.invalidate() }
        controller.showWindow(nil)
        let window = try #require(controller.window)
        let visible = try #require(window.screen?.visibleFrame)
        window.setFrameOrigin(NSPoint(x: visible.maxX - window.frame.width * 0.75, y: visible.minY + 10))
        #expect(!visible.contains(window.frame))
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification,
                                        object: NSApplication.shared)
        #expect(visible.contains(window.frame))
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
        controller.setDeviceBezelVisible(false)
        #expect(window.styleMask.contains(.resizable))
        #expect(!controller.canSetScale(.pointAccurate))
        #expect(controller.canSetScale(.fitScreen))
    }

    @Test func showDeviceBezelsIsAnAppWidePreference() throws {
        _ = NSApplication.shared
        // Bezels hidden from another window: like Simulator.app, a new window
        // opens without its bezel, so it is resizable and takes the display's
        // size without the bezel.
        let preferences = MemoryPreferences()
        preferences.set(false, forKey: HostPreferences.showChrome)
        let display = TestDisplay()
        display.naturalSize = NSSize(width: 200, height: 300)
        display.bezel = NSSize(width: 20, height: 20)
        display.bezelPadding = NSSize(width: 9, height: 0)
        let controller = try makeController(display, preferences: preferences)
        defer { controller.invalidate() }
        #expect(display.chromePadding == nil)
        #expect(controller.window?.styleMask.contains(.resizable) == true)
        #expect(display.view.frame.size == NSSize(width: 200, height: 300))
        // The menu's checkmark shows the preference, also without a device window.
        let menus = MenuController(application: nil)
        menus.install()
        defer { NSApp.mainMenu = nil }
        let item = try #require(NSApp.mainMenu?.items.first { $0.title == "Window" }?.submenu?.items
            .first { $0.title == "Show Device Bezels" })
        let saved = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[HostPreferences.showChrome]
        defer { UserDefaults.standard.set(saved, forKey: HostPreferences.showChrome) }
        for shows in [false, true] {
            UserDefaults.standard.set(shows, forKey: HostPreferences.showChrome)
            _ = menus.validateMenuItem(item)
            #expect(item.state == (shows ? .on : .off))
        }
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
        controller.setDeviceBezelVisible(false)
        #expect(display.renderScale == 1)
        #expect(DeviceCommand.command(.pointAccurate).state?(controller) == .on)
        #expect(showsDisplay(NSSize(width: 360, height: 400)))
        #expect(window.frame.origin == origin)
        #expect(window.styleMask.contains(.resizable))
        // Showing it keeps a scale chosen without the bezel and grows the window.
        controller.perform(.pointAccurate)
        controller.setDeviceBezelVisible(true)
        #expect(display.renderScale == 1)
        #expect(showsDisplay(NSSize(width: 400, height: 460)))
        #expect(window.frame.origin == origin)
        #expect(!window.styleMask.contains(.resizable))
        // The window may rise above the screen by the bezel's top padding at
        // the display's scale, and no further once the bezel is hidden.
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

    @Test func draggingACornerOfTheBezelScalesTheDisplayAroundTheOppositeCorner() throws {
        let (controller, display) = try makeBezelController()
        defer { controller.invalidate() }
        let window = try #require(controller.window)
        let visible = try #require(window.screen?.visibleFrame)
        #expect(!window.styleMask.contains(.resizable))
        // A drag elsewhere on the display resizes nothing.
        controller.perform(.pointAccurate)
        let middle = window.convertPoint(toScreen: display.view.convert(
            NSPoint(x: display.view.bounds.midX, y: display.view.bounds.midY), to: nil))
        try drag(window, from: middle, by: NSSize(width: 30, height: -55))
        #expect(display.renderScale == 1)
        for corner in [DisplayResizeRect.Corner.lowerLeft, .lowerRight, .upperRight, .upperLeft] {
            controller.perform(.pointAccurate)
            window.setFrameOrigin(NSPoint(x: (visible.midX - window.frame.width / 2).rounded(),
                                          y: (visible.midY - window.frame.height / 2).rounded()))
            let start = window.frame
            // Moving the corner outward by a quarter of the display's 120 by
            // 220 points, a quarter larger, as Simulator.app's DeviceWindow does.
            let outward = NSSize(width: corner.isLeft ? -30 : 30, height: corner.isLower ? -55 : 55)
            try drag(window, from: try point(of: corner, in: display), by: outward) {
                #expect(display.isResizing)
                #expect(display.renderScale == 1.25)
                // The window takes the display's size, 12 points below its
                // header, and keeps the display's opposite corner.
                #expect(window.contentLayoutRect.size
                    == NSSize(width: display.view.frame.width, height: display.view.frame.height + 12))
                #expect(corner.isLeft ? window.frame.maxX == start.maxX : window.frame.minX == start.minX)
                #expect(corner.isLower ? window.frame.maxY == start.maxY : window.frame.minY == start.minY)
            }
            #expect(!display.isResizing)
            #expect(display.renderScale == 1.25)
        }
    }

    @Test func aBezelDragStopsAtTheDevicesMinimumAndTheScreensEdge() throws {
        let (controller, display) = try makeBezelController()
        defer { controller.invalidate() }
        let window = try #require(controller.window)
        let visible = try #require(window.screen?.visibleFrame)
        controller.perform(.pointAccurate)
        window.setFrameOrigin(NSPoint(x: visible.midX - window.frame.width / 2, y: visible.midY - window.frame.height / 2))
        try drag(window, from: try point(of: .lowerRight, in: display), by: NSSize(width: -1000, height: 1000)) {
            // An iPhone's minimum, which the fixed scales also keep.
            #expect(display.renderScale == 0.4)
        }
        try drag(window, from: try point(of: .lowerRight, in: display), by: NSSize(width: 10_000, height: -10_000)) {
            // The dragged corner stops at an edge of the screen's visible frame.
            let frame = window.frame
            #expect(frame.maxX <= visible.maxX + 0.001 && frame.minY >= visible.minY - 0.001)
            #expect(abs(frame.maxX - visible.maxX) < 0.001 || abs(frame.minY - visible.minY) < 0.001)
        }
    }

    @Test func aWindowThatABezelDragLeavesOffTheScreenComesBackWithinReach() throws {
        let (controller, display) = try makeBezelController()
        defer { controller.invalidate() }
        let window = try #require(controller.window)
        let visible = try #require(window.screen?.visibleFrame)
        controller.perform(.pointAccurate)
        window.setFrameOrigin(NSPoint(x: visible.maxX - 50, y: visible.minY - window.frame.height + 50))
        let reach = visible.insetBy(dx: 128, dy: 128)
        try #require(!window.frame.intersects(reach))
        try drag(window, from: try point(of: .upperLeft, in: display), by: NSSize(width: -30, height: 55)) {
            #expect(!window.frame.intersects(reach))
        }
        // Like Simulator.app, the window moves until it reaches 128 points
        // into the screen's visible frame.
        #expect(abs(window.frame.minX - reach.maxX) < 0.001 && abs(window.frame.maxY - reach.minY) < 0.001)
    }

    @Test func theBezelShowsResizeCursorsOutsideFullScreen() throws {
        let (controller, display) = try makeBezelController()
        defer { controller.invalidate() }
        let window = try #require(controller.window)
        #expect(display.showsResizeCursors)
        controller.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification, object: window))
        #expect(!display.showsResizeCursors)
        // In full screen, where the display fits the window, a drag on a
        // corner of the bezel resizes nothing.
        try drag(window, from: try point(of: .lowerRight, in: display), by: NSSize(width: 30, height: -55)) {
            #expect(!display.isResizing)
        }
        controller.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: window))
        #expect(display.showsResizeCursors)
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

    @Test func aRestartShowsTheBezelAsShowDeviceBezelsSays() async throws {
        let preferences = MemoryPreferences()
        preferences.set(false, forKey: HostPreferences.showChrome)
        func display(showingBezel shows: Bool) -> TestDisplay {
            let display = TestDisplay()
            display.naturalSize = NSSize(width: 200, height: 300)
            display.bezel = NSSize(width: 20, height: 20)
            display.bezelPadding = NSSize(width: 9, height: 0)
            display.showsBezel = shows
            return display
        }
        let controller = try makeController(display(showingBezel: true), preferences: preferences)
        defer { controller.invalidate() }
        controller.showWindow(nil)
        let window = try #require(controller.window)
        // Like Simulator.app, the device's next display after a restart shows
        // the bezel as Show Device Bezels says, whatever it shows when it is
        // created, and the window follows it.
        await controller.prepareForRestart()
        let hidden = display(showingBezel: true)
        controller.reconnect(try makeSession(hidden))
        #expect(hidden.chromePadding == nil)
        #expect(window.styleMask.contains(.resizable))
        #expect(hidden.view.frame.size == NSSize(width: 200, height: 300))
        preferences.set(true, forKey: HostPreferences.showChrome)
        await controller.prepareForRestart()
        let shown = display(showingBezel: false)
        controller.reconnect(try makeSession(shown))
        #expect(shown.chromePadding == NSSize(width: 9, height: 0))
        #expect(!window.styleMask.contains(.resizable))
        #expect(shown.showsResizeCursors)
        #expect(shown.view.frame.size == NSSize(width: 220, height: 320))
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
        // Graphics Quality Override needs its feature, and Slow Animations
        // without its feature toggles the frontmost app.
        #expect(try visibleTitles("Debug") == ["Toggle Slow Animations in Frontmost App", "-", "Color Blended Layers",
                                                "Color Copied Images", "Color Misaligned Images",
                                                "Color Off-screen Rendered", "-", "Open System Log…",
                                                "Simulate Memory Warning", "-", "Show Parallel Testing Devices"])
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

    @Test func debugMenuFollowsSimulatorAppOrderAndShortcuts() throws {
        _ = NSApplication.shared
        let menus = MenuController(application: nil)
        menus.install()
        defer { NSApp.mainMenu = nil }
        let debug = try #require(NSApp.mainMenu?.items.first { $0.title == "Debug" }?.submenu)
        let features = [DeviceCapabilities.slowMotionStateful, DeviceCapabilities.graphicsQualityOverride]
        menus.updateVisibility(in: debug, for: DeviceCapabilities(family: .iPhone, runtimeVersion: 0x1B_00_00,
                                                                  supportsFeature: { features.contains($0) }))
        #expect(debug.items.filter { !$0.isHidden }.map { $0.isSeparatorItem ? "-" : $0.title } == [
            "Toggle Slow Animations in Frontmost App", "Graphics Quality Override", "-", "Color Blended Layers",
            "Color Copied Images", "Color Misaligned Images", "Color Off-screen Rendered", "-", "Open System Log…",
            "Simulate Memory Warning", "-", "Show Parallel Testing Devices",
        ])
        let quality = try #require(debug.items.first { $0.title == "Graphics Quality Override" }?.submenu)
        #expect(quality.items.map(\.title) == ["Device Default", "Low Quality", "High Quality"])
        let shortcuts = debug.items.filter { !$0.keyEquivalent.isEmpty }
        #expect(shortcuts.map(\.title) == ["Open System Log…", "Simulate Memory Warning"])
        #expect(shortcuts.map(\.keyEquivalent) == ["/", "m"])
        #expect(shortcuts.map(\.keyEquivalentModifierMask) == [.command, [.command, .shift]])
    }

    @Test func slowAnimationsAndGraphicsQualityFollowTheAppsSettings() throws {
        let keys = [HostPreferences.slowMotionAnimation, HostPreferences.graphicsQualityOverride]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) } }
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        let slowMotion = "com.apple.UIKit.SimulatorSlowMotionAnimationState"
        let quality = "com.apple.UIKit.ForceGraphicsQuality"
        let features: Set = [DeviceCapabilities.slowMotionStateful, DeviceCapabilities.graphicsQualityOverride]
        let display = TestDisplay()
        let controller = try makeController(display, features: features)
        defer { controller.invalidate() }
        let slow = DeviceCommand.command(.toggleSlowAnimations)
        #expect(slow.stateTitle?(controller) == "Slow Animations" && slow.state?(controller) == .off)
        controller.perform(.toggleSlowAnimations)
        #expect(slow.state?(controller) == .on)
        controller.perform(.graphicsQualityLow)
        #expect(DeviceCommand.command(.graphicsQualityLow).state?(controller) == .on)
        #expect(DeviceCommand.command(.graphicsQualityDefault).state?(controller) == .off)
        #expect(display.notificationStates == [slowMotion: 1, quality: 10])
        #expect(display.postedNotifications == [slowMotion, quality])

        // A device that refuses the state keeps the app's setting unchanged.
        display.notificationError = HostError.operation("refused")
        #expect(throws: (any Error).self) { try controller.session.toggleSlowAnimations() }
        #expect(slow.state?(controller) == .on)

        // Connecting applies the settings, but not the default quality.
        let connected = TestDisplay()
        try makeSession(connected, features: features).applyDebugSettings()
        #expect(connected.notificationStates == [slowMotion: 1, quality: 10])
        UserDefaults.standard.set(GraphicsQuality.deviceDefault.rawValue, forKey: HostPreferences.graphicsQualityOverride)
        let older = TestDisplay()
        try makeSession(older, features: [DeviceCapabilities.graphicsQualityOverride]).applyDebugSettings()
        #expect(older.postedNotifications.isEmpty)

        // A guest that does not keep slow animations gets Simulator.app's
        // toggle, which still alternates the state.
        let other = try makeController(older, features: [])
        defer { other.invalidate() }
        #expect(slow.stateTitle?(other) == "Toggle Slow Animations in Frontmost App" && slow.state?(other) == .off)
        other.perform(.toggleSlowAnimations)
        #expect(older.notificationStates == [slowMotion: 0])
        #expect(!UserDefaults.standard.bool(forKey: HostPreferences.slowMotionAnimation))
    }

    @Test func graphicsQualityAppliesAtOnceUnlessAnAppleTVRestartsItsSystemUI() async throws {
        let key = HostPreferences.graphicsQualityOverride
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("arguments"), simctl = directory.appendingPathComponent("simctl")
        try """
            #!/bin/sh
            printf '%s\\n' "$*" >> "\(log.path)"
            """.write(to: simctl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: simctl.path)
        let quality = "com.apple.UIKit.ForceGraphicsQuality"
        for family in [DeviceCapabilities.Family.tv, .iPhone] {
            let display = TestDisplay()
            let controller = try makeController(display, family: family,
                                                features: [DeviceCapabilities.graphicsQualityOverride], simctl: simctl)
            defer { controller.invalidate() }
            // While another device-tool operation runs, Simulator.app still
            // applies the choice; only the Apple TV's restart has to wait.
            #expect(controller.session.reserve())
            #expect(DeviceCommand.command(.graphicsQualityHigh).isEnabled(controller) == (family != .tv))
            controller.perform(.graphicsQualityHigh)
            #expect(display.notificationStates[quality] == (family == .tv ? nil : 100))
            controller.session.release()
            if family == .tv { controller.perform(.graphicsQualityHigh) }
            for _ in 0..<200 where controller.session.isBusy { try await Task.sleep(for: .milliseconds(10)) }
            #expect(display.notificationStates[quality] == 100)
        }
        #expect(try String(contentsOf: log, encoding: .utf8) == "spawn test-device launchctl stop com.apple.PineBoard\n")
    }

    @Test func colorOptionsShowTheDeviceStateAndReportDroppedChanges() throws {
        let display = TestDisplay()
        let controller = try makeController(display)
        defer { controller.invalidate() }
        controller.perform(.colorBlendedLayers)
        controller.perform(.colorOffscreenRendered)
        #expect(display.caDebugOptions.map(\.rawValue).sorted() == [2, 17])
        let blended = DeviceCommand.command(.colorBlendedLayers)
        #expect(blended.state?(controller) == .on && DeviceCommand.command(.colorCopiedImages).state?(controller) == .off)
        // The checkmark is read from the device, which another host can change.
        display.caDebugOptions.remove(.colorBlendedLayers)
        #expect(blended.state?(controller) == .off)
        // CoreSimulator does not report a dropped change; reading back does.
        display.droppedCADebugOptions = [.colorMisalignedImages]
        #expect(throws: (any Error).self) { try controller.session.toggle(.colorMisalignedImages) }
    }

    @Test func memoryWarningRewritesTheTriggerFileInPlaceAndReportsFailures() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let trigger = directory.appendingPathComponent("memory_warning_simulation")
        try Data("earlier".utf8).write(to: trigger)
        let file = try FileManager.default.attributesOfItem(atPath: trigger.path)[.systemFileNumber] as? Int
        let display = TestDisplay()
        display.memoryWarningURL = trigger
        let controller = try makeController(display)
        defer { controller.invalidate() }
        controller.perform(.simulateMemoryWarning)
        let attributes = try FileManager.default.attributesOfItem(atPath: trigger.path)
        #expect(attributes[.size] as? Int == 0)
        // Like CoreSimulator's write, the file is truncated rather than replaced.
        #expect(attributes[.systemFileNumber] as? Int == file)
        display.memoryWarningURL = directory.appendingPathComponent("missing/memory_warning_simulation")
        #expect(throws: (any Error).self) { try controller.session.simulateMemoryWarning() }
    }

    @Test func openSystemLogOpensTheDevicesLogOrReportsItsAbsence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let display = TestDisplay()
        display.logFolder = directory
        var opened: [URL] = []
        let controller = try makeController(display, openLog: { opened.append($0) })
        defer { controller.invalidate() }
        await #expect(throws: (any Error).self) { try await controller.session.openSystemLog() }
        #expect(opened.isEmpty)
        let log = directory.appendingPathComponent("system.log")
        try Data().write(to: log)
        controller.perform(.openSystemLog)
        for _ in 0..<200 where opened.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(opened == [log])
    }

    @Test func gpuSelectionRewritesCoreSimulatorsPolicyAsSimulatorAppDoes() throws {
        _ = NSApplication.shared
        let defaults = try #require(MemoryDefaults(suiteName: nil))
        let menus = MenuController(application: nil, gpuPolicy: GPUPolicy(defaults: defaults))
        menus.install()
        defer { NSApp.mainMenu = nil }
        let file = try #require(NSApp.mainMenu?.items.first { $0.title == "File" }?.submenu)
        let titles = file.items.map { $0.isSeparatorItem ? "-" : $0.title }
        let index = try #require(titles.firstIndex(of: "GPU Selection"))
        #expect(titles[(index - 2)...(index + 2)] == ["Stop Recording", "-", "GPU Selection", "-", "Install App or Import Media…"])
        let gpu = try #require(file.items[index].submenu)
        #expect(gpu.items.map { $0.isSeparatorItem ? "-" : $0.title } == [
            "Automatic", "Prefer Integrated GPU", "Prefer Discrete GPU", "-", "Use External GPU When Available",
        ])
        let items = gpu.items.filter { !$0.isSeparatorItem }
        func checked() -> [String] { items.filter { menus.validateMenuItem($0) && $0.state == .on }.map(\.title) }
        func choose(_ title: String) throws -> [String]? {
            let item = try #require(items.first { $0.title == title })
            #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
            return defaults.stringArray(forKey: GPUPolicy.key)
        }
        // Unset, the policy is Simulator.app's default order, led by automatic.
        #expect(checked() == ["Automatic"])
        #expect(try choose("Prefer Integrated GPU") == ["lowPower", "discrete", "external"])
        #expect(try choose("Use External GPU When Available") == ["external", "lowPower", "discrete"])
        #expect(checked() == ["Prefer Integrated GPU", "Use External GPU When Available"])
        #expect(try choose("Prefer Discrete GPU") == ["external", "discrete", "lowPower"])
        #expect(try choose("Automatic") == ["external", "automatic"])
        #expect(try choose("Use External GPU When Available") == ["automatic", "external"])
        #expect(checked() == ["Automatic"])
        // An older single string is an order of one; kinds the menu does not
        // offer are dropped.
        defaults.set("headless", forKey: GPUPolicy.key)
        #expect(checked().isEmpty)
        #expect(try choose("Prefer Discrete GPU") == ["discrete", "lowPower", "external"])
        // Without a policy, the choices are unavailable.
        let unavailable = MenuController(application: nil)
        #expect(!items.contains { unavailable.validateMenuItem($0) })
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
                                family: DeviceCapabilities.Family = .iPhone,
                                features: Set<String> = [DeviceCapabilities.displayRotation],
                                framebufferMask: Bool = false,
                                simctl: URL = DeviceTools.simctl,
                                devicectl: URL = DeviceTools.devicectl,
                                recordingProcess: ((URL, DeviceTools.ScreenMask) -> Process)? = nil,
                                screenPointsPerInch: Double? = nil,
                                device identifier: String = "test-device",
                                preferences: MemoryPreferences = MemoryPreferences(),
                                openLog: @escaping (URL) async throws -> Void = { _ in },
                                onClose: @escaping (DeviceWindowController, DeviceLifetimeChoice?) -> Void = { _, _ in },
                                onRestart: @escaping (DeviceWindowController, Bool) -> Void = { _, _ in })
        throws -> DeviceWindowController {
        let session = try makeSession(display, family: family, features: features, framebufferMask: framebufferMask,
                                      simctl: simctl, devicectl: devicectl, recordingProcess: recordingProcess,
                                      openLog: openLog, screenPointsPerInch: screenPointsPerInch, device: identifier)
        return try DeviceWindowController(session: session, preferences: preferences, onClose: onClose,
                                          onRestart: onRestart)
    }

    /// A shown window whose display, 100 by 200 points at scale 1, has a
    /// 10-point bezel without top padding, like an iPhone's.
    private func makeBezelController() throws -> (DeviceWindowController, TestDisplay) {
        let display = TestDisplay()
        display.naturalSize = NSSize(width: 100, height: 200)
        display.bezel = NSSize(width: 20, height: 20)
        display.bezelPadding = NSSize(width: 9, height: 0)
        let controller = try makeController(display)
        controller.showWindow(nil)
        return (controller, display)
    }

    /// The middle of a resize corner of `display`'s bezel, on the screen.
    private func point(of corner: DisplayResizeRect.Corner, in display: TestDisplay) throws -> NSPoint {
        let rect = try #require(display.resizeRects.first { $0.corner == corner }).rect
        let window = try #require(display.view.window)
        return window.convertPoint(toScreen: display.view.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil))
    }

    /// Presses the mouse at `start` on the screen, drags it by `offset`, runs
    /// `during`, and releases it. `window` receives the events as AppKit
    /// passes it the events that no view handles, such as a press on a corner
    /// of the bezel.
    private func drag(_ window: NSWindow, from start: NSPoint, by offset: NSSize,
                      during: () throws -> Void = {}) throws {
        func event(_ type: NSEvent.EventType, at location: NSPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type, location: window.convertPoint(fromScreen: location), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1))
        }
        let end = NSPoint(x: start.x + offset.width, y: start.y + offset.height)
        window.mouseDown(with: try event(.leftMouseDown, at: start))
        window.mouseDragged(with: try event(.leftMouseDragged, at: end))
        try during()
        window.mouseUp(with: try event(.leftMouseUp, at: end))
    }

    private func makeSession(_ display: TestDisplay,
                             family: DeviceCapabilities.Family = .iPhone,
                             features: Set<String> = [DeviceCapabilities.displayRotation],
                             framebufferMask: Bool = false,
                             simctl: URL = DeviceTools.simctl,
                             devicectl: URL = DeviceTools.devicectl,
                             recordingProcess: ((URL, DeviceTools.ScreenMask) -> Process)? = nil,
                             openLog: @escaping (URL) async throws -> Void = { _ in },
                             screenPointsPerInch: Double? = nil,
                             device identifier: String = "test-device") throws -> DeviceSession {
        DeviceSession(
            device: availableDevice(identifier, "Test iPhone", runtime: "iOS", state: 3),
            capabilities: DeviceCapabilities(family: family, runtimeVersion: 0x1B_00_00,
                                             supportsFeature: { features.contains($0) },
                                             hasFramebufferMask: framebufferMask,
                                             screenPointsPerInch: screenPointsPerInch),
            display: display,
            tools: try DeviceTools(identifier: "test-device", xcodeURL: URL(fileURLWithPath: "/Applications/Xcode.app"),
                                   simctl: simctl, devicectl: devicectl),
            recordingProcess: recordingProcess, openLog: openLog)
    }
}

/// Preferences kept in memory, so that tests leave the app's defaults alone.
private final class MemoryPreferences: PreferenceStore {
    var values: [String: Any] = [:]
    func object(forKey defaultName: String) -> Any? { values[defaultName] }
    func bool(forKey defaultName: String) -> Bool { values[defaultName] as? Bool ?? false }
    func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
}

/// The app's user defaults under keys of one store, which keeps its values in
/// the registration domain, so that they are read as `UserDefaults` reads
/// them but never saved.
private final class RegisteredDefaults: PreferenceStore {
    private let prefix = "NeoSimulatorTests.\(UUID().uuidString)."
    func object(forKey defaultName: String) -> Any? { UserDefaults.standard.object(forKey: prefix + defaultName) }
    func bool(forKey defaultName: String) -> Bool { UserDefaults.standard.bool(forKey: prefix + defaultName) }
    /// Registers `value`; nil, which the registration domain cannot remove,
    /// leaves the key as it is.
    func set(_ value: Any?, forKey defaultName: String) {
        if let value { UserDefaults.standard.register(defaults: [prefix + defaultName: value]) }
    }
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
/// Defaults kept in memory, so that tests never write CoreSimulator's domain.
/// A scratch suite would leave its property list behind.
private final class MemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
    override func removeObject(forKey defaultName: String) { values[defaultName] = nil }
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
    /// Thrown when a notification state is set.
    var notificationError: Error?
    func setNotificationState(_ name: String, to state: UInt64) throws {
        if let notificationError { throw notificationError }
        notificationStates[name] = state
    }
    func contentSizeCategory() throws -> Int { contentSize }
    func setContentSizeCategory(_ category: Int) throws { contentSize = category }
    func increaseContrastMode() throws -> Int { contrastMode }
    func setIncreaseContrast(_ enabled: Bool) throws { contrastMode = enabled ? 2 : 1 }
    func triggerCloudSync() async throws {}
    var logFolder = URL(fileURLWithPath: "/nonexistent")
    var memoryWarningURL = URL(fileURLWithPath: "/nonexistent/memory_warning_simulation")
    var caDebugOptions: Set<CADebugOption> = []
    /// Options whose changes the device drops, as CoreSimulator can without an error.
    var droppedCADebugOptions: Set<CADebugOption> = []
    func logDirectory() throws -> URL { logFolder }
    func memoryWarningFile() throws -> URL { memoryWarningURL }
    func caDebugOption(_ option: CADebugOption) throws -> Bool { caDebugOptions.contains(option) }
    func setCADebugOption(_ option: CADebugOption, enabled: Bool) throws {
        guard !droppedCADebugOptions.contains(option) else { return }
        if enabled { caDebugOptions.insert(option) } else { caDebugOptions.remove(option) }
    }
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
    /// Whether the display shows its bezel, as SimDisplayView's
    /// showDeviceChrome says; a new display shows it.
    var showsBezel = true
    private var outerSize: NSSize {
        showsBezel ? NSSize(width: naturalSize.width + bezel.width, height: naturalSize.height + bezel.height) : naturalSize
    }
    func setChromeVisible(_ visible: Bool) { showsBezel = visible }
    /// A 20-point square at each corner of the bezel, as SimulatorKit places
    /// resize corners in the display's coordinates.
    var resizeRects: [DisplayResizeRect] {
        guard chromePadding != nil else { return [] }
        let size = size(for: renderScale)
        return [DisplayResizeRect.Corner.lowerLeft, .lowerRight, .upperRight, .upperLeft].map {
            DisplayResizeRect(corner: $0, rect: NSRect(x: $0.isLeft ? 0 : size.width - 20,
                                                       y: $0.isLower ? 0 : size.height - 20, width: 20, height: 20))
        }
    }
    private(set) var showsResizeCursors = false
    func setShowsResizeCursors(_ shows: Bool) { showsResizeCursors = shows }
    /// Whether the display is between SimDisplayView's beginResize() and endResize().
    private(set) var isResizing = false
    func setRenderScale(_ scale: CGFloat) {
        renderScale = scale
        view.setFrameSize(size(for: scale))
    }
    func size(for scale: CGFloat) -> NSSize { NSSize(width: outerSize.width * scale, height: outerSize.height * scale) }
    func scale(for size: NSSize) -> CGFloat { min(size.width / outerSize.width, size.height / outerSize.height) }
    func setActive(_ active: Bool) { activations.append(active) }
    func setKeyboardEnabled(_ enabled: Bool) { keyboard.append(enabled) }
    var rotations: [Double] = []
    /// Called with each angle the display turns to, as SimulatorKit then
    /// gives the display its rotated size.
    var onRotation: (Double) -> Void = { _ in }
    func setRotation(degrees: Double) {
        rotations.append(degrees)
        onRotation(degrees)
    }
    func beginResize() { isResizing = true }
    func resize(to size: NSSize) { setRenderScale(scale(for: size)) }
    func endResize() { isResizing = false }
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

    @Test func aBezelDragLeavesTheWindowWithinReachOfItsScreen() {
        let visible = NSRect(x: 0, y: 0, width: 1000, height: 800)
        func origin(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            WindowScale.origin(of: NSRect(x: x, y: y, width: 300, height: 400), reaching: visible)
        }
        // A window that reaches 128 points into the visible frame stays,
        // also mostly past its edges.
        #expect(origin(-150, 600) == NSPoint(x: -150, y: 600))
        // Otherwise it moves along each axis until it reaches that far.
        #expect(origin(900, 300) == NSPoint(x: 872, y: 300))
        #expect(origin(-250, 300) == NSPoint(x: -172, y: 300))
        #expect(origin(300, 700) == NSPoint(x: 300, y: 672))
        #expect(origin(300, -350) == NSPoint(x: 300, y: -272))
    }

    @Test func showDeviceBezelsReadsShowChromeAsSimulatorDoes() {
        // Simulator.app reads ShowChrome with boolForKey:, which reads a
        // value that `defaults write` saved as a string by its text.
        let defaults = RegisteredDefaults()
        let values: [(Any, Bool)] = [("NO", false), ("0", false), ("false", false), ("YES", true), ("1", true),
                                     (false, false), (true, true)]
        for (value, shows) in values {
            defaults.set(value, forKey: HostPreferences.showChrome)
            #expect(defaults.showsDeviceBezels == shows)
        }
        // Without a value, as before the app registers its default, it is on.
        #expect(RegisteredDefaults().showsDeviceBezels)
    }

    @Test func windowGeometryIsSavedForEachArrangementOfScreens() throws {
        let preferences = MemoryPreferences()
        let laptop = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let two = [laptop, NSRect(x: -565, y: 982, width: 2560, height: 1440)]
        let none = preferences.windowGeometry(forDevice: "A", screens: two)
        #expect(none.center == nil && none.scale == nil)
        preferences.setWindowGeometry(center: NSPoint(x: 10.5, y: -20), scale: 1.5, forDevice: "A", screens: two)
        preferences.setWindowGeometry(center: NSPoint(x: 300, y: 400), scale: 0.5, forDevice: "B", screens: two)
        preferences.setWindowGeometry(center: NSPoint(x: 1, y: 2), scale: nil, forDevice: "B", screens: two)
        // Simulator.app's keys: the arrangement of screens is a UUID in
        // ScreenConfigurations, which names the window's center and scale in
        // DevicePreferences[UDID].SimulatorWindowGeometry.
        let configurations = preferences.values["ScreenConfigurations"] as? [String: [String]]
        let (name, frames) = try #require(configurations?.first)
        #expect(configurations?.count == 1 && UUID(uuidString: name)?.uuidString == name)
        #expect(frames == ["{{0, 0}, {1512, 982}}", "{{-565, 982}, {2560, 1440}}"])
        let devices = preferences.values["DevicePreferences"] as? [String: [String: [String: [String: Any]]]]
        #expect(devices?["A"]?["SimulatorWindowGeometry"]?[name]?["WindowScale"] as? Double == 1.5)
        #expect(devices?["A"]?["SimulatorWindowGeometry"]?[name]?["WindowCenter"] as? String == "{10.5, -20}")
        // A later save replaces what was saved in the arrangement.
        #expect(devices?["B"]?["SimulatorWindowGeometry"]?[name]?["WindowScale"] == nil)
        #expect(devices?["B"]?["SimulatorWindowGeometry"]?[name]?["WindowCenter"] as? String == "{1, 2}")
        // The same screens in another order are the same arrangement.
        let saved = preferences.windowGeometry(forDevice: "A", screens: two.reversed())
        #expect(saved.center == NSPoint(x: 10.5, y: -20) && saved.scale == 1.5)
        // Fewer screens, or a screen moved, are other arrangements, which
        // have no geometry until a window closes there and are saved too.
        let alone = [laptop], moved = [laptop, NSRect(x: 1512, y: 0, width: 2560, height: 1440)]
        for screens in [alone, moved] {
            let other = preferences.windowGeometry(forDevice: "A", screens: screens)
            #expect(other.center == nil && other.scale == nil)
        }
        #expect((preferences.values["ScreenConfigurations"] as? [String: [String]])?.count == 3)
        preferences.setWindowGeometry(center: NSPoint(x: 5, y: 6), scale: 2, forDevice: "A", screens: alone)
        #expect(preferences.windowGeometry(forDevice: "A", screens: alone).center == NSPoint(x: 5, y: 6))
        #expect(preferences.windowGeometry(forDevice: "A", screens: two).center == NSPoint(x: 10.5, y: -20))
        let current = preferences.screenConfiguration(for: alone)
        for invalid: Any in [0, -1, "1.5", Double.nan] {
            preferences.values["DevicePreferences"] = ["A": ["SimulatorWindowGeometry": [current: ["WindowScale": invalid]]]]
            #expect(preferences.windowGeometry(forDevice: "A", screens: alone).scale == nil)
        }
        // Like Simulator.app, the zero point, which an unreadable string also
        // gives, is no center.
        for invalid: Any in ["{0, 0}", "center", 12] {
            preferences.values["DevicePreferences"] = ["A": ["SimulatorWindowGeometry": [current: ["WindowCenter": invalid]]]]
            #expect(preferences.windowGeometry(forDevice: "A", screens: alone).center == nil)
        }
        // An entry that is not a UUID names no arrangement. Like
        // Simulator.app, entries that are not all lists of strings are
        // replaced by the new arrangement.
        preferences.values["ScreenConfigurations"] = ["laptop": ["{{0, 0}, {1512, 982}}"]]
        let named = preferences.screenConfiguration(for: alone)
        #expect(named != "laptop" && UUID(uuidString: named) != nil)
        preferences.values["ScreenConfigurations"] = [current: ["{{0, 0}, {1512, 982}}"], "other": [1]] as [String: Any]
        let replaced = preferences.screenConfiguration(for: alone)
        #expect(replaced != current)
        #expect(preferences.values["ScreenConfigurations"] as? [String: [String]] == [replaced: ["{{0, 0}, {1512, 982}}"]])
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
        // otherwise leaves the frame to AppKit, which shrinks a resizable
        // window taller than the screen.
        let screen = try #require(NSScreen.screens.first)
        let mask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
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
