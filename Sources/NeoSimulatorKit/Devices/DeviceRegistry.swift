import Foundation
import NeoSimulatorDeviceIO
import Observation

/// Retains one ``DeviceModel`` per listed device for the application's lifetime.
///
/// Registries are process-local. Other processes' changes arrive through observed signals
/// or revalidation, such as on foreground activation.
@MainActor @Observable
public final class DeviceRegistry {
    public private(set) var devices: [DeviceModel] = []
    /// The inventory sources that the last read could not read. What only they list stays in `devices`.
    package private(set) var inventoryIssues: [DeviceInventoryIssue] = []

    @ObservationIgnored package let source: any DeviceStateSource
    @ObservationIgnored private var models: [DeviceInventoryID: DeviceModel] = [:]
    @ObservationIgnored private var readsStopped = false
    @ObservationIgnored private var runningRead: Task<Void, any Error>?
    @ObservationIgnored private var queuedRead: Task<Void, any Error>?
    /// The devices that a screen connected to after the running inventory read began.
    @ObservationIgnored private var connectedDuringRead: Set<DeviceInventoryID> = []

    /// Reads real devices through CoreSimulator, CoreDevice, and their command-line tools. Nothing is read until ``refresh()``.
    public convenience init() { self.init(source: LiveDeviceStateSource()) }

    package init(source: any DeviceStateSource) { self.source = source }

    public func device(for id: DeviceInventoryID) -> DeviceModel? { models[id] }

    /// Reads the inventory, and returns once a read that began after this call has been published. Callers during a read
    /// share the one read that follows it. Only cancellation throws: a source that fails is reported and what it listed stays.
    public func refresh() async throws {
        let task = queuedRead ?? beginInventoryRead()
        try await task.value
        try Task.checkCancellation()
    }

    private func beginInventoryRead() -> Task<Void, any Error> {
        let previous = runningRead
        let task = Task { [weak self, source] in
            _ = await previous?.result
            defer { self?.inventoryReadEnded() }
            self?.connectedDuringRead = []
            let snapshot = try await source.inventory()
            try Task.checkCancellation()
            self?.apply(snapshot)
        }
        if previous == nil { runningRead = task } else { queuedRead = task }
        return task
    }

    private func inventoryReadEnded() {
        runningRead = queuedRead
        queuedRead = nil
    }

    /// Marks every device's state out of date. Only what something holds through ``DeviceModel/keepCurrent(_:)`` reads now.
    public func revalidate() {
        for model in models.values { model.revalidate() }
    }

    /// Updates inventory while retaining existing models.
    /// Remove a device only when every source that listed it successfully reports its absence.
    /// Retired work cannot publish to a replacement model. A screen's newer boot state takes
    /// precedence over a read started before that connection.
    package func apply(_ snapshot: DeviceInventorySnapshot) {
        var listed: [DeviceModel] = []
        var seen: Set<DeviceInventoryID> = []
        for device in snapshot.devices where seen.insert(device.id).inserted {
            let model = models[device.id]
            let current = Self.retainingUnreadValues(of: model?.inventory, in: device, snapshot: snapshot,
                                                     keepingState: connectedDuringRead.contains(device.id))
            let unreadSources = model?.sources.filter { snapshot.retains([$0]) } ?? []
            let sources = snapshot.sources(of: device).union(unreadSources)
            if let model {
                model.update(current, sources: sources)
                listed.append(model)
            } else {
                let model = makeModel(current)
                model.update(current, sources: sources)
                listed.append(model)
            }
        }
        for model in devices where !seen.contains(model.id) {
            if snapshot.retains(model.sources) { listed.append(model) }
            else {
                model.retire()
                models[model.id] = nil
            }
        }
        if listed.map(\.id) != devices.map(\.id) { devices = listed }
        inventoryIssues = snapshot.issues
    }

    /// CoreDevice and renderer ownership add to a simulator's record, so failing to read them says nothing of it.
    private static func retainingUnreadValues(of previous: InventoryDevice?, in device: InventoryDevice, snapshot: DeviceInventorySnapshot,
                                              keepingState: Bool) -> InventoryDevice {
        guard case .simulator(let new) = device, case .simulator(let old)? = previous else { return device }
        var owner = new.ownerXcodeURL
        var capabilities: Set<String>?
        var coreDevice: CoreDeviceDevice?
        if !snapshot.didRead(.rendererOwnership) { owner = old.ownerXcodeURL }
        if !snapshot.didRead(.coreDevice), new.coreDevice == nil, let record = old.coreDevice {
            capabilities = old.capabilities
            coreDevice = record
        }
        return .simulator(new.inventoryCopy(ownerXcodeURL: owner, capabilities: capabilities, coreDevice: coreDevice,
                                            state: keepingState ? old.state : nil,
                                            lastBootDate: keepingState ? old.lastBootDate : new.lastBootDate ?? old.lastBootDate))
    }

    private func makeModel(_ device: InventoryDevice, channel: SimulatorDeviceChannel? = nil) -> DeviceModel {
        let model = DeviceModel(inventory: device, source: source, registry: self, readsStopped: readsStopped)
        if let channel { model.follow(channel) }
        else if case .simulator(let identifier, let path) = device.id.destination {
            model.follow(DeviceIOHub.shared.channel(for: .device(DeviceAddress(identifier: identifier, deviceSetPath: path))))
        }
        models[device.id] = model
        return model
    }

    /// The model of a device that a session is about to show, which a process with no inventory has only from here. `device`
    /// and `lastBootDate` are the record that the session connected from, which can be newer than the last inventory read.
    package func presentedModel(of device: AvailableDevice, lastBootDate: Date?, ownerXcodeURL: URL?, channel: SimulatorDeviceChannel) -> DeviceModel {
        let id = DeviceInventoryID.simulator(udid: device.identifier, deviceSetPath: device.deviceSetPath)
        let model = models[id] ?? makeModel(.simulator(SimulatorHostDevice(presenting: device, ownerXcodeURL: ownerXcodeURL)), channel: channel)
        model.follow(channel)
        model.observeConnection(to: device, lastBootDate: lastBootDate)
        if runningRead != nil { connectedDuringRead.insert(id) }
        return model
    }

    package func presentationEnded(of model: DeviceModel) {
        guard !model.isPresented, !devices.contains(where: { $0 === model }), models[model.id] === model else { return }
        models[model.id] = nil
    }

    /// Stops the state reads running now and refuses new ones until ``resumeReading()``, without stopping any change.
    package func stopReading() {
        readsStopped = true
        for model in models.values { model.stopReading() }
    }

    package func resumeReading() {
        readsStopped = false
        for model in models.values { model.resumeReading() }
    }

    package func finishReading() async {
        for model in Array(models.values) { await model.finishReading() }
    }

    /// The accepted changes of one device, or of every device, that have not finished.
    package func writeTasks(for id: DeviceInventoryID?) -> [Task<Void, any Error>] {
        guard let id else { return models.values.flatMap(\.writeTasks) }
        return models[id]?.writeTasks ?? []
    }
}
