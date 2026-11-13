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
    @Test func aRequestWithAnUnknownOutcomeLeavesCarPlayStateUnknownAndItsLateCompletionAdvancesNothing() async throws {
        let unknown = DeviceOperationFailure.outcomeUnknown(operation: "request", cause: .timedOut(.seconds(10)))
        let changes = ExternalDisplayChanges(carPlayReconnectionDelay: .zero)
        let screen = TestExternalScreen()
        let (controller, _) = try makeExternalDisplayController(screen, features: Self.carPlayFeatures,
                                                                preferences: MemoryPreferences(), externalDisplayChanges: changes)
        defer { controller.invalidate() }
        var failures: [String] = []
        let report: @MainActor (any Error) -> Void = { failures.append($0.localizedDescription) }

        // The mode may have changed, and the channel's own answer ended the step; the native completion comes later.
        screen.defersChanges = true
        screen.unknownOutcome = unknown
        controller.session.chooseExternalDisplay(.size1920x1080, failure: report)
        #expect(failures == ["Could not set the external display of Test iPhone to \(ExternalDisplayMode.size1920x1080.title): \(unknown.localizedDescription)"])
        #expect(!changes.isBusy)
        screen.deliverCompletions()
        screen.unknownOutcome = nil
        screen.defersChanges = false
        #expect(!changes.isBusy)

        // A session request that may have reached the guest is not followed by another in this boot.
        failures = []
        screen.carPlayErrors["start carplay"] = unknown
        controller.session.chooseExternalDisplay(.carPlay, failure: report)
        #expect(failures.count == 1)
        screen.carPlayErrors = [:]
        let sent = screen.requests.count
        controller.session.chooseExternalDisplay(.disabled, failure: report)
        #expect(!screen.requests.dropFirst(sent).contains("stop carplay"))
    }

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
        screen.completionError = SimulatorError.operation("Invalid argument")
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
        screen.carPlayErrors = ["stop carplay": SimulatorError.operation("busy")]
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
        screen.carPlayErrors = ["save carplay": SimulatorError.operation("disk full")]
        choose(.carPlay)
        #expect(screen.requests == ["save carplay", "mode 800x480@2 carplay", "start carplay", "connect service"])
        #expect(failures == ["Could not save the CarPlay configuration of Test iPhone: disk full"])
        screen.carPlayErrors = ["remove service": SimulatorError.operation("no port"),
                                "stop carplay": SimulatorError.operation("no bridge")]
        choose(.size1280x720)
        #expect(screen.requests.suffix(4) == ["save off", "remove service", "stop carplay", "mode 1280x720@1"])
        #expect(failures.last == """
            Could not disconnect the CarPlay touch screen of Test iPhone: no port
            Could not stop CarPlay on Test iPhone: no bridge
            """)
        screen.carPlayErrors = [:]
        choose(.size640x480)
        #expect(screen.requests.suffix(4) == ["save off", "remove service", "stop carplay", "mode 640x480@1"])
        screen.carPlayErrors = ["start carplay": SimulatorError.operation("no CarPlay")]
        var count = screen.requests.count
        choose(.carPlay)
        #expect(Array(screen.requests.dropFirst(count))
            == ["save carplay", "off", "mode 800x480@2 carplay", "start carplay"])
        #expect(failures.last == "Could not start CarPlay on Test iPhone: no CarPlay")
        screen.carPlayErrors = ["connect service": SimulatorError.operation("send failed")]
        count = screen.requests.count
        choose(.carPlay)
        #expect(Array(screen.requests.dropFirst(count))
            == ["save carplay", "mode 800x480@2 carplay", "start carplay", "connect service"])
        #expect(failures.last == "Could not connect the CarPlay touch screen of Test iPhone: send failed")
        screen.carPlayErrors = [:]
        screen.completionError = SimulatorError.operation("mode failed")
        count = screen.requests.count
        choose(.carPlay)
        #expect(Array(screen.requests.dropFirst(count)) == [
            "save carplay", "remove service", "stop carplay", "mode 800x480@2 carplay",
        ])
        #expect(failures.last == "Could not set the external display of Test iPhone to CarPlay: mode failed")
        screen.completionError = nil
        controller.showWindow(nil)
        screen.carPlayErrors = ["save carplay": SimulatorError.operation("disk full"),
                                "start carplay": SimulatorError.operation("no CarPlay")]
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
}
