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

    @Test func theSaveScreenButtonStopsARecordingAsInSimulatorApp() async throws {
        // The first recording runs until it is stopped and then takes half a
        // second to finish; the second fails.
        var recordings = 0
        let controller = try makeController(TestDisplay()) { _, _ in
            recordings += 1
            return Self.recorder(then: recordings == 1 ? "trap 'sleep 0.5; exit 0' INT; while :; do sleep 0.05; done"
                                                       : "sleep 0.3; exit 1")
        }
        defer { controller.invalidate() }
        let toolbar = try #require(controller.window?.toolbar)
        let items = toolbar.items.map(\.itemIdentifier.rawValue)
        #expect(items == ["NSToolbarFlexibleSpaceItem", "home", "saveScreen", "rotateRight", "NSToolbarFlexibleSpaceItem"])
        let item = try #require(toolbar.items.first { $0.itemIdentifier.rawValue == "saveScreen" })
        func shows(_ symbol: String, _ label: String) -> Bool {
            item.toolTip == label && item.image?.accessibilityDescription == label && item.image?.tiffRepresentation
                == NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.tiffRepresentation
        }
        #expect(shows("camera.on.rectangle", "Save Screen"))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try controller.session.startRecording(to: .file(directory.appendingPathComponent("Recording.mov")), mask: .ignored)
        let recording = try #require(controller.session.recording)
        // Like Simulator.app's, the Save Screen button shows `stop.circle`,
        // untinted, and stops the recording; the toolbar adds no item, and the
        // item keeps its label.
        try await wait { shows("stop.circle", "Stop Recording") }
        #expect(shows("stop.circle", "Stop Recording"))
        #expect(item.label == "Save Screen")
        #expect(item.isEnabled)
        #expect(toolbar.items.map(\.itemIdentifier.rawValue) == items)
        #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
        try #require(recording.isStopping)
        // It is Save Screen again as soon as the recording stops, while the
        // movie is still being finished.
        try await wait { shows("camera.on.rectangle", "Save Screen") }
        #expect(shows("camera.on.rectangle", "Save Screen"))
        #expect(controller.session.recording === recording)
        #expect(item.isEnabled)
        try await recording.waitUntilFinished()
        try await wait { controller.session.recording == nil }
        #expect(shows("camera.on.rectangle", "Save Screen"))
        #expect(toolbar.items.map(\.itemIdentifier.rawValue) == items)

        // A recording that fails also gives the button back.
        try controller.session.startRecording(to: .file(directory.appendingPathComponent("Failed.mov")), mask: .ignored)
        try await wait { shows("stop.circle", "Stop Recording") }
        #expect(shows("stop.circle", "Stop Recording"))
        try await wait { controller.session.recording == nil }
        #expect(controller.session.recording == nil)
        try await wait { shows("camera.on.rectangle", "Save Screen") }
        #expect(shows("camera.on.rectangle", "Save Screen"))
    }

    @Test func theToolbarsButtonsShowTheirOptionAlternatesWhileThePointerIsOverTheToolbar() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // A devicectl stand-in that logs its arguments and reports portrait.
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
        /// The way the last rotation turned the device.
        func rotation() async throws -> String? {
            for _ in 0..<300 where controller.session.isBusy { try await Task.sleep(for: .milliseconds(10)) }
            let rotate = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").last { $0.contains(" rotate ") }
            return rotate?.split(separator: " ").dropLast().last.map(String.init)
        }
        // The faces of Simulator.app's toolbar nib.
        #expect(pointer.faces == ButtonFace.normal)
        // Away from the toolbar, Option changes nothing.
        pointer.hold(.option)
        #expect(pointer.faces == ButtonFace.normal)
        // Over the toolbar, Save Screen and Rotate show their alternates while
        // Option is down, also with another modifier. Home has none.
        pointer.hold([])
        pointer.enter()
        #expect(pointer.faces == ButtonFace.normal)
        pointer.hold(.option)
        #expect(pointer.faces == ButtonFace.optionAlternates)
        pointer.hold([.option, .shift])
        #expect(pointer.faces == ButtonFace.optionAlternates)
        pointer.hold(.shift)
        #expect(pointer.faces == ButtonFace.normal)
        // A click performs the alternate: Rotate turns the device left.
        pointer.hold(.option)
        #expect(try pointer.click(.rotateRight))
        #expect(try await rotation() == "left")
        // Leaving the toolbar gives the buttons their own faces back, and
        // Option no longer switches them.
        pointer.exit()
        #expect(pointer.faces == ButtonFace.normal)
        pointer.hold([])
        pointer.hold(.option)
        #expect(pointer.faces == ButtonFace.normal)
        #expect(try pointer.click(.rotateRight))
        #expect(try await rotation() == "right")
        // Entering with Option already down shows the alternates at once.
        pointer.enter()
        #expect(pointer.faces == ButtonFace.optionAlternates)
        pointer.hold([])
        #expect(pointer.faces == ButtonFace.normal)
    }

    @Test func aRecordingKeepsSaveScreenAsStopRecordingWhateverOptionDoes() async throws {
        let controller = try makeController(TestDisplay()) { _, _ in
            Self.recorder(then: "trap 'sleep 0.3; exit 0' INT; while :; do sleep 0.05; done")
        }
        defer { controller.invalidate() }
        let pointer = try ToolbarPointer(controller)
        // With Option down over the toolbar, Save Screen records the screen as
        // File ▸ Record Screen does.
        pointer.enter()
        pointer.hold(.option)
        #expect(pointer.faces == ButtonFace.optionAlternates)
        #expect(try pointer.click(.saveScreen))
        let recording = try #require(controller.session.recording)
        // While the recording runs, Save Screen is Stop Recording whatever
        // Option and the pointer do, and Rotate still follows Option.
        try await wait { pointer.faces[1] == .stopRecording }
        #expect(pointer.faces == [.home, .stopRecording, .rotateLeft])
        pointer.hold([])
        #expect(pointer.faces == [.home, .stopRecording, .rotate])
        pointer.exit()
        pointer.hold(.option)
        pointer.enter()
        #expect(pointer.faces == [.home, .stopRecording, .rotateLeft])
        // A click with Option stops the recording.
        #expect(try pointer.click(.saveScreen))
        #expect(recording.isStopping)
        // As soon as the recording stops, Save Screen follows Option again,
        // and Record Screen is available once the movie is finished.
        try await wait { pointer.faces[1] == .recordScreen }
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

    @Test func theOptionAlternatesFollowTheAppsActivationAsInSimulatorApp() throws {
        let controller = try makeController(TestDisplay())
        defer { controller.invalidate() }
        let window = try #require(controller.window)
        let pointer = try ToolbarPointer(controller)
        // Like Simulator.app's `SimToolbar`, the toolbar's view tracks the
        // pointer while the app is active, in any of its windows: AppKit
        // reports the pointer leaving when the app resigns active and entering
        // when the app becomes active with the pointer over the toolbar.
        #expect(pointer.area.options == [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect])
        // A window that resigns key keeps the alternates while Option is
        // down, although it sends its device a modifier release through the
        // app.
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
        var releases = 0
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            if event.modifierFlags.isEmpty { releases += 1 }
            return event
        }
        defer { monitor.map(NSEvent.removeMonitor) }
        pointer.enter()
        pointer.hold(.option)
        #expect(pointer.faces == ButtonFace.optionAlternates)
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: window))
        #expect(releases == 1)
        #expect(pointer.faces == ButtonFace.optionAlternates)
        // When the app resigns active, the buttons take their own faces as the
        // pointer leaves. Option changes made in another app do not reach this
        // one.
        pointer.exit()
        #expect(pointer.faces == ButtonFace.normal)
        pointer.holdInAnotherApp([])
        pointer.holdInAnotherApp(.option)
        #expect(pointer.faces == ButtonFace.normal)
        // When the app becomes active again with the pointer over the toolbar,
        // the buttons read Option as they enter.
        pointer.enter()
        #expect(pointer.faces == ButtonFace.optionAlternates)
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
            let display = controller.session.display
            let frame = display.view.frame
            #expect(frame.minX >= 0)
            #expect(frame.minY >= 0)
            #expect(frame.maxX <= content.bounds.maxX)
            #expect(frame.maxY <= window.contentLayoutRect.maxY)
            // The display keeps its own size, centered across the window,
            // instead of filling it as when the window has the display's size.
            #expect(frame.size == display.size(for: display.renderScale))
            #expect(abs(frame.midX - content.bounds.midX) < 0.001)
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
    }

    @Test func editMenuEndsWithSimulatorAppsPasteboardCommands() throws {
        _ = NSApplication.shared
        MenuController(application: nil).install()
        defer { NSApp.mainMenu = nil }
        let edit = try #require(NSApp.mainMenu?.items.first { $0.title == "Edit" }?.submenu)
        #expect(edit.items.map { $0.isSeparatorItem ? "-" : $0.title } == [
            "Undo", "Redo", "-", "Cut", "Copy", "Copy Screen", "Paste", "Select All", "-",
            "Automatically Sync Pasteboard", "Get Pasteboard", "Send Pasteboard",
        ])
        #expect(edit.items.suffix(3).allSatisfy { $0.keyEquivalent.isEmpty })
    }

    @Test func automaticPasteboardSyncIsOffUntilChosen() throws {
        _ = NSApplication.shared
        // Simulator.app registers PasteboardAutomaticSync on; NeoSimulator
        // registers it off. Registered values are not saved.
        HostPreferences.registerDefaults()
        #expect(UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain)[
            HostPreferences.pasteboardAutomaticSync] as? Bool == false)
        let preferences = MemoryPreferences()
        let sync = PasteboardSync(preferences: preferences) { [] }
        #expect(!sync.isOn)
        let menu = MenuController(application: nil, pasteboardSync: sync)
        menu.install()
        defer { NSApp.mainMenu = nil }
        let edit = try #require(NSApp.mainMenu?.items.first { $0.title == "Edit" }?.submenu)
        let item = try #require(edit.items.first { $0.title == "Automatically Sync Pasteboard" })
        let action = try #require(item.action)
        // Like Simulator.app's, the item is enabled without a device window
        // and checked while synchronization is on, which it saves.
        #expect(menu.validateMenuItem(item))
        #expect(item.state == .off)
        #expect(NSApp.sendAction(action, to: item.target, from: item))
        #expect(sync.isOn)
        #expect(preferences.values[HostPreferences.pasteboardAutomaticSync] as? Bool == true)
        #expect(menu.validateMenuItem(item))
        #expect(item.state == .on)
        #expect(PasteboardSync(preferences: preferences) { [] }.isOn)
        #expect(NSApp.sendAction(action, to: item.target, from: item))
        #expect(!sync.isOn)
        #expect(preferences.values[HostPreferences.pasteboardAutomaticSync] as? Bool == false)
        #expect(menu.validateMenuItem(item))
        #expect(item.state == .off)
        #expect(!MenuController(application: nil).validateMenuItem(item))
    }

    @Test func pasteboardTransfersNeedADeviceThatExchangesItsPasteboard() throws {
        let get = DeviceCommand.command(.getPasteboard), send = DeviceCommand.command(.sendPasteboard)
        func availability(_ family: DeviceCapabilities.Family, features: Set<String> = [DeviceCapabilities.pasteboard],
                          _ change: (DeviceWindowController, TestDisplay) -> Void = { _, _ in }) throws -> [Bool] {
            let display = TestDisplay()
            let controller = try makeController(display, family: family, features: features)
            defer { controller.invalidate() }
            change(controller, display)
            return [get, send].flatMap { [$0.isSupported(controller.session.capabilities), $0.isEnabled(controller)] }
        }
        // Like Simulator.app, other devices show the commands disabled.
        for family in [DeviceCapabilities.Family.iPhone, .iPad, .vision] {
            #expect(try availability(family) == [true, true, true, true])
        }
        for family in [DeviceCapabilities.Family.tv, .watch] {
            #expect(try availability(family) == [true, false, true, false])
        }
        #expect(try availability(.iPhone, features: []) == [true, false, true, false])
        #expect(try availability(.iPhone) { $1.isBooted = false } == [true, false, true, false])
        #expect(try availability(.iPhone) { controller, _ in controller.session.disconnect() } == [true, false, true, false])
    }

    @Test func pasteboardTransfersConnectOnlyWhenChosen() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.lynnswap.NeoSimulatorTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let display = TestDisplay()
        let controller = try makeController(display, features: [DeviceCapabilities.pasteboard], pasteboard: pasteboard)
        defer { controller.invalidate() }
        // Nothing crosses without a command, so the device's pasteboard
        // service is not even connected until one is chosen.
        #expect(display.pasteboards.isEmpty)
        controller.perform(.getPasteboard)
        controller.perform(.sendPasteboard)
        controller.perform(.getPasteboard)
        let connection = try #require(display.pasteboards.first)
        #expect(display.pasteboards.count == 1)
        #expect(connection.pasteboard === pasteboard)
        #expect(connection.transfers == [.get, .send, .get])
        // Like Simulator.app, the connection is told not to synchronize.
        #expect(connection.automaticSync == [false])
        // The connection stays until the window disconnects, so that the Mac
        // pasteboard can read the device's data when an app pastes it.
        #expect(!connection.isDisconnected)
        controller.invalidate()
        #expect(connection.isDisconnected)
    }

    @Test func pasteboardTransferFailuresReachTheirCommand() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.lynnswap.NeoSimulatorTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let display = TestDisplay()
        let session = try makeSession(display, features: [DeviceCapabilities.pasteboard], pasteboard: pasteboard)
        defer { session.disconnect() }
        var failures: [String] = []
        func transfer(_ transfer: PasteboardTransfer) {
            session.transferPasteboard(transfer) { failures.append($0.localizedDescription) }
        }
        let get = "Could not get the simulator's pasteboard: "
        let send = "Could not send the pasteboard to the simulator: "
        let closed = "The simulator closed its pasteboard connection."

        display.pasteboardError = HostError.operation("Unable to lookup in current state: Shutdown")
        transfer(.get)
        #expect(failures == [get + "Unable to lookup in current state: Shutdown"])
        #expect(display.pasteboards.isEmpty)

        // The next transfer connects. The connection's first activation is
        // its own; each later one completes a push.
        transfer(.send)
        let first = try #require(display.pasteboards.first)
        first.send(.activated)
        first.send(.activated)
        transfer(.get)
        first.send(.failedToApply(HostError.operation("pasteboard communication failure")))
        #expect(failures.last == get + "pasteboard communication failure")
        transfer(.get)
        first.send(.applied(generation: 1))
        // With nothing pending, the device closing the connection is no failure.
        first.send(.lostConnection)
        #expect(failures.count == 2)
        #expect(first.isDisconnected)

        // Transfers still pending fail, and the next transfer connects again.
        transfer(.send)
        let second = try #require(display.pasteboards.last)
        #expect(display.pasteboards.count == 2)
        second.send(.activated)
        transfer(.get)
        second.send(.lostConnection)
        #expect(Set(failures.dropFirst(2)) == [send + closed, get + closed])
        transfer(.send)
        #expect(display.pasteboards.count == 3)
    }

    @Test func pasteboardDelegateAnswersSimPasteboardPlus() throws {
        let runtime = try makeRuntime()
        #expect(runtime.pasteboard.serviceName == "com.apple.CoreSimulator.SimPasteboardInterface")
        // The connection calls the protocol's optional methods by selector, so
        // each must match the protocol's declaration exactly.
        let delegateProtocol = try #require(objc_getProtocol("_TtP17SimPasteboardPlus21SimPasteboardDelegate_"))
        var events: [String] = []
        let delegate = SimulatorPasteboardDelegate { events.append("\($0)") }
        let interface = NSObject(), host = NSUUID(), pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let callbacks: [(String, () -> Void)] = [
            ("simPasteboardDidBecomeActive:", { delegate.simPasteboardDidBecomeActive(interface) }),
            ("simPasteboardDidLoseConnection:", { delegate.simPasteboardDidLoseConnection(interface) }),
            ("simPasteboardDidApplySnapshot:fromHost:incomingGeneration:toPasteboard:atGeneration:", {
                delegate.simPasteboardDidApplySnapshot(interface, fromHost: host, incomingGeneration: 7,
                                                       toPasteboard: pasteboard, atGeneration: 2)
            }),
            ("simPasteboardErrorApplyingSnapshot:fromHost:generation:error:toPasteboard:", {
                delegate.simPasteboardErrorApplyingSnapshot(interface, fromHost: host, generation: 7,
                                                            error: NSError(domain: "CFPasteboardErrorDomain", code: -25130),
                                                            toPasteboard: pasteboard)
            }),
            ("simPasteboardDidChangeAutoNotifyState:forPasteboard:toStatus:", {
                delegate.simPasteboardDidChangeAutoNotifyState(interface, forPasteboard: pasteboard, toStatus: true)
            }),
        ]
        for (name, call) in callbacks {
            let selector = NSSelectorFromString(name)
            let declared = protocol_getMethodDescription(delegateProtocol, selector, false, true)
            let method = try #require(class_getInstanceMethod(SimulatorPasteboardDelegate.self, selector), "\(name)")
            #expect(declared.types.map { String(cString: $0) } == String(cString: method_getTypeEncoding(method)!))
            call()
        }
        #expect(events.count == 5)
        #expect(events.prefix(3) == ["activated", "lostConnection", "applied(generation: 2)"])
        #expect(events[3].hasPrefix("failedToApply"))
        #expect(events.last == "synchronizationChanged(true)")
    }

    @Test func devicesConnectingWhileSynchronizingReceiveTheMacPasteboard() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.lynnswap.NeoSimulatorTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        var sessions: [DeviceSession] = []
        let sync = PasteboardSync(preferences: MemoryPreferences()) { sessions }
        func start(_ family: DeviceCapabilities.Family = .iPhone, features: Set<String> = [DeviceCapabilities.pasteboard],
                   _ change: (TestDisplay) -> Void = { _ in }) throws -> (DeviceSession, TestDisplay) {
            let display = TestDisplay()
            change(display)
            let session = try makeSession(display, family: family, features: features, pasteboard: pasteboard,
                                          pasteboardSync: sync)
            sessions.append(session)
            session.startPasteboardSync()
            return (session, display)
        }
        defer { sessions.forEach { $0.disconnect() } }

        // Off, a device that connects is not even connected to.
        #expect(try start().1.pasteboards.isEmpty)

        sync.toggle()
        // On, like Simulator.app when a device connects: its connection
        // synchronizes and is sent the Mac pasteboard.
        let (session, display) = try start()
        let connection = try #require(display.pasteboards.first)
        #expect(display.pasteboards.count == 1)
        #expect(connection.pasteboard === pasteboard)
        #expect(connection.automaticSync == [true])
        #expect(connection.transfers == [.send])
        // Get Pasteboard and Send Pasteboard are unavailable meanwhile.
        #expect(!session.canTransferPasteboard)
        session.transferPasteboard(.get) { _ in Issue.record("no transfer") }
        #expect(connection.transfers == [.send])
        // Devices that do not exchange pasteboards are left alone.
        #expect(try start(.tv).1.pasteboards.isEmpty)
        #expect(try start(features: []).1.pasteboards.isEmpty)
        #expect(try start { $0.isBooted = false }.1.pasteboards.isEmpty)
    }

    @Test func turningPasteboardSyncOnAndOffReachesEveryDevice() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.lynnswap.NeoSimulatorTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        var sessions: [DeviceSession] = []
        let sync = PasteboardSync(preferences: MemoryPreferences()) { sessions }
        func add(_ family: DeviceCapabilities.Family) throws -> (DeviceSession, TestDisplay) {
            let display = TestDisplay()
            let session = try makeSession(display, family: family, features: [DeviceCapabilities.pasteboard],
                                          pasteboard: pasteboard, pasteboardSync: sync)
            sessions.append(session)
            return (session, display)
        }
        let (phone, phoneDisplay) = try add(.iPhone)
        let (pad, padDisplay) = try add(.iPad)
        let (_, tvDisplay) = try add(.tv)
        defer { sessions.forEach { $0.disconnect() } }
        phone.transferPasteboard(.get) { _ in }
        let phoneConnection = try #require(phoneDisplay.pasteboards.first)

        // Turning it on tells every device's connection and connects the
        // devices not yet connected, without transferring anything.
        sync.toggle()
        #expect(phoneConnection.automaticSync == [false, true])
        let padConnection = try #require(padDisplay.pasteboards.first)
        #expect(padConnection.automaticSync == [true])
        #expect(padConnection.transfers.isEmpty)
        #expect(tvDisplay.pasteboards.isEmpty)
        #expect(!phone.canTransferPasteboard && !pad.canTransferPasteboard)

        // Turning it off stops every connection's synchronization and keeps
        // the connections for Get and Send Pasteboard.
        sync.toggle()
        #expect(phoneConnection.automaticSync == [false, true, false])
        #expect(padConnection.automaticSync == [true, false])
        #expect(!phoneConnection.isDisconnected && !padConnection.isDisconnected)
        #expect(phoneConnection.transfers == [.get])
        #expect(padConnection.transfers.isEmpty)
        #expect(phone.canTransferPasteboard && pad.canTransferPasteboard)
        #expect(phoneDisplay.pasteboards.count == 1 && padDisplay.pasteboards.count == 1)
    }

    @Test func aDevicesCopyReachesTheOtherDevicesWithoutEcho() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.lynnswap.NeoSimulatorTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let preferences = MemoryPreferences()
        preferences.values[HostPreferences.pasteboardAutomaticSync] = true
        var sessions: [DeviceSession] = []
        let sync = PasteboardSync(preferences: preferences) { sessions }
        var connections: [TestPasteboard] = []
        for index in 0..<3 {
            let display = TestDisplay()
            let session = try makeSession(display, features: [DeviceCapabilities.pasteboard], device: "device-\(index)",
                                          pasteboard: pasteboard, pasteboardSync: sync)
            sessions.append(session)
            session.startPasteboardSync()
            connections.append(try #require(display.pasteboards.first))
        }
        defer { sessions.forEach { $0.disconnect() } }
        let (first, second, third) = (connections[0], connections[1], connections[2])
        func pushes() -> [Int] { connections.map { $0.transfers.count - 1 } }
        /// The device's copy replaces the Mac pasteboard, as SimPasteboardPlus applies it.
        func copy(on connection: TestPasteboard, _ text: String) {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            connection.send(.applied(generation: pasteboard.changeCount))
        }
        func settle() async throws {
            try await Task.sleep(for: .milliseconds(50))
        }

        // The other devices are sent the Mac pasteboard once the run loop
        // ends its pass, and the device that copied is not.
        copy(on: first, "first")
        #expect(pushes() == [0, 0, 0])
        try await settle()
        #expect(pushes() == [0, 1, 1])

        // Of copies in one pass, the last one's device is left out, and each
        // other device is sent the Mac pasteboard once.
        copy(on: first, "first again")
        copy(on: second, "second")
        try await settle()
        #expect(pushes() == [1, 1, 2])

        // A device whose copy the Mac pasteboard still holds is not sent it
        // back, also when another device's late report starts the exchange.
        first.send(.applied(generation: pasteboard.changeCount - 1))
        try await settle()
        #expect(pushes() == [1, 1, 3])
        // After a copy that could not be applied, it is sent again.
        second.send(.failedToApply(HostError.operation("pasteboard communication failure")))
        first.send(.applied(generation: pasteboard.changeCount - 1))
        try await settle()
        #expect(pushes() == [1, 2, 4])

        // Off, a device's copy reaches no other device.
        sync.toggle()
        copy(on: third, "third")
        try await settle()
        #expect(pushes() == [1, 2, 4])
    }

    @Test func synchronizedDevicesReconnectAtOnceWhenTheConnectionCloses() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.lynnswap.NeoSimulatorTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let preferences = MemoryPreferences()
        preferences.values[HostPreferences.pasteboardAutomaticSync] = true
        var sessions: [DeviceSession] = []
        let sync = PasteboardSync(preferences: preferences) { sessions }
        let display = TestDisplay()
        let session = try makeSession(display, features: [DeviceCapabilities.pasteboard], pasteboard: pasteboard,
                                      pasteboardSync: sync)
        sessions.append(session)
        defer { session.disconnect() }
        session.startPasteboardSync()
        let first = try #require(display.pasteboards.first)

        // Like Simulator.app, for example after CoreSimulatorBridge restarts:
        // the new connection synchronizes without being sent the Mac pasteboard.
        first.send(.lostConnection)
        #expect(first.isDisconnected)
        #expect(display.pasteboards.count == 2)
        let second = try #require(display.pasteboards.last)
        #expect(second.automaticSync == [true])
        #expect(second.transfers.isEmpty)

        // A device that is shutting down is not connected again.
        display.isBooted = false
        second.send(.lostConnection)
        #expect(display.pasteboards.count == 2)
        // Off, the next transfer connects instead.
        display.isBooted = true
        sync.toggle()
        session.transferPasteboard(.get) { _ in }
        #expect(display.pasteboards.count == 3)
        try #require(display.pasteboards.last).send(.lostConnection)
        #expect(display.pasteboards.count == 3)
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
        let runtime = try makeRuntime()
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

    @Test func aUserInterfacePluginGivesTheWindowItsToolbarAndTakesTheInput() throws {
        let display = TestDisplay()
        let overlay = InputView()
        display.view.addSubview(overlay)
        let toolbar = NSToolbar(identifier: "PluginToolbar")
        // Like SimulatorKit for Apple Vision Pro, the display has loaded the
        // plugin by the time the window opens.
        display.plugin = SimulatorUserInterfacePlugin(overlayView: overlay, toolbar: toolbar)
        let controller = try makeController(display, family: .vision, features: [], userInterfacePlugin: true)
        defer { controller.invalidate() }
        let window = try #require(controller.window)
        // Like Simulator.app, the window shows the plugin's toolbar.
        #expect(window.toolbar === toolbar)
        // The overlay takes the window's focus and the Mac's modifiers.
        controller.focusInput()
        #expect(window.firstResponder === overlay)
        #expect(!overlay.modifiers.isEmpty && display.input.modifiers.isEmpty)
        // The plugin's buttons send Simulator.app's actions, which reach the
        // window from the overlay.
        #expect(overlay.tryToPerform(Selector(("homeButtonPressed:")), with: nil))
        #expect(display.buttons == [.home])
    }

    @Test func aWindowWaitsForItsDisplaysUserInterfacePluginAndReportsOneThatDoesNotLoad() async throws {
        _ = NSApplication.shared
        let display = TestDisplay()
        let controller = try makeController(display, family: .vision, features: [], userInterfacePlugin: true,
                                            userInterfacePluginLookUp: (50, .milliseconds(10)))
        defer { controller.invalidate() }
        controller.showWindow(nil)
        let window = try #require(controller.window)
        let deviceToolbar = window.toolbar
        // A plugin that loads later replaces the window's toolbar then.
        let toolbar = NSToolbar(identifier: "LatePluginToolbar")
        display.plugin = SimulatorUserInterfacePlugin(overlayView: nil, toolbar: toolbar)
        try await wait { window.toolbar === toolbar }
        #expect(window.toolbar === toolbar && toolbar !== deviceToolbar)
        #expect(window.attachedSheet == nil)

        // A plugin that never loads, or that cannot be used, is reported.
        for error in [nil, HostError.unavailable("plugin from another Xcode")] as [Error?] {
            let missing = TestDisplay()
            missing.pluginError = error
            let unloaded = try makeController(missing, family: .vision, features: [], userInterfacePlugin: true,
                                              userInterfacePluginLookUp: (3, .milliseconds(10)))
            defer { unloaded.invalidate() }
            unloaded.showWindow(nil)
            let unloadedWindow = try #require(unloaded.window)
            try await wait { unloadedWindow.attachedSheet != nil }
            let sheet = try #require(unloadedWindow.attachedSheet)
            #expect(texts(in: sheet.contentView).contains {
                $0.hasPrefix("The controls of Test iPhone are unavailable: ")
                    && $0.hasSuffix(error == nil ? "SimulatorKit did not load its user interface plugin." : "plugin from another Xcode")
            })
            unloadedWindow.endSheet(sheet)
        }
        // A device type without a plugin is not looked up.
        let phone = TestDisplay()
        phone.pluginError = HostError.unavailable("looked up")
        let phoneController = try makeController(phone)
        defer { phoneController.invalidate() }
        phoneController.showWindow(nil)
        try await Task.sleep(for: .milliseconds(50))
        #expect(phoneController.window?.attachedSheet == nil)
    }

    @Test func recordingsAreAnnouncedAsInSimulatorApp() async throws {
        let display = TestDisplay()
        let overlay = InputView()
        display.view.addSubview(overlay)
        display.plugin = SimulatorUserInterfacePlugin(overlayView: overlay, toolbar: nil)
        // A recording runs until it is stopped, and another fails at once.
        var recordings = 0
        let controller = try makeController(display, family: .vision, features: [], recordingProcess: { _, _ in
            recordings += 1
            return Self.recorder(then: recordings == 1 ? "while :; do sleep 0.05; done" : "sleep 0.1; exit 1")
        }, userInterfacePlugin: true)
        defer { controller.invalidate() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try controller.session.startRecording(to: .file(directory.appendingPathComponent("Recording.mov")), mask: .ignored)
        let recording = try #require(controller.session.recording)
        #expect(display.announcedRecordings == [true])
        // Save Screen on the plugin's toolbar stops it with Simulator.app's
        // `toggleVideoRecording:`, and its end is announced.
        #expect(overlay.tryToPerform(Selector(("toggleVideoRecording:")), with: nil))
        #expect(recording.isStopping)
        try await recording.waitUntilFinished()
        try await wait { controller.session.recording == nil }
        #expect(display.announcedRecordings == [true, false])
        try controller.session.startRecording(to: .file(directory.appendingPathComponent("Failed.mov")), mask: .ignored)
        try await wait { controller.session.recording == nil }
        #expect(display.announcedRecordings == [true, false, true, false])
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
            ["Restart", "Erase All Content and Settings…", "Shut Down", "-", "Home", "Lock", "Shake",
             "App Switcher", "-", "Trigger Screenshot"])
        controller.perform(.rotateRight)
        #expect(!controller.session.isBusy)
    }

    @Test func eachFamilysToolbarHasSimulatorAppsButtons() throws {
        func items(_ family: DeviceCapabilities.Family, _ features: Set<String>) throws -> [DeviceCommand.ID] {
            let controller = try makeController(TestDisplay(), family: family, features: features)
            defer { controller.invalidate() }
            return try #require(controller.window?.toolbar).items.compactMap {
                DeviceCommand.ID(rawValue: $0.itemIdentifier.rawValue)
            }
        }
        // IndigoWatchToolbar.nib and IndigoTVToolbar.nib, and
        // IndigoWatchAODToolbar.nib for a watch with an always-on display.
        #expect(try items(.watch, [DeviceCapabilities.keyboard]) == [.home, .saveScreen])
        #expect(try items(.tv, [DeviceCapabilities.keyboard]) == [.home, .saveScreen])
        #expect(try items(.watch, [DeviceCapabilities.alwaysOnDisplay]) == [.home, .saveScreen, .alwaysOn])
        // An iPhone with an always-on display gets the iPhone toolbar.
        #expect(try items(.iPhone, [DeviceCapabilities.alwaysOnDisplay, DeviceCapabilities.displayRotation])
            == [.home, .saveScreen, .rotateRight])
    }

    @Test func alwaysOnPressesLockAndFollowsTheWatchsBacklight() async throws {
        let display = TestDisplay()
        display.backlightState = 2
        let controller = try makeController(display, family: .watch, features: [DeviceCapabilities.alwaysOnDisplay])
        defer { controller.invalidate() }
        let item = try #require(controller.window?.toolbar?.items.first { $0.itemIdentifier.rawValue == "alwaysOn" })
        let button = try #require(item.view as? NSButton)
        #expect(item.label == "Always On")
        #expect(button.toolTip == "Toggle Always On")
        #expect(button.state == .off)
        // Like Simulator.app's, the button is on while the backlight is 0 or
        // 1 and off at 2, and other values leave it as it is.
        for (backlight, on) in [(1, true), (-101, true), (2, false), (-101, false), (0, true)] as [(Int32, Bool)] {
            display.backlightState = backlight
            display.onPropertiesChange?()
            #expect(controller.session.showsAlwaysOn == on, "backlight \(backlight)")
            try await wait { button.state == (on ? .on : .off) }
            #expect(button.state == (on ? .on : .off), "backlight \(backlight)")
        }
        // A click presses Lock, and the button keeps the backlight's state
        // until the backlight changes.
        button.performClick(nil)
        #expect(display.buttons == [.lock])
        #expect(button.state == .on)
        display.backlightState = 2
        display.onPropertiesChange?()
        try await wait { button.state == .off }
        #expect(button.state == .off)
        // Another family's backlight changes nothing.
        let tv = TestDisplay()
        tv.backlightState = 1
        let tvController = try makeController(tv, family: .tv, features: [DeviceCapabilities.alwaysOnDisplay])
        defer { tvController.invalidate() }
        tv.onPropertiesChange?()
        #expect(!tvController.session.showsAlwaysOn)
    }

    @Test func menusShowWhatEachFamilySupportsAsInSimulatorApp() throws {
        _ = NSApplication.shared
        let menus = MenuController(application: nil)
        menus.install()
        defer { NSApp.mainMenu = nil }
        func visible(_ title: String, _ family: DeviceCapabilities.Family) throws -> [String] {
            let menu = try #require(NSApp.mainMenu?.items.first { $0.title == title }?.submenu)
            menus.updateVisibility(in: menu, for: DeviceCapabilities(family: family, runtimeVersion: 0x1B_00_00,
                                                                     supportsFeature: { _ in false }))
            return menu.items.filter { !$0.isHidden }.map { $0.isSeparatorItem ? "-" : $0.title }
        }
        let commands = ["Restart", "Erase All Content and Settings…", "Shut Down", "-", "Home"]
        // Lock is for iPhones, iPads, and watches, and Side Button for watches.
        #expect(try visible("Device", .watch) == commands + ["Lock", "Side Button"])
        #expect(try visible("Device", .tv) == commands)
        #expect(try visible("Device", .vision) == commands)
        // Apple Vision's display has no bezel to show.
        #expect(try !visible("Window", .vision).contains("Show Device Bezels"))
        #expect(try visible("Window", .watch).contains("Show Device Bezels"))
    }

    @Test func onlyADeviceThatRotatesReadsItsOrientation() async throws {
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
        // Like Simulator.app, which turns only an iPhone's or iPad's display,
        // a watch's window does not ask for the orientation.
        let watch = try makeController(TestDisplay(), family: .watch, features: [DeviceCapabilities.keyboard],
                                       devicectl: devicectl)
        defer { watch.invalidate() }
        var position = NSPoint.zero
        watch.showNewWindow(cascadingFrom: &position)
        #expect(!watch.session.isBusy)
        #expect(!FileManager.default.fileExists(atPath: log.path))
        // An iPhone's does.
        let phone = try makeController(TestDisplay(), devicectl: devicectl, device: "phone")
        defer { phone.invalidate() }
        phone.showNewWindow(cascadingFrom: &position)
        #expect(phone.session.isBusy)
        try await wait { !phone.session.isBusy }
        #expect(try String(contentsOf: log, encoding: .utf8).contains("orientation get"))
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
        // The window takes the display's size at the scale, right below its
        // header without a bezel, also when the display is narrower than a
        // manual resize can make the window.
        func fitsDisplay() -> Bool {
            display.view.frame.size == display.size(for: display.renderScale)
                && window.contentLayoutRect.size == display.view.frame.size
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
        // Wide enough that the fitted window keeps the unified title bar.
        display.naturalSize = NSSize(width: 400, height: 300)
        let controller = try makeController(display)
        defer { controller.invalidate() }
        controller.showWindow(nil)
        let window = try #require(controller.window)
        let visible = try #require((window.screen ?? NSScreen.main)?.visibleFrame)
        // Like Simulator.app, the space is the visible frame less the window's
        // header, which a display without a bezel sits right below.
        let above = window.frame.height - window.contentLayoutRect.height
        controller.perform(.fitScreen)
        // Unlike NeoSimulator's earlier Fit Screen, the scale can exceed 1.
        let expected = min((visible.width - 20) / 400, (visible.height - above - 20) / 300)
        #expect(abs(display.renderScale - expected) < 0.000_001)
        #expect(abs(window.frame.midX - visible.midX) < 1 && abs(window.frame.midY - visible.midY) < 1)
        #expect(visible.contains(window.frame))
        #expect(DeviceCommand.command(.fitScreen).state == nil)
    }

    @Test func fitScreenFitsAWindowThatTakesTheExpandedTitleBar() throws {
        let display = TestDisplay()
        // Wide, so the window starts with the unified title bar.
        display.naturalSize = NSSize(width: 600, height: 300)
        let controller = try makeController(display)
        defer { controller.invalidate() }
        controller.showWindow(nil)
        let window = try #require(controller.window)
        let visible = try #require((window.screen ?? NSScreen.main)?.visibleFrame)
        #expect(window.toolbarStyle == .unified)
        // Fitted to the screen, a tall and narrow display makes the window far
        // narrower than the unified style allows, and the taller expanded
        // title bar must still leave the window inside the screen.
        let tall = NSSize(width: 60, height: visible.height * 2)
        display.naturalSize = tall
        controller.perform(.fitScreen)
        #expect(window.toolbarStyle == .expanded)
        // AppKit keeps a window without a bezel inside the screen, so the
        // scale shows whether the display fits below the expanded title bar.
        func fitted(_ window: NSWindow) -> CGFloat {
            (visible.height - (window.frame.height - window.contentLayoutRect.height) - 20) / tall.height
        }
        #expect(abs(display.renderScale - fitted(window)) < 0.000_001)
        #expect(window.frame.height <= visible.height)
        // A new window of such a display opens fitted the same way.
        let other = TestDisplay()
        other.naturalSize = tall
        let opened = try makeController(other)
        defer { opened.invalidate() }
        let openedWindow = try #require(opened.window)
        #expect(openedWindow.toolbarStyle == .expanded)
        #expect(abs(other.renderScale - fitted(openedWindow)) < 0.000_001)
        #expect(openedWindow.frame.height <= visible.height)
    }

    @Test func fixedScalesAreCheckedAgainstTheTitleBarTheyWouldGiveTheWindow() throws {
        let display = TestDisplay()
        // Wide, so the window starts with the unified title bar.
        display.naturalSize = NSSize(width: 600, height: 300)
        let controller = try makeController(display)
        defer { controller.invalidate() }
        controller.showWindow(nil)
        let window = try #require(controller.window)
        let visible = try #require(window.screen?.visibleFrame)
        let pointAccurate = DeviceCommand.command(.pointAccurate)
        #expect(window.toolbarStyle == .unified)
        // At Point Accurate a narrow display would take the expanded title
        // bar, under which this height no longer fits without a bezel.
        display.naturalSize = NSSize(width: 60, height: visible.height - 60)
        #expect(!pointAccurate.isEnabled(controller))
        // From an expanded window, a wide display would take the unified title
        // bar, under which the same height fits.
        controller.perform(.fitScreen)
        #expect(window.toolbarStyle == .expanded)
        display.naturalSize = NSSize(width: 600, height: visible.height - 60)
        #expect(pointAccurate.isEnabled(controller))
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
        // A fixed scale must fit the screen below the window's header, which
        // a display without a bezel sits right below.
        let visible = try #require(window.screen?.visibleFrame)
        let above = window.frame.height - window.contentLayoutRect.height
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
            // Wide enough that a window fitted to any screen keeps the unified
            // title bar that Fit Screen measured; a narrower one would take
            // the taller expanded style after the scale is chosen.
            display.naturalSize = NSSize(width: 320, height: 160)
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
        // Showing the window again while the reading is pending, as Open
        // Simulator or a Dock click does, keeps the placement for its result.
        preferences.setWindowGeometry(center: center, scale: 0.5, forDevice: "F", screens: screens)
        let reshownDisplay = TestDisplay()
        reshownDisplay.naturalSize = tall
        reshownDisplay.onRotation = { [unowned reshownDisplay] in reshownDisplay.naturalSize = $0 == 0 ? tall : landscape }
        let reshown = try makeController(reshownDisplay, devicectl: devicectl, device: "F", preferences: preferences)
        defer { reshown.invalidate() }
        reshown.showNewWindow(cascadingFrom: &cascade)
        reshown.showAndActivate()
        try await readOrientation(reshown)
        #expect(reshownDisplay.renderScale == 0.5)
        let reshownWindow = try #require(reshown.window)
        #expect(abs(reshownWindow.frame.midX - center.x) < 1 && abs(reshownWindow.frame.midY - center.y) < 1)
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
        // The window takes the display's size, 1 point below its header with
        // the bezel, whose images have 9 points of top padding, and right
        // below it without.
        func showsDisplay(_ size: NSSize, below gap: CGFloat) -> Bool {
            display.view.frame.size == size
                && window.contentLayoutRect.size == NSSize(width: size.width, height: size.height + gap)
        }
        controller.perform(.pointAccurate)
        #expect(showsDisplay(NSSize(width: 400, height: 460), below: 1))
        let origin = window.frame.origin
        // Hiding the bezel keeps the scale and the window's bottom-left
        // corner, as Simulator.app does, and shrinks the window.
        controller.setDeviceBezelVisible(false)
        #expect(display.renderScale == 1)
        #expect(DeviceCommand.command(.pointAccurate).state?(controller) == .on)
        #expect(showsDisplay(NSSize(width: 360, height: 400), below: 0))
        #expect(window.frame.origin == origin)
        #expect(window.styleMask.contains(.resizable))
        // Showing it keeps a scale chosen without the bezel and grows the window.
        controller.perform(.pointAccurate)
        controller.setDeviceBezelVisible(true)
        #expect(display.renderScale == 1)
        #expect(showsDisplay(NSSize(width: 400, height: 460), below: 1))
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

    @Test func theGapAboveTheDisplayFollowsTheBezelsTopPadding() throws {
        // With an iPhone 17 Pro's bezel, which has no top padding, with an
        // iPad's, which has 9 points, and without a bezel, where Simulator.app's
        // chrome refresh turns the gap off and the display meets the header.
        for (padding, gap) in [(NSSize(width: 9, height: 0), CGFloat(10)), (NSSize(width: 10, height: 9), 1), (nil, 0)] {
            let display = TestDisplay()
            display.naturalSize = NSSize(width: 200, height: 300)
            display.bezel = padding == nil ? .zero : NSSize(width: 20, height: 20)
            display.bezelPadding = padding
            display.showsBezel = padding != nil
            let controller = try makeController(display)
            defer { controller.invalidate() }
            controller.showWindow(nil)
            let window = try #require(controller.window)
            controller.perform(.pointAccurate)
            // Like Simulator.app's constraints, the display fills the window
            // below the gap.
            let size = display.size(for: 1)
            #expect(display.view.frame == NSRect(origin: .zero, size: size))
            #expect(window.contentLayoutRect.maxY - display.view.frame.maxY == gap)
            #expect(window.contentLayoutRect.size == NSSize(width: size.width, height: size.height + gap))
        }
    }

    @Test func theToolbarTakesSimulatorAppsStyleForTheDisplaysWidth() throws {
        let threshold = Self.unifiedWidth()
        let display = TestDisplay()
        display.naturalSize = NSSize(width: threshold, height: 300)
        let controller = try makeController(display)
        defer { controller.invalidate() }
        controller.showWindow(nil)
        let window = try #require(controller.window)
        let toolbar = try #require(window.toolbar)
        func header() -> CGFloat { window.frame.height - window.contentLayoutRect.height }
        // Like Simulator.app's toolbar nibs, the buttons sit between two
        // flexible spaces.
        #expect(toolbar.items.first?.itemIdentifier == .flexibleSpace)
        #expect(toolbar.items.last?.itemIdentifier == .flexibleSpace)
        // A display as wide as the buttons, the title, and 130 points keeps
        // the unified style, which hides the last flexible space, so that the
        // buttons follow the title.
        controller.perform(.pointAccurate)
        #expect(window.toolbarStyle == .unified)
        #expect(toolbar.items.last?.isHidden == true)
        // Like Simulator.app's, the title truncates so that every button stays
        // in the title bar instead of the overflow menu.
        window.layoutIfNeeded()
        #expect(toolbar.visibleItems?.compactMap { DeviceCommand.ID(rawValue: $0.itemIdentifier.rawValue) }
            == [.home, .saveScreen, .rotateRight])
        let unified = header()
        #expect(window.frame.height == 300 + unified)
        #expect((0..<1).contains(window.frame.width - threshold))
        // A narrower display takes the expanded style, which centers the
        // buttons in a row below the title. The window is as tall as the
        // display and the taller title bar.
        display.naturalSize = NSSize(width: threshold - 0.01, height: 300)
        controller.perform(.pointAccurate)
        #expect(window.toolbarStyle == .expanded)
        #expect(toolbar.items.last?.isHidden == false)
        let expanded = header()
        #expect(expanded > unified)
        #expect(window.frame.height == 300 + expanded)
        #expect(display.view.frame.size == NSSize(width: window.frame.width, height: 300))
        // Every geometry update, such as Show Device Bezels', chooses the
        // style again.
        display.naturalSize = NSSize(width: threshold + 1, height: 300)
        controller.setDeviceBezelVisible(false)
        #expect(window.toolbarStyle == .unified)
        #expect(header() == unified)
        #expect(window.frame.height == 300 + unified)
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
        #expect(buttons() == [.home, .saveScreen, .rotateRight])

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try controller.session.startRecording(to: .file(directory.appendingPathComponent("Recording.mov")), mask: .ignored)
        let recording = try #require(controller.session.recording)
        let saveScreen = try #require(toolbar.items.first { $0.itemIdentifier.rawValue == "saveScreen" })
        for _ in 0..<200 where saveScreen.toolTip != "Stop Recording" { try await Task.sleep(for: .milliseconds(10)) }
        #expect(saveScreen.toolTip == "Stop Recording")
        // Simulator.app adds no item and does not measure its toolbar again,
        // so a display at the threshold keeps the unified style through the
        // next geometry update, with every button in the title bar.
        controller.setDeviceBezelVisible(false)
        #expect(window.toolbarStyle == .unified)
        #expect(buttons() == [.home, .saveScreen, .rotateRight])
        recording.stop()
        try await recording.waitUntilFinished()
    }

    @Test func titleBarPreferencesChooseTheCompactOrExpandedStyle() throws {
        // Simulator.app registers UseMonobar on and UseCompactTitleBar off.
        HostPreferences.registerDefaults()
        let registered = UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain)
        #expect(registered["UseMonobar"] as? Bool == true)
        #expect(registered["UseCompactTitleBar"] as? Bool == false)
        // Without values, as before the app registers them, the same.
        #expect(MemoryPreferences().usesMonobar)
        #expect(!MemoryPreferences().usesCompactTitleBar)
        // A value that `defaults write` saved as a string reads as
        // `boolForKey:` reads it.
        let defaults = RegisteredDefaults()
        defaults.set("NO", forKey: HostPreferences.useMonobar)
        defaults.set("YES", forKey: HostPreferences.useCompactTitleBar)
        #expect(!defaults.usesMonobar)
        #expect(defaults.usesCompactTitleBar)

        let preferences = MemoryPreferences()
        let display = TestDisplay()
        let controller = try makeController(display, preferences: preferences)
        defer { controller.invalidate() }
        controller.showWindow(nil)
        let window = try #require(controller.window)
        let wide = (Self.unifiedWidth() + 50).rounded(), narrow = (Self.unifiedWidth() - 50).rounded()
        // Each geometry update reads the preferences again.
        var headers: [NSWindow.ToolbarStyle: CGFloat] = [:]
        for (compact, monobar, wideStyle, narrowStyle) in [
            (false, true, NSWindow.ToolbarStyle.unified, NSWindow.ToolbarStyle.expanded),
            (true, true, .unifiedCompact, .unifiedCompact),
            (true, false, .unifiedCompact, .unifiedCompact),
            (false, false, .expanded, .expanded),
        ] {
            preferences.set(compact, forKey: HostPreferences.useCompactTitleBar)
            preferences.set(monobar, forKey: HostPreferences.useMonobar)
            for (width, style) in [(wide, wideStyle), (narrow, narrowStyle)] {
                display.naturalSize = NSSize(width: width, height: 300)
                controller.perform(.pointAccurate)
                #expect(window.toolbarStyle == style, "compact \(compact) monobar \(monobar) width \(width)")
                // The display fills the window below the title bar.
                #expect(display.view.frame == NSRect(x: 0, y: 0, width: width, height: 300))
                headers[style] = window.frame.height - 300
            }
        }
        // The compact title bar is the lowest and the expanded one the tallest.
        let compact = try #require(headers[.unifiedCompact]), unified = try #require(headers[.unified])
        let expanded = try #require(headers[.expanded])
        #expect(compact < unified && unified < expanded)
    }

    @Test func scaleCommandsLeaveRoomForTheTitleBarOfTheToolbarsStyle() throws {
        let display = TestDisplay()
        display.naturalSize = NSSize(width: 200, height: 400)
        let controller = try makeController(display)
        defer { controller.invalidate() }
        controller.showWindow(nil)
        let window = try #require(controller.window)
        let visible = try #require(window.screen?.visibleFrame)
        // A display narrower than the toolbar needs has the expanded title bar.
        controller.perform(.pointAccurate)
        #expect(window.toolbarStyle == .expanded)
        let header = window.frame.height - window.contentLayoutRect.height
        #expect(window.frame.height == 400 + header)
        // Fit Screen leaves room for that title bar and 20 points.
        let fit = try #require(controller.scale(for: .fitScreen))
        #expect(abs(fit - min((visible.width - 20) / 200, (visible.height - header - 20) / 400)) < 0.000_001)
        // A fixed scale must fit below it.
        display.naturalSize = NSSize(width: 200, height: visible.height - header)
        #expect(controller.canSetScale(.pointAccurate))
        display.naturalSize = NSSize(width: 200, height: visible.height - header + 1)
        #expect(!controller.canSetScale(.pointAccurate))
    }

    @Test func aManualResizeTakesTheStyleForItsWidthAndKeepsTheHeightBelowTheTitleBar() throws {
        let controller = try makeController(TestDisplay())
        defer { controller.invalidate() }
        controller.showWindow(nil)
        let window = try #require(controller.window)
        func header() -> CGFloat { window.frame.height - window.contentLayoutRect.height }
        func resize(width: CGFloat) {
            window.setContentSize(NSSize(width: width, height: window.frame.height))
            controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        }
        let wide = (Self.unifiedWidth() + 40).rounded(), narrow = (Self.unifiedWidth() - 40).rounded()
        window.setContentSize(NSSize(width: wide, height: 600))
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        #expect(window.toolbarStyle == .unified)
        let below = window.frame.height - header()
        // Like Simulator.app's windowDidResize:, the window grows by the
        // taller title bar when it becomes too narrow for the unified style,
        // and shrinks back.
        resize(width: narrow)
        #expect(window.toolbarStyle == .expanded)
        #expect(window.frame.height - header() == below)
        resize(width: wide)
        #expect(window.toolbarStyle == .unified)
        #expect(window.frame.height - header() == below)
        // In full screen, the style stays as it is.
        controller.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification, object: window))
        resize(width: narrow)
        #expect(window.toolbarStyle == .unified)
        controller.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: window))
    }

    @Test func theWindowIsBlackWithoutABezelAndClearAroundOne() throws {
        let display = TestDisplay()
        display.naturalSize = NSSize(width: 200, height: 300)
        display.bezel = NSSize(width: 20, height: 20)
        display.bezelPadding = NSSize(width: 9, height: 0)
        let controller = try makeController(display)
        defer { controller.invalidate() }
        controller.showWindow(nil)
        let window = try #require(controller.window)
        #expect(!window.isOpaque)
        #expect(window.backgroundColor == .clear)
        controller.setDeviceBezelVisible(false)
        #expect(window.backgroundColor == .black)
        controller.setDeviceBezelVisible(true)
        #expect(window.backgroundColor == .clear)
        // Like Simulator.app, full screen keeps the window's color when the
        // bezel is hidden, and leaving full screen turns it black.
        controller.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification, object: window))
        controller.setDeviceBezelVisible(false)
        #expect(window.backgroundColor == .clear)
        controller.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: window))
        #expect(window.backgroundColor == .black)
        // A window that opens without its bezel is black.
        let preferences = MemoryPreferences()
        preferences.set(false, forKey: HostPreferences.showChrome)
        let other = TestDisplay()
        other.bezel = NSSize(width: 20, height: 20)
        other.bezelPadding = NSSize(width: 9, height: 0)
        let bezelless = try makeController(other, preferences: preferences)
        defer { bezelless.invalidate() }
        #expect(bezelless.window?.backgroundColor == .black)
    }

    @Test func theTitleBarIsRoundedBelowOnlyAboveABezel() throws {
        let display = TestDisplay()
        display.bezel = NSSize(width: 20, height: 20)
        display.bezelPadding = NSSize(width: 9, height: 0)
        let controller = try makeController(display)
        defer { controller.invalidate() }
        controller.showWindow(nil)
        let window = try #require(controller.window)
        // As in Simulator.app's window, AppKit draws the title bar.
        #expect(!window.titlebarAppearsTransparent)
        // Like Simulator.app, the window rounds the layer of the
        // NSTitlebarContainerView that holds the title bar with the radius it
        // reads from the window's private `_cornerRadius`.
        var view: NSView? = window.standardWindowButton(.closeButton)
        while let current = view, current.className != "NSTitlebarContainerView" { view = current.superview }
        let layer = try #require(view?.layer)
        try #require(window.responds(to: NSSelectorFromString("_cornerRadius")))
        func windowRadius() throws -> CGFloat {
            CGFloat(try #require(window.value(forKey: "_cornerRadius") as? NSNumber).doubleValue)
        }
        for (width, style) in [((Self.unifiedWidth() + 40).rounded(), NSWindow.ToolbarStyle.unified),
                               ((Self.unifiedWidth() - 40).rounded(), .expanded)] {
            display.naturalSize = NSSize(width: width - 20, height: 300)
            controller.perform(.pointAccurate)
            #expect(window.toolbarStyle == style)
            #expect(layer.cornerRadius == (try windowRadius()))
            #expect(layer.cornerRadius > 0)
            #expect(layer.maskedCorners == [.layerMinXMinYCorner, .layerMaxXMinYCorner])
            #expect(layer.masksToBounds)
        }
        // Without the bezel, the title bar is square below.
        controller.setDeviceBezelVisible(false)
        #expect(layer.cornerRadius == 0)
        controller.setDeviceBezelVisible(true)
        #expect(layer.cornerRadius == (try windowRadius()))
        // So it is in full screen.
        controller.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification, object: window))
        #expect(layer.cornerRadius == 0)
        controller.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: window))
        #expect(layer.cornerRadius == (try windowRadius()))
        // The radius is the window's own: a window that reports another one
        // rounds the title bar with it.
        let selector = NSSelectorFromString("_cornerRadius")
        let original = try #require(class_getInstanceMethod(NSWindow.self, selector))
        let radius: @convention(block) (AnyObject) -> CGFloat = { _ in 7 }
        class_replaceMethod(DeviceWindow.self, selector, imp_implementationWithBlock(radius),
                            method_getTypeEncoding(original))
        defer {
            class_replaceMethod(DeviceWindow.self, selector, method_getImplementation(original),
                                method_getTypeEncoding(original))
        }
        controller.perform(.pointAccurate)
        #expect(layer.cornerRadius == 7)
    }

    @Test func windowFramesAreIntegralAtAFractionalScale() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // A devicectl stand-in that sets any orientation and reports landscape.
        let devicectl = directory.appendingPathComponent("devicectl")
        try """
            #!/bin/sh
            printf '{"result":{"deviceOrientation":"landscapeLeft","deviceOrientationNonFlat":"landscapeLeft"}}'
            """.write(to: devicectl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: devicectl.path)
        let portrait = NSSize(width: 161, height: 323), landscape = NSSize(width: 323, height: 161)
        func makeDisplay() -> TestDisplay {
            let display = TestDisplay()
            display.naturalSize = portrait
            display.bezel = NSSize(width: 21, height: 21)
            display.bezelPadding = NSSize(width: 10, height: 9)
            display.onRotation = { [unowned display] in display.naturalSize = $0 == 0 ? portrait : landscape }
            return display
        }
        // The device's window last closed at a fractional scale.
        let preferences = MemoryPreferences()
        preferences.setWindowGeometry(center: NSPoint(x: 300, y: 300), scale: 1.37, forDevice: "test-device",
                                      screens: NSScreen.screens.map(\.frame))
        var display = makeDisplay()
        let controller = try makeController(display, devicectl: devicectl, preferences: preferences)
        defer { controller.invalidate() }
        let window = try #require(controller.window)
        // Like Simulator.app's geometry update, the window takes the smallest
        // integral frame around the display and the space above it, and the
        // display fills the window below the gap.
        func isSizedToDisplay(gap: CGFloat = 1) -> Bool {
            let frame = window.frame, size = display.size(for: display.renderScale)
            let header = frame.height - window.contentLayoutRect.height
            let extra = NSSize(width: frame.width - size.width, height: frame.height - header - gap - size.height)
            return display.renderScale != display.renderScale.rounded()
                && [frame.minX, frame.minY, frame.width, frame.height].allSatisfy { $0 == $0.rounded() }
                && (0..<1).contains(extra.width) && (0..<1).contains(extra.height)
                && display.view.frame == NSRect(x: 0, y: 0, width: frame.width, height: frame.height - header - gap)
        }
        #expect(isSizedToDisplay(), "new window")
        display.screenScale = 1.43 * (window.screen?.backingScaleFactor ?? 1)
        controller.perform(.pixelAccurate)
        #expect(isSizedToDisplay(), "scale command")
        controller.perform(.landscapeLeft)
        for _ in 0..<300 where controller.session.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        #expect(display.rotations == [90])
        #expect(isSizedToDisplay(), "rotation")
        controller.setDeviceBezelVisible(false)
        #expect(isSizedToDisplay(gap: 0), "bezel hidden")
        controller.setDeviceBezelVisible(true)
        #expect(isSizedToDisplay(), "bezel shown")
        let visible = try #require(window.screen?.visibleFrame)
        window.setFrameOrigin(NSPoint(x: (visible.midX - window.frame.width / 2).rounded(),
                                      y: (visible.midY - window.frame.height / 2).rounded()))
        try drag(window, from: try point(of: .lowerRight, in: display), by: NSSize(width: 30.3, height: -20.6)) {
            #expect(isSizedToDisplay(), "bezel drag")
        }
        controller.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification, object: window))
        window.setFrame(NSRect(x: 100, y: 100, width: 300, height: 300), display: true)
        controller.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: window))
        #expect(isSizedToDisplay(), "full screen left")
        await controller.prepareForRestart()
        display = makeDisplay()
        controller.reconnect(try makeSession(display))
        #expect(isSizedToDisplay(), "restart")
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
                // The window takes the display's size, 10 points below its
                // header, and keeps the display's opposite corner.
                #expect(window.contentLayoutRect.size
                    == NSSize(width: display.view.frame.width, height: display.view.frame.height + 10))
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

    @Test func aPressOnTheBezelOutsideItsCornersMovesTheWindow() throws {
        var drags: [(window: NSWindow, event: NSEvent)] = []
        let (controller, display) = try makeBezelController { drags.append(($0, $1)) }
        defer { controller.invalidate() }
        let window = try #require(controller.window)
        let view = display.view, scale = display.renderScale
        // Like SimulatorKit's digitizer, the input view covers the device's
        // screen, inside the 10-point bezel, and the bezel next to it. A
        // button on the bezel takes its presses.
        display.input.frame = view.bounds.insetBy(dx: 3 * scale, dy: 3 * scale)
        let button = TestButton(frame: NSRect(x: view.bounds.maxX - 10 * scale, y: view.bounds.midY,
                                              width: 10 * scale, height: 30 * scale))
        view.addSubview(button)
        // A press on the bezel outside the digitizer reaches the window, which
        // moves with its drag, and so does a press that the digitizer passes on.
        let edge = view.convert(NSPoint(x: 1.5 * scale, y: view.bounds.midY), to: nil)
        #expect(try press(window, at: edge) === view)
        display.input.passesOnPresses = true
        let nextToScreen = view.convert(NSPoint(x: 6 * scale, y: view.bounds.midY), to: nil)
        #expect(try press(window, at: nextToScreen) === display.input)
        display.input.passesOnPresses = false
        #expect(drags.map(\.window) == [window, window])
        #expect(drags.map(\.event.locationInWindow) == [edge, nextToScreen])
        // Presses that the digitizer and the button keep reach the device.
        let screen = try press(window, at: view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil))
        let pressedButton = try press(window, at: view.convert(NSPoint(x: button.frame.midX, y: button.frame.midY), to: nil))
        #expect(screen === display.input && display.input.presses.count == 2)
        #expect(pressedButton === button && button.presses.count == 1)
        // A press on a corner resizes the window instead.
        try drag(window, from: try point(of: .lowerLeft, in: display), by: NSSize(width: -30, height: -55)) {
            #expect(display.isResizing)
        }
        // Like Simulator.app, where no view takes a press outside the display,
        // a press in the gap below the header that reaches the window moves it.
        let content = try #require(window.contentView)
        let gap = content.convert(NSPoint(
            x: view.frame.midX, y: view.frame.maxY + WindowScale.displayGap(bezelPadding: display.chromePadding) / 2), to: nil)
        #expect(try press(window, at: gap) === content)
        #expect(drags.map(\.event.locationInWindow) == [edge, nextToScreen, gap])
    }

    @Test func allowsMoveByDragOnWindowChromeTurnsMovingByTheBezelOff() throws {
        let preferences = MemoryPreferences()
        preferences.set(false, forKey: HostPreferences.allowsMoveByDragOnWindowChrome)
        var drags = 0
        let (controller, display) = try makeBezelController(preferences: preferences) { _, _ in drags += 1 }
        defer { controller.invalidate() }
        let window = try #require(controller.window)
        _ = try press(window, at: try pointOnBezel(of: display))
        #expect(drags == 0)
        // Like Simulator.app, which reads the preference at each press, the
        // next press follows a change.
        preferences.set(true, forKey: HostPreferences.allowsMoveByDragOnWindowChrome)
        _ = try press(window, at: try pointOnBezel(of: display))
        #expect(drags == 1)
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
            DeviceCapabilities.routableAudio, DeviceCapabilities.applePayAuthorization, DeviceCapabilities.keyboard,
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
        #expect(try visibleTitles("I/O") == ["Keyboard", "-", "Audio Input", "Audio Output", "Increase Volume",
                                              "Decrease Volume", "-", "Open URL…"])
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

    // MARK: Audio routes

    private static let microphone = HostAudioDevice(uid: "Microphone", name: "MacBook Pro Microphone",
                                                    inputChannels: 1, outputChannels: 0, defaultScopes: 1)
    private static let speakers = HostAudioDevice(uid: "Speakers", name: "MacBook Pro Speakers",
                                                  inputChannels: 0, outputChannels: 2, defaultScopes: 2)
    private static let loopback = HostAudioDevice(uid: "Loopback", name: "BlackHole 2ch",
                                                  inputChannels: 2, outputChannels: 2, defaultScopes: 0)
    private static let headset = HostAudioDevice(uid: "Headset", name: "USB Headset",
                                                 inputChannels: 1, outputChannels: 2, defaultScopes: 0)
    private static let routableFeatures = defaultFeatures.union([DeviceCapabilities.routableAudio])

    /// A controller whose device routes audio through `port`.
    private func makeAudioController(_ port: TestAudioRoutes?, device: String = "test-device",
                                     features: Set<String> = routableFeatures,
                                     preferences: MemoryPreferences) throws -> (DeviceWindowController, TestDisplay) {
        let display = TestDisplay()
        display.audioPort = port
        return (try makeController(display, features: features, device: device, preferences: preferences), display)
    }

    /// The text of `view`'s labels, such as an alert's.
    private func texts(in view: NSView?) -> [String] {
        guard let view else { return [] }
        return ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap { texts(in: $0) }
    }

    @Test func audioMenusAreAttachedForTheKeyDeviceThatRoutesAudio() throws {
        _ = NSApplication.shared
        let menus = MenuController(application: nil)
        menus.install()
        defer { NSApp.mainMenu = nil }
        let io = try #require(NSApp.mainMenu?.items.first { $0.title == "I/O" }?.submenu)
        let items = try ["Audio Input", "Audio Output"].map { title in try #require(io.items.first { $0.title == title }) }
        // Like Simulator.app, they follow Touch Pressure's separator and precede the volume commands.
        let titles = io.items.map { $0.isSeparatorItem ? "-" : $0.title }
        #expect(titles.prefix(7) == ["Keyboard", "Touch Pressure", "-", "Audio Input", "Audio Output",
                                     "Increase Volume", "Decrease Volume"])
        func attached(_ window: DeviceWindowController?) -> [String] {
            menus.updateAudioMenus(for: window)
            return items.map { "\($0.submenu?.title ?? "none")\($0.isEnabled ? "" : " (disabled)")" }
        }
        #expect(attached(nil) == ["none (disabled)", "none (disabled)"])
        let preferences = MemoryPreferences()
        let (routing, _) = try makeAudioController(TestAudioRoutes([Self.speakers]), preferences: preferences)
        defer { routing.invalidate() }
        #expect(attached(routing) == ["Audio Input", "Audio Output"])
        // A device without SimFeatureRoutableAudio leaves them disabled but shown.
        let (silent, _) = try makeAudioController(nil, device: "B", features: Self.defaultFeatures, preferences: preferences)
        defer { silent.invalidate() }
        #expect(attached(silent) == ["none (disabled)", "none (disabled)"])
        menus.updateVisibility(in: io, for: silent.session.capabilities)
        #expect(items.allSatisfy { !$0.isHidden })
        #expect(attached(routing) == ["Audio Input", "Audio Output"])
    }

    @Test func audioMenusListTheMacsDevicesAndCheckTheGuestsRoute() throws {
        _ = NSApplication.shared
        let preferences = MemoryPreferences()
        let port = TestAudioRoutes([Self.microphone, Self.loopback, Self.speakers, Self.headset])
        let (controller, _) = try makeAudioController(port, preferences: preferences)
        defer { controller.invalidate() }
        let input = AudioRouteMenu(scope: .input), output = AudioRouteMenu(scope: .output)
        func items(_ audio: AudioRouteMenu, keyDevice: Bool = true) -> [String] {
            let menu = NSMenu()
            audio.update(menu, for: keyDevice ? controller : nil)
            #expect(!menu.items.contains { $0.isSeparatorItem })
            return menu.items.map { "\($0.title)\($0.state == .on ? " ✓" : "")\($0.isEnabled ? "" : " (disabled)")" }
        }
        // Until the port reports, only System is listed.
        #expect(items(output) == ["System"])
        controller.session.connectAudioRoutes { Issue.record($0) }
        // System names the Mac's default device; each list has the devices
        // with channels in its direction, in the port's order.
        #expect(items(input) == ["System (MacBook Pro Microphone) ✓", "MacBook Pro Microphone", "BlackHole 2ch", "USB Headset"])
        #expect(items(output) == ["System (MacBook Pro Speakers) ✓", "BlackHole 2ch", "MacBook Pro Speakers", "USB Headset"])
        // The checkmark follows the guest's route, also one set elsewhere.
        preferences.set(["Headset"], forKey: HostPreferences.recentAudioOutputDeviceUIDs)
        port.report { $0.outputRoute = "Headset" }
        #expect(items(output) == ["System (MacBook Pro Speakers)", "BlackHole 2ch", "MacBook Pro Speakers", "USB Headset ✓"])
        // Without a default device in the list, System has no name.
        port.report { $0.defaultOutput = "Elsewhere" }
        #expect(items(output).first == "System")
        // A guest routed to a device the Mac lacks shows the Mac's default
        // device, as SimulatorKit selects it.
        #expect(port.current.outputRoute == "Headset")
        var state = port.current
        state.outputRoute = "Gone"
        #expect(state.selectedDevice(in: .output) == Self.speakers)
        #expect(state.selectedDevice(in: .input) == Self.microphone)

        // Like Simulator.app, the routes are available with any key device
        // window, and only then.
        (controller.session.display as? TestDisplay)?.isBooted = false
        #expect(!items(input).contains { $0.hasSuffix("(disabled)") })
        #expect(items(input, keyDevice: false) == ["System (disabled)"])
    }

    @Test func aChosenAudioRouteIsSavedAndAppliedToEveryDeviceWindow() throws {
        let preferences = MemoryPreferences()
        let ports = [TestAudioRoutes([Self.microphone, Self.loopback, Self.speakers]),
                     TestAudioRoutes([Self.microphone, Self.loopback, Self.speakers])]
        let (a, _) = try makeAudioController(ports[0], device: "A", preferences: preferences)
        let (b, _) = try makeAudioController(ports[1], device: "B", preferences: preferences)
        let (silent, silentDisplay) = try makeAudioController(TestAudioRoutes([Self.loopback]), device: "C",
                                                              features: Self.defaultFeatures, preferences: preferences)
        defer { [a, b, silent].forEach { $0.invalidate() } }
        for controller in [a, b, silent] { controller.session.connectAudioRoutes { Issue.record($0) } }
        // Both devices already follow System, which nothing has replaced.
        #expect(preferences.recentAudioRoutes(in: .output) == [AudioRouting.systemDefault])
        #expect(ports.allSatisfy { $0.requests.isEmpty })
        #expect(silentDisplay.audioConnections == 0)

        a.selectAudioRoute("Loopback", in: .output)
        #expect(preferences.values[HostPreferences.recentAudioOutputDeviceUIDs] as? [String]
            == ["Loopback", AudioRouting.systemDefault])
        #expect(ports.map(\.requests) == [["output Loopback"], ["output Loopback"]])
        #expect(ports.allSatisfy { $0.current.outputRoute == "Loopback" && $0.current.inputRoute == AudioRouting.systemDefault })
        #expect(preferences.recentAudioRoutes(in: .input) == [AudioRouting.systemDefault])

        // A device the Mac does not have is saved, and the guests keep their route.
        b.selectAudioRoute("Gone", in: .output)
        #expect(ports.map(\.requests) == [["output Loopback"], ["output Loopback"]])
        b.selectAudioRoute(AudioRouting.systemDefault, in: .output)
        #expect(ports.map(\.requests.last) == ["output \(AudioRouting.systemDefault)", "output \(AudioRouting.systemDefault)"])
        // The recent routes keep each route once, most recent first, and five at most.
        for route in ["Loopback", "One", "Two", "Three", "Gone"] { a.selectAudioRoute(route, in: .input) }
        #expect(preferences.recentAudioRoutes(in: .input) == ["Gone", "Three", "Two", "One", "Loopback"])
        #expect(preferences.recentAudioRoutes(in: .output) == [AudioRouting.systemDefault, "Gone", "Loopback"])
        // Like Simulator.app, an empty or foreign list is System alone.
        for stored in [[] as [Any], [1, 2] as [Any], "Loopback" as Any] {
            preferences.set(stored, forKey: HostPreferences.recentAudioInputDeviceUIDs)
            #expect(preferences.recentAudioRoutes(in: .input) == [AudioRouting.systemDefault])
        }
    }

    @Test func connectingAndPortChangesRouteToTheMostRecentRouteTheMacHas() throws {
        let preferences = MemoryPreferences()
        preferences.set(["Headset", "Loopback", AudioRouting.systemDefault], forKey: HostPreferences.recentAudioOutputDeviceUIDs)
        // The Mac lacks the headset: connecting routes the output to the
        // next recent route; the input stays at System.
        let port = TestAudioRoutes([Self.microphone, Self.loopback, Self.speakers])
        let (controller, _) = try makeAudioController(port, preferences: preferences)
        defer { controller.invalidate() }
        controller.session.connectAudioRoutes { Issue.record($0) }
        #expect(port.requests == ["output Loopback"])
        // The headset appears, and the output follows it.
        port.report { $0.devices.append(Self.headset) }
        #expect(port.requests.last == "output Headset")
        // It goes away: the next recent route that the Mac has.
        port.report { $0.devices.removeAll { $0 == Self.headset } }
        #expect(port.requests.last == "output Loopback")
        // Another process routes the guest elsewhere, and it comes back.
        port.report { $0.outputRoute = "Speakers" }
        #expect(port.requests.last == "output Loopback" && port.requests.count == 4)
        #expect(port.current.outputRoute == "Loopback")
        // A change that leaves the guest on its route asks for nothing.
        port.report { $0.defaultOutput = "Loopback" }
        #expect(port.requests.count == 4)
        // System needs a default device in its direction; without one and
        // without another recent route, the route stays.
        preferences.set([AudioRouting.systemDefault], forKey: HostPreferences.recentAudioOutputDeviceUIDs)
        port.report { $0.devices = [Self.microphone, Self.loopback] }
        #expect(port.requests.count == 4)
        port.report { $0.devices.append(Self.speakers) }
        #expect(port.requests.last == "output \(AudioRouting.systemDefault)")

        // A closed window no longer follows its device.
        controller.invalidate()
        #expect(port.isDisconnected)
        let count = port.requests.count
        port.report { $0.outputRoute = "Speakers" }
        #expect(port.requests.count == count)
    }

    @Test func audioRouteFailuresOfAChoiceArePresentedAndOthersLogged() throws {
        let preferences = MemoryPreferences()
        let port = TestAudioRoutes([Self.microphone, Self.loopback, Self.speakers])
        let (controller, _) = try makeAudioController(port, preferences: preferences)
        defer { controller.invalidate() }
        controller.showWindow(nil)
        let window = try #require(controller.window)
        // A failed route made on the device's own goes to the session's
        // handler, not to the window.
        preferences.set(["Loopback"], forKey: HostPreferences.recentAudioOutputDeviceUIDs)
        port.routeError = HostError.operation("port failed")
        var automatic: [String] = []
        controller.session.connectAudioRoutes { automatic.append($0.localizedDescription) }
        #expect(automatic == ["Could not route the audio output of Test iPhone to BlackHole 2ch: port failed"])
        #expect(window.attachedSheet == nil)
        // A chosen route's failure is presented on the window.
        controller.selectAudioRoute("Speakers", in: .output)
        #expect(port.requests == ["output Loopback", "output Speakers"])
        let sheet = try #require(window.attachedSheet)
        window.endSheet(sheet)
        port.routeError = nil
        port.refusal = HostError.operation("refused")
        controller.selectAudioRoute("Loopback", in: .output)
        window.endSheet(try #require(window.attachedSheet))

        // A device whose port does not connect reports why when a route is chosen.
        let (unconnected, display) = try makeAudioController(nil, device: "B", preferences: MemoryPreferences())
        defer { unconnected.invalidate() }
        unconnected.showWindow(nil)
        var reasons: [String] = []
        unconnected.session.connectAudioRoutes { reasons.append($0.localizedDescription) }
        #expect(display.audioConnections == 1 && reasons == ["The device has no audio route port."])
        #expect(unconnected.window?.attachedSheet == nil)
        unconnected.selectAudioRoute("Loopback", in: .input)
        let unavailable = try #require(unconnected.window?.attachedSheet)
        #expect(texts(in: unavailable.contentView).contains(
            "Could not change the audio input of Test iPhone: The device has no audio route port."))
        unconnected.window?.endSheet(unavailable)
    }

    // MARK: External displays

    private static let externalDisplayFeatures = defaultFeatures.union(
        [DeviceCapabilities.externalDisplay, DeviceCapabilities.integratedDisplay])

    /// A controller whose device has `screen` as its external display, connected as a new connection connects it.
    private func makeExternalDisplayController(_ screen: TestExternalScreen? = TestExternalScreen(),
                                               family: DeviceCapabilities.Family = .iPhone,
                                               features: Set<String> = Self.externalDisplayFeatures,
                                               device: String = "test-device",
                                               preferences: MemoryPreferences = MemoryPreferences(),
                                               externalDisplayChanges: ExternalDisplayChanges = ExternalDisplayChanges(),
                                               runtimeVersion: UInt32 = 0x1B_00_00,
                                               enhancedMultitasking: Bool = false,
                                               failure: @escaping @MainActor (Error) -> Void = { Issue.record($0) })
        throws -> (DeviceWindowController, TestDisplay) {
        let display = TestDisplay()
        display.externalScreen = screen
        let controller = try makeController(display, family: family, features: features, device: device,
                                            preferences: preferences, externalDisplayChanges: externalDisplayChanges,
                                            runtimeVersion: runtimeVersion, enhancedMultitasking: enhancedMultitasking)
        controller.session.connectExternalDisplay(failure: failure)
        return (controller, display)
    }

    /// The External Displays items with their checkmarks and enabling for `controller`.
    private func externalDisplayItems(for controller: DeviceWindowController?) -> [String] {
        ExternalDisplayMode.allCases.map { mode in
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            let enabled = DeviceCommand.command(mode.commandID).validate(item, for: controller)
            return "\(item.title)\(item.state == .on ? " ✓" : "")\(enabled ? "" : " (disabled)")"
        }
    }

    @Test func externalDisplaysFollowSimulatorAppsMenuAndFeatures() throws {
        _ = NSApplication.shared
        let menus = MenuController(application: nil)
        menus.install()
        defer { NSApp.mainMenu = nil }
        let io = try #require(NSApp.mainMenu?.items.first { $0.title == "I/O" }?.submenu)
        func titles(_ menu: NSMenu, visibleOnly: Bool = false) -> [String] {
            menu.items.filter { !visibleOnly || !$0.isHidden }.map { $0.isSeparatorItem ? "-" : $0.title }
        }
        // Like Simulator.app, the submenu follows the volume commands and a separator.
        #expect(titles(io).suffix(5) == ["Decrease Volume", "-", "External Displays", "-", "Open URL…"])
        let item = try #require(io.items.first { $0.title == "External Displays" })
        #expect(titles(try #require(item.submenu)) == [
            "Disabled", "-", "640×480", "720×480", "1024×768", "1280×720 (720p)", "1920×1080 (1080p)", "3840×2160 (4K)",
            "-", "CarPlay",
        ])
        #expect(item.submenu?.items.allSatisfy { $0.keyEquivalent.isEmpty } == true)
        // Shown for a device with an external display port and its own screen.
        for (features, shown) in [(Self.externalDisplayFeatures, true),
                                  (Self.defaultFeatures, false),
                                  (Self.defaultFeatures.union([DeviceCapabilities.externalDisplay]), false),
                                  (Self.defaultFeatures.union([DeviceCapabilities.integratedDisplay]), false)] {
            let controller = try makeController(TestDisplay(), features: features)
            defer { controller.invalidate() }
            menus.updateVisibility(in: io, for: controller.session.capabilities)
            #expect(item.isHidden == !shown)
            #expect(titles(io, visibleOnly: true).suffix(shown ? 5 : 3) == (shown
                ? ["Audio Output", "-", "External Displays", "-", "Open URL…"]
                : ["Audio Output", "-", "Open URL…"]))
        }
    }

    @Test func externalDisplayCheckmarksShowTheDisplaysActualState() throws {
        _ = NSApplication.shared
        let preferences = MemoryPreferences()
        let screen = TestExternalScreen()
        let (controller, display) = try makeExternalDisplayController(screen, preferences: preferences)
        defer { controller.invalidate() }
        // A saved choice that the display does not show is not checked.
        preferences.setExternalDisplayTag(ExternalDisplayMode.size1920x1080.rawValue, forDevice: "test-device")
        #expect(externalDisplayItems(for: controller) == [
            "Disabled ✓", "640×480", "720×480", "1024×768", "1280×720 (720p)", "1920×1080 (1080p)", "3840×2160 (4K)",
            "CarPlay (disabled)",
        ])
        // Another tool turns the display on.
        screen.report { $0 = ExternalScreenState(isPoweredOn: true, pixelSize: CGSize(width: 1280, height: 720), scale: 1) }
        #expect(externalDisplayItems(for: controller).filter { $0.hasSuffix("✓") } == ["1280×720 (720p) ✓"])
        // A size or scale that the menu does not offer checks nothing.
        screen.report { $0.pixelSize = CGSize(width: 1600, height: 900) }
        #expect(!externalDisplayItems(for: controller).contains { $0.hasSuffix("✓") })
        screen.report { $0 = ExternalScreenState(isPoweredOn: true, pixelSize: CGSize(width: 1280, height: 720), scale: 2) }
        #expect(!externalDisplayItems(for: controller).contains { $0.hasSuffix("✓") })
        // Like Simulator.app, the items stay enabled while the device restarts,
        // and its unknown display state checks nothing.
        display.isBooted = false
        controller.session.disconnect()
        #expect(externalDisplayItems(for: controller) == [
            "Disabled", "640×480", "720×480", "1024×768", "1280×720 (720p)", "1920×1080 (1080p)", "3840×2160 (4K)",
            "CarPlay (disabled)",
        ])
        // Without a device window, the items are disabled and unchecked.
        #expect(externalDisplayItems(for: nil).allSatisfy { $0.hasSuffix("(disabled)") && !$0.contains("✓") })
    }

    /// The External Displays items with a subtitle for `controller`, with
    /// their enabling.
    private func externalDisplaySubtitles(for controller: DeviceWindowController) -> [String] {
        ExternalDisplayMode.allCases.compactMap { mode in
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            let enabled = DeviceCommand.command(mode.commandID).validate(item, for: controller)
            return item.subtitle.map { "\(item.title)\(enabled ? "" : " (disabled)"): \($0)" }
        }
    }

    @Test func externalDisplayItemsSayWhichSizesTheDeviceCannotShow() throws {
        _ = NSApplication.shared
        // Like an iPad's screen: an exact 720×480 mode at 60 Hz and the
        // menu's sizes at 120 Hz.
        let screen = TestExternalScreen()
        screen.modes = [.exact720x480, .allowedAt120Hertz(scale: 2), .allowedAt120Hertz(scale: 1)]
        let (controller, display) = try makeExternalDisplayController(screen, features: Self.externalDisplayFeatures
            .union([DeviceCapabilities.carPlay]))
        defer { controller.invalidate() }
        // The guest would show 720×480 rather than 640×480, and CarPlay's
        // 800×480 at a scale of 2 has no mode.
        #expect(externalDisplaySubtitles(for: controller) == [
            "640×480 (disabled): This device shows 720×480", "CarPlay (disabled): Not available on this device",
        ])
        // Before the session reads the modes, as while the device restarts,
        // nothing is known to be unavailable.
        display.isBooted = false
        controller.session.disconnect()
        #expect(externalDisplaySubtitles(for: controller).isEmpty)

        // iPadOS before 27 cannot leave a 4K display on an iPad with Stage Manager.
        func iPad(runtime: UInt32, enhancedMultitasking: Bool) throws -> [String] {
            let screen = TestExternalScreen()
            let (controller, _) = try makeExternalDisplayController(
                screen, family: .iPad, runtimeVersion: runtime, enhancedMultitasking: enhancedMultitasking)
            defer { controller.invalidate() }
            return externalDisplaySubtitles(for: controller)
        }
        #expect(try iPad(runtime: 0x1A_05_00, enhancedMultitasking: true)
            == ["3840×2160 (4K) (disabled): Not available on this device"])
        #expect(try iPad(runtime: 0x12_06_00, enhancedMultitasking: true)
            == ["3840×2160 (4K) (disabled): Not available on this device"])
        #expect(try iPad(runtime: 0x1B_00_00, enhancedMultitasking: true).isEmpty)
        #expect(try iPad(runtime: 0x1A_05_00, enhancedMultitasking: false).isEmpty)
    }

    @Test func aSizeTheDeviceCannotShowChangesNothingAndSaysWhy() async throws {
        _ = NSApplication.shared
        let preferences = MemoryPreferences()
        // A choice that Simulator.app saved is restored when the device connects.
        preferences.setExternalDisplayTag(ExternalDisplayMode.size640x480.rawValue, forDevice: "test-device")
        let screen = TestExternalScreen()
        screen.modes = [.exact720x480, .allowedAt120Hertz(scale: 1)]
        var failures: [String] = []
        let (controller, _) = try makeExternalDisplayController(screen, preferences: preferences) {
            failures.append($0.localizedDescription)
        }
        defer { controller.invalidate() }
        try await wait { !failures.isEmpty }
        let reason = """
            Could not set the external display of Test iPhone to 640×480: The device would show its own 720×480 \
            mode instead, which has more pixels at up to 60 Hz.
            """
        #expect(failures == [reason])
        #expect(screen.requests.isEmpty && controller.session.externalDisplayMode == .disabled)
        // A size the device shows still applies, and a choice that reaches
        // the session anyway is presented on the device window.
        controller.showWindow(nil)
        controller.perform(.externalDisplay1920x1080)
        controller.perform(.externalDisplay640x480)
        #expect(controller.window?.attachedSheet == nil)
        controller.chooseExternalDisplay(.size640x480)
        #expect(screen.requests == ["mode 1920x1080@1"])
        #expect(controller.session.externalDisplayMode == .size1920x1080)
        let sheet = try #require(controller.window?.attachedSheet)
        #expect(texts(in: sheet.contentView).contains(reason))
        controller.window?.endSheet(sheet)
    }

    @Test func theExternalDisplaysWindowSaysWhichSizeTheGuestShows() throws {
        _ = NSApplication.shared
        let screen = TestExternalScreen()
        screen.modes = [.exact720x480, .allowedAt120Hertz(scale: 1)]
        let (controller, _) = try makeExternalDisplayController(screen)
        defer { controller.invalidate() }
        // Another tool sets 1920×1080 at 120 Hz, which the guest replaces with
        // its 720×480 mode in the display's top-left corner.
        screen.report {
            $0 = ExternalScreenState(isPoweredOn: true, pixelSize: CGSize(width: 1920, height: 1080), scale: 1,
                                     refreshRate: 120)
        }
        let window = try #require(controller.externalDisplayWindow?.window)
        #expect(window.subtitle == "External Display – Device Shows 720×480")
        screen.report { $0.refreshRate = 60 }
        #expect(window.subtitle == "External Display")
        screen.report { $0.pixelSize = CGSize(width: 640, height: 480) }
        #expect(window.subtitle == "External Display – Device Shows 720×480")
    }

    @Test func choosingASizeSavesItForTheDeviceAndSetsTheDisplaysMode() throws {
        let preferences = MemoryPreferences()
        preferences.updatePreferences(forDevice: "test-device") { $0["ConnectHardwareKeyboard"] = false }
        preferences.setExternalDisplayTag(ExternalDisplayMode.size640x480.rawValue, forDevice: "other-device")
        let screen = TestExternalScreen()
        let (controller, _) = try makeExternalDisplayController(screen, preferences: preferences)
        defer { controller.invalidate() }
        #expect(screen.requests.isEmpty)
        controller.perform(.externalDisplay1920x1080)
        #expect(screen.requests == ["mode 1920x1080@1"])
        #expect(controller.session.externalDisplayMode == .size1920x1080)
        // Simulator.app's key and tag, beside the device's other preferences
        // and the other devices' choices.
        let devices = try #require(preferences.values[HostPreferences.devicePreferences] as? [String: Any])
        let saved = try #require(devices["test-device"] as? [String: Any])
        #expect(saved["SimulatorExternalDisplay"] as? Int == 2614)
        #expect(saved["ConnectHardwareKeyboard"] as? Bool == false)
        #expect(preferences.externalDisplayTag(forDevice: "other-device") == 2214)
        controller.perform(.externalDisplay3840x2160)
        #expect(screen.requests == ["mode 1920x1080@1", "mode 3840x2160@1"])
        #expect(preferences.externalDisplayTag(forDevice: "test-device") == 2664)
    }

    @Test func disabledTurnsTheDisplayOffAndSavesTheChoice() throws {
        let preferences = MemoryPreferences()
        let screen = TestExternalScreen()
        let (controller, _) = try makeExternalDisplayController(screen, preferences: preferences)
        defer { controller.invalidate() }
        // Unlike Simulator.app, which turns off only a display whose window is
        // open, Disabled turns off also a display that is off.
        preferences.setExternalDisplayTag(ExternalDisplayMode.size720x480.rawValue, forDevice: "test-device")
        controller.perform(.externalDisplayDisabled)
        #expect(screen.requests == ["off"])
        #expect(preferences.externalDisplayTag(forDevice: "test-device") == 2114)
        controller.perform(.externalDisplay720x480)
        controller.perform(.externalDisplayDisabled)
        #expect(screen.requests == ["off", "mode 720x480@1", "off"])
        #expect(controller.session.externalDisplayMode == .disabled)
        #expect(preferences.externalDisplayTag(forDevice: "test-device") == 2114)
    }

    @Test func theExternalDisplaysWindowFollowsTheDisplay() throws {
        _ = NSApplication.shared
        let preferences = MemoryPreferences()
        let screen = TestExternalScreen()
        let (controller, _) = try makeExternalDisplayController(screen, preferences: preferences)
        defer { controller.invalidate() }
        #expect(controller.externalDisplayWindow == nil)
        // Like Simulator.app's screen monitor, a display that another tool
        // turns on gets its window too.
        screen.report { $0 = ExternalScreenState(isPoweredOn: true, pixelSize: CGSize(width: 720, height: 480), scale: 1) }
        let external = try #require(controller.externalDisplayWindow)
        let window = try #require(external.window)
        let display = try #require(screen.displays.last)
        #expect(screen.displays.count == 1 && external.display === display)
        #expect(window.isVisible)
        #expect(window.title == "Test iPhone" && window.subtitle == "External Display")
        // Without a toolbar or a bezel; resizable, below a title bar, black.
        #expect(window.toolbar == nil)
        #expect(window.styleMask == [.titled, .closable, .miniaturizable, .resizable])
        #expect(window.backgroundColor == .black)
        #expect(display.supportsTouchPressure == [false])
        // Like Simulator.app's window without a bezel, the display fills the
        // window below the title bar, with no gap, at its scale.
        func content() -> NSSize { window.contentRect(forFrameRect: window.frame).size }
        let scale = display.renderScale
        #expect(scale > 0 && scale <= 1)
        #expect(abs(content().width - 720 * scale) <= 1 && abs(content().height - 480 * scale) <= 1)
        #expect(window.contentAspectRatio == NSSize(width: 720, height: 480))
        // A new size keeps the display's scale. The smaller size fits any
        // screen that the first one fits at this scale.
        controller.perform(.externalDisplay640x480)
        #expect(controller.externalDisplayWindow === external && display.renderScale == scale)
        #expect(abs(content().width - 640 * scale) <= 1 && abs(content().height - 480 * scale) <= 1)
        #expect(window.contentAspectRatio == NSSize(width: 640, height: 480))
        // The display turning off closes the window without saving Disabled.
        screen.report { $0.isPoweredOn = false }
        #expect(controller.externalDisplayWindow == nil && !window.isVisible)
        #expect(display.disconnectCount == 1)
        #expect(preferences.externalDisplayTag(forDevice: "test-device") == 2214)
        // Turning it on again opens a new window with a new display.
        controller.perform(.externalDisplay720x480)
        #expect(controller.externalDisplayWindow != nil && screen.displays.count == 2)
    }

    @Test func closingTheExternalDisplaysWindowChoosesDisabled() throws {
        _ = NSApplication.shared
        let preferences = MemoryPreferences()
        let screen = TestExternalScreen()
        let (controller, _) = try makeExternalDisplayController(screen, preferences: preferences)
        defer { controller.invalidate() }
        controller.perform(.externalDisplay1280x720)
        #expect(preferences.externalDisplayTag(forDevice: "test-device") == 2414)
        let window = try #require(controller.externalDisplayWindow?.window)
        window.close()
        #expect(screen.requests == ["mode 1280x720@1", "off"])
        #expect(preferences.externalDisplayTag(forDevice: "test-device") == 2114)
        #expect(controller.externalDisplayWindow == nil)
        // Where the window closed is saved apart from the device window's place.
        let saved = preferences.windowGeometry(forDevice: "test-device", screens: NSScreen.screens.map(\.frame),
                                               kind: .externalDisplay)
        #expect(saved.center != nil && saved.scale != nil)
        #expect(preferences.windowGeometry(forDevice: "test-device", screens: NSScreen.screens.map(\.frame)).center == nil)
        // When turning the display off fails, its window opens again.
        controller.perform(.externalDisplay1280x720)
        screen.completionError = HostError.operation("power failed")
        try #require(controller.externalDisplayWindow?.window).close()
        #expect(controller.externalDisplayWindow != nil)
    }

    @Test func aChangeOfADeviceThatShutDownDoesNotHoldItsNextSession() throws {
        let preferences = MemoryPreferences()
        let changes = ExternalDisplayChanges()
        let screen = TestExternalScreen()
        screen.defersChanges = true
        let (shutDown, display) = try makeExternalDisplayController(screen, preferences: preferences,
                                                                    externalDisplayChanges: changes)
        // A size is in flight when the device shuts down, and its completion
        // does not come.
        shutDown.perform(.externalDisplay1920x1080)
        display.isBooted = false
        shutDown.invalidate()
        #expect(!changes.isBusy)
        // The device's next session restores its choice at once, and the
        // abandoned change's late completion changes nothing.
        preferences.setExternalDisplayTag(ExternalDisplayMode.size640x480.rawValue, forDevice: "test-device")
        let (booted, _) = try makeExternalDisplayController(screen, preferences: preferences,
                                                            externalDisplayChanges: changes)
        defer { booted.invalidate() }
        #expect(screen.requests == ["mode 1920x1080@1", "mode 640x480@1"])
        screen.deliver()
        #expect(!changes.isBusy && booted.session.externalDisplayMode == .size640x480)
    }

    @Test func aChangeWhoseCompletionNeverComesIsAbandonedAfterItsTimeout() async throws {
        let changes = ExternalDisplayChanges(completionTimeout: .milliseconds(50))
        let screen = TestExternalScreen()
        screen.defersChanges = true
        let (controller, _) = try makeExternalDisplayController(screen, externalDisplayChanges: changes)
        defer { controller.invalidate() }
        var failures: [String] = []
        controller.session.chooseExternalDisplay(.size1920x1080) { failures.append($0.localizedDescription) }
        controller.session.chooseExternalDisplay(.size640x480) { failures.append($0.localizedDescription) }
        #expect(screen.requests == ["mode 1920x1080@1"])
        // Each change is abandoned once its timeout passes, and the next goes.
        for _ in 0..<100 where failures.count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(screen.requests == ["mode 1920x1080@1", "mode 640x480@1"])
        #expect(failures == [
            "Could not set the external display of Test iPhone to 1920×1080 (1080p): CoreSimulator did not complete the change.",
            "Could not set the external display of Test iPhone to 640×480: CoreSimulator did not complete the change.",
        ])
    }

    @Test func aDeviceWindowThatClosesTurnsTheExternalDisplayOffAndKeepsTheChoice() throws {
        let preferences = MemoryPreferences()
        let screen = TestExternalScreen()
        let (controller, _) = try makeExternalDisplayController(screen, preferences: preferences)
        controller.perform(.externalDisplay1920x1080)
        let external = try #require(controller.externalDisplayWindow)
        controller.invalidate()
        #expect(screen.requests == ["mode 1920x1080@1", "off"])
        #expect(screen.isDisconnected)
        #expect(external.window?.isVisible == false)
        #expect(preferences.externalDisplayTag(forDevice: "test-device") == 2614)
        // A device that is no longer booted is left alone.
        let other = TestExternalScreen()
        let (shutDown, display) = try makeExternalDisplayController(other, preferences: preferences)
        #expect(other.requests == ["mode 1920x1080@1"])
        display.isBooted = false
        shutDown.invalidate()
        #expect(other.requests == ["mode 1920x1080@1"])
    }

    @Test func connectingRestoresTheDevicesSavedChoice() throws {
        let preferences = MemoryPreferences()
        preferences.setExternalDisplayTag(ExternalDisplayMode.size1280x720.rawValue, forDevice: "test-device")
        let screen = TestExternalScreen()
        let (controller, _) = try makeExternalDisplayController(screen, preferences: preferences)
        #expect(screen.requests == ["mode 1280x720@1"])
        #expect(controller.externalDisplayWindow != nil)
        controller.invalidate()
        // Disabled, the default, leaves a display that is on with its window,
        // as Simulator.app does.
        preferences.setExternalDisplayTag(ExternalDisplayMode.disabled.rawValue, forDevice: "test-device")
        let on = TestExternalScreen()
        on.current = ExternalScreenState(isPoweredOn: true, pixelSize: CGSize(width: 1920, height: 1080), scale: 1)
        let (second, _) = try makeExternalDisplayController(on, preferences: preferences)
        #expect(on.requests.isEmpty && second.externalDisplayWindow != nil)
        second.invalidate()
        // CarPlay on a device without CarPlay is not applied, and stays saved.
        preferences.setExternalDisplayTag(2714, forDevice: "test-device")
        let carPlay = TestExternalScreen()
        let (third, _) = try makeExternalDisplayController(carPlay, preferences: preferences)
        defer { third.invalidate() }
        #expect(carPlay.requests.isEmpty)
        #expect(preferences.externalDisplayTag(forDevice: "test-device") == 2714)
        // A device without the features does not connect.
        let display = TestDisplay()
        display.externalScreen = TestExternalScreen()
        let plain = try makeController(display)
        defer { plain.invalidate() }
        plain.session.connectExternalDisplay { Issue.record($0) }
        #expect(display.externalScreenConnections == 0)
    }

    @Test func aRestartClosesTheExternalDisplayAndItsReconnectionRestoresIt() async throws {
        let preferences = MemoryPreferences()
        let screen = TestExternalScreen()
        let (controller, _) = try makeExternalDisplayController(screen, preferences: preferences)
        defer { controller.invalidate() }
        controller.perform(.externalDisplay1024x768)
        let first = try #require(controller.externalDisplayWindow)
        await controller.prepareForRestart()
        // Like Simulator.app, the window disconnects while the device is still
        // booted, which turns the display off.
        #expect(controller.externalDisplayWindow == nil && first.window?.isVisible == false)
        #expect(screen.requests == ["mode 1024x768@1", "off"])
        // A choice made meanwhile is saved and applied by the reconnection.
        controller.perform(.externalDisplay1920x1080)
        #expect(screen.requests.count == 2)
        let display = TestDisplay()
        let rebooted = TestExternalScreen()
        display.externalScreen = rebooted
        let session = try makeSession(display, features: Self.externalDisplayFeatures, preferences: preferences)
        controller.reconnect(session)
        session.connectExternalDisplay { Issue.record($0) }
        #expect(rebooted.requests == ["mode 1920x1080@1"])
        let second = try #require(controller.externalDisplayWindow)
        #expect(second !== first && rebooted.displays.count == 1)
    }

    @Test func externalDisplayFailuresAreReported() async throws {
        let preferences = MemoryPreferences()
        var failures: [String] = []
        func choose(_ mode: ExternalDisplayMode, on controller: DeviceWindowController) {
            controller.session.chooseExternalDisplay(mode) { failures.append($0.localizedDescription) }
        }
        // A device without an external display port: the choice is saved, and
        // its failure is reported once the look-up for the display ends.
        let (portless, display) = try makeExternalDisplayController(nil, preferences: preferences)
        defer { portless.invalidate() }
        choose(.size1920x1080, on: portless)
        for _ in 0..<100 where failures.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(display.externalScreenConnections > 1)
        #expect(preferences.externalDisplayTag(forDevice: "test-device") == 2614)
        #expect(failures == [
            "Could not set the external display of Test iPhone to 1920×1080 (1080p): The device has no external display port.",
        ])
        // A size that no mode takes, and failures CoreSimulator reports later.
        let screen = TestExternalScreen()
        let (controller, _) = try makeExternalDisplayController(screen, device: "B", preferences: preferences)
        defer { controller.invalidate() }
        screen.refusal = HostError.operation("no mode")
        choose(.size640x480, on: controller)
        screen.refusal = nil
        screen.completionError = HostError.operation("mode failed")
        choose(.size640x480, on: controller)
        #expect(Array(failures.dropFirst()) == [
            "Could not set the external display of Test iPhone to 640×480: no mode",
            "Could not set the external display of Test iPhone to 640×480: mode failed",
        ])
        #expect(controller.externalDisplayWindow == nil)
        screen.completionError = nil
        choose(.size640x480, on: controller)
        screen.completionError = HostError.operation("power failed")
        choose(.disabled, on: controller)
        #expect(failures.last == "Could not turn off the external display of Test iPhone: power failed")
        #expect(controller.externalDisplayWindow != nil)
        // Restoring the saved choice reports to its own handler.
        var restored: [String] = []
        let failing = TestExternalScreen()
        failing.completionError = HostError.operation("restore failed")
        preferences.setExternalDisplayTag(ExternalDisplayMode.size640x480.rawValue, forDevice: "C")
        let (restoring, _) = try makeExternalDisplayController(failing, device: "C", preferences: preferences) {
            restored.append($0.localizedDescription)
        }
        defer { restoring.invalidate() }
        #expect(restored == ["Could not set the external display of Test iPhone to 640×480: restore failed"])
    }

    @Test func aChosenExternalDisplaysFailureIsPresentedOnItsDeviceWindow() throws {
        _ = NSApplication.shared
        let screen = TestExternalScreen()
        let (controller, _) = try makeExternalDisplayController(screen)
        defer { controller.invalidate() }
        controller.showWindow(nil)
        screen.completionError = HostError.operation("mode failed")
        controller.perform(.externalDisplay1024x768)
        let sheet = try #require(controller.window?.attachedSheet)
        #expect(texts(in: sheet.contentView).contains("Could not set the external display of Test iPhone to 1024×768: mode failed"))
        controller.window?.endSheet(sheet)
    }

    @Test func anExternalDisplayThatAppearsAfterTheDeviceConnectsIsRestoredAndFollowed() async throws {
        let preferences = MemoryPreferences()
        preferences.setExternalDisplayTag(ExternalDisplayMode.size1280x720.rawValue, forDevice: "test-device")
        var failures: [String] = []
        // SimulatorKit's screen adapter has not listed the TVOut screen yet.
        let (controller, display) = try makeExternalDisplayController(nil, preferences: preferences) {
            failures.append($0.localizedDescription)
        }
        defer { controller.invalidate() }
        #expect(controller.session.externalDisplayMode == nil)
        let screen = TestExternalScreen()
        display.externalScreen = screen
        for _ in 0..<100 where screen.requests.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        // The saved choice is applied once the screen appears, and the
        // display's changes are followed from then on.
        #expect(screen.requests == ["mode 1280x720@1"])
        #expect(controller.externalDisplayWindow != nil)
        #expect(failures.isEmpty)
        screen.report { $0.isPoweredOn = false }
        #expect(controller.session.externalDisplayMode == .disabled && controller.externalDisplayWindow == nil)
    }

    @Test func aChoiceWhileTheExternalDisplayIsLookedUpWaitsForIt() async throws {
        let preferences = MemoryPreferences()
        var failures: [String] = []
        let (controller, display) = try makeExternalDisplayController(nil, preferences: preferences) {
            failures.append($0.localizedDescription)
        }
        defer { controller.invalidate() }
        controller.session.chooseExternalDisplay(.size640x480) { failures.append($0.localizedDescription) }
        #expect(failures.isEmpty)
        let screen = TestExternalScreen()
        screen.current.isPoweredOn = true
        display.externalScreen = screen
        controller.session.chooseExternalDisplay(.disabled) { failures.append($0.localizedDescription) }
        for _ in 0..<100 where screen.requests.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        // The last choice, Disabled, turns off a display that is on.
        #expect(screen.requests == ["off"])
        #expect(failures.isEmpty)
    }

    @Test func aDeviceWhoseExternalDisplayNeverAppearsReportsTheChoice() async throws {
        let preferences = MemoryPreferences()
        preferences.setExternalDisplayTag(ExternalDisplayMode.size1920x1080.rawValue, forDevice: "test-device")
        var restored: [String] = []
        let (controller, display) = try makeExternalDisplayController(nil, preferences: preferences) {
            restored.append($0.localizedDescription)
        }
        defer { controller.invalidate() }
        var chosen: [String] = []
        controller.session.chooseExternalDisplay(.size1024x768) { chosen.append($0.localizedDescription) }
        for _ in 0..<1000 where chosen.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(chosen == [
            "Could not set the external display of Test iPhone to 1024×768: The device has no external display port.",
        ])
        #expect(restored.isEmpty)
        // The menu shows no state for it, and the items stay available.
        #expect(controller.session.externalDisplayMode == nil)
        #expect(externalDisplayItems(for: controller).allSatisfy {
            !$0.contains("✓") && ($0 == "CarPlay (disabled)") == $0.hasSuffix("(disabled)")
        })
        let lookups = display.externalScreenConnections
        controller.session.chooseExternalDisplay(.size1024x768) { chosen.append($0.localizedDescription) }
        #expect(chosen.count == 2 && display.externalScreenConnections == lookups + 1)
    }

    @Test func theLastExternalDisplayChoiceWinsOverChangesInFlight() throws {
        let preferences = MemoryPreferences()
        let screen = TestExternalScreen()
        screen.defersChanges = true
        let (controller, _) = try makeExternalDisplayController(screen, preferences: preferences)
        defer { controller.invalidate() }
        // Disabled right after a size, before CoreSimulator has turned the
        // display on, turns it off once that change completes.
        controller.perform(.externalDisplay1920x1080)
        controller.perform(.externalDisplayDisabled)
        #expect(screen.requests == ["mode 1920x1080@1"])
        screen.deliver()
        #expect(screen.requests == ["mode 1920x1080@1", "off"])
        screen.deliver()
        #expect(!screen.current.isPoweredOn && controller.session.externalDisplayMode == .disabled)
        #expect(preferences.externalDisplayTag(forDevice: "test-device") == 2114)
        // Of the choices made while a change is in flight, only the last follows it.
        controller.perform(.externalDisplay640x480)
        controller.perform(.externalDisplay1024x768)
        controller.perform(.externalDisplay3840x2160)
        screen.deliver()
        screen.deliver()
        #expect(Array(screen.requests.dropFirst(2)) == ["mode 640x480@1", "mode 3840x2160@1"])
        #expect(controller.session.externalDisplayMode == .size3840x2160)
    }

    @Test func aDeviceWindowThatClosesAfterAFailedChangeTurnsTheDisplayOff() throws {
        let screen = TestExternalScreen()
        screen.defersChanges = true
        let (controller, _) = try makeExternalDisplayController(screen)
        // A size completes before the display reports it; the next size fails
        // later. Closing the device window still turns the display off.
        controller.perform(.externalDisplay1920x1080)
        screen.deliverCompletions()
        screen.completionError = HostError.operation("mode failed")
        controller.perform(.externalDisplay1280x720)
        screen.deliverCompletions()
        screen.completionError = nil
        controller.invalidate()
        #expect(screen.requests == ["mode 1920x1080@1", "mode 1280x720@1", "off"])
        screen.deliver()
        #expect(!screen.current.isPoweredOn)
    }

    @Test func quittingWaitsForTheExternalDisplayChangesOfAClosedWindow() async throws {
        final class Result { var idle: Bool? }
        let changes = ExternalDisplayChanges()
        let screen = TestExternalScreen()
        screen.defersChanges = true
        let (controller, _) = try makeExternalDisplayController(screen, externalDisplayChanges: changes)
        #expect(controller.session.hasExternalDisplay)
        // The window closes, keeping the device running, while a size is in
        // flight. The device's changes outlive the session, and their wait
        // ends once the size and then the power-off have completed.
        controller.perform(.externalDisplay1920x1080)
        controller.invalidate()
        #expect(changes.isBusy)
        let result = Result()
        let wait = Task { result.idle = await changes.idle(before: .now + .seconds(60)) }
        await Task.yield()
        screen.deliver()
        await Task.yield()
        #expect(screen.requests == ["mode 1920x1080@1", "off"])
        #expect(result.idle == nil)
        screen.deliver()
        await wait.value
        #expect(result.idle == true && !changes.isBusy)
        #expect(!screen.current.isPoweredOn)
        // A power-off that does not complete ends the wait at its deadline.
        let held = TestExternalScreen()
        held.defersChanges = true
        let heldChanges = ExternalDisplayChanges()
        let (other, _) = try makeExternalDisplayController(held, externalDisplayChanges: heldChanges)
        other.invalidate()
        #expect(held.requests == ["off"])
        #expect(await !heldChanges.idle(before: .now + .milliseconds(50)))
    }

    @Test func aReopenedDevicesExternalDisplayFollowsThePowerOffOfItsClosedWindow() throws {
        let preferences = MemoryPreferences()
        let changes = ExternalDisplayChanges()
        let screen = TestExternalScreen()
        screen.defersChanges = true
        let (closed, _) = try makeExternalDisplayController(screen, preferences: preferences, externalDisplayChanges: changes)
        // The window closes, keeping the device running, while a size is in
        // flight, so its power-off waits. The reopened device's session then
        // restores the size, which follows that power-off.
        closed.perform(.externalDisplay1920x1080)
        closed.invalidate()
        let (reopened, _) = try makeExternalDisplayController(screen, preferences: preferences,
                                                              externalDisplayChanges: changes)
        defer { reopened.invalidate() }
        screen.deliver()
        screen.deliver()
        #expect(screen.requests.last == "mode 1920x1080@1")
        #expect(screen.current.isPoweredOn && reopened.session.externalDisplayMode == .size1920x1080)
        #expect(reopened.externalDisplayWindow != nil)
    }

    @Test func aDeviceWindowThatClosesDuringAChangeTurnsTheDisplayOffAfterIt() throws {
        let screen = TestExternalScreen()
        screen.defersChanges = true
        let (controller, _) = try makeExternalDisplayController(screen)
        controller.perform(.externalDisplay1920x1080)
        controller.invalidate()
        #expect(screen.requests == ["mode 1920x1080@1"])
        screen.deliver()
        #expect(screen.requests == ["mode 1920x1080@1", "off"])
        screen.deliver()
        #expect(!screen.current.isPoweredOn)
    }

    @Test func theExternalDisplaysWindowScalesAndTakesTheKeyboardWhileKey() throws {
        _ = NSApplication.shared
        let preferences = MemoryPreferences()
        let screen = TestExternalScreen()
        // Small enough for Point Accurate on any Mac screen, large enough for
        // Pixel Accurate's half scale on a Retina one.
        screen.current = ExternalScreenState(isPoweredOn: true, pixelSize: CGSize(width: 640, height: 480), scale: 1)
        let (controller, _) = try makeExternalDisplayController(screen, preferences: preferences)
        defer { controller.invalidate() }
        let external = try #require(controller.externalDisplayWindow)
        let window = try #require(external.window)
        let display = try #require(screen.displays.last)
        #expect(controller.scaledWindow === controller)
        external.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
        #expect(controller.scaledWindow === external)
        // The display takes the Mac's keyboard while its window is key.
        #expect(display.keyboard == [true])
        #expect(window.firstResponder === display.inputView)
        // The scale commands scale the key external display's window; Physical
        // Size is for a device's own screen.
        controller.perform(.pointAccurate)
        #expect(display.renderScale == 1)
        #expect(DeviceCommand.command(.pointAccurate).validate(NSMenuItem(), for: controller))
        #expect(!DeviceCommand.command(.physicalSize).validate(NSMenuItem(), for: controller))
        let backing = try #require(window.screen ?? NSScreen.main).backingScaleFactor
        controller.perform(.pixelAccurate)
        #expect(display.renderScale == 1 / backing)
        external.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: window))
        #expect(display.keyboard == [true, false])
        #expect(controller.scaledWindow === controller)
        // Its next window opens at the scale it closed at.
        window.close()
        controller.perform(.externalDisplay640x480)
        let reopened = try #require(screen.displays.last)
        #expect(reopened !== display && reopened.renderScale == 1 / backing)
    }

    @Test func theExternalDisplayFitsItsFullScreenWindowAgainWhenItTakesANewSize() throws {
        _ = NSApplication.shared
        let screen = TestExternalScreen()
        screen.current = ExternalScreenState(isPoweredOn: true, pixelSize: CGSize(width: 640, height: 480), scale: 1)
        let (controller, _) = try makeExternalDisplayController(screen)
        defer { controller.invalidate() }
        let external = try #require(controller.externalDisplayWindow)
        let window = try #require(external.window)
        let display = try #require(screen.displays.last)
        external.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification, object: window))
        window.setFrame(NSRect(x: 0, y: 0, width: 800, height: 600), display: true)
        let available = window.contentRect(forFrameRect: window.frame).size
        func fits() -> Bool {
            let size = display.size(for: display.renderScale)
            return size.width <= available.width + 0.5 && size.height <= available.height + 0.5
                && (abs(size.width - available.width) <= 0.5 || abs(size.height - available.height) <= 0.5)
        }
        #expect(fits())
        // SimulatorKit's display takes the new resolution after CoreSimulator
        // reports it; the display then fits the window again.
        controller.perform(.externalDisplay1920x1080)
        display.takeScreenSize(NSSize(width: 1920, height: 1080))
        #expect(fits())
    }

    @Test func aNewSizeDuringALiveResizeConstrainsTheExternalDisplaysWindowToIt() throws {
        _ = NSApplication.shared
        let screen = TestExternalScreen()
        screen.current = ExternalScreenState(isPoweredOn: true, pixelSize: CGSize(width: 640, height: 480), scale: 1)
        let (controller, _) = try makeExternalDisplayController(screen)
        defer { controller.invalidate() }
        let external = try #require(controller.externalDisplayWindow)
        let window = try #require(external.window)
        #expect(window.contentAspectRatio == NSSize(width: 640, height: 480))
        // Another tool changes the resolution while the window's edge is
        // dragged: the rest of the drag keeps the new aspect ratio and minimum.
        external.windowWillStartLiveResize(Notification(name: NSWindow.willStartLiveResizeNotification, object: window))
        screen.report { $0.pixelSize = CGSize(width: 1920, height: 1080) }
        #expect(window.contentAspectRatio == NSSize(width: 1920, height: 1080))
        let minimum = window.contentMinSize
        #expect(abs(minimum.width / minimum.height - 1920.0 / 1080.0) < 0.01)
        external.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: window))
        #expect(window.contentAspectRatio == NSSize(width: 1920, height: 1080))
    }

    @Test func theExternalDisplaysWindowGivesItsDisplayTheMacsModifiersWithTheFocus() throws {
        _ = NSApplication.shared
        let preferences = MemoryPreferences()
        preferences.updatePreferences(forDevice: "test-device") { $0["ConnectHardwareKeyboard"] = false }
        let screen = TestExternalScreen()
        screen.current = ExternalScreenState(isPoweredOn: true, pixelSize: CGSize(width: 640, height: 480), scale: 1)
        let (controller, _) = try makeExternalDisplayController(screen, preferences: preferences)
        defer { controller.invalidate() }
        let external = try #require(controller.externalDisplayWindow)
        let window = try #require(external.window)
        let display = try #require(screen.displays.last)
        // Without the Mac's keyboard, the digitizer still takes the modifiers
        // the Mac holds whenever the window becomes key, which it missed while
        // another window had the focus.
        external.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
        external.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: window))
        external.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
        #expect(display.keyboard.isEmpty)
        #expect(window.firstResponder === display.inputView)
        #expect(display.input.modifiers.count == 2)
        #expect(display.input.modifiers.last?.modifierFlags == NSEvent.modifierFlags)
    }

    // MARK: CarPlay

    private static let carPlayFeatures = externalDisplayFeatures.union([DeviceCapabilities.carPlay])

    @Test func carPlayFollowsSimulatorAppsMenuItemAndFeature() throws {
        _ = NSApplication.shared
        let menus = MenuController(application: nil)
        menus.install()
        defer { NSApp.mainMenu = nil }
        let io = try #require(NSApp.mainMenu?.items.first { $0.title == "I/O" }?.submenu)
        let submenu = try #require(io.items.first { $0.title == "External Displays" }?.submenu)
        // Like Simulator.app, CarPlay is the last item, after a separator.
        let item = try #require(submenu.items.last)
        #expect(item.title == "CarPlay" && item.keyEquivalent.isEmpty)
        #expect(submenu.items.dropLast().last?.isSeparatorItem == true)
        // It shows with the submenu and is enabled only for a device with
        // CarPlay, which alone can show it checked.
        for (features, enabled) in [(Self.carPlayFeatures, true), (Self.externalDisplayFeatures, false)] {
            let screen = TestExternalScreen()
            screen.current = ExternalScreenState(isPoweredOn: true, pixelSize: CGSize(width: 800, height: 480), scale: 2,
                                                 isCarPlay: true)
            let (controller, _) = try makeExternalDisplayController(screen, features: features)
            defer { controller.invalidate() }
            menus.updateVisibility(in: io, for: controller.session.capabilities)
            #expect(!item.isHidden && submenu.items.allSatisfy { !$0.isHidden })
            #expect(externalDisplayItems(for: controller).last == (enabled ? "CarPlay ✓" : "CarPlay (disabled)"))
        }
    }

    @Test func choosingCarPlayConfiguresTheGuestAndOpensACarPlayWindow() throws {
        _ = NSApplication.shared
        let preferences = MemoryPreferences()
        // A CarPlay window opens at Point Accurate whatever scale the device's
        // last external display window closed at, at that window's center.
        preferences.setWindowGeometry(center: NSPoint(x: 400, y: 300), scale: 0.5, forDevice: "test-device",
                                      screens: NSScreen.screens.map(\.frame), kind: .externalDisplay)
        let screen = TestExternalScreen()
        let (controller, _) = try makeExternalDisplayController(screen, features: Self.carPlayFeatures,
                                                                preferences: preferences)
        defer { controller.invalidate() }
        controller.perform(.externalDisplayCarPlay)
        // Like Simulator.app: the configuration that the guest reads when the
        // screen changes, the CarPlay screen, then the guest's CarPlay
        // session and the HID service that takes the touches.
        #expect(screen.requests == ["save carplay", "mode 800x480@2 carplay", "start carplay", "connect service"])
        #expect(preferences.externalDisplayTag(forDevice: "test-device") == 2714)
        #expect(controller.session.externalDisplayMode == .carPlay)
        #expect(externalDisplayItems(for: controller).filter { $0.hasSuffix("✓") } == ["CarPlay ✓"])
        let window = try #require(controller.externalDisplayWindow?.window)
        #expect(window.title == "Test iPhone" && window.subtitle == "CarPlay")
        #expect(window.collectionBehavior == [.fullScreenAuxiliary])
        let display = try #require(screen.displays.last)
        #expect(display.renderScale == 1 && display.supportsTouchPressure == [false])
        let content = window.contentRect(forFrameRect: window.frame).size
        #expect(abs(content.width - 400) <= 1 && abs(content.height - 240) <= 1)
        #expect(abs(window.frame.midX - 400) <= 1 && abs(window.frame.midY - 300) <= 1)
        // Closing the window chooses Disabled, which ends CarPlay once the
        // display is off.
        window.close()
        #expect(Array(screen.requests.dropFirst(4)) == ["save off", "off", "remove service", "stop carplay"])
        #expect(preferences.externalDisplayTag(forDevice: "test-device") == 2114)
    }

    @Test func aChangeEndsTheCarPlayThatThisHostStarted() throws {
        _ = NSApplication.shared
        let screen = TestExternalScreen()
        let (controller, _) = try makeExternalDisplayController(
            screen, features: Self.carPlayFeatures,
            externalDisplayChanges: ExternalDisplayChanges(carPlayReconnectionDelay: .zero))
        defer { controller.invalidate() }
        func requests(_ perform: () -> Void) -> [String] {
            let count = screen.requests.count
            perform()
            return Array(screen.requests.dropFirst(count))
        }
        // CarPlay chosen again ends the session it started and starts another.
        #expect(requests { controller.perform(.externalDisplayCarPlay) }
            == ["save carplay", "mode 800x480@2 carplay", "start carplay", "connect service"])
        let window = try #require(controller.externalDisplayWindow?.window)
        #expect(requests { controller.perform(.externalDisplayCarPlay) } == [
            "save carplay", "remove service", "stop carplay", "mode 800x480@2 carplay", "start carplay", "connect service",
        ])
        // A size ends CarPlay first and turns the guest's configuration off;
        // the window stays and names the external display again.
        #expect(requests { controller.perform(.externalDisplay1920x1080) }
            == ["save off", "remove service", "stop carplay", "mode 1920x1080@1"])
        #expect(controller.externalDisplayWindow?.window === window)
        #expect(window.subtitle == "External Display")
        #expect(window.collectionBehavior == [.fullScreenPrimary, .fullScreenAllowsTiling])
        // CarPlay from a size turns the display off first, so that the guest
        // takes the CarPlay screen as a new display, and a new window opens.
        #expect(requests { controller.perform(.externalDisplayCarPlay) }
            == ["save carplay", "off", "mode 800x480@2 carplay", "start carplay", "connect service"])
        #expect(controller.externalDisplayWindow?.window?.subtitle == "CarPlay")
        #expect(controller.externalDisplayWindow?.window !== window)
        // Disabled ends CarPlay once the display is off; a size afterwards
        // has no CarPlay to end.
        #expect(requests { controller.perform(.externalDisplayDisabled) }
            == ["save off", "off", "remove service", "stop carplay"])
        #expect(requests { controller.perform(.externalDisplay640x480) } == ["save off", "mode 640x480@1"])
    }

    @Test func carPlayWaitsUntilTheDisplayHasBeenOffForTheGuest() async throws {
        let screen = TestExternalScreen()
        let delay = Duration.milliseconds(200)
        let (controller, _) = try makeExternalDisplayController(
            screen, features: Self.carPlayFeatures, externalDisplayChanges: ExternalDisplayChanges(carPlayReconnectionDelay: delay))
        defer { controller.invalidate() }
        func waitForCarPlay() async throws {
            for _ in 0..<200 where screen.requests.last != "connect service" { try await Task.sleep(for: .milliseconds(10)) }
        }
        // A display that showed a size turns off, and the CarPlay screen
        // waits for the delay.
        controller.perform(.externalDisplay720x480)
        var start = ContinuousClock.now
        controller.perform(.externalDisplayCarPlay)
        #expect(screen.requests == ["save off", "mode 720x480@1", "save carplay", "off"])
        try await waitForCarPlay()
        #expect(ContinuousClock.now - start >= delay)
        #expect(screen.requests.suffix(3) == ["mode 800x480@2 carplay", "start carplay", "connect service"])
        // So does one that Disabled just turned off.
        controller.perform(.externalDisplayDisabled)
        start = ContinuousClock.now
        controller.perform(.externalDisplayCarPlay)
        #expect(screen.requests.last == "save carplay")
        try await waitForCarPlay()
        #expect(ContinuousClock.now - start >= delay * 0.9)
        // A display that has been off for longer, and one that already is a
        // CarPlay screen, change at once.
        controller.perform(.externalDisplayDisabled)
        try await Task.sleep(for: delay)
        let count = screen.requests.count
        controller.perform(.externalDisplayCarPlay)
        #expect(Array(screen.requests.dropFirst(count)) == ["save carplay", "mode 800x480@2 carplay", "start carplay", "connect service"])
        controller.perform(.externalDisplayCarPlay)
        #expect(screen.requests.last == "connect service")
    }

    @Test func closingTheDeviceWindowEndsCarPlayAndKeepsItsConfiguration() throws {
        let preferences = MemoryPreferences()
        let screen = TestExternalScreen()
        let (controller, _) = try makeExternalDisplayController(screen, features: Self.carPlayFeatures,
                                                                preferences: preferences)
        controller.perform(.externalDisplayCarPlay)
        controller.invalidate()
        // Like Simulator.app, the choice and the guest's configuration stay for
        // the next connection; unlike Simulator.app, the CarPlay that this host
        // started ends with the display.
        #expect(Array(screen.requests.dropFirst(4)) == ["off", "remove service", "stop carplay"])
        #expect(preferences.externalDisplayTag(forDevice: "test-device") == 2714)
    }

    @Test func connectingRestoresCarPlayAndANewBootHasNoSessionToEnd() throws {
        let preferences = MemoryPreferences()
        preferences.setExternalDisplayTag(ExternalDisplayMode.carPlay.rawValue, forDevice: "test-device")
        let changes = ExternalDisplayChanges()
        let screen = TestExternalScreen()
        let restored = ["save carplay", "mode 800x480@2 carplay", "start carplay", "connect service"]
        let (first, _) = try makeExternalDisplayController(screen, features: Self.carPlayFeatures,
                                                           preferences: preferences, externalDisplayChanges: changes)
        #expect(screen.requests == restored)
        #expect(first.externalDisplayWindow?.window?.subtitle == "CarPlay")
        // The device shuts down as its window closes, as a restart does, and
        // the display does not turn off, so the session is not ended. The
        // next boot starts without it: its connection ends nothing first.
        screen.completionError = HostError.operation("Invalid argument")
        first.invalidate()
        #expect(Array(screen.requests.dropFirst(4)) == ["off"])
        let rebooted = TestExternalScreen()
        rebooted.deviceBootDate = Date(timeIntervalSinceReferenceDate: 1)
        let (second, secondDisplay) = try makeExternalDisplayController(
            rebooted, features: Self.carPlayFeatures, preferences: preferences, externalDisplayChanges: changes)
        #expect(rebooted.requests == restored)
        // Nor after a window that disconnects from a device that shut down.
        secondDisplay.isBooted = false
        second.invalidate()
        #expect(rebooted.requests.count == 4)
        let third = TestExternalScreen()
        third.deviceBootDate = Date(timeIntervalSinceReferenceDate: 2)
        let (last, _) = try makeExternalDisplayController(third, features: Self.carPlayFeatures,
                                                          preferences: preferences, externalDisplayChanges: changes)
        defer { last.invalidate() }
        #expect(third.requests == restored)
    }

    @Test func aCarPlaySessionThatDidNotEndIsKeptInsteadOfAnother() throws {
        let screen = TestExternalScreen()
        let (controller, _) = try makeExternalDisplayController(screen, features: Self.carPlayFeatures)
        defer { controller.invalidate() }
        var failures: [String] = []
        func requests(choosing mode: ExternalDisplayMode) -> [String] {
            let count = screen.requests.count
            controller.session.chooseExternalDisplay(mode) { failures.append($0.localizedDescription) }
            return Array(screen.requests.dropFirst(count))
        }
        _ = requests(choosing: .carPlay)
        #expect(screen.carPlaySessions == 1)
        // CarPlay chosen again, whose session does not end: that session
        // stays the device's CarPlay, and its HID service comes back.
        screen.carPlayErrors = ["stop carplay": HostError.operation("busy")]
        #expect(requests(choosing: .carPlay)
            == ["save carplay", "remove service", "stop carplay", "mode 800x480@2 carplay", "connect service"])
        #expect(failures == ["Could not stop CarPlay on Test iPhone: busy"])
        #expect(screen.carPlaySessions == 1)
        // Disabled then ends it, and none is left.
        screen.carPlayErrors = [:]
        #expect(requests(choosing: .disabled) == ["save off", "off", "remove service", "stop carplay"])
        #expect(screen.carPlaySessions == 0 && failures.count == 1)
    }

    @Test func aCarPlayStartWithoutAnAnswerStopsSessionRequestsUntilTheDeviceRestarts() async throws {
        let preferences = MemoryPreferences()
        let changes = ExternalDisplayChanges(completionTimeout: .milliseconds(50), carPlayReconnectionDelay: .zero)
        let screen = TestExternalScreen()
        let (controller, _) = try makeExternalDisplayController(screen, features: Self.carPlayFeatures,
                                                                preferences: preferences, externalDisplayChanges: changes)
        var failures: [String] = []
        func choose(_ mode: ExternalDisplayMode, on controller: DeviceWindowController,
                    screen: TestExternalScreen) -> [String] {
            let count = screen.requests.count
            controller.session.chooseExternalDisplay(mode) { failures.append($0.localizedDescription) }
            return Array(screen.requests.dropFirst(count))
        }
        // The guest does not answer the start before the change stops
        // waiting, which leaves the session unknown and is reported once.
        screen.defersCarPlaySessions = true
        #expect(choose(.carPlay, on: controller, screen: screen)
            == ["save carplay", "mode 800x480@2 carplay", "start carplay"])
        for _ in 0..<100 where failures.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(failures == [
            "Could not start CarPlay on Test iPhone: The device did not answer, so NeoSimulator leaves its CarPlay session as it is until the device restarts.",
        ])
        // Its late answer changes nothing.
        screen.deliverCarPlaySessions()
        screen.defersCarPlaySessions = false
        // Until the device restarts, no session request is sent, while the
        // screen and the HID service still follow the choices.
        #expect(choose(.disabled, on: controller, screen: screen) == ["save off", "off"])
        #expect(choose(.carPlay, on: controller, screen: screen)
            == ["save carplay", "mode 800x480@2 carplay", "connect service"])
        #expect(choose(.size1920x1080, on: controller, screen: screen)
            == ["save off", "remove service", "mode 1920x1080@1"])
        #expect(failures.count == 1)
        controller.invalidate()
        // The next boot, which restores the size, starts CarPlay again.
        let rebooted = TestExternalScreen()
        rebooted.deviceBootDate = Date(timeIntervalSinceReferenceDate: 1)
        let (next, _) = try makeExternalDisplayController(rebooted, features: Self.carPlayFeatures,
                                                          preferences: preferences, externalDisplayChanges: changes)
        defer { next.invalidate() }
        #expect(choose(.carPlay, on: next, screen: rebooted)
            == ["save carplay", "off", "mode 800x480@2 carplay", "start carplay", "connect service"])
        #expect(rebooted.carPlaySessions == 1 && failures.count == 1)
    }

    @Test func aCarPlayEndWithoutAnAnswerStopsSessionRequestsToo() async throws {
        let screen = TestExternalScreen()
        let (controller, _) = try makeExternalDisplayController(
            screen, features: Self.carPlayFeatures,
            externalDisplayChanges: ExternalDisplayChanges(completionTimeout: .milliseconds(50),
                                                           carPlayReconnectionDelay: .zero))
        defer { controller.invalidate() }
        var failures: [String] = []
        func choose(_ mode: ExternalDisplayMode) -> [String] {
            let count = screen.requests.count
            controller.session.chooseExternalDisplay(mode) { failures.append($0.localizedDescription) }
            return Array(screen.requests.dropFirst(count))
        }
        _ = choose(.carPlay)
        #expect(screen.carPlaySessions == 1)
        screen.defersCarPlaySessions = true
        #expect(choose(.disabled) == ["save off", "off", "remove service", "stop carplay"])
        for _ in 0..<100 where failures.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(failures == [
            "Could not stop CarPlay on Test iPhone: The device did not answer, so NeoSimulator leaves its CarPlay session as it is until the device restarts.",
        ])
        // The end succeeds late, which changes nothing: CarPlay chosen again
        // starts no session beside one that may still run, and Disabled ends
        // none that may have ended.
        screen.deliverCarPlaySessions()
        screen.defersCarPlaySessions = false
        #expect(screen.carPlaySessions == 0)
        #expect(choose(.carPlay) == ["save carplay", "mode 800x480@2 carplay", "connect service"])
        #expect(choose(.disabled) == ["save off", "off", "remove service"])
        #expect(screen.carPlaySessions == 0 && failures.count == 1)
    }

    @Test func aDeviceThatRestartsDuringACarPlayChangeGetsNoEndOfASessionItLost() throws {
        let screen = TestExternalScreen()
        let (controller, _) = try makeExternalDisplayController(
            screen, features: Self.carPlayFeatures,
            externalDisplayChanges: ExternalDisplayChanges(carPlayReconnectionDelay: .zero))
        defer { controller.invalidate() }
        func choose(_ mode: ExternalDisplayMode) -> [String] {
            let count = screen.requests.count
            controller.session.chooseExternalDisplay(mode) { Issue.record($0) }
            return Array(screen.requests.dropFirst(count))
        }
        _ = choose(.carPlay)
        #expect(screen.carPlaySessions == 1)
        // The device restarts while Disabled waits for the HID service's
        // removal, as a restart that follows a closed window can.
        screen.defersCarPlayServices = true
        #expect(choose(.disabled) == ["save off", "off", "remove service"])
        screen.restart(boot: Date(timeIntervalSinceReferenceDate: 1))
        let count = screen.requests.count
        screen.deliverCarPlayServices()
        screen.defersCarPlayServices = false
        // The new boot gets no end of the session the restart took, and
        // CarPlay starts there as usual.
        #expect(screen.requests.count == count && screen.carPlaySessions == 0)
        #expect(Array(choose(.carPlay).suffix(2)) == ["start carplay", "connect service"])
        #expect(screen.carPlaySessions == 1)
    }

    @Test func aCarPlaySessionRequestThatRunsAfterARestartIsNotSent() throws {
        let screen = TestExternalScreen()
        let (controller, _) = try makeExternalDisplayController(
            screen, features: Self.carPlayFeatures,
            externalDisplayChanges: ExternalDisplayChanges(carPlayReconnectionDelay: .zero))
        defer { controller.invalidate() }
        func choose(_ mode: ExternalDisplayMode) -> [String] {
            let count = screen.requests.count
            controller.session.chooseExternalDisplay(mode) { Issue.record($0) }
            return Array(screen.requests.dropFirst(count))
        }
        _ = choose(.carPlay)
        // Disabled's end waits to run while the device restarts: it reaches
        // no guest, which is no failure.
        screen.defersCarPlaySessions = true
        #expect(choose(.disabled) == ["save off", "off", "remove service", "stop carplay"])
        screen.restart(boot: Date(timeIntervalSinceReferenceDate: 1))
        screen.deliverCarPlaySessions()
        screen.defersCarPlaySessions = false
        #expect(screen.carPlaySessions == 0)
        #expect(Array(choose(.carPlay).suffix(2)) == ["start carplay", "connect service"])
        #expect(screen.carPlaySessions == 1)
    }

    @Test func aCarPlayHIDServiceWithoutAnAnswerIsRemovedByTheNextChange() async throws {
        let screen = TestExternalScreen()
        let (controller, _) = try makeExternalDisplayController(
            screen, features: Self.carPlayFeatures,
            externalDisplayChanges: ExternalDisplayChanges(completionTimeout: .milliseconds(50),
                                                           carPlayReconnectionDelay: .zero))
        defer { controller.invalidate() }
        var failures: [String] = []
        func choose(_ mode: ExternalDisplayMode) -> [String] {
            let count = screen.requests.count
            controller.session.chooseExternalDisplay(mode) { failures.append($0.localizedDescription) }
            return Array(screen.requests.dropFirst(count))
        }
        func timeOut() async throws {
            let count = failures.count
            for _ in 0..<100 where failures.count == count { try await Task.sleep(for: .milliseconds(20)) }
        }
        // A start without an answer leaves the session unknown.
        screen.defersCarPlaySessions = true
        _ = choose(.carPlay)
        try await timeOut()
        // CarPlay chosen again creates the HID service, whose answer does not
        // come either.
        screen.defersCarPlayServices = true
        #expect(choose(.carPlay) == ["save carplay", "mode 800x480@2 carplay", "connect service"])
        try await timeOut()
        #expect(failures.last
            == "Could not connect the CarPlay touch screen of Test iPhone: CoreSimulator did not complete the change.")
        // The service may exist, so Disabled removes it.
        screen.defersCarPlayServices = false
        #expect(choose(.disabled) == ["save off", "off", "remove service"])
        #expect(failures.count == 2)
    }

    @Test func carPlaySessionStateMovesOnlyOnAnswersOfItsBoot() {
        let first = Date(timeIntervalSinceReferenceDate: 0)
        let second = Date(timeIntervalSinceReferenceDate: 1)
        var state = CarPlaySessionState()
        #expect(state.session(in: first) == .none && !state.hasService(in: first))
        // A start that fails leaves none; one that succeeds starts it, with
        // its HID service. An end that fails leaves it started.
        state.willSend(in: first)
        state.sessionAnswered(starting: true, succeeded: false, in: first)
        #expect(state.session(in: first) == .none)
        state.sessionAnswered(starting: true, succeeded: true, in: first)
        state.serviceAnswered(created: true, succeeded: true, in: first)
        state.sessionAnswered(starting: false, succeeded: false, in: first)
        #expect(state.session(in: first) == .started && state.hasService(in: first))
        // A new boot has no session or service, and answers from the earlier
        // boot, for the session or the service, change nothing in it.
        #expect(state.session(in: second) == .none && !state.hasService(in: second))
        state.willSend(in: second)
        state.sessionAnswered(starting: true, succeeded: true, in: second)
        state.serviceAnswered(created: true, succeeded: true, in: second)
        state.sessionAnswered(starting: false, succeeded: true, in: first)
        state.serviceAnswered(created: false, succeeded: true, in: first)
        state.timedOut(in: first)
        #expect(state.session(in: second) == .started && state.hasService(in: second))
        // An answer that did not come in time leaves the session unknown,
        // which later answers do not change, until another boot.
        state.timedOut(in: second)
        state.sessionAnswered(starting: false, succeeded: true, in: second)
        #expect(state.session(in: second) == .unknown && state.hasService(in: second))
        state.serviceAnswered(created: false, succeeded: true, in: second)
        #expect(!state.hasService(in: second))
        let third = Date(timeIntervalSinceReferenceDate: 2)
        #expect(state.session(in: third) == .none)
    }

    @Test func carPlayFailuresAreReportedTogether() throws {
        _ = NSApplication.shared
        let screen = TestExternalScreen()
        let (controller, _) = try makeExternalDisplayController(
            screen, features: Self.carPlayFeatures,
            externalDisplayChanges: ExternalDisplayChanges(carPlayReconnectionDelay: .zero))
        defer { controller.invalidate() }
        var failures: [String] = []
        func choose(_ mode: ExternalDisplayMode) {
            controller.session.chooseExternalDisplay(mode) { failures.append($0.localizedDescription) }
        }
        // A configuration that is not saved is reported, and the change goes on.
        screen.carPlayErrors = ["save carplay": HostError.operation("disk full")]
        choose(.carPlay)
        #expect(screen.requests == ["save carplay", "mode 800x480@2 carplay", "start carplay", "connect service"])
        #expect(failures == ["Could not save the CarPlay configuration of Test iPhone: disk full"])
        // Ending CarPlay fails in both steps, and the size is still set; the
        // failures of one change come together.
        screen.carPlayErrors = ["remove service": HostError.operation("no port"),
                                "stop carplay": HostError.operation("no bridge")]
        choose(.size1280x720)
        #expect(screen.requests.suffix(4) == ["save off", "remove service", "stop carplay", "mode 1280x720@1"])
        #expect(failures.last == """
            Could not disconnect the CarPlay touch screen of Test iPhone: no port
            Could not stop CarPlay on Test iPhone: no bridge
            """)
        // A session that did not end is ended by the next change.
        screen.carPlayErrors = [:]
        choose(.size640x480)
        #expect(screen.requests.suffix(4) == ["save off", "remove service", "stop carplay", "mode 640x480@1"])
        // A session that does not start gets no HID service, and leaves nothing
        // to end.
        screen.carPlayErrors = ["start carplay": HostError.operation("no CarPlay")]
        var count = screen.requests.count
        choose(.carPlay)
        #expect(Array(screen.requests.dropFirst(count))
            == ["save carplay", "off", "mode 800x480@2 carplay", "start carplay"])
        #expect(failures.last == "Could not start CarPlay on Test iPhone: no CarPlay")
        screen.carPlayErrors = ["connect service": HostError.operation("send failed")]
        count = screen.requests.count
        choose(.carPlay)
        #expect(Array(screen.requests.dropFirst(count))
            == ["save carplay", "mode 800x480@2 carplay", "start carplay", "connect service"])
        #expect(failures.last == "Could not connect the CarPlay touch screen of Test iPhone: send failed")
        // A CarPlay screen that is not set starts no CarPlay.
        screen.carPlayErrors = [:]
        screen.completionError = HostError.operation("mode failed")
        count = screen.requests.count
        choose(.carPlay)
        #expect(Array(screen.requests.dropFirst(count)) == [
            "save carplay", "remove service", "stop carplay", "mode 800x480@2 carplay",
        ])
        #expect(failures.last == "Could not set the external display of Test iPhone to CarPlay: mode failed")
        // On the device window, the failures of a choice share one alert.
        screen.completionError = nil
        controller.showWindow(nil)
        screen.carPlayErrors = ["save carplay": HostError.operation("disk full"),
                                "start carplay": HostError.operation("no CarPlay")]
        controller.perform(.externalDisplayCarPlay)
        let sheet = try #require(controller.window?.attachedSheet)
        #expect(texts(in: sheet.contentView).contains("""
            Could not save the CarPlay configuration of Test iPhone: disk full
            Could not start CarPlay on Test iPhone: no CarPlay
            """))
        controller.window?.endSheet(sheet)
    }

    @Test func carPlayConfigurationIsWrittenAsSimulatorAppWritesIt() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Library/Application Support/Simulator/extended_display.plist")
        func read() throws -> NSDictionary {
            try #require(NSDictionary(contentsOf: file))
        }
        // The folder is created, and CarPlay writes Simulator.app's default
        // configuration under its plain keys.
        try CarPlayConfiguration.save(carPlay: true, to: file)
        #expect(try read() == [
            "stark": true, "width": 800, "height": 480, "scale": 2.0, "hasBackButton": false, "hasHomeButton": false,
            "hasWheel": false, "hasWheelBump": false, "hasTouchScreen": true, "hasTouchScreenLofi": false,
            "protocols": [String](),
        ] as NSDictionary)
        // Every other choice replaces it with stark off.
        try CarPlayConfiguration.save(carPlay: false, to: file)
        #expect(try read() == ["stark": 0] as NSDictionary)
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

    // MARK: Keyboard and touch pressure

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
        // Audio Input and Audio Output stay shown, as in Simulator.app.
        #expect(visible([DeviceCapabilities.keyboard, DeviceCapabilities.touchPressure])
            == ["Keyboard", "Touch Pressure", "-", "Audio Input", "Audio Output", "-", "Open URL…"])
        // Each submenu needs its feature.
        #expect(visible([DeviceCapabilities.touchPressure])
            == ["Touch Pressure", "-", "Audio Input", "Audio Output", "-", "Open URL…"])
        #expect(visible([]) == ["Audio Input", "Audio Output", "-", "Open URL…"])
        func items(_ title: String) throws -> [NSMenuItem] {
            try #require(io.items.first { $0.title == title }?.submenu).items
        }
        let keyboard = try items("Keyboard"), pressure = try items("Touch Pressure")
        #expect(keyboard.map(\.title) == ["Use the Same Keyboard Language as macOS", "Connect Hardware Keyboard",
                                          "Toggle Software Keyboard"])
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
        for _ in 0..<100 where first.hardwareKeyboard.isEmpty { await Task.yield() }
        #expect(first.hardwareKeyboard == [false])
        // Simulator.app's key: DevicePreferences[UDID].ConnectHardwareKeyboard.
        let devices = preferences.values[HostPreferences.devicePreferences] as? [String: [String: Any]]
        #expect(devices?["A"]?[HostPreferences.connectHardwareKeyboard] as? Bool == false)
        #expect(connect.state?(a) == .off && connect.state?(b) == .on)
        // Without a hardware keyboard, the Mac's keyboard does not type into
        // the device, also when its window becomes key again, and the
        // software keyboard cannot be toggled.
        #expect(first.keyboard == [true, false])
        a.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: a.window))
        a.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: a.window))
        #expect(first.keyboard == [true, false])
        #expect(!software.isEnabled(a) && software.isEnabled(b))
        a.perform(.toggleSoftwareKeyboard)
        #expect(first.events.isEmpty)
        #expect(second.hardwareKeyboard.isEmpty)

        a.perform(.connectHardwareKeyboard)
        for _ in 0..<100 where first.hardwareKeyboard.count < 2 { await Task.yield() }
        #expect(first.hardwareKeyboard == [false, true] && first.keyboard == [true, false, true])
        #expect(connect.state?(a) == .on && software.isEnabled(a))
    }

    @Test func aFailedHardwareKeyboardChangeIsReportedAndKept() async throws {
        let preferences = MemoryPreferences()
        let display = TestDisplay()
        display.hardwareKeyboardError = HostError.operation("keyboard failed")
        let controller = try makeController(display, preferences: preferences)
        defer { controller.invalidate() }
        controller.showWindow(nil)
        let window = try #require(controller.window)
        controller.perform(.connectHardwareKeyboard)
        for _ in 0..<100 where window.attachedSheet == nil { await Task.yield() }
        #expect(try #require(window.attachedSheet).isVisible)
        // Like Simulator.app, the choice is saved before it is applied, so it
        // stays; choosing again retries.
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
        // Without choices, the device gets a hardware keyboard and the Mac's language.
        var (display, failures) = try await apply(MemoryPreferences())
        #expect(display.hardwareKeyboard == [true] && display.keyboardLanguages == ["ja"] && failures.isEmpty)
        // The device's own choice comes first, then the app-wide value.
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

        // Use the Same Keyboard Language as macOS off leaves the language alone.
        preferences.set(false, forKey: HostPreferences.enableKeyboardSync)
        (display, failures) = try await apply(preferences)
        #expect(display.keyboardLanguages.isEmpty && failures.isEmpty)

        // A language that cannot be determined, and each failed change, are
        // reported without stopping the other change.
        (display, failures) = try await apply(MemoryPreferences(), language: nil)
        #expect(display.hardwareKeyboard == [true] && display.keyboardLanguages.isEmpty && failures.count == 1)
        let failing = TestDisplay()
        failing.hardwareKeyboardError = HostError.operation("keyboard failed")
        failing.keyboardLanguageError = HostError.operation("language failed")
        (display, failures) = try await apply(MemoryPreferences(), failing: failing)
        #expect(display.hardwareKeyboard == [true] && display.keyboardLanguages == ["ja"])
        #expect(failures == ["keyboard failed", "language failed"])
    }

    @Test func theMacsInputSourceReachesTheKeyDeviceWhileLanguageSyncIsOn() async throws {
        let preferences = MemoryPreferences()
        var language = "en"
        let first = TestDisplay(), second = TestDisplay()
        let a = try makeController(first, device: "A", preferences: preferences, keyboardLanguage: { language })
        let b = try makeController(second, device: "B", preferences: preferences, keyboardLanguage: { language })
        defer { a.invalidate(); b.invalidate() }
        func changeInputSource(to new: String) async {
            language = new
            NotificationCenter.default.post(name: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil)
            for _ in 0..<10 { await Task.yield() }
        }
        await changeInputSource(to: "en")
        #expect(first.keyboardLanguages.isEmpty && second.keyboardLanguages.isEmpty)
        a.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: a.window))
        await changeInputSource(to: "ja")
        #expect(first.keyboardLanguages == ["ja"] && second.keyboardLanguages.isEmpty)
        a.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: a.window))
        b.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: b.window))
        await changeInputSource(to: "de")
        #expect(first.keyboardLanguages == ["ja"] && second.keyboardLanguages == ["de"])

        // Like Simulator.app, the command changes only the app-wide preference.
        let sync = DeviceCommand.command(.syncKeyboardLanguage)
        #expect(sync.state?(a) == .on)
        b.perform(.syncKeyboardLanguage)
        #expect(preferences.values[HostPreferences.enableKeyboardSync] as? Bool == false)
        #expect(sync.state?(a) == .off && sync.state?(b) == .off)
        await changeInputSource(to: "fr")
        #expect(second.keyboardLanguages == ["de"])
        b.perform(.syncKeyboardLanguage)
        #expect(second.keyboardLanguages == ["de"])
        b.invalidate()
        await changeInputSource(to: "it")
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
        // Like Simulator.app, a display takes pressure on the own screen of a
        // device that takes it, and the trackpad's force with a Force Touch trackpad.
        #expect([watch, phone, other, external].map(\.supportsTouchPressure) == [[true], [true], [false], [false]])
        #expect(watch.usesTrackpadForce == [true] && watch.touchModes == [.shallow])

        let force = DeviceCommand.command(.useTrackpadForce)
        #expect(force.isEnabled(p) && force.state?(p) == .on)
        p.perform(.useTrackpadForce)
        #expect(preferences.values[HostPreferences.useTrackpadForce] as? Bool == false)
        #expect(force.state?(w) == .off)
        #expect(watch.usesTrackpadForce == [true, false] && phone.usesTrackpadForce == [true, false])
        #expect(other.usesTrackpadForce == [true])
        // Without a Force Touch trackpad, the option is off and unavailable.
        p.perform(.useTrackpadForce)
        #expect(force.state?(p) == .on)
        trackpad = false
        #expect(!force.isEnabled(p) && force.state?(p) == .off)

        // Shallow and Deep Press need a watch, and change every window that
        // takes touch pressure.
        let shallow = DeviceCommand.command(.shallowPress), deep = DeviceCommand.command(.deepPress)
        #expect(shallow.isEnabled(w) && deep.isEnabled(w) && !deep.isEnabled(p))
        #expect(shallow.state?(w) == .on && deep.state?(w) == .off && shallow.state?(p) == .off)
        p.perform(.deepPress)
        #expect(watch.touchModes.last == .shallow)
        w.perform(.deepPress)
        #expect(watch.touchModes.last == .deep && phone.touchModes.last == .deep && other.touchModes == [.shallow])
        #expect(shallow.state?(w) == .off && deep.state?(w) == .on && deep.state?(p) == .off)
        // A window that opens later, or reconnects after a restart, takes the
        // app's settings.
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
        // The window uses a trackpad connected after it opened, as the menu then shows.
        trackpad = true
        trackpadsChanged?()
        #expect(display.usesTrackpadForce == [false, true])
        #expect(DeviceCommand.command(.useTrackpadForce).state?(controller) == .on)
        // A change that leaves the Force Touch trackpads as they were applies nothing.
        trackpadsChanged?()
        #expect(display.usesTrackpadForce == [false, true])
        trackpad = false
        trackpadsChanged?()
        #expect(display.usesTrackpadForce == [false, true, false])
    }

    @Test func touchIndicatorsFollowTheirPreferencesInEveryOpenWindow() async throws {
        let preferences = MemoryPreferences()
        let first = TestDisplay(), second = TestDisplay(), elsewhere = TestDisplay()
        let a = try makeController(first, device: "A", preferences: preferences)
        let b = try makeController(second, device: "B", preferences: preferences)
        // A window whose preferences are kept in another store.
        let c = try makeController(elsewhere, device: "C")
        defer { for controller in [a, b, c] { controller.invalidate() } }
        // A new window draws pinches unless they were turned off, and nothing else.
        #expect(first.touchIndicators == [.pinches] && elsewhere.touchIndicators == [.pinches])

        preferences.set(true, forKey: HostPreferences.showSingleTouches)
        preferences.set(false, forKey: HostPreferences.showPinches)
        preferences.set(true, forKey: HostPreferences.highlightEdgeGestures)
        NotificationCenter.default.post(name: TouchIndicator.didChangeNotification, object: preferences)
        #expect(first.touchIndicators == [.singleTouches, .edgeGestures])
        #expect(second.touchIndicators == [.singleTouches, .edgeGestures])
        #expect(elsewhere.touchIndicators == [.pinches])

        // A window draws them again on the display of its next connection.
        await a.prepareForRestart()
        let restarted = TestDisplay()
        a.reconnect(try makeSession(restarted, device: "A", preferences: preferences))
        #expect(restarted.touchIndicators == [.singleTouches, .edgeGestures])
        // A closed window follows no more changes.
        b.invalidate()
        preferences.set(true, forKey: HostPreferences.showPinchPivotPoint)
        NotificationCenter.default.post(name: TouchIndicator.didChangeNotification, object: preferences)
        #expect(restarted.touchIndicators == [.singleTouches, .pinchPivotPoint, .edgeGestures])
        #expect(second.touchIndicators == [.singleTouches, .edgeGestures])
    }

    @Test func settingsShowAppKitsPanelForTheAppsSettingsBundle() throws {
        _ = NSApplication.shared
        MenuController(application: nil).install()
        defer { NSApp.mainMenu = nil }
        let app = try #require(NSApp.mainMenu?.items.first?.submenu)
        #expect(app.items.prefix(4).map { $0.isSeparatorItem ? "-" : $0.title } == ["About NeoSimulator", "-", "Settings…", "-"])
        let settings = try #require(app.items.first { $0.title == "Settings…" })
        #expect(settings.keyEquivalent == "," && settings.keyEquivalentModifierMask == .command)
        // Like Simulator.app's, the item goes to the first responder, and
        // AppKit's NSApplication answers it.
        let action = try #require(settings.action)
        #expect(settings.target == nil && action == Selector(("orderFrontPreferencesPanel:")))
        #expect(NSApp.target(forAction: action, to: nil, from: settings) as AnyObject === NSApp)
    }

    /// A controller whose session and touch pressure settings keep their
    /// preferences in `preferences`. Without `touchPressure`, the Mac has no
    /// Force Touch trackpad.
    /// The private runtime of the selected Xcode, as the host loads it.
    private func makeRuntime() throws -> SimulatorRuntime {
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
        return try SimulatorRuntime(xcodeURL: xcode)
    }

    private func makeController(_ display: TestDisplay,
                                family: DeviceCapabilities.Family = .iPhone,
                                features: Set<String> = Self.defaultFeatures,
                                framebufferMask: Bool = false,
                                simctl: URL = DeviceTools.simctl,
                                devicectl: URL = DeviceTools.devicectl,
                                recordingProcess: ((URL, DeviceTools.ScreenMask) -> Process)? = nil,
                                screenPointsPerInch: Double? = nil,
                                device identifier: String = "test-device",
                                preferences: MemoryPreferences = MemoryPreferences(),
                                touchPressure: TouchPressure? = nil,
                                keyboardLanguage: @escaping @MainActor () -> String? = { "fr" },
                                openLog: @escaping (URL) async throws -> Void = { _ in },
                                pasteboard: NSPasteboard? = nil,
                                pasteboardSync: PasteboardSync? = nil,
                                externalDisplayChanges: ExternalDisplayChanges = ExternalDisplayChanges(),
                                userInterfacePlugin: Bool = false,
                                runtimeVersion: UInt32 = 0x1B_00_00,
                                enhancedMultitasking: Bool = false,
                                userInterfacePluginLookUp: (attempts: Int, interval: Duration) = (5, .milliseconds(20)),
                                performWindowDrag: @escaping (NSWindow, NSEvent) -> Void = { _, _ in },
                                onClose: @escaping (DeviceWindowController, DeviceLifetimeChoice?) -> Void = { _, _ in },
                                onRestart: @escaping (DeviceWindowController, Bool) -> Void = { _, _ in })
        throws -> DeviceWindowController {
        let session = try makeSession(display, family: family, features: features, framebufferMask: framebufferMask,
                                      simctl: simctl, devicectl: devicectl, recordingProcess: recordingProcess,
                                      openLog: openLog, screenPointsPerInch: screenPointsPerInch, device: identifier,
                                      preferences: preferences, keyboardLanguage: keyboardLanguage,
                                      pasteboard: pasteboard, pasteboardSync: pasteboardSync,
                                      externalDisplayChanges: externalDisplayChanges,
                                      userInterfacePlugin: userInterfacePlugin, runtimeVersion: runtimeVersion,
                                      enhancedMultitasking: enhancedMultitasking)
        return try DeviceWindowController(
            session: session, preferences: preferences,
            touchPressure: touchPressure ?? TouchPressure(preferences: preferences, forceTouchTrackpad: { false }),
            performWindowDrag: performWindowDrag, userInterfacePluginLookUp: userInterfacePluginLookUp,
            onClose: onClose, onRestart: onRestart)
    }

    /// Waits up to two seconds for `condition`, checking it every 10 ms. It
    /// stops checking once the condition holds: a `for … where` loop would
    /// check it on every remaining pass without suspending, and a check that
    /// renders images then holds up the main actor that tests running
    /// alongside share.
    private func wait(until condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The features of an iPhone that the tests need unless they choose others.
    private static let defaultFeatures: Set<String> = [DeviceCapabilities.displayRotation, DeviceCapabilities.keyboard]

    /// A `simctl io recordVideo` stand-in that acknowledges the first frame,
    /// then runs `script`, and that a stop ends normally.
    private static func recorder(then script: String) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap 'exit 0' INT; echo 'Recording started' >&2; \(script)"]
        return process
    }

    /// Simulator.app's toolbar style threshold for the test device's window:
    /// the buttons of its iPhone toolbar nib (Home 31, Save Screen 32, and
    /// Rotate 25 points) with 4 points each, the wider of the title in the
    /// headline font and the subtitle in the subheadline font, and 130 points.
    private static func unifiedWidth(title: String = "Test iPhone", subtitle: String = "iOS") -> CGFloat {
        func width(_ text: String, _ style: NSFont.TextStyle) -> CGFloat {
            let font = NSFont.preferredFont(forTextStyle: style, options: [:])
            return NSAttributedString(string: text, attributes: [.font: font]).size().width
        }
        return (31 + 4) + (32 + 4) + (25 + 4) + max(width(title, .headline), width(subtitle, .subheadline)) + 130
    }

    /// A shown window whose display, 100 by 200 points at scale 1, has a
    /// 10-point bezel without top padding, like an iPhone's.
    private func makeBezelController(preferences: MemoryPreferences = MemoryPreferences(),
                                     performWindowDrag: @escaping (NSWindow, NSEvent) -> Void = { _, _ in })
        throws -> (DeviceWindowController, TestDisplay) {
        let display = TestDisplay()
        display.naturalSize = NSSize(width: 100, height: 200)
        display.bezel = NSSize(width: 20, height: 20)
        display.bezelPadding = NSSize(width: 9, height: 0)
        let controller = try makeController(display, preferences: preferences, performWindowDrag: performWindowDrag)
        controller.showWindow(nil)
        return (controller, display)
    }

    /// The middle of a resize corner of `display`'s bezel, on the screen.
    private func point(of corner: DisplayResizeRect.Corner, in display: TestDisplay) throws -> NSPoint {
        let rect = try #require(display.resizeRects.first { $0.corner == corner }).rect
        let window = try #require(display.view.window)
        return window.convertPoint(toScreen: display.view.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil))
    }

    /// The middle of the left edge of the 10-point bezel of a display from
    /// `makeBezelController()`, away from its corners, in the window.
    private func pointOnBezel(of display: TestDisplay) throws -> NSPoint {
        let view = display.view
        try #require(view.window != nil)
        return view.convert(NSPoint(x: 5 * display.renderScale, y: view.bounds.midY), to: nil)
    }

    /// Presses the mouse at `location` in `window` as AppKit's dispatch does
    /// in a key window, and returns the view that the press hits. That view
    /// receives the press, and its responder chain passes on a press it does
    /// not handle: SimulatorKit's bezel passes its presses on to the window,
    /// its buttons keep theirs, and its digitizer keeps those it does not
    /// pass on.
    private func press(_ window: NSWindow, at location: NSPoint) throws -> NSView {
        let hit = try #require(window.contentView?.superview?.hitTest(location))
        hit.mouseDown(with: try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: location, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1)))
        return hit
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
                             features: Set<String> = Self.defaultFeatures,
                             framebufferMask: Bool = false,
                             simctl: URL = DeviceTools.simctl,
                             devicectl: URL = DeviceTools.devicectl,
                             recordingProcess: ((URL, DeviceTools.ScreenMask) -> Process)? = nil,
                             openLog: @escaping (URL) async throws -> Void = { _ in },
                             screenPointsPerInch: Double? = nil,
                             device identifier: String = "test-device",
                             preferences: MemoryPreferences = MemoryPreferences(),
                             keyboardLanguage: @escaping @MainActor () -> String? = { "fr" },
                             pasteboard: NSPasteboard? = nil,
                             pasteboardSync: PasteboardSync? = nil,
                             externalDisplayChanges: ExternalDisplayChanges = ExternalDisplayChanges(),
                             userInterfacePlugin: Bool = false,
                             runtimeVersion: UInt32 = 0x1B_00_00,
                             enhancedMultitasking: Bool = false) throws -> DeviceSession {
        // Five looks for an external display, 20 ms apart, so that a test
        // sees the look-up end.
        DeviceSession(
            device: availableDevice(identifier, "Test iPhone", runtime: "iOS", state: 3),
            capabilities: DeviceCapabilities(family: family, runtimeVersion: runtimeVersion,
                                             supportsFeature: { features.contains($0) },
                                             hasFramebufferMask: framebufferMask,
                                             screenPointsPerInch: screenPointsPerInch,
                                             hasUserInterfacePlugin: userInterfacePlugin,
                                             supportsEnhancedMultitasking: enhancedMultitasking),
            display: display,
            tools: try DeviceTools(identifier: "test-device", xcodeURL: URL(fileURLWithPath: "/Applications/Xcode.app"),
                                   simctl: simctl, devicectl: devicectl),
            recordingProcess: recordingProcess, openLog: openLog, preferences: preferences,
            hostKeyboardLanguage: keyboardLanguage, pasteboard: pasteboard, pasteboardSync: pasteboardSync,
            externalDisplayChanges: externalDisplayChanges, externalScreenLookUp: (5, .milliseconds(20)))
    }
}

/// Whether each change an observation reported arrived on the main thread.
@MainActor
private final class ChangeLog {
    var onMainThread: [Bool] = []
}

/// What a device window's toolbar button shows: its image's symbol and
/// description, its tooltip, and its item's label.
private struct ButtonFace: Equatable {
    var symbol: String?
    var imageDescription: String?
    var toolTip: String?
    var label: String

    static let home = ButtonFace(symbol: "house", imageDescription: "Home", toolTip: "Home", label: "Home")
    static let saveScreen = ButtonFace(symbol: "camera.on.rectangle", imageDescription: "Save Screen",
                                       toolTip: "Save Screen", label: "Save Screen")
    static let recordScreen = ButtonFace(symbol: "record.circle", imageDescription: "Start Recording",
                                         toolTip: "Record Screen", label: "Save Screen")
    static let stopRecording = ButtonFace(symbol: "stop.circle", imageDescription: "Stop Recording",
                                          toolTip: "Stop Recording", label: "Save Screen")
    static let rotate = ButtonFace(symbol: "rotate.right", imageDescription: "Rotate Right", toolTip: "Rotate", label: "Rotate")
    /// As in Simulator.app, the image has the symbol's own description.
    static let rotateLeft = ButtonFace(symbol: "rotate.left",
                                       imageDescription: NSImage(systemSymbolName: "rotate.left", accessibilityDescription: nil)?
                                           .accessibilityDescription,
                                       toolTip: "Rotate", label: "Rotate")
    /// Home, Save Screen, and Rotate, as Simulator.app's iPhone toolbar shows them.
    static let normal = [home, saveScreen, rotate]
    /// The same buttons while Option is down with the pointer over the toolbar.
    static let optionAlternates = [home, recordScreen, rotateLeft]

    @MainActor
    init(_ item: NSToolbarItem) {
        let image = item.image?.tiffRepresentation
        symbol = ["house", "camera.on.rectangle", "record.circle", "stop.circle", "rotate.right", "rotate.left"].first {
            image != nil && NSImage(systemSymbolName: $0, accessibilityDescription: nil)?.tiffRepresentation == image
        }
        imageDescription = item.image?.accessibilityDescription
        toolTip = item.toolTip
        label = item.label
    }

    init(symbol: String?, imageDescription: String?, toolTip: String?, label: String) {
        (self.symbol, self.imageDescription, self.toolTip, self.label) = (symbol, imageDescription, toolTip, label)
    }
}

/// Moves the pointer onto and off a device window's toolbar as AppKit reports
/// it, through the tracking area of the toolbar's view, and holds modifier
/// keys as the keyboard does: the toolbar reads the keys held, and hears of
/// each change through a modifier event that the app sends.
@MainActor
private final class ToolbarPointer {
    let area: NSTrackingArea
    private let window: NSWindow
    private let toolbar: NSToolbar
    private var keys: NSEvent.ModifierFlags = []

    init(_ controller: DeviceWindowController) throws {
        window = try #require(controller.window)
        toolbar = try #require(window.toolbar)
        let owner = try #require(toolbar.delegate as? DeviceToolbar)
        let view = try #require(toolbar.value(forKey: "_toolbarView") as? NSView)
        area = try #require(view.trackingAreas.first { $0.owner as AnyObject === owner })
        owner.modifierFlags = { [unowned self] in self.keys }
    }

    func enter() { report(.mouseEntered, "mouseEntered:") }
    func exit() { report(.mouseExited, "mouseExited:") }

    /// Sends the area's owner the event AppKit sends it.
    private func report(_ type: NSEvent.EventType, _ selector: String) {
        let event = NSEvent.enterExitEvent(with: type, location: .zero, modifierFlags: keys, timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                           trackingNumber: 0, userData: nil)
        _ = (area.owner as AnyObject).perform(NSSelectorFromString(selector), with: event)
    }

    /// Holds `keys`, which the app hears of through a modifier event.
    func hold(_ keys: NSEvent.ModifierFlags) {
        self.keys = keys
        if let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: keys,
                                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                                        characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 58) {
            NSApp.sendEvent(event)
        }
    }

    /// Holds `keys` while another app is active, so that no modifier event
    /// reaches this one.
    func holdInAnotherApp(_ keys: NSEvent.ModifierFlags) { self.keys = keys }

    func item(_ id: DeviceCommand.ID) throws -> NSToolbarItem {
        try #require(toolbar.items.first { $0.itemIdentifier.rawValue == id.rawValue })
    }

    /// The faces of the toolbar's buttons, in toolbar order.
    var faces: [ButtonFace] {
        toolbar.items.filter { DeviceCommand.ID(rawValue: $0.itemIdentifier.rawValue) != nil }.map(ButtonFace.init)
    }

    /// Clicks `id`'s button, as AppKit sends its action.
    func click(_ id: DeviceCommand.ID) throws -> Bool {
        let item = try item(id)
        return NSApp.sendAction(try #require(item.action), to: item.target, from: item)
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
    /// The presses the digitizer received.
    var presses: [NSEvent] = []
    /// Whether the digitizer passes its presses on, as SimulatorKit's does
    /// with a press on the bezel next to the screen once the pointer moves
    /// away from the screen.
    var passesOnPresses = false
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { keyDowns.append(event) }
    override func keyUp(with event: NSEvent) { keyUps.append(event) }
    override func flagsChanged(with event: NSEvent) { modifiers.append(event) }
    override func mouseDown(with event: NSEvent) {
        presses.append(event)
        if passesOnPresses { super.mouseDown(with: event) }
    }
}
/// A hardware button on the bezel, which takes its presses as SimulatorKit's
/// `SimChromeButton` does.
@MainActor
private final class TestButton: NSView {
    var presses: [NSEvent] = []
    override func mouseDown(with event: NSEvent) { presses.append(event) }
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
    var inputView: NSView { foundPlugin?.overlayView ?? input }
    /// The user-interface plugin the display has loaded, and the error that
    /// finding it throws.
    var plugin: SimulatorUserInterfacePlugin?
    var pluginError: Error?
    /// The plugin once `userInterfacePlugin()` found it.
    private var foundPlugin: SimulatorUserInterfacePlugin?
    func userInterfacePlugin() throws -> SimulatorUserInterfacePlugin? {
        if let pluginError { throw pluginError }
        foundPlugin = plugin
        return plugin
    }
    var backlightState: Int32?
    /// Each recording start (true) and end (false) announced, in order.
    var announcedRecordings: [Bool] = []
    func announceRecording(started: Bool) { announcedRecordings.append(started) }
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
    /// Each hardware keyboard connection and keyboard language the device
    /// was given, in order.
    var hardwareKeyboard: [Bool] = []
    var keyboardLanguages: [String] = []
    /// Fail these keyboard changes after recording them.
    var hardwareKeyboardError: Error?
    var keyboardLanguageError: Error?
    func setHardwareKeyboardConnected(_ connected: Bool) async throws {
        hardwareKeyboard.append(connected)
        if let hardwareKeyboardError { throw hardwareKeyboardError }
    }
    func setKeyboardLanguage(_ language: String) async throws {
        keyboardLanguages.append(language)
        if let keyboardLanguageError { throw keyboardLanguageError }
    }
    /// Each pasteboard connection, with the pasteboard it manages, in order.
    var pasteboards: [TestPasteboard] = []
    /// Fails the next pasteboard connection with this error.
    var pasteboardError: Error?
    func connectPasteboard(_ pasteboard: NSPasteboard,
                           events: @escaping @MainActor (SimulatorPasteboardEvent) -> Void) throws -> any SimulatorPasteboard {
        if let error = pasteboardError {
            pasteboardError = nil
            throw error
        }
        let connection = TestPasteboard(pasteboard: pasteboard, events: events)
        pasteboards.append(connection)
        return connection
    }
    /// The device's audio route port, or nil for a device whose port does not connect.
    var audioPort: TestAudioRoutes?
    var audioConnections = 0
    func connectAudioRoutes(changed: @escaping @MainActor () -> Void) throws -> any SimulatorAudioRoutes {
        audioConnections += 1
        guard let audioPort else { throw HostError.unavailable("The device has no audio route port.") }
        audioPort.changed = changed
        return audioPort
    }
    /// The device's external display, or nil for a device without one.
    var externalScreen: TestExternalScreen?
    var externalScreenConnections = 0
    func connectExternalScreen(changed: @escaping @MainActor () -> Void) throws -> (any SimulatorExternalScreen)? {
        externalScreenConnections += 1
        externalScreen?.changed = changed
        return externalScreen
    }
    /// Each value the digitizer's touch pressure settings were given, in order.
    var supportsTouchPressure: [Bool] = []
    var usesTrackpadForce: [Bool] = []
    var touchModes: [SimulatedTouchMode] = []
    func setSupportsTouchPressure(_ supports: Bool) { supportsTouchPressure.append(supports) }
    func setUsesTrackpadForce(_ uses: Bool) { usesTrackpadForce.append(uses) }
    func setSimulatedTouchMode(_ mode: SimulatedTouchMode) { touchModes.append(mode) }
    /// The touch indicators the digitizer draws.
    private(set) var touchIndicators: Set<TouchIndicator> = []
    func setTouchIndicator(_ indicator: TouchIndicator, shown: Bool) {
        if shown { touchIndicators.insert(indicator) } else { touchIndicators.remove(indicator) }
    }
    var rotations: [Double] = []
    /// Called with each angle the display turns to, as SimulatorKit then
    /// gives the display its rotated size.
    var onRotation: (Double) -> Void = { _ in }
    func setRotation(degrees: Double) {
        rotations.append(degrees)
        onRotation(degrees)
    }
    /// Takes a new size of its screen as SimulatorKit's display does, a
    /// moment after CoreSimulator reports it: its view takes that size at
    /// the display's scale.
    func takeScreenSize(_ size: NSSize) {
        naturalSize = size
        view.setFrameSize(self.size(for: renderScale))
    }
    func beginResize() { isResizing = true }
    func resize(to size: NSSize) { setRenderScale(scale(for: size)) }
    func endResize() { isResizing = false }
    func disconnect() { disconnectCount += 1; onDisconnect() }
}

/// A device's audio route port that records the routes it is asked for, as
/// "input <route>" or "output <route>", and applies them as CoreSimulator does,
/// reporting the change. The test reports other changes, such as a Mac device
/// appearing or another process routing the device.
@MainActor
private final class TestAudioRoutes: SimulatorAudioRoutes {
    var current: AudioRouteState
    private(set) var requests: [String] = []
    /// Completes each route with this error, without applying it.
    var routeError: Error?
    /// Refuses each route with this error.
    var refusal: Error?
    var changed: (() -> Void)?
    private(set) var isDisconnected = false

    init(_ devices: [HostAudioDevice], input: String = AudioRouting.systemDefault,
         output: String = AudioRouting.systemDefault) {
        current = AudioRouteState(devices: devices, inputRoute: input, outputRoute: output,
                                  defaultInput: devices.first { $0.isDefault(in: .input) }?.uid,
                                  defaultOutput: devices.first { $0.isDefault(in: .output) }?.uid)
    }

    func state() throws -> AudioRouteState { current }

    func route(_ scope: AudioScope, to route: String, completion: @escaping @MainActor (Error?) -> Void) throws {
        if let refusal { throw refusal }
        requests.append("\(scope.noun) \(route)")
        guard routeError == nil else { return completion(routeError) }
        completion(nil)
        report { state in
            if scope == .input { state.inputRoute = route } else { state.outputRoute = route }
        }
    }

    func disconnect() {
        isDisconnected = true
        changed = nil
    }

    /// A change that the port reports.
    func report(_ change: (inout AudioRouteState) -> Void) {
        change(&current)
        changed?()
    }
}

/// Modes like those of the TVOut screens of iOS 26.5 devices: an exact
/// 720×480 mode at 60 Hz, the menu's sizes at 120 Hz, and, on an iPhone,
/// ranges at 60 Hz.
private extension ExternalScreenMode {
    static let exact720x480 = ExternalScreenMode(sizes: .exact(CGSize(width: 720, height: 480)), scale: 1,
                                                 refreshRate: 60)

    static func allowedAt120Hertz(scale: CGFloat) -> ExternalScreenMode {
        ExternalScreenMode(sizes: .allowed(ExternalDisplayMode.sizes.compactMap(\.pixelSize)), scale: scale,
                           refreshRate: 120)
    }

    static func rangeAt60Hertz(scale: CGFloat) -> ExternalScreenMode {
        ExternalScreenMode(sizes: .range(minimum: CGSize(width: 320, height: 200), maximum: CGSize(width: 3840, height: 2160)),
                           scale: scale, refreshRate: 60)
    }
}

/// A device's external display that records the changes it is asked for, as
/// "mode <width>x<height>@<scale>", with " carplay" for a CarPlay screen, or
/// "off", and applies them as CoreSimulator does, reporting the change. It
/// also records the CarPlay requests that reach the guest, as "save carplay"
/// or "save off" for the configuration file, "start carplay" or "stop
/// carplay" for the session, and "connect service" or "remove service" for
/// the HID service, completing them at once unless the session requests are
/// held. The test reports other changes, such as `simctl` turning the display
/// on.
@MainActor
private final class TestExternalScreen: SimulatorExternalScreen {
    let screenID: UInt32 = 2
    /// The device's boot; a screen of another boot needs another date.
    var deviceBootDate: Date? = Date(timeIntervalSinceReferenceDate: 0)
    var current = ExternalScreenState(isPoweredOn: false, pixelSize: CGSize(width: 720, height: 480), scale: 1)
    /// The modes the display advertises, which a session reads when it
    /// connects; by default 60 Hz modes that take every size at scales 1 and 2.
    var modes = [1, 2].map {
        ExternalScreenMode(sizes: .range(minimum: CGSize(width: 1, height: 1), maximum: CGSize(width: 8192, height: 8192)),
                           scale: $0, refreshRate: 60)
    }
    private(set) var requests: [String] = []
    /// Completes each change with this error, without applying it.
    var completionError: Error?
    /// Refuses each change with this error, as for a size that no mode takes.
    var refusal: Error?
    /// Fails these CarPlay requests, by their names in `requests`: saving the
    /// configuration throws, and the others complete with the error.
    var carPlayErrors: [String: Error] = [:]
    /// The guest's CarPlay sessions as its CoreSimulatorBridge counts them: a
    /// start adds one and an end removes one, also below zero, which fails.
    private(set) var carPlaySessions = 0
    /// Holds the session requests until `deliverCarPlaySessions()`, as a
    /// guest that answers after the change stopped waiting.
    var defersCarPlaySessions = false
    private var pendingSessions: [() -> Void] = []
    /// Holds the HID service requests until `deliverCarPlayServices()`.
    var defersCarPlayServices = false
    private var pendingServices: [() -> Void] = []
    /// Holds each change's report and completion until `deliver()`, or
    /// `deliverReports()` and `deliverCompletions()` apart, as CoreSimulator
    /// reports and completes a change later, in either order.
    var defersChanges = false
    private var pendingReports: [() -> Void] = []
    private var pendingCompletions: [() -> Void] = []
    var changed: (() -> Void)?
    /// The displays made for the display's windows, in order.
    private(set) var displays: [TestDisplay] = []
    private(set) var isDisconnected = false

    func state() throws -> ExternalScreenState { current }

    func supportedModes() throws -> [ExternalScreenMode] { modes }

    func setMode(pixelSize: CGSize, scale: CGFloat, carPlay: Bool,
                 completion: @escaping @MainActor (Error?) -> Void) throws {
        if let refusal { throw refusal }
        requests.append("mode \(Int(pixelSize.width))x\(Int(pixelSize.height))@\(Int(scale))\(carPlay ? " carplay" : "")")
        complete(completion) {
            $0 = ExternalScreenState(isPoweredOn: true, pixelSize: pixelSize, scale: scale, isCarPlay: carPlay)
        }
    }

    func powerOff(completion: @escaping @MainActor (Error?) -> Void) throws {
        if let refusal { throw refusal }
        requests.append("off")
        complete(completion) { $0.isPoweredOn = false }
    }

    func saveCarPlayConfiguration(carPlay: Bool) throws {
        let request = carPlay ? "save carplay" : "save off"
        requests.append(request)
        if let error = carPlayErrors[request] { throw error }
    }

    func setCarPlayEnabled(_ enabled: Bool, inBoot boot: Date?, completion: @escaping @MainActor (Error?) -> Void) {
        let request = enabled ? "start carplay" : "stop carplay"
        requests.append(request)
        let answer = { [self] in
            // Like the device, which checks its boot when the request runs.
            guard deviceBootDate == boot else { return completion(CarPlayRequestMoot()) }
            if let error = carPlayErrors[request] { return completion(error) }
            carPlaySessions += enabled ? 1 : -1
            completion(carPlaySessions < 0 ? HostError.operation("invalid session count") : nil)
        }
        if defersCarPlaySessions { pendingSessions.append(answer) } else { answer() }
    }

    /// Answers the held session requests in the order they came.
    func deliverCarPlaySessions() {
        let answers = pendingSessions
        pendingSessions = []
        for answer in answers { answer() }
    }

    func setCarPlayService(connected: Bool, completion: @escaping @MainActor (Error?) -> Void) throws {
        let request = connected ? "connect service" : "remove service"
        requests.append(request)
        let answer = { [self] in completion(carPlayErrors[request]) }
        if defersCarPlayServices { pendingServices.append(answer) } else { answer() }
    }

    func deliverCarPlayServices() {
        let answers = pendingServices
        pendingServices = []
        for answer in answers { answer() }
    }

    /// The device restarts: a new boot, whose guest has no CarPlay session.
    func restart(boot: Date) {
        deviceBootDate = boot
        carPlaySessions = 0
    }

    /// Applies and reports a change and completes it, at once or when it is delivered.
    private func complete(_ completion: @escaping @MainActor (Error?) -> Void,
                          _ change: @escaping (inout ExternalScreenState) -> Void) {
        let error = completionError
        let report = { [self] in if error == nil { self.report(change) } }
        guard defersChanges else {
            report()
            return completion(error)
        }
        pendingReports.append(report)
        pendingCompletions.append { completion(error) }
    }

    /// Delivers the held reports, then the held completions.
    func deliver() {
        deliverReports()
        deliverCompletions()
    }

    /// Applies and reports the held changes in the order they were asked for.
    func deliverReports() {
        let reports = pendingReports
        pendingReports = []
        for report in reports { report() }
    }

    /// Completes the held changes in the order they were asked for.
    func deliverCompletions() {
        let completions = pendingCompletions
        pendingCompletions = []
        for completion in completions { completion() }
    }

    func makeDisplay() throws -> any SimulatorDisplay {
        let display = TestDisplay()
        display.naturalSize = NSSize(width: current.pixelSize.width / current.scale,
                                     height: current.pixelSize.height / current.scale)
        display.screenScale = current.scale
        display.displayClass = 1
        displays.append(display)
        return display
    }

    func disconnect() {
        isDisconnected = true
        changed = nil
    }

    /// A change that the display reports.
    func report(_ change: (inout ExternalScreenState) -> Void) {
        change(&current)
        changed?()
    }
}

/// A device's pasteboard connection that records its pushes and pulls; the
/// test sends the device's events.
@MainActor
private final class TestPasteboard: SimulatorPasteboard {
    let pasteboard: NSPasteboard
    private let events: (SimulatorPasteboardEvent) -> Void
    private(set) var transfers: [PasteboardTransfer] = []
    /// Each value automatic synchronization was set to, in order.
    private(set) var automaticSync: [Bool] = []
    private(set) var isDisconnected = false

    init(pasteboard: NSPasteboard, events: @escaping @MainActor (SimulatorPasteboardEvent) -> Void) {
        self.pasteboard = pasteboard
        self.events = events
    }

    func pull() throws { transfers.append(.get) }
    func push() throws { transfers.append(.send) }
    func setAutomaticSync(_ enabled: Bool) throws { automaticSync.append(enabled) }
    func disconnect() { isDisconnected = true }
    func send(_ event: SimulatorPasteboardEvent) { events(event) }
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

    @Test func movingByTheBezelReadsAllowsMoveByDragOnWindowChromeAsSimulatorDoes() {
        // Simulator.app registers it on and reads it with boolForKey:.
        HostPreferences.registerDefaults()
        let registered = UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain)
        #expect(registered["AllowsMoveByDragOnWindowChrome"] as? Bool == true)
        let defaults = RegisteredDefaults()
        // Without a value, as before the app registers its default, it is on.
        #expect(defaults.movesWindowByDraggingBezel)
        let values: [(Any, Bool)] = [("NO", false), ("YES", true), (false, false), (true, true)]
        for (value, moves) in values {
            defaults.set(value, forKey: HostPreferences.allowsMoveByDragOnWindowChrome)
            #expect(defaults.movesWindowByDraggingBezel == moves)
        }
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

    @Test func touchIndicatorPreferencesUseSimulatorAppsKeysAndDefaults() {
        #expect(TouchIndicator.allCases.map(\.preferenceKey)
            == ["ShowSingleTouches", "ShowPinches", "ShowPinchPivotPoint", "HighlightEdgeGestures"])
        // Simulator.app registers pinches on and the others off.
        HostPreferences.registerDefaults()
        let registered = UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain)
        #expect(TouchIndicator.allCases.map { registered[$0.preferenceKey] as? Bool } == [false, true, false, false])
        // Without values, as before the app registers its defaults, only pinches show.
        #expect(TouchIndicator.allCases.filter(MemoryPreferences().showsTouchIndicator) == [.pinches])
        // A value that `defaults write` saved as a string reads as `boolForKey:` reads it.
        let defaults = RegisteredDefaults()
        defaults.set("NO", forKey: HostPreferences.showPinches)
        defaults.set("YES", forKey: HostPreferences.showSingleTouches)
        #expect(TouchIndicator.allCases.filter(defaults.showsTouchIndicator) == [.singleTouches])
    }

    @Test func defaultsObservationReportsChangesOnTheMainThread() async throws {
        // A key of the test's own, removed afterwards.
        let key = "NeoSimulatorTests-\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let changes = ChangeLog()
        var observation: DefaultsObservation? = DefaultsObservation(.standard, keys: [key]) {
            changes.onMainThread.append(Thread.isMainThread)
        }
        UserDefaults.standard.set(true, forKey: key)
        #expect(changes.onMainThread == [true])
        // A change on another thread is reported on the main thread.
        await Task.detached { UserDefaults.standard.set(false, forKey: key) }.value
        for _ in 0..<100 where changes.onMainThread.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(changes.onMainThread == [true, true])
        withExtendedLifetime(observation) {}
        // A released observation reports nothing.
        observation = nil
        UserDefaults.standard.set(true, forKey: key)
        #expect(changes.onMainThread.count == 2)
    }

    @Test func keyboardAndTrackpadPreferencesUseSimulatorAppsKeys() {
        // Each is on unless it was turned off.
        let preferences = MemoryPreferences()
        #expect(preferences.syncsKeyboardLanguage && preferences.prefersTrackpadForce)
        #expect(preferences.connectsHardwareKeyboard(forDevice: "A"))
        // A device's choice keeps its other preferences and the other devices'.
        preferences.setWindowGeometry(center: NSPoint(x: 1, y: 2), scale: 1, forDevice: "A", screens: [.zero])
        preferences.setConnectsHardwareKeyboard(false, forDevice: "A")
        #expect(!preferences.connectsHardwareKeyboard(forDevice: "A"))
        #expect(preferences.connectsHardwareKeyboard(forDevice: "B"))
        #expect(preferences.windowGeometry(forDevice: "A", screens: [.zero]).center == NSPoint(x: 1, y: 2))
        // A device without a choice, or with one that is not a Boolean,
        // follows the app-wide value.
        preferences.set(false, forKey: HostPreferences.connectHardwareKeyboard)
        #expect(!preferences.connectsHardwareKeyboard(forDevice: "B"))
        preferences.values[HostPreferences.devicePreferences] = ["B": [HostPreferences.connectHardwareKeyboard: "YES"]]
        #expect(!preferences.connectsHardwareKeyboard(forDevice: "B"))
        // A value that `defaults write` saved as a string reads as
        // `boolForKey:` reads it.
        let defaults = RegisteredDefaults()
        defaults.set("NO", forKey: HostPreferences.enableKeyboardSync)
        defaults.set("0", forKey: HostPreferences.useTrackpadForce)
        #expect(!defaults.syncsKeyboardLanguage && !defaults.prefersTrackpadForce)
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
        // A watch's title drops "Apple Watch ", after the split.
        #expect(deviceWindowTitles(name: "Apple Watch Series 11 (46mm)", runtimeName: "watchOS 27.0")
            == ("Series 11 (46mm)", "watchOS 27.0"))
        #expect(deviceWindowTitles(name: "Apple Watch SE (44mm) (2nd generation)", runtimeName: "watchOS 26.5")
            == ("SE (44mm)", "2nd generation – watchOS 26.5"))
        #expect(deviceWindowTitles(name: "Apple Watch", runtimeName: "watchOS 27.0") == ("Apple Watch", "watchOS 27.0"))
    }

    @Test func externalDisplayModesUseSimulatorAppsTagsAndSizes() {
        #expect(ExternalDisplayMode.allCases.map(\.rawValue) == [2114, 2214, 2514, 2314, 2414, 2614, 2664, 2714])
        #expect(ExternalDisplayMode.allCases.compactMap(\.pixelSize).map { "\(Int($0.width))x\(Int($0.height))" }
            == ["640x480", "720x480", "1024x768", "1280x720", "1920x1080", "3840x2160", "800x480"])
        // Sizes at a point per pixel, and CarPlay at Simulator.app's CarPlay scale.
        #expect(ExternalDisplayMode.allCases.dropFirst().map(\.scale) == [1, 1, 1, 1, 1, 1, 2])
    }

    @Test func externalDisplayModeChoiceTakesARateTheGuestKeepsWhateverTheOrder() throws {
        func choice(_ width: CGFloat, _ height: CGFloat, scale: CGFloat = 1, current: ExternalScreenState? = nil,
                    _ modes: [ExternalScreenMode]) throws(ExternalDisplayLimit) -> ExternalScreenMode? {
            switch try ExternalScreenMode.choice(for: CGSize(width: width, height: height), scale: scale,
                                                 current: current, among: modes) {
            case .current: nil
            case .advertised(let index): modes[index]
            }
        }
        // An iPhone's screen lists its modes in another order at each read;
        // a size takes the 60 Hz range of its scale in every order, also where
        // the 120 Hz mode that takes it comes first.
        let iPhone: [ExternalScreenMode] = [.exact720x480, .allowedAt120Hertz(scale: 1), .allowedAt120Hertz(scale: 2),
                                            .rangeAt60Hertz(scale: 3), .rangeAt60Hertz(scale: 1), .rangeAt60Hertz(scale: 2)]
        for modes in [iPhone, Array(iPhone.reversed()), [iPhone[1], iPhone[4], iPhone[0], iPhone[2], iPhone[5], iPhone[3]]] {
            for size in [(1024, 768), (1280, 720), (1920, 1080), (3840, 2160)] as [(CGFloat, CGFloat)] {
                #expect(try choice(size.0, size.1, modes) == .rangeAt60Hertz(scale: 1))
            }
            #expect(try choice(720, 480, modes)?.refreshRate == 60)
            // CarPlay's 800×480 at a scale of 2.
            #expect(try choice(800, 480, scale: 2, modes) == .rangeAt60Hertz(scale: 2))
        }
        // An iPad's screen, and an iPhone's with iOS 27.0, takes the menu's sizes
        // only at 120 Hz; the exact 60 Hz mode of the scale sets them at 60 Hz.
        let iPad: [ExternalScreenMode] = [.exact720x480, .allowedAt120Hertz(scale: 2), .allowedAt120Hertz(scale: 1)]
        for modes in [iPad, Array(iPad.reversed())] {
            for size in [(720, 480), (1024, 768), (1920, 1080), (3840, 2160)] as [(CGFloat, CGFloat)] {
                #expect(try choice(size.0, size.1, modes) == .exact720x480)
            }
            // Without a 60 Hz mode of the scale, the guest would show its 720×480.
            #expect(throws: ExternalDisplayLimit.showsInstead(CGSize(width: 720, height: 480))) {
                try choice(1920, 1080, scale: 2, modes)
            }
            #expect(throws: ExternalDisplayLimit.noMode) { try choice(1000, 700, modes) }
        }
        // The guest shows its 720×480 mode rather than 640×480, at any rate.
        for modes in [iPhone, iPad] {
            #expect(throws: ExternalDisplayLimit.showsInstead(CGSize(width: 720, height: 480))) {
                try choice(640, 480, modes)
            }
        }
        #expect(throws: ExternalDisplayLimit.noMode) { try choice(3840, 2161, iPhone) }
        #expect(throws: ExternalDisplayLimit.noMode) { try choice(1024, 768, scale: 3, iPad) }
        // A screen that already has the size at the scale keeps its mode,
        // unless the guest drops its rate, as when another tool set 120 Hz.
        func state(_ width: CGFloat, _ height: CGFloat, _ rate: Double) -> ExternalScreenState {
            ExternalScreenState(isPoweredOn: true, pixelSize: CGSize(width: width, height: height), scale: 1,
                                refreshRate: rate)
        }
        #expect(try choice(1920, 1080, current: state(1920, 1080, 60), iPad) == nil)
        #expect(try choice(1920, 1080, current: state(1920, 1080, 120), iPad) == .exact720x480)
        #expect(try choice(1280, 720, current: state(1920, 1080, 60), iPhone) == .rangeAt60Hertz(scale: 1))
    }

    @Test func theGuestShowsItsLargestModeAtUpTo60Hertz() {
        let modes: [ExternalScreenMode] = [.exact720x480, .allowedAt120Hertz(scale: 1)]
        func shown(_ width: CGFloat, _ height: CGFloat, _ rate: Double, _ modes: [ExternalScreenMode] = modes) -> String {
            let size = ExternalScreenMode.guestSize(for: CGSize(width: width, height: height), refreshRate: rate,
                                                    among: modes)
            return "\(Int(size.width))x\(Int(size.height))"
        }
        #expect(shown(1920, 1080, 120) == "720x480")
        #expect(shown(3840, 2160, 120) == "720x480")
        #expect(shown(1920, 1080, 60) == "1920x1080")
        #expect(shown(1024, 768, 60) == "1024x768")
        #expect(shown(720, 480, 120) == "720x480")
        #expect(shown(640, 480, 60) == "720x480")
        // Below 49 Hz is dropped too.
        #expect(shown(1920, 1080, 30) == "720x480")
        // Without an exact mode, nor one at a rate the guest keeps, the
        // display keeps its size.
        #expect(shown(640, 480, 60, [.rangeAt60Hertz(scale: 1)]) == "640x480")
        #expect(shown(1920, 1080, 120, [.allowedAt120Hertz(scale: 1)]) == "1920x1080")
    }

    @Test func externalDisplayStateNamesTheItemItShows() {
        func mode(_ on: Bool, _ width: CGFloat, _ height: CGFloat, _ scale: CGFloat = 1) -> ExternalDisplayMode? {
            ExternalScreenState(isPoweredOn: on, pixelSize: CGSize(width: width, height: height), scale: scale).mode
        }
        #expect(mode(false, 1920, 1080) == .disabled)
        #expect(mode(true, 1920, 1080) == .size1920x1080)
        #expect(mode(true, 720, 480) == .size720x480)
        #expect(mode(true, 1920, 1080, 2) == nil)
        #expect(mode(true, 1600, 900) == nil)
        // A CarPlay screen is CarPlay whatever its size, and off is Disabled.
        func carPlay(_ on: Bool, _ width: CGFloat, _ height: CGFloat, _ scale: CGFloat) -> ExternalDisplayMode? {
            ExternalScreenState(isPoweredOn: on, pixelSize: CGSize(width: width, height: height), scale: scale,
                                isCarPlay: true).mode
        }
        #expect(carPlay(true, 800, 480, 2) == .carPlay)
        #expect(carPlay(true, 1920, 1080, 1) == .carPlay)
        #expect(carPlay(false, 800, 480, 2) == .disabled)
        #expect(mode(true, 800, 480, 2) == nil)
    }

    @Test func externalDisplayChoicesUseSimulatorAppsDevicePreference() {
        let preferences = MemoryPreferences()
        #expect(preferences.externalDisplayTag(forDevice: "A") == 2114)
        preferences.set(["A": ["SimulatorExternalDisplay": "2614"]], forKey: HostPreferences.devicePreferences)
        #expect(preferences.externalDisplayTag(forDevice: "A") == 2114)
        preferences.set(["A": ["SimulatorExternalDisplay": 2714]], forKey: HostPreferences.devicePreferences)
        #expect(preferences.externalDisplayTag(forDevice: "A") == 2714)
        preferences.setExternalDisplayTag(2614, forDevice: "B")
        #expect(preferences.externalDisplayTag(forDevice: "A") == 2714)
        #expect(preferences.externalDisplayTag(forDevice: "B") == 2614)
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
