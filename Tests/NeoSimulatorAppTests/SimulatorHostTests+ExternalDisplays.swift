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
    @Test func captureTargetsTheKeyExternalDisplayAndReleasesItsKeys() throws {
        _ = NSApplication.shared
        let tap = TestKeyboardEventTap()
        let screen = TestExternalScreen()
        screen.current.isPoweredOn = true
        let (controller, primary) = try makeExternalDisplayController(screen, keyboardCaptureTap: tap,
            applicationIsActive: { true }, makeWindow: {
                KeyPresentationWindow(contentRect: $0, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                      backing: .buffered, defer: false)
            })
        defer { controller.invalidate() }
        let external = try #require(controller.externalDisplayWindow)
        let window = try #require(external.window)
        let display = try #require(screen.displays.last)
        external.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
        #expect(DeviceWindowController.deviceWindow(for: window) === controller)
        let command = DeviceCommand.command(.captureKeyboard)
        #expect(command.isEnabled(controller))
        controller.perform(.captureKeyboard)
        try #require(controller.capturesKeyboard && tap.starts == 1)
        #expect(command.state?(controller) == .on)
        #expect(try tap.key(.keyDown, code: 0))
        #expect(display.input.keyDowns.map(\.keyCode) == [0])
        #expect(primary.input.keyDowns.isEmpty)
        controller.perform(.captureKeyboard)
        #expect(!controller.capturesKeyboard && tap.stops == 1)
        #expect(command.state?(controller) == .off)
        #expect(display.input.keyUps.map(\.keyCode) == [0])
        controller.perform(.captureKeyboard)
        #expect(try tap.key(.keyDown, code: 1))
        screen.report { $0.isPoweredOn = false }
        #expect(controller.externalDisplayWindow == nil)
        #expect(!controller.capturesKeyboard && tap.stops == 2)
        #expect(display.input.keyUps.map(\.keyCode) == [0, 1])
        #expect(primary.input.keyUps.isEmpty)
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

    @Test func aDisabledChoiceThatWasNotSentIsAppliedOnceWhenTheDeviceAnswersAgain() async throws {
        let preferences = MemoryPreferences()
        let screen = TestExternalScreen()
        screen.current = ExternalScreenState(isPoweredOn: true, pixelSize: CGSize(width: 1280, height: 720), scale: 1)
        var failures: [String] = []
        let session = try await recoverExternalDisplay(screen, preferences: preferences) { session in
            session.chooseExternalDisplay(.disabled) { failures.append($0.localizedDescription) }
            try await wait { failures.count == 1 }
            #expect(screen.requests.isEmpty)
        }
        defer { session.disconnect() }
        let notSent = DeviceOperationFailure.notSent(operation: "turn off the external display", heldBy: "hold the device")
        #expect(failures == ["Could not turn off the external display of Test iPhone: \(notSent.localizedDescription)"])
        #expect(preferences.externalDisplayTag(forDevice: "test-device") == ExternalDisplayMode.disabled.rawValue)
        #expect(screen.requests == ["off"])
        #expect(!screen.current.isPoweredOn)
    }

    @Test func aModeChoiceThatWasNotSentIsAppliedOnceWhenTheDeviceAnswersAgain() async throws {
        let screen = TestExternalScreen()
        var failures: [String] = []
        let session = try await recoverExternalDisplay(screen) { session in
            session.chooseExternalDisplay(.size1280x720) { failures.append($0.localizedDescription) }
            try await wait { failures.count == 1 }
        }
        defer { session.disconnect() }
        #expect(screen.requests.filter { $0.hasPrefix("mode") }.count == 1)
        #expect(screen.current.isPoweredOn && screen.current.pixelSize == CGSize(width: 1280, height: 720))
    }

    @Test func recoveryLeavesADisplayWithNoSavedChoiceAlone() async throws {
        let preferences = MemoryPreferences()
        // A device can have a record of other preferences and still no choice.
        preferences.set(["test-device": ["WindowScale": 2]], forKey: HostPreferences.devicePreferences)
        let screen = TestExternalScreen()
        // Another tool turned it on.
        screen.current = ExternalScreenState(isPoweredOn: true, pixelSize: CGSize(width: 1280, height: 720), scale: 1)
        let session = try await recoverExternalDisplay(screen, preferences: preferences) { _ in }
        defer { session.disconnect() }
        #expect(screen.requests.isEmpty)
        #expect(screen.current.isPoweredOn)
        #expect(preferences.externalDisplayTag(forDevice: "test-device") == nil)
    }

    @Test func recoveryAppliesADisabledChoiceThatAnEarlierSessionSaved() async throws {
        let preferences = MemoryPreferences()
        preferences.setExternalDisplayTag(ExternalDisplayMode.disabled.rawValue, forDevice: "test-device")
        let screen = TestExternalScreen()
        let session = try await recoverExternalDisplay(screen, preferences: preferences) { _ in
            #expect(screen.requests.isEmpty)
            // Another tool turns it on while the device does not answer.
            screen.report { $0 = ExternalScreenState(isPoweredOn: true, pixelSize: CGSize(width: 1280, height: 720), scale: 1) }
        }
        defer { session.disconnect() }
        #expect(screen.requests == ["off"])
        #expect(!screen.current.isPoweredOn)
    }

    @Test func recoveryDoesNotApplyASavedCarPlayTheDeviceCannotShow() async throws {
        let preferences = MemoryPreferences()
        preferences.setExternalDisplayTag(ExternalDisplayMode.carPlay.rawValue, forDevice: "test-device")
        let screen = TestExternalScreen()
        let session = try await recoverExternalDisplay(screen, preferences: preferences) { _ in }
        defer { session.disconnect() }
        #expect(screen.requests.isEmpty)
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

    @Test(arguments: [false, true])
    func pendingExternalDisplayDoesNotOpenAfterPowerOffOrClosingTheDevice(_ closesDevice: Bool) async throws {
        let screen = TestExternalScreen()
        var resume: CheckedContinuation<Void, Never>?
        var preparations = 0
        screen.prepareDisplay = {
            preparations += 1
            await withCheckedContinuation { resume = $0 }
        }
        let (controller, _) = try makeExternalDisplayController(screen)
        defer { controller.invalidate() }
        controller.perform(.externalDisplay1280x720)
        let pending = try #require(resume)
        screen.report { $0.pixelSize = CGSize(width: 1920, height: 1080) }
        #expect(preparations == 1 && controller.externalDisplayWindow == nil)
        if closesDevice { controller.invalidate() }
        else { controller.perform(.externalDisplayDisabled) }
        screen.prepareDisplay = nil
        pending.resume()
        try await wait { screen.displays.first?.stopCount == 1 }
        #expect(screen.displays.count == 1 && controller.externalDisplayWindow == nil)
        if !closesDevice {
            controller.perform(.externalDisplay1280x720)
            try await wait { controller.externalDisplayWindow != nil }
            #expect(screen.displays.count == 2)
        }
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
        screen.completionError = SimulatorError.operation("power failed")
        try #require(controller.externalDisplayWindow?.window).close()
        #expect(controller.externalDisplayWindow != nil)
    }

    @Test func aChangeOfADeviceThatShutDownDoesNotHoldItsNextSession() async throws {
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
        try await wait { !changes.isBusy }
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

    @Test(arguments: [ExternalDisplayMode.size1920x1080, .disabled])
    func aScreenRequestThatExpiresBehindAnotherCallIsWithdrawn(mode: ExternalDisplayMode) async throws {
        let worker = HeldDeviceWorker()
        defer { worker.release() }
        let holding = try await holdWithAnotherCall(worker)
        let screen = TestExternalScreen()
        screen.worker = worker
        let changes = ExternalDisplayChanges(completionTimeout: .milliseconds(50), carPlayReconnectionDelay: .zero)
        var failures: [ExternalDisplayFailure] = []
        changes.apply(mode, through: screen, savesCarPlayConfiguration: false) { failures += $0 }
        // The choice after it waits for it, and then expires behind the same call.
        changes.apply(.size640x480, through: screen, savesCarPlayConfiguration: false) { failures += $0 }
        try await wait { !changes.isBusy }
        #expect(failures.map(\.step) == [.screen, .screen])
        #expect(await worker.channel.unresolvedOperations().map(\.state) == [.running])

        try await finishCall(holding, on: worker)
        #expect(worker.calls == ["another call", "last call"])
        #expect(screen.requests.isEmpty)
    }

    /// The screen's request is answered at once, so the session's is made inside the screen's task, which ends first.
    @Test func aCarPlaySessionRequestThatExpiresBehindAnotherCallIsWithdrawn() async throws {
        let worker = HeldDeviceWorker()
        defer { worker.release() }
        let holding = try await holdWithAnotherCall(worker)
        let screen = TestExternalScreen()
        screen.carPlayWorker = worker
        let changes = ExternalDisplayChanges(completionTimeout: .milliseconds(50), carPlayReconnectionDelay: .zero)
        var failures: [ExternalDisplayFailure] = []
        changes.apply(.carPlay, through: screen, savesCarPlayConfiguration: true) { failures += $0 }
        try await wait { !changes.isBusy }
        #expect(failures.map(\.step) == [.carPlaySession(starting: true)])

        try await finishCall(holding, on: worker)
        #expect(worker.calls == ["another call", "last call"])
        #expect(screen.requests == ["save carplay", "mode 800x480@2 carplay"])
        #expect(screen.carPlaySessions == 0)
        changes.apply(.carPlay, through: screen, savesCarPlayConfiguration: true) { Issue.record("\($0)") }
        try await wait { !changes.isBusy }
        #expect(screen.carPlaySessions == 1)
        #expect(screen.requests.suffix(2) == ["start carplay", "connect service"])
    }

    @Test func aCarPlayServiceRequestThatExpiresBehindAnotherCallIsWithdrawn() async throws {
        let screen = TestExternalScreen()
        let changes = ExternalDisplayChanges(completionTimeout: .milliseconds(50), carPlayReconnectionDelay: .zero)
        changes.apply(.carPlay, through: screen, savesCarPlayConfiguration: true) { Issue.record("\($0)") }
        #expect(screen.requests == ["save carplay", "mode 800x480@2 carplay", "start carplay", "connect service"])

        let worker = HeldDeviceWorker()
        defer { worker.release() }
        let holding = try await holdWithAnotherCall(worker)
        screen.carPlayWorker = worker
        var failures: [ExternalDisplayFailure] = []
        changes.apply(.disabled, through: screen, savesCarPlayConfiguration: true) { failures += $0 }
        try await wait { !changes.isBusy }
        #expect(failures.map(\.step) == [.carPlayService(creating: false)])

        try await finishCall(holding, on: worker)
        #expect(worker.calls == ["another call", "last call"])
        #expect(Array(screen.requests.dropFirst(4)) == ["save off", "off"])
    }

    /// The request is on the worker, where stopping waiting for it stops nothing. It runs once and may still complete,
    /// and neither the change's failure nor what comes after says that it was not sent.
    @Test func aRequestAlreadyRunningWhenItsChangeExpiresGoesOnWithAnUnknownOutcome() async throws {
        let worker = HeldDeviceWorker()
        defer { worker.release() }
        worker.hold()
        let screen = TestExternalScreen()
        screen.worker = worker
        screen.defersChanges = true
        let changes = ExternalDisplayChanges(completionTimeout: .milliseconds(500), carPlayReconnectionDelay: .zero)
        var failures: [ExternalDisplayFailure] = []
        changes.apply(.size1920x1080, through: screen, savesCarPlayConfiguration: false) { failures += $0 }
        try await wait { worker.calls == ["set the external display's mode"] }
        try await wait { !changes.isBusy }
        #expect(failures.map(\.error.localizedDescription) == ["CoreSimulator did not complete the change."])
        #expect(await worker.channel.unresolvedOperations().map(\.state) == [.running])

        worker.release()
        try await worker.call("last call")
        #expect(worker.calls == ["set the external display's mode", "last call"])
        #expect(screen.requests == ["mode 1920x1080@1"])
        screen.deliver()
        #expect(!changes.isBusy && failures.count == 1)
    }

    @Test func aRequestAbandonedWithItsSessionIsWithdrawnBeforeTheNextSessionsChangeRuns() async throws {
        let worker = HeldDeviceWorker()
        defer { worker.release() }
        let holding = try await holdWithAnotherCall(worker)
        let ended = TestExternalScreen(), next = TestExternalScreen()
        ended.worker = worker
        next.worker = worker
        let changes = ExternalDisplayChanges(carPlayReconnectionDelay: .zero)
        changes.apply(.size1920x1080, through: ended, savesCarPlayConfiguration: false) { Issue.record("\($0)") }
        changes.abandon(changesThrough: ended)
        changes.apply(.size640x480, through: next, savesCarPlayConfiguration: false) { Issue.record("\($0)") }

        try await finishCall(holding, on: worker)
        try await wait { !changes.isBusy }
        #expect(worker.calls == ["another call", "set the external display's mode", "last call"])
        #expect(ended.requests.isEmpty && next.requests == ["mode 640x480@1"])
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
        // A saved Disabled is a choice like the others.
        preferences.setExternalDisplayTag(ExternalDisplayMode.disabled.rawValue, forDevice: "test-device")
        let on = TestExternalScreen()
        on.current = ExternalScreenState(isPoweredOn: true, pixelSize: CGSize(width: 1920, height: 1080), scale: 1)
        let (second, _) = try makeExternalDisplayController(on, preferences: preferences)
        #expect(on.requests == ["off"] && second.externalDisplayWindow == nil)
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

    @Test func connectingLeavesADisplayWithNoSavedChoiceOrAnUnknownOneAlone() throws {
        let preferences = MemoryPreferences()
        let on = TestExternalScreen()
        on.current = ExternalScreenState(isPoweredOn: true, pixelSize: CGSize(width: 1920, height: 1080), scale: 1)
        let (first, _) = try makeExternalDisplayController(on, preferences: preferences)
        #expect(on.requests.isEmpty && first.externalDisplayWindow != nil)
        first.invalidate()
        #expect(preferences.externalDisplayTag(forDevice: "test-device") == nil)

        preferences.setExternalDisplayTag(1234, forDevice: "test-device")
        let stillOn = TestExternalScreen()
        stillOn.current = on.current
        stillOn.current.isPoweredOn = true
        let (second, _) = try makeExternalDisplayController(stillOn, preferences: preferences)
        defer { second.invalidate() }
        #expect(stillOn.requests.isEmpty && second.externalDisplayWindow != nil)
        #expect(preferences.externalDisplayTag(forDevice: "test-device") == 1234)
    }

    @Test func aDisabledChoiceThatWasNotSentIsAppliedByTheNextSession() throws {
        let preferences = MemoryPreferences()
        let screen = TestExternalScreen()
        screen.current = ExternalScreenState(isPoweredOn: true, pixelSize: CGSize(width: 1920, height: 1080), scale: 1)
        let (first, _) = try makeExternalDisplayController(screen, preferences: preferences)
        var failures: [String] = []
        screen.refusal = DeviceOperationFailure.notSent(operation: "turn off the external display", heldBy: "hold the device")
        first.session.chooseExternalDisplay(.disabled) { failures.append($0.localizedDescription) }
        #expect(failures.count == 1 && screen.requests.isEmpty)
        first.invalidate()

        let next = TestExternalScreen()
        next.current = ExternalScreenState(isPoweredOn: true, pixelSize: CGSize(width: 1920, height: 1080), scale: 1)
        let (second, _) = try makeExternalDisplayController(next, preferences: preferences)
        defer { second.invalidate() }
        #expect(next.requests == ["off"] && second.externalDisplayWindow == nil)
    }

    @Test func aSavedDisabledChoiceAsksForNothingUnlessADisplayIsOn() throws {
        let preferences = MemoryPreferences()
        preferences.setExternalDisplayTag(ExternalDisplayMode.disabled.rawValue, forDevice: "test-device")
        let adapterless = TestDisplay()
        adapterless.hasScreenAdapter = false
        let missing = try makeController(adapterless, features: Self.externalDisplayFeatures, preferences: preferences)
        defer { missing.invalidate() }
        missing.session.connectExternalDisplay { Issue.record($0) }

        // Not even the guest's CarPlay configuration is rewritten.
        let off = TestExternalScreen()
        let (alreadyOff, _) = try makeExternalDisplayController(off, features: Self.carPlayFeatures, preferences: preferences)
        defer { alreadyOff.invalidate() }
        #expect(off.requests.isEmpty)

        let (late, display) = try makeExternalDisplayController(nil, preferences: preferences)
        defer { late.invalidate() }
        let on = TestExternalScreen()
        on.current = ExternalScreenState(isPoweredOn: true, pixelSize: CGSize(width: 1920, height: 1080), scale: 1)
        display.connectExternalScreen(on)
        display.deliverScreenReports()
        #expect(on.requests == ["off"] && late.externalDisplayWindow == nil)
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
        screen.refusal = SimulatorError.operation("no mode")
        choose(.size640x480, on: controller)
        screen.refusal = nil
        screen.completionError = SimulatorError.operation("mode failed")
        choose(.size640x480, on: controller)
        #expect(Array(failures.dropFirst()) == [
            "Could not set the external display of Test iPhone to 640×480: no mode",
            "Could not set the external display of Test iPhone to 640×480: mode failed",
        ])
        #expect(controller.externalDisplayWindow == nil)
        screen.completionError = nil
        choose(.size640x480, on: controller)
        screen.completionError = SimulatorError.operation("power failed")
        choose(.disabled, on: controller)
        #expect(failures.last == "Could not turn off the external display of Test iPhone: power failed")
        #expect(controller.externalDisplayWindow != nil)
        var restored: [String] = []
        let failing = TestExternalScreen()
        failing.completionError = SimulatorError.operation("restore failed")
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
        display.externalScreenError = SimulatorError.operation("no proxy")
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
        screen.completionError = SimulatorError.operation("mode failed")
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
        screen.completionError = SimulatorError.operation("mode failed")
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
        let waiting = Task { result.idle = await changes.idle(before: .now + .seconds(60)) }
        screen.deliver()
        try await wait { screen.requests == ["mode 1920x1080@1", "off"] }
        #expect(result.idle == nil)
        screen.deliver()
        await waiting.value
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
}
