import ABIBridge
import AppKit
import Darwin
import Observation
import Testing
import Synchronization

@Suite(.serialized) @MainActor
struct InputFocusTests {
    @Test func resizingAnAppKeepsPointScaleAcrossCompactMovesAndPreservesPrimaryGeometry() async throws {
        _ = NSApplication.shared
        let primary = TestDisplay(), app = TestDisplay()
        app.naturalSize = NSSize(width: 500, height: 600)
        primary.appDisplay = app
        let transport = TestAppResizeTransport()
        let preferences = MemoryPreferences()
        let screens = NSScreen.screens.map(\.frame)
        preferences.setWindowGeometry(center: NSPoint(x: 300, y: 300), scale: 0.5, forDevice: "test-device", screens: screens)
        let controller = try makeController(primary, preferences: preferences, appResizeTransport: { transport },
                                            presentCompactWindow: { _ in })
        defer { controller.invalidate() }
        controller.showCompactWindow()
        let parent = NSViewController()
        parent.view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        controller.embed(in: parent)
        let saved = preferences.windowGeometry(forDevice: "test-device", screens: screens)
        try await wait { controller.session.canResizeApp }
        controller.toggleAppResize()
        try await wait { controller.session.isResizingApp }
        #expect(app.renderScale == 1)
        controller.showCompactWindow()
        #expect(app.renderScale == 1)
        controller.window?.setFrameOrigin(NSPoint(x: 500, y: 400))
        controller.embed(in: parent)
        let retained = preferences.windowGeometry(forDevice: "test-device", screens: screens)
        #expect(retained.scale == saved.scale && retained.center == saved.center)
        controller.session.stopAppResize()
        controller.showCompactWindow()
        #expect(primary.renderScale == 0.5)
    }

    @Test func recordingWaitsForThePendingAppDisplayConnectionAndCapturesTheShownDisplay() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("arguments")
        let simctl = directory.appendingPathComponent("simctl")
        try """
        #!/bin/sh
        printf '%s\n' "$@" > "\(log.path)"
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
        #expect(throws: HostError.self) {
            try session.startRecording(to: .file(directory.appendingPathComponent("pending.mov")), mask: .ignored)
        }
        if let unexpected = session.recording { unexpected.stop(); try await unexpected.waitUntilFinished() }
        #expect(session.recording == nil && !FileManager.default.fileExists(atPath: log.path))
        primary.completeAppDisplayConnection()
        try await wait { session.isResizingApp }
        #expect(DeviceCommand.command(.recordScreen).isEnabled(controller))
        try session.startRecording(to: .file(directory.appendingPathComponent("app.mov")), mask: .ignored)
        let recording = try #require(session.recording)
        try await wait { FileManager.default.fileExists(atPath: log.path) }
        #expect(try String(contentsOf: log, encoding: .utf8).split(separator: "\n").contains("--display=47"))
        recording.stop()
        try await recording.waitUntilFinished()
    }

    @Test func appResizeSwitchesTheCanvasInputAndCaptureAsOneOwnedDisplay() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("arguments"), simctl = directory.appendingPathComponent("simctl")
        try """
            #!/bin/sh
            printf '%s\\n' "$@" > "\(log.path)"
            for destination do :; done
            printf '\\211PNG\\r\\n\\032\\n' > "$destination"
            """.write(to: simctl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: simctl.path)
        let primary = TestDisplay(), app = TestDisplay()
        app.captureDisplayID = 47
        app.displayClass = 1
        primary.appDisplay = app
        let transport = TestAppResizeTransport()
        let controller = try makeController(primary, features: [DeviceCapabilities.keyboard], simctl: simctl, appResizeTransport: { transport })
        defer { controller.invalidate() }
        let session = controller.session
        controller.showAndActivate()
        try await wait { session.canResizeApp }
        #expect(session.canResizeApp)
        try await wait { controller.window?.toolbar?.items.contains { $0.itemIdentifier.rawValue == "resizeApp" && $0.isEnabled } == true }
        let item = try #require(controller.window?.toolbar?.items.first { $0.itemIdentifier.rawValue == "resizeApp" })
        let button = try #require(item.view as? NSButton)
        #expect(item.isEnabled)
        session.send(.hold(.button(.home), for: .seconds(30)), failure: { Issue.record($0) })
        #expect(NSApp.sendAction(try #require(button.action), to: button.target, from: button))
        try await wait { session.isResizingApp }
        #expect(session.display === app)
        #expect(primary.requestedDisplayUniqueIDs == [transport.lease.displayUniqueID])
        #expect(primary.events.map(\.state) == [.down, .up])
        #expect(controller.presentationViewController.view.subviews.contains(app.view))
        controller.focusInput()
        #expect(controller.presentationWindow?.firstResponder === app.inputView)
        let screenshot = try await session.screenshot(mask: .ignored)
        defer { try? FileManager.default.removeItem(at: screenshot) }
        #expect(try String(contentsOf: log, encoding: .utf8).split(separator: "\n").contains("--display=47"))
        let geometry = AppResizeGeometry(minimumSize: CGSize(width: 200, height: 200), maximumSize: CGSize(width: 700, height: 800),
            preferredSize: CGSize(width: 500, height: 600), resolvedSize: CGSize(width: 480, height: 580), cornerRadius: 16)
        transport.lease.geometryUpdates.continuation.yield(geometry)
        try await wait { session.appResizeGeometry == geometry }
        session.resizeApp(to: CGSize(width: 900, height: 100))
        try await wait { transport.lease.adjustedSizes.last == CGSize(width: 700, height: 200) }
        #expect(session.appResizeGeometry?.resolvedSize == CGSize(width: 480, height: 580))
        #expect(transport.lease.adjustedSizes.last == CGSize(width: 700, height: 200))
        session.send(.press(.button(.home)), failure: { Issue.record($0) })
        #expect(app.events.map(\.state) == [.down, .up])
        controller.detachPresentation()
        #expect(session.display === primary)
        #expect(!session.isResizingApp)
        #expect(transport.lease.invalidations == 1)
        #expect(app.disconnectCount == 1)
        #expect(primary.disconnectCount == 0)
    }

    @Test func appResizeInvalidatesAnAssertionReturnedAfterStopAndCleansUpFailedDisplayConnection() async throws {
        let primary = TestDisplay()
        let delayed = TestAppResizeTransport()
        delayed.holdsStart = true
        let session = try makeSession(primary, appResizeTransport: { delayed })
        defer { session.disconnect() }
        try await wait { session.canResizeApp }
        session.toggleAppResize(size: CGSize(width: 500, height: 600))
        try await wait { delayed.startContinuation != nil }
        session.stopAppResize()
        delayed.completeStart()
        try await wait { delayed.lease.invalidations == 1 }
        #expect(delayed.lease.invalidations == 1)
        #expect(primary.requestedDisplayUniqueIDs.isEmpty)
        #expect(session.display === primary)

        let rejected = TestAppResizeTransport()
        let disconnected = TestDisplay()
        disconnected.appDisplayError = HostError.operation("Display disconnected")
        let failed = try makeSession(disconnected, appResizeTransport: { rejected })
        defer { failed.disconnect() }
        var failures: [String] = []
        failed.onAppResizeError = { failures.append($0.localizedDescription) }
        try await wait { failed.canResizeApp }
        failed.toggleAppResize(size: CGSize(width: 500, height: 600))
        try await wait { !failures.isEmpty }
        #expect(failures == ["Display disconnected"])
        #expect(rejected.lease.invalidations == 1)
        #expect(failed.display === disconnected)
        #expect(!failed.isStartingAppResize && !failed.isResizingApp)
    }

    @Test func appResizeEligibilityInvalidationAndGeometryFailureRestoreThePrimaryDisplay() async throws {
        for end in 0..<3 {
            let primary = TestDisplay(), app = TestDisplay()
            primary.appDisplay = app
            let transport = TestAppResizeTransport()
            let session = try makeSession(primary, appResizeTransport: { transport })
            defer { session.disconnect() }
            var failures: [String] = []
            session.onAppResizeError = { failures.append($0.localizedDescription) }
            try await wait { session.canResizeApp }
            session.toggleAppResize(size: CGSize(width: 500, height: 600))
            try await wait { session.isResizingApp }
            transport.eligibilityUpdates.continuation.yield(.resizing)
            await Task.yield()
            #expect(session.isResizingApp)
            switch end {
            case 0: transport.eligibilityUpdates.continuation.yield(.unavailable)
            case 1: transport.lease.invalidation.continuation.finish()
            default:
                transport.lease.adjustmentError = HostError.operation("Geometry rejected")
                session.resizeApp(to: CGSize(width: 600, height: 700))
            }
            try await wait { !session.isResizingApp }
            #expect(session.display === primary)
            #expect(app.disconnectCount == 1)
            #expect(transport.lease.invalidations == 1)
            #expect(failures == (end == 2 ? ["Geometry rejected"] : []))
        }
    }

    @Test func sigtermHandsOffOnTheMainActor() async throws {
        let previous = signal(SIGTERM, SIG_IGN)
        let handoffs = AsyncStream<Void>.makeStream()
        let source = HostApplication.observeHandoverSignal {
            MainActor.assertIsolated()
            handoffs.continuation.yield(())
        }
        defer {
            source.cancel()
            signal(SIGTERM, previous)
            handoffs.continuation.finish()
        }
        try #require(kill(getpid(), SIGTERM) == 0)
        var events = handoffs.stream.makeAsyncIterator()
        #expect(await events.next() != nil)
        await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
            source.setCancelHandler { @Sendable in finished.resume() }
            source.cancel()
        }
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
        #expect(window.firstResponder === display.inputView)
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
        #expect(content.bounds.contains(display.view.frame))
        controller.detachPresentation()
        #expect(controller.presentationViewController.parent == nil && content.superview == nil)
        #expect(display.disconnectCount == 0 && closes == 0)
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
        #expect(controller.window?.contentView === content)
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
        await controller.prepareForRestart()
        let replacement = TestDisplay()
        let replacementSession = try makeSession(replacement, features: [DeviceCapabilities.keyboard])
        controller.reconnect(replacementSession, present: false)
        #expect(controller.isEmbedded && controller.presentationViewController.parent === parent)
        #expect(controller.session === replacementSession && compactPresentations == 2)
        #expect(replacement.disconnectCount == 0 && display.disconnectCount == 1 && closes == 0)
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

    @Test func embeddedZoomKeepsPanningAndScaleSeparateFromCompactGeometry() throws {
        _ = NSApplication.shared
        let display = TestDisplay()
        let controller = try makeController(display)
        defer { controller.invalidate() }
        let session = controller.session
        let compactScale = display.renderScale
        let compactFrame = try #require(controller.window?.frame)
        let parent = NSViewController()
        parent.view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        let window = KeyPresentationWindow(contentRect: parent.view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = parent
        defer { window.close() }
        let outerFrame = window.frame
        controller.embed(in: parent)
        parent.view.layoutSubtreeIfNeeded()
        let content = controller.presentationViewController.view
        let scroll = try #require(content.subviews.compactMap { $0 as? NSScrollView }.first)
        #expect(controller.canvasZoom.mode == .fit)
        #expect(WindowScale.matches(display.renderScale, display.scale(for: content.bounds.size)))
        let fitScale = display.renderScale
        controller.performCanvasZoom(.zoomIn)
        #expect(display.renderScale > fitScale)
        controller.setScale(.pointAccurate)
        #expect(controller.canvasZoom.mode == .fixed(1) && display.renderScale == 1)
        #expect(window.frame == outerFrame && controller.window?.frame == compactFrame)
        let clip = scroll.contentView
        let local = NSPoint(x: 120, y: 400)
        let before = display.view.convert(local, to: content)
        let originalOrigin = clip.bounds.origin
        clip.scroll(to: NSPoint(x: 60, y: 240))
        scroll.reflectScrolledClipView(clip)
        let after = display.view.convert(local, to: content)
        #expect(after.x == before.x - (clip.bounds.minX - originalOrigin.x))
        #expect(after.y == before.y - (clip.bounds.minY - originalOrigin.y))
        #expect(display.view.convert(after, from: content) == local)
        parent.view.setFrameSize(NSSize(width: 250, height: 350))
        parent.view.layoutSubtreeIfNeeded()
        #expect(display.renderScale == 1 && controller.canvasZoom.mode == .fixed(1))
        let pannedCenter = NSPoint(x: clip.bounds.midX, y: clip.bounds.midY)
        controller.showCompactWindow()
        #expect(WindowScale.matches(display.renderScale, compactScale))
        controller.embed(in: parent)
        parent.view.layoutSubtreeIfNeeded()
        #expect(display.renderScale == 1 && controller.canvasZoom.mode == .fixed(1))
        #expect(abs(clip.bounds.midX - pannedCenter.x) < 1 && abs(clip.bounds.midY - pannedCenter.y) < 1)
        #expect(controller.session === session && display.disconnectCount == 0)
        controller.focusInput()
        #expect(window.firstResponder === display.inputView)
        controller.performCanvasZoom(.fit)
        #expect(controller.canvasZoomIsSelected(.fit))
        #expect(scroll.documentVisibleRect.contains(display.view.frame))
        parent.view.setFrameSize(NSSize(width: 220, height: 300))
        parent.view.layoutSubtreeIfNeeded()
        #expect(WindowScale.matches(display.renderScale, display.scale(for: content.bounds.size)))
        display.takeScreenSize(NSSize(width: 844, height: 390))
        content.layoutSubtreeIfNeeded()
        #expect(WindowScale.matches(display.renderScale, display.scale(for: content.bounds.size)))
        controller.performCanvasZoom(.physicalSize)
        let physicalScale = try #require(controller.scale(for: .physicalSize))
        #expect(controller.canvasZoomIsSelected(.physicalSize) && WindowScale.matches(display.renderScale, physicalScale))
        display.takeScreenSize(NSSize(width: 390, height: 844))
        content.layoutSubtreeIfNeeded()
        #expect(WindowScale.matches(display.renderScale, physicalScale))
        let zoomAction: CanvasZoom.Action = controller.canPerformCanvasZoom(.zoomOut) ? .zoomOut : .zoomIn
        try #require(controller.canPerformCanvasZoom(zoomAction))
        controller.performCanvasZoom(zoomAction)
        if zoomAction == .zoomOut {
            #expect(display.renderScale < physicalScale)
        } else {
            #expect(display.renderScale > physicalScale)
        }
        #expect(!controller.canvasZoomIsSelected(.physicalSize))
        #expect(window.frame == outerFrame)
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
        let recording = try #require(controller.session.recording)
        try await wait { pointer.faces[1] == .stopRecording }
        #expect(pointer.faces == [.home, .stopRecording, .rotateLeft])
        pointer.hold([])
        #expect(pointer.faces == [.home, .stopRecording, .rotate])
        pointer.exit()
        pointer.hold(.option)
        pointer.enter()
        #expect(pointer.faces == [.home, .stopRecording, .rotateLeft])
        #expect(try pointer.click(.saveScreen))
        #expect(recording.isStopping)
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
        // SimToolbar tracks all active-app windows, not just the key window.
        // AppKit sends exit/enter events when the app deactivates/reactivates.
        #expect(pointer.area.options == [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect])
        // Resigning key releases device modifiers without clearing toolbar alternates.
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
        // Modifier changes in another app do not reach this toolbar.
        pointer.exit()
        #expect(pointer.faces == ButtonFace.normal)
        pointer.holdInAnotherApp([])
        pointer.holdInAnotherApp(.option)
        #expect(pointer.faces == ButtonFace.normal)
        pointer.enter()
        #expect(pointer.faces == ButtonFace.optionAlternates)
    }

    @Test func quickSaveScreenUsesTheScreenshotFolderAndMaskPreference() async throws {
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
        #expect(display.pasteboards.isEmpty)
        controller.perform(.getPasteboard)
        controller.perform(.sendPasteboard)
        controller.perform(.getPasteboard)
        let connection = try #require(display.pasteboards.first)
        #expect(display.pasteboards.count == 1)
        #expect(connection.pasteboard === pasteboard)
        #expect(connection.transfers == [.get, .send, .get])
        #expect(connection.automaticSync == [false])
        // Keep the connection alive for lazy reads from the Mac pasteboard.
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

        // The first activation belongs to the connection; later activations complete pushes.
        transfer(.send)
        let first = try #require(display.pasteboards.first)
        first.send(.activated)
        first.send(.activated)
        transfer(.get)
        first.send(.failedToApply(HostError.operation("pasteboard communication failure")))
        #expect(failures.last == get + "pasteboard communication failure")
        transfer(.get)
        first.send(.applied(generation: 1))
        first.send(.lostConnection)
        #expect(failures.count == 2)
        #expect(first.isDisconnected)

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

    @Test func nativeRuntimeJoinsPreparationAndRecoversAfterToolkitMismatch() async throws {
        async let first = makeRuntime()
        async let second = makeRuntime()
        let (runtime, joined) = try await (first, second)
        #expect(runtime === joined)

        let otherToolkit = runtime.uiXcodeURL.appendingPathComponent("DifferentXcode.app")
        await #expect(throws: HostError.self) {
            try await SimulatorRuntime.load(xcodeURL: runtime.xcodeURL, uiXcodeURL: otherToolkit)
        }
        let retried = try await SimulatorRuntime.load(xcodeURL: runtime.xcodeURL, uiXcodeURL: runtime.uiXcodeURL)
        #expect(try SimulatorRuntime.selectUIXcode(from: [otherToolkit]) == runtime.uiXcodeURL)
        #expect(retried.pasteboard.serviceName == "com.apple.CoreSimulator.SimPasteboardInterface")
    }

    @Test func pasteboardDelegateAnswersSimPasteboardPlus() async throws {
        let runtime = try await makeRuntime()
        #expect(runtime.pasteboard.serviceName == "com.apple.CoreSimulator.SimPasteboardInterface")
        // Optional protocol callbacks must match the private Objective-C declarations.
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

        #expect(try start().1.pasteboards.isEmpty)

        sync.toggle()
        let (session, display) = try start()
        let connection = try #require(display.pasteboards.first)
        #expect(display.pasteboards.count == 1)
        #expect(connection.pasteboard === pasteboard)
        #expect(connection.automaticSync == [true])
        #expect(connection.transfers == [.send])
        #expect(!session.canTransferPasteboard)
        session.transferPasteboard(.get) { _ in Issue.record("no transfer") }
        #expect(connection.transfers == [.send])
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

        sync.toggle()
        #expect(phoneConnection.automaticSync == [false, true])
        let padConnection = try #require(padDisplay.pasteboards.first)
        #expect(padConnection.automaticSync == [true])
        #expect(padConnection.transfers.isEmpty)
        #expect(tvDisplay.pasteboards.isEmpty)
        #expect(!phone.canTransferPasteboard && !pad.canTransferPasteboard)

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

        sync.toggle()
        copy(on: third, "third")
        try await settle()
        #expect(pushes() == [1, 2, 4])
    }

    @Test func copiesReachSameUDIDDevicesInOtherSetsWithoutEcho() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.lynnswap.NeoSimulatorTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let preferences = MemoryPreferences()
        preferences.values[HostPreferences.pasteboardAutomaticSync] = true
        var sessions: [DeviceSession] = []
        let sync = PasteboardSync(preferences: preferences) { sessions }
        var connections: [TestPasteboard] = []
        for path in [nil, "/fixture/XCTestDevices"] as [String?] {
            let display = TestDisplay()
            let session = try makeSession(display, features: [DeviceCapabilities.pasteboard], device: "same",
                deviceSetPath: path, pasteboard: pasteboard, pasteboardSync: sync)
            sessions.append(session)
            session.startPasteboardSync()
            connections.append(try #require(display.pasteboards.first))
        }
        defer { sessions.forEach { $0.disconnect() } }
        let before = connections.map { $0.transfers.count }
        pasteboard.clearContents()
        pasteboard.setString("copied", forType: .string)
        await withCheckedContinuation { continuation in
            connections[0].send(.applied(generation: pasteboard.changeCount))
            // This marker runs after the forwarding block scheduled in this run-loop mode.
            RunLoop.main.perform(inModes: [.default]) { continuation.resume() }
        }
        #expect(connections[0].transfers.count == before[0])
        #expect(connections[1].transfers.count == before[1] + 1)
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

        // Reconnection resumes synchronization without replacing the guest's pasteboard.
        first.send(.lostConnection)
        #expect(first.isDisconnected)
        #expect(display.pasteboards.count == 2)
        let second = try #require(display.pasteboards.last)
        #expect(second.automaticSync == [true])
        #expect(second.transfers.isEmpty)

        display.isBooted = false
        second.send(.lostConnection)
        #expect(display.pasteboards.count == 2)
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
        let pluginDelegate = TestPluginToolbarDelegate()
        toolbar.delegate = pluginDelegate
        toolbar.insertItem(withItemIdentifier: TestPluginToolbarDelegate.itemIdentifier, at: 0)
        // SimulatorKit loads the Apple Vision Pro plugin before opening its window.
        display.plugin = SimulatorUserInterfacePlugin(overlayView: overlay, toolbar: toolbar)
        let controller = try makeController(display, family: .vision, features: [], userInterfacePlugin: true)
        defer { controller.invalidate() }
        let window = try #require(controller.window)
        #expect(window.toolbar === toolbar)
        var mainWindowRequests = 0
        controller.onShowInMainWindow = { mainWindowRequests += 1 }
        let mainWindowItem = try #require(toolbar.items.first { $0.itemIdentifier.rawValue == "ShowInMainWindow" })
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
        #expect(overlay.tryToPerform(Selector(("homeButtonPressed:")), with: nil))
        #expect(display.buttons == [.home])
    }

    @Test func visionOSMenuCommandsGoToThePluginsOverlay() throws {
        _ = NSApplication.shared
        MenuController(application: nil).install()
        defer { NSApp.mainMenu = nil }
        let items = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap { menu in
            menu.items + menu.items.compactMap(\.submenu).flatMap(\.items)
        } ?? []
        let commands = try ["Re-Center Open Apps", "Orbit Mode", "75%", "Show Gaze Target",
                            "User and 2 Spatial Participants"].map { title in
            try #require(items.first { $0.title == title })
        }
        let display = TestDisplay()
        let overlay = PluginOverlay()
        display.view.addSubview(overlay)
        display.plugin = SimulatorUserInterfacePlugin(overlayView: overlay, toolbar: nil)
        let controller = try makeController(display, family: .vision, features: [DeviceCapabilities.hoverboard],
                                            userInterfacePlugin: true)
        defer { controller.invalidate() }
        let window = try #require(controller.window)
        controller.focusInput()
        // The plugin overlay handles and validates these responder-chain actions.
        for command in commands {
            let action = try #require(command.action)
            let target = try #require(responder(in: window, taking: action))
            #expect(target === overlay, "\(command.title)")
            #expect((target as? NSMenuItemValidation)?.validateMenuItem(command) == true)
            #expect(NSApp.sendAction(action, to: target, from: command))
        }
        #expect(overlay.actions == ["recenterAllOpenApps:", "viewportModeChangedToOrbit:", "setImmersionTo75:",
                                    "toggleShowGazeTarget:", "configureSimulatedFaceTimeSession1x2:"])
        #expect(overlay.validateMenuItem(commands[3]) && commands[3].state == .on)
        let phone = try makeController(TestDisplay())
        defer { phone.invalidate() }
        phone.focusInput()
        let phoneWindow = try #require(phone.window)
        #expect(commands.allSatisfy { responder(in: phoneWindow, taking: $0.action!) == nil })
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
        let toolbar = NSToolbar(identifier: "LatePluginToolbar")
        display.plugin = SimulatorUserInterfacePlugin(overlayView: nil, toolbar: toolbar)
        try await wait { window.toolbar === toolbar }
        #expect(window.toolbar === toolbar && toolbar !== deviceToolbar)
        #expect(window.attachedSheet == nil)

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
        // Simulator.app's plugin uses toggleVideoRecording: to stop recording.
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
            ["Restart", "Erase All Content and Settings…", "Shut Down", "-", "Home", "Re-Center Open Apps", "Lock",
             "Shake", "App Switcher", "-", "Trigger Screenshot"])
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
        // Matches IndigoWatchToolbar, IndigoTVToolbar, and IndigoWatchAODToolbar.
        #expect(try items(.watch, [DeviceCapabilities.keyboard]) == [.home, .saveScreen])
        #expect(try items(.tv, [DeviceCapabilities.keyboard]) == [.home, .saveScreen])
        #expect(try items(.watch, [DeviceCapabilities.alwaysOnDisplay]) == [.home, .saveScreen, .alwaysOn])
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
        // Simulator.app treats backlight states 0/1 as on, 2 as off, and ignores unknown values.
        for (backlight, on) in [(1, true), (-101, true), (2, false), (-101, false), (0, true)] as [(Int32, Bool)] {
            display.backlightState = backlight
            display.onPropertiesChange?()
            #expect(controller.session.showsAlwaysOn == on, "backlight \(backlight)")
            try await wait { button.state == (on ? .on : .off) }
            #expect(button.state == (on ? .on : .off), "backlight \(backlight)")
        }
        // Lock leaves the indicator unchanged until the backlight reports a new state.
        button.performClick(nil)
        #expect(display.buttons == [.lock])
        #expect(button.state == .on)
        display.backlightState = 2
        display.onPropertiesChange?()
        try await wait { button.state == .off }
        #expect(button.state == .off)
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
        let commands = ["Restart", "Erase All Content and Settings…", "Shut Down", "-", "Home", "Re-Center Open Apps"]
        #expect(try visible("Device", .watch) == commands + ["Lock", "Side Button"])
        #expect(try visible("Device", .tv) == commands)
        #expect(try visible("Device", .vision) == commands + [
            "-", "Interaction Mode", "Look Around Mode", "Pan Mode", "Orbit Mode", "Dolly Mode", "-", "Reset Camera", "-",
            "Simulated Scenes",
        ])
        #expect(try !visible("Window", .vision).contains("Show Device Bezels"))
        #expect(try visible("Window", .watch).contains("Show Device Bezels"))
    }

    @Test func watchGesturesAndSimulateFallFollowSimulatorAppsMenus() throws {
        _ = NSApplication.shared
        let menus = MenuController(application: nil)
        menus.install()
        defer { NSApp.mainMenu = nil }
        func visible(_ title: String, submenu: String? = nil, runtime: UInt32 = 0x1B_00_00,
                     _ features: Set<String>) throws -> [String] {
            let menu = try #require(NSApp.mainMenu?.items.first { $0.title == title }?.submenu)
            menus.updateVisibility(in: menu, for: DeviceCapabilities(family: .watch, runtimeVersion: runtime,
                                                                     supportsFeature: { features.contains($0) }))
            let shown = try submenu.map { name in try #require(menu.items.first { $0.title == name }?.submenu) } ?? menu
            return shown.items.filter { !$0.isHidden }.map { $0.isSeparatorItem ? "-" : $0.title }
        }
        let gestures = DeviceCapabilities.watchGestures, fall = DeviceCapabilities.fallDetection
        // Wrist Flick requires watchOS 12.
        #expect(try visible("Device", [gestures, DeviceCapabilities.actionButtonSting, DeviceCapabilities.siri])
            == ["Restart", "Erase All Content and Settings…", "Shut Down", "-", "Home", "Re-Center Open Apps", "Lock",
                "Side Button", "Action Button", "Gestures", "Siri"])
        #expect(try visible("Device", submenu: "Gestures", [gestures]) == ["Double Tap", "Wrist Flick"])
        #expect(try visible("Device", submenu: "Gestures", runtime: 0x0B_06_00, [gestures]) == ["Double Tap"])
        #expect(try visible("Device", submenu: "Gestures", runtime: 0x0C_00_00, [gestures])
            == ["Double Tap", "Wrist Flick"])
        #expect(try !visible("Device", [fall]).contains("Gestures"))
        #expect(try visible("Features", [fall, DeviceCapabilities.faceID, DeviceCapabilities.applePayAuthorization])
            .prefix(3) == ["Face ID", "Simulate Fall", "Authorize Apple Pay"])
        #expect(try visible("Features", submenu: "Simulate Fall", [fall])
            == ["Confirmed", "Dismissed", "Rejected", "Unresponsive"])
        #expect(try !visible("Features", [gestures]).contains("Simulate Fall"))
        let items = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items)
            .filter { ["Gestures", "Simulate Fall"].contains($0.title) }.compactMap(\.submenu).flatMap(\.items)
        #expect(items?.count == 6 && items?.allSatisfy(\.keyEquivalent.isEmpty) == true)
    }

    // MARK: Apple TV Remote

    @Test(arguments: [false, true]) func theAppleTVRemoteItemShowsAndHidesTheRemoteAsInSimulatorApp(integrated: Bool) throws {
        _ = NSApplication.shared
        let menus = MenuController(application: nil)
        let windowMenu: NSMenu
        if integrated {
            windowMenu = NSMenu(title: "View")
            menus.addScreenCommands(file: NSMenu(), edit: NSMenu(), view: windowMenu)
        } else {
            menus.install()
            windowMenu = try #require(NSApp.mainMenu?.items.first { $0.title == "Window" }?.submenu)
        }
        defer { NSApp.mainMenu = nil }
        let item = try #require(windowMenu.items.first { $0.title == "Show Apple TV Remote" })
        // Matches Simulator.app's MainMenu.nib placement and shortcut.
        let index = windowMenu.index(of: item)
        #expect(windowMenu.items[index - 1].title == "Show Device Bezels")
        #expect(windowMenu.items[index + 1].title == "Stay On Top")
        let fullScreen = try #require(windowMenu.items.first { $0.title == "Enter Full Screen" })
        #expect(fullScreen.keyEquivalent == "f" && fullScreen.keyEquivalentModifierMask == [.command, .control])
        #expect(item.keyEquivalent == "r" && item.keyEquivalentModifierMask == [.command, .shift])
        for family in [DeviceCapabilities.Family.iPhone, .iPad, .tv, .watch, .vision] {
            menus.updateVisibility(in: windowMenu, for: DeviceCapabilities(family: family, runtimeVersion: 0x1B_00_00,
                                                                           supportsFeature: { _ in false }))
            #expect(!item.isHidden)
        }
        let remote = TVRemoteController(target: { nil })
        let tv = try makeController(TestDisplay(), family: .tv, features: [DeviceCapabilities.tvRemote], tvRemote: remote)
        let phone = try makeController(TestDisplay(), tvRemote: remote)
        defer {
            tv.invalidate()
            phone.invalidate()
            remote.close()
        }
        let command = DeviceCommand.command(.appleTVRemote)
        #expect(!command.validate(item, for: phone))
        #expect(command.validate(item, for: tv))
        #expect(item.title == "Show Apple TV Remote")
        tv.perform(.appleTVRemote)
        #expect(remote.isVisible)
        #expect(command.validate(item, for: tv))
        #expect(item.title == "Hide Apple TV Remote")
        tv.perform(.appleTVRemote)
        #expect(!remote.isVisible)
        #expect(command.validate(item, for: tv))
        #expect(item.title == "Show Apple TV Remote")
        // AppleRemotePanel leaves keyboard focus in the device window.
        #expect(remote.window?.canBecomeKey == false)
    }

    @Test func theRemotesButtonsHoldTheAppleTVsButtonsAsInSimulatorApp() throws {
        _ = NSApplication.shared
        let display = TestDisplay()
        var target: DeviceWindowController?
        let remote = TVRemoteController(target: { target })
        let tv = try makeController(display, family: .tv, features: [DeviceCapabilities.tvRemote], tvRemote: remote)
        let phoneDisplay = TestDisplay()
        let phone = try makeController(phoneDisplay, tvRemote: remote)
        defer {
            tv.invalidate()
            phone.invalidate()
            remote.close()
        }
        target = tv
        remote.showWindow(nil)
        let content = try #require(remote.window?.contentView)
        func view(_ label: String) throws -> NSView {
            try #require(content.subviews.first { $0.accessibilityLabel() == label }, "\(label)")
        }
        let click = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: remote.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let buttons: [(String, TVRemoteButton)] = [
            ("Select", .select), ("Menu", .menu), ("TV", .tv), ("Siri", .siri), ("Play/Pause", .playPause),
            ("Volume Up", .volumeUp), ("Volume Down", .volumeDown),
        ]
        for (label, button) in buttons {
            let view = try view(label)
            view.mouseDown(with: click)
            #expect(display.events.last?.input == .tvRemote(button) && display.events.last?.state == .down, "\(label)")
            view.mouseUp(with: click)
            #expect(display.events.last?.input == .tvRemote(button) && display.events.last?.state == .up, "\(label)")
        }
        #expect(display.events.count == 14)
        target = phone
        try view("Menu").mouseDown(with: click)
        try view("Menu").mouseUp(with: click)
        #expect(phoneDisplay.events.isEmpty)
        target = tv
        try view("Siri").mouseDown(with: click)
        remote.close()
        #expect(display.events.suffix(2).map(\.input) == [.tvRemote(.siri), .tvRemote(.siri)])
        #expect(display.events.suffix(2).map(\.state) == [.down, .up])
        remote.showWindow(nil)
        try view("Play/Pause").mouseDown(with: click)
        tv.session.disconnect()
        try view("Play/Pause").mouseUp(with: click)
        #expect(display.events.suffix(2).map(\.input) == [.tvRemote(.playPause), .tvRemote(.playPause)])
        #expect(display.events.suffix(2).map(\.state) == [.down, .up])
        #expect(display.events.count == 18)
    }

    @Test func theRemotesTouchSurfaceTouchesWhileOptionIsHeldAsInSimulatorApp() throws {
        _ = NSApplication.shared
        let display = TestDisplay(), other = TestDisplay()
        var target: DeviceWindowController?
        let remote = TVRemoteController(target: { target })
        let tv = try makeController(display, family: .tv, features: [DeviceCapabilities.tvRemote], tvRemote: remote)
        let otherTV = try makeController(other, family: .tv, features: [DeviceCapabilities.tvRemote], tvRemote: remote)
        defer {
            tv.invalidate()
            otherTV.invalidate()
            remote.close()
        }
        target = tv
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
        target = otherTV
        surface.mouseMoved(with: try event(.mouseMoved, 0.5, 0.75, option: true))
        #expect(display.remoteTouches.suffix(2) == [touch(.began, 0.5, 0.5), touch(.ended, 0.5, 0.75)])
        #expect(other.remoteTouches == [touch(.began, 0.5, 0.75)])
        remote.close()
        #expect(other.remoteTouches.last == touch(.ended, 0.5, 0.75))
        remote.showWindow(nil)
        target = tv
        surface.mouseEntered(with: try event(.mouseEntered, 0.25, 0.25, option: true))
        tv.session.disconnect()
        surface.mouseExited(with: try event(.mouseExited, 0, 0.25, option: true))
        #expect(display.remoteTouches.suffix(2) == [touch(.began, 0.25, 0.25), touch(.ended, 0.25, 0.25)])
        #expect(display.remoteTouches.count == 12)
    }

    @Test func aDragOffTheRemotesTouchSurfaceEndsTheTouchAtItsEdge() throws {
        _ = NSApplication.shared
        let display = TestDisplay()
        var target: DeviceWindowController?
        let remote = TVRemoteController(target: { target })
        let tv = try makeController(display, family: .tv, features: [DeviceCapabilities.tvRemote], tvRemote: remote)
        defer {
            tv.invalidate()
            remote.close()
        }
        target = tv
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
        var target: DeviceWindowController?
        let remote = TVRemoteController(target: { target })
        let tv = try makeController(display, family: .tv, features: [DeviceCapabilities.tvRemote], tvRemote: remote)
        defer {
            tv.invalidate()
            remote.close()
        }
        target = tv
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

    @Test func closingTheRemoteSendsAgainWhatAnotherAppleTVStillHolds() throws {
        _ = NSApplication.shared
        let first = TestDisplay(), second = TestDisplay()
        var target: DeviceWindowController?
        let remote = TVRemoteController(target: { target })
        let a = try makeController(first, family: .tv, features: [DeviceCapabilities.tvRemote], device: "a", tvRemote: remote)
        let b = try makeController(second, family: .tv, features: [DeviceCapabilities.tvRemote], device: "b", tvRemote: remote)
        defer {
            a.invalidate()
            b.invalidate()
            remote.close()
        }
        remote.showWindow(nil)
        let window = try #require(remote.window)
        let content = try #require(window.contentView)
        let surface = try #require(content.subviews.compactMap { $0 as? TVRemoteTouchSurface }.first)
        let menu = try #require(content.subviews.first { $0.accessibilityLabel() == "Menu" })
        func event(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) throws -> NSEvent {
            let location = surface.convert(NSPoint(x: x * surface.bounds.width, y: (1 - y) * surface.bounds.height), to: nil)
            if type == .mouseEntered {
                return try #require(NSEvent.enterExitEvent(
                    with: type, location: location, modifierFlags: .option, timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
            }
            return try #require(NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: .option, timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        func touch(_ phase: TVRemoteTouch.Phase, _ x: CGFloat, _ y: CGFloat) -> TVRemoteTouch {
            TVRemoteTouch(phase: phase, point: CGPoint(x: x, y: y))
        }
        // Switching targets leaves A's failed touch-end pending while B receives input.
        target = a
        surface.mouseEntered(with: try event(.mouseEntered, 0.5, 0.5))
        first.undeliveredTouches = 1
        target = b
        surface.mouseMoved(with: try event(.mouseMoved, 0.5, 0.75))
        remote.close()
        #expect(first.remoteTouches == [touch(.began, 0.5, 0.5), touch(.ended, 0.5, 0.75), touch(.ended, 0.5, 0.75)])
        #expect(second.remoteTouches == [touch(.began, 0.5, 0.75), touch(.ended, 0.5, 0.75)])
        // Both devices may hold Menu when A's release fails before switching to B.
        remote.showWindow(nil)
        target = a
        first.undeliveredEvents = [1]
        menu.mouseDown(with: try event(.leftMouseDown, 0, 0))
        menu.mouseUp(with: try event(.leftMouseUp, 0, 0))
        target = b
        menu.mouseDown(with: try event(.leftMouseDown, 0, 0))
        remote.close()
        #expect(first.events.map(\.state) == [.down, .up, .up])
        #expect(second.events.map(\.state) == [.down, .up])
        #expect((first.events + second.events).allSatisfy { $0.input == .tvRemote(.menu) })
    }

    @Test func aRemoteButtonOrTouchReportsOneErrorEach() throws {
        let display = TestDisplay()
        display.deliveryError = HostError.operation("delivery failed")
        let controller = try makeController(display, family: .tv, features: [DeviceCapabilities.tvRemote])
        defer { controller.invalidate() }
        var failures = 0
        controller.session.pressRemoteButton(.menu) { _ in failures += 1 }
        controller.session.releaseRemoteButton(.menu)
        #expect(display.events.count == 2 && failures == 1)
        for point in [CGPoint(x: 0.25, y: 0.25), CGPoint(x: 0.5, y: 0.5)] {
            controller.session.touchRemote(at: point) { _ in failures += 1 }
        }
        controller.session.liftRemoteTouch(at: CGPoint(x: 0.5, y: 0.5))
        #expect(display.remoteTouches.map(\.phase) == [.began, .moved, .ended] && failures == 2)
    }

    @Test func theRemoteClosesForAnotherDeviceAndWithTheLastAppleTVAsInSimulatorApp() throws {
        _ = NSApplication.shared
        let remote = TVRemoteController(target: { nil })
        func make(_ family: DeviceCapabilities.Family, _ features: Set<String>) throws -> DeviceWindowController {
            let controller = try makeController(TestDisplay(), family: family, features: features, tvRemote: remote)
            controller.showWindow(nil)
            return controller
        }
        func becomeKey(_ controller: DeviceWindowController) {
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: controller.window)
        }
        let tv = try make(.tv, [DeviceCapabilities.tvRemote])
        let phone = try make(.iPhone, [])
        defer {
            tv.invalidate()
            phone.invalidate()
            remote.close()
        }
        remote.showWindow(nil)
        becomeKey(tv)
        #expect(remote.isVisible)
        becomeKey(phone)
        #expect(!remote.isVisible)
        remote.showWindow(nil)
        tv.window?.close()
        #expect(remote.isVisible)
        let lastTV = try make(.tv, [DeviceCapabilities.tvRemote])
        defer { lastTV.invalidate() }
        phone.window?.close()
        #expect(remote.isVisible)
        try #require(!NSApp.windows.contains { $0 !== lastTV.window && $0.isVisible && $0.windowController is DeviceWindowController })
        lastTV.window?.close()
        #expect(!remote.isVisible)
        let shutDown = try make(.tv, [DeviceCapabilities.tvRemote])
        remote.showWindow(nil)
        shutDown.invalidate()
        #expect(!remote.isVisible)
    }

    @Test func anotherDevicesExternalDisplayWindowClosesTheRemoteAsItsDeviceWindowDoes() throws {
        _ = NSApplication.shared
        let remote = TVRemoteController(target: { nil })
        let tv = try makeController(TestDisplay(), family: .tv, features: [DeviceCapabilities.tvRemote], tvRemote: remote)
        let screen = TestExternalScreen()
        let (phone, _) = try makeExternalDisplayController(screen)
        defer {
            tv.invalidate()
            phone.invalidate()
            remote.close()
        }
        screen.report { $0 = ExternalScreenState(isPoweredOn: true, pixelSize: CGSize(width: 1280, height: 720), scale: 1) }
        let external = try #require(phone.externalDisplayWindow?.window)
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        remote.showWindow(nil)
        #expect(DeviceCommand.command(.appleTVRemote).validate(item, for: tv) && item.title == "Hide Apple TV Remote")
        // Simulator.app treats an external display window as its iPhone's window.
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: external)
        #expect(!remote.isVisible)
        _ = DeviceCommand.command(.appleTVRemote).validate(item, for: tv)
        #expect(item.title == "Show Apple TV Remote")
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

    @Test func visionOSCommandsFollowSimulatorAppsMainMenu() throws {
        _ = NSApplication.shared
        let menus = MenuController(application: nil)
        menus.install()
        defer { NSApp.mainMenu = nil }
        func menu(_ title: String, in parent: NSMenu? = NSApp.mainMenu) throws -> NSMenu {
            try #require(parent?.items.first { $0.title == title }?.submenu)
        }
        func visible(_ menu: NSMenu, _ capabilities: DeviceCapabilities) -> [String] {
            menus.updateVisibility(in: menu, for: capabilities)
            return menu.items.filter { !$0.isHidden }.map { $0.isSeparatorItem ? "-" : $0.title }
        }
        func device(_ family: DeviceCapabilities.Family, _ features: Set<String>) -> DeviceCapabilities {
            DeviceCapabilities(family: family, runtimeVersion: 0x1A_05_00, supportsFeature: { features.contains($0) })
        }
        let vision = device(.vision, [DeviceCapabilities.opticID, DeviceCapabilities.hoverboard])
        let phone = device(.iPhone, [])
        // Match Simulator.app's responder actions and Control-Command camera shortcuts.
        let deviceMenu = try menu("Device")
        let deviceCommands = try ["Re-Center Open Apps", "Interaction Mode", "Look Around Mode", "Pan Mode", "Orbit Mode",
                                  "Dolly Mode", "Reset Camera", "Simulated Scenes"].map { title in
            try #require(deviceMenu.items.first { $0.title == title })
        }
        #expect(deviceCommands.map { $0.action.map(NSStringFromSelector) } == [
            "recenterAllOpenApps:", "viewportModeChangedToInteraction:", "viewportModeChangedToLookAround:",
            "viewportModeChangedToPan:", "viewportModeChangedToOrbit:", "viewportModeChangedToDolly:",
            "resetViewportCamera:", "selectSimulatedScene:",
        ])
        #expect(deviceCommands.allSatisfy { $0.target == nil && $0.submenu == nil })
        #expect(deviceCommands.map(\.keyEquivalent) == ["", "1", "2", "3", "4", "5", "0", ""])
        #expect(deviceCommands.filter { !$0.keyEquivalent.isEmpty }.allSatisfy {
            $0.keyEquivalentModifierMask == [.control, .command]
        })
        // Simulator.app hides Increase/Decrease Immersion, 0%, and 25%.
        let io = try menu("I/O")
        #expect(visible(io, vision) == ["Audio Input", "Audio Output", "-", "Set Immersion To", "-", "Open URL…"])
        #expect(!visible(io, phone).contains("Set Immersion To"))
        let immersion = try menu("Set Immersion To", in: io)
        #expect(immersion.items.map(\.title) == ["50%", "75%", "100%"])
        #expect(immersion.items.map { $0.action.map(NSStringFromSelector) } ==
            ["setImmersionTo50:", "setImmersionTo75:", "setImmersionTo100:"])
        #expect(immersion.items.allSatisfy { $0.target == nil && $0.keyEquivalent.isEmpty })
        // Optic ID and FaceTime commands have no shortcuts on Apple Vision Pro.
        let features = try menu("Features")
        #expect(visible(features, vision) == ["Optic ID", "-", "FaceTime", "-", "Trigger iCloud Sync", "-", "Location"])
        #expect(!visible(features, phone).contains("Optic ID"))
        #expect(!visible(features, phone).contains("FaceTime"))
        let faceTime = try menu("FaceTime", in: features)
        #expect(faceTime.items.map(\.title) == [
            "User and 1 Spatial Participant", "User and 2 Spatial Participants", "User and 3 Spatial Participants",
            "User and 4 Spatial Participants", "User, 1 Participant and 4 Spatial Participants",
            "User, 8 Participants and 4 Spatial Participants",
        ])
        #expect(faceTime.items.map { $0.action.map(NSStringFromSelector) } == [
            "configureSimulatedFaceTimeSession1x1:", "configureSimulatedFaceTimeSession1x2:",
            "configureSimulatedFaceTimeSession1x3:", "configureSimulatedFaceTimeSession1x4:",
            "configureSimulatedFaceTimeSession1x4x1:", "configureSimulatedFaceTimeSession1x4x8:",
        ])
        #expect(faceTime.items.allSatisfy { $0.target == nil && $0.keyEquivalent.isEmpty })
        menus.updateKeyEquivalents(for: vision)
        let opticID = try menu("Optic ID", in: features)
        #expect(opticID.items.map(\.title) == ["Enrolled", "Matching Eye", "Non-matching Eye"])
        #expect(opticID.items.map(\.keyEquivalent) == ["", "", ""])
        let debug = try menu("Debug")
        #expect(visible(debug, vision).suffix(5) ==
            ["Simulate Memory Warning", "-", "Show Gaze Target", "-", "Show Parallel Testing Devices"])
        #expect(!visible(debug, device(.vision, [DeviceCapabilities.opticID])).contains("Show Gaze Target"))
        let gaze = try #require(debug.items.first { $0.title == "Show Gaze Target" })
        #expect(gaze.action == Selector(("toggleShowGazeTarget:")) && gaze.target == nil)
    }

    @Test(arguments: [false, true]) func onlyADeviceThatRotatesReadsItsOrientation(embedded: Bool) async throws {
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
        // Simulator.app queries orientation only for iPhone and iPad displays.
        let watch = try makeController(TestDisplay(), family: .watch, features: [DeviceCapabilities.keyboard],
                                       devicectl: devicectl)
        defer { watch.invalidate() }
        var position = NSPoint.zero
        let parent = NSViewController()
        parent.view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        if embedded { watch.embed(in: parent) }
        else { watch.showNewWindow(cascadingFrom: &position) }
        #expect(!watch.session.isBusy)
        #expect(!FileManager.default.fileExists(atPath: log.path))
        let phone = try makeController(TestDisplay(), devicectl: devicectl, device: "phone")
        defer { phone.invalidate() }
        if embedded { phone.embed(in: parent) }
        else { phone.showNewWindow(cascadingFrom: &position) }
        #expect(phone.session.isBusy)
        while phone.session.isBusy {
            await withCheckedContinuation { continuation in
                withObservationTracking { _ = phone.session.isBusy } onChange: { continuation.resume() }
            }
        }
        #expect(try String(contentsOf: log, encoding: .utf8).contains("orientation get"))
        if embedded {
            phone.showCompactWindow()
            phone.embed(in: parent)
            #expect(!phone.session.isBusy)
            #expect(try String(contentsOf: log, encoding: .utf8).split(separator: "\n").count == 1)
        }
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
        window.setContentSize(NSSize(width: 600, height: 400))
        controller.setDeviceBezelVisible(false)
        let chosen = window.frame.size
        display.onPropertiesChange?()
        #expect(window.frame.size == chosen)
        #expect(display.rotations == [90])
    }

    @Test func resumingGuestFollowAppliesTheNextGuestRotation() throws {
        let display = TestDisplay()
        // Keep Point Accurate small enough for the test display in either orientation.
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
        controller.perform(.rotateDeviceAutomatically)
        display.guestInterfaceAngle = 90
        display.naturalSize = landscape
        display.onPropertiesChange?()
        controller.setScale(.pointAccurate)
        #expect(isLandscape())
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
        // A bezel-free display sits directly below the header, even below the manual minimum width.
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
        window.setContentSize(NSSize(width: 360, height: 500))
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        #expect(display.renderScale != 1 && display.renderScale != 1.5)
        #expect(checked().isEmpty)
        controller.perform(.pixelAccurate)
        display.screenScale = 1.25 * backing
        #expect(display.renderScale == 1.5)
        #expect(checked().isEmpty)
    }

    @Test func unavailableScaleCommandsKeepTheirCheckmarks() throws {
        let display = TestDisplay()
        display.naturalSize = NSSize(width: 160, height: 320)
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
        // Simulator.app preserves checkmarks when scale commands are unavailable in full screen,
        controller.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification, object: window))
        window.setContentSize(NSSize(width: 500, height: 900))
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        #expect(display.renderScale != 1.5)
        #expect(checked(for: controller) == [.pixelAccurate])
        controller.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: window))
        #expect(display.renderScale == 1.5)
        // on another screen for Physical Size,
        controller.perform(.physicalSize)
        #expect(display.renderScale == 0.5)
        #expect(checked(for: controller) == [.physicalSize])
        display.displayClass = 1
        controller.perform(.pointAccurate)
        #expect(checked(for: controller) == [.physicalSize, .pointAccurate])
        // or without a device window.
        display.displayClass = 0
        #expect(checked(for: nil) == [.physicalSize, .pointAccurate])
    }

    @Test func fitScreenFillsTheScreenAndCentersTheWindow() throws {
        let display = TestDisplay()
        display.naturalSize = NSSize(width: 400, height: 300)
        let controller = try makeController(display)
        defer { controller.invalidate() }
        controller.showWindow(nil)
        let window = try #require(controller.window)
        let visible = try #require((window.screen ?? NSScreen.main)?.visibleFrame)
        // Fit below the window header, matching Simulator.app.
        let above = window.frame.height - window.contentLayoutRect.height
        controller.perform(.fitScreen)
        let expected = min((visible.width - 20) / 400, (visible.height - above - 20) / 300)
        #expect(abs(display.renderScale - expected) < 0.000_001)
        #expect(abs(window.frame.midX - visible.midX) < 1 && abs(window.frame.midY - visible.midY) < 1)
        #expect(visible.contains(window.frame))
        #expect(DeviceCommand.command(.fitScreen).state == nil)
    }

    @Test func fitScreenFitsAWindowThatTakesTheExpandedTitleBar() throws {
        let display = TestDisplay()
        display.naturalSize = NSSize(width: 600, height: 300)
        let controller = try makeController(display)
        defer { controller.invalidate() }
        controller.showWindow(nil)
        let window = try #require(controller.window)
        let visible = try #require((window.screen ?? NSScreen.main)?.visibleFrame)
        #expect(window.toolbarStyle == .unified)
        // A narrow display switches to the taller expanded title bar during fitting.
        let tall = NSSize(width: 60, height: visible.height * 2)
        display.naturalSize = tall
        controller.perform(.fitScreen)
        #expect(window.toolbarStyle == .expanded)
        // AppKit constrains bezel-free windows; the scale reveals whether the display fits.
        func fitted(_ window: NSWindow) -> CGFloat {
            (visible.height - (window.frame.height - window.contentLayoutRect.height) - 20) / tall.height
        }
        #expect(abs(display.renderScale - fitted(window)) < 0.000_001)
        #expect(window.frame.height <= visible.height)
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
        display.naturalSize = NSSize(width: 600, height: 300)
        let controller = try makeController(display)
        defer { controller.invalidate() }
        controller.showWindow(nil)
        let window = try #require(controller.window)
        let visible = try #require(window.screen?.visibleFrame)
        let pointAccurate = DeviceCommand.command(.pointAccurate)
        #expect(window.toolbarStyle == .unified)
        // The expanded title bar makes this height too tall.
        display.naturalSize = NSSize(width: 60, height: visible.height - 60)
        #expect(!pointAccurate.isEnabled(controller))
        // The unified title bar leaves enough space for the same height.
        controller.perform(.fitScreen)
        #expect(window.toolbarStyle == .expanded)
        display.naturalSize = NSSize(width: 600, height: visible.height - 60)
        #expect(pointAccurate.isEnabled(controller))
    }

    @Test func scaleCommandsAreValidatedAsInSimulator() throws {
        let display = TestDisplay()
        display.naturalSize = NSSize(width: 200, height: 400)
        // Equal densities keep every fixed scale at 1, even on small screens.
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
        controller.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification))
        #expect(enabled().isEmpty)
        controller.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification))
        #expect(enabled().count == 4)
        display.displayClass = 1
        #expect(enabled() == [.pointAccurate, .pixelAccurate, .fitScreen])
        display.displayClass = 0
        display.screenScale = 0.39 * backing
        #expect(!enabled().contains(.pixelAccurate))
        display.screenScale = 0.41 * backing
        #expect(enabled().contains(.pixelAccurate))
        // Fixed scales must fit below the header.
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
        let elsewhere = "0D7A6E4C-5F4B-4D0E-9C61-2B8C9D0A1E2F"
        preferences.values[HostPreferences.devicePreferences] = ["test-device": [
            "ChromeTint": "#FFFFFF", "SimulatorWindowGeometry": [elsewhere: ["WindowCenter": "{10, 20}"]],
        ]]
        func open() throws -> (DeviceWindowController, TestDisplay) {
            let display = TestDisplay()
            // Keep the unified title bar after fitting so its measured height remains valid.
            display.naturalSize = NSSize(width: 320, height: 160)
            return (try makeController(display, preferences: preferences), display)
        }
        let (first, display) = try open()
        #expect(display.renderScale == 1)
        display.screenScale = 1.5 * (first.window?.screen?.backingScaleFactor ?? 1)
        first.perform(.pixelAccurate)
        first.showWindow(nil)
        let frame = try #require(first.window?.frame)
        // Closing through the delegate saves geometry for this screen arrangement.
        first.window?.close()
        let device = preferences.preferences(forDevice: "test-device")
        #expect(device?["ChromeTint"] as? String == "#FFFFFF")
        let geometry = device?["SimulatorWindowGeometry"] as? [String: Any]
        #expect((geometry?[elsewhere] as? [String: Any])?["WindowCenter"] as? String == "{10, 20}")
        let saved = preferences.windowGeometry(forDevice: "test-device", screens: screens)
        #expect(saved.scale == 1.5)
        #expect(saved.center == NSPoint(x: frame.midX, y: frame.midY))
        let (second, reopened) = try open()
        #expect(reopened.renderScale == 1.5)
        second.invalidate()
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
        // iPad top padding bypasses AppKit's constraint, so the host must restore the window onscreen.
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
        // Saved geometry applies only to the matching screen arrangement.
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
        #expect(display.renderScale == 1)
        var cascade = NSPoint.zero
        controller.showNewWindow(cascadingFrom: &cascade)
        #expect(cascade != .zero)
        let window = try #require(controller.window)
        let placed = window.frame
        window.center()
        #expect(window.frame == placed)
        let configurations = preferences.values[HostPreferences.screenConfigurations] as? [String: [String]]
        #expect(configurations == [elsewhere: ["{{-9000, 9000}, {640, 480}}"]])
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
        // On reconnect, Simulator.app preserves the top edge while restoring the upright shape.
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
        // Closing during restart must preserve the last connected geometry.
        let restarting = try makeController(TestDisplay(), device: "A", preferences: preferences)
        restarting.showWindow(nil)
        await restarting.prepareForRestart()
        restarting.window?.close()
        let kept = preferences.windowGeometry(forDevice: "A", screens: screens)
        #expect(kept.center == NSPoint(x: 100, y: 200) && kept.scale == 2)
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
        // A host conflict before showing the window must preserve the saved geometry.
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
        // Simulator.app preserves scale on rotation, even beyond the screen width.
        let landscape = NSSize(width: visible.width + 100, height: 200)
        first.guestInterfaceAngle = 90
        first.naturalSize = landscape
        first.onPropertiesChange?()
        #expect(first.renderScale == 1)
        #expect(window.frame.width > visible.width)
        #expect(window.frame.maxY == top.rounded())
        first.bezel = NSSize(width: 40, height: 40)
        controller.setDeviceBezelVisible(false)
        controller.setDeviceBezelVisible(true)
        #expect(first.renderScale == 1)
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
        // AppKit does not constrain a nonresizable window with a bezel.
        display.bezelPadding = NSSize(width: 10, height: 0)
        let controller = try makeController(display)
        defer { controller.invalidate() }
        controller.showWindow(nil)
        let window = try #require(controller.window)
        let visible = try #require(window.screen?.visibleFrame)
        window.setFrameOrigin(NSPoint(x: visible.maxX - window.frame.width - 10, y: visible.minY + 20))
        display.guestInterfaceAngle = 90
        display.naturalSize = NSSize(width: 500, height: 200)
        display.onPropertiesChange?()
        #expect(display.rotations == [90])
        #expect(window.frame.width == 500)
        #expect(visible.contains(window.frame))
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
        func readOrientation(_ controller: DeviceWindowController) async {
            while controller.session.isBusy {
                await withCheckedContinuation { continuation in
                    withObservationTracking { _ = controller.session.isBusy } onChange: { continuation.resume() }
                }
            }
        }
        let visible = try #require(NSScreen.screens.first?.visibleFrame)
        let center = NSPoint(x: visible.midX, y: visible.midY)
        let screens = NSScreen.screens.map(\.frame)
        var cascade = NSPoint.zero
        // Read orientation after showing, then restore the saved center in that shape.
        preferences.setWindowGeometry(center: center, scale: nil, forDevice: "A", screens: screens)
        let (reopened, display) = try open("A")
        defer { reopened.invalidate() }
        reopened.showNewWindow(cascadingFrom: &cascade)
        await readOrientation(reopened)
        #expect(display.rotations == [90])
        let window = try #require(reopened.window)
        #expect(window.contentLayoutRect.width == landscape.width)
        #expect(abs(window.frame.midX - center.x) < 1 && abs(window.frame.midY - center.y) < 1)
        preferences.setWindowGeometry(center: center, scale: nil, forDevice: "B", screens: screens)
        let (moved, _) = try open("B")
        defer { moved.invalidate() }
        moved.showNewWindow(cascadingFrom: &cascade)
        let movedWindow = try #require(moved.window)
        movedWindow.setFrameOrigin(NSPoint(x: movedWindow.frame.minX - 20, y: movedWindow.frame.minY - 20))
        let topLeft = NSPoint(x: movedWindow.frame.minX, y: movedWindow.frame.maxY)
        await readOrientation(moved)
        #expect(movedWindow.contentLayoutRect.width == landscape.width)
        #expect(abs(movedWindow.frame.minX - topLeft.x) < 1 && abs(movedWindow.frame.maxY - topLeft.y) < 1)
        let (centered, _) = try open("C")
        defer { centered.invalidate() }
        var first = NSPoint.zero
        centered.showNewWindow(cascadingFrom: &first)
        await readOrientation(centered)
        let centeredWindow = try #require(centered.window)
        #expect(centeredWindow.contentLayoutRect.width == landscape.width)
        let placed = centeredWindow.frame
        centeredWindow.center()
        #expect(centeredWindow.frame == placed)
        // Evaluate the saved scale against the reported orientation, matching Simulator.app.
        let tall = NSSize(width: 100, height: visible.height * 4)
        preferences.setWindowGeometry(center: center, scale: 0.5, forDevice: "D", screens: screens)
        let tallDisplay = TestDisplay()
        tallDisplay.naturalSize = tall
        tallDisplay.onRotation = { [unowned tallDisplay] in tallDisplay.naturalSize = $0 == 0 ? tall : landscape }
        let rescaled = try makeController(tallDisplay, devicectl: devicectl, device: "D", preferences: preferences)
        defer { rescaled.invalidate() }
        #expect(tallDisplay.renderScale < 0.5)
        rescaled.showNewWindow(cascadingFrom: &cascade)
        await readOrientation(rescaled)
        #expect(tallDisplay.renderScale == 0.5)
        let rescaledWindow = try #require(rescaled.window)
        #expect(rescaledWindow.contentLayoutRect.width == landscape.width * 0.5)
        #expect(abs(rescaledWindow.frame.midX - center.x) < 1 && abs(rescaledWindow.frame.midY - center.y) < 1)
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
        await readOrientation(guestRotated)
        #expect(guestDisplay.renderScale == 0.5)
        let guestWindow = try #require(guestRotated.window)
        #expect(abs(guestWindow.frame.midX - center.x) < 1 && abs(guestWindow.frame.midY - center.y) < 1)
        preferences.setWindowGeometry(center: center, scale: 0.5, forDevice: "F", screens: screens)
        let reshownDisplay = TestDisplay()
        reshownDisplay.naturalSize = tall
        reshownDisplay.onRotation = { [unowned reshownDisplay] in reshownDisplay.naturalSize = $0 == 0 ? tall : landscape }
        let reshown = try makeController(reshownDisplay, devicectl: devicectl, device: "F", preferences: preferences)
        defer { reshown.invalidate() }
        reshown.showNewWindow(cascadingFrom: &cascade)
        reshown.showAndActivate()
        await readOrientation(reshown)
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
        // AppKit requires a resizable window throughout the full-screen transition.
        controller.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification, object: window))
        #expect(window.styleMask.contains(.resizable))
        controller.setDeviceBezelVisible(false)
        controller.setDeviceBezelVisible(true)
        #expect(window.styleMask.contains(.resizable))
        // Leaving full screen restores the saved scale and origin, regardless of AppKit's placement.
        window.setFrame(NSRect(x: windowed.minX + 30, y: windowed.minY + 30,
                               width: windowed.width / 2, height: windowed.height / 2), display: true)
        #expect(display.renderScale < 1)
        controller.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: window))
        #expect(!window.styleMask.contains(.resizable))
        #expect(display.renderScale == 1)
        #expect(window.frame == windowed)
        controller.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification, object: window))
        controller.windowDidFailToEnterFullScreen(window)
        #expect(!window.styleMask.contains(.resizable))
    }

    @Test func leavingFullScreenMovesTheWindowBackInsideItsScreen() throws {
        let display = TestDisplay()
        display.naturalSize = NSSize(width: 200, height: 300)
        // iPad bezel padding bypasses AppKit's window constraint.
        display.bezelPadding = NSSize(width: 10, height: 9)
        let controller = try makeController(display)
        defer { controller.invalidate() }
        controller.showWindow(nil)
        let window = try #require(controller.window)
        let visible = try #require(window.screen?.visibleFrame)
        window.setFrameOrigin(NSPoint(x: visible.maxX + 100, y: visible.minY + 10))
        controller.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification, object: window))
        controller.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: window))
        #expect(visible.contains(window.frame))
    }

    @Test func aScreenChangeMovesTheWindowBackInsideItsScreen() throws {
        let display = TestDisplay()
        display.naturalSize = NSSize(width: 200, height: 300)
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
        display.bezelPadding = NSSize(width: 9, height: 0)
        let controller = try makeController(display)
        defer { controller.invalidate() }
        controller.showWindow(nil)
        let window = try #require(controller.window)
        let visible = try #require(window.screen?.visibleFrame)
        // Simulator.app permits full screen for nonresizable bezel windows.
        #expect(!window.styleMask.contains(.resizable))
        #expect(window.collectionBehavior.contains(.fullScreenPrimary))
        display.naturalSize = NSSize(width: 200, height: visible.height)
        #expect(controller.canSetScale(.pointAccurate))
        controller.perform(.pointAccurate)
        #expect(display.renderScale == 1)
        #expect(display.view.frame.height == visible.height + 20)
        #expect(window.frame.height > visible.height)
        #expect(window.frame.maxY <= visible.maxY + 1)
        controller.setDeviceBezelVisible(false)
        #expect(window.styleMask.contains(.resizable))
        #expect(!controller.canSetScale(.pointAccurate))
        #expect(controller.canSetScale(.fitScreen))
    }

    @Test(arguments: [false, true]) func showDeviceBezelsIsAnAppWidePreference(integrated: Bool) throws {
        _ = NSApplication.shared
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
        let menus = MenuController(application: nil)
        var updates: [Bool] = []
        menus.toggleDeviceBezels = {
            let shows = !HostPreferences.defaults.showsDeviceBezels
            HostPreferences.defaults.set(shows, forKey: HostPreferences.showChrome)
            updates.append(shows)
            controller.setDeviceBezelVisible(shows)
        }
        let windowMenu: NSMenu
        if integrated {
            windowMenu = NSMenu(title: "View")
            menus.addScreenCommands(file: NSMenu(), edit: NSMenu(), view: windowMenu)
        } else {
            menus.install()
            windowMenu = try #require(NSApp.mainMenu?.items.first { $0.title == "Window" }?.submenu)
        }
        defer {
            NSApp.mainMenu = nil
            withExtendedLifetime(menus) {}
        }
        let item = try #require(windowMenu.items.first { $0.title == "Show Device Bezels" })
        let saved = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[HostPreferences.showChrome]
        defer { UserDefaults.standard.set(saved, forKey: HostPreferences.showChrome) }
        for shows in [false, true] {
            UserDefaults.standard.set(shows, forKey: HostPreferences.showChrome)
            #expect(menus.validateMenuItem(item))
            #expect(item.state == (shows ? .on : .off))
            #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
            #expect(updates.last == !shows && HostPreferences.defaults.showsDeviceBezels == !shows)
            #expect((display.chromePadding != nil) == !shows)
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
        #expect(!window.styleMask.contains(.resizable))
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
        // Cover zero-padding artwork, padded iPad artwork, and the bezel-free header gap.
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
        // Simulator.app's toolbar nibs enclose the buttons in flexible spaces.
        #expect(toolbar.items.first?.itemIdentifier == .flexibleSpace)
        #expect(toolbar.items.last?.itemIdentifier == .flexibleSpace)
        // Unified style hides the trailing space and places the buttons after the title.
        controller.perform(.pointAccurate)
        #expect(window.toolbarStyle == .unified)
        #expect(toolbar.items.last?.isHidden == true)
        // The title must truncate before buttons move to the overflow menu.
        window.layoutIfNeeded()
        #expect(toolbar.visibleItems?.compactMap { DeviceCommand.ID(rawValue: $0.itemIdentifier.rawValue) }
            == [.home, .saveScreen, .rotateRight])
        let unified = header()
        #expect(window.frame.height == 300 + unified)
        #expect((0..<1).contains(window.frame.width - threshold))
        display.naturalSize = NSSize(width: threshold - 0.01, height: 300)
        controller.perform(.pointAccurate)
        #expect(window.toolbarStyle == .expanded)
        #expect(toolbar.items.last?.isHidden == false)
        let expanded = header()
        #expect(expanded > unified)
        #expect(window.frame.height == 300 + expanded)
        #expect(display.view.frame.size == NSSize(width: window.frame.width, height: 300))
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
        // Simulator.app preserves the toolbar measurement while the recording button changes.
        controller.setDeviceBezelVisible(false)
        #expect(window.toolbarStyle == .unified)
        #expect(buttons() == [.home, .saveScreen, .rotateRight])
        recording.stop()
        try await recording.waitUntilFinished()
    }

    @Test func titleBarPreferencesChooseTheCompactOrExpandedStyle() throws {
        // Simulator.app defaults to UseMonobar on and UseCompactTitleBar off.
        HostPreferences.registerDefaults()
        let registered = UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain)
        #expect(registered["UseMonobar"] as? Bool == true)
        #expect(registered["UseCompactTitleBar"] as? Bool == false)
        #expect(MemoryPreferences().usesMonobar)
        #expect(!MemoryPreferences().usesCompactTitleBar)
        // Match boolForKey: conversion of values written as strings.
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
                #expect(display.view.frame == NSRect(x: 0, y: 0, width: width, height: 300))
                headers[style] = window.frame.height - 300
            }
        }
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
        controller.perform(.pointAccurate)
        #expect(window.toolbarStyle == .expanded)
        let header = window.frame.height - window.contentLayoutRect.height
        #expect(window.frame.height == 400 + header)
        let fit = try #require(controller.scale(for: .fitScreen))
        #expect(abs(fit - min((visible.width - 20) / 200, (visible.height - header - 20) / 400)) < 0.000_001)
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
        // Simulator.app adjusts window height when resizing switches the title-bar style.
        resize(width: narrow)
        #expect(window.toolbarStyle == .expanded)
        #expect(window.frame.height - header() == below)
        resize(width: wide)
        #expect(window.toolbarStyle == .unified)
        #expect(window.frame.height - header() == below)
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
        // Full screen preserves the bezel color; leaving full screen restores black.
        controller.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification, object: window))
        controller.setDeviceBezelVisible(false)
        #expect(window.backgroundColor == .clear)
        controller.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: window))
        #expect(window.backgroundColor == .black)
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
        #expect(!window.titlebarAppearsTransparent)
        // Simulator.app rounds NSTitlebarContainerView using the window's private _cornerRadius.
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
        controller.setDeviceBezelVisible(false)
        #expect(layer.cornerRadius == 0)
        controller.setDeviceBezelVisible(true)
        #expect(layer.cornerRadius == (try windowRadius()))
        controller.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification, object: window))
        #expect(layer.cornerRadius == 0)
        controller.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: window))
        #expect(layer.cornerRadius == (try windowRadius()))
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
        let preferences = MemoryPreferences()
        preferences.setWindowGeometry(center: NSPoint(x: 300, y: 300), scale: 1.37, forDevice: "test-device",
                                      screens: NSScreen.screens.map(\.frame))
        var display = makeDisplay()
        let controller = try makeController(display, devicectl: devicectl, preferences: preferences)
        defer { controller.invalidate() }
        let window = try #require(controller.window)
        // Simulator.app encloses the display and header gap in an integral frame.
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
            let outward = NSSize(width: corner.isLeft ? -30 : 30, height: corner.isLower ? -55 : 55)
            try drag(window, from: try point(of: corner, in: display), by: outward) {
                #expect(display.isResizing)
                #expect(display.renderScale == 1.25)
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
            #expect(display.renderScale == 0.4)
        }
        try drag(window, from: try point(of: .lowerRight, in: display), by: NSSize(width: 10_000, height: -10_000)) {
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
        // Simulator.app keeps at least 128 points of the window within the visible screen.
        #expect(abs(window.frame.minX - reach.maxX) < 0.001 && abs(window.frame.maxY - reach.minY) < 0.001)
    }

    @Test func theBezelShowsResizeCursorsOutsideFullScreen() throws {
        let (controller, display) = try makeBezelController()
        defer { controller.invalidate() }
        let window = try #require(controller.window)
        #expect(display.showsResizeCursors)
        controller.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification, object: window))
        #expect(!display.showsResizeCursors)
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
        try drag(window, from: try point(of: .lowerLeft, in: display), by: NSSize(width: -30, height: -55)) {
            #expect(display.isResizing)
        }
        // No view consumes the header gap, so its presses reach window dragging.
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
        // Simulator.app reads this preference for each press.
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
        // Simulate a portrait-only guest.
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
        let log = directory.appendingPathComponent("calls"), fail = directory.appendingPathComponent("fail")
        let simctl = directory.appendingPathComponent("simctl")
        try """
            #!/bin/sh
            echo "$1" >> "\(log.path)"
            case " $(cat "\(fail.path)" 2>/dev/null) " in
              *" $1 "*) echo "$1 failed" >&2; exit 1 ;;
            esac
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
        let erase = await run(erasing: true, failing: "erase")
        #expect(erase.calls == ["shutdown", "erase", "boot"])
        #expect(erase.error?.contains("while erasing") == true)
        #expect(erase.error?.hasSuffix("The device was shut down and booted again.") == true)
        let boot = await run(erasing: false, failing: "boot")
        #expect(boot.calls == ["shutdown", "boot"])
        #expect(boot.error?.hasPrefix("Restart failed while booting") == true)
        #expect(boot.error?.hasSuffix("The device was shut down.") == true)
        let eraseAndBoot = await run(erasing: true, failing: "erase boot")
        #expect(eraseAndBoot.calls == ["shutdown", "erase", "boot"])
        #expect(eraseAndBoot.error?.contains("erase failed") == true)
        #expect(eraseAndBoot.error?.contains("boot failed") == true)
        #expect(eraseAndBoot.error?.hasSuffix("The device was shut down.") == true)
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
        // A reconnected display must reapply the saved bezel preference.
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
        try controller.session.startRecording(to: .file(directory.appendingPathComponent("Recording.mov")), mask: .ignored)
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
        // Open Simulator populates on opening, so its empty submenu must remain visible.
        #expect(try visibleTitles("File").prefix(3) == ["New Simulator…", "Open Simulator", "-"])
        #expect(try visibleTitles("Device") == ["Restart", "Erase All Content and Settings…", "Shut Down", "-",
                                                 "Home", "Re-Center Open Apps", "Lock", "Action Button", "Siri",
                                                 "Shake", "App Switcher", "-", "Trigger Screenshot"])
        #expect(try visibleTitles("I/O") == ["Keyboard", "-", "Audio Input", "Audio Output", "Increase Volume",
                                              "Decrease Volume", "-", "Open URL…"])
        #expect(try visibleTitles("Features") == ["Authorize Apple Pay", "-", "Toggle Appearance",
                                                   "Toggle In-call Status Bar", "-", "Increase Preferred Text Size",
                                                   "Decrease Preferred Text Size", "Toggle Increase Contrast", "-",
                                                   "Trigger iCloud Sync", "-", "Location"])
        // Slow Animations falls back to the frontmost app when the device lacks the feature.
        #expect(try visibleTitles("Debug") == ["Toggle Slow Animations in Frontmost App", "-", "Color Blended Layers",
                                                "Color Copied Images", "Color Misaligned Images",
                                                "Color Off-screen Rendered", "-", "Open System Log…",
                                                "Simulate Memory Warning", "-", "Show Parallel Testing Devices"])
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
        #expect(try shortcuts("Optic ID") == ["", "", ""])
        // Face ID appears first and takes the shortcuts shared with Optic ID.
        menus.updateKeyEquivalents(for: device(DeviceCapabilities.faceID))
        #expect(try shortcuts("Touch ID") == ["", "", ""] && shortcuts("Face ID") == ["", "m", "n"])
        #expect(try shortcuts("Optic ID") == ["", "m", "n"])
        menus.updateVisibility(in: features, for: device(DeviceCapabilities.faceID))
        #expect(features.items.filter { !$0.isHidden }.prefix(2).map { $0.isSeparatorItem ? "-" : $0.title }
                == ["Face ID", "-"])
        menus.updateKeyEquivalents(for: device(DeviceCapabilities.touchID))
        #expect(try shortcuts("Touch ID") == ["", "m", "n"] && shortcuts("Face ID") == ["", "", ""])
        #expect(try shortcuts("Optic ID") == ["", "", ""])
        // Simulator.app assigns Shift-Command-I to Trigger iCloud Sync.
        let items = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items) ?? []
        #expect(items.filter { $0.keyEquivalent == "i" && $0.keyEquivalentModifierMask == [.command, .shift] }
            .map(\.title) == ["Trigger iCloud Sync"])
    }

    @Test func opticIDPostsSimulatorAppsGuestNotifications() throws {
        let display = TestDisplay()
        let controller = try makeController(display, family: .vision, features: [DeviceCapabilities.opticID])
        defer { controller.invalidate() }
        let enrolled = NSMenuItem()
        controller.perform(.opticIDEnrolled)
        #expect(DeviceCommand.command(.opticIDEnrolled).validate(enrolled, for: controller) && enrolled.state == .on)
        controller.perform(.opticIDMatching)
        controller.perform(.opticIDNonMatching)
        controller.perform(.faceIDMatching)
        controller.perform(.opticIDEnrolled)
        #expect(DeviceCommand.command(.opticIDEnrolled).validate(enrolled, for: controller) && enrolled.state == .off)
        #expect(display.postedNotifications == [
            "com.apple.BiometricKit.enrollmentChanged", "com.apple.BiometricKit_Sim.oyster.match",
            "com.apple.BiometricKit_Sim.oyster.nomatch", "com.apple.BiometricKit.enrollmentChanged",
        ])
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
        display.contrastMode = 0
        #expect(throws: (any Error).self) { try session.toggleIncreaseContrast() }
        #expect(display.contrastMode == 0)
    }

    @Test func simulateFallSetsAndPostsTheGuestsFallState() throws {
        let display = TestDisplay()
        let controller = try makeController(display, family: .watch, features: [DeviceCapabilities.fallDetection])
        defer { controller.invalidate() }
        let name = "com.apple.sos.user-fell"
        for (command, state) in [(DeviceCommand.ID.fallUnresponsive, 3), (.fallRejected, 2), (.fallDismissed, 1),
                                 (.fallConfirmed, 0)] as [(DeviceCommand.ID, UInt64)] {
            controller.perform(command)
            #expect(display.notificationStates[name] == state, "\(command)")
        }
        #expect(display.postedNotifications == Array(repeating: name, count: 4))
        display.notificationError = HostError.operation("refused")
        #expect(throws: (any Error).self) { try controller.session.simulateFall(.dismissed) }
        #expect(display.postedNotifications.count == 4)
        let other = TestDisplay()
        let otherController = try makeController(other, family: .watch, features: [], device: "other")
        defer { otherController.invalidate() }
        otherController.perform(.fallConfirmed)
        #expect(other.notificationStates.isEmpty && other.postedNotifications.isEmpty)
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

        display.notificationError = HostError.operation("refused")
        #expect(throws: (any Error).self) { try controller.session.toggleSlowAnimations() }
        #expect(slow.state?(controller) == .on)

        let connected = TestDisplay()
        try makeSession(connected, features: features).applyDebugSettings()
        #expect(connected.notificationStates == [slowMotion: 1, quality: 10])
        UserDefaults.standard.set(GraphicsQuality.deviceDefault.rawValue, forKey: HostPreferences.graphicsQualityOverride)
        let older = TestDisplay()
        try makeSession(older, features: [DeviceCapabilities.graphicsQualityOverride]).applyDebugSettings()
        #expect(older.postedNotifications.isEmpty)

        // Simulator.app toggles slow animation in the frontmost app when the guest lacks support.
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
            // Device-tool work delays only the Apple TV restart, matching Simulator.app.
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
        // Read the guest's state because another host may change it.
        display.caDebugOptions.remove(.colorBlendedLayers)
        #expect(blended.state?(controller) == .off)
        // CoreSimulator can silently drop writes; read back to detect that.
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
        // CoreSimulator truncates this file in place.
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

    @Test(arguments: [false, true]) func gpuSelectionRewritesCoreSimulatorsPolicyAsSimulatorAppDoes(integrated: Bool) throws {
        _ = NSApplication.shared
        let defaults = try #require(MemoryDefaults(suiteName: nil))
        let menus = MenuController(application: nil, gpuPolicy: GPUPolicy(defaults: defaults))
        let file: NSMenu
        if integrated {
            file = NSMenu(title: "File")
            menus.addScreenCommands(file: file, edit: NSMenu(), view: NSMenu())
        } else {
            menus.install()
            file = try #require(NSApp.mainMenu?.items.first { $0.title == "File" }?.submenu)
        }
        defer { NSApp.mainMenu = nil }
        let titles = file.items.map { $0.isSeparatorItem ? "-" : $0.title }
        let index = try #require(titles.firstIndex(of: "GPU Selection"))
        if !integrated {
            #expect(titles[(index - 2)...(index + 2)] == ["Stop Recording", "-", "GPU Selection", "-", "Install App or Import Media…"])
        }
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
        // Simulator.app's default priority starts with automatic.
        #expect(checked() == ["Automatic"])
        #expect(try choose("Prefer Integrated GPU") == ["lowPower", "discrete", "external"])
        #expect(try choose("Use External GPU When Available") == ["external", "lowPower", "discrete"])
        #expect(checked() == ["Prefer Integrated GPU", "Use External GPU When Available"])
        #expect(try choose("Prefer Discrete GPU") == ["external", "discrete", "lowPower"])
        #expect(try choose("Automatic") == ["external", "automatic"])
        #expect(try choose("Use External GPU When Available") == ["automatic", "external"])
        #expect(checked() == ["Automatic"])
        // A legacy string is a one-item order; omit unsupported kinds.
        defaults.set("headless", forKey: GPUPolicy.key)
        #expect(checked().isEmpty)
        #expect(try choose("Prefer Discrete GPU") == ["discrete", "lowPower", "external"])
        let unavailable = MenuController(application: nil)
        #expect(!items.contains { unavailable.validateMenuItem($0) })
    }

    @Test func connectingRestoresTheSavedLocationOnDevicesWithScenarios() async throws {
        let restoreDefaults = removeLocationPreferences()
        defer { restoreDefaults() }
        HostPreferences.registerDefaults()
        let defaults = UserDefaults.standard
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
        #expect(try await restore() == (.custom, [.coordinate(37.785834, -122.406417)]))
        defaults.set(LocationSelection.scenarioMode, forKey: HostPreferences.locationMode)
        defaults.set("Freeway Drive", forKey: HostPreferences.locationScenario)
        #expect(try await restore() == (.scenario("Freeway Drive"), [.scenario("Freeway Drive")]))
        defaults.set("Apple", forKey: HostPreferences.locationScenario)
        #expect(try await restore() == (LocationSelection.none, [.cleared]))
        #expect(defaults.integer(forKey: HostPreferences.locationMode) == LocationSelection.noneMode)
        #expect(defaults.string(forKey: HostPreferences.locationScenario) == "Apple")
        defaults.set(5000, forKey: HostPreferences.locationMode)
        #expect(try await restore() == (LocationSelection.none, [.cleared]))
    }

    @Test func connectingKeepsTheSelectedDevicesLocationInsteadOfTheAppWideDefault() async throws {
        let restoreDefaults = removeLocationPreferences()
        defer { restoreDefaults() }
        HostPreferences.registerDefaults()
        let identifier = UUID().uuidString
        let key = "DeviceLocationPreset.\(identifier)"
        let defaults = try #require(UserDefaults(suiteName: "dev.lynnswap.NeoSimulator"))
        defer { defaults.removeObject(forKey: key); defaults.synchronize() }
        defaults.set(["mode": "custom", "latitude": 12.5, "longitude": 34.5], forKey: key)
        #expect(defaults.synchronize())
        func connect() async throws -> TestDisplay {
            let display = TestDisplay()
            display.scenarios = Self.scenarios
            let session = try makeSession(display, device: identifier)
            try await session.restoreLocation()
            return display
        }
        #expect(try await connect().appliedLocations == [.coordinate(12.5, 34.5)])
        let display = TestDisplay()
        display.scenarios = Self.scenarios
        let session = try makeSession(display, device: identifier)
        try await session.setCustomLocation(latitude: 45.5, longitude: 67.5)
        #expect(try await connect().appliedLocations == [.coordinate(45.5, 67.5)])
        defaults.set(["mode": "none"], forKey: key)
        #expect(defaults.synchronize())
        try session.refreshLocationSelection()
        #expect(session.location == LocationSelection.none)
        #expect(display.appliedLocations == [.coordinate(45.5, 67.5)])
        #expect(try await connect().appliedLocations == [.cleared])
        defaults.set(["mode": "custom", "latitude": 12.5, "longitude": 34.5], forKey: key)
        #expect(defaults.synchronize())
        try session.refreshLocationSelection()
        #expect(session.location == .custom)
        #expect(display.appliedLocations == [.coordinate(45.5, 67.5)])
    }

    @Test func aRestoreWaitingForScenariosKeepsLaterChoicesAndEndedSessions() async throws {
        let restoreDefaults = removeLocationPreferences()
        defer { restoreDefaults() }
        HostPreferences.registerDefaults()
        // Scenario discovery can finish after a user changes the location.
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
        // Simulator.app saves the choice before applying it, so choosing it again retries.
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

    private func makeAudioController(_ port: TestAudioRoutes?, device: String = "test-device",
                                     features: Set<String> = routableFeatures,
                                     preferences: MemoryPreferences) throws -> (DeviceWindowController, TestDisplay) {
        let display = TestDisplay()
        display.audioPort = port
        return (try makeController(display, features: features, device: device, preferences: preferences), display)
    }

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
        // Matches Simulator.app's placement between Touch Pressure and volume commands.
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
        #expect(items(output) == ["System"])
        controller.session.connectAudioRoutes { Issue.record($0) }
        // System uses the Mac's default; device ordering comes from the port.
        #expect(items(input) == ["System (MacBook Pro Microphone) ✓", "MacBook Pro Microphone", "BlackHole 2ch", "USB Headset"])
        #expect(items(output) == ["System (MacBook Pro Speakers) ✓", "BlackHole 2ch", "MacBook Pro Speakers", "USB Headset"])
        preferences.set(["Headset"], forKey: HostPreferences.recentAudioOutputDeviceUIDs)
        port.report { $0.outputRoute = "Headset" }
        #expect(items(output) == ["System (MacBook Pro Speakers)", "BlackHole 2ch", "MacBook Pro Speakers", "USB Headset ✓"])
        port.report(.availableDevices) { $0.defaultOutput = "Elsewhere" }
        #expect(items(output).first == "System")
        // SimulatorKit substitutes the Mac's default when the guest's route is missing.
        #expect(port.current.outputRoute == "Headset")
        var state = port.current
        state.outputRoute = "Gone"
        #expect(state.selectedDevice(in: .output) == Self.speakers)
        #expect(state.selectedDevice(in: .input) == Self.microphone)

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
        #expect(preferences.recentAudioRoutes(in: .output) == [AudioRouting.systemDefault])
        #expect(ports.allSatisfy { $0.requests.isEmpty })
        #expect(silentDisplay.audioConnections == 0)
        for identifier in ["A", "B"] {
            try preferences.saveAudioRoute("Speakers", forDevice: identifier, in: .output)
        }

        a.selectAudioRoute("Loopback", in: .output)
        #expect(preferences.values[HostPreferences.recentAudioOutputDeviceUIDs] as? [String]
            == ["Loopback", AudioRouting.systemDefault])
        #expect(ports.map(\.requests) == [["output Loopback"], ["output Loopback"]])
        #expect(ports.allSatisfy { $0.current.outputRoute == "Loopback" && $0.current.inputRoute == AudioRouting.systemDefault })
        for identifier in ["A", "B"] {
            #expect(try preferences.preferredAudioRoutes(forDevice: identifier, in: .output).first == "Loopback")
        }
        #expect(preferences.recentAudioRoutes(in: .input) == [AudioRouting.systemDefault])

        b.selectAudioRoute("Gone", in: .output)
        #expect(ports.map(\.requests) == [["output Loopback"], ["output Loopback"]])
        b.selectAudioRoute(AudioRouting.systemDefault, in: .output)
        #expect(ports.map(\.requests.last) == ["output \(AudioRouting.systemDefault)", "output \(AudioRouting.systemDefault)"])
        for identifier in ["A", "B"] {
            #expect(try preferences.preferredAudioRoutes(forDevice: identifier, in: .output).first == AudioRouting.systemDefault)
        }
        for route in ["Loopback", "One", "Two", "Three", "Gone"] { a.selectAudioRoute(route, in: .input) }
        #expect(preferences.recentAudioRoutes(in: .input) == ["Gone", "Three", "Two", "One", "Loopback"])
        #expect(preferences.recentAudioRoutes(in: .output) == [AudioRouting.systemDefault, "Gone", "Loopback"])
        // Simulator.app falls back to System for empty or foreign lists.
        for stored in [[] as [Any], [1, 2] as [Any], "Loopback" as Any] {
            preferences.set(stored, forKey: HostPreferences.recentAudioInputDeviceUIDs)
            #expect(preferences.recentAudioRoutes(in: .input) == [AudioRouting.systemDefault])
        }
    }

    @Test func connectingAndPortChangesRouteToTheMostRecentRouteTheMacHas() throws {
        let preferences = MemoryPreferences()
        preferences.set(["Headset", "Loopback", AudioRouting.systemDefault], forKey: HostPreferences.recentAudioOutputDeviceUIDs)
        let port = TestAudioRoutes([Self.microphone, Self.loopback, Self.speakers])
        let (controller, _) = try makeAudioController(port, preferences: preferences)
        defer { controller.invalidate() }
        controller.session.connectAudioRoutes { Issue.record($0) }
        #expect(port.requests == ["output Loopback"])
        port.report(.availableDevices) { $0.devices.append(Self.headset) }
        #expect(port.requests.last == "output Headset")
        port.report(.availableDevices) { $0.devices.removeAll { $0 == Self.headset } }
        #expect(port.requests.last == "output Loopback")
        port.report { $0.outputRoute = "Speakers" }
        #expect(port.requests.last == "output Loopback" && port.requests.count == 3)
        #expect(port.current.outputRoute == "Speakers")
        #expect(controller.session.audioRoutes?.outputRoute == "Speakers")
        port.report(.availableDevices) { $0.defaultOutput = "Loopback" }
        #expect(port.requests.count == 4)
        // Without a usable recent route or system default, leave the guest's route unchanged.
        preferences.set([AudioRouting.systemDefault], forKey: HostPreferences.recentAudioOutputDeviceUIDs)
        port.report(.availableDevices) { $0.devices = [Self.microphone, Self.loopback] }
        #expect(port.requests.count == 4)
        port.report(.availableDevices) { $0.devices.append(Self.speakers) }
        #expect(port.requests.last == "output \(AudioRouting.systemDefault)")

        controller.invalidate()
        #expect(port.isDisconnected)
        let count = port.requests.count
        port.report { $0.outputRoute = "Speakers" }
        #expect(port.requests.count == count)
    }

    @Test func reconnectingAudioPreservesTheDeviceChoiceInsteadOfTheGlobalRecentRoute() throws {
        let preferences = MemoryPreferences()
        preferences.set(["Headset", AudioRouting.systemDefault], forKey: HostPreferences.recentAudioOutputDeviceUIDs)
        try preferences.saveAudioRoute("Loopback", forDevice: "A", in: .output)
        for _ in 0..<2 {
            let port = TestAudioRoutes([Self.microphone, Self.loopback, Self.speakers, Self.headset])
            let (controller, _) = try makeAudioController(port, device: "A", preferences: preferences)
            controller.session.connectAudioRoutes { Issue.record($0) }
            #expect(port.current.outputRoute == "Loopback")
            port.report { $0.outputRoute = "Speakers" }
            #expect(port.requests == ["output Loopback"])
            #expect(controller.session.audioRoutes?.outputRoute == "Speakers")
            port.report(.availableDevices) { $0.devices.removeAll { $0 == Self.headset } }
            #expect(port.requests == ["output Loopback", "output Loopback"])
            controller.invalidate()
        }
    }

    @Test func audioRouteFailuresOfAChoiceArePresentedAndOthersLogged() throws {
        let preferences = MemoryPreferences()
        let port = TestAudioRoutes([Self.microphone, Self.loopback, Self.speakers])
        let (controller, _) = try makeAudioController(port, preferences: preferences)
        defer { controller.invalidate() }
        controller.showWindow(nil)
        let window = try #require(controller.window)
        // Unrequested device changes report errors through the session handler.
        preferences.set(["Loopback"], forKey: HostPreferences.recentAudioOutputDeviceUIDs)
        port.routeError = HostError.operation("port failed")
        var automatic: [String] = []
        controller.session.connectAudioRoutes { automatic.append($0.localizedDescription) }
        #expect(automatic == ["Could not route the audio output of Test iPhone to BlackHole 2ch: port failed"])
        #expect(window.attachedSheet == nil)
        controller.selectAudioRoute("Speakers", in: .output)
        #expect(port.requests == ["output Loopback", "output Speakers"])
        let sheet = try #require(window.attachedSheet)
        window.endSheet(sheet)
        port.routeError = nil
        port.refusal = HostError.operation("refused")
        controller.selectAudioRoute("Loopback", in: .output)
        window.endSheet(try #require(window.attachedSheet))

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

    /// Connects the external display after the screen adapter reports it.
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
        if let screen { display.connectExternalScreen(screen) }
        let controller = try makeController(display, family: family, features: features, device: device,
                                            preferences: preferences, externalDisplayChanges: externalDisplayChanges,
                                            runtimeVersion: runtimeVersion, enhancedMultitasking: enhancedMultitasking)
        controller.session.connectExternalDisplay(failure: failure)
        display.deliverScreenReports()
        return (controller, display)
    }

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
        // Matches Simulator.app's placement after the volume commands.
        #expect(titles(io).suffix(7) == ["Decrease Volume", "-", "External Displays", "-", "Set Immersion To", "-",
                                         "Open URL…"])
        let item = try #require(io.items.first { $0.title == "External Displays" })
        #expect(titles(try #require(item.submenu)) == [
            "Disabled", "-", "640×480", "720×480", "1024×768", "1280×720 (720p)", "1920×1080 (1080p)", "3840×2160 (4K)",
            "-", "CarPlay",
        ])
        #expect(item.submenu?.items.allSatisfy { $0.keyEquivalent.isEmpty } == true)
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
        preferences.setExternalDisplayTag(ExternalDisplayMode.size1920x1080.rawValue, forDevice: "test-device")
        #expect(externalDisplayItems(for: controller) == [
            "Disabled ✓", "640×480", "720×480", "1024×768", "1280×720 (720p)", "1920×1080 (1080p)", "3840×2160 (4K)",
            "CarPlay (disabled)",
        ])
        screen.report { $0 = ExternalScreenState(isPoweredOn: true, pixelSize: CGSize(width: 1280, height: 720), scale: 1) }
        #expect(externalDisplayItems(for: controller).filter { $0.hasSuffix("✓") } == ["1280×720 (720p) ✓"])
        screen.report { $0.pixelSize = CGSize(width: 1600, height: 900) }
        #expect(!externalDisplayItems(for: controller).contains { $0.hasSuffix("✓") })
        screen.report { $0 = ExternalScreenState(isPoweredOn: true, pixelSize: CGSize(width: 1280, height: 720), scale: 2) }
        #expect(!externalDisplayItems(for: controller).contains { $0.hasSuffix("✓") })
        // Simulator.app leaves these items enabled during restart, with no state checked.
        display.isBooted = false
        controller.session.disconnect()
        #expect(externalDisplayItems(for: controller) == [
            "Disabled", "640×480", "720×480", "1024×768", "1280×720 (720p)", "1920×1080 (1080p)", "3840×2160 (4K)",
            "CarPlay (disabled)",
        ])
        #expect(externalDisplayItems(for: nil).allSatisfy { $0.hasSuffix("(disabled)") && !$0.contains("✓") })
    }

    private func externalDisplaySubtitles(for controller: DeviceWindowController) -> [String] {
        ExternalDisplayMode.allCases.compactMap { mode in
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            let enabled = DeviceCommand.command(mode.commandID).validate(item, for: controller)
            return item.subtitle.map { "\(item.title)\(enabled ? "" : " (disabled)"): \($0)" }
        }
    }

    @Test func externalDisplayItemsSayWhichSizesTheDeviceCannotShow() throws {
        _ = NSApplication.shared
        // An iPad advertises 720×480 at 60 Hz and the menu's sizes at 120 Hz.
        let screen = TestExternalScreen()
        screen.modes = [.exact720x480, .allowedAt120Hertz(scale: 2), .allowedAt120Hertz(scale: 1)]
        let (controller, display) = try makeExternalDisplayController(screen, features: Self.externalDisplayFeatures
            .union([DeviceCapabilities.carPlay]))
        defer { controller.invalidate() }
        // This guest falls back to 720×480; no mode supports CarPlay's 800×480 at scale 2.
        #expect(externalDisplaySubtitles(for: controller) == [
            "640×480 (disabled): This device shows 720×480", "CarPlay (disabled): Not available on this device",
        ])
        // Before modes arrive, availability is unknown.
        display.isBooted = false
        controller.session.disconnect()
        #expect(externalDisplaySubtitles(for: controller).isEmpty)

        // Before iPadOS 27, Stage Manager cannot keep a 4K external display on.
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

    @Test func theExternalDisplaysWindowSaysWhenTheGuestDoesNotShowItsSize() throws {
        _ = NSApplication.shared
        let screen = TestExternalScreen()
        screen.modes = [.exact720x480, .allowedAt120Hertz(scale: 1)]
        let (controller, _) = try makeExternalDisplayController(screen)
        defer { controller.invalidate() }
        screen.report {
            $0 = ExternalScreenState(isPoweredOn: true, pixelSize: CGSize(width: 1920, height: 1080), scale: 1,
                                     refreshRate: 120)
        }
        let window = try #require(controller.externalDisplayWindow?.window)
        #expect(window.subtitle == "External Display – Size Not Shown by Device")
        screen.report { $0.refreshRate = 60 }
        #expect(window.subtitle == "External Display")
        screen.report { $0.pixelSize = CGSize(width: 640, height: 480) }
        #expect(window.subtitle == "External Display – Size Not Shown by Device")
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
        #expect(preferences.externalDisplayTag(forDevice: "test-device") == 2614)
        #expect(!preferences.connectsHardwareKeyboard(forDevice: "test-device"))
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
        // Disabled also sends power-off to an already-off display; Simulator.app requires an open window.
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
        // Like Simulator.app's screen monitor, follow changes made by other tools.
        screen.report { $0 = ExternalScreenState(isPoweredOn: true, pixelSize: CGSize(width: 720, height: 480), scale: 1) }
        let external = try #require(controller.externalDisplayWindow)
        let window = try #require(external.window)
        let display = try #require(screen.displays.last)
        #expect(screen.displays.count == 1 && external.display === display)
        #expect(window.isVisible)
        #expect(window.title == "Test iPhone" && window.subtitle == "External Display")
        #expect(window.toolbar == nil)
        #expect(window.styleMask == [.titled, .closable, .miniaturizable, .resizable])
        #expect(window.backgroundColor == .black)
        #expect(display.supportsTouchPressure == [false])
        // Match Simulator.app's bezel-free window, with no gap below the title bar.
        func content() -> NSSize { window.contentRect(forFrameRect: window.frame).size }
        let scale = display.renderScale
        #expect(scale > 0 && scale <= 1)
        #expect(abs(content().width - 720 * scale) <= 1 && abs(content().height - 480 * scale) <= 1)
        #expect(window.contentAspectRatio == NSSize(width: 720, height: 480))
        controller.perform(.externalDisplay640x480)
        #expect(controller.externalDisplayWindow === external && display.renderScale == scale)
        #expect(abs(content().width - 640 * scale) <= 1 && abs(content().height - 480 * scale) <= 1)
        #expect(window.contentAspectRatio == NSSize(width: 640, height: 480))
        screen.report { $0.isPoweredOn = false }
        #expect(controller.externalDisplayWindow == nil && !window.isVisible)
        #expect(display.disconnectCount == 1)
        #expect(preferences.externalDisplayTag(forDevice: "test-device") == 2214)
        controller.perform(.externalDisplay720x480)
        #expect(controller.externalDisplayWindow != nil && screen.displays.count == 2)
    }

    @Test func externalDisplayGeometryKeepsSameUDIDDeviceSetsSeparate() throws {
        _ = NSApplication.shared
        let preferences = MemoryPreferences()
        let screens = NSScreen.screens.map(\.frame)
        let normal = SimulatorDeviceIdentifier("same")
        let clone = SimulatorDeviceIdentifier("same", deviceSetPath: "/fixture/XCTestDevices")
        preferences.setWindowGeometry(center: NSPoint(x: 10, y: 20), scale: 0.25,
            forDevice: normal.preferenceIdentifier, screens: screens, kind: .externalDisplay)
        preferences.setWindowGeometry(center: NSPoint(x: 30, y: 40), scale: 0.5,
            forDevice: clone.preferenceIdentifier, screens: screens, kind: .externalDisplay)
        let display = TestDisplay()
        let session = try makeSession(TestDisplay(), device: "same", deviceSetPath: clone.deviceSetPath, preferences: preferences)
        defer { session.disconnect() }
        let external = try ExternalDisplayWindowController(session: session, display: display,
            state: ExternalScreenState(isPoweredOn: true, pixelSize: CGSize(width: 32, height: 32), scale: 1),
            deviceWindow: nil, preferences: preferences, onClose: {})
        #expect(display.renderScale == 0.5)
        external.window?.setFrameOrigin(NSPoint(x: 100, y: 200))
        external.invalidate()
        let original = preferences.windowGeometry(forDevice: normal.preferenceIdentifier, screens: screens, kind: .externalDisplay)
        let saved = preferences.windowGeometry(forDevice: clone.preferenceIdentifier, screens: screens, kind: .externalDisplay)
        #expect(original.center == NSPoint(x: 10, y: 20) && original.scale == 0.25)
        #expect(saved.center != NSPoint(x: 30, y: 40) && saved.scale == 0.5)
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
        let saved = preferences.windowGeometry(forDevice: "test-device", screens: NSScreen.screens.map(\.frame),
                                               kind: .externalDisplay)
        #expect(saved.center != nil && saved.scale != nil)
        #expect(preferences.windowGeometry(forDevice: "test-device", screens: NSScreen.screens.map(\.frame)).center == nil)
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
        // Shutdown abandons an in-flight mode change whose completion never arrives.
        shutDown.perform(.externalDisplay1920x1080)
        display.isBooted = false
        shutDown.invalidate()
        #expect(!changes.isBusy)
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
        // Simulator.app's default Disabled preference leaves an existing external display on.
        preferences.setExternalDisplayTag(ExternalDisplayMode.disabled.rawValue, forDevice: "test-device")
        let on = TestExternalScreen()
        on.current = ExternalScreenState(isPoweredOn: true, pixelSize: CGSize(width: 1920, height: 1080), scale: 1)
        let (second, _) = try makeExternalDisplayController(on, preferences: preferences)
        #expect(on.requests.isEmpty && second.externalDisplayWindow != nil)
        second.invalidate()
        preferences.setExternalDisplayTag(2714, forDevice: "test-device")
        let carPlay = TestExternalScreen()
        let (third, _) = try makeExternalDisplayController(carPlay, preferences: preferences)
        defer { third.invalidate() }
        #expect(carPlay.requests.isEmpty)
        #expect(preferences.externalDisplayTag(forDevice: "test-device") == 2714)
        let display = TestDisplay()
        display.connectExternalScreen(TestExternalScreen())
        let plain = try makeController(display)
        defer { plain.invalidate() }
        plain.session.connectExternalDisplay { Issue.record($0) }
        #expect(display.externalScreenRegistrations == 0)
    }

    @Test func aRestartClosesTheExternalDisplayAndItsReconnectionRestoresIt() async throws {
        let preferences = MemoryPreferences()
        let screen = TestExternalScreen()
        let (controller, _) = try makeExternalDisplayController(screen, preferences: preferences)
        defer { controller.invalidate() }
        controller.perform(.externalDisplay1024x768)
        let first = try #require(controller.externalDisplayWindow)
        await controller.prepareForRestart()
        // Simulator.app disconnects and powers off the display while the device is still booted.
        #expect(controller.externalDisplayWindow == nil && first.window?.isVisible == false)
        #expect(screen.requests == ["mode 1024x768@1", "off"])
        controller.perform(.externalDisplay1920x1080)
        #expect(screen.requests.count == 2)
        let display = TestDisplay()
        let rebooted = TestExternalScreen()
        display.connectExternalScreen(rebooted)
        let session = try makeSession(display, features: Self.externalDisplayFeatures, preferences: preferences)
        controller.reconnect(session)
        session.connectExternalDisplay { Issue.record($0) }
        display.deliverScreenReports()
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
        let (portless, _) = try makeExternalDisplayController(nil, preferences: preferences)
        defer { portless.invalidate() }
        choose(.size1920x1080, on: portless)
        #expect(failures.isEmpty)
        try await wait { !failures.isEmpty }
        #expect(preferences.externalDisplayTag(forDevice: "test-device") == 2614)
        #expect(failures == [
            "Could not set the external display of Test iPhone to 1920×1080 (1080p): The device has no external display port.",
        ])
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

    @Test func aChoiceAfterAFailedConnectionToTheExternalDisplayConnectsAgain() throws {
        var failures: [String] = []
        let (controller, display) = try makeExternalDisplayController(nil) { failures.append($0.localizedDescription) }
        defer { controller.invalidate() }
        func choose(_ mode: ExternalDisplayMode) {
            controller.session.chooseExternalDisplay(mode) { failures.append($0.localizedDescription) }
        }
        choose(.size1024x768)
        display.externalScreenError = HostError.operation("no proxy")
        let screen = TestExternalScreen()
        display.connectExternalScreen(screen)
        display.deliverScreenReports()
        let reason = "Could not connect to the external display of Test iPhone: no proxy"
        #expect(failures == [reason] && !display.isRegisteredForExternalScreen)
        choose(.size1024x768)
        #expect(failures.count == 1)
        display.deliverScreenReports()
        #expect(failures == [reason, reason])
        display.externalScreenError = nil
        choose(.size1280x720)
        #expect(screen.requests.isEmpty)
        display.deliverScreenReports()
        #expect(screen.requests == ["mode 1280x720@1"] && controller.externalDisplayWindow != nil)
        #expect(failures.count == 2 && display.externalScreenRegistrations == 3)
        #expect(!display.isRegisteredForExternalScreen)
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

    @Test func anExternalDisplayReportedAfterTheDeviceConnectsIsRestoredAndFollowed() throws {
        let preferences = MemoryPreferences()
        preferences.setExternalDisplayTag(ExternalDisplayMode.size1280x720.rawValue, forDevice: "test-device")
        var failures: [String] = []
        let (controller, display) = try makeExternalDisplayController(nil, preferences: preferences) {
            failures.append($0.localizedDescription)
        }
        defer { controller.invalidate() }
        #expect(controller.session.externalDisplayMode == nil)
        let screen = TestExternalScreen()
        display.connectExternalScreen(screen)
        #expect(screen.requests.isEmpty)
        display.deliverScreenReports()
        // Release the registration after connecting, matching Simulator.app.
        #expect(screen.requests == ["mode 1280x720@1"])
        #expect(controller.externalDisplayWindow != nil)
        #expect(!display.isRegisteredForExternalScreen)
        #expect(failures.isEmpty)
        screen.report { $0.isPoweredOn = false }
        #expect(controller.session.externalDisplayMode == .disabled && controller.externalDisplayWindow == nil)
    }

    @Test func aChoiceBeforeTheExternalDisplayIsReportedWaitsForIt() throws {
        let preferences = MemoryPreferences()
        var failures: [String] = []
        let (controller, display) = try makeExternalDisplayController(nil, preferences: preferences) {
            failures.append($0.localizedDescription)
        }
        defer { controller.invalidate() }
        controller.session.chooseExternalDisplay(.size640x480) { failures.append($0.localizedDescription) }
        let screen = TestExternalScreen()
        screen.current.isPoweredOn = true
        display.connectExternalScreen(screen)
        controller.session.chooseExternalDisplay(.disabled) { failures.append($0.localizedDescription) }
        #expect(screen.requests.isEmpty)
        display.deliverScreenReports()
        #expect(screen.requests == ["off"])
        #expect(failures.isEmpty)
    }

    @Test func onlyTheAdaptersFirstReportOfTheExternalDisplayCounts() throws {
        let preferences = MemoryPreferences()
        for device in ["test-device", "B"] {
            preferences.setExternalDisplayTag(ExternalDisplayMode.size1280x720.rawValue, forDevice: device)
        }
        // Queued adapter reports retain their registration and arrive after it is released.
        let (controller, display) = try makeExternalDisplayController(nil, preferences: preferences)
        defer { controller.invalidate() }
        let first = TestExternalScreen()
        let second = TestExternalScreen()
        display.connectExternalScreen(first)
        display.connectExternalScreen(second)
        display.deliverScreenReports()
        #expect(first.requests == ["mode 1280x720@1"] && second.requests.isEmpty)
        let (closed, other) = try makeExternalDisplayController(nil, device: "B", preferences: preferences)
        let late = TestExternalScreen()
        other.connectExternalScreen(late)
        closed.invalidate()
        other.deliverScreenReports()
        #expect(late.requests.isEmpty && !closed.session.hasExternalDisplay)
        #expect(!other.isRegisteredForExternalScreen)
    }

    @Test func aDeviceWhoseExternalDisplayIsNeverReportedReportsTheChoice() async throws {
        let preferences = MemoryPreferences()
        preferences.setExternalDisplayTag(ExternalDisplayMode.size1920x1080.rawValue, forDevice: "test-device")
        var restored: [String] = []
        let (controller, display) = try makeExternalDisplayController(nil, preferences: preferences) {
            restored.append($0.localizedDescription)
        }
        defer { controller.invalidate() }
        var chosen: [String] = []
        controller.session.chooseExternalDisplay(.size1024x768) { chosen.append($0.localizedDescription) }
        #expect(chosen.isEmpty)
        try await wait { !chosen.isEmpty }
        #expect(chosen == [
            "Could not set the external display of Test iPhone to 1024×768: The device has no external display port.",
        ])
        #expect(restored.isEmpty)
        #expect(controller.session.externalDisplayMode == nil)
        #expect(externalDisplayItems(for: controller).allSatisfy {
            !$0.contains("✓") && ($0 == "CarPlay (disabled)") == $0.hasSuffix("(disabled)")
        })
        controller.session.chooseExternalDisplay(.size1280x720) { chosen.append($0.localizedDescription) }
        #expect(chosen.count == 2)
        let screen = TestExternalScreen()
        display.connectExternalScreen(screen)
        display.deliverScreenReports()
        #expect(screen.requests == ["mode 1280x720@1"] && controller.externalDisplayWindow != nil)
        #expect(restored.isEmpty && chosen.count == 2 && display.externalScreenRegistrations == 1)

        let adapterless = TestDisplay()
        adapterless.hasScreenAdapter = false
        let other = try makeController(adapterless, features: Self.externalDisplayFeatures, preferences: preferences)
        defer { other.invalidate() }
        other.session.connectExternalDisplay { restored.append($0.localizedDescription) }
        other.session.chooseExternalDisplay(.size1024x768) { chosen.append($0.localizedDescription) }
        #expect(restored == [
            "Could not set the external display of Test iPhone to 1280×720 (720p): The device has no external display port.",
        ])
        #expect(chosen.last == "Could not set the external display of Test iPhone to 1024×768: The device has no external display port.")
    }

    @Test func theLastExternalDisplayChoiceWinsOverChangesInFlight() throws {
        let preferences = MemoryPreferences()
        let screen = TestExternalScreen()
        screen.defersChanges = true
        let (controller, _) = try makeExternalDisplayController(screen, preferences: preferences)
        defer { controller.invalidate() }
        controller.perform(.externalDisplay1920x1080)
        controller.perform(.externalDisplayDisabled)
        #expect(screen.requests == ["mode 1920x1080@1"])
        screen.deliver()
        #expect(screen.requests == ["mode 1920x1080@1", "off"])
        screen.deliver()
        #expect(!screen.current.isPoweredOn && controller.session.externalDisplayMode == .disabled)
        #expect(preferences.externalDisplayTag(forDevice: "test-device") == 2114)
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
        // Mode and power-off requests outlive the closing window's session.
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
        // Reopening must restore the saved size after the previous session's pending power-off.
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
        // Fit Point Accurate on any screen and Pixel Accurate's half scale on Retina.
        screen.current = ExternalScreenState(isPoweredOn: true, pixelSize: CGSize(width: 640, height: 480), scale: 1)
        let (controller, _) = try makeExternalDisplayController(screen, preferences: preferences)
        defer { controller.invalidate() }
        let external = try #require(controller.externalDisplayWindow)
        let window = try #require(external.window)
        let display = try #require(screen.displays.last)
        #expect(controller.scaledWindow === controller)
        external.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
        #expect(controller.scaledWindow === external)
        #expect(display.keyboard == [true])
        #expect(window.firstResponder === display.inputView)
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
        // SimulatorKit updates its display after CoreSimulator reports the resolution.
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
        // A returning key window must receive modifiers missed while another window had focus.
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
        // Simulator.app places CarPlay last, after a separator.
        let item = try #require(submenu.items.last)
        #expect(item.title == "CarPlay" && item.keyEquivalent.isEmpty)
        #expect(submenu.items.dropLast().last?.isSeparatorItem == true)
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
        preferences.setWindowGeometry(center: NSPoint(x: 400, y: 300), scale: 0.5, forDevice: "test-device",
                                      screens: NSScreen.screens.map(\.frame), kind: .externalDisplay)
        let screen = TestExternalScreen()
        let (controller, _) = try makeExternalDisplayController(screen, features: Self.carPlayFeatures,
                                                                preferences: preferences)
        defer { controller.invalidate() }
        controller.perform(.externalDisplayCarPlay)
        // Match Simulator.app's order: configuration, screen, guest session, then HID service.
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
        #expect(requests { controller.perform(.externalDisplayCarPlay) }
            == ["save carplay", "mode 800x480@2 carplay", "start carplay", "connect service"])
        let window = try #require(controller.externalDisplayWindow?.window)
        #expect(requests { controller.perform(.externalDisplayCarPlay) } == [
            "save carplay", "remove service", "stop carplay", "mode 800x480@2 carplay", "start carplay", "connect service",
        ])
        #expect(requests { controller.perform(.externalDisplay1920x1080) }
            == ["save off", "remove service", "stop carplay", "mode 1920x1080@1"])
        #expect(controller.externalDisplayWindow?.window === window)
        #expect(window.subtitle == "External Display")
        #expect(window.collectionBehavior == [.fullScreenPrimary, .fullScreenAllowsTiling])
        // Power off first so the guest recognizes CarPlay as a new display.
        #expect(requests { controller.perform(.externalDisplayCarPlay) }
            == ["save carplay", "off", "mode 800x480@2 carplay", "start carplay", "connect service"])
        #expect(controller.externalDisplayWindow?.window?.subtitle == "CarPlay")
        #expect(controller.externalDisplayWindow?.window !== window)
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
        controller.perform(.externalDisplay720x480)
        var start = ContinuousClock.now
        controller.perform(.externalDisplayCarPlay)
        #expect(screen.requests == ["save off", "mode 720x480@1", "save carplay", "off"])
        try await waitForCarPlay()
        #expect(ContinuousClock.now - start >= delay)
        #expect(screen.requests.suffix(3) == ["mode 800x480@2 carplay", "start carplay", "connect service"])
        controller.perform(.externalDisplayDisabled)
        start = ContinuousClock.now
        controller.perform(.externalDisplayCarPlay)
        #expect(screen.requests.last == "save carplay")
        try await waitForCarPlay()
        #expect(ContinuousClock.now - start >= delay * 0.9)
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
        // Preserve the choice and configuration for reconnect, but end this host's CarPlay session.
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
        // Shutdown ends the guest session; the next boot must not send another end request.
        screen.completionError = HostError.operation("Invalid argument")
        first.invalidate()
        #expect(Array(screen.requests.dropFirst(4)) == ["off"])
        let rebooted = TestExternalScreen()
        rebooted.deviceBootDate = Date(timeIntervalSinceReferenceDate: 1)
        let (second, secondDisplay) = try makeExternalDisplayController(
            rebooted, features: Self.carPlayFeatures, preferences: preferences, externalDisplayChanges: changes)
        #expect(rebooted.requests == restored)
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
        // Failed termination preserves the session; restore its HID service.
        screen.carPlayErrors = ["stop carplay": HostError.operation("busy")]
        #expect(requests(choosing: .carPlay)
            == ["save carplay", "remove service", "stop carplay", "mode 800x480@2 carplay", "connect service"])
        #expect(failures == ["Could not stop CarPlay on Test iPhone: busy"])
        #expect(screen.carPlaySessions == 1)
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
        // Timeout leaves the guest session unknown.
        screen.defersCarPlaySessions = true
        #expect(choose(.carPlay, on: controller, screen: screen)
            == ["save carplay", "mode 800x480@2 carplay", "start carplay"])
        for _ in 0..<100 where failures.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(failures == [
            "Could not start CarPlay on Test iPhone: The device did not answer, so NeoSimulator leaves its CarPlay session as it is until the device restarts.",
        ])
        screen.deliverCarPlaySessions()
        screen.defersCarPlaySessions = false
        // While the session is unknown, change only the screen and HID service until the next boot.
        #expect(choose(.disabled, on: controller, screen: screen) == ["save off", "off"])
        #expect(choose(.carPlay, on: controller, screen: screen)
            == ["save carplay", "mode 800x480@2 carplay", "connect service"])
        #expect(choose(.size1920x1080, on: controller, screen: screen)
            == ["save off", "remove service", "mode 1920x1080@1"])
        #expect(failures.count == 1)
        controller.invalidate()
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
        // Ignore the late end response; the unknown session permits neither another start nor end.
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
        // Restart while waiting for HID-service removal.
        screen.defersCarPlayServices = true
        #expect(choose(.disabled) == ["save off", "off", "remove service"])
        screen.restart(boot: Date(timeIntervalSinceReferenceDate: 1))
        let count = screen.requests.count
        screen.deliverCarPlayServices()
        screen.defersCarPlayServices = false
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
        // Restart makes the pending end request moot.
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
        screen.defersCarPlaySessions = true
        _ = choose(.carPlay)
        try await timeOut()
        screen.defersCarPlayServices = true
        #expect(choose(.carPlay) == ["save carplay", "mode 800x480@2 carplay", "connect service"])
        try await timeOut()
        #expect(failures.last
            == "Could not connect the CarPlay touch screen of Test iPhone: CoreSimulator did not complete the change.")
        screen.defersCarPlayServices = false
        #expect(choose(.disabled) == ["save off", "off", "remove service"])
        #expect(failures.count == 2)
    }

    @Test func carPlaySessionStateMovesOnlyOnAnswersOfItsBoot() {
        let first = Date(timeIntervalSinceReferenceDate: 0)
        let second = Date(timeIntervalSinceReferenceDate: 1)
        var state = CarPlaySessionState()
        #expect(state.session(in: first) == .none && !state.hasService(in: first))
        // Start failure leaves no session; end failure preserves it.
        state.willSend(in: first)
        state.sessionAnswered(starting: true, succeeded: false, in: first)
        #expect(state.session(in: first) == .none)
        state.sessionAnswered(starting: true, succeeded: true, in: first)
        state.serviceAnswered(created: true, succeeded: true, in: first)
        state.sessionAnswered(starting: false, succeeded: false, in: first)
        #expect(state.session(in: first) == .started && state.hasService(in: first))
        // A new boot discards both the old session and its late responses.
        #expect(state.session(in: second) == .none && !state.hasService(in: second))
        state.willSend(in: second)
        state.sessionAnswered(starting: true, succeeded: true, in: second)
        state.serviceAnswered(created: true, succeeded: true, in: second)
        state.sessionAnswered(starting: false, succeeded: true, in: first)
        state.serviceAnswered(created: false, succeeded: true, in: first)
        state.timedOut(in: first)
        #expect(state.session(in: second) == .started && state.hasService(in: second))
        // Timeout keeps the session unknown until another boot.
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
        screen.carPlayErrors = ["save carplay": HostError.operation("disk full")]
        choose(.carPlay)
        #expect(screen.requests == ["save carplay", "mode 800x480@2 carplay", "start carplay", "connect service"])
        #expect(failures == ["Could not save the CarPlay configuration of Test iPhone: disk full"])
        screen.carPlayErrors = ["remove service": HostError.operation("no port"),
                                "stop carplay": HostError.operation("no bridge")]
        choose(.size1280x720)
        #expect(screen.requests.suffix(4) == ["save off", "remove service", "stop carplay", "mode 1280x720@1"])
        #expect(failures.last == """
            Could not disconnect the CarPlay touch screen of Test iPhone: no port
            Could not stop CarPlay on Test iPhone: no bridge
            """)
        screen.carPlayErrors = [:]
        choose(.size640x480)
        #expect(screen.requests.suffix(4) == ["save off", "remove service", "stop carplay", "mode 640x480@1"])
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
        screen.carPlayErrors = [:]
        screen.completionError = HostError.operation("mode failed")
        count = screen.requests.count
        choose(.carPlay)
        #expect(Array(screen.requests.dropFirst(count)) == [
            "save carplay", "remove service", "stop carplay", "mode 800x480@2 carplay",
        ])
        #expect(failures.last == "Could not set the external display of Test iPhone to CarPlay: mode failed")
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
        // Use Simulator.app's default CarPlay configuration and unprefixed keys.
        try CarPlayConfiguration.save(carPlay: true, to: file)
        #expect(try read() == [
            "stark": true, "width": 800, "height": 480, "scale": 2.0, "hasBackButton": false, "hasHomeButton": false,
            "hasWheel": false, "hasWheelBump": false, "hasTouchScreen": true, "hasTouchScreenLofi": false,
            "protocols": [String](),
        ] as NSDictionary)
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
        // End each field with valid text to avoid AppKit's formatter error on focus change.
        func type(_ texts: [String], in field: NSTextField) throws -> [Bool] {
            #expect(window.makeFirstResponder(field))
            let editor = try #require(field.currentEditor() as? NSTextView)
            return texts.map { text in
                editor.selectAll(nil)
                editor.insertText(text, replacementRange: editor.selectedRange())
                #expect(editor.string == text)
                return dialog.okButton.isEnabled
            }
        }
        #expect(try type(["91", "x", "", "-90"], in: dialog.latitudeField) == [false, false, false, true])
        #expect(try type(["-181", "180", "-180"], in: dialog.longitudeField) == [false, true, true])
        dialog.okButton.performClick(nil)
        #expect(accepted == [[-90, -180]] && !window.isVisible)

        dialog.show(latitude: 1, longitude: 2)
        #expect(dialog.latitudeField.doubleValue == 1 && dialog.okButton.isEnabled)
        cancel.performClick(nil)
        #expect(accepted.count == 1 && !window.isVisible)
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
        #expect(controller.session.location == nil && display.appliedLocations.isEmpty)
        dialog.latitudeField.doubleValue = 10
        dialog.longitudeField.doubleValue = -20
        dialog.okButton.performClick(nil)
        #expect(!window.isVisible)
        #expect(controller.session.location == .custom && display.appliedLocations == [.coordinate(10, -20)])
        #expect(UserDefaults.standard.double(forKey: HostPreferences.locationLatitude) == 10)
        #expect(UserDefaults.standard.double(forKey: HostPreferences.locationLongitude) == -20)
        #expect(UserDefaults.standard.integer(forKey: HostPreferences.locationMode) == LocationSelection.customMode)
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
        controller.toggleStayOnTop()
        #expect(window.level == .floating)
        controller.toggleStayOnTop()
        #expect(window.level == .normal)
        controller.invalidate()
        #expect(!window.isVisible)
    }

    private static let scenarios = [LocationScenario(name: "City Run", localizedName: "City Run"),
                                    LocationScenario(name: "Freeway Drive", localizedName: "Freeway Drive")]

    /// Clears location preferences and returns their restoration closure.
    private func removeLocationPreferences() -> () -> Void {
        let keys = [HostPreferences.locationMode, HostPreferences.locationScenario,
                    HostPreferences.locationLatitude, HostPreferences.locationLongitude]
        let saved = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")
        let shared = UserDefaults(suiteName: "dev.lynnswap.NeoSimulator")
        let presetKey = "DeviceLocationPreset.test-device"
        let savedPreset = shared?.object(forKey: presetKey)
        shared?.removeObject(forKey: presetKey)
        shared?.synchronize()
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        return {
            for key in keys { UserDefaults.standard.set(saved?[key], forKey: key) }
            shared?.set(savedPreset, forKey: presetKey)
            shared?.synchronize()
        }
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
        // devicectl cannot reach parallel-test devices; SimulatorKit still reports their rotation.
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
            OpenSimulatorMenu.items(for: devices, hasWindow: { $0 == SimulatorDeviceIdentifier("a") }, action: #selector(NSText.copy(_:)),
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
        #expect(first.map { $0.representedObject as? SimulatorDeviceIdentifier } == ["a", "a", "b", "b"].map { SimulatorDeviceIdentifier($0) })
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

    @Test(arguments: [false, true]) func closeWindowAsksBeforeClosing(integrated: Bool) throws {
        _ = NSApplication.shared
        let menus = MenuController(application: nil)
        let file: NSMenu
        if integrated {
            file = NSMenu(title: "File")
            menus.addCloseWindowCommands(to: file)
        } else {
            menus.install()
            file = try #require(NSApp.mainMenu?.items.first { $0.title == "File" }?.submenu)
        }
        defer {
            NSApp.mainMenu = nil
            withExtendedLifetime(menus) {}
        }
        let item = try #require(file.items.first { $0.title == "Close Window…" })
        #expect(item.keyEquivalent == "w" && item.keyEquivalentModifierMask == [.command, .control] && item.isAlternate)
        #expect(item.target === menus && item.action == NSSelectorFromString("closeAsking:"))
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
        #expect(HostApplication.initialDevice(in: devices + [current], current: SimulatorDeviceIdentifier(identifier.lowercased()))?.id == identifier)
        #expect(HostApplication.initialDevice(in: devices, current: SimulatorDeviceIdentifier(identifier))?.id == "D")
        #expect(HostApplication.initialDevice(in: [devices[0], devices[4]], current: nil)?.id == "A")
        #expect(HostApplication.initialDevice(in: [], current: nil) == nil)
        let path = "/fixture/TestingDevices"
        let clone = AvailableDevice(identifier: identifier, name: "Testing iPad", descriptiveName: "Testing iPad", runtimeIdentifier: "", runtimeName: "", productFamily: 2, deviceTypeName: "iPad", state: 1, deviceSetPath: path)
        let saved = SimulatorDeviceIdentifier(identifier.lowercased(), deviceSetPath: path)
        #expect(HostApplication.initialDevice(in: devices + [current, clone], current: saved)?.identity == clone.identity)
        #expect(HostApplication.initialDevice(in: devices + [current], current: saved)?.identity == devices[3].identity)
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
            supportedDeviceTypes: ["old": ["b"], "new": ["a", "c"]], canPair: { _, _, _, _ in true })
        var created: [[String]] = []
        var failure: Error?
        let form = NewSimulatorWindowController(catalog: catalog, create: { name, deviceType, runtime in
            if let failure { throw failure }
            created.append([name, deviceType, runtime])
            return "device"
        }, pair: { _, _ in Issue.record("paired without a watch") })
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
        #expect(selection() == ["iPhone B", "iOS 26.0"])
        #expect(form.nameField.placeholderString == "iPhone B")
        choose("iPad C", in: form.deviceTypes)
        #expect(selection() == ["iPad C", "iOS 27.0"])
        choose("iOS 26.0", in: form.runtimes)
        #expect(selection() == ["iPhone B", "iOS 26.0"])
        choose("iPhone X", in: form.deviceTypes)
        #expect(selection() == ["iPhone X", nil])
        choose("iPad C", in: form.deviceTypes)
        #expect(selection() == ["iPad C", "iOS 27.0"])
        choose("iOS 28.0", in: form.runtimes)
        #expect(selection() == [nil, "iOS 28.0"])
        choose("iOS 26.0", in: form.runtimes)
        #expect(selection() == ["iPhone B", "iOS 26.0"])

        failure = HostError.operation("creation failed")
        form.forwardButton.performClick(nil)
        for _ in 0..<100 where window.attachedSheet == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(window.isVisible && created.isEmpty)
        window.endSheet(try #require(window.attachedSheet))
        failure = nil
        form.forwardButton.performClick(nil)
        for _ in 0..<100 where window.isVisible { try await Task.sleep(for: .milliseconds(10)) }
        #expect(created == [["iPhone B", "b", "old"]])
        #expect(!window.isVisible)
    }

    @Test func newSimulatorWithoutRuntimesCannotCreate() throws {
        let form = NewSimulatorWindowController(
            catalog: SimulatorCatalog(deviceTypes: [.init(identifier: "a", name: "iPhone A", productFamily: 1)],
                                      runtimes: [], supportedDeviceTypes: [:], canPair: { _, _, _, _ in true }),
            create: { _, _, _ in
                Issue.record("created without a runtime")
                return ""
            }, pair: { _, _ in Issue.record("paired without a runtime") })
        #expect(form.runtimes.itemTitles == ["No Runtimes Available"])
        #expect(!form.runtimes.isEnabled && !form.deviceTypes.isEnabled && !form.forwardButton.isEnabled)
        #expect(!form.pairedWatchButton.isEnabled)
    }

    /// Only the first watch is pairable; pairing checks are recorded in pairings.
    private func pairingCatalog(_ pairings: PairingChecks? = nil) -> SimulatorCatalog {
        SimulatorCatalog(
            deviceTypes: [.init(identifier: "phone", name: "iPhone A", productFamily: 1),
                          .init(identifier: "pad", name: "iPad A", productFamily: 2),
                          .init(identifier: "w1", name: "Apple Watch One", productFamily: 4),
                          .init(identifier: "w2", name: "Apple Watch Two", productFamily: 4),
                          .init(identifier: "w3", name: "Apple Watch Old", productFamily: 4)],
            runtimes: [.init(identifier: "ios", name: "iOS 27.0"), .init(identifier: "old", name: "watchOS 10.0"),
                       .init(identifier: "new", name: "watchOS 27.0"), .init(identifier: "tv", name: "tvOS 27.0")],
            supportedDeviceTypes: ["ios": ["phone", "pad"], "old": ["w3"], "new": ["w1", "w2"]],
            canPair: { watchType, watchRuntime, phoneType, phoneRuntime in
                pairings?.entries.append([watchType, watchRuntime, phoneType, phoneRuntime].joined(separator: " "))
                return watchType == "w1"
            })
    }

    @Test func newSimulatorOffersAPairedWatchOnlyForAnIPhone() throws {
        _ = NSApplication.shared
        let data = try JSONEncoder().encode(SimulatorCatalog.Snapshot(catalog: pairingCatalog()))
        let catalog = try JSONDecoder().decode(SimulatorCatalog.Snapshot.self, from: data).catalog()
        #expect(catalog.canPair("w1", "new", "phone", "ios"))
        #expect(!catalog.canPair("w2", "new", "phone", "ios"))
        let form = NewSimulatorWindowController(catalog: catalog, create: { _, _, _ in "" }, pair: { _, _ in })
        defer { form.close() }
        form.showWindow(nil)
        func choose(_ title: String, in popUp: NSPopUpButton) {
            popUp.selectItem(withTitle: title)
            popUp.sendAction(popUp.action, to: popUp.target)
        }
        #expect(form.deviceTypes.titleOfSelectedItem == "iPhone A")
        #expect(form.pairedWatchButton.isEnabled && form.pairedWatchButton.state == .off)
        #expect(form.forwardButton.title == "Create" && form.forwardButton.isEnabled && !form.previousButton.isEnabled)
        form.pairedWatchButton.performClick(nil)
        #expect(form.forwardButton.title == "Next")
        choose("iPad A", in: form.deviceTypes)
        #expect(!form.pairedWatchButton.isEnabled && form.pairedWatchButton.state == .off)
        #expect(form.forwardButton.title == "Create")
        choose("iPhone A", in: form.deviceTypes)
        #expect(form.pairedWatchButton.isEnabled && form.pairedWatchButton.state == .off)
        form.pairedWatchButton.performClick(nil)
        #expect(form.forwardButton.title == "Next")
        form.pairedWatchButton.performClick(nil)
        #expect(form.forwardButton.title == "Create")
    }

    @Test func newSimulatorWatchPageKeepsTheWatchCompatibleAndPairable() throws {
        _ = NSApplication.shared
        let pairings = PairingChecks()
        let form = NewSimulatorWindowController(catalog: pairingCatalog(pairings), create: { _, _, _ in "" },
                                                pair: { _, _ in })
        defer { form.close() }
        form.showWindow(nil)
        func choose(_ title: String, in popUp: NSPopUpButton) {
            popUp.selectItem(withTitle: title)
            popUp.sendAction(popUp.action, to: popUp.target)
        }
        func selection() -> [String?] {
            [form.watchDeviceTypes.titleOfSelectedItem, form.watchRuntimes.titleOfSelectedItem]
        }
        form.pairedWatchButton.performClick(nil)
        form.forwardButton.performClick(nil)
        #expect(form.showsWatchPage && form.previousButton.isEnabled && form.forwardButton.title == "Create")
        #expect(form.watchDeviceTypes.itemArray.map(\.title) == ["Apple Watch One", "Apple Watch Two", "Apple Watch Old"])
        #expect(form.watchRuntimes.itemTitles == ["watchOS 10.0", "watchOS 27.0"])
        #expect(selection() == ["Apple Watch Old", "watchOS 10.0"])
        #expect(form.watchNameField.placeholderString == "Apple Watch Old")
        #expect(!form.forwardButton.isEnabled && pairings.entries.last == "w3 old phone ios")
        choose("watchOS 27.0", in: form.watchRuntimes)
        #expect(selection() == ["Apple Watch One", "watchOS 27.0"])
        #expect(form.forwardButton.isEnabled && pairings.entries.last == "w1 new phone ios")
        choose("Apple Watch Old", in: form.watchDeviceTypes)
        #expect(form.watchRuntimes.itemTitles == ["watchOS 10.0"] && selection() == ["Apple Watch Old", "watchOS 10.0"])
        #expect(form.watchNameField.placeholderString == "Apple Watch Old" && !form.forwardButton.isEnabled)
        choose("Apple Watch Two", in: form.watchDeviceTypes)
        #expect(form.watchRuntimes.itemTitles == ["watchOS 27.0"] && selection() == ["Apple Watch Two", "watchOS 27.0"])
        #expect(!form.forwardButton.isEnabled && pairings.entries.last == "w2 new phone ios")
        choose("Apple Watch One", in: form.watchDeviceTypes)
        #expect(form.watchRuntimes.itemTitles == ["watchOS 27.0"] && form.forwardButton.isEnabled)
        form.previousButton.performClick(nil)
        #expect(!form.showsWatchPage && !form.previousButton.isEnabled)
        #expect(form.forwardButton.title == "Next" && form.forwardButton.isEnabled)
    }

    @Test func newSimulatorCreatesAndPairsTheWatchAndKeepsTheDevicesOnFailure() async throws {
        _ = NSApplication.shared
        @MainActor final class Failures { var watch: Error?, pair: Error? }
        let failures = Failures()
        var operations: [String] = []
        let form = NewSimulatorWindowController(catalog: pairingCatalog(), create: { name, deviceType, runtime in
            if deviceType.hasPrefix("w"), let failure = failures.watch { throw failure }
            operations.append("create \(name) \(deviceType) \(runtime)")
            return deviceType == "phone" ? "phone-\(operations.count)" : "watch-\(operations.count)"
        }, pair: { watch, phone in
            if let failure = failures.pair { throw failure }
            operations.append("pair \(watch) \(phone)")
        })
        defer { form.close() }
        let window = try #require(form.window)
        form.showWindow(nil)
        form.pairedWatchButton.performClick(nil)
        form.forwardButton.performClick(nil)
        form.watchRuntimes.selectItem(withTitle: "watchOS 27.0")
        form.watchRuntimes.sendAction(form.watchRuntimes.action, to: form.watchRuntimes.target)
        #expect(form.forwardButton.isEnabled)

        failures.pair = HostError.operation("pairing failed")
        form.forwardButton.performClick(nil)
        try await wait { window.attachedSheet != nil }
        let pairingAlert = try #require(window.attachedSheet)
        #expect(texts(in: pairingAlert.contentView).contains(
            "Created “iPhone A” and “Apple Watch One”, but could not pair them: pairing failed"))
        window.endSheet(pairingAlert)
        #expect(window.isVisible && form.forwardButton.isEnabled)
        #expect(operations == ["create iPhone A phone ios", "create Apple Watch One w1 new"])
        operations.removeAll()
        failures.watch = HostError.operation("watch failed")
        form.forwardButton.performClick(nil)
        try await wait { window.attachedSheet != nil }
        let watchAlert = try #require(window.attachedSheet)
        #expect(texts(in: watchAlert.contentView).contains(
            "Created “iPhone A”, but could not create its paired Apple Watch: watch failed"))
        window.endSheet(watchAlert)
        #expect(operations == ["create iPhone A phone ios"])

        operations.removeAll()
        failures.watch = nil
        failures.pair = nil
        form.watchNameField.stringValue = "My Watch"
        form.forwardButton.performClick(nil)
        try await wait { !window.isVisible }
        #expect(operations == ["create iPhone A phone ios", "create My Watch w1 new", "pair watch-2 phone-1"])
        #expect(!window.isVisible)
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

    @Test func watchGesturesSendOneMessageEachAndReportItsFailure() throws {
        let display = TestDisplay()
        let controller = try makeController(display, family: .watch, features: [DeviceCapabilities.watchGestures])
        defer { controller.invalidate() }
        controller.perform(.doubleTap)
        controller.perform(.wristFlick)
        // Watch gestures are single messages, without down/up events.
        #expect(display.gestures == [.doubleTap, .wristFlick])
        #expect(display.events.isEmpty)
        display.deliveryError = HostError.operation("delivery failed")
        var failures: [Error] = []
        controller.session.send(.watchGesture(.doubleTap)) { failures.append($0) }
        #expect(failures.count == 1)
        let other = TestDisplay()
        let otherController = try makeController(other, family: .watch, features: [], device: "other")
        defer { otherController.invalidate() }
        otherController.perform(.doubleTap)
        #expect(other.gestures.isEmpty)
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
        // Overlap the holds even on a slow runner.
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
        #expect(!preferences.connectsHardwareKeyboard(forDevice: "A"))
        #expect(connect.state?(a) == .off && connect.state?(b) == .on)
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

        // Simulator.app changes only the app-wide preference.
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

    /// Follows the key-window responder chain without making a test window key.
    private func responder(in window: NSWindow, taking action: Selector) -> NSResponder? {
        window.firstResponder.flatMap { sequence(first: $0, next: \.nextResponder).first { $0.responds(to: action) } }
    }

    /// Loads the selected Xcode's private runtime.
    private func makeRuntime() async throws -> SimulatorRuntime {
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
        return try await SimulatorRuntime.load(xcodeURL: xcode)
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
                                tvRemote: TVRemoteController? = nil,
                                keyboardLanguage: @escaping @MainActor () -> String? = { "fr" },
                                openLog: @escaping (URL) async throws -> Void = { _ in },
                                pasteboard: NSPasteboard? = nil,
                                pasteboardSync: PasteboardSync? = nil,
                                externalDisplayChanges: ExternalDisplayChanges = ExternalDisplayChanges(),
                                userInterfacePlugin: Bool = false,
                                runtimeVersion: UInt32 = 0x1B_00_00,
                                enhancedMultitasking: Bool = false,
                                appResizeTransport: (@MainActor () async throws -> (any SimulatorAppResizeTransport)?)? = nil,
                                userInterfacePluginLookUp: (attempts: Int, interval: Duration) = (5, .milliseconds(20)),
                                performWindowDrag: @escaping (NSWindow, NSEvent) -> Void = { _, _ in },
                                presentCompactWindow: @escaping (NSWindow) -> Void = { $0.makeKeyAndOrderFront(nil) },
                                onClose: @escaping (DeviceWindowController, DeviceLifetimeChoice?) -> Void = { _, _ in },
                                onRestart: @escaping (DeviceWindowController, Bool) -> Void = { _, _ in },
                                onShutDown: ((DeviceWindowController) -> Void)? = nil)
        throws -> DeviceWindowController {
        let session = try makeSession(display, family: family, features: features, framebufferMask: framebufferMask,
                                      simctl: simctl, devicectl: devicectl, recordingProcess: recordingProcess,
                                      openLog: openLog, screenPointsPerInch: screenPointsPerInch, device: identifier,
                                      preferences: preferences, keyboardLanguage: keyboardLanguage,
                                      pasteboard: pasteboard, pasteboardSync: pasteboardSync,
                                      externalDisplayChanges: externalDisplayChanges,
                                      userInterfacePlugin: userInterfacePlugin, runtimeVersion: runtimeVersion,
                                      enhancedMultitasking: enhancedMultitasking, appResizeTransport: appResizeTransport)
        return try DeviceWindowController(
            session: session, preferences: preferences,
            touchPressure: touchPressure ?? TouchPressure(preferences: preferences, forceTouchTrackpad: { false }),
            tvRemote: tvRemote ?? TVRemoteController(target: { nil }),
            performWindowDrag: performWindowDrag, presentCompactWindow: presentCompactWindow,
            userInterfacePluginLookUp: userInterfacePluginLookUp,
            onClose: onClose, onRestart: onRestart, onShutDown: onShutDown)
    }

    /// Yields between checks so image rendering cannot starve other main-actor tests.
    private func wait(until condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static let defaultFeatures: Set<String> = [DeviceCapabilities.displayRotation, DeviceCapabilities.keyboard]

    /// Acknowledges the first frame and exits normally on SIGINT.
    private static func recorder(then script: String) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap 'exit 0' INT; echo 'Recording started' >&2; \(script)"]
        return process
    }

    /// Simulator.app's threshold: nib button widths plus padding, title width, and 130 points.
    private static func unifiedWidth(title: String = "Test iPhone", subtitle: String = "iOS") -> CGFloat {
        func width(_ text: String, _ style: NSFont.TextStyle) -> CGFloat {
            let font = NSFont.preferredFont(forTextStyle: style, options: [:])
            return NSAttributedString(string: text, attributes: [.font: font]).size().width
        }
        return (31 + 4) + (32 + 4) + (25 + 4) + max(width(title, .headline), width(subtitle, .subheadline)) + 130
    }

    /// Uses an iPhone-style bezel with no top padding.
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

    /// Returns the resize corner's center in screen coordinates.
    private func point(of corner: DisplayResizeRect.Corner, in display: TestDisplay) throws -> NSPoint {
        let rect = try #require(display.resizeRects.first { $0.corner == corner }).rect
        let window = try #require(display.view.window)
        return window.convertPoint(toScreen: display.view.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil))
    }

    /// Returns the left bezel's midpoint in window coordinates, away from resize corners.
    private func pointOnBezel(of display: TestDisplay) throws -> NSPoint {
        let view = display.view
        try #require(view.window != nil)
        return view.convert(NSPoint(x: 5 * display.renderScale, y: view.bounds.midY), to: nil)
    }

    /// Hit-tests and dispatches through the responder chain as AppKit does.
    private func press(_ window: NSWindow, at location: NSPoint) throws -> NSView {
        let hit = try #require(window.contentView?.superview?.hitTest(location))
        hit.mouseDown(with: try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: location, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1)))
        return hit
    }

    /// Sends unhandled drag events directly to the window, as a bezel-corner drag does.
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
                             deviceSetPath: String? = nil,
                             preferences: MemoryPreferences = MemoryPreferences(),
                             keyboardLanguage: @escaping @MainActor () -> String? = { "fr" },
                             pasteboard: NSPasteboard? = nil,
                             pasteboardSync: PasteboardSync? = nil,
                             externalDisplayChanges: ExternalDisplayChanges = ExternalDisplayChanges(),
                             userInterfacePlugin: Bool = false,
                             runtimeVersion: UInt32 = 0x1B_00_00,
                             enhancedMultitasking: Bool = false,
                             appResizeTransport: (@MainActor () async throws -> (any SimulatorAppResizeTransport)?)? = nil) throws -> DeviceSession {
        // Keep the external-display timeout short enough to exercise expiry.
        DeviceSession(
            device: availableDevice(identifier, "Test iPhone", runtime: "iOS", state: 3, deviceSetPath: deviceSetPath),
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
            externalDisplayChanges: externalDisplayChanges, externalScreenTimeout: .milliseconds(100),
            appResizeTransport: appResizeTransport)
    }
}

@MainActor
private final class TestAppResizeTransport: SimulatorAppResizeTransport {
    let lease = TestAppResizeLease()
    let eligibilityUpdates = AsyncThrowingStream<AppResizeEligibility, any Error>.makeStream()
    var holdsStart = false
    var startContinuation: CheckedContinuation<any SimulatorAppResizeLease, Never>?
    func eligibility() async throws -> AsyncThrowingStream<AppResizeEligibility, any Error> {
        eligibilityUpdates.continuation.yield(.eligible)
        return eligibilityUpdates.stream
    }
    func start(size: CGSize, cornerRadius: CGFloat) async throws -> any SimulatorAppResizeLease {
        if holdsStart { return await withCheckedContinuation { startContinuation = $0 } }
        return lease
    }
    func completeStart() { startContinuation?.resume(returning: lease); startContinuation = nil }
}

@MainActor
private final class TestAppResizeLease: SimulatorAppResizeLease {
    let displayUniqueID = "dedicated-app-display"
    let geometry = AppResizeGeometry(minimumSize: CGSize(width: 200, height: 200), maximumSize: CGSize(width: 1000, height: 1000),
        preferredSize: CGSize(width: 500, height: 600), resolvedSize: CGSize(width: 500, height: 600), cornerRadius: 0)
    let geometryUpdates = AsyncThrowingStream<AppResizeGeometry, any Error>.makeStream()
    let invalidation = AsyncStream<Void>.makeStream()
    var invalidations = 0
    var adjustedSizes: [CGSize] = []
    var adjustmentError: (any Error)?
    func updates() throws -> AsyncThrowingStream<AppResizeGeometry, any Error> { geometryUpdates.stream }
    func adjust(size: CGSize, cornerRadius: CGFloat) async throws {
        if let adjustmentError { throw adjustmentError }
        adjustedSizes.append(size)
    }
    func awaitInvalidation() async throws { for await _ in invalidation.stream { return } }
    func invalidate() throws {
        guard invalidations == 0 else { return }
        invalidations += 1
        invalidation.continuation.finish()
        geometryUpdates.continuation.finish()
    }
}

@MainActor
private final class ChangeLog {
    var onMainThread: [Bool] = []
}

/// Entries use "watch-type watch-runtime phone-type phone-runtime".
@MainActor
private final class PairingChecks {
    var entries: [String] = []
}

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
    static let normal = [home, saveScreen, rotate]
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

/// Sends AppKit tracking and modifier events while exposing the held keys.
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

    private func report(_ type: NSEvent.EventType, _ selector: String) {
        let event = NSEvent.enterExitEvent(with: type, location: .zero, modifierFlags: keys, timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                           trackingNumber: 0, userData: nil)
        _ = (area.owner as AnyObject).perform(NSSelectorFromString(selector), with: event)
    }

    func hold(_ keys: NSEvent.ModifierFlags) {
        self.keys = keys
        if let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: keys,
                                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                                        characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 58) {
            NSApp.sendEvent(event)
        }
    }

    /// Changes held keys without sending this app a modifier event.
    func holdInAnotherApp(_ keys: NSEvent.ModifierFlags) { self.keys = keys }

    func item(_ id: DeviceCommand.ID) throws -> NSToolbarItem {
        try #require(toolbar.items.first { $0.itemIdentifier.rawValue == id.rawValue })
    }

    var faces: [ButtonFace] {
        toolbar.items.filter { DeviceCommand.ID(rawValue: $0.itemIdentifier.rawValue) != nil }.map(ButtonFace.init)
    }

    func click(_ id: DeviceCommand.ID) throws -> Bool {
        let item = try item(id)
        return NSApp.sendAction(try #require(item.action), to: item.target, from: item)
    }
}

private final class MemoryPreferences: PreferenceStore {
    var values: [String: Any] = [:]
    func object(forKey defaultName: String) -> Any? { values[defaultName] }
    func bool(forKey defaultName: String) -> Bool { values[defaultName] as? Bool ?? false }
    func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
}

/// Isolates keys in the registration domain, preserving UserDefaults conversions without disk writes.
private final class RegisteredDefaults: PreferenceStore {
    private let prefix = "NeoSimulatorTests.\(UUID().uuidString)."
    func object(forKey defaultName: String) -> Any? { UserDefaults.standard.object(forKey: prefix + defaultName) }
    func bool(forKey defaultName: String) -> Bool { UserDefaults.standard.bool(forKey: prefix + defaultName) }
    /// Registration cannot remove a value, so nil leaves the existing key unchanged.
    func set(_ value: Any?, forKey defaultName: String) {
        if let value { UserDefaults.standard.register(defaults: [prefix + defaultName: value]) }
    }
}

@MainActor
private final class InputView: NSView {
    var keyDowns: [NSEvent] = []
    var keyUps: [NSEvent] = []
    var modifiers: [NSEvent] = []
    var presses: [NSEvent] = []
    /// SimulatorKit passes bezel presses up the responder chain after they leave the screen.
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

/// Models key-window state without showing or activating a window on the WindowServer.
@MainActor
private final class KeyPresentationWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

@MainActor
private final class TestPluginToolbarDelegate: NSObject, NSToolbarDelegate {
    static let itemIdentifier = NSToolbarItem.Identifier("PluginControl")
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        NSToolbarItem(itemIdentifier: identifier)
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.itemIdentifier] }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.itemIdentifier] }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.itemIdentifier] }
}
/// Models menu handling by Apple Vision Pro's XROS.VirtualHMDInputView overlay.
@MainActor
private final class PluginOverlay: NSView, NSMenuItemValidation {
    var actions: [String] = []
    private var showsGazeTarget = false
    override var acceptsFirstResponder: Bool { true }
    @objc func recenterAllOpenApps(_ sender: Any?) { actions.append("recenterAllOpenApps:") }
    @objc func viewportModeChangedToOrbit(_ sender: Any?) { actions.append("viewportModeChangedToOrbit:") }
    @objc func setImmersionTo75(_ sender: Any?) { actions.append("setImmersionTo75:") }
    @objc func configureSimulatedFaceTimeSession1x2(_ sender: Any?) {
        actions.append("configureSimulatedFaceTimeSession1x2:")
    }
    @objc func toggleShowGazeTarget(_ sender: NSMenuItem) {
        actions.append("toggleShowGazeTarget:")
        showsGazeTarget.toggle()
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleShowGazeTarget(_:)) { item.state = showsGazeTarget ? .on : .off }
        return true
    }
}
/// Consumes bezel presses like SimulatorKit's SimChromeButton.
@MainActor
private final class TestButton: NSView {
    var presses: [NSEvent] = []
    override func mouseDown(with event: NSEvent) { presses.append(event) }
}
@MainActor
private final class RefusingResponder: NSResponder {
    override func resignFirstResponder() -> Bool { false }
}
/// Avoids writing CoreSimulator defaults; even a scratch suite leaves a plist behind.
private final class MemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
    override func removeObject(forKey defaultName: String) { values[defaultName] = nil }
}
private enum AppliedLocation: Equatable {
    case cleared, coordinate(Double, Double), scenario(String)
}

/// Mirrors SimDisplayView's intrinsic sizing.
@MainActor
private final class TestDisplayView: NSView {
    var displaySize: () -> NSSize = { .zero }
    override var intrinsicContentSize: NSSize { displaySize() }
}

@MainActor
private final class TestDisplay: SimulatorDisplay {
    let view: NSView = TestDisplayView(frame: NSRect(x: 0, y: 0, width: 390, height: 844))
    let input = InputView()
    var captureDisplayID: UInt32?
    var appDisplay: TestDisplay?
    var appDisplayError: (any Error)?
    var requestedDisplayUniqueIDs: [String] = []
    var holdsAppDisplayConnection = false
    var appDisplayConnection: CheckedContinuation<Void, Never>?
    func completeAppDisplayConnection() { appDisplayConnection?.resume(); appDisplayConnection = nil }
    func connectAppDisplay(uniqueID: String) async throws -> any SimulatorDisplay {
        requestedDisplayUniqueIDs.append(uniqueID)
        if holdsAppDisplayConnection { await withCheckedContinuation { appDisplayConnection = $0 } }
        if let appDisplayError { throw appDisplayError }
        guard let appDisplay else { throw HostError.unavailable("No dedicated display") }
        return appDisplay
    }
    var inputView: NSView { foundPlugin?.overlayView ?? input }
    var plugin: SimulatorUserInterfacePlugin?
    var pluginError: Error?
    private var foundPlugin: SimulatorUserInterfacePlugin?
    func userInterfacePlugin() throws -> SimulatorUserInterfacePlugin? {
        if let pluginError { throw pluginError }
        foundPlugin = plugin
        return plugin
    }
    var backlightState: Int32?
    var announcedRecordings: [Bool] = []
    func announceRecording(started: Bool) { announcedRecordings.append(started) }
    /// Size at scale 1, excluding the bezel.
    var naturalSize = NSSize(width: 390, height: 844)
    private(set) var renderScale: CGFloat = 1
    var screenScale: CGFloat? = 3
    var displayClass: UInt16? = 0
    var onPropertiesChange: (() -> Void)?
    var guestInterfaceAngle: Double?
    var isBooted = true
    var events: [(input: HIDInput, state: HIDState)] = []
    /// Runs before the event is recorded.
    var onSend: () -> Void = {}
    var deliveryError: Error?
    var undeliveredStates: Set<HIDState> = []
    /// Zero-based indices into the recorded events.
    var undeliveredEvents: Set<Int> = []
    var unavailableStates: Set<HIDState> = []
    var deferCompletions = false
    var pendingCompletions: [() -> Void] = []
    var created: [(state: HIDState, at: ContinuousClock.Instant)] = []
    var buttons: [DeviceButton] {
        events.compactMap { if case .button(let button) = $0.input, $0.state == .down { button } else { nil } }
    }
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
        let touch = touchMessages.removeValue(forKey: ObjectIdentifier(message))
        free(UnsafeMutableRawPointer(message.take()))
        let undelivered: Bool
        if let touch {
            remoteTouches.append(touch)
            undelivered = undeliveredTouches > 0 && touch.phase == .ended
            if undelivered { undeliveredTouches -= 1 }
        } else {
            events.append((message.input, message.state))
            undelivered = undeliveredStates.contains(message.state) || undeliveredEvents.contains(events.count - 1)
        }
        let error = undelivered ? HostError.operation("Undelivered") : deliveryError
        if deferCompletions {
            pendingCompletions.append { completion?(error) }
        } else {
            completion?(error)
        }
    }
    /// Remote touches are recorded separately from events.
    var remoteTouches: [TVRemoteTouch] = []
    var undeliveredTouches = 0
    private var touchMessages: [ObjectIdentifier: TVRemoteTouch] = [:]
    func message(for touch: TVRemoteTouch) throws -> HIDMessage {
        let message = HIDMessage(input: .tvRemoteTouch, state: touch.phase == .ended ? .up : .down,
                                 pointer: OpaquePointer(malloc(1)!))
        touchMessages[ObjectIdentifier(message)] = touch
        return message
    }
    var gestures: [WatchGesture] = []
    func send(_ gesture: WatchGesture, completion: @escaping @MainActor (Error?) -> Void) throws {
        gestures.append(gesture)
        completion(deliveryError)
    }
    func toggleAppearance() throws {}
    var notificationStates: [String: UInt64] = [:]
    var postedNotifications: [String] = []
    var contentSize = 4
    var contrastMode = 1
    func postNotification(_ name: String) throws { postedNotifications.append(name) }
    func notificationState(_ name: String) throws -> UInt64 { notificationStates[name] ?? 0 }
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
    /// CoreSimulator can silently drop these changes.
    var droppedCADebugOptions: Set<CADebugOption> = []
    func logDirectory() throws -> URL { logFolder }
    func memoryWarningFile() throws -> URL { memoryWarningURL }
    func caDebugOption(_ option: CADebugOption) throws -> Bool { caDebugOptions.contains(option) }
    func setCADebugOption(_ option: CADebugOption, enabled: Bool) throws {
        guard !droppedCADebugOptions.contains(option) else { return }
        if enabled { caDebugOptions.insert(option) } else { caDebugOptions.remove(option) }
    }
    var scenarios: [LocationScenario] = []
    var appliedLocations: [AppliedLocation] = []
    var locationError: Error?
    /// Simulates a newly booted device that lists scenarios late.
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
    /// Added size at scale 1 while the bezel is visible.
    var bezel = NSSize.zero
    /// Nil means the device type has no bezel.
    var bezelPadding: NSSize?
    var chromePadding: NSSize? { showsBezel ? bezelPadding : nil }
    /// SimDisplayView starts with showDeviceChrome enabled.
    var showsBezel = true
    private var outerSize: NSSize {
        showsBezel ? NSSize(width: naturalSize.width + bezel.width, height: naturalSize.height + bezel.height) : naturalSize
    }
    func setChromeVisible(_ visible: Bool) { showsBezel = visible }
    /// SimulatorKit uses 20-point corner squares in display coordinates.
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
    private(set) var isResizing = false
    func setRenderScale(_ scale: CGFloat) {
        renderScale = scale
        view.setFrameSize(size(for: scale))
    }
    func size(for scale: CGFloat) -> NSSize { NSSize(width: outerSize.width * scale, height: outerSize.height * scale) }
    func scale(for size: NSSize) -> CGFloat { min(size.width / outerSize.width, size.height / outerSize.height) }
    func setKeyboardEnabled(_ enabled: Bool) { keyboard.append(enabled) }
    var hardwareKeyboard: [Bool] = []
    var keyboardLanguages: [String] = []
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
    var pasteboards: [TestPasteboard] = []
    /// Fails once, then clears itself.
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
    /// Nil simulates a failed port connection.
    var audioPort: TestAudioRoutes?
    var audioConnections = 0
    func connectAudioRoutes(changed: @escaping @MainActor (AudioRouteChange) -> Void) throws -> any SimulatorAudioRoutes {
        audioConnections += 1
        guard let audioPort else { throw HostError.unavailable("The device has no audio route port.") }
        audioPort.changed = changed
        return audioPort
    }
    var hasScreenAdapter = true
    private(set) var externalScreen: TestExternalScreen?
    var externalScreenError: Error?
    private(set) var externalScreenRegistrations = 0
    /// SimulatorKit holds adapter registrations weakly.
    private var adapterRegistrations: [WeakAdapterRegistration] = []
    /// Queued reports retain their registration and can outlive the session's reference.
    private var queuedScreenReports: [() -> Void] = []
    func registerForExternalScreen(
        changed: @escaping @MainActor () -> Void,
        found: @escaping @MainActor (Result<any SimulatorExternalScreen, any Error>) -> Void
    ) throws -> AnyObject? {
        externalScreenRegistrations += 1
        guard hasScreenAdapter else { return nil }
        let registration = TestAdapterRegistration(changed: changed, found: found)
        adapterRegistrations.append(WeakAdapterRegistration(registration))
        if externalScreen != nil { queueScreenReport(to: registration) }
        return registration
    }
    func connectExternalScreen(_ screen: TestExternalScreen) {
        externalScreen = screen
        for registration in adapterRegistrations.compactMap(\.registration) { queueScreenReport(to: registration) }
    }
    var isRegisteredForExternalScreen: Bool { adapterRegistrations.contains { $0.registration != nil } }
    func deliverScreenReports() {
        let reports = queuedScreenReports
        queuedScreenReports = []
        for report in reports { report() }
    }
    private func queueScreenReport(to registration: TestAdapterRegistration) {
        guard let screen = externalScreen else { return }
        let error = externalScreenError
        queuedScreenReports.append {
            if let error { return registration.found(.failure(error)) }
            screen.changed = registration.changed
            registration.found(.success(screen))
        }
    }
    var supportsScrolling: [Bool] = []
    func setSupportsScrolling(_ supports: Bool) { supportsScrolling.append(supports) }
    var wantsEdgeSwipes: [Bool] = []
    func setWantsEdgeSwipes(_ wants: Bool) { wantsEdgeSwipes.append(wants) }
    var supportsTouchPressure: [Bool] = []
    var usesTrackpadForce: [Bool] = []
    var touchModes: [SimulatedTouchMode] = []
    func setSupportsTouchPressure(_ supports: Bool) { supportsTouchPressure.append(supports) }
    func setUsesTrackpadForce(_ uses: Bool) { usesTrackpadForce.append(uses) }
    func setSimulatedTouchMode(_ mode: SimulatedTouchMode) { touchModes.append(mode) }
    private(set) var touchIndicators: Set<TouchIndicator> = []
    func setTouchIndicator(_ indicator: TouchIndicator, shown: Bool) {
        if shown { touchIndicators.insert(indicator) } else { touchIndicators.remove(indicator) }
    }
    var rotations: [Double] = []
    /// Simulates SimulatorKit resizing the display after rotation.
    var onRotation: (Double) -> Void = { _ in }
    func setRotation(degrees: Double) {
        rotations.append(degrees)
        onRotation(degrees)
    }
    /// Updates the view after CoreSimulator reports a new screen size.
    func takeScreenSize(_ size: NSSize) {
        naturalSize = size
        view.setFrameSize(self.size(for: renderScale))
    }
    func beginResize() { isResizing = true }
    func resize(to size: NSSize) { setRenderScale(scale(for: size)) }
    func endResize() { isResizing = false }
    func disconnect() { disconnectCount += 1; onDisconnect() }
}

/// Records "input <route>" and "output <route>" requests; tests report external changes.
@MainActor
private final class TestAudioRoutes: SimulatorAudioRoutes {
    var current: AudioRouteState
    private(set) var requests: [String] = []
    /// Fails completion without changing the route.
    var routeError: Error?
    /// Throws before recording the request.
    var refusal: Error?
    var changed: ((AudioRouteChange) -> Void)?
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

    func report(_ reason: AudioRouteChange = .selectedDevice, _ change: (inout AudioRouteState) -> Void) {
        change(&current)
        changed?(reason)
    }
}

/// Its lifetime controls the screen-adapter registration.
@MainActor
private final class TestAdapterRegistration {
    let changed: @MainActor () -> Void
    let found: @MainActor (Result<any SimulatorExternalScreen, any Error>) -> Void
    init(changed: @escaping @MainActor () -> Void,
         found: @escaping @MainActor (Result<any SimulatorExternalScreen, any Error>) -> Void) {
        self.changed = changed
        self.found = found
    }
}

@MainActor
private struct WeakAdapterRegistration {
    weak var registration: TestAdapterRegistration?
    init(_ registration: TestAdapterRegistration) { self.registration = registration }
}

/// iOS 26.5 TVOut modes: 720×480 at 60 Hz, menu sizes at 120 Hz, and iPhone ranges at 60 Hz.
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

/// Records display and CarPlay requests, with independently deferred reports and completions.
@MainActor
private final class TestExternalScreen: SimulatorExternalScreen {
    let screenID: UInt32 = 2
    /// Identifies the boot that owns this screen.
    var deviceBootDate: Date? = Date(timeIntervalSinceReferenceDate: 0)
    var current = ExternalScreenState(isPoweredOn: false, pixelSize: CGSize(width: 720, height: 480), scale: 1)
    var modes = [1, 2].map {
        ExternalScreenMode(sizes: .range(minimum: CGSize(width: 1, height: 1), maximum: CGSize(width: 8192, height: 8192)),
                           scale: $0, refreshRate: 60)
    }
    private(set) var requests: [String] = []
    /// Fails completion without applying the change.
    var completionError: Error?
    /// Throws before recording the request.
    var refusal: Error?
    /// Errors keyed by request name; saving throws and other requests fail completion.
    var carPlayErrors: [String: Error] = [:]
    /// Mirrors CoreSimulatorBridge's session count, including invalid negative counts.
    private(set) var carPlaySessions = 0
    var defersCarPlaySessions = false
    private var pendingSessions: [() -> Void] = []
    var defersCarPlayServices = false
    private var pendingServices: [() -> Void] = []
    /// Reports and completions can arrive independently, in either order.
    var defersChanges = false
    private var pendingReports: [() -> Void] = []
    private var pendingCompletions: [() -> Void] = []
    var changed: (() -> Void)?
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
            // The device checks its boot when the request executes.
            guard deviceBootDate == boot else { return completion(CarPlayRequestMoot()) }
            if let error = carPlayErrors[request] { return completion(error) }
            carPlaySessions += enabled ? 1 : -1
            completion(carPlaySessions < 0 ? HostError.operation("invalid session count") : nil)
        }
        if defersCarPlaySessions { pendingSessions.append(answer) } else { answer() }
    }

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

    func restart(boot: Date) {
        deviceBootDate = boot
        carPlaySessions = 0
    }

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

    func deliver() {
        deliverReports()
        deliverCompletions()
    }

    func deliverReports() {
        let reports = pendingReports
        pendingReports = []
        for report in reports { report() }
    }

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

    func report(_ change: (inout ExternalScreenState) -> Void) {
        change(&current)
        changed?()
    }
}

/// Records transfers while tests supply device events.
@MainActor
private final class TestPasteboard: SimulatorPasteboard {
    let pasteboard: NSPasteboard
    private let events: (SimulatorPasteboardEvent) -> Void
    private(set) var transfers: [PasteboardTransfer] = []
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
        // Use Simulator.app's density defaults for missing or invalid values.
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
        #expect(origin(-50, -100, 1200, 1000) == NSPoint(x: -200, y: -200))
        #expect(origin(100, 100, 1200, 1000) == NSPoint(x: 0, y: 0))
    }

    @Test func aBezelDragLeavesTheWindowWithinReachOfItsScreen() {
        let visible = NSRect(x: 0, y: 0, width: 1000, height: 800)
        func origin(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            WindowScale.origin(of: NSRect(x: x, y: y, width: 300, height: 400), reaching: visible)
        }
        // Simulator.app keeps 128 points within reach, even if most of the window is offscreen.
        #expect(origin(-150, 600) == NSPoint(x: -150, y: 600))
        #expect(origin(900, 300) == NSPoint(x: 872, y: 300))
        #expect(origin(-250, 300) == NSPoint(x: -172, y: 300))
        #expect(origin(300, 700) == NSPoint(x: 300, y: 672))
        #expect(origin(300, -350) == NSPoint(x: 300, y: -272))
    }

    @Test func movingByTheBezelReadsAllowsMoveByDragOnWindowChromeAsSimulatorDoes() {
        // Simulator.app registers true and reads with boolForKey:.
        HostPreferences.registerDefaults()
        let registered = UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain)
        #expect(registered["AllowsMoveByDragOnWindowChrome"] as? Bool == true)
        let defaults = RegisteredDefaults()
        #expect(defaults.movesWindowByDraggingBezel)
        let values: [(Any, Bool)] = [("NO", false), ("YES", true), (false, false), (true, true)]
        for (value, moves) in values {
            defaults.set(value, forKey: HostPreferences.allowsMoveByDragOnWindowChrome)
            #expect(defaults.movesWindowByDraggingBezel == moves)
        }
    }

    @Test func showDeviceBezelsReadsShowChromeAsSimulatorDoes() {
        // Match boolForKey: conversion of ShowChrome values written as strings.
        let defaults = RegisteredDefaults()
        let values: [(Any, Bool)] = [("NO", false), ("0", false), ("false", false), ("YES", true), ("1", true),
                                     (false, false), (true, true)]
        for (value, shows) in values {
            defaults.set(value, forKey: HostPreferences.showChrome)
            #expect(defaults.showsDeviceBezels == shows)
        }
        #expect(RegisteredDefaults().showsDeviceBezels)
    }

    @Test func touchIndicatorPreferencesUseSimulatorAppsKeysAndDefaults() {
        #expect(TouchIndicator.allCases.map(\.preferenceKey)
            == ["ShowSingleTouches", "ShowPinches", "ShowPinchPivotPoint", "HighlightEdgeGestures"])
        // Simulator.app defaults to pinch indicators only.
        HostPreferences.registerDefaults()
        let registered = UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain)
        #expect(TouchIndicator.allCases.map { registered[$0.preferenceKey] as? Bool } == [false, true, false, false])
        #expect(TouchIndicator.allCases.filter(MemoryPreferences().showsTouchIndicator) == [.pinches])
        let defaults = RegisteredDefaults()
        defaults.set("NO", forKey: HostPreferences.showPinches)
        defaults.set("YES", forKey: HostPreferences.showSingleTouches)
        #expect(TouchIndicator.allCases.filter(defaults.showsTouchIndicator) == [.singleTouches])
    }

    @Test func defaultsObservationReportsChangesOnTheMainThread() async throws {
        let key = "NeoSimulatorTests-\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let changes = ChangeLog()
        var observation: DefaultsObservation? = DefaultsObservation(.standard, keys: [key]) {
            changes.onMainThread.append(Thread.isMainThread)
        }
        UserDefaults.standard.set(true, forKey: key)
        #expect(changes.onMainThread == [true])
        await Task.detached { UserDefaults.standard.set(false, forKey: key) }.value
        for _ in 0..<100 where changes.onMainThread.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(changes.onMainThread == [true, true])
        withExtendedLifetime(observation) {}
        observation = nil
        UserDefaults.standard.set(true, forKey: key)
        #expect(changes.onMainThread.count == 2)
    }

    @Test func keyboardAndTrackpadPreferencesUseSimulatorAppsKeys() {
        let preferences = MemoryPreferences()
        #expect(preferences.syncsKeyboardLanguage && preferences.prefersTrackpadForce)
        #expect(preferences.connectsHardwareKeyboard(forDevice: "A"))
        preferences.setWindowGeometry(center: NSPoint(x: 1, y: 2), scale: 1, forDevice: "A", screens: [.zero])
        preferences.setConnectsHardwareKeyboard(false, forDevice: "A")
        #expect(!preferences.connectsHardwareKeyboard(forDevice: "A"))
        #expect(preferences.connectsHardwareKeyboard(forDevice: "B"))
        #expect(preferences.windowGeometry(forDevice: "A", screens: [.zero]).center == NSPoint(x: 1, y: 2))
        preferences.set(false, forKey: HostPreferences.connectHardwareKeyboard)
        #expect(!preferences.connectsHardwareKeyboard(forDevice: "B"))
        preferences.values[HostPreferences.devicePreferences] = ["B": [HostPreferences.connectHardwareKeyboard: "YES"]]
        #expect(!preferences.connectsHardwareKeyboard(forDevice: "B"))
        // Match boolForKey: conversion of values written as strings.
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
        let name = preferences.screenConfiguration(for: two)
        #expect(UUID(uuidString: name)?.uuidString == name)
        #expect(preferences.values["ScreenConfigurations"] == nil)
        let deviceA = preferences.values["DevicePreferences.A"] as? [String: [String: [String: Any]]]
        let deviceB = preferences.values["DevicePreferences.B"] as? [String: [String: [String: Any]]]
        #expect(deviceA?["SimulatorWindowGeometry"]?[name]?["WindowScale"] as? Double == 1.5)
        #expect(deviceA?["SimulatorWindowGeometry"]?[name]?["WindowCenter"] as? String == "{10.5, -20}")
        #expect(deviceB?["SimulatorWindowGeometry"]?[name]?["WindowScale"] == nil)
        #expect(deviceB?["SimulatorWindowGeometry"]?[name]?["WindowCenter"] as? String == "{1, 2}")
        let saved = preferences.windowGeometry(forDevice: "A", screens: two.reversed())
        #expect(saved.center == NSPoint(x: 10.5, y: -20) && saved.scale == 1.5)
        let alone = [laptop], moved = [laptop, NSRect(x: 1512, y: 0, width: 2560, height: 1440)]
        for screens in [alone, moved] {
            let other = preferences.windowGeometry(forDevice: "A", screens: screens)
            #expect(other.center == nil && other.scale == nil)
        }
        #expect(Set([two, alone, moved].map { preferences.screenConfiguration(for: $0) }).count == 3)
        #expect(MemoryPreferences().screenConfiguration(for: two.reversed()) == name)
        preferences.setWindowGeometry(center: NSPoint(x: 5, y: 6), scale: 2, forDevice: "A", screens: alone)
        #expect(preferences.windowGeometry(forDevice: "A", screens: alone).center == NSPoint(x: 5, y: 6))
        #expect(preferences.windowGeometry(forDevice: "A", screens: two).center == NSPoint(x: 10.5, y: -20))
        let current = preferences.screenConfiguration(for: alone)
        preferences.values.removeValue(forKey: "DevicePreferences.A")
        for invalid: Any in [0, -1, "1.5", Double.nan] {
            preferences.values["DevicePreferences"] = ["A": ["SimulatorWindowGeometry": [current: ["WindowScale": invalid]]]]
            #expect(preferences.windowGeometry(forDevice: "A", screens: alone).scale == nil)
        }
        // Simulator.app treats a zero or unreadable center as absent.
        for invalid: Any in ["{0, 0}", "center", 12] {
            preferences.values["DevicePreferences"] = ["A": ["SimulatorWindowGeometry": [current: ["WindowCenter": invalid]]]]
            #expect(preferences.windowGeometry(forDevice: "A", screens: alone).center == nil)
        }
        // Existing valid UUIDs win over the generated arrangement ID.
        let legacy = UUID().uuidString
        preferences.values["ScreenConfigurations"] = [legacy: ["{{0, 0}, {1512, 982}}"]]
        #expect(preferences.screenConfiguration(for: alone) == legacy)
        preferences.values["ScreenConfigurations"] = ["laptop": ["{{0, 0}, {1512, 982}}"]]
        #expect(preferences.screenConfiguration(for: alone) == current)
        let malformed: [String: Any] = [legacy: ["{{0, 0}, {1512, 982}}"], "other": [1]]
        preferences.values["ScreenConfigurations"] = malformed
        #expect(preferences.screenConfiguration(for: alone) == legacy)
        #expect((preferences.values["ScreenConfigurations"] as? NSDictionary) == (malformed as NSDictionary))
    }

    @Test func rendererDefaultsPreserveIndependentDeviceSavesAndLegacyGeometry() throws {
        let domain = "NeoSimulatorTests.\(UUID().uuidString)"
        let first = try #require(UserDefaults(suiteName: domain))
        let second = try #require(UserDefaults(suiteName: domain))
        defer { first.removePersistentDomain(forName: domain) }
        let screens = [NSRect(x: 0, y: 0, width: 1512, height: 982)]
        let arrangement = UUID().uuidString
        let legacy: [String: Any] = [
            "A": ["SimulatorWindowGeometry": [arrangement: ["WindowCenter": "{10, 20}", "WindowScale": 1.5]],
                  HostPreferences.connectHardwareKeyboard: true],
            "B": [HostPreferences.connectHardwareKeyboard: true]
        ]
        first.set(legacy, forKey: HostPreferences.devicePreferences)
        first.set([arrangement: screens.map(NSStringFromRect)], forKey: HostPreferences.screenConfigurations)
        #expect(first.synchronize())
        #expect(second.windowGeometry(forDevice: "A", screens: screens).center == NSPoint(x: 10, y: 20))
        #expect(second.screenConfiguration(for: screens) == arrangement)

        // B saves after A has read its record, but before A commits its change.
        // A whole-dictionary write would overwrite B's keyboard preference.
        first.updatePreferences(forDevice: "A") { device in
            second.setConnectsHardwareKeyboard(false, forDevice: "B")
            device[HostPreferences.connectHardwareKeyboard] = false
        }
        #expect(first.synchronize() && second.synchronize())
        #expect(!first.connectsHardwareKeyboard(forDevice: "A"))
        #expect(!first.connectsHardwareKeyboard(forDevice: "B"))
        #expect(second.windowGeometry(forDevice: "A", screens: screens).scale == 1.5)
        #expect((first.object(forKey: HostPreferences.devicePreferences) as? NSDictionary) == (legacy as NSDictionary))
    }

    @Test func aBezelWithTopPaddingMayReachAboveTheScreen() throws {
        let visible = NSRect(x: 0, y: 74, width: 2560, height: 1336)
        let tall = NSRect(x: -40, y: -300, width: 900, height: 2000)
        #expect(WindowScale.frame(tall, constrainedBelow: visible, topInset: 18)
            == NSRect(x: -40, y: visible.maxY + 18 - 2000, width: 900, height: 2000))
        let low = NSRect(x: 2500, y: -500, width: 900, height: 1000)
        #expect(WindowScale.frame(low, constrainedBelow: visible, topInset: 18) == low)
        let reaching = NSRect(x: 0, y: visible.maxY + 18 - 1000, width: 900, height: 1000)
        #expect(WindowScale.frame(reaching, constrainedBelow: visible, topInset: 18) == reaching)
        // Bezel top padding bypasses AppKit's constraint, which can shrink a resizable window.
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
        // iPhone mode ordering changes between reads; always select the supported 60 Hz range.
        let iPhone: [ExternalScreenMode] = [.exact720x480, .allowedAt120Hertz(scale: 1), .allowedAt120Hertz(scale: 2),
                                            .rangeAt60Hertz(scale: 3), .rangeAt60Hertz(scale: 1), .rangeAt60Hertz(scale: 2)]
        for modes in [iPhone, Array(iPhone.reversed()), [iPhone[1], iPhone[4], iPhone[0], iPhone[2], iPhone[5], iPhone[3]]] {
            for size in [(1024, 768), (1280, 720), (1920, 1080), (3840, 2160)] as [(CGFloat, CGFloat)] {
                #expect(try choice(size.0, size.1, modes) == .rangeAt60Hertz(scale: 1))
            }
            #expect(try choice(720, 480, modes)?.refreshRate == 60)
            #expect(try choice(800, 480, scale: 2, modes) == .rangeAt60Hertz(scale: 2))
        }
        // iPad and iOS 27 iPhone modes need an exact 60 Hz mode to avoid the guest's 720×480 fallback.
        let iPad: [ExternalScreenMode] = [.exact720x480, .allowedAt120Hertz(scale: 2), .allowedAt120Hertz(scale: 1)]
        for modes in [iPad, Array(iPad.reversed())] {
            for size in [(720, 480), (1024, 768), (1920, 1080), (3840, 2160)] as [(CGFloat, CGFloat)] {
                #expect(try choice(size.0, size.1, modes) == .exact720x480)
            }
            #expect(throws: ExternalDisplayLimit.showsInstead(CGSize(width: 720, height: 480))) {
                try choice(1920, 1080, scale: 2, modes)
            }
            #expect(throws: ExternalDisplayLimit.noMode) { try choice(1000, 700, modes) }
        }
        for modes in [iPhone, iPad] {
            #expect(throws: ExternalDisplayLimit.showsInstead(CGSize(width: 720, height: 480))) {
                try choice(640, 480, modes)
            }
        }
        #expect(throws: ExternalDisplayLimit.noMode) { try choice(3840, 2161, iPhone) }
        #expect(throws: ExternalDisplayLimit.noMode) { try choice(1024, 768, scale: 3, iPad) }
        // Preserve the current mode only if the guest supports its rate.
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
        #expect(shown(1920, 1080, 30) == "720x480")
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
        // Avoid shared dispatch workers while deliberately blocking the main actor during startup.
        Thread.detachNewThread {
            center.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil,
                userInfo: [NSWorkspace.applicationUserInfoKey: application])
            posted.signal()
        }
        try #require(posted.wait(timeout: .now() + 3) == .success)

        #expect(monitor.conflictingHostName == "Device Hub")
        #expect(throws: HostError.self) { try monitor.check() }
    }

    @Test func browserAndMenusKeepSameUDIDDevicesInTheirOwnSets() async throws {
        let source = TestCatalog()
        let normal = availableDevice("same", "Normal", runtime: "iOS 27", state: 1)
        let clone = AvailableDevice(identifier: "same", name: "Testing", descriptiveName: "Testing", runtimeIdentifier: normal.runtimeIdentifier,
                                    runtimeName: normal.runtimeName, productFamily: 1, deviceTypeName: "iPhone", state: 1, deviceSetPath: "/custom/XCTestDevices")
        source.devices = [normal, clone]
        let model = DeviceBrowserModel(source: source)
        await model.open(clone)?.value
        #expect(source.opened == [clone.identity])
        #expect(model.devices.first { $0.identity == normal.identity }?.state == 1)
        #expect(model.devices.first { $0.identity == clone.identity }?.state == 3)
        await model.open(normal)?.value
        #expect(source.opened == [clone.identity, normal.identity])
        let items = OpenSimulatorMenu.items(for: [normal, clone], hasWindow: { $0 == clone.identity }, action: #selector(NSText.copy(_:)), target: nil)
        #expect(items.map { $0.representedObject as? SimulatorDeviceIdentifier } == [normal.identity, normal.identity, clone.identity, clone.identity])
        #expect(normal.identity.preferenceIdentifier == "same")
        #expect(clone.identity.preferenceIdentifier != normal.identity.preferenceIdentifier)
        #expect(try JSONDecoder().decode([SimulatorDeviceIdentifier].self, from: JSONEncoder().encode([normal.identity, clone.identity])) == [normal.identity, clone.identity])
    }

    @Test func browserReflectsCatalogChangesAndReportsBootErrors() async throws {
        let source = TestCatalog()
        let model = DeviceBrowserModel(source: source)
        let device = try #require(model.devices.first)
        await model.open(device)?.value
        #expect(source.opened == [device.identity])
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

    @Test func managerRequestsOpenTheExplicitDeviceAndKeepQuitChoices() throws {
        let identifier = UUID().uuidString
        let options = try HostLaunchOptions(arguments: ["--managed", "--headless", "--owner-pid", "123", "--owner-launch-date", "1234.5", "--xcode", "/Xcode.app", "--device", identifier, "--device-set", "/custom/XCTestDevices"])
        #expect(options.deviceIdentifier == identifier)
        #expect(options.isManaged && options.isHeadless)
        #expect(options.owner == RendererOwnerIdentity(processIdentifier: 123, launchDate: Date(timeIntervalSinceReferenceDate: 1234.5)))
        #expect(throws: (any Error).self) {
            try HostLaunchOptions(arguments: ["--managed", "--xcode", "/Xcode.app"])
        }
        #expect(throws: (any Error).self) {
            try HostLaunchOptions(arguments: ["--owner-pid", "123", "--owner-launch-date", "1234.5", "--xcode", "/Xcode.app"])
        }
        #expect(try RendererRequest(url: #require(URL(string: "neosimulator-renderer://open-device?udid=\(identifier)")))
            == .openDevice(SimulatorDeviceIdentifier(identifier)))
        let selected = SimulatorDeviceIdentifier(identifier, deviceSetPath: "/custom/Parallel Testing Devices")
        var components = URLComponents()
        components.scheme = "neosimulator-renderer"
        components.host = "open-device"
        components.queryItems = selected.queryItems
        #expect(try RendererRequest(url: #require(components.url)) == .openDevice(selected))
        #expect(try RendererRequest(url: #require(URL(string: "neosimulator-renderer://quit"))) == .quit(asks: false))
        #expect(try RendererRequest(url: #require(URL(string: "neosimulator-renderer://quit?ask=true"))) == .quit(asks: true))
        #expect(try RendererRequest(url: #require(URL(string: "neosimulator-renderer://activate"))) == .activate)
        #expect(try RendererRequest(url: #require(URL(string: "neosimulator-renderer://show-browser"))) == .showBrowser)
        #expect(throws: (any Error).self) {
            try RendererRequest(url: #require(URL(string: "neosimulator-renderer://open-device")))
        }
    }

    @Test func rendererMigrationPreservesStandaloneSettingsOnceWithoutOverwritingNewChoices() throws {
        let source = "NeoSimulatorTests.Source.\(UUID().uuidString)"
        let target = "NeoSimulatorTests.Renderer.\(UUID().uuidString)"
        let defaults = UserDefaults.standard
        defer {
            defaults.removePersistentDomain(forName: source)
            defaults.removePersistentDomain(forName: target)
        }
        defaults.setPersistentDomain([HostPreferences.showChrome: false, HostPreferences.detachOnAppQuit: true], forName: source)
        defaults.setPersistentDomain([HostPreferences.showChrome: true], forName: target)
        HostPreferences.migrateStandalonePreferences(defaults: defaults, sourceDomain: source, targetDomain: target)
        let migrated = try #require(defaults.persistentDomain(forName: target))
        #expect(migrated[HostPreferences.showChrome] as? Bool == true)
        #expect(migrated[HostPreferences.detachOnAppQuit] as? Bool == true)
        defaults.setPersistentDomain([HostPreferences.detachOnAppQuit: false], forName: source)
        HostPreferences.migrateStandalonePreferences(defaults: defaults, sourceDomain: source, targetDomain: target)
        #expect(defaults.persistentDomain(forName: target)?[HostPreferences.detachOnAppQuit] as? Bool == true)
    }
}

@MainActor
private final class TestCatalog: DeviceBrowserSource {
    var devices = [availableDevice("phone", "Phone", runtime: "iOS 27", state: 1)]
    var opened: [SimulatorDeviceIdentifier] = []
    var failure: Error?
    func availableSimulatorDevices() -> [AvailableDevice] { devices }
    func openSimulator(withIdentifier identifier: SimulatorDeviceIdentifier) async throws {
        if let failure { throw failure }
        opened.append(identifier)
        devices = devices.map {
            var device = $0
            if device.identity == identifier { device.state = 3 }
            return device
        }
    }
}

private func availableDevice(_ identifier: String, _ name: String, runtime: String, state: UInt, deviceSetPath: String? = nil) -> AvailableDevice {
    AvailableDevice(identifier: identifier, name: name, descriptiveName: "\(runtime) - \(name)",
                    runtimeIdentifier: "runtime \(runtime)", runtimeName: runtime,
                    productFamily: name.hasPrefix("iPad") ? 2 : 1, deviceTypeName: name, state: state, deviceSetPath: deviceSetPath)
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
        try await tools.screenshot(to: directory.appendingPathComponent("screen.png"), mask: .ignored, displayID: 47)
        #expect(try String(contentsOf: log, encoding: .utf8).split(separator: "\n").contains("--display=47"))
        let recording = tools.recordingProcess(to: URL(fileURLWithPath: "/tmp/video.mov"), mask: .ignored, codec: .h264, displayID: 47)
        #expect(recording.arguments?.prefix(4) == ["--set", "/tmp/XCTestDevices", "io", "test-device"])
        #expect(recording.arguments?.contains("--display=47") == true)
    }

    @Test func createDevicePassesNameTypeAndRuntimeToSimctl() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("arguments"), simctl = directory.appendingPathComponent("simctl")
        try """
            #!/bin/sh
            printf '%s\\n' "$DEVELOPER_DIR" "$@" > "\(log.path)"
            echo 0D6B2C3A-0000-4000-8000-000000000001
            """.write(to: simctl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: simctl.path)
        let xcode = URL(fileURLWithPath: "/Applications/Xcode.app")
        let identifier = try await DeviceTools.createDevice(named: "My Phone", deviceType: "type", runtime: "runtime",
                                                            xcodeURL: xcode, simctl: simctl)
        #expect(identifier == "0D6B2C3A-0000-4000-8000-000000000001")
        #expect(try String(contentsOf: log, encoding: .utf8).split(separator: "\n") == [
            "/Applications/Xcode.app/Contents/Developer", "create", "My Phone", "type", "runtime",
        ])
        try await DeviceTools.pairDevices(watch: "watch", phone: "phone", xcodeURL: xcode,
                                          deviceSetPath: "/tmp/Devices", simctl: simctl)
        #expect(try String(contentsOf: log, encoding: .utf8).split(separator: "\n") == [
            "/Applications/Xcode.app/Contents/Developer", "--set", "/tmp/Devices", "pair", "watch", "phone",
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


private final class RendererOwnerMonitorFixture: Sendable {
    struct State {
        var exit: (@Sendable () -> Void)?
        var deadline: (@Sendable () -> Void)?
        var observedPID: Int32?
        var seconds: TimeInterval?
        var observationCancelled = false
        var deadlineCancelled = false
        var cleanupRequests = 0
        var forcedExits = 0
    }
    let state = Mutex(State())

    func makeMonitor() -> RendererOwnerMonitor {
        RendererOwnerMonitor(processIdentifier: 123, cleanup: { [self] in
            state.withLock { $0.cleanupRequests += 1 }
        }, observeExit: { [self] pid, exit in
            state.withLock { $0.observedPID = pid; $0.exit = exit }
            return { [self] in state.withLock { $0.observationCancelled = true } }
        }, scheduleDeadline: { [self] seconds, deadline in
            state.withLock { $0.seconds = seconds; $0.deadline = deadline }
            return { [self] in state.withLock { $0.deadlineCancelled = true } }
        }, forceExit: { [self] in state.withLock { $0.forcedExits += 1 } })
    }

    func exitOwner() { state.withLock { $0.exit }?() }
    func expireDeadline() { state.withLock { $0.deadline }?() }
}

@Suite struct RendererOwnerMonitorTests {
    @Test func ownerLossRequestsCleanupOnceAndBoundsAStalledRunLoop() {
        let fixture = RendererOwnerMonitorFixture()
        let monitor = fixture.makeMonitor()
        #expect(fixture.state.withLock { $0.observedPID } == 123)
        #expect(fixture.state.withLock { $0.seconds } == nil)
        fixture.exitOwner()
        fixture.exitOwner()
        #expect(fixture.state.withLock { $0.cleanupRequests } == 1)
        #expect(fixture.state.withLock { $0.seconds } == 60)
        #expect(fixture.state.withLock { $0.forcedExits } == 0)
        // No run-loop cleanup is completed: only the independently controlled deadline progresses.
        fixture.expireDeadline()
        #expect(fixture.state.withLock { $0.forcedExits } == 1)
        monitor.stop()
        fixture.expireDeadline()
        #expect(fixture.state.withLock { $0.forcedExits } == 1)
        #expect(fixture.state.withLock { $0.observationCancelled && $0.deadlineCancelled })
    }

    @Test func normalCompletionAndLateCallbacksNeverStartOrForceOrphanCleanup() {
        let normal = RendererOwnerMonitorFixture()
        let monitor = normal.makeMonitor()
        monitor.stop()
        normal.exitOwner()
        normal.expireDeadline()
        #expect(normal.state.withLock { $0.cleanupRequests == 0 && $0.forcedExits == 0 && $0.seconds == nil })

        let orphan = RendererOwnerMonitorFixture()
        let completing = orphan.makeMonitor()
        orphan.exitOwner()
        completing.stop()
        orphan.expireDeadline()
        #expect(orphan.state.withLock { $0.cleanupRequests == 1 && $0.forcedExits == 0 && $0.deadlineCancelled })
    }
}
