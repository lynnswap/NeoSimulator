import NeoSimulatorKit
import NeoSimulatorHostSupport
import Foundation
import Observation

@MainActor @Observable
final class ServiceProfile: Identifiable, BackgroundServiceEditing {
    struct Record: Codable, Equatable, Sendable {
        let id: UUID
        var name: String
        var configuration: ServiceConfiguration
    }

    let id: UUID
    private(set) var name: String
    private(set) var configuration: ServiceConfiguration
    private(set) var serviceState: SimulatorBackgroundServices?
    var issue: String?
    @ObservationIgnored fileprivate weak var store: ServiceProfileStore?
    var canEdit: Bool { store != nil && id != Self.default.id }
    @ObservationIgnored lazy var categories = SimulatorBackgroundServiceCategory.all.map {
        BackgroundServiceCategoryModel($0, source: self)
    }

    nonisolated static let defaultID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    static let `default` = ServiceProfile(record: Record(
        id: defaultID, name: "Default", configuration: ServiceConfiguration()))

    fileprivate var record: Record { Record(id: id, name: name, configuration: configuration) }

    fileprivate init(record: Record) {
        id = record.id
        name = record.name
        configuration = record.configuration
        serviceState = record.configuration.state()
    }

    func setServices(_ targets: [SimulatorBackgroundServiceTarget], enabled: Bool) {
        guard canEdit, let store else { return }
        var updated = configuration
        updated.set(targets, enabled: enabled)
        do { try store.update(id, configuration: updated) }
        catch { issue = error.localizedDescription }
    }

    fileprivate func update(from record: Record) {
        if name != record.name { name = record.name }
        if configuration != record.configuration {
            configuration = record.configuration
            serviceState = record.configuration.state()
        }
    }
}

/// Which profile a device takes at each boot.
enum ServiceProfileSelection: Codable, Hashable, Sendable {
    /// The common default, whichever it is then. Nothing applies while it is off.
    case inheritDefault
    case profile(UUID)
    /// Nothing is written automatically, including the device's overrides.
    case doNotApply
}

/// A device's choice and its explicit per-service changes, which apply above whatever the choice resolves to.
struct DeviceServiceProfile: Codable, Equatable, Sendable {
    var selection: ServiceProfileSelection
    var overrides: [String: Bool]

    private enum LegacyCodingKeys: String, CodingKey { case profileID, pendingApplication }

    init(selection: ServiceProfileSelection = .inheritDefault, overrides: [String: Bool] = [:]) {
        self.selection = selection
        self.overrides = overrides
    }

    /// Default also represented devices without a choice. A pending application distinguishes an explicit Default
    /// request; other Default bindings inherit, so a device the user only toggled does not gain an automatic profile.
    /// These are persistent startup choices; upgrading leaves already-running devices unchanged.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        overrides = try values.decode([String: Bool].self, forKey: .overrides)
        if let selection = try values.decodeIfPresent(ServiceProfileSelection.self, forKey: .selection) {
            self.selection = selection
        } else {
            let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
            let profileID = try legacy.decode(UUID.self, forKey: .profileID)
            let pending = try legacy.decodeIfPresent(Bool.self, forKey: .pendingApplication) ?? false
            selection = profileID == ServiceProfile.defaultID && !pending ? .inheritDefault : .profile(profileID)
        }
    }
}

/// Owns reusable definitions and device-specific intent. Live launchd state stays in each device's `BackgroundServicesState`.
@MainActor @Observable
final class ServiceProfileStore {
    private struct State: Codable, Equatable {
        var profiles: [ServiceProfile.Record] = []
        var commonProfileID: UUID?
        var devices: [DeviceInventoryID: DeviceServiceProfile] = [:]
    }

    enum Failure: Error, LocalizedError {
        case emptyName, missingProfile

        var errorDescription: String? {
            switch self {
            case .emptyName: "Enter a name for the service profile."
            case .missingProfile: "This service profile no longer exists."
            }
        }
    }

    static let defaultsKey = "BackgroundServiceProfiles"
    private(set) var profiles: [ServiceProfile] = []
    /// What devices that inherit take at each boot. Nil means that nothing applies to them.
    private(set) var commonProfileID: UUID?
    private var devices: [DeviceInventoryID: DeviceServiceProfile] = [:]
    private var state: State { State(profiles: profiles.map(\.record), commonProfileID: commonProfileID, devices: devices) }
    private(set) var issue: String?
    let fileURL: URL
    @ObservationIgnored private let legacyDefaults: UserDefaults?
    @ObservationIgnored private var loadFailure: (any Error)?

    static var defaultFileURL: URL {
        let identifier = Bundle(for: ServiceProfileStore.self).bundleIdentifier ?? "dev.lynnswap.NeoSimulator"
        return URL.applicationSupportDirectory.appending(path: identifier, directoryHint: .isDirectory)
            .appending(path: "ServiceProfiles.json")
    }

    init(fileURL: URL = ServiceProfileStore.defaultFileURL, legacyDefaults: UserDefaults? = .standard) {
        self.fileURL = fileURL
        self.legacyDefaults = legacyDefaults
        reload()
    }

    var availableProfiles: [ServiceProfile] { [.default] + profiles }
    func profile(_ id: UUID) -> ServiceProfile? { id == ServiceProfile.default.id ? .default : profiles.first { $0.id == id } }
    func binding(for device: DeviceInventoryID) -> DeviceServiceProfile? { devices[device] }
    var commonProfile: ServiceProfile? { commonProfileID.flatMap(profile) }
    func selection(for device: DeviceInventoryID) -> ServiceProfileSelection { devices[device]?.selection ?? .inheritDefault }

    /// The profile that applies to the device now, if any.
    func resolvedProfile(for device: DeviceInventoryID) -> ServiceProfile? {
        switch selection(for: device) {
        case .inheritDefault: commonProfile
        case .profile(let id): profile(id)
        case .doNotApply: nil
        }
    }

    /// What applying to the device writes now: the latest definition of its profile, with its overrides.
    /// Nil means nothing is written, and the overrides stay for a later choice.
    func configuration(for device: DeviceInventoryID) -> ServiceConfiguration? {
        resolvedProfile(for: device)?.configuration.applying(devices[device]?.overrides ?? [:])
    }

    func reload() {
        do {
            let loaded = try readState()
            apply(loaded)
            issue = nil
            loadFailure = nil
        } catch {
            loadFailure = error
            issue = "Unable to read service profiles: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func create(name: String, configuration: ServiceConfiguration, assigningTo device: DeviceInventoryID? = nil) throws -> ServiceProfile {
        let profile = ServiceProfile(record: .init(id: UUID(), name: try validName(name), configuration: configuration))
        var updated = state
        updated.profiles.append(profile.record)
        if let device { updated.devices[device] = DeviceServiceProfile(selection: .profile(profile.id)) }
        try save(updated, adding: profile)
        return profile
    }

    func update(_ id: UUID, name: String? = nil, configuration: ServiceConfiguration,
                assigningTo device: DeviceInventoryID? = nil) throws {
        guard let index = state.profiles.firstIndex(where: { $0.id == id }) else { throw Failure.missingProfile }
        var updated = state
        if let name { updated.profiles[index].name = try validName(name) }
        updated.profiles[index].configuration = configuration
        if let device {
            let inherits = selection(for: device) == .inheritDefault && commonProfileID == id
            updated.devices[device] = DeviceServiceProfile(selection: inherits ? .inheritDefault : .profile(id))
        }
        try save(updated)
    }

    func move(_ id: UUID, before nextID: UUID?) throws {
        var updated = state
        guard let index = updated.profiles.firstIndex(where: { $0.id == id }) else { throw Failure.missingProfile }
        if id == nextID { return }
        let profile = updated.profiles.remove(at: index)
        if let nextID {
            guard let destination = updated.profiles.firstIndex(where: { $0.id == nextID }) else { throw Failure.missingProfile }
            updated.profiles.insert(profile, at: destination)
        } else {
            updated.profiles.append(profile)
        }
        try save(updated)
    }

    func delete(_ id: UUID) throws {
        var updated = state
        updated.profiles.removeAll { $0.id == id }
        if updated.commonProfileID == id { updated.commonProfileID = nil }
        // Removing the association does not change the simulator's services.
        for (device, binding) in updated.devices where binding.selection == .profile(id) {
            updated.devices[device]?.selection = .inheritDefault
        }
        try save(updated)
    }

    func setCommonProfile(_ id: UUID?) throws {
        if let id, profile(id) == nil { throw Failure.missingProfile }
        var updated = state
        updated.commonProfileID = id
        try save(updated)
    }

    @discardableResult
    func assign(_ selection: ServiceProfileSelection, to device: DeviceInventoryID,
                preservingOverrides: Bool = true) throws -> DeviceServiceProfile {
        if case .profile(let id) = selection, profile(id) == nil { throw Failure.missingProfile }
        var updated = state
        let binding = DeviceServiceProfile(selection: selection, overrides: preservingOverrides ? updated.devices[device]?.overrides ?? [:] : [:])
        updated.devices[device] = binding
        try save(updated)
        return binding
    }

    func removeBinding(for device: DeviceInventoryID) throws {
        var updated = state
        updated.devices.removeValue(forKey: device)
        try save(updated)
    }

    func record(_ targets: [SimulatorBackgroundServiceTarget], enabled: Bool, for device: DeviceInventoryID,
                productFamily: String, currentConfiguration: ServiceConfiguration? = nil) throws {
        var configuration = currentConfiguration ?? self.configuration(for: device)
            ?? ServiceConfiguration().applying(devices[device]?.overrides ?? [:])
        let affected = configuration.set(targets, enabled: enabled, productFamily: productFamily)
        guard !affected.isEmpty else { return }
        var updated = state
        // A change stays explicit even if it matches the profile now, because the profile can change later.
        for label in affected { updated.devices[device, default: DeviceServiceProfile()].overrides[label] = enabled }
        try save(updated)
    }

    private func validName(_ name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw Failure.emptyName }
        return name
    }

    private func save(_ updated: State, adding profile: ServiceProfile? = nil) throws {
        if let loadFailure { throw loadFailure }
        guard updated != state else { return }
        let data = try JSONEncoder().encode(updated)
        try write(data)
        apply(updated, adding: profile)
    }

    private func readState() throws -> State {
        do {
            return try JSONDecoder().decode(State.self, from: Data(contentsOf: fileURL))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            guard let data = legacyDefaults?.data(forKey: Self.defaultsKey) else { return State() }
            let migrated = try JSONDecoder().decode(State.self, from: data)
            try write(data)
            legacyDefaults?.removeObject(forKey: Self.defaultsKey)
            return migrated
        }
    }

    private func write(_ data: Data) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    private func apply(_ loaded: State, adding profile: ServiceProfile? = nil) {
        var existing = Dictionary(profiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if let profile { existing[profile.id] = profile }
        let updated = loaded.profiles.map { record in
            let profile = existing[record.id] ?? ServiceProfile(record: record)
            profile.store = self
            profile.update(from: record)
            return profile
        }
        if profiles.map(\.id) != updated.map(\.id) { profiles = updated }
        if commonProfileID != loaded.commonProfileID { commonProfileID = loaded.commonProfileID }
        if devices != loaded.devices { devices = loaded.devices }
    }
}
