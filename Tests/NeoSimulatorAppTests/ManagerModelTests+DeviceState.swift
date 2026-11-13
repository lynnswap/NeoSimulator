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
    @Test func connectionObservationRecoveryPreservesOtherObservationFailures() {
        let model = SimulatorManagerModel(source: ManagerModelSource(devices: []))
        model.registry.stopReading()
        model.inventoryObservationFailed(ManagerModelSource.Failure.unavailable)
        model.processObservationFailed(ManagerModelSource.Failure.unavailable)
        model.processObservationRecovered()
        #expect(model.backgroundIssue?.contains("Live device updates are unavailable") == true)
        model.inventoryObservationRecovered()
        #expect(model.backgroundIssue == nil)
    }

    @Test(arguments: [false, true])
    func connectionChangesWaitForAnInFlightInventoryRead(retry: Bool) async throws {
        let source = ManagerModelSource(devices: [])
        if retry { await source.failNextSynchronization() }
        let model = SimulatorManagerModel(source: source)
        model.registry.stopReading()
        await source.holdInventoryReads()
        var events = source.events.makeAsyncIterator()
        let refresh = Task { await model.refresh() }
        #expect(await events.next() == .inventory)
        await model.synchronizeConnections()
        #expect(await source.synchronizationRequests == 0)
        await source.completeInventoryRead()
        await refresh.value
        #expect(await events.next() == .synchronize)
        if retry {
            while await events.next() != .synchronize {}
        }
        #expect(await source.synchronizationRequests == (retry ? 2 : 1))
    }

    @Test func recentUsesSimulatorActivityWithoutBorrowingCustomSetMetadata() async throws {
        let defaultDevice = simulator(name: "Default", lastUsedAt: Date(timeIntervalSinceReferenceDate: 200))
        let customDevice = simulator(deviceSet: "/tmp/sidebar-custom-set", name: "Custom", lastUsedAt: Date(timeIntervalSinceReferenceDate: 300))
        let newDevice = simulator(deviceSet: "/tmp/sidebar-new-set", name: "New", createdAt: Date(timeIntervalSinceReferenceDate: 400))
        let payload = Data(#"""
        {"result":{"devices":[{"identifier":"core-record","properties":{
          "hardware":{"fidelity":"simulated","udid":"same-udid"},"state":{"name":"Default"},
          "connection":{"state":"unavailable","lastConnectionDate":100}}}]}}
        """#.utf8)
        let snapshot = try await DeviceInventoryReader(
            readSimulators: { DeviceInventorySnapshot(devices: [defaultDevice, customDevice, newDevice], issues: []) },
            readCoreDevices: { payload }).read()
        #expect(snapshot.issues.isEmpty)
        #expect(snapshot.devices.first { $0.id == defaultDevice.id }?.lastConnectionDate == Date(timeIntervalSinceReferenceDate: 100))
        #expect(snapshot.devices.first { $0.id == customDevice.id }?.lastConnectionDate == nil)
        let presentation = DeviceBrowserPresentation(devices: snapshot.devices, sortOrder: .recent)
        #expect(presentation.sections.count == 1)
        #expect(presentation.devices.map(\.id) == [newDevice.id, customDevice.id, defaultDevice.id])
        let availability = DeviceBrowserPresentation(devices: snapshot.devices, sortOrder: .availability)
        #expect(Set(availability.sections.first?.devices.map(\.id) ?? []) == Set([customDevice.id, newDevice.id]))
        #expect(availability.sections.last?.devices.map(\.id) == [defaultDevice.id])
    }

    @Test func operatingSystemOrderUsesTypedVersionsWithMissingValuesLast() throws {
        // base, patched and rebuilt share a 24B114 revision apart from humanReadableVersionString. BuildUpdate.<
        // compares only base and patched by factory, so availability and identifiers would then form a cycle.
        let payload = Data(#"""
        {"result":{"devices":[
          {"identifier":"older","properties":{"hardware":{"fidelity":"physical","osPlatform":"iOS"},
            "software":{"osVersionNumber":{"stringValue":"27.2"}},"connection":{"state":"connected"}}},
          {"identifier":"base","properties":{"hardware":{"fidelity":"physical","osPlatform":"iOS"},
            "software":{"osVersionNumber":{"stringValue":"27.2"},"osBuildVersions":{"buildVersion":{"factoryIdentifier":1,"majorLetterComponent":"B","majorNumberComponent":24,"name":"24B114",
              "revisionVersion":{"components":[24,2,114,0,0],"extraInfo":{"humanReadableVersionString":"a","versionExtraString":"x"},"originalComponentsCount":5,"stringValue":"24.2.114.0.0"},"updateNumberComponent":114}}}}},
          {"identifier":"patched","properties":{"hardware":{"fidelity":"physical","osPlatform":"iOS"},
            "software":{"osVersionNumber":{"stringValue":"27.2"},"osBuildVersions":{"buildVersion":{"factoryIdentifier":2,"majorLetterComponent":"B","majorNumberComponent":24,"name":"24B114",
              "revisionVersion":{"components":[24,2,114,0,0],"extraInfo":{"humanReadableVersionString":"a","versionExtraString":"x"},"originalComponentsCount":5,"stringValue":"24.2.114.0.0"},"updateNumberComponent":114}}},
            "connection":{"state":"connected"}}},
          {"identifier":"rebuilt","properties":{"hardware":{"fidelity":"physical","osPlatform":"iOS"},
            "software":{"osVersionNumber":{"stringValue":"27.2"},"osBuildVersions":{"buildVersion":{"factoryIdentifier":1,"majorLetterComponent":"B","majorNumberComponent":24,"name":"24B114",
              "revisionVersion":{"components":[24,2,114,0,0],"extraInfo":{"humanReadableVersionString":"b","versionExtraString":"x"},"originalComponentsCount":5,"stringValue":"24.2.114.0.0"},"updateNumberComponent":114}}},
            "connection":{"state":"connected"}}},
          {"identifier":"earlierBuild","properties":{"hardware":{"fidelity":"physical","osPlatform":"iOS"},
            "software":{"osVersionNumber":{"stringValue":"27.2"},"osBuildVersions":{"buildVersion":{"factoryIdentifier":9,"majorLetterComponent":"B","majorNumberComponent":24,"name":"24B91016s",
              "revisionVersion":{"components":[24,2,101,6,19],"originalComponentsCount":5,"stringValue":"24.2.101.6.19"},"updateLetterComponent":"s","updateNumberComponent":91016}}}}},
          {"identifier":"newer","properties":{"hardware":{"fidelity":"physical","osPlatform":"iOS"},
            "software":{"osVersionNumber":{"stringValue":"27.10"}}}},
          {"identifier":"unknown","properties":{"hardware":{"fidelity":"physical","osPlatform":"iOS"}}},
          {"identifier":"watch","properties":{"hardware":{"fidelity":"physical","osPlatform":"watchOS"},
            "software":{"osVersionNumber":{"stringValue":"27.2"}}}},
          {"identifier":"vision","properties":{"hardware":{"fidelity":"physical","osPlatform":"visionOS"},
            "software":{"osVersionNumber":{"stringValue":"27.2"}}}},
          {"identifier":"future","properties":{"hardware":{"fidelity":"physical","osPlatform":"futureOS"},
            "software":{"osVersionNumber":{"stringValue":"1.0"}}}}
        ]}}
        """#.utf8)
        let devices = try CoreDeviceInventoryDecoder.decode(payload).map(InventoryDevice.remote)
        let presentation = DeviceBrowserPresentation(devices: devices, sortOrder: .operatingSystem)
        #expect(presentation.sections.map(\.title) == ["futureOS 1.0", "iOS 27.10", "iOS 27.2", "iOS Other", "watchOS 27.2", "visionOS 27.2"])
        // Typed builds precede availability: 24B91016s before 24B114, and a missing build after both.
        #expect(presentation.sections.first { $0.id == "iOS 27.2" }?.devices.map(\.id)
            == ["earlierBuild", "rebuilt", "base", "patched", "older"].map(DeviceInventoryID.coreDevice))
        let platforms = DeviceBrowserPresentation(devices: devices, sortOrder: .platform)
        #expect(platforms.sections.map(\.id) == ["futureOS", "iOS", "watchOS", "xrOS"])
        #expect(platforms.sections.map(\.title) == ["futureOS", "iOS", "watchOS", "visionOS"])
    }

    @Test func returningToAFreshDeviceKeepsItsObjectAndReadsNothing() async throws {
        let first = simulator(deviceSet: "/first")
        let second = simulator(deviceSet: "/second")
        let source = ManagerModelSource(devices: [first, second])
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source)
        await manager.refresh()
        manager.inspect(first, selectionCount: 1)
        let model = try #require(manager.selection.device)
        #expect(await events.next() == .read(first.id))
        await source.completeRead(settings(appearance: .dark))
        await manager.registry.finishReading()
        manager.inspect(second, selectionCount: 1)
        #expect(await events.next() == .read(second.id))
        await source.completeRead(settings(appearance: .light))
        await manager.registry.finishReading()

        manager.inspect(first, selectionCount: 1)
        #expect(manager.selection.device === model)
        #expect(!model.settings.isLoading && model.settings.appearance == .dark)
        await manager.registry.finishReading()
        #expect(await source.readCount == 2)
        try await manager.prepareForQuit()
    }

    @Test func unchangedInventoryRefreshReadsNothing() async throws {
        let device = simulator()
        let source = ManagerModelSource(devices: [device])
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source)
        await manager.refresh()
        manager.inspect(device, selectionCount: 1)
        let model = try #require(manager.selection.device)
        #expect(await events.next() == .read(device.id))
        await source.completeRead(settings(appearance: .dark))
        await manager.registry.finishReading()

        await manager.refresh()
        await source.setDevices([simulator(lastUsedAt: Date(timeIntervalSinceReferenceDate: 1))])
        await manager.refresh()
        await manager.registry.finishReading()
        #expect(manager.registry.device(for: device.id) === model)
        #expect(await source.readCount == 1)
        try await manager.prepareForQuit()
    }

    @Test func onlyChangedFieldsInvalidateObservers() async throws {
        let device = simulator()
        let source = ManagerModelSource(devices: [device])
        var events = source.events.makeAsyncIterator()
        let (registry, model, interest) = try await settingsFixture(source)
        defer { interest.release() }
        let values = model.settings
        #expect(await events.next() == .read(device.id))
        await source.completeRead(settings(appearance: .dark, contentSize: .medium))
        await registry.finishReading()

        final class Invalidations: @unchecked Sendable { nonisolated(unsafe) var names: [String] = [] }
        let invalidations = Invalidations()
        withObservationTracking { _ = values.appearance } onChange: { invalidations.names.append("appearance") }
        withObservationTracking { _ = values.contentSize } onChange: { invalidations.names.append("contentSize") }
        withObservationTracking { _ = values.status(of: .appearance) } onChange: { invalidations.names.append("status") }
        withObservationTracking { _ = model.name } onChange: { invalidations.names.append("name") }
        model.revalidate(.settings)
        #expect(await events.next() == .read(device.id))
        await source.completeRead(settings(appearance: .dark, contentSize: .large))
        await registry.finishReading()
        #expect(invalidations.names == ["contentSize"])
    }

    @Test func groupsPublishAsTheyFinish() async throws {
        let device = simulator()
        let source = ManagerModelSource(devices: [device])
        var events = source.events.makeAsyncIterator()
        let (registry, model, interest) = try await settingsFixture(source)
        defer { interest.release() }
        let values = model.settings
        #expect(values.isLoading)
        #expect(await events.next() == .read(device.id))

        await source.publishRead(.values(.appearance) { $0.appearance = .dark })
        #expect(values.appearance == .dark && !values.isLoading)
        #expect(values.status(of: .appearance) == .current && values.status(of: .textSize) == .unread)
        await source.publishRead(.failed(.textSize, "Held up"))
        #expect(values.status(of: .textSize) == .stale("Held up") && values.failures == ["Held up"])
        await source.publishRead(.values(.accessibility, failures: ["Show Borders: Held up"]) { $0.reduceMotion = true })
        #expect(values.reduceMotion == true && values.status(of: .accessibility) == .stale("Show Borders: Held up"))
        #expect(values.status(of: .voiceOver) == .unread)
        await source.completeRead(settings(appearance: .dark))
        await registry.finishReading()
        #expect(await source.readCount == 1)
    }

    @Test func readFailureKeepsValuesAndUnsupportedClearsThem() async throws {
        let device = simulator()
        let source = ManagerModelSource(devices: [device])
        var events = source.events.makeAsyncIterator()
        let (registry, model, interest) = try await settingsFixture(source)
        defer { interest.release() }
        let values = model.settings
        #expect(await events.next() == .read(device.id))
        await source.completeRead(SimulatorDeviceSettings(appearance: .dark, contentSize: .large, boldText: true))
        await registry.finishReading()
        #expect(values.status(of: .appearance) == .current)

        model.revalidate(.settings)
        #expect(await events.next() == .read(device.id))
        await source.publishRead(.failed(.appearance, "No answer"))
        await source.publishRead(.unsupported(.boldText))
        await source.completeRead(SimulatorDeviceSettings(appearance: .light, contentSize: .large, boldText: true))
        await registry.finishReading()
        #expect(values.appearance == .dark && values.status(of: .appearance) == .stale("No answer"))
        #expect(values.boldText == nil && values.status(of: .boldText) == .unsupported)
        #expect(values.contentSize == .large && values.status(of: .textSize) == .current)
        // A failed read is not tried again by itself, only when something next invalidates it.
        #expect(await source.readCount == 2)
    }

    @Test func readsFromBeforeAWriteOrAnOldBootAreDiscarded() async throws {
        let device = simulator()
        let source = ManagerModelSource(devices: [device])
        var events = source.events.makeAsyncIterator()
        let (registry, model, interest) = try await settingsFixture(source)
        defer { interest.release() }
        let values = model.settings
        #expect(await events.next() == .read(device.id))
        await source.completeRead(settings(appearance: .light))
        await registry.finishReading()

        // A write accepted while a read runs outlives what that read saw.
        model.revalidate(.settings)
        #expect(await events.next() == .read(device.id))
        let applying = Task { try await values.set(.appearance(.dark)) }
        #expect(await events.next() == .write(device.id))
        await source.completeWrite()
        try await applying.value
        await source.completeRead(settings(appearance: .light))
        #expect(values.appearance == .dark)
        #expect(await events.next() == .read(device.id))
        await source.completeRead(settings(appearance: .dark))
        await registry.finishReading()

        // A read that began before the device stopped describes a boot that is over.
        model.revalidate(.settings)
        #expect(await events.next() == .read(device.id))
        await source.setDevices([simulator(state: "Shutdown")])
        try await registry.refresh()
        await source.setDevices([device])
        try await registry.refresh()
        #expect(await events.next() == .read(device.id))
        await source.completeRead(settings(appearance: .light))
        #expect(values.appearance == .dark)
        await source.completeRead(settings(appearance: .dark, contentSize: .large))
        await registry.finishReading()
        #expect(values.appearance == .dark && values.contentSize == .large)
    }

    @Test func aFinishedChangeIsConfirmedWhileAnotherGroupOfARunningReadStaysUnanswered() async throws {
        let device = simulator()
        let source = ManagerModelSource(devices: [device])
        var events = source.events.makeAsyncIterator()
        let (registry, model, interest) = try await settingsFixture(source)
        defer { interest.release() }
        let values = model.settings
        #expect(await events.next() == .read(device.id))
        await source.completeRead(settings(appearance: .light))
        await registry.finishReading()

        model.revalidate(.settings)
        #expect(await events.next() == .read(device.id))
        let applying = Task { try await values.set(.appearance(.dark)) }
        #expect(await events.next() == .write(device.id))
        await source.completeWrite()
        try await applying.value
        // What this read saw of the group predates the change, so it says nothing. Display Zoom has not answered at all.
        await source.publishRead(.values(.appearance) { $0.appearance = .light })
        #expect(values.appearance == .dark)
        #expect(await events.next() == .read(device.id))
        #expect(await source.heldReadGroups.last == [.appearance])
        await source.publishRead(.values(.appearance) { $0.appearance = .dark })
        #expect(values.appearance == .dark && values.status(of: .appearance) == .current)
        #expect(await source.heldReadGroups.first?.contains(.displayZoom) == true)

        // The group that was held answers for itself, and nothing is read again.
        await source.completeRead(settings(appearance: .dark))
        await registry.finishReading()
        #expect(values.appearance == .dark)
        #expect(await source.readCount == 3)
    }

    @Test func aFinishedChangeIsConfirmedWhileALaterChangeToAnotherGroupStaysHeld() async throws {
        let device = simulator()
        let source = ManagerModelSource(devices: [device])
        var events = source.events.makeAsyncIterator()
        let (registry, model, interest) = try await settingsFixture(source)
        defer { interest.release() }
        let values = model.settings
        #expect(await events.next() == .read(device.id))
        await source.completeRead(SimulatorDeviceSettings(appearance: .light, boldText: false))
        await registry.finishReading()

        let first = try values.accept(.appearance(.dark))
        #expect(await events.next() == .write(device.id))
        let second = try values.accept(.boldText(true))
        await source.completeWrite()
        try await first.task.value
        // The later change has started or is about to. Either way the earlier one is not held for its outcome.
        var seen = [await events.next(), await events.next()]
        #expect(seen.contains(.read(device.id)) && seen.contains(.write(device.id)))
        #expect(await source.heldReadGroups == [[.appearance]])
        await source.completeRead(SimulatorDeviceSettings(appearance: .dark))
        #expect(values.status(of: .appearance) == .current && values.boldText == true)
        await source.completeWrite()
        try await second.task.value
        seen = [await events.next()]
        #expect(seen == [.read(device.id)])
        #expect(await source.heldReadGroups == [[.boldText]])
        await source.completeRead(SimulatorDeviceSettings(boldText: true))
        await registry.finishReading()
        #expect(values.boldText == true)
        #expect(await source.groupReadCount == DeviceSettingsGroup.allCases.count + 2)
    }

    @Test func aHeldWriteOnOneDeviceDoesNotDelayAnother() async throws {
        let first = simulator(deviceSet: "/first")
        let second = simulator(deviceSet: "/second")
        let source = ManagerModelSource(devices: [first, second])
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source)
        await manager.refresh()
        manager.setDeviceSetting(.appearance(.dark), for: first.id)
        #expect(await events.next() == .write(first.id))
        manager.setDeviceSetting(.boldText(true), for: first.id)
        manager.setDeviceSetting(.appearance(.light), for: second.id)
        // The second device's write reaches it while the first's stays held, and the first's next stays behind it.
        #expect(await events.next() == .write(second.id))
        #expect(await source.writtenChanges == [.appearance(.dark), .appearance(.light)])
        await source.completeWrite(for: second.id)
        #expect(await events.next() == .read(second.id))
        #expect(await source.writtenChanges.count == 2)
        await source.completeRead(SimulatorDeviceSettings(appearance: .light), for: second.id)
        await source.completeWrite(for: first.id)
        let started = [await events.next(), await events.next()]
        #expect(started.contains(.write(first.id)) && started.contains(.read(first.id)))
        await source.completeRead(SimulatorDeviceSettings(appearance: .dark), for: first.id)
        await source.completeWrite(for: first.id)
        #expect(await events.next() == .read(first.id))
        await source.completeRead(SimulatorDeviceSettings(appearance: .dark, boldText: true), for: first.id)
        try await manager.prepareForQuit()
        #expect(await source.writtenChanges.last == .boldText(true))
    }

    @Test func deletionRequiresASuccessfulScope() async throws {
        let remote = try #require(try CoreDeviceInventoryDecoder.decode(Data(#"{"result":{"devices":[{"identifier":"A","properties":{"hardware":{"fidelity":"physical"},"state":{"name":"A"},"connection":{"state":"connected"}}}]}}"#.utf8)).first)
        let xcode = URL(fileURLWithPath: "/Fixture.app")
        let catalog = DeviceInventoryIssue.Source.simulators(xcodeURL: xcode, deviceSetPath: nil)
        let otherCatalog = DeviceInventoryIssue.Source.simulators(xcodeURL: URL(fileURLWithPath: "/Other.app"), deviceSetPath: nil)
        let phone = simulator()
        let registry = DeviceRegistry(source: ManagerModelSource(devices: []))
        struct Unread: Error {}
        registry.apply(DeviceInventorySnapshot(devices: [phone, .remote(remote)], issues: [],
                                               sources: [phone.id: [catalog, otherCatalog], .coreDevice("A"): [.coreDevice]]))
        let phoneModel = try #require(registry.device(for: phone.id))
        let remoteModel = try #require(registry.device(for: .coreDevice("A")))

        registry.apply(DeviceInventorySnapshot(devices: [phone, .remote(remote)], issues: [.init(source: catalog, error: Unread())],
                                               sources: [phone.id: [otherCatalog], .coreDevice("A"): [.coreDevice]]))
        registry.apply(DeviceInventorySnapshot(devices: [.remote(remote)], issues: [.init(source: catalog, error: Unread())],
                                               sources: [.coreDevice("A"): [.coreDevice]]))
        #expect(registry.device(for: phone.id) === phoneModel)

        // A failed source says nothing of what only it listed, and the sources that read still decide theirs.
        registry.apply(DeviceInventorySnapshot(devices: [phone], issues: [.init(source: .coreDevice, error: Unread())],
                                               sources: [phone.id: [catalog]]))
        #expect(registry.device(for: .coreDevice("A")) === remoteModel)
        #expect(registry.devices.count == 2)
        registry.apply(DeviceInventorySnapshot(devices: [.remote(remote)], issues: [.init(source: catalog, error: Unread())],
                                               sources: [.coreDevice("A"): [.coreDevice]]))
        #expect(registry.device(for: phone.id) === phoneModel)
        registry.apply(DeviceInventorySnapshot(devices: [.remote(remote)], issues: [.init(source: .simulators(xcodeURL: nil, deviceSetPath: nil), error: Unread())],
                                               sources: [.coreDevice("A"): [.coreDevice]]))
        #expect(registry.device(for: phone.id) === phoneModel)
        // Renderer ownership lists nothing by itself.
        registry.apply(DeviceInventorySnapshot(devices: [.remote(remote)], issues: [.init(source: .rendererOwnership, error: Unread())],
                                               sources: [.coreDevice("A"): [.coreDevice]]))
        #expect(registry.device(for: phone.id) == nil)
        // A device that returns is a new device, with nothing of the old one's state.
        registry.apply(DeviceInventorySnapshot(devices: [phone, .remote(remote)], issues: [],
                                               sources: [phone.id: [catalog], .coreDevice("A"): [.coreDevice]]))
        #expect(registry.device(for: phone.id) !== phoneModel)
        #expect(registry.device(for: .coreDevice("A")) === remoteModel)
        registry.apply(DeviceInventorySnapshot(devices: [phone], issues: [], sources: [phone.id: [catalog]]))
        #expect(registry.device(for: .coreDevice("A")) == nil)
    }

    @Test func aRemovedDeviceKeepsLateReadsAndNewWritesOutOfItsReplacement() async throws {
        let device = simulator()
        let source = ManagerModelSource(devices: [device])
        var events = source.events.makeAsyncIterator()
        let (registry, model, interest) = try await settingsFixture(source)
        defer { interest.release() }
        let presentation = model.beginPresentation {}
        defer { model.endPresentation(presentation) }
        #expect(await events.next() == .read(device.id))

        registry.apply(DeviceInventorySnapshot(devices: [], issues: []))
        await source.completeRead(settings(appearance: .dark))
        await model.finishReading()
        try #require(registry.device(for: device.id) == nil)
        try #require(!model.isAvailable && !model.canInspectSettings)
        #expect(model.settings.appearance == nil)
        await #expect(throws: SimulatorError.self) { try await model.settings.set(.boldText(true)) }
        #expect(await source.writtenChanges.isEmpty)

        registry.apply(DeviceInventorySnapshot(devices: [device], issues: []))
        let replacement = try #require(registry.device(for: device.id))
        #expect(replacement !== model)
        let newInterest = replacement.keepCurrent(.settings)
        defer { newInterest.release() }
        #expect(await events.next() == .read(device.id))
        await source.completeRead(settings(appearance: .light))
        await registry.finishReading()
        #expect(replacement.settings.appearance == .light && model.settings.appearance == nil)
    }

    @Test func revalidationReadsOnlyDevicesOfInterest() async throws {
        let first = simulator(deviceSet: "/first")
        let second = simulator(deviceSet: "/second")
        let source = ManagerModelSource(devices: [first, second])
        var events = source.events.makeAsyncIterator()
        let (registry, model, interest) = try await settingsFixture(source)
        defer { interest.release() }
        #expect(model.id == first.id)
        #expect(await events.next() == .read(first.id))
        await source.completeRead(settings(appearance: .dark))
        await registry.finishReading()

        // However many times it is invalidated while one read runs, each group reads once more when its own read ends.
        registry.revalidate()
        #expect(await events.next() == .read(first.id))
        registry.revalidate()
        registry.revalidate()
        await source.completeRead(settings(appearance: .dark))
        let groups = DeviceSettingsGroup.allCases.count
        for _ in 0..<groups { #expect(await events.next() == .read(first.id)) }
        for _ in 0..<groups { await source.completeRead(settings(appearance: .dark)) }
        await registry.finishReading()
        #expect(await source.groupReadCount == 3 * groups)

        // What nothing held read when it is next held.
        let later = try #require(registry.device(for: second.id)).keepCurrent(.settings)
        defer { later.release() }
        #expect(await events.next() == .read(second.id))
        await source.completeRead(settings(appearance: .light))
        await registry.finishReading()
    }

    @Test func minimalIsReadOnlyAndItsEditableCopiesKeepIndependentConfigurations() throws {
        let domain = "NeoSimulator.MinimalServiceProfile.\(UUID().uuidString)"
        let fileURL = serviceProfileURL(domain)
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = ServiceProfileStore(fileURL: fileURL, legacyDefaults: nil)
        let settings = ServiceProfilesSettingsModel(store: store)
        let minimal = store.minimal
        let original = minimal.configuration
        #expect(original.disabledLabels.contains("com.apple.searchd"))
        #expect(original.disabledLabels.contains("com.apple.navd"))
        #expect(!original.disabledLabels.contains("com.apple.assistantd"))
        settings.selectedProfileID = minimal.id
        #expect(!minimal.canEdit && !settings.canDelete && !settings.canEditCategories)
        minimal.setServices([.service("com.apple.searchd")], enabled: true)
        #expect(minimal.configuration == original)

        settings.duplicate(minimal)
        let copy = settings.selectedProfile
        #expect(copy.canEdit && copy.configuration == original)
        copy.setServices([.service("com.apple.searchd")], enabled: true)
        #expect(!copy.configuration.disabledLabels.contains("com.apple.searchd"))
        #expect(minimal.configuration == original)

        let category = try store.createCategory(named: "Agents")
        let label = try store.addService("com.example.agent", to: category)
        for profile in store.builtInProfiles {
            let custom = try #require(profile.categories.first { $0.id == category })
            #expect(custom.items.first?.label == label && custom.isEnabled)
            #expect(!profile.configuration.disabledLabels.contains(label))
        }
        #expect(copy.configuration.disabledLabels == original.disabledLabels.subtracting(["com.apple.searchd"]))

        let imported = try #require(
            store.importProfiles(from: [
                (name: "Minimal.json", contents: store.exportedFile(for: minimal))
            ]).first)
        #expect(imported.canEdit && imported.configuration == original)
        try store.setDefaultProfile(minimal.id)
        let restored = ServiceProfileStore(fileURL: fileURL, legacyDefaults: nil)
        #expect(restored.defaultProfile === restored.minimal)
        #expect(restored.profiles.map(\.id) == [copy.id, imported.id])
        #expect(restored.profile(copy.id)?.configuration == copy.configuration)
    }

    @Test(arguments: [false, true])
    func defaultChangesApplyTheLatestChoiceAfterManagement(reselectOriginal: Bool) async throws {
        let domain = "NeoSimulator.DeferredProfileDefault.\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: serviceProfileURL(domain).deletingLastPathComponent()) }
        let store = ServiceProfileStore(fileURL: serviceProfileURL(domain), legacyDefaults: nil)
        let profile = try store.create(name: "Development", configuration: ServiceConfiguration())
        let label = "com.apple.searchd"
        let other = "com.apple.searchtoold"
        let next = try store.create(name: "Next", configuration: ServiceConfiguration(disabledLabels: [label]))
        try store.setDefaultProfile(profile.id)
        let device = simulator()
        let source = ManagerModelSource(devices: [device])
        await source.holdManagement()
        await source.holdServiceReads()
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source, serviceProfiles: store)
        await manager.refresh()
        let rename = DeviceManagementAction.rename("Renamed")
        manager.manage(rename, devices: [device])
        #expect(await events.next() == .manage(rename, [device.id]))
        profile.setServices([.service(label)], enabled: false)
        // Even an equivalent definition must replace the deferred request with the newly chosen default.
        try store.setDefaultProfile(next.id)
        if reselectOriginal {
            // An edit while this profile is no longer selected must not join its earlier deferred request.
            profile.setServices([.service(other)], enabled: false)
            try store.setDefaultProfile(profile.id)
        }
        await source.completeManagement(rename)
        let services = try #require(manager.registry.device(for: device.id)?.backgroundServices)
        try await wait(timeout: .seconds(5)) { manager.managingDeviceIDs.isEmpty && services.isChanging }
        #expect(await events.next() == .readServices(device.id))
        await source.completeServiceRead(disabled: [])
        #expect(await events.next() == .changeServices(device.id))
        let expected: Set<String> = reselectOriginal ? [label, other] : [label]
        await source.completeServiceChange(disabled: expected)
        try await awaitServiceOperations(manager)
        #expect(await source.serviceChanges.count == 1)
        #expect(services.configuration?.disabledLabels == expected)
        #expect(store.resolvedProfile(for: device.id) === (reselectOriginal ? profile : next))
        try await manager.prepareForQuit()
    }

    @Test func aDeviceListedAfterTheFirstInventoryAppliesOnlyIfItBootedSince() async throws {
        let domain = "NeoSimulator.ListedLaterProfile.\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: serviceProfileURL(domain).deletingLastPathComponent()) }
        let store = ServiceProfileStore(fileURL: serviceProfileURL(domain), legacyDefaults: nil)
        let label = "com.apple.searchd"
        let common = try store.create(name: "Common", configuration: ServiceConfiguration(disabledLabels: [label]))
        try store.setDefaultProfile(common.id)
        let source = ManagerModelSource(devices: [])
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source, serviceProfiles: store)
        await source.holdInventoryReads()
        let firstRead = Task { await manager.refresh() }
        #expect(await events.next() == .inventory)
        let bootedDuringRead = Date()
        await source.completeInventoryRead()
        await firstRead.value

        let running = simulator(deviceSet: "/running", lastBootDate: Date(timeIntervalSinceNow: -60))
        let unknown = simulator(deviceSet: "/unknown")
        let booted = simulator(deviceSet: "/booted", lastBootDate: bootedDuringRead)
        await source.setDevices([running, unknown, booted])
        await manager.refresh()
        #expect(manager.registry.device(for: running.id)?.backgroundServices.isChanging == false)
        #expect(manager.registry.device(for: unknown.id)?.backgroundServices.isChanging == false)
        #expect(await events.next() == .changeServices(booted.id))
        await source.completeServiceChange(disabled: [label])
        try await awaitServiceOperations(manager)

        // An initially unknown date can later establish that this device also booted after observation began.
        await source.setDevices([running, simulator(deviceSet: "/unknown", lastBootDate: .now), booted])
        await manager.refresh()
        #expect(await events.next() == .changeServices(unknown.id))
        await source.completeServiceChange(disabled: [label])
        try await awaitServiceOperations(manager)

        // What is known of a device ends when it leaves the inventory.
        await source.setDevices([running])
        await manager.refresh()
        await source.setDevices([running, booted])
        await manager.refresh()
        #expect(await events.next() == .changeServices(booted.id))
        await source.completeServiceChange(disabled: [label])
        try await awaitServiceOperations(manager)
        try await manager.prepareForQuit()
    }

    @Test func aNewStoreAppliesAllServicesAtTheNextBoot() async throws {
        let domain = "NeoSimulator.StandardStartupProfile.\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: serviceProfileURL(domain).deletingLastPathComponent()) }
        let store = ServiceProfileStore(fileURL: serviceProfileURL(domain), legacyDefaults: nil)
        let stopped = simulator(state: "Shutdown")
        let source = ManagerModelSource(devices: [stopped])
        await source.holdServiceReads()
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source, serviceProfiles: store)
        await manager.refresh()
        await source.setDevices([simulator()])
        await manager.refresh()
        #expect(await events.next() == .readServices(stopped.id))
        let label = "com.apple.searchd"
        await source.completeServiceRead(disabled: [label])
        #expect(await events.next() == .changeServices(stopped.id))
        #expect(await source.serviceChanges == [.init(targets: [.service(label)], enabled: true)])
        await source.completeServiceChange(disabled: [])
        try await awaitServiceOperations(manager)
        try await manager.prepareForQuit()
    }

    @Test func changingTheDefaultAppliesToInheritingDevicesImmediately() async throws {
        let domain = "NeoSimulator.ChosenProfile.\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: serviceProfileURL(domain).deletingLastPathComponent()) }
        let store = ServiceProfileStore(fileURL: serviceProfileURL(domain), legacyDefaults: nil)
        let label = "com.apple.searchd"
        let other = "com.apple.searchtoold"
        let device = simulator()
        let independent = simulator(deviceSet: "/independent")
        let stopped = simulator(deviceSet: "/stopped", state: "Shutdown")
        try store.assign(.profile(ServiceProfile.allServicesID), to: independent.id)
        let source = ManagerModelSource(devices: [device, independent, stopped])
        await source.skipSettingsReads()
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source, serviceProfiles: store)
        await manager.refresh()
        let services = try #require(manager.registry.device(for: device.id)?.backgroundServices)
        manager.inspect(device, selectionCount: 1)
        manager.selection.setServicesVisible(true)
        await manager.registry.finishReading()
        let inspector = BackgroundServicesInspectorModel(manager: manager, showProfileSettings: { _ in })

        manager.selectServiceProfile(.inheritDefault, for: device.id)
        try await awaitServiceOperations(manager)
        #expect(!services.isChanging && store.defaultProfile === store.allServices)
        let common = try store.create(name: "Common", configuration: ServiceConfiguration(disabledLabels: [label]))
        try store.setDefaultProfile(common.id)
        try await wait(timeout: .seconds(5)) { services.isChanging }
        #expect(manager.registry.device(for: independent.id)?.backgroundServices.isChanging == false)
        #expect(manager.registry.device(for: stopped.id)?.backgroundServices.isChanging == false)
        #expect(store.configuration(for: stopped.id)?.disabledLabels == [label])
        #expect(await events.next() == .changeServices(device.id))
        await source.completeServiceChange(disabled: [label])
        try await awaitServiceOperations(manager)
        #expect(services.configuration?.disabledLabels == [label])
        #expect(!inspector.hasProfileChanges && !inspector.canRevertProfile)

        // Later edits keep using the same live application path.
        common.setServices([.service(other)], enabled: false)
        #expect(await events.next() == .changeServices(device.id))
        #expect(
            await source.serviceChanges.last == .init(targets: [label, other].map { .service($0) }, enabled: false))
        await source.completeServiceChange(disabled: [label, other])
        try await awaitServiceOperations(manager)

        manager.selectServiceProfile(.inheritDefault, for: device.id)
        #expect(services.isChanging)
        #expect(await events.next() == .changeServices(device.id))
        await source.completeServiceChange(disabled: [label, other])
        try await awaitServiceOperations(manager)

        // Reverting clears explicit overrides and reapplies the inherited definition.
        manager.setBackgroundServices([.service(label)], enabled: true, for: device.id)
        #expect(await events.next() == .changeServices(device.id))
        await source.completeServiceChange(disabled: [other])
        try await awaitServiceOperations(manager)
        #expect(
            store.binding(for: device.id) == DeviceServiceProfile(selection: .inheritDefault, overrides: [label: true]))
        let next = try store.create(name: "Next", configuration: ServiceConfiguration(disabledLabels: [label]))
        await source.holdServiceReads()
        try store.setDefaultProfile(next.id)
        #expect(await events.next() == .readServices(device.id))
        await source.completeServiceRead(disabled: [other])
        #expect(await events.next() == .changeServices(device.id))
        await source.completeServiceChange(disabled: [])
        try await awaitServiceOperations(manager)
        #expect(services.configuration?.disabledLabels == [])
        #expect(store.binding(for: device.id)?.overrides == [label: true])
        manager.revertServiceProfile(for: device.id)
        #expect(await events.next() == .readServices(device.id))
        await source.completeServiceRead(disabled: [])
        #expect(await events.next() == .changeServices(device.id))
        await source.completeServiceChange(disabled: [label])
        try await awaitServiceOperations(manager)
        #expect(store.binding(for: device.id) == DeviceServiceProfile(selection: .inheritDefault))
        try await manager.prepareForQuit()
    }

    @Test func aStoreThatCannotBeWrittenKeepsTheChoiceWhichStillAppliesAtBoot() async throws {
        let domain = "NeoSimulator.ProfileWriteFailure.\(UUID().uuidString)"
        let fileURL = serviceProfileURL(domain)
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = ServiceProfileStore(fileURL: fileURL, legacyDefaults: nil)
        let stopped = simulator(state: "Shutdown")
        let source = ManagerModelSource(devices: [stopped])
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source, serviceProfiles: store)
        let failures = AsyncStream<Void>.makeStream()
        var errors = failures.stream.makeAsyncIterator()
        manager.onError = { _ in failures.continuation.yield(()) }
        let profile = try store.create(name: "Search Off", configuration: ServiceConfiguration(disabledLabels: ["com.apple.searchd"]))
        await manager.refresh()
        manager.selectServiceProfile(.profile(profile.id), for: stopped.id)
        try FileManager.default.removeItem(at: fileURL)
        try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: false)

        manager.selectServiceProfile(.inheritDefault, for: stopped.id)
        #expect(await errors.next() != nil)
        #expect(store.selection(for: stopped.id) == .profile(profile.id))

        await source.setDevices([simulator()])
        manager.manage(.start, devices: [stopped])
        #expect(await events.next() == .manage(.start, [stopped.id]))
        #expect(await events.next() == .changeServices(stopped.id))
        await source.completeServiceChange(disabled: ["com.apple.searchd"])
        try await awaitServiceOperations(manager)
        #expect(manager.registry.device(for: stopped.id)?.backgroundServices.isChanging == false)
        try await manager.prepareForQuit()
    }

    @Test func aServiceReadFailureKeepsCachedValuesUntilRetrySucceeds() async throws {
        let domain = "NeoSimulator.ServiceReadFailure.\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: serviceProfileURL(domain).deletingLastPathComponent()) }
        let store = ServiceProfileStore(fileURL: serviceProfileURL(domain), legacyDefaults: nil)
        let device = simulator()
        let source = ManagerModelSource(devices: [device])
        await source.skipSettingsReads()
        await source.holdServiceReads()
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source, serviceProfiles: store)
        let inspector = BackgroundServicesInspectorModel(manager: manager, showProfileSettings: { _ in })
        await manager.refresh()
        manager.inspect(device, selectionCount: 1)
        manager.selection.setServicesVisible(true)
        #expect(await events.next() == .readServices(device.id))
        await source.completeServiceRead(disabled: ["com.apple.searchd"])
        await manager.registry.finishReading()
        #expect(inspector.content == .simulator(.services))

        inspector.requestRefresh()
        #expect(await events.next() == .readServices(device.id))
        await source.failServiceRead()
        await manager.registry.finishReading()
        // What was read stays, with why it may be out of date.
        #expect(inspector.content == .simulator(.services))
        #expect(inspector.serviceState?.disabledLabels == ["com.apple.searchd"])
        #expect(inspector.issue == ManagerModelSource.Failure.unavailable.localizedDescription)
        #expect(!inspector.canSaveProfile)

        inspector.requestRefresh()
        #expect(await events.next() == .readServices(device.id))
        await source.completeServiceRead(disabled: [])
        await manager.registry.finishReading()
        #expect(inspector.content == .simulator(.services) && inspector.issue == nil)
        try await manager.prepareForQuit()
    }

    @Test func servicesThatACategoryAddsStayUnknownUntilAReadCoversThem() async throws {
        let domain = "NeoSimulator.AddedServiceCoverage.\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: serviceProfileURL(domain).deletingLastPathComponent()) }
        let store = ServiceProfileStore(fileURL: serviceProfileURL(domain), legacyDefaults: nil)
        let device = simulator()
        let label = "com.example.agent"
        let searchd = "com.apple.searchd"
        let source = ManagerModelSource(devices: [device])
        await source.skipSettingsReads()
        await source.holdServiceReads()
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source, serviceProfiles: store)
        let inspector = BackgroundServicesInspectorModel(manager: manager, showProfileSettings: { _ in })
        await manager.refresh()
        manager.inspect(device, selectionCount: 1)
        manager.selection.setServicesVisible(true)
        // The simulator has the label turned off, which a read of the built-in categories leaves out.
        #expect(await events.next() == .readServices(device.id))
        await source.completeServiceRead(disabled: [label])
        await manager.registry.finishReading()
        #expect(inspector.content == .simulator(.services))

        // A category without new services keeps what was read while the services are read again.
        let categoryID = try store.createCategory(named: "Agents")
        #expect(inspector.content == .simulator(.services))
        #expect(await events.next() == .readServices(device.id))
        await source.completeServiceRead(disabled: [label])
        await manager.registry.finishReading()

        // Once the category lists the label, the services are unknown rather than showing it on, and a change that
        // started before reads back without the label.
        manager.setBackgroundServices([.service(searchd)], enabled: false, for: device.id)
        #expect(await events.next() == .changeServices(device.id))
        try store.addService(label, to: categoryID)
        #expect(inspector.serviceState == nil && inspector.content == .simulator(.loading) && inspector.canSaveProfile)
        await source.completeServiceChange(disabled: [label, searchd])
        #expect(await events.next() == .readServices(device.id))
        #expect(inspector.serviceState == nil)
        await source.failServiceRead()
        await manager.registry.finishReading()
        #expect(inspector.serviceState == nil)
        #expect(inspector.content == .simulator(.failure(ManagerModelSource.Failure.unavailable.localizedDescription)))

        inspector.requestRefresh()
        #expect(await events.next() == .readServices(device.id))
        await source.completeServiceRead(disabled: [label, searchd])
        await manager.registry.finishReading()
        #expect(inspector.serviceState?.disabledLabels == [label, searchd])
        try await manager.prepareForQuit()
    }

    @Test(arguments: zip([1, 3], ["Disabled", "Enabled"]))
    func ddiServicesUsesTheAdvertisedFlagAmongOtherPreparednessBits(_ raw: Int64, _ expected: String) {
        let information = DeviceInformation(device: simulator(), properties: [
            "state": .object(["preparednessState": .integer(raw)]),
        ])
        #expect(information.fields.first { $0.title == "DDI Services" }?.value == expected)
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
}
