import AppKit
import Foundation
import Observation
import Testing
@testable import XcodeSimulatorHost

@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor
struct ManagerModelTests {
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
            device("unavailable-watch", available: false), device("other-phone", family: "iPhone")].map(InventoryDevice.simulator))
        let manager = SimulatorManagerModel(source: source)
        await manager.refresh()
        let target = NSObject()
        let menu = SimulatorPairingMenu.make(for: phone, model: manager, target: target, action: #selector(NSApplication.terminate(_:)))
        #expect(manager.pairingWatches(for: phone).map(\.identifier) == [watch.identifier])
        let actions = menu.items.filter { $0.action != nil }
        #expect(actions.map(\.title) == ["unpaired-watch", "New Watch Simulator…"])
        #expect(actions.allSatisfy { $0.isEnabled })
        guard case .pair(let identifiers) = actions.first?.representedObject as? SimulatorPairingMenu.Action else {
            Issue.record("Expected an existing-watch pairing action")
            return
        }
        #expect(identifiers == [phone.inventoryID, watch.inventoryID])
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
        await manager.refresh()
        manager.openDevice(device.id)
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
        manager.restoreScreen(decoded) {
            #expect(!manager.inventory.isEmpty)
            presented = true
        }
        #expect(await events.next() == .open(decoded.deviceID))
        #expect(await source.lastOpenXcodeURL == xcode)
        #expect(!presented)
        await source.completeOpen()
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
        let source = ManagerModelSource(devices: [device])
        var events = source.events.makeAsyncIterator()
        let manager = SimulatorManagerModel(source: source)
        await manager.refresh()
        manager.settings.inspect(device, selectionCount: 1)
        #expect(await events.next() == .read(device.id))
        await source.completeRead(settings(appearance: "light", contentSize: "medium"))
        await manager.settings.finishReading()

        manager.setDeviceSetting(.appearance("dark"), for: device.id)
        manager.setDeviceSetting(.contentSize("large"), for: device.id)
        #expect(manager.settings.settings?.appearance == "dark")
        #expect(manager.settings.settings?.contentSize == "large")
        #expect(await events.next() == .write(device.id))
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

    @Test func failedEditRefreshesTheSelectedDevice() async throws {
        let device = simulator()
        let source = ManagerModelSource(devices: [device])
        var events = source.events.makeAsyncIterator()
        let model = DeviceSettingsModel(source: source)
        model.inspect(device, selectionCount: 1)
        #expect(await events.next() == .read(device.id))
        await source.completeRead(settings(appearance: "light"))
        await model.finishReading()

        let edit = model.accept(.appearance("dark"), for: device)
        let applying = Task { try await model.apply(edit) }
        #expect(await events.next() == .write(device.id))
        await source.failWrite()
        do { try await applying.value; Issue.record("The source failure must reach the caller.") }
        catch { #expect(error is ManagerModelSource.Failure) }
        #expect(await events.next() == .read(device.id))
        await source.completeRead(settings(appearance: "dark"))
        await model.finishReading()
        #expect(model.settings?.appearance == "dark")
        #expect(model.issue == nil)
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

    @Test func pendingEditsStayWithTheirDeviceAcrossSelectionChanges() async throws {
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
        await source.completeWrite()
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
            kind: .physical, name: "Duo", modelIdentifier: "iPhone19,4", modelName: "iPhone Duo",
            platform: "iOS", osVersion: nil, osBuild: nil, connectionState: "connected",
            pairingState: "paired", transportType: nil, bootState: "booted", capabilities: [],
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

    private func simulator(deviceSet: String? = nil) -> InventoryDevice {
        .simulator(SimulatorHostDevice(identifier: "same-udid", name: "Test Phone", descriptiveName: "Test Phone",
            runtimeIdentifier: "test-runtime", runtimeName: "iOS", productFamily: "iPhone", state: "Booted",
            deviceSetPath: deviceSet, capabilities: ["com.apple.dt.coredevice.device.shutdown"]))
    }

    private func settings(appearance: String, contentSize: String? = nil) -> SimulatorDeviceSettings {
        SimulatorDeviceSettings(appearance: appearance, contentSize: contentSize)
    }
}

private actor ManagerModelSource: SimulatorManagerSource {
    enum Event: Equatable, Sendable { case read(DeviceInventoryID), write(DeviceInventoryID), open(DeviceInventoryID), close(DeviceInventoryID), quit, manage(DeviceManagementAction, [DeviceInventoryID]) }
    enum Failure: LocalizedError {
        case unavailable, native
        var errorDescription: String? { self == .native ? "Native shutdown failed" : "Unavailable" }
    }
    nonisolated let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private let devices: [InventoryDevice]
    private var holdsManagement = false
    private var immediateRead: SimulatorDeviceSettings?
    private var readContinuation: CheckedContinuation<SimulatorDeviceSettings, any Error>?
    private var openContinuation: CheckedContinuation<Void, any Error>?
    private var writeContinuation: CheckedContinuation<SimulatorDeviceSettings, any Error>?
    private var pendingWrite: SimulatorDeviceSettings?
    private(set) var writeInputs: [SimulatorDeviceSettings?] = []
    private(set) var readCount = 0
    private(set) var lastOpenXcodeURL: URL?
    private(set) var artworkXcodeRequests: [DeviceInventoryID] = []
    private(set) var installedXcodeReadCount = 0
    private(set) var managementRequests = 0
    private(set) var preparationRequests = 0
    private let managementFailureID: DeviceInventoryID?
    private var managementWaiters: [(DeviceManagementAction, CheckedContinuation<Void, Never>)] = []
    private var admittedManagement: Set<UUID> = []

    init(devices: [InventoryDevice], managementFailureID: DeviceInventoryID? = nil, holdsManagement: Bool = false) {
        self.managementFailureID = managementFailureID
        self.holdsManagement = holdsManagement
        self.devices = devices
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
    func failWrite() {
        let waiting = writeContinuation
        writeContinuation = nil
        pendingWrite = nil
        waiting?.resume(throwing: Failure.unavailable)
    }
    func quitRenderer(keepingDevicesRunning: Bool?) { continuation.yield(.quit) }
    func selectHost(_ host: SimulatorHost, xcodeURL: URL?) throws { throw Failure.unavailable }
    func openDevice(_ deviceID: DeviceInventoryID, xcodeURL: URL?) async throws {
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
    func inspector(for device: InventoryDevice) throws -> DeviceInspector { throw Failure.unavailable }
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
