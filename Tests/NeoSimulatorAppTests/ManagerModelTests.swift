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

@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor
struct ManagerModelTests {
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

    @Test func launchAppliesThePreferenceAndQuitEndsTheSession() async throws {
        let source = ManagerModelSource(devices: [])
        let manager = SimulatorManagerModel(source: source)
        let file = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).plist")
        let access = HostPreferenceAccess(file: file, chooseFile: { _, _ in
            Issue.record("Device Hub has not created a settings file to select.")
            return nil
        })
        manager.requestHostPreferenceAccess = { try await access.request() }
        manager.start()
        try await manager.quitRenderer(keepingDevicesRunning: true)
        #expect(await source.sessionEvents == ["begin", "status", "quit", "end"])
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

    @Test func aFailedLaunchStillExposesThePreferredHostForRetry() async throws {
        let source = ManagerModelSource(devices: [])
        await source.failSessionStart()
        let manager = SimulatorManagerModel(source: source)
        var reported = false
        manager.onError = { _ in reported = true }
        manager.start()
        try await manager.prepareForQuit()
        #expect(reported)
        #expect(manager.status?.preferredHost == .neo)
        #expect(manager.status?.host == .deviceHub)
    }

    @Test func failedExitPreparationKeepsTheSessionAvailableForAnotherAttempt() async throws {
        let source = ManagerModelSource(devices: [])
        let manager = SimulatorManagerModel(source: source)
        manager.start()
        do {
            try await manager.quitRenderer(keepingDevicesRunning: true) {
                throw ManagerModelSource.Failure.unavailable
            }
            Issue.record("Exit preparation should have failed")
        } catch ManagerModelSource.Failure.unavailable {}
        #expect(await !source.sessionEvents.contains("end"))
        try await manager.quitRenderer(keepingDevicesRunning: true)
        #expect(await source.sessionEvents.last == "end")
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
        preferences.startLastDevice = false
        #expect(defaults.bool(forKey: "ShowSingleTouches"))
        #expect(!defaults.bool(forKey: "StartLastDeviceOnLaunch") && !defaults.bool(forKey: "SessionOnLaunch"))
        #expect(preferences.gifImageSize == 640)
        let externalDefaults = try #require(UserDefaults(suiteName: domain))
        externalDefaults.set(true, forKey: HostPreferences.screenShotUseMask)
        #expect(preferences.includeDeviceMask)
        preferences.startLastDevice = true
        #expect(defaults.bool(forKey: HostPreferences.startLastDeviceOnLaunch) && defaults.bool(forKey: HostPreferences.sessionOnLaunch))
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
        browser.menuNeedsUpdate(menu)
        #expect(button.state == .off)
        let simulators = try #require(menu.items.first { $0.title == "Simulators" })
        #expect(NSApp.sendAction(try #require(simulators.action), to: simulators.target, from: simulators))
        #expect(button.state == .on && button.image === image)
        #expect(item.menuFormRepresentation?.state == .on)
        let all = try #require(menu.items.first { $0.title == "All Devices" })
        #expect(NSApp.sendAction(try #require(all.action), to: all.target, from: all))
        #expect(button.state == .off && button.image === image)
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
            controller.menuNeedsUpdate(menu)
            let item = try #require(menu.items.first { $0.title == title && !$0.isSectionHeader })
            #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
        }
        func deviceNames() -> Set<String> {
            Set((0..<outline.numberOfRows).compactMap { row in
                guard let item = outline.item(atRow: row), controller.outlineView(outline, shouldSelectItem: item) else { return nil }
                return controller.outlineView(outline, typeSelectStringFor: nil, item: item)
            })
        }
        try choose("Show Groups")
        try choose("iPhone Duo")
        #expect(deviceNames() == ["Review Device", "Unavailable Device", "Desk Phone"])
        try choose("iPhone")
        #expect(deviceNames() == ["iPhone Duo Clone"])
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
        #expect(controller.settings.serviceProfiles.model.selectedProfileID == ServiceProfile.allServices.id)
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
                outline.item(atRow: row).flatMap { controller.outlineView(outline, typeSelectStringFor: nil, item: $0) }.map { ($0, row) }
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
            controller.menuNeedsUpdate(menu)
            let item = try #require(menu.items.first { $0.title == title && !$0.isSectionHeader })
            #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
        }
        try choose("Availability")
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

        func deviceNames() -> [String] {
            (0..<outline.numberOfRows).compactMap { row in
                guard let item = outline.item(atRow: row), controller.outlineView(outline, shouldSelectItem: item) else { return nil }
                return controller.outlineView(outline, typeSelectStringFor: nil, item: item)
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
        controller.update()
        #expect(controller.selectedIdentifiers == [.coreDevice("A")])
        #expect(outline.item(atRow: outline.selectedRow) as? NSObject === selectedRow)
        #expect(!viewScreen.isEnabled)
        let row = try #require(controller.outlineView(outline, viewFor: outline.tableColumns.first, item: selectedRow))
        #expect(row.accessibilityLabel()?.hasSuffix(", Available") == true)

        try choose("All Availability")
        try choose("Recent")
        await source.setDevices(try devices())
        await model.refresh()
        controller.update()
        controller.selectDevice(.coreDevice("A"))
        let roots = (0..<controller.outlineView(outline, numberOfChildrenOfItem: nil)).map {
            controller.outlineView(outline, child: $0, ofItem: nil)
        }
        for root in roots { outline.collapseItem(root) }
        let revision = controller.presentationIntent.revision
        // Moving A into B's collapsed day replaces that parent's cached children.
        await source.setDevices(try devices(firstDate: 200_000))
        await model.inventoryDidChange()
        try await wait {
            controller.outlineView(outline, numberOfChildrenOfItem: nil) == 1
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

    @Test func previewViewScreenOpensTheSelectedDevice() async throws {
        _ = NSApplication.shared
        let devices = try CoreDeviceInventoryDecoder.decode(Data(#"{"result":{"devices":[{"identifier":"A","properties":{"hardware":{"fidelity":"physical"},"state":{"name":"A"},"connection":{"state":"connected"}},"capabilities":[{"featureIdentifier":"com.apple.coredevice.feature.viewdevicescreen"}]}]}}"#.utf8))
        let source = ManagerModelSource(devices: devices.map(InventoryDevice.remote))
        let model = SimulatorManagerModel(source: source)
        model.registry.stopReading()
        await model.refresh()
        var requested: [DeviceInventoryID] = []
        model.onDeviceOpenRequested = { requested.append($0) }
        let controller = ManagerWindowController(model: model, screens: DeviceScreens(model: model),
                                                 menus: MenuController(application: nil))
        controller.window?.setFrameAutosaveName("")
        defer { controller.window?.close() }
        controller.selectDevice(.coreDevice("A"))
        let content = try #require(controller.window?.contentView)
        let viewScreen = try #require(inspectorViews(content).compactMap { $0 as? NSButton }
            .first { $0.title == "View Screen" })
        viewScreen.performClick(nil)
        #expect(requested == [.coreDevice("A")])
        try await wait(timeout: .seconds(5)) {
            !model.isBusy
        }
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
        try await wait(timeout: .seconds(5)) {
            pane.liveDeviceIdentifier == rendered && renderedController.presentationViewController.parent === pane.liveScreenContainer
        }
        #expect(main.selectedIdentifiers == [selected])
        #expect(model.selection.device?.id == selected && main.deviceInspector.inspection.device?.id == selected)
        #expect((mode == "new-selection" ? aController : bController).presentationViewController.parent == nil)
        #expect(aSession.state == .connected && app.screens.screen(for: aID)?.commandTarget === aController)
        try await aSession.stop()
        try await bSession.stop()
        main.window?.close()
    }

    @Test func quittingStopsTheAcceptedMoveAndWaitsForIt() async throws {
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
        defer { main.window?.close() }
        let aTransport = TestRemoteScreenTransport()
        let aSession = RemoteDeviceScreenSession(device: a) { _, _, _ in aTransport }
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
        let releasing = AsyncStream<Void>.makeStream(), resume = AsyncStream<Void>.makeStream()
        var releases = releasing.stream.makeAsyncIterator()
        aTransport.onReleaseInputs = {
            aTransport.onReleaseInputs = nil
            releasing.continuation.yield(())
            var permits = resume.stream.makeAsyncIterator()
            _ = await permits.next()
        }
        let content = try #require(main.window?.contentView)
        let outline = try #require(inspectorViews(content).compactMap { $0 as? NSOutlineView }.first)
        let bRow = try #require((0..<outline.numberOfRows).first { row in
            row != outline.selectedRow && outline.item(atRow: row).map { main.outlineView(outline, shouldSelectItem: $0) } == true
        })
        outline.selectRowIndexes(IndexSet(integer: bRow), byExtendingSelection: false)
        #expect(await releases.next() != nil)
        app.screens.beginQuitting()
        resume.continuation.yield(())
        await pane.waitForScreenMoves()
        #expect(!aController.isEmbedded && !bController.isEmbedded && pane.liveDeviceIdentifier == nil)
        #expect(aSession.state == .connected && bSession.state == .connected)
        try await aSession.stop()
        try await bSession.stop()
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
        #expect(model.selection.device?.id == aID && main.deviceInspector.inspection.device?.id == aID)
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
        let session = RemoteDeviceScreenSession(device: a) { _, _, _ in TestRemoteScreenTransport() }
        let backgroundSession = RemoteDeviceScreenSession(device: c) { _, _, _ in transport }
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
        let compacting = Task { try await main.presentConnectedScreen(cID, purpose: .automatic, preserving: .compact) }
        try #require(await releases.next() != nil)
        outline.selectRowIndexes(IndexSet(rows.prefix(2)), byExtendingSelection: false)
        outline.selectRowIndexes(IndexSet(integer: rows[2]), byExtendingSelection: true)
        try #require(main.selectedIdentifiers.count == 3)
        resume.continuation.yield(())
        try await compacting.value
        try await wait(timeout: .seconds(5)) {
            pane.liveDeviceIdentifier == nil && pane.liveCommandTarget == nil
        }
        #expect(controller.presentationViewController.parent == nil)
        #expect(main.selectedIdentifiers.count == 3 && model.selection.device == nil)
        try await session.stop()
        try await backgroundSession.stop()
    }

    @Test func aContextMenuLeavesTheSelectionAndPresentationOfAnyRow() async throws {
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
        try await wait(timeout: .seconds(5)) {
            pane.liveDeviceIdentifier == nil && !aController.isEmbedded
        }
        let compactIntent = main.presentationIntent
        main.update()
        let content = try #require(main.window?.contentView)
        let fields = inspectorViews(content)
        let search = try #require(fields.compactMap { $0 as? NSSearchField }.first { $0.placeholderString == "Search Devices" })
        search.stringValue = "B"
        main.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        search.stringValue = ""
        main.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        #expect(main.presentationIntent.revision == compactIntent.revision && main.presentationIntent.placement == .compact)
        let outline = try #require(fields.compactMap { $0 as? NSOutlineView }.first)
        let aRow = outline.selectedRow
        try #require(aRow >= 0)
        main.updateDeviceMenu(for: aRow)
        #expect(main.presentationIntent.revision == compactIntent.revision && main.presentationIntent.placement == .compact)
        let bRow = try #require((0..<outline.numberOfRows).first { row in
            row != aRow && outline.item(atRow: row).map { main.outlineView(outline, shouldSelectItem: $0) } == true
        })
        main.updateDeviceMenu(for: bRow)
        #expect(main.presentationIntent.revision == compactIntent.revision && main.presentationIntent.placement == .compact)
        #expect(main.selectedIdentifiers == [aID] && outline.selectedRow == aRow)
        #expect(pane.liveDeviceIdentifier == nil && !bController.isEmbedded)
        #expect(model.selection.device?.id == aID && main.deviceInspector.inspection.device?.id == aID)
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
        main.update()
        let content = try #require(main.window?.contentView)
        let outline = try #require(inspectorViews(content).compactMap { $0 as? NSOutlineView }.first)
        let menu = try #require(outline.menu)
        func row(of device: InventoryDevice) throws -> Int {
            try #require((0..<outline.numberOfRows).first { row in
                guard let item = outline.item(atRow: row) else { return false }
                return main.outlineView(outline, viewFor: outline.tableColumns.first, item: item)?.accessibilityLabel()?.hasPrefix("\(device.name),") == true
            })
        }
        func restart(fromMenuOf row: Int) async throws {
            try await wait { model.managingDeviceIDs.isEmpty }
            main.updateDeviceMenu(for: row)
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
        let header = try #require((0..<outline.numberOfRows).first { outline.item(atRow: $0).map { main.outlineView(outline, shouldSelectItem: $0) } == false })
        main.updateDeviceMenu(for: header)
        #expect(menu.items.isEmpty)
        #expect(main.selectedIdentifiers == [first.id, third.id] && main.presentationIntent.revision == group.revision)
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
        try await main.presentConnectedScreen(aID, purpose: initial ? .startup : .automatic)
        let selected = initial ? aID : bID
        #expect(main.selectedIdentifiers == [selected])
        #expect(model.selection.device?.id == selected && main.deviceInspector.inspection.device?.id == selected)
        #expect(pane.liveDeviceIdentifier == (initial ? aID : nil))
        #expect((controller.presentationViewController.parent === pane.liveScreenContainer) == initial)
        #expect(session.state == .connected && app.screens.screen(for: aID)?.commandTarget === controller)
        if !initial {
            try await main.presentConnectedScreen(aID, purpose: .automatic, preserving: .compact)
            #expect(compactPresentations == 1 && main.selectedIdentifiers == [bID] && pane.liveDeviceIdentifier == nil)
        }
        if initial {
            let compact = try #require(main.window?.toolbar?.items.first { $0.itemIdentifier.rawValue == "CompactDeviceWindow" })
            #expect(!compact.isHidden && compact.isEnabled)
            #expect(NSApp.sendAction(try #require(compact.action), to: compact.target, from: compact))
            try await wait(timeout: .seconds(5)) {
                pane.liveDeviceIdentifier == nil && !controller.isEmbedded
            }
            #expect(compact.isHidden && !compact.isEnabled)
            try await main.presentConnectedScreen(aID, purpose: .requested)
            #expect(pane.liveDeviceIdentifier == nil && !controller.isEmbedded)
            main.showDevice(aID)
            try await wait(timeout: .seconds(5)) {
                pane.liveDeviceIdentifier == aID && controller.isEmbedded
            }
        }
        try await session.stop()
        main.window?.close()
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
        let session = RemoteDeviceScreenSession(device: a, captureSources: catalog) { _, _, _ in TestRemoteScreenTransport() }
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
        try await wait(timeout: .seconds(5)) {
            pane.liveDeviceIdentifier == nil && !controller.isEmbedded
        }
        #expect(controller.presentationViewController.supplementalTarget(forAction: action, sender: command) as AnyObject? === controller)
        #expect(controller.validateMenuItem(command))
        try await session.stop()
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
                row != outline.selectedRow && outline.item(atRow: row).map { main.outlineView(outline, shouldSelectItem: $0) } == true
            })
            outline.selectRowIndexes(IndexSet(integer: bRow), byExtendingSelection: false)
        } else {
            let compact = try #require(main.window?.toolbar?.items.first { $0.itemIdentifier.rawValue == "CompactDeviceWindow" })
            #expect(NSApp.sendAction(try #require(compact.action), to: compact.target, from: compact))
            try await wait(timeout: .seconds(5)) {
                pane.liveDeviceIdentifier == nil && !aController.isEmbedded
            }
        }
        await source.completeWrite()
        try await wait(timeout: .seconds(5)) {
            !model.isBusy && bController.isEmbedded == selectsAnotherDevice && !aController.isEmbedded
        }
        #expect(main.selectedIdentifiers == [selectsAnotherDevice ? bID : aID])
        #expect(pane.liveDeviceIdentifier == (selectsAnotherDevice ? bID : nil))
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
            outline.item(atRow: $0).map { first.outlineView(outline, shouldSelectItem: $0) } == true
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
        second.update()
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
        let servicesAccessory = try #require(inspector.topAlignedAccessoryViewControllers.compactMap { $0 as? BackgroundServicesAccessoryViewController }.first)
        let searchAccessory = try #require(inspector.topAlignedAccessoryViewControllers.compactMap { $0 as? BackgroundServiceSearchAccessoryViewController }.first)
        #expect(servicesAccessory.isHidden)
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
            #expect(controller.deviceInspector.inspection.isVisible == (!collapsed && (index == 1 || index == 2)))
            #expect(model.selection.showsServices == (!collapsed && index == 3))
            if let page { #expect(controller.deviceInspector.inspection.page == page) }
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
        #expect(!controller.deviceInspector.inspection.isVisible)
        inspector.isCollapsed = false
        #expect(tabs.selectedSegment == 2 && controller.deviceInspector.inspection.isVisible)
        try click(0, collapsed: false)
        #expect(accessory.isHidden)
        let device = simulator()
        let deviceModel = DeviceModel(inventory: device, source: model.registry.source)
        controller.deviceInspector.update(device: deviceModel, isManaging: false, isVisible: true)
        try click(2, collapsed: false, page: .info)
        controller.deviceInspector.update(device: deviceModel, isManaging: false, isVisible: true)
        window.layoutIfNeeded()
        #expect(!accessory.isHidden && accessory.view.frame.height > 0)
        #expect((0..<categories.segmentCount).map { categories.label(forSegment: $0) } == ["Info", "Apps", "Profiles"])
        #expect(!categories.isDescendant(of: controller.deviceInspector.view))
        let informationScroll = try #require(inspectorViews(controller.deviceInspector.view)
            .compactMap { $0 as? NSScrollView }.first { !$0.isHiddenOrHasHiddenAncestor })
        let viewport = informationScroll.convert(informationScroll.bounds, to: nil)
        let accessoryFrame = accessory.view.convert(accessory.view.bounds, to: nil)
        #expect(viewport.maxY > accessoryFrame.minY)
        categories.selectedSegment = 1
        #expect(NSApp.sendAction(try #require(categories.action), to: categories.target, from: categories))
        #expect(controller.deviceInspector.inspection.content == .applications)
        try click(1, collapsed: false, page: .reports)
        #expect(accessory.isHidden)
        model.registry.apply(DeviceInventorySnapshot(devices: [device], issues: []))
        model.inspect(device, selectionCount: 1)
        try click(3, collapsed: false)
        window.layoutIfNeeded()
        #expect(!servicesAccessory.isHidden && !searchAccessory.isHidden)
        #expect(servicesAccessory.view.convert(servicesAccessory.view.bounds, to: nil).maxY <= window.contentLayoutRect.maxY)
        try click(0, collapsed: false)
        #expect(servicesAccessory.isHidden && searchAccessory.isHidden)
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
        let controller = ManagerDeviceInspectorController(model: manager)
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

    @Test func changingProfileCapabilityClearsTheOldKindEvenWhenTheRefreshFails() async throws {
        _ = NSApplication.shared
        func device(features: Set<String>) -> InventoryDevice { inspectedRemote(features: features) }
        let original = device(features: ["provisioningprofiles", "configurationprofiles"])
        let source = ManagerModelSource(devices: [], inspectorResponse:
            #"{"result":{"provisioningProfiles":[{"uuid":"fixture.profile","name":"Fixture"}]}}"#)
        await source.skipSettingsReads()
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source)
        let controller = ManagerDeviceInspectorController(model: manager)
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
        let controller = ManagerDeviceInspectorController(model: manager)
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

    // MARK: Changes confirmed in a sheet

    /// Puts up `action`'s sheet about the first of two listed devices, then selects the second while it waits.
    private func inspectorAskingAboutFirstDevice(action: String, page: DeviceInspectorModel.Page, content: DeviceInspectorModel.Content) async throws
        -> (source: ManagerModelSource, manager: SimulatorManagerModel, controller: ManagerDeviceInspectorController, window: NSWindow, sheet: NSWindow,
            first: InventoryDevice, second: InventoryDevice) {
        _ = NSApplication.shared
        let features: Set<String> = ["streamapplist", "uninstallapp", "configurationprofiles", "listFiles", "transferFiles", "processcontrol", "streamprocesslist"]
        let first = inspectedRemote("first-device", features: features)
        let second = inspectedRemote("second-device", features: features)
        let source = ManagerModelSource(devices: [], inspectorResponse:
            #"{"result":{"apps":[{"bundleIdentifier":"fixture.app","name":"Fixture","containerAccessible":true}],"configurationProfiles":[{"payloadIdentifier":"fixture.configuration","name":"Configuration"}],"files":[{"relativePath":"Fixture.ips","metadata":{},"resources":{"isDirectory":false}}]}}"#)
        await source.skipSettingsReads()
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source)
        let controller = ManagerDeviceInspectorController(model: manager)
        // A sheet only needs a window to attach to; this one is never ordered on screen.
        let window = NSWindow(contentViewController: controller)
        manager.registry.apply(DeviceInventorySnapshot(devices: [first, second], issues: []))
        controller.setPage(page)
        controller.inspection.select(content)
        for device in [first, second] {
            manager.inspect(device, selectionCount: 1)
            let selectedDevice = try #require(manager.registry.device(for: device.id))
            controller.update(device: selectedDevice, isManaging: false, isVisible: true)
            #expect(await events.next() == .inspect(device.id))
            await finishInspectorRead(controller.inspection)
            guard device.id == first.id else { break }
            let table = try #require(inspectorViews(controller.view).compactMap { $0 as? NSTableView }.first {
                $0.accessibilityLabel() == "Installed Applications, Profiles, and Reports"
            })
            try await wait(timeout: .seconds(5)) { table.numberOfRows == 1 }
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            #expect(NSApp.sendAction(NSSelectorFromString(action), to: controller, from: nil))
            try await wait(timeout: .seconds(5)) { window.attachedSheet != nil }
        }
        return (source, manager, controller, window, try #require(window.attachedSheet), first, second)
    }

    // `install:` reaches the same call the same way, but its open panel has no URL until a person picks a file.
    @Test(arguments: [
        ("remove:", DeviceInspectorModel.Page.info, DeviceInspectorModel.Content.applications, ["device", "uninstall", "app", "fixture.app"]),
        ("remove:", .info, .configuration, ["device", "profile", "remove", "fixture.configuration"]),
        ("downloadReport:", .reports, .info, ["device", "copy", "from", "--domain-type", "systemCrashLogs", "--source", "Fixture.ips"]),
        ("exportData:", .info, .applications, ["device", "copy", "from", "--source", "."]),
        ("importData:", .info, .applications, ["device"]),
    ])
    func aChangeConfirmedAfterTheSelectionMovesActsOnTheDeviceItAskedAbout(
        change: (action: String, page: DeviceInspectorModel.Page, content: DeviceInspectorModel.Content, command: [String])) async throws {
        let (source, manager, controller, window, sheet, first, _) = try await inspectorAskingAboutFirstDevice(
            action: change.action, page: change.page, content: change.content)
        var events = source.events.makeAsyncIterator()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory.appending(path: "Chosen"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        await source.holdInspectorReads()
        if let panel = sheet as? NSSavePanel {
            panel.directoryURL = directory
            panel.nameFieldStringValue = "Chosen"
            window.endSheet(panel, returnCode: .OK)
        } else { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
        if change.action == "importData:" {
            try await wait(timeout: .seconds(5)) { window.attachedSheet != nil && window.attachedSheet !== sheet }
            window.endSheet(try #require(window.attachedSheet), returnCode: .alertFirstButtonReturn)
        }
        try await wait(timeout: .seconds(5)) { !manager.managingDeviceIDs.isEmpty }
        try #require(manager.managingDeviceIDs == [first.id])
        #expect(await events.next() == .inspect(first.id))
        let command = try #require(await source.inspectorCommands.last).arguments
        #expect(command.starts(with: change.command))
        #expect(command.contains("first-device") && !command.contains("second-device"))
        await source.failInspectorRead()
        try await wait(timeout: .seconds(5)) { manager.managingDeviceIDs.isEmpty }
        controller.update(device: nil, isManaging: false, isVisible: true)
    }

    @Test func aDeviceRetiredWhileItsSheetWasUpRejectsTheConfirmedChange() async throws {
        let (source, manager, controller, window, sheet, _, second) = try await inspectorAskingAboutFirstDevice(
            action: "remove:", page: .info, content: .applications)
        var failures: [String] = []
        manager.onError = { failures.append($0.localizedDescription) }
        manager.registry.apply(DeviceInventorySnapshot(devices: [second], issues: []))
        window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        try await wait(timeout: .seconds(5)) { !failures.isEmpty }
        #expect(failures == ["first-device: This device is no longer available."])
        #expect(await source.inspectorCommands.allSatisfy { !$0.arguments.contains("uninstall") })
        try await wait(timeout: .seconds(5)) { manager.managingDeviceIDs.isEmpty }
        controller.update(device: nil, isManaging: false, isVisible: true)
    }

    @Test func cancellingAQuitRestoresTheInstallerOfAnApplicationListThatCannotBeRead() async throws {
        _ = NSApplication.shared
        let device = inspectedRemote(features: ["installapp"])
        let source = ManagerModelSource(devices: [], inspectorResponse: Self.inspectionResponse)
        await source.skipSettingsReads()
        let manager = SimulatorManagerModel(source: source)
        let controller = ManagerDeviceInspectorController(model: manager)
        // A quit can be cancelled before the inspector was ever shown.
        controller.resumeAfterCancelledQuit()
        #expect(!controller.isViewLoaded)

        manager.registry.apply(DeviceInventorySnapshot(devices: [device], issues: []))
        manager.inspect(device, selectionCount: 1)
        controller.setPage(.info)
        controller.inspection.select(.applications)
        let selectedDevice = try #require(manager.registry.device(for: device.id))
        controller.update(device: selectedDevice, isManaging: false, isVisible: true)
        let install = try #require(inspectorViews(controller.view).compactMap { $0 as? NSButton }.first { $0.toolTip == "Install…" })
        #expect(install.isEnabled && !install.isHidden)

        try await controller.finishPreviews()
        #expect(!install.isEnabled)
        controller.resumeAfterCancelledQuit()
        #expect(install.isEnabled)
        #expect(await source.inspectorCommands.isEmpty)
        controller.update(device: nil, isManaging: false, isVisible: true)
    }

    // MARK: Inspection state

    private static let inspectionResponse = #"{"result":{"properties":{"name":"Details"},"apps":[{"bundleIdentifier":"fixture.app","name":"Fixture"}],"configurationProfiles":[{"payloadIdentifier":"fixture.configuration","name":"Configuration"}],"provisioningProfiles":[{"uuid":"fixture.provisioning","name":"Provisioning"}],"files":[{"relativePath":"Fixture.ips","metadata":{},"resources":{"isDirectory":false}}]}}"#

    private func inspectedRemote(_ identifier: String = "inspected-device", connection: String = "connected",
                                 features: Set<String> = ["streamapplist", "configurationprofiles", "provisioningprofiles", "listFiles"]) -> InventoryDevice {
        .remote(CoreDeviceDevice(identifier: identifier, udid: nil, kind: .physical, name: identifier, reportedName: identifier,
            modelIdentifier: nil, modelName: nil, cpuType: nil, platform: "iOS", osVersion: nil, osBuild: nil, osBuildUpdate: nil,
            connectionState: connection, pairingState: "paired", transportType: nil, bootState: "booted", preparednessState: nil,
            capabilities: Set(features.map { "com.apple.coredevice.feature." + $0 }), lastConnectedAt: nil, visibilityClass: nil))
    }

    private func applications(_ names: String...) -> String {
        #"{"result":{"apps":["# + names.map { #"{"bundleIdentifier":"fixture.\#($0)","name":"\#($0)"}"# }.joined(separator: ",") + "]}}"
    }

    private func listing(_ device: InventoryDevice..., response: String = ManagerModelTests.inspectionResponse) -> (ManagerModelSource, DeviceRegistry) {
        let source = ManagerModelSource(devices: [], inspectorResponse: response)
        let registry = DeviceRegistry(source: source)
        registry.apply(DeviceInventorySnapshot(devices: device, issues: []))
        return (source, registry)
    }

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
        #expect(app.model.status?.preferredHost == .neo)
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
        window.update()
        let content = try #require(window.window?.contentView)
        let start = try #require(inspectorViews(content).compactMap { $0 as? NSButton }.first { $0.title == "Start" })
        try #require(start.isEnabled)
        start.performClick(nil)
        #expect(await events.next() == .open(stopped.id))
        #expect(await source.lastOpenBootIfNeeded == true)
        manager.cancelOpening(running.id)
        #expect(source.cancelledOpenIDs == [running.id])
        await source.completeOpen(for: stopped.id)
        try await wait { !manager.openingDeviceIDs.contains(stopped.id) }
        #expect(manager.openingDeviceIDs == [running.id])
        await source.completeOpen(for: running.id)
        try await wait { !manager.isBusy }
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

    /// A read that reports its process identifier to the returned task and then never exits by itself.
    private func unresponsiveRead(in directory: URL) throws -> (command: SystemCommand, identifier: Task<Int32?, any Error>) {
        let ready = directory.appending(path: "ready-\(UUID().uuidString)")
        try #require(mkfifo(ready.path, 0o600) == 0)
        let identifier = Task {
            let data = try await performBlockingIO { try FileHandle(forReadingFrom: ready).readToEnd() ?? Data() }
            return Int32(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (SystemCommand(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '%s\\n' \"$$\" > \"$1\"; exec /bin/sleep 300", "fixture", ready.path], policy: .cancellable), identifier)
    }

    /// A registry with `devices`, and the first device's model, whose settings stay current while the test runs.
    private func settingsFixture(_ source: ManagerModelSource) async throws -> (registry: DeviceRegistry, model: DeviceModel, interest: DeviceReadInterest) {
        let registry = DeviceRegistry(source: source)
        try await registry.refresh()
        let model = try #require(registry.devices.first)
        return (registry, model, model.keepCurrent(.settings))
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
        #expect(await events.next() == .read(first.id))
        var settings = SimulatorDeviceSettings(appearance: .light, boldText: false, liquidGlassOpacity: 0.5)
        settings.colorFilterRequiredOSVersion = 27
        await source.completeRead(settings)
        await manager.registry.finishReading()
        #expect(panel.colorFilterRequirement == "OS 27+")
        let toggle = try #require(panel.binding(for: \.boldText))
        let picker = try #require(panel.binding(for: \.appearance))
        let slider = try #require(panel.binding(for: \.liquidGlassOpacity))

        manager.inspect(deselect ? nil : second, selectionCount: deselect ? 0 : 1)
        #expect(panel.boldText == nil && panel.appearance == nil && panel.liquidGlassOpacity == nil)
        #expect(panel.colorFilterRequirement.isEmpty)
        #expect(toggle.wrappedValue == false)
        #expect(picker.wrappedValue == "light")
        #expect(slider.wrappedValue == 0.5)
        toggle.wrappedValue = true
        picker.wrappedValue = "dark"
        slider.wrappedValue = 0.75
        if !deselect {
            #expect(await events.next() == .read(second.id))
            await source.completeRead(SimulatorDeviceSettings(appearance: .dark, boldText: true, liquidGlassOpacity: 1))
            await manager.registry.finishReading()
            #expect(toggle.wrappedValue == false && picker.wrappedValue == "light" && slider.wrappedValue == 0.5)
            toggle.wrappedValue = false
            picker.wrappedValue = "light"
            slider.wrappedValue = 0
            #expect(panel.boldText == true && panel.appearance == "dark" && panel.liquidGlassOpacity == 1)
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
        let toggle = try #require(panel.binding(for: \.boldText))
        let picker = try #require(panel.binding(for: \.appearance))
        let slider = try #require(panel.binding(for: \.textSize))
        let medium = Double(try #require(DeviceContentSize.allCases.firstIndex(of: .medium)))
        let large = Double(try #require(DeviceContentSize.allCases.firstIndex(of: .large)))

        toggle.wrappedValue = true
        picker.wrappedValue = "dark"
        slider.wrappedValue = large
        #expect(toggle.wrappedValue == true && picker.wrappedValue == "dark" && slider.wrappedValue == large)
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
            await source.completeRead(SimulatorDeviceSettings(appearance: .dark, contentSize: .large, boldText: true))
        }
        try await awaitServiceOperations(manager)
        await manager.registry.finishReading()
        #expect(panel.boldText == true && panel.appearance == "dark" && panel.textSize == large)

        await source.setDevices([simulator(state: "Shutdown")])
        await manager.refresh()
        #expect(panel.content == .unavailable)
        toggle.wrappedValue = false
        picker.wrappedValue = "light"
        slider.wrappedValue = medium
        await source.setDevices([device])
        await manager.refresh()
        #expect(await events.next() == .read(device.id))
        await source.completeRead(SimulatorDeviceSettings())
        await manager.registry.finishReading()
        #expect(panel.content == .unavailable)
        #expect(panel.binding(for: \.boldText) == nil)
        #expect(panel.binding(for: \.appearance) == nil)
        #expect(panel.binding(for: \.textSize) == nil)
        #expect(toggle.wrappedValue == false && picker.wrappedValue == "light" && slider.wrappedValue == medium)
        toggle.wrappedValue = true
        picker.wrappedValue = "dark"
        slider.wrappedValue = large
        try await manager.prepareForQuit()
        #expect(await source.writtenChanges.count == 3)
        #expect(manager.selection.device?.settings.boldText == nil)
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

    // MARK: Device state ownership

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

    @Test func aHostOperationFollowsAcceptedWritesAndHoldsLaterOnesOfItsDevice() async throws {
        let first = simulator(deviceSet: "/first")
        let second = simulator(deviceSet: "/second")
        let source = ManagerModelSource(devices: [first, second])
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source)
        await manager.refresh()
        manager.setDeviceSetting(.appearance(.dark), for: first.id)
        #expect(await events.next() == .write(first.id))
        manager.closeDevice(first.id, keepingDeviceRunning: true, after: Task {})
        #expect(!manager.canEditSettings(for: first.id) && manager.canEditSettings(for: second.id))
        // The close waits for the edit accepted before it. The edit accepted after it waits for the close.
        manager.setDeviceSetting(.boldText(true), for: first.id)
        manager.setDeviceSetting(.boldText(true), for: second.id)
        #expect(await events.next() == .write(second.id))
        await source.completeWrite(for: second.id)
        #expect(await events.next() == .read(second.id))
        await source.completeRead(SimulatorDeviceSettings(boldText: true), for: second.id)
        await source.completeWrite(for: first.id)
        // The finished edit's read does not wait for what follows it, which stays in order.
        let started = [await events.next(), await events.next(), await events.next()]
        #expect(started.filter { $0 != .read(first.id) } == [.close(first.id), .write(first.id)])
        await source.completeRead(SimulatorDeviceSettings(appearance: .dark), for: first.id)
        await source.completeWrite(for: first.id)
        #expect(await events.next() == .read(first.id))
        await source.completeRead(SimulatorDeviceSettings(appearance: .dark, boldText: true), for: first.id)
        try await manager.prepareForQuit()
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

    /// What a screen does as it connects: it reports its own record of the device, and shows the model it gets back.
    private func connectScreen(_ registry: DeviceRegistry, booted: Bool, name: String = "Test Phone", lastBootDate: Date? = nil) -> DeviceModel {
        let record = AvailableDevice(identifier: "same-udid", name: name, descriptiveName: name, runtimeIdentifier: "test-runtime",
                                     runtimeName: "iOS", productFamily: 1, deviceTypeName: "Phone", state: booted ? 3 : 1, deviceSetPath: nil)
        return registry.presentedModel(of: record, lastBootDate: lastBootDate, ownerXcodeURL: URL(fileURLWithPath: "/Screen Xcode.app"),
            channel: SimulatorDeviceChannel(scope: .device(DeviceAddress(identifier: "same-udid", deviceSetPath: nil))))
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
            unchosen: .init(profileID: ServiceProfile.allServices.id, base: ServiceConfiguration(),
                            overrides: ["com.apple.searchd": false], requestID: UUID(), pendingApplication: false),
            pendingDefault: .init(profileID: ServiceProfile.allServices.id, base: ServiceConfiguration(),
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
        #expect(store.selection(for: pendingDefault) == .profile(ServiceProfile.allServices.id))
        #expect(store.configuration(for: pendingDefault) == ServiceConfiguration())
        #expect(store.availableProfiles.first === ServiceProfile.allServices)
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
        let table = try #require(inspectorViews(controller.view).compactMap { $0 as? NSTableView }
            .first { !($0 is NSOutlineView) })
        let accessory = try #require(controller.splitViewItems.first?.topAlignedAccessoryViewControllers.first)
        let defaultMenu = try #require(inspectorViews(accessory.view).compactMap { $0 as? NSPopUpButton }.first)
        #expect(controller.tableView(table, pasteboardWriterForRow: 0) == nil)
        let writer = try #require(controller.tableView(table, pasteboardWriterForRow: 3))
        let drag = TestDraggingInfo(item: writer, source: table)
        defer { drag.draggingPasteboard.releaseGlobally() }
        #expect(controller.tableView(table, validateDrop: drag, proposedRow: 1, proposedDropOperation: .above) == .move)
        #expect(!controller.tableView(table, acceptDrop: drag, row: 0, dropOperation: .above))
        #expect(controller.tableView(table, acceptDrop: drag, row: 1, dropOperation: .above))
        try await wait(timeout: .seconds(5)) {
            table.selectedRow == 3
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
        #expect(inspector.savedProfileChoices.map(\.id) == [.profile(third.id), .profile(first.id), .profile(second.id)])

        let downwardWriter = try #require(controller.tableView(table, pasteboardWriterForRow: 2))
        let downward = TestDraggingInfo(item: downwardWriter, source: table)
        defer { downward.draggingPasteboard.releaseGlobally() }
        #expect(controller.tableView(table, acceptDrop: downward, row: 4, dropOperation: .above))
        let restored = ServiceProfileStore(fileURL: fileURL, legacyDefaults: nil)
        #expect(restored.profiles.map(\.id) == [third.id, second.id, first.id])
        #expect(controller.model.selectedProfile === second)
        drag.draggingSource = nil
        #expect(controller.tableView(table, validateDrop: drag, proposedRow: 1, proposedDropOperation: .above).isEmpty)

        try store.update(first.id, name: ServiceProfile.allServices.name, configuration: first.configuration)
        try store.update(third.id, name: ServiceProfile.allServices.name, configuration: third.configuration)
        try await wait(timeout: .seconds(5)) {
            defaultMenu.itemArray.compactMap { $0.representedObject as? UUID } == store.availableProfiles.map(\.id)
                && defaultMenu.itemTitles == store.availableProfiles.map(\.name)
        }
        let choice = try #require(defaultMenu.itemArray.first { $0.representedObject as? UUID == first.id })
        defaultMenu.select(choice)
        #expect(NSApp.sendAction(try #require(defaultMenu.action), to: defaultMenu.target, from: defaultMenu))
        #expect(store.defaultProfile === first)
    }

    @Test func serviceProfilesKeepDeviceOverridesAcrossSwitchesAndRelaunch() throws {
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
        try store.assign(.profile(full.id), to: first)
        // A matching base value must not discard an explicit per-device choice.
        #expect(store.binding(for: first)?.overrides[label] == true)
        try store.assign(.profile(slim.id), to: first)
        let restored = ServiceProfileStore(fileURL: serviceProfileURL(domain), legacyDefaults: defaults)
        #expect(restored.profiles.map(\.id) == store.profiles.map(\.id))
        #expect(restored.profiles.map(\.name) == store.profiles.map(\.name))
        #expect(restored.profiles.map(\.configuration) == store.profiles.map(\.configuration))
        #expect(restored.configuration(for: first)?.disabledLabels == [])
        #expect(restored.configuration(for: second)?.disabledLabels == [label])
        try restored.assign(.profile(slim.id), to: first, preservingOverrides: false)
        #expect(restored.configuration(for: first)?.disabledLabels == [label])
    }

    @Test func devicesInheritTheCommonProfileBelowTheirOverridesUntilTheyChooseOtherwise() throws {
        let domain = "NeoSimulator.CommonServiceProfile.\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: serviceProfileURL(domain).deletingLastPathComponent()) }
        let store = ServiceProfileStore(fileURL: serviceProfileURL(domain), legacyDefaults: nil)
        let device = simulator().id
        let label = "com.apple.searchd"
        let other = "com.apple.searchtoold"
        #expect(store.defaultProfile === ServiceProfile.allServices && store.selection(for: device) == .inheritDefault)
        #expect(store.defaultProfile.name == "All Services")

        // All Services is the default; an individual change stays an inherited override.
        try store.record([.service(label)], enabled: false, for: device, productFamily: "iPhone")
        #expect(store.binding(for: device) == DeviceServiceProfile(selection: .inheritDefault, overrides: [label: false]))
        #expect(store.resolvedProfile(for: device) === ServiceProfile.allServices)
        #expect(store.configuration(for: device)?.disabledLabels == [label])

        let common = try store.create(name: "Common", configuration: ServiceConfiguration())
        try store.setDefaultProfile(common.id)
        #expect(store.resolvedProfile(for: device) === common)
        #expect(store.configuration(for: device)?.disabledLabels == [label])

        // A choice that matches the profile today stays explicit when the profile changes.
        try store.record([.service(other)], enabled: true, for: device, productFamily: "iPhone")
        try store.update(common.id, configuration: ServiceConfiguration(disabledLabels: [other]))
        #expect(store.configuration(for: device)?.disabledLabels == [label])

        let oldSelection = try JSONSerialization.data(withJSONObject: [
            "selection": ["doNotApply": [:]], "overrides": [label: false],
        ])
        let inherited = try JSONDecoder().decode(DeviceServiceProfile.self, from: oldSelection)
        #expect(inherited == DeviceServiceProfile(selection: .inheritDefault, overrides: [label: false]))

        // A named profile is independent of the app-wide default.
        let named = try store.create(name: "Named", configuration: ServiceConfiguration())
        try store.setDefaultProfile(ServiceProfile.allServicesID)
        try store.assign(.profile(named.id), to: device)
        #expect(store.configuration(for: device)?.disabledLabels == [label])

        try store.setDefaultProfile(common.id)
        try store.assign(.inheritDefault, to: device)
        let restored = ServiceProfileStore(fileURL: serviceProfileURL(domain), legacyDefaults: nil)
        #expect(restored.defaultProfile.id == common.id)
        #expect(restored.selection(for: device) == .inheritDefault)
        #expect(restored.configuration(for: device)?.disabledLabels == [label])

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
        #expect(store.profile(ServiceProfile.allServices.id)?.configuration.disabledLabels.isEmpty == true)
        #expect(store.availableProfiles.count == 1 && store.availableProfiles.first === ServiceProfile.allServices)
        try store.record([.service(label)], enabled: false, for: device, productFamily: "iPhone")
        let changed = try #require(store.binding(for: device))
        #expect(changed.selection == .inheritDefault)
        #expect(changed.overrides == [label: false])
        let saved = try store.create(name: "Focused", configuration: ServiceConfiguration().applying(changed.overrides), assigningTo: device)
        let restored = ServiceProfileStore(fileURL: serviceProfileURL(domain), legacyDefaults: defaults)
        #expect(restored.binding(for: device) == DeviceServiceProfile(selection: .profile(saved.id)))
        #expect(restored.configuration(for: device)?.disabledLabels == [label])
        try restored.assign(.profile(ServiceProfile.allServices.id), to: device)
        #expect(restored.configuration(for: device)?.disabledLabels.isEmpty == true)
        #expect(restored.binding(for: device)?.overrides.isEmpty == true)
        #expect(restored.profile(saved.id)?.configuration.disabledLabels == [label])
    }

    @Test func savingAnExistingProfileOverwritesItAndKeepsOtherDevicesUnchanged() throws {
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

        try restored.assign(.profile(profile.id), to: second, preservingOverrides: false)
        #expect(restored.configuration(for: second) == current)
        #expect(restored.binding(for: second)?.overrides.isEmpty == true)
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
        controller.isVisible = true
        let accessory = BackgroundServicesAccessoryViewController(model: model)
        accessory.isActive = true
        let pane = NSSplitViewItem(inspectorWithViewController: controller)
        pane.minimumThickness = 280
        pane.maximumThickness = 440
        pane.addTopAlignedAccessoryViewController(accessory)
        pane.addTopAlignedAccessoryViewController(controller.searchAccessory)
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
        let outline = try #require(controller.children.compactMap { $0 as? BackgroundServiceOutlineController }.first)
        #expect(pane.topAlignedAccessoryViewControllers.first === accessory)
        #expect(!accessory.isHidden && accessory.view.frame.height > 0)
        #expect(accessory.view.window === window)
        #expect(!accessory.view.isDescendant(of: controller.view))
        #expect(outline.view.bounds.height > 100)
        let columnWidth = try #require(outline.outline.tableColumns.first).width
        outline.outline.expandItem(category)
        view.layoutSubtreeIfNeeded()
        #expect(category.isExpanded)
        #expect(outline.outline.tableColumns.first?.width == columnWidth)
        let widgets = try #require(model.categories.first { $0.id == "widgets" })
        widgets.isExpanded = false
        let search = controller.searchAccessory.searchField
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
        toggle.state = .off
        let action = try #require(toggle.action)
        #expect(NSApp.sendAction(action, to: toggle.target, from: toggle))
        #expect(await events.next() == .changeServices(device.id))

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
        #expect(model.savedProfileChoices.map(\.id) == [.profile(saved.id)])
        #expect(settings.settings.serviceProfiles.model.store.profile(saved.id) === saved)
        #expect(model.selectedProfileTitle == "Development")

        model.setServices([.service(item.label)], enabled: true)
        #expect(await events.next() == .changeServices(device.id))
        await source.completeServiceChange(disabled: [])
        try await awaitServiceOperations(manager)
        #expect(model.selectedProfileTitle == "Development (Modified)")
        model.saveProfile()
        #expect(store.profiles.count == 1 && store.profiles.first?.id == saved.id)
        #expect(store.profiles.first?.configuration.disabledLabels.isEmpty == true)
        #expect(!model.hasProfileChanges)
        let binding = store.binding(for: device.id)
        model.profileEditor = nil
        model.openProfileSettings()
        #expect(settings.settings.selectedTabViewItemIndex == 3)
        #expect(settings.settings.serviceProfiles.model.selectedProfile === saved)
        #expect(store.binding(for: device.id) == binding)
        #expect(model.selectedProfileSelection == .profile(saved.id))
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
        controller.model.create()
        try await wait(timeout: .seconds(5)) {
            guard let field = window.firstResponder as? NSTextView else { return false }
            return field.string == "Profile (1)" && field.selectedRange() == NSRange(location: 0, length: 11)
        }
        #expect(window.attachedSheet == nil)
        let first = controller.model.selectedProfile
        let field = try #require(window.firstResponder as? NSTextView)
        #expect(field.enabledTextCheckingTypes == 0)
        field.string = "Focused"
        let table = try #require(inspectorViews(controller.view).compactMap { $0 as? NSTableView }
            .first { !($0 is NSOutlineView) })
        window.makeFirstResponder(table)
        #expect(first.name == "Focused")
        #expect(search.stringValue == "com.apple.searchd")
        let details = try #require(controller.splitViewItems[1].viewController.children.compactMap { $0 as? BackgroundServiceOutlineController }.first)
        let filtered = try #require(details.model.sections.first?.items.first)
        filtered.setEnabled(false)
        #expect(first.configuration.disabledLabels == ["com.apple.searchd"])
        #expect(ServiceProfile.allServices.configuration.disabledLabels.isEmpty)
        controller.model.create()
        #expect(controller.model.selectedProfile.name == "Profile (1)")
        controller.model.create()
        #expect(controller.model.selectedProfile.name == "Profile (2)")
    }

    @Test func selectingDefaultEnablesEveryServiceExceptTheOverriddenOnes() async throws {
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
        manager.selectServiceProfile(.profile(ServiceProfile.allServices.id), for: device.id)
        #expect(await events.next() == .readServices(device.id))
        await source.completeServiceRead(disabled: [label, other])
        #expect(await events.next() == .changeServices(device.id))
        await source.completeServiceChange(disabled: [label])
        try await awaitServiceOperations(manager)
        #expect(store.binding(for: device.id) == DeviceServiceProfile(selection: .profile(ServiceProfile.allServices.id), overrides: [label: false]))
        #expect(manager.selection.device?.backgroundServices.configuration?.disabledLabels == [label])
        #expect(await source.serviceChanges == [.init(targets: [.service(other)], enabled: true)])
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
        #expect(store.binding(for: device.id)?.overrides[label] == true)
        #expect(manager.selection.device?.backgroundServices.configuration?.disabledLabels == [other])
        #expect(await source.serviceChanges == [.init(targets: [.service(other)], enabled: false)])
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

        // An edit waits for the next boot.
        try store.update(profile.id, name: profile.name, configuration: ServiceConfiguration(disabledLabels: ["com.apple.searchtoold"]))
        await manager.refresh()
        #expect(!services.isChanging)
        await source.setDevices([simulator(state: "Shutdown")])
        await manager.refresh()
        await source.setDevices([simulator()])
        await manager.refresh()
        #expect(await events.next() == .changeServices(stopped.id))
        #expect(await source.serviceChanges == [.init(targets: [.service("com.apple.searchd")], enabled: false),
                                                .init(targets: [.service("com.apple.searchtoold")], enabled: false)])
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

    @Test func aFailedStartupProfileIsReportedOnceAndWaitsForTheNextBootOrChoice() async throws {
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
        await source.failServiceChange(disabled: [])
        try await wait(timeout: .seconds(5)) { failures == 1 }
        await manager.refresh()
        #expect(manager.registry.device(for: device.id)?.backgroundServices.isChanging == false)
        #expect(await source.serviceChanges.count == 1 && failures == 1)

        await source.setDevices([simulator(lastBootDate: Date(timeIntervalSinceNow: -10))])
        await manager.refresh()
        #expect(await events.next() == .changeServices(device.id))
        await source.completeServiceChange(disabled: [label])
        try await awaitServiceOperations(manager)

        manager.selectServiceProfile(.inheritDefault, for: device.id)
        #expect(await events.next() == .changeServices(device.id))
        await source.completeServiceChange(disabled: [label])
        try await awaitServiceOperations(manager)
        #expect(failures == 1)
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

    @Test func choosingAProfileWritesOnlyWhatResolvesAndEditingACommonChoiceWritesNothing() async throws {
        let domain = "NeoSimulator.ChosenProfile.\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: serviceProfileURL(domain).deletingLastPathComponent()) }
        let store = ServiceProfileStore(fileURL: serviceProfileURL(domain), legacyDefaults: nil)
        let label = "com.apple.searchd"
        let device = simulator()
        let source = ManagerModelSource(devices: [device])
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source, serviceProfiles: store)
        await manager.refresh()
        let services = try #require(manager.registry.device(for: device.id)?.backgroundServices)

        manager.selectServiceProfile(.inheritDefault, for: device.id)
        try await awaitServiceOperations(manager)
        #expect(!services.isChanging && store.defaultProfile === ServiceProfile.allServices)
        let common = try store.create(name: "Common", configuration: ServiceConfiguration(disabledLabels: [label]))
        try store.setDefaultProfile(common.id)
        await manager.refresh()
        #expect(!services.isChanging)

        manager.selectServiceProfile(.inheritDefault, for: device.id)
        #expect(services.isChanging)
        #expect(await events.next() == .changeServices(device.id))
        await source.completeServiceChange(disabled: [label])
        try await awaitServiceOperations(manager)

        // Reverting clears explicit overrides and reapplies the inherited definition.
        manager.setBackgroundServices([.service(label)], enabled: false, for: device.id)
        #expect(await events.next() == .changeServices(device.id))
        await source.completeServiceChange(disabled: [label])
        try await awaitServiceOperations(manager)
        #expect(store.binding(for: device.id) == DeviceServiceProfile(selection: .inheritDefault, overrides: [label: false]))
        manager.revertServiceProfile(for: device.id)
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

    private func awaitServiceOperations(_ manager: SimulatorManagerModel) async throws {
        try await wait(timeout: .seconds(5)) {
            !manager.isBusy && manager.managingDeviceIDs.isEmpty
                && !manager.registry.devices.contains { $0.backgroundServices.isChanging }
        }
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
        await source.completeServiceRead(disabled: ["com.apple.bird"])
        await manager.registry.finishReading()

        manager.setBackgroundServices([.category("store")], enabled: false, for: device.id)
        #expect(await events.next() == .changeServices(device.id))
        await source.completeServiceChange(disabled: ["com.apple.bird", "com.apple.amsaccountsd"])
        try await awaitServiceOperations(manager)
        let profile = try store.create(name: "Development", configuration: ServiceConfiguration())
        try store.assign(.profile(profile.id), to: device.id)
        #expect(store.configuration(for: device.id)?.disabledLabels.contains("com.apple.amsaccountsd") == true)
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

    private struct LegacyServiceProfiles: Encodable {
        struct Binding: Encodable {
            let profileID: UUID
            let base: ServiceConfiguration
            let overrides: [String: Bool]
            let requestID: UUID
            let pendingApplication: Bool
        }
        let profiles: [ServiceProfile.Record]
        let devices: [DeviceInventoryID: Binding]
    }

    private func serviceProfileURL(_ domain: String) -> URL {
        URL.temporaryDirectory.appending(path: domain, directoryHint: .isDirectory)
            .appending(path: "ServiceProfiles.json")
    }

    private func simulator(deviceSet: String? = nil, name: String = "Test Phone", state: String = "Booted",
                           lastUsedAt: Date? = nil, lastBootDate: Date? = nil, createdAt: Date? = nil) -> InventoryDevice {
        .simulator(SimulatorHostDevice(identifier: "same-udid", name: name, descriptiveName: name,
            runtimeIdentifier: "test-runtime", runtimeName: "iOS", productFamily: "iPhone", state: state,
            deviceSetPath: deviceSet, lastUsedAt: lastUsedAt, lastBootDate: lastBootDate, createdAt: createdAt, capabilities: ["com.apple.dt.coredevice.device.shutdown"]))
    }

    private func settings(appearance: DeviceAppearance, contentSize: DeviceContentSize? = nil) -> SimulatorDeviceSettings {
        SimulatorDeviceSettings(appearance: appearance, contentSize: contentSize)
    }
}

private struct ServiceChangeSource: DeviceStateSource {
    let device: InventoryDevice
    let backend: SimulatorBackgroundServiceBackend
    func inventory() -> DeviceInventorySnapshot { DeviceInventorySnapshot(devices: [device], issues: []) }
    func readSettings(_ groups: Set<DeviceSettingsGroup>, of device: InventoryDevice,
                      publish: @escaping @concurrent @Sendable (DeviceSettingsGroupRead) async -> Void) async {}
    func write(_ change: DeviceSettingChange, to device: InventoryDevice) async throws {}
    func backgroundServices(for device: InventoryDevice) async throws -> SimulatorBackgroundServices { try await backend.read() }
    func setBackgroundServices(_ targets: [SimulatorBackgroundServiceTarget], enabled: Bool,
                               for device: InventoryDevice) async throws -> SimulatorBackgroundServicesUpdate {
        try await backend.update(targets, enabled: enabled)
    }
    func inspector(for device: InventoryDevice) -> DeviceInspector { DeviceInspector(device: device, simulatorXcodeURL: nil) }
    func stopReads() {}
    func resumeReads() {}
}

actor ManagerModelSource: SimulatorManagerSource {
    private var failsSessionStart = false
    private(set) var sessionEvents: [String] = []
    func failSessionStart() { failsSessionStart = true }
    func beginSession() throws {
        sessionEvents.append("begin")
        if failsSessionStart { throw Failure.unavailable }
    }
    func endSession() { sessionEvents.append("end") }
    private nonisolated let cancelledOpens = Mutex<Set<DeviceInventoryID>>([])
    nonisolated var cancelledOpenIDs: Set<DeviceInventoryID> { cancelledOpens.withLock { $0 } }
    enum Event: Equatable, Sendable { case read(DeviceInventoryID), write(DeviceInventoryID), open(DeviceInventoryID), close(DeviceInventoryID), inspect(DeviceInventoryID), inventory, quit, manage(DeviceManagementAction, [DeviceInventoryID]), readServices(DeviceInventoryID), changeServices(DeviceInventoryID) }
    struct ServiceChange: Equatable, Sendable {
        let targets: [SimulatorBackgroundServiceTarget]
        let enabled: Bool
    }
    enum Failure: LocalizedError {
        case unavailable, native
        var errorDescription: String? { self == .native ? "Native shutdown failed" : "Unavailable" }
    }
    nonisolated let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private var devices: [InventoryDevice]
    private var inspectorResponse: String?
    private var holdsInspectorReads = false
    private var inspectorReads: [(device: DeviceInventoryID, finished: CheckedContinuation<CommandOutput, any Error>)] = []
    private(set) var inspectorCommands: [DeviceInspectorCommand] = []
    private var holdsInventoryReads = false
    private var inventoryRead: CheckedContinuation<Void, Never>?
    private var holdsManagement = false
    private var failsClose = false
    private var immediateRead: SimulatorDeviceSettings?
    private var skipsSettingsReads = false
    /// A batch of settings reads that a test holds, and answers whole or a group at a time.
    private struct HeldRead {
        let device: DeviceInventoryID
        var groups: Set<DeviceSettingsGroup>
        let publish: @concurrent @Sendable (DeviceSettingsGroupRead) async -> Void
        let finished: CheckedContinuation<Void, Never>
    }
    private var heldReads: [HeldRead] = []
    private var openContinuations: [(DeviceInventoryID, CheckedContinuation<Void, any Error>)] = []
    private var heldWrites: [(device: DeviceInventoryID, finished: CheckedContinuation<Void, any Error>)] = []
    private(set) var writtenChanges: [DeviceSettingChange] = []
    private var holdsServiceReads = false
    private var serviceReads: [(device: DeviceInventoryID, finished: CheckedContinuation<SimulatorBackgroundServices, any Error>)] = []
    private var serviceChange: CheckedContinuation<SimulatorBackgroundServicesUpdate, any Error>?
    private(set) var serviceChanges: [ServiceChange] = []
    private(set) var readCount = 0
    /// Settings groups read, however they were batched.
    private(set) var groupReadCount = 0
    private(set) var quitCount = 0
    private(set) var lastOpenXcodeURL: URL?
    private(set) var lastOpenBootIfNeeded: Bool?
    private(set) var artworkXcodeRequests: [DeviceInventoryID] = []
    private(set) var installedXcodeReadCount = 0
    private(set) var managementRequests = 0
    private(set) var preparationRequests = 0
    private let managementFailureID: DeviceInventoryID?
    private var failingSimulatorCommand: String?
    private var managementWaiters: [(DeviceManagementAction, [DeviceInventoryID], CheckedContinuation<Void, Never>)] = []
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
    private nonisolated let reads = CommandReads()
    private var heldRead: SystemCommand?
    nonisolated func stopReads() { reads.stop() }
    nonisolated func resumeReads() { reads.resume() }
    /// Inventory and management catalog reads wait for this command, through the production read boundary.
    func holdReads(in command: SystemCommand?) { heldRead = command }
    private func readThroughHeldCommand() async throws {
        if let heldRead { _ = try await reads.run(heldRead) }
    }
    func inventory() async throws -> DeviceInventorySnapshot {
        try await readThroughHeldCommand()
        if holdsInventoryReads {
            await withCheckedContinuation { waiting in
                inventoryRead = waiting
                continuation.yield(.inventory)
            }
        }
        return DeviceInventorySnapshot(devices: devices, issues: [])
    }
    func holdInventoryReads() { holdsInventoryReads = true }
    func completeInventoryRead() {
        holdsInventoryReads = false
        inventoryRead?.resume()
        inventoryRead = nil
    }
    func status() -> SimulatorHostStatus {
        sessionEvents.append("status")
        return SimulatorHostStatus(host: failsSessionStart ? .deviceHub : .neo, preferredHost: .neo,
                                   restorationAvailable: false, rendererRunning: false)
    }
    func readSettings(_ groups: Set<DeviceSettingsGroup>, of device: InventoryDevice,
                      publish: @escaping @concurrent @Sendable (DeviceSettingsGroupRead) async -> Void) async {
        if skipsSettingsReads { return }
        readCount += 1
        groupReadCount += groups.count
        if let immediateRead {
            self.immediateRead = nil
            continuation.yield(.read(device.id))
            for group in groups { await publish(.values(group) { $0.replace(group, with: immediateRead) }) }
            return
        }
        await withCheckedContinuation { waiting in
            heldReads.append(HeldRead(device: device.id, groups: groups, publish: publish, finished: waiting))
            continuation.yield(.read(device.id))
        }
    }
    func returnOnNextRead(_ settings: SimulatorDeviceSettings) { immediateRead = settings }
    /// For a test of something else: settings reads answer nothing, at once and without an event.
    func skipSettingsReads() { skipsSettingsReads = true }
    /// Answers what the oldest held read of `device` still waits for.
    func completeRead(_ settings: SimulatorDeviceSettings, for device: DeviceInventoryID? = nil) async {
        guard let index = heldReads.firstIndex(where: { device == nil || $0.device == device }) else { return }
        let read = heldReads.remove(at: index)
        for group in read.groups { await read.publish(.values(group) { $0.replace(group, with: settings) }) }
        read.finished.resume()
    }
    /// Answers one group of the oldest held read that has it, which ends once nothing is left to answer.
    func publishRead(_ result: DeviceSettingsGroupRead) async {
        guard let index = heldReads.firstIndex(where: { $0.groups.contains(result.group) }) else { return }
        heldReads[index].groups.remove(result.group)
        let read = heldReads[index]
        if read.groups.isEmpty { heldReads.remove(at: index) }
        await read.publish(result)
        if read.groups.isEmpty { read.finished.resume() }
    }
    /// What each held read still waits for, oldest first.
    var heldReadGroups: [Set<DeviceSettingsGroup>] { heldReads.map(\.groups) }
    func write(_ change: DeviceSettingChange, to device: InventoryDevice) async throws {
        writtenChanges.append(change)
        switch change {
        case .appearance, .contentSize, .boldText, .showBorders, .reduceTransparency: break
        default: throw Failure.unavailable
        }
        try await withCheckedThrowingContinuation { waiting in
            heldWrites.append((device.id, waiting))
            continuation.yield(.write(device.id))
        }
    }
    func completeWrite(for device: DeviceInventoryID? = nil) {
        guard let index = heldWrites.firstIndex(where: { device == nil || $0.device == device }) else { return }
        heldWrites.remove(at: index).finished.resume()
    }
    func failWrite() {
        guard !heldWrites.isEmpty else { return }
        heldWrites.removeFirst().finished.resume(throwing: Failure.unavailable)
    }
    /// Background service reads return no overrides at once unless a test holds them.
    func holdServiceReads() { holdsServiceReads = true }
    func backgroundServices(for device: InventoryDevice) async throws -> SimulatorBackgroundServices {
        guard holdsServiceReads else { return SimulatorBackgroundServices(disabled: [], loaded: [], productFamily: "iPhone") }
        return try await withCheckedThrowingContinuation { waiting in
            serviceReads.append((device.id, waiting))
            continuation.yield(.readServices(device.id))
        }
    }
    func completeServiceRead(disabled: Set<String>, loaded: Set<String> = [], for device: DeviceInventoryID? = nil) {
        guard let index = serviceReads.firstIndex(where: { device == nil || $0.device == device }) else { return }
        serviceReads.remove(at: index).finished.resume(returning: SimulatorBackgroundServices(disabled: disabled, loaded: loaded, productFamily: "iPhone"))
    }
    func failServiceRead() {
        guard !serviceReads.isEmpty else { return }
        serviceReads.removeFirst().finished.resume(throwing: Failure.unavailable)
    }
    func setBackgroundServices(_ targets: [SimulatorBackgroundServiceTarget], enabled: Bool,
                               for device: InventoryDevice) async throws -> SimulatorBackgroundServicesUpdate {
        serviceChanges.append(ServiceChange(targets: targets, enabled: enabled))
        return try await withCheckedThrowingContinuation { waiting in
            serviceChange = waiting
            continuation.yield(.changeServices(device.id))
        }
    }
    func completeServiceChange(disabled: Set<String>, notStarted: [String] = []) {
        let waiting = serviceChange
        serviceChange = nil
        waiting?.resume(returning: SimulatorBackgroundServicesUpdate(
            services: SimulatorBackgroundServices(disabled: disabled, loaded: [], productFamily: "iPhone"),
            stillEnabledLabels: [], notStartedLabels: notStarted))
    }
    func failServiceChange(disabled: Set<String>, loaded: Set<String> = []) {
        let waiting = serviceChange
        serviceChange = nil
        waiting?.resume(throwing: SimulatorBackgroundServicesUpdateFailure(
            services: SimulatorBackgroundServices(disabled: disabled, loaded: loaded, productFamily: "iPhone"),
            underlyingError: SimulatorHostFailure(Failure.unavailable)))
    }
    func quitRenderer(keepingDevicesRunning: Bool?) { sessionEvents.append("quit"); quitCount += 1; continuation.yield(.quit) }
    func selectHost(_ host: SimulatorHost, xcodeURL: URL?) throws { throw Failure.unavailable }
    nonisolated func makeScreenOpenRequest(for deviceID: DeviceInventoryID) -> SimulatorScreenOpenRequest {
        SimulatorScreenOpenRequest(deviceID: deviceID) { _ = self.cancelledOpens.withLock { $0.insert(deviceID) } }
    }
    func openDevice(_ request: SimulatorScreenOpenRequest, xcodeURL: URL?, bootIfNeeded: Bool) async throws {
        let deviceID = request.deviceID
        lastOpenXcodeURL = xcodeURL
        lastOpenBootIfNeeded = bootIfNeeded
        try await withCheckedThrowingContinuation { waiting in
            openContinuations.append((deviceID, waiting))
            continuation.yield(.open(deviceID))
        }
    }
    func completeOpen(for deviceID: DeviceInventoryID? = nil) {
        guard let index = openContinuations.firstIndex(where: { deviceID == nil || $0.0 == deviceID }) else { return }
        openContinuations.remove(at: index).1.resume()
    }
    func failOpen() {
        guard !openContinuations.isEmpty else { return }
        openContinuations.removeFirst().1.resume(throwing: Failure.unavailable)
    }
    func closeDevice(_ deviceID: DeviceInventoryID, keepingDeviceRunning: Bool) throws {
        continuation.yield(.close(deviceID))
        if failsClose { throw Failure.native }
    }
    func failClose() { failsClose = true }
    func creationCatalog() throws -> SimulatorCreationContext { throw Failure.unavailable }
    func creationCatalog(for deviceID: DeviceInventoryID) throws -> SimulatorCreationContext { throw Failure.unavailable }
    func createSimulator(named name: String, deviceType: String, runtime: String, context: SimulatorCreationContext) throws -> String { throw Failure.unavailable }
    func pairSimulators(watch: String, phone: String, context: SimulatorCreationContext) throws { throw Failure.unavailable }
    func holdManagement() { holdsManagement = true }
    func failSimulatorCommand(_ command: String) { failingSimulatorCommand = command }
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
            try await self.readThroughHeldCommand()
            return DeviceManagementContext(device: device, xcodeURL: URL(fileURLWithPath: "/Fixture.app"), renderer: nil)
        }, renderer: { _ in nil }, readPairs: { _, _ in
            await self.beginManagement(request, action: action, devices: devices)
            return Data()
        }, runSimctl: { _, arguments, _ in
            await self.beginManagement(request, action: action, devices: devices)
            if arguments.first == (await self.failingSimulatorCommand) { throw Failure.native }
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
                managementWaiters.append((action, devices.map(\.id), waiting))
                continuation.yield(.manage(action, devices.map(\.id)))
            }
        } else { continuation.yield(.manage(action, devices.map(\.id))) }
    }
    func completeManagement(_ action: DeviceManagementAction, for device: DeviceInventoryID? = nil) {
        guard let index = managementWaiters.firstIndex(where: { waiter in
            waiter.0 == action && (device.map { waiter.1.contains($0) } ?? true)
        }) else { return }
        managementWaiters.remove(at: index).2.resume()
        holdsManagement = false
    }
    func inspector(for device: InventoryDevice) throws -> DeviceInspector {
        guard inspectorResponse != nil else { throw Failure.unavailable }
        return DeviceInspector(device: device, simulatorXcodeURL: URL(fileURLWithPath: "/Fixture.app"),
            transport: .init(run: { command in try await self.readInspector(device.id, command: command) }))
    }
    private func readInspector(_ identifier: DeviceInventoryID, command: DeviceInspectorCommand) async throws -> CommandOutput {
        inspectorCommands.append(command)
        if holdsInspectorReads {
            return try await withCheckedThrowingContinuation { waiting in
                inspectorReads.append((identifier, waiting))
                continuation.yield(.inspect(identifier))
            }
        }
        continuation.yield(.inspect(identifier))
        return CommandOutput(terminationStatus: 0, stdout: Data((inspectorResponse ?? "").utf8), stderr: Data())
    }
    func holdInspectorReads() { holdsInspectorReads = true }
    func setInspectorResponse(_ response: String) { inspectorResponse = response }
    /// Answers `device`'s oldest held read, or every held read and those that follow when no device is named.
    func completeInspectorRead(_ response: String? = nil, of device: DeviceInventoryID? = nil) {
        if let response { inspectorResponse = response }
        let output = CommandOutput(terminationStatus: 0, stdout: Data((inspectorResponse ?? "").utf8), stderr: Data())
        for waiting in takeInspectorReads(of: device) { waiting.resume(returning: output) }
    }
    func failInspectorRead(with error: any Error = Failure.unavailable, of device: DeviceInventoryID? = nil) {
        for waiting in takeInspectorReads(of: device) { waiting.resume(throwing: error) }
    }
    private func takeInspectorReads(of device: DeviceInventoryID?) -> [CheckedContinuation<CommandOutput, any Error>] {
        guard let device else {
            holdsInspectorReads = false
            defer { inspectorReads = [] }
            return inspectorReads.map(\.finished)
        }
        guard let index = inspectorReads.firstIndex(where: { $0.device == device }) else { return [] }
        return [inspectorReads.remove(at: index).finished]
    }
    func restore(force: Bool) throws { throw Failure.unavailable }
    func synchronizeXcodeConnections() -> Bool { false }
    func testingDeviceVisibilityDidChange() {}
}

@MainActor
private final class SettingsWindowFrameSamples: NSObject {
    var frames: [NSRect] = []
    @objc func resized(_ notification: Notification) {
        if let window = notification.object as? NSWindow { frames.append(window.frame) }
    }
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
