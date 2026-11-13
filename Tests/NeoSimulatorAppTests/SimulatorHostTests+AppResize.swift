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
    @Test(arguments: [false, true])
    func appResizePreservesTheEmbeddedInputFocus(screenFocused: Bool) async throws {
        _ = NSApplication.shared
        let primary = TestDisplay(), app = TestDisplay()
        primary.appDisplay = app
        let transport = TestAppResizeTransport()
        let controller = try makeController(primary, appResizeTransport: { transport })
        defer { controller.invalidate() }
        let parent = NSViewController()
        parent.view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        let window = KeyPresentationWindow(contentRect: parent.view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = parent
        defer { window.close() }
        controller.embed(in: parent)
        let search = NSSearchField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        parent.view.addSubview(search)
        try #require(window.makeFirstResponder(search))
        let editor = try #require(window.firstResponder)
        if screenFocused { controller.focusInput() }
        try #require(window.firstResponder === (screenFocused ? primary.inputView : editor))
        try await wait { controller.session.canResizeApp }
        controller.toggleAppResize()
        try await wait { controller.session.isResizingApp }
        try #require(controller.session.display === app)
        #expect(window.firstResponder === (screenFocused ? app.inputView : editor))
        if !screenFocused { try #require(window.makeFirstResponder(search)) }
        let returningFocus = window.firstResponder
        transport.lease.invalidation.continuation.finish()
        try await wait { !controller.session.isResizingApp }
        try #require(controller.session.display === primary)
        #expect(window.firstResponder === (screenFocused ? primary.inputView : returningFocus))
    }

    @Test(arguments: ["compact", "embedded", "fullscreen", "fullscreen-before-resize"])
    func stoppingAppResizeRestoresTheManualPrimaryScale(presentation: String) async throws {
        _ = NSApplication.shared
        let primary = TestDisplay(), app = TestDisplay()
        app.naturalSize = NSSize(width: 500, height: 600)
        primary.appDisplay = app
        let transport = TestAppResizeTransport()
        let controller = try makeController(primary, features: [DeviceCapabilities.keyboard],
            simctl: URL(fileURLWithPath: "/usr/bin/false"), devicectl: URL(fileURLWithPath: "/usr/bin/false"),
            appResizeTransport: { transport }, keyboardCaptureTap: TestKeyboardEventTap(), presentCompactWindow: { _ in })
        defer { controller.invalidate() }
        controller.showCompactWindow()
        let window = try #require(controller.window)
        primary.screenScale = window.backingScaleFactor / 2
        controller.setScale(.pixelAccurate)
        try #require(primary.renderScale == 0.5)
        let compactSize = window.frame.size
        let parent = NSViewController()
        var main: KeyPresentationWindow?
        defer { main?.close() }
        if presentation == "embedded" {
            parent.view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
            main = KeyPresentationWindow(contentRect: parent.view.frame, styleMask: [.titled], backing: .buffered, defer: false)
            main?.isReleasedWhenClosed = false
            main?.contentViewController = parent
            controller.embed(in: parent)
            updateCanvas { controller.performCanvasZoom(.fit) }
        }
        if presentation == "fullscreen-before-resize" {
            controller.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification, object: window))
            window.setContentSize(NSSize(width: 800, height: 900))
            controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
            try #require(primary.renderScale != 0.5)
        }
        try await wait { controller.session.canResizeApp }
        if presentation == "embedded" {
            updateCanvas {
                controller.setScale(.pixelAccurate)
                controller.toggleAppResize()
            }
        } else { controller.toggleAppResize() }
        try await wait { controller.session.isResizingApp }
        try #require(app.renderScale == 1)
        if presentation == "embedded" {
            let content = controller.presentationViewController.view
            let scroll = try #require(content.subviews.compactMap { $0 as? NSScrollView }.first)
            #expect(scroll.magnification == 1)
        }
        if presentation == "fullscreen-before-resize" {
            controller.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: window))
        }
        if presentation == "fullscreen" {
            controller.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification, object: window))
        }
        controller.session.stopAppResize()
        if presentation == "fullscreen" {
            controller.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: window))
        }
        if presentation == "embedded" {
            #expect(controller.canvasZoom.mode == .fixed(0.5) && controller.canvasZoom.scale == 0.5)
            let rendered = primary.view.convert(primary.view.bounds, to: parent.view).size
            let expected = primary.size(for: 0.5)
            let pixel = 1 / main!.backingScaleFactor
            #expect(abs(rendered.width - expected.width) <= pixel && abs(rendered.height - expected.height) <= pixel)
        } else {
            #expect(primary.renderScale == 0.5)
            #expect(primary.view.frame.size == primary.size(for: 0.5))
        }
        #expect(window.frame.size == compactSize)
    }

    @Test func stoppingAppResizeKeepsAnOversizedPointAccuratePrimaryWindow() async throws {
        _ = NSApplication.shared
        let visible = try #require(NSScreen.main?.visibleFrame)
        let primary = TestDisplay(), app = TestDisplay()
        primary.naturalSize = NSSize(width: visible.width + 100, height: 300)
        primary.bezel = NSSize(width: 20, height: 20)
        primary.bezelPadding = NSSize(width: 10, height: 10)
        primary.appDisplay = app
        let transport = TestAppResizeTransport()
        let controller = try makeController(primary, appResizeTransport: { transport })
        defer { controller.invalidate() }
        let window = try #require(controller.window)
        try #require(DeviceCommand.command(.pointAccurate).isEnabled(controller))
        controller.perform(.pointAccurate)
        let size = window.frame.size
        try #require(primary.renderScale == 1 && size.width > visible.width)
        try await wait { controller.session.canResizeApp }
        controller.toggleAppResize()
        try await wait { controller.session.isResizingApp }
        controller.session.stopAppResize()
        #expect(primary.renderScale == 1)
        #expect(window.frame.size == size)
    }

    @Test func stoppingAppResizeAppliesManualRotationToThePrimaryBeforeLayingItOut() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = directory.appendingPathComponent("orientation")
        try "portrait".write(to: state, atomically: true, encoding: .utf8)
        let devicectl = directory.appendingPathComponent("devicectl")
        try """
            #!/bin/sh
            case "$3" in
            rotate) printf landscapeRight > "\(state.path)" ;;
            get) o=$(cat "\(state.path)")
                 printf '{"result":{"deviceOrientation":"%s","deviceOrientationNonFlat":"%s"}}' "$o" "$o" ;;
            esac
            """.write(to: devicectl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: devicectl.path)
        let key = HostPreferences.rotateWindowWhenSignaledByGuest
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.set(false, forKey: key)
        let primary = TestDisplay(), app = TestDisplay()
        let portrait = NSSize(width: 400, height: 600), landscape = NSSize(width: 600, height: 400)
        primary.naturalSize = portrait
        primary.onRotation = { [weak primary] angle in
            primary?.takeScreenSize(abs(angle.truncatingRemainder(dividingBy: 180)) == 90 ? landscape : portrait)
        }
        primary.appDisplay = app
        let transport = TestAppResizeTransport()
        let controller = try makeController(primary, devicectl: devicectl, appResizeTransport: { transport })
        defer { controller.invalidate() }
        let window = try #require(controller.window)
        let scale = primary.renderScale
        try await wait { controller.session.canResizeApp }
        controller.toggleAppResize()
        try await wait { controller.session.isResizingApp }
        try #require(DeviceCommand.command(.rotateRight).isEnabled(controller))
        controller.perform(.rotateRight)
        try await wait { !controller.session.isBusy }
        try #require(controller.session.displayAngle == -90 && app.rotations.last == -90)
        controller.session.stopAppResize()
        primary.onPropertiesChange?()
        #expect(primary.rotations.last == -90)
        #expect(primary.view.intrinsicContentSize == NSSize(width: landscape.width * scale, height: landscape.height * scale))
        #expect(window.frame.width == (landscape.width * scale).rounded(.up))
    }

    @Test(arguments: [false, true])
    func resizingAnAppKeepsPointScaleAcrossCompactMovesAndPreservesPrimaryGeometry(startInCompact: Bool) async throws {
        _ = NSApplication.shared
        let primary = TestDisplay(), app = TestDisplay()
        app.naturalSize = NSSize(width: 500, height: 600)
        primary.appDisplay = app
        let transport = TestAppResizeTransport()
        let preferences = MemoryPreferences()
        let screens = NSScreen.screens.map(\.frame)
        preferences.setWindowGeometry(center: NSPoint(x: 300, y: 300), scale: 0.75, forDevice: "test-device", screens: screens)
        let controller = try makeController(primary, features: [DeviceCapabilities.keyboard],
            simctl: URL(fileURLWithPath: "/usr/bin/false"), devicectl: URL(fileURLWithPath: "/usr/bin/false"),
            preferences: preferences, appResizeTransport: { transport },
            keyboardCaptureTap: TestKeyboardEventTap(), presentCompactWindow: { _ in })
        defer { controller.invalidate() }
        controller.showCompactWindow()
        let window = try #require(controller.window)
        primary.screenScale = window.backingScaleFactor / 2
        controller.setScale(.pixelAccurate)
        try #require(primary.renderScale == 0.5)
        let savedCenter = NSPoint(x: window.frame.midX, y: window.frame.midY)
        let parent = NSViewController()
        parent.view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        if !startInCompact { controller.embed(in: parent) }
        try await wait { controller.session.canResizeApp }
        controller.toggleAppResize()
        try await wait { controller.session.isResizingApp }
        #expect(app.renderScale == 1)
        controller.showCompactWindow()
        #expect(app.renderScale == 1)
        controller.window?.setFrameOrigin(NSPoint(x: 500, y: 400))
        controller.embed(in: parent)
        let retained = preferences.windowGeometry(forDevice: "test-device", screens: screens)
        #expect(retained.scale == 0.5 && retained.center == savedCenter)
        controller.session.stopAppResize()
        controller.showCompactWindow()
        #expect(primary.renderScale == 0.5)
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
        let controls = DeviceCanvasControls()
        controller.canvasControls = controls
        controls.update(supports: { _ in true }, isEnabled: { _ in true }, recordingTitle: "Record Screen")
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
        #expect(app.view.isDescendant(of: controller.presentationViewController.view))
        controller.presentationViewController.view.layoutSubtreeIfNeeded()
        #expect(!controls.isHidden && controls.fittingSize.height > 0)
        let center = controls.convert(NSPoint(x: controls.bounds.midX, y: controls.bounds.midY), to: nil)
        #expect(controller.presentationWindow?.contentView?.superview?.hitTest(center)?.isDescendant(of: controls) == true)
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
        disconnected.appDisplayError = SimulatorError.operation("Display disconnected")
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
            try await wait { session.appResizeEligibility == .resizing }
            #expect(session.isResizingApp)
            switch end {
            case 0: transport.eligibilityUpdates.continuation.yield(.unavailable)
            case 1: transport.lease.invalidation.continuation.finish()
            default:
                transport.lease.adjustmentError = SimulatorError.operation("Geometry rejected")
                session.resizeApp(to: CGSize(width: 600, height: 700))
            }
            try await wait { !session.isResizingApp }
            #expect(session.display === primary)
            #expect(app.disconnectCount == 1)
            #expect(transport.lease.invalidations == 1)
            #expect(failures == (end == 2 ? ["Geometry rejected"] : []))
        }
    }
}
