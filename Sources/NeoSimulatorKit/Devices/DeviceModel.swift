import Foundation
import NeoSimulatorDeviceIO
import Observation
import Synchronization

/// The parts of a device's state that are read independently.
public struct DeviceStateGroups: OptionSet, Sendable {
    /// The bit values of the groups in this set.
    public var rawValue: Int

    /// Creates a set of groups from their bit values.
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// The values in ``DeviceSettingsState``.
    public static let settings = Self(rawValue: 1 << 0)
    /// The values in ``BackgroundServicesState``.
    public static let backgroundServices = Self(rawValue: 1 << 1)
    /// What device commands show, which only a connected screen's session can read.
    public static let commandState = Self(rawValue: 1 << 2)
    /// ``DeviceInspectionState/info``.
    public static let info = Self(rawValue: 1 << 3)
    /// ``DeviceInspectionState/applications``.
    public static let applications = Self(rawValue: 1 << 4)
    /// ``DeviceInspectionState/configurationProfiles``.
    public static let configurationProfiles = Self(rawValue: 1 << 5)
    /// ``DeviceInspectionState/provisioningProfiles``.
    public static let provisioningProfiles = Self(rawValue: 1 << 6)
    /// ``DeviceInspectionState/reports``.
    public static let reports = Self(rawValue: 1 << 7)
    /// Everything in ``DeviceInspectionState``.
    public static let inspection: Self = [.info, .applications, .configurationProfiles, .provisioningProfiles, .reports]
    /// Every group.
    public static let all: Self = [.settings, .backgroundServices, .commandState, .inspection]
}

/// Keeps selected state groups current until released.
/// Without an interest, reads occur only to confirm accepted changes.
///
/// Deallocating an interest also releases it. Other interests in the same groups keep them current.
@MainActor
public final class DeviceReadInterest {
    private var end: (@MainActor () -> Void)?

    fileprivate init(end: @escaping @MainActor () -> Void) { self.end = end }

    /// Ends this interest. Calling this again does nothing.
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
///
/// After the inventory stops listing the device, the model keeps its last values, ``isAvailable`` becomes `false`, and
/// changes to the device throw ``SimulatorError/operation(_:)``.
@MainActor @Observable
public final class DeviceModel: Identifiable {
    /// The device's stable identity.
    public nonisolated let id: DeviceInventoryID
    /// The name that the inventory last listed.
    public private(set) var name: String
    /// The kind of device that the inventory last listed.
    public private(set) var kind: DeviceInventoryKind
    /// Whether the inventory last listed the device as available. This is `false` once the inventory stops listing it.
    public private(set) var isAvailable: Bool
    /// Whether the device can answer for its settings now. A simulator must be running.
    public private(set) var canInspectSettings: Bool
    /// Whether the device can answer for its background services now. Only a running simulator can.
    public private(set) var canInspectBackgroundServices: Bool
    package private(set) var inventory: InventoryDevice

    /// The device's settings.
    public let settings: DeviceSettingsState
    /// The device's background services, which only a running simulator can report.
    public let backgroundServices: BackgroundServicesState
    /// The device's details, applications, profiles, and reports.
    public let inspection: DeviceInspectionState

    /// Whether biometrics are enrolled. Touch ID, Face ID, and Optic ID share this guest state.
    ///
    /// Only a connected session reads this. It is `nil` before that read, after the session ends, and on a device
    /// without biometrics.
    public private(set) var isBiometricEnrolled: Bool?
    /// Whether the guest is showing StandBy.
    ///
    /// Only a connected session reads this. It is `nil` before that read, after the session ends, and on a device
    /// without StandBy.
    public private(set) var showsStandBy: Bool?
    /// The Core Animation debug options as the device last reported them.
    ///
    /// Only a connected session reads these, so this is empty before that read and after the session ends.
    public private(set) var debugOptions: [CADebugOption: Bool] = [:]
    /// The native request past its deadline. New requests are rejected until it returns.
    public private(set) var unresponsiveOperation: String?
    /// Why the last read or reapplied setting failed, until a later read succeeds.
    public private(set) var lastIssue: String?
    /// The device's audio routes as a connected screen's audio port last reported them.
    package private(set) var audioRoutes: AudioRouteState?

    @ObservationIgnored package let source: any DeviceStateSource
    @ObservationIgnored private weak var registry: DeviceRegistry?
    /// The categories whose services ``backgroundServices`` reads and changes.
    package var backgroundServiceCatalog: BackgroundServiceCatalog { registry?.backgroundServiceCatalog ?? .builtIn }
    /// The inventory sources that last listed the device, which decide when its absence means that it has gone.
    @ObservationIgnored package private(set) var sources: Set<DeviceInventoryIssue.Source> = []
    /// Results of reads from before this changes describe a device that no longer exists, so they are dropped.
    @ObservationIgnored package private(set) var epoch = 0
    @ObservationIgnored package private(set) var readsStopped: Bool
    @ObservationIgnored package private(set) var isRetired = false
    @ObservationIgnored private var interest: [Int: Int] = [:]
    @ObservationIgnored private var presentations = 0
    @ObservationIgnored private var commandReaders: [UUID: @MainActor () -> Void] = [:]
    @ObservationIgnored private var health: [Task<Void, Never>] = []
    @ObservationIgnored private weak var followedChannel: SimulatorDeviceChannel?
    /// The call that each followed channel holds, in the order that ``follow(_:)`` follows them.
    @ObservationIgnored private var heldCalls: [String?] = []
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
        for follower in health { follower.cancel() }
        for observer in recoveryObservers.values { observer.finish() }
    }

    // MARK: Reading

    /// Reads what is out of date in `groups` now, and again whenever it is invalidated, until the result is released.
    ///
    /// - Parameter groups: The groups to keep current.
    /// - Returns: An interest to retain for as long as the groups should stay current.
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
    ///
    /// - Parameter groups: The groups to invalidate.
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
        for follower in health { follower.cancel() }
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

    /// Refuses a change that the device must not receive. One that an earlier call holds the way to is refused by the
    /// channel that it would take, since a call held on one of a device's channels leaves the others answering.
    package func checkAcceptsChanges() throws {
        try checkIsListed()
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

    /// Keeps `unresponsiveOperation` as `channel` and, for a device's channel, the channel of the requests that its guest
    /// answers report it, since either can hold a call while the other answers. A channel's stream has one consumer
    /// each, so the model takes its own and fans recoveries out through ``recoveries()``.
    package func follow(_ channel: SimulatorDeviceChannel) {
        guard followedChannel !== channel else { return }
        followedChannel = channel
        for follower in health { follower.cancel() }
        var channels = [channel]
        if case .device(let device) = channel.scope { channels.append(DeviceIOHub.shared.channel(for: .bridge(device))) }
        // What a replaced channel held is taken as this one's, so that its first report of an answer recovers the device.
        heldCalls = [unresponsiveOperation] + Array(repeating: nil, count: channels.count - 1)
        health = channels.enumerated().map { index, channel in
            let changes = channel.healthChanges()
            return Task { [weak self] in
                for await health in changes {
                    // A channel that another has replaced may still have had a change on its way.
                    guard let self, !Task.isCancelled else { return }
                    self.apply(health, from: index)
                }
            }
        }
    }

    /// A channel that answers again is a recovery even while another still holds a call, since what it takes can go on.
    private func apply(_ health: DeviceChannelHealth, from channel: Int) {
        let wasHeld = heldCalls[channel] != nil
        if case .unresponsive(let call, _) = health { heldCalls[channel] = call } else { heldCalls[channel] = nil }
        let held = heldCalls.lazy.compactMap { $0 }.first
        if held != unresponsiveOperation { unresponsiveOperation = held }
        guard wasHeld, heldCalls[channel] == nil else { return }
        revalidate([.settings, .backgroundServices])
        for observer in recoveryObservers.values { observer.yield() }
    }

    /// An element each time a call that outlived its deadline on one of the device's channels returns, which is the only
    /// thing that recovers that channel.
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
