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
    func relaunchRestoresIndependentCompactWindowsAndHonorsNewerChoice(_ showsCompactDeviceInMain: Bool) async throws {
        _ = NSApplication.shared
        let ids = ["00000000-0000-0000-0000-000000000001", "00000000-0000-0000-0000-000000000002", "00000000-0000-0000-0000-000000000003"]
        let devices = ids.map { id in InventoryDevice.simulator(SimulatorHostDevice(identifier: id,
            name: id, descriptiveName: id, runtimeIdentifier: "fixture-runtime", runtimeName: "iOS",
            productFamily: "iPhone", state: "Booted")) }
        let source = ManagerModelSource(devices: devices)
        await source.skipSettingsReads()
        var events = source.events.makeAsyncIterator()
        let model = SimulatorManagerModel(source: source)
        await model.refresh()
        let access = HostPreferenceAccess(file: URL.temporaryDirectory.appending(path: "\(UUID().uuidString).plist"))
        let app = AppDelegate(makeLicenses: SettingsPreview.licenses, hostPreferenceAccess: access)
        app.model = model
        app.prepareMainWindow()
        let main = try #require(app.mainWindow)
        main.window?.setFrameAutosaveName("")
        app.startManager()
        var compactPresentations: [String] = []
        var controllers: [DeviceWindowController] = []
        for id in ids {
            let controller = try makeController(TestDisplay(), features: [], device: id,
                keyboardLanguage: { nil }, keyboardCaptureTap: TestKeyboardEventTap(),
                presentCompactWindow: { compactPresentations.append(id); $0.orderFront(nil) })
            controllers.append(controller)
            app.screens.attach(controller, as: .simulator(udid: id, deviceSetPath: nil))
        }
        var compactController: DeviceWindowController?
        if !showsCompactDeviceInMain {
            let controller = try makeController(
                TestDisplay(), features: [], device: ids[1],
                keyboardLanguage: { nil }, keyboardCaptureTap: TestKeyboardEventTap(),
                presentCompactWindow: {
                    compactPresentations.append(ids[1]); $0.orderFront(nil)
                })
            compactController = controller
            app.screens.attach(controller, as: devices[1].id, compact: true)
        }
        defer { compactController?.invalidate(); controllers.forEach { $0.invalidate() }; main.window?.close() }
        let xcode = URL(fileURLWithPath: "/Applications/Fixture Xcode.app")
        let restorations = zip(ids, [SimulatorScreenRestoration.Presentation.hidden, .compact, .main]).map {
            SimulatorScreenRestoration(device: SimulatorDeviceIdentifier($0.0), xcodeURL: xcode, presentation: $0.1)
        }
        app.application(NSApp, open: restorations.map(\.url))
        #expect(await events.next() == .open(devices[0].id))
        await source.completeOpen()
        #expect(await events.next() == .open(devices[1].id))
        if showsCompactDeviceInMain { main.showDevice(devices[1].id) }
        await source.completeOpen()
        #expect(await events.next() == .open(devices[2].id))
        await source.completeOpen()
        try await wait(timeout: .seconds(5)) {
            !model.isBusy
        }
        let selected = showsCompactDeviceInMain ? devices[1].id : devices[2].id
        let pane = main.deviceScreenViewController
        #expect(main.selectedIdentifiers == [selected] && pane.liveDeviceIdentifier == selected)
        #expect(model.selection.device?.id == selected && main.inspectorController.deviceInspector.inspection.device?.id == selected)
        #expect(main.window?.isVisible == true)
        #expect(compactPresentations == (showsCompactDeviceInMain ? [] : [ids[1]]))
        #expect(controllers[0].window?.isVisible == false && !controllers[0].isEmbedded)
        #expect(controllers[showsCompactDeviceInMain ? 1 : 2].presentationViewController.parent === pane.liveScreenContainer)
        guard !showsCompactDeviceInMain else { return }
        try #require(app.screens.screen(for: devices[1].id)?.presentation == .compact)
        try await main.presentConnectedScreen(devices[1].id, purpose: .automatic)
        #expect(compactPresentations == [ids[1]])
        app.application(NSApp, open: [restorations[1].url])
        #expect(await events.next() == .open(devices[1].id))
        await source.completeOpen()
        try await wait(timeout: .seconds(5)) {
            !model.isBusy
        }
        #expect(compactPresentations == [ids[1], ids[1]])
    }

    @Test func canvasAccessoryKeepsControlsOutsideTheNativeContentSafeArea() async throws {
        _ = NSApplication.shared
        let split = NSSplitViewController()
        let content = NSViewController()
        content.view = NSView()
        let viewport = NSView()
        viewport.clipsToBounds = true
        viewport.translatesAutoresizingMaskIntoConstraints = false
        content.view.addSubview(viewport)
        NSLayoutConstraint.activate([
            viewport.leadingAnchor.constraint(equalTo: content.view.safeAreaLayoutGuide.leadingAnchor),
            viewport.trailingAnchor.constraint(equalTo: content.view.safeAreaLayoutGuide.trailingAnchor),
            viewport.topAnchor.constraint(equalTo: content.view.safeAreaLayoutGuide.topAnchor),
            viewport.bottomAnchor.constraint(equalTo: content.view.safeAreaLayoutGuide.bottomAnchor),
        ])
        let item = NSSplitViewItem(viewController: content)
        let accessory = DeviceCanvasAccessoryViewController()
        accessory.onMinimumWidthChange = { [weak item] in item?.minimumThickness = max(280, $0) }
        item.addBottomAlignedAccessoryViewController(accessory)
        split.addSplitViewItem(item)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = split
        defer { window.close() }
        #expect(accessory.isHidden)
        let controls = DeviceCanvasControls()
        controls.update(supports: { ["home", "capture", "record", "rotate"].contains($0) },
                        isEnabled: { _ in true }, recordingTitle: "Record Screen")
        accessory.setControls(controls)
        for size in [NSSize(width: 500, height: 700), NSSize(width: 600, height: 600)] {
            window.setContentSize(size)
            split.view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let canvasFrame = viewport.convert(viewport.bounds, to: split.view)
            let accessoryFrame = accessory.view.convert(accessory.view.bounds, to: split.view)
            #expect(!accessory.isHidden && accessoryFrame.height > 0)
            #expect(!canvasFrame.intersects(accessoryFrame))
            #expect(controls.isDescendant(of: accessory.view) && controls.window === window)
            #expect(accessory.view.bounds.insetBy(dx: -1, dy: -1).contains(controls.convert(controls.bounds, to: accessory.view)))
            #expect(controls.bounds.height + 1 >= controls.fittingSize.height)
            func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
            #expect(descendants(controls).compactMap { $0 as? NSButton }.allSatisfy { !$0.isBordered })
        }
        let originalSize = controls.fittingSize
        controls.update(supports: { _ in true }, isEnabled: { _ in true }, recordingTitle: "Stop Recording",
                        recordingStartDate: Date.now.addingTimeInterval(-10))
        accessory.refresh()
        split.view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        #expect(controls.fittingSize.width > originalSize.width)
        #expect(controls.fittingSize.height == originalSize.height)
        #expect(item.minimumThickness >= controls.fittingSize.width)
        #expect(accessory.view.bounds.insetBy(dx: -1, dy: -1).contains(controls.convert(controls.bounds, to: accessory.view)))
        accessory.setControls(controls)
        #expect((accessory.view as? NSStackView)?.arrangedSubviews.count == 1)
        let runtime = try await makeRuntime()
        let catalog = runtime.uiXcodeURL.appendingPathComponent("Contents/SharedFrameworks/DeviceKit.framework/Versions/A/Resources/Assets.car")
        let rotation = try await DeviceSymbolResource.load(named: "rotate.device.right", from: catalog)
        try #require(rotation != nil)
        let artworkPublished = XCTestExpectation(description: "Loaded canvas artwork is laid out")
        var layouts = 0
        controls.onLayoutChange = {
            accessory.refresh()
            layouts += 1
            if layouts == 2 { artworkPublished.fulfill() }
        }
        controls.xcodeURL = runtime.uiXcodeURL
        controls.update(supports: { $0 == "rotate" }, isEnabled: { _ in true }, recordingTitle: "Record Screen")
        try #require(await XCTWaiter.fulfillment(of: [artworkPublished], timeout: 5) == .completed)
        split.view.layoutSubtreeIfNeeded()
        #expect(controls.fittingSize.height == originalSize.height)
        #expect(controls.bounds.height + 1 >= controls.fittingSize.height)
        #expect(accessory.view.bounds.insetBy(dx: -1, dy: -1).contains(controls.convert(controls.bounds, to: accessory.view)))
        accessory.setControls(nil)
        #expect(accessory.isHidden && controls.superview == nil)
        accessory.setControls(controls)
        #expect(controls.isDescendant(of: accessory.view))
        controls.update(supports: { _ in false }, isEnabled: { _ in false }, recordingTitle: "Record Screen")
        accessory.refresh()
        #expect(accessory.isHidden)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func embeddedCanvasFitsBetweenThePaneBarsAndDrawsBehindThem(native: Bool) async throws {
        _ = NSApplication.shared
        let display = TestDisplay()
        display.usesNativeCanvas = native
        let controller = try makeController(display, features: [DeviceCapabilities.keyboard],
            simctl: URL(fileURLWithPath: "/usr/bin/false"), devicectl: URL(fileURLWithPath: "/usr/bin/false"),
            keyboardCaptureTap: TestKeyboardEventTap(), presentCompactWindow: { _ in })
        defer { controller.invalidate() }
        let model = SimulatorManagerModel(source: ManagerModelSource(devices: []))
        model.registry.stopReading()
        let screens = DeviceScreens(model: model)
        let screen = screens.attach(controller, as: .simulator(udid: controller.session.device.identifier,
                                                               deviceSetPath: controller.session.device.deviceSetPath))
        let controls = screen.canvasControls
        controls.update(supports: { ["home", "capture", "record"].contains($0) },
                        isEnabled: { _ in true }, recordingTitle: "Record Screen")
        let manager = ManagerWindowController(model: model, screens: screens, menus: MenuController(application: nil))
        let mainWindow = try #require(manager.window)
        mainWindow.setFrameAutosaveName("")
        defer { mainWindow.close() }
        mainWindow.setContentSize(NSSize(width: 1040, height: 700))
        mainWindow.contentView?.layoutSubtreeIfNeeded()
        let live = manager.deviceScreenViewController.liveScreenContainer
        updateCanvas {
            controller.embed(in: live)
            manager.deviceScreenViewController.showLiveScreen(screen)
            mainWindow.contentView?.layoutSubtreeIfNeeded()
        }
        let canvas = controller.presentationViewController.view
        let viewport = try #require(canvas.layoutGuides.first { $0.identifier.rawValue == "DeviceCanvasViewport" })
        let pixel = 1 / mainWindow.backingScaleFactor
        let fitArea = canvas.convert(viewport.frame, to: nil)
        let controlsRect = controls.convert(controls.bounds, to: nil)
        // Fit keeps the device between the toolbar and the canvas controls.
        #expect(controller.canvasZoom.mode == .fit && controls.window === mainWindow)
        #expect(fitArea.minY >= controlsRect.maxY - pixel && fitArea.maxY <= mainWindow.contentLayoutRect.maxY + pixel)
        #expect(fitArea.insetBy(dx: -pixel, dy: -pixel).contains(display.view.convert(display.view.bounds, to: nil)))
        // At point size the device is taller than the fitting area and continues behind both bars.
        updateCanvas { controller.setScale(.pointAccurate) }
        let pane = live.view.convert(live.view.bounds, to: nil)
        let shown = display.view.convert(display.view.visibleRect, to: nil)
        #expect(shown.maxY > mainWindow.contentLayoutRect.maxY + 1 && shown.minY < controlsRect.minY - 1,
                "Shown \(NSStringFromRect(shown)) for fitting area \(NSStringFromRect(fitArea))")
        #expect(pane.insetBy(dx: -pixel, dy: -pixel).contains(shown))
        // Clicks in the fitting area still reach the matching device point; the controls stay above the device.
        let frameView = try #require(mainWindow.contentView?.superview)
        let center = NSPoint(x: fitArea.midX, y: fitArea.midY)
        let hit = try #require(frameView.hitTest(center))
        #expect(hit === display.view || hit.isDescendant(of: display.view))
        let local = display.view.convert(center, from: nil)
        #expect(abs(local.x - display.view.bounds.midX) <= 1 && abs(local.y - display.view.bounds.midY) <= 1,
                "Local \(NSStringFromPoint(local)) in \(NSStringFromRect(display.view.bounds))")
        let control = try #require(frameView.hitTest(NSPoint(x: controlsRect.midX, y: controlsRect.midY)))
        #expect(control === controls || control.isDescendant(of: controls))
        let toolbar = try #require(mainWindow.toolbar)
        let capture = try #require(toolbar.items.first { $0.itemIdentifier.rawValue == "captureKeyboard" })
        let compact = try #require(toolbar.items.first { $0.itemIdentifier.rawValue == "CompactDeviceWindow" })
        let zoom = try #require(toolbar.items.first { $0.itemIdentifier.rawValue == "CanvasZoom" } as? NSToolbarItemGroup)
        #expect(zoom.isEnabled)
        controller.showCompactWindow()
        manager.deviceScreenViewController.showDevicePreview(ifDisplaying: screen.id)
        try await wait { zoom.isHidden && !zoom.isEnabled }
        updateCanvas {
            controller.embed(in: live)
            manager.deviceScreenViewController.showLiveScreen(screen)
            mainWindow.contentView?.layoutSubtreeIfNeeded()
        }
        try await wait { !zoom.isHidden && zoom.isEnabled }
        let fitIndex = try #require(CanvasZoom.Action.allCases.firstIndex(of: .fit))
        let zoomMenu = try #require(zoom.menuFormRepresentation?.submenu)
        let fitMenuItem = zoomMenu.items[fitIndex]
        #expect(NSApp.sendAction(try #require(fitMenuItem.action), to: fitMenuItem.target, from: fitMenuItem))
        try await wait { zoom.isSelected(at: fitIndex) }
        screen.perform(CanvasZoom.Action.zoomIn.rawValue)
        try await wait { !zoom.subitems.indices.contains { zoom.isSelected(at: $0) } }
        #expect(NSApp.sendAction(try #require(fitMenuItem.action), to: fitMenuItem.target, from: fitMenuItem))
        try await wait { zoom.isSelected(at: fitIndex) }
        #expect(fitMenuItem.state == .on)
        let physicalIndex = try #require(CanvasZoom.Action.allCases.firstIndex(of: .physicalSize))
        display.displayClass = 1
        zoomMenu.update()
        #expect(!zoomMenu.items[physicalIndex].isEnabled && fitMenuItem.isEnabled)
        display.displayClass = 0
        let overflow = NSMenu()
        let captureMenuItem = try #require(capture.menuFormRepresentation)
        overflow.addItem(captureMenuItem)
        try #require(capture.isEnabled)
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
                             styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        defer { if let parent = sheet.sheetParent { parent.endSheet(sheet) }; sheet.close() }
        mainWindow.beginSheet(sheet, completionHandler: { _ in })
        try await wait { !capture.isEnabled && !compact.isEnabled && !zoom.isEnabled }
        overflow.update()
        zoomMenu.update()
        #expect(!captureMenuItem.isEnabled && zoomMenu.items.allSatisfy { !$0.isEnabled })
        let revision = screen.canvasControlsUpdates
        screen.perform(CanvasZoom.Action.zoomIn.rawValue)
        try await wait { screen.canvasControlsUpdates > revision }
        mainWindow.endSheet(sheet)
        try await wait { compact.isEnabled && capture.isEnabled && zoom.isEnabled }
        overflow.update()
        zoomMenu.update()
        #expect(captureMenuItem.isEnabled && fitMenuItem.isEnabled)
        controller.session.disconnect()
        try await wait { !capture.isEnabled }
    }

    @Test func aRejectedAppSizeIsReportedOnceOverTheConnectedScreen() async throws {
        _ = NSApplication.shared
        let data = Data(#"{"result":{"devices":[{"identifier":"fixture-command","properties":{"hardware":{"fidelity":"physical"},"state":{"name":"Fixture"}}}]}}"#.utf8)
        let device = try #require(CoreDeviceInventoryDecoder.decode(data).first)
        let resize = TestAppResizeTransport()
        let primary = TestRemoteScreenTransport(), dedicated = TestRemoteScreenTransport()
        let session = RemoteDeviceScreenSession(device: device, makeResizeTransport: { _ in resize }) { _, _, target in
            target == nil ? primary : dedicated
        }
        var alerts: [NSAlert] = []
        let controller = RemoteDeviceWindowController(device: device, session: session, presentCompactWindow: { _ in },
            presentAlert: { alert, _ in alerts.append(alert); return .alertFirstButtonReturn })
        let window = try #require(controller.window)
        controller.showWindow(nil)
        try await session.start()
        try await wait { session.canResizeApp }
        try await session.startAppResize(size: CGSize(width: 400, height: 600))
        let rejection = NSError(domain: "NeoSimulatorTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "The app can’t use this size.",
            NSLocalizedRecoverySuggestionErrorKey: "Make the window larger, then try again.",
        ])
        resize.lease.adjustmentError = rejection
        window.setContentSize(CGSize(width: 520, height: 640))
        controller.presentationViewController.view.layoutSubtreeIfNeeded()
        controller.layoutScreen()
        try await wait { !alerts.isEmpty }
        // The device's later geometry updates the screen without repeating the failure.
        var geometry = resize.lease.geometry
        geometry.resolvedSize = CGSize(width: 480, height: 620)
        resize.lease.geometryUpdates.continuation.yield(geometry)
        try await wait { session.appResizeGeometry == geometry }
        #expect(alerts.map(\.messageText) == [rejection.localizedDescription])
        #expect(alerts.first?.informativeText == rejection.localizedRecoverySuggestion)
        #expect(session.state == .connected && session.isResizingApp && window.isVisible)
        try await controller.stopAndClose()
    }

    @Test func fullscreenRestorationUsesTheCurrentDisplayScalePolicy() async throws {
        _ = NSApplication.shared
        let primary = TestDisplay(), app = TestDisplay()
        app.naturalSize = NSSize(width: 500, height: 600)
        primary.appDisplay = app
        let transport = TestAppResizeTransport()
        let preferences = MemoryPreferences()
        preferences.setWindowGeometry(center: NSPoint(x: 300, y: 300), scale: 0.5,
            forDevice: "test-device", screens: NSScreen.screens.map(\.frame))
        let controller = try makeController(primary, features: [DeviceCapabilities.keyboard],
            simctl: URL(fileURLWithPath: "/usr/bin/false"), devicectl: URL(fileURLWithPath: "/usr/bin/false"),
            preferences: preferences, appResizeTransport: { transport },
            keyboardCaptureTap: TestKeyboardEventTap(), presentCompactWindow: { _ in })
        defer { controller.invalidate() }
        controller.showCompactWindow()
        let window = try #require(controller.window)
        try #require(primary.renderScale == 0.5)
        controller.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification, object: window))
        try await wait { controller.session.canResizeApp }
        controller.toggleAppResize()
        try await wait { controller.session.isResizingApp }
        controller.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: window))
        #expect(app.renderScale == 1)
        window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: 600, height: 700)), display: true)
        let windowed = window.frame
        controller.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification, object: window))
        window.setFrame(windowed.insetBy(dx: -100, dy: -50), display: true)
        let fullscreenSize = NSSize(width: 900, height: 900)
        app.takeScreenSize(fullscreenSize)
        // AppKit restores its window before the guest reports the smaller framebuffer.
        window.setFrame(windowed, display: true)
        let content = try #require(controller.presentationViewController.view as? any DisplayContentView)
        let restoredViewport = content.availableDisplaySize
        controller.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: window))
        #expect(window.frame.size == windowed.size)
        #expect(app.naturalSize == fullscreenSize && app.renderScale == 1)
        try await wait { transport.lease.adjustedSizes.last == restoredViewport }
        #expect(transport.lease.adjustedSizes.last == restoredViewport)
        controller.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification, object: window))
        controller.session.stopAppResize()
        controller.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: window))
        #expect(primary.renderScale == 0.5)
    }

    @Test func appMinimumGeometryUsesABoundedPannableViewportInBothPresentations() async throws {
        _ = NSApplication.shared
        let visible = try #require(NSScreen.main?.visibleFrame)
        let primary = TestDisplay(), app = TestDisplay()
        app.naturalSize = NSSize(width: visible.width + 600, height: 600)
        primary.appDisplay = app
        let transport = TestAppResizeTransport()
        transport.lease.geometry.minimumSize = NSSize(width: app.naturalSize.width, height: 300)
        transport.lease.geometry.maximumSize = NSSize(width: app.naturalSize.width * 2, height: 2000)
        transport.lease.geometry.resolvedSize = app.naturalSize
        let controller = try makeController(primary, appResizeTransport: { transport }, presentCompactWindow: { _ in })
        defer { controller.invalidate() }
        let compact = try #require(controller.window)
        let normalMinimum = compact.contentMinSize
        let parent = NSViewController()
        parent.view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        let main = KeyPresentationWindow(contentRect: parent.view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        main.isReleasedWhenClosed = false
        main.contentViewController = parent
        defer { main.close() }
        controller.embed(in: parent)
        try await wait { controller.session.canResizeApp }
        controller.toggleAppResize()
        try await wait { controller.session.isResizingApp }
        let content = controller.presentationViewController.view
        content.layoutSubtreeIfNeeded()
        let scroll = try #require(content.subviews.compactMap { $0 as? NSScrollView }.first)
        #expect(app.renderScale == 1 && !controller.canPerformCanvasZoom(.zoomOut))
        #expect(scroll.frame == content.bounds)
        let mainFrame = main.frame
        let local = NSPoint(x: app.naturalSize.width - 8, y: 300)
        func panToRightEdge() {
            let clip = scroll.contentView
            let target = NSRect(x: app.view.frame.maxX - clip.bounds.width, y: 0,
                                width: clip.bounds.width, height: clip.bounds.height)
            clip.scroll(to: clip.constrainBoundsRect(target).origin)
            scroll.reflectScrolledClipView(clip)
        }
        panToRightEdge()
        #expect(scroll.contentView.bounds.contains(app.view.convert(local, to: scroll.contentView)))
        #expect(main.frame == mainFrame)
        controller.showCompactWindow()
        content.layoutSubtreeIfNeeded()
        #expect(!scroll.isHidden && app.renderScale == 1)
        let maximum = compact.contentRect(forFrameRect: visible).size
        #expect(compact.contentMinSize.width == maximum.width)
        let header = content.bounds.height - compact.contentLayoutRect.height
        #expect(compact.contentMinSize.height == 300 + header + WindowScale.displayGap(bezelPadding: nil))
        #expect(compact.frame.width <= visible.width && compact.frame.height <= visible.height)
        panToRightEdge()
        #expect(scroll.contentView.bounds.contains(app.view.convert(local, to: scroll.contentView)))
        let pointInWindow = app.view.convert(local, to: nil)
        #expect(app.inputView.convert(pointInWindow, from: nil) == local)
        controller.session.stopAppResize()
        #expect(compact.contentMinSize == normalMinimum && scroll.isHidden)
    }

    @Test func nativeCanvasKeepsMagnificationStableWhileResizingAndPanning() throws {
        _ = NSApplication.shared
        let host = NativeCanvasHostingView(rootView: AnyView(Color.clear))
        host.sizingOptions = []
        host.contentSize = { NSSize(width: 800, height: 1200) }
        let content = DeviceContentView(display: host, usesNativeCanvas: true)
        content.isEmbedded = true
        let window = KeyPresentationWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
            styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        window.contentView = container
        content.frame = container.bounds.insetBy(dx: 0, dy: 64)
        content.autoresizingMask = [.width, .height]
        container.addSubview(content)
        let zoom = CanvasZoom()
        zoom.scale = 0.73
        content.canvasZoom = zoom
        updateCanvas { content.applyCanvasMagnification(range: 0.1...4, layout: true) }
        let scroll = try #require(content.subviews.compactMap { $0 as? NSScrollView }.first)
        var magnifications: [CGFloat?] = []
        content.onNativeCanvasMagnification = { magnifications.append($0) }
        updateCanvas {
            window.setContentSize(NSSize(width: 500, height: 450))
            content.layoutSubtreeIfNeeded()
        }
        let finalFrame = host.convert(host.bounds, to: content)
        try #require(!magnifications.isEmpty)
        updateCanvas {
            scroll.contentView.scroll(to: NSPoint(x: 100, y: 500))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        #expect(host.convert(host.bounds, to: content) != finalFrame)
        #expect(magnifications.allSatisfy { $0 == scroll.magnification })
    }

    @Test func nativeCanvasKeepsTheCompactWindowResizableWithDeviceBezels() throws {
        let display = TestDisplay()
        display.usesNativeCanvas = true
        display.bezelPadding = NSSize(width: 10, height: 9)
        let controller = try makeController(display, presentCompactWindow: { _ in })
        defer { controller.invalidate() }
        controller.showCompactWindow()
        let window = try #require(controller.window)
        #expect(window.styleMask.contains(.resizable))
        controller.setDeviceBezelVisible(false)
        controller.setDeviceBezelVisible(true)
        #expect(window.styleMask.contains(.resizable))
        controller.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification, object: window))
        controller.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: window))
        #expect(window.styleMask.contains(.resizable))
    }

    @Test func nativeCanvasMovesBetweenWindowsWithoutLosingItsViewport() async throws {
        _ = NSApplication.shared
        let display = TestDisplay()
        display.usesNativeCanvas = true
        display.naturalSize = NSSize(width: 20, height: 20)
        let controller = try makeController(display, features: [DeviceCapabilities.keyboard],
            simctl: URL(fileURLWithPath: "/usr/bin/false"), devicectl: URL(fileURLWithPath: "/usr/bin/false"),
            keyboardCaptureTap: TestKeyboardEventTap(), presentCompactWindow: { _ in })
        defer { controller.invalidate() }
        let standalone = controller.presentationViewController.view
        standalone.layoutSubtreeIfNeeded()
        let standaloneWindow = try #require(controller.window)
        let standaloneHeader = max(0, standalone.bounds.height - standaloneWindow.contentLayoutRect.height)
        #expect((standalone as? any DisplayContentView)?.availableDisplaySize
            == NSSize(width: standalone.bounds.width, height: standalone.bounds.height - standaloneHeader))
        #expect(display.view.frame.origin == .zero)
        let controls = DeviceCanvasControls()
        controller.canvasControls = controls
        controls.update(supports: { _ in true }, isEnabled: { _ in true }, recordingTitle: "Record Screen")
        func checkControls() throws {
            controller.presentationViewController.view.layoutSubtreeIfNeeded()
            let window = try #require(controller.presentationWindow)
            #expect(controls.bounds.height + 1 >= controls.fittingSize.height)
            let center = controls.convert(NSPoint(x: controls.bounds.midX, y: controls.bounds.midY), to: nil)
            #expect(window.contentView?.superview?.hitTest(center)?.isDescendant(of: controls) == true)
        }
        let initialFrame = try #require(controller.window?.frame)
        #expect(initialFrame.width >= 500 && initialFrame.height >= 700)
        display.naturalSize = NSSize(width: 336, height: 644.5)
        display.onPropertiesChange?()
        #expect(controller.window?.frame == initialFrame)
        let parent = NSViewController()
        parent.view = NSView(frame: NSRect(x: 0, y: 0, width: 575, height: 673))
        let window = KeyPresentationWindow(contentRect: parent.view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = parent
        defer { window.close() }
        updateCanvas {
            controller.embed(in: parent)
            parent.view.layoutSubtreeIfNeeded()
        }
        let content = controller.presentationViewController.view
        let scroll = try #require(content.subviews.compactMap { $0 as? NSScrollView }.first)
        let viewport = try #require(content.layoutGuides.first { $0.identifier.rawValue == "DeviceCanvasViewport" })
        #expect(viewport.frame.minX == 8 && viewport.frame.maxX == content.bounds.maxX - 8)
        #expect(viewport.frame.minY == controls.frame.maxY && viewport.frame.maxY == content.bounds.maxY - 8)
        #expect(WindowScale.matches(controller.canvasZoom.scale, display.scale(for: viewport.frame.size)))
        #expect(try fitRect(of: content, in: scroll).insetBy(dx: -1 / window.backingScaleFactor, dy: -1 / window.backingScaleFactor).contains(documentRect(of: display.view, in: scroll)))
        let previousControlsSize = controls.fittingSize
        controls.update(supports: { _ in true }, isEnabled: { _ in true }, recordingTitle: "Stop Recording",
                        recordingStartDate: Date.now.addingTimeInterval(-10))
        content.layoutSubtreeIfNeeded()
        #expect(controls.fittingSize.width > previousControlsSize.width)
        #expect(controls.fittingSize.height == previousControlsSize.height)
        #expect(viewport.frame.minY >= controls.frame.maxY)
        #expect((content as? any DisplayContentView)?.availableDisplaySize == viewport.frame.size)
        #expect(WindowScale.matches(controller.canvasZoom.scale, display.scale(for: viewport.frame.size)))
        #expect(try fitRect(of: content, in: scroll).insetBy(dx: -1 / window.backingScaleFactor, dy: -1 / window.backingScaleFactor).contains(documentRect(of: display.view, in: scroll)))
        display.naturalSize = NSSize(width: 900, height: 900)
        display.onPropertiesChange?()
        updateCanvas { controller.setScale(.pointAccurate) }
        let before = display.view.convert(NSPoint(x: 120, y: 400), to: content)
        let origin = scroll.contentView.bounds.origin
        scroll.contentView.scroll(to: NSPoint(x: 60, y: 240))
        scroll.reflectScrolledClipView(scroll.contentView)
        let after = display.view.convert(NSPoint(x: 120, y: 400), to: content)
        #expect(before != after)
        #expect(after.y == before.y - (scroll.contentView.bounds.minY - origin.y))
        controls.update(supports: { _ in true }, isEnabled: { _ in true }, recordingTitle: "Record Screen")
        display.naturalSize = NSSize(width: 80, height: 900)
        display.onPropertiesChange?()
        controller.showCompactWindow()
        try checkControls()
        let compact = try #require(controller.window)
        #expect(display.view.window === compact && compact.isOpaque)
        #expect(compact.backgroundColor == .windowBackgroundColor)
        let beforeFit = compact.frame
        controller.setScale(.fitScreen)
        #expect(compact.frame != beforeFit)
        #expect(controller.scaleState(.fitScreen) == .on)
        let fittedWindow = compact.frame
        let shortControlsHeight = controls.fittingSize.height
        controls.update(supports: { _ in true }, isEnabled: { _ in true }, recordingTitle: "Stop Recording",
                        recordingStartDate: Date.now.addingTimeInterval(-10))
        content.layoutSubtreeIfNeeded()
        #expect(controls.fittingSize.height == shortControlsHeight)
        let available = try #require((content as? any DisplayContentView)?.availableDisplaySize)
        let renderedSize = display.size(for: display.renderScale)
        #expect(renderedSize.width <= available.width + 0.001 && renderedSize.height <= available.height + 0.001)
        #expect(compact.frame.height == fittedWindow.height && compact.frame.width > fittedWindow.width)
        #expect(try #require(compact.screen).visibleFrame.contains(compact.frame))
        try checkControls()
        controller.setDeviceBezelVisible(false)
        controller.setDeviceBezelVisible(true)
        #expect(compact.backgroundColor == .windowBackgroundColor)
        controller.embed(in: parent)
        let accessory = DeviceCanvasAccessoryViewController()
        parent.view.addSubview(accessory.view)
        accessory.setControls(controls)
        // AppDelegate refreshes the screen controls after moving them to the accessory.
        controls.update(supports: { _ in true }, isEnabled: { _ in true }, recordingTitle: "Record Screen")
        parent.view.layoutSubtreeIfNeeded()
        #expect(controls.isDescendant(of: accessory.view) && viewport.frame.minY == content.bounds.minY)
        #expect((content as? any DisplayContentView)?.availableDisplaySize == viewport.frame.size)
        updateCanvas { controller.performCanvasZoom(.fit) }
        updateCanvas {
            parent.view.setFrameSize(NSSize(width: 400, height: 300))
            parent.view.layoutSubtreeIfNeeded()
        }
        #expect(try fitRect(of: content, in: scroll).insetBy(dx: -1 / window.backingScaleFactor, dy: -1 / window.backingScaleFactor).contains(documentRect(of: display.view, in: scroll)))
        #expect(display.disconnectCount == 0)
        controller.showCompactWindow()
        let beforeRestart = compact.frame
        await controller.prepareForRestart()
        let replacement = TestDisplay()
        replacement.usesNativeCanvas = true
        replacement.naturalSize = NSSize(width: 20, height: 20)
        controller.reconnect(try makeSession(replacement, features: [DeviceCapabilities.keyboard],
            simctl: URL(fileURLWithPath: "/usr/bin/false"), devicectl: URL(fileURLWithPath: "/usr/bin/false")), present: false)
        #expect(compact.frame == beforeRestart)
        replacement.naturalSize = NSSize(width: 900, height: 900)
        replacement.onPropertiesChange?()
        #expect(compact.frame == beforeRestart)
        #expect(replacement.view.window === compact && display.disconnectCount == 1)
        #expect(controls.superview === controller.presentationViewController.view)
        try checkControls()
    }

    @Test(.timeLimit(.minutes(1)))
    func startupGeometryRefitsKeepTheLatestNativeSizeWithoutAnimation() async throws {
        _ = NSApplication.shared
        let display = TestDisplay()
        display.usesNativeCanvas = true
        let controller = try makeController(display, features: [],
            keyboardCaptureTap: TestKeyboardEventTap(), presentCompactWindow: { _ in })
        defer { controller.invalidate() }
        let parent = NSViewController()
        parent.view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        let window = KeyPresentationWindow(contentRect: parent.view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = parent
        defer { window.close() }
        updateCanvas {
            controller.embed(in: parent)
            parent.view.layoutSubtreeIfNeeded()
            // Native readiness can deliver multiple valid sizes before the AppKit transaction completes.
            for height in 844...1144 {
                display.naturalSize = NSSize(width: 390, height: height)
                display.onPropertiesChange?()
            }
        }
        let scroll = try #require(controller.presentationViewController.view.subviews.compactMap { $0 as? NSScrollView }.first)
        #expect(controller.canvasZoom.mode == .fit && display.renderScale == 1)
        #expect(WindowScale.matches(scroll.magnification, controller.canvasZoom.fitScale))
        #expect(controller.canvasZoom.fitScale == display.scale(for: try #require((controller.presentationViewController.view as? any DisplayContentView)?.availableDisplaySize)))
    }

    @Test(.timeLimit(.minutes(1)))
    func nativeNaturalSizeIgnoresTheCanvasMagnification() async throws {
        _ = NSApplication.shared
        let display = TestDisplay()
        display.usesNativeCanvas = true
        display.naturalSize = NSSize(width: 100, height: 44)
        let controller = try makeController(display, features: [],
            keyboardCaptureTap: TestKeyboardEventTap(), presentCompactWindow: { _ in })
        defer { controller.invalidate() }
        // DeviceKit's loading content aligns its AppKit-backed indicator to the backing pixels of the
        // view that presents it, and measures again after each backing change. The indicator then
        // depends on any magnification of that view, and height limits Fit in this pane.
        var content: CGFloat = 32
        let limit = 50
        var measurements = 0
        let view = try #require(display.view as? TestDisplayView)
        let measure = { [unowned display, unowned view] in
            guard measurements < limit else { return }
            let scale = view.convertToBacking(NSSize(width: 1, height: 1)).height
            let height = content + (12 * scale).rounded(.up) / scale
            guard height != display.naturalSize.height else { return }
            measurements += 1
            display.naturalSize.height = height
            display.onPropertiesChange?()
        }
        view.onBackingPropertiesChange = measure
        let parent = NSViewController()
        parent.view = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 416))
        let window = KeyPresentationWindow(contentRect: parent.view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = parent
        defer { window.close() }
        updateCanvas {
            controller.embed(in: parent)
            parent.view.layoutSubtreeIfNeeded()
        }
        let scroll = try #require(controller.presentationViewController.view.subviews.compactMap { $0 as? NSScrollView }.first)
        try #require(scroll.magnification > 2)
        #expect(measurements < limit, "Natural size was measured \(measurements) times")
        #expect(display.naturalSize.height == content + 12)
        let canvas = controller.presentationViewController.view
        func expectFit() throws {
            let available = try #require((canvas as? any DisplayContentView)?.availableDisplaySize)
            #expect(controller.canvasZoom.mode == .fit && display.renderScale == 1)
            #expect(controller.canvasZoom.fitScale == display.scale(for: available))
            #expect(WindowScale.matches(scroll.magnification, controller.canvasZoom.fitScale))
            #expect(try fitRect(of: canvas, in: scroll).insetBy(dx: -1 / window.backingScaleFactor, dy: -1 / window.backingScaleFactor)
                .contains(documentRect(of: display.view, in: scroll)))
        }
        try expectFit()
        let point = display.view.convert(NSPoint(x: display.view.bounds.midX, y: display.view.bounds.midY), to: nil)
        let root = try #require(window.contentView)
        let frameView = try #require(root.superview)
        let hit = try #require(root.hitTest(frameView.convert(point, from: nil)))
        #expect(hit === display.view || hit.isDescendant(of: display.view))
        // A readiness change still updates the natural size and Fit.
        updateCanvas {
            content = 40
            measure()
        }
        #expect(measurements < limit, "Natural size was measured \(measurements) times")
        #expect(display.naturalSize.height == content + 12)
        try expectFit()
    }

    @Test(arguments: [false, true])
    func rotationKeepsFinalGeometryAndAnimatesEmbeddedPresentation(embedded: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tool = directory.appendingPathComponent("devicectl")
        try """
            #!/bin/sh
            printf '%s' '{"result":{"deviceOrientation":"landscapeRight","deviceOrientationNonFlat":"landscapeRight"}}'
            """.write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        let display = TestDisplay()
        display.naturalSize = NSSize(width: 400, height: 800)
        display.onRotation = { [weak display] _ in
            display?.takeScreenSize(NSSize(width: 800, height: 400))
            // A flush during AppKit layout must not publish the new orientation before its animation.
            let key = "rotationTransaction"
            CATransaction.setValue(true, forKey: key)
            CATransaction.flush()
            #expect(CATransaction.value(forKey: key) as? Bool == true)
        }
        let controller = try makeController(display, devicectl: tool)
        defer { controller.invalidate() }
        let parent = NSViewController()
        parent.view = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 700))
        let window: NSWindow
        if embedded {
            window = NSWindow(contentViewController: parent)
            window.isReleasedWhenClosed = false
            controller.embed(in: parent)
        } else {
            window = try #require(controller.window)
        }
        defer { window.close() }
        window.orderBack(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        let before = window.convertToScreen(display.view.convert(display.view.bounds, to: nil))
        controller.perform(.rotateRight)
        try await wait { !controller.session.isBusy }
        #expect(controller.session.displayAngle == -90)
        let host = try #require(display.view.superview as? DisplayPresentationView)
        let finalFrame = host.frame
        let target = window.convertToScreen(host.convert(host.bounds, to: nil))
        #expect(finalFrame.width > finalFrame.height)
        if !embedded {
            #expect(host.layer?.animation(forKey: "displayRotation") == nil)
            #expect(window.contentLayoutRect.contains(host.convert(host.bounds, to: nil)))
            return
        }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let animation = try #require(host.layer?.animation(forKey: "displayRotation") as? CAKeyframeAnimation)
        let values = try #require(animation.values as? [NSValue])
        let layer = try #require(host.layer)
        let anchor = CGPoint(x: layer.anchorPoint.x * host.bounds.width, y: layer.anchorPoint.y * host.bounds.height)
        func transformed(_ rect: CGRect, by value: NSValue) -> CGRect {
            rect.offsetBy(dx: -anchor.x, dy: -anchor.y)
                .applying(CATransform3DGetAffineTransform(value.caTransform3DValue))
                .offsetBy(dx: anchor.x, dy: anchor.y)
        }
        let first = window.convertToScreen(host.convert(transformed(host.bounds, by: try #require(values.first)), to: nil))
        #expect(abs(first.minX - before.minX) < 1 && abs(first.minY - before.minY) < 1, "First \(first), before \(before), final \(host.convert(host.bounds, to: nil))")
        #expect(abs(first.width - before.width) < 1 && abs(first.height - before.height) < 1)
        for (index, value) in values.enumerated() {
            let center = transformed(CGRect(x: host.bounds.midX, y: host.bounds.midY, width: 0, height: 0), by: value)
            let point = window.convertPoint(toScreen: host.convert(center.origin, to: nil))
            let progress = CGFloat(index) / CGFloat(values.count - 1)
            let expected = NSPoint(x: before.midX + (target.midX - before.midX) * progress,
                                   y: before.midY + (target.midY - before.midY) * progress)
            #expect(abs(point.x - expected.x) < 1 && abs(point.y - expected.y) < 1)
        }
        #expect(CATransform3DIsIdentity(try #require(values.last).caTransform3DValue))
        #expect(host.frame == finalFrame)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func embeddedZoomKeepsPanningAndScaleSeparateFromCompactGeometry(native: Bool) async throws {
        _ = NSApplication.shared
        let display = TestDisplay()
        display.usesNativeCanvas = native
        display.input.frame = display.view.bounds
        let controller = try makeController(display, features: [DeviceCapabilities.keyboard],
            simctl: URL(fileURLWithPath: "/usr/bin/false"), devicectl: URL(fileURLWithPath: "/usr/bin/false"),
            keyboardCaptureTap: TestKeyboardEventTap(), presentCompactWindow: { _ in })
        defer { controller.invalidate() }
        let session = controller.session
        let compactScale = display.renderScale
        var compactFrame = try #require(controller.window?.frame)
        let parent = NSViewController()
        parent.view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 500))
        let window = KeyPresentationWindow(contentRect: parent.view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = parent
        defer { window.close() }
        updateCanvas {
            controller.embed(in: parent)
            parent.view.layoutSubtreeIfNeeded()
        }
        let content = controller.presentationViewController.view
        let scroll = try #require(content.subviews.compactMap { $0 as? NSScrollView }.first)
        let fittingGuide = try #require(content.layoutGuides.first { $0.identifier.rawValue == "DeviceCanvasViewport" })
        #expect(controller.canvasZoom.mode == .fit)
        #expect(WindowScale.matches(scroll.magnification, controller.canvasZoom.fitScale))
        window.orderBack(nil)
        // AppKit moves a window that covers the Dock when it first orders it in, so the frame to keep is read after that.
        let outerFrame = window.frame
        let animatedCanvas = try #require(content as? DeviceContentView)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let animationTime = CACurrentMediaTime()
            let start = scroll.magnification
            let anchor = visibleDevicePoint(of: display.view, in: scroll, fitting: fittingGuide, of: content)
            controller.performCanvasZoom(.zoomIn)
            #expect(scroll.magnification == start)
            animatedCanvas.advanceCanvasMagnification(at: animationTime)
            animatedCanvas.advanceCanvasMagnification(at: animationTime + 0.09)
            #expect(scroll.magnification > start && scroll.magnification < controller.canvasZoom.scale)
            let shownAnchor = visibleDevicePoint(of: display.view, in: scroll, fitting: fittingGuide, of: content)
            #expect(abs(shownAnchor.x - anchor.x) * scroll.magnification <= 1 / window.backingScaleFactor
                && abs(shownAnchor.y - anchor.y) * scroll.magnification <= 1 / window.backingScaleFactor)
            let point = NSPoint(x: display.input.bounds.width * 0.35, y: display.input.bounds.height * 0.6)
            let location = display.input.convert(point, to: nil)
            let presses = display.input.presses.count
            #expect(try press(window, at: location) === display.input)
            #expect(display.input.presses.count == presses + 1)
            let received = display.input.convert(try #require(display.input.presses.last).locationInWindow, from: nil)
            #expect(abs(received.x - point.x) * scroll.magnification <= 1 / window.backingScaleFactor
                && abs(received.y - point.y) * scroll.magnification <= 1 / window.backingScaleFactor)
            let shown = display.view.convert(display.view.bounds, to: content)
            #expect(abs(shown.width - display.size(for: 1).width * scroll.magnification) <= 1 / window.backingScaleFactor)
            if native {
                let reported = try #require(display.canvasMagnifications.last?.scale)
                #expect(WindowScale.matches(reported, scroll.magnification))
            }
            controller.performCanvasZoom(.zoomIn)
            let latest = controller.canvasZoom.scale
            animatedCanvas.advanceCanvasMagnification(at: animationTime + 0.1)
            animatedCanvas.advanceCanvasMagnification(at: animationTime + 0.3)
            #expect(WindowScale.matches(scroll.magnification, latest))
            controller.performCanvasZoom(.zoomOut)
            controller.performCanvasZoom(.fit)
            animatedCanvas.advanceCanvasMagnification(at: animationTime + 0.5)
            #expect(WindowScale.matches(scroll.magnification, controller.canvasZoom.fitScale))
            controller.performCanvasZoom(.zoomOut)
            animatedCanvas.advanceCanvasMagnification(at: animationTime + 0.6)
            animatedCanvas.advanceCanvasMagnification(at: animationTime + 0.69)
            let interrupted = scroll.magnification
            let handle = try #require(content.subviews.first { $0.identifier?.rawValue == "DeviceCanvasResize.upperRight" })
            let corner = handle.convert(NSPoint(x: handle.bounds.midX + 3, y: handle.bounds.midY + 3), to: nil)
            let cornerBefore = handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: content)
            #expect(try press(window, at: corner) === handle)
            content.layoutSubtreeIfNeeded()
            let cornerAfter = handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: content)
            #expect(abs(cornerAfter.x - cornerBefore.x) <= 1 / window.backingScaleFactor
                && abs(cornerAfter.y - cornerBefore.y) <= 1 / window.backingScaleFactor)
            #expect(controller.canvasZoom.mode == .fixed(interrupted) && controller.canvasZoom.scale == interrupted)
            handle.mouseUp(with: try #require(NSEvent.mouseEvent(
                with: .leftMouseUp, location: corner, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)))
            animatedCanvas.advanceCanvasMagnification(at: animationTime + 0.9)
            #expect(scroll.magnification == interrupted)
            controller.performCanvasZoom(.zoomIn)
            #expect(controller.window?.frame == compactFrame)
            controller.showCompactWindow()
            animatedCanvas.advanceCanvasMagnification(at: animationTime + 1)
            #expect(scroll.magnification == 1)
            controller.embed(in: parent)
            compactFrame = try #require(controller.window?.frame)
            updateCanvas {
                parent.view.layoutSubtreeIfNeeded()
                controller.performCanvasZoom(.fit)
            }
        }
        let previousFrame = documentRect(of: display.view, in: scroll).size
        let previousMagnification = scroll.magnification
        updateCanvas {
            parent.view.setFrameSize(NSSize(width: 400, height: 600))
            parent.view.layoutSubtreeIfNeeded()
        }
        try #require(scroll.magnification > previousMagnification)
        let resizedFrame = documentRect(of: display.view, in: scroll).size
        #expect(abs(resizedFrame.width - previousFrame.width) <= 1 / window.backingScaleFactor
            && abs(resizedFrame.height - previousFrame.height) <= 1 / window.backingScaleFactor && display.renderScale == 1)
        let originalCenter = center(of: display.view, in: content)
        let initialMagnification = scroll.magnification
        try #require(controller.canPerformCanvasZoom(.zoomIn))
        updateCanvas { controller.performCanvasZoom(.zoomIn) }
        #expect(scroll.magnification > initialMagnification)
        #expect(WindowScale.matches(scroll.magnification, controller.canvasZoom.scale))
        updateCanvas { controller.performCanvasZoom(.zoomIn) }
        let backingPixel = 1 / window.backingScaleFactor
        let zoomedCenter = center(of: display.view, in: content)
        #expect(abs(zoomedCenter.x - originalCenter.x) <= backingPixel
            && abs(zoomedCenter.y - originalCenter.y) <= backingPixel)
        updateCanvas { controller.performCanvasZoom(.zoomIn) }
        parent.view.setFrameSize(NSSize(width: 420, height: 620))
        parent.view.layoutSubtreeIfNeeded()
        parent.view.setFrameSize(NSSize(width: 400, height: 600))
        parent.view.layoutSubtreeIfNeeded()
        updateCanvas { controller.performCanvasZoom(.zoomIn) }
        updateCanvas { controller.performCanvasZoom(.zoomIn) }
        #expect(WindowScale.matches(scroll.magnification, controller.canvasZoom.scale))
        let resizedCenter = center(of: display.view, in: content)
        #expect(abs(resizedCenter.x - originalCenter.x) <= backingPixel
            && abs(resizedCenter.y - originalCenter.y) <= backingPixel)
        let clipDuringZoom = scroll.contentView
        clipDuringZoom.scroll(to: NSPoint(x: clipDuringZoom.bounds.minX + 10, y: clipDuringZoom.bounds.minY + 20))
        scroll.reflectScrolledClipView(clipDuringZoom)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        let pannedZoomCenter = visibleDevicePoint(of: display.view, in: scroll, fitting: fittingGuide, of: content)
        updateCanvas { controller.performCanvasZoom(.zoomIn) }
        let settledCenter = visibleDevicePoint(of: display.view, in: scroll, fitting: fittingGuide, of: content)
        #expect(abs(settledCenter.x - pannedZoomCenter.x) * scroll.magnification <= backingPixel
            && abs(settledCenter.y - pannedZoomCenter.y) * scroll.magnification <= backingPixel)
        controller.performCanvasZoom(.fit)
        // SimulatorKit can deliver a frame from before the latest scale change.
        display.view.setFrameSize(NSSize(width: previousFrame.width / 2, height: previousFrame.height / 2))
        try #require(display.view.frame.size != display.size(for: display.renderScale))
        updateCanvas {
            parent.view.setFrameSize(NSSize(width: 300, height: 400))
            parent.view.layoutSubtreeIfNeeded()
        }
        let visible = try fitRect(of: content, in: scroll)
        let pixel = 1 / window.backingScaleFactor
        let fittedRect = documentRect(of: display.view, in: scroll)
        try #require(visible.width > 0 && visible.height > 0 && fittedRect.width > 0 && fittedRect.height > 0)
        #expect(visible.insetBy(dx: -pixel, dy: -pixel).contains(fittedRect))
        #expect(min(abs(visible.width - fittedRect.width), abs(visible.height - fittedRect.height)) <= pixel)
        let fitScale = scroll.magnification
        let centerAtFit = center(of: display.view, in: content)
        updateCanvas { controller.performCanvasZoom(.zoomIn) }
        let centerAfterZoom = center(of: display.view, in: content)
        #expect(abs(centerAfterZoom.x - centerAtFit.x) <= pixel && abs(centerAfterZoom.y - centerAtFit.y) <= pixel)
        #expect(scroll.magnification > fitScale && display.renderScale == 1)
        updateCanvas {
            controller.performCanvasZoom(.zoomIn)
            controller.performCanvasZoom(.zoomIn)
            controller.performCanvasZoom(.zoomOut)
        }
        let centerAfterRetarget = center(of: display.view, in: content)
        let visibleCenter = visibleDevicePoint(of: display.view, in: scroll, fitting: fittingGuide, of: content)
        let deviceSize = documentRect(of: display.view, in: scroll).size
        #expect(abs(centerAfterRetarget.x - centerAtFit.x) <= pixel && abs(centerAfterRetarget.y - centerAtFit.y) <= pixel)
        #expect(abs(visibleCenter.x - deviceSize.width / 2) * scroll.magnification <= pixel
            && abs(visibleCenter.y - deviceSize.height / 2) * scroll.magnification <= pixel)
        updateCanvas { controller.setScale(.pointAccurate) }
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
        #expect(scroll.magnification == 1 && WindowScale.matches(display.renderScale, compactScale))
        controller.embed(in: parent)
        parent.view.layoutSubtreeIfNeeded()
        #expect(display.renderScale == 1 && controller.canvasZoom.mode == .fixed(1))
        #expect(abs(clip.bounds.midX - pannedCenter.x) < 1 && abs(clip.bounds.midY - pannedCenter.y) < 1)
        #expect(controller.session === session && display.disconnectCount == 0)
        controller.focusInput()
        #expect(window.firstResponder === display.inputView)
        updateCanvas { controller.performCanvasZoom(.fit) }
        #expect(controller.canvasZoomIsSelected(.fit))
        #expect(try fitRect(of: content, in: scroll).insetBy(dx: -pixel, dy: -pixel).contains(documentRect(of: display.view, in: scroll)))
        updateCanvas {
            parent.view.setFrameSize(NSSize(width: 220, height: 300))
            parent.view.layoutSubtreeIfNeeded()
        }
        #expect(WindowScale.matches(scroll.magnification, controller.canvasZoom.fitScale))
        updateCanvas {
            display.takeScreenSize(NSSize(width: 844, height: 390))
            content.layoutSubtreeIfNeeded()
        }
        #expect(WindowScale.matches(scroll.magnification, controller.canvasZoom.fitScale))
        updateCanvas { controller.performCanvasZoom(.physicalSize) }
        let physicalScale = try #require(controller.scale(for: .physicalSize))
        #expect(controller.canvasZoomIsSelected(.physicalSize) && WindowScale.matches(scroll.magnification, physicalScale))
        updateCanvas {
            display.takeScreenSize(NSSize(width: 390, height: 844))
            content.layoutSubtreeIfNeeded()
        }
        #expect(WindowScale.matches(scroll.magnification, physicalScale))
        let zoomAction: CanvasZoom.Action = controller.canPerformCanvasZoom(.zoomOut) ? .zoomOut : .zoomIn
        try #require(controller.canPerformCanvasZoom(zoomAction))
        updateCanvas { controller.performCanvasZoom(zoomAction) }
        if zoomAction == .zoomOut {
            #expect(scroll.magnification < physicalScale && display.renderScale == 1)
        } else {
            #expect(scroll.magnification > physicalScale && display.renderScale == 1)
        }
        #expect(!controller.canvasZoomIsSelected(.physicalSize))
        #expect(window.frame == outerFrame)
        updateCanvas {
            controller.setScale(.pointAccurate)
            controller.performCanvasZoom(.fit)
        }
        #expect(try fitRect(of: content, in: scroll).insetBy(dx: -pixel, dy: -pixel).contains(documentRect(of: display.view, in: scroll)))
        #expect(controller.canvasZoomIsSelected(.fit) && display.renderScale == 1)
        #expect(window.firstResponder === display.inputView)
        updateCanvas {
            controller.setScale(.pointAccurate)
            controller.performCanvasZoom(.fit)
            parent.view.setFrameSize(NSSize(width: 400, height: 600))
            parent.view.layoutSubtreeIfNeeded()
        }
        #expect(controller.canvasZoomIsSelected(.fit))
        #expect(WindowScale.matches(scroll.magnification, controller.canvasZoom.fitScale))
        #expect(try fitRect(of: content, in: scroll).insetBy(dx: -pixel, dy: -pixel).contains(documentRect(of: display.view, in: scroll)))
        updateCanvas {
            controller.setScale(.pointAccurate)
            controller.performCanvasZoom(.fit)
            controller.showCompactWindow()
        }
        #expect(scroll.magnification == 1)
        controller.embed(in: parent)
        updateCanvas {
            parent.view.setFrameSize(NSSize(width: 220, height: 300))
            parent.view.layoutSubtreeIfNeeded()
        }
        updateCanvas { controller.performCanvasZoom(.zoomIn) }
        updateCanvas { controller.performCanvasZoom(.zoomOut) }
        let fixedScale = controller.canvasZoom.scale
        try #require(fixedScale < 0.4)
        let fixedExtent = display.view.convert(display.view.bounds, to: content).size
        updateCanvas {
            parent.view.setFrameSize(NSSize(width: 400, height: 600))
            parent.view.layoutSubtreeIfNeeded()
        }
        let grownExtent = display.view.convert(display.view.bounds, to: content).size
        #expect(controller.canvasZoom.mode == .fixed(fixedScale))
        #expect(WindowScale.matches(scroll.magnification, fixedScale))
        #expect(abs(grownExtent.width - fixedExtent.width) <= pixel && abs(grownExtent.height - fixedExtent.height) <= pixel)
        if native && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            controller.performCanvasZoom(.zoomIn)
            let time = CACurrentMediaTime()
            animatedCanvas.advanceCanvasMagnification(at: time)
            animatedCanvas.advanceCanvasMagnification(at: time + 0.09)
            let replacement = TestDisplay()
            replacement.usesNativeCanvas = true
            controller.reconnect(try makeSession(replacement, features: [DeviceCapabilities.keyboard]), present: false)
            session.disconnect()
            #expect(!replacement.canvasMagnifications.isEmpty)
            #expect(replacement.canvasMagnifications.allSatisfy { $0.scale == nil || $0.attached })
            let updates = replacement.canvasMagnifications.count
            animatedCanvas.advanceCanvasMagnification(at: time + 1)
            #expect(replacement.canvasMagnifications.count == updates)
        }
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

        for error in [nil, SimulatorError.unavailable("plugin from another Xcode")] as [Error?] {
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
        phone.pluginError = SimulatorError.unavailable("looked up")
        let phoneController = try makeController(phone)
        defer { phoneController.invalidate() }
        phoneController.showWindow(nil)
        try await Task.sleep(for: .milliseconds(50))
        #expect(phoneController.window?.attachedSheet == nil)
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
        // The read waits for the guest to start, which a test display has done.
        try await wait {
            !phone.session.isBusy && (try? String(contentsOf: log, encoding: .utf8))?.contains("orientation get") == true
        }
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
        #expect(throws: DeviceDomainError.self) { try reading("faceDown", "faceDown") }
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
            display.naturalSize = NSSize(width: Self.unifiedWidth(), height: 160)
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
        let log = directory.appendingPathComponent("arguments"), devicectl = directory.appendingPathComponent("devicectl")
        try """
            #!/bin/sh
            printf '%s\\n' "$*" >> "\(log.path)"
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
        // Each window reads once, after its guest has started, so the read may not have begun when the window shows.
        var reads = 0
        func readOrientation(_ controller: DeviceWindowController) async throws {
            reads += 1
            try await wait {
                !controller.session.isBusy
                    && (try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n").count == reads
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
        try await readOrientation(reopened)
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
        try await readOrientation(moved)
        #expect(movedWindow.contentLayoutRect.width == landscape.width)
        #expect(abs(movedWindow.frame.minX - topLeft.x) < 1 && abs(movedWindow.frame.maxY - topLeft.y) < 1)
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
        try await readOrientation(rescaled)
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
        #expect(guestDisplay.rotations == [90])
        try await readOrientation(guestRotated)
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
        let controller = try makeController(display, features: [DeviceCapabilities.keyboard],
            simctl: URL(fileURLWithPath: "/usr/bin/false"), devicectl: URL(fileURLWithPath: "/usr/bin/false"),
            keyboardCaptureTap: TestKeyboardEventTap(), presentCompactWindow: { _ in })
        defer { controller.invalidate() }
        controller.showCompactWindow()
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
        #expect(window.styleMask.contains(.resizable))
        #expect(display.renderScale == 1)
        #expect(window.frame == windowed)
        controller.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification, object: window))
        controller.windowDidFailToEnterFullScreen(window)
        #expect(window.styleMask.contains(.resizable))
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
        #expect(window.styleMask.contains(.resizable))
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
        controller.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification, object: window))
        window.setFrame(NSRect(x: 100, y: 100, width: 300, height: 300), display: true)
        controller.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: window))
        #expect(isSizedToDisplay(), "full screen left")
        await controller.prepareForRestart()
        display = makeDisplay()
        controller.reconnect(try makeSession(display))
        #expect(isSizedToDisplay(), "restart")
    }

    @Test(arguments: [false, true])
    func compactWindowResizesAtItsFrameWithDeviceBezels(native: Bool) throws {
        let display = TestDisplay()
        display.usesNativeCanvas = native
        display.naturalSize = NSSize(width: 400, height: 600)
        display.bezel = NSSize(width: 20, height: 20)
        display.bezelPadding = NSSize(width: 9, height: 0)
        let controller = try makeController(display)
        defer { controller.invalidate() }
        controller.showWindow(nil)
        let window = try #require(controller.window)
        #expect(window.styleMask.contains(.resizable))
        #expect(!display.showsResizeCursors)
        let content = controller.presentationViewController.view
        content.needsLayout = true
        content.layoutSubtreeIfNeeded()
        let naturalSize = display.naturalSize
        let initialScale = display.renderScale
        let start = window.frame
        controller.windowWillStartLiveResize(Notification(name: NSWindow.willStartLiveResizeNotification, object: window))
        window.setFrame(NSRect(origin: start.origin, size: NSSize(width: 500, height: 450)), display: true)
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        controller.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: window))
        #expect(window.frame.size != start.size)
        #expect(display.naturalSize == naturalSize && !display.isResizing)
        #expect(display.renderScale < initialScale)
        let scale = display.renderScale
        try drag(window, from: try point(of: .lowerRight, in: display), by: NSSize(width: 30, height: -55)) {
            #expect(!display.isResizing && display.renderScale == scale)
        }
        controller.setDeviceBezelVisible(false)
        controller.setDeviceBezelVisible(true)
        #expect(window.styleMask.contains(.resizable) && !display.showsResizeCursors)
    }

    @Test(arguments: [false, true])
    func embeddedDeviceCornersResizeOnlyTheCanvas(native: Bool) throws {
        let display = TestDisplay()
        display.deviceInsets = NSEdgeInsets(top: 11, left: 9, bottom: 7, right: 13)
        display.usesNativeCanvas = native
        display.naturalSize = NSSize(width: 400, height: 600)
        // Integral display dimensions keep the synthesized pointer movement on the pixel grid.
        display.bezel = NSSize(width: 80, height: 40)
        display.bezelPadding = NSSize(width: 9, height: 0)
        let controller = try makeController(display, presentCompactWindow: { _ in })
        defer { controller.invalidate() }
        controller.showWindow(nil)
        let compactFrame = try #require(controller.window?.frame)
        let compactScale = display.renderScale
        let parent = NSViewController()
        parent.view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 656))
        let window = KeyPresentationWindow(contentRect: parent.view.frame, styleMask: [.titled, .resizable],
                                           backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = parent
        defer { window.close() }
        controller.embed(in: parent)
        parent.view.layoutSubtreeIfNeeded()
        let mainFrame = window.frame
        let content = controller.presentationViewController.view
        let scroll = try #require(content.subviews.compactMap { $0 as? NSScrollView }.first)
        display.deviceFrameReadCount = 0
        content.layout()
        #expect(display.deviceFrameReadCount == 1)
        if !native {
            let frame = display.deviceFrame
            let button = TestButton(frame: NSRect(x: frame.maxX + 1, y: frame.maxY - 26, width: 8, height: 8))
            display.view.addSubview(button)
            let point = display.view.convert(NSPoint(x: button.frame.midX, y: button.frame.midY), to: nil)
            try #require(press(window, at: point) === button)
        }
        for corner in [DisplayResizeCorner.lowerLeft, .lowerRight, .upperRight, .upperLeft] {
            controller.performCanvasZoom(.fit)
            let scale = controller.canvasZoom.scale
            let handle = try #require(content.subviews.first {
                $0.identifier?.rawValue == "DeviceCanvasResize.\(corner.rawValue)"
            })
            func cornerPoint() -> NSPoint {
                if native {
                    return handle.convert(NSPoint(x: handle.bounds.midX + (corner.isLeft ? -4 : 4),
                                                   y: handle.bounds.midY + (corner.isLower ? -4 : 4)), to: nil)
                }
                let frame = display.deviceFrame
                return display.view.convert(NSPoint(x: corner.isLeft ? frame.minX + 4 : frame.maxX - 4,
                                                     y: corner.isLower ? frame.minY + 4 : frame.maxY - 4), to: nil)
            }
            func checkHandleFrame() {
                let frame = display.view.convert(display.deviceFrame, to: content)
                let center = NSPoint(x: corner.isLeft ? frame.minX : frame.maxX,
                                     y: corner.isLower ? frame.minY : frame.maxY)
                #expect(abs(handle.frame.midX - center.x) < 1 && abs(handle.frame.midY - center.y) < 1)
                #expect(handle.frame.width >= 44 && handle.frame.height >= 44)
            }
            checkHandleFrame()
            let frame = display.view.convert(display.deviceFrame, to: content)
            for point in [
                NSPoint(x: corner.isLeft ? frame.minX - 4 : frame.maxX + 4,
                        y: corner.isLower ? frame.minY : frame.maxY),
                NSPoint(x: corner.isLeft ? frame.minX : frame.maxX,
                        y: corner.isLower ? frame.minY - 4 : frame.maxY + 4),
            ] {
                #expect(window.contentView?.superview?.hitTest(content.convert(point, to: nil)) === handle)
            }
            display.input.frame = display.view.bounds
            let guest = display.framebufferFrame
            if !native {
                let artwork = display.deviceFrame
                let edge = NSPoint(x: corner.isLeft ? (artwork.minX + guest.minX) / 2 : (artwork.maxX + guest.maxX) / 2,
                                   y: corner.isLower ? guest.minY + 1 : guest.maxY - 1)
                #expect(try press(window, at: display.view.convert(edge, to: nil)) === display.input)
            }
            let guestCorner = NSPoint(x: corner.isLeft ? guest.minX + 1 : guest.maxX - 1,
                                      y: corner.isLower ? guest.minY + 1 : guest.maxY - 1)
            let pressCount = display.input.presses.count
            #expect(try press(window, at: display.view.convert(guestCorner, to: nil)) === display.input)
            #expect(display.input.presses.count == pressCount + 1)
            let start = cornerPoint()
            let hit = try press(window, at: start)
            #expect(hit === handle)
            let size = display.view.convert(display.view.bounds, to: content).size
            var end = NSPoint(x: start.x + (corner.isLeft ? -size.width : size.width) / 8,
                              y: start.y + (corner.isLower ? -size.height : size.height) / 8)
            func event(_ type: NSEvent.EventType) throws -> NSEvent {
                try #require(NSEvent.mouseEvent(with: type, location: end, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            }
            hit.mouseDragged(with: try event(.leftMouseDragged))
            #expect(display.isResizing)
            #expect(WindowScale.matches(controller.canvasZoom.scale, scale * 1.25))
            checkHandleFrame()
            #expect(WindowScale.matches(scroll.magnification, controller.canvasZoom.scale))
            #expect(display.renderScale == 1 && display.naturalSize == NSSize(width: 400, height: 600))
            #expect(window.frame == mainFrame && controller.window?.frame == compactFrame)
            end = NSPoint(x: start.x + (corner.isLeft ? size.width : -size.width) / 8,
                          y: start.y + (corner.isLower ? size.height : -size.height) / 8)
            hit.mouseDragged(with: try event(.leftMouseDragged))
            #expect(WindowScale.matches(controller.canvasZoom.scale, scale * 0.75))
            end = NSPoint(x: start.x + (corner.isLeft ? -size.width : size.width) / 8, y: start.y)
            hit.mouseDragged(with: try event(.leftMouseDragged))
            #expect(controller.canvasZoom.scale > scale)
            hit.mouseUp(with: try event(.leftMouseUp))
            #expect(!display.isResizing)
        }
        controller.setDeviceBezelVisible(false)
        controller.performCanvasZoom(.fit)
        display.input.frame = display.view.bounds
        for corner in [DisplayResizeCorner.lowerLeft, .lowerRight, .upperRight, .upperLeft] {
            let bounds = display.view.bounds
            let point = NSPoint(x: corner.isLeft ? bounds.minX + 4 : bounds.maxX - 4,
                                y: corner.isLower ? bounds.minY + 4 : bounds.maxY - 4)
            let count = display.input.presses.count
            #expect(try press(window, at: display.view.convert(point, to: nil)) === display.input)
            #expect(display.input.presses.count == count + 1)
        }
        controller.setDeviceBezelVisible(true)
        controller.performCanvasZoom(.fit)
        let handle = try #require(content.subviews.first { $0.identifier?.rawValue == "DeviceCanvasResize.lowerRight" })
        let start = handle.convert(NSPoint(x: handle.bounds.midX + 4, y: handle.bounds.midY - 4), to: nil)
        _ = try press(window, at: start)
        #expect(display.isResizing)
        controller.showCompactWindow()
        #expect(!display.isResizing && display.renderScale == compactScale)
        #expect(controller.window?.frame == compactFrame)
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
        #expect(window.styleMask.contains(.resizable))
        #expect(!shown.showsResizeCursors)
        #expect(shown.view.frame.size == NSSize(width: 220, height: 320))
    }

    @Test func guestInterfaceOrientationsUseSimulatorKitAngles() {
        #expect([1, 2, 3, 4, 0].map(SimScreenUIOrientation.displayAngle) == [0, 180, -90, 90, 0])
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

    @Test func aReleaseNotYetDeliveredIsSentAgainWhenTheWindowCloses() async throws {
        let display = TestDisplay()
        display.deferCompletions = true
        let controller = try makeController(display)
        controller.session.send(.hold(.button(.actionStaccato), for: .milliseconds(10))) { _ in }
        for _ in 0..<300 where display.events.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        controller.invalidate()
        #expect(display.events.map(\.state) == [.down, .up, .up])
    }
}
