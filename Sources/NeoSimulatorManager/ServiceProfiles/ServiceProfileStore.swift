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
    /// What the services do, by label, for those that a file of profiles describes.
    package var summaries: [String: String] = [:]

    private enum CodingKeys: String, CodingKey { case id, name, labels, summaries }

    /// The identifier that ``SimulatorBackgroundServiceTarget/category(_:)`` takes for the category.
    package var categoryID: String { "custom." + id.uuidString }

    /// A service that simulators need, which a file of profiles can group in a category of its own, stays on as it
    /// does in the built-in categories.
    fileprivate var category: SimulatorBackgroundServiceCategory {
        SimulatorBackgroundServiceCategory(
            id: categoryID, name: name, summary: String(localized: "Services that you added."),
            consequence: String(localized: "The services that you added to this category stop."),
            services: labels.filter { requiredReasons[$0] == nil }.map {
                SimulatorBackgroundService($0, summaries[$0] ?? "")
            },
            requiredServices: labels.compactMap { label in
                requiredReasons[label].map { SimulatorRequiredBackgroundService(label, reason: summaries[label] ?? $0) }
            })
    }
}

/// Why simulators need each service that the built-in categories keep on, by label.
private let requiredReasons = Dictionary(
    SimulatorBackgroundServiceCategory.all.flatMap(\.requiredServices).map { ($0.label, $0.reason) },
    uniquingKeysWith: { first, _ in first })

/// The labels in the order that a category's switches list them: its services, then those that simulators need.
private func requiredLast(_ labels: [String]) -> [String] {
    labels.filter { requiredReasons[$0] == nil } + labels.filter { requiredReasons[$0] != nil }
}

extension CustomServiceCategory {
    /// Categories saved before their services had summaries have none.
    package init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        labels = try values.decode([String].self, forKey: .labels)
        summaries = try values.decodeIfPresent([String: String].self, forKey: .summaries) ?? [:]
    }
}

/// A line of a JSON Lines file of service profiles. A profile line starts each profile, a category line starts each of
/// its categories, and each service line after it lists a service of that category and whether the profile turns it
/// on. A service that no line turns off stays on.
private struct ProfileFileLine: Decodable {
    enum Kind: String, Decodable { case profile, category, service }

    static let currentVersion = 1

    var type: Kind
    var version: Int?
    var name: String?
    var label: String?
    var enabled: Bool?
    var description: String?

    /// The line, with its fields in the same order on every line and spaced for reading.
    func encoded() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let fields: [(String, (any Encodable)?)] = [
            ("type", type.rawValue), ("version", version), ("name", name), ("label", label), ("enabled", enabled),
            ("description", description),
        ]
        let members = try fields.compactMap { key, value in
            try value.map { "\"\(key)\": " + String(decoding: try encoder.encode($0), as: UTF8.self) }
        }
        return "{" + members.joined(separator: ", ") + "}\n"
    }
}

/// A category's name and its services, which tell whether a category that a file lists is one that's here already.
private struct ListedCategory: Equatable {
    let name: String
    /// The labels, in the order that the category's switches list them.
    let labels: [String]
    /// What the services do, by label, for those that say.
    let summaries: [String: String]

    init(name: String, labels: [String], summaries: [String: String]) {
        self.name = name
        self.labels = requiredLast(labels)
        self.summaries = summaries
    }

    init(builtIn category: SimulatorBackgroundServiceCategory) {
        let services =
            category.services.map { ($0.label, $0.summary) } + category.requiredServices.map { ($0.label, $0.reason) }
        self.init(
            name: category.name, labels: services.map(\.0),
            summaries: Dictionary(services.filter { !$0.1.isEmpty }, uniquingKeysWith: { first, _ in first }))
    }

    init(_ category: CustomServiceCategory) {
        self.init(name: category.name, labels: category.labels, summaries: category.summaries)
    }
}

/// A profile that lines of a file describe, as far as they go.
private struct ProfileFileReading {
    struct Category {
        let line: Int
        let name: String
        var services: [(label: String, line: Int)] = []
        var summaries: [String: String] = [:]

        var listed: ListedCategory { ListedCategory(name: name, labels: services.map(\.label), summaries: summaries) }
    }

    let line: Int
    let name: String
    private(set) var categories: [Category] = []
    /// Whether the profile turns on each service that a line lists.
    private(set) var enabled: [String: Bool] = [:]

    init(_ record: ProfileFileLine, line: Int) throws {
        guard let version = record.version else {
            throw LineFailure(line: line, reason: ServiceProfileStore.Failure.missingField("version"))
        }
        guard version == ProfileFileLine.currentVersion else {
            throw LineFailure(line: line, reason: ServiceProfileStore.Failure.unsupportedProfileVersion)
        }
        guard let name = record.name else {
            throw LineFailure(line: line, reason: ServiceProfileStore.Failure.missingField("name"))
        }
        self.line = line
        self.name = name
    }

    mutating func addCategory(_ record: ProfileFileLine, line: Int) throws {
        guard let name = record.name else {
            throw LineFailure(line: line, reason: ServiceProfileStore.Failure.missingField("name"))
        }
        categories.append(Category(line: line, name: name.trimmingCharacters(in: .whitespaces)))
    }

    mutating func addService(_ record: ProfileFileLine, line: Int) throws {
        guard let last = categories.indices.last else {
            throw LineFailure(line: line, reason: ServiceProfileStore.Failure.serviceOutsideCategory)
        }
        guard let label = record.label?.trimmingCharacters(in: .whitespaces) else {
            throw LineFailure(line: line, reason: ServiceProfileStore.Failure.missingField("label"))
        }
        let isEnabled = record.enabled ?? true
        if !isEnabled, let reason = requiredReasons[label] {
            throw LineFailure(line: line, reason: ServiceProfileStore.Failure.requiredService(label, reason: reason))
        }
        // A service that two categories list has one switch.
        if let earlier = enabled[label], earlier != isEnabled {
            throw LineFailure(line: line, reason: ServiceProfileStore.Failure.conflictingService(label))
        }
        enabled[label] = isEnabled
        categories[last].services.append((label, line))
        if let summary = record.description, !summary.isEmpty { categories[last].summaries[label] = summary }
    }
}

/// A failure that a line of a file of profiles causes.
private struct LineFailure: Error {
    let line: Int
    let reason: any Error
}

/// Runs `body`, which a failure of attributes to `line`.
private func reading<Value>(line: Int, _ body: () throws -> Value) throws -> Value {
    do { return try body() } catch { throw LineFailure(line: line, reason: error) }
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
        case noProfiles, unreadableLine, unsupportedProfileVersion, lineOutsideProfile, serviceOutsideCategory
        case missingField(String)
        case conflictingService(String)

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
            case .noProfiles: "The file contains no service profiles."
            case .unreadableLine: "The line isn’t a profile, category, or service line."
            case .unsupportedProfileVersion: "The profile is in a format that this version of NeoSimulator can’t read."
            case .lineOutsideProfile: "The line comes before the first profile line."
            case .serviceOutsideCategory: "The service comes before the profile’s first category line."
            case .missingField(let key): "The line has no “\(key)”."
            case .conflictingService(let label): "The profile turns “\(label)” both on and off."
            }
        }
    }

    /// Why a line of a file can't become a profile.
    package struct ImportFailure: Error, LocalizedError {
        package let file: String
        /// The line, counting from 1, or `nil` for a failure of the whole file.
        package let line: Int?
        package let reason: any Error

        package var errorDescription: String? {
            guard let line else { return "“\(file)”: \(reason.localizedDescription)" }
            return "“\(file)”, line \(line): \(reason.localizedDescription)"
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
        var updated = state
        let index = try customCategoryIndex(categoryID, in: updated)
        updated.customCategories[index].labels.append(
            try validLabel(label, besides: updated.customCategories[index].labels))
        try save(updated)
    }

    /// Removes a service from a custom category, as ``deleteCategory(_:)`` does for each of its services.
    package func removeService(_ label: String, from categoryID: String) throws {
        var updated = state
        let index = try customCategoryIndex(categoryID, in: updated)
        updated.customCategories[index].labels.removeAll { $0 == label }
        updated.customCategories[index].summaries[label] = nil
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

    /// The trimmed label, if a custom category that lists `labels` can add it.
    /// - Parameter keepingRequired: Whether a service that simulators need can join, as one that stays on.
    private func validLabel(_ label: String, besides labels: [String], keepingRequired: Bool = false) throws -> String {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { throw Failure.emptyLabel }
        guard !labels.contains(label) else { throw Failure.listedService(label) }
        if !keepingRequired, let reason = requiredReasons[label] {
            throw Failure.requiredService(label, reason: reason)
        }
        guard !BackgroundServiceCatalog.wedgingLabels.contains(label) else { throw Failure.wedgingService(label) }
        return label
    }

    // MARK: Files

    /// The profile as a JSON Lines file that ``importProfiles(from:)`` reads, with every service that it shows.
    ///
    /// A profile line names the profile. A category line follows for each category that the profile shows, and a line
    /// for each of the category's services follows it, with whether the profile turns the service on.
    package func exportedLines(for profile: ServiceProfile) throws -> Data {
        var lines = [ProfileFileLine(type: .profile, version: ProfileFileLine.currentVersion, name: profile.name)]
        let listings = profile.categories.map { model in
            customCategories.first { $0.categoryID == model.id }.map { ListedCategory($0) }
                ?? ListedCategory(builtIn: model.category)
        }
        for listed in listings {
            lines.append(ProfileFileLine(type: .category, name: listed.name))
            for label in listed.labels {
                lines.append(
                    ProfileFileLine(
                        type: .service, label: label, enabled: !profile.configuration.disabledLabels.contains(label),
                        description: listed.summaries[label]))
            }
        }
        return Data(try lines.map { try $0.encoded() }.joined().utf8)
    }

    /// Adds the profiles that JSON Lines files describe, each as a new profile, with the categories that they list.
    ///
    /// A category with the name and services of one that's here, built in or custom, is that category. Any other
    /// becomes a new custom category, so a file can add categories and services, and never changes one that's here.
    /// Nothing changes unless every line of every file imports.
    /// - Parameter files: Each file's name, which a failure names, and its contents.
    /// - Returns: The new profiles, in the order of the files and their lines.
    /// - Throws: ``ImportFailure`` for a line or file that can't import.
    @discardableResult
    package func importProfiles(from files: [(name: String, contents: Data)]) throws -> [ServiceProfile] {
        if let loadFailure { throw loadFailure }
        var updated = state
        var imported: [ServiceProfile.Record] = []
        for file in files {
            let count = imported.count
            let lines = file.contents.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            do {
                var profile: ProfileFileReading?
                // JSON allows the whitespace that a blank line or a carriage return leaves.
                for (index, text) in lines.enumerated() where text.contains(where: { !" \t\r".utf8.contains($0) }) {
                    let line = index + 1
                    guard let record = try? JSONDecoder().decode(ProfileFileLine.self, from: Data(text)) else {
                        throw LineFailure(line: line, reason: Failure.unreadableLine)
                    }
                    if record.type == .profile {
                        if let profile { imported.append(try add(profile, to: &updated)) }
                        profile = try ProfileFileReading(record, line: line)
                    } else if profile == nil {
                        throw LineFailure(line: line, reason: Failure.lineOutsideProfile)
                    } else if record.type == .category {
                        try profile?.addCategory(record, line: line)
                    } else {
                        try profile?.addService(record, line: line)
                    }
                }
                if let profile { imported.append(try add(profile, to: &updated)) }
            } catch let failure as LineFailure {
                throw ImportFailure(file: file.name, line: failure.line, reason: failure.reason)
            }
            if imported.count == count { throw ImportFailure(file: file.name, line: nil, reason: Failure.noProfiles) }
        }
        updated.profiles += imported
        try save(updated)
        return imported.compactMap { profile($0.id) }
    }

    /// Adds the categories of `profile` that `state` lacks, and returns the profile's record.
    private func add(_ profile: ProfileFileReading, to state: inout State) throws -> ServiceProfile.Record {
        let name = try reading(line: profile.line) { try validName(profile.name) }
        for category in profile.categories {
            let listed = category.listed
            if SimulatorBackgroundServiceCategory.all.contains(where: { ListedCategory(builtIn: $0) == listed })
                || state.customCategories.contains(where: { ListedCategory($0) == listed })
            {
                continue
            }
            let name = try reading(line: category.line) { try validName(listed.name, empty: .emptyCategoryName) }
            var labels: [String] = []
            for service in category.services {
                labels.append(
                    try reading(line: service.line) {
                        try validLabel(service.label, besides: labels, keepingRequired: true)
                    })
            }
            state.customCategories.append(
                CustomServiceCategory(
                    id: UUID(), name: name, labels: requiredLast(labels), summaries: category.summaries))
        }
        let disabled = profile.enabled.filter { !$0.value }.keys
        return ServiceProfile.Record(
            id: UUID(), name: name, configuration: ServiceConfiguration(disabledLabels: Set(disabled)))
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
