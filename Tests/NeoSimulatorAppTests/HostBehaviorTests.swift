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
        #expect(preferences.externalDisplayTag(forDevice: "A") == nil)
        preferences.set(["A": ["WindowScale": 2]], forKey: HostPreferences.devicePreferences)
        #expect(preferences.externalDisplayTag(forDevice: "A") == nil)
        preferences.set(["A": ["SimulatorExternalDisplay": "2614"]], forKey: HostPreferences.devicePreferences)
        #expect(preferences.externalDisplayTag(forDevice: "A") == nil)
        preferences.set(["A": ["SimulatorExternalDisplay": 2114]], forKey: HostPreferences.devicePreferences)
        #expect(preferences.externalDisplayTag(forDevice: "A") == 2114)
        preferences.set(["A": ["SimulatorExternalDisplay": 2714]], forKey: HostPreferences.devicePreferences)
        #expect(preferences.externalDisplayTag(forDevice: "A") == 2714)
        preferences.setExternalDisplayTag(2614, forDevice: "B")
        #expect(preferences.externalDisplayTag(forDevice: "A") == 2714)
        #expect(preferences.externalDisplayTag(forDevice: "B") == 2614)

        // The same through UserDefaults' own conversions.
        let defaults = RegisteredDefaults()
        #expect(defaults.externalDisplayTag(forDevice: "A") == nil)
        defaults.setExternalDisplayTag(ExternalDisplayMode.disabled.rawValue, forDevice: "A")
        #expect(defaults.externalDisplayTag(forDevice: "A") == 2114)
    }

    @Test(arguments: [false, true])
    func launchConflictIsRetainedBeforeDeferredTeardown(_ ownsCompanion: Bool) throws {
        let center = NotificationCenter()
        let url = URL(filePath: "/Xcode.app/Contents/Applications/DeviceHub.app")
        let monitor = HostConflictMonitor(
            notificationCenter: center,
            allowsDeviceHub: { pid, bundleURL in
                ownsCompanion && pid == 101 && bundleURL == url
            })
        var teardownCalled = false
        monitor.onConflict = { teardownCalled = true }
        center.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil,
            userInfo: [
                NSWorkspace.applicationUserInfoKey: FixtureRunningApplication(processIdentifier: 101, bundleURL: url)
            ])

        if ownsCompanion {
            try monitor.check()
            center.post(
                name: NSWorkspace.didLaunchApplicationNotification, object: nil,
                userInfo: [
                    NSWorkspace.applicationUserInfoKey: FixtureRunningApplication(
                        processIdentifier: 102, bundleURL: url)
                ])
        }

        #expect(monitor.conflictingHostName == "Device Hub")
        #expect(throws: SimulatorError.self) { try monitor.check() }
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
        #expect(throws: SimulatorError.self) { try monitor.check() }
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
        source.failure = SimulatorError.operation("Boot failed")
        await model.open(device)?.value
        #expect(model.errorMessage == "Boot failed")
        #expect(model.opening.isEmpty)
        source.devices = []
        model.refresh()
        #expect(model.devices.isEmpty)
    }

    @Test func browserShowsWhatTheSetsLastReportedUntilAReloadAnswers() async throws {
        let source = TestCatalog()
        let model = DeviceBrowserModel(source: source)
        let shown = model.devices
        source.reloadFailure = DeviceOperationFailure.notSent(operation: "read the device set", heldBy: "read the device set")
        await model.reload()?.value
        #expect(model.devices.map(\.identity) == shown.map(\.identity))
        #expect(model.errorMessage?.contains("has not returned") == true)
        source.reloadFailure = nil
        source.reloadedDevices = []
        // Showing what was last reported reads nothing.
        model.refresh()
        #expect(model.devices.map(\.identity) == shown.map(\.identity))
        await model.reload()?.value
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
                throw SimulatorError.operation("Capture failed")
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

    @Test func nativeBindingValidationRequiresExplicitRuntimeValidation() throws {
        let xcode = ["--xcode", "/Xcode.app"]
        let plain = try HostLaunchOptions(arguments: xcode + ["--validate-runtime"])
        #expect(plain.validatesRuntime && !plain.includesNativeBindings)
        let included = try HostLaunchOptions(arguments: xcode + ["--validate-runtime", "--include-native-bindings"])
        #expect(included.validatesRuntime && included.includesNativeBindings && !included.readsCreationCatalog)
        for arguments in [
            ["--include-native-bindings"],
            ["--include-native-bindings", "--creation-catalog", "--validate-runtime"],
            ["--validate-runtime", "--include-native-bindings", "--include-native-bindings"],
            ["--validate-runtime", "--include-native-bindings", "--startup-result", "/tmp/result"],
        ] {
            #expect(throws: (any Error).self) { try HostLaunchOptions(arguments: xcode + arguments) }
        }
    }

    @Test func managerRequestsOpenTheExplicitDeviceAndKeepQuitChoices() throws {
        let identifier = UUID().uuidString
        let options = try HostLaunchOptions(arguments: ["--managed", "--headless", "--owner-pid", "123", "--owner-launch-date", "1234.5", "--xcode", "/Xcode.app", "--device", identifier, "--device-set", "/custom/XCTestDevices"])
        #expect(options.deviceIdentifier == identifier)
        #expect(options.isManaged && options.isHeadless)
        #expect(options.owner == RendererOwnerIdentity(processIdentifier: 123, launchDate: Date(timeIntervalSinceReferenceDate: 1234.5)))
        let bridgeArguments =
            WorkspaceClient.rendererLaunchArguments(
                owner: try #require(options.owner),
                startupResultURL: URL(fileURLWithPath: "/tmp/result"), xcodeURL: options.xcodeURL, deviceIdentifier: nil
            )
            + ["--device-hub-proxy"]
        let bridge = try HostLaunchOptions(arguments: bridgeArguments)
        #expect(bridge.isDeviceHubProxy && bridge.owner == options.owner)
        #expect(!bridge.isHeadless && bridge.deviceIdentifier == nil)
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
        SimulatorPreferences.migrateStandalonePreferences(defaults: defaults, sourceDomain: source, targetDomain: target)
        let migrated = try #require(defaults.persistentDomain(forName: target))
        #expect(migrated[HostPreferences.showChrome] as? Bool == true)
        #expect(migrated[HostPreferences.detachOnAppQuit] as? Bool == true)
        defaults.setPersistentDomain([HostPreferences.detachOnAppQuit: false], forName: source)
        SimulatorPreferences.migrateStandalonePreferences(defaults: defaults, sourceDomain: source, targetDomain: target)
        #expect(defaults.persistentDomain(forName: target)?[HostPreferences.detachOnAppQuit] as? Bool == true)
    }
}
