import NeoSimulatorKit
import NeoSimulatorHostSupport
import Foundation
import Observation

@MainActor @Observable
package final class ServiceProfile: Identifiable, BackgroundServiceEditing {
    package struct Record: Codable, Equatable, Sendable {
        package let id: UUID
        package var name: String
        package var configuration: ServiceConfiguration
    }

    package let id: UUID
    package private(set) var name: String
    package private(set) var configuration: ServiceConfiguration
    package private(set) var serviceState: SimulatorBackgroundServices?
    package var issue: String?
    @ObservationIgnored fileprivate weak var store: ServiceProfileStore?
    package var canEdit: Bool { store != nil && id != Self.allServices.id }
    @ObservationIgnored package lazy var categories = SimulatorBackgroundServiceCategory.all.map {
        BackgroundServiceCategoryModel($0, source: self)
    }

    package nonisolated static let allServicesID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    package static let allServices = ServiceProfile(record: Record(
        id: allServicesID, name: String(localized: "All Services"), configuration: ServiceConfiguration()))

    fileprivate var record: Record { Record(id: id, name: name, configuration: configuration) }

    fileprivate init(record: Record) {
        id = record.id
        name = record.name
        configuration = record.configuration
        serviceState = record.configuration.state()
    }

    package func setServices(_ targets: [SimulatorBackgroundServiceTarget], enabled: Bool) {
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
package enum ServiceProfileSelection: Codable, Hashable, Sendable {
    /// The app-wide default profile, whichever it is at the next boot.
    case inheritDefault
    case profile(UUID)
}

/// A device's choice and its explicit per-service changes, which apply above whatever the choice resolves to.
package struct DeviceServiceProfile: Codable, Equatable, Sendable {
    package var selection: ServiceProfileSelection
    package var overrides: [String: Bool]

    private enum LegacyCodingKeys: String, CodingKey { case profileID, pendingApplication }
    private enum StoredSelection: Decodable {
        case inheritDefault, profile(UUID), doNotApply

        package var selection: ServiceProfileSelection {
            switch self {
            case .inheritDefault, .doNotApply: .inheritDefault
            case .profile(let id): .profile(id)
            }
        }
    }

    package init(selection: ServiceProfileSelection = .inheritDefault, overrides: [String: Bool] = [:]) {
        self.selection = selection
        self.overrides = overrides
    }

    /// Existing opt-outs become inherited selections without losing per-service overrides.
    /// Legacy all-services requests remain explicit; unnamed choices inherit the app default.
    package init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        overrides = try values.decode([String: Bool].self, forKey: .overrides)
        if let selection = try values.decodeIfPresent(StoredSelection.self, forKey: .selection) {
            self.selection = selection.selection
        } else {
            let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
            let profileID = try legacy.decode(UUID.self, forKey: .profileID)
            let pending = try legacy.decodeIfPresent(Bool.self, forKey: .pendingApplication) ?? false
            selection = profileID == ServiceProfile.allServicesID && !pending ? .inheritDefault : .profile(profileID)
        }
    }
}

/// Owns reusable definitions and device-specific intent. Live launchd state stays in each device's `BackgroundServicesState`.
@MainActor @Observable
package final class ServiceProfileStore {
    private struct State: Codable, Equatable {
        package var profiles: [ServiceProfile.Record] = []
        package var defaultProfileID: UUID? = ServiceProfile.allServicesID
        private enum CodingKeys: String, CodingKey {
            case profiles, devices
            case defaultProfileID = "commonProfileID"
        }
        package var devices: [DeviceInventoryID: DeviceServiceProfile] = [:]
    }

    package enum Failure: Error, LocalizedError {
        case emptyName, missingProfile

        package var errorDescription: String? {
            switch self {
            case .emptyName: "Enter a name for the service profile."
            case .missingProfile: "This service profile no longer exists."
            }
        }
    }

    package static let defaultsKey = "BackgroundServiceProfiles"
    package private(set) var profiles: [ServiceProfile] = []
    /// What devices that inherit take at each boot.
    package private(set) var defaultProfileID = ServiceProfile.allServicesID
    private var devices: [DeviceInventoryID: DeviceServiceProfile] = [:]
    private var state: State { State(profiles: profiles.map(\.record), defaultProfileID: defaultProfileID, devices: devices) }
    package private(set) var issue: String?
    package let fileURL: URL
    @ObservationIgnored private let legacyDefaults: UserDefaults?
    @ObservationIgnored private var loadFailure: (any Error)?

    package static var defaultFileURL: URL {
        let identifier = Bundle(for: ServiceProfileStore.self).bundleIdentifier ?? "dev.lynnswap.NeoSimulator"
        return URL.applicationSupportDirectory.appending(path: identifier, directoryHint: .isDirectory)
            .appending(path: "ServiceProfiles.json")
    }

    package init(fileURL: URL = ServiceProfileStore.defaultFileURL, legacyDefaults: UserDefaults? = .standard) {
        self.fileURL = fileURL
        self.legacyDefaults = legacyDefaults
        reload()
    }

    package var availableProfiles: [ServiceProfile] { [.allServices] + profiles }
    package func profile(_ id: UUID) -> ServiceProfile? { id == ServiceProfile.allServices.id ? .allServices : profiles.first { $0.id == id } }
    package func binding(for device: DeviceInventoryID) -> DeviceServiceProfile? { devices[device] }
    package var defaultProfile: ServiceProfile { profile(defaultProfileID) ?? .allServices }
    package func selection(for device: DeviceInventoryID) -> ServiceProfileSelection { devices[device]?.selection ?? .inheritDefault }

    /// The profile that applies to the device now, if any.
    package func resolvedProfile(for device: DeviceInventoryID) -> ServiceProfile? {
        switch selection(for: device) {
        case .inheritDefault: defaultProfile
        case .profile(let id): profile(id)
        }
    }

    /// What applying to the device writes now: the latest definition of its profile, with its overrides.
    /// A failed store read or missing profile cannot supply a configuration.
    package func configuration(for device: DeviceInventoryID) -> ServiceConfiguration? {
        guard loadFailure == nil else { return nil }
        return resolvedProfile(for: device)?.configuration.applying(devices[device]?.overrides ?? [:])
    }

    package func reload() {
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
    package func create(name: String, configuration: ServiceConfiguration, assigningTo device: DeviceInventoryID? = nil) throws -> ServiceProfile {
        let profile = ServiceProfile(record: .init(id: UUID(), name: try validName(name), configuration: configuration))
        var updated = state
        updated.profiles.append(profile.record)
        if let device { updated.devices[device] = DeviceServiceProfile(selection: .profile(profile.id)) }
        try save(updated, adding: profile)
        return profile
    }

    package func update(_ id: UUID, name: String? = nil, configuration: ServiceConfiguration,
                assigningTo device: DeviceInventoryID? = nil) throws {
        guard let index = state.profiles.firstIndex(where: { $0.id == id }) else { throw Failure.missingProfile }
        var updated = state
        if let name { updated.profiles[index].name = try validName(name) }
        updated.profiles[index].configuration = configuration
        if let device {
            let inherits = selection(for: device) == .inheritDefault && defaultProfileID == id
            updated.devices[device] = DeviceServiceProfile(selection: inherits ? .inheritDefault : .profile(id))
        }
        try save(updated)
    }

    package func move(_ id: UUID, before nextID: UUID?) throws {
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

    package func delete(_ id: UUID) throws {
        var updated = state
        updated.profiles.removeAll { $0.id == id }
        if updated.defaultProfileID == id { updated.defaultProfileID = ServiceProfile.allServicesID }
        // Removing the association does not change the simulator's services.
        for (device, binding) in updated.devices where binding.selection == .profile(id) {
            updated.devices[device]?.selection = .inheritDefault
        }
        try save(updated)
    }

    package func setDefaultProfile(_ id: UUID) throws {
        if profile(id) == nil { throw Failure.missingProfile }
        var updated = state
        updated.defaultProfileID = id
        try save(updated)
    }

    @discardableResult
    package func assign(_ selection: ServiceProfileSelection, to device: DeviceInventoryID,
                preservingOverrides: Bool = true) throws -> DeviceServiceProfile {
        if case .profile(let id) = selection, profile(id) == nil { throw Failure.missingProfile }
        var updated = state
        let binding = DeviceServiceProfile(selection: selection, overrides: preservingOverrides ? updated.devices[device]?.overrides ?? [:] : [:])
        updated.devices[device] = binding
        try save(updated)
        return binding
    }

    package func removeBinding(for device: DeviceInventoryID) throws {
        var updated = state
        updated.devices.removeValue(forKey: device)
        try save(updated)
    }

    package func record(_ targets: [SimulatorBackgroundServiceTarget], enabled: Bool, for device: DeviceInventoryID,
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
        let defaultID = loaded.defaultProfileID ?? ServiceProfile.allServicesID
        if defaultProfileID != defaultID { defaultProfileID = defaultID }
        if devices != loaded.devices { devices = loaded.devices }
    }
}
