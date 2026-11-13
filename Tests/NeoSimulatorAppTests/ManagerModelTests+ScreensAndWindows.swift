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
    @Test func inventoryLoadingAndFailuresStayInTheSidebar() async throws {
        _ = NSApplication.shared
        let source = ManagerModelSource(devices: [])
        await source.holdInventoryReads()
        defer { Task { await source.completeInventoryRead() } }
        var events = source.events.makeAsyncIterator()
        let model = SimulatorManagerModel(source: source)
        model.registry.stopReading()
        let controller = ManagerWindowController(model: model, screens: DeviceScreens(model: model),
                                                 menus: MenuController(application: nil))
        controller.window?.setFrameAutosaveName("")
        defer { controller.window?.close() }
        let split = try #require(controller.window?.contentViewController as? NSSplitViewController)
        let sidebar = try #require(split.splitViewItems.first)
        let status = try #require(inspectorViews(sidebar.viewController.view)
            .compactMap { $0 as? NSHostingView<SidebarStatusView> }.first)
        let startup = AsyncStream<Void>.makeStream()
        defer { startup.continuation.finish() }
        model.requestHostPreferenceAccess = {
            var permission = startup.stream.makeAsyncIterator()
            _ = await permission.next()
        }
        model.start()
        try await wait { status.rootView.content == .loading && !status.isHidden }
        #expect(!model.isRefreshingInventory)
        startup.continuation.finish()
        #expect(await events.next() == .inventory)
        try await wait { status.rootView.content == .loading && !status.isHidden }
        await source.completeInventoryRead()
        try await wait { !model.isBusy && status.rootView.content == .empty }
        model.inventoryObservationFailed(ManagerModelSource.Failure.unavailable)
        try await wait {
            if case .failure = status.rootView.content { return true }
            return false
        }
        let issue = try #require(model.backgroundIssue)
        #expect(!inspectorViews(controller.deviceScreenViewController.view)
            .compactMap { $0 as? NSTextField }.contains { $0.stringValue == issue })
        await source.setDevices([simulator()])
        await model.refresh()
        try await wait { status.isHidden }
        let banner = try #require(sidebar.bottomAlignedAccessoryViewControllers.first)
        #expect(!banner.isHidden)
        #expect(inspectorViews(banner.view).compactMap { $0 as? NSTextField }.contains { $0.stringValue == issue })
        var retried = false
        let recovered = AsyncStream<Void>.makeStream()
        defer { recovered.continuation.finish() }
        model.retryDeviceObservation = {
            retried = true
            var recovery = recovered.stream.makeAsyncIterator()
            _ = await recovery.next()
            model.inventoryObservationRecovered()
        }
        let retry = try #require(inspectorViews(banner.view).compactMap { $0 as? NSButton }.first)
        await source.holdInventoryReads()
        retry.performClick(nil)
        #expect(await events.next() == .inventory)
        await source.completeInventoryRead()
        try await wait { retried }
        #expect(!banner.isHidden)
        recovered.continuation.finish()
        try await wait { retried && banner.isHidden }
        let switching = AsyncStream<Void>.makeStream()
        defer { switching.continuation.finish() }
        model.requestHostPreferenceAccess = {
            var permission = switching.stream.makeAsyncIterator()
            _ = await permission.next()
        }
        model.openDeviceHub(xcodeURL: URL(filePath: "/Applications/Test Xcode.app"))
        try await wait {
            !banner.isHidden && inspectorViews(banner.view).compactMap { $0 as? NSProgressIndicator }
                .contains { !$0.isHidden }
        }
        switching.continuation.finish()
        try await wait { !model.isBusy && banner.isHidden }
    }

    @Test func theDisplayHostPickerIsExplicitAndDirectHubLaunchesDoNotSelectIt() async throws {
        let source = ManagerModelSource(devices: [])
        let manager = SimulatorManagerModel(source: source)
        await manager.refresh()
        let settings = GeneralSettingsModel(
            manager: manager, preferences: SimulatorPreferences(),
            frameworks: manager.frameworks, restart: {})
        settings.preferredHost = .deviceHub
        try await wait { !manager.isBusy }
        #expect(await source.selectedHosts == [.deviceHub])
        manager.openDeviceHub(xcodeURL: URL(filePath: "/Applications/Test Xcode.app"))
        try await wait { !manager.isBusy }
        #expect(await source.selectedHosts == [.deviceHub])
        settings.preferredHost = .neo
        try await wait { !manager.isBusy }
        #expect(await source.selectedHosts == [.deviceHub, .neo])
        try await manager.prepareForQuit()
    }

    @Test func aTakeoverCancelsAcceptedSimulatorOpensAndPreservesFailuresAndLaterRequests() async throws {
        let clean = simulator(), failing = simulator(deviceSet: "/failing-set"), later = simulator(deviceSet: "/later-set")
        let source = ManagerModelSource(devices: [clean, failing, later])
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source)
        await manager.refresh()
        var reports: [String] = []
        manager.onError = { reports.append($0.localizedDescription) }
        var began = 0
        let takeovers = HostTakeovers<NSObject>(didBegin: {
            began += 1
            manager.cancelPendingSimulatorOpens()
        }, report: { reports.append($0.localizedDescription) })
        manager.openDevice(clean.id)
        #expect(await events.next() == .open(clean.id))
        manager.openDevice(failing.id)
        #expect(await events.next() == .open(failing.id))
        let first = NSObject(), second = NSObject()
        takeovers.begin(first, hostName: "Simulator") {
            takeovers.begin(second, hostName: "Simulator", checkOthers: {})
        }
        #expect(began == 1)
        #expect(source.cancelledOpenIDs == [clean.id, failing.id])
        await source.completeOpen(for: clean.id)
        await source.failOpen()
        try await wait { manager.openingDeviceIDs.isEmpty && reports.count == 1 }
        takeovers.end(first, failure: nil)
        takeovers.end(second, failure: nil)
        #expect(reports == ["Unavailable", "Simulator is now displaying the simulators."])
        manager.openDevice(later.id)
        #expect(await events.next() == .open(later.id))
        #expect(!source.cancelledOpenIDs.contains(later.id))
        await source.failOpen()
        try await wait { reports.count == 3 }
        try await manager.quitRenderer(keepingDevicesRunning: true)
    }

    @Test(arguments: [false, true])
    func preferenceAccessIsReusedAfterRelaunch(_ selectsFolder: Bool) async throws {
        let domain = "dev.lynnswap.NeoSimulator.HostPreferenceAccess.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "settings.plist")
        try PropertyListSerialization.data(fromPropertyList: [:], format: .xml, options: 0).write(to: file)
        var selections = 0
        let chooseFile: (URL, NSWindow?) async throws -> URL? = { requested, _ in
            #expect(requested == file)
            selections += 1
            return selectsFolder ? directory : file
        }
        let domains = SystemPreferenceDomains()
        let preference = ManagedPreference(domain: file.deletingPathExtension().path, key: "enabled")
        do {
            let access = HostPreferenceAccess(defaults: defaults, file: file, chooseFile: chooseFile)
            try await access.request()
            try await domains.write(.trueValue, to: preference)
        }
        let restored = HostPreferenceAccess(defaults: defaults, file: file, chooseFile: chooseFile)
        #expect(restored.restore())
        try await restored.request()
        #expect(selections == 1)
        #expect(try await domains.readDomain(preference.domain, keys: [preference.key])[preference.key] as? Bool == true)
        #if DEBUG
        restored.reset()
        #expect(!restored.restore())
        let reset = HostPreferenceAccess(defaults: defaults, file: file, chooseFile: chooseFile)
        #expect(!reset.restore())
        try await restored.request()
        #expect(selections == 2)
        #endif
    }

    @Test(arguments: DeviceBrowserPresentation.SortOrder.allCases)
    func sidebarSortsOwnTheirSections(_ order: DeviceBrowserPresentation.SortOrder) throws {
        let records = try CoreDeviceInventoryDecoder.decode(Data(#"""
        {"result":{"devices":[
          {"identifier":"phone","properties":{"hardware":{"fidelity":"physical","osPlatform":"iOS"},
            "state":{"name":"Beta"},"software":{"osVersionNumber":{"stringValue":"27.2"}},
            "connection":{"state":"connected","lastConnectionDate":200}}},
          {"identifier":"provisioning","properties":{"hardware":{"fidelity":"physical","osPlatform":"iOS"},
            "state":{"name":"Bravo","visibilityClass":"devicesBeingProvisioned"},
            "software":{"osVersionNumber":{"stringValue":"27.2"}},
            "connection":{"state":"unavailable","lastConnectionDate":50}}},
          {"identifier":"vm","properties":{"hardware":{"fidelity":"virtual","osPlatform":"macOS"},
            "state":{"name":"Alpha"},"software":{"osVersionNumber":{"stringValue":"15.10"}},
            "connection":{"state":"connected","lastConnectionDate":100}}},
          {"identifier":"other","properties":{"hardware":{"fidelity":"future","marketingName":"Fallback Name"}}},
          {"identifier":"symbol","properties":{"hardware":{"fidelity":"future"},"state":{"name":"42"}}}
        ]}}
        """#.utf8))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let presentation = DeviceBrowserPresentation(devices: records.map(InventoryDevice.remote), sortOrder: order,
                                                     calendar: calendar, locale: Locale(identifier: "en_US_POSIX"),
                                                     now: Date(timeIntervalSinceReferenceDate: 86_400))
        let expected: [String] = switch order {
        case .availability: ["Available", "Unavailable"]
        case .recent: ["Jan 2, 2001", "Jan 1, 2001", "Other"]
        case .name: ["Other", "A", "B", "#"]
        case .fidelity: ["Other", "Physical Devices", "Virtual Machines"]
        case .platform: ["iOS", "macOS", "Other"]
        case .operatingSystem: ["Other Other", "iOS 27.2", "macOS 15.10"]
        }
        #expect(presentation.sections.map(\.title) == expected)
        #expect(Set(presentation.devices.map(\.id)) == Set(records.map { .coreDevice($0.identifier) }))
        // The same-day provisioning Bravo precedes Beta except where Name compares names first.
        let names = presentation.devices.map(\.name)
        let bravo = try #require(names.firstIndex(of: "Bravo")), beta = try #require(names.firstIndex(of: "Beta"))
        #expect((bravo < beta) == (order != .name))
        if order == .recent {
            #expect(presentation.sections[1].devices.map(\.name) == ["Beta", "Alpha"])
        }
        if order == .name { #expect(presentation.sections[0].devices[0].name == "Fallback Name") }
    }

    @Test func deviceKitActiveStateOrdersAndDrawsRowsWithoutChangingSelection() async throws {
        _ = NSApplication.shared
        let domain = "NeoSimulator.SidebarFixture.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        // One section, so availability and the Active priority order rows across it.
        defaults.set(DeviceBrowserPresentation.SortOrder.fidelity.rawValue, forKey: "SidebarSortOrder")
        let ids = Dictionary(uniqueKeysWithValues: ["Alpha", "Mike", "Zulu", "Echo"].map { ($0, UUID()) })
        // Booting gives Alpha and Mike Neo's own active artwork; Echo is unavailable.
        let data = try JSONSerialization.data(withJSONObject: ["result": ["devices": [
            ("Alpha", "connected", ["bootState": "booting"]), ("Mike", "connected", ["bootState": "booting"]),
            ("Zulu", "connected", [:]), ("Echo", "unavailable", [:]),
        ].map { name, connection, state in
            ["identifier": ids[name]!.uuidString, "properties": ["hardware": ["fidelity": "physical"],
                "state": state.merging(["name": name]) { $1 }, "connection": ["state": connection]]]
        }]])
        let model = SimulatorManagerModel(source: ManagerModelSource(devices: try CoreDeviceInventoryDecoder.decode(data).map(InventoryDevice.remote)))
        model.registry.stopReading()
        await model.refresh()
        let controller = ManagerWindowController(model: model, screens: DeviceScreens(model: model),
                                                 menus: MenuController(application: nil), defaults: defaults)
        controller.window?.setFrameAutosaveName("")
        defer { controller.window?.close() }
        // The unshown window is only tall enough for every row when an earlier run saved its autosave frame.
        controller.window?.setContentSize(NSSize(width: 1040, height: 700))
        let content = try #require(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let outline = try #require(inspectorViews(content).compactMap { $0 as? NSOutlineView }.first)
        controller.selectDevice(.coreDevice(ids["Mike"]!.uuidString))
        func rows() -> [String: Int] {
            Dictionary(uniqueKeysWithValues: (0..<outline.numberOfRows).compactMap { row in
                outline.item(atRow: row).flatMap { controller.sidebar.outlineView(outline, typeSelectStringFor: nil, item: $0) }.map { ($0, row) }
            })
        }
        func order() -> [String] { rows().sorted { $0.value < $1.value }.map(\.key) }
        func artwork() -> [String: Bool] {
            content.layoutSubtreeIfNeeded()
            return rows().compactMapValues { row in
                outline.view(atColumn: 0, row: row, makeIfNecessary: false)?.subviews
                    .compactMap { $0 as? NSHostingView<SidebarDeviceArtwork> }.first?.rootView.isActive
            }
        }
        func update(_ change: () -> Void, until expected: [String]) async throws {
            change()
            try await wait(timeout: .seconds(5)) {
                order() == expected
            }
            #expect(controller.selectedIdentifiers == [.coreDevice(ids["Mike"]!.uuidString)])
            #expect(outline.selectedRow == rows()["Mike"])
        }
        #expect(order() == ["Alpha", "Mike", "Zulu", "Echo"])
        #expect(artwork() == ["Alpha": true, "Mike": true, "Zulu": false, "Echo": false])

        // Native false overrides Neo's booting artwork; unknown Mike keeps it without being promoted or demoted.
        try await update({ model.activeStatesDidChange(DeviceActiveStates([ids["Zulu"]!: true, ids["Alpha"]!: false, ids["Echo"]!: true])) },
                         until: ["Zulu", "Alpha", "Mike", "Echo"])
        #expect(artwork() == ["Alpha": false, "Mike": true, "Zulu": true, "Echo": true])
        // The same order still redraws the row whose value changed.
        model.activeStatesDidChange(DeviceActiveStates([ids["Zulu"]!: true, ids["Alpha"]!: false, ids["Mike"]!: false, ids["Echo"]!: true]))
        try await wait(timeout: .seconds(5)) {
            artwork()["Mike"] == false
        }
        #expect(order() == ["Zulu", "Alpha", "Mike", "Echo"])

        try await update({ model.activeStateObservationFailed(ManagerModelSource.Failure.unavailable) },
                         until: ["Alpha", "Mike", "Zulu", "Echo"])
        #expect(artwork() == ["Alpha": true, "Mike": true, "Zulu": false, "Echo": false])
        #expect(model.backgroundIssue?.contains("Active devices are unavailable") == true)
    }

    @Test func sidebarOptionsRestoreAndUseNativeFallbacks() throws {
        let domain = "NeoSimulator.SidebarFixture.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        var options = DeviceBrowserPresentation.Options(defaults: defaults)
        #expect(options.sortOrder == .recent && options.showGroups)
        options.sortOrder = .availability
        options.showGroups = false
        options.save(to: defaults)
        let restored = DeviceBrowserPresentation.Options(defaults: defaults)
        #expect(restored.sortOrder == .availability && !restored.showGroups)
        defaults.set(-1, forKey: "SidebarSortOrder")
        #expect(DeviceBrowserPresentation.Options(defaults: defaults).sortOrder == .recent)
    }

    @Test(arguments: ["new-selection", "return-selection", "rollback"])
    func pendingPresentationKeepsTheLaterSelectionAndCanvas(_ mode: String) async throws {
        _ = NSApplication.shared
        let devices = try CoreDeviceInventoryDecoder.decode(Data(#"{"result":{"devices":[{"identifier":"A","properties":{"hardware":{"fidelity":"physical"},"state":{"name":"A"}}},{"identifier":"B","properties":{"hardware":{"fidelity":"physical"},"state":{"name":"B"}}}]}}"#.utf8))
        let a = try #require(devices.first), b = try #require(devices.last)
        let source = ManagerModelSource(devices: devices.map(InventoryDevice.remote))
        let model = SimulatorManagerModel(source: source)
        model.registry.stopReading()
        await model.refresh()
        let app = AppDelegate(makeLicenses: SettingsPreview.licenses)
        app.model = model
        app.prepareMainWindow()
        let main = try #require(app.mainWindow)
        main.window?.setFrameAutosaveName("")
        let pane = main.deviceScreenViewController
        let aTransport = TestRemoteScreenTransport(), bTransport = TestRemoteScreenTransport()
        let aSession = RemoteDeviceScreenSession(device: a) { _, _, _ in aTransport }
        let bSession = RemoteDeviceScreenSession(device: b) { _, _, _ in bTransport }
        try await aSession.start()
        try await bSession.start()
        let aController = RemoteDeviceWindowController(device: a, session: aSession, presentCompactWindow: { _ in })
        let bController = RemoteDeviceWindowController(device: b, session: bSession, presentCompactWindow: { _ in })
        let aID = DeviceInventoryID.coreDevice(a.identifier), bID = DeviceInventoryID.coreDevice(b.identifier)
        app.screens.attach(aController)
        app.screens.attach(bController)
        main.selectDevice(aID)
        if mode != "new-selection" {
            try await main.presentConnectedScreen(aID, purpose: .requested)
        }
        let releasing = AsyncStream<Void>.makeStream(), resume = AsyncStream<Void>.makeStream()
        var releases = releasing.stream.makeAsyncIterator()
        aTransport.onReleaseInputs = {
            aTransport.onReleaseInputs = nil
            releasing.continuation.yield(())
            var permits = resume.stream.makeAsyncIterator()
            _ = await permits.next()
        }
        if mode == "return-selection" { main.showDevice(bID) }
        else if mode == "rollback" {
            main.selectDevice(bID)
            bTransport.onReleaseInputs = {
                bTransport.onReleaseInputs = nil
                throw ManagerModelSource.Failure.unavailable
            }
        }
        let target = mode == "new-selection" ? aID : bID
        let opening = Task { try await main.presentConnectedScreen(target, purpose: .requested) }
        #expect(await releases.next() != nil)
        if mode != "rollback" {
            let content = try #require(main.window?.contentView)
            let outline = try #require(inspectorViews(content).compactMap { $0 as? NSOutlineView }.first)
            let otherRow = try #require((0..<outline.numberOfRows).first { row in
                row != outline.selectedRow && outline.item(atRow: row).map { main.sidebar.outlineView(outline, shouldSelectItem: $0) } == true
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
        try await wait(timeout: .seconds(5)) {
            pane.liveDeviceIdentifier == rendered && renderedController.presentationViewController.parent === pane.liveScreenContainer
        }
        #expect(main.selectedIdentifiers == [selected])
        #expect(model.selection.device?.id == selected && main.inspectorController.deviceInspector.inspection.device?.id == selected)
        #expect((mode == "new-selection" ? aController : bController).presentationViewController.parent == nil)
        #expect(aSession.state == .connected && app.screens.screen(for: aID)?.commandTarget === aController)
        try await aSession.stop()
        try await bSession.stop()
        main.window?.close()
    }

    @Test func connectionCompletionHonorsTheReselectedDevicesLatestMainIntent() async throws {
        _ = NSApplication.shared
        let devices = try CoreDeviceInventoryDecoder.decode(Data(#"{"result":{"devices":[{"identifier":"A","properties":{"hardware":{"fidelity":"physical"},"state":{"name":"A"}}},{"identifier":"B","properties":{"hardware":{"fidelity":"physical"},"state":{"name":"B"}}}]}}"#.utf8))
        let a = try #require(devices.first), b = try #require(devices.last)
        let model = SimulatorManagerModel(source: ManagerModelSource(devices: devices.map(InventoryDevice.remote)))
        model.registry.stopReading()
        await model.refresh()
        let app = AppDelegate(makeLicenses: SettingsPreview.licenses)
        app.model = model
        app.prepareMainWindow()
        let main = try #require(app.mainWindow)
        main.window?.setFrameAutosaveName("")
        let pane = main.deviceScreenViewController
        let aTransport = TestRemoteScreenTransport(), bTransport = TestRemoteScreenTransport()
        let aSession = RemoteDeviceScreenSession(device: a) { _, _, _ in aTransport }
        let bSession = RemoteDeviceScreenSession(device: b) { _, _, _ in bTransport }
        try await aSession.start()
        try await bSession.start()
        let aController = RemoteDeviceWindowController(device: a, session: aSession, presentCompactWindow: { _ in })
        let bController = RemoteDeviceWindowController(device: b, session: bSession, presentCompactWindow: { _ in })
        let aID = DeviceInventoryID.coreDevice(a.identifier), bID = DeviceInventoryID.coreDevice(b.identifier)
        app.screens.attach(bController)
        main.selectDevice(bID)
        try await main.presentConnectedScreen(bID, purpose: .requested)
        main.selectDevice(aID)
        let content = try #require(main.window?.contentView)
        let outline = try #require(inspectorViews(content).compactMap { $0 as? NSOutlineView }.first)
        let aRow = outline.selectedRow
        let bRow = try #require((0..<outline.numberOfRows).first { row in
            row != aRow && outline.item(atRow: row).map { main.sidebar.outlineView(outline, shouldSelectItem: $0) } == true
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
        app.screens.attach(aController)
        let connected = Task {
            try await main.presentConnectedScreen(aID, purpose: .automatic, preserving: .compact)
        }
        resume.continuation.yield(())
        try await connected.value
        try await wait(timeout: .seconds(5)) {
            pane.liveDeviceIdentifier == aID && aController.presentationViewController.parent === pane.liveScreenContainer
        }
        #expect(main.selectedIdentifiers == [aID])
        #expect(model.selection.device?.id == aID && main.inspectorController.deviceInspector.inspection.device?.id == aID)
        #expect(!bController.isEmbedded && aSession.state == .connected)
        try await aSession.stop()
        try await bSession.stop()
        main.window?.close()
    }

    @Test func extendingMultipleSelectionReplacesThePendingDetach() async throws {
        _ = NSApplication.shared
        let devices = try CoreDeviceInventoryDecoder.decode(Data(#"{"result":{"devices":[{"identifier":"A","properties":{"hardware":{"fidelity":"physical"},"state":{"name":"A"}}},{"identifier":"B","properties":{"hardware":{"fidelity":"physical"},"state":{"name":"B"}}},{"identifier":"C","properties":{"hardware":{"fidelity":"physical"},"state":{"name":"C"}}}]}}"#.utf8))
        let a = try #require(devices.first), c = try #require(devices.last)
        let aID = DeviceInventoryID.coreDevice(a.identifier), cID = DeviceInventoryID.coreDevice(c.identifier)
        let model = SimulatorManagerModel(source: ManagerModelSource(devices: devices.map(InventoryDevice.remote)))
        model.registry.stopReading()
        await model.refresh()
        let app = AppDelegate(makeLicenses: SettingsPreview.licenses)
        app.model = model
        app.prepareMainWindow()
        let main = try #require(app.mainWindow)
        main.window?.setFrameAutosaveName("")
        let pane = main.deviceScreenViewController
        defer { main.window?.close() }
        let transport = TestRemoteScreenTransport()
        let session = RemoteDeviceScreenSession(device: a) { _, _, _ in transport }
        let backgroundSession = RemoteDeviceScreenSession(device: c) { _, _, _ in TestRemoteScreenTransport() }
        try await session.start()
        try await backgroundSession.start()
        let controller = RemoteDeviceWindowController(device: a, session: session, presentCompactWindow: { _ in })
        let background = RemoteDeviceWindowController(device: c, session: backgroundSession, presentCompactWindow: { _ in })
        let backgroundParent = NSViewController()
        backgroundParent.view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        try await background.embed(in: backgroundParent)
        app.screens.attach(controller)
        app.screens.attach(background)
        main.selectDevice(aID)
        try await main.presentConnectedScreen(aID, purpose: .requested)
        let content = try #require(main.window?.contentView)
        let outline = try #require(inspectorViews(content).compactMap { $0 as? NSOutlineView }.first)
        let rows = (0..<outline.numberOfRows).filter { row in
            outline.item(atRow: row).map { main.sidebar.outlineView(outline, shouldSelectItem: $0) } == true
        }
        try #require(rows.count == 3)
        try await main.presentConnectedScreen(cID, purpose: .automatic, preserving: .compact)
        let releasing = AsyncStream<Void>.makeStream(), resume = AsyncStream<Void>.makeStream()
        var releases = releasing.stream.makeAsyncIterator()
        transport.onReleaseInputs = {
            transport.onReleaseInputs = nil
            releasing.continuation.yield(())
            var permits = resume.stream.makeAsyncIterator()
            _ = await permits.next()
        }
        outline.selectRowIndexes(IndexSet(rows.prefix(2)), byExtendingSelection: false)
        try #require(await releases.next() != nil)
        outline.selectRowIndexes(IndexSet(integer: rows[2]), byExtendingSelection: true)
        try #require(main.selectedIdentifiers.count == 3)
        resume.continuation.yield(())
        try await wait(timeout: .seconds(5)) {
            pane.liveDeviceIdentifier == nil && pane.liveCommandTarget == nil
        }
        #expect(controller.presentationViewController.parent == nil)
        #expect(main.selectedIdentifiers.count == 3 && model.selection.device == nil)
        #expect(app.screens.compactScreen(for: cID) != nil)
        try await app.screens.stopAll()
    }

    @Test func aContextMenuLeavesTheSelectionAndPresentationOfAnyRow() async throws {
        _ = NSApplication.shared
        let devices = try CoreDeviceInventoryDecoder.decode(Data(#"{"result":{"devices":[{"identifier":"A","properties":{"hardware":{"fidelity":"physical"},"state":{"name":"A"},"connection":{"state":"connected"}},"capabilities":[{"featureIdentifier":"com.apple.coredevice.feature.viewdevicescreen"}]},{"identifier":"B","properties":{"hardware":{"fidelity":"physical"},"state":{"name":"B"}}}]}}"#.utf8))
        let a = try #require(devices.first), b = try #require(devices.last)
        let model = SimulatorManagerModel(source: ManagerModelSource(devices: devices.map(InventoryDevice.remote)))
        model.registry.stopReading()
        await model.refresh()
        let app = AppDelegate(makeLicenses: SettingsPreview.licenses)
        app.model = model
        app.prepareMainWindow()
        let main = try #require(app.mainWindow)
        main.window?.setFrameAutosaveName("")
        let pane = main.deviceScreenViewController
        defer { main.window?.close() }
        let aSession = RemoteDeviceScreenSession(device: a) { _, _, _ in TestRemoteScreenTransport() }
        let bSession = RemoteDeviceScreenSession(device: b) { _, _, _ in TestRemoteScreenTransport() }
        try await aSession.start()
        try await bSession.start()
        let aController = RemoteDeviceWindowController(device: a, session: aSession, presentCompactWindow: { _ in })
        let bController = RemoteDeviceWindowController(device: b, session: bSession, presentCompactWindow: { _ in })
        let aID = DeviceInventoryID.coreDevice(a.identifier)
        app.screens.attach(aController)
        app.screens.attach(bController)
        main.selectDevice(aID)
        try await main.presentConnectedScreen(aID, purpose: .requested)
        let compact = try #require(main.window?.toolbar?.items.first { $0.itemIdentifier.rawValue == "CompactDeviceWindow" })
        #expect(NSApp.sendAction(try #require(compact.action), to: compact.target, from: compact))
        try await wait(timeout: .seconds(5)) { app.screens.compactScreen(for: aID) != nil }
        #expect(pane.liveDeviceIdentifier == aID && aController.isEmbedded)
        var compactIntent = main.presentationIntent
        main.sidebar.update()
        let content = try #require(main.window?.contentView)
        let fields = inspectorViews(content)
        let search = try #require(fields.compactMap { $0 as? NSSearchField }.first { $0.placeholderString == "Search" })
        search.stringValue = "B"
        main.sidebar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        search.stringValue = ""
        main.sidebar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        #expect(main.presentationIntent.revision == compactIntent.revision && main.presentationIntent.placement == .compact)
        let outline = try #require(fields.compactMap { $0 as? NSOutlineView }.first)
        #expect(model.canViewScreen(.remote(a)))
        #expect(NSApp.sendAction(try #require(outline.doubleAction), to: outline.target, from: outline))
        #expect(model.openingDeviceIDs.isEmpty)
        await pane.waitForScreenMoves()
        compactIntent = main.presentationIntent
        let aRow = outline.selectedRow
        try #require(aRow >= 0)
        main.sidebar.updateDeviceMenu(for: aRow)
        #expect(main.presentationIntent.revision == compactIntent.revision && main.presentationIntent.placement == .compact)
        let bRow = try #require((0..<outline.numberOfRows).first { row in
            row != aRow && outline.item(atRow: row).map { main.sidebar.outlineView(outline, shouldSelectItem: $0) } == true
        })
        main.sidebar.updateDeviceMenu(for: bRow)
        #expect(main.presentationIntent.revision == compactIntent.revision && main.presentationIntent.placement == .compact)
        #expect(main.selectedIdentifiers == [aID] && outline.selectedRow == aRow)
        #expect(pane.liveDeviceIdentifier == aID && !bController.isEmbedded)
        #expect(model.selection.device?.id == aID && main.inspectorController.deviceInspector.inspection.device?.id == aID)
        let menu = try #require(outline.menu)
        let open = try #require(menu.items.first { $0.title == "Open in New Window" })
        #expect(NSApp.sendAction(try #require(open.action), to: open.target, from: open))
        let bWindow = try #require(app.screens.compactWindow(for: .coreDevice(b.identifier)))
        #expect(bWindow.isVisible && main.selectedIdentifiers == [aID])
        #expect(main.presentationIntent.revision == compactIntent.revision && aController.isEmbedded)
        bWindow.close()
        try await aSession.stop()
        try await bSession.stop()
    }

    @Test func aContextMenuActsOnItsRowOrTheSelectionThatIncludesIt() async throws {
        _ = NSApplication.shared
        let first = simulator(deviceSet: "/first", name: "First")
        let second = simulator(deviceSet: "/second", name: "Second")
        let third = simulator(deviceSet: "/third", name: "Third")
        let source = ManagerModelSource(devices: [first, second, third])
        var events = source.events.makeAsyncIterator()
        let model = SimulatorManagerModel(source: source)
        model.registry.stopReading()
        await model.refresh()
        let app = AppDelegate(makeLicenses: SettingsPreview.licenses)
        app.model = model
        app.prepareMainWindow()
        let main = try #require(app.mainWindow)
        main.window?.setFrameAutosaveName("")
        defer { main.window?.close() }
        main.sidebar.update()
        let content = try #require(main.window?.contentView)
        let outline = try #require(inspectorViews(content).compactMap { $0 as? NSOutlineView }.first)
        let menu = try #require(outline.menu)
        func row(of device: InventoryDevice) throws -> Int {
            try #require((0..<outline.numberOfRows).first { row in
                guard let item = outline.item(atRow: row) else { return false }
                return main.sidebar.outlineView(outline, viewFor: outline.tableColumns.first, item: item)?.accessibilityLabel()?.hasPrefix("\(device.name),") == true
            })
        }
        func restart(fromMenuOf row: Int) async throws {
            try await wait { model.managingDeviceIDs.isEmpty }
            main.sidebar.updateDeviceMenu(for: row)
            menu.performActionForItem(at: try #require(menu.items.firstIndex { $0.title == "Restart" }))
        }

        main.selectDevice(first.id)
        let selection = main.presentationIntent
        // A row outside the selection is the only target, and stays unselected.
        try await restart(fromMenuOf: try row(of: second))
        #expect(await events.next() == .manage(.restart, [second.id]))
        #expect(main.selectedIdentifiers == [first.id] && model.selection.device?.id == first.id)
        #expect(main.presentationIntent.revision == selection.revision)

        // A row inside a multiple selection stands for all of it.
        outline.selectRowIndexes(IndexSet([try row(of: first), try row(of: third)]), byExtendingSelection: false)
        #expect(main.selectedIdentifiers == [first.id, third.id])
        let group = main.presentationIntent
        try await restart(fromMenuOf: try row(of: third))
        #expect(await events.next() == .manage(.restart, [first.id, third.id]))
        // A row outside it does not change it.
        try await restart(fromMenuOf: try row(of: second))
        #expect(await events.next() == .manage(.restart, [second.id]))
        #expect(main.selectedIdentifiers == [first.id, third.id] && main.presentationIntent.revision == group.revision)
        // No row means the selection, and a row that is no device has no menu.
        try await restart(fromMenuOf: -1)
        #expect(await events.next() == .manage(.restart, [first.id, third.id]))
        let header = try #require((0..<outline.numberOfRows).first { outline.item(atRow: $0).map { main.sidebar.outlineView(outline, shouldSelectItem: $0) } == false })
        main.sidebar.updateDeviceMenu(for: header)
        #expect(menu.items.isEmpty)
        #expect(main.selectedIdentifiers == [first.id, third.id] && main.presentationIntent.revision == group.revision)
        main.selectDevice(first.id)
        main.sidebar.updateDeviceMenu(for: try row(of: second))
        let open = try #require(menu.items.first { $0.title == "Open in New Window" })
        #expect(NSApp.sendAction(try #require(open.action), to: open.target, from: open))
        let previewWindow = try #require(app.screens.compactWindow(for: second.id))
        let previewContent = try #require(previewWindow.contentView)
        let viewScreen = try #require(
            inspectorViews(previewContent).compactMap { $0 as? NSButton }
                .first { $0.title == "View Screen" })
        viewScreen.performClick(nil)
        #expect(await events.next() == .open(second.id))
        #expect(main.selectedIdentifiers == [first.id])
        await source.completeOpen(for: second.id)
        try await wait { model.openingDeviceIDs.isEmpty }
        previewWindow.close()
        try await model.quitRenderer(keepingDevicesRunning: true)
    }

    @Test func startingSimulatorsFromTheSidebarOpensTheScreenOfEach() async throws {
        _ = NSApplication.shared
        let first = simulator(deviceSet: "/first", name: "First", state: "Shutdown")
        let second = simulator(deviceSet: "/second", name: "Second", state: "Shutdown")
        let source = ManagerModelSource(devices: [first, second])
        var events = source.events.makeAsyncIterator()
        let model = SimulatorManagerModel(source: source)
        model.registry.stopReading()
        await model.refresh()
        let app = AppDelegate(makeLicenses: SettingsPreview.licenses)
        app.model = model
        app.prepareMainWindow()
        let main = try #require(app.mainWindow)
        main.window?.setFrameAutosaveName("")
        defer { main.window?.close() }
        main.sidebar.update()
        let content = try #require(main.window?.contentView)
        let outline = try #require(inspectorViews(content).compactMap { $0 as? NSOutlineView }.first)
        let menu = try #require(outline.menu)
        let rows = (0..<outline.numberOfRows).filter { row in
            outline.item(atRow: row).map { main.sidebar.outlineView(outline, shouldSelectItem: $0) } == true
        }
        outline.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
        #expect(main.selectedIdentifiers == [first.id, second.id])

        main.sidebar.updateDeviceMenu(for: -1)
        menu.performActionForItem(at: try #require(menu.items.firstIndex { $0.title == "Start" }))
        let opened = [await events.next(), await events.next()]
        #expect(opened.contains(.open(first.id)) && opened.contains(.open(second.id)))
        #expect(await source.lastOpenBootIfNeeded == true)
        await source.completeOpen(for: first.id)
        await source.completeOpen(for: second.id)
        try await wait { !model.isBusy }
        main.selectDevice(first.id)
        let navigation = NSMenu()
        main.deviceActions.populate(navigation, devices: [second])
        let open = try #require(navigation.items.first { $0.title == "Open in New Window" })
        #expect(NSApp.sendAction(try #require(open.action), to: open.target, from: open))
        let previewWindow = try #require(app.screens.compactWindow(for: second.id))
        let previewMenu = try #require(app.screens.makeCompactDeviceMenu?(second, previewWindow))
        previewMenu.performActionForItem(at: try #require(previewMenu.items.firstIndex { $0.title == "Start" }))
        #expect(await events.next() == .open(second.id))
        #expect(main.selectedIdentifiers == [first.id])
        await source.completeOpen(for: second.id)
        try await wait { !model.isBusy }
        previewWindow.close()
        try await model.quitRenderer(keepingDevicesRunning: true)
    }

    @Test(arguments: [false, true])
    func automaticPresentationPreservesSelectionAndInitialPresentation(_ initial: Bool) async throws {
        _ = NSApplication.shared
        let domain = "NeoSimulator.AutomaticPresentation.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let devices = try CoreDeviceInventoryDecoder.decode(Data(#"{"result":{"devices":[{"identifier":"A","properties":{"hardware":{"fidelity":"physical"},"state":{"name":"A"}}},{"identifier":"B","properties":{"hardware":{"fidelity":"physical"},"state":{"name":"B"}}}]}}"#.utf8))
        let a = try #require(devices.first), b = try #require(devices.last)
        let aID = DeviceInventoryID.coreDevice(a.identifier), bID = DeviceInventoryID.coreDevice(b.identifier)
        let model = SimulatorManagerModel(source: ManagerModelSource(devices: devices.map(InventoryDevice.remote)))
        model.registry.stopReading()
        await model.refresh()
        let app = AppDelegate(makeLicenses: SettingsPreview.licenses)
        app.model = model
        app.prepareMainWindow(defaults: defaults)
        let main = try #require(app.mainWindow)
        main.window?.setFrameAutosaveName("")
        let pane = main.deviceScreenViewController
        let transport = TestRemoteScreenTransport()
        let session = RemoteDeviceScreenSession(device: a) { _, _, _ in transport }
        try await session.start()
        var compactPresentations = 0
        let controller = RemoteDeviceWindowController(device: a, session: session,
            presentCompactWindow: { _ in compactPresentations += 1 })
        app.screens.attach(controller)
        if !initial { main.selectDevice(bID) }
        try await main.presentConnectedScreen(aID, purpose: .automatic)
        let selected = initial ? aID : bID
        #expect(main.selectedIdentifiers == [selected] && model.selection.device?.id == selected)
        // The inspector follows the selection through observation, whose changes arrive after this turn.
        try await wait { main.inspectorController.deviceInspector.inspection.device?.id == selected }
        #expect(pane.liveDeviceIdentifier == (initial ? aID : nil))
        #expect((controller.presentationViewController.parent === pane.liveScreenContainer) == initial)
        #expect(session.state == .connected && app.screens.screen(for: aID)?.commandTarget === controller)
        if !initial {
            try await main.presentConnectedScreen(aID, purpose: .automatic, preserving: .compact)
            #expect(compactPresentations == 1 && main.selectedIdentifiers == [bID] && pane.liveDeviceIdentifier == nil)
        }
        if initial {
            let window = try #require(main.window)
            window.orderFront(nil)
            #expect(window.isVisible)
            let compact = try #require(
                window.toolbar?.items.first { $0.itemIdentifier.rawValue == "CompactDeviceWindow" })
            #expect(!compact.isHidden && compact.isEnabled)
            #expect(NSApp.sendAction(try #require(compact.action), to: compact.target, from: compact))
            try await wait(timeout: .seconds(5)) { app.screens.compactScreen(for: aID) != nil }
            #expect(window.isVisible)
            #expect(pane.liveDeviceIdentifier == aID && controller.isEmbedded)
            #expect(!compact.isHidden && compact.isEnabled)
            try await main.presentConnectedScreen(aID, purpose: .requested)
            #expect(pane.liveDeviceIdentifier == aID && controller.isEmbedded)
            main.showDevice(aID)
            try await wait(timeout: .seconds(5)) {
                pane.liveDeviceIdentifier == aID && controller.isEmbedded
            }
        }
        try await session.stop()
        main.window?.close()
    }

    @Test(arguments: [false, true])
    func doubleClickShowsAWindowBeforeTheSimulatorOpens(_ closesWhileOpening: Bool) async throws {
        _ = NSApplication.shared
        let device = simulator(state: "Shutdown")
        let source = ManagerModelSource(devices: [device])
        var events = source.events.makeAsyncIterator()
        let model = SimulatorManagerModel(source: source)
        model.registry.stopReading()
        await model.refresh()
        let app = AppDelegate(makeLicenses: SettingsPreview.licenses)
        app.model = model
        let main = app.prepareMainWindow()
        main.window?.setFrameAutosaveName("")
        defer { main.window?.close() }
        main.selectDevice(device.id)
        let content = try #require(main.window?.contentView)
        let outline = try #require(inspectorViews(content).compactMap { $0 as? NSOutlineView }.first)
        #expect(NSApp.sendAction(try #require(outline.doubleAction), to: outline.target, from: outline))
        let compact = try #require(app.screens.compactWindow(for: device.id))
        #expect(compact.isVisible && app.screens.compactScreen(for: device.id) == nil)
        #expect(compact.frame.width / compact.frame.height < 0.53, "Initial compact frame: \(compact.frame)")
        #expect(model.openingDeviceIDs.contains(device.id))
        while let event = await events.next() {
            if event == .open(device.id) { break }
        }
        if closesWhileOpening {
            compact.close()
            #expect(app.screens.compactWindow(for: device.id) == nil && main.presentationIntent.placement == .main)
            await source.completeOpen()
        } else {
            await source.failOpen()
        }
        try await wait { !model.isBusy }
        if !closesWhileOpening {
            #expect(compact.isVisible)
            let labels = inspectorViews(try #require(compact.contentView)).compactMap { $0 as? NSTextField }
            #expect(labels.contains { $0.stringValue == ManagerModelSource.Failure.unavailable.localizedDescription })
            await source.setDevices([simulator(state: "Booted")])
            await model.refresh()
            try await wait { model.canManage(.rename("Renamed"), deviceIDs: [device.id]) }
            let item = try #require(compact.toolbar?.items.compactMap { $0 as? NSMenuToolbarItem }.first)
            let menu = item.menu
            menu.delegate?.menuNeedsUpdate?(menu)
            #expect(menu.items.first?.title == "" && menu.items.dropFirst().first?.title == "View Screen")
            #expect(menu.items.contains { $0.title == "Shut Down" } && !menu.items.contains { $0.title == "Start" })
            let rename = try #require(menu.items.first { $0.title == "Rename…" })
            try #require(rename.isEnabled)
            #expect(NSApp.sendAction(try #require(rename.action), to: rename.target, from: rename))
            try await wait { compact.attachedSheet != nil }
            #expect(main.window?.attachedSheet == nil)
            compact.endSheet(try #require(compact.attachedSheet), returnCode: .alertSecondButtonReturn)
            compact.close()
        }
        #expect(app.screens.compactScreen(for: device.id) == nil)
        try await model.quitRenderer(keepingDevicesRunning: true)
    }

    @Test(arguments: ["sheet", "close", "independent"])
    func aPendingCompactWindowFollowsItsOwnLifetimeDuringMainPresentation(_ mode: String) async throws {
        _ = NSApplication.shared
        let devices = try CoreDeviceInventoryDecoder.decode(
            Data(
                #"{"result":{"devices":[{"identifier":"A","properties":{"hardware":{"fidelity":"physical"},"state":{"name":"A"}}},{"identifier":"B","properties":{"hardware":{"fidelity":"physical"},"state":{"name":"B"}}}]}}"#
                    .utf8))
        let a = try #require(devices.first), b = try #require(devices.last)
        let aID = DeviceInventoryID.coreDevice(a.identifier), bID = DeviceInventoryID.coreDevice(b.identifier)
        let model = SimulatorManagerModel(source: ManagerModelSource(devices: devices.map(InventoryDevice.remote)))
        model.registry.stopReading()
        await model.refresh()
        let app = AppDelegate(makeLicenses: SettingsPreview.licenses)
        app.model = model
        let main = app.prepareMainWindow()
        let window = try #require(main.window)
        window.setFrameAutosaveName("")
        defer { window.close() }
        let transport = TestRemoteScreenTransport()
        let aSession = RemoteDeviceScreenSession(device: a) { _, _, _ in transport }
        let bSession = RemoteDeviceScreenSession(device: b) { _, _, _ in TestRemoteScreenTransport() }
        try await aSession.start()
        try await bSession.start()
        let aController = RemoteDeviceWindowController(device: a, session: aSession, presentCompactWindow: { _ in })
        app.screens.attach(aController)
        app.screens.attach(RemoteDeviceWindowController(device: b, session: bSession, presentCompactWindow: { _ in }))
        main.selectDevice(aID)
        try await main.presentConnectedScreen(aID, purpose: .requested)
        main.selectDevice(bID)
        app.screens.prepareCompactWindow(for: .remote(b))
        let pending = try #require(app.screens.compactWindow(for: bID))
        if mode != "sheet" {
            let releasing = AsyncStream<Void>.makeStream(), resume = AsyncStream<Void>.makeStream()
            var releases = releasing.stream.makeAsyncIterator()
            transport.onReleaseInputs = {
                transport.onReleaseInputs = nil
                releasing.continuation.yield(())
                var permits = resume.stream.makeAsyncIterator()
                _ = await permits.next()
            }
            let opening = Task { try await main.presentConnectedScreen(bID, purpose: .requested) }
            #expect(await releases.next() != nil)
            let compact: Task<Void, any Error>?
            if mode == "close" {
                pending.close()
                compact = nil
            } else {
                compact = Task {
                    try await main.deviceScreenViewController.switchToCompactWindow(for: bID, while: { true })
                }
                do { try await wait { app.screens.compactScreen(for: bID) != nil } } catch { Issue.record(error) }
            }
            resume.continuation.yield(())
            try await compact?.value
            try await opening.value
            #expect((app.screens.compactWindow(for: bID) == nil) == (mode == "close"))
        } else {
            let sheet = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.beginSheet(sheet, completionHandler: { _ in })
            await #expect(throws: RemoteDeviceWindowError.self) {
                try await main.presentConnectedScreen(bID, purpose: .requested)
            }
            #expect(app.screens.compactScreen(for: bID) != nil && aController.isEmbedded)
            window.endSheet(sheet)
        }
        try await app.screens.stopAll()
    }

    @Test(arguments: ["Open in New Window", "Open in New Tab"])
    func compactWindowCommandsKeepBothPresentationsInteractive(command: String) async throws {
        _ = NSApplication.shared
        let devices = try CoreDeviceInventoryDecoder.decode(
            Data(
                #"{"result":{"devices":[{"identifier":"A","properties":{"hardware":{"fidelity":"physical"},"state":{"name":"A"},"connection":{"state":"connected"}},"capabilities":[{"featureIdentifier":"com.apple.coredevice.feature.viewdevicescreen"}]}]}}"#
                    .utf8))
        let device = try #require(devices.first)
        let identifier = DeviceInventoryID.coreDevice(device.identifier)
        let model = SimulatorManagerModel(source: ManagerModelSource(devices: devices.map(InventoryDevice.remote)))
        model.registry.stopReading()
        await model.refresh()
        let app = AppDelegate(makeLicenses: SettingsPreview.licenses)
        app.model = model
        let main = app.prepareMainWindow()
        let window = try #require(main.window)
        window.setFrameAutosaveName("")
        defer { window.close() }
        window.orderFront(nil)
        let mainTransport = TestRemoteScreenTransport(), compactTransport = TestRemoteScreenTransport()
        var connections = 0
        let session = RemoteDeviceScreenSession(device: device) { _, _, _ in
            connections += 1
            return connections == 1 ? mainTransport : compactTransport
        }
        try await session.start()
        var presentations = 0
        let controller = RemoteDeviceWindowController(
            device: device, session: session,
            presentCompactWindow: {
                presentations += 1
                $0.orderFront(nil)
            })
        let screen = app.screens.attach(controller)
        main.selectDevice(identifier)
        try await main.presentConnectedScreen(identifier, purpose: .requested)
        let content = try #require(window.contentView)
        let outline = try #require(inspectorViews(content).compactMap { $0 as? NSOutlineView }.first)
        let menu = NSMenu()
        main.deviceActions.populate(menu, devices: [.remote(device)], window: window)
        let open = try #require(menu.items.first { $0.title == command })
        #expect(NSApp.sendAction(try #require(open.action), to: open.target, from: open))
        let preparedWindow = try #require(app.screens.compactWindow(for: identifier))
        let preparedFrame = preparedWindow.frame
        #expect(preparedWindow.isVisible)
        try await wait {
            (app.screens.compactScreen(for: identifier)?.commandTarget as? RemoteDeviceWindowController)?.session.state
                == .connected
        }
        await main.deviceScreenViewController.waitForScreenMoves()
        let compact = try #require(app.screens.compactScreen(for: identifier))
        let additional = try #require(compact.commandTarget as? RemoteDeviceWindowController)
        #expect(additional.window === preparedWindow)
        #expect(additional.window?.isVisible == true)
        #expect(preparedWindow.frame == preparedFrame)
        preparedWindow.contentView?.layoutSubtreeIfNeeded()
        let viewport = additional.session.contentView
        let displayed = viewport.convert(viewport.bounds, to: nil)
        #expect(
            displayed.maxY <= preparedWindow.contentLayoutRect.maxY + 0.5,
            "The physical screen must fit below the compact window's toolbar.")
        if command == "Open in New Tab" {
            #expect(window.tabbedWindows?.contains(where: { $0 === preparedWindow }) == true)
        } else {
            #expect(window.isVisible)
        }
        #expect(main.deviceScreenViewController.liveScreen === screen && controller.isEmbedded)
        #expect(additional.session !== session && additional.session.contentView !== session.contentView)
        screen.perform("home")
        compact.perform("home")
        try await wait { mainTransport.buttons == [.down, .up] && compactTransport.buttons == [.down, .up] }
        #expect(NSApp.sendAction(try #require(outline.doubleAction), to: outline.target, from: outline))
        try await wait { presentations == 2 }
        #expect(connections == 2 && app.screens.compactScreen(for: identifier) === compact)
        let reusedMenu = NSMenu()
        main.deviceActions.populate(reusedMenu, devices: [.remote(device)], window: preparedWindow)
        let placement = command == "Open in New Tab" ? "Open in New Window" : "Open in New Tab"
        let reused = try #require(reusedMenu.items.first { $0.title == placement })
        #expect(NSApp.sendAction(try #require(reused.action), to: reused.target, from: reused))
        if placement == "Open in New Window" {
            #expect((preparedWindow.tabbedWindows?.count ?? 0) <= 1)
        } else {
            #expect(window.tabbedWindows?.contains(where: { $0 === preparedWindow }) == true)
        }
        #expect(
            app.screens.compactWindow(for: identifier) === preparedWindow && main.selectedIdentifiers == [identifier])
        additional.performScreenAction("compact")
        try await wait { app.screens.compactScreen(for: identifier) == nil }
        #expect(app.screens.compactScreen(for: identifier) == nil && app.screens.screen(for: identifier) === screen)
        #expect(session.state == .connected && controller.isEmbedded)
        screen.perform("home")
        try await wait { mainTransport.buttons.count == 4 }
        try await app.screens.stopAll()
    }

    @Test func browserRestoresPanesAndSelectionWhenInventoryArrives() async throws {
        let domain = "NeoSimulator.BrowserRestoration.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer {
            defaults.removePersistentDomain(forName: domain)
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key.contains(domain) {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        func savedLayout() -> NSDictionary {
            NSDictionary(dictionary: UserDefaults.standard.dictionaryRepresentation().filter { $0.key.contains(domain) })
        }
        let devices = [simulator(state: "Shutdown"), simulator(deviceSet: "/tmp/OtherDeviceSet", state: "Shutdown")]
        let source = ManagerModelSource(devices: devices)
        let model = SimulatorManagerModel(source: source)
        model.registry.stopReading()
        await model.refresh()
        func browser() -> ManagerWindowController {
            let controller = ManagerWindowController(model: model, screens: DeviceScreens(model: model),
                menus: MenuController(application: nil), defaults: defaults, splitViewAutosaveName: domain)
            controller.window?.setFrameAutosaveName("")
            controller.showWindow(nil)
            controller.window?.contentView?.layoutSubtreeIfNeeded()
            return controller
        }
        func split(_ controller: ManagerWindowController) throws -> NSSplitViewController {
            try #require(controller.window?.contentViewController as? NSSplitViewController)
        }
        func tabs(_ controller: ManagerWindowController) throws -> NSSegmentedControl {
            try #require(controller.window?.toolbar?.items.first { $0.itemIdentifier.rawValue == "DeviceInspector" }?.view as? NSSegmentedControl)
        }
        let first = browser()
        defer { first.window?.close() }
        let firstSplit = try split(first)
        let outline = try #require(inspectorViews(firstSplit.splitViewItems[0].viewController.view)
            .compactMap { $0 as? NSOutlineView }.first)
        let rows = (0..<outline.numberOfRows).filter {
            outline.item(atRow: $0).map { first.sidebar.outlineView(outline, shouldSelectItem: $0) } == true
        }
        outline.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
        #expect(first.selectedIdentifiers == Set(devices.map(\.id)))
        let initialLayout = savedLayout()
        let firstTabs = try tabs(first)
        firstTabs.selectedSegment = 3
        NSApp.sendAction(firstTabs.action!, to: firstTabs.target, from: firstTabs)
        firstSplit.splitViewItems[0].isCollapsed = true
        firstSplit.view.layoutSubtreeIfNeeded()
        try await wait { !savedLayout().isEqual(initialLayout) }
        let inspectorWidth = firstSplit.splitViewItems[2].viewController.view.frame.width
        first.window?.close()
        firstSplit.splitView.autosaveName = nil

        await source.setDevices([])
        await model.refresh()
        let second = browser()
        defer { second.window?.close() }
        let secondSplit = try split(second)
        #expect(secondSplit.splitViewItems[0].isCollapsed)
        #expect(!secondSplit.splitViewItems[2].isCollapsed)
        #expect(abs(secondSplit.splitViewItems[2].viewController.view.frame.width - inspectorWidth) < 1)
        #expect(try tabs(second).selectedSegment == 3)
        #expect(second.selectedIdentifiers.isEmpty)
        await source.setDevices(devices)
        await model.refresh()
        second.sidebar.update()
        #expect(second.selectedIdentifiers == Set(devices.map(\.id)))
        let restoredOutline = try #require(inspectorViews(secondSplit.splitViewItems[0].viewController.view)
            .compactMap { $0 as? NSOutlineView }.first)
        #expect(restoredOutline.selectedRowIndexes.count == 2)
        let previousLayout = savedLayout()
        secondSplit.splitViewItems[2].isCollapsed = true
        secondSplit.view.layoutSubtreeIfNeeded()
        try await wait { !savedLayout().isEqual(previousLayout) }
        second.window?.close()
        secondSplit.splitView.autosaveName = nil
        let third = browser()
        defer { third.window?.close() }
        #expect(try split(third).splitViewItems[2].isCollapsed)
        let thirdTabs = try tabs(third)
        thirdTabs.selectedSegment = 3
        NSApp.sendAction(thirdTabs.action!, to: thirdTabs.target, from: thirdTabs)
        #expect(try !split(third).splitViewItems[2].isCollapsed)
    }

    @Test func aScreenThatConnectsAfterAnInventoryReadUpdatesTheSameModelFromItsOwnRecord() async throws {
        let stopped = simulator(state: "Shutdown")
        let catalog = DeviceInventoryIssue.Source.simulators(xcodeURL: URL(fileURLWithPath: "/Catalog Xcode.app"), deviceSetPath: nil)
        let source = ManagerModelSource(devices: [])
        var events = source.events.makeAsyncIterator()
        let registry = DeviceRegistry(source: source)
        registry.apply(DeviceInventorySnapshot(devices: [stopped], issues: [], sources: [stopped.id: [catalog]]))
        let model = try #require(registry.device(for: stopped.id))
        let interest = model.keepCurrent()
        defer { interest.release() }
        model.revalidate()
        await registry.finishReading()
        #expect(await source.readCount == 0)

        // Asking to open it says nothing. Only a record that says it runs does.
        #expect(connectScreen(registry, booted: false) === model)
        #expect(!model.canInspectSettings && !model.canInspectBackgroundServices)
        await registry.finishReading()
        #expect(await source.readCount == 0)

        #expect(connectScreen(registry, booted: true, name: "A Screen's Name") === model)
        try #require(model.canInspectSettings && model.canInspectBackgroundServices)
        // What else the inventory said of the device, and who said it, stays the inventory's.
        #expect(registry.devices.map(\.id) == [stopped.id] && model.sources == [catalog] && model.name == "Test Phone")
        guard case .simulator(let known) = model.inventory else { throw ManagerModelSource.Failure.unavailable }
        #expect(known.ownerXcodeURL == nil)
        #expect(await events.next() == .read(stopped.id))
        await source.completeRead(settings(appearance: .dark))
        await registry.finishReading()
        #expect(model.settings.appearance == .dark && model.backgroundServices.status == .current)

        // A later read that agrees is no new generation.
        await source.setDevices([simulator()])
        try await registry.refresh()
        await registry.finishReading()
        #expect(await source.readCount == 1)
        // One that says the device stopped is the authority on it.
        await source.setDevices([stopped])
        try await registry.refresh()
        #expect(!model.canInspectSettings)
    }

    @Test func anInventoryReadFromBeforeAScreenConnectedCannotStopItsDevice() async throws {
        let stopped = simulator(state: "Shutdown")
        let source = ManagerModelSource(devices: [stopped])
        var events = source.events.makeAsyncIterator()
        let registry = DeviceRegistry(source: source)
        try await registry.refresh()
        let model = try #require(registry.device(for: stopped.id))
        let interest = model.keepCurrent(.settings)
        defer { interest.release() }

        await source.holdInventoryReads()
        let reading = Task { try await registry.refresh() }
        #expect(await events.next() == .inventory)
        _ = connectScreen(registry, booted: true)
        #expect(await events.next() == .read(stopped.id))
        await source.completeInventoryRead()
        try await reading.value
        // It began while the device was stopped, so it does not end the generation that the screen found.
        try #require(model.canInspectSettings)
        await source.completeRead(settings(appearance: .dark))
        await registry.finishReading()
        #expect(model.settings.appearance == .dark)
        #expect(await source.readCount == 1)

        // A read that began after the screen connected can say that the device has stopped.
        try await registry.refresh()
        #expect(!model.canInspectSettings)
    }

    @Test func aScreenInAProcessWithNoInventoryKeepsItsModelWhenAReadFirstListsIt() async throws {
        let source = ManagerModelSource(devices: [simulator()])
        var events = source.events.makeAsyncIterator()
        let registry = DeviceRegistry(source: source)
        let model = connectScreen(registry, booted: true)
        #expect(registry.devices.isEmpty && model.canInspectSettings && model.sources.isEmpty)
        let interest = model.keepCurrent(.settings)
        defer { interest.release() }
        let presentation = model.beginPresentation {}
        defer { model.endPresentation(presentation) }
        #expect(await events.next() == .read(model.id))
        await source.completeRead(settings(appearance: .dark))
        await registry.finishReading()

        try await registry.refresh()
        #expect(registry.devices.first === model && !model.sources.isEmpty)
        await registry.finishReading()
        #expect(model.settings.appearance == .dark)
        #expect(await source.readCount == 1)
    }

    @Test func aScreenThatReconnectsToALaterBootStartsANewGeneration() async throws {
        let source = ManagerModelSource(devices: [simulator()])
        var events = source.events.makeAsyncIterator()
        let (registry, model, interest) = try await settingsFixture(source)
        defer { interest.release() }
        #expect(await events.next() == .read(model.id))
        await source.completeRead(settings(appearance: .light))
        await registry.finishReading()

        // Reopening the boot it already knows asks the device nothing, and neither does a record with no date.
        let boot = Date(timeIntervalSince1970: 1)
        _ = connectScreen(registry, booted: true, lastBootDate: boot)
        _ = connectScreen(registry, booted: true, lastBootDate: boot)
        _ = connectScreen(registry, booted: true)
        await registry.finishReading()
        #expect(await source.readCount == 1)

        // The inventory saw it running both times, so only the date says that this is a different boot.
        model.revalidate(.settings)
        #expect(await events.next() == .read(model.id))
        #expect(connectScreen(registry, booted: true, lastBootDate: Date(timeIntervalSince1970: 2)) === model)
        #expect(await events.next() == .read(model.id))
        await source.completeRead(settings(appearance: .light))
        #expect(model.settings.appearance == .light)
        await source.completeRead(settings(appearance: .dark))
        await registry.finishReading()
        #expect(model.settings.appearance == .dark)
        #expect(await source.readCount == 3)
    }

    @Test func selectingMinimalAndReselectingTheDefaultApplyExactConfigurations() async throws {
        let domain = "NeoSimulator.ApplyMinimalServiceProfile.\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: serviceProfileURL(domain).deletingLastPathComponent()) }
        let store = ServiceProfileStore(fileURL: serviceProfileURL(domain), legacyDefaults: nil)
        let category = try store.createCategory(named: "Agents")
        let custom = try store.addService("com.example.agent", to: category)
        let required = "com.apple.gamed"
        let device = simulator()
        let source = ManagerModelSource(devices: [device])
        await source.skipSettingsReads()
        await source.holdServiceReads()
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source, serviceProfiles: store)
        await manager.refresh()
        manager.inspect(device, selectionCount: 1)

        manager.selectServiceProfile(.profile(store.minimal.id), for: device.id)
        #expect(await events.next() == .readServices(device.id))
        await source.completeServiceRead(disabled: [custom, required])
        #expect(await events.next() == .changeServices(device.id))
        await source.completeServiceChange(disabled: [])
        #expect(await events.next() == .changeServices(device.id))
        let disabled = store.minimal.configuration.disabledLabels
        await source.completeServiceChange(disabled: disabled)
        try await awaitServiceOperations(manager)
        let changes = await source.serviceChanges
        #expect(changes.first == .init(targets: [required, custom].map { .service($0) }, enabled: true))
        let stopping = try #require(changes.last)
        #expect(!stopping.enabled && stopping.targets.contains(.service("com.apple.navd")))
        #expect(!stopping.targets.contains(.service("com.apple.assistantd")))

        try store.setDefaultProfile(store.minimal.id)
        for choice in [ServiceProfileSelection.inheritDefault, .inheritDefault] {
            try store.record([.service("com.apple.searchd")], enabled: true, for: device.id, productFamily: "iPhone")
            manager.selectServiceProfile(choice, for: device.id)
            #expect(await events.next() == .readServices(device.id))
            await source.completeServiceRead(disabled: disabled.subtracting(["com.apple.searchd"]))
            #expect(await events.next() == .changeServices(device.id))
            await source.completeServiceChange(disabled: disabled)
            try await awaitServiceOperations(manager)
            #expect(store.binding(for: device.id) == DeviceServiceProfile(selection: .inheritDefault))
            #expect(await source.serviceChanges.last == .init(targets: [.service("com.apple.searchd")], enabled: false))
        }
        let inspector = BackgroundServicesInspectorModel(manager: manager, showProfileSettings: { _ in })
        manager.setBackgroundServices([.service("com.apple.searchd")], enabled: true, for: device.id)
        #expect(await events.next() == .changeServices(device.id))
        await source.completeServiceChange(disabled: disabled.subtracting(["com.apple.searchd"]))
        try await awaitServiceOperations(manager)
        inspector.saveProfile()
        let editor = try #require(inspector.profileEditor)
        editor.name = "My Minimal"
        #expect(editor.commit())
        let saved = try #require(store.profiles.first)
        #expect(saved.configuration.disabledLabels == disabled.subtracting(["com.apple.searchd"]))
        #expect(store.minimal.configuration.disabledLabels == disabled)
        try await manager.prepareForQuit()
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
                "identifier": identifier, "properties": ["hardware": ["fidelity": "virtual"],
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
        first.1.resume(throwing: HostOperationError.io("cleanup-fixture", "Recording could not be saved"))
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
}
