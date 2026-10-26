import Foundation
import Testing
@testable import XcodeSimulatorHost

@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor
struct ManagerModelTests {
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
        let applying = Task {
            beganApplying.continuation.yield(())
            try await model.apply(.contentSize("large"), to: device)
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

        let applying = Task { try await model.apply(.appearance("dark"), to: device) }
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

    @Test func artworkResolvesXcodeBeforeOpeningAScreen() async throws {
        let device = simulator(deviceSet: "/tmp/artwork-device-set")
        let source = ManagerModelSource(devices: [device])
        let model = SimulatorManagerModel(source: source)
        let url = await model.artworkXcodeURL(for: device)
        #expect(url == URL(fileURLWithPath: "/Applications/Test Xcode.app"))
        #expect(await source.artworkXcodeRequests == [device.id])
    }

    private func simulator(deviceSet: String? = nil) -> InventoryDevice {
        .simulator(SimulatorHostDevice(identifier: "same-udid", name: "Test Phone", descriptiveName: "Test Phone",
            runtimeIdentifier: "test-runtime", runtimeName: "iOS", productFamily: "iPhone", state: "Booted",
            deviceSetPath: deviceSet))
    }

    private func settings(appearance: String, contentSize: String? = nil) -> SimulatorDeviceSettings {
        SimulatorDeviceSettings(appearance: appearance, contentSize: contentSize)
    }
}

private actor ManagerModelSource: SimulatorManagerSource {
    enum Event: Equatable, Sendable { case read(DeviceInventoryID), write(DeviceInventoryID), quit }
    enum Failure: Error { case unavailable }
    nonisolated let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private let devices: [InventoryDevice]
    private var immediateRead: SimulatorDeviceSettings?
    private var readContinuation: CheckedContinuation<SimulatorDeviceSettings, any Error>?
    private var writeContinuation: CheckedContinuation<SimulatorDeviceSettings, any Error>?
    private var pendingWrite: SimulatorDeviceSettings?
    private(set) var writeInputs: [SimulatorDeviceSettings?] = []
    private(set) var readCount = 0
    private(set) var artworkXcodeRequests: [DeviceInventoryID] = []

    init(devices: [InventoryDevice]) {
        self.devices = devices
        (events, continuation) = AsyncStream.makeStream()
    }

    func xcodeURL(forDevice deviceID: DeviceInventoryID) -> URL {
        artworkXcodeRequests.append(deviceID)
        return URL(fileURLWithPath: "/Applications/Test Xcode.app")
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
    func openDevice(_ deviceID: DeviceInventoryID, xcodeURL: URL?) throws { throw Failure.unavailable }
    func closeDevice(_ deviceID: DeviceInventoryID, keepingDeviceRunning: Bool) throws { throw Failure.unavailable }
    func creationCatalog() throws -> SimulatorCreationContext { throw Failure.unavailable }
    func createSimulator(named name: String, deviceType: String, runtime: String, context: SimulatorCreationContext) throws -> String { throw Failure.unavailable }
    func pairSimulators(watch: String, phone: String, context: SimulatorCreationContext) throws { throw Failure.unavailable }
    func manage(_ action: DeviceManagementAction, devices: [InventoryDevice]) -> DeviceManagementReport { DeviceManagementReport(results: []) }
    func inspector(for device: InventoryDevice) throws -> DeviceInspector { throw Failure.unavailable }
    func restore(force: Bool) throws { throw Failure.unavailable }
    func synchronizeXcodeConnections() -> Bool { false }
    func testingDeviceVisibilityDidChange() {}
}
