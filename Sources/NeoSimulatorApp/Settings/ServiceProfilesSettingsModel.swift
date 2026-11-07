import NeoSimulatorKit
import NeoSimulatorHostSupport
import Foundation
import Observation

@MainActor @Observable
final class ServiceProfilesSettingsModel {
    let store: ServiceProfileStore
    var selectedProfileID: UUID? = ServiceProfile.default.id
    var editingProfileID: UUID?
    var deleting: ServiceProfile?
    var issue: String?

    init(store: ServiceProfileStore) { self.store = store }

    var selectedProfile: ServiceProfile { selectedProfileID.flatMap(store.profile) ?? .default }
    var canDelete: Bool { selectedProfile.id != ServiceProfile.default.id }
    var commonProfileID: UUID? {
        get { store.commonProfileID }
        set {
            do { try store.setCommonProfile(newValue) }
            catch { issue = error.localizedDescription }
        }
    }

    func create() { create(configuration: ServiceConfiguration()) }
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
            if selectedProfileID == deleting.id { selectedProfileID = ServiceProfile.default.id }
        } catch { issue = error.localizedDescription }
        self.deleting = nil
    }
}
