import Foundation
import Observation
@_spi(NeoSimulator) import XcodeSimulatorHost

struct ServiceConfiguration: Codable, Equatable, Sendable {
    var disabledLabels: Set<String> = []

    static var labels: Set<String> {
        Set(SimulatorBackgroundServiceCategory.all.flatMap { $0.services.map(\.label) })
    }

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

struct ServiceProfile: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var configuration: ServiceConfiguration
    var revision: Int
}

struct DeviceServiceProfile: Codable, Equatable, Sendable {
    let profileID: UUID
    var base: ServiceConfiguration
    var revision: Int
    var overrides: [String: Bool]
    var requestID: UUID
    var pendingApplication: Bool

    var configuration: ServiceConfiguration { base.applying(overrides) }
}

/// Owns reusable definitions and device-specific intent. Live launchd state stays in BackgroundServicesModel.
@MainActor @Observable
final class ServiceProfileStore {
    private struct State: Codable, Equatable {
        var profiles: [ServiceProfile] = []
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
    private var state = State()
    private(set) var issue: String?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var loadFailure: (any Error)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        reload()
    }

    var profiles: [ServiceProfile] { state.profiles }
    func profile(_ id: UUID) -> ServiceProfile? { state.profiles.first { $0.id == id } }
    func binding(for device: DeviceInventoryID) -> DeviceServiceProfile? { state.devices[device] }
    func usageCount(_ id: UUID) -> Int { state.devices.values.filter { $0.profileID == id }.count }

    func hasUpdate(for device: DeviceInventoryID) -> Bool {
        guard let binding = binding(for: device), let profile = profile(binding.profileID) else { return false }
        return profile.revision != binding.revision
    }

    func reload() {
        do {
            let loaded = try defaults.data(forKey: Self.defaultsKey).map { try JSONDecoder().decode(State.self, from: $0) } ?? State()
            state = loaded
            issue = nil
            loadFailure = nil
        } catch {
            loadFailure = error
            issue = "Unable to read service profiles: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func create(name: String, configuration: ServiceConfiguration) throws -> ServiceProfile {
        let profile = ServiceProfile(id: UUID(), name: try validName(name), configuration: configuration, revision: 1)
        var updated = state
        updated.profiles.append(profile)
        try save(updated)
        return profile
    }

    func update(_ id: UUID, name: String, configuration: ServiceConfiguration) throws {
        guard let index = state.profiles.firstIndex(where: { $0.id == id }) else { throw Failure.missingProfile }
        var updated = state
        updated.profiles[index].name = try validName(name)
        if updated.profiles[index].configuration != configuration {
            updated.profiles[index].configuration = configuration
            updated.profiles[index].revision += 1
        }
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
    func assign(_ profileID: UUID?, to device: DeviceInventoryID, pending: Bool) throws -> DeviceServiceProfile? {
        var updated = state
        guard let profileID else {
            updated.devices.removeValue(forKey: device)
            try save(updated)
            return nil
        }
        guard let profile = profile(profileID) else { throw Failure.missingProfile }
        let binding = DeviceServiceProfile(profileID: profileID, base: profile.configuration, revision: profile.revision,
                                           overrides: updated.devices[device]?.overrides ?? [:],
                                           requestID: UUID(), pendingApplication: pending)
        updated.devices[device] = binding
        try save(updated)
        return binding
    }

    func record(_ targets: [SimulatorBackgroundServiceTarget], enabled: Bool, for device: DeviceInventoryID,
                productFamily: String) throws {
        guard var binding = state.devices[device] else { return }
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

    @discardableResult
    func resetOverrides(for device: DeviceInventoryID, labels: Set<String>? = nil, pending: Bool) throws -> DeviceServiceProfile? {
        guard var binding = state.devices[device] else { return nil }
        if let labels { binding.overrides = binding.overrides.filter { !labels.contains($0.key) } }
        else { binding.overrides.removeAll() }
        binding.requestID = UUID()
        binding.pendingApplication = pending
        var updated = state
        updated.devices[device] = binding
        try save(updated)
        return binding
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

    private func save(_ updated: State) throws {
        if let loadFailure { throw loadFailure }
        guard updated != state else { return }
        let data = try JSONEncoder().encode(updated)
        defaults.set(data, forKey: Self.defaultsKey)
        state = updated
    }
}
