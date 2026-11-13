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
    @Test func returningToADeviceOrGroupReadsNothingAgainAndSharesARunningRead() async throws {
        let first = inspectedRemote("first"), second = inspectedRemote("second")
        let (source, registry) = listing(first, second)
        await source.skipSettingsReads()
        var events = source.events.makeAsyncIterator()
        let a = try #require(registry.device(for: first.id)), b = try #require(registry.device(for: second.id))
        let selection = ManagerSelection()
        selection.setInspection(.applications)
        selection.select(a, count: 1)
        #expect(await events.next() == .inspect(first.id))
        await registry.finishReading()
        selection.select(b, count: 1)
        #expect(await events.next() == .inspect(second.id))
        await registry.finishReading()
        selection.setInspection(.reports)
        #expect(await events.next() == .inspect(second.id))
        await registry.finishReading()
        #expect(b.inspection.reports.map(\.name) == ["Fixture.ips"])

        selection.setInspection(.applications)
        selection.select(a, count: 1)
        await registry.finishReading()
        #expect(a.inspection.applications.map(\.name) == ["Fixture"] && a.inspection.status(of: .applications) == .current)
        #expect(b.inspection.applications.map(\.name) == ["Fixture"] && b.inspection.reports.map(\.name) == ["Fixture.ips"])
        #expect(await source.inspectorCommands.count == 3)

        await source.holdInspectorReads()
        a.revalidate(.applications)
        #expect(await events.next() == .inspect(first.id))
        selection.select(b, count: 1)
        selection.select(a, count: 1)
        #expect(a.inspection.isReading(.applications))
        await source.completeInspectorRead(applications("Fresh"))
        await registry.finishReading()
        #expect(a.inspection.applications.map(\.name) == ["Fresh"])
        #expect(await source.inspectorCommands.count == 4)
        selection.select(nil, count: 0)
    }

    @Test func revalidatingDuringAReadLeadsToOneMoreRead() async throws {
        let device = inspectedRemote()
        let (source, registry) = listing(device)
        var events = source.events.makeAsyncIterator()
        let model = try #require(registry.device(for: device.id))
        await source.holdInspectorReads()
        let interest = model.keepCurrent(.applications)
        defer { interest.release() }
        #expect(await events.next() == .inspect(device.id))
        for _ in 0..<3 { model.revalidate(.applications) }
        model.revalidate(.reports)
        await source.completeInspectorRead(of: device.id)
        #expect(await events.next() == .inspect(device.id))
        await source.completeInspectorRead()
        await registry.finishReading()
        #expect(await source.inspectorCommands.count == 2)
    }

    @Test func aFailedOrPartialReadKeepsWhatItCouldNotAnswerAndLeavesOtherGroupsAlone() async throws {
        let device = inspectedRemote()
        let (source, registry) = listing(device)
        var events = source.events.makeAsyncIterator()
        let model = try #require(registry.device(for: device.id))
        let state = model.inspection
        let interest = model.keepCurrent([.info, .applications, .configurationProfiles, .reports])
        defer { interest.release() }
        for _ in 0..<4 { #expect(await events.next() == .inspect(device.id)) }
        await registry.finishReading()
        try #require(state.status(of: .applications) == .current && state.status(of: .info) == .current)

        await source.holdInspectorReads()
        model.revalidate([.applications, .info])
        for _ in 0..<2 { #expect(await events.next() == .inspect(device.id)) }
        await source.failInspectorRead()
        await registry.finishReading()
        #expect(state.applications.map(\.name) == ["Fixture"] && state.status(of: .applications) == .stale("Read Applications: Unavailable"))
        #expect(state.info["name"] == .string("Details") && state.status(of: .info) == .stale("Read Device Info: Unavailable"))
        #expect(state.status(of: .reports) == .current && state.status(of: .configurationProfiles) == .current)
        // A failure is not read again until something asks.
        #expect(await source.inspectorCommands.count == 6)
        model.revalidate(.info)
        #expect(await events.next() == .inspect(device.id))
        await registry.finishReading()
        #expect(state.status(of: .info) == .current)

        await source.setInspectorResponse(#"""
            {"result":{"files":[{"relativePath":"New.ips","metadata":{},"resources":{"isDirectory":false}},{"relativePath":"../outside.ips","metadata":{},"resources":{"isDirectory":false}}],
            "configurationProfiles":[{"payloadIdentifier":"new","name":"New"}],"partialConfigurationProfiles":[{"name":"Broken"},{"name":"Broken"}]}}
            """#)
        model.revalidate([.reports, .configurationProfiles])
        for _ in 0..<2 { #expect(await events.next() == .inspect(device.id)) }
        await registry.finishReading()
        #expect(state.reports.map(\.name) == ["New.ips"])
        #expect(state.status(of: .reports) == .stale("1 reports returned incomplete metadata. Available reports are shown."))
        #expect(state.configurationProfiles.map(\.name) == ["New"])
        #expect(state.status(of: .configurationProfiles) == .stale("2 profiles returned incomplete records. Available profiles are shown."))
    }

    @Test func aSimulatorsFailedInfoReadAddsWhatItsInventoryKnowsToWhatItKnew() async throws {
        let record = try #require(try CoreDeviceInventoryDecoder.decode(Data(#"{"result":{"devices":[{"identifier":"SIM","properties":{"hardware":{"fidelity":"simulated","udid":"same-udid"},"state":{"name":"Test Phone"},"connection":{"state":"connected"}},"capabilities":[]}]}}"#.utf8)).first)
        guard case .simulator(let phone) = simulator() else { throw ManagerModelSource.Failure.unavailable }
        let device = InventoryDevice.simulator(phone.inventoryCopy(ownerXcodeURL: nil, coreDevice: record))
        let (source, registry) = listing(device, response: #"{"devices":{"test-runtime":[{"udid":"same-udid","name":"Details"}]}}"#)
        var events = source.events.makeAsyncIterator()
        let model = try #require(registry.device(for: device.id))
        await source.holdInspectorReads()
        let interest = model.keepCurrent(.info)
        defer { interest.release() }
        #expect(await events.next() == .inspect(device.id))
        await source.failInspectorRead()
        await registry.finishReading()
        #expect(model.inspection.info["coreDeviceIdentifier"] == .string("SIM") && model.inspection.info["name"] == nil)
        #expect(model.inspection.status(of: .info) == .stale("Read Device Info: Unavailable"))

        model.revalidate(.info)
        #expect(await events.next() == .inspect(device.id))
        await registry.finishReading()
        #expect(model.inspection.info["name"] == .string("Details") && model.inspection.status(of: .info) == .current)
    }

    @Test func unsupportedIsDistinctFromFailedAndFromNotYetAvailable() async throws {
        let plist = #"{ "dev.example.kept" = { CFBundleIdentifier = "dev.example.kept"; CFBundleDisplayName = Kept; }; }"#
        let custom = simulator(deviceSet: "/custom")
        let (source, registry) = listing(simulator(state: "Shutdown"), custom, response: plist)
        var events = source.events.makeAsyncIterator()
        let model = try #require(registry.device(for: simulator().id)), customModel = try #require(registry.device(for: custom.id))
        let groups: DeviceStateGroups = [.applications, .configurationProfiles, .provisioningProfiles, .reports]
        let interests = [model.keepCurrent(groups), customModel.keepCurrent([.configurationProfiles, .provisioningProfiles, .reports])]
        defer { interests.forEach { $0.release() } }
        registry.revalidate()
        await registry.finishReading()
        #expect(await source.inspectorCommands.isEmpty)
        #expect(model.inspection.status(of: .reports) == .unsupported)
        #expect(model.inspection.status(of: .applications) == .unread && !model.inspection.canRead(.applications))
        #expect(customModel.inspection.status(of: .configurationProfiles) == .unsupported && customModel.inspection.status(of: .reports) == .unsupported)

        registry.apply(DeviceInventorySnapshot(devices: [simulator(), custom], issues: []))
        #expect(await events.next() == .inspect(simulator().id))
        await registry.finishReading()
        #expect(model.inspection.applications.map(\.name) == ["Kept"] && model.inspection.status(of: .applications) == .current)

        registry.apply(DeviceInventorySnapshot(devices: [simulator(state: "Shutdown"), custom], issues: []))
        registry.revalidate()
        await registry.finishReading()
        #expect(model.inspection.applications.map(\.name) == ["Kept"] && !model.inspection.canRead(.applications))
        #expect(await source.inspectorCommands.count == 1)
    }

    @Test func aDeviceThatDisconnectsKeepsItsListsAndOneThatLosesACapabilityDoesNot() async throws {
        let device = inspectedRemote()
        let (source, registry) = listing(device)
        var events = source.events.makeAsyncIterator()
        let model = try #require(registry.device(for: device.id))
        let interest = model.keepCurrent(.applications)
        defer { interest.release() }
        #expect(await events.next() == .inspect(device.id))
        await registry.finishReading()

        registry.apply(DeviceInventorySnapshot(devices: [inspectedRemote(connection: "disconnected", features: [])], issues: []))
        await registry.finishReading()
        #expect(model.inspection.applications.map(\.name) == ["Fixture"] && !model.inspection.canRead(.applications))
        #expect(await source.inspectorCommands.count == 1)

        registry.apply(DeviceInventorySnapshot(devices: [device], issues: []))
        #expect(await events.next() == .inspect(device.id))
        await source.holdInspectorReads()
        await registry.finishReading()
        model.revalidate(.applications)
        #expect(await events.next() == .inspect(device.id))
        // A read that was running when the device stopped having this does not bring it back.
        registry.apply(DeviceInventorySnapshot(devices: [inspectedRemote(features: [])], issues: []))
        await source.completeInspectorRead()
        await registry.finishReading()
        #expect(model.inspection.applications.isEmpty && model.inspection.status(of: .applications) == .unsupported)
    }

    @Test func aLateReadReachesNeitherARestartedOrRemovedDeviceNorItsReplacement() async throws {
        let device = inspectedRemote()
        let (source, registry) = listing(device)
        var events = source.events.makeAsyncIterator()
        let model = try #require(registry.device(for: device.id))
        await source.holdInspectorReads()
        let interest = model.keepCurrent(.applications)
        defer { interest.release() }
        #expect(await events.next() == .inspect(device.id))
        model.deviceRestarted()
        #expect(await events.next() == .inspect(device.id))
        await source.completeInspectorRead(applications("BeforeRestart"), of: device.id)
        await source.completeInspectorRead(applications("AfterRestart"), of: device.id)
        await registry.finishReading()
        #expect(model.inspection.applications.map(\.name) == ["AfterRestart"])

        model.revalidate(.applications)
        #expect(await events.next() == .inspect(device.id))
        registry.apply(DeviceInventorySnapshot(devices: [], issues: []))
        await source.completeInspectorRead(applications("Late"), of: device.id)
        #expect(!model.inspection.canRead(.applications))
        await #expect(throws: SimulatorError.self) { try await model.inspection.uninstallApplication(bundleIdentifier: "fixture.app") }

        registry.apply(DeviceInventorySnapshot(devices: [device], issues: []))
        let replacement = try #require(registry.device(for: device.id))
        #expect(replacement !== model)
        let newInterest = replacement.keepCurrent(.applications)
        defer { newInterest.release() }
        #expect(await events.next() == .inspect(device.id))
        await source.completeInspectorRead(applications("Replacement"))
        await registry.finishReading()
        #expect(replacement.inspection.applications.map(\.name) == ["Replacement"])
        #expect(model.inspection.applications.map(\.name) == ["AfterRestart"])
    }

    @Test func aChangeInvalidatesOnlyWhatItCanHaveChangedEvenWhenItFails() async throws {
        let device = inspectedRemote()
        let (source, registry) = listing(device)
        var events = source.events.makeAsyncIterator()
        let model = try #require(registry.device(for: device.id))
        let state = model.inspection
        var interest: DeviceReadInterest? = model.keepCurrent(.inspection)
        defer { interest?.release() }
        for _ in 0..<5 { #expect(await events.next() == .inspect(device.id)) }
        await registry.finishReading()
        func commands(after count: Int) async -> [[String]] {
            await source.inspectorCommands.dropFirst(count).map { Array($0.arguments.prefix(3)) }
        }

        try await state.uninstallApplication(bundleIdentifier: "fixture.app")
        for _ in 0..<2 { #expect(await events.next() == .inspect(device.id)) }
        await registry.finishReading()
        #expect(await commands(after: 5) == [["device", "uninstall", "app"], ["device", "info", "apps"]])

        // A failure can have changed the device, and changes only the kind of profile it was for.
        await source.holdInspectorReads()
        let removal = Task { try await state.removeProfile(identifier: "fixture.provisioning", kind: .provisioning) }
        #expect(await events.next() == .inspect(device.id))
        await source.failInspectorRead()
        await #expect(throws: (any Error).self) { try await removal.value }
        #expect(await events.next() == .inspect(device.id))
        await registry.finishReading()
        let afterRemoval = await source.inspectorCommands.suffix(2).map(\.arguments)
        #expect(afterRemoval[0].starts(with: ["device", "profile", "remove"]) && afterRemoval[1].starts(with: ["device", "profile", "list", "--type", "provisioning"]))
        #expect(await source.inspectorCommands.count == 9)
        #expect(state.status(of: .provisioningProfiles) == .current)

        // A read from before a change does not answer for it.
        await source.holdInspectorReads()
        model.revalidate(.applications)
        #expect(await events.next() == .inspect(device.id))
        let install = Task { try await state.installApplication(at: URL(fileURLWithPath: "/fixture/New.app")) }
        #expect(await events.next() == .inspect(device.id))
        await source.completeInspectorRead(applications("BeforeInstall"), of: device.id)
        await source.completeInspectorRead(of: device.id)
        try await install.value
        #expect(await events.next() == .inspect(device.id))
        #expect(state.applications.map(\.name) == ["Fixture"])
        await source.completeInspectorRead(applications("Installed"))
        await registry.finishReading()
        #expect(state.applications.map(\.name) == ["Installed"])

        // With nothing holding the list a change only marks it, and it is read when something next does.
        interest?.release()
        interest = nil
        let count = await source.inspectorCommands.count
        try await state.uninstallApplication(bundleIdentifier: "fixture.Installed")
        await registry.finishReading()
        #expect(await commands(after: count) == [["device", "uninstall", "app"]])
        #expect(await events.next() == .inspect(device.id))
        let held = model.keepCurrent(.inspection)
        defer { held.release() }
        #expect(await events.next() == .inspect(device.id))
        await registry.finishReading()
        #expect(await commands(after: count + 1) == [["device", "info", "apps"]])

        // A change that never started changed nothing.
        await source.holdInspectorReads()
        let running = Task { try await state.uninstallApplication(bundleIdentifier: "running") }
        #expect(await events.next() == .inspect(device.id))
        let queued = Task { try await state.uninstallApplication(bundleIdentifier: "queued") }
        try await wait { model.writeTasks.count == 2 }
        registry.apply(DeviceInventorySnapshot(devices: [], issues: []))
        await #expect(throws: CancellationError.self) { try await queued.value }
        await source.completeInspectorRead()
        try await running.value
        #expect(await source.inspectorCommands.last?.arguments.contains("queued") == false)
    }

    @Test func aReadStoppedForAQuitStaysOutOfDateRatherThanFailing() async throws {
        let device = inspectedRemote()
        let (source, registry) = listing(device)
        var events = source.events.makeAsyncIterator()
        let model = try #require(registry.device(for: device.id))
        await source.holdInspectorReads()
        let interest = model.keepCurrent([.info, .applications])
        defer { interest.release() }
        for _ in 0..<2 { #expect(await events.next() == .inspect(device.id)) }
        model.stopReading()
        model.resumeReading()
        for _ in 0..<2 { await source.failInspectorRead(with: CancellationError(), of: device.id) }
        for _ in 0..<2 { #expect(await events.next() == .inspect(device.id)) }
        #expect(model.inspection.status(of: .info) == .unread && model.inspection.status(of: .applications) == .unread)
        await source.completeInspectorRead()
        await registry.finishReading()
        #expect(model.inspection.status(of: .info) == .current && model.inspection.status(of: .applications) == .current)
    }

    @Test func applicationChangesReachOnlyTheDeviceTheyChanged() async throws {
        // The same UDID in the default set is a different device.
        let device = simulator(deviceSet: "/custom")
        let (source, registry) = listing(device, simulator(), response: "{}")
        var events = source.events.makeAsyncIterator()
        let model = try #require(registry.device(for: device.id)), other = try #require(registry.device(for: simulator().id))
        let interests = [model.keepCurrent(.applications), other.keepCurrent(.applications)]
        defer { interests.forEach { $0.release() } }
        for _ in 0..<2 { _ = await events.next() }
        await registry.finishReading()
        model.revalidate(.applications)
        #expect(await events.next() == .inspect(device.id))
        await registry.finishReading()
        #expect(await source.inspectorCommands.count == 3)
    }

    @Test func aSameDeviceRenameKeepsInfoUntilTheFreshDetailsArrive() async throws {
        let original = simulator()
        let updated = simulator(name: "Inventory Rename")
        func response(_ name: String) -> String {
            "{\"devices\":{\"test-runtime\":[{\"udid\":\"same-udid\",\"name\":\"\(name)\"}]}}"
        }
        let (source, registry) = listing(original, response: response("Initial Details"))
        var events = source.events.makeAsyncIterator()
        let model = try #require(registry.device(for: original.id))
        let interest = model.keepCurrent(.info)
        defer { interest.release() }
        #expect(await events.next() == .inspect(original.id))
        await registry.finishReading()
        try #require(model.inspection.info["name"] == .string("Initial Details"))
        await source.holdInspectorReads()
        registry.apply(DeviceInventorySnapshot(devices: [updated], issues: []))
        #expect(await events.next() == .inspect(updated.id))
        #expect(model.inspection.info["name"] == .string("Initial Details"))
        await source.completeInspectorRead(response("Fresh Details"))
        await registry.finishReading()
        #expect(model.inspection.info["name"] == .string("Fresh Details"))
    }

    @Test func screenDropsInstallWithTheInspectorInstallerOfTheirDevice() async throws {
        func device(_ name: String, features: Set<String>) -> InventoryDevice {
            .remote(CoreDeviceDevice(identifier: name, udid: nil, kind: .physical, name: name, reportedName: name,
                modelIdentifier: nil, modelName: nil, cpuType: nil, platform: "iOS", osVersion: nil, osBuild: nil, osBuildUpdate: nil,
                connectionState: "connected", pairingState: "paired", transportType: nil, bootState: "booted", preparednessState: nil,
                capabilities: Set(features.map { "com.apple.coredevice.feature." + $0 }), lastConnectedAt: nil, visibilityClass: nil))
        }
        let listing = device("Listing", features: ["streamapplist"])
        let phone = device("Phone", features: ["installapp"])
        let source = ManagerModelSource(devices: [listing, phone], inspectorResponse: "{}")
        var events = source.events.makeAsyncIterator()
        let model = SimulatorManagerModel(source: source)
        await model.refresh()
        var failures: [String] = []
        model.onError = { failures.append($0.localizedDescription) }
        let application = URL(fileURLWithPath: "/fixture/Dropped.app")
        #expect(!model.canInstallApplications(on: listing.id))
        model.installApplications(at: [application], on: listing.id)
        #expect(model.managingDeviceIDs.isEmpty)

        try #require(model.canInstallApplications(on: phone.id))
        await source.holdInspectorReads()
        model.installApplications(at: [application], on: phone.id)
        #expect(await events.next() == .inspect(phone.id))
        let command = try #require(await source.inspectorCommands.last)
        #expect(command.source == .coreDevice)
        #expect(command.arguments.starts(with: ["device", "install", "app", application.path, "--device", "Phone"]))
        // The inspector shows the same operation as in progress, and a second drop waits for it.
        #expect(model.managingDeviceIDs == [phone.id] && !model.canInstallApplications(on: phone.id))
        await source.failInspectorRead()
        try await wait(timeout: .seconds(5)) { model.managingDeviceIDs.isEmpty }
        #expect(failures == ["Phone: No files were imported.\n\nDropped.app: Install Application: Unavailable"])
        #expect(model.canInstallApplications(on: phone.id))
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
        let origin = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        origin.isReleasedWhenClosed = false
        defer { origin.close() }
        origin.orderFront(nil)
        let deviceActions = DeviceActions(model: manager, window: nil, liveScreen: { nil })
        var createdFor: DeviceInventoryID?
        deviceActions.onNewCompanion = { createdFor = $0.inventoryID }
        let context = NSMenu()
        deviceActions.populate(context, devices: [.simulator(phone)], includesViewScreen: false, window: origin)
        let titles = context.items.filter { !$0.isSeparatorItem && !$0.isAlternate }.map(\.title)
        #expect(!titles.contains("Clone…") && !titles.contains("Pair Simulators"))
        let create = try #require(context.items.first { $0.title == "Pair Apple Watch…" })
        let eraseIndex = try #require(context.items.firstIndex { $0.title == "Reset Content and Settings…" })
        let createIndex = try #require(context.items.firstIndex { $0 === create })
        let removeIndex = try #require(context.items.firstIndex { $0.title == "Remove…" })
        #expect(eraseIndex < createIndex && createIndex < removeIndex)
        #expect(create.isEnabled && create.submenu == nil)
        #expect(NSApp.sendAction(try #require(create.action), to: create.target, from: create))
        #expect(createdFor == phone.inventoryID)
        let applicationMenu = NSMenu()
        deviceActions.populate(applicationMenu, devices: [.simulator(phone)], includingAdditionalActions: true)
        #expect(applicationMenu.items.contains { $0.title == "Clone…" && $0.isEnabled })

        var events = source.events.makeAsyncIterator()
        manager.manage(.pair, devices: manager.inventory.filter { identifiers.contains($0.id) })
        #expect(await events.next() == .manage(.pair, [phone.inventoryID, watch.inventoryID]))
        try await wait { manager.managingDeviceIDs.isEmpty }

        let pairedPhone = device("phone", family: "iPhone", pairs: ["pair"])
        let linkedWatch = device("unpaired-watch", pairs: ["pair"])
        await source.setDevices(
            [
                pairedPhone, linkedWatch,
                device("unpaired-watch", set: "/custom", pairs: ["pair"]),
            ].map(InventoryDevice.simulator))
        await manager.refresh()
        deviceActions.populate(context, devices: [.simulator(pairedPhone)], includesViewScreen: false, window: origin)
        let unpair = try #require(context.items.first { $0.title == "Unpair unpaired-watch…" })
        #expect(NSApp.sendAction(try #require(unpair.action), to: unpair.target, from: unpair))
        #expect(manager.managingDeviceIDs.isEmpty)
        let sheet = try #require(origin.attachedSheet)
        let content = try #require(sheet.contentView)
        let confirm = try #require(
            inspectorViews(content).compactMap { $0 as? NSButton }
                .first { $0.title == "Unpair" })
        confirm.performClick(nil)
        #expect(await events.next() == .manage(.unpairCompanion(["pair"]), [watch.inventoryID]))
        try await wait { origin.attachedSheet == nil && manager.managingDeviceIDs.isEmpty }
        deviceActions.populate(context, devices: [.simulator(linkedWatch)], includesViewScreen: false, window: origin)
        #expect(context.items.contains { $0.title == "Unpair phone…" })
        #expect(!context.items.contains { $0.title == "Pair iPhone…" })

        #expect(NSApp.sendAction(try #require(unpair.action), to: unpair.target, from: unpair))
        let pendingSheet = try #require(origin.attachedSheet)
        let pendingContent = try #require(pendingSheet.contentView)
        let pendingConfirm = try #require(
            inspectorViews(pendingContent).compactMap { $0 as? NSButton }
                .first { $0.title == "Unpair" })
        await source.setDevices(
            [
                phone, device("unpaired-watch", pairs: ["replacement-pair"]),
                device("replacement-phone", family: "iPhone", pairs: ["replacement-pair"]),
            ].map(InventoryDevice.simulator))
        await manager.refresh()
        let acceptedRequests = await source.managementRequests
        pendingConfirm.performClick(nil)
        try await wait { origin.attachedSheet == nil }
        #expect(manager.managingDeviceIDs.isEmpty)
        #expect(await source.managementRequests == acceptedRequests)

        await source.setDevices([phone, watch].map(InventoryDevice.simulator))
        await manager.refresh()
        #expect(NSApp.sendAction(try #require(unpair.action), to: unpair.target, from: unpair))
        #expect(origin.attachedSheet == nil && manager.managingDeviceIDs.isEmpty)
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

    @Test func aPostureConnectionFailureStaysWithItsDeviceWithoutAlerting() async throws {
        guard case .simulator(let simulator) = simulator() else { return }
        let device = InventoryDevice.simulator(
            simulator.inventoryCopy(ownerXcodeURL: nil, capabilities: DevicePosturePayload.features))
        let postures = ManagerPostureConnections()
        postures.startFailure = ManagerModelSource.Failure.unavailable
        let manager = SimulatorManagerModel(
            source: ManagerModelSource(devices: [device]), makeDevicePosture: postures.model)
        var failures: [any Error] = []
        manager.onError = { failures.append($0) }
        await manager.refresh()
        manager.setOpenDeviceScreens([device.id])
        try await wait { manager.devicePostures[device.id]?.state == .failed }
        #expect(failures.isEmpty)
        #expect(manager.devicePostures[device.id]?.lastError != nil)
        #expect(manager.devicePostures[device.id]?.canSelect == false)
        #expect(manager.backgroundIssue(for: device.id)?.contains(device.name) == true)

        postures.startFailure = nil
        var events = postures.events.stream.makeAsyncIterator()
        await manager.retryBackgroundOperations(for: device.id)
        #expect(await events.next() == .observing(device.id))
        #expect(manager.devicePostures[device.id]?.canSelect == true)
        #expect(manager.devicePostures[device.id]?.lastError == nil && manager.backgroundIssue(for: device.id) == nil)
        await manager.stopDevicePostures()
    }

    @Test func connectingAScreenReplacesItsFailedPostureOwnerAfterDrainingIt() async throws {
        let features = DevicePosturePayload.features
        let data = try JSONSerialization.data(withJSONObject: ["result": ["devices": [[
            "identifier": "remote-command", "properties": ["hardware": ["fidelity": "physical", "hardwareModel": "V68AP"],
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
        // Posture observation can resume while the restart's service defaults are still applying.
        try await awaitServiceOperations(manager)

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

    @Test func closingAScreenClosesItsDeviceAndReportsItsFailedCleanup() async throws {
        let device = simulator()
        let source = ManagerModelSource(devices: [device])
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source)
        var failures: [String] = []
        manager.onError = { failures.append($0.localizedDescription) }
        manager.closeDevice(device.id, keepingDeviceRunning: true, after: Task { throw ManagerModelSource.Failure.unavailable })
        #expect(await events.next() == .close(device.id))
        // When the device's close fails too, both failures are reported.
        await source.failClose()
        manager.closeDevice(device.id, keepingDeviceRunning: true, after: Task { throw ManagerModelSource.Failure.unavailable })
        #expect(await events.next() == .close(device.id))
        try await manager.quitRenderer(keepingDevicesRunning: true)
        let cleanup = ManagerModelSource.Failure.unavailable.localizedDescription
        let close = ManagerModelSource.Failure.native.localizedDescription
        #expect(failures == [cleanup, [close, cleanup].joined(separator: "\n")])
    }

    @Test func aRemoteScreenUsesItsCommandIdentityAndClosingDuringManagementPreventsResubscription() async throws {
        let features = DevicePosturePayload.features.union(["com.apple.coredevice.feature.rebootdevice"])
        let data = try JSONSerialization.data(withJSONObject: ["result": ["devices": [[
            "identifier": "coredevice-command-id", "properties": [
                "hardware": ["fidelity": "physical", "udid": "different-hardware-udid", "hardwareModel": "V68AP"],
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

    @Test func onboardingDefersInitialURLsUntilAccessIsGranted() async throws {
        _ = NSApplication.shared
        let domain = "dev.lynnswap.NeoSimulator.HostPreferenceAccess.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let file = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).plist")
        try PropertyListSerialization.data(fromPropertyList: [:], format: .xml, options: 0).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let source = ManagerModelSource(devices: [simulator()])
        var selections = 0
        let access = HostPreferenceAccess(defaults: defaults, file: file, chooseFile: { _, window in
            #expect(window?.isVisible == true)
            selections += 1
            if selections == 1 { return nil }
            if selections == 2 { throw ManagerModelSource.Failure.unavailable }
            return file
        })
        let app = AppDelegate(makeLicenses: SettingsPreview.licenses, hostPreferenceAccess: access)
        app.model = SimulatorManagerModel(source: source)
        defer { app.mainWindow?.window?.close() }
        var events = source.events.makeAsyncIterator()
        let restoration = SimulatorScreenRestoration(device: SimulatorDeviceIdentifier("same-udid"),
            xcodeURL: URL(fileURLWithPath: "/Xcode.app"), presentation: .compact)
        app.applicationWillFinishLaunching(Notification(name: NSApplication.willFinishLaunchingNotification))
        app.application(NSApp, open: [restoration.url])
        #expect(!app.model.isBusy && app.model.openingDeviceIDs.isEmpty)
        #expect(app.mainWindow == nil && selections == 0)
        #expect(await source.sessionEvents.isEmpty)
        app.startManager()
        try await wait { app.onboardingWindow?.window?.isVisible == true }
        #expect(app.mainWindow == nil && selections == 0)
        #expect(await source.sessionEvents.isEmpty)
        app.onboardingWindow?.close()
        try await wait { app.onboardingWindow == nil }
        #expect(app.mainWindow == nil && selections == 0)

        app.startManager()
        try await wait { app.onboardingWindow?.window?.isVisible == true }
        let onboarding = try #require(app.onboardingWindow)
        onboarding.allowAccess()
        try await wait { selections == 1 && !onboarding.state.isRequesting }
        #expect(onboarding.window?.isVisible == true && onboarding.state.errorMessage == nil)
        #expect(app.mainWindow == nil)
        onboarding.allowAccess()
        try await wait { onboarding.state.errorMessage != nil && !onboarding.state.isRequesting }
        #expect(onboarding.state.errorMessage == ManagerModelSource.Failure.unavailable.localizedDescription)
        #expect(await source.sessionEvents.isEmpty)
        onboarding.allowAccess()
        while let event = await events.next() {
            if event == .open(restoration.deviceID) { break }
        }
        #expect(app.mainWindow?.window?.isVisible == true && selections == 3)
        #expect(app.onboardingWindow == nil && onboarding.window?.isVisible == false)
        #expect(await source.sessionEvents.first == "begin")
        #expect(app.model.status?.host == .neo)
        await source.completeOpen()
        try await app.model.quitRenderer(keepingDevicesRunning: true)
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
        try input.fileHandleForWriting.close()
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

    @Test func aStalledAcceptedChangeCannotHoldAQuitAndIsReportedAsUnknown() async throws {
        let device = simulator()
        let source = ManagerModelSource(devices: [device], holdsManagement: true)
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source)
        let commands = UninterruptedCommands()
        manager.uninterruptedCommands = commands
        manager.terminationLimit = .milliseconds(50)
        manager.terminationGrace = .milliseconds(50)
        var reports: [String] = []
        manager.onError = { reports.append($0.localizedDescription) }
        manager.manage(.erase, devices: [device])
        #expect(await events.next() == .manage(.erase, [device.id]))

        try await manager.prepareForQuit()
        #expect(reports.count == 1 && reports[0].contains("had not finished when NeoSimulator quit"))
        // Later steps of the quit join the same wait, and report it once.
        try await manager.prepareForQuit()
        #expect(reports.count == 1)
        // The stalled change has an owner to the end, whose own report still arrives.
        await source.completeManagement(.erase)
    }

    @Test func anOperationOnOneDeviceLeavesOtherDevicesManageable() async throws {
        let first = simulator(deviceSet: "/first")
        let second = simulator(deviceSet: "/second")
        let third = simulator(deviceSet: "/third")
        let source = ManagerModelSource(devices: [first, second, third], holdsManagement: true)
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source)
        manager.registry.stopReading()
        await manager.refresh()

        // Another device can start and finish while this one's restart stays held, but not one that it overlaps.
        manager.manage(.restart, devices: [first])
        #expect(await events.next() == .manage(.restart, [first.id]))
        #expect(!manager.canManage(.restart, deviceIDs: [first.id]))
        #expect(!manager.canManage(.restart, deviceIDs: [first.id, second.id]))
        #expect(manager.canManage(.restart, deviceIDs: [second.id]))
        manager.manage(.restart, devices: [second])
        #expect(await events.next() == .manage(.restart, [second.id]))
        #expect(manager.managingDeviceIDs == [first.id, second.id] && !manager.canManage(.restart, deviceIDs: [second.id]))
        await source.completeManagement(.restart, for: second.id)
        try await wait { manager.managingDeviceIDs == [first.id] }
        #expect(manager.canManage(.restart, deviceIDs: [second.id]))

        // Work queued for a device stops only that device, even when it only attaches a screen.
        manager.openScreen(for: third)
        #expect(await events.next() == .open(third.id))
        #expect(manager.isBusy && manager.canManage(.restart, deviceIDs: [second.id]))
        #expect(!manager.canManage(.restart, deviceIDs: [third.id]) && !manager.canManage(.restart, deviceIDs: [second.id, third.id]))
        await source.completeOpen()
        try await wait { !manager.isBusy }
        #expect(manager.canManage(.restart, deviceIDs: [third.id]))

        // Work that concerns every device stops all of them, whichever it is.
        let access = AsyncStream<CheckedContinuation<Void, Never>>.makeStream()
        var accesses = access.stream.makeAsyncIterator()
        manager.requestHostPreferenceAccess = { await withCheckedContinuation { access.continuation.yield($0) } }
        manager.restoreDefaults()
        let transition = try #require(await accesses.next())
        #expect(!manager.canManage(.restart, deviceIDs: [second.id]) && !manager.canManage(.forceShutdown, deviceIDs: [third.id]))
        manager.manage(.restart, devices: [second])
        #expect(await source.managementRequests == 2)
        transition.resume()
        try await wait { !manager.isBusy }
        #expect(manager.canManage(.restart, deviceIDs: [second.id]))

        await source.completeManagement(.restart, for: first.id)
        try await manager.quitRenderer(keepingDevicesRunning: true)
        #expect(manager.managingDeviceIDs.isEmpty)
    }

    @Test func aHeldCloseOfOneDeviceHoldsOnlyThatDevicesWork() async throws {
        let first = simulator(deviceSet: "/first")
        let second = simulator(deviceSet: "/second")
        let data = try JSONSerialization.data(withJSONObject: ["result": ["devices": [["identifier": "remote",
            "properties": ["hardware": ["fidelity": "physical"], "state": ["name": "Remote"], "connection": ["state": "connected"]],
            "capabilities": [["featureIdentifier": "com.apple.coredevice.feature.viewdevicescreen"]]]]]])
        let remote = InventoryDevice.remote(try #require(CoreDeviceInventoryDecoder.decode(data).first))
        let source = ManagerModelSource(devices: [first, second, remote], holdsManagement: true)
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source)
        manager.registry.stopReading()
        await manager.refresh()
        let remoteOpens = AsyncStream<DeviceInventoryID>.makeStream()
        manager.onOpenRemoteDevice = { remoteOpens.continuation.yield(.coreDevice($0.identifier)) }
        var remoteOpened = remoteOpens.stream.makeAsyncIterator()

        // The screen's cleanup holds A's close. Everything on another device starts and finishes behind it.
        let cleanup = AsyncStream<Void>.makeStream()
        manager.closeDevice(first.id, keepingDeviceRunning: true, after: Task { for await _ in cleanup.stream { break } })
        #expect(manager.queuedDeviceIDs == [first.id] && !manager.holdsAllEdits)
        #expect(!manager.canManage(.restart, deviceIDs: [first.id]) && manager.canManage(.restart, deviceIDs: [second.id]))
        #expect(manager.canViewScreen(remote))
        manager.closeDevice(second.id, keepingDeviceRunning: true, after: Task {})
        #expect(await events.next() == .close(second.id))
        try await wait { manager.queuedDeviceIDs == [first.id] }
        manager.openScreen(for: second)
        #expect(await events.next() == .open(second.id))
        await source.completeOpen(for: second.id)
        try await wait { manager.queuedDeviceIDs == [first.id] }
        manager.openScreen(for: remote)
        #expect(await remoteOpened.next() == remote.id)
        try await wait { manager.queuedDeviceIDs == [first.id] }
        manager.manage(.restart, devices: [second])
        #expect(await events.next() == .manage(.restart, [second.id]))
        await source.completeManagement(.restart, for: second.id)
        try await wait { manager.managingDeviceIDs.isEmpty }

        // A's later open follows its close, and work that concerns every device follows both and holds what comes after.
        let access = AsyncStream<CheckedContinuation<Void, Never>>.makeStream()
        var accesses = access.stream.makeAsyncIterator()
        manager.requestHostPreferenceAccess = { await withCheckedContinuation { access.continuation.yield($0) } }
        manager.openScreen(for: first)
        manager.restoreDefaults()
        #expect(manager.holdsAllEdits && !manager.canManage(.restart, deviceIDs: [second.id]) && !manager.canViewScreen(remote))
        manager.openScreen(for: second)
        cleanup.continuation.yield(())
        #expect(await events.next() == .close(first.id))
        #expect(await events.next() == .open(first.id))
        await source.completeOpen(for: first.id)
        let transition = try #require(await accesses.next())
        #expect(manager.queuedDeviceIDs == [second.id])
        transition.resume()
        #expect(await events.next() == .open(second.id))
        await source.completeOpen(for: second.id)
        try await wait { !manager.isBusy }
        try await manager.quitRenderer(keepingDevicesRunning: true)
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

    @Test func stalledScreenOpenDoesNotBlockAnotherDeviceAndCancellationStaysPerDevice() async throws {
        let running = simulator()
        let stopped = simulator(deviceSet: "/other-set", state: "Shutdown")
        let source = ManagerModelSource(devices: [running, stopped])
        defer {
            Task {
                await source.completeOpen(for: running.id)
                await source.completeOpen(for: stopped.id)
            }
        }
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source)
        await manager.refresh()

        manager.openDevice(running.id)
        #expect(await events.next() == .open(running.id))
        let window = ManagerWindowController(model: manager, screens: DeviceScreens(model: manager),
                                             menus: MenuController(application: nil))
        window.window?.setFrameAutosaveName("")
        defer { window.window?.close() }
        window.selectDevice(stopped.id)
        window.sidebar.update()
        let content = try #require(window.window?.contentView)
        let start = try #require(inspectorViews(content).compactMap { $0 as? NSButton }.first { $0.title == "Start" })
        let outline = try #require(inspectorViews(content).compactMap { $0 as? NSOutlineView }.first)
        func selectedProgressIsHidden() -> Bool? {
            (outline.view(atColumn: 0, row: outline.selectedRow, makeIfNecessary: true) as? SimulatorSidebarCellView)?.progress.isHidden
        }
        #expect(selectedProgressIsHidden() == true)
        #expect(inspectorViews(window.deviceScreenViewController.view).compactMap { $0 as? NSProgressIndicator }.isEmpty)
        try #require(start.isEnabled)
        start.performClick(nil)
        #expect(await events.next() == .open(stopped.id))
        try await wait { selectedProgressIsHidden() == false }
        #expect(await source.lastOpenBootIfNeeded == true)
        manager.cancelOpening(running.id)
        #expect(source.cancelledOpenIDs == [running.id])
        await source.completeOpen(for: stopped.id)
        try await wait { !manager.openingDeviceIDs.contains(stopped.id) }
        #expect(manager.openingDeviceIDs == [running.id])
        await source.completeOpen(for: running.id)
        try await wait { !manager.isBusy }
        try await wait { selectedProgressIsHidden() == true }
        try await manager.quitRenderer(keepingDevicesRunning: true)
    }

    @Test func acceptedEditsShowAtOnceRunInOrderAndDrainBeforeQuit() async throws {
        let device = simulator()
        let queued = simulator(deviceSet: "/queued-device-set")
        let source = ManagerModelSource(devices: [device, queued])
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source)
        await manager.refresh()
        manager.inspect(device, selectionCount: 1)
        let values = try #require(manager.selection.device?.settings)
        #expect(await events.next() == .read(device.id))
        await source.completeRead(settings(appearance: .light, contentSize: .medium))
        await manager.registry.finishReading()

        manager.openDevice(device.id)
        #expect(await events.next() == .open(device.id))
        // A device that stops before the request reaches its host must not boot beside these edits.
        #expect(await source.lastOpenBootIfNeeded == false)
        manager.openDevice(queued.id)
        #expect(await events.next() == .open(queued.id))
        #expect(manager.openingDeviceIDs == [device.id, queued.id])
        #expect(manager.isBusy && manager.canEditSettings(for: device.id))
        manager.setDeviceSetting(.appearance(.dark), for: device.id)
        manager.setDeviceSetting(.contentSize(.large), for: device.id)
        #expect(values.appearance == .dark)
        #expect(values.contentSize == .large)
        manager.cancelOpening(queued.id)
        // The running device's screen is still connecting when the first edit reaches the device.
        #expect(await events.next() == .write(device.id))
        manager.cancelOpening(device.id)
        #expect(source.cancelledOpenIDs == [device.id, queued.id])
        // The lower IPC deliberately returns success after cancellation.
        await source.completeOpen(for: device.id)
        await source.completeOpen(for: queued.id)
        await source.completeWrite()
        // The first edit's read does not wait for the second, which changes another group.
        let started = [await events.next(), await events.next()]
        #expect(started.contains(.write(device.id)) && started.contains(.read(device.id)))
        #expect(await source.writtenChanges == [.appearance(.dark), .contentSize(.large)])
        await source.completeRead(settings(appearance: .dark, contentSize: .large))

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
        #expect(manager.openingDeviceIDs.isEmpty)
        #expect(values.appearance == .dark)
        #expect(values.contentSize == .large)
        #expect(await source.readCount == 2)
        manager.resumeAfterCancelledQuit()
        // What the stopped reads did not confirm is read again.
        #expect(await events.next() == .read(device.id))
        await source.completeRead(settings(appearance: .dark, contentSize: .large))
        await manager.registry.finishReading()
        manager.openDevice(device.id)
        #expect(await events.next() == .open(device.id))
        await source.completeOpen()
        try await manager.quitRenderer(keepingDevicesRunning: true)
        #expect(await events.next() == .quit)
    }

    @Test func reopeningDuringAShutDownCloseBootsTheDeviceAgain() async throws {
        let device = simulator()
        let source = ManagerModelSource(devices: [device])
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source)
        await manager.refresh()
        let cleanup = AsyncStream<Void>.makeStream()
        manager.closeDevice(device.id, keepingDeviceRunning: false, after: Task { for await _ in cleanup.stream { break } })
        // The inventory still reports the device running while its close waits for the screen's cleanup.
        manager.openDevice(device.id)
        await source.setDevices([simulator(state: "Shutdown")])
        cleanup.continuation.yield(())
        #expect(await events.next() == .close(device.id))
        #expect(await events.next() == .open(device.id))
        #expect(await source.lastOpenBootIfNeeded == true)
        #expect(!manager.canEditSettings(for: device.id))
        await source.completeOpen()
        try await manager.quitRenderer(keepingDevicesRunning: true)
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
    func retiringAnOpenPublishesRefreshRequestsDeferredWhileBusy(_ cancelled: Bool) async throws {
        func remote(_ name: String) throws -> InventoryDevice {
            let data = try JSONSerialization.data(withJSONObject: ["result": ["devices": [["identifier": "remote",
                "properties": ["hardware": ["fidelity": "physical"], "state": ["name": name]]]]]])
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
        #expect(await events.next() == .open(next.id))
        await source.setDevices([device, next, try remote("Updated")])
        await manager.refresh()
        #expect(manager.isBusy && manager.inventory.last?.name == "Original")
        if cancelled {
            manager.cancelOpening(device.id)
            await source.completeOpen()
        } else { await source.failOpen() }
        try await wait { manager.inventory.last?.name == "Updated" }
        #expect(manager.openingDeviceIDs == [next.id])
        await source.completeOpen()
        try await manager.quitRenderer(keepingDevicesRunning: true)
    }

    @Test func anOpenedScreenIsNoLongerCancellableWhileItsInventoryRefreshes() async throws {
        let device = simulator()
        let queued = simulator(deviceSet: "/queued-device-set")
        let source = ManagerModelSource(devices: [device, queued])
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source)
        manager.openDevice(device.id)
        #expect(await events.next() == .open(device.id))
        manager.openDevice(queued.id)
        #expect(await events.next() == .open(queued.id))
        await source.holdInventoryReads()
        await source.completeOpen()
        #expect(await events.next() == .inventory)
        #expect(manager.openingDeviceIDs == [queued.id])
        manager.openDevice(device.id)
        manager.cancelOpening(device.id)
        #expect(manager.openingDeviceIDs == [queued.id])
        let quitting = Task.immediate { try await manager.quitRenderer(keepingDevicesRunning: true) }
        #expect(source.cancelledOpenIDs == [device.id, queued.id])
        await source.completeOpen(for: queued.id)
        await source.completeInventoryRead()
        try await quitting.value
        // Quit cancelled only the unfinished open and did not close the opened screen.
        #expect(await events.next() == .quit)
    }

    /// The child never exits by itself and the accepted close is not cancelled, so only stopping the read lets the quit finish.
    @Test func quittingStopsAnInventoryReadHeldByAnUnresponsiveChild() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let device = simulator()
        let source = ManagerModelSource(devices: [device])
        let manager = SimulatorManagerModel(source: source)
        await manager.refresh()
        // A read that published would remove the device.
        await source.setDevices([])
        let child = try unresponsiveRead(in: directory)
        await source.holdReads(in: child.command)
        manager.closeDevice(device.id, keepingDeviceRunning: true, after: Task {})
        let identifier = try #require(try await child.identifier.value)
        try await manager.prepareForQuit()
        #expect(kill(identifier, 0) == -1 && errno == ESRCH)
        #expect(manager.inventory.map(\.id) == [device.id])
        #expect(manager.backgroundIssue == nil)

        await source.holdReads(in: nil)
        manager.resumeAfterCancelledQuit()
        try await wait { manager.inventory.isEmpty }
    }

    /// Quitting releases the read and reports that the accepted change did not run.
    @Test func quittingStopsAManagementCatalogReadHeldByAnUnresponsiveChild() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let device = simulator()
        let source = ManagerModelSource(devices: [device])
        let manager = SimulatorManagerModel(source: source)
        var reported: [any Error] = []
        manager.onError = { reported.append($0) }
        await manager.refresh()
        let child = try unresponsiveRead(in: directory)
        await source.holdReads(in: child.command)
        manager.manage(.rename("Renamed"), devices: [device])
        let identifier = try #require(try await child.identifier.value)
        try await manager.prepareForQuit()
        #expect(kill(identifier, 0) == -1 && errno == ESRCH)
        #expect(await source.managementRequests == 0)
        let failure = try #require(reported.first as? any LocalizedError)
        #expect(reported.count == 1)
        #expect(failure.recoverySuggestion?.contains("stopped before the requested change was applied") == true)
    }

    /// Reads run through the real runner, so the backend's read back ends with the cancelled change, and the consumer has to read again.
    @Test func aStoppedServiceChangeReachesItsConsumerWithItsOutcomeAndIsReadAgain() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let child = try unresponsiveRead(in: directory)
        let command = child.command
        let label = "com.apple.searchd"
        let device = simulator()
        let changeStarted = Mutex(false)
        let registry = DeviceRegistry(source: ServiceChangeSource(device: device, backend: SimulatorBackgroundServiceBackend(launchctl: { arguments in
            guard ["print-disabled", "list"].contains(arguments[0]) else {
                changeStarted.withLock { $0 = true }
                return try await SystemCommandRunner().run(command)
            }
            let disabled = arguments[0] == "print-disabled" && changeStarted.withLock { $0 }
            return try await SystemCommandRunner().run(SystemCommand(executable: URL(fileURLWithPath: "/bin/echo"),
                arguments: [disabled ? "\"\(label)\" => disabled" : ""], policy: .backgroundServiceCommand))
        }, jobPlists: { _ in [:] }, pause: { _ in }, productFamily: "iPhone")))
        try await registry.refresh()
        let model = try #require(registry.device(for: device.id))
        let interest = model.keepCurrent(.backgroundServices)
        defer { interest.release() }
        let services = model.backgroundServices
        let applying = Task { try await services.set([.service(label)], enabled: false) }
        let identifier = try #require(try await child.identifier.value)
        applying.cancel()
        let failure = try await #require(throws: SimulatorHostFailure.self) { try await applying.value }
        #expect(kill(identifier, 0) == -1 && errno == ESRCH)
        #expect(failure.failureReason?.contains("disable \(label): sh was stopped before it finished, so what it changed is unknown.") == true)
        #expect(!services.isChanging)
        try await wait { services.services?.disabledLabels == [label] }
    }

    @Test func editingDuringRefreshStillReadsExternalChanges() async throws {
        let device = simulator()
        let source = ManagerModelSource(devices: [device])
        var events = source.events.makeAsyncIterator()
        let (registry, model, interest) = try await settingsFixture(source)
        defer { interest.release() }
        #expect(await events.next() == .read(device.id))
        await source.completeRead(settings(appearance: .light, contentSize: .medium))
        await registry.finishReading()

        model.revalidate(.settings)
        #expect(await events.next() == .read(device.id))
        let values = model.settings
        let applying = Task { try await values.set(.contentSize(.large)) }
        #expect(await events.next() == .write(device.id))
        // This read began before the edit, so it says nothing of the edited group, though it does of the rest.
        await source.completeRead(settings(appearance: .dark, contentSize: .medium))
        #expect(values.appearance == .dark && values.contentSize == .large)
        await source.returnOnNextRead(settings(appearance: .dark, contentSize: .large))
        await source.completeWrite()
        try await applying.value
        #expect(await events.next() == .read(device.id))
        await registry.finishReading()

        #expect(values.appearance == .dark)
        #expect(values.contentSize == .large)
    }

    @Test func sameDeviceMetadataKeepsLoadedValuesAndAnInFlightRead() async throws {
        let device = simulator()
        let renamed = simulator(name: "Renamed Phone", lastUsedAt: Date(timeIntervalSinceReferenceDate: 1))
        let source = ManagerModelSource(devices: [device])
        var events = source.events.makeAsyncIterator()
        let (registry, model, interest) = try await settingsFixture(source)
        defer { interest.release() }
        #expect(await events.next() == .read(device.id))
        await source.completeRead(settings(appearance: .light))
        await registry.finishReading()

        model.revalidate(.settings)
        #expect(await events.next() == .read(device.id))
        await source.setDevices([renamed])
        try await registry.refresh()
        #expect(registry.device(for: device.id) === model)
        #expect(model.name == "Renamed Phone" && model.settings.appearance == .light)
        await source.completeRead(settings(appearance: .dark))
        await registry.finishReading()
        // The rename asked nothing of the device, and the read that was running still answers for it.
        #expect(model.settings.appearance == .dark)
        #expect(await source.readCount == 2)

        await source.setDevices([simulator(name: "Renamed Phone", state: "Shutdown")])
        try await registry.refresh()
        #expect(!model.canInspectSettings && model.settings.appearance == .dark)
        await source.setDevices([renamed])
        try await registry.refresh()
        #expect(await events.next() == .read(device.id))
        await source.completeRead(settings(appearance: .light, contentSize: .large))
        await registry.finishReading()
        #expect(model.canInspectSettings && model.settings.contentSize == .large)
    }

    @Test func sameDeviceMetadataKeepsAcceptedEditsAndTheirConfirmation() async throws {
        let device = simulator()
        let source = ManagerModelSource(devices: [device])
        var events = source.events.makeAsyncIterator()
        let (registry, model, interest) = try await settingsFixture(source)
        defer { interest.release() }
        let values = model.settings
        #expect(await events.next() == .read(device.id))
        await source.completeRead(settings(appearance: .light, contentSize: .medium))
        await registry.finishReading()

        registry.stopReading()
        let applying = Task { try await values.set(.contentSize(.large)) }
        #expect(await events.next() == .write(device.id))
        await source.setDevices([simulator(name: "Renamed Phone")])
        try await registry.refresh()
        #expect(values.appearance == .light && values.contentSize == .large)
        await source.setDevices([simulator(name: "Latest Phone")])
        try await registry.refresh()
        await source.completeWrite()
        try await applying.value
        #expect(model.name == "Latest Phone" && values.contentSize == .large)

        registry.resumeReading()
        #expect(await events.next() == .read(device.id))
        await source.completeRead(settings(appearance: .dark, contentSize: .large))
        await registry.finishReading()
        #expect(values.appearance == .dark && values.contentSize == .large)
    }

    @Test func resultsStayWithTheirDeviceAcrossDeviceSets() async throws {
        let first = simulator(deviceSet: "/first")
        let second = simulator(deviceSet: "/second")
        let source = ManagerModelSource(devices: [first, second])
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source)
        await manager.refresh()
        manager.inspect(first, selectionCount: 1)
        let firstValues = try #require(manager.selection.device?.settings)
        #expect(await events.next() == .read(first.id))
        manager.inspect(second, selectionCount: 1)
        let secondValues = try #require(manager.selection.device?.settings)
        #expect(await events.next() == .read(second.id))
        await source.completeRead(settings(appearance: .dark), for: first.id)
        #expect(secondValues.appearance == nil && firstValues.appearance == .dark)
        await source.completeRead(settings(appearance: .light), for: second.id)
        await manager.registry.finishReading()
        #expect(manager.selection.device?.id == second.id)
        #expect(secondValues.appearance == .light && firstValues.appearance == .dark)
    }

    @Test(arguments: [false, true])
    func settingsBindingsSurviveSelectionChanges(_ deselect: Bool) async throws {
        let first = simulator(deviceSet: "/first")
        let second = simulator(deviceSet: "/second")
        let source = ManagerModelSource(devices: [first, second])
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source)
        await manager.refresh()
        let panel = DeviceSettingsPanelModel(manager: manager, screens: DeviceScreens(model: manager),
            preferences: SimulatorPreferences(), customLocation: {})
        manager.inspect(first, selectionCount: 1)
        #expect(panel.content == .settings)
        let loadingForm = try #require(panel.form)
        #expect(await events.next() == .read(first.id))
        var settings = SimulatorDeviceSettings(appearance: .light, boldText: false, liquidGlassOpacity: 0.5, colorFilter: SimulatorColorFilter.none)
        settings.colorFilterRequiredOSVersion = 27
        let zoomMode = SimulatorDisplayZoomMode(rawMode: 3, nativeName: "Default", width: 390, height: 844)
        settings.displayZoom = zoomMode
        settings.supportedDisplayZoomModes = [zoomMode]
        settings.audioOutputDevice = "speakers"
        settings.audioOutputDevices = [SimulatorAudioDevice(identifier: "speakers", name: "Speakers")]
        settings.audioInputDevice = "microphone"
        settings.audioInputDevices = [SimulatorAudioDevice(identifier: "microphone", name: "Microphone")]
        await source.completeRead(settings)
        await manager.registry.finishReading()
        @Bindable var form = try #require(panel.form)
        #expect(panel.content == .settings && form === loadingForm)
        #expect(form.colorFilterRequirement == "OS 27+")
        #expect(form.colorFilter == .some(.none) && form.colorFilterAvailable)
        let toggle = $form.boldText
        let picker = $form.appearance
        let slider = $form.liquidGlassOpacity
        let zoom = $form.displayZoom
        let output = $form.audioOutput
        let input = $form.audioInput
        let control = ManagerSettingSlider.Control(model: form.liquidGlassOpacitySlider)
        defer { control.stopObserving() }
        #expect(control.doubleValue == 0.5)
        #expect(zoom.wrappedValue == 3 && output.wrappedValue == "speakers" && input.wrappedValue == "microphone")

        manager.inspect(deselect ? nil : second, selectionCount: deselect ? 0 : 1)
        #expect(panel.form?.device.id == (deselect ? nil : second.id))
        #expect(panel.form?.colorFilterRequirement.isEmpty ?? true)
        #expect(toggle.wrappedValue == false)
        #expect(picker.wrappedValue == .light)
        #expect(slider.wrappedValue == 0.5)
        toggle.wrappedValue = true
        picker.wrappedValue = .dark
        slider.wrappedValue = 0.75
        zoom.wrappedValue = 4
        output.wrappedValue = "headphones"
        input.wrappedValue = "external-microphone"
        if !deselect {
            #expect(panel.content == .settings)
            #expect(await events.next() == .read(second.id))
            await source.completeRead(SimulatorDeviceSettings(appearance: .dark, boldText: true, liquidGlassOpacity: 1))
            await manager.registry.finishReading()
            #expect(toggle.wrappedValue == false && picker.wrappedValue == .light && slider.wrappedValue == 0.5)
            toggle.wrappedValue = false
            picker.wrappedValue = .light
            slider.wrappedValue = 0
            let selected = try #require(panel.form)
            #expect(selected.boldText && selected.appearance == .dark && selected.liquidGlassOpacity == 1)
            control.setModel(selected.liquidGlassOpacitySlider)
            #expect(control.doubleValue == 1 && control.model === selected.liquidGlassOpacitySlider)
        }
        try await manager.prepareForQuit()
        #expect(await source.writtenChanges.isEmpty)
    }

    @Test func settingsBindingsTrackEditsAndSurviveUnavailableSettings() async throws {
        let device = simulator()
        let source = ManagerModelSource(devices: [device])
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source)
        await manager.refresh()
        let panel = DeviceSettingsPanelModel(manager: manager, screens: DeviceScreens(model: manager),
            preferences: SimulatorPreferences(), customLocation: {})
        manager.inspect(device, selectionCount: 1)
        #expect(await events.next() == .read(device.id))
        await source.completeRead(SimulatorDeviceSettings(appearance: .light, contentSize: .medium, boldText: false))
        await manager.registry.finishReading()
        @Bindable var form = try #require(panel.form)
        let toggle = $form.boldText
        let picker = $form.appearance
        let slider = $form.textSize
        let medium = Double(try #require(DeviceContentSize.allCases.firstIndex(of: .medium)))
        let large = Double(try #require(DeviceContentSize.allCases.firstIndex(of: .large)))
        let control = ManagerSettingSlider.Control(model: form.textSizeSlider)
        defer { control.stopObserving() }
        #expect(control.isEnabled && control.doubleValue == medium)
        let disabledView = NSHostingView(rootView: ManagerSettingSlider(model: form.textSizeSlider).disabled(true))
        disabledView.frame = NSRect(x: 0, y: 0, width: 200, height: 30)
        try await wait {
            disabledView.layoutSubtreeIfNeeded()
            return inspectorViews(disabledView).contains { $0 is ManagerSettingSlider.Control }
        }
        let disabledControl = try #require(inspectorViews(disabledView).compactMap { $0 as? ManagerSettingSlider.Control }.first)
        #expect(!disabledControl.isEnabled)
        disabledControl.doubleValue = large
        disabledControl.sendAction(disabledControl.action, to: disabledControl.target)
        #expect(form.textSize == medium && disabledControl.doubleValue == medium)

        toggle.wrappedValue = true
        picker.wrappedValue = .dark
        control.doubleValue = large
        control.sendAction(control.action, to: control.target)
        #expect(toggle.wrappedValue == true && picker.wrappedValue == .dark && slider.wrappedValue == large)
        // Each edit changes its own group, so each is read back at its own outcome, however far the next has got.
        var writes = 0
        var reads = 0
        while writes < 3 || reads < 3 {
            let event = await events.next()
            if event == .write(device.id) {
                writes += 1
                await source.completeWrite()
            } else {
                #expect(event == .read(device.id))
                reads += 1
            }
        }
        for _ in 0..<reads {
            await source.completeRead(SimulatorDeviceSettings(appearance: .dark, contentSize: .extraLarge, boldText: true))
        }
        try await awaitServiceOperations(manager)
        await manager.registry.finishReading()
        let confirmedSize = Double(try #require(DeviceContentSize.allCases.firstIndex(of: .extraLarge)))
        #expect(form.boldText && form.appearance == .dark && form.textSize == confirmedSize)
        try await wait { control.doubleValue == confirmedSize }

        await source.setDevices([simulator(state: "Shutdown")])
        await manager.refresh()
        #expect(panel.content == .unavailable)
        toggle.wrappedValue = false
        picker.wrappedValue = .light
        slider.wrappedValue = medium
        await source.setDevices([device])
        await manager.refresh()
        #expect(await events.next() == .read(device.id))
        await source.completeRead(SimulatorDeviceSettings())
        await manager.registry.finishReading()
        #expect(panel.content == .unavailable)
        #expect(!form.boldTextAvailable && !form.appearanceAvailable && !form.textSizeAvailable)
        #expect(toggle.wrappedValue == false && picker.wrappedValue == nil && slider.wrappedValue == 0)
        #expect(form.displayZoom == nil && form.audioOutput == nil && form.audioInput == nil)
        #expect(form.colorFilter == nil && form.locationSelection == nil)
        try await wait { !control.isEnabled }
        control.doubleValue = large
        control.sendAction(control.action, to: control.target)
        #expect(control.doubleValue == 0 && form.textSize == 0)
        toggle.wrappedValue = true
        picker.wrappedValue = .dark
        slider.wrappedValue = large
        try await manager.prepareForQuit()
        #expect(await source.writtenChanges.count == 3)
        #expect(manager.selection.device?.settings.boldText == nil)
    }

    @Test(arguments: [
        DeviceSettingChange.audioOutputDevice("systemDefault"),
        .audioInputDevice("systemDefault"),
        .displayZoom(2),
        .clearLocation,
        .locationScenario("city-bicycle"),
    ])
    func settingsPickersCanReplaceAnUnavailableSelection(_ change: DeviceSettingChange) async throws {
        let device = simulator()
        let source = ManagerModelSource(devices: [device])
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source)
        await manager.refresh()
        let panel = DeviceSettingsPanelModel(
            manager: manager, screens: DeviceScreens(model: manager),
            preferences: SimulatorPreferences(), customLocation: {}
        )
        manager.inspect(device, selectionCount: 1)
        #expect(await events.next() == .read(device.id))
        var settings = SimulatorDeviceSettings(appearance: .light)
        let systemDefault = SimulatorAudioDevice(identifier: "systemDefault", name: "System Default")
        settings.locationAvailable = true
        settings.locationMode = .scenario
        settings.locationScenario = "deleted-route"
        settings.locationScenarios = [SimulatorLocationScenario(name: "city-bicycle", displayName: "City Bicycle")]
        if case .locationScenario = change {
            settings.locationMode = nil
            settings.locationScenario = nil
        }
        settings.audioOutputDevice = "disconnected-speakers"
        settings.audioInputDevice = "disconnected-microphone"
        settings.audioOutputDevices = [systemDefault]
        settings.audioInputDevices = [systemDefault]
        settings.displayZoom = SimulatorDisplayZoomMode(rawMode: 1, nativeName: "Old Mode", width: 320, height: 640)
        settings.supportedDisplayZoomModes = [
            SimulatorDisplayZoomMode(rawMode: 2, nativeName: "Default", width: 390, height: 844)
        ]
        await source.completeRead(settings)
        await manager.registry.finishReading()
        @Bindable var form = try #require(panel.form)

        switch change {
        case .audioOutputDevice(let identifier):
            #expect(form.audioOutput == nil)
            try #require(form.audioOutputAvailable)
            $form.audioOutput.wrappedValue = identifier
            #expect(form.audioOutput == identifier)
        case .audioInputDevice(let identifier):
            #expect(form.audioInput == nil)
            try #require(form.audioInputAvailable)
            $form.audioInput.wrappedValue = identifier
            #expect(form.audioInput == identifier)
        case .displayZoom(let mode):
            #expect(form.displayZoom == nil)
            try #require(form.displayZoomAvailable)
            $form.displayZoom.wrappedValue = mode
            #expect(form.displayZoom == mode)
        case .clearLocation:
            #expect(form.locationSelection == .some(.scenario("deleted-route")))
            #expect(form.unavailableLocationScenario == "deleted-route")
            $form.locationSelection.wrappedValue = .some(.none)
            #expect(form.unavailableLocationScenario == nil)
        case .locationScenario(let name):
            #expect(form.locationSelection == nil)
            try #require(form.locationAvailable)
            $form.locationSelection.wrappedValue = .some(.scenario(name))
            #expect(form.locationSelection == .some(.scenario(name)))
        default:
            Issue.record("Unexpected setting in picker test")
        }
        #expect(await events.next() == .write(device.id))
        await source.returnOnNextRead(settings.applying(change))
        await source.completeWrite()
        try await awaitServiceOperations(manager)
        await manager.registry.finishReading()
        #expect(await source.writtenChanges == [change])
        try await manager.prepareForQuit()
    }

    @Test func aClearedSelectionLeavesAResultWithItsDevice() async throws {
        let device = simulator()
        let source = ManagerModelSource(devices: [device])
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source)
        await manager.refresh()
        manager.inspect(device, selectionCount: 1)
        #expect(await events.next() == .read(device.id))
        manager.inspect(nil, selectionCount: 0)
        await source.completeRead(settings(appearance: .dark))
        await manager.registry.finishReading()
        #expect(manager.selection.device == nil)
        #expect(manager.registry.device(for: device.id)?.settings.appearance == .dark)
        manager.inspect(device, selectionCount: 1)
        await manager.registry.finishReading()
        #expect(await source.readCount == 1)
    }

    @Test func aFailedEditIsReadBackWithoutWaitingForAChangeToAnotherGroup() async throws {
        let device = simulator()
        let source = ManagerModelSource(devices: [device])
        var events = source.events.makeAsyncIterator()
        let reported = AsyncStream<(ManagerModelSource.Failure?, Bool?, DeviceContentSize?)>.makeStream()
        var errors = reported.stream.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source)
        manager.onError = { error in
            let values = manager.selection.device?.settings
            reported.continuation.yield((error as? ManagerModelSource.Failure, values?.boldText, values?.contentSize))
        }
        await manager.refresh()
        manager.inspect(device, selectionCount: 1)
        let values = try #require(manager.selection.device?.settings)
        #expect(await events.next() == .read(device.id))
        await source.completeRead(SimulatorDeviceSettings(contentSize: .medium, boldText: false))
        await manager.registry.finishReading()

        manager.setDeviceSetting(.boldText(true), for: device.id)
        #expect(await events.next() == .write(device.id))
        manager.setDeviceSetting(.contentSize(.large), for: device.id)
        await source.failWrite()
        let failure = try #require(await errors.next())
        // Only the failed edit stops showing, and what the device did is read rather than assumed.
        #expect(failure.0 == .unavailable)
        #expect(failure.1 == false && failure.2 == .large)
        let started = [await events.next(), await events.next()]
        #expect(started.contains(.write(device.id)) && started.contains(.read(device.id)))
        await source.completeRead(SimulatorDeviceSettings(contentSize: .large, boldText: true))
        #expect(values.boldText == true && values.contentSize == .large)
        await source.returnOnNextRead(SimulatorDeviceSettings(contentSize: .large, boldText: true))
        await source.completeWrite()
        #expect(await events.next() == .read(device.id))
        await manager.registry.finishReading()
        #expect(values.boldText == true && values.contentSize == .large)
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
        manager.inspect(device, selectionCount: 1)
        let values = try #require(manager.selection.device?.settings)
        #expect(await events.next() == .read(device.id))
        await source.completeRead(SimulatorDeviceSettings(showBorders: false, reduceTransparency: false))
        await manager.registry.finishReading()

        manager.setDeviceSetting(.showBorders(true), for: device.id)
        #expect(values.showBorders == true)
        #expect(await events.next() == .write(device.id))
        manager.setDeviceSetting(.reduceTransparency(true), for: device.id)
        manager.setDeviceSetting(.showBorders(false), for: device.id)
        #expect(values.showBorders == false)
        #expect(values.reduceTransparency == true)
        await source.failWrite()
        #expect(await events.next() == .write(device.id))
        #expect(await failureEvents.next() is ManagerModelSource.Failure)
        #expect(values.showBorders == false)
        #expect(values.reduceTransparency == true)
        await source.completeWrite()
        #expect(await events.next() == .write(device.id))
        #expect(values.showBorders == false)
        #expect(values.reduceTransparency == true)
        await source.returnOnNextRead(SimulatorDeviceSettings(showBorders: false, reduceTransparency: true))
        await source.completeWrite()
        #expect(await events.next() == .read(device.id))
        await manager.registry.finishReading()
        #expect(values.showBorders == false)
        #expect(values.reduceTransparency == true)
        try await manager.quitRenderer(keepingDevicesRunning: true)
    }

    @Test(arguments: [false, true])
    func pendingEditsStayWithTheirDeviceAcrossSelectionChanges(_ fails: Bool) async throws {
        let first = simulator(deviceSet: "/first")
        let second = simulator(deviceSet: "/second")
        let source = ManagerModelSource(devices: [first, second])
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source)
        await manager.refresh()
        manager.inspect(first, selectionCount: 1)
        let firstValues = try #require(manager.selection.device?.settings)
        #expect(await events.next() == .read(first.id))
        await source.completeRead(SimulatorDeviceSettings(showBorders: false))
        await manager.registry.finishReading()
        manager.setDeviceSetting(.showBorders(true), for: first.id)
        #expect(await events.next() == .write(first.id))

        manager.inspect(second, selectionCount: 1)
        let secondValues = try #require(manager.selection.device?.settings)
        #expect(secondValues.showBorders == nil && firstValues.showBorders == true)
        #expect(await events.next() == .read(second.id))
        if fails { await source.failWrite() }
        else { await source.completeWrite() }
        // A device nothing shows still confirms what it was asked to change.
        #expect(await events.next() == .read(first.id))
        await source.completeRead(SimulatorDeviceSettings(showBorders: false), for: second.id)
        await source.completeRead(SimulatorDeviceSettings(showBorders: true), for: first.id)
        await manager.registry.finishReading()
        #expect(secondValues.showBorders == false)

        manager.inspect(first, selectionCount: 1)
        await manager.registry.finishReading()
        #expect(firstValues.showBorders == true)
        #expect(await source.readCount == 3)
        try await manager.quitRenderer(keepingDevicesRunning: true)
    }
}
