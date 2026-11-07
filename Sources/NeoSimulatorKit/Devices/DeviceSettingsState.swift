import Foundation
import NeoSimulatorDeviceIO
import Observation

/// Observable settings for one device. Groups publish independently as reads finish.
/// Accepted changes appear immediately and remain until their outcome is known.
///
/// A value is `nil`, or an array is empty, until its group's read answers and on a device without that setting. Use
/// ``status(of:)`` to tell these apart. A device can be read only while ``DeviceModel/canInspectSettings`` is `true`.
@MainActor @Observable
public final class DeviceSettingsState {
    /// The light or dark appearance.
    public private(set) var appearance: DeviceAppearance?
    /// The preferred text size.
    public private(set) var contentSize: DeviceContentSize?
    /// Whether Bold Text is on. Only iPhone and iPad simulators report this.
    public private(set) var boldText: Bool?
    /// The current Display Zoom mode. Only iPhone and iPad simulators report this.
    public private(set) var displayZoom: SimulatorDisplayZoomMode?
    /// The Display Zoom modes that the device offers.
    public private(set) var supportedDisplayZoomModes: [SimulatorDisplayZoomMode] = []
    /// Whether Increase Contrast is on.
    public private(set) var increaseContrast: Bool?
    /// The look and feel as the device names it, which can be a value that ``SimulatorLookAndFeel`` does not list.
    public private(set) var lookAndFeel: String?
    /// The looks and feels that the device offers.
    public private(set) var supportedLooksAndFeels: [SimulatorLookAndFeel] = []
    /// The Liquid Glass opacity.
    public private(set) var liquidGlassOpacity: Double?
    /// The current color filter.
    public private(set) var colorFilter: SimulatorColorFilter?
    /// The current color filter's intensity.
    public private(set) var colorFilterIntensity: Double?
    /// The OS version required when this guest cannot change color filters.
    public private(set) var colorFilterRequiredOSVersion: Int?
    /// Whether Reduce Motion is on.
    public private(set) var reduceMotion: Bool?
    /// Whether Show Borders is on.
    public private(set) var showBorders: Bool?
    /// Whether Reduce Transparency is on.
    public private(set) var reduceTransparency: Bool?
    /// Whether VoiceOver is on.
    public private(set) var voiceOver: Bool?
    /// The output volume.
    public private(set) var volume: Int?
    /// `systemDefault`, or a CoreAudio device UID.
    public private(set) var audioInputDevice: String?
    /// `systemDefault`, or a CoreAudio device UID.
    public private(set) var audioOutputDevice: String?
    /// The audio inputs that the device can select.
    public private(set) var audioInputDevices: [SimulatorAudioDevice] = []
    /// The audio outputs that the device can select.
    public private(set) var audioOutputDevices: [SimulatorAudioDevice] = []
    /// Whether the device can simulate a location.
    public private(set) var locationAvailable = false
    /// The recorded routes that the device can simulate.
    public private(set) var locationScenarios: [SimulatorLocationScenario] = []
    /// The device's saved desired location mode. External live changes may differ.
    public private(set) var locationMode: DeviceLocationMode?
    /// The ``SimulatorLocationScenario/name`` of the selected route when ``locationMode`` is
    /// ``DeviceLocationMode/scenario``.
    public private(set) var locationScenario: String?
    /// Whether no group has answered yet.
    public private(set) var isLoading = true

    @Observable
    fileprivate final class GroupRead {
        var status = DeviceReadStatus.unread
    }

    private struct PendingEdit {
        let id = UUID()
        let change: DeviceSettingChange
    }

    /// What identifies a batch of reads when its results arrive.
    @MainActor
    private final class ReadBatch {
        let epoch: Int
        let serials: [DeviceSettingsGroup: Int]
        var answered: Set<DeviceSettingsGroup> = []

        init(epoch: Int, serials: [DeviceSettingsGroup: Int]) {
            self.epoch = epoch
            self.serials = serials
        }
    }

    @ObservationIgnored package weak var owner: DeviceModel?
    @ObservationIgnored private let reads = Dictionary(uniqueKeysWithValues: DeviceSettingsGroup.allCases.map { ($0, GroupRead()) })
    @ObservationIgnored private var confirmed = SimulatorDeviceSettings()
    @ObservationIgnored private var pending: [PendingEdit] = []
    @ObservationIgnored private var dirty = Set(DeviceSettingsGroup.allCases)
    /// Out-of-date groups that read regardless of interest, because they confirm a change.
    @ObservationIgnored private var forced: Set<DeviceSettingsGroup> = []
    @ObservationIgnored private var reading: Set<DeviceSettingsGroup> = []
    /// Changes with each accepted change, so that a result read before it is dropped and read again.
    @ObservationIgnored private var serials: [DeviceSettingsGroup: Int] = [:]
    @ObservationIgnored private var readTasks: [UUID: Task<Void, Never>] = [:]

    package init() {}

    /// Returns the last read status of `group`.
    ///
    /// - Parameter group: The group to look up.
    /// - Returns: The group's status.
    public func status(of group: DeviceSettingsGroup) -> DeviceReadStatus { reads[group]!.status }

    /// Read failures by group. Failed reads preserve the previous values.
    public var failures: [String] {
        DeviceSettingsGroup.allCases.compactMap { group in
            if case .stale(let reason) = status(of: group) { reason } else { nil }
        }
    }

    /// Applies `change` optimistically and waits for completion. Cancellation before execution
    /// sends nothing; cancellation after it starts reports an unknown outcome and triggers read-back.
    ///
    /// Changes to one device run in the order they are accepted. The new value appears at once and stays until the change
    /// settles. A change that reached the device is then read back, even without a ``DeviceReadInterest``.
    ///
    /// - Parameter change: The change to apply.
    /// - Throws: ``SimulatorError/operation(_:)`` if the device is no longer listed, `CancellationError` if the caller
    ///   is cancelled, or another error if the device cannot accept the change or applying it fails. Use the
    ///   error's `localizedDescription`, because these errors are not all ``SimulatorError`` values.
    public func set(_ change: DeviceSettingChange) async throws {
        let write = try accept(change)
        try await withTaskCancellationHandler { try await write.task.value } onCancel: { write.task.cancel() }
    }

    /// `hold` is what the change must follow other than the device's earlier changes.
    package func accept(_ change: DeviceSettingChange, after hold: Task<Void, Never>? = nil) throws -> DeviceWrite {
        guard let owner else { throw CancellationError() }
        try owner.checkAcceptsChanges()
        let edit = PendingEdit(change: change)
        pending.append(edit)
        serials[change.group, default: 0] += 1
        publish()
        return owner.enqueueWrite(after: hold) { [weak owner] in
            guard let owner else { throw CancellationError() }
            try await owner.source.write(change, to: owner.inventory)
        } settle: { [weak self] result in
            self?.settle(edit, result)
        }
    }

    private func settle(_ edit: PendingEdit, _ result: DeviceWriteResult) {
        pending.removeAll { $0.id == edit.id }
        let group = edit.change.group
        switch result {
        case .applied:
            confirmed = confirmed.applying(edit.change)
            forced.insert(group)
        case .notStarted:
            break
        case .failed(let error):
            switch error {
            case DeviceOperationFailure.notSent: break
            case is DeviceOperationFailure, is CancellationError:
                setStatus(.stale(error.localizedDescription), of: group)
                forced.insert(group)
            default: forced.insert(group)
            }
        }
        dirty.insert(group)
        publish()
        scheduleReads()
    }

    // MARK: Reading

    package func markAllDirty() { dirty.formUnion(DeviceSettingsGroup.allCases) }

    /// Something other than a change through this object may have changed `groups`, such as a device command.
    package func invalidate(_ groups: Set<DeviceSettingsGroup>) {
        for group in groups { serials[group, default: 0] += 1 }
        dirty.formUnion(groups)
        scheduleReads()
    }

    /// Refreshes invalidated groups with active read interest. Reads within a group coalesce,
    /// and accepted changes defer read-back until their final outcome. Groups proceed independently.
    package func scheduleReads() {
        guard let owner, !owner.readsStopped, owner.inventory.canInspectSettings else { return }
        let wanted = owner.wants(.settings) ? dirty : dirty.intersection(forced)
        let groups = wanted.subtracting(reading).subtracting(pending.map(\.change.group))
        guard !groups.isEmpty else { return }
        dirty.subtract(groups)
        forced.subtract(groups)
        reading.formUnion(groups)
        let batch = ReadBatch(epoch: owner.epoch, serials: serials)
        let identifier = UUID()
        let source = owner.source
        let device = owner.inventory
        readTasks[identifier] = Task { [weak self] in
            await source.readSettings(groups, of: device) { [weak self] read in
                await self?.receive(read, batch)
            }
            self?.finish(batch, requested: groups, identifier: identifier)
        }
    }

    private func receive(_ read: DeviceSettingsGroupRead, _ batch: ReadBatch) {
        guard let owner, batch.epoch == owner.epoch, reading.contains(read.group) else { return }
        let group = read.group
        batch.answered.insert(group)
        reading.remove(group)
        // What this answer leaves out of date does not wait for the rest of its batch.
        defer { scheduleReads() }
        // A stopped read may have seen nothing, and one begun before an accepted change can predate it.
        guard !owner.readsStopped, batch.serials[group, default: 0] == serials[group, default: 0] else {
            dirty.insert(group)
            return
        }
        switch read.outcome {
        case .values:
            read.apply(&confirmed)
            if read.failures.isEmpty { setStatus(.current, of: group) }
            else {
                NSLog("NeoSimulator settings: %@", read.failures.joined(separator: "\n"))
                setStatus(.stale(read.failures.joined(separator: "\n")), of: group)
            }
        case .failed(let reason):
            NSLog("NeoSimulator settings: %@", reason)
            setStatus(.stale(reason), of: group)
        case .unsupported:
            confirmed.replace(group, with: SimulatorDeviceSettings())
            setStatus(.unsupported, of: group)
        }
        publish()
    }

    /// A group left unanswered, as by cancellation, stays out of date for the next invalidation.
    private func finish(_ batch: ReadBatch, requested: Set<DeviceSettingsGroup>, identifier: UUID) {
        readTasks[identifier] = nil
        guard batch.epoch == owner?.epoch else { return }
        let unanswered = requested.subtracting(batch.answered)
        reading.subtract(unanswered)
        scheduleReads()
        dirty.formUnion(unanswered)
    }

    /// Reads of the device before now can answer nothing of the device now.
    package func discardRunningReads() {
        cancelReads()
        reading.removeAll()
        markAllDirty()
    }

    package func cancelReads() { readTasks.values.forEach { $0.cancel() } }

    package func finishReading() async {
        while let task = readTasks.values.first { await task.value }
    }

    private func setStatus(_ status: DeviceReadStatus, of group: DeviceSettingsGroup) {
        let read = reads[group]!
        if read.status != status { read.status = status }
        let loading = reads.values.allSatisfy { $0.status == .unread }
        if isLoading != loading { isLoading = loading }
    }

    // MARK: Observations

    /// Applies a value already known by the connected session without changing the group's read status.
    package func observe(audioRoutes: AudioRouteState) {
        confirmed.updateAudioRoutes(audioRoutes)
        publish()
    }

    package func observe(location: LocationSelection) {
        switch location {
        case .none:
            confirmed.locationMode = DeviceLocationMode.none
            confirmed.locationScenario = nil
        case .custom:
            confirmed.locationMode = .custom
            confirmed.locationScenario = nil
        case .scenario(let name):
            confirmed.locationMode = .scenario
            confirmed.locationScenario = name
        }
        publish()
    }

    package func observe(locationScenarios scenarios: [LocationScenario]) {
        confirmed.locationAvailable = true
        confirmed.locationScenarios = scenarios.map { SimulatorLocationScenario(name: $0.name, displayName: $0.localizedName) }
        publish()
    }

    // MARK: Publication

    private func publish() {
        var values = confirmed
        for edit in pending { values = values.applying(edit.change) }
        assign(\.appearance, values.appearance)
        assign(\.contentSize, values.contentSize)
        assign(\.boldText, values.boldText)
        assign(\.displayZoom, values.displayZoom)
        assign(\.supportedDisplayZoomModes, values.supportedDisplayZoomModes)
        assign(\.increaseContrast, values.increaseContrast)
        assign(\.lookAndFeel, values.lookAndFeel)
        assign(\.supportedLooksAndFeels, values.supportedLooksAndFeels)
        assign(\.liquidGlassOpacity, values.liquidGlassOpacity)
        assign(\.colorFilter, values.colorFilter)
        assign(\.colorFilterIntensity, values.colorFilterIntensity)
        assign(\.colorFilterRequiredOSVersion, values.colorFilterRequiredOSVersion)
        assign(\.reduceMotion, values.reduceMotion)
        assign(\.showBorders, values.showBorders)
        assign(\.reduceTransparency, values.reduceTransparency)
        assign(\.voiceOver, values.voiceOver)
        assign(\.volume, values.volume)
        assign(\.audioInputDevice, values.audioInputDevice)
        assign(\.audioOutputDevice, values.audioOutputDevice)
        assign(\.audioInputDevices, values.audioInputDevices)
        assign(\.audioOutputDevices, values.audioOutputDevices)
        assign(\.locationAvailable, values.locationAvailable)
        assign(\.locationScenarios, values.locationScenarios)
        assign(\.locationMode, values.locationMode)
        assign(\.locationScenario, values.locationScenario)
    }

    private func assign<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<DeviceSettingsState, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }
}
