import Foundation
import NeoSimulatorDeviceIO
import Observation

/// A value a device reports about itself, structured however its tools report it.
public indirect enum DeviceInfoValue: Equatable, Sendable {
    case object([String: Self]), array([Self]), string(String), integer(Int64), unsignedInteger(UInt64), number(Double),
         boolean(Bool), data(Data), date(Date), null

    package init(_ value: DeviceInspectorValue) {
        switch value {
        case .object(let fields): self = .object(fields.mapValues(Self.init))
        case .array(let values): self = .array(values.map(Self.init))
        case .string(let value): self = .string(value)
        case .integer(let value): self = .integer(value)
        case .unsignedInteger(let value): self = .unsignedInteger(value)
        case .number(let value): self = .number(value)
        case .boolean(let value): self = .boolean(value)
        case .data(let value): self = .data(value)
        case .date(let value): self = .date(value)
        case .null: self = .null
        }
    }

    public var string: String? { if case .string(let value) = self { value } else { nil } }
    public subscript(_ key: String) -> Self? { if case .object(let fields) = self { fields[key] } else { nil } }
}

/// Whether a device can answer for part of its inspection.
package enum DeviceInspectionSupport {
    case available
    /// A simulator that has not started, or a device that has not connected.
    case notNow
    case unsupported
}

/// What a device reports of itself: its details, its installed applications and profiles, and its reports.
///
/// Each part is read independently, only while something holds it through ``DeviceModel/keepCurrent(_:)``, and keeps what it
/// last answered until a later answer replaces it. A failed read leaves the values and reports its reason in ``status(of:)``.
/// ``DeviceReadStatus/unsupported`` means that the device never has this part, and clears it; a device that might answer
/// later keeps what it has, and ``canRead(_:)`` says that it cannot answer now.
///
/// A change made through this object or a screen's import marks only what it can have changed as out of date. A change made
/// elsewhere stays unknown until ``DeviceModel/revalidate(_:)``.
@MainActor @Observable
public final class DeviceInspectionState {
    /// The device's details under the names its tools use, so a name that one device has another can lack.
    public var info: [String: DeviceInfoValue] { infoRead.value }
    public var applications: [DeviceApplication] { applicationsRead.value }
    public var configurationProfiles: [DeviceProfile] { configurationRead.value }
    public var provisioningProfiles: [DeviceProfile] { provisioningRead.value }
    /// The device's reports, most recently modified first.
    public var reports: [DeviceReport] { reportsRead.value }

    @ObservationIgnored private weak var owner: DeviceModel?
    private let infoRead = InspectionRead<[String: DeviceInfoValue]>(group: .info, empty: [:]) { inspector in
        let snapshot = await inspector.info()
        if snapshot.issues.contains(where: { $0.error is CancellationError }) { throw CancellationError() }
        let fields = snapshot.fields.mapValues(DeviceInfoValue.init)
        guard !snapshot.issues.isEmpty else { return InspectionAnswer { _ in fields } }
        return InspectionAnswer(issue: snapshot.issues.map(\.localizedDescription).joined(separator: "\n")) {
            $0.merging(fields) { _, new in new }
        }
    }
    private let applicationsRead = InspectionRead<[DeviceApplication]>(group: .applications, empty: []) { inspector in
        let applications = try await inspector.applications()
        return InspectionAnswer { _ in applications }
    }
    private let configurationRead = InspectionRead<[DeviceProfile]>(group: .configurationProfiles, empty: []) { inspector in
        let snapshot = try await inspector.profiles(kind: .configuration)
        return .profiles(snapshot.profiles, partial: snapshot.partialConfigurationProfiles.count)
    }
    private let provisioningRead = InspectionRead<[DeviceProfile]>(group: .provisioningProfiles, empty: []) { inspector in
        let snapshot = try await inspector.profiles(kind: .provisioning)
        return .profiles(snapshot.profiles, partial: snapshot.partialProvisioningProfiles.count)
    }
    private let reportsRead = InspectionRead<[DeviceReport]>(group: .reports, empty: []) { inspector in
        let snapshot = try await inspector.reports()
        let reports = snapshot.reports.sorted {
            if $0.modificationDate != $1.modificationDate { return ($0.modificationDate ?? .distantPast) > ($1.modificationDate ?? .distantPast) }
            return $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
        let issue = snapshot.issues.isEmpty ? nil : "\(snapshot.issues.count) reports returned incomplete metadata. Available reports are shown."
        return InspectionAnswer(issue: issue) { _ in reports }
    }

    private var reads: [any InspectionReading] { [infoRead, applicationsRead, configurationRead, provisioningRead, reportsRead] }

    package init() {}

    package func attach(to owner: DeviceModel) {
        self.owner = owner
        for read in reads { read.attach(to: owner) }
    }

    /// What the last read of `group`, one group of ``DeviceStateGroups/inspection``, answered.
    public func status(of group: DeviceStateGroups) -> DeviceReadStatus {
        reads.first { $0.group == group }?.status ?? .unread
    }

    /// Whether a read of any of `groups` is running.
    public func isReading(_ groups: DeviceStateGroups) -> Bool {
        reads.contains { groups.contains($0.group) && $0.isReading }
    }

    /// Whether the device can answer for `group`, one group of ``DeviceStateGroups/inspection``, now. A stopped simulator
    /// cannot list its applications, for example, but keeps what it last listed.
    public func canRead(_ group: DeviceStateGroups) -> Bool {
        guard let owner, !owner.isRetired else { return false }
        return owner.inventory.inspectionSupport(of: group) == .available
    }

    // MARK: Changing

    /// Installs an `.app` bundle or the application in an `.ipa` package, and returns when it has finished.
    public func installApplication(at url: URL) async throws {
        try await change(affecting: .applications) { try await $0.installApplication(at: url) }
    }

    public func uninstallApplication(bundleIdentifier: String) async throws {
        try await change(affecting: .applications) { try await $0.uninstallApplication(bundleIdentifier: bundleIdentifier) }
    }

    public func installProfile(at url: URL, kind: DeviceProfileKind) async throws {
        try await change(affecting: .profiles(of: kind)) { try await $0.installProfile(at: url, kind: kind) }
    }

    public func removeProfile(identifier: String, kind: DeviceProfileKind) async throws {
        try await change(affecting: .profiles(of: kind)) { try await $0.removeProfile(identifier: identifier, kind: kind) }
    }

    /// Runs `perform` in its turn among the device's changes. Reads of `groups` wait for it and an earlier read of them does
    /// not answer, and afterwards they are out of date, even after a failure, which can have changed the device. `prepare`
    /// runs at the change's turn, and throwing from it stops the change with nothing sent.
    package func change(affecting groups: DeviceStateGroups, prepare: (@MainActor () throws -> Void)? = nil,
                        perform: @escaping @Sendable (DeviceInspector) async throws -> Void) async throws {
        guard let owner else { throw CancellationError() }
        try owner.checkIsListed()
        let affected = reads.filter { groups.contains($0.group) }
        for read in affected { read.changeAccepted() }
        let write = owner.enqueueWrite(after: nil) { [weak self] in
            guard let owner = self?.owner else { throw CancellationError() }
            try prepare?()
            try await perform(try await owner.source.inspector(for: owner.inventory))
        } settle: { result in
            for read in affected { read.changeSettled(result) }
        }
        try await withTaskCancellationHandler { try await write.task.value } onCancel: { write.task.cancel() }
    }

    /// What runs commands that change nothing here, such as one that downloads what the device holds.
    package func inspector() async throws -> DeviceInspector {
        guard let owner else { throw CancellationError() }
        try owner.checkIsListed()
        return try await owner.source.inspector(for: owner.inventory)
    }

    // MARK: Reading

    package func markDirty(_ groups: DeviceStateGroups) {
        for read in reads where groups.contains(read.group) { read.markDirty() }
    }

    package func scheduleReads() {
        for read in reads { read.scheduleRead() }
    }

    package func discardRunningReads() {
        for read in reads { read.discardRunningRead() }
    }

    package func cancelReads() {
        for read in reads { read.cancelRead() }
    }

    package func finishReading() async {
        for read in reads { await read.finishReading() }
    }

    /// The device's inventory record changed, which is part of its details and can change what it can answer for.
    package func deviceChanged() {
        infoRead.markDirty()
        for read in reads { read.supportChanged() }
    }
}

extension DeviceStateGroups {
    package static func profiles(of kind: DeviceProfileKind) -> Self {
        kind == .configuration ? .configurationProfiles : .provisioningProfiles
    }
}

/// What a read found. `update` makes the new value from the one before, because an incomplete answer can add to it.
private struct InspectionAnswer<Value: Sendable>: Sendable {
    /// What the read could not answer.
    var issue: String?
    let update: @Sendable (Value) -> Value
}

extension InspectionAnswer<[DeviceProfile]> {
    fileprivate static func profiles(_ profiles: [DeviceProfile], partial: Int) -> Self {
        let issue = partial == 0 ? nil : "\(partial) profiles returned incomplete records. Available profiles are shown."
        return Self(issue: issue) { _ in profiles }
    }
}

@MainActor
private protocol InspectionReading: AnyObject {
    var group: DeviceStateGroups { get }
    var status: DeviceReadStatus { get }
    var isReading: Bool { get }
    func attach(to owner: DeviceModel)
    func markDirty()
    func scheduleRead()
    func discardRunningRead()
    func cancelRead()
    func finishReading() async
    func supportChanged()
    func changeAccepted()
    func changeSettled(_ result: DeviceWriteResult)
}

/// One part of a device's inspection: what it last answered, and the one read of it that can be running.
@MainActor @Observable
private final class InspectionRead<Value: Equatable & Sendable>: InspectionReading {
    private(set) var value: Value
    private(set) var status = DeviceReadStatus.unread
    private(set) var isReading = false

    @ObservationIgnored let group: DeviceStateGroups
    @ObservationIgnored private let empty: Value
    @ObservationIgnored private let read: @Sendable (DeviceInspector) async throws -> InspectionAnswer<Value>
    @ObservationIgnored private weak var owner: DeviceModel?
    @ObservationIgnored private var dirty = true
    @ObservationIgnored private var serial = 0
    @ObservationIgnored private var changes = 0
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var readIdentifier: UUID?

    init(group: DeviceStateGroups, empty: Value, read: @escaping @Sendable (DeviceInspector) async throws -> InspectionAnswer<Value>) {
        self.group = group
        self.empty = empty
        self.read = read
        value = empty
    }

    func attach(to owner: DeviceModel) {
        self.owner = owner
        supportChanged()
    }

    func markDirty() { dirty = true }

    /// A later read follows any read that is running, and a part with an accepted change reads after its outcome.
    func scheduleRead() {
        guard let owner, !owner.readsStopped, dirty, readTask == nil, changes == 0, owner.wants(group),
              owner.inventory.inspectionSupport(of: group) == .available else { return }
        dirty = false
        isReading = true
        let identifier = UUID()
        readIdentifier = identifier
        let epoch = owner.epoch
        let request = serial
        let source = owner.source
        let device = owner.inventory
        readTask = Task { [weak self, read] in
            let result: Result<InspectionAnswer<Value>, any Error>
            do { result = .success(try await read(try await source.inspector(for: device))) }
            catch { result = .failure(error) }
            self?.receive(result, epoch: epoch, serial: request, identifier: identifier)
        }
    }

    private func receive(_ result: Result<InspectionAnswer<Value>, any Error>, epoch: Int, serial request: Int, identifier: UUID) {
        guard readIdentifier == identifier else { return }
        readTask = nil
        readIdentifier = nil
        isReading = false
        defer { scheduleRead() }
        guard let owner, epoch == owner.epoch, !owner.readsStopped, request == serial else {
            dirty = true
            return
        }
        switch result {
        case .success(let answer):
            let updated = answer.update(value)
            if value != updated { value = updated }
            setStatus(answer.issue.map { .stale($0) } ?? .current)
        case .failure(let error):
            if error is CancellationError || (error as? DeviceInspectorFailure)?.error is CancellationError {
                dirty = true
                return
            }
            NSLog("NeoSimulator inspection read: %@", String(describing: error))
            setStatus(.stale(error.localizedDescription))
        }
    }

    func discardRunningRead() {
        cancelRead()
        readTask = nil
        readIdentifier = nil
        if isReading { isReading = false }
        dirty = true
    }

    func cancelRead() { readTask?.cancel() }

    func finishReading() async {
        while let readTask { await readTask.value }
    }

    /// What can never answer holds nothing and reads nothing. It can answer again after a change of its inventory record.
    func supportChanged() {
        guard let owner else { return }
        if owner.inventory.inspectionSupport(of: group) == .unsupported {
            guard status != .unsupported else { return }
            discardRunningRead()
            if value != empty { value = empty }
            setStatus(.unsupported)
        } else if status == .unsupported {
            setStatus(.unread)
            dirty = true
        }
    }

    func changeAccepted() {
        changes += 1
        serial += 1
    }

    func changeSettled(_ result: DeviceWriteResult) {
        changes -= 1
        if case .notStarted = result {} else { dirty = true }
        scheduleRead()
    }

    private func setStatus(_ status: DeviceReadStatus) {
        if self.status != status { self.status = status }
    }
}
