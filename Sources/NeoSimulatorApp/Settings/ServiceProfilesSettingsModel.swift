import NeoSimulatorKit
import NeoSimulatorHostSupport
import Foundation
import Observation
import NeoSimulatorManager

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
    var canDelete: Bool { selectedProfile.canEdit }
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

    /// Categories change beside an editable profile; built-in profiles show them read-only.
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

    /// The services that the services pane selects.
    var selectedServices: [BackgroundServiceItem] = []

    /// The selected services that the selected custom category shows, which can be edited and removed.
    var selectedCustomServices: [BackgroundServiceItem] {
        guard selectedCustomCategory != nil, let items = list.selectedSection?.items else { return [] }
        return items.filter { item in selectedServices.contains { $0 === item } }
    }

    /// Adds a service to the selected custom category and selects it, clearing the filter so that it shows.
    func addService(_ label: String, summary: String) throws {
        guard let category = selectedCustomCategory else { throw ServiceProfileStore.Failure.missingCategory }
        let label = try store.addService(label, summary: summary, to: category.id)
        list.query = ""
        selectService(label, in: category)
    }

    /// What `service` does as `category` says, which an edit starts from.
    func summary(of service: BackgroundServiceItem, in category: BackgroundServiceCategoryModel) -> String {
        store.customCategories.first { $0.categoryID == category.id }?.summaries[service.label] ?? ""
    }

    /// Changes `service`'s label and what it does, keeping it selected.
    func updateService(
        _ service: BackgroundServiceItem, in category: BackgroundServiceCategoryModel, label: String, summary: String
    ) throws {
        let label = try store.updateService(service.label, in: category.id, label: label, summary: summary)
        selectService(label, in: category)
    }

    func removeServices(_ services: [BackgroundServiceItem], from category: BackgroundServiceCategoryModel) throws {
        try store.removeServices(services.map(\.label), from: category.id)
    }

    private func selectService(_ label: String, in category: BackgroundServiceCategoryModel) {
        selectedServices = category.items.filter { $0.label == label }
    }

    // MARK: JSON files, which carry profiles between Macs

    /// A name for `profile`'s file, from its name without what file names can't have.
    func exportFileName(for profile: ServiceProfile) -> String {
        let unsafe = CharacterSet(charactersIn: "/:").union(.controlCharacters)
        let name = String(String.UnicodeScalarView(profile.name.unicodeScalars.map { unsafe.contains($0) ? "-" : $0 }))
            // A leading period hides the file.
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        return (name.isEmpty ? "Service Profile" : name) + ".json"
    }

    /// Writes `profile` to a JSON file at `url`.
    func export(_ profile: ServiceProfile, to url: URL) async throws {
        try await writeFile(store.exportedFile(for: profile), to: url)
    }

    /// Adds the profile in each JSON file and selects the first. Nothing changes unless every file imports.
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
