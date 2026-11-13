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
            ["captureKeyboard", "home", "saveScreen", "rotateRight"])
        let home = try #require(commands.first { $0.itemIdentifier.rawValue == "home" })
        #expect(NSApp.sendAction(try #require(home.action), to: home.target, from: home))
        #expect(display.buttons == [.home])
        #expect(controller.session.reserve())
        try await wait {
            commands.filter { ["saveScreen", "rotateRight"].contains($0.itemIdentifier.rawValue) }
                .allSatisfy { !$0.isEnabled }
        }
        #expect(home.isEnabled)
        controller.session.disconnect()
        try await wait { commands.allSatisfy { !$0.isEnabled } }
    }

    @Test func toolbarItemChangesStayInTheirOwnDeviceWindow() throws {
        let controller = try makeController(TestDisplay())
        defer { controller.invalidate() }
        let other = try makeController(TestDisplay(), device: "other-device")
        defer { other.invalidate() }
        controller.showWindow(nil)
        other.showWindow(nil)
        let toolbar = try #require(controller.window?.toolbar)
        let otherToolbar = try #require(other.window?.toolbar)
        let otherItems = otherToolbar.items.map(\.itemIdentifier)
        controller.onShowInMainWindow = {}
        #expect(toolbar.items.first?.itemIdentifier == .flexibleSpace)
        #expect(toolbar.items.dropFirst().first?.itemIdentifier.rawValue == "ShowInMainWindow")
        let window = try #require(controller.window)
        window.setContentSize(NSSize(width: 300, height: 600))
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        #expect(window.titleVisibility == .visible && window.toolbarStyle == .unified)
        #expect(otherToolbar.items.map(\.itemIdentifier) == otherItems)
    }

    @Test func displayStaysBelowTheNativeToolbarWhenResized() throws {
        let controller = try makeController(TestDisplay())
        defer { controller.invalidate() }
        let window = try #require(controller.window)
        for size in [NSSize(width: 360, height: 780), NSSize(width: 800, height: 420)] {
            window.setContentSize(size)
            controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
            let content = try #require(window.contentView)
            let display = controller.display
            let frame = display.view.convert(display.view.bounds, to: content)
            #expect(frame.minX >= 0)
            #expect(frame.minY >= 0)
            #expect(frame.maxX <= content.bounds.maxX)
            #expect(frame.maxY <= window.contentLayoutRect.maxY)
            #expect(display.view.frame.size == display.size(for: display.renderScale))
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

    @Test func eachFamilysToolbarHasSimulatorAppsButtons() throws {
        func items(_ family: DeviceCapabilities.Family, _ features: Set<String>) throws -> [DeviceCommand.ID] {
            let controller = try makeController(TestDisplay(), family: family, features: features)
            defer { controller.invalidate() }
            return try #require(controller.window?.toolbar).items.compactMap {
                DeviceCommand.ID(rawValue: $0.itemIdentifier.rawValue)
            }
        }
        // Matches IndigoWatchToolbar, IndigoTVToolbar, and IndigoWatchAODToolbar.
        #expect(try items(.watch, [DeviceCapabilities.keyboard]) == [.captureKeyboard, .home, .saveScreen])
        #expect(try items(.tv, [DeviceCapabilities.keyboard]) == [.captureKeyboard, .home, .saveScreen])
        #expect(try items(.watch, [DeviceCapabilities.alwaysOnDisplay]) == [.home, .saveScreen, .alwaysOn])
        #expect(try items(.iPhone, [DeviceCapabilities.alwaysOnDisplay, DeviceCapabilities.displayRotation])
            == [.home, .saveScreen, .rotateRight])
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
        let commands = ["Restart", "Shut Down", "-", "Erase All Content and Settings…", "-", "Home", "Re-Center Open Apps"]
        #expect(try visible("Device", .watch) == commands + ["Lock", "Side Button"])
        #expect(try visible("Device", .tv) == commands)
        #expect(try visible("Device", .vision) == commands + [
            "-", "Interaction Mode", "Look Around Mode", "Pan Mode", "Orbit Mode", "Dolly Mode", "-", "Reset Camera", "-",
            "Simulated Scenes",
        ])
        #expect(try !visible("Window", .vision).contains("Show Device Bezels"))
        #expect(try visible("Window", .watch).contains("Show Device Bezels"))
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
        #expect(gaze.action == #selector(PluginOverlay.toggleShowGazeTarget(_:)) && gaze.target == nil)
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
            == [.captureKeyboard, .home, .saveScreen, .rotateRight])
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

        display.naturalSize = NSSize(width: 200, height: 400)
        let controls = DeviceCanvasControls()
        controller.canvasControls = controls
        controls.update(supports: { _ in true }, isEnabled: { _ in true }, recordingTitle: "Record Screen")
        controller.perform(.pointAccurate)
        let content = try #require(window.contentView)
        let displayFrame = display.view.convert(display.view.bounds, to: content)
        let controlsFrame = controls.convert(controls.bounds, to: content)
        let occupiedHeight = window.frame.height - displayFrame.height
        #expect(occupiedHeight > header + controls.bounds.height)
        #expect(displayFrame.minY >= controlsFrame.maxY)
        display.naturalSize = NSSize(width: 200, height: visible.height - occupiedHeight)
        #expect(controller.canSetScale(.pointAccurate))
        display.naturalSize.height += 1
        #expect(!controller.canSetScale(.pointAccurate))
        display.naturalSize = NSSize(width: visible.width - 16, height: 200)
        #expect(controller.canSetScale(.pointAccurate))
        display.naturalSize.width += 1
        #expect(!controller.canSetScale(.pointAccurate))
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
        #expect(try visibleTitles("Device") == ["Restart", "Shut Down", "-", "Erase All Content and Settings…", "-",
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

    @Test func featureCommandsChangeTheGuestState() async throws {
        let display = TestDisplay()
        let controller = try makeController(display, features: [DeviceCapabilities.faceID, DeviceCapabilities.standBy])
        defer { controller.invalidate() }
        let session = controller.session
        controller.perform(.faceIDEnrolled)
        for _ in 0..<300 where controller.session.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        #expect(session.isBiometricEnrolled)
        controller.perform(.faceIDMatching)
        for _ in 0..<300 where controller.session.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        controller.perform(.faceIDNonMatching)
        for _ in 0..<300 where controller.session.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        controller.perform(.touchIDMatching)
        for _ in 0..<300 where controller.session.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        controller.perform(.faceIDEnrolled)
        for _ in 0..<300 where controller.session.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!session.isBiometricEnrolled)
        controller.perform(.toggleStandBy)
        for _ in 0..<300 where controller.session.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        #expect(DeviceCommand.command(.toggleStandBy).stateTitle?(controller) == "Hide StandBy")
        controller.perform(.toggleInCallStatusBar)
        for _ in 0..<300 where controller.session.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        controller.perform(.shake)
        for _ in 0..<300 where controller.session.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        #expect(display.postedNotifications == [
            "com.apple.BiometricKit.enrollmentChanged", "com.apple.BiometricKit_Sim.pearl.match",
            "com.apple.BiometricKit_Sim.pearl.nomatch", "com.apple.BiometricKit.enrollmentChanged",
            "com.apple.springboard.ambient.presentation", "com.apple.iphonesimulator.toggleincallstatusbar",
            "com.apple.UIKit.SimulatorShake",
        ])

        display.contentSize = 11
        try await session.changeTextSize(by: 1)
        try await session.changeTextSize(by: 1)
        #expect(display.contentSize == 12)
        try await session.changeTextSize(by: -1)
        #expect(display.contentSize == 11)
        display.contentSize = 0
        await #expect(throws: (any Error).self) { try await session.changeTextSize(by: -1) }
        #expect(display.contentSize == 0)

        try await session.toggleIncreaseContrast()
        #expect(display.contrastMode == 2)
        try await session.toggleIncreaseContrast()
        #expect(display.contrastMode == 1)
        display.contrastMode = 0
        await #expect(throws: (any Error).self) { try await session.toggleIncreaseContrast() }
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

    @Test func validatingAMenuAsksTheDeviceNothingAndOpeningOneReadsItOnceWithoutWaiting() async throws {
        let display = TestDisplay()
        let worker = HeldDeviceWorker()
        defer { worker.release() }
        let model = standaloneDeviceModel()
        let controller = try makeController(display, features: [DeviceCapabilities.faceID, DeviceCapabilities.standBy], model: model)
        defer { controller.invalidate() }
        display.worker = worker
        worker.hold()
        let enrolled = NSMenuItem()
        for _ in 0..<10 {
            #expect(DeviceCommand.command(.faceIDEnrolled).validate(enrolled, for: controller))
            #expect(enrolled.state == .off)
            #expect(DeviceCommand.command(.toggleStandBy).stateTitle?(controller) == "Show StandBy")
            #expect(DeviceCommand.command(.colorBlendedLayers).state?(controller) == .off)
        }
        #expect(display.guestStateReads == 0)

        // However many menus open while a read is held, one read runs and one more follows it.
        display.notificationStates["com.apple.BiometricKit.enrollmentChanged"] = 1
        var changes = 0
        for _ in 0..<5 { controller.session.refreshGuestState { changes += 1 } }
        #expect(display.guestStateReads == 1)
        #expect(model.isBiometricEnrolled == nil)
        worker.release()
        try await wait { display.guestStateReads == 2 && changes == 5 }
        #expect(model.isBiometricEnrolled == true && model.showsStandBy == false)
        #expect(controller.session.isBiometricEnrolled)
        _ = DeviceCommand.command(.faceIDEnrolled).validate(enrolled, for: controller)
        #expect(enrolled.state == .on)
    }

    @Test func commandsAndInspectorShareTheStateOfTheirDevice() async throws {
        let device = InventoryDevice.simulator(SimulatorHostDevice(identifier: "test-device", name: "Test iPhone", descriptiveName: "Test iPhone",
            runtimeIdentifier: "runtime", runtimeName: "iOS", productFamily: "iPhone", state: "Booted"))
        let source = ManagerModelSource(devices: [device])
        var events = source.events.makeAsyncIterator()
        let registry = DeviceRegistry(source: source)
        try await registry.refresh()
        let model = try #require(registry.device(for: device.id))
        let inspected = model.keepCurrent(.settings)
        defer { inspected.release() }
        #expect(await events.next() == .read(device.id))
        await source.completeRead(SimulatorDeviceSettings(appearance: .light))
        await registry.finishReading()

        let display = TestDisplay()
        let controller = try makeController(display, features: [DeviceCapabilities.faceID], model: model)
        defer { controller.invalidate() }
        #expect(controller.session.model === model)

        // What a command changes, the inspector reads again.
        try await controller.session.toggleAppearance()
        #expect(display.appearanceToggles == 1)
        #expect(await events.next() == .read(device.id))
        await source.completeRead(SimulatorDeviceSettings(appearance: .dark))
        await registry.finishReading()
        #expect(model.settings.appearance == .dark)

        // What the inspector refreshes, the session reads again, and its commands answer from the same state.
        display.notificationStates["com.apple.BiometricKit.enrollmentChanged"] = 1
        model.revalidate(.commandState)
        try await wait { model.isBiometricEnrolled == true }
        #expect(controller.session.isBiometricEnrolled)
        #expect(await source.readCount == 2)
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
}
