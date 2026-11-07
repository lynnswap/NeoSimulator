import Foundation

/// A simulator's CoreDevice record, as far as it says what the simulator has.
@MainActor
package protocol CoreDeviceFeatureRecord: AnyObject, Sendable {
    /// Whether CoreDevice is connected to the simulator. A record that is not lists no features whatever the simulator has.
    func isConnected() async throws -> Bool
    func supports(_ feature: String) throws -> Bool
}

/// Supplies a simulator record and change streams that begin with current state,
/// so subscribing after a read cannot miss an intervening change.
@MainActor
package protocol CoreDeviceRecordSource: AnyObject, Sendable {
    associatedtype Record: CoreDeviceFeatureRecord
    /// The simulator's record, or nil while CoreDevice lists none, which says nothing about the simulator. Each read can
    /// return a new value of an unchanged record, so only a change of the list says that the record may have been replaced.
    func record() async throws -> Record?
    /// Calls `changed` when CoreDevice's list of devices changes, which can replace the simulator's record.
    func followInventory(_ changed: @escaping @MainActor () -> Void) async throws
    /// Calls `changed` when what CoreDevice knows of `record` itself changes, including its connection.
    func follow(_ record: Record, _ changed: @escaping @MainActor () -> Void) async throws
}

/// What a simulator's record says about features.
package enum CoreDeviceFeatureAnswer<Record> {
    /// CoreDevice is connected to the simulator and lists every feature.
    case supported(Record)
    /// CoreDevice is connected to the simulator and does not list them all, which is the only evidence that it lacks them.
    case absent
}

/// Follows a screen connection's current CoreDevice record.
///
/// Missing or disconnected records wait for notifications; read failures propagate.
/// Observation starts before reading and ends when no callers remain. Simulator features
/// are available only while booted.
///
/// List changes advance a generation and replace the record subscription. Stale reads
/// retry against the current generation; stopping cancels pending and future waits.
@MainActor
package final class CoreDeviceRecordDiscovery<Source: CoreDeviceRecordSource> {
    private let source: Source
    private var waiters: [Int: AsyncStream<Void>.Continuation] = [:]
    private var nextWaiter = 0
    private var inventoryFollower: Task<Void, Never>?
    private var hasInventory = false
    private var recordFollower: Task<Void, Never>?
    /// Why the notifications ended, which everything waiting on them is told.
    private var failure: (any Error)?
    /// What the current generation's latest read found.
    private var latest: Source.Record?
    private var listGeneration = 0
    private var stopped = false
    /// Reports whether anything is waiting because CoreDevice has not answered yet.
    package var onAwaitingChange: (@MainActor (Bool) -> Void)?

    package init(source: Source) {
        self.source = source
    }

    deinit {
        inventoryFollower?.cancel()
        recordFollower?.cancel()
    }

    /// Waits until CoreDevice is connected to the simulator, and returns what its record says about `features`.
    package func answer(for features: [String]) async throws -> CoreDeviceFeatureAnswer<Source.Record> {
        try await wait { record -> CoreDeviceFeatureAnswer<Source.Record>? in
            // The features are read after the state, so a connected state is never paired with an older record's features.
            guard try await record.isConnected() else { return nil }
            for feature in features where try !record.supports(feature) { return .absent }
            return .supported(record)
        }
    }

    /// Waits for the simulator's record whatever it says, until `limit`.
    package func record(limit: Duration) async throws -> Source.Record {
        let waiting = Task { try await wait { $0 } }
        return try await withTaskCancellationHandler {
            guard await waiting.ends(before: ContinuousClock.now + limit) else {
                waiting.cancel()
                throw DeviceIOError.temporary("coredevice-record", "CoreDevice has not listed this simulator yet.")
            }
            return try await waiting.value
        } onCancel: {
            waiting.cancel()
        }
    }

    /// Ends every wait as cancelled, and any later one, with the connection this belongs to. A read in flight then ends
    /// its wait as cancelled too, whatever it found.
    package func stop() {
        stopped = true
        for waiter in waiters.values { waiter.finish() }
        endFollowing()
    }

    private func wait<Value>(_ decide: @MainActor (Source.Record) async throws -> Value?) async throws -> Value {
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        let (changes, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let waiter = nextWaiter
        nextWaiter += 1
        waiters[waiter] = continuation
        if waiters.count == 1 { onAwaitingChange?(true) }
        defer {
            waiters[waiter] = nil
            if waiters.isEmpty {
                endFollowing()
                onAwaitingChange?(false)
            }
        }
        try followChanges()
        if hasInventory { continuation.yield() }
        if let failure { throw failure }
        for await _ in changes {
            if let failure { throw failure }
            if let value = try await read(decide) { return value }
            try followChanges()
        }
        throw CancellationError()
    }

    private func read<Value>(_ decide: @MainActor (Source.Record) async throws -> Value?) async throws -> Value? {
        while true {
            try Task.checkCancellation()
            guard !stopped else { throw CancellationError() }
            let generation = listGeneration
            do {
                let record = try await source.record()
                guard isCurrent(generation) else { continue }
                latest = record
                guard let record else { return nil }
                let value = try await decide(record)
                guard isCurrent(generation) else { continue }
                return value
            } catch {
                guard isCurrent(generation) else { continue }
                throw error
            }
        }
    }

    private func isCurrent(_ generation: Int) -> Bool { !stopped && generation == listGeneration }

    /// Nothing but this wakes a wait, so a stop that refuses it ends the wait.
    private func followChanges() throws {
        guard !stopped else { throw CancellationError() }
        if inventoryFollower == nil {
            inventoryFollower = follow { [weak self, source] _ in
                try await source.followInventory { [weak self] in self?.listChanged() }
            }
        }
        // Each read returns a new value of an unchanged record, so only a new generation follows again. The follower starts
        // with what is current, so nothing since the read is missed.
        if recordFollower == nil, let latest {
            recordFollower = follow { [source] changed in try await source.follow(latest, changed) }
        }
    }

    private func follow(_ stream: @escaping @MainActor (@escaping @MainActor () -> Void) async throws -> Void) -> Task<Void, Never> {
        Task { [weak self] in
            do {
                try await stream { [weak self] in self?.changed() }
                guard !Task.isCancelled else { return }
                self?.fail(DeviceIOError.unavailable("coredevice-record", "CoreDevice stopped reporting this simulator's changes."))
            } catch {
                guard !Task.isCancelled else { return }
                self?.fail(error)
            }
        }
    }

    /// Begins a generation. What was followed of the old record ends here, and its end counts for nothing. A failure this
    /// clears can only be that follower's, since one of the list's own would have ended these notifications.
    private func listChanged() {
        hasInventory = true
        listGeneration += 1
        latest = nil
        recordFollower?.cancel()
        recordFollower = nil
        failure = nil
        changed()
    }

    private func changed() {
        for waiter in waiters.values { waiter.yield() }
    }

    private func fail(_ error: any Error) {
        failure = error
        changed()
    }

    private func endFollowing() {
        inventoryFollower?.cancel()
        recordFollower?.cancel()
        inventoryFollower = nil
        hasInventory = false
        recordFollower = nil
        failure = nil
        latest = nil
    }
}

/// The record of the simulator of `udid` in CoreDevice's own list, which holds only the default device set.
@MainActor
package final class CoreDeviceSimulatorRecordSource: CoreDeviceRecordSource {
    private let udid: String
    private let inventory = CoreDeviceInventoryChangeSource()

    package init(simulatorUDID: String) {
        udid = simulatorUDID
    }

    package func record() async throws -> CoreDeviceRemoteScreenDevice? {
        guard let identifier = try await CoreDeviceRemoteScreenDevice.simulatorIdentifier(udid: udid) else { return nil }
        return try await CoreDeviceRemoteScreenDevice(identifier: identifier)
    }

    package func followInventory(_ changed: @escaping @MainActor () -> Void) async throws {
        try await inventory.initialize()
        try await inventory.follow(onReady: changed, onChange: changed)
    }

    package func follow(_ record: CoreDeviceRemoteScreenDevice, _ changed: @escaping @MainActor () -> Void) async throws {
        try await record.followInfoChanges(changed)
    }
}

package typealias CoreDeviceSimulatorRecord = CoreDeviceRecordDiscovery<CoreDeviceSimulatorRecordSource>

extension CoreDeviceRecordDiscovery where Source == CoreDeviceSimulatorRecordSource {
    package convenience init(simulatorUDID: String) {
        self.init(source: CoreDeviceSimulatorRecordSource(simulatorUDID: simulatorUDID))
    }
}
