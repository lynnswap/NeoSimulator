import Foundation
import NeoSimulatorDeviceIO
import Observation

/// The devices one process knows of, each with one ``DeviceModel`` for as long as it is listed.
///
/// An application owns its registry and keeps it for as long as it uses the devices; which of them it shows is its own
/// concern. Separate processes have separate registries, which do not share objects or caches: what one process changes
/// reaches another only through a signal the other observes, or a revalidation when it comes to the foreground.
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

    /// Publishes what an inventory read found. A listed device keeps its object. A device that is not listed has gone only
    /// if every source that listed it read successfully, and a record that another source adds to survives that source's
    /// failure. Work running for a device that has gone finishes without publishing to anyone looking it up again.
    package func apply(_ snapshot: DeviceInventorySnapshot) {
        var listed: [DeviceModel] = []
        var seen: Set<DeviceInventoryID> = []
        for device in snapshot.devices where seen.insert(device.id).inserted {
            let model = models[device.id]
            let current = Self.retainingUnreadValues(of: model?.inventory, in: device, snapshot: snapshot)
            let sources = snapshot.sources(of: device)
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
            else if !model.isPresented { models[model.id] = nil }
        }
        if listed.map(\.id) != devices.map(\.id) { devices = listed }
        inventoryIssues = snapshot.issues
    }

    /// CoreDevice and renderer ownership add to a simulator's record, so failing to read them says nothing of it.
    private static func retainingUnreadValues(of previous: InventoryDevice?, in device: InventoryDevice, snapshot: DeviceInventorySnapshot) -> InventoryDevice {
        guard case .simulator(let new) = device, case .simulator(let old)? = previous else { return device }
        var owner = new.ownerXcodeURL
        var capabilities: Set<String>?
        var coreDevice: CoreDeviceDevice?
        if !snapshot.didRead(.rendererOwnership) { owner = old.ownerXcodeURL }
        if !snapshot.didRead(.coreDevice), new.coreDevice == nil, let record = old.coreDevice {
            capabilities = old.capabilities
            coreDevice = record
        }
        return .simulator(new.inventoryCopy(ownerXcodeURL: owner, capabilities: capabilities, coreDevice: coreDevice))
    }

    private func makeModel(_ device: InventoryDevice, channel: SimulatorDeviceChannel? = nil) -> DeviceModel {
        let model = DeviceModel(inventory: device, source: source, registry: self, readsStopped: readsStopped)
        if let channel { model.follow(channel) }
        else if case .simulator(let identifier, let path) = device.id.destination {
            model.follow(DeviceIOHub.shared.channel(for: DeviceAddress(identifier: identifier, deviceSetPath: path)))
        }
        models[device.id] = model
        return model
    }

    /// The model of a device that a session is about to show, which a process with no inventory has only from here.
    package func presentedModel(of device: AvailableDevice, ownerXcodeURL: URL?, channel: SimulatorDeviceChannel) -> DeviceModel {
        let id = DeviceInventoryID.simulator(udid: device.identifier, deviceSetPath: device.deviceSetPath)
        if let model = models[id] {
            model.follow(channel)
            return model
        }
        return makeModel(.simulator(SimulatorHostDevice(presenting: device, ownerXcodeURL: ownerXcodeURL)), channel: channel)
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
