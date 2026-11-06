import Foundation
import NeoSimulatorDeviceIO
import Observation
import Synchronization

/// The parts of a device's state that are read independently.
public struct DeviceStateGroups: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let settings = Self(rawValue: 1 << 0)
    public static let backgroundServices = Self(rawValue: 1 << 1)
    /// What device commands show, which only a connected screen's session can read.
    public static let commandState = Self(rawValue: 1 << 2)
    public static let all: Self = [.settings, .backgroundServices, .commandState]
}

/// Keeps part of a device's state current while it is held. Nothing is read for a device that nothing holds, except what
/// confirms a change it was asked to make.
@MainActor
public final class DeviceReadInterest {
    private var end: (@MainActor () -> Void)?

    fileprivate init(end: @escaping @MainActor () -> Void) { self.end = end }

    public func release() {
        end?()
        end = nil
    }

    isolated deinit { release() }
}

/// An accepted change to one device, which runs after the changes accepted before it.
package struct DeviceWrite: Sendable {
    package let id: UUID
    package let task: Task<Void, any Error>
}

/// What became of an accepted change.
package enum DeviceWriteResult {
    case applied
    /// Nothing reached the device, because it was stopped before its turn.
    case notStarted
    case failed(any Error)
}

/// What is known of one device, which everything that presents the device in this process shares.
///
/// A device keeps the same model for as long as its registry lists it, so returning to it finds what it last answered.
/// Reading a property asks the device nothing. Hold a ``DeviceReadInterest`` from ``keepCurrent(_:)`` to have what changed
/// read again as it is invalidated.
///
/// A change made outside this process that sends no signal stays unknown until ``revalidate(_:)`` or
/// ``DeviceRegistry/revalidate()``, which a client should call when it returns to the foreground or the user asks.
@MainActor @Observable
public final class DeviceModel: Identifiable {
    public nonisolated let id: DeviceInventoryID
    public private(set) var name: String
    public private(set) var kind: DeviceInventoryKind
    public private(set) var isAvailable: Bool
    /// Whether the device can answer for its settings now. A simulator must be running.
    public private(set) var canInspectSettings: Bool
    /// Whether the device can answer for its background services now. Only a running simulator can.
    public private(set) var canInspectBackgroundServices: Bool
    package private(set) var inventory: InventoryDevice

    public let settings: DeviceSettingsState
    public let backgroundServices: BackgroundServicesState

    /// Whether biometrics are enrolled. Touch ID, Face ID, and Optic ID share this guest state.
    public private(set) var isBiometricEnrolled: Bool?
    public private(set) var showsStandBy: Bool?
    /// The Core Animation debug options as the device last reported them.
    public private(set) var debugOptions: [CADebugOption: Bool] = [:]
    /// The native call that has outlived its deadline, while one has. Requests are not sent until it returns.
    public private(set) var unresponsiveOperation: String?
    /// Why the last read or reapplied setting failed, until a later read succeeds.
    public private(set) var lastIssue: String?
    /// The device's audio routes as a connected screen's audio port last reported them.
    package private(set) var audioRoutes: AudioRouteState?

    @ObservationIgnored package let source: any DeviceStateSource
    @ObservationIgnored private weak var registry: DeviceRegistry?
    /// The inventory sources that last listed the device, which decide when its absence means that it has gone.
    @ObservationIgnored package private(set) var sources: Set<DeviceInventoryIssue.Source> = []
    /// Results of reads from before this changes describe a device that no longer exists, so they are dropped.
    @ObservationIgnored package private(set) var epoch = 0
    @ObservationIgnored package private(set) var readsStopped: Bool
    @ObservationIgnored private var interest: [Int: Int] = [:]
    @ObservationIgnored private var presentations = 0
    @ObservationIgnored private var commandReaders: [UUID: @MainActor () -> Void] = [:]
    @ObservationIgnored private var health: Task<Void, Never>?
    @ObservationIgnored private weak var followedChannel: SimulatorDeviceChannel?
    @ObservationIgnored private var recoveryObservers: [UUID: AsyncStream<Void>.Continuation] = [:]
    @ObservationIgnored private var writes: [UUID: Task<Void, any Error>] = [:]
    @ObservationIgnored private var unstartedWrites: Set<UUID> = []
    @ObservationIgnored private var lastWrite: Task<Void, Never>?

    package init(inventory: InventoryDevice, source: any DeviceStateSource, registry: DeviceRegistry? = nil, readsStopped: Bool = false) {
        id = inventory.id
        name = inventory.name
        kind = inventory.kind
        isAvailable = inventory.isAvailable
        canInspectSettings = inventory.canInspectSettings
        canInspectBackgroundServices = inventory.canInspectBackgroundServices
        self.inventory = inventory
        self.source = source
        self.registry = registry
        self.readsStopped = readsStopped
        settings = DeviceSettingsState()
        backgroundServices = BackgroundServicesState()
        settings.owner = self
        backgroundServices.owner = self
    }

    isolated deinit {
        health?.cancel()
        for observer in recoveryObservers.values { observer.finish() }
    }

    // MARK: Reading

    /// Reads what is out of date in `groups` now, and again whenever it is invalidated, until the result is released.
    public func keepCurrent(_ groups: DeviceStateGroups = [.settings, .backgroundServices]) -> DeviceReadInterest {
        for group in Self.singleGroups where groups.contains(group) { interest[group.rawValue, default: 0] += 1 }
        scheduleReads()
        return DeviceReadInterest { [weak self] in
            guard let self else { return }
            for group in Self.singleGroups where groups.contains(group) { self.interest[group.rawValue, default: 1] -= 1 }
        }
    }

    private static let singleGroups: [DeviceStateGroups] = [.settings, .backgroundServices, .commandState]

    package func wants(_ group: DeviceStateGroups) -> Bool { interest[group.rawValue, default: 0] > 0 }

    /// Marks `groups` out of date. What something holds is read again, after any read of it that is running; the rest is
    /// read when something next holds it. Command state is read through a connected screen's session, if there is one.
    public func revalidate(_ groups: DeviceStateGroups = .all) {
        if groups.contains(.settings) { settings.markAllDirty() }
        if groups.contains(.backgroundServices) { backgroundServices.markDirty() }
        scheduleReads()
        if groups.contains(.commandState) { commandReaders.values.forEach { $0() } }
    }

    private func scheduleReads() {
        settings.scheduleReads()
        backgroundServices.scheduleReads()
    }

    /// Takes in what the inventory lists now. Only what can change the device's answers makes it read again.
    package func update(_ device: InventoryDevice, sources: Set<DeviceInventoryIssue.Source>) {
        self.sources = sources
        let previous = inventory
        guard previous != device else { return }
        inventory = device
        assign(\.name, device.name)
        assign(\.kind, device.kind)
        assign(\.isAvailable, device.isAvailable)
        assign(\.canInspectSettings, device.canInspectSettings)
        assign(\.canInspectBackgroundServices, device.canInspectBackgroundServices)
        backgroundServices.deviceChanged()
        if Self.answersDiffer(previous, device) { deviceRestarted() }
    }

    private static func answersDiffer(_ first: InventoryDevice, _ second: InventoryDevice) -> Bool {
        if first.canInspectSettings != second.canInspectSettings { return true }
        guard case .remote(let old) = first, case .remote(let new) = second else { return false }
        return old.capabilities != new.capabilities || old.connectionState != new.connectionState
    }

    private func assign<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<DeviceModel, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    /// The device started again, or changed what it can answer for, so nothing read before now describes it. What is held
    /// stays until a new read replaces it.
    package func deviceRestarted() {
        epoch += 1
        settings.discardRunningReads()
        backgroundServices.discardRunningRead()
        scheduleReads()
    }

    package func stopReading() {
        readsStopped = true
        settings.cancelReads()
        backgroundServices.cancelRead()
    }

    package func resumeReading() {
        readsStopped = false
        revalidate([.settings, .backgroundServices])
    }

    package func finishReading() async {
        await settings.finishReading()
        await backgroundServices.finishReading()
    }

    // MARK: Writing

    /// Refuses a change that the device could not be sent because an earlier call to it has not returned.
    package func checkAcceptsChanges() throws {
        if let unresponsiveOperation {
            throw DeviceOperationFailure.notSent(operation: "change the device's state", heldBy: unresponsiveOperation)
        }
    }

    /// Runs `perform` after the changes accepted before it and after `hold`. Another device's changes are not in this
    /// order. `settle` always runs once, before the task ends.
    package func enqueueWrite(after hold: Task<Void, Never>?, perform: @escaping @MainActor () async throws -> Void,
                              settle: @escaping @MainActor (DeviceWriteResult) -> Void) -> DeviceWrite {
        let id = UUID()
        let previous = lastWrite
        unstartedWrites.insert(id)
        let task = Task { [weak self] in
            defer {
                self?.writes[id] = nil
                self?.unstartedWrites.remove(id)
            }
            await waitUnlessCancelled(for: previous)
            await waitUnlessCancelled(for: hold)
            guard !Task.isCancelled else {
                settle(.notStarted)
                throw CancellationError()
            }
            self?.unstartedWrites.remove(id)
            do {
                try await perform()
                settle(.applied)
            } catch {
                settle(.failed(error))
                throw error
            }
        }
        writes[id] = task
        lastWrite = Task {
            await previous?.value
            _ = await task.result
        }
        return DeviceWrite(id: id, task: task)
    }

    package var writeTasks: [Task<Void, any Error>] { Array(writes.values) }

    /// Whether `write` has yet to reach the device.
    package func isUnstarted(_ write: DeviceWrite) -> Bool { unstartedWrites.contains(write.id) }

    // MARK: Channel health

    /// Keeps `unresponsiveOperation` as `channel` reports it. A channel's stream has one consumer each, so the model takes
    /// its own and fans recoveries out through ``recoveries()``.
    package func follow(_ channel: SimulatorDeviceChannel) {
        guard followedChannel !== channel else { return }
        followedChannel = channel
        health?.cancel()
        let changes = channel.healthChanges()
        health = Task { [weak self] in
            for await health in changes {
                guard let self else { return }
                self.apply(health)
            }
        }
    }

    private func apply(_ health: DeviceChannelHealth) {
        switch health {
        case .unresponsive(let call, _):
            unresponsiveOperation = call
        case .ready:
            guard unresponsiveOperation != nil else { return }
            unresponsiveOperation = nil
            revalidate([.settings, .backgroundServices])
            for observer in recoveryObservers.values { observer.yield() }
        }
    }

    /// An element each time a call that outlived its deadline returns, which is the only thing that recovers a device.
    package func recoveries() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let identifier = UUID()
        recoveryObservers[identifier] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.recoveryObservers[identifier] = nil }
        }
        return stream
    }

    // MARK: Presenting sessions

    /// A session keeps its device's model registered while it shows it, even if the inventory stops listing the device.
    /// `readCommandState` is how a revalidation reaches what only that session can read.
    package func beginPresentation(readCommandState: @escaping @MainActor () -> Void) -> UUID {
        presentations += 1
        let identifier = UUID()
        commandReaders[identifier] = readCommandState
        return identifier
    }

    /// What only a session could read stops being known when it ends.
    package func endPresentation(_ identifier: UUID) {
        guard commandReaders.removeValue(forKey: identifier) != nil else { return }
        presentations -= 1
        isBiometricEnrolled = nil
        showsStandBy = nil
        debugOptions = [:]
        audioRoutes = nil
        registry?.presentationEnded(of: self)
    }

    package var isPresented: Bool { presentations > 0 }

    /// Holds a reading of command state, and returns whether it changed what is held.
    package func update(biometricEnrolled: Bool?, showsStandBy: Bool?, debugOptions: [CADebugOption: Bool]) -> Bool {
        if lastIssue != nil { lastIssue = nil }
        guard biometricEnrolled != isBiometricEnrolled || showsStandBy != self.showsStandBy
                || debugOptions != self.debugOptions else { return false }
        assign(\.isBiometricEnrolled, biometricEnrolled)
        assign(\.showsStandBy, showsStandBy)
        assign(\.debugOptions, debugOptions)
        return true
    }

    package func note(issue: String) { lastIssue = issue }

    /// Takes in what a connected screen's audio port reported.
    package func observe(audioRoutes: AudioRouteState) {
        assign(\.audioRoutes, audioRoutes)
        settings.observe(audioRoutes: audioRoutes)
    }

    /// The location a host last chose for the device, as far as this process knows. CoreSimulator does not report the guest's.
    package var location: LocationSelection? {
        switch settings.locationMode {
        case .some(.none): LocationSelection.none
        case .some(.custom): .custom
        case .some(.scenario): settings.locationScenario.map { .scenario($0) } ?? LocationSelection.none
        case nil: nil
        }
    }

    package var locationScenarios: [LocationScenario] {
        settings.locationScenarios.map { LocationScenario(name: $0.name, localizedName: $0.displayName) }
    }
}

/// Returns when `task` ends or the caller is cancelled, whichever is first. Waiting for its value could not be given up.
private func waitUnlessCancelled(for task: Task<Void, Never>?) async {
    guard let task else { return }
    let waiting = Mutex<CheckedContinuation<Void, Never>?>(nil)
    let finish: @Sendable () -> Void = { waiting.withLock { $0.take() }?.resume() }
    await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
            waiting.withLock { $0 = continuation }
            if Task.isCancelled { return finish() }
            Task {
                await task.value
                finish()
            }
        }
    } onCancel: { finish() }
}
