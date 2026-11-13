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
        let defaults = try #require(HostPreferences.deviceSettingsDefaults)
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
        let controller = try makeController(display, device: identifier)
        defer { controller.invalidate() }
        let session = controller.session
        let model = SimulatorManagerModel(source: ManagerModelSource(devices: []))
        model.registry.stopReading()
        let screens = DeviceScreens(model: model)
        defer { withExtendedLifetime(screens) {} }
        _ = screens.attach(controller, as: .simulator(udid: identifier, deviceSetPath: nil))
        try await session.setCustomLocation(latitude: 45.5, longitude: 67.5)
        #expect(try await connect().appliedLocations == [.coordinate(45.5, 67.5)])
        defaults.set(["mode": "none"], forKey: key)
        #expect(defaults.synchronize())
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("dev.lynnswap.NeoSimulator.DeviceLocationChanged"),
            object: identifier, userInfo: nil, deliverImmediately: true)
        for _ in 0..<100 where session.location != LocationSelection.none {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(session.location == LocationSelection.none)
        #expect(display.appliedLocations == [.coordinate(45.5, 67.5)])
        #expect(try await connect().appliedLocations == [.cleared])
        defaults.set(["mode": "custom", "latitude": 12.5, "longitude": 34.5], forKey: key)
        #expect(defaults.synchronize())
        try session.refreshLocationSelection()
        #expect(session.location == .custom)
        #expect(display.appliedLocations == [.coordinate(45.5, 67.5)])
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
        display.locationError = SimulatorError.operation("location failed")
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
}
