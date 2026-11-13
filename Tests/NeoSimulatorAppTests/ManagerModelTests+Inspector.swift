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
    @Test func aHostTakeoverRetainsItsContextsAndReportsEveryCleanupFailureTogether() throws {
        var reports: [any Error] = []
        let takeovers = HostTakeovers<NSObject> { reports.append($0) }
        var first: NSObject? = NSObject()
        weak let retained = first
        let second = NSObject()
        takeovers.begin(try #require(first), hostName: "Simulator") {
            takeovers.begin(second, hostName: "Simulator", checkOthers: {})
        }
        first = nil
        #expect(retained != nil)
        takeovers.end(try #require(retained), failure: SimulatorError.operation("First input cleanup failed"))
        #expect(reports.isEmpty)
        takeovers.end(second, failure: SimulatorError.operation("Second input cleanup failed"))
        let report = try #require(reports.first)
        #expect(reports.count == 1)
        switch report {
        case SimulatorError.conflict(let message):
            #expect(message == "Simulator is now displaying the simulators.\nFirst input cleanup failed\nSecond input cleanup failed")
        default:
            Issue.record("Expected a host conflict, got \(report)")
        }
    }

    @Test func overlappingHostTakeoversAndLaterEventsReportIndependently() {
        var reports: [String] = []
        let takeovers = HostTakeovers<NSObject> { reports.append($0.localizedDescription) }
        let first = NSObject(), second = NSObject(), newer = NSObject()
        takeovers.begin(first, hostName: "Simulator") {
            takeovers.begin(second, hostName: "Simulator", checkOthers: {})
        }
        takeovers.begin(newer, hostName: "Device Hub", checkOthers: {})
        takeovers.end(newer, failure: nil)
        #expect(reports == ["Device Hub is now displaying the simulators."])
        takeovers.end(first, failure: nil)
        #expect(reports.count == 1)
        takeovers.end(second, failure: nil)
        #expect(reports.last == "Simulator is now displaying the simulators.")
        takeovers.begin(newer, hostName: "Simulator", checkOthers: {})
        takeovers.end(newer, failure: nil)
        #expect(reports.count == 3)
    }

    @Test(arguments: [(nil as String?, "Other"), ("  ßeta  ", "SS"), ("\nAlpha", "#"), ("", "#")])
    func sidebarNameGroupsUseTheReportedFirstCharacter(_ name: String?, _ expected: String) throws {
        var state: [String: String] = [:]
        state["name"] = name
        let data = try JSONSerialization.data(withJSONObject: ["result": ["devices": [["identifier": "phone",
            "properties": ["hardware": ["fidelity": "physical", "marketingName": "Fallback"], "state": state]]]]])
        let device = InventoryDevice.remote(try #require(CoreDeviceInventoryDecoder.decode(data).first))
        let presentation = DeviceBrowserPresentation(devices: [device], sortOrder: .name)
        #expect(presentation.sections.map(\.id) == [expected])
    }

    @Test func inspectorTabsToggleVisibilityAndSwitchPages() throws {
        _ = NSApplication.shared
        let domain = "NeoSimulator.InspectorFixture.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let model = SimulatorManagerModel(source: ManagerModelSource(devices: []))
        model.registry.stopReading()
        let controller = ManagerWindowController(model: model, screens: DeviceScreens(model: model),
                                                 menus: MenuController(application: nil), defaults: defaults)
        let window = try #require(controller.window)
        window.setFrameAutosaveName("")
        defer { window.close() }
        let split = try #require(window.contentViewController as? NSSplitViewController)
        let inspector = try #require(split.splitViewItems.last)
        let accessory = try #require(inspector.topAlignedAccessoryViewControllers.first)
        let tabs = try #require(window.toolbar?.items.first { $0.itemIdentifier.rawValue == "DeviceInspector" }?.view as? NSSegmentedControl)
        let categories = try #require(inspectorViews(accessory.view).compactMap { $0 as? NSSegmentedControl }.first)
        let searchAccessory = try #require(
            inspector.topAlignedAccessoryViewControllers.compactMap {
                $0 as? BackgroundServicesActionsAccessoryViewController
            }.first)
        let profileAccessory = try #require(
            inspector.topAlignedAccessoryViewControllers.compactMap {
                $0 as? BackgroundServicesProfileAccessoryViewController
            }.first)
        #expect(searchAccessory.isHidden && profileAccessory.isHidden)
        #expect((0..<tabs.segmentCount).map { tabs.toolTip(forSegment: $0) } == ["Settings", "Reports", "Info", "Background Services"])
        window.setContentSize(NSSize(width: 1200, height: 800))
        split.view.layoutSubtreeIfNeeded()
        #expect(accessory.isHidden)
        #expect(accessory.view.window === window)
        window.makeKeyAndOrderFront(nil)
        let frame = window.frame

        let overflow = try #require(window.toolbar?.items.first { $0.itemIdentifier.rawValue == "DeviceInspector" }?.menuFormRepresentation?.submenu)
        #expect(overflow.items.map(\.title) == ["Settings", "Reports", "Info", "Background Services"])

        func click(_ index: Int, collapsed: Bool, page: DeviceInspectorModel.Page? = nil, fromMenu: Bool = false) throws {
            let sender: AnyObject = fromMenu ? overflow.items[index] : tabs
            let action = try #require(fromMenu ? overflow.items[index].action : tabs.action)
            let target = fromMenu ? overflow.items[index].target : tabs.target
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                if !fromMenu { tabs.selectedSegment = index }
                #expect(NSApp.sendAction(action, to: target, from: sender))
            }
            #expect(inspector.isCollapsed == collapsed)
            #expect((0..<tabs.segmentCount).filter { tabs.isSelected(forSegment: $0) } == (collapsed ? [] : [index]))
            #expect(overflow.items.filter { $0.state == .on }.map(\.tag) == (collapsed ? [] : [index]))
            #expect(!tabs.isHidden)
            #expect(inspector.topAlignedAccessoryViewControllers.first === accessory)
            #expect(window.frame == frame, "Tab \(index), collapsed \(collapsed): frame \(window.frame), original \(frame)")
            #expect(controller.inspectorController.deviceInspector.inspection.isVisible == (!collapsed && (index == 1 || index == 2)))
            #expect(model.selection.showsServices == (!collapsed && index == 3))
            if let page { #expect(controller.inspectorController.deviceInspector.inspection.page == page) }
        }

        #expect(!inspector.isCollapsed && tabs.selectedSegment == 0)
        try click(0, collapsed: true)
        try click(0, collapsed: false)
        #expect(!inspector.isCollapsed && tabs.selectedSegment == 0)
        try click(3, collapsed: false)
        try click(3, collapsed: true)
        try click(1, collapsed: false, page: .reports)
        try click(1, collapsed: true, page: .reports)
        try click(2, collapsed: false, page: .info)
        try click(2, collapsed: true, page: .info)
        try click(2, collapsed: false, page: .info)
        try click(2, collapsed: true, page: .info, fromMenu: true)
        try click(2, collapsed: false, page: .info, fromMenu: true)

        inspector.isCollapsed = true
        #expect((0..<tabs.segmentCount).allSatisfy { !tabs.isSelected(forSegment: $0) })
        #expect(!controller.inspectorController.deviceInspector.inspection.isVisible)
        inspector.isCollapsed = false
        #expect(tabs.selectedSegment == 2 && controller.inspectorController.deviceInspector.inspection.isVisible)
        try click(0, collapsed: false)
        #expect(accessory.isHidden)
        let device = simulator()
        model.registry.apply(DeviceInventorySnapshot(devices: [device], issues: []))
        model.inspect(device, selectionCount: 1)
        try click(2, collapsed: false, page: .info)
        window.layoutIfNeeded()
        #expect(!accessory.isHidden && accessory.view.frame.height > 0)
        #expect((0..<categories.segmentCount).map { categories.label(forSegment: $0) } == ["Info", "Apps", "Profiles"])
        #expect(!categories.isDescendant(of: controller.inspectorController.deviceInspector.view))
        let informationScroll = try #require(inspectorViews(controller.inspectorController.deviceInspector.view)
            .compactMap { $0 as? NSScrollView }.first { !$0.isHiddenOrHasHiddenAncestor })
        let viewport = informationScroll.convert(informationScroll.bounds, to: nil)
        let accessoryFrame = accessory.view.convert(accessory.view.bounds, to: nil)
        #expect(viewport.maxY > accessoryFrame.minY)
        categories.selectedSegment = 1
        #expect(NSApp.sendAction(try #require(categories.action), to: categories.target, from: categories))
        #expect(controller.inspectorController.deviceInspector.inspection.content == .applications)
        try click(1, collapsed: false, page: .reports)
        #expect(accessory.isHidden)
        try click(3, collapsed: false)
        window.layoutIfNeeded()
        let services = try #require(inspector.viewController.children.compactMap { $0 as? BackgroundServicesViewController }.first)
        #expect(!searchAccessory.isHidden && !profileAccessory.isHidden)
        #expect(inspectorViews(services.view).contains { $0 is NSOutlineView })
        try click(0, collapsed: false)
        #expect(
            services.parent == nil && services.view.window == nil && searchAccessory.isHidden
                && profileAccessory.isHidden)
        controller.stopInspectorReads()
    }

    @Test(arguments: [(DeviceInspectorModel.Page.info, DeviceInspectorModel.Content.applications),
                      (.info, .configuration), (.reports, .info)])
    func sameDeviceInventoryUpdatesKeepInspectorRecordsAndSelection(selection: (page: DeviceInspectorModel.Page, content: DeviceInspectorModel.Content)) async throws {
        _ = NSApplication.shared
        let features: Set<String> = ["streamapplist", "installapp", "launchapplication", "configurationprofiles", "listFiles", "transferFiles"]
        func device(_ identifier: String = "inspected-device", name: String = "Phone", features: Set<String> = features) -> InventoryDevice {
            .remote(CoreDeviceDevice(identifier: identifier, udid: nil, kind: .physical, name: name, reportedName: name,
                modelIdentifier: nil, modelName: nil, cpuType: nil, platform: "iOS", osVersion: nil, osBuild: nil, osBuildUpdate: nil,
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
        await source.skipSettingsReads()
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source)
        let controller = ManagerDeviceInspectorController(model: manager, inspection: DeviceInspectorModel())
        func show(_ device: InventoryDevice) throws {
            manager.registry.apply(DeviceInventorySnapshot(devices: [device], issues: []))
            manager.inspect(device, selectionCount: 1)
            let selectedDevice = try #require(manager.registry.device(for: device.id))
            controller.update(device: selectedDevice, isManaging: false, isVisible: true)
        }
        func records() -> Int {
            switch (selection.page, selection.content) {
            case (.info, .applications): controller.inspection.device?.inspection.applications.count ?? 0
            case (.reports, _): controller.inspection.device?.inspection.reports.count ?? 0
            default: controller.inspection.profiles.count
            }
        }
        controller.setPage(selection.page)
        controller.inspection.select(selection.content)
        try show(device())
        #expect(await events.next() == .inspect(device().id))
        await finishInspectorRead(controller.inspection)
        let views = inspectorViews(controller.view)
        let table = try #require(views.compactMap { $0 as? NSTableView }.first {
            $0.accessibilityLabel() == "Installed Applications, Profiles, and Reports"
        })
        // The controller publishes rows in a separate observation callback after the model finishes reading.
        try await wait(timeout: .seconds(5)) {
            table.numberOfRows == 1
        }
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let filter = try #require(views.compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "Report Type" })
        if selection.page == .reports {
            filter.selectItem(at: 1)
            NSApp.sendAction(try #require(filter.action), to: filter.target, from: filter)
        }
        // A rename says nothing of these lists, so it reads nothing and leaves what shows.
        try show(device(name: "Renamed Phone"))
        await finishInspectorRead(controller.inspection)
        #expect(await source.inspectorCommands.count == 1)
        #expect(table.numberOfRows == 1 && table.selectedRow == 0 && records() == 1)
        #expect(selection.page != .reports || filter.indexOfSelectedItem == 1)

        try show(device(name: "Renamed Phone", features: []))
        try await wait(timeout: .seconds(5)) { table.numberOfRows == 0 }
        #expect(records() == 0)
        let toolTip = selection.content == .applications ? "Launch Application" : (selection.page == .reports ? "Download Report…" : "Remove…")
        let action = try #require(views.compactMap { $0 as? NSButton }.first { $0.toolTip == toolTip })
        #expect(!action.isEnabled)

        await source.holdInspectorReads()
        try show(device("other-device"))
        #expect(table.numberOfRows == 0 && table.selectedRow == -1 && records() == 0)
        #expect(await events.next() == .inspect(device("other-device").id))
        await source.completeInspectorRead()
        await finishInspectorRead(controller.inspection)
        controller.stopReading()
    }

    @Test func failedInfoOffersARetryAndOnlyWhatShowsIsRead() async throws {
        _ = NSApplication.shared
        let device = inspectedRemote()
        let source = ManagerModelSource(devices: [], inspectorResponse: Self.inspectionResponse)
        await source.skipSettingsReads()
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source)
        manager.registry.apply(DeviceInventorySnapshot(devices: [device], issues: []))
        manager.inspect(device, selectionCount: 1)
        let model = try #require(manager.registry.device(for: device.id))
        let controller = ManagerDeviceInspectorController(model: manager, inspection: DeviceInspectorModel())
        controller.update(device: model, isManaging: false, isVisible: true)
        #expect(await events.next() == .inspect(device.id))
        await manager.registry.finishReading()
        let retry = try #require(inspectorViews(controller.view).compactMap { $0 as? NSButton }.first { $0.title == "Retry" })
        #expect(retry.isHidden)

        await source.holdInspectorReads()
        model.revalidate(.info)
        #expect(await events.next() == .inspect(device.id))
        await source.failInspectorRead()
        await manager.registry.finishReading()
        try await wait(timeout: .seconds(5)) { !retry.isHidden }
        #expect(model.inspection.info["name"] == .string("Details"))
        #expect(NSApp.sendAction(try #require(retry.action), to: retry.target, from: retry))
        #expect(await events.next() == .inspect(device.id))
        await manager.registry.finishReading()
        try await wait(timeout: .seconds(5)) { retry.isHidden }
        #expect(model.inspection.status(of: .info) == .current)

        // Hidden, it reads nothing, and showing it again reads what has gone out of date.
        controller.update(device: model, isManaging: false, isVisible: false)
        model.revalidate(.info)
        await manager.registry.finishReading()
        #expect(await source.inspectorCommands.count == 3)
        controller.update(device: model, isManaging: false, isVisible: true)
        #expect(await events.next() == .inspect(device.id))
        await manager.registry.finishReading()
        #expect(await source.inspectorCommands.count == 4)
        controller.update(device: nil, isManaging: false, isVisible: true)
    }

    @Test func aChangeHeldWhenAQuitRunsOutReportsWhetherItRan() async throws {
        let device = simulator()
        let source = ManagerModelSource(devices: [device])
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source)
        manager.terminationLimit = .milliseconds(50)
        manager.terminationGrace = .milliseconds(50)
        manager.uninterruptedCommands = UninterruptedCommands()
        var reports: [String] = []
        manager.onError = { reports.append($0.localizedDescription) }
        await manager.refresh()
        manager.setDeviceSetting(.appearance(.dark), for: device.id)
        #expect(await events.next() == .write(device.id))
        manager.setDeviceSetting(.boldText(true), for: device.id)
        try await manager.prepareForQuit()
        #expect(reports.contains { $0.contains("did not run") })
        #expect(reports.contains { $0.contains("had not finished when NeoSimulator quit") })
        #expect(await source.writtenChanges == [.appearance(.dark)])
        await source.completeWrite(for: device.id)
    }

    @Test func serviceInspectorKeepsExpandedRowsWhileResizingAndSavesThroughItsModel() async throws {
        let domain = "NeoSimulator.ServiceInspector.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: serviceProfileURL(domain).deletingLastPathComponent())
        }
        let device = simulator()
        let store = ServiceProfileStore(fileURL: serviceProfileURL(domain), legacyDefaults: defaults)
        let source = ManagerModelSource(devices: [device])
        await source.skipSettingsReads()
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source, serviceProfiles: store)
        await manager.refresh()
        manager.inspect(device, selectionCount: 1)
        manager.selection.setServicesVisible(true)
        await manager.registry.finishReading()
        let settings = SettingsWindowController(makeLicenses: SettingsPreview.licenses, model: manager, restart: {},
            makeSimulator: { throw SimulatorError.operation("Unused") },
            preferences: SimulatorPreferences(defaults: defaults, creationDefaults: defaults),
            reportFailure: { _ in Issue.record("Unexpected failure") })
        defer { settings.window?.close() }
        let model = BackgroundServicesInspectorModel(manager: manager, showProfileSettings: {
            settings.settings.selectServiceProfile($0)
        })
        let category = try #require(model.categories.first { $0.id == "search" })
        let item = try #require(category.items.first { $0.label == "com.apple.searchd" })
        let controller = BackgroundServicesViewController(model: model)
        let pane = NSSplitViewItem(inspectorWithViewController: controller)
        pane.minimumThickness = 280
        pane.maximumThickness = 440
        controller.addAccessories(to: pane)
        let split = NSSplitViewController()
        split.splitView.isVertical = true
        split.addSplitViewItem(pane)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 600),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = split
        window.setContentSize(NSSize(width: 320, height: 600))
        defer { window.close() }
        let view = split.view
        view.layoutSubtreeIfNeeded()
        let outlineView = try #require(inspectorViews(controller.view).compactMap { $0 as? NSOutlineView }.first)
        let outline = try #require(outlineView.delegate as? BackgroundServiceOutlineController)
        let scroll = try #require(outlineView.enclosingScrollView)
        #expect(pane.topAlignedAccessoryViewControllers.first === controller.profileAccessory)
        // Only the list scrolls; the profile controls stay above it.
        #expect(!inspectorViews(controller.profileAccessory.view).contains { $0 is NSScrollView })
        window.makeKeyAndOrderFront(nil)
        try await wait(timeout: .seconds(5)) {
            view.layoutSubtreeIfNeeded()
            return scroll.contentInsets.top > 0
        }
        // Saving and reverting show only while the services differ from the profile.
        let accessory = controller.actionsAccessory
        func shownActions() -> (shown: Bool, height: CGFloat, top: CGFloat, bottom: CGFloat) {
            view.layoutSubtreeIfNeeded()
            let hidden = accessory.saveButton.isHiddenOrHasHiddenAncestor
            #expect(accessory.revertButton.isHiddenOrHasHiddenAncestor == hidden)
            return (!hidden, accessory.view.frame.height, scroll.contentInsets.top, scroll.contentInsets.bottom)
        }
        let unchanged = shownActions()
        #expect(!unchanged.shown && !model.hasProfileChanges)
        let scrollFrame = scroll.convert(scroll.bounds, to: controller.view)
        #expect(scrollFrame == controller.view.bounds)
        #expect(scroll.contentInsets.top == scroll.safeAreaInsets.top)
        #expect(scroll.contentInsets.bottom == scroll.safeAreaInsets.bottom)
        let origin = scroll.contentView.bounds.origin
        scroll.contentView.scroll(to: NSPoint(x: 0, y: outlineView.rect(ofRow: 0).minY - scroll.contentInsets.top / 2))
        scroll.reflectScrolledClipView(scroll.contentView)
        let firstRow = outlineView.convert(outlineView.rect(ofRow: 0), to: controller.view)
        #expect(firstRow.maxY > scrollFrame.maxY - scroll.contentInsets.top)
        #expect(firstRow.minY < scrollFrame.maxY)
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(outline.view.bounds.height > 100)
        #expect(pane.topAlignedAccessoryViewControllers.count == 2)
        #expect(pane.topAlignedAccessoryViewControllers.last === accessory)
        #expect(pane.bottomAlignedAccessoryViewControllers.isEmpty)
        let searchFrame = accessory.view.convert(accessory.view.bounds, to: nil)
        let profileFrame = controller.profileAccessory.view.convert(controller.profileAccessory.view.bounds, to: nil)
        #expect(searchFrame.maxY <= profileFrame.minY)
        let columnWidth = try #require(outline.outline.tableColumns.first).width
        outline.outline.expandItem(category)
        view.layoutSubtreeIfNeeded()
        #expect(category.isExpanded)
        #expect(outline.outline.tableColumns.first?.width == columnWidth)
        let widgets = try #require(model.categories.first { $0.id == "widgets" })
        widgets.isExpanded = false
        let search = accessory.searchField
        search.stringValue = "COM.APPLE.CHRONOD"
        #expect(NSApp.sendAction(try #require(search.action), to: search.target, from: search))
        try await wait(timeout: .seconds(5)) {
            outline.outline.numberOfRows == 2 && outline.outline.isItemExpanded(widgets)
        }
        #expect(outline.model.sections.flatMap(\.items).map(\.label) == ["com.apple.chronod"])
        #expect(!widgets.isExpanded && category.isExpanded)
        search.stringValue = "no-matching-service"
        #expect(NSApp.sendAction(try #require(search.action), to: search.target, from: search))
        #expect(outline.model.sections.isEmpty)
        search.stringValue = ""
        #expect(NSApp.sendAction(try #require(search.action), to: search.target, from: search))
        try await wait(timeout: .seconds(5)) {
            outline.outline.isItemExpanded(category) && !outline.outline.isItemExpanded(widgets)
        }
        #expect(outline.outline.tableColumns.first?.width == columnWidth)
        let row = outline.outline.row(forItem: item)
        let cell = try #require(outline.outline.view(atColumn: 0, row: row, makeIfNecessary: true))
        let label = try #require(inspectorViews(cell).compactMap { $0 as? NSTextField }.first { $0.stringValue == item.label })
        let sharedEditor = try #require(window.fieldEditor(true, for: label) as? NSTextView)
        sharedEditor.enabledTextCheckingTypes = NSTextCheckingResult.CheckingType.link.rawValue
        label.selectText(nil)
        let text = try #require(label.currentEditor())
        #expect(text.string == item.label && text.selectedRange == NSRange(location: 0, length: item.label.utf16.count))
        #expect((text as? NSTextView)?.enabledTextCheckingTypes == 0)
        let toggle = try #require(cell.subviews.compactMap { $0 as? NSSwitch }.first)
        outlineView.scrollRowToVisible(row)
        view.layoutSubtreeIfNeeded()
        let scrollPosition = scroll.contentView.bounds.origin
        let serviceFrame = outlineView.convert(outlineView.rect(ofRow: row), to: controller.view)
        toggle.state = .off
        let action = try #require(toggle.action)
        #expect(NSApp.sendAction(action, to: toggle.target, from: toggle))
        #expect(await events.next() == .changeServices(device.id))
        try await wait(timeout: .seconds(5)) {
            let changed = shownActions()
            return changed.shown
        }
        #expect(shownActions() == (true, unchanged.height, unchanged.top, unchanged.bottom))
        #expect(scroll.contentView.bounds.origin == scrollPosition)
        #expect(outlineView.convert(outlineView.rect(ofRow: row), to: controller.view) == serviceFrame)

        await source.completeServiceChange(disabled: [item.label])
        try await awaitServiceOperations(manager)
        toggle.state = .on
        #expect(NSApp.sendAction(action, to: toggle.target, from: toggle))
        #expect(await events.next() == .changeServices(device.id))
        await source.completeServiceChange(disabled: [])
        try await awaitServiceOperations(manager)
        try await wait(timeout: .seconds(5)) { shownActions() == unchanged }
        #expect(!model.hasProfileChanges && !model.canSaveProfile && !model.canRevertProfile)
        #expect(store.binding(for: device.id)?.overrides.isEmpty == true)
        #expect(scroll.contentView.bounds.origin == scrollPosition)
        #expect(outlineView.convert(outlineView.rect(ofRow: row), to: controller.view) == serviceFrame)

        toggle.state = .off
        #expect(NSApp.sendAction(action, to: toggle.target, from: toggle))
        #expect(await events.next() == .changeServices(device.id))
        try await wait(timeout: .seconds(5)) { shownActions().shown }

        view.frame.size.width = 440
        view.layoutSubtreeIfNeeded()
        view.frame.size.width = 280
        view.layoutSubtreeIfNeeded()
        #expect(category.isExpanded && outline.outline.isItemExpanded(category))
        #expect(!item.isEnabled)
        #expect(model.canSaveProfile)
        model.saveProfile()
        #expect(model.profileEditor != nil)
        try await wait(timeout: .seconds(5)) {
            window.attachedSheet != nil
        }
        let sheet = try #require(window.attachedSheet)
        // The sheet takes the height of its name field and buttons, and starts editing the name.
        #expect(abs(sheet.contentLayoutRect.height - (sheet.contentView?.fittingSize.height ?? 0)) < 1)
        try await wait(timeout: .seconds(5)) {
            sheet.firstResponder is NSTextView
        }
        let expandedWidth = try #require(outline.outline.tableColumns.first).width
        outline.outline.collapseItem(category)
        view.layoutSubtreeIfNeeded()
        #expect(outline.outline.tableColumns.first?.width == expandedWidth)
        await source.completeServiceChange(disabled: [item.label])
        try await awaitServiceOperations(manager)
        let editor = try #require(model.profileEditor)
        editor.name = "Development"
        #expect(editor.commit())
        let saved = try #require(store.profiles.first)
        #expect(saved.configuration.disabledLabels == [item.label])
        #expect(!model.hasProfileChanges)
        try await wait(timeout: .seconds(5)) { shownActions() == unchanged }
        #expect(
            model.profileChoices.map(\.id) == [
                .profile(ServiceProfile.allServicesID), .profile(ServiceProfile.minimalID), .profile(saved.id),
            ])
        #expect(settings.settings.serviceProfiles.model.store.profile(saved.id) === saved)
        let profiles = controller.profileAccessory.profileButton
        try await wait(timeout: .seconds(5)) {
            profiles.titleOfSelectedItem == "Development"
        }

        model.setServices([.service(item.label)], enabled: true)
        #expect(await events.next() == .changeServices(device.id))
        await source.completeServiceChange(disabled: [])
        try await awaitServiceOperations(manager)
        try await wait(timeout: .seconds(5)) {
            profiles.titleOfSelectedItem == "Development (Modified)"
        }
        #expect(shownActions().shown)
        model.saveProfile()
        #expect(store.profiles.count == 1 && store.profiles.first?.id == saved.id)
        #expect(store.profiles.first?.configuration.disabledLabels.isEmpty == true)
        #expect(!model.hasProfileChanges)
        try await wait(timeout: .seconds(5)) { shownActions() == unchanged }
        let binding = store.binding(for: device.id)
        model.profileEditor = nil
        try await wait(timeout: .seconds(5)) {
            profiles.titleOfSelectedItem == "Development"
        }
        let openSettings = try #require(profiles.itemArray.last)
        profiles.select(openSettings)
        #expect(NSApp.sendAction(try #require(openSettings.action), to: openSettings.target, from: openSettings))
        #expect(profiles.titleOfSelectedItem == "Development")
        #expect(settings.settings.selectedTabViewItemIndex == 3)
        #expect(settings.settings.serviceProfiles.model.selectedProfile === saved)
        #expect(store.binding(for: device.id) == binding)
        #expect(model.selectedProfileSelection == .profile(saved.id))
        try await manager.prepareForQuit()
    }

    @Test func automaticDeviceFailuresUseTheSelectedInspectorsBottomAccessory() async throws {
        _ = NSApplication.shared
        let domain = "NeoSimulator.DeviceFeedback.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: serviceProfileURL(domain).deletingLastPathComponent())
        }
        let first = simulator(deviceSet: "/first", name: "First Phone")
        let second = simulator(deviceSet: "/second", name: "Second Phone")
        let source = ManagerModelSource(devices: [
            simulator(deviceSet: "/first", name: first.name, state: "Shutdown"),
            simulator(deviceSet: "/second", name: second.name, state: "Shutdown"),
        ])
        await source.skipSettingsReads()
        await source.holdServiceReads()
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(
            source: source,
            serviceProfiles: ServiceProfileStore(fileURL: serviceProfileURL(domain), legacyDefaults: nil))
        var failures: [any Error] = []
        manager.onError = { failures.append($0) }
        let controller = ManagerWindowController(
            model: manager, screens: DeviceScreens(model: manager),
            menus: MenuController(application: nil), defaults: defaults)
        controller.window?.setFrameAutosaveName("")
        defer { controller.window?.close() }
        let split = try #require(controller.window?.contentViewController as? NSSplitViewController)
        let sidebar = try #require(split.splitViewItems.first?.bottomAlignedAccessoryViewControllers.first)

        await manager.refresh()
        await source.setDevices([first, second])
        await manager.refresh()
        let reads = [await events.next(), await events.next()]
        #expect(reads.contains(.readServices(first.id)) && reads.contains(.readServices(second.id)))
        await source.failServiceRead()
        await source.failServiceRead()
        try await awaitServiceOperations(manager)
        #expect(failures.isEmpty && manager.backgroundIssue == nil)

        controller.selectDevice(first.id)
        let inspector = try #require(split.splitViewItems.last?.bottomAlignedAccessoryViewControllers.first)
        func shows(_ name: String) -> Bool {
            !inspector.isHidden
                && inspectorViews(inspector.view).compactMap { $0 as? NSTextField }
                    .contains { $0.stringValue.contains(name) }
        }
        try await wait { shows(first.name) }
        #expect(sidebar.isHidden)
        controller.selectDevice(second.id)
        try await wait { shows(second.name) }
        #expect(!shows(first.name))
        controller.sidebar.model.select([])
        controller.sidebar.update()
        try await wait { inspector.isHidden }
        controller.selectDevice(first.id)
        try await wait { shows(first.name) }

        manager.inventoryObservationFailed(ManagerModelSource.Failure.unavailable)
        try await wait { !sidebar.isHidden }
        #expect(shows(first.name))
        let retry = try #require(
            inspectorViews(inspector.view).compactMap { $0 as? NSButton }
                .first { $0.title == "Try Again" })
        retry.performClick(nil)
        #expect(await events.next() == .readServices(first.id))
        await source.completeServiceRead(disabled: [], for: first.id)
        try await awaitServiceOperations(manager)
        try await wait { inspector.isHidden }
        #expect(!sidebar.isHidden && manager.backgroundIssue != nil)
        controller.selectDevice(second.id)
        try await wait { shows(second.name) }
        try await manager.prepareForQuit()
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
}
