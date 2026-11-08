import NeoSimulatorKit
import NeoSimulatorHostSupport
import Foundation
import Observation
import NeoSimulatorManager
import UniformTypeIdentifiers

@MainActor @Observable
final class ServiceProfilesSettingsModel {
    let store: ServiceProfileStore
    /// The selected profile's categories, which the filter and the selected category narrow to the services that show.
    let list = BackgroundServiceListModel(categories: [])
    var selectedProfileID: UUID? = ServiceProfile.allServicesID
    var editingProfileID: UUID?
    var deleting: ServiceProfile?
    var issue: String?

    init(store: ServiceProfileStore) { self.store = store }

    var selectedProfile: ServiceProfile { selectedProfileID.flatMap(store.profile) ?? store.allServices }
    var canDelete: Bool { selectedProfile.id != ServiceProfile.allServicesID }
    var defaultProfileID: UUID {
        get { store.defaultProfileID }
        set {
            do { try store.setDefaultProfile(newValue) }
            catch { issue = error.localizedDescription }
        }
    }

    /// Adds a profile with `profile`'s services and starts naming it.
    func duplicate(_ profile: ServiceProfile) { create(configuration: profile.configuration) }

    private func create(configuration: ServiceConfiguration) {
        let names = Set(store.availableProfiles.map(\.name))
        var index = 1
        while names.contains("Profile (\(index))") { index += 1 }
        do {
            let profile = try store.create(name: "Profile (\(index))", configuration: configuration)
            selectedProfileID = profile.id
            editingProfileID = profile.id
        } catch { issue = error.localizedDescription }
    }

    func rename(_ profile: ServiceProfile, to name: String) {
        do { try store.update(profile.id, name: name, configuration: profile.configuration) }
        catch { issue = error.localizedDescription }
    }

    func move(_ id: UUID, before nextID: UUID?) -> Bool {
        do {
            try store.move(id, before: nextID)
            return true
        } catch {
            issue = error.localizedDescription
            return false
        }
    }

    func delete() {
        guard let deleting else { return }
        do {
            try store.delete(deleting.id)
            if selectedProfileID == deleting.id { selectedProfileID = ServiceProfile.allServicesID }
        } catch { issue = error.localizedDescription }
        self.deleting = nil
    }

    // MARK: Categories, which every profile shares

    /// Categories change beside a profile that can change, while the built-in profile shows its fixed categories.
    var canEditCategories: Bool { selectedProfile.canEdit }

    /// The selected category if the app added it, which can gain and lose services, be renamed, and be deleted.
    var selectedCustomCategory: BackgroundServiceCategoryModel? {
        guard canEditCategories else { return nil }
        return list.selectedSection.map(\.category).flatMap { $0.isCustom ? $0 : nil }
    }

    /// A name that no custom category has.
    var newCategoryName: String {
        let names = Set(store.customCategories.map(\.name))
        var index = 1
        while names.contains("Category (\(index))") { index += 1 }
        return "Category (\(index))"
    }

    /// Adds a custom category and selects it, clearing the filter so that it shows.
    func addCategory(named name: String) throws {
        guard canEditCategories else { return }
        let id = try store.createCategory(named: name)
        list.query = ""
        list.selectedCategoryID = id
    }

    func renameCategory(_ category: BackgroundServiceCategoryModel, to name: String) throws {
        try store.renameCategory(category.id, to: name)
    }

    func deleteCategory(_ category: BackgroundServiceCategoryModel) throws {
        try store.deleteCategory(category.id)
    }

    /// Adds a service to the selected custom category, clearing the filter so that it shows.
    func addService(_ label: String) throws {
        guard let category = selectedCustomCategory else { throw ServiceProfileStore.Failure.missingCategory }
        try store.addService(label, to: category.id)
        list.query = ""
    }

    func removeService(_ service: BackgroundServiceItem, from category: BackgroundServiceCategoryModel) throws {
        try store.removeService(service.label, from: category.id)
    }

    // MARK: Files, which carry profiles between Macs

    /// JSON Lines, which the system doesn't declare a type for.
    nonisolated static let fileType = UTType(filenameExtension: "jsonl") ?? .data

    /// A name for `profile`'s file, from its name without what file names can't have.
    func exportFileName(for profile: ServiceProfile) -> String {
        let unsafe = CharacterSet(charactersIn: "/:").union(.controlCharacters)
        let name = String(String.UnicodeScalarView(profile.name.unicodeScalars.map { unsafe.contains($0) ? "-" : $0 }))
            // A leading period hides the file.
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        return (name.isEmpty ? "Service Profile" : name) + ".jsonl"
    }

    /// Writes `profile` to a JSON Lines file at `url`.
    func export(_ profile: ServiceProfile, to url: URL) async throws {
        try await writeFile(store.exportedLine(for: profile), to: url)
    }

    /// Adds the profiles in JSON Lines files and selects the first. Nothing changes unless every file imports.
    func importProfiles(from urls: [URL]) async throws {
        let files = try await readFiles(at: urls)
        if let first = try store.importProfiles(from: files).first { selectedProfileID = first.id }
    }
}

@concurrent private func writeFile(_ contents: Data, to url: URL) async throws {
    try contents.write(to: url, options: .atomic)
}

@concurrent private func readFiles(at urls: [URL]) async throws -> [(name: String, contents: Data)] {
    try urls.map { (name: $0.lastPathComponent, contents: try Data(contentsOf: $0)) }
}
