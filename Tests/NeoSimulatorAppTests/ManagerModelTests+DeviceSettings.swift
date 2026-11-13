import AppKit
import Foundation
@testable import NeoSimulatorApp
@testable import NeoSimulatorDeviceIO
@testable import NeoSimulatorHostSupport
@testable import NeoSimulatorKit
@testable import NeoSimulatorPresentationAdapters
@testable import NeoSimulatorService
import Observation
import SwiftUI
import Synchronization
import Testing
import IOSurface
@testable import NeoSimulatorManager
@testable import NeoSimulatorCompactWindow
@testable import NeoSimulatorDeviceScreens
@testable import NeoSimulatorInspector
@testable import NeoSimulatorDeviceDisplay
@testable import NeoSimulatorSidebar

extension ManagerModelTests {
    @Test func inaccessiblePreferenceFilesStillRequestFolderAccess() async throws {
        let domain = "dev.lynnswap.NeoSimulator.HostPreferenceAccess.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let file = directory.appending(path: "settings.plist")
        try Data().write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: directory.path)
        var selections = 0
        let access = HostPreferenceAccess(defaults: defaults, file: file, chooseFile: { _, _ in
            selections += 1
            return nil
        })
        #expect(!access.restore())
        await #expect(throws: CancellationError.self) { try await access.request() }
        #expect(selections == 1)
    }

    @Test func cancellingPreferenceFileSelectionStopsTheSessionBeforeSettingsChange() async throws {
        let domain = "dev.lynnswap.NeoSimulator.HostPreferenceAccess.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let file = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).plist")
        try PropertyListSerialization.data(fromPropertyList: [:], format: .xml, options: 0).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let access = HostPreferenceAccess(defaults: defaults, file: file, chooseFile: { _, _ in nil })
        let source = ManagerModelSource(devices: [])
        let manager = SimulatorManagerModel(source: source)
        manager.requestHostPreferenceAccess = { try await access.request() }
        var cancelled = false
        manager.onError = { cancelled = $0 is CancellationError }
        manager.start()
        try await manager.prepareForQuit()
        #expect(cancelled)
        #expect(await source.sessionEvents == ["status"])
    }

    @Test func settingsProvideSimulatorCreationAndKeepExistingPreferences() async throws {
        _ = NSApplication.shared
        let domain = "NeoSimulator.SettingsFixture.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = SimulatorPreferences(defaults: defaults, creationDefaults: defaults)
        let model = SimulatorManagerModel(source: ManagerModelSource(devices: []))
        let browser = ManagerWindowController(model: model, screens: DeviceScreens(model: model),
                                              menus: MenuController(application: nil), defaults: defaults)
        defer { browser.window?.close() }
        let items = try #require(browser.window?.toolbar?.items)
        #expect(items.first(where: { $0.itemIdentifier.rawValue == "Settings" })?.action == #selector(AppDelegate.showSettings(_:)))
        #expect(items.allSatisfy { $0.itemIdentifier.rawValue != "NewSimulator" })
        var created: [String] = []
        var attempts = 0
        let windowController = SettingsWindowController(makeLicenses: SettingsPreview.licenses, model: model, restart: {}, makeSimulator: {
            attempts += 1
            if attempts == 1 { throw SimulatorError.operation("Catalog unavailable") }
            return NewSimulatorModel(catalog: SimulatorCatalog(
                deviceTypes: [.init(identifier: "phone", name: "iPhone", productFamily: 1)],
                runtimes: [.init(identifier: "ios", name: "iOS")],
                supportedDeviceTypes: ["ios": ["phone"]], canPair: { _, _, _, _ in false }),
                create: { name, type, runtime in created = [name, type, runtime]; return "created" },
                pair: { _, _ in Issue.record("Unexpected pairing") })
        }, preferences: preferences, reportFailure: { _ in Issue.record("Unexpected failure") })
        let controller = windowController.settings
        #if DEBUG
        #expect(controller.tabViewItems.contains { $0.viewController === controller.debug })
        var resets = 0
        controller.resetOnboarding = { resets += 1 }
        controller.debug.rootView.resetOnboarding()
        #expect(resets == 1)
        #endif
        let settingsWindow = try #require(windowController.window)
        defer { settingsWindow.close() }
        settingsWindow.layoutIfNeeded()
        #expect(settingsWindow.contentLayoutRect.height == ceil(controller.selectedContentSize.height))
        controller.selectedTabViewItemIndex = 1
        await controller.simulatorLoading?.value
        #expect(controller.devices.state.issue == "Catalog unavailable")
        controller.devices.state.reload()
        await controller.simulatorLoading?.value
        let form = try #require(controller.devices.state.form)
        settingsWindow.layoutIfNeeded()
        #expect(settingsWindow.contentLayoutRect.height == ceil(controller.selectedContentSize.height))
        form.name = "My Phone"
        form.forward()
        await form.waitForCreation()
        #expect(created == ["My Phone", "phone", "ios"])
        preferences.showSingleTouches = true
        #expect(defaults.bool(forKey: "ShowSingleTouches"))
        #expect(preferences.gifImageSize == 640)
        let externalDefaults = try #require(UserDefaults(suiteName: domain))
        externalDefaults.set(true, forKey: HostPreferences.screenShotUseMask)
        #expect(preferences.includeDeviceMask)
    }

    @Test func deviceFilterShowsNativeSelectionWithoutChangingItsSymbol() throws {
        let domain = "NeoSimulator.DeviceFilter.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let model = SimulatorManagerModel(source: ManagerModelSource(devices: []))
        let browser = ManagerWindowController(model: model, screens: DeviceScreens(model: model),
                                              menus: MenuController(application: nil), defaults: defaults)
        defer { browser.window?.close() }
        let item = try #require(browser.window?.toolbar?.items.first { $0.itemIdentifier.rawValue == "FilterSimulators" })
        let button = try #require(item.view as? NSButton)
        let image = try #require(button.image)
        let menu = try #require(item.menuFormRepresentation?.submenu)
        browser.sidebar.menuNeedsUpdate(menu)
        #expect(button.state == .off)
        let simulators = try #require(menu.items.first { $0.title == "Simulators" })
        #expect(NSApp.sendAction(try #require(simulators.action), to: simulators.target, from: simulators))
        #expect(button.state == .on && button.image === image)
        #expect(item.menuFormRepresentation?.state == .on)
        let all = try #require(menu.items.first { $0.title == "All Devices" })
        #expect(NSApp.sendAction(try #require(all.action), to: all.target, from: all))
        #expect(button.state == .off && button.image === image)
    }

    @Test func settingsToolbarResizesWindowWithoutIntermediateFrames() throws {
        let domain = "NeoSimulator.SettingsAnimation.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let model = SimulatorManagerModel(source: ManagerModelSource(devices: []))
        let controller = SettingsWindowController(makeLicenses: SettingsPreview.licenses, model: model, restart: {},
            makeSimulator: { throw SimulatorError.operation("Unused") },
            preferences: SimulatorPreferences(defaults: defaults, creationDefaults: defaults),
            reportFailure: { _ in Issue.record("Unexpected failure") })
        let window = try #require(controller.window)
        defer { window.close() }
        #expect(controller.settings.serviceProfiles.model.selectedProfileID == ServiceProfile.allServicesID)
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        let samples = SettingsWindowFrameSamples()
        NotificationCenter.default.addObserver(samples, selector: #selector(SettingsWindowFrameSamples.resized(_:)),
                                                name: NSWindow.didResizeNotification, object: window)
        defer { NotificationCenter.default.removeObserver(samples) }
        for tab in [controller.settings.licenses, controller.settings.capture,
                    controller.settings.serviceProfiles, controller.settings.general] {
            let before = window.frame
            samples.frames = []
            let item = try #require(window.toolbar?.items.first {
                $0.label == tab.title
            })
            let action = try #require(item.action)
            #expect(NSApp.sendAction(action, to: item.target, from: item))
            window.layoutIfNeeded()
            let after = window.frame
            #expect(after.height != before.height)
            #expect(abs(after.maxY - before.maxY) < 1)
            #expect(window.contentLayoutRect.height == ceil(controller.settings.selectedContentSize.height))
            #expect(samples.frames.allSatisfy { $0 == after })
        }
    }

    @Test func settingsRefreshRuntimesAndRememberTheDeviceFamily() async throws {
        let domain = "NeoSimulator.CreationFixture.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        var runtimeInstalled = false
        let model = SimulatorManagerModel(source: ManagerModelSource(devices: []))
        func makeForm() -> NewSimulatorModel {
            NewSimulatorModel(catalog: SimulatorCatalog(
                deviceTypes: [.init(identifier: "phone", name: "iPhone", productFamily: 1),
                              .init(identifier: "pad", name: "iPad", productFamily: 2)],
                runtimes: runtimeInstalled ? [.init(identifier: "ios", name: "iOS")] : [],
                supportedDeviceTypes: runtimeInstalled ? ["ios": ["phone", "pad"]] : [:],
                canPair: { _, _, _, _ in false }),
                create: { _, _, _ in "created" }, pair: { _, _ in },
                preferences: SimulatorPreferences(defaults: defaults, creationDefaults: defaults))
        }
        let controller = SettingsViewController(makeLicenses: SettingsPreview.licenses, model: model, restart: {}, makeSimulator: { makeForm() },
                                                preferences: SimulatorPreferences(defaults: defaults, creationDefaults: defaults),
                                                reportFailure: { _ in Issue.record("Unexpected failure") })
        _ = controller.view
        controller.selectedTabViewItemIndex = 1
        await controller.simulatorLoading?.value
        let first = try #require(controller.devices.state.form)
        #expect(!first.canProceed)
        controller.devices.state.isVisible = true
        first.name = "My iPad"
        first.selectCategory(.iPad)
        runtimeInstalled = true
        controller.reloadSimulatorIfVisible()
        await controller.simulatorLoading?.value
        let refreshed = try #require(controller.devices.state.form)
        #expect(refreshed !== first && refreshed.name == "My iPad")
        #expect(refreshed.category == .iPad && refreshed.deviceType == "pad")
        #expect(refreshed.runtime == "ios" && refreshed.canProceed)
        #expect(makeForm().category == .iPad)

        controller.devices.state.isVisible = false
        controller.reloadSimulatorIfVisible()
        await controller.simulatorLoading?.value
        let reopened = try #require(controller.devices.state.form)
        #expect(reopened.name.isEmpty && !reopened.addsWatch)
        #expect(reopened.category == .iPad && reopened.deviceType == "pad" && reopened.runtime == "ios")
    }

    @Test func sidebarRegroupingKeepsSelectionExpansionAndFilters() async throws {
        _ = NSApplication.shared
        let domain = "NeoSimulator.SidebarFixture.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        func devices(firstDate: Double = 100, firstConnection: String = "connected") throws -> [InventoryDevice] {
            let data = try JSONSerialization.data(withJSONObject: ["result": ["devices": [
                ["identifier": "A", "properties": ["hardware": ["fidelity": "physical"], "state": ["name": "Alpha"],
                    "connection": ["state": firstConnection, "lastConnectionDate": firstDate]],
                    "capabilities": [["featureIdentifier": "com.apple.coredevice.feature.viewdevicescreen"]]],
                ["identifier": "B", "properties": ["hardware": ["fidelity": "physical"], "state": ["name": "Beta"],
                    "connection": ["state": "connected", "lastConnectionDate": 200_000]]],
            ]]])
            return try CoreDeviceInventoryDecoder.decode(data).map(InventoryDevice.remote)
        }
        let source = ManagerModelSource(devices: try devices())
        let model = SimulatorManagerModel(source: source)
        model.registry.stopReading()
        await model.refresh()
        let controller = ManagerWindowController(model: model, screens: DeviceScreens(model: model),
                                                 menus: MenuController(application: nil), defaults: defaults)
        controller.window?.setFrameAutosaveName("")
        defer { controller.window?.close() }
        let content = try #require(controller.window?.contentView)
        let outline = try #require(inspectorViews(content).compactMap { $0 as? NSOutlineView }.first)
        let menu = try #require(controller.window?.toolbar?.items
            .first { $0.itemIdentifier.rawValue == "FilterSimulators" }?.menuFormRepresentation?.submenu)
        func choose(_ title: String) throws {
            controller.sidebar.menuNeedsUpdate(menu)
            let item = try #require(menu.items.first { $0.title == title && !$0.isSectionHeader })
            #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
        }
        try choose("Availability")
        #expect(controller.sidebar.outlineView(outline, numberOfChildrenOfItem: nil) == 1)
        try choose("Recent")
        controller.selectDevice(.coreDevice("A"))
        let selectedRow = try #require(outline.item(atRow: outline.selectedRow) as? NSObject)
        let groupedOrder = (0..<outline.numberOfRows).compactMap { row -> NSObject? in
            guard let item = outline.item(atRow: row), controller.sidebar.outlineView(outline, shouldSelectItem: item) else { return nil }
            return item as? NSObject
        }
        try choose("Show Groups")
        #expect(outline.numberOfRows == 2)
        #expect((0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? NSObject } == groupedOrder)
        #expect(controller.selectedIdentifiers == [.coreDevice("A")])
        try choose("Show Groups")
        let group = try #require(outline.parent(forItem: selectedRow))
        outline.collapseItem(group)
        let restored = ManagerWindowController(model: model, screens: DeviceScreens(model: model),
                                               menus: MenuController(application: nil), defaults: defaults)
        restored.window?.setFrameAutosaveName("")
        defer { restored.window?.close() }
        let restoredContent = try #require(restored.window?.contentView)
        let restoredOutline = try #require(inspectorViews(restoredContent).compactMap { $0 as? NSOutlineView }.first)
        #expect(!restoredOutline.isItemExpanded(restoredOutline.item(atRow: 2)))
        controller.selectDevice(.coreDevice("A"))
        #expect(outline.isItemExpanded(group))
        let search = try #require(inspectorViews(content).compactMap { $0 as? NSSearchField }
                .first { $0.placeholderString == "Search" })
        search.stringValue = "Alpha"
        controller.sidebar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        search.stringValue = ""
        controller.selectDevice(.coreDevice("A"))
        controller.sidebar.update()
        let newGroup = try #require(outline.item(atRow: 0))
        #expect(outline.isItemExpanded(newGroup))
        search.stringValue = "Alpha"
        controller.sidebar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        await source.setDevices(try devices(firstDate: 200_000))
        await model.refresh()
        controller.sidebar.update()
        #expect(search.stringValue == "Alpha")
        #expect(controller.selectedIdentifiers == [.coreDevice("A")])
        #expect(outline.item(atRow: outline.selectedRow) as? NSObject === selectedRow)
        search.stringValue = ""
        controller.sidebar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        #expect(controller.sidebar.outlineView(outline, numberOfChildrenOfItem: nil) == 1)
        #expect(controller.selectedIdentifiers == [.coreDevice("A")])

        func deviceNames() -> [String] {
            (0..<outline.numberOfRows).compactMap { row in
                guard let item = outline.item(atRow: row), controller.sidebar.outlineView(outline, shouldSelectItem: item) else { return nil }
                return controller.sidebar.outlineView(outline, typeSelectStringFor: nil, item: item)
            }
        }
        for (date, expected) in [(199_999.0, ["Beta", "Alpha"]), (200_001.0, ["Alpha", "Beta"])] {
            await source.setDevices(try devices(firstDate: date))
            await model.inventoryDidChange()
            try await wait(timeout: .seconds(5)) {
                deviceNames() == expected
            }
            #expect(controller.selectedIdentifiers == [.coreDevice("A")])
            #expect(outline.item(atRow: outline.selectedRow) as? NSObject === selectedRow)
        }

        try choose("Availability")
        try choose("Available")
        let viewScreen = try #require(inspectorViews(content).compactMap { $0 as? NSButton }
            .first { $0.title == "View Screen" })
        #expect(viewScreen.isEnabled)
        await source.setDevices(try devices(firstDate: 200_000, firstConnection: "connecting"))
        await model.refresh()
        controller.sidebar.update()
        #expect(controller.selectedIdentifiers == [.coreDevice("A")])
        #expect(outline.item(atRow: outline.selectedRow) as? NSObject === selectedRow)
        #expect(!viewScreen.isEnabled)
        let row = try #require(controller.sidebar.outlineView(outline, viewFor: outline.tableColumns.first, item: selectedRow))
        #expect(row.accessibilityLabel()?.hasSuffix(", Available") == true)

        try choose("All Availability")
        try choose("Recent")
        await source.setDevices(try devices())
        await model.refresh()
        controller.sidebar.update()
        controller.selectDevice(.coreDevice("A"))
        let roots = (0..<controller.sidebar.outlineView(outline, numberOfChildrenOfItem: nil)).map {
            controller.sidebar.outlineView(outline, child: $0, ofItem: nil)
        }
        for root in roots { outline.collapseItem(root) }
        let revision = controller.presentationIntent.revision
        // Moving A into B's collapsed day replaces that parent's cached children.
        await source.setDevices(try devices(firstDate: 200_000))
        await model.inventoryDidChange()
        try await wait {
            controller.sidebar.outlineView(outline, numberOfChildrenOfItem: nil) == 1
        }
        let merged = try #require(outline.item(atRow: 0))
        #expect(!outline.isItemExpanded(merged))
        outline.expandItem(merged)
        #expect(deviceNames() == ["Alpha", "Beta"])
        #expect(outline.item(atRow: outline.selectedRow) as? NSObject === selectedRow)
        #expect(outline.parent(forItem: selectedRow) as? NSObject === merged as? NSObject)
        #expect(controller.selectedIdentifiers == [.coreDevice("A")])
        #expect(controller.presentationIntent.revision == revision)
    }
}
