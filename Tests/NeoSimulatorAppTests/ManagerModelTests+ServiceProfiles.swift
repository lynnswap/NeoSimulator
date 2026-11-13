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
    @Test func changingProfileCapabilityClearsTheOldKindEvenWhenTheRefreshFails() async throws {
        _ = NSApplication.shared
        func device(features: Set<String>) -> InventoryDevice { inspectedRemote(features: features) }
        let original = device(features: ["provisioningprofiles", "configurationprofiles"])
        let source = ManagerModelSource(devices: [], inspectorResponse:
            #"{"result":{"provisioningProfiles":[{"uuid":"fixture.profile","name":"Fixture"}]}}"#)
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
        controller.inspection.select(.provisioning)
        try show(original)
        #expect(await events.next() == .inspect(original.id))
        await finishInspectorRead(controller.inspection)
        let views = inspectorViews(controller.view)
        let table = try #require(views.compactMap { $0 as? NSTableView }.first {
            $0.accessibilityLabel() == "Installed Applications, Profiles, and Reports"
        })
        try await wait(timeout: .seconds(5)) {
            table.numberOfRows == 1
        }
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let remove = try #require(views.compactMap { $0 as? NSButton }.first { $0.toolTip == "Remove…" })
        try #require(remove.isEnabled)

        await source.holdInspectorReads()
        try show(device(features: ["configurationprofiles"]))
        #expect(controller.inspection.content == .configuration)
        #expect(table.numberOfRows == 0 && table.selectedRow == -1)
        #expect(controller.inspection.profiles.isEmpty)
        #expect(controller.inspection.device?.inspection.status(of: .provisioningProfiles) == .unsupported)
        #expect(await events.next() == .inspect(original.id))
        await source.failInspectorRead()
        await finishInspectorRead(controller.inspection)
        let status = try #require(views.compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "Inspector Status" })
        try await wait(timeout: .seconds(5)) {
            status.stringValue.contains("Unavailable")
        }
        #expect(table.numberOfRows == 0 && table.selectedRow == -1)
        #expect(!remove.isEnabled)
        controller.stopReading()
    }

    @Test func serviceProfilesMigrateToFileWithoutChangingIDsNamesOrOverrides() throws {
        let domain = "NeoSimulator.ProfileFileMigration.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        let fileURL = serviceProfileURL(domain)
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        }
        let first = ServiceProfile.Record(id: UUID(), name: "Development", configuration: ServiceConfiguration())
        let second = ServiceProfile.Record(id: UUID(), name: "Development",
            configuration: ServiceConfiguration(disabledLabels: ["com.apple.searchd"]))
        let device = simulator(deviceSet: "/custom-set").id
        let unchosen = simulator(deviceSet: "/unchosen-set").id
        let pendingDefault = simulator(deviceSet: "/pending-default").id
        let data = try JSONEncoder().encode(LegacyServiceProfiles(profiles: [first, second], devices: [
            device: .init(profileID: second.id, base: ServiceConfiguration(disabledLabels: ["com.apple.searchtoold"]),
                          overrides: ["com.apple.searchd": true], requestID: UUID(), pendingApplication: true),
                    unchosen: .init(
                        profileID: ServiceProfile.allServicesID, base: ServiceConfiguration(),
                            overrides: ["com.apple.searchd": false], requestID: UUID(), pendingApplication: false),
                    pendingDefault: .init(
                        profileID: ServiceProfile.allServicesID, base: ServiceConfiguration(),
                                  overrides: [:], requestID: UUID(), pendingApplication: true),
        ]))
        defaults.set(data, forKey: ServiceProfileStore.defaultsKey)

        let store = ServiceProfileStore(fileURL: fileURL, legacyDefaults: defaults)
        #expect(store.issue == nil)
        #expect(defaults.data(forKey: ServiceProfileStore.defaultsKey) == nil)
        #expect(try Data(contentsOf: fileURL) == data)
        #expect(store.profiles.map(\.id) == [first.id, second.id])
        #expect(store.profiles.map(\.name) == ["Development", "Development"])
        let binding = DeviceServiceProfile(selection: .profile(second.id), overrides: ["com.apple.searchd": true])
        #expect(store.binding(for: device) == binding)
        // The saved copy of the profile gives way to its definition.
        #expect(store.configuration(for: device)?.disabledLabels == [])
        // Unnamed choices now use All Services, retaining their explicit overrides.
        #expect(store.binding(for: unchosen) == DeviceServiceProfile(selection: .inheritDefault, overrides: ["com.apple.searchd": false]))
        #expect(store.defaultProfileID == ServiceProfile.allServicesID)
        #expect(store.configuration(for: unchosen)?.disabledLabels == ["com.apple.searchd"])
        #expect(store.selection(for: pendingDefault) == .profile(ServiceProfile.allServicesID))
        #expect(store.configuration(for: pendingDefault) == ServiceConfiguration())
        #expect(store.availableProfiles.first === store.allServices)
        defaults.set(Data("obsolete".utf8), forKey: ServiceProfileStore.defaultsKey)
        let restored = ServiceProfileStore(fileURL: fileURL, legacyDefaults: defaults)
        #expect(restored.issue == nil && restored.binding(for: device) == binding)
        #expect(restored.profiles.map(\.id) == [first.id, second.id])
        try restored.setDefaultProfile(first.id)
        let rewritten = ServiceProfileStore(fileURL: fileURL, legacyDefaults: nil)
        #expect(rewritten.issue == nil && rewritten.binding(for: device) == binding)
        #expect(rewritten.defaultProfile.id == first.id)
    }

    @Test(arguments: [false, true])
    func failedProfileFileMigrationPreservesDataUntilItCanBeRecovered(blockedDirectory: Bool) throws {
        let domain = "NeoSimulator.ProfileFileFailure.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        let fileURL = serviceProfileURL(domain)
        let directory = fileURL.deletingLastPathComponent()
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: directory)
        }
        let record = ServiceProfile.Record(id: UUID(), name: "Saved", configuration: ServiceConfiguration())
        let data = try JSONEncoder().encode(LegacyServiceProfiles(profiles: [record], devices: [:]))
        defaults.set(data, forKey: ServiceProfileStore.defaultsKey)
        if blockedDirectory {
            try Data("not a directory".utf8).write(to: directory)
        } else {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("corrupt".utf8).write(to: fileURL)
        }
        let store = ServiceProfileStore(fileURL: fileURL, legacyDefaults: defaults)
        #expect(store.issue != nil && store.profiles.isEmpty)
        #expect(store.configuration(for: simulator().id) == nil)
        do {
            try store.create(name: "Must Not Replace Saved Data", configuration: ServiceConfiguration())
            Issue.record("A failed read must prevent overwriting saved profiles")
        } catch {}
        #expect(defaults.data(forKey: ServiceProfileStore.defaultsKey) == data)
        if !blockedDirectory { #expect(try Data(contentsOf: fileURL) == Data("corrupt".utf8)) }
        try FileManager.default.removeItem(at: directory)
        store.reload()
        #expect(store.issue == nil && store.profiles.map(\.id) == [record.id])
        #expect(defaults.data(forKey: ServiceProfileStore.defaultsKey) == nil)
    }

    @Test func draggingServiceProfilesPersistsOrderAndKeepsSelectionAndIdentity() async throws {
        let domain = "NeoSimulator.ProfileOrder.\(UUID().uuidString)"
        let fileURL = serviceProfileURL(domain)
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = ServiceProfileStore(fileURL: fileURL, legacyDefaults: nil)
        let first = try store.create(name: "First", configuration: ServiceConfiguration())
        let second = try store.create(name: "Second", configuration: ServiceConfiguration())
        let third = try store.create(name: "Third", configuration: ServiceConfiguration())
        let controller = ServiceProfilesSettingsViewController(store: store)
        controller.model.selectedProfileID = second.id
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.close() }
        let table = try #require(
            inspectorViews(controller.view).compactMap { $0 as? NSTableView }
                .first { $0.accessibilityLabel() == "Service Profiles" })
        let accessory = try #require(controller.splitViewItems.first?.topAlignedAccessoryViewControllers.first)
        let defaultMenu = try #require(inspectorViews(accessory.view).compactMap { $0 as? NSPopUpButton }.first)
        // Built-in profiles drag out as files, but stay at the top.
        for row in 0..<2 {
            let builtIn = TestDraggingInfo(
                item: try #require(controller.tableView(table, pasteboardWriterForRow: row)), source: table)
        defer { builtIn.draggingPasteboard.releaseGlobally() }
        #expect(
            controller.tableView(table, validateDrop: builtIn, proposedRow: 2, proposedDropOperation: .above).isEmpty)
        }
        let writer = try #require(controller.tableView(table, pasteboardWriterForRow: 4))
        let drag = TestDraggingInfo(item: writer, source: table)
        defer { drag.draggingPasteboard.releaseGlobally() }
        #expect(controller.tableView(table, validateDrop: drag, proposedRow: 1, proposedDropOperation: .above) == .move)
        #expect(!controller.tableView(table, acceptDrop: drag, row: 1, dropOperation: .above))
        #expect(controller.tableView(table, acceptDrop: drag, row: 2, dropOperation: .above))
        try await wait(timeout: .seconds(5)) {
            table.selectedRow == 4
        }
        #expect(store.profiles.map(\.id) == [third.id, first.id, second.id])
        #expect(controller.model.selectedProfile === second && store.profiles.first === third)
        let manager = SimulatorManagerModel(source: ManagerModelSource(devices: []), serviceProfiles: store)
        let inspector = BackgroundServicesInspectorModel(manager: manager, showProfileSettings: { _ in })
        #expect(inspector.defaultProfileChoice.id == .inheritDefault)
        #expect(inspector.defaultProfileChoice.title == "Use Default: All Services")
        defaultMenu.selectItem(withTitle: "Third")
        #expect(NSApp.sendAction(try #require(defaultMenu.action), to: defaultMenu.target, from: defaultMenu))
        #expect(inspector.defaultProfileChoice.title == "Use Default: Third")
        #expect(controller.model.selectedProfile === second)
        #expect(
            inspector.profileChoices.map(\.id) == [
                .profile(ServiceProfile.allServicesID), .profile(ServiceProfile.minimalID), .profile(third.id),
                .profile(first.id), .profile(second.id),
            ])

        let downwardWriter = try #require(controller.tableView(table, pasteboardWriterForRow: 3))
        let downward = TestDraggingInfo(item: downwardWriter, source: table)
        defer { downward.draggingPasteboard.releaseGlobally() }
        #expect(controller.tableView(table, acceptDrop: downward, row: 5, dropOperation: .above))
        let restored = ServiceProfileStore(fileURL: fileURL, legacyDefaults: nil)
        #expect(restored.profiles.map(\.id) == [third.id, second.id, first.id])
        #expect(controller.model.selectedProfile === second)
        drag.draggingSource = nil
        #expect(controller.tableView(table, validateDrop: drag, proposedRow: 1, proposedDropOperation: .above).isEmpty)

        try store.update(first.id, name: store.allServices.name, configuration: first.configuration)
        try store.update(third.id, name: store.allServices.name, configuration: third.configuration)
        try await wait(timeout: .seconds(5)) {
            defaultMenu.itemArray.compactMap { $0.representedObject as? UUID } == store.availableProfiles.map(\.id)
                && defaultMenu.itemTitles == store.availableProfiles.map(\.name)
        }
        let choice = try #require(defaultMenu.itemArray.first { $0.representedObject as? UUID == first.id })
        defaultMenu.select(choice)
        #expect(NSApp.sendAction(try #require(defaultMenu.action), to: defaultMenu.target, from: defaultMenu))
        #expect(store.defaultProfile === first)
    }

    @Test func serviceProfilesDragOutAsFilesThatUpdateTheSameProfileWhenDroppedBack() async throws {
        let domain = "NeoSimulator.ProfileFileDrags.\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appending(path: domain, directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: serviceProfileURL(domain).deletingLastPathComponent())
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = ServiceProfileStore(fileURL: serviceProfileURL(domain), legacyDefaults: nil)
        let search = ServiceConfiguration(disabledLabels: ["com.apple.searchd"])
        let profile = try store.create(name: "Search: Off", configuration: search)
        let controller = ServiceProfilesSettingsViewController(store: store)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520), styleMask: [.titled, .resizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let table = try #require(
            inspectorViews(controller.view).compactMap { $0 as? NSTableView }
                .first { $0.accessibilityLabel() == "Service Profiles" })
        try await wait(timeout: .seconds(5)) { table.numberOfRows == 3 }

        // Control-clicking the built-in profile offers to export it, but not to rename it.
        let row = table.rect(ofRow: 0)
        let click = try #require(
            NSEvent.mouseEvent(
                with: .rightMouseDown, location: table.convert(NSPoint(x: row.midX, y: row.midY), to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1))
        let menu = try #require(table.menu(for: click))
        controller.menuNeedsUpdate(menu)
        #expect(menu.items.map(\.title) == ["Duplicate", "Export…"])

        // A profile drags out as a file named after it, with what it had when the drag started.
        let promise = try #require(controller.tableView(table, pasteboardWriterForRow: 2) as? NSFilePromiseProvider)
        let delegate = try #require(promise.delegate)
        let name = delegate.filePromiseProvider(promise, fileNameForType: promise.fileType)
        #expect(name == "Search- Off.json")
        try store.update(profile.id, name: "Renamed", configuration: ServiceConfiguration())
        func write(to url: URL) async -> (any Error)? {
            await withCheckedContinuation { written in
                delegate.filePromiseProvider(promise, writePromiseTo: url) { written.resume(returning: $0) }
            }
        }
        // A file that the destination already has stays as it is.
        let existing = directory.appending(path: "Existing.json")
        try Data("kept".utf8).write(to: existing)
        let refusal = await write(to: existing)
        #expect(try refusal != nil && Data(contentsOf: existing) == Data("kept".utf8))
        let file = directory.appending(path: name)
        #expect(await write(to: file) == nil)

        // Cancelling a replacement leaves the profile and selection untouched.
        let saved = try Data(contentsOf: store.fileURL)
        let selection = controller.model.selectedProfileID
        let cancelled = TestDraggingInfo([file])
        defer { cancelled.draggingPasteboard.releaseGlobally() }
        #expect(controller.tableView(table, acceptDrop: cancelled, row: -1, dropOperation: .on))
        try await wait(timeout: .seconds(5)) { window.attachedSheet != nil }
        let confirmation = try #require(window.attachedSheet)
        let confirmationContent = try #require(confirmation.contentView)
        let replace = try #require(
            inspectorViews(confirmationContent).compactMap { $0 as? NSButton }.first {
                $0.title == "Replace"
            })
        #expect(replace.hasDestructiveAction && replace.keyEquivalent.isEmpty)
        let cancel = try #require(
            inspectorViews(confirmationContent).compactMap { $0 as? NSButton }.first {
                $0.title == "Cancel"
            })
        #expect(cancel.keyEquivalent == "\u{1b}")
        window.endSheet(confirmation, returnCode: .alertSecondButtonReturn)
        try await wait(timeout: .seconds(5)) { window.attachedSheet == nil }
        #expect(try Data(contentsOf: store.fileURL) == saved && controller.model.selectedProfileID == selection)

        // Dropping the file updates the same profile after confirmation; only profile files drop.
        let notes = directory.appending(path: "Notes.txt")
        try Data().write(to: notes)
        for (url, operation) in [(notes, NSDragOperation()), (file, .copy)] {
            let drop = TestDraggingInfo([url])
            defer { drop.draggingPasteboard.releaseGlobally() }
            #expect(
                controller.tableView(table, validateDrop: drop, proposedRow: 1, proposedDropOperation: .above)
                    == operation)
            #expect(controller.tableView(table, acceptDrop: drop, row: -1, dropOperation: .on) == !operation.isEmpty)
        }
        try await wait(timeout: .seconds(5)) { window.attachedSheet != nil }
        window.endSheet(try #require(window.attachedSheet), returnCode: .alertFirstButtonReturn)
        try await wait(timeout: .seconds(5)) { profile.name == "Search: Off" && profile.configuration == search }
        let imported = try #require(store.profiles.last)
        #expect(store.profiles.count == 1 && imported === profile)
        #expect(controller.model.selectedProfile === imported)
    }

    @Test func serviceProfilesKeepOverridesAcrossRelaunchAndClearThemOnSelection() throws {
        let domain = "NeoSimulator.ServiceProfiles.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: serviceProfileURL(domain).deletingLastPathComponent())
        }
        let store = ServiceProfileStore(fileURL: serviceProfileURL(domain), legacyDefaults: defaults)
        let first = simulator(deviceSet: "/first").id
        let second = simulator(deviceSet: "/second").id
        let label = "com.apple.searchd"
        let slim = try store.create(name: "Slim", configuration: ServiceConfiguration(disabledLabels: [label]))
        let full = try store.create(name: "Full", configuration: ServiceConfiguration())
        try store.assign(.profile(slim.id), to: first)
        try store.assign(.profile(slim.id), to: second)
        try store.record([.service(label)], enabled: true, for: first, productFamily: "iPhone")
        let restored = ServiceProfileStore(fileURL: serviceProfileURL(domain), legacyDefaults: defaults)
        #expect(restored.profiles.map(\.id) == store.profiles.map(\.id))
        #expect(restored.profiles.map(\.name) == store.profiles.map(\.name))
        #expect(restored.profiles.map(\.configuration) == store.profiles.map(\.configuration))
        #expect(restored.configuration(for: first)?.disabledLabels == [])
        #expect(restored.configuration(for: second)?.disabledLabels == [label])
        try restored.record([.service(label)], enabled: false, for: first, productFamily: "iPhone")
        #expect(restored.configuration(for: first) == slim.configuration)
        #expect(restored.binding(for: first)?.overrides.isEmpty == true)
        try restored.assign(.profile(full.id), to: first)
        #expect(restored.binding(for: first)?.overrides.isEmpty == true)
        try restored.assign(.profile(slim.id), to: first)
        #expect(restored.configuration(for: first)?.disabledLabels == [label])
    }

    @Test func devicesInheritTheCommonProfileBelowTheirOverridesUntilTheyChooseOtherwise() throws {
        let domain = "NeoSimulator.CommonServiceProfile.\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: serviceProfileURL(domain).deletingLastPathComponent()) }
        let store = ServiceProfileStore(fileURL: serviceProfileURL(domain), legacyDefaults: nil)
        let device = simulator().id
        let label = "com.apple.searchd"
        let other = "com.apple.searchtoold"
        #expect(store.defaultProfile === store.allServices && store.selection(for: device) == .inheritDefault)
        #expect(store.defaultProfile.name == "All Services")

        // All Services is the default; an individual change stays an inherited override.
        try store.record([.service(label)], enabled: false, for: device, productFamily: "iPhone")
        #expect(store.binding(for: device) == DeviceServiceProfile(selection: .inheritDefault, overrides: [label: false]))
        #expect(store.resolvedProfile(for: device) === store.allServices)
        #expect(store.configuration(for: device)?.disabledLabels == [label])

        let common = try store.create(name: "Common", configuration: ServiceConfiguration())
        try store.setDefaultProfile(common.id)
        #expect(store.resolvedProfile(for: device) === common)
        #expect(store.configuration(for: device)?.disabledLabels == [label])

        // Returning a switch to the profile removes its override and follows later profile edits.
        try store.record([.service(other)], enabled: true, for: device, productFamily: "iPhone")
        try store.update(common.id, configuration: ServiceConfiguration(disabledLabels: [other]))
        #expect(store.configuration(for: device)?.disabledLabels == [label, other])

        let oldSelection = try JSONSerialization.data(withJSONObject: [
            "selection": ["doNotApply": [:]], "overrides": [label: false],
        ])
        let inherited = try JSONDecoder().decode(DeviceServiceProfile.self, from: oldSelection)
        #expect(inherited == DeviceServiceProfile(selection: .inheritDefault, overrides: [label: false]))

        // A named profile is independent of the app-wide default.
        let named = try store.create(name: "Named", configuration: ServiceConfiguration())
        try store.setDefaultProfile(ServiceProfile.allServicesID)
        try store.assign(.profile(named.id), to: device)
        #expect(store.configuration(for: device)?.disabledLabels == [])

        try store.setDefaultProfile(common.id)
        try store.assign(.inheritDefault, to: device)
        let restored = ServiceProfileStore(fileURL: serviceProfileURL(domain), legacyDefaults: nil)
        #expect(restored.defaultProfile.id == common.id)
        #expect(restored.selection(for: device) == .inheritDefault)
        #expect(restored.configuration(for: device)?.disabledLabels == [other])

        // Saving the changes into what the device inherits leaves it inheriting. Into another profile, it chooses that one.
        try restored.update(named.id, configuration: ServiceConfiguration(disabledLabels: [label]), assigningTo: device)
        #expect(restored.binding(for: device) == DeviceServiceProfile(selection: .profile(named.id)))
        try restored.assign(.inheritDefault, to: device)
        try restored.update(common.id, configuration: ServiceConfiguration(disabledLabels: [label]), assigningTo: device)
        #expect(restored.binding(for: device) == DeviceServiceProfile(selection: .inheritDefault))
        #expect(restored.configuration(for: device)?.disabledLabels == [label])
    }

    @Test func editingAProfileReachesDevicesThatUseItAndDeletingItReturnsThemToInheriting() async throws {
        let domain = "NeoSimulator.ServiceProfileUpdates.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: serviceProfileURL(domain).deletingLastPathComponent())
        }
        let store = ServiceProfileStore(fileURL: serviceProfileURL(domain), legacyDefaults: defaults)
        let device = simulator().id
        let profile = try store.create(name: "Development", configuration: ServiceConfiguration())
        try store.assign(.profile(profile.id), to: device)
        try store.record([.service("com.apple.searchtoold")], enabled: false, for: device, productFamily: "iPhone")
        try store.setDefaultProfile(profile.id)
        let settings = ServiceProfilesSettingsModel(store: store)
        settings.selectedProfileID = profile.id
        let changes = AsyncStream<Void>.makeStream()
        var change = changes.stream.makeAsyncIterator()
        withObservationTracking { _ = profile.configuration } onChange: { changes.continuation.yield() }
        profile.setServices([.service("com.apple.searchd")], enabled: false)
        _ = await change.next()
        #expect(settings.selectedProfile === profile && store.profile(profile.id) === profile)
        #expect(profile.configuration.disabledLabels == ["com.apple.searchd"])
        store.reload()
        #expect(settings.selectedProfile === profile)
        #expect(store.configuration(for: device)?.disabledLabels == ["com.apple.searchd", "com.apple.searchtoold"])
        try store.delete(profile.id)
        #expect(store.defaultProfileID == ServiceProfile.allServicesID && store.profiles.isEmpty)
        #expect(store.binding(for: device) == DeviceServiceProfile(selection: .inheritDefault, overrides: ["com.apple.searchtoold": false]))
        #expect(store.configuration(for: device)?.disabledLabels == ["com.apple.searchtoold"])
    }

    @Test func individualChangesKeepInheritingAndSavingThemAssignsTheNewProfile() throws {
        let domain = "NeoSimulator.DefaultServiceProfile.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: serviceProfileURL(domain).deletingLastPathComponent())
        }
        let store = ServiceProfileStore(fileURL: serviceProfileURL(domain), legacyDefaults: defaults)
        let device = simulator().id
        let label = "com.apple.searchd"
        #expect(store.profile(ServiceProfile.allServicesID)?.configuration.disabledLabels.isEmpty == true)
        #expect(store.availableProfiles.map(\.id) == [ServiceProfile.allServicesID, ServiceProfile.minimalID])
        try store.record([.service(label)], enabled: false, for: device, productFamily: "iPhone")
        let changed = try #require(store.binding(for: device))
        #expect(changed.selection == .inheritDefault)
        #expect(changed.overrides == [label: false])
        let saved = try store.create(name: "Focused", configuration: ServiceConfiguration().applying(changed.overrides), assigningTo: device)
        let restored = ServiceProfileStore(fileURL: serviceProfileURL(domain), legacyDefaults: defaults)
        #expect(restored.binding(for: device) == DeviceServiceProfile(selection: .profile(saved.id)))
        #expect(restored.configuration(for: device)?.disabledLabels == [label])
        try restored.assign(.profile(ServiceProfile.allServicesID), to: device)
        #expect(restored.configuration(for: device)?.disabledLabels.isEmpty == true)
        #expect(restored.binding(for: device)?.overrides.isEmpty == true)
        #expect(restored.profile(saved.id)?.configuration.disabledLabels == [label])
    }

    @Test func savingAnExistingProfileUpdatesItsDefinitionAndKeepsOtherDevicesOverrides() throws {
        let domain = "NeoSimulator.OverwriteServiceProfile.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: serviceProfileURL(domain).deletingLastPathComponent())
        }
        let store = ServiceProfileStore(fileURL: serviceProfileURL(domain), legacyDefaults: defaults)
        let first = simulator(deviceSet: "/first").id
        let second = simulator(deviceSet: "/second").id
        let profile = try store.create(name: "Development", configuration: ServiceConfiguration())
        try store.assign(.profile(profile.id), to: first)
        try store.assign(.profile(profile.id), to: second)
        try store.record([.service("com.apple.searchd")], enabled: false, for: first, productFamily: "iPhone")
        try store.record([.service("com.apple.searchtoold")], enabled: false, for: first, productFamily: "iPhone")
        try store.record([.service("com.apple.searchtoold")], enabled: false, for: second, productFamily: "iPhone")
        let other = try #require(store.binding(for: second))
        let current = try #require(store.configuration(for: first))

        try store.update(profile.id, configuration: current, assigningTo: first)
        let restored = ServiceProfileStore(fileURL: serviceProfileURL(domain), legacyDefaults: defaults)
        #expect(restored.profiles.count == 1)
        #expect(restored.profile(profile.id)?.name == "Development")
        #expect(restored.profile(profile.id)?.configuration == current)
        #expect(restored.binding(for: first) == DeviceServiceProfile(selection: .profile(profile.id)))
        #expect(restored.configuration(for: first) == current)
        #expect(restored.binding(for: second) == other)
        #expect(restored.configuration(for: second) == current)

        try restored.assign(.profile(profile.id), to: second)
        #expect(restored.configuration(for: second) == current)
        #expect(restored.binding(for: second)?.overrides.isEmpty == true)
    }

    @Test(arguments: [false, true])
    func profileEditsApplyToRunningFollowersAndKeepTheirIndividualOverrides(managingFollower: Bool) async throws {
        let domain = "NeoSimulator.FollowingServiceProfile.\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: serviceProfileURL(domain).deletingLastPathComponent()) }
        let store = ServiceProfileStore(fileURL: serviceProfileURL(domain), legacyDefaults: nil)
        let label = "com.apple.searchd"
        let other = "com.apple.searchtoold"
        let profile = try store.create(name: "Development", configuration: ServiceConfiguration())
        try store.setDefaultProfile(profile.id)
        let first = simulator(deviceSet: "/first")
        let second = simulator(deviceSet: "/second")
        let stopped = simulator(deviceSet: "/stopped", state: "Shutdown")
        let independent = simulator(deviceSet: "/independent")
        try store.assign(.profile(profile.id), to: first.id)
        try store.record([.service(other)], enabled: false, for: first.id, productFamily: "iPhone")
        try store.assign(.profile(store.allServices.id), to: independent.id)
        let source = ManagerModelSource(devices: [first, second, stopped, independent])
        await source.skipSettingsReads()
        await source.holdServiceReads()
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source, serviceProfiles: store)
        var applicationFailure: (any Error)?
        manager.onError = { applicationFailure = $0 }
        await manager.refresh()
        let firstServices = try #require(manager.registry.device(for: first.id)?.backgroundServices)
        let secondServices = try #require(manager.registry.device(for: second.id)?.backgroundServices)
        let rename = DeviceManagementAction.rename("Renamed")
        if managingFollower {
            await source.holdManagement()
            manager.manage(rename, devices: [first])
            #expect(await events.next() == .manage(rename, [first.id]))
        }

        // Settings changes the same definition that the inspector saves.
        profile.setServices([.service(label)], enabled: false)
        #expect(firstServices.isChanging == !managingFollower && secondServices.isChanging)
        #expect(manager.registry.device(for: stopped.id)?.backgroundServices.isChanging == false)
        #expect(manager.registry.device(for: independent.id)?.backgroundServices.isChanging == false)
        #expect(store.binding(for: first.id)?.overrides == [other: false])
        #expect(store.configuration(for: stopped.id)?.disabledLabels == [label])
        if managingFollower {
            await source.completeManagement(rename)
            try await wait(timeout: .seconds(5)) { firstServices.isChanging }
        }
        if firstServices.isChanging && secondServices.isChanging {
            let reads = [await events.next(), await events.next()]
            #expect(reads.contains(.readServices(first.id)) && reads.contains(.readServices(second.id)))
            for device in [first, second] {
                await source.completeServiceRead(disabled: [], for: device.id)
                #expect(await events.next() == .changeServices(device.id))
                if device.id == first.id {
                    await source.completeServiceChange(disabled: [label, other])
                } else {
                    await source.failServiceChange(disabled: [])
                }
            }
            try await awaitServiceOperations(manager)
            #expect(firstServices.configuration?.disabledLabels == [label, other])
            #expect(secondServices.configuration?.disabledLabels == [] && applicationFailure == nil)
            #expect(manager.backgroundIssue(for: second.id)?.contains(second.name) == true)
            let inspector = BackgroundServicesInspectorModel(manager: manager, showProfileSettings: { _ in })
            manager.inspect(second, selectionCount: 1)
            manager.selection.setServicesVisible(true)
            #expect(await events.next() == .readServices(second.id))
            await source.completeServiceRead(disabled: [])
            await manager.registry.finishReading()
            #expect(inspector.hasProfileChanges && !inspector.canSaveProfile && inspector.canRevertProfile)
            inspector.saveProfile()
            #expect(profile.configuration.disabledLabels == [label])
            inspector.revertProfile()
            #expect(await events.next() == .readServices(second.id))
            await source.completeServiceRead(disabled: [])
            #expect(await events.next() == .changeServices(second.id))
            await source.completeServiceChange(disabled: [label])
            try await awaitServiceOperations(manager)
            #expect(!inspector.hasProfileChanges && manager.backgroundIssue(for: second.id) == nil)
        }
        try await manager.prepareForQuit()
    }

    @Test(arguments: [false, true])
    func savingProfileChangesUsesTheLatestDefinitionInsteadOfStaleDeviceState(stopped: Bool) async throws {
        let domain = "NeoSimulator.StaleServiceProfileSave.\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: serviceProfileURL(domain).deletingLastPathComponent()) }
        let store = ServiceProfileStore(fileURL: serviceProfileURL(domain), legacyDefaults: nil)
        let label = "com.apple.searchd"
        let other = "com.apple.searchtoold"
        let profile = try store.create(
            name: "Development", configuration: ServiceConfiguration(disabledLabels: [label]))
        let device = simulator()
        try store.assign(.profile(profile.id), to: device.id)
        try store.record([.service(other)], enabled: false, for: device.id, productFamily: "iPhone")
        let source = ManagerModelSource(devices: [device])
        await source.skipSettingsReads()
        await source.holdServiceReads()
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source, serviceProfiles: store)
        await manager.refresh()
        manager.inspect(device, selectionCount: 1)
        manager.selection.setServicesVisible(true)
        #expect(await events.next() == .readServices(device.id))
        // Opening NeoSimulator leaves an already-running simulator unchanged.
        await source.completeServiceRead(disabled: [])
        await manager.registry.finishReading()
        if stopped {
            await source.setDevices([simulator(state: "Shutdown")])
            await manager.refresh()
        }
        let inspector = BackgroundServicesInspectorModel(manager: manager, showProfileSettings: { _ in })
        #expect(inspector.canSaveProfile)
        inspector.saveProfile()
        #expect(profile.configuration.disabledLabels == [label, other])
        #expect(store.binding(for: device.id)?.overrides.isEmpty == true)
        #expect(!inspector.canSaveProfile && inspector.hasProfileChanges == !stopped)
        // A stale readback without individual edits must not replace the shared definition.
        inspector.saveProfile()
        #expect(profile.configuration.disabledLabels == [label, other])
        try await manager.prepareForQuit()
    }

    @Test(arguments: [false, true])
    func catalogEditsDoNotReapplyTheirFollowersOtherServices(renaming: Bool) async throws {
        let domain = "NeoSimulator.RemovedProfileService.\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: serviceProfileURL(domain).deletingLastPathComponent()) }
        let store = ServiceProfileStore(fileURL: serviceProfileURL(domain), legacyDefaults: nil)
        let category = try store.createCategory(named: "Agents")
        let custom = try store.addService("com.example.agent", to: category)
        let other = "com.apple.searchd"
        let profile = try store.create(
            name: "Development", configuration: ServiceConfiguration(disabledLabels: [custom, other]))
        try store.setDefaultProfile(profile.id)
        let device = simulator()
        let source = ManagerModelSource(devices: [device])
        await source.holdServiceReads()
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source, serviceProfiles: store)
        await manager.refresh()
        let services = try #require(manager.registry.device(for: device.id)?.backgroundServices)

        let renamed = "com.example.renamed"
        if renaming {
            try store.updateService(custom, in: category, label: renamed, summary: "")
        } else {
            try store.removeServices([custom], from: category)
        }
        let expected: Set<String> = renaming ? [renamed, other] : [other]
        #expect(profile.configuration.disabledLabels == expected)
        if services.isChanging {
            #expect(await events.next() == .readServices(device.id))
            await source.completeServiceRead(disabled: [])
            #expect(await events.next() == .changeServices(device.id))
            await source.completeServiceChange(disabled: expected)
            try await awaitServiceOperations(manager)
        }
        #expect(await source.serviceChanges.isEmpty)
        try await manager.prepareForQuit()
    }

    @Test func profileEditsApplyEvenWhenStaleReadbackAlreadyMatchesTheNewDefinition() async throws {
        let domain = "NeoSimulator.StaleProfileFollower.\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: serviceProfileURL(domain).deletingLastPathComponent()) }
        let store = ServiceProfileStore(fileURL: serviceProfileURL(domain), legacyDefaults: nil)
        let profile = try store.create(name: "Development", configuration: ServiceConfiguration())
        try store.setDefaultProfile(profile.id)
        let label = "com.apple.searchd"
        let device = simulator()
        let source = ManagerModelSource(devices: [device])
        await source.skipSettingsReads()
        await source.holdServiceReads()
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source, serviceProfiles: store)
        await manager.refresh()
        manager.inspect(device, selectionCount: 1)
        manager.selection.setServicesVisible(true)
        #expect(await events.next() == .readServices(device.id))
        await source.completeServiceRead(disabled: [label])
        await manager.registry.finishReading()
        let services = try #require(manager.registry.device(for: device.id)?.backgroundServices)
        let inspector = BackgroundServicesInspectorModel(manager: manager, showProfileSettings: { _ in })
        inspector.requestRefresh()
        #expect(await events.next() == .readServices(device.id))
        await source.failServiceRead()
        await manager.registry.finishReading()
        #expect(services.configuration?.disabledLabels == [label] && inspector.issue != nil)

        profile.setServices([.service(label)], enabled: false)
        #expect(services.isChanging)
        if services.isChanging {
            #expect(await events.next() == .readServices(device.id))
            // Another client has enabled the service since the last successful read.
            await source.completeServiceRead(disabled: [])
            #expect(await events.next() == .changeServices(device.id))
            await source.completeServiceChange(disabled: [label])
            try await awaitServiceOperations(manager)
            #expect(!inspector.hasProfileChanges && inspector.issue == nil)
        }
        try await manager.prepareForQuit()
    }

    @Test func saveServiceProfileFollowsTheManagerResponderChain() async throws {
        _ = NSApplication.shared
        let domain = "NeoSimulator.SaveProfileShortcut.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: serviceProfileURL(domain).deletingLastPathComponent())
        }
        let device = simulator()
        let store = ServiceProfileStore(fileURL: serviceProfileURL(domain), legacyDefaults: defaults)
        let profile = try store.create(name: "Development", configuration: ServiceConfiguration())
        try store.assign(.profile(profile.id), to: device.id)
        let source = ManagerModelSource(devices: [device])
        await source.skipSettingsReads()
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source, serviceProfiles: store)
        await manager.refresh()
        let app = AppDelegate(makeLicenses: SettingsPreview.licenses)
        app.model = manager
        let main = app.prepareMainWindow(defaults: defaults)
        let window = try #require(main.window)
        window.setFrameAutosaveName("")
        defer { window.close() }
        let previousMenus = (NSApp.mainMenu, NSApp.windowsMenu, NSApp.servicesMenu)
        defer {
            NSApp.mainMenu = previousMenus.0
            NSApp.windowsMenu = previousMenus.1
            NSApp.servicesMenu = previousMenus.2
        }
        app.installMenu()
        let menu = try #require(NSApp.mainMenu)
        let file = try #require(menu.items.first { $0.title == "File" }?.submenu)
        let save = try #require(
            file.items.first { $0.action == #selector(ManagerWindowController.saveServiceProfile(_:)) })
        #expect(save.keyEquivalent == "s" && save.keyEquivalentModifierMask == .command && save.target == nil)
        let screenshot = try #require(
            file.items.first { $0.action == #selector(RemoteDeviceWindowController.saveScreenshot(_:)) })
        #expect(screenshot.keyEquivalent.isEmpty)
        main.selectDevice(device.id)
        let inspector = main.inspectorController.model
        inspector.toggle(.services)
        await manager.registry.finishReading()
        let services = inspector.services
        #expect(!main.validateMenuItem(save))
        services.setServices([.service("com.apple.searchd")], enabled: false)
        #expect(await events.next() == .changeServices(device.id))
        await source.completeServiceChange(disabled: ["com.apple.searchd"])
        try await awaitServiceOperations(manager)
        window.makeKeyAndOrderFront(nil)
        let sidebar = try #require(inspectorViews(main.sidebar.view).compactMap { $0 as? NSOutlineView }.first)
        #expect(window.makeFirstResponder(sidebar))
        #expect(main.validateMenuItem(save))
        // A locked Mac may have no application key window; follow the focused view's responder chain directly.
        #expect(sidebar.tryToPerform(try #require(save.action), with: save))
        #expect(profile.configuration.disabledLabels == ["com.apple.searchd"])
        #expect(!services.hasProfileChanges && !main.validateMenuItem(save))
        inspector.toggle(.settings)
        #expect(!main.validateMenuItem(save))
        try await manager.prepareForQuit()
    }

    @Test func deletingAnUnselectedServiceProfileKeepsTheSelection() throws {
        let domain = "NeoSimulator.DeleteProfile.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: serviceProfileURL(domain).deletingLastPathComponent())
        }
        let store = ServiceProfileStore(fileURL: serviceProfileURL(domain), legacyDefaults: defaults)
        let selected = try store.create(name: "Selected", configuration: ServiceConfiguration())
        let deleted = try store.create(name: "Deleted", configuration: ServiceConfiguration())
        let model = ServiceProfilesSettingsModel(store: store)
        model.selectedProfileID = selected.id
        model.deleting = deleted
        model.delete()
        #expect(model.selectedProfileID == selected.id && store.profile(deleted.id) == nil)
        model.duplicate(selected)
        #expect(model.selectedProfileID != selected.id && store.profiles.count == 2)
        #expect(model.selectedProfile.name == "Profile (1)" && model.editingProfileID == model.selectedProfileID)
    }

    @Test func addingServiceProfilesFocusesAndSelectsTheirNames() async throws {
        let domain = "NeoSimulator.ProfileNameEditing.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: serviceProfileURL(domain).deletingLastPathComponent())
        }
        let store = ServiceProfileStore(fileURL: serviceProfileURL(domain), legacyDefaults: defaults)
        let controller = ServiceProfilesSettingsViewController(store: store)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let searchAccessory = try #require(controller.splitViewItems[1].topAlignedAccessoryViewControllers.first)
        let search = try #require(inspectorViews(searchAccessory.view).compactMap { $0 as? BackgroundServiceSearchField }.first)
        search.stringValue = "com.apple.searchd"
        #expect(NSApp.sendAction(try #require(search.action), to: search.target, from: search))
        let sharedEditor = try #require(window.fieldEditor(true, for: nil) as? NSTextView)
        sharedEditor.enabledTextCheckingTypes = NSTextCheckingResult.CheckingType.link.rawValue
        let actionsAccessory = try #require(controller.splitViewItems[0].bottomAlignedAccessoryViewControllers.first)
        let actions = try #require(inspectorViews(actionsAccessory.view).compactMap { $0 as? NSSegmentedControl }.first)
        #expect(!actions.isEnabled(forSegment: 1))
        #expect(controller.addProfileMenu.items.map(\.title) == ["New Profile", "Import…"])
        func addProfile() { controller.addProfileMenu.performActionForItem(at: 0) }
        addProfile()
        try await wait(timeout: .seconds(5)) {
            guard let field = window.firstResponder as? NSTextView else { return false }
            return field.string == "Profile (1)" && field.selectedRange() == NSRange(location: 0, length: 11)
        }
        #expect(window.attachedSheet == nil)
        #expect(actions.isEnabled(forSegment: 1))
        let first = controller.model.selectedProfile
        let field = try #require(window.firstResponder as? NSTextView)
        #expect(field.enabledTextCheckingTypes == 0)
        field.string = "Focused"
        let table = try #require(
            inspectorViews(controller.view).compactMap { $0 as? NSTableView }
                .first { $0.accessibilityLabel() == "Service Profiles" })
        window.makeFirstResponder(table)
        #expect(first.name == "Focused")
        #expect(search.stringValue == "com.apple.searchd")
        let lists = inspectorViews(controller.services.view).compactMap { $0 as? NSTableView }
        let categories = try #require(lists.first { $0.accessibilityLabel() == "Service Categories" })
        let services = try #require(lists.first { $0.accessibilityLabel() == "Services" })
        func shownServices() -> [String] {
            (0..<services.numberOfRows).compactMap { row in
                services.view(atColumn: 0, row: row, makeIfNecessary: true).flatMap {
                    inspectorViews($0).compactMap { $0 as? NSTextField }.first?.stringValue
                }
            }
        }
        // The filter above both lists insets them, and the matches of the selected category show beside it.
        try await wait(timeout: .seconds(5)) {
            controller.view.layoutSubtreeIfNeeded()
            return [categories, services].allSatisfy { ($0.enclosingScrollView?.contentInsets.top ?? 0) > 0 }
                && categories.numberOfRows == 1 && categories.selectedRow == 0
                && shownServices() == ["com.apple.searchd"]
        }
        let filtered = try #require(controller.services.list.selectedSection?.items.first)
        try filtered.setEnabled(false)
        #expect(first.configuration.disabledLabels == ["com.apple.searchd"])
        #expect(store.allServices.configuration.disabledLabels.isEmpty)
        search.stringValue = ""
        #expect(NSApp.sendAction(try #require(search.action), to: search.target, from: search))
        let other = try #require(controller.services.list.sections.dropFirst().first)
        try await wait(timeout: .seconds(5)) {
            categories.numberOfRows == controller.services.list.sections.count
        }
        // Turning off a service that keeps running says why and leaves the profile and the switch as they were.
        let connectivity = try #require(
            controller.services.list.sections.firstIndex { $0.category.id == "connectivity" })
        categories.selectRowIndexes(IndexSet(integer: connectivity), byExtendingSelection: false)
        let required = try #require(
            controller.services.list.selectedSection?.items.first { $0.label == "com.apple.sharingd" })
        let reason = try #require(required.keptRunningReason)
        try await wait(timeout: .seconds(5)) { shownServices().contains(required.label) }
        let requiredRow = try #require(controller.services.list.selectedSection?.items.firstIndex { $0 === required })
        services.scrollRowToVisible(requiredRow)
        let requiredSwitch = try #require(
            services.view(atColumn: 0, row: requiredRow, makeIfNecessary: false).flatMap {
                inspectorViews($0).compactMap { $0 as? NSSwitch }.first
            })
        #expect(required.isEnabled && requiredSwitch.state == .on && requiredSwitch.isEnabled)
        requiredSwitch.performClick(nil)
        try await wait(timeout: .seconds(5)) { window.attachedSheet != nil }
        let refusal = try #require(window.attachedSheet)
        let refusalText = inspectorViews(try #require(refusal.contentView)).compactMap {
            ($0 as? NSTextField)?.stringValue
        }
        #expect(refusalText.contains(reason) && refusalText.contains { $0.contains(required.label) })
        #expect(first.configuration.disabledLabels == ["com.apple.searchd"] && requiredSwitch.state == .on)
        window.endSheet(refusal)
        categories.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        try await wait(timeout: .seconds(5)) {
            shownServices() == other.items.map(\.label)
        }
        let otherLabel = try #require(other.items.first?.label)
        search.stringValue = otherLabel
        #expect(NSApp.sendAction(try #require(search.action), to: search.target, from: search))
        try await wait(timeout: .seconds(5)) {
            shownServices().contains(otherLabel) && categories.selectedRow >= 0
        }
        // Moving the divider between the categories and the services resizes both and keeps what they show.
        let shown = shownServices()
        let selectedRow = categories.selectedRow
        let panes = controller.services.splitView
        let categoriesPane = controller.services.splitViewItems[0].viewController.view
        let servicesPane = controller.services.splitViewItems[1].viewController.view
        let widths = (categories: categoriesPane.frame.width, services: servicesPane.frame.width)
        panes.setPosition(categoriesPane.convert(categoriesPane.bounds, to: panes).maxX + 40, ofDividerAt: 0)
        panes.layoutSubtreeIfNeeded()
        #expect(categoriesPane.frame.width > widths.categories && servicesPane.frame.width < widths.services)
        #expect(search.stringValue == otherLabel && categories.selectedRow == selectedRow)
        #expect(controller.services.list.selectedSection?.category === other.category && shownServices() == shown)
        // Adding copies the selected profile into a new one and keeps the default.
        addProfile()
        let copy = controller.model.selectedProfile
        #expect(copy.name == "Profile (1)" && copy.id != first.id)
        #expect(
            copy.configuration == first.configuration && first.configuration.disabledLabels == ["com.apple.searchd"])
        #expect(store.defaultProfileID == ServiceProfile.allServicesID)
        addProfile()
        #expect(controller.model.selectedProfile.name == "Profile (2)")
    }

    @Test func customCategoriesShowAboveTheBuiltInOnesAndTakeTheirFirstService() async throws {
        let domain = "NeoSimulator.CustomCategoryPanes.\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: serviceProfileURL(domain).deletingLastPathComponent()) }
        let store = ServiceProfileStore(fileURL: serviceProfileURL(domain), legacyDefaults: nil)
        let profile = try store.create(name: "Agents Off", configuration: ServiceConfiguration())
        let controller = ServiceProfilesSettingsViewController(store: store)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let list = controller.services.list
        let lists = inspectorViews(controller.services.view).compactMap { $0 as? NSTableView }
        let categories = try #require(lists.first { $0.accessibilityLabel() == "Service Categories" })
        let services = try #require(lists.first { $0.accessibilityLabel() == "Services" })
        func titles(_ table: NSTableView) -> [String] {
            (0..<table.numberOfRows).compactMap { row in
                table.view(atColumn: 0, row: row, makeIfNecessary: true).flatMap {
                    inspectorViews($0).compactMap { $0 as? NSTextField }.first?.stringValue
                }
            }
        }
        let actions = try (0..<2).map { pane in
            let accessory = try #require(
                controller.services.splitViewItems[pane].bottomAlignedAccessoryViewControllers.first)
            return try #require(inspectorViews(accessory.view).compactMap { $0 as? NSSegmentedControl }.first)
        }
        // The categories' delete and the services' add work on a selected category that the app added.
        func editsCustomCategory() -> Bool {
            actions[0].isEnabled(forSegment: 1) && actions[1].isEnabled(forSegment: 0)
        }
        // Fills in the sheet that shows and confirms it, and returns what its fields showed.
        @discardableResult
        func answer(_ texts: [String], confirming confirm: String) async throws -> [String] {
            try await wait(timeout: .seconds(5)) { window.attachedSheet != nil }
            let sheet = inspectorViews(try #require(window.attachedSheet?.contentView))
            let fields = sheet.compactMap { $0 as? NSTextField }.filter(\.isEditable)
            let shown = fields.map(\.stringValue)
            for (field, text) in zip(fields, texts) { field.stringValue = text }
            try #require(sheet.compactMap { $0 as? NSButton }.first { $0.title == confirm }).performClick(nil)
            try await wait(timeout: .seconds(5)) { window.attachedSheet == nil }
            return shown
        }
        func press(
            _ control: NSSegmentedControl, segment: Int = 0, answering texts: String...,
            confirming confirm: String = "Add"
        ) async throws {
            let button = try #require(
                (control.cell as? NSSegmentedCell)?.accessibilityChildren()?[segment] as? any NSAccessibilityProtocol)
            _ = button.accessibilityPerformPress()
            try await answer(texts, confirming: confirm)
        }
        // The built-in profile shows its fixed categories, which gain nothing beside it.
        let builtIn = SimulatorBackgroundServiceCategory.all.map(\.name)
        try await wait(timeout: .seconds(5)) { titles(categories) == builtIn }
        #expect(!actions[0].isEnabled(forSegment: 0) && !editsCustomCategory())
        try controller.model.addCategory(named: "Agents")
        #expect(store.customCategories.isEmpty)
        controller.model.selectedProfileID = profile.id
        try await wait(timeout: .seconds(5)) { actions[0].isEnabled(forSegment: 0) }
        #expect(titles(categories) == builtIn && !editsCustomCategory())

        // A new category shows and stays selected without services, above the built-in ones.
        try await press(actions[0], answering: "Agents")
        try await wait(timeout: .seconds(5)) {
            titles(categories) == ["Custom", "Agents", "Built-in"] + builtIn && categories.selectedRow == 1
        }
        let agents = try #require(list.selectedSection?.category)
        #expect(categories.delegate?.tableView?(categories, shouldSelectRow: 0) == false)
        let servicesPane = controller.services.splitViewItems[1].viewController.view
        func showsNoServices() -> Bool {
            services.numberOfRows == 0
                && inspectorViews(servicesPane).contains {
                    String(describing: type(of: $0)).hasPrefix("NSHostingView") && !$0.isHidden
                }
        }
        // The services pane can take the new category after the categories pane shows it.
        try await wait(timeout: .seconds(5)) { editsCustomCategory() && showsNoServices() }
        list.query = "agents"
        try await wait(timeout: .seconds(5)) {
            titles(categories) == ["Custom", "Agents"] && categories.selectedRow == 1 && showsNoServices()
        }

        // Its first service shows beside it once the filter clears for it.
        try await press(actions[1], answering: " com.example.agent ")
        try await wait(timeout: .seconds(5)) {
            list.query.isEmpty && titles(services) == ["com.example.agent"] && !showsNoServices()
        }
        #expect(list.selectedSection?.category === agents && categories.selectedRow == 1)

        // A service can say what it does, and the one that's added or edited is selected.
        try await press(actions[1], answering: "com.example.helper", " Helps the agent. ")
        try await wait(timeout: .seconds(5)) {
            titles(services) == ["com.example.agent", "com.example.helper"] && services.selectedRowIndexes == [1]
        }
        #expect(agents.items.map(\.detail) == ["", "Helps the agent."])
        // A row's shortcut menu edits its label and description, starting from what it has.
        func edit(row: Int) throws {
            let rect = services.rect(ofRow: row)
            let click = try #require(
                NSEvent.mouseEvent(
                    with: .rightMouseDown, location: services.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil),
                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                    clickCount: 1, pressure: 1))
            let menu = try #require(services.menu(for: click))
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.performActionForItem(at: try #require(menu.items.firstIndex { $0.title == "Edit…" }))
        }
        try edit(row: 0)
        #expect(
            try await answer(["com.example.worker", "Works for the agent."], confirming: "Save")
                == ["com.example.agent", ""])
        try await wait(timeout: .seconds(5)) {
            titles(services) == ["com.example.worker", "com.example.helper"] && services.selectedRowIndexes == [0]
        }
        try edit(row: 1)
        #expect(
            try await answer(["com.example.helper", "Helps."], confirming: "Save")
                == ["com.example.helper", "Helps the agent."])
        try await wait(timeout: .seconds(5)) {
            agents.items.map(\.detail) == ["Works for the agent.", "Helps."] && services.selectedRowIndexes == [1]
        }

        // The Delete key and the minus button remove the selected services once the removal is confirmed.
        services.selectRowIndexes([0, 1], byExtendingSelection: false)
        try await wait(timeout: .seconds(5)) { actions[1].isEnabled(forSegment: 1) }
        // The Delete key, whose key code is kVK_Delete.
        let delete = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: "\u{7F}", charactersIgnoringModifiers: "\u{7F}", isARepeat: false,
                keyCode: 51))
        services.keyDown(with: delete)
        try await answer([], confirming: "Cancel")
        #expect(titles(services) == ["com.example.worker", "com.example.helper"])
        try await press(actions[1], segment: 1, confirming: "Remove")
        try await wait(timeout: .seconds(5)) { showsNoServices() && !actions[1].isEnabled(forSegment: 1) }
        #expect(store.customCategories.map(\.labels) == [[]])

        // The built-in categories' services stay as they are.
        categories.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
        try await wait(timeout: .seconds(5)) {
            list.selectedSection?.category.isCustom == false && !editsCustomCategory()
        }
        #expect(services.delegate?.tableView?(services, shouldSelectRow: 0) == false)
        controller.model.selectedProfileID = ServiceProfile.allServicesID
        try await wait(timeout: .seconds(5)) {
            titles(categories) == ["Custom"] + store.customCategories.map(\.name) + ["Built-in"] + builtIn
                && !actions[0].isEnabled(forSegment: 0)
        }
    }

    @Test func reusedServiceSwitchesShowTheirProfileWithoutMoving() async throws {
        let domain = "NeoSimulator.ServiceSwitchReuse.\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: serviceProfileURL(domain).deletingLastPathComponent()) }
        let store = ServiceProfileStore(fileURL: serviceProfileURL(domain), legacyDefaults: nil)
        let category = try #require(
            SimulatorBackgroundServiceCategory.all.max { $0.services.count < $1.services.count })
        let labels = Set(category.services.map(\.label))
        let even = Set(category.services.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element.label))
        let first = try store.create(name: "Even", configuration: ServiceConfiguration(disabledLabels: even))
        let second = try store.create(
            name: "Odd", configuration: ServiceConfiguration(disabledLabels: labels.subtracting(even)))
        let controller = ServiceProfilesSettingsViewController(store: store)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 360),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let lists = inspectorViews(controller.services.view).compactMap { $0 as? NSTableView }
        let categories = try #require(lists.first { $0.accessibilityLabel() == "Service Categories" })
        let services = try #require(lists.first { $0.accessibilityLabel() == "Services" })
        let scroll = try #require(services.enclosingScrollView)
        // The switches in view, by the position that their layers draw and the item that their row shows.
        func shownSwitches() -> [(drawing: String, isOn: Bool, item: BackgroundServiceItem)] {
            let items = controller.services.list.selectedSection?.items ?? []
            let rows = services.rows(in: services.visibleRect)
            return (rows.location..<rows.location + rows.length).compactMap { row in
                guard
                    let toggle = services.view(atColumn: 0, row: row, makeIfNecessary: false)
                        .flatMap({ inspectorViews($0).compactMap { $0 as? NSSwitch }.first })
                else { return nil }
                var drawing: [String] = []
                func visit(_ layer: CALayer) {
                    drawing.append("\(layer.frame) \(layer.transform.m41) \(layer.opacity)")
                    layer.sublayers?.forEach(visit)
                }
                toggle.layer.map(visit)
                return (drawing.joined(separator: "|"), toggle.state == .on, items[row])
            }
        }
        for profile in [first, second, first] {
            controller.model.selectedProfileID = profile.id
            try await wait(timeout: .seconds(5)) {
                controller.services.list.categories.first === profile.categories.first
                    && categories.numberOfRows == controller.services.list.sections.count
            }
            let index = try #require(controller.services.list.sections.firstIndex { $0.category.id == category.id })
            categories.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            try await wait(timeout: .seconds(5)) {
                controller.services.list.selectedSection?.category.category == category
                    && services.numberOfRows == controller.services.list.selectedSection?.items.count
            }
            var offset: CGFloat = 0
            while offset < services.frame.height {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: offset - scroll.contentInsets.top))
                scroll.reflectScrolledClipView(scroll.contentView)
                window.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(30))
                let shown = shownSwitches()
                #expect(!shown.isEmpty && shown.allSatisfy { $0.isOn == $0.item.isEnabled })
                // A switch that animated to its row's state would still be moving.
                for _ in 0..<3 {
                    try await Task.sleep(for: .milliseconds(40))
                    #expect(shownSwitches().map(\.drawing) == shown.map(\.drawing))
                }
                offset += scroll.contentView.bounds.height / 2
            }
        }
        #expect(first.configuration.disabledLabels == even)
        #expect(second.configuration.disabledLabels == labels.subtracting(even))

        let sharedLabel = try #require(category.services.first?.label)
        let sharedID = try store.createCategory(named: "Shared Service")
        try store.addService(sharedLabel, to: sharedID)
        let sharedProfile = try store.create(name: "Shared", configuration: ServiceConfiguration(disabledLabels: []))
        let sharedCategory = try #require(sharedProfile.categories.first { $0.id == sharedID })
        let cell = BackgroundServiceCell()
        window.contentView?.addSubview(cell)
        cell.configure(item: sharedCategory, showsDetails: false)
        let toggle = try #require(cell.subviews.compactMap { $0 as? NSSwitch }.first)
        #expect(sharedCategory.isEnabled && toggle.state == .on)
        // Another enabled category keeps this shared service on without changing the profile.
        toggle.performClick(nil)
        #expect(sharedProfile.configuration.disabledLabels.isEmpty && toggle.state == .on)

        let item = try #require(sharedCategory.items.first)
        cell.configure(item: item, showsDetails: false)
        toggle.performClick(nil)
        #expect(sharedProfile.configuration.disabledLabels == [sharedLabel] && toggle.state == .off)
    }

    @Test func selectingAllServicesDiscardsOverridesAndRestoresEveryManagedService() async throws {
        let domain = "NeoSimulator.ResetDefaultServiceProfile.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: serviceProfileURL(domain).deletingLastPathComponent())
        }
        let store = ServiceProfileStore(fileURL: serviceProfileURL(domain), legacyDefaults: defaults)
        let device = simulator()
        let label = "com.apple.searchd"
        let other = "com.apple.searchtoold"
        let required = "com.apple.gamed"
        let profile = try store.create(name: "Search Off", configuration: ServiceConfiguration(disabledLabels: [label, other]))
        try store.assign(.profile(profile.id), to: device.id)
        try store.record([.service(label)], enabled: false, for: device.id, productFamily: "iPhone")
        let source = ManagerModelSource(devices: [device])
        await source.skipSettingsReads()
        await source.holdServiceReads()
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source, serviceProfiles: store)
        await manager.refresh()
        manager.inspect(device, selectionCount: 1)
        manager.selectServiceProfile(.profile(ServiceProfile.allServicesID), for: device.id)
        #expect(await events.next() == .readServices(device.id))
        await source.completeServiceRead(disabled: [label, other, required])
        #expect(await events.next() == .changeServices(device.id))
        await source.completeServiceChange(disabled: [])
        try await awaitServiceOperations(manager)
        #expect(
            store.binding(for: device.id)
                == DeviceServiceProfile(selection: .profile(ServiceProfile.allServicesID)))
        #expect(manager.selection.device?.backgroundServices.configuration?.disabledLabels == [])
        #expect(
            await source.serviceChanges == [
                .init(targets: [required, label, other].map { .service($0) }, enabled: true)
            ])
        try await manager.prepareForQuit()
    }

    @Test func customCategoriesSwitchEveryProfileUntilTheyAreRemoved() async throws {
        let domain = "NeoSimulator.CustomServiceCategory.\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: serviceProfileURL(domain).deletingLastPathComponent()) }
        let store = ServiceProfileStore(fileURL: serviceProfileURL(domain), legacyDefaults: nil)
        let device = simulator()
        let label = "com.example.agent"
        let categoryID = try store.createCategory(named: "Agents")
        try store.addService(label, to: categoryID)
        for refused in [label, "com.apple.sharingd", "com.apple.nanoregistryd"] {
            #expect(throws: ServiceProfileStore.Failure.self) { try store.addService(refused, to: categoryID) }
        }
        let profile = try store.create(name: "Agents Off", configuration: ServiceConfiguration())
        let other = try store.create(name: "Other", configuration: ServiceConfiguration())
        let category = try #require(profile.categories.first)
        #expect(category.id == categoryID && category.isCustom && category.items.map(\.label) == [label])
        category.setEnabled(false)
        #expect(profile.configuration.disabledLabels == [label])
        #expect(other.categories.first?.id == categoryID && other.categories.first?.isEnabled == true)
        let copy = try store.create(name: "Copy", configuration: profile.configuration)

        // Simulators read and change the custom services, which another profile turns on again.
        let source = ManagerModelSource(devices: [device])
        await source.skipSettingsReads()
        await source.holdServiceReads()
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source, serviceProfiles: store)
        await manager.refresh()
        manager.selectServiceProfile(.profile(profile.id), for: device.id)
        #expect(await events.next() == .readServices(device.id))
        await source.completeServiceRead(disabled: [])
        #expect(await events.next() == .changeServices(device.id))
        await source.completeServiceChange(disabled: [label])
        try await awaitServiceOperations(manager)
        manager.selectServiceProfile(.profile(ServiceProfile.allServicesID), for: device.id)
        #expect(await events.next() == .readServices(device.id))
        await source.completeServiceRead(disabled: [label])
        #expect(await events.next() == .changeServices(device.id))
        await source.completeServiceChange(disabled: [])
        try await awaitServiceOperations(manager)
        #expect(
            await source.serviceChanges == [
                .init(targets: [.service(label)], enabled: false),
                .init(targets: [.service(label)], enabled: true),
            ])
        try store.record([.service(label)], enabled: false, for: device.id, productFamily: "iPhone")
        try await manager.prepareForQuit()

        // The definitions last, and a service that takes a new label stays off where it was off.
        let restored = ServiceProfileStore(fileURL: serviceProfileURL(domain), legacyDefaults: nil)
        #expect(restored.customCategories.map(\.labels) == [[label]])
        #expect(restored.profile(copy.id)?.configuration.disabledLabels == [label])
        let renamed = "com.example.worker"
        try restored.updateService(label, in: categoryID, label: renamed, summary: " Works for the agents. ")
        for saved in [restored, ServiceProfileStore(fileURL: serviceProfileURL(domain), legacyDefaults: nil)] {
            #expect(
                saved.catalog.category(categoryID)?.services
                    == [SimulatorBackgroundService(renamed, "Works for the agents.")])
            #expect(saved.profile(copy.id)?.configuration.disabledLabels == [renamed])
            #expect(saved.binding(for: device.id)?.overrides == [renamed: false])
        }

        // Removing a service takes it out of every profile and device.
        try restored.removeServices([renamed], from: categoryID)
        for saved in [restored, ServiceProfileStore(fileURL: serviceProfileURL(domain), legacyDefaults: nil)] {
            #expect(saved.profiles.allSatisfy { $0.configuration.disabledLabels.isEmpty })
            #expect(saved.binding(for: device.id)?.overrides == [:])
            #expect(saved.catalog.category(categoryID)?.services.isEmpty == true)
        }
        try restored.deleteCategory(categoryID)
        #expect(ServiceProfileStore(fileURL: serviceProfileURL(domain), legacyDefaults: nil).catalog == .builtIn)
    }

    @Test func profileFilesListEveryServiceAndImportWhatTheySay() throws {
        let domains = ["Exporting", "Importing"].map { "NeoSimulator.ServiceProfileFiles.\($0).\(UUID().uuidString)" }
        defer {
            for domain in domains {
                try? FileManager.default.removeItem(at: serviceProfileURL(domain).deletingLastPathComponent())
            }
        }
        let store = ServiceProfileStore(fileURL: serviceProfileURL(domains[0]), legacyDefaults: nil)
        let label = "com.example.agent"
        let categoryID = try store.createCategory(named: "Agents")
        try store.addService(label, to: categoryID)
        let searchd = "com.apple.searchd"
        let profile = try store.create(
            name: "Agents Off", configuration: ServiceConfiguration(disabledLabels: [label, searchd]))
        // A file as someone who edits it sees it.
        struct File: Codable {
            struct Category: Codable, Equatable {
                var name: String
                var services: [Service]
            }
            struct Service: Codable, Equatable {
                var label: String?
                var enabled: Bool?
                var description: String?
            }
            var version: Int
            var id: UUID?
            var name: String
            var categories: [Category]
        }

        // All Services nests every built-in service in its category, spread over lines for reading.
        let builtIn = try store.exportedFile(for: store.allServices)
        var file = try JSONDecoder().decode(File.self, from: builtIn)
        #expect(file.version == 1 && file.name == "All Services" && file.id == ServiceProfile.allServicesID)
        #expect(file.categories.map(\.name) == ["Agents"] + SimulatorBackgroundServiceCategory.all.map(\.name))
        #expect(
            file.categories.map { $0.services.map { $0.label ?? "" } }
                == [[label]]
                + SimulatorBackgroundServiceCategory.all.map {
                    $0.services.map(\.label) + $0.requiredServices.map(\.label)
                })
        #expect(file.categories.allSatisfy { $0.services.allSatisfy { $0.enabled == true } })
        #expect(
            String(decoding: builtIn, as: UTF8.self).split(separator: "\n").count
                > file.categories.flatMap(\.services).count)
        let custom = try store.exportedFile(for: profile)
        let customFile = try JSONDecoder().decode(File.self, from: custom)
        #expect(customFile.name == "Agents Off" && customFile.id == profile.id)
        #expect(
            customFile.categories.first
                == File.Category(name: "Agents", services: [File.Service(label: label, enabled: false)]))

        // A file imports as written: its switches, and its categories and services, which join the custom ones unless
        // they match one that's here. A renamed category keeps on the services that simulators need.
        let other = ServiceProfileStore(fileURL: serviceProfileURL(domains[1]), legacyDefaults: nil)
        let guarded = try #require(SimulatorBackgroundServiceCategory.all.first { !$0.requiredServices.isEmpty })
        file.name = "Quiet"
        for category in file.categories.indices {
            if file.categories[category].name == guarded.name { file.categories[category].name = "Mine" }
            for service in file.categories[category].services.indices
            where file.categories[category].services[service].label == searchd {
                file.categories[category].services[service].enabled = false
            }
        }
        file.categories.append(
            File.Category(
                name: "Tools",
                services: [
                    File.Service(label: "com.example.tool", enabled: false, description: "Builds things."),
                    File.Service(label: "com.example.helper"),
                ]))
        var legacy = customFile
        legacy.id = nil
        let imported = try other.importProfiles(from: [
            ("Quiet.json", JSONEncoder().encode(file)), ("Agents Off.json", custom),
            ("Agents Off 2.json", JSONEncoder().encode(legacy)),
        ])
        #expect(imported.map(\.name) == ["Quiet", "Agents Off", "Agents Off"])
        #expect(Set(imported.map(\.id)).count == 3 && imported.allSatisfy(\.canEdit))
        #expect(imported[1].id == profile.id && imported[2].id != profile.id)
        #expect(imported[0].configuration.disabledLabels == [searchd, "com.example.tool"])
        #expect(imported[1].configuration == profile.configuration)
        #expect(other.customCategories.map(\.name) == ["Agents", "Mine", "Tools"])
        // A service that the file doesn't turn off is on.
        let tools = try #require(imported[0].categories.first { $0.category.name == "Tools" })
        #expect(tools.isCustom && tools.items.map(\.detail) == ["Builds things.", ""])
        #expect(tools.items.map(\.isEnabled) == [false, true])
        let mine = try #require(imported[0].categories.first { $0.category.name == "Mine" })
        #expect(
            mine.category.services == guarded.services && mine.category.requiredServices == guarded.requiredServices)
        #expect(mine.items.filter { $0.keptRunningReason != nil }.map(\.label) == guarded.requiredServices.map(\.label))
        #expect(
            ServiceProfileStore(fileURL: serviceProfileURL(domains[1]), legacyDefaults: nil).customCategories
                == other.customCategories)
        // A category that differs from one here joins beside it.
        var helpers = customFile
        helpers.categories[0].name = "Helpers"
        try store.importProfiles(from: [("Helpers.json", JSONEncoder().encode(helpers))])
        #expect(store.customCategories.map(\.name) == ["Agents", "Helpers"])
        #expect(store.customCategories.allSatisfy { $0.labels == [label] })

        // A file that can't import names the field that fails, and nothing that any file has imports.
        let saved = try Data(contentsOf: other.fileURL)
        var later = customFile
        later.version = 2
        let required = try #require(SimulatorBackgroundServiceCategory.all.lazy.flatMap(\.requiredServices).first)
        var requiredOff = try JSONDecoder().decode(File.self, from: builtIn)
        let category = try #require(
            requiredOff.categories.firstIndex { $0.services.contains { $0.label == required.label } })
        let service = try #require(requiredOff.categories[category].services.firstIndex { $0.label == required.label })
        requiredOff.categories[category].services[service].enabled = false
        var wedging = customFile
        wedging.categories.append(
            File.Category(name: "Broken", services: [File.Service(label: "com.apple.nanoregistryd")]))
        var unlabeled = customFile
        unlabeled.categories[0].services[0].label = nil
        var invalidID = try #require(JSONSerialization.jsonObject(with: custom) as? [String: Any])
        invalidID["id"] = "not-a-uuid"
        var replacement = customFile
        replacement.name = "Replacement"
        replacement.categories[0].services[0].enabled = true
        let failures: [(Data, String?)] = try [
            (JSONEncoder().encode(later), "version"),
            (JSONEncoder().encode(requiredOff), "categories[\(category)].services[\(service)].enabled"),
            (JSONEncoder().encode(wedging), "categories[\(wedging.categories.count - 1)].services[0].label"),
            (JSONEncoder().encode(unlabeled), "categories[0].services[0].label"),
            (JSONSerialization.data(withJSONObject: invalidID), "id"),
            (custom, "id"),
            (Data("Agents Off".utf8), nil),
        ]
        for (contents, field) in failures {
            let failure = try #require(throws: ServiceProfileStore.ImportFailure.self) {
                try other.importProfiles(from: [
                    ("Agents Off.json", JSONEncoder().encode(replacement)), ("Profiles.json", contents),
                ])
            }
            #expect(failure.field == field)
            #expect(failure.localizedDescription.hasPrefix("“Profiles.json”\(field.map { ", \($0)" } ?? ""): "))
            #expect(try other.profiles.count == 3 && Data(contentsOf: other.fileURL) == saved)
        }
    }

    @Test func importingAnUpdatedProfileKeepsAssignmentsAndAppliesToRunningFollowers() async throws {
        let domains = ["Publisher", "Recipient"].map { "NeoSimulator.ProfileDistribution.\($0).\(UUID().uuidString)" }
        defer {
            for domain in domains {
                try? FileManager.default.removeItem(at: serviceProfileURL(domain).deletingLastPathComponent())
            }
        }
        let publisher = ServiceProfileStore(fileURL: serviceProfileURL(domains[0]), legacyDefaults: nil)
        let published = try publisher.create(name: "Team", configuration: ServiceConfiguration())
        let recipient = ServiceProfileStore(fileURL: serviceProfileURL(domains[1]), legacyDefaults: nil)
        let imported = try #require(
            recipient.importProfiles(from: [
                ("Team.json", publisher.exportedFile(for: published))
            ]).first)
        #expect(imported.id == published.id)
        let independent = try recipient.create(name: "Personal", configuration: ServiceConfiguration())
        try recipient.setDefaultProfile(imported.id)
        let device = simulator()
        let source = ManagerModelSource(devices: [device])
        await source.skipSettingsReads()
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source, serviceProfiles: recipient)
        await manager.refresh()
        manager.inspect(device, selectionCount: 1)
        manager.selection.setServicesVisible(true)
        await manager.registry.finishReading()
        let configuration = ServiceConfiguration(disabledLabels: ["com.apple.searchd"])
        try publisher.update(published.id, name: "Team Updated", configuration: configuration)
        let updates = try recipient.importProfiles(from: [
            ("Team Updated.json", publisher.exportedFile(for: published))
        ])
        #expect(updates.count == 1 && updates.first === imported)
        #expect(imported.name == "Team Updated" && imported.configuration == configuration)
        #expect(recipient.profiles.map(\.id) == [published.id, independent.id])
        #expect(recipient.defaultProfile === imported && recipient.selection(for: device.id) == .inheritDefault)
        #expect(await events.next() == .changeServices(device.id))
        await source.completeServiceChange(disabled: configuration.disabledLabels)
        try await awaitServiceOperations(manager)
        #expect(manager.selection.device?.backgroundServices.configuration == configuration)
        let restored = ServiceProfileStore(fileURL: recipient.fileURL, legacyDefaults: nil)
        #expect(
            restored.defaultProfileID == published.id && restored.profile(published.id)?.configuration == configuration)
        try await manager.prepareForQuit()
    }

    @Test func profileEditsUseTheSameSharedServiceAndPlatformRulesAsLiveControls() throws {
        let storeCategory = try #require(SimulatorBackgroundServiceCategory.all.first { $0.id == "store" })
        let shared = "com.apple.amsaccountsd"
        var configuration = ServiceConfiguration()
        let affected = configuration.set([.category(storeCategory.id)], enabled: false)
        #expect(!affected.contains(shared))
        #expect(!configuration.disabledLabels.contains(shared))
        configuration.set([.service(shared)], enabled: false)
        #expect(configuration.disabledLabels.contains(shared))
        #expect(configuration.set([.service("com.apple.homed")], enabled: false, productFamily: "Apple Watch").isEmpty)
        #expect(!configuration.disabledLabels.contains("com.apple.homed"))
    }

    @Test func profileApplyPreservesOverridesAndReportsUnappliedStateAfterFailure() async throws {
        let domain = "NeoSimulator.ServiceProfileApply.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: serviceProfileURL(domain).deletingLastPathComponent())
        }
        let store = ServiceProfileStore(fileURL: serviceProfileURL(domain), legacyDefaults: defaults)
        let device = simulator()
        let label = "com.apple.searchd"
        let other = "com.apple.searchtoold"
        let profile = try store.create(name: "Search Off", configuration: ServiceConfiguration(disabledLabels: [label, other]))
        try store.assign(.profile(profile.id), to: device.id)
        try store.record([.service(label)], enabled: true, for: device.id, productFamily: "iPhone")
        let source = ManagerModelSource(devices: [device])
        await source.skipSettingsReads()
        await source.holdServiceReads()
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source, serviceProfiles: store)
        var failure: (any Error)?
        manager.onError = { failure = $0 }
        await manager.refresh()
        manager.inspect(device, selectionCount: 1)
        manager.selectServiceProfile(.profile(profile.id), for: device.id)
        #expect(await events.next() == .readServices(device.id))
        await source.completeServiceRead(disabled: [])
        #expect(await events.next() == .changeServices(device.id))
        await source.failServiceChange(disabled: [other], loaded: [other])
        try await awaitServiceOperations(manager)
        #expect(failure != nil)
        #expect(store.binding(for: device.id)?.overrides.isEmpty == true)
        #expect(manager.selection.device?.backgroundServices.configuration?.disabledLabels == [other])
        #expect(
            await source.serviceChanges == [
                .init(targets: [label, other].sorted().map { .service($0) }, enabled: false)
            ])
        manager.revertServiceProfile(for: device.id)
        #expect(await events.next() == .readServices(device.id))
        await source.completeServiceRead(disabled: [other], loaded: [other])
        #expect(await events.next() == .changeServices(device.id))
        await source.completeServiceChange(disabled: [label, other])
        try await awaitServiceOperations(manager)
        #expect(store.binding(for: device.id)?.overrides.isEmpty == true)
        #expect(await source.serviceChanges.last == .init(targets: [label, other].sorted().map { .service($0) }, enabled: false))
        #expect(manager.selection.device?.backgroundServices.configuration?.disabledLabels == [label, other])
        try await manager.prepareForQuit()
    }

    @Test func aSelectedProfileAppliesAtEachBootWithItsLatestDefinition() async throws {
        let domain = "NeoSimulator.StartupServiceProfile.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: serviceProfileURL(domain).deletingLastPathComponent())
        }
        let store = ServiceProfileStore(fileURL: serviceProfileURL(domain), legacyDefaults: defaults)
        let stopped = simulator(state: "Shutdown")
        let source = ManagerModelSource(devices: [stopped])
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source, serviceProfiles: store)
        let profile = try store.create(name: "Search Off", configuration: ServiceConfiguration(disabledLabels: ["com.apple.searchd"]))
        await manager.refresh()
        manager.selectServiceProfile(.profile(profile.id), for: stopped.id)
        #expect(store.selection(for: stopped.id) == .profile(profile.id))
        let services = try #require(manager.registry.device(for: stopped.id)?.backgroundServices)
        #expect(!services.isChanging)
        await source.setDevices([simulator()])
        manager.manage(.start, devices: [stopped])
        #expect(await events.next() == .manage(.start, [stopped.id]))
        #expect(await events.next() == .changeServices(stopped.id))
        await source.completeServiceChange(disabled: ["com.apple.searchd"])
        try await awaitServiceOperations(manager)

        // Definition edits apply now and remain the definition used at later boots.
        try store.update(profile.id, name: profile.name, configuration: ServiceConfiguration(disabledLabels: ["com.apple.searchtoold"]))
        #expect(await events.next() == .changeServices(stopped.id))
        await source.completeServiceChange(disabled: ["com.apple.searchtoold"])
        try await awaitServiceOperations(manager)
        await manager.refresh()
        #expect(!services.isChanging)
        await source.setDevices([simulator(state: "Shutdown")])
        await manager.refresh()
        await source.setDevices([simulator()])
        await manager.refresh()
        #expect(await events.next() == .changeServices(stopped.id))
        #expect(
            await source.serviceChanges == [
                .init(targets: [.service("com.apple.searchd")], enabled: false),
                .init(targets: [.service("com.apple.searchtoold")], enabled: false),
                .init(targets: [.service("com.apple.searchtoold")], enabled: false),
            ])
        await source.completeServiceChange(disabled: ["com.apple.searchtoold"])
        try await awaitServiceOperations(manager)

        manager.manage(.remove, devices: manager.inventory)
        #expect(await events.next() == .manage(.remove, [stopped.id]))
        try await awaitServiceOperations(manager)
        #expect(store.binding(for: stopped.id) == nil)
        try await manager.prepareForQuit()
    }

    @Test(arguments: [false, true])
    func theCommonProfileAppliesOnceForEachBootThatAnInventoryShows(laterDateIsAnotherBoot: Bool) async throws {
        let domain = "NeoSimulator.CommonProfileBoots.\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: serviceProfileURL(domain).deletingLastPathComponent()) }
        let store = ServiceProfileStore(fileURL: serviceProfileURL(domain), legacyDefaults: nil)
        let label = "com.apple.searchd"
        let common = try store.create(name: "Common", configuration: ServiceConfiguration(disabledLabels: [label]))
        try store.setDefaultProfile(common.id)
        let device = simulator(lastBootDate: Date(timeIntervalSinceNow: -60))
        let source = ManagerModelSource(devices: [device])
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source, serviceProfiles: store)
        var failures: [any Error] = []
        manager.onError = { failures.append($0) }

        // It was running before NeoSimulator looked.
        await manager.refresh()
        let services = try #require(manager.registry.device(for: device.id)?.backgroundServices)
        #expect(!services.isChanging)

        // Xcode rebooted it between reads, which both say that it is booted.
        let reboot = Date(timeIntervalSinceNow: -30)
        await source.setDevices([simulator(lastBootDate: reboot)])
        await manager.refresh()
        #expect(await events.next() == .changeServices(device.id))
        await source.completeServiceChange(disabled: [label])
        try await awaitServiceOperations(manager)
        await manager.refresh()
        #expect(!services.isChanging)
        #expect(await source.serviceChanges.count == 1)

        // Several reads can retain the preceding date. Its replacement identifies either this boot or a later one.
        await source.setDevices([simulator(state: "Shutdown", lastBootDate: reboot)])
        await manager.refresh()
        await source.setDevices([simulator(lastBootDate: reboot)])
        await manager.refresh()
        #expect(await events.next() == .changeServices(device.id))
        await manager.refresh()
        await manager.refresh()
        await source.setDevices([simulator(lastBootDate: laterDateIsAnotherBoot ? .now : Date(timeIntervalSinceNow: -10))])
        await manager.refresh()
        await source.completeServiceChange(disabled: [label])
        if laterDateIsAnotherBoot {
            #expect(await events.next() == .changeServices(device.id))
            await source.completeServiceChange(disabled: [label])
        }
        try await awaitServiceOperations(manager)
        #expect(!services.isChanging)
        #expect(await source.serviceChanges.count == (laterDateIsAnotherBoot ? 3 : 2))
        #expect(failures.isEmpty)
        try await manager.prepareForQuit()
    }

    @Test func devicesApplyStartupProfilesIndependently() async throws {
        let domain = "NeoSimulator.IndependentProfiles.\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: serviceProfileURL(domain).deletingLastPathComponent()) }
        let store = ServiceProfileStore(fileURL: serviceProfileURL(domain), legacyDefaults: nil)
        let label = "com.apple.searchd"
        let common = try store.create(name: "Common", configuration: ServiceConfiguration(disabledLabels: [label]))
        try store.setDefaultProfile(common.id)
        let held = simulator(deviceSet: "/held", state: "Shutdown")
        let free = simulator(deviceSet: "/free", state: "Shutdown")
        let source = ManagerModelSource(devices: [held, free])
        await source.holdServiceReads()
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source, serviceProfiles: store)
        await manager.refresh()

        await source.setDevices([simulator(deviceSet: "/held"), simulator(deviceSet: "/free")])
        await manager.refresh()
        let firstRead = await events.next()
        let secondRead = await events.next()
        let reads = [firstRead, secondRead]
        #expect(reads.contains(.readServices(held.id)) && reads.contains(.readServices(free.id)))

        await source.completeServiceRead(disabled: [], for: free.id)
        #expect(await events.next() == .changeServices(free.id))
        await source.completeServiceChange(disabled: [label])
        let freeServices = try #require(manager.registry.device(for: free.id)?.backgroundServices)
        try await wait(timeout: .seconds(5)) { !freeServices.isChanging }
        #expect(manager.registry.device(for: held.id)?.backgroundServices.isChanging == true)

        await source.completeServiceRead(disabled: [], for: held.id)
        #expect(await events.next() == .changeServices(held.id))
        await source.completeServiceChange(disabled: [label])
        try await awaitServiceOperations(manager)
        #expect(await source.serviceChanges.count == 2)
        try await manager.prepareForQuit()
    }

    @Test(arguments: [false, true])
    func aFailedStartupProfileStaysWithItsDeviceUntilRetryOrTheNextBoot(managingRetry: Bool) async throws {
        let domain = "NeoSimulator.FailedStartupProfile.\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: serviceProfileURL(domain).deletingLastPathComponent()) }
        let store = ServiceProfileStore(fileURL: serviceProfileURL(domain), legacyDefaults: nil)
        let label = "com.apple.searchd"
        let common = try store.create(name: "Common", configuration: ServiceConfiguration(disabledLabels: [label]))
        try store.setDefaultProfile(common.id)
        let device = simulator(lastBootDate: Date(timeIntervalSinceNow: -60))
        let source = ManagerModelSource(devices: [device])
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source, serviceProfiles: store)
        var failures = 0
        manager.onError = { _ in failures += 1 }
        await manager.refresh()

        await source.setDevices([simulator(lastBootDate: Date(timeIntervalSinceNow: -30))])
        await manager.refresh()
        #expect(await events.next() == .changeServices(device.id))
        await source.failServiceChange(disabled: [label], loaded: [label])
        try await awaitServiceOperations(manager)
        #expect(manager.registry.device(for: device.id)?.backgroundServices.services?.disabledLabels == [label])
        #expect(manager.registry.device(for: device.id)?.backgroundServices.services?.loadedLabels == [label])
        #expect(failures == 0)
        #expect(manager.backgroundIssue(for: device.id)?.contains(device.name) == true)
        await manager.refresh()
        #expect(manager.registry.device(for: device.id)?.backgroundServices.isChanging == false)
        #expect(await source.serviceChanges.count == 1 && manager.backgroundIssue(for: device.id) != nil)
        manager.inventoryObservationFailed(ManagerModelSource.Failure.unavailable)
        manager.inventoryObservationRecovered()
        #expect(manager.backgroundIssue(for: device.id)?.contains(device.name) == true)

        let rename = DeviceManagementAction.rename("Renamed")
        if managingRetry {
            await source.holdManagement()
            manager.manage(rename, devices: manager.inventory)
            #expect(await events.next() == .manage(rename, [device.id]))
        } else {
            manager.setBackgroundServices([.service(label)], enabled: false, for: device.id)
            #expect(await events.next() == .changeServices(device.id))
        }
        await manager.retryBackgroundOperations(for: device.id)
        if managingRetry {
            await source.completeManagement(rename)
        } else {
            await source.completeServiceChange(disabled: [label])
        }
        #expect(await events.next() == .changeServices(device.id))
        await source.completeServiceChange(disabled: [label])
        try await awaitServiceOperations(manager)
        #expect(manager.backgroundIssue(for: device.id) == nil)

        await source.setDevices([simulator(lastBootDate: Date(timeIntervalSinceNow: -10))])
        await manager.refresh()
        #expect(await events.next() == .changeServices(device.id))
        await source.completeServiceChange(disabled: [label])
        try await awaitServiceOperations(manager)

        manager.selectServiceProfile(.inheritDefault, for: device.id)
        #expect(await events.next() == .changeServices(device.id))
        await source.completeServiceChange(disabled: [label])
        try await awaitServiceOperations(manager)
        #expect(failures == 0)
        try await manager.prepareForQuit()
    }

    @Test(arguments: [false, true])
    func anUnconfirmedAutomaticProfileAlertsOnlyAfterAChangeMayHaveRun(mayHaveChanged: Bool) async throws {
        let domain = "NeoSimulator.UnconfirmedProfile.\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: serviceProfileURL(domain).deletingLastPathComponent()) }
        let store = ServiceProfileStore(fileURL: serviceProfileURL(domain), legacyDefaults: nil)
        let profile = try store.create(
            name: "Search Off",
            configuration: ServiceConfiguration(disabledLabels: ["com.apple.searchd"]))
        try store.setDefaultProfile(profile.id)
        let stopped = simulator(state: "Shutdown")
        let source = ManagerModelSource(devices: [stopped])
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source, serviceProfiles: store)
        var failures: [any Error] = []
        manager.onError = { failures.append($0) }
        await manager.refresh()
        await source.setDevices([simulator()])
        await manager.refresh()
        #expect(await events.next() == .changeServices(stopped.id))
        await source.setDevices([stopped])
        await manager.refresh()
        await source.failServiceChange(disabled: nil, mayHaveChanged: mayHaveChanged)
        try await awaitServiceOperations(manager)
        #expect(failures.count == (mayHaveChanged ? 1 : 0))
        #expect(manager.backgroundIssue == nil && manager.backgroundIssue(for: stopped.id) == nil)
        try await manager.prepareForQuit()
    }

    @Test func aFailedAutomaticProfileStillReportsItsOutcomeWhileQuitting() async throws {
        let domain = "NeoSimulator.QuittingStartupProfile.\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: serviceProfileURL(domain).deletingLastPathComponent()) }
        let store = ServiceProfileStore(fileURL: serviceProfileURL(domain), legacyDefaults: nil)
        let label = "com.apple.searchd"
        let profile = try store.create(name: "Search Off", configuration: ServiceConfiguration(disabledLabels: [label]))
        try store.setDefaultProfile(profile.id)
        let stopped = simulator(state: "Shutdown")
        let source = ManagerModelSource(devices: [stopped])
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source, serviceProfiles: store)
        var failures: [any Error] = []
        manager.onError = { failures.append($0) }
        await manager.refresh()
        await source.setDevices([simulator()])
        await manager.refresh()
        #expect(await events.next() == .changeServices(stopped.id))

        let quitting = Task.immediate { try await manager.prepareForQuit() }
        await source.failServiceChange(disabled: [label], loaded: [label])
        try await quitting.value
        #expect(failures.count == 1)
        let services = try #require(manager.registry.device(for: stopped.id)?.backgroundServices.services)
        #expect(services.disabledLabels == [label] && services.loadedLabels == [label])
    }

    @Test(arguments: [false, true])
    func aStoppedStartupProfileDoesNotAlertWhenItsReadFails(stopsBeforeFailure: Bool) async throws {
        let domain = "NeoSimulator.StoppedStartupProfile.\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: serviceProfileURL(domain).deletingLastPathComponent()) }
        let store = ServiceProfileStore(fileURL: serviceProfileURL(domain), legacyDefaults: nil)
        let stopped = simulator(state: "Shutdown")
        let source = ManagerModelSource(devices: [stopped])
        await source.holdServiceReads()
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source, serviceProfiles: store)
        var failures: [any Error] = []
        manager.onError = { failures.append($0) }
        await manager.refresh()

        await source.setDevices([simulator()])
        await manager.refresh()
        #expect(await events.next() == .readServices(stopped.id))
        if stopsBeforeFailure {
            await source.setDevices([stopped])
            await manager.refresh()
        }
        await source.failServiceRead()
        try await awaitServiceOperations(manager)
        #expect(failures.isEmpty)
        if !stopsBeforeFailure {
            #expect(manager.backgroundIssue(for: stopped.id) != nil)
            await source.setDevices([stopped])
            await manager.refresh()
        }
        #expect(manager.backgroundIssue(for: stopped.id) == nil)
        #expect(await source.serviceChanges.isEmpty)

        await source.setDevices([simulator()])
        await manager.refresh()
        #expect(await events.next() == .readServices(stopped.id))
        await source.completeServiceRead(disabled: [])
        try await awaitServiceOperations(manager)
        #expect(manager.backgroundIssue(for: stopped.id) == nil && failures.isEmpty)
        try await manager.prepareForQuit()
    }

    @Test(arguments: [false, true])
    func aRestartAppliesTheProfileOnceWhenItEnds(reportsBootDates: Bool) async throws {
        let domain = "NeoSimulator.RestartProfile.\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: serviceProfileURL(domain).deletingLastPathComponent()) }
        let store = ServiceProfileStore(fileURL: serviceProfileURL(domain), legacyDefaults: nil)
        let label = "com.apple.searchd"
        let common = try store.create(name: "Common", configuration: ServiceConfiguration(disabledLabels: [label]))
        try store.setDefaultProfile(common.id)
        let device = simulator(lastBootDate: reportsBootDates ? Date(timeIntervalSinceNow: -60) : nil)
        let source = ManagerModelSource(devices: [device], holdsManagement: true)
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source, serviceProfiles: store)
        await manager.refresh()
        let services = try #require(manager.registry.device(for: device.id)?.backgroundServices)

        manager.manage(.restart, devices: [device])
        #expect(await events.next() == .manage(.restart, [device.id]))
        // A read during the restart can show the new boot, but the action holds the device until it ends.
        if reportsBootDates { await source.setDevices([simulator(lastBootDate: Date(timeIntervalSinceNow: -30))]) }
        await manager.refresh()
        #expect(!services.isChanging)
        await source.completeManagement(.restart)
        #expect(await events.next() == .changeServices(device.id))
        await source.completeServiceChange(disabled: [label])
        try await awaitServiceOperations(manager)
        await manager.refresh()
        #expect(!services.isChanging)
        #expect(await source.serviceChanges.count == 1)
        if reportsBootDates {
            await source.setDevices([simulator(lastBootDate: Date(timeIntervalSinceNow: -10))])
            await manager.refresh()
            #expect(await events.next() == .changeServices(device.id))
            await source.completeServiceChange(disabled: [label])
            try await awaitServiceOperations(manager)
            #expect(await source.serviceChanges.count == 2)
        }
        try await manager.prepareForQuit()
    }

    @Test(arguments: ["erase", "shutdown"])
    func anEraseAppliesItsProfileIfItRebootedDespiteAnError(failingCommand: String) async throws {
        let domain = "NeoSimulator.PartialEraseProfile.\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: serviceProfileURL(domain).deletingLastPathComponent()) }
        let store = ServiceProfileStore(fileURL: serviceProfileURL(domain), legacyDefaults: nil)
        let label = "com.apple.searchd"
        let profile = try store.create(name: "Development", configuration: ServiceConfiguration(disabledLabels: [label]))
        try store.setDefaultProfile(profile.id)
        let device = simulator()
        let source = ManagerModelSource(devices: [device])
        await source.failSimulatorCommand(failingCommand)
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source, serviceProfiles: store)
        var failures: [any Error] = []
        manager.onError = { failures.append($0) }
        await manager.refresh()
        manager.manage(.erase, devices: [device])
        #expect(await events.next() == .manage(.erase, [device.id]))
        if failingCommand == "erase" {
            #expect(await events.next() == .changeServices(device.id))
            await source.completeServiceChange(disabled: [label])
        }
        try await awaitServiceOperations(manager)
        #expect(failures.count == 1)
        #expect(await source.serviceChanges.count == (failingCommand == "erase" ? 1 : 0))
        try await manager.prepareForQuit()
    }

    @Test func aBootDuringAnAcceptedChangeAppliesItsProfileAfterThatChange() async throws {
        let domain = "NeoSimulator.BootDuringChange.\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: serviceProfileURL(domain).deletingLastPathComponent()) }
        let store = ServiceProfileStore(fileURL: serviceProfileURL(domain), legacyDefaults: nil)
        let label = "com.apple.searchd"
        let other = "com.apple.searchtoold"
        let common = try store.create(name: "Common", configuration: ServiceConfiguration(disabledLabels: [other]))
        try store.setDefaultProfile(common.id)
        let device = simulator(lastBootDate: Date(timeIntervalSinceNow: -60))
        let source = ManagerModelSource(devices: [device])
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source, serviceProfiles: store)
        await manager.refresh()

        manager.setBackgroundServices([.service(label)], enabled: false, for: device.id)
        #expect(await events.next() == .changeServices(device.id))
        await source.setDevices([simulator(lastBootDate: Date(timeIntervalSinceNow: -30))])
        await manager.refresh()
        #expect(await source.serviceChanges.count == 1)

        await source.completeServiceChange(disabled: [label])
        #expect(await events.next() == .changeServices(device.id))
        #expect(await source.serviceChanges.last == .init(targets: [label, other].sorted().map { .service($0) }, enabled: false))
        await source.completeServiceChange(disabled: [label, other])
        try await awaitServiceOperations(manager)
        await manager.refresh()
        #expect(await source.serviceChanges.count == 2)
        try await manager.prepareForQuit()
    }

    @Test func serviceOverridesUseTheInspectedStateForSharedServices() async throws {
        let domain = "NeoSimulator.LiveServiceOverrides.\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: serviceProfileURL(domain).deletingLastPathComponent()) }
        let store = ServiceProfileStore(fileURL: serviceProfileURL(domain), legacyDefaults: nil)
        let device = simulator()
        let source = ManagerModelSource(devices: [device])
        await source.skipSettingsReads()
        await source.holdServiceReads()
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source, serviceProfiles: store)
        await manager.refresh()
        manager.inspect(device, selectionCount: 1)
        manager.selection.setServicesVisible(true)
        #expect(await events.next() == .readServices(device.id))
        await source.completeServiceRead(disabled: ["com.apple.bird", "com.apple.sharingd"])
        await manager.registry.finishReading()
        // A required service that something disabled shows as off, and only turning it on reaches the simulator.
        let inspector = BackgroundServicesInspectorModel(manager: manager, showProfileSettings: { _ in })
        let required = try #require(inspector.categories.flatMap(\.items).first { $0.label == "com.apple.sharingd" })
        #expect(!required.isEnabled && required.keptRunningReason != nil)
        #expect(throws: BackgroundServiceKeptRunning.self) { try required.setEnabled(false) }

        manager.setBackgroundServices([.category("store")], enabled: false, for: device.id)
        #expect(await events.next() == .changeServices(device.id))
        await source.completeServiceChange(disabled: ["com.apple.bird", "com.apple.amsaccountsd", "com.apple.sharingd"])
        try await awaitServiceOperations(manager)
        try required.setEnabled(true)
        #expect(await events.next() == .changeServices(device.id))
        await source.completeServiceChange(disabled: ["com.apple.bird", "com.apple.amsaccountsd"])
        try await awaitServiceOperations(manager)
        #expect(required.isEnabled)
        #expect(
            await source.serviceChanges == [
                .init(targets: [.category("store")], enabled: false),
                .init(targets: [.service("com.apple.sharingd")], enabled: true),
            ])
        let profile = try store.create(name: "Development", configuration: ServiceConfiguration())
        try store.assign(.profile(profile.id), to: device.id)
        #expect(store.configuration(for: device.id)?.disabledLabels.contains("com.apple.amsaccountsd") == false)
        try await manager.prepareForQuit()
    }

    @Test func backgroundServiceChangesRunInOrderAndQuitWaitsForThem() async throws {
        let domain = "NeoSimulator.ServiceQueue.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: serviceProfileURL(domain).deletingLastPathComponent())
        }
        let device = simulator()
        let source = ManagerModelSource(devices: [device])
        await source.skipSettingsReads()
        await source.holdServiceReads()
        var events = source.events.makeAsyncIterator()
        let search = try #require(SimulatorBackgroundServiceCategory.all.first { $0.id == "search" })
        let labels = Set(search.services.map(\.label))
        let reported = AsyncStream<(any Error, SimulatorBackgroundServiceState?)>.makeStream()
        var errors = reported.stream.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source, serviceProfiles: ServiceProfileStore(fileURL: serviceProfileURL(domain), legacyDefaults: defaults))
        manager.onError = { reported.continuation.yield(($0, manager.selection.device?.backgroundServices.services?.state(of: search))) }
        await manager.refresh()
        manager.selection.setServicesVisible(true)
        manager.inspect(device, selectionCount: 1)
        let services = try #require(manager.selection.device?.backgroundServices)
        #expect(await events.next() == .readServices(device.id))
        await source.completeServiceRead(disabled: [])
        await manager.registry.finishReading()

        manager.setBackgroundServices([.category("search")], enabled: false, for: device.id)
        #expect(await events.next() == .changeServices(device.id))
        manager.setBackgroundServices([.service("com.apple.searchd")], enabled: true, for: device.id)
        #expect(!services.isEnabled(search))
        #expect(services.isEnabled("com.apple.searchd"))
        #expect(!manager.canManage(.erase, deviceIDs: [device.id]))
        #expect(manager.canManage(.forceShutdown, deviceIDs: [device.id]))

        let beganQuitting = AsyncStream<Void>.makeStream()
        var quitEvents = beganQuitting.stream.makeAsyncIterator()
        let quitting = Task {
            beganQuitting.continuation.yield(())
            try await manager.quitRenderer(keepingDevicesRunning: true)
        }
        await quitEvents.next()
        // The first change stops partway; its readback shows before the error is reported.
        await source.failServiceChange(disabled: labels.subtracting(["com.apple.searchd"]))
        let failure = try #require(await errors.next())
        #expect(failure.0 is SimulatorHostFailure && failure.1 == .partiallyDisabled)
        #expect(await events.next() == .changeServices(device.id))
        await source.completeServiceChange(disabled: labels.subtracting(["com.apple.searchd"]), notStarted: ["com.apple.searchd"])
        #expect(await events.next() == .quit)
        try await quitting.value
        #expect(await source.serviceChanges == [.init(targets: [.category("search")], enabled: false),
                                                .init(targets: [.service("com.apple.searchd")], enabled: true)])
        #expect(services.outcome?.notStartedLabels == ["com.apple.searchd"])
        let inspector = BackgroundServicesInspectorModel(manager: manager, showProfileSettings: { _ in })
        let item = try #require(inspector.categories.flatMap(\.items).first { $0.label == "com.apple.searchd" })
        #expect(item.help.contains("Starts after the simulator restarts."))
    }

    @Test func backgroundServiceResultsStayWithTheirDevice() async throws {
        let domain = "NeoSimulator.ServiceResults.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: serviceProfileURL(domain).deletingLastPathComponent())
        }
        let first = simulator(deviceSet: "/first")
        let second = simulator(deviceSet: "/second")
        let source = ManagerModelSource(devices: [first, second])
        await source.skipSettingsReads()
        await source.holdServiceReads()
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source, serviceProfiles: ServiceProfileStore(fileURL: serviceProfileURL(domain), legacyDefaults: defaults))
        await manager.refresh()
        manager.inspect(first, selectionCount: 1)
        let firstServices = try #require(manager.selection.device?.backgroundServices)
        // launchd is read only while the Background Services page shows.
        #expect(!firstServices.isReading)
        manager.selection.setServicesVisible(true)
        #expect(await events.next() == .readServices(first.id))
        manager.inspect(second, selectionCount: 1)
        let secondServices = try #require(manager.selection.device?.backgroundServices)
        #expect(await events.next() == .readServices(second.id))
        await source.completeServiceRead(disabled: ["com.apple.searchd"], for: first.id)
        #expect(secondServices.services == nil)
        await source.completeServiceRead(disabled: [], for: second.id)
        await manager.registry.finishReading()
        #expect(secondServices.services?.disabledLabels == [])
        #expect(firstServices.services?.disabledLabels == ["com.apple.searchd"])

        manager.setBackgroundServices([.category("search")], enabled: false, for: second.id)
        #expect(await events.next() == .changeServices(second.id))
        manager.inspect(first, selectionCount: 1)
        #expect(!firstServices.isChanging && secondServices.isChanging)
        await source.completeServiceChange(disabled: ["com.apple.searchd"], notStarted: ["com.apple.searchtoold"])
        await manager.registry.finishReading()
        #expect(firstServices.services?.disabledLabels == ["com.apple.searchd"])
        #expect(firstServices.outcome == nil && secondServices.outcome?.notStartedLabels == ["com.apple.searchtoold"])
        try await manager.quitRenderer(keepingDevicesRunning: true)
    }

    @Test func profilesFollowTheAvailableKindWhenChangingDevices() throws {
        guard case .simulator(let simulator) = simulator() else { return }
        func device(_ features: [String]) -> DeviceModel {
            DeviceModel(inventory: .simulator(simulator.inventoryCopy(ownerXcodeURL: nil, capabilities:
                Set(features.map { "com.apple.coredevice.feature." + $0 }))), source: ManagerModelSource(devices: []))
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
        inspection.device = DeviceModel(inventory: .simulator(SimulatorHostDevice(identifier: "phone", name: "Phone", descriptiveName: "Phone",
            runtimeIdentifier: "runtime", runtimeName: "iOS", productFamily: "iPhone", state: "Shutdown",
            capabilities: Set(features.map { "com.apple.coredevice.feature." + $0 }))), source: ManagerModelSource(devices: []))
        inspection.select(.configuration)
        #expect(!inspection.canReadApplications && !inspection.canInstallApplications && !inspection.canReadProfiles)
    }
}
