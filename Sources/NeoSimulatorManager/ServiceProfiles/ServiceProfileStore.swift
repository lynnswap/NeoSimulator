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
    /// The categories that this profile shows, whose switches change it.
    package private(set) var categories: [BackgroundServiceCategoryModel] = []
    package var issue: String?
    @ObservationIgnored fileprivate weak var store: ServiceProfileStore?
    package var canEdit: Bool { store != nil && id != Self.allServicesID }
    /// The built-in profile keeps to the built-in categories, which nothing adds to.
    private var catalog: BackgroundServiceCatalog {
        guard let store, canEdit else { return .builtIn }
        return store.catalog
    }

    package nonisolated static let allServicesID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    fileprivate var record: Record { Record(id: id, name: name, configuration: configuration) }

    fileprivate init(record: Record) {
        id = record.id
        name = record.name
        configuration = record.configuration
    }

    package func setServices(_ targets: [SimulatorBackgroundServiceTarget], enabled: Bool) {
        guard canEdit, let store else { return }
        var updated = configuration
        updated.set(targets, enabled: enabled, catalog: store.catalog)
        do { try store.update(id, configuration: updated) }
        catch { issue = error.localizedDescription }
    }

    fileprivate func update(from record: Record) {
        if name != record.name { name = record.name }
        if configuration != record.configuration {
            configuration = record.configuration
            serviceState = record.configuration.state(catalog: catalog)
        }
    }

    /// Shows the categories of ``catalog``, keeping the models of those that remain.
    fileprivate func showCatalog() {
        guard let store else { return }
        categories = BackgroundServiceCategoryModel.models(
            for: catalog, custom: store.customCategoryIDs, reusing: categories, source: self)
        serviceState = configuration.state(catalog: catalog)
    }
}

/// A category that the app adds beside the built-in ones. Its definition is app-wide, and each profile turns its
/// services on and off.
package struct CustomServiceCategory: Codable, Equatable, Sendable {
    package let id: UUID
    package var name: String
    /// The launchd labels of the category's services.
    package var labels: [String]

    /// The identifier that ``SimulatorBackgroundServiceTarget/category(_:)`` takes for the category.
    package var categoryID: String { "custom." + id.uuidString }

    fileprivate var category: SimulatorBackgroundServiceCategory {
        SimulatorBackgroundServiceCategory(
            id: categoryID, name: name, summary: String(localized: "Services that you added."),
            consequence: String(localized: "The services that you added to this category stop."),
            services: labels.map { SimulatorBackgroundService($0, "") })
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
        package var profiles: [ServiceProfile.Record]
        package var defaultProfileID: UUID?
        package var devices: [DeviceInventoryID: DeviceServiceProfile]
        package var customCategories: [CustomServiceCategory]
        private enum CodingKeys: String, CodingKey {
            case profiles, devices, customCategories
            case defaultProfileID = "commonProfileID"
        }

        init(
            profiles: [ServiceProfile.Record] = [], defaultProfileID: UUID? = ServiceProfile.allServicesID,
            devices: [DeviceInventoryID: DeviceServiceProfile] = [:], customCategories: [CustomServiceCategory] = []
        ) {
            self.profiles = profiles
            self.defaultProfileID = defaultProfileID
            self.devices = devices
            self.customCategories = customCategories
        }

        /// Files from before custom categories have none.
        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            profiles = try values.decode([ServiceProfile.Record].self, forKey: .profiles)
            defaultProfileID = try values.decodeIfPresent(UUID.self, forKey: .defaultProfileID)
            devices = try values.decode([DeviceInventoryID: DeviceServiceProfile].self, forKey: .devices)
            customCategories = try values.decodeIfPresent([CustomServiceCategory].self, forKey: .customCategories) ?? []
        }

        /// The built-in categories below the custom ones.
        var catalog: BackgroundServiceCatalog {
            BackgroundServiceCatalog(customCategories.map(\.category) + SimulatorBackgroundServiceCategory.all)
        }
    }

    package enum Failure: Error, LocalizedError {
        case emptyName, missingProfile
        case emptyCategoryName, missingCategory, emptyLabel
        case listedService(String)
        case requiredService(String, reason: String)
        case wedgingService(String)

        package var errorDescription: String? {
            switch self {
            case .emptyName: "Enter a name for the service profile."
            case .missingProfile: "This service profile no longer exists."
            case .emptyCategoryName: "Enter a name for the category."
            case .missingCategory: "This category no longer exists."
            case .emptyLabel: "Enter the launchd label of a service."
            case .listedService(let label): "The category already lists “\(label)”."
            case .requiredService(let label, let reason): "“\(label)” stays on because simulators need it. \(reason)"
            case .wedgingService(let label):
                "Turning off “\(label)” stops simulators from working, even after they restart."
            }
        }
    }

    package static let defaultsKey = "BackgroundServiceProfiles"
    package private(set) var profiles: [ServiceProfile] = []
    /// The built-in profile, which turns on every service that the categories list, including those in the custom
    /// categories that it doesn't show.
    package let allServices = ServiceProfile(
        record: .init(
            id: ServiceProfile.allServicesID, name: String(localized: "All Services"),
            configuration: ServiceConfiguration()))
    /// What devices that inherit take at each boot.
    package private(set) var defaultProfileID = ServiceProfile.allServicesID
    private var devices: [DeviceInventoryID: DeviceServiceProfile] = [:]
    /// The categories that the app added, above the built-in ones.
    package private(set) var customCategories: [CustomServiceCategory] = []
    /// The custom categories above the built-in ones, which every profile and simulator switches.
    package private(set) var catalog = BackgroundServiceCatalog.builtIn
    package var customCategoryIDs: Set<String> { Set(customCategories.map(\.categoryID)) }
    /// Receives each change to ``catalog``, so that what reads and changes simulators can take it in.
    @ObservationIgnored package var catalogDidChange: (@MainActor (BackgroundServiceCatalog) -> Void)?
    private var state: State {
        State(
            profiles: profiles.map(\.record), defaultProfileID: defaultProfileID, devices: devices,
            customCategories: customCategories)
    }
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
        allServices.store = self
        allServices.showCatalog()
        reload()
    }

    package var availableProfiles: [ServiceProfile] { [allServices] + profiles }
    package func profile(_ id: UUID) -> ServiceProfile? {
        id == allServices.id ? allServices : profiles.first { $0.id == id }
    }
    package func binding(for device: DeviceInventoryID) -> DeviceServiceProfile? { devices[device] }
    package var defaultProfile: ServiceProfile { profile(defaultProfileID) ?? allServices }
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
        let affected = configuration.set(targets, enabled: enabled, productFamily: productFamily, catalog: catalog)
        guard !affected.isEmpty else { return }
        var updated = state
        // A change stays explicit even if it matches the profile now, because the profile can change later.
        for label in affected { updated.devices[device, default: DeviceServiceProfile()].overrides[label] = enabled }
        try save(updated)
    }

    /// Adds a category without services, which every profile lists.
    /// - Returns: The category's identifier.
    @discardableResult
    package func createCategory(named name: String) throws -> String {
        let category = CustomServiceCategory(
            id: UUID(), name: try validName(name, empty: .emptyCategoryName), labels: [])
        var updated = state
        updated.customCategories.append(category)
        try save(updated)
        return category.categoryID
    }

    package func renameCategory(_ id: String, to name: String) throws {
        var updated = state
        let index = try customCategoryIndex(id, in: updated)
        updated.customCategories[index].name = try validName(name, empty: .emptyCategoryName)
        try save(updated)
    }

    /// Removes a custom category from every profile. Profiles and simulators forget their choices for services that no
    /// other category lists, and a simulator keeps each of those services as it is.
    package func deleteCategory(_ id: String) throws {
        var updated = state
        updated.customCategories.remove(at: try customCategoryIndex(id, in: updated))
        try save(forgettingUnlistedServices(updated))
    }

    /// Adds the service with this launchd label to a custom category, which starts on in every profile.
    ///
    /// The label need not exist in every runtime, since enabling one without a job only lifts its override.
    /// - Throws: ``Failure`` if the label is empty, the category lists it, or turning it off would break simulators.
    package func addService(_ label: String, to categoryID: String) throws {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { throw Failure.emptyLabel }
        var updated = state
        let index = try customCategoryIndex(categoryID, in: updated)
        guard !updated.customCategories[index].labels.contains(label) else { throw Failure.listedService(label) }
        if let required = SimulatorBackgroundServiceCategory.all.lazy.flatMap(\.requiredServices)
            .first(where: { $0.label == label })
        {
            throw Failure.requiredService(label, reason: required.reason)
        }
        guard !BackgroundServiceCatalog.wedgingLabels.contains(label) else { throw Failure.wedgingService(label) }
        updated.customCategories[index].labels.append(label)
        try save(updated)
    }

    /// Removes a service from a custom category, as ``deleteCategory(_:)`` does for each of its services.
    package func removeService(_ label: String, from categoryID: String) throws {
        var updated = state
        let index = try customCategoryIndex(categoryID, in: updated)
        updated.customCategories[index].labels.removeAll { $0 == label }
        try save(forgettingUnlistedServices(updated))
    }

    private func customCategoryIndex(_ id: String, in state: State) throws -> Int {
        guard let index = state.customCategories.firstIndex(where: { $0.categoryID == id }) else {
            throw Failure.missingCategory
        }
        return index
    }

    /// Drops what profiles and devices choose for services that `updated`'s categories no longer list. Nothing could
    /// change or show those choices, and a profile that kept one would never match its simulator.
    private func forgettingUnlistedServices(_ updated: State) -> State {
        let unlisted = catalog.slimmable.subtracting(updated.catalog.slimmable)
        guard !unlisted.isEmpty else { return updated }
        var result = updated
        for index in result.profiles.indices { result.profiles[index].configuration.disabledLabels.subtract(unlisted) }
        for (device, binding) in result.devices {
            result.devices[device]?.overrides = binding.overrides.filter { !unlisted.contains($0.key) }
        }
        return result
    }

    private func validName(_ name: String, empty: Failure = .emptyName) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw empty }
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
        if customCategories != loaded.customCategories { customCategories = loaded.customCategories }
        let catalog = loaded.catalog
        let catalogChanged = catalog != self.catalog
        if catalogChanged { self.catalog = catalog }
        var existing = Dictionary(profiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if let profile { existing[profile.id] = profile }
        let updated = loaded.profiles.map { record in
            let profile = existing[record.id] ?? ServiceProfile(record: record)
            let attaching = profile.store !== self
            profile.store = self
            profile.update(from: record)
            if attaching || catalogChanged { profile.showCatalog() }
            return profile
        }
        if profiles.map(\.id) != updated.map(\.id) { profiles = updated }
        let defaultID = loaded.defaultProfileID ?? ServiceProfile.allServicesID
        if defaultProfileID != defaultID { defaultProfileID = defaultID }
        if devices != loaded.devices { devices = loaded.devices }
        if catalogChanged { catalogDidChange?(catalog) }
    }
}
