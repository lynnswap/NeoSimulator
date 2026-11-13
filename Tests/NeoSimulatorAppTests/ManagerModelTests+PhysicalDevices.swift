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
    @Test(arguments: [false, true])
    func anUnpairedDeviceCanPairFromItsPreviewAndMenuAfterAnInterruptedAttempt(cancelled: Bool) async throws {
        _ = NSApplication.shared
        let device = try Self.pairingDevice(paired: false)
        let paired = try Self.pairingDevice(paired: true)
        let inProgress = try Self.pairingDevice(paired: false, pairingState: "pairingInProgress")
        let source = ManagerModelSource(devices: [inProgress])
        let manager = SimulatorManagerModel(source: source)
        manager.registry.stopReading()
        await manager.refresh()
        #expect(!manager.canPairWithHost(inProgress))
        await source.setDevices([device])
        await manager.refresh()
        let original = manager.registry.device(for: device.id)
        let screens = DeviceScreens(model: manager)
        let controller = ManagerWindowController(
            model: manager, screens: screens, menus: MenuController(application: nil))
        controller.window?.setFrameAutosaveName("")
        defer { controller.window?.close() }
        controller.sidebar.model.kindFilter = .physical
        #expect(controller.sidebar.model.filteredDevices.map(\.id) == [device.id])
        controller.selectDevice(device.id)
        let content = try #require(controller.window?.contentView)
        let button = try #require(inspectorViews(content).compactMap { $0 as? NSButton }.first { $0.title == "Pair" })
        #expect(button.isEnabled && !manager.canViewScreen(device))
        let resume = AsyncStream<Void>.makeStream()
        var attempts = 0
        var failures = 0
        manager.onError = { _ in failures += 1 }
        controller.deviceActions.pairRemoteDevice = { _, _ in
            attempts += 1
            var replies = resume.stream.makeAsyncIterator()
            _ = await replies.next()
            if attempts == 1 {
                if cancelled { throw CancellationError() }
                throw SimulatorError.operation("Pairing failed")
            }
            await source.setDevices([paired])
        }
        // The compact preview was created from an older paired snapshot.
        let compact = try #require(screens.makeCompactPreview?(paired))
        let compactPair = try #require(
            inspectorViews(compact.view).compactMap { $0 as? NSButton }.first { $0.title == "Pair" })
        compactPair.performClick(nil)
        try await wait { attempts == 1 }
        #expect(!manager.canPairWithHost(device) && manager.managingDeviceIDs.contains(device.id))
        resume.continuation.yield(())
        try await wait { manager.canPairWithHost(device) }
        #expect(button.title == "Pair")
        #expect(failures == (cancelled ? 0 : 1))
        let menu = NSMenu()
        controller.deviceActions.populate(menu, devices: [device], includesViewScreen: false)
        let pair = try #require(menu.items.first { $0.title == "Pair" })
        let navigationIndex = try #require(menu.items.firstIndex { $0.title == "Open in New Window" })
        let pairingIndex = try #require(menu.items.firstIndex { $0 === pair })
        #expect(pairingIndex > navigationIndex)
        #expect(NSApp.sendAction(try #require(pair.action), to: pair.target, from: pair))
        try await wait { attempts == 2 }
        resume.continuation.yield(())
        try await wait {
            manager.inventory.first?.id == device.id && manager.canViewScreen(manager.inventory[0])
                && button.title == "View Screen"
        }
        #expect(manager.registry.device(for: device.id) === original)
        #expect(attempts == 2)
        try await manager.quitRenderer(keepingDevicesRunning: true)
    }

    @Test(arguments: [false, true], [false, true])
    func aPairingSheetCancelsWhenItsWindowClosesOrTheAppQuits(quitting: Bool, waitingForPIN: Bool) async throws {
        _ = NSApplication.shared
        let device = try Self.pairingDevice(paired: false)
        guard case .remote(let remote) = device else { Issue.record("Expected the remote pairing fixture"); return }
        let manager = SimulatorManagerModel(source: ManagerModelSource(devices: [device]))
        manager.registry.stopReading()
        manager.terminationLimit = .seconds(1)
        await manager.refresh()
        var failures: [any Error] = []
        manager.onError = { failures.append($0) }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        var nativeReply: CheckedContinuation<Void, Never>?
        var nativeFinished = false
        manager.pairWithHost(device) {
            try await DevicePairingSheet.pair(
                remote, in: window,
                using: { _, prompt in
                    defer { nativeFinished = true }
                    if !waitingForPIN { await withCheckedContinuation { nativeReply = $0 } }
                    _ = try await prompt(false, nil)
                })
        }
        try await wait {
            if !waitingForPIN { return window.attachedSheet != nil && nativeReply != nil }
            guard let content = window.attachedSheet?.contentView else { return false }
            return inspectorViews(content).compactMap { $0 as? NSTextField }
                .contains { $0.placeholderString == "Pairing Code" && !$0.isHidden && $0.isEnabled }
        }
        let panel = try #require(window.attachedSheet)
        let content = try #require(panel.contentView)
        let cancel = try #require(
            inspectorViews(content).compactMap { $0 as? NSButton }
                .first { $0.title == "Cancel" })
        defer {
            if cancel.target != nil { cancel.performClick(nil) }
            nativeReply?.resume()
            window.close()
        }
        if quitting { try await manager.quitRenderer(keepingDevicesRunning: true) } else { window.close() }
        try await wait { window.attachedSheet == nil }
        #expect(failures.isEmpty)
        if !waitingForPIN {
            #expect(!nativeFinished && manager.managingDeviceIDs.contains(device.id))
            #expect(!manager.canPairWithHost(device))
            nativeReply?.resume()
            nativeReply = nil
            try await wait { nativeFinished }
            #expect(window.attachedSheet == nil)
        }
        try await wait { !manager.managingDeviceIDs.contains(device.id) }
        if !quitting {
            #expect(manager.canPairWithHost(device))
            try await manager.quitRenderer(keepingDevicesRunning: true)
        }
    }

    @Test func aPhysicalScreenMenuStopsSharingAndThenOffersViewScreen() async throws {
        _ = NSApplication.shared
        let data = try JSONSerialization.data(withJSONObject: [
            "result": [
                "devices": [
                    [
                        "identifier": "remote",
                        "properties": [
                            "hardware": ["fidelity": "physical"], "state": ["name": "Remote"],
                            "connection": ["state": "connected"],
                        ],
                    ]
                ]
            ]
        ])
        let device = InventoryDevice.remote(try #require(CoreDeviceInventoryDecoder.decode(data).first))
        let manager = SimulatorManagerModel(source: ManagerModelSource(devices: [device]))
        manager.registry.stopReading()
        await manager.refresh()
        manager.setOpenDeviceScreens([device.id])
        let stopped = AsyncStream<String>.makeStream()
        manager.onStopRemoteDevice = {
            manager.setOpenDeviceScreens([])
            stopped.continuation.yield($0.identifier)
        }
        var stops = stopped.stream.makeAsyncIterator()
        let actions = DeviceActions(model: manager, window: nil, liveScreen: { nil })
        let menu = NSMenu()
        actions.populate(menu, devices: [device], includesViewScreen: false)
        let stop = try #require(menu.items.first { $0.title == "Stop Screen Sharing" })
        #expect(NSApp.sendAction(try #require(stop.action), to: stop.target, from: stop))
        #expect(await stops.next() == "remote")
        try await wait { manager.canViewScreen(device) }
        actions.populate(menu, devices: [device])
        #expect(menu.items.contains { $0.title == "View Screen" })
        #expect(!menu.items.contains { $0.title == "Stop Screen Sharing" })
        try await manager.quitRenderer(keepingDevicesRunning: true)
    }

    @Test func aPairedPhysicalScreenCanPrepareDeveloperServicesBeforeAdvertisingScreenSupport() async throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "result": [
                "devices": [
                    [
                        "identifier": "remote",
                        "properties": [
                            "hardware": ["fidelity": "physical"], "state": ["name": "Remote"],
                            "connection": ["state": "disconnected"],
                        ],
                    ]
                ]
            ]
        ])
        let device = InventoryDevice.remote(try #require(CoreDeviceInventoryDecoder.decode(data).first))
        let manager = SimulatorManagerModel(source: ManagerModelSource(devices: [device]))
        manager.registry.stopReading()
        await manager.refresh()
        #expect(manager.canViewScreen(device))
        let opens = AsyncStream<String>.makeStream()
        manager.onOpenRemoteDevice = { opens.continuation.yield($0.identifier) }
        var opened = opens.stream.makeAsyncIterator()
        manager.openScreen(for: device)
        #expect(await opened.next() == "remote")
        try await manager.quitRenderer(keepingDevicesRunning: true)
    }

    @Test func deviceHubHandoffCancelsInspectorReadsBeforeClosingTheRenderer() async throws {
        let device = simulator()
        let source = ManagerModelSource(devices: [device])
        await source.holdServiceReads()
        await source.observeServiceReadCancellation()
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source)
        await manager.refresh()
        let model = try #require(manager.registry.device(for: device.id))
        let interest = model.keepCurrent(.backgroundServices)
        #expect(await events.next() == .readServices(device.id))
        await source.holdServiceReads(false)
        let xcode = URL(filePath: "/Applications/Test Xcode.app")
        manager.openDeviceHub(xcodeURL: xcode)
        let next = await events.next()
        #expect(next == .cancelledServiceRead(device.id))
        interest.release()
        await source.completeServiceRead(disabled: [])
        if next != .deviceHub { #expect(await events.next() == .deviceHub) }
        try await wait { !manager.isBusy }
        manager.deviceHubDidExit(xcodeURL: xcode)
        try await wait { !manager.isBusy }
        #expect(await source.sessionEvents.contains("resume"))
        try await manager.prepareForQuit()
    }

    @Test func cancellingQuitResumesADeviceHubExitReceivedWhileStopping() async throws {
        let source = ManagerModelSource(devices: [])
        let manager = SimulatorManagerModel(source: source)
        try await manager.prepareForQuit()
        manager.deviceHubDidExit(xcodeURL: URL(filePath: "/Applications/Test Xcode.app"))
        #expect(await !source.sessionEvents.contains("resume"))
        manager.resumeAfterCancelledQuit()
        try await wait { !manager.isBusy }
        #expect(await source.sessionEvents.filter { $0 == "resume" }.count == 1)
        try await manager.prepareForQuit()
    }

    @Test func deviceFamilyFilterClassifiesDuoByItsMetadata() async throws {
        _ = NSApplication.shared
        let domain = "NeoSimulator.DuoFilter.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let duo = "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo"
        let source = ManagerModelSource(devices: [
            .simulator(SimulatorHostDevice(identifier: "phone", name: "iPhone Duo Clone", descriptiveName: "Phone",
                runtimeIdentifier: "ios", runtimeName: "iOS 27.2", productFamily: "iPhone", state: "Shutdown",
                deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17")),
            .simulator(SimulatorHostDevice(identifier: "renamed", name: "Review Device", descriptiveName: "Renamed",
                runtimeIdentifier: "duo-ios", runtimeName: "iOS 27.2", productFamily: "iPhone", state: "Shutdown",
                deviceTypeIdentifier: duo)),
            // A catalog that lacks the device type leaves the family empty.
            .simulator(SimulatorHostDevice(identifier: "unavailable", name: "Unavailable Device", descriptiveName: "Unavailable",
                runtimeIdentifier: "duo-ios", runtimeName: "iOS 27.2", productFamily: "", state: "Shutdown",
                deviceTypeIdentifier: duo, isAvailable: false)),
            .remote(CoreDeviceDevice(identifier: "physical", udid: nil, kind: .physical, name: "Desk Phone", reportedName: "Desk Phone",
                modelIdentifier: "iPhone19,4", modelName: "iPhone Duo", cpuType: nil, platform: "iOS", osVersion: nil, osBuild: nil,
                osBuildUpdate: nil, connectionState: "connected", pairingState: "paired", transportType: nil, bootState: "booted",
                preparednessState: nil, capabilities: [], lastConnectedAt: nil, visibilityClass: nil)),
        ])
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
        func deviceNames() -> Set<String> {
            Set((0..<outline.numberOfRows).compactMap { row in
                guard let item = outline.item(atRow: row), controller.sidebar.outlineView(outline, shouldSelectItem: item) else { return nil }
                return controller.sidebar.outlineView(outline, typeSelectStringFor: nil, item: item)
            })
        }
        try choose("Show Groups")
        try choose("iPhone Duo")
        #expect(deviceNames() == ["Review Device", "Unavailable Device", "Desk Phone"])
        try choose("iPhone")
        #expect(deviceNames() == ["iPhone Duo Clone"])
    }

    @Test func sidebarAvailabilityUsesRetainedCoreDeviceClassification() throws {
        let data = Data(#"""
        {"result":{"devices":[
          {"identifier":"connecting","properties":{"hardware":{"fidelity":"physical"},
            "state":{"name":"Connecting"},"connection":{"state":"connecting"}}},
          {"identifier":"boot","properties":{"hardware":{"fidelity":"virtual"},
            "connection":{"state":"unavailable"}},
            "capabilities":[{"featureIdentifier":"com.apple.dt.coredevice.device.boot"}]},
          {"identifier":"resume","properties":{"hardware":{"fidelity":"virtual"},
            "connection":{"state":"unavailable"}},
            "capabilities":[{"featureIdentifier":"com.apple.dt.coredevice.virtualmachineplugin.resumeFromPause"}]},
          {"identifier":"provisioning","properties":{"hardware":{"fidelity":"physical"},
            "state":{"visibilityClass":"devicesBeingProvisioned"},"connection":{"state":"unavailable"}}},
          {"identifier":"unavailable","properties":{"hardware":{"fidelity":"physical"},
            "connection":{"state":"unavailable"}}},
          {"identifier":"future","properties":{"hardware":{"fidelity":"physical"},
            "connection":{"state":"future-state"}}},
          {"identifier":"missing","properties":{"hardware":{"fidelity":"physical"}}}
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

    @Test(arguments: ["Booted", "Shutdown", "paired", "unpaired"])
    func deviceMenusOfferNavigationForSimulatorAndPairingStates(state: String) async throws {
        _ = NSApplication.shared
        let device =
            ["Booted", "Shutdown"].contains(state)
            ? simulator(state: state)
            : inspectedRemote(
                pairingState: state,
                features: state == "paired" ? ["renamedevice", "rebootdevice", "unpairdevice"] : [])
        let source = ManagerModelSource(devices: [device])
        let manager = SimulatorManagerModel(source: source)
        manager.registry.stopReading()
        await manager.refresh()
        let actions = DeviceActions(model: manager, window: nil, liveScreen: { nil })
        actions.openDeviceWindow = { _, _, _ in }
        let menu = NSMenu()
        actions.populate(menu, devices: [device], includesViewScreen: false)
        let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
        #expect(titles.contains("Open in New Tab") && titles.contains("Open in New Window"))
        #expect(titles.contains("Show in Finder") == (state != "unpaired"))
        if state == "Booted" || state == "Shutdown" {
            #expect(titles.contains("Start") == (state == "Shutdown"))
            #expect(titles.contains("Shut Down") == (state == "Booted"))
            #expect(titles.contains("Reset Content and Settings…") && titles.contains("Remove…"))
        }
        if state == "paired" {
            #expect(titles.contains("Unpair…") && titles.contains("Restart"))
            var shown: DeviceInventoryID?
            var failure: String?
            actions.showDeviceInFinder = {
                shown = $0.id; throw SimulatorError.operation("Finder failed")
            }
            manager.onError = { failure = $0.localizedDescription }
            let finder = try #require(menu.items.first { $0.title == "Show in Finder" })
            #expect(NSApp.sendAction(try #require(finder.action), to: finder.target, from: finder))
            try await wait { failure != nil }
            #expect(shown == device.id && failure?.contains("Finder failed") == true)
            let watch = InventoryDevice.simulator(
                SimulatorHostDevice(
                    identifier: "watch", name: "Watch", descriptiveName: "Watch",
                    runtimeIdentifier: "watch-runtime", runtimeName: "watchOS", productFamily: "Apple Watch",
                    state: "Booted", pairIdentifiers: ["pair"]))
            await source.setDevices([device, watch])
            await manager.refresh()
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.orderFront(nil)
            actions.populate(menu, devices: [device, watch], window: window)
            let unpair = try #require(menu.items.first { $0.title == "Unpair…" })
            #expect(NSApp.sendAction(try #require(unpair.action), to: unpair.target, from: unpair))
            let sheet = try #require(window.attachedSheet)
            #expect(manager.managingDeviceIDs.isEmpty)
            let content = try #require(sheet.contentView)
            let cancel = try #require(
                inspectorViews(content).compactMap { $0 as? NSButton }.first { $0.title == "Cancel" })
            cancel.performClick(nil)
            try await wait { window.attachedSheet == nil }
        }
        try await manager.quitRenderer(keepingDevicesRunning: true)
    }

    @Test func screenSourceCommandReachesTheRemoteScreenInEitherWindow() async throws {
        _ = NSApplication.shared
        let devices = try CoreDeviceInventoryDecoder.decode(Data(#"{"result":{"devices":[{"identifier":"A","properties":{"hardware":{"fidelity":"physical"},"state":{"name":"A"}}}]}}"#.utf8))
        let a = try #require(devices.first)
        let aID = DeviceInventoryID.coreDevice(a.identifier)
        let model = SimulatorManagerModel(source: ManagerModelSource(devices: devices.map(InventoryDevice.remote)))
        model.registry.stopReading()
        await model.refresh()
        let app = AppDelegate(makeLicenses: SettingsPreview.licenses)
        app.model = model
        app.prepareMainWindow()
        let main = try #require(app.mainWindow)
        main.window?.setFrameAutosaveName("")
        defer { main.window?.close() }
        let pane = main.deviceScreenViewController
        let suite = "NeoSimulatorTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = ScreenCaptureSourceCatalog(defaults: defaults)
        let connecting = AsyncStream<Void>.makeStream(), resume = AsyncStream<Void>.makeStream()
        var connections = connecting.stream.makeAsyncIterator()
        var attempts = 0
        defer { resume.continuation.finish() }
        let session = RemoteDeviceScreenSession(device: a, captureSources: catalog) { _, _, _ in
            attempts += 1
            if attempts == 2 {
                connecting.continuation.yield(())
                var permits = resume.stream.makeAsyncIterator()
                _ = await permits.next()
            }
            return TestRemoteScreenTransport()
        }
        try await session.start()
        let controller = RemoteDeviceWindowController(device: a, session: session, presentCompactWindow: { _ in })
        app.screens.attach(controller)
        main.selectDevice(aID)
        try await main.presentConnectedScreen(aID, purpose: .requested)
        // The screen and its frame can cover the canvas and its context menu, so the menu bar offers the command.
        let command = NSMenuItem(title: "Choose Screen Source…", action: NSSelectorFromString("chooseCaptureSource:"), keyEquivalent: "")
        let action = try #require(command.action)
        #expect(main.supplementalTarget(forAction: action, sender: command) as AnyObject? === controller)
        // A screen shown without a Mac capture source, as a virtual machine's is, has no source to choose.
        #expect(!controller.validateMenuItem(command))
        catalog.choose(RemoteScreenCaptureSource(name: "A", uniqueID: "a-capture-identity"), for: a.identifier)
        #expect(controller.validateMenuItem(command))
        let compact = try #require(main.window?.toolbar?.items.first { $0.itemIdentifier.rawValue == "CompactDeviceWindow" })
        #expect(NSApp.sendAction(try #require(compact.action), to: compact.target, from: compact))
        try await wait(timeout: .seconds(5)) { app.screens.compactScreen(for: aID) != nil }
        let additional = try #require(
            app.screens.compactScreen(for: aID)?.commandTarget as? RemoteDeviceWindowController)
        #expect(await connections.next() != nil)
        #expect(pane.liveDeviceIdentifier == aID && controller.isEmbedded)
        #expect(
            additional.presentationViewController.supplementalTarget(forAction: action, sender: command) as AnyObject?
                === additional)
        #expect(!additional.validateMenuItem(command))
        resume.continuation.yield(())
        try await wait(timeout: .seconds(5)) { additional.session.state == .connected }
        #expect(additional.validateMenuItem(command))
        try await app.screens.stopAll()
    }

    @Test(arguments: [false, true])
    func queuedRemoteOpenPreservesNewerSelectionOrCompact(_ selectsAnotherDevice: Bool) async throws {
        _ = NSApplication.shared
        let devices = try CoreDeviceInventoryDecoder.decode(Data(#"{"result":{"devices":[{"identifier":"A","properties":{"hardware":{"fidelity":"physical"},"state":{"name":"A"}}},{"identifier":"B","properties":{"hardware":{"fidelity":"physical"},"state":{"name":"B"}}}]}}"#.utf8))
        let a = try #require(devices.first), b = try #require(devices.last)
        let aID = DeviceInventoryID.coreDevice(a.identifier), bID = DeviceInventoryID.coreDevice(b.identifier)
        let source = ManagerModelSource(devices: devices.map(InventoryDevice.remote))
        var events = source.events.makeAsyncIterator()
        let model = SimulatorManagerModel(source: source)
        model.registry.stopReading()
        await model.refresh()
        let app = AppDelegate(makeLicenses: SettingsPreview.licenses)
        app.model = model
        app.prepareMainWindow()
        let main = try #require(app.mainWindow)
        main.window?.setFrameAutosaveName("")
        let pane = main.deviceScreenViewController
        let aSession = RemoteDeviceScreenSession(device: a) { _, _, _ in TestRemoteScreenTransport() }
        let bSession = RemoteDeviceScreenSession(device: b) { _, _, _ in TestRemoteScreenTransport() }
        try await aSession.start()
        try await bSession.start()
        let aController = RemoteDeviceWindowController(device: a, session: aSession, presentCompactWindow: { _ in })
        let bController = RemoteDeviceWindowController(device: b, session: bSession, presentCompactWindow: { _ in })
        app.screens.attach(aController)
        app.screens.attach(bController)
        main.selectDevice(aID)
        try await main.presentConnectedScreen(aID, purpose: .requested)
        model.setDeviceSetting(.appearance(.dark), for: bID)
        #expect(await events.next() == .write(bID))
        #expect(!model.isBusy)
        model.openScreen(for: .remote(a))
        if selectsAnotherDevice {
            let content = try #require(main.window?.contentView)
            let outline = try #require(inspectorViews(content).compactMap { $0 as? NSOutlineView }.first)
            let bRow = try #require((0..<outline.numberOfRows).first { row in
                row != outline.selectedRow && outline.item(atRow: row).map { main.sidebar.outlineView(outline, shouldSelectItem: $0) } == true
            })
            outline.selectRowIndexes(IndexSet(integer: bRow), byExtendingSelection: false)
        } else {
            let compact = try #require(main.window?.toolbar?.items.first { $0.itemIdentifier.rawValue == "CompactDeviceWindow" })
            #expect(NSApp.sendAction(try #require(compact.action), to: compact.target, from: compact))
            try await wait(timeout: .seconds(5)) { app.screens.compactScreen(for: aID) != nil }
        }
        await source.completeWrite()
        try await wait(timeout: .seconds(5)) {
            !model.isBusy && bController.isEmbedded == selectsAnotherDevice
                && aController.isEmbedded != selectsAnotherDevice
        }
        #expect(main.selectedIdentifiers == [selectsAnotherDevice ? bID : aID])
        #expect(pane.liveDeviceIdentifier == (selectsAnotherDevice ? bID : aID))
        #expect(aSession.state == .connected)
        try await aSession.stop()
        try await bSession.stop()
        main.window?.close()
    }

    @Test func liveRemoteScreenChangesReachTheToolbarAndClosingReturnsThePaneToThePreview() async throws {
        _ = NSApplication.shared
        let devices = try CoreDeviceInventoryDecoder.decode(Data(#"{"result":{"devices":[{"identifier":"A","properties":{"hardware":{"fidelity":"physical"},"state":{"name":"A"}}}]}}"#.utf8))
        let a = try #require(devices.first)
        let aID = DeviceInventoryID.coreDevice(a.identifier)
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
        transport.inputCapabilities = [.keyboard]
        let session = RemoteDeviceScreenSession(device: a) { _, _, _ in transport }
        try await session.start()
        let controller = RemoteDeviceWindowController(device: a, session: session, presentCompactWindow: { _ in })
        let screen = app.screens.attach(controller)
        main.selectDevice(aID)
        try await main.presentConnectedScreen(aID, purpose: .requested)
        let capture = try #require(main.window?.toolbar?.items.first { $0.itemIdentifier.rawValue == "captureKeyboard" })
        #expect(pane.liveScreen === screen && !capture.isHidden && capture.isEnabled)
        let more = try #require(main.window?.toolbar?.items.first { $0.itemIdentifier.rawValue == "CanvasMoreActions" })
        let compact = try #require(main.window?.toolbar?.items.first { $0.itemIdentifier.rawValue == "CompactDeviceWindow" })
        let window = try #require(main.window)
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
                             styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        defer {
            if let parent = sheet.sheetParent { parent.endSheet(sheet) }
            sheet.close()
        }
        window.beginSheet(sheet, completionHandler: { _ in })
        try await wait(timeout: .seconds(5)) {
            !capture.isEnabled && !compact.isEnabled && !more.isEnabled
        }
        window.endSheet(sheet)
        try await wait(timeout: .seconds(5)) {
            capture.isEnabled && compact.isEnabled && more.isEnabled
        }
        let releasing = AsyncStream<Void>.makeStream(), resume = AsyncStream<Void>.makeStream()
        var releases = releasing.stream.makeAsyncIterator()
        transport.onReleaseInputs = {
            transport.onReleaseInputs = nil
            releasing.continuation.yield(())
            var permits = resume.stream.makeAsyncIterator()
            _ = await permits.next()
        }
        let closing = Task { try await controller.stopAndClose() }
        #expect(await releases.next() != nil)
        // The remote controller reports that it is closing only through its change callback.
        try await wait(timeout: .seconds(5)) {
            !capture.isEnabled
        }
        #expect(pane.liveScreen === screen)
        resume.continuation.yield(())
        try await closing.value
        try await wait(timeout: .seconds(5)) {
            pane.liveScreenContainer.view.isHidden && capture.isHidden
        }
        #expect(app.screens.screen(for: aID) == nil && pane.liveDeviceIdentifier == nil)
    }

    @Test func aFailedCoreDeviceReadKeepsWhatItAddedToASimulator() async throws {
        let record = try #require(try CoreDeviceInventoryDecoder.decode(Data(#"{"result":{"devices":[{"identifier":"SIM","properties":{"hardware":{"fidelity":"simulated","udid":"same-udid"},"state":{"name":"Test Phone"},"connection":{"state":"connected"}},"capabilities":[{"featureIdentifier":"com.apple.coredevice.feature.companiondevicepairing"}]}]}}"#.utf8)).first)
        guard case .simulator(let phone) = simulator() else { throw ManagerModelSource.Failure.unavailable }
        let owner = URL(fileURLWithPath: "/Owner.app")
        let known = InventoryDevice.simulator(phone.inventoryCopy(ownerXcodeURL: owner, coreDevice: record))
        let registry = DeviceRegistry(source: ManagerModelSource(devices: []))
        struct Unread: Error {}
        registry.apply(DeviceInventorySnapshot(devices: [known], issues: []))
        let model = try #require(registry.device(for: known.id))

        registry.apply(DeviceInventorySnapshot(devices: [.simulator(phone)], issues: [
            .init(source: .coreDevice, error: Unread()), .init(source: .rendererOwnership, error: Unread())]))
        #expect(model.inventory == known)
        registry.apply(DeviceInventorySnapshot(devices: [.simulator(phone)], issues: []))
        #expect(model.inventory == .simulator(phone))
    }

    @Test func remoteDuoResolvesInstalledArtworkWithoutOpeningAScreen() async {
        let device = InventoryDevice.remote(CoreDeviceDevice(identifier: "remote-duo", udid: nil,
            kind: .physical, name: "Duo", reportedName: "Duo", modelIdentifier: "iPhone19,4", modelName: "iPhone Duo", cpuType: nil,
            platform: "iOS", osVersion: nil, osBuild: nil, osBuildUpdate: nil, connectionState: "connected",
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

    @Test func remoteInfoUsesAvailablePropertiesWithoutSubstitutingItsCommandIDForUDID() async throws {
        let remote = CoreDeviceDevice(identifier: "command-id", udid: nil,
            kind: .physical, name: "Known Phone", reportedName: "Known Phone", modelIdentifier: "iPhone19,2", modelName: "iPhone 18 Pro", cpuType: nil,
            platform: "iOS", osVersion: "27.1", osBuild: nil, osBuildUpdate: nil, connectionState: "connected",
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
        let information = DeviceInformation(device: snapshot.device, properties: snapshot.fields.mapValues(DeviceInfoValue.init))
        #expect(information.fields.first { $0.id == ["name"] }?.value == "Current Phone")
        #expect(information.fields.first { $0.id == ["operatingSystem"] }?.value == "iOS 27.2")
        #expect(information.fields.first { $0.id == ["modelName"] }?.value == "iPhone 18 Pro")
        #expect(!information.fields.contains { $0.id == ["udid"] })
        #expect(information.fields.first { $0.id == ["connection", "transportType"] }?.value == "USB")
        #expect(information.fields.first { $0.id == ["connection", "state"] }?.value == "futureRawState")
        #expect(information.fields.filter { $0.id.starts(with: ["hardware", "cpuType"]) }.map(\.value) == ["arm64e"])
        let unknown = try JSONDecoder().decode(DeviceInspectorValue.self, from: Data(#"{"hardware":{"cpuType":{"type":2147483647,"subtype":18446744071562067970}}}"#.utf8))
        let unknownInfo = DeviceInformation(device: .remote(remote), properties: try #require(unknown.object).mapValues(DeviceInfoValue.init))
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
        try await wait(timeout: .seconds(5)) {
            !manager.isBusy && manager.activePairedDevice(for: phone().id)?.name == "Renamed Companion"
        }
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

        let source = ManagerModelSource(devices: inventory)
        let manager = SimulatorManagerModel(source: source)
        await manager.refresh()
        func model(_ device: SimulatorHostDevice) -> DeviceModel { DeviceModel(inventory: .simulator(device), source: source) }
        let inspection = DeviceInspectorModel()
        inspection.device = model(watch)
        let target = NSObject()
        let suite = "NeoSimulatorTests.PairedInfo.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = NSHostingController(rootView: DeviceInformationView(model: DeviceInformationModel(
            manager: manager, inspection: inspection, visibility: DeviceInfoVisibility(defaults: defaults),
            pairingMenu: { SimulatorPairingMenu.make(for: $0, model: manager, target: target,
                                                    action: #selector(NSApplication.terminate(_:))) },
            deviceMenu: { device in
                let menu = NSMenu(title: device.name)
                menu.addItem(withTitle: "View Screen", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
                return menu
            },
            unpair: { _ in Issue.record("Unpaired without a user action") })))
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
        inspection.device = model(SimulatorHostDevice(identifier: watch.identifier,
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
        inspection.device = model(phone)
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        #expect(try #require(addButton(in: view)).isEnabled)
        inspection.device = model(device("unpaired-phone", family: "iPhone", pairs: []))
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
}
