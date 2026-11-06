import Foundation

/// A simulator's CoreDevice record, as far as it says what the simulator has.
@MainActor
package protocol CoreDeviceFeatureRecord: AnyObject, Sendable {
    /// Whether CoreDevice is connected to the simulator. A record that is not lists no features whatever the simulator has.
    func isConnected() async throws -> Bool
    func supports(_ feature: String) throws -> Bool
}

/// Where a simulator's record and the notifications of its changes come from. Each stream starts with what is current
/// when it is followed, so a change right after a read is not missed.
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

/// The one owner of a screen connection's view of its simulator's CoreDevice record. A missing record or one that is not
/// connected is no answer, so what asks waits on CoreDevice's notifications for one, and a failed read is its asker's
/// failure, not an answer. An asker that the first read answers follows nothing.
///
/// A simulator's record lists no features until the simulator boots, and none again once it shuts down.
@MainActor
package final class CoreDeviceRecordDiscovery<Source: CoreDeviceRecordSource> {
    private let source: Source
    private var waiters: [Int: AsyncStream<Void>.Continuation] = [:]
    private var nextWaiter = 0
    private var inventoryFollower: Task<Void, Never>?
    private var recordFollower: Task<Void, Never>?
    /// Why the notifications ended, which everything waiting on them is told.
    private var failure: (any Error)?
    private var latest: Source.Record?
    /// How many times CoreDevice's list has changed, which can replace the simulator's record.
    private var listChanges = 0
    /// What `listChanges` was when the read of `latest` began.
    private var latestListChanges = 0
    /// What `listChanges` was when the read of the record that `recordFollower` follows began.
    private var followedListChanges = 0
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
        if let value = try await read(decide) { return value }
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
        if let failure { throw failure }
        for await _ in changes {
            if let failure { throw failure }
            if let value = try await read(decide) { return value }
            try followChanges()
        }
        throw CancellationError()
    }

    private func read<Value>(_ decide: @MainActor (Source.Record) async throws -> Value?) async throws -> Value? {
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        do {
            let listChangesSeen = listChanges
            let record = try await source.record()
            guard !stopped else { throw CancellationError() }
            // What another read found after a later change of the list stays the latest.
            if listChangesSeen >= latestListChanges {
                latest = record
                latestListChanges = listChangesSeen
            }
            guard let record else { return nil }
            let value = try await decide(record)
            guard !stopped else { throw CancellationError() }
            return value
        } catch {
            guard !stopped else { throw CancellationError() }
            throw error
        }
    }

    /// Nothing but this wakes a wait, so a stop that refuses it ends the wait.
    private func followChanges() throws {
        guard !stopped else { throw CancellationError() }
        if inventoryFollower == nil {
            inventoryFollower = follow { [weak self, source] changed in
                try await source.followInventory { [weak self] in
                    self?.listChanges += 1
                    changed()
                }
            }
        }
        // A record replaced by a change of the list says nothing of its successor. What was followed then ends, and its end
        // counts for nothing. The next follower starts with what is current, so nothing since the read is missed.
        if followedListChanges != latestListChanges {
            recordFollower?.cancel()
            recordFollower = nil
        }
        if recordFollower == nil, let latest {
            followedListChanges = latestListChanges
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
        recordFollower = nil
        failure = nil
        latest = nil
    }
}

extension CoreDeviceRemoteScreenDevice: CoreDeviceFeatureRecord {}

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
        try await inventory.follow(onChange: changed)
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
