import AppKit
import Foundation
import Observation
import SwiftUI
import Testing
import XCTest
@_spi(NeoSimulator) @testable import XcodeSimulatorHost
import Synchronization

@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor
struct ManagerModelTests {
    @Test(arguments: DeviceBrowserPresentation.SortOrder.allCases)
    func sidebarSortsOwnTheirSections(_ order: DeviceBrowserPresentation.SortOrder) throws {
        let records = try CoreDeviceInventoryDecoder.decode(Data(#"""
        {"result":{"devices":[
          {"identifier":"phone","properties":{"hardware":{"reality":"physical","platform":"iOS"},
            "state":{"name":"Beta"},"software":{"osVersionNumber":{"stringValue":"27.2"}},
            "connection":{"state":"connected","lastConnectionDate":200}}},
          {"identifier":"vm","properties":{"hardware":{"reality":"virtual","platform":"macOS"},
            "state":{"name":"Alpha"},"software":{"osVersionNumber":{"stringValue":"15.10"}},
            "connection":{"state":"connected","lastConnectionDate":100}}},
          {"identifier":"other","properties":{"hardware":{"reality":"future","marketingName":"Fallback Name"}}},
          {"identifier":"symbol","properties":{"hardware":{"reality":"future"},"state":{"name":"42"}}}
        ]}}
        """#.utf8))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let presentation = DeviceBrowserPresentation(devices: records.map(InventoryDevice.remote), sortOrder: order,
                                                     calendar: calendar, locale: Locale(identifier: "en_US_POSIX"))
        let expected: [String] = switch order {
        case .availability: ["Available", "Unavailable"]
        case .recent: ["Jan 1, 2001", "Other"]
        case .name: ["Other", "A", "B", "#"]
        case .fidelity: ["Other", "Physical Devices", "Virtual Machines"]
        case .platform: ["iOS", "macOS", "Other"]
        case .operatingSystem: ["Other Other", "iOS 27.2", "macOS 15.10"]
        }
        #expect(presentation.sections.map(\.title) == expected)
        #expect(Set(presentation.devices.map(\.id)) == Set(records.map { .coreDevice($0.identifier) }))
        if order == .recent {
            // Full timestamps run Beta -> Alpha; the same-day name order runs Alpha -> Beta.
            #expect(presentation.sections[0].devices.map(\.name) == ["Alpha", "Beta"])
        }
        if order == .name { #expect(presentation.sections[0].devices[0].name == "Fallback Name") }
    }

    @Test func sidebarAvailabilityUsesRetainedCoreDeviceClassification() throws {
        let data = Data(#"""
        {"result":{"devices":[
          {"identifier":"connecting","properties":{"hardware":{"reality":"physical"},
            "state":{"name":"Connecting"},"connection":{"state":"connecting"}}},
          {"identifier":"boot","properties":{"hardware":{"reality":"virtual"},
            "connection":{"state":"unavailable"}},
            "capabilities":[{"featureIdentifier":"com.apple.dt.coredevice.device.boot"}]},
          {"identifier":"resume","properties":{"hardware":{"reality":"virtual"},
            "connection":{"state":"unavailable"}},
            "capabilities":[{"featureIdentifier":"com.apple.dt.coredevice.virtualmachineplugin.resumeFromPause"}]},
          {"identifier":"provisioning","properties":{"hardware":{"reality":"physical"},
            "state":{"visibilityClass":"devicesBeingProvisioned"},"connection":{"state":"unavailable"}}},
          {"identifier":"unavailable","properties":{"hardware":{"reality":"physical"},
            "connection":{"state":"unavailable"}}},
          {"identifier":"future","properties":{"hardware":{"reality":"physical"},
            "connection":{"state":"future-state"}}},
          {"identifier":"missing","properties":{"hardware":{"reality":"physical"}}}
        ]}}
        """#.utf8)
        let devices = try CoreDeviceInventoryDecoder.decode(data).map(InventoryDevice.remote)
        let grouped = DeviceBrowserPresentation(devices: devices, sortOrder: .availability)
        #expect(Set(grouped.sections.first?.devices.map(\.id) ?? []) ==
            Set(["connecting", "boot", "resume", "provisioning"].map(DeviceInventoryID.coreDevice)))
        #expect(Set(grouped.sections.last?.devices.map(\.id) ?? []) ==
            Set(["unavailable", "future", "missing"].map(DeviceInventoryID.coreDevice)))
        let recent = DeviceBrowserPresentation(devices: devices, sortOrder: .recent)
        #expect(Set(recent.devices.prefix(4).map(\.id)) == Set(grouped.sections[0].devices.map(\.id)))
    }

    @Test(arguments: [(nil as String?, "Other"), ("  ßeta  ", "SS"), ("\nAlpha", "#"), ("", "#")])
    func sidebarNameGroupsUseTheReportedFirstCharacter(_ name: String?, _ expected: String) throws {
        var state: [String: String] = [:]
        state["name"] = name
        let data = try JSONSerialization.data(withJSONObject: ["result": ["devices": [["identifier": "phone",
            "properties": ["hardware": ["reality": "physical", "marketingName": "Fallback"], "state": state]]]]])
        let device = InventoryDevice.remote(try #require(CoreDeviceInventoryDecoder.decode(data).first))
        let presentation = DeviceBrowserPresentation(devices: [device], sortOrder: .name)
        #expect(presentation.sections.map(\.id) == [expected])
    }

    @Test func recentUsesJoinedConnectionTimeWithoutBorrowingCustomSetMetadata() async throws {
        let defaultDevice = simulator(name: "Default", lastUsedAt: .distantFuture)
        let customDevice = simulator(deviceSet: "/tmp/sidebar-custom-set", name: "Custom", lastUsedAt: .distantFuture)
        let payload = Data(#"""
        {"result":{"devices":[{"identifier":"core-record","properties":{
          "hardware":{"reality":"simulated","udid":"same-udid"},"state":{"name":"Default"},
          "connection":{"state":"unavailable","lastConnectionDate":100}}}]}}
        """#.utf8)
        let snapshot = await DeviceInventoryReader(
            readSimulators: { DeviceInventorySnapshot(devices: [defaultDevice, customDevice], issues: []) },
            readCoreDevices: { payload }).read()
        #expect(snapshot.issues.isEmpty)
        #expect(snapshot.devices.first { $0.id == defaultDevice.id }?.lastConnectionDate == Date(timeIntervalSinceReferenceDate: 100))
        #expect(snapshot.devices.first { $0.id == customDevice.id }?.lastConnectionDate == nil)
        let presentation = DeviceBrowserPresentation(devices: snapshot.devices, sortOrder: .recent)
        #expect(presentation.sections.count == 2)
        #expect(presentation.sections.last?.id == "Other")
        #expect(presentation.sections.last?.devices.map(\.id) == [customDevice.id])
        let availability = DeviceBrowserPresentation(devices: snapshot.devices, sortOrder: .availability)
        #expect(availability.sections.first?.devices.map(\.id) == [customDevice.id])
        #expect(availability.sections.last?.devices.map(\.id) == [defaultDevice.id])
    }

    @Test func operatingSystemSectionsUseNumericVersionsWithMissingVersionLast() throws {
        let payload = Data(#"""
        {"result":{"devices":[
          {"identifier":"older","properties":{"hardware":{"reality":"physical","platform":"iOS"},
            "software":{"osVersionNumber":{"stringValue":"27.2"}}}},
          {"identifier":"newer","properties":{"hardware":{"reality":"physical","platform":"iOS"},
            "software":{"osVersionNumber":{"stringValue":"27.10"}}}},
          {"identifier":"unknown","properties":{"hardware":{"reality":"physical","platform":"iOS"}}},
          {"identifier":"watch","properties":{"hardware":{"reality":"physical","platform":"watchOS"},
            "software":{"osVersionNumber":{"stringValue":"27.2"}}}},
          {"identifier":"vision","properties":{"hardware":{"reality":"physical","platform":"visionOS"},
            "software":{"osVersionNumber":{"stringValue":"27.2"}}}},
          {"identifier":"future","properties":{"hardware":{"reality":"physical","platform":"futureOS"},
            "software":{"osVersionNumber":{"stringValue":"1.0"}}}}
        ]}}
        """#.utf8)
        let devices = try CoreDeviceInventoryDecoder.decode(payload).map(InventoryDevice.remote)
        let presentation = DeviceBrowserPresentation(devices: devices, sortOrder: .operatingSystem)
        #expect(presentation.sections.map(\.title) == ["futureOS 1.0", "iOS 27.10", "iOS 27.2", "iOS Other", "watchOS 27.2", "visionOS 27.2"])
        let platforms = DeviceBrowserPresentation(devices: devices, sortOrder: .platform)
        #expect(platforms.sections.map(\.id) == ["futureOS", "iOS", "watchOS", "xrOS"])
        #expect(platforms.sections.map(\.title) == ["futureOS", "iOS", "watchOS", "visionOS"])
    }

    @Test func sidebarRegroupingKeepsSelectionExpansionAndFilters() async throws {
        _ = NSApplication.shared
        let domain = "NeoSimulator.SidebarFixture.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        func devices(firstDate: Double = 100, firstConnection: String = "connected") throws -> [InventoryDevice] {
            let data = try JSONSerialization.data(withJSONObject: ["result": ["devices": [
                ["identifier": "A", "properties": ["hardware": ["reality": "physical"], "state": ["name": "Alpha"],
                    "connection": ["state": firstConnection, "lastConnectionDate": firstDate]],
                    "capabilities": [["featureIdentifier": "com.apple.coredevice.feature.viewdevicescreen"]]],
                ["identifier": "B", "properties": ["hardware": ["reality": "physical"], "state": ["name": "Beta"],
                    "connection": ["state": "connected", "lastConnectionDate": 200_000]]],
            ]]])
            return try CoreDeviceInventoryDecoder.decode(data).map(InventoryDevice.remote)
        }
        let source = ManagerModelSource(devices: try devices())
        let model = SimulatorManagerModel(source: source)
        model.settings.setReadingSuspended(true)
        await model.refresh()
        let controller = ManagerWindowController(model: model, defaults: defaults)
        controller.window?.setFrameAutosaveName("")
        defer { controller.window?.close() }
        let content = try #require(controller.window?.contentView)
        let outline = try #require(inspectorViews(content).compactMap { $0 as? NSOutlineView }.first)
        let menu = try #require(controller.window?.toolbar?.items.compactMap { $0 as? NSMenuToolbarItem }
            .first { $0.itemIdentifier.rawValue == "FilterSimulators" }?.menu)
        func choose(_ title: String) throws {
            controller.menuNeedsUpdate(menu)
            let item = try #require(menu.items.first { $0.title == title && !$0.isSectionHeader })
            #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
        }
        #expect(controller.outlineView(outline, numberOfChildrenOfItem: nil) == 1)
        try choose("Recent")
        controller.selectDevice(.coreDevice("A"))
        let selectedRow = try #require(outline.item(atRow: outline.selectedRow) as? NSObject)
        let groupedOrder = (0..<outline.numberOfRows).compactMap { row -> NSObject? in
            guard let item = outline.item(atRow: row), controller.outlineView(outline, shouldSelectItem: item) else { return nil }
            return item as? NSObject
        }
        try choose("Show Groups")
        #expect(outline.numberOfRows == 2)
        #expect((0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? NSObject } == groupedOrder)
        #expect(controller.selectedIdentifiers == [.coreDevice("A")])
        try choose("Show Groups")
        let group = try #require(outline.parent(forItem: selectedRow))
        outline.collapseItem(group)
        let restored = ManagerWindowController(model: model, defaults: defaults)
        restored.window?.setFrameAutosaveName("")
        defer { restored.window?.close() }
        let restoredContent = try #require(restored.window?.contentView)
        let restoredOutline = try #require(inspectorViews(restoredContent).compactMap { $0 as? NSOutlineView }.first)
        #expect(!restoredOutline.isItemExpanded(restoredOutline.item(atRow: 2)))
        controller.selectDevice(.coreDevice("A"))
        #expect(outline.isItemExpanded(group))
        let search = try #require(inspectorViews(content).compactMap { $0 as? NSSearchField }
            .first { $0.placeholderString == "Search Devices" })
        search.stringValue = "Alpha"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        search.stringValue = ""
        controller.selectDevice(.coreDevice("A"))
        controller.update()
        let newGroup = try #require(outline.item(atRow: 0))
        #expect(outline.isItemExpanded(newGroup))
        search.stringValue = "Alpha"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        await source.setDevices(try devices(firstDate: 200_000))
        await model.refresh()
        controller.update()
        #expect(search.stringValue == "Alpha")
        #expect(controller.selectedIdentifiers == [.coreDevice("A")])
        #expect(outline.item(atRow: outline.selectedRow) as? NSObject === selectedRow)
        search.stringValue = ""
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        #expect(controller.outlineView(outline, numberOfChildrenOfItem: nil) == 1)
        #expect(controller.selectedIdentifiers == [.coreDevice("A")])
        try choose("Availability")
        try choose("Available")
        let viewScreen = try #require(inspectorViews(content).compactMap { $0 as? NSButton }
            .first { $0.title == "View Screen" })
        #expect(viewScreen.isEnabled)
        await source.setDevices(try devices(firstDate: 200_000, firstConnection: "connecting"))
        await model.refresh()
        controller.update()
        #expect(controller.selectedIdentifiers == [.coreDevice("A")])
        #expect(outline.item(atRow: outline.selectedRow) as? NSObject === selectedRow)
        #expect(!viewScreen.isEnabled)
        let row = try #require(controller.outlineView(outline, viewFor: outline.tableColumns.first, item: selectedRow))
        #expect(row.accessibilityLabel()?.hasSuffix(", Available") == true)
    }

    @Test func sidebarOptionsRestoreAndUseNativeFallbacks() throws {
        let domain = "NeoSimulator.SidebarFixture.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        var options = DeviceBrowserPresentation.Options(defaults: defaults)
        #expect(options.sortOrder == .availability && options.showGroups)
        options.sortOrder = .recent
        options.showGroups = false
        options.save(to: defaults)
        let restored = DeviceBrowserPresentation.Options(defaults: defaults)
        #expect(restored.sortOrder == .recent && !restored.showGroups)
        defaults.set(-1, forKey: "SidebarSortOrder")
        #expect(DeviceBrowserPresentation.Options(defaults: defaults).sortOrder == .availability)
    }

    @Test(arguments: ["new-selection", "return-selection", "rollback"])
    func pendingPresentationKeepsTheLaterSelectionAndCanvas(_ mode: String) async throws {
        _ = NSApplication.shared
        let devices = try CoreDeviceInventoryDecoder.decode(Data(#"{"result":{"devices":[{"identifier":"A","properties":{"hardware":{"reality":"physical"},"state":{"name":"A"}}},{"identifier":"B","properties":{"hardware":{"reality":"physical"},"state":{"name":"B"}}}]}}"#.utf8))
        let a = try #require(devices.first), b = try #require(devices.last)
        let source = ManagerModelSource(devices: devices.map(InventoryDevice.remote))
        let model = SimulatorManagerModel(source: source)
        model.settings.setReadingSuspended(true)
        await model.refresh()
        let app = AppDelegate()
        app.model = model
        app.prepareMainWindow()
        let main = try #require(app.mainWindow)
        main.window?.setFrameAutosaveName("")
        let aTransport = TestRemoteScreenTransport(), bTransport = TestRemoteScreenTransport()
        let aSession = RemoteDeviceScreenSession(device: a) { _, _, _ in aTransport }
        let bSession = RemoteDeviceScreenSession(device: b) { _, _, _ in bTransport }
        try await aSession.start()
        try await bSession.start()
        let aController = RemoteDeviceWindowController(device: a, session: aSession, presentCompactWindow: { _ in })
        let bController = RemoteDeviceWindowController(device: b, session: bSession, presentCompactWindow: { _ in })
        let aID = DeviceInventoryID.coreDevice(a.identifier), bID = DeviceInventoryID.coreDevice(b.identifier)
        app.remoteWindows = [aID: aController, bID: bController]
        main.selectDevice(aID)
        if mode != "new-selection" {
            try await app.presentConnectedScreen(aID, purpose: .requested)
        }
        let releasing = AsyncStream<Void>.makeStream(), resume = AsyncStream<Void>.makeStream()
        var releases = releasing.stream.makeAsyncIterator()
        aTransport.onReleaseInputs = {
            aTransport.onReleaseInputs = nil
            releasing.continuation.yield(())
            var permits = resume.stream.makeAsyncIterator()
            _ = await permits.next()
        }
        if mode == "return-selection" { app.selectDeviceForPresentation(bID) }
        else if mode == "rollback" {
            main.selectDevice(bID)
            bTransport.onReleaseInputs = {
                bTransport.onReleaseInputs = nil
                throw ManagerModelSource.Failure.unavailable
            }
        }
        let target = mode == "new-selection" ? aID : bID
        let opening = Task { try await app.presentConnectedScreen(target, purpose: .requested) }
        #expect(await releases.next() != nil)
        if mode != "rollback" {
            let content = try #require(main.window?.contentView)
            let outline = try #require(inspectorViews(content).compactMap { $0 as? NSOutlineView }.first)
            let otherRow = try #require((0..<outline.numberOfRows).first { row in
                row != outline.selectedRow && outline.item(atRow: row).map { main.outlineView(outline, shouldSelectItem: $0) } == true
            })
            outline.selectRowIndexes(IndexSet(integer: otherRow), byExtendingSelection: false)
        }
        resume.continuation.yield(())
        if mode == "rollback" {
            await #expect(throws: ManagerModelSource.Failure.self) { try await opening.value }
        } else { try await opening.value }
        let selected = mode == "return-selection" ? aID : bID
        let rendered = mode == "new-selection" ? bID : aID
        let renderedController = mode == "new-selection" ? bController : aController
        let presented = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated {
                main.liveDeviceIdentifier == rendered && renderedController.presentationViewController.parent === main.liveScreenContainer
            }
        }, object: nil)
        try #require(await XCTWaiter.fulfillment(of: [presented], timeout: 5) == .completed)
        #expect(main.selectedIdentifiers == [selected])
        #expect(model.settings.device?.id == selected && main.deviceInspector.inspection.device?.id == selected)
        #expect((mode == "new-selection" ? aController : bController).presentationViewController.parent == nil)
        #expect(aSession.state == .connected && app.remoteWindows[aID] === aController)
        try await aSession.stop()
        try await bSession.stop()
        main.window?.close()
    }

    @Test func connectionCompletionHonorsTheReselectedDevicesLatestMainIntent() async throws {
        _ = NSApplication.shared
        let devices = try CoreDeviceInventoryDecoder.decode(Data(#"{"result":{"devices":[{"identifier":"A","properties":{"hardware":{"reality":"physical"},"state":{"name":"A"}}},{"identifier":"B","properties":{"hardware":{"reality":"physical"},"state":{"name":"B"}}}]}}"#.utf8))
        let a = try #require(devices.first), b = try #require(devices.last)
        let model = SimulatorManagerModel(source: ManagerModelSource(devices: devices.map(InventoryDevice.remote)))
        model.settings.setReadingSuspended(true)
        await model.refresh()
        let app = AppDelegate()
        app.model = model
        app.prepareMainWindow()
        let main = try #require(app.mainWindow)
        main.window?.setFrameAutosaveName("")
        let aTransport = TestRemoteScreenTransport(), bTransport = TestRemoteScreenTransport()
        let aSession = RemoteDeviceScreenSession(device: a) { _, _, _ in aTransport }
        let bSession = RemoteDeviceScreenSession(device: b) { _, _, _ in bTransport }
        try await aSession.start()
        try await bSession.start()
        let aController = RemoteDeviceWindowController(device: a, session: aSession, presentCompactWindow: { _ in })
        let bController = RemoteDeviceWindowController(device: b, session: bSession, presentCompactWindow: { _ in })
        let aID = DeviceInventoryID.coreDevice(a.identifier), bID = DeviceInventoryID.coreDevice(b.identifier)
        app.remoteWindows[bID] = bController
        main.selectDevice(bID)
        try await app.presentConnectedScreen(bID, purpose: .requested)
        main.selectDevice(aID)
        let content = try #require(main.window?.contentView)
        let outline = try #require(inspectorViews(content).compactMap { $0 as? NSOutlineView }.first)
        let aRow = outline.selectedRow
        let bRow = try #require((0..<outline.numberOfRows).first { row in
            row != aRow && outline.item(atRow: row).map { main.outlineView(outline, shouldSelectItem: $0) } == true
        })
        outline.selectRowIndexes(IndexSet(integer: bRow), byExtendingSelection: false)
        let releasing = AsyncStream<Void>.makeStream(), resume = AsyncStream<Void>.makeStream()
        var releases = releasing.stream.makeAsyncIterator()
        bTransport.onReleaseInputs = {
            bTransport.onReleaseInputs = nil
            releasing.continuation.yield(())
            var permits = resume.stream.makeAsyncIterator()
            _ = await permits.next()
        }
        outline.selectRowIndexes(IndexSet(integer: aRow), byExtendingSelection: false)
        #expect(await releases.next() != nil)
        app.remoteWindows[aID] = aController
        let connected = Task {
            try await app.presentConnectedScreen(aID, purpose: .automatic, preserving: .compact)
        }
        resume.continuation.yield(())
        try await connected.value
        let presented = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated {
                main.liveDeviceIdentifier == aID && aController.presentationViewController.parent === main.liveScreenContainer
            }
        }, object: nil)
        try #require(await XCTWaiter.fulfillment(of: [presented], timeout: 5) == .completed)
        #expect(main.selectedIdentifiers == [aID])
        #expect(model.settings.device?.id == aID && main.deviceInspector.inspection.device?.id == aID)
        #expect(!bController.isEmbedded && aSession.state == .connected)
        try await aSession.stop()
        try await bSession.stop()
        main.window?.close()
    }

    @Test func extendingMultipleSelectionReplacesThePendingDetach() async throws {
        _ = NSApplication.shared
        let devices = try CoreDeviceInventoryDecoder.decode(Data(#"{"result":{"devices":[{"identifier":"A","properties":{"hardware":{"reality":"physical"},"state":{"name":"A"}}},{"identifier":"B","properties":{"hardware":{"reality":"physical"},"state":{"name":"B"}}},{"identifier":"C","properties":{"hardware":{"reality":"physical"},"state":{"name":"C"}}}]}}"#.utf8))
        let a = try #require(devices.first), c = try #require(devices.last)
        let aID = DeviceInventoryID.coreDevice(a.identifier), cID = DeviceInventoryID.coreDevice(c.identifier)
        let model = SimulatorManagerModel(source: ManagerModelSource(devices: devices.map(InventoryDevice.remote)))
        model.settings.setReadingSuspended(true)
        await model.refresh()
        let app = AppDelegate()
        app.model = model
        app.prepareMainWindow()
        let main = try #require(app.mainWindow)
        main.window?.setFrameAutosaveName("")
        defer { main.window?.close() }
        let transport = TestRemoteScreenTransport()
        let session = RemoteDeviceScreenSession(device: a) { _, _, _ in TestRemoteScreenTransport() }
        let backgroundSession = RemoteDeviceScreenSession(device: c) { _, _, _ in transport }
        try await session.start()
        try await backgroundSession.start()
        let controller = RemoteDeviceWindowController(device: a, session: session, presentCompactWindow: { _ in })
        let background = RemoteDeviceWindowController(device: c, session: backgroundSession, presentCompactWindow: { _ in })
        let backgroundParent = NSViewController()
        backgroundParent.view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        try await background.embed(in: backgroundParent)
        app.remoteWindows = [aID: controller, cID: background]
        main.selectDevice(aID)
        try await app.presentConnectedScreen(aID, purpose: .requested)
        let content = try #require(main.window?.contentView)
        let outline = try #require(inspectorViews(content).compactMap { $0 as? NSOutlineView }.first)
        let rows = (0..<outline.numberOfRows).filter { row in
            outline.item(atRow: row).map { main.outlineView(outline, shouldSelectItem: $0) } == true
        }
        try #require(rows.count == 3)
        let releasing = AsyncStream<Void>.makeStream(), resume = AsyncStream<Void>.makeStream()
        var releases = releasing.stream.makeAsyncIterator()
        transport.onReleaseInputs = {
            transport.onReleaseInputs = nil
            releasing.continuation.yield(())
            var permits = resume.stream.makeAsyncIterator()
            _ = await permits.next()
        }
        let compacting = Task { try await app.presentConnectedScreen(cID, purpose: .automatic, preserving: .compact) }
        try #require(await releases.next() != nil)
        outline.selectRowIndexes(IndexSet(rows.prefix(2)), byExtendingSelection: false)
        outline.selectRowIndexes(IndexSet(integer: rows[2]), byExtendingSelection: true)
        try #require(main.selectedIdentifiers.count == 3)
        resume.continuation.yield(())
        try await compacting.value
        let detached = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated {
                main.liveDeviceIdentifier == nil && main.activeScreenCommandTarget == nil
            }
        }, object: nil)
        #expect(await XCTWaiter.fulfillment(of: [detached], timeout: 5) == .completed)
        #expect(controller.presentationViewController.parent == nil)
        #expect(main.selectedIdentifiers.count == 3 && model.settings.device == nil)
        try await session.stop()
        try await backgroundSession.stop()
    }

    @Test func contextMenuSelectionStartsMainIntentWithoutChangingRefreshOrSameRowIntent() async throws {
        _ = NSApplication.shared
        let devices = try CoreDeviceInventoryDecoder.decode(Data(#"{"result":{"devices":[{"identifier":"A","properties":{"hardware":{"reality":"physical"},"state":{"name":"A"}}},{"identifier":"B","properties":{"hardware":{"reality":"physical"},"state":{"name":"B"}}}]}}"#.utf8))
        let a = try #require(devices.first), b = try #require(devices.last)
        let model = SimulatorManagerModel(source: ManagerModelSource(devices: devices.map(InventoryDevice.remote)))
        model.settings.setReadingSuspended(true)
        await model.refresh()
        let app = AppDelegate()
        app.model = model
        app.prepareMainWindow()
        let main = try #require(app.mainWindow)
        main.window?.setFrameAutosaveName("")
        defer { main.window?.close() }
        let aSession = RemoteDeviceScreenSession(device: a) { _, _, _ in TestRemoteScreenTransport() }
        let bSession = RemoteDeviceScreenSession(device: b) { _, _, _ in TestRemoteScreenTransport() }
        try await aSession.start()
        try await bSession.start()
        let aController = RemoteDeviceWindowController(device: a, session: aSession, presentCompactWindow: { _ in })
        let bController = RemoteDeviceWindowController(device: b, session: bSession, presentCompactWindow: { _ in })
        let aID = DeviceInventoryID.coreDevice(a.identifier), bID = DeviceInventoryID.coreDevice(b.identifier)
        app.remoteWindows = [aID: aController, bID: bController]
        main.selectDevice(aID)
        try await app.presentConnectedScreen(aID, purpose: .requested)
        main.onShowCompactWindow?(aID)
        let compacted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated { main.liveDeviceIdentifier == nil && !aController.isEmbedded }
        }, object: nil)
        try #require(await XCTWaiter.fulfillment(of: [compacted], timeout: 5) == .completed)
        let compactIntent = app.presentationIntent
        main.update()
        let content = try #require(main.window?.contentView)
        let fields = inspectorViews(content)
        let search = try #require(fields.compactMap { $0 as? NSSearchField }.first { $0.placeholderString == "Search Devices" })
        search.stringValue = "B"
        main.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        search.stringValue = ""
        main.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        #expect(app.presentationIntent.revision == compactIntent.revision && app.presentationIntent.placement == .compact)
        let outline = try #require(fields.compactMap { $0 as? NSOutlineView }.first)
        let aRow = outline.selectedRow
        try #require(aRow >= 0)
        main.updateDeviceMenu(for: aRow)
        #expect(app.presentationIntent.revision == compactIntent.revision && app.presentationIntent.placement == .compact)
        let bRow = try #require((0..<outline.numberOfRows).first { row in
            row != aRow && outline.item(atRow: row).map { main.outlineView(outline, shouldSelectItem: $0) } == true
        })
        main.updateDeviceMenu(for: bRow)
        let embedded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated {
                main.liveDeviceIdentifier == bID && bController.presentationViewController.parent === main.liveScreenContainer
            }
        }, object: nil)
        try #require(await XCTWaiter.fulfillment(of: [embedded], timeout: 5) == .completed)
        try await app.presentConnectedScreen(bID, purpose: .automatic)
        #expect(main.selectedIdentifiers == [bID] && main.liveDeviceIdentifier == bID)
        #expect(bController.presentationViewController.parent === main.liveScreenContainer)
        #expect(model.settings.device?.id == bID && main.deviceInspector.inspection.device?.id == bID)
        try await aSession.stop()
        try await bSession.stop()
    }

    @Test(arguments: [false, true])
    func automaticPresentationPreservesSelectionAndInitialPresentation(_ initial: Bool) async throws {
        _ = NSApplication.shared
        let devices = try CoreDeviceInventoryDecoder.decode(Data(#"{"result":{"devices":[{"identifier":"A","properties":{"hardware":{"reality":"physical"},"state":{"name":"A"}}},{"identifier":"B","properties":{"hardware":{"reality":"physical"},"state":{"name":"B"}}}]}}"#.utf8))
        let a = try #require(devices.first), b = try #require(devices.last)
        let aID = DeviceInventoryID.coreDevice(a.identifier), bID = DeviceInventoryID.coreDevice(b.identifier)
        let model = SimulatorManagerModel(source: ManagerModelSource(devices: devices.map(InventoryDevice.remote)))
        model.settings.setReadingSuspended(true)
        await model.refresh()
        let app = AppDelegate()
        app.model = model
        app.prepareMainWindow()
        let main = try #require(app.mainWindow)
        main.window?.setFrameAutosaveName("")
        let transport = TestRemoteScreenTransport()
        let session = RemoteDeviceScreenSession(device: a) { _, _, _ in transport }
        try await session.start()
        var compactPresentations = 0
        let controller = RemoteDeviceWindowController(device: a, session: session,
            presentCompactWindow: { _ in compactPresentations += 1 })
        app.remoteWindows[aID] = controller
        if !initial { main.selectDevice(bID) }
        try await app.presentConnectedScreen(aID, purpose: initial ? .startup : .automatic)
        let selected = initial ? aID : bID
        #expect(main.selectedIdentifiers == [selected])
        #expect(model.settings.device?.id == selected && main.deviceInspector.inspection.device?.id == selected)
        #expect(main.liveDeviceIdentifier == (initial ? aID : nil))
        #expect((controller.presentationViewController.parent === main.liveScreenContainer) == initial)
        #expect(session.state == .connected && app.remoteWindows[aID] === controller)
        if !initial {
            try await app.presentConnectedScreen(aID, purpose: .automatic, preserving: .compact)
            #expect(compactPresentations == 1 && main.selectedIdentifiers == [bID] && main.liveDeviceIdentifier == nil)
        }
        if initial {
            main.onShowCompactWindow?(aID)
            let compacted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                MainActor.assumeIsolated { main.liveDeviceIdentifier == nil && !controller.isEmbedded }
            }, object: nil)
            try #require(await XCTWaiter.fulfillment(of: [compacted], timeout: 5) == .completed)
            try await app.presentConnectedScreen(aID, purpose: .requested)
            #expect(main.liveDeviceIdentifier == nil && !controller.isEmbedded)
            app.selectDeviceForPresentation(aID)
            let embedded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                MainActor.assumeIsolated { main.liveDeviceIdentifier == aID && controller.isEmbedded }
            }, object: nil)
            try #require(await XCTWaiter.fulfillment(of: [embedded], timeout: 5) == .completed)
        }
        try await session.stop()
        main.window?.close()
    }

    @Test(arguments: [false, true])
    func queuedRemoteOpenPreservesNewerSelectionOrCompact(_ selectsAnotherDevice: Bool) async throws {
        _ = NSApplication.shared
        let devices = try CoreDeviceInventoryDecoder.decode(Data(#"{"result":{"devices":[{"identifier":"A","properties":{"hardware":{"reality":"physical"},"state":{"name":"A"}}},{"identifier":"B","properties":{"hardware":{"reality":"physical"},"state":{"name":"B"}}}]}}"#.utf8))
        let a = try #require(devices.first), b = try #require(devices.last)
        let aID = DeviceInventoryID.coreDevice(a.identifier), bID = DeviceInventoryID.coreDevice(b.identifier)
        let source = ManagerModelSource(devices: devices.map(InventoryDevice.remote))
        var events = source.events.makeAsyncIterator()
        let model = SimulatorManagerModel(source: source)
        model.settings.setReadingSuspended(true)
        await model.refresh()
        let app = AppDelegate()
        app.model = model
        app.prepareMainWindow()
        let main = try #require(app.mainWindow)
        main.window?.setFrameAutosaveName("")
        let aSession = RemoteDeviceScreenSession(device: a) { _, _, _ in TestRemoteScreenTransport() }
        let bSession = RemoteDeviceScreenSession(device: b) { _, _, _ in TestRemoteScreenTransport() }
        try await aSession.start()
        try await bSession.start()
        let aController = RemoteDeviceWindowController(device: a, session: aSession, presentCompactWindow: { _ in })
        let bController = RemoteDeviceWindowController(device: b, session: bSession, presentCompactWindow: { _ in })
        app.remoteWindows = [aID: aController, bID: bController]
        main.selectDevice(aID)
        try await app.presentConnectedScreen(aID, purpose: .requested)
        model.setDeviceSetting(.appearance("dark"), for: bID)
        #expect(await events.next() == .write(bID))
        #expect(!model.isBusy)
        model.openScreen(for: .remote(a))
        if selectsAnotherDevice {
            let content = try #require(main.window?.contentView)
            let outline = try #require(inspectorViews(content).compactMap { $0 as? NSOutlineView }.first)
            let bRow = try #require((0..<outline.numberOfRows).first { row in
                row != outline.selectedRow && outline.item(atRow: row).map { main.outlineView(outline, shouldSelectItem: $0) } == true
            })
            outline.selectRowIndexes(IndexSet(integer: bRow), byExtendingSelection: false)
        } else {
            main.onShowCompactWindow?(aID)
            let compacted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                MainActor.assumeIsolated { main.liveDeviceIdentifier == nil && !aController.isEmbedded }
            }, object: nil)
            try #require(await XCTWaiter.fulfillment(of: [compacted], timeout: 5) == .completed)
        }
        await source.returnOnNextRead(SimulatorDeviceSettings(appearance: "dark"))
        await source.completeWrite()
        let completed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated { !model.isBusy }
        }, object: nil)
        try #require(await XCTWaiter.fulfillment(of: [completed], timeout: 5) == .completed)
        #expect(main.selectedIdentifiers == [selectsAnotherDevice ? bID : aID])
        #expect(main.liveDeviceIdentifier == (selectsAnotherDevice ? bID : nil))
        #expect(bController.isEmbedded == selectsAnotherDevice)
        #expect(!aController.isEmbedded && aSession.state == .connected)
        try await aSession.stop()
        try await bSession.stop()
        main.window?.close()
    }

    @Test(arguments: [(DeviceInspectorModel.Page.info, DeviceInspectorModel.Content.applications),
                      (.info, .configuration), (.reports, .info)])
    func sameDeviceInventoryUpdatesKeepInspectorRecordsAndSelection(selection: (page: DeviceInspectorModel.Page, content: DeviceInspectorModel.Content)) async throws {
        _ = NSApplication.shared
        let features: Set<String> = ["streamapplist", "installapp", "launchapplication", "configurationprofiles", "listFiles", "transferFiles"]
        func device(_ identifier: String = "inspected-device", name: String = "Phone", features: Set<String> = features) -> InventoryDevice {
            .remote(CoreDeviceDevice(identifier: identifier, udid: nil, kind: .physical, name: name, reportedName: name,
                modelIdentifier: nil, modelName: nil, cpuType: nil, platform: "iOS", osVersion: nil, osBuild: nil,
                connectionState: "connected", pairingState: "paired", transportType: nil, bootState: "booted", preparednessState: nil,
                capabilities: Set(features.map { "com.apple.coredevice.feature." + $0 }), lastConnectedAt: nil, visibilityClass: nil))
        }
        let response: String
        switch (selection.page, selection.content) {
        case (.info, .applications):
            response = #"{"result":{"apps":[{"bundleIdentifier":"fixture.app","name":"Fixture"}]}}"#
        case (.reports, _):
            response = #"{"result":{"files":[{"relativePath":"Fixture.ips","metadata":{},"resources":{"isDirectory":false}}]}}"#
        default:
            response = #"{"result":{"configurationProfiles":[{"payloadIdentifier":"fixture.profile","name":"Fixture"}]}}"#
        }
        let source = ManagerModelSource(devices: [], inspectorResponse: response)
        var events = source.events.makeAsyncIterator()
        let controller = ManagerDeviceInspectorController(model: SimulatorManagerModel(source: source))
        controller.setPage(selection.page)
        controller.inspection.select(selection.content)
        controller.update(device: device(), isManaging: false, isVisible: true)
        #expect(await events.next() == .inspect(device().id))
        await finishInspectorRead(controller.inspection)
        let views = inspectorViews(controller.view)
        let table = try #require(views.compactMap { $0 as? NSTableView }.first {
            $0.accessibilityLabel() == "Installed Applications, Profiles, and Reports"
        })
        // The controller publishes rows in a separate observation callback after the model finishes reading.
        let rowsPublished = XCTNSPredicateExpectation(predicate: NSPredicate { object, _ in
            MainActor.assumeIsolated { (object as? NSTableView)?.numberOfRows == 1 }
        }, object: table)
        try #require(await XCTWaiter.fulfillment(of: [rowsPublished], timeout: 5) == .completed)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let filter = try #require(views.compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "Report Type" })
        if selection.page == .reports {
            filter.selectItem(at: 1)
            NSApp.sendAction(try #require(filter.action), to: filter.target, from: filter)
        }
        await source.holdInspectorReads()
        let updated = device(name: "Renamed Phone")
        controller.update(device: updated, isManaging: false, isVisible: true)
        #expect(await events.next() == .inspect(updated.id))
        #expect(table.numberOfRows == 1 && table.selectedRow == 0)
        #expect(selection.page != .reports || filter.indexOfSelectedItem == 1)
        switch (selection.page, selection.content) {
        case (.info, .applications): #expect(controller.inspection.applications.count == 1)
        case (.reports, _): #expect(controller.inspection.reports.count == 1)
        default: #expect(controller.inspection.profiles.count == 1)
        }
        await source.completeInspectorRead()
        await finishInspectorRead(controller.inspection)
        #expect(controller.inspection.inspector?.device == updated)
        #expect(table.selectedRow == 0)

        controller.update(device: device(name: "Renamed Phone", features: []), isManaging: false, isVisible: true)
        await finishInspectorRead(controller.inspection)
        #expect(controller.inspection.inspector?.device.capabilities.isEmpty == true)
        let toolTip = selection.content == .applications ? "Launch Application" : (selection.page == .reports ? "Download Report…" : "Remove…")
        let action = try #require(views.compactMap { $0 as? NSButton }.first { $0.toolTip == toolTip })
        #expect(!action.isEnabled)

        await source.holdInspectorReads()
        controller.update(device: device("other-device"), isManaging: false, isVisible: true)
        #expect(table.numberOfRows == 0 && table.selectedRow == -1)
        #expect(controller.inspection.applications.isEmpty && controller.inspection.profiles.isEmpty && controller.inspection.reports.isEmpty)
        #expect(await events.next() == .inspect(device("other-device").id))
        await source.completeInspectorRead()
        await finishInspectorRead(controller.inspection)
        controller.stopReading()
    }

    @Test func changingProfileCapabilityClearsTheOldKindEvenWhenTheRefreshFails() async throws {
        _ = NSApplication.shared
        func device(features: Set<String>) -> InventoryDevice {
            .remote(CoreDeviceDevice(identifier: "inspected-device", udid: nil, kind: .physical, name: "Phone", reportedName: "Phone",
                modelIdentifier: nil, modelName: nil, cpuType: nil, platform: "iOS", osVersion: nil, osBuild: nil,
                connectionState: "connected", pairingState: "paired", transportType: nil, bootState: "booted", preparednessState: nil,
                capabilities: Set(features.map { "com.apple.coredevice.feature." + $0 }), lastConnectedAt: nil, visibilityClass: nil))
        }
        let original = device(features: ["provisioningprofiles", "configurationprofiles"])
        let source = ManagerModelSource(devices: [], inspectorResponse:
            #"{"result":{"provisioningProfiles":[{"uuid":"fixture.profile","name":"Fixture"}]}}"#)
        var events = source.events.makeAsyncIterator()
        let controller = ManagerDeviceInspectorController(model: SimulatorManagerModel(source: source))
        controller.inspection.select(.provisioning)
        controller.update(device: original, isManaging: false, isVisible: true)
        #expect(await events.next() == .inspect(original.id))
        await finishInspectorRead(controller.inspection)
        let views = inspectorViews(controller.view)
        let table = try #require(views.compactMap { $0 as? NSTableView }.first {
            $0.accessibilityLabel() == "Installed Applications, Profiles, and Reports"
        })
        let rowsPublished = XCTNSPredicateExpectation(predicate: NSPredicate { object, _ in
            MainActor.assumeIsolated { (object as? NSTableView)?.numberOfRows == 1 }
        }, object: table)
        try #require(await XCTWaiter.fulfillment(of: [rowsPublished], timeout: 5) == .completed)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let remove = try #require(views.compactMap { $0 as? NSButton }.first { $0.toolTip == "Remove…" })
        try #require(remove.isEnabled)

        await source.holdInspectorReads()
        controller.update(device: device(features: ["configurationprofiles"]), isManaging: false, isVisible: true)
        #expect(controller.inspection.content == .configuration)
        #expect(table.numberOfRows == 0 && table.selectedRow == -1)
        #expect(controller.inspection.profiles.isEmpty)
        #expect(await events.next() == .inspect(original.id))
        await source.failInspectorRead()
        await finishInspectorRead(controller.inspection)
        let status = try #require(views.compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "Inspector Status" })
        let failurePublished = XCTNSPredicateExpectation(predicate: NSPredicate { object, _ in
            MainActor.assumeIsolated { (object as? NSTextField)?.stringValue.contains("Unavailable") == true }
        }, object: status)
        try #require(await XCTWaiter.fulfillment(of: [failurePublished], timeout: 5) == .completed)
        #expect(table.numberOfRows == 0 && table.selectedRow == -1)
        #expect(!remove.isEnabled)
        controller.stopReading()
    }

    @Test func sameDeviceInventoryRenameKeepsInfoUntilTheFreshDetailsArrive() async throws {
        _ = NSApplication.shared
        let original = simulator()
        guard case .simulator(let previous) = original else { return }
        let updated = InventoryDevice.simulator(SimulatorHostDevice(identifier: previous.identifier, name: "Inventory Rename",
            descriptiveName: "Inventory Rename", runtimeIdentifier: previous.runtimeIdentifier, runtimeName: previous.runtimeName,
            productFamily: previous.productFamily, state: previous.state))
        func response(_ name: String) -> String {
            "{\"devices\":{\"test-runtime\":[{\"udid\":\"same-udid\",\"name\":\"\(name)\"}]}}"
        }
        let source = ManagerModelSource(devices: [], inspectorResponse: response("Initial Details"))
        var events = source.events.makeAsyncIterator()
        let controller = ManagerDeviceInspectorController(model: SimulatorManagerModel(source: source))
        controller.setPage(.info)
        controller.update(device: original, isManaging: false, isVisible: true)
        #expect(await events.next() == .inspect(original.id))
        await finishInspectorRead(controller.inspection)
        try #require(controller.inspection.infoProperties["name"] == .string("Initial Details"))
        await source.holdInspectorReads()
        controller.update(device: updated, isManaging: false, isVisible: true)
        #expect(await events.next() == .inspect(updated.id))
        #expect(controller.inspection.infoProperties["name"] == .string("Initial Details"))
        await source.completeInspectorRead(response("Fresh Details"))
        await finishInspectorRead(controller.inspection)
        #expect(controller.inspection.infoProperties["name"] == .string("Fresh Details"))
        #expect(controller.inspection.inspector?.device == updated)
        controller.stopReading()
    }

    private func finishInspectorRead(_ inspection: DeviceInspectorModel) async {
        while inspection.reading {
            await withCheckedContinuation { continuation in
                withObservationTracking { _ = inspection.reading } onChange: { continuation.resume() }
            }
        }
    }

    private func inspectorViews(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(inspectorViews)
    }

    @Test func pairingMenuUsesCoreDeviceEligibilityAndTheSelectedDeviceSet() async throws {
        _ = NSApplication.shared
        let feature = "com.apple.coredevice.feature.companiondevicepairing"
        func device(_ id: String, family: String = "Apple Watch", set: String? = nil,
                    pairs: Set<String> = [], capabilities: Set<String> = [feature], available: Bool = true) -> SimulatorHostDevice {
            SimulatorHostDevice(identifier: id, name: id, descriptiveName: id,
                runtimeIdentifier: "runtime-\(id)", runtimeName: "OS", productFamily: family, state: "Shutdown",
                deviceSetPath: set, deviceTypeIdentifier: "type-\(id)", isAvailable: available,
                capabilities: capabilities, pairIdentifiers: pairs)
        }
        let phone = device("phone", family: "iPhone")
        let watch = device("unpaired-watch")
        let source = ManagerModelSource(devices: [phone, watch, device("paired-watch", pairs: ["existing-pair"]),
            device("unknown-watch", capabilities: []), device("other-set-watch", set: "/custom"),
            device("unavailable-watch", available: false), device("other-phone", family: "iPhone", pairs: ["other-pair"]),
            device("unknown-phone", family: "iPhone", capabilities: []),
            device("other-set-phone", family: "iPhone", set: "/custom"),
            device("unavailable-phone", family: "iPhone", available: false)].map(InventoryDevice.simulator))
        let manager = SimulatorManagerModel(source: source)
        await manager.refresh()
        let target = NSObject()
        let menu = SimulatorPairingMenu.make(for: phone, model: manager, target: target, action: #selector(NSApplication.terminate(_:)))
        #expect(manager.pairingCandidates(for: phone).map(\.identifier) == [watch.identifier])
        let actions = menu.items.filter { $0.action != nil }
        #expect(actions.map(\.title) == ["unpaired-watch", "New Watch Simulator…"])
        #expect(actions.allSatisfy { $0.isEnabled })
        guard case .pair(let identifiers) = actions.first?.representedObject as? SimulatorPairingMenu.Action else {
            Issue.record("Expected an existing-watch pairing action")
            return
        }
        #expect(identifiers == [phone.inventoryID, watch.inventoryID])
        let watchMenu = SimulatorPairingMenu.make(for: watch, model: manager, target: target,
                                                 action: #selector(NSApplication.terminate(_:)))
        #expect(manager.canAddPairing(for: watch))
        #expect(manager.pairingCandidates(for: watch).map(\.identifier) == ["other-phone", "phone"])
        #expect(watchMenu.title == "Pair iPhone")
        #expect(watchMenu.items.filter { $0.action != nil }.map(\.title) == ["other-phone", "phone", "New iPhone Simulator…"])
        guard case .pair(let watchIdentifiers) = watchMenu.items.first(where: { $0.action != nil })?.representedObject as? SimulatorPairingMenu.Action else {
            Issue.record("Expected a phone pairing action for the existing watch")
            return
        }
        #expect(watchIdentifiers == [watch.inventoryID, device("other-phone", family: "iPhone").inventoryID])
        guard case .newCompanion(let existingID) = watchMenu.items.last?.representedObject as? SimulatorPairingMenu.Action else {
            Issue.record("Expected an iPhone creation action for the existing watch")
            return
        }
        #expect(existingID == watch.inventoryID)
        let pairedWatch = device("paired-watch", pairs: ["existing-pair"])
        #expect(!manager.canAddPairing(for: pairedWatch))
        #expect(manager.pairingCandidates(for: pairedWatch).isEmpty)
        let pairedMenu = SimulatorPairingMenu.make(for: pairedWatch, model: manager, target: target,
                                                  action: #selector(NSApplication.terminate(_:)))
        #expect(pairedMenu.items.filter { $0.action != nil }.allSatisfy { !$0.isEnabled })
        var events = source.events.makeAsyncIterator()
        manager.manage(.pair, devices: manager.inventory.filter { identifiers.contains($0.id) })
        #expect(await events.next() == .manage(.pair, [phone.inventoryID, watch.inventoryID]))
    }

    @Test func openingASimulatorRetriesItsFailedPostureAfterPresentationSucceeds() async throws {
        guard case .simulator(let simulator) = simulator(deviceSet: "/custom-device-set") else { return }
        let device = InventoryDevice.simulator(simulator.inventoryCopy(ownerXcodeURL: nil, capabilities: DevicePosturePayload.features))
        let source = ManagerModelSource(devices: [device])
        let postures = ManagerPostureConnections()
        var events = source.events.makeAsyncIterator()
        var postureEvents = postures.events.stream.makeAsyncIterator()
        let failures = AsyncStream<Void>.makeStream()
        var failureEvents = failures.stream.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source, makeDevicePosture: postures.model)
        manager.onError = { _ in failures.continuation.yield(()) }
        var requested: [DeviceInventoryID] = []
        manager.onDeviceOpenRequested = { requested.append($0) }
        await manager.refresh()
        manager.openDevice(device.id)
        #expect(requested == [device.id])
        #expect(await events.next() == .open(device.id))
        manager.setOpenDeviceScreens([device.id])
        #expect(manager.isBusy && manager.devicePostures.isEmpty)
        await source.completeOpen()
        #expect(await postureEvents.next() == .observing(device.id))
        #expect(!manager.isBusy)
        let failed = try #require(manager.devicePostures[device.id])
        postures.failCurrentObservation()
        #expect(await postureEvents.next() == .stopped(device.id))
        try #require(failed.state == .failed)

        manager.openDevice(device.id)
        #expect(await events.next() == .open(device.id))
        #expect(manager.devicePostures[device.id] === failed)
        await source.failOpen()
        _ = await failureEvents.next()
        #expect(manager.devicePostures[device.id] === failed && failed.state == .failed)

        manager.openDevice(device.id)
        #expect(await events.next() == .open(device.id))
        #expect(manager.devicePostures[device.id] === failed)
        await source.completeOpen()
        for _ in 0..<200 where manager.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        try #require(!manager.isBusy && manager.devicePostures[device.id] !== failed)
        #expect(await postureEvents.next() == .observing(device.id))
        #expect(failed.state == .stopped && manager.devicePostures[device.id]?.canSelect == true)
        #expect(postures.identifiers == [device.id, device.id])
        await manager.stopDevicePostures()
        #expect(await postureEvents.next() == .stopped(device.id))
    }

    @Test func connectingAScreenReplacesItsFailedPostureOwnerAfterDrainingIt() async throws {
        let features = DevicePosturePayload.features
        let data = try JSONSerialization.data(withJSONObject: ["result": ["devices": [[
            "identifier": "remote-command", "properties": ["hardware": ["reality": "physical", "hardwareModel": "V68AP"],
                "state": ["name": "Duo"], "connection": ["state": "connected"]],
            "capabilities": features.sorted().map { ["featureIdentifier": $0] }]]]])
        let device = InventoryDevice.remote(try #require(CoreDeviceInventoryDecoder.decode(data).first))
        let postures = ManagerPostureConnections()
        var events = postures.events.stream.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: ManagerModelSource(devices: [device]), makeDevicePosture: postures.model)
        await manager.refresh()
        manager.setOpenDeviceScreens([device.id])
        #expect(await events.next() == .observing(device.id))
        let failed = try #require(manager.devicePostures[device.id])
        await manager.deviceScreenDidConnect(device.id)
        #expect(manager.devicePostures[device.id] === failed)
        postures.failCurrentObservation()
        #expect(await events.next() == .stopped(device.id))
        #expect(failed.state == .failed && !failed.canSelect)
        await manager.deviceScreenDidConnect(device.id)
        #expect(await events.next() == .observing(device.id))
        #expect(failed.state == .stopped)
        #expect(manager.devicePostures[device.id] !== failed && manager.devicePostures[device.id]?.canSelect == true)
        #expect(postures.identifiers == [device.id, device.id])
        await manager.stopDevicePostures()
        #expect(await events.next() == .stopped(device.id))
    }

    @Test func restartingAnOpenSimulatorReplacesPostureObservationAfterManagementFinishes() async throws {
        guard case .simulator(let simulator) = simulator(deviceSet: "/custom-device-set") else { return }
        let device = InventoryDevice.simulator(simulator.inventoryCopy(ownerXcodeURL: nil, capabilities: DevicePosturePayload.features))
        let source = ManagerModelSource(devices: [device])
        let postures = ManagerPostureConnections()
        var events = source.events.makeAsyncIterator()
        var postureEvents = postures.events.stream.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source, makeDevicePosture: postures.model)
        var failures: [any Error] = []
        manager.onError = { failures.append($0) }
        await manager.refresh()
        manager.setOpenDeviceScreens([device.id])
        #expect(await postureEvents.next() == .observing(device.id))
        #expect(manager.devicePostures[device.id]?.canSelect == true)

        await source.holdManagement()
        manager.manage(.restart, devices: [device])
        #expect(await postureEvents.next() == .stopped(device.id))
        #expect(await events.next() == .manage(.restart, [device.id]))
        // Inventory still advertises the old booted simulator during restart.
        await manager.inventoryDidChange()
        manager.setOpenDeviceScreens([device.id])
        #expect(manager.devicePostures[device.id] == nil)
        #expect(postures.identifiers == [device.id])
        await source.completeManagement(.restart)
        #expect(await postureEvents.next() == .observing(device.id))
        #expect(postures.identifiers == [device.id, device.id])
        #expect(manager.devicePostures[device.id]?.canSelect == true)
        #expect(failures.isEmpty)

        // A presentation-preparation failure must restore controls for a screen
        // that remains open, even though the backend management never started.
        manager.beforeManagingSimulators = { _, _ in throw ManagerModelSource.Failure.unavailable }
        manager.manage(.restart, devices: [device])
        #expect(await postureEvents.next() == .stopped(device.id))
        #expect(await postureEvents.next() == .observing(device.id))
        #expect(postures.identifiers.count == 3 && failures.count == 1)
        manager.setOpenDeviceScreens([])
        manager.closeDevice(device.id, keepingDeviceRunning: true, after: Task {})
        await manager.inventoryDidChange()
        #expect(await postureEvents.next() == .stopped(device.id))
        #expect(await events.next() == .close(device.id))
        #expect(manager.devicePostures.isEmpty && postures.identifiers.count == 3)
        await manager.stopDevicePostures()
    }

    @Test func aRemoteScreenUsesItsCommandIdentityAndClosingDuringManagementPreventsResubscription() async throws {
        let features = DevicePosturePayload.features.union(["com.apple.coredevice.feature.rebootdevice"])
        let data = try JSONSerialization.data(withJSONObject: ["result": ["devices": [[
            "identifier": "coredevice-command-id", "properties": [
                "hardware": ["reality": "physical", "udid": "different-hardware-udid", "hardwareModel": "V68AP"],
                "state": ["name": "Remote Duo"], "connection": ["state": "connected"]],
            "capabilities": features.sorted().map { ["featureIdentifier": $0] }]]]])
        let device = InventoryDevice.remote(try #require(CoreDeviceInventoryDecoder.decode(data).first))
        let source = ManagerModelSource(devices: [device])
        let postures = ManagerPostureConnections()
        var events = source.events.makeAsyncIterator()
        var postureEvents = postures.events.stream.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source, makeDevicePosture: postures.model)
        await manager.refresh()
        manager.setOpenDeviceScreens([device.id])
        #expect(await postureEvents.next() == .observing(.coreDevice("coredevice-command-id")))
        #expect(manager.devicePostures[device.id]?.confirmedPosture == .closed)
        manager.beforeManagingRemoteDevices = { identifiers in
            #expect(identifiers == [device.id])
            // stopAndClose removes the actual remote session before management.
            manager.setOpenDeviceScreens([])
        }
        await source.holdManagement()
        manager.manage(.restart, devices: [device])
        #expect(await postureEvents.next() == .stopped(device.id))
        #expect(await events.next() == .manage(.restart, [device.id]))
        await manager.inventoryDidChange()
        #expect(manager.devicePostures.isEmpty && postures.identifiers == [device.id])
        await source.completeManagement(.restart)
        for _ in 0..<200 where !manager.managingDeviceIDs.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(manager.managingDeviceIDs.isEmpty)
        #expect(manager.devicePostures.isEmpty && postures.identifiers == [device.id])
        manager.setOpenDeviceScreens([device.id])
        #expect(await postureEvents.next() == .observing(device.id))
        #expect(postures.identifiers == [device.id, device.id])
        await manager.stopDevicePostures()
        #expect(await postureEvents.next() == .stopped(device.id))
    }

    @Test func screenRestorationKeepsItsSourceAndPresentation() async throws {
        let device = SimulatorDeviceIdentifier("test-device", deviceSetPath: "/custom/testing devices")
        let xcode = URL(fileURLWithPath: "/Applications/Other Xcode.app", isDirectory: true)
        let restoration = SimulatorScreenRestoration(device: device, xcodeURL: xcode, presentation: .compact)
        let decoded = try #require(SimulatorScreenRestoration(url: restoration.url))
        #expect(decoded == restoration)
        let source = ManagerModelSource(devices: [simulator()])
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source)
        var presented = false
        let presentations = AsyncStream<Void>.makeStream()
        var presentationEvents = presentations.stream.makeAsyncIterator()
        manager.restoreScreen(decoded) {
            #expect(!manager.inventory.isEmpty)
            presented = true
            presentations.continuation.yield(())
        }
        #expect(await events.next() == .open(decoded.deviceID))
        #expect(await source.lastOpenXcodeURL == xcode)
        #expect(!presented)
        await source.completeOpen()
        await presentationEvents.next()
        try await manager.quitRenderer(keepingDevicesRunning: true)
        #expect(presented)
    }


    @Test func relaunchWaitsForTheOldProcessToExit() async throws {
        let owner = Process()
        owner.executableURL = URL(fileURLWithPath: "/bin/cat")
        let input = Pipe()
        owner.standardInput = input
        owner.standardOutput = FileHandle.nullDevice
        try owner.run()
        defer { if owner.isRunning { owner.terminate() } }
        let ready = AsyncStream<Void>.makeStream()
        var events = ready.stream.makeAsyncIterator()
        var didExit = false
        let waiting = Task {
            await ManagerRelaunch.waitForExit(of: owner.processIdentifier) { ready.continuation.yield(()) }
            didExit = true
        }
        await events.next()
        #expect(owner.isRunning && !didExit)
        owner.terminate()
        await waiting.value
        #expect(didExit)
    }


    @Test func frameworkSettingPersistsOverrideAndRestoresDefault() throws {
        let suite = "NeoSimulator.UIFrameworkSettingsTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = UIFrameworkSettings(defaults: defaults, discover: { [] })
        #expect(settings.selectedXcodeURL == nil && !settings.needsRestart)
        let xcode = URL(fileURLWithPath: "/Applications/Xcode 27.1.app", isDirectory: true)
        settings.select(xcode)
        #expect(settings.needsRestart)
        #expect(UIFrameworkSettings.selection(in: defaults) == xcode)
        let relaunched = UIFrameworkSettings(defaults: defaults, discover: { [] })
        #expect(relaunched.selectedXcodeURL == xcode && !relaunched.needsRestart)
        relaunched.select(nil)
        #expect(relaunched.needsRestart && UIFrameworkSettings.selection(in: defaults) == nil)
        settings.select(nil)
        #expect(!settings.needsRestart)
    }

    @Test func forceCanJoinNormalShutdownWithoutTheOriginalRequestUnlockingIt() async throws {
        let device = simulator()
        let other = InventoryDevice.simulator(SimulatorHostDevice(identifier: "other", name: "Other Phone", descriptiveName: "Other Phone",
            runtimeIdentifier: "test-runtime", runtimeName: "iOS", productFamily: "iPhone", state: "Booted"))
        let source = ManagerModelSource(devices: [device, other], holdsManagement: true)
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source)
        manager.manage(.shutdown, devices: [device])
        #expect(await events.next() == .manage(.shutdown, [device.id]))
        manager.openScreen(for: other)
        #expect(await events.next() == .open(other.id))
        #expect(manager.isBusy)
        #expect(!manager.canManage(.erase, deviceIDs: [other.id]))
        #expect(manager.canManage(.forceShutdown, deviceIDs: [device.id]))
        manager.manage(.forceShutdown, devices: [device])
        #expect(await events.next() == .manage(.forceShutdown, [device.id]))
        #expect(!manager.canManage(.forceShutdown, deviceIDs: [device.id]))
        let changes = AsyncStream<Set<DeviceInventoryID>>.makeStream()
        var changed = changes.stream.makeAsyncIterator()
        withObservationTracking {
            _ = manager.managingDeviceIDs
        } onChange: {
            Task { @MainActor in changes.continuation.yield(manager.managingDeviceIDs) }
        }
        await source.completeManagement(.shutdown)
        #expect(await changed.next() == [device.id])
        #expect(!manager.canManage(.restart, deviceIDs: [device.id]))
        await source.completeManagement(.forceShutdown)
        await source.completeOpen()
        try await manager.quitRenderer(keepingDevicesRunning: true)
        #expect(manager.managingDeviceIDs.isEmpty)
    }

    @Test(arguments: [DeviceManagementAction.restart, .erase, .remove])
    func forceCannotJoinOtherManagementRequests(_ action: DeviceManagementAction) async throws {
        let device = simulator()
        let source = ManagerModelSource(devices: [device], holdsManagement: true)
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source)
        manager.manage(action, devices: [device])
        #expect(await events.next() == .manage(action, [device.id]))
        #expect(!manager.canManage(.forceShutdown, deviceIDs: [device.id]))
        manager.manage(.forceShutdown, devices: [device])
        #expect(await source.managementRequests == 1)
        await source.completeManagement(action)
        try await manager.quitRenderer(keepingDevicesRunning: true)
    }

    @Test func acceptedEditsMergeSnapshotsAndDrainBeforeQuit() async throws {
        let device = simulator()
        let queued = simulator(deviceSet: "/queued-device-set")
        let source = ManagerModelSource(devices: [device, queued])
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source)
        await manager.refresh()
        manager.settings.inspect(device, selectionCount: 1)
        #expect(await events.next() == .read(device.id))
        await source.completeRead(settings(appearance: "light", contentSize: "medium"))
        await manager.settings.finishReading()

        manager.openDevice(device.id)
        #expect(await events.next() == .open(device.id))
        manager.openDevice(queued.id)
        #expect(manager.openingDeviceIDs == [device.id, queued.id])
        manager.setDeviceSetting(.appearance("dark"), for: device.id)
        manager.setDeviceSetting(.contentSize("large"), for: device.id)
        #expect(manager.settings.settings?.appearance == "dark")
        #expect(manager.settings.settings?.contentSize == "large")
        manager.cancelOpening(queued.id)
        manager.cancelOpening(device.id)
        #expect(source.cancelledOpenIDs == [device.id, queued.id])
        // The lower IPC deliberately returns success after cancellation.
        await source.completeOpen()
        #expect(await events.next() == .write(device.id))
        #expect(manager.openingDeviceIDs.isEmpty)
        await source.completeWrite()
        #expect(await events.next() == .write(device.id))
        let inputs = await source.writeInputs
        #expect(inputs.count == 2)
        #expect(inputs[1]?.appearance == "dark")
        #expect(inputs[1]?.contentSize == "medium")

        let beganQuitting = AsyncStream<Void>.makeStream()
        var quitEvents = beganQuitting.stream.makeAsyncIterator()
        let quitting = Task {
            beganQuitting.continuation.yield(())
            try await manager.quitRenderer(keepingDevicesRunning: true)
        }
        await quitEvents.next()
        await source.completeWrite()
        #expect(await events.next() == .quit)
        try await quitting.value
        #expect(manager.settings.settings?.appearance == "dark")
        #expect(manager.settings.settings?.contentSize == "large")
        #expect(await source.readCount == 1)
        manager.resumeAfterCancelledQuit()
        manager.openDevice(device.id)
        #expect(await events.next() == .open(device.id))
        await source.completeOpen()
        try await manager.quitRenderer(keepingDevicesRunning: true)
        #expect(await events.next() == .quit)
    }

    @Test func failedOpenCancellationPreventsQuitAndAllowsRetry() async throws {
        let device = simulator()
        let source = ManagerModelSource(devices: [device])
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source)
        manager.openDevice(device.id)
        #expect(await events.next() == .open(device.id))
        let quitting = Task.immediate { try await manager.quitRenderer(keepingDevicesRunning: true) }
        await source.failOpen()
        do { try await quitting.value; Issue.record("Quit ignored failed open cleanup") }
        catch {}
        #expect(await source.quitCount == 0)
        manager.openDevice(device.id)
        #expect(await events.next() == .open(device.id))
        await source.completeOpen()
        try await manager.quitRenderer(keepingDevicesRunning: true)
        #expect(await source.quitCount == 1)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func retiringAnOpenPublishesInventoryEventsDeferredWhileBusy(_ cancelled: Bool) async throws {
        func remote(_ name: String) throws -> InventoryDevice {
            let data = try JSONSerialization.data(withJSONObject: ["result": ["devices": [["identifier": "remote",
                "properties": ["hardware": ["reality": "physical"], "state": ["name": name]]]]]])
            return .remote(try #require(CoreDeviceInventoryDecoder.decode(data).first))
        }
        let device = simulator()
        let next = simulator(deviceSet: "/next-set")
        let source = ManagerModelSource(devices: [device, next, try remote("Original")])
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source)
        await manager.refresh()
        manager.openDevice(device.id)
        #expect(await events.next() == .open(device.id))
        manager.openDevice(next.id)
        await source.setDevices([device, next, try remote("Updated")])
        await manager.inventoryDidChange()
        #expect(manager.isBusy && manager.inventory.last?.name == "Original")
        if cancelled {
            manager.cancelOpening(device.id)
            await source.completeOpen()
        } else { await source.failOpen() }
        // Admission of the next FIFO operation follows retirement of the first open and its refresh.
        #expect(await events.next() == .open(next.id))
        #expect(manager.inventory.last?.name == "Updated")
        await source.completeOpen()
        try await manager.quitRenderer(keepingDevicesRunning: true)
    }

    @Test func editingDuringRefreshStillReadsExternalChanges() async throws {
        let device = simulator()
        let source = ManagerModelSource(devices: [device])
        var events = source.events.makeAsyncIterator()
        let model = DeviceSettingsModel(source: source)
        model.inspect(device, selectionCount: 1)
        #expect(await events.next() == .read(device.id))
        await source.completeRead(settings(appearance: "light", contentSize: "medium"))
        await model.finishReading()

        model.requestRefresh()
        #expect(await events.next() == .read(device.id))
        let beganApplying = AsyncStream<Void>.makeStream()
        var applyEvents = beganApplying.stream.makeAsyncIterator()
        let edit = model.accept(.contentSize("large"), for: device)
        let applying = Task {
            beganApplying.continuation.yield(())
            try await model.apply(edit)
        }
        await applyEvents.next()
        await source.completeRead(settings(appearance: "dark", contentSize: "medium"))
        #expect(await events.next() == .write(device.id))
        await source.returnOnNextRead(settings(appearance: "dark", contentSize: "large"))
        await source.completeWrite()
        try await applying.value
        await model.finishReading()

        #expect(model.settings?.appearance == "dark")
        #expect(model.settings?.contentSize == "large")
    }

    @Test func sameDeviceMetadataKeepsLoadedValuesAndAnInFlightRead() async throws {
        let device = simulator()
        let renamed = simulator(name: "Renamed Phone")
        let source = ManagerModelSource(devices: [device])
        var events = source.events.makeAsyncIterator()
        let model = DeviceSettingsModel(source: source)
        model.inspect(device, selectionCount: 1)
        #expect(await events.next() == .read(device.id))
        await source.completeRead(settings(appearance: "light"))
        await model.finishReading()

        model.requestRefresh()
        #expect(await events.next() == .read(device.id))
        model.inspect(renamed, selectionCount: 1)
        #expect(model.device == renamed && model.settings?.appearance == "light")
        await source.completeRead(settings(appearance: "dark"))
        #expect(await events.next() == .read(device.id))
        #expect(model.settings?.appearance == "dark")
        await source.completeRead(settings(appearance: "light", contentSize: "large"))
        await model.finishReading()
        #expect(model.settings?.contentSize == "large")

        model.inspect(simulator(name: "Renamed Phone", state: "Shutdown"), selectionCount: 1)
        #expect(model.device?.canInspectSettings == false && model.settings?.contentSize == "large")
        model.inspect(renamed, selectionCount: 1)
        #expect(await events.next() == .read(device.id))
        await source.completeRead(settings(appearance: "dark", contentSize: "large"))
        await model.finishReading()
        #expect(model.device?.canInspectSettings == true && model.settings?.appearance == "dark")
    }

    @Test func sameDeviceMetadataKeepsAcceptedEditsAndTheirConfirmation() async throws {
        let device = simulator()
        let source = ManagerModelSource(devices: [device])
        var events = source.events.makeAsyncIterator()
        let model = DeviceSettingsModel(source: source)
        model.inspect(device, selectionCount: 1)
        #expect(await events.next() == .read(device.id))
        await source.completeRead(settings(appearance: "light", contentSize: "medium"))
        await model.finishReading()

        model.setReadingSuspended(true)
        let edit = model.accept(.contentSize("large"), for: device)
        model.inspect(simulator(name: "Renamed Phone"), selectionCount: 1)
        #expect(model.settings?.appearance == "light" && model.settings?.contentSize == "large")
        let applying = Task { try await model.apply(edit) }
        #expect(await events.next() == .write(device.id))
        #expect(await source.writeInputs.last??.appearance == "light")
        let latest = simulator(name: "Latest Phone")
        model.inspect(latest, selectionCount: 1)
        await source.completeWrite()
        try await applying.value
        #expect(model.device == latest && model.settings?.contentSize == "large")

        model.setReadingSuspended(false)
        #expect(await events.next() == .read(device.id))
        await source.completeRead(settings(appearance: "dark", contentSize: "large"))
        await model.finishReading()
        #expect(model.settings?.appearance == "dark" && model.settings?.contentSize == "large")
    }

    @Test func switchingDeviceSetsDiscardsTheCancelledResult() async throws {
        let first = simulator(deviceSet: "/first")
        let second = simulator(deviceSet: "/second")
        let source = ManagerModelSource(devices: [first, second])
        var events = source.events.makeAsyncIterator()
        let model = DeviceSettingsModel(source: source)
        model.inspect(first, selectionCount: 1)
        #expect(await events.next() == .read(first.id))
        model.inspect(second, selectionCount: 1)
        // The source deliberately completes even after cancellation, as an in-flight IPC can.
        await source.completeRead(settings(appearance: "dark"))
        #expect(await events.next() == .read(second.id))
        #expect(model.settings == nil)
        await source.completeRead(settings(appearance: "light"))
        await model.finishReading()
        #expect(model.device?.id == second.id)
        #expect(model.settings?.appearance == "light")
    }

    @Test func clearingSelectionDiscardsTheCancelledResult() async throws {
        let device = simulator()
        let source = ManagerModelSource(devices: [device])
        var events = source.events.makeAsyncIterator()
        let model = DeviceSettingsModel(source: source)
        model.inspect(device, selectionCount: 1)
        #expect(await events.next() == .read(device.id))
        model.inspect(nil, selectionCount: 0)
        await source.completeRead(settings(appearance: "dark"))
        await model.finishReading()
        #expect(model.device == nil)
        #expect(model.settings == nil)
        #expect(model.issue == nil)
        #expect(!model.isLoading)
    }

    @Test func partialEditConfirmsActualValuesBeforeReportingTheFailure() async throws {
        let device = simulator()
        let source = ManagerModelSource(devices: [device])
        var events = source.events.makeAsyncIterator()
        let reported = AsyncStream<(SimulatorHostFailure?, Bool?, String?)>.makeStream()
        var errors = reported.stream.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source)
        manager.onError = { error in
            reported.continuation.yield((error as? SimulatorHostFailure,
                manager.settings.settings?.boldText, manager.settings.settings?.contentSize))
        }
        await manager.refresh()
        manager.settings.inspect(device, selectionCount: 1)
        #expect(await events.next() == .read(device.id))
        await source.completeRead(SimulatorDeviceSettings(contentSize: "medium", boldText: false))
        await manager.settings.finishReading()

        manager.setDeviceSetting(.boldText(true), for: device.id)
        #expect(await events.next() == .write(device.id))
        manager.setDeviceSetting(.contentSize("large"), for: device.id)
        await source.failWrite(afterApplying: true)
        let failure = try #require(await errors.next())
        #expect(failure.0?.technicalDetails == "Unavailable")
        #expect(failure.1 == true && failure.2 == "large")
        #expect(await events.next() == .write(device.id))
        #expect(await source.writeInputs.last??.boldText == true)
        await source.returnOnNextRead(SimulatorDeviceSettings(contentSize: "large", boldText: true))
        await source.completeWrite()
        #expect(await events.next() == .read(device.id))
        await manager.settings.finishReading()
        #expect(manager.settings.settings?.boldText == true && manager.settings.settings?.contentSize == "large")
        try await manager.quitRenderer(keepingDevicesRunning: true)
    }

    @Test func rapidSwitchEditsKeepTheirLatestValuesWhenAnEarlierWriteFails() async throws {
        let device = simulator()
        let source = ManagerModelSource(devices: [device])
        var events = source.events.makeAsyncIterator()
        let failures = AsyncStream<any Error>.makeStream()
        var failureEvents = failures.stream.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source)
        manager.onError = { failures.continuation.yield($0) }
        await manager.refresh()
        manager.settings.inspect(device, selectionCount: 1)
        #expect(await events.next() == .read(device.id))
        await source.completeRead(SimulatorDeviceSettings(showBorders: false, reduceTransparency: false))
        await manager.settings.finishReading()

        manager.setDeviceSetting(.showBorders(true), for: device.id)
        #expect(manager.settings.settings?.showBorders == true)
        #expect(await events.next() == .write(device.id))
        manager.setDeviceSetting(.reduceTransparency(true), for: device.id)
        manager.setDeviceSetting(.showBorders(false), for: device.id)
        #expect(manager.settings.settings?.showBorders == false)
        #expect(manager.settings.settings?.reduceTransparency == true)
        await source.failWrite()
        #expect(await events.next() == .write(device.id))
        #expect(await failureEvents.next() is ManagerModelSource.Failure)
        #expect(manager.settings.settings?.showBorders == false)
        #expect(manager.settings.settings?.reduceTransparency == true)
        await source.completeWrite()
        #expect(await events.next() == .write(device.id))
        #expect(manager.settings.settings?.showBorders == false)
        #expect(manager.settings.settings?.reduceTransparency == true)
        await source.returnOnNextRead(SimulatorDeviceSettings(showBorders: false, reduceTransparency: true))
        await source.completeWrite()
        #expect(await events.next() == .read(device.id))
        await manager.settings.finishReading()
        #expect(manager.settings.settings?.showBorders == false)
        #expect(manager.settings.settings?.reduceTransparency == true)
        try await manager.quitRenderer(keepingDevicesRunning: true)
    }

    @Test(arguments: [false, true])
    func pendingEditsStayWithTheirDeviceAcrossSelectionChanges(_ partialFailure: Bool) async throws {
        let first = simulator(deviceSet: "/first")
        let second = simulator(deviceSet: "/second")
        let source = ManagerModelSource(devices: [first, second])
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source)
        await manager.refresh()
        manager.settings.inspect(first, selectionCount: 1)
        #expect(await events.next() == .read(first.id))
        await source.completeRead(SimulatorDeviceSettings(showBorders: false))
        await manager.settings.finishReading()
        manager.setDeviceSetting(.showBorders(true), for: first.id)
        #expect(await events.next() == .write(first.id))

        manager.settings.inspect(second, selectionCount: 1)
        #expect(manager.settings.settings == nil)
        if partialFailure { await source.failWrite(afterApplying: true) }
        else { await source.completeWrite() }
        #expect(await events.next() == .read(second.id))
        await source.completeRead(SimulatorDeviceSettings(showBorders: false))
        await manager.settings.finishReading()
        #expect(manager.settings.settings?.showBorders == false)

        manager.settings.inspect(first, selectionCount: 1)
        #expect(await events.next() == .read(first.id))
        await source.completeRead(SimulatorDeviceSettings(showBorders: true))
        await manager.settings.finishReading()
        #expect(manager.settings.settings?.showBorders == true)
        try await manager.quitRenderer(keepingDevicesRunning: true)
    }

    @Test func artworkResolvesXcodeBeforeOpeningAScreen() async throws {
        let device = simulator(deviceSet: "/tmp/artwork-device-set")
        let source = ManagerModelSource(devices: [device])
        let model = SimulatorManagerModel(source: source)
        let urls = await model.artworkXcodeURLs(for: device)
        #expect(urls == [URL(fileURLWithPath: "/Applications/Test Xcode.app")])
        #expect(await source.artworkXcodeRequests == [device.id])
    }

    @Test func missingModelUsesFamilyPreview() async throws {
        let artwork = DeviceArtworkCache().artwork(modelIdentifier: nil, family: "Mac", xcodeURL: nil)
        let image = try #require(await artwork.hardwarePreview())
        let expected = try #require(NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: nil))
        #expect(try #require(image.tiffRepresentation) == #require(expected.tiffRepresentation))
    }

    @Test func remoteDuoResolvesInstalledArtworkWithoutOpeningAScreen() async {
        let device = InventoryDevice.remote(CoreDeviceDevice(identifier: "remote-duo", udid: nil,
            kind: .physical, name: "Duo", reportedName: "Duo", modelIdentifier: "iPhone19,4", modelName: "iPhone Duo", cpuType: nil,
            platform: "iOS", osVersion: nil, osBuild: nil, connectionState: "connected",
            pairingState: "paired", transportType: nil, bootState: "booted", preparednessState: nil, capabilities: [],
            lastConnectedAt: nil, visibilityClass: nil))
        let source = ManagerModelSource(devices: [device])
        let model = SimulatorManagerModel(source: source)
        let artwork = DeviceArtworkCache().artwork(modelIdentifier: device.modelIdentifier, family: "iPhone",
            xcodeURL: nil, resolveXcodeURLs: { await model.artworkXcodeURLs(for: device) })
        while artwork.symbol == nil {
            await withCheckedContinuation { continuation in
                withObservationTracking { _ = artwork.symbol } onChange: { continuation.resume() }
            }
        }
        #expect(await source.installedXcodeReadCount == 1)
        #expect(await source.artworkXcodeRequests.isEmpty)
    }

    @Test(arguments: [false, true])
    func forceShutdownPrecedesPresentationCleanupAndRetainsBothFailures(remote: Bool) async throws {
        let targets = try ["A", "B"].map { identifier -> InventoryDevice in
            if !remote {
                return .simulator(SimulatorHostDevice(identifier: identifier, name: identifier, descriptiveName: identifier,
                    runtimeIdentifier: "runtime", runtimeName: "iOS", productFamily: "iPhone", state: "Booted",
                    capabilities: ["com.apple.dt.coredevice.device.shutdown"]))
            }
            let data = try JSONSerialization.data(withJSONObject: ["result": ["devices": [[
                "identifier": identifier, "properties": ["hardware": ["reality": "virtual"],
                    "state": ["name": identifier], "connection": ["state": "connected", "pairingState": "paired"]],
                "capabilities": [["featureIdentifier": "com.apple.dt.coredevice.device.shutdown"]]
            ]]]])
            return .remote(try #require(CoreDeviceInventoryDecoder.decode(data).first))
        }
        let source = ManagerModelSource(devices: targets, managementFailureID: remote ? nil : targets[0].id)
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source)
        let cleanups = AsyncStream<(DeviceInventoryID, CheckedContinuation<Void, any Error>)>.makeStream()
        var cleanupEvents = cleanups.stream.makeAsyncIterator()
        let failures = AsyncStream<any Error>.makeStream()
        var failureEvents = failures.stream.makeAsyncIterator()
        let cleanup: @MainActor ([DeviceInventoryID]) async throws -> Void = { identifiers in
            #expect(identifiers.count == 1)
            try await withCheckedThrowingContinuation { waiting in
                cleanups.continuation.yield((identifiers[0], waiting))
            }
        }
        manager.beforeManagingSimulators = { _, devices in try await cleanup(devices.map(\.id)) }
        manager.beforeManagingRemoteDevices = { try await cleanup(Array($0)) }
        manager.onError = { failures.continuation.yield($0) }
        manager.manage(.forceShutdown, devices: targets)
        #expect(await events.next() == .manage(.forceShutdown, targets.map(\.id)))
        let first = try #require(await cleanupEvents.next())
        #expect(first.0 == targets[0].id)
        #expect(manager.managingDeviceIDs == Set(targets.map(\.id)))
        first.1.resume(throwing: CLIError.io("cleanup-fixture", "Recording could not be saved"))
        let second = try #require(await cleanupEvents.next())
        #expect(second.0 == targets[1].id)
        second.1.resume()
        let failure = try #require(await failureEvents.next() as? LocalizedError)
        let details = try #require(failure.recoverySuggestion)
        #expect(details.contains("Native shutdown failed") == !remote)
        #expect(details.contains("Recording could not be saved"))
        if remote { #expect(details.contains("Completed: Forcibly shut down")) }
        #expect(await source.managementRequests == 1)
    }

    @Test func normalShutdownStillAwaitsPresentationCleanupBeforeNativeManagement() async throws {
        let device = simulator()
        let source = ManagerModelSource(devices: [device])
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source)
        let started = AsyncStream<CheckedContinuation<Void, any Error>>.makeStream()
        var cleanupEvents = started.stream.makeAsyncIterator()
        manager.beforeManagingSimulators = { _, _ in
            try await withCheckedThrowingContinuation { started.continuation.yield($0) }
        }
        manager.manage(.shutdown, devices: [device])
        let cleanup = try #require(await cleanupEvents.next())
        #expect(await source.preparationRequests == 1)
        #expect(await source.managementRequests == 0)
        cleanup.resume()
        #expect(await events.next() == .manage(.shutdown, [device.id]))
        try await manager.quitRenderer(keepingDevicesRunning: true)
    }

    @Test func infoCardsUseLiveValuesAndRetainKnownInventoryFallbacks() throws {
        let information = DeviceInformation(device: simulator(), properties: [
            "name": .string("Renamed Phone"), "operatingSystem": .string("iOS 27.2"),
            "modelName": .string("iPhone 18 Pro"),
            "coreDeviceIdentifier": .string("coredevice-command-id"),
            "hardware": .object(["serialNumber": .string("serial"),
                "cpuType": .object(["type": .integer(16777228), "subtype": .integer(0)]),
                "platform": .string("iOS"), "productType": .string("iPhone99,2"), "reality": .string("simulated")]),
            "state": .string("Booted"), "bootState": .string("shutdown"), "preparednessState": .integer(0),
            "connection": .object(["state": .string("disconnected"), "pairingState": .string("paired"),
                "transportType": .string("sameMachine"), "lastConnectionDate": .date(Date(timeIntervalSinceReferenceDate: 100))]),
        ])
        func value(_ id: String) -> String? { information.fields.first { $0.id == [id] }?.value }
        #expect(value("name") == "Renamed Phone")
        #expect(value("operatingSystem") == "iOS 27.2")
        #expect(value("modelName") == "iPhone 18 Pro")
        #expect(value("udid") == "same-udid")
        #expect(information.fields.filter { $0.id == ["modelName"] || $0.id == ["udid"] }.allSatisfy { $0.group == .hardware })
        let serial = try #require(information.fields.first { $0.id == ["hardware", "serialNumber"] })
        #expect(serial.value == "serial" && serial.group == .hardware)
        let coreID = try #require(information.fields.first { $0.id == ["coreDeviceIdentifier"] })
        #expect(coreID.title == "CoreDevice ID" && coreID.value == "coredevice-command-id" && coreID.group == .essential)
        let hardware = Dictionary(uniqueKeysWithValues: information.fields.filter { $0.group == .hardware }.map { ($0.title, $0.value) })
        #expect(hardware["CPU Type"] == "arm64" && hardware["Platform"] == "iOS")
        #expect(hardware["Product Type"] == "iPhone99,2" && hardware["Fidelity"] == "Simulated")
        #expect(information.fields.first { $0.id == ["bootState"] }?.value == "ShutDown")
        #expect(information.fields.first { $0.title == "DDI Services" }?.value == "Disabled")
        #expect(information.fields.first { $0.id == ["state"] }?.value == "Booted")
        let connection = information.fields.filter { $0.group == .connection }
        #expect(Set(connection.map(\.title)) == ["Tunnel State", "Pairing State", "Transport Type", "Last Connection Date"])
        #expect(connection.first { $0.id == ["connection", "state"] }?.value == "Disconnected")
        #expect(connection.first { $0.id == ["connection", "pairingState"] }?.value == "Paired")
        #expect(connection.first { $0.id == ["connection", "transportType"] }?.value == "Same Machine")
        #expect(connection.first { $0.id == ["connection", "lastConnectionDate"] }?.value == Date(timeIntervalSinceReferenceDate: 100).formatted())
    }

    @Test(arguments: zip([1, 3], ["Disabled", "Enabled"]))
    func ddiServicesUsesTheAdvertisedFlagAmongOtherPreparednessBits(_ raw: Int64, _ expected: String) {
        let information = DeviceInformation(device: simulator(), properties: [
            "state": .object(["preparednessState": .integer(raw)]),
        ])
        #expect(information.fields.first { $0.title == "DDI Services" }?.value == expected)
    }

    @Test func remoteInfoUsesAvailablePropertiesWithoutSubstitutingItsCommandIDForUDID() async throws {
        let remote = CoreDeviceDevice(identifier: "command-id", udid: nil,
            kind: .physical, name: "Known Phone", reportedName: "Known Phone", modelIdentifier: "iPhone19,2", modelName: "iPhone 18 Pro", cpuType: nil,
            platform: "iOS", osVersion: "27.1", osBuild: nil, connectionState: "connected",
            pairingState: "paired", transportType: nil, bootState: "booted", preparednessState: nil, capabilities: [],
            lastConnectedAt: nil, visibilityClass: nil)
        let payload = Data(#"""
        {"result":{"properties":{
          "state":{"name":"Current Phone","bootState":"futureBoot"},
          "hardware":{"cpuType":{"type":16777228,"subtype":18446744071562067970},"reality":"futureReality"},
          "connection":{"transportType":"USB","state":"futureRawState"},
          "software":{"osVersionNumber":{"stringValue":"27.2"},"osBuildVersions":{"buildVersion":{"name":"27C100"}}},
          "configuration":{"displays":[{"name":"Primary"},{"name":"External"}]}
        }}}
        """#.utf8)
        let snapshot = await DeviceInspector(device: .remote(remote), simulatorXcodeURL: nil, transport: .init(run: { command in
            #expect(command.arguments.starts(with: ["device", "info", "details"]))
            return CommandOutput(terminationStatus: 0, stdout: payload, stderr: Data())
        })).info()
        #expect(snapshot.issues.isEmpty)
        let information = DeviceInformation(device: snapshot.device, properties: snapshot.fields)
        #expect(information.fields.first { $0.id == ["name"] }?.value == "Current Phone")
        #expect(information.fields.first { $0.id == ["operatingSystem"] }?.value == "iOS 27.2")
        #expect(information.fields.first { $0.id == ["modelName"] }?.value == "iPhone 18 Pro")
        #expect(!information.fields.contains { $0.id == ["udid"] })
        #expect(information.fields.first { $0.id == ["connection", "transportType"] }?.value == "USB")
        #expect(information.fields.first { $0.id == ["connection", "state"] }?.value == "futureRawState")
        #expect(information.fields.filter { $0.id.starts(with: ["hardware", "cpuType"]) }.map(\.value) == ["arm64e"])
        let unknown = try JSONDecoder().decode(DeviceInspectorValue.self, from: Data(#"{"hardware":{"cpuType":{"type":2147483647,"subtype":18446744071562067970}}}"#.utf8))
        let unknownInfo = DeviceInformation(device: .remote(remote), properties: try #require(unknown.object))
        #expect(unknownInfo.fields.first { $0.id == ["hardware", "cpuType"] }?.value == "type 2147483647, subtype 18446744071562067970")
        #expect(information.fields.first { $0.id == ["hardware", "reality"] }?.value == "futureReality")
        #expect(information.fields.first { $0.id == ["state", "bootState"] }?.value == "futureBoot")
        #expect(!information.fields.contains { $0.title == "DDI Services" })
        #expect(information.fields.first { $0.value == "27C100" }?.title == "Software / OS Builds / Build / Name")
        #expect(information.fields.first { $0.value == "Primary" }?.title == "Configuration / Displays — Item 1 / Name")
        #expect(information.fields.first { $0.value == "External" }?.title == "Configuration / Displays — Item 2 / Name")
    }

    @Test func pairedCanvasLinkUsesFreshInventoryAndTheExistingExplicitOpenRoute() async throws {
        let pairedID = DeviceInventoryID.simulator(udid: "watch", deviceSetPath: "/custom")
        func phone(active: Bool = true, state: String = "Booted") -> InventoryDevice {
            .simulator(SimulatorHostDevice(identifier: "phone", name: "Phone", descriptiveName: "Phone",
                runtimeIdentifier: "runtime", runtimeName: "iOS", productFamily: "iPhone", state: state,
                deviceSetPath: "/custom", pairIdentifiers: ["pair"], activePairedDeviceID: active ? pairedID : nil))
        }
        func watch(_ name: String, set: String? = "/custom") -> InventoryDevice {
            .simulator(SimulatorHostDevice(identifier: "watch", name: name, descriptiveName: name,
                runtimeIdentifier: "runtime", runtimeName: "watchOS", productFamily: "Apple Watch", state: "Shutdown",
                deviceSetPath: set, pairIdentifiers: ["pair"]))
        }
        let source = ManagerModelSource(devices: [phone(), watch("Companion"), watch("Other Set", set: nil)])
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source)
        await manager.refresh()
        #expect(manager.activePairedDevice(for: phone().id)?.name == "Companion")
        manager.openActivePairedDevice(for: phone().id)
        #expect(await events.next() == .open(pairedID))
        await source.setDevices([phone(), watch("Renamed Companion")])
        await source.completeOpen()
        let published = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated {
                !manager.isBusy && manager.activePairedDevice(for: phone().id)?.name == "Renamed Companion"
            }
        }, object: nil)
        try #require(await XCTWaiter.fulfillment(of: [published], timeout: 5) == .completed)
        await source.setDevices([phone(active: false), watch("Renamed Companion")])
        await manager.refresh()
        #expect(manager.activePairedDevice(for: phone().id) == nil)
        manager.openActivePairedDevice(for: phone().id)
        #expect(!manager.isBusy)
        await source.setDevices([phone(state: "Shutdown"), watch("Renamed Companion")])
        await manager.refresh()
        #expect(manager.activePairedDevice(for: phone().id) == nil)
        try await manager.quitRenderer(keepingDevicesRunning: true)
    }

    @Test func pairedInfoResolvesThePartnerInItsDeviceSetAndUnpairsTheWatchFromEitherSide() async throws {
        _ = NSApplication.shared
        func device(_ id: String, family: String, set: String? = nil, pairs: Set<String> = ["pair"]) -> SimulatorHostDevice {
            SimulatorHostDevice(identifier: id, name: id, descriptiveName: id,
                runtimeIdentifier: "runtime", runtimeName: family == "Apple Watch" ? "watchOS" : "iOS",
                productFamily: family, state: "Shutdown", deviceSetPath: set,
                deviceTypeIdentifier: "model",
                capabilities: ["com.apple.coredevice.feature.companiondevicepairing"], pairIdentifiers: pairs)
        }
        let phone = device("phone", family: "iPhone")
        let watch = device("watch", family: "Apple Watch")
        let inventory: [InventoryDevice] = [
            .simulator(phone), .simulator(watch),
            .simulator(device("watch", family: "Apple Watch", set: "/other-set")),
            .simulator(device("unpaired-watch", family: "Apple Watch", pairs: ["other-pair"])),
        ]
        #expect(DeviceInformation.pairedSimulators(for: phone, in: inventory) == [watch])
        #expect(DeviceInformation.pairedSimulators(for: watch, in: inventory) == [phone])
        #expect(DeviceInformation.watchToUnpair(device: phone, partner: watch) == watch)
        #expect(DeviceInformation.watchToUnpair(device: watch, partner: phone) == watch)

        let manager = SimulatorManagerModel(source: ManagerModelSource(devices: inventory))
        await manager.refresh()
        let inspection = DeviceInspectorModel()
        inspection.device = .simulator(watch)
        let target = NSObject()
        let suite = "NeoSimulatorTests.PairedInfo.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = NSHostingController(rootView: DeviceInformationView(
            manager: manager, inspection: inspection, visibility: DeviceInfoVisibility(defaults: defaults),
            pairingMenu: { SimulatorPairingMenu.make(for: $0, model: manager, target: target,
                                                    action: #selector(NSApplication.terminate(_:))) },
            deviceMenu: { device in
                let menu = NSMenu(title: device.name)
                menu.addItem(withTitle: "View Screen", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
                return menu
            },
            unpair: { _ in Issue.record("Unpaired without a user action") }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 800),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.close() }
        let view = controller.view
        window.setContentSize(NSSize(width: 280, height: 800))
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        func tables(in view: NSView) -> [NSTableView] {
            (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap { tables(in: $0) }
        }
        let pairedTable = try #require(tables(in: view).first { $0.numberOfRows == 1 })
        let pairedScroll = try #require(pairedTable.enclosingScrollView)
        let viewport = pairedScroll.documentVisibleRect
        let row = pairedTable.rect(ofRow: 0)
        let backingPixel = 1 / window.backingScaleFactor
        #expect(viewport.height > 0 && row.height > 0)
        #expect(viewport.minY <= row.minY + backingPixel)
        #expect(viewport.maxY >= row.maxY - backingPixel)
        #expect(row.height >= 40)
        #expect(pairedScroll.frame.height < 120)
        let pairedRow = try #require(pairedTable.view(atColumn: 0, row: 0, makeIfNecessary: true))
        pairedRow.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        func popupButtons(in view: NSView) -> [NSPopUpButton] {
            (view as? NSPopUpButton).map { [$0] } ?? view.subviews.flatMap { popupButtons(in: $0) }
        }
        let more = try #require(popupButtons(in: pairedRow).first {
            $0.accessibilityLabel() == "More Actions for \(phone.name)"
        })
        #expect(more.convert(more.bounds, to: pairedRow).minX > pairedRow.bounds.midX)
        #expect(more.menu?.items.contains {
            $0.title == "View Screen" && $0.action == #selector(NSApplication.terminate(_:))
        } == true)
        func addButton(in view: NSView) -> NSPopUpButton? {
            if let button = view as? NSPopUpButton,
               button.accessibilityLabel() == "Add Paired Simulator" { return button }
            return view.subviews.lazy.compactMap { addButton(in: $0) }.first
        }
        let add = try #require(addButton(in: view))
        #expect(add.frame.width >= 24 && add.frame.height >= 24)
        let canAddAnotherPhone = add.isEnabled
        #expect(!canAddAnotherPhone)
        let pairedPosition = pairedScroll.convert(pairedScroll.bounds, to: view).origin
        inspection.device = .simulator(SimulatorHostDevice(identifier: watch.identifier,
            name: String(repeating: "A long device name ", count: 20), descriptiveName: watch.descriptiveName,
            runtimeIdentifier: watch.runtimeIdentifier, runtimeName: String(repeating: "A long OS name ", count: 20),
            productFamily: watch.productFamily, state: watch.state,
            deviceTypeIdentifier: String(repeating: "A long model name ", count: 20),
            capabilities: watch.capabilities, pairIdentifiers: watch.pairIdentifiers))
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let afterLongValues = try #require(tables(in: view).first { $0.numberOfRows == 1 }?.enclosingScrollView)
        let longValuePosition = afterLongValues.convert(afterLongValues.bounds, to: view).origin
        #expect(abs(longValuePosition.y - pairedPosition.y) < 1)
        inspection.device = .simulator(phone)
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        #expect(try #require(addButton(in: view)).isEnabled)
        inspection.device = .simulator(device("unpaired-phone", family: "iPhone", pairs: []))
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let emptyPairedTable = try #require(tables(in: view).first)
        #expect(emptyPairedTable.numberOfRows == 1)
        #expect(emptyPairedTable.selectedRow == -1)
        let emptyScroll = try #require(emptyPairedTable.enclosingScrollView)
        let emptyRow = emptyPairedTable.rect(ofRow: 0)
        #expect(emptyRow.height >= 120)
        #expect(emptyScroll.documentVisibleRect.minY <= emptyRow.minY + backingPixel)
        #expect(emptyScroll.documentVisibleRect.maxY >= emptyRow.maxY - backingPixel)

        var selected: DeviceInventoryID?
        let selectionController = NSHostingController(rootView: PairedSimulatorsView(
            devices: [phone], selection: Binding(get: { selected }, set: { selected = $0 }),
            emptyLabel: "No Paired iPhone Simulators", menu: { _ in NSMenu() }))
        window.contentViewController = selectionController
        let selectionView = selectionController.view
        selectionView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let selectionTable = try #require(tables(in: selectionView).first)
        selectionTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        #expect(selected == phone.inventoryID)
        selectionController.rootView = PairedSimulatorsView(
            devices: [], selection: Binding(get: { selected }, set: { selected = $0 }),
            emptyLabel: "No Paired iPhone Simulators", menu: { _ in NSMenu() })
        selectionView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        #expect(selectionTable.numberOfRows == 1)
        #expect(selectionTable.selectedRow == -1)
    }

    @Test func profilesFollowTheAvailableKindWhenChangingDevices() throws {
        guard case .simulator(let simulator) = simulator() else { return }
        func device(_ features: [String]) -> InventoryDevice {
            .simulator(simulator.inventoryCopy(ownerXcodeURL: nil, capabilities:
                Set(features.map { "com.apple.coredevice.feature." + $0 })))
        }
        let inspection = DeviceInspectorModel()
        inspection.device = device(["configurationprofiles", "provisioningprofiles"])
        inspection.select(.provisioning)
        inspection.device = device(["configurationprofiles"])
        #expect(inspection.content == .configuration && inspection.canReadProfiles)
        inspection.device = device(["provisioningprofiles"])
        #expect(inspection.content == .provisioning && inspection.canReadProfiles)
        inspection.select(.configuration)
        #expect(inspection.content == .provisioning && inspection.canReadProfiles)
    }

    @Test func stoppedSimulatorDoesNotExposeAppAndProfileOperationsFromCachedCapabilities() {
        let features = ["streamapplist", "installapp", "configurationprofiles"]
        let inspection = DeviceInspectorModel()
        inspection.device = .simulator(SimulatorHostDevice(identifier: "phone", name: "Phone", descriptiveName: "Phone",
            runtimeIdentifier: "runtime", runtimeName: "iOS", productFamily: "iPhone", state: "Shutdown",
            capabilities: Set(features.map { "com.apple.coredevice.feature." + $0 })))
        inspection.select(.configuration)
        #expect(!inspection.canReadApplications && !inspection.canInstallApplications && !inspection.canReadProfiles)
    }

    @Test func infoVisibilityStartsWithFourFieldsAndPersistsExplicitChoices() throws {
        let suite = "NeoSimulatorTests.InfoVisibility.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let information = DeviceInformation(device: simulator(), properties: [
            "modelName": .string("iPhone 18 Pro"), "hardware": .object(["serialNumber": .string("serial")]),
        ])
        let visibility = DeviceInfoVisibility(defaults: defaults)
        #expect(!information.fields.contains { $0.id == ["hardware", "cpuType"] || $0.id == ["state", "preparednessState"] })
        #expect(Set(information.fields.filter { visibility.isVisible($0) }.map(\.id)) == DeviceInformation.defaultFields)
        let serial = try #require(information.fields.first { $0.id == ["hardware", "serialNumber"] })
        let os = try #require(information.fields.first { $0.id == ["operatingSystem"] })
        visibility.setVisible(true, for: serial)
        visibility.setVisible(false, for: os)
        let restored = DeviceInfoVisibility(defaults: defaults)
        #expect(restored.isVisible(serial) && !restored.isVisible(os))
    }

    @Test(arguments: [true, false])
    func cpuVisibilityKeepsComponentChoicesWhenFieldsCollapse(legacyHiddenFields: Bool) throws {
        let suite = "NeoSimulatorTests.CPUVisibility.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cpuPath = ["hardware", "cpuType"]
        if legacyHiddenFields {
            defaults.set([cpuPath + ["type"], cpuPath + ["subtype"], ["future"]],
                         forKey: DeviceInfoVisibility.legacyPreferenceKey)
        } else {
            defaults.set(["defaultVisible": false, "overrides": [
                ["path": cpuPath + ["type"], "visible": true],
                ["path": cpuPath + ["subtype"], "visible": false],
                ["path": ["future"], "visible": false],
            ]], forKey: DeviceInfoVisibility.preferenceKey)
        }
        let information = DeviceInformation(device: simulator(), properties: [
            "hardware": .object(["cpuType": .object(["type": .integer(16777228), "subtype": .integer(0)])]),
            "future": .object(["value": .string("retained choice")]),
        ])
        let cpu = try #require(information.fields.first { $0.id == cpuPath })
        let future = try #require(information.fields.first { $0.id == ["future", "value"] })
        let visibility = DeviceInfoVisibility(defaults: defaults)
        #expect(visibility.isVisible(cpu) == !legacyHiddenFields)
        visibility.setVisible(true, for: cpu)
        let restored = DeviceInfoVisibility(defaults: defaults)
        #expect(restored.isVisible(cpu) && !restored.isVisible(future))
        restored.setVisible(false, for: cpu)
        #expect(!DeviceInfoVisibility(defaults: defaults).isVisible(cpu))
    }

    @Test(arguments: [false, true])
    func infoVisibilityMigratesLegacyShowAllAndAncestorHidingWithoutLosingUnseenChoices(hidesHardware: Bool) throws {
        let suite = "NeoSimulatorTests.LegacyInfoVisibility.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(hidesHardware ? [["hardware"], ["future"]] : [],
                     forKey: DeviceInfoVisibility.legacyPreferenceKey)
        let information = DeviceInformation(device: simulator(), properties: [
            "modelName": .string("iPhone 18 Pro"),
            "hardware": .object(["serialNumber": .string("serial"), "cpuType": .string("arm64")]),
        ])
        let model = try #require(information.fields.first { $0.id == ["modelName"] })
        let serial = try #require(information.fields.first { $0.id == ["hardware", "serialNumber"] })
        let cpu = try #require(information.fields.first { $0.id == ["hardware", "cpuType"] })
        let visibility = DeviceInfoVisibility(defaults: defaults)
        #expect(visibility.isVisible(model) == !hidesHardware)
        visibility.setVisible(true, for: model)
        #expect(visibility.isVisible(model) && visibility.isVisible(cpu) == !hidesHardware)
        visibility.setVisible(true, for: serial)
        let restored = DeviceInfoVisibility(defaults: defaults)
        #expect(restored.isVisible(model) && restored.isVisible(serial))
        #expect(restored.isVisible(cpu) == !hidesHardware)
        let later = DeviceInformation(device: simulator(), properties: [
            "future": .object(["revision": .string("known later")]),
            "hardware": .object(["vendorProperty": .string("known later")]),
        ])
        let future = try #require(later.fields.first { $0.id == ["future", "revision"] })
        let sibling = try #require(later.fields.first { $0.id == ["hardware", "vendorProperty"] })
        #expect(restored.isVisible(future) == !hidesHardware && restored.isVisible(sibling) == !hidesHardware)
    }

    private func simulator(deviceSet: String? = nil, name: String = "Test Phone", state: String = "Booted",
                           lastUsedAt: Date? = nil) -> InventoryDevice {
        .simulator(SimulatorHostDevice(identifier: "same-udid", name: name, descriptiveName: name,
            runtimeIdentifier: "test-runtime", runtimeName: "iOS", productFamily: "iPhone", state: state,
            deviceSetPath: deviceSet, lastUsedAt: lastUsedAt, capabilities: ["com.apple.dt.coredevice.device.shutdown"]))
    }

    private func settings(appearance: String, contentSize: String? = nil) -> SimulatorDeviceSettings {
        SimulatorDeviceSettings(appearance: appearance, contentSize: contentSize)
    }
}

actor ManagerModelSource: SimulatorManagerSource {
    private nonisolated let cancelledOpens = Mutex<Set<DeviceInventoryID>>([])
    nonisolated var cancelledOpenIDs: Set<DeviceInventoryID> { cancelledOpens.withLock { $0 } }
    enum Event: Equatable, Sendable { case read(DeviceInventoryID), write(DeviceInventoryID), open(DeviceInventoryID), close(DeviceInventoryID), inspect(DeviceInventoryID), quit, manage(DeviceManagementAction, [DeviceInventoryID]) }
    enum Failure: LocalizedError {
        case unavailable, native
        var errorDescription: String? { self == .native ? "Native shutdown failed" : "Unavailable" }
    }
    nonisolated let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private var devices: [InventoryDevice]
    private var inspectorResponse: String?
    private var holdsInspectorReads = false
    private var inspectorRead: CheckedContinuation<CommandOutput, any Error>?
    private var holdsManagement = false
    private var immediateRead: SimulatorDeviceSettings?
    private var readContinuation: CheckedContinuation<SimulatorDeviceSettings, any Error>?
    private var openContinuation: CheckedContinuation<Void, any Error>?
    private var writeContinuation: CheckedContinuation<SimulatorDeviceSettings, any Error>?
    private var pendingWrite: SimulatorDeviceSettings?
    private(set) var writeInputs: [SimulatorDeviceSettings?] = []
    private(set) var readCount = 0
    private(set) var quitCount = 0
    private(set) var lastOpenXcodeURL: URL?
    private(set) var artworkXcodeRequests: [DeviceInventoryID] = []
    private(set) var installedXcodeReadCount = 0
    private(set) var managementRequests = 0
    private(set) var preparationRequests = 0
    private let managementFailureID: DeviceInventoryID?
    private var managementWaiters: [(DeviceManagementAction, CheckedContinuation<Void, Never>)] = []
    private var admittedManagement: Set<UUID> = []

    init(devices: [InventoryDevice], managementFailureID: DeviceInventoryID? = nil, holdsManagement: Bool = false,
         inspectorResponse: String? = nil) {
        self.managementFailureID = managementFailureID
        self.holdsManagement = holdsManagement
        self.devices = devices
        self.inspectorResponse = inspectorResponse
        (events, continuation) = AsyncStream.makeStream()
    }

    func xcodeURL(forDevice deviceID: DeviceInventoryID) -> URL {
        artworkXcodeRequests.append(deviceID)
        return URL(fileURLWithPath: "/Applications/Test Xcode.app")
    }
    func installedXcodes() -> [SimulatorXcode] {
        installedXcodeReadCount += 1
        return [SimulatorXcode(url: URL(fileURLWithPath: "/Applications/Test Xcode.app"), version: "27.1", name: "Test Xcode")]
    }
    func setDevices(_ devices: [InventoryDevice]) { self.devices = devices }
    func inventory() -> DeviceInventorySnapshot { DeviceInventorySnapshot(devices: devices, issues: []) }
    func status() -> SimulatorHostStatus { SimulatorHostStatus(host: .neo, restorationAvailable: false, rendererRunning: false) }
    func deviceSettings(for device: InventoryDevice) async throws -> SimulatorDeviceSettings {
        readCount += 1
        if let immediateRead {
            self.immediateRead = nil
            continuation.yield(.read(device.id))
            return immediateRead
        }
        return try await withCheckedThrowingContinuation { waiting in
            readContinuation = waiting
            continuation.yield(.read(device.id))
        }
    }
    func returnOnNextRead(_ settings: SimulatorDeviceSettings) { immediateRead = settings }
    func completeRead(_ settings: SimulatorDeviceSettings) {
        let waiting = readContinuation
        readContinuation = nil
        waiting?.resume(returning: settings)
    }
    func setDeviceSetting(_ setting: SimulatorDeviceSetting, for device: InventoryDevice) async throws {
        _ = try await write(setting, device: device, updating: nil)
    }
    func setDeviceSetting(_ setting: SimulatorDeviceSetting, for device: InventoryDevice,
                          updating settings: SimulatorDeviceSettings) async throws -> SimulatorDeviceSettings {
        try await write(setting, device: device, updating: settings)
    }
    private func write(_ setting: SimulatorDeviceSetting, device: InventoryDevice,
                       updating snapshot: SimulatorDeviceSettings?) async throws -> SimulatorDeviceSettings {
        writeInputs.append(snapshot)
        var updated = snapshot ?? SimulatorDeviceSettings()
        switch setting {
        case .appearance(let appearance): updated.appearance = appearance
        case .contentSize(let size): updated.contentSize = size
        case .boldText(let value): updated.boldText = value
        case .showBorders(let value): updated.showBorders = value
        case .reduceTransparency(let value): updated.reduceTransparency = value
        default: throw Failure.unavailable
        }
        pendingWrite = updated
        return try await withCheckedThrowingContinuation { waiting in
            writeContinuation = waiting
            continuation.yield(.write(device.id))
        }
    }
    func completeWrite() {
        let waiting = writeContinuation
        let updated = pendingWrite
        writeContinuation = nil
        pendingWrite = nil
        if let updated { waiting?.resume(returning: updated) }
    }
    func failWrite(afterApplying: Bool = false) {
        let waiting = writeContinuation
        let updated = pendingWrite
        writeContinuation = nil
        pendingWrite = nil
        if afterApplying, let updated {
            waiting?.resume(throwing: SimulatorDeviceSettingsUpdateFailure(settings: updated,
                underlyingError: SimulatorHostFailure(Failure.unavailable)))
        } else {
            waiting?.resume(throwing: Failure.unavailable)
        }
    }
    func quitRenderer(keepingDevicesRunning: Bool?) { quitCount += 1; continuation.yield(.quit) }
    func selectHost(_ host: SimulatorHost, xcodeURL: URL?) throws { throw Failure.unavailable }
    nonisolated func makeScreenOpenRequest(for deviceID: DeviceInventoryID) -> SimulatorScreenOpenRequest {
        SimulatorScreenOpenRequest(deviceID: deviceID) { self.cancelledOpens.withLock { $0.insert(deviceID) } }
    }
    func openDevice(_ request: SimulatorScreenOpenRequest, xcodeURL: URL?) async throws {
        let deviceID = request.deviceID
        lastOpenXcodeURL = xcodeURL
        try await withCheckedThrowingContinuation { waiting in
            openContinuation = waiting
            continuation.yield(.open(deviceID))
        }
    }
    func completeOpen() { openContinuation?.resume(); openContinuation = nil }
    func failOpen() { openContinuation?.resume(throwing: Failure.unavailable); openContinuation = nil }
    func closeDevice(_ deviceID: DeviceInventoryID, keepingDeviceRunning: Bool) { continuation.yield(.close(deviceID)) }
    func creationCatalog() throws -> SimulatorCreationContext { throw Failure.unavailable }
    func creationCatalog(for deviceID: DeviceInventoryID) throws -> SimulatorCreationContext { throw Failure.unavailable }
    func createSimulator(named name: String, deviceType: String, runtime: String, context: SimulatorCreationContext) throws -> String { throw Failure.unavailable }
    func pairSimulators(watch: String, phone: String, context: SimulatorCreationContext) throws { throw Failure.unavailable }
    func holdManagement() { holdsManagement = true }
    func manage(_ action: DeviceManagementAction, devices: [InventoryDevice],
                preparingDisplay: (@isolated(any) @Sendable (InventoryDevice) async throws -> Void)?) async -> DeviceManagementReport {
        let request = UUID()
        let preparation: (@isolated(any) @Sendable (InventoryDevice) async throws -> Void)?
        if let preparingDisplay {
            preparation = { target in
                await self.recordPreparation()
                try await preparingDisplay(target)
            }
        } else { preparation = nil }
        let backend = DeviceManagementBackend(context: { device, _ in
            DeviceManagementContext(device: device, xcodeURL: URL(fileURLWithPath: "/Fixture.app"), renderer: nil)
        }, runSimctl: { _, _, _ in
            await self.beginManagement(request, action: action, devices: devices)
            return Data()
        }, runDevicectl: { _ in
            await self.beginManagement(request, action: action, devices: devices)
            return Data()
        }, shutdownSimulator: { _, _, _ in
            await self.beginManagement(request, action: action, devices: devices)
        }, manageCoreDevice: { _, identifier in
            await self.beginManagement(request, action: action, devices: devices)
            if self.managementFailureID == identifier { throw Failure.native }
        }, release: { _, _ in }, restart: { _, _, _ in false }, attach: { _, _ in })
        return await backend.manage(action, devices: devices, preparingDisplay: preparation)
    }
    private func recordPreparation() { preparationRequests += 1 }
    private func beginManagement(_ request: UUID, action: DeviceManagementAction, devices: [InventoryDevice]) async {
        guard admittedManagement.insert(request).inserted else { return }
        managementRequests += 1
        if holdsManagement {
            await withCheckedContinuation { waiting in
                managementWaiters.append((action, waiting))
                continuation.yield(.manage(action, devices.map(\.id)))
            }
        } else { continuation.yield(.manage(action, devices.map(\.id))) }
    }
    func completeManagement(_ action: DeviceManagementAction) {
        guard let index = managementWaiters.firstIndex(where: { $0.0 == action }) else { return }
        managementWaiters.remove(at: index).1.resume()
        holdsManagement = false
    }
    func inspector(for device: InventoryDevice) throws -> DeviceInspector {
        guard inspectorResponse != nil else { throw Failure.unavailable }
        return DeviceInspector(device: device, simulatorXcodeURL: URL(fileURLWithPath: "/Fixture.app"),
            transport: .init(run: { command in try await self.readInspector(device.id) }))
    }
    private func readInspector(_ identifier: DeviceInventoryID) async throws -> CommandOutput {
        if holdsInspectorReads {
            return try await withCheckedThrowingContinuation { waiting in
                inspectorRead = waiting
                continuation.yield(.inspect(identifier))
            }
        }
        continuation.yield(.inspect(identifier))
        return CommandOutput(terminationStatus: 0, stdout: Data((inspectorResponse ?? "").utf8), stderr: Data())
    }
    func holdInspectorReads() { holdsInspectorReads = true }
    func completeInspectorRead(_ response: String? = nil) {
        if let response { inspectorResponse = response }
        holdsInspectorReads = false
        let waiting = inspectorRead
        inspectorRead = nil
        waiting?.resume(returning: CommandOutput(terminationStatus: 0, stdout: Data((inspectorResponse ?? "").utf8), stderr: Data()))
    }
    func failInspectorRead() {
        holdsInspectorReads = false
        let waiting = inspectorRead
        inspectorRead = nil
        waiting?.resume(throwing: Failure.unavailable)
    }
    func restore(force: Bool) throws { throw Failure.unavailable }
    func synchronizeXcodeConnections() -> Bool { false }
    func testingDeviceVisibilityDidChange() {}
}

@MainActor
private final class ManagerPostureConnections {
    enum Event: Equatable { case observing(DeviceInventoryID), stopped(DeviceInventoryID) }
    let events = AsyncStream<Event>.makeStream()
    private(set) var identifiers: [DeviceInventoryID] = []
    private var current: ManagerPostureTransport?
    func failCurrentObservation() { current?.fail() }
    func model(_ identifier: DeviceInventoryID) -> DevicePostureModel {
        DevicePostureModel(deviceID: identifier) { [self] id in
            identifiers.append(id)
            let transport = ManagerPostureTransport(identifier: id, events: events.continuation)
            current = transport
            return transport
        }
    }
}

@MainActor
private final class ManagerPostureTransport: DevicePostureTransport {
    let identifier: DeviceInventoryID
    let events: AsyncStream<ManagerPostureConnections.Event>.Continuation
    private let lifetime = AsyncThrowingStream<Void, any Error>.makeStream()
    init(identifier: DeviceInventoryID, events: AsyncStream<ManagerPostureConnections.Event>.Continuation) {
        self.identifier = identifier
        self.events = events
    }
    func observe(_ update: @escaping @MainActor (Double?) -> Void) async throws {
        update(0)
        events.yield(.observing(identifier))
        defer { events.yield(.stopped(identifier)) }
        for try await _ in lifetime.stream { }
    }
    func fail() { lifetime.continuation.finish(throwing: ManagerModelSource.Failure.unavailable) }
    func send(_ posture: DevicePosture) async throws { }
}
