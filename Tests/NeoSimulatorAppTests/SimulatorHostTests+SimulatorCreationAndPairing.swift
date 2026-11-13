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
    @Test func nativeCanvasRecreatesInputSurfacesWhenReturningToAWindow() throws {
        final class Creations { var count = 0 }
        final class InputView: NSView {
            override var acceptsFirstResponder: Bool { true }
        }
        struct Content: NSViewRepresentable {
            let creations: Creations
            init(_ creations: Creations) { self.creations = creations }
            func makeNSView(context: Context) -> NSView {
                creations.count += 1
                return InputView(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
            }
            func updateNSView(_ nsView: NSView, context: Context) {}
        }
        let creations = Creations()
        let host = NativeCanvasHostingView(rootView: AnyView(Content(creations)))
        let window = KeyPresentationWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 500),
                                           styleMask: .titled, backing: .buffered, defer: false)
        let other = KeyPresentationWindow(contentRect: window.frame, styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        other.isReleasedWhenClosed = false
        defer { window.close(); other.close() }
        window.contentView = host
        _ = host.fittingSize
        host.layoutSubtreeIfNeeded()
        let initial = creations.count
        #expect(initial > 0)
        window.contentView = NSView()
        window.contentView = host
        // The controller focuses input immediately on reattachment, before another layout pass.
        let input = host.inputView { $0 is InputView }
        #expect(input is InputView)
        #expect(window.makeFirstResponder(input) && window.firstResponder === input)
        #expect(creations.count > initial)
        let returned = creations.count
        other.contentView = host
        let moved = host.inputView { $0 is InputView }
        #expect(moved !== input && moved is InputView)
        #expect(other.makeFirstResponder(moved) && other.firstResponder === moved)
        #expect(creations.count > returned)
    }

    @Test func pairedCanvasContentChangesTheMainAccessorySafeArea() throws {
        _ = NSApplication.shared
        let split = NSSplitViewController()
        let pane = NSViewController()
        pane.view = NSView()
        let viewport = NSView()
        viewport.translatesAutoresizingMaskIntoConstraints = false
        pane.view.addSubview(viewport)
        NSLayoutConstraint.activate([
            viewport.leadingAnchor.constraint(equalTo: pane.view.safeAreaLayoutGuide.leadingAnchor),
            viewport.trailingAnchor.constraint(equalTo: pane.view.safeAreaLayoutGuide.trailingAnchor),
            viewport.topAnchor.constraint(equalTo: pane.view.safeAreaLayoutGuide.topAnchor),
            viewport.bottomAnchor.constraint(equalTo: pane.view.safeAreaLayoutGuide.bottomAnchor),
        ])
        let item = NSSplitViewItem(viewController: pane)
        let accessory = DeviceCanvasAccessoryViewController()
        accessory.onMinimumWidthChange = { item.minimumThickness = max(280, $0) }
        item.addBottomAlignedAccessoryViewController(accessory)
        split.addSplitViewItem(item)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = split
        defer { window.close() }
        let controls = DeviceCanvasControls()
        controls.update(supports: { $0 == "home" }, isEnabled: { _ in true }, recordingTitle: "Record Screen")
        accessory.setControls(controls)
        window.setContentSize(NSSize(width: 500, height: 700))
        split.view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let unpairedHeight = controls.fittingSize.height
        let actionBarWidth = controls.fittingSize.width
        let unpairedSpace = viewport.frame.height
        try #require(unpairedSpace > 0)
        #expect(abs(viewport.frame.minY - controls.fittingSize.height - 8) < 1)
        controls.update(supports: { $0 == "home" }, isEnabled: { _ in true }, recordingTitle: "Record Screen",
                        pairedDeviceName: "Companion Watch")
        accessory.refresh()
        window.setContentSize(NSSize(width: 500, height: 700))
        split.view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        #expect(controls.fittingSize.height > unpairedHeight)
        #expect(viewport.frame.height < unpairedSpace)
        #expect(!viewport.frame.intersects(accessory.view.convert(accessory.view.bounds, to: pane.view)))
        #expect(controls.bounds.height + 1 >= controls.fittingSize.height)
        let pairedMinimumWidth = controls.fittingSize.width
        #expect(controls.bounds.width > actionBarWidth)
        controls.update(supports: { $0 == "home" }, isEnabled: { _ in true }, recordingTitle: "Record Screen",
                        pairedDeviceName: String(repeating: "A long companion name ", count: 50))
        accessory.refresh()
        window.setContentSize(NSSize(width: 500, height: 700))
        split.view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        #expect(controls.fittingSize.width <= pairedMinimumWidth + 1)
        #expect(controls.bounds.width + 1 >= actionBarWidth)
        #expect(item.minimumThickness <= pane.view.bounds.width)
        #expect(viewport.frame.width > 0 && controls.bounds.height + 1 >= controls.fittingSize.height)
        controls.update(supports: { $0 == "home" }, isEnabled: { _ in true }, recordingTitle: "Record Screen")
        accessory.refresh()
        window.setContentSize(NSSize(width: 500, height: 700))
        split.view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        #expect(controls.fittingSize.height == unpairedHeight)
        #expect(abs(viewport.frame.height - unpairedSpace) < 1)
    }

    @Test(arguments: [false, true]) func pairedCanvasContentKeepsTheCompactDisplayInsideItsViewport(native: Bool) throws {
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
        let identifier = DeviceInventoryID.simulator(udid: controller.session.device.identifier,
                                                     deviceSetPath: controller.session.device.deviceSetPath)
        let screen = screens.attach(controller, as: identifier)
        let controls = screen.canvasControls
        controls.update(supports: { ["home", "capture", "record"].contains($0) },
                        isEnabled: { _ in true }, recordingTitle: "Record Screen")
        controller.showCompactWindow()
        let canvas = controller.presentationViewController.view
        let viewport = try #require(canvas.layoutGuides.first { $0.identifier.rawValue == "DeviceCanvasViewport" })
        let window = try #require(controller.presentationWindow)
        let compactRoot = try #require(window.contentView)
        window.contentView?.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: window.contentView!.bounds.width + 120,
                                     height: window.contentView!.bounds.height + 80))
        window.contentView?.layoutSubtreeIfNeeded()
        let manualSize = window.frame.size
        let manualScale = display.renderScale
        controls.update(supports: { ["home", "capture", "record"].contains($0) },
                        isEnabled: { _ in true }, recordingTitle: "Record Screen")
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(window.frame.size == manualSize)
        #expect(display.renderScale == manualScale)
        let unpairedHeight = controls.fittingSize.height
        let unpairedSpace = viewport.frame.size
        let unpairedScale = display.renderScale
        let unpairedWindowSize = window.frame.size
        controls.update(supports: { ["home", "capture", "record"].contains($0) },
                        isEnabled: { _ in true }, recordingTitle: "Record Screen", pairedDeviceName: "Companion Watch")
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(controls.fittingSize.height > unpairedHeight)
        #expect(controls.bounds.height + 1 >= controls.fittingSize.height)
        if native {
            #expect(viewport.frame.height < unpairedSpace.height)
        } else {
            #expect(display.renderScale == unpairedScale)
            #expect(window.frame.height > unpairedWindowSize.height)
        }
        let controlsRect = controls.convert(controls.bounds, to: nil)
        #expect(abs(canvas.convert(viewport.frame, to: nil).minY - controlsRect.maxY) < 1)
        #expect(abs(canvas.convert(viewport.frame, to: nil).minX - controlsRect.minX) < 1)
        #expect(window.contentView!.bounds.insetBy(dx: -1, dy: -1).contains(controlsRect))
        #expect(!canvas.convert(viewport.frame, to: nil).intersects(controlsRect))
        #expect(canvas.convert(viewport.frame, to: nil).insetBy(dx: -1, dy: -1).contains(display.view.convert(display.view.bounds, to: nil)))
        controls.update(supports: { ["home", "capture", "record"].contains($0) },
                        isEnabled: { _ in true }, recordingTitle: "Record Screen")
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(controls.fittingSize.height == unpairedHeight)
        #expect(abs(viewport.frame.height - unpairedSpace.height) < 1)

        controls.update(supports: { ["home", "capture", "record"].contains($0) },
                        isEnabled: { _ in true }, recordingTitle: "Record Screen", pairedDeviceName: "Companion Watch")
        let manager = ManagerWindowController(model: model, screens: screens, menus: MenuController(application: nil))
        let mainWindow = try #require(manager.window)
        mainWindow.setFrameAutosaveName("")
        defer { mainWindow.close() }
        mainWindow.setContentSize(NSSize(width: 1040, height: 700))
        mainWindow.contentView?.layoutSubtreeIfNeeded()
        let pane = manager.deviceScreenViewController
        controller.embed(in: pane.liveScreenContainer)
        pane.showLiveScreen(screen)
        mainWindow.setContentSize(NSSize(width: 1040, height: 650))
        mainWindow.contentView?.layoutSubtreeIfNeeded()
        mainWindow.displayIfNeeded()
        #expect(window.contentView === compactRoot && !canvas.isDescendant(of: compactRoot))
        #expect(controls.superview !== canvas && controls.window === mainWindow)
        #expect(abs(canvas.convert(viewport.frame, to: nil).minY - controls.convert(controls.bounds, to: nil).maxY) < 1)
        #expect(viewport.frame.height > canvas.bounds.height - controls.bounds.height)
        #expect(display.renderScale > 0)
        #expect(canvas.convert(viewport.frame, to: nil).insetBy(dx: -1, dy: -1).contains(display.view.convert(display.view.bounds, to: nil)))

        controller.showCompactWindow()
        pane.showDevicePreview(ifDisplaying: identifier)
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(window.contentView === compactRoot && canvas.superview === compactRoot)
        #expect(canvas.frame == compactRoot.bounds)
        #expect(controls.superview === canvas && controls.window === window)
        #expect(viewport.frame.height > 0 && display.renderScale > 0)
        #expect(canvas.convert(viewport.frame, to: nil).insetBy(dx: -1, dy: -1).contains(display.view.convert(display.view.bounds, to: nil)))
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
            == ["Restart", "Shut Down", "-", "Erase All Content and Settings…", "-", "Home", "Re-Center Open Apps", "Lock",
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

    @Test func newSimulatorKeepsDeviceTypeAndRuntimeCompatible() async throws {
        let catalog = SimulatorCatalog(
            deviceTypes: [.init(identifier: "a", name: "iPhone A", productFamily: 1),
                          .init(identifier: "b", name: "iPhone B", productFamily: 1),
                          .init(identifier: "x", name: "iPhone X", productFamily: 1),
                          .init(identifier: "c", name: "iPad C", productFamily: 2)],
            runtimes: [.init(identifier: "old", name: "iOS 26.0"), .init(identifier: "new", name: "iOS 27.0"),
                       .init(identifier: "empty", name: "iOS 28.0")],
            supportedDeviceTypes: ["old": ["b"], "new": ["a", "c"]], canPair: { _, _, _, _ in true })
        @MainActor final class Creation {
            var requests: [[String]] = []
            var failure: Error?
        }
        let creation = Creation()
        let model = NewSimulatorModel(catalog: catalog, create: { name, type, runtime in
            if let failure = creation.failure { throw failure }
            creation.requests.append([name, type, runtime])
            return "device"
        }, pair: { _, _ in Issue.record("paired without a watch") })
        #expect(model.deviceTypes.map(\.identifier) == ["a", "b", "x"])
        #expect(model.runtimes.map(\.identifier) == ["old", "new"])
        #expect(model.deviceType == "b" && model.runtime == "old")
        model.selectCategory(.iPad)
        #expect(model.deviceTypes.map(\.identifier) == ["c"] && model.runtime == "new")
        model.selectCategory(.iPhone)
        model.selectDeviceType("x")
        #expect(model.runtime == nil && !model.canProceed)
        model.selectDeviceType("a")
        #expect(model.runtime == "new" && model.canProceed)
        model.selectRuntime("old")
        #expect(model.deviceType == "b")
        creation.failure = SimulatorError.operation("creation failed")
        model.forward()
        await model.waitForCreation()
        #expect(model.error == "creation failed" && creation.requests.isEmpty && model.canProceed)
        creation.failure = nil
        model.forward()
        await model.waitForCreation()
        #expect(creation.requests == [["iPhone B", "b", "old"]] && model.error == nil)
    }

    @Test func newSimulatorRuntimeNamesPreserveBuildSelection() async throws {
        let beta = SimulatorCatalog.Runtime(identifier: "beta", name: "iOS 27.0", buildVersion: "beta-build")
        let candidate = SimulatorCatalog.Runtime(identifier: "candidate", name: "iOS 27.0", buildVersion: "candidate-build")
        let source = SimulatorCatalog(
            deviceTypes: [.init(identifier: "phone", name: "iPhone", productFamily: 1)],
            runtimes: [beta, candidate],
            supportedDeviceTypes: [beta.identifier: ["phone"], candidate.identifier: ["phone"]],
            canPair: { _, _, _, _ in false })
        let snapshot = try JSONDecoder().decode(SimulatorCatalog.Snapshot.self,
                                                 from: JSONEncoder().encode(snapshot(of: source)))
        let catalog = snapshot.catalog()
        var createdRuntime: String?
        let model = NewSimulatorModel(catalog: catalog, create: { _, _, runtime in
            createdRuntime = runtime
            return "created-device"
        }, pair: { _, _ in Issue.record("Paired without a watch") })
        #expect(model.runtimes.map(\.identifier) == [beta.identifier, candidate.identifier])
        await model.loadRuntimeNames { throw URLError(.notConnectedToInternet) }
        #expect(model.runtimeName(beta) == "iOS 27.0 (beta-build)")
        let metadata = try PropertyListSerialization.data(fromPropertyList: [
            "downloadables": [
                ["name": "iOS 27.0 beta 2 Simulator Runtime", "simulatorVersion": ["buildUpdate": "beta-build"]],
                ["name": "Unrelated Download"],
            ],
            "otherDownloadables": [
                ["name": "iOS 27.0 Release Candidate Simulator Runtime", "simulatorVersion": ["buildUpdate": "candidate-build"]],
            ],
        ], format: .xml, options: 0)
        await model.loadRuntimeNames { metadata }
        #expect(model.runtimeName(beta) == "iOS 27.0 beta 2 (beta-build)")
        #expect(model.runtimeName(candidate) == "iOS 27.0 Release Candidate (candidate-build)")
        #expect(model.runtime == beta.identifier)
        model.selectRuntime(candidate.identifier)
        model.forward()
        await model.waitForCreation()
        #expect(createdRuntime == candidate.identifier)
    }

    @Test func newSimulatorSeparatesIPhoneDuoFromSameVersionRuntimes() async {
        var created: [String] = []
        let model = NewSimulatorModel(catalog: Duo.catalog(), create: { _, type, runtime in
            created = [type, runtime]
            return "device"
        }, pair: { _, _ in Issue.record("Paired without a watch") })
        #expect(model.categories.map(\.name) == ["iPhone", "iPhone Duo", "iPad", "Apple Watch"])
        #expect(model.category == .iPhone && model.deviceTypes.map(\.identifier) == [Duo.phone])
        #expect(model.runtimes.map(\.identifier) == [Duo.ios270, Duo.ios272])

        model.selectCategory(.iPhoneDuo)
        #expect(model.deviceTypes.map(\.identifier) == [Duo.duo])
        #expect(model.runtimes.map(\.identifier) == [Duo.ios271, Duo.ios272Duo])
        #expect(model.deviceType == Duo.duo && model.runtime == Duo.ios271)
        #expect(model.canAddWatch)

        model.selectRuntime(Duo.ios272Duo)
        model.forward()
        await model.waitForCreation()
        #expect(created == [Duo.duo, Duo.ios272Duo])
    }

    @Test func newSimulatorRemembersIPhoneAndDuoSelectionsIndependently() throws {
        let domain = "NeoSimulator.DuoCreationChoices.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        func makeForm() -> NewSimulatorModel {
            NewSimulatorModel(catalog: Duo.catalog(), create: { _, _, _ in "" }, pair: { _, _ in },
                              preferences: SimulatorPreferences(defaults: defaults, creationDefaults: defaults))
        }
        let first = makeForm()
        first.selectRuntime(Duo.ios270)
        first.selectCategory(.iPhoneDuo)
        first.selectRuntime(Duo.ios272Duo)

        let reopened = makeForm()
        #expect(reopened.category == .iPhoneDuo)
        #expect(reopened.deviceType == Duo.duo && reopened.runtime == Duo.ios272Duo)
        reopened.selectCategory(.iPhone)
        #expect(reopened.deviceType == Duo.phone && reopened.runtime == Duo.ios270)
        reopened.selectCategory(.iPhoneDuo)
        #expect(reopened.deviceType == Duo.duo && reopened.runtime == Duo.ios272Duo)

        let refreshed = makeForm()
        refreshed.selectCategory(.iPad)
        refreshed.restoreInput(from: reopened)
        #expect(refreshed.category == .iPhoneDuo && refreshed.runtime == Duo.ios272Duo)

        let companion = NewSimulatorModel(catalog: Duo.catalog(), pairingWith: .init(
            identifier: "watch", name: "Watch", productFamily: "Apple Watch", deviceType: Duo.watch, runtime: Duo.watchOS),
            create: { _, _, _ in "" }, pair: { _, _ in },
            preferences: SimulatorPreferences(defaults: defaults, creationDefaults: defaults))
        #expect(companion.deviceType == Duo.phone && companion.runtime == Duo.ios270)
    }

    @Test func newIPhoneForAWatchListsDuoWithOnlyItsOwnRuntimes() {
        let model = NewSimulatorModel(catalog: Duo.catalog(), pairingWith: .init(
            identifier: "watch", name: "Watch", productFamily: "Apple Watch", deviceType: Duo.watch, runtime: Duo.watchOS),
            create: { _, _, _ in "" }, pair: { _, _ in })
        #expect(model.deviceTypes.map(\.identifier) == [Duo.duo, Duo.phone])
        model.selectDeviceType(Duo.phone)
        #expect(model.runtimes.map(\.identifier) == [Duo.ios270, Duo.ios272] && model.runtime == Duo.ios270)
        model.selectDeviceType(Duo.duo)
        #expect(model.runtimes.map(\.identifier) == [Duo.ios271, Duo.ios272Duo] && model.runtime == Duo.ios271)
        #expect(model.canProceed)
    }

    @Test func newSimulatorWithoutRuntimesCannotCreate() {
        let model = NewSimulatorModel(
            catalog: SimulatorCatalog(deviceTypes: [.init(identifier: "a", name: "iPhone A", productFamily: 1)],
                                      runtimes: [], supportedDeviceTypes: [:], canPair: { _, _, _, _ in true }),
            create: { _, _, _ in Issue.record("created without a runtime"); return "" },
            pair: { _, _ in Issue.record("paired without a runtime") })
        #expect(model.runtimes.isEmpty && !model.canProceed)
    }

    @Test func newSimulatorReportsFailureAfterItsWindowCloses() async throws {
        var reported: String?
        let model = NewSimulatorModel(catalog: pairingCatalog(), create: { _, _, _ in
            throw SimulatorError.operation("Creation failed after closing")
        }, pair: { _, _ in })
        var controller: NewSimulatorWindowController? = NewSimulatorWindowController(model: model, reportFailure: {
            reported = $0.localizedDescription
        })
        controller?.window?.layoutIfNeeded()
        let content = try #require(controller?.window?.contentLayoutRect)
        let preferred = try #require(controller?.form.preferredContentSize)
        #expect(content.width >= preferred.width && content.height >= preferred.height)
        model.forward()
        controller?.close()
        controller = nil
        await model.waitForCreation()
        #expect(reported == "Creation failed after closing")
    }

    @Test func newSimulatorOffersAPairedWatchOnlyForAnIPhone() throws {
        let data = try JSONEncoder().encode(snapshot(of: pairingCatalog()))
        let catalog = try JSONDecoder().decode(SimulatorCatalog.Snapshot.self, from: data).catalog()
        let model = NewSimulatorModel(catalog: catalog, create: { _, _, _ in "" }, pair: { _, _ in })
        #expect(model.canAddWatch && !model.addsWatch && model.forwardTitle == "Create")
        model.setAddsWatch(true)
        #expect(model.forwardTitle == "Next")
        model.selectCategory(.iPad)
        #expect(!model.canAddWatch && !model.addsWatch && model.forwardTitle == "Create")
        model.selectCategory(.iPhone)
        #expect(model.canAddWatch && !model.addsWatch)
        model.setAddsWatch(true)
        model.setAddsWatch(false)
        #expect(model.forwardTitle == "Create")
    }

    @Test func newSimulatorRemembersChoicesWithoutNamesOrPairing() throws {
        let domain = "NeoSimulator.CreationChoices.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let base = pairingCatalog()
        let catalog = SimulatorCatalog(
            deviceTypes: base.deviceTypes + [.init(identifier: "second-pad", name: "iPad B", productFamily: 2)],
            runtimes: base.runtimes + [.init(identifier: "next-ios", name: "Next iOS")],
            supportedDeviceTypes: base.supportedDeviceTypes.merging([
                "ios": ["phone", "incompatible-phone", "pad", "second-pad"],
                "next-ios": ["phone", "incompatible-phone", "pad", "second-pad"],
            ]) { $1 },
            canPair: base.canPair)
        func makeForm(_ catalog: SimulatorCatalog) -> NewSimulatorModel {
            NewSimulatorModel(catalog: catalog, create: { _, _, _ in "" }, pair: { _, _ in },
                              preferences: SimulatorPreferences(defaults: defaults, creationDefaults: defaults))
        }
        let first = makeForm(catalog)
        first.name = "My iPhone"
        first.watchName = "My Watch"
        first.selectDeviceType("incompatible-phone")
        first.selectRuntime("next-ios")
        first.selectWatchType("w2")
        first.selectWatchRuntime("new")
        first.setAddsWatch(true)

        let reopened = makeForm(catalog)
        #expect(reopened.deviceType == "incompatible-phone" && reopened.runtime == "next-ios")
        #expect(reopened.watchType == "w2" && reopened.watchRuntime == "new")
        #expect(reopened.name.isEmpty && reopened.watchName.isEmpty && !reopened.addsWatch)

        first.selectCategory(.iPad)
        first.selectDeviceType("second-pad")
        first.selectRuntime("next-ios")
        let companion = NewSimulatorModel(catalog: catalog, pairingWith: .init(
            identifier: "watch", name: "Watch", productFamily: "Apple Watch", deviceType: "w1", runtime: "new"),
            create: { _, _, _ in "" }, pair: { _, _ in },
            preferences: SimulatorPreferences(defaults: defaults, creationDefaults: defaults))
        companion.selectDeviceType("phone")
        companion.selectRuntime("ios")
        let afterCompanion = makeForm(catalog)
        #expect(afterCompanion.category == .iPad && afterCompanion.deviceType == "second-pad")
        #expect(afterCompanion.runtime == "next-ios")
        afterCompanion.selectCategory(.iPhone)
        #expect(afterCompanion.deviceType == "phone" && afterCompanion.runtime == "ios")

        afterCompanion.selectCategory(.appleWatch)
        afterCompanion.selectDeviceType("w3")
        let refreshedWatch = makeForm(catalog)
        refreshedWatch.restoreInput(from: afterCompanion)
        let reopenedWatch = makeForm(catalog)
        #expect(reopenedWatch.deviceType == "w3" && reopenedWatch.runtime == "old")

        afterCompanion.selectCategory(.iPhone)
        afterCompanion.selectDeviceType("incompatible-phone")
        afterCompanion.selectRuntime("next-ios")
        let changedCatalog = SimulatorCatalog(
            deviceTypes: [
                .init(identifier: "phone", name: "iPhone", productFamily: 1),
                .init(identifier: "incompatible-phone", name: "New iPhone", productFamily: 1),
                .init(identifier: "w2", name: "New Watch", productFamily: 4),
                .init(identifier: "w3", name: "Watch", productFamily: 4),
            ],
            runtimes: [.init(identifier: "ios", name: "iOS"), .init(identifier: "old", name: "watchOS")],
            supportedDeviceTypes: ["ios": ["phone"], "old": ["w3"]], canPair: { _, _, _, _ in false })
        let fallback = makeForm(changedCatalog)
        fallback.restoreInput(from: afterCompanion)
        #expect(fallback.deviceType == "phone" && fallback.runtime == "ios" && fallback.canProceed)
        #expect(fallback.watchType == "w3" && fallback.watchRuntime == "old")
        let availableAgain = makeForm(catalog)
        #expect(availableAgain.deviceType == "incompatible-phone" && availableAgain.runtime == "next-ios")
    }

    @Test func newSimulatorWatchPageKeepsTheWatchCompatibleAndPairable() {
        let pairings = PairingChecks()
        let model = NewSimulatorModel(catalog: pairingCatalog(pairings), create: { _, _, _ in "" }, pair: { _, _ in })
        model.setAddsWatch(true)
        model.forward()
        #expect(model.showsWatchPage && model.forwardTitle == "Create")
        #expect(model.watchType == "w3" && model.watchRuntime == "old" && !model.canProceed)
        model.selectWatchRuntime("new")
        #expect(model.watchType == "w1" && model.canProceed)
        model.selectWatchType("w3")
        #expect(model.availableWatchRuntimes.map(\.identifier) == ["old"] && !model.canProceed)
        model.selectWatchType("w2")
        #expect(model.availableWatchRuntimes.map(\.identifier) == ["new"] && !model.canProceed)
        model.selectWatchType("w1")
        #expect(model.canProceed)
        model.selectWatchType("unavailable-watch")
        #expect(model.availableWatchRuntimes.isEmpty && !model.canProceed)
        model.selectWatchType("w1")
        #expect(model.canProceed)
        model.previous()
        #expect(!model.showsWatchPage && model.forwardTitle == "Next")
        model.name = "My iPhone"
        model.watchName = "My Watch"
        model.forward()
        let refreshed = NewSimulatorModel(catalog: pairingCatalog(), create: { _, _, _ in "" }, pair: { _, _ in })
        refreshed.restoreInput(from: model)
        #expect(refreshed.name == "My iPhone" && refreshed.watchName == "My Watch")
        #expect(refreshed.deviceType == "phone" && refreshed.runtime == "ios")
        #expect(refreshed.watchType == "w1" && refreshed.watchRuntime == "new")
        #expect(refreshed.showsWatchPage && refreshed.addsWatch && refreshed.canProceed)
    }

    @Test func newSimulatorCreatesAndPairsTheWatchAndKeepsTheDevicesOnFailure() async {
        @MainActor final class Failures { var watch: Error?, pair: Error? }
        let failures = Failures()
        var operations: [String] = []
        let model = NewSimulatorModel(catalog: pairingCatalog(), create: { name, type, runtime in
            if type.hasPrefix("w"), let failure = failures.watch { throw failure }
            operations.append("create \(name) \(type) \(runtime)")
            return type == "phone" ? "phone-\(operations.count)" : "watch-\(operations.count)"
        }, pair: { watch, phone in
            if let failure = failures.pair { throw failure }
            operations.append("pair \(watch) \(phone)")
        })
        model.setAddsWatch(true)
        model.forward()
        model.selectWatchRuntime("new")
        failures.pair = SimulatorError.operation("pairing failed")
        model.forward()
        await model.waitForCreation()
        #expect(model.error == "Created “iPhone A” and “Apple Watch One”, but could not pair them: pairing failed")
        #expect(operations == ["create iPhone A phone ios", "create Apple Watch One w1 new"])
        operations.removeAll()
        failures.watch = SimulatorError.operation("watch failed")
        model.forward()
        await model.waitForCreation()
        #expect(model.error == "Created “iPhone A”, but could not create its paired Apple Watch: watch failed")
        #expect(operations == ["create iPhone A phone ios"])
        operations.removeAll()
        failures.watch = nil
        failures.pair = nil
        model.watchName = "My Watch"
        model.forward()
        await model.waitForCreation()
        #expect(operations == ["create iPhone A phone ios", "create My Watch w1 new", "pair watch-2 phone-1"])
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true], ["iPhone", "Apple Watch"])
    func newCompanionCreatesOnlyTheOppositeDeviceAndRetainsItsIdentifierWhenPairingFails(
        pairingFails: Bool, existingFamily: String
    ) async throws {
        let createsPhone = existingFamily == "Apple Watch"
        let createdName = createsPhone ? "My iPhone" : "My Watch"
        let createdID = createsPhone ? "created-phone" : "created-watch"
        var operations: [String] = []
        let model = NewSimulatorModel(catalog: pairingCatalog(), pairingWith:
            .init(identifier: createsPhone ? "existing-watch" : "existing-phone",
                  name: createsPhone ? "Existing Watch" : "Existing Phone", productFamily: existingFamily,
                  deviceType: createsPhone ? "w1" : "phone", runtime: createsPhone ? "new" : "ios"),
            create: { name, type, runtime in operations.append("create \(name) \(type) \(runtime)"); return createdID },
            pair: { watch, phone in
                operations.append("pair \(watch) \(phone)")
                if pairingFails { throw SimulatorError.operation("pairing failed") }
            })
        #expect(model.showsWatchPage == !createsPhone)
        if createsPhone {
            #expect(model.deviceTypes.map(\.identifier) == ["phone"])
            model.name = createdName
        } else {
            #expect(model.watchTypes.map(\.identifier) == ["w1"])
            model.watchName = createdName
        }
        model.forward()
        await model.waitForCreation()
        #expect(operations == [
            createsPhone ? "create My iPhone phone ios" : "create My Watch w1 new",
            createsPhone ? "pair existing-watch created-phone" : "pair created-watch existing-phone",
        ])
        if pairingFails {
            #expect(model.error == "Created “\(createdName)” (\(createdID)), but could not pair it with “\(createsPhone ? "Existing Watch" : "Existing Phone")”: pairing failed")
        } else { #expect(model.error == nil) }
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
        display.deliveryError = SimulatorError.operation("delivery failed")
        var failures: [Error] = []
        controller.session.send(.watchGesture(.doubleTap)) { failures.append($0) }
        #expect(failures.count == 1)
        let other = TestDisplay()
        let otherController = try makeController(other, family: .watch, features: [], device: "other")
        defer { otherController.invalidate() }
        otherController.perform(.doubleTap)
        #expect(other.gestures.isEmpty)
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

    @Test func aHoldCreatesItsReleaseWhenItEnds() async throws {
        let display = TestDisplay()
        let controller = try makeController(display)
        defer { controller.invalidate() }
        controller.session.send(.hold(.button(.actionStaccato), for: .milliseconds(50))) { _ in }
        for _ in 0..<300 where display.events.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(display.created.map(\.state) == [.down, .up])
        #expect(display.created[1].at - display.created[0].at >= .milliseconds(50))
    }
}
