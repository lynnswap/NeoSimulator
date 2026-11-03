import Foundation
import Observation
import XcodeSimulatorHost

struct ServiceConfiguration: Codable, Equatable, Sendable {
    var disabledLabels: Set<String> = []

    static let labels = Set(SimulatorBackgroundServiceCategory.all.flatMap { $0.services.map(\.label) })

    func state(productFamily: String = "") -> SimulatorBackgroundServices {
        SimulatorBackgroundServices(disabled: disabledLabels, loaded: [], productFamily: productFamily)
    }

    func applying(_ overrides: [String: Bool]) -> Self {
        var result = self
        for (label, enabled) in overrides {
            if enabled { result.disabledLabels.remove(label) }
            else { result.disabledLabels.insert(label) }
        }
        return result
    }

    @discardableResult
    mutating func set(_ targets: [SimulatorBackgroundServiceTarget], enabled: Bool,
                      productFamily: String = "") -> Set<String> {
        let categories = SimulatorBackgroundServiceCategory.all.filter { targets.contains(.category($0.id)) }
        let named = targets.compactMap { target -> String? in
            if case .service(let label) = target { return label }
            return nil
        }
        var affected = Set(categories.flatMap { $0.services.map(\.label) }).union(named).intersection(Self.labels)
        if enabled {
            disabledLabels.subtract(affected)
        } else {
            let before = state(productFamily: productFamily)
            affected.subtract(before.labelsKeptEnabled(disabling: categories, named: named))
            affected = affected.filter { before.canDisable($0) }
            disabledLabels.formUnion(affected)
        }
        return affected
    }
}

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

    static let `default` = ServiceProfile(record: Record(
        id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
        name: "Default", configuration: ServiceConfiguration()))

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

struct DeviceServiceProfile: Codable, Equatable, Sendable {
    let profileID: UUID
    var base: ServiceConfiguration
    var overrides: [String: Bool]
    var requestID: UUID
    var pendingApplication: Bool

    var configuration: ServiceConfiguration { base.applying(overrides) }

    @MainActor init(profile: ServiceProfile, overrides: [String: Bool] = [:], pending: Bool) {
        self.init(profileID: profile.id, base: profile.configuration, overrides: overrides, pending: pending)
    }

    init(profileID: UUID, base: ServiceConfiguration, overrides: [String: Bool] = [:], pending: Bool) {
        self.profileID = profileID
        self.base = base
        self.overrides = overrides
        requestID = UUID()
        pendingApplication = pending
    }
}

/// Owns reusable definitions and device-specific intent. Live launchd state stays in BackgroundServicesModel.
@MainActor @Observable
final class ServiceProfileStore {
    private struct State: Codable, Equatable {
        var profiles: [ServiceProfile.Record] = []
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
    private var devices: [DeviceInventoryID: DeviceServiceProfile] = [:]
    private var state: State { State(profiles: profiles.map(\.record), devices: devices) }
    private(set) var issue: String?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var loadFailure: (any Error)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        reload()
    }

    var availableProfiles: [ServiceProfile] { [.default] + profiles }
    func profile(_ id: UUID) -> ServiceProfile? { id == ServiceProfile.default.id ? .default : profiles.first { $0.id == id } }
    func binding(for device: DeviceInventoryID) -> DeviceServiceProfile? { devices[device] }

    func reload() {
        do {
            let loaded = try defaults.data(forKey: Self.defaultsKey).map { try JSONDecoder().decode(State.self, from: $0) } ?? State()
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
        if let device { updated.devices[device] = DeviceServiceProfile(profile: profile, pending: false) }
        try save(updated, adding: profile)
        return profile
    }

    func update(_ id: UUID, name: String? = nil, configuration: ServiceConfiguration,
                assigningTo device: DeviceInventoryID? = nil) throws {
        guard let index = state.profiles.firstIndex(where: { $0.id == id }) else { throw Failure.missingProfile }
        var updated = state
        if let name { updated.profiles[index].name = try validName(name) }
        updated.profiles[index].configuration = configuration
        if let device { updated.devices[device] = DeviceServiceProfile(profileID: id, base: configuration, pending: false) }
        try save(updated)
    }

    func delete(_ id: UUID) throws {
        var updated = state
        updated.profiles.removeAll { $0.id == id }
        // Removing the association does not change the simulator's services.
        updated.devices = updated.devices.filter { $0.value.profileID != id }
        try save(updated)
    }

    @discardableResult
    func assign(_ profileID: UUID, to device: DeviceInventoryID, pending: Bool,
                preservingOverrides: Bool = true) throws -> DeviceServiceProfile {
        guard let profile = profile(profileID) else { throw Failure.missingProfile }
        var updated = state
        let overrides = !preservingOverrides || profileID == ServiceProfile.default.id ? [:] : updated.devices[device]?.overrides ?? [:]
        let binding = DeviceServiceProfile(profile: profile, overrides: overrides, pending: pending)
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
                productFamily: String) throws {
        var binding = state.devices[device] ?? DeviceServiceProfile(profile: .default, pending: false)
        var configuration = binding.configuration
        let affected = configuration.set(targets, enabled: enabled, productFamily: productFamily)
        for label in affected {
            let enabled = !configuration.disabledLabels.contains(label)
            if enabled == !binding.base.disabledLabels.contains(label) { binding.overrides.removeValue(forKey: label) }
            else { binding.overrides[label] = enabled }
        }
        guard binding != state.devices[device] else { return }
        binding.requestID = UUID()
        var updated = state
        updated.devices[device] = binding
        try save(updated)
    }

    func beginApplication(for device: DeviceInventoryID, requestID: UUID) throws {
        guard var binding = state.devices[device], binding.requestID == requestID, binding.pendingApplication else { return }
        binding.pendingApplication = false
        var updated = state
        updated.devices[device] = binding
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
        defaults.set(data, forKey: Self.defaultsKey)
        apply(updated, adding: profile)
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
        if devices != loaded.devices { devices = loaded.devices }
    }
}
