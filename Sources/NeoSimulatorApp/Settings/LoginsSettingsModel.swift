import Foundation
import NeoSimulatorManager
import Observation

@MainActor @Observable
final class LoginsSettingsModel {
    /// What the editor's fields hold, for a new login or for the saved one that it changes.
    struct Draft: Identifiable {
        let id = UUID()
        /// The saved login that the editor changes, or `nil` for a new one.
        let existing: SavedLogin.ID?
        var applicationIdentifier = ""
        var label = ""
        var userName = ""
        /// A new password. A saved login keeps its own while this is empty, and the editor never shows that one.
        var password = ""
        /// The origins as the person enters them, separated by commas.
        var origins = ""
        var allowsAutomation = true
        var issue: String?

        init() { existing = nil }

        init(_ login: SavedLogin) {
            existing = login.id
            applicationIdentifier = login.applicationIdentifier
            label = login.label
            userName = login.userName
            origins = login.origins.map(\.text).joined(separator: ", ")
            allowsAutomation = login.allowsAutomation
        }

        var canSave: Bool {
            !applicationIdentifier.isEmpty && !label.isEmpty && (existing != nil || !password.isEmpty)
        }
    }

    let store: LoginStore
    var selection: SavedLogin.ID?
    /// The editor's fields while it is open.
    var draft: Draft?
    /// The login that the person is asked to confirm deleting.
    var deleting: SavedLogin?
    var issue: String?
    private(set) var isSaving = false
    @ObservationIgnored private(set) var loading: Task<Void, Never>?

    init(store: LoginStore) { self.store = store }

    var selectedLogin: SavedLogin? { store.logins.first { $0.id == selection } }

    func reload() {
        guard loading == nil else { return }
        loading = Task { [weak self, store] in
            await store.reload()
            self?.loading = nil
        }
    }

    func add() { draft = Draft() }

    func edit(_ id: SavedLogin.ID?) {
        guard let login = store.logins.first(where: { $0.id == id }) else { return }
        selection = login.id
        draft = Draft(login)
    }

    /// Saves the editor's fields and closes it, or shows in it why the login couldn't be saved.
    func save() async {
        guard let draft, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let login = SavedLogin(
                applicationIdentifier: draft.applicationIdentifier, label: draft.label, userName: draft.userName,
                origins: try WebOrigin.list(from: draft.origins), allowsAutomation: draft.allowsAutomation)
            selection = try await store.save(login, password: draft.password, replacing: draft.existing).id
            self.draft = nil
        } catch {
            self.draft?.issue = error.localizedDescription
        }
    }

    func delete() async {
        guard let deleting else { return }
        self.deleting = nil
        do {
            try await store.delete(deleting.id)
        } catch {
            issue = error.localizedDescription
        }
    }
}
