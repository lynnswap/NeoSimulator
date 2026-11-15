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
    /// Whether the pane is waiting for the keychain. It starts one read or change at a time, so that none acts on
    /// logins that another is about to change.
    private(set) var isBusy = false
    /// The read or change that the pane is waiting for.
    @ObservationIgnored private(set) var operation: Task<Void, Never>?

    init(store: LoginStore) { self.store = store }

    var selectedLogin: SavedLogin? { store.logins.first { $0.id == selection } }

    private func start(_ work: @escaping @MainActor () async -> Void) {
        isBusy = true
        operation = Task { [weak self] in
            await work()
            self?.isBusy = false
            self?.operation = nil
        }
    }

    func reload() {
        guard !isBusy else { return }
        start { [store] in await store.reload() }
    }

    func add() {
        guard !isBusy else { return }
        draft = Draft()
    }

    func edit(_ id: SavedLogin.ID?) {
        guard !isBusy, let login = store.logins.first(where: { $0.id == id }) else { return }
        selection = login.id
        draft = Draft(login)
    }

    /// Saves the editor's fields and closes it, or shows in it why the login couldn't be saved.
    func save() {
        guard let draft, !isBusy else { return }
        start { [self] in
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
    }

    func delete(_ login: SavedLogin) {
        guard !isBusy else { return }
        start { [self] in
            do {
                try await store.delete(login.id)
            } catch {
                issue = error.localizedDescription
            }
        }
    }
}
