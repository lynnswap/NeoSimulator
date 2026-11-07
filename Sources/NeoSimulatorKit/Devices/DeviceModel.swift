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
    public static let info = Self(rawValue: 1 << 3)
    public static let applications = Self(rawValue: 1 << 4)
    public static let configurationProfiles = Self(rawValue: 1 << 5)
    public static let provisioningProfiles = Self(rawValue: 1 << 6)
    public static let reports = Self(rawValue: 1 << 7)
    /// Everything in ``DeviceInspectionState``.
    public static let inspection: Self = [.info, .applications, .configurationProfiles, .provisioningProfiles, .reports]
    public static let all: Self = [.settings, .backgroundServices, .commandState, .inspection]
}

/// Keeps selected state groups current until released.
/// Without an interest, reads occur only to confirm accepted changes.
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

/// The cached state shared by views of one device in this process.
///
/// The registry retains this model while it lists the device. Property access performs no I/O.
/// Retain a ``DeviceReadInterest`` from ``keepCurrent(_:)`` to refresh invalidated groups.
/// Call ``revalidate(_:)`` or ``DeviceRegistry/revalidate()`` on foreground activation or
/// explicit refresh to discover external changes that send no observable signal.
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
    public let inspection: DeviceInspectionState

    /// Whether biometrics are enrolled. Touch ID, Face ID, and Optic ID share this guest state.
    public private(set) var isBiometricEnrolled: Bool?
    public private(set) var showsStandBy: Bool?
    /// The Core Animation debug options as the device last reported them.
    public private(set) var debugOptions: [CADebugOption: Bool] = [:]
    /// The native request past its deadline. New requests are rejected until it returns.
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
    @ObservationIgnored package private(set) var isRetired = false
    @ObservationIgnored private var interest: [Int: Int] = [:]
    @ObservationIgnored private var presentations = 0
    @ObservationIgnored private var commandReaders: [UUID: @MainActor () -> Void] = [:]
    @ObservationIgnored private var health: Task<Void, Never>?
    @ObservationIgnored private weak var followedChannel: SimulatorDeviceChannel?
    @ObservationIgnored private var recoveryObservers: [UUID: AsyncStream<Void>.Continuation] = [:]
    @ObservationIgnored private var writes: [UUID: Task<Void, any Error>] = [:]
    @ObservationIgnored private var unstartedWrites: Set<UUID> = []
    @ObservationIgnored private var lastWrite: Task<Void, Never>?
    /// A screen can announce a start before CoreSimulator replaces the preceding boot's date.
    @ObservationIgnored private var pendingBoot: (previousDate: Date, observedAt: Date)?

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
        inspection = DeviceInspectionState()
        settings.owner = self
        backgroundServices.owner = self
        inspection.attach(to: self)
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

    private static let singleGroups: [DeviceStateGroups] = [.settings, .backgroundServices, .commandState, .info, .applications,
                                                            .configurationProfiles, .provisioningProfiles, .reports]

    package func wants(_ group: DeviceStateGroups) -> Bool { interest[group.rawValue, default: 0] > 0 }

    /// Invalidates `groups`. Groups with a retained interest refresh after any current read;
    /// others refresh when interest resumes. Command state requires a connected session.
    public func revalidate(_ groups: DeviceStateGroups = .all) {
        if groups.contains(.settings) { settings.markAllDirty() }
        if groups.contains(.backgroundServices) { backgroundServices.markDirty() }
        inspection.markDirty(groups)
        scheduleReads()
        if groups.contains(.commandState) { commandReaders.values.forEach { $0() } }
    }

    private func scheduleReads() {
        settings.scheduleReads()
        backgroundServices.scheduleReads()
        inspection.scheduleReads()
    }

    /// Takes in what the inventory lists now. Only what can change the device's answers makes it read again.
    package func update(_ device: InventoryDevice, sources: Set<DeviceInventoryIssue.Source>) {
        guard !isRetired else { return }
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
        inspection.deviceChanged()
        var answersDiffer = Self.answersDiffer(previous, device)
        if case .simulator(let old) = previous, case .simulator(let new) = device {
            if !device.canInspectSettings { pendingBoot = nil }
            else if !previous.canInspectSettings, let date = old.lastBootDate, new.lastBootDate == date {
                pendingBoot = (date, .now)
            }
            if let pendingBoot, let date = new.lastBootDate, date != pendingBoot.previousDate {
                if date > pendingBoot.observedAt { answersDiffer = true }
                self.pendingBoot = nil
            } else if let oldDate = old.lastBootDate, let newDate = new.lastBootDate, oldDate != newDate {
                answersDiffer = true
            }
        }
        if answersDiffer { deviceRestarted() } else { inspection.scheduleReads() }
    }

    /// Updates running state and boot time from a screen connection.
    /// Other fields remain inventory-owned; the next inventory read also takes over these fields.
    package func observeConnection(to device: AvailableDevice, lastBootDate: Date?) {
        guard case .simulator(let known) = inventory else { return }
        let state = SimulatorHostDevice(presenting: device, ownerXcodeURL: nil).state
        update(.simulator(known.inventoryCopy(ownerXcodeURL: known.ownerXcodeURL, state: state,
                                             lastBootDate: lastBootDate)), sources: sources)
    }

    private static func answersDiffer(_ first: InventoryDevice, _ second: InventoryDevice) -> Bool {
        if first.canInspectSettings != second.canInspectSettings { return true }
        guard case .remote(let old) = first, case .remote(let new) = second else { return false }
        return old.capabilities != new.capabilities || old.connectionState != new.connectionState
    }

    private func assign<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<DeviceModel, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    /// Discards reads from before a restart or capability change, retaining values until refreshed.
    package func deviceRestarted() {
        epoch += 1
        settings.discardRunningReads()
        backgroundServices.discardRunningRead()
        inspection.discardRunningReads()
        scheduleReads()
    }

    /// The inventory has authoritatively stopped listing this device. Existing callers may keep the last values, but
    /// unfinished reads belong to this retired generation and new changes must not target a later replacement.
    package func retire() {
        guard !isRetired else { return }
        isRetired = true
        readsStopped = true
        isAvailable = false
        canInspectSettings = false
        canInspectBackgroundServices = false
        epoch += 1
        settings.discardRunningReads()
        backgroundServices.discardRunningRead()
        inspection.discardRunningReads()
        for identifier in unstartedWrites { writes[identifier]?.cancel() }
        health?.cancel()
    }

    package func stopReading() {
        readsStopped = true
        settings.cancelReads()
        backgroundServices.cancelRead()
        inspection.cancelReads()
    }

    package func resumeReading() {
        readsStopped = false
        revalidate([.settings, .backgroundServices, .inspection])
    }

    package func finishReading() async {
        await settings.finishReading()
        await backgroundServices.finishReading()
        await inspection.finishReading()
    }

    // MARK: Writing

    /// Refuses a change that the device could not be sent because an earlier call to it has not returned.
    package func checkAcceptsChanges() throws {
        try checkIsListed()
        if let unresponsiveOperation {
            throw DeviceOperationFailure.notSent(operation: "change the device's state", heldBy: unresponsiveOperation)
        }
    }

    /// Refuses a change that a later device with the same identity must not receive.
    package func checkIsListed() throws {
        guard !isRetired else { throw SimulatorError.operation("This device is no longer available.") }
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

    /// A session retains its model while it shows it; an authoritative inventory removal can retire that model.
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
