import AppKit
import NeoSimulatorManager
import SwiftUI

@MainActor
final class LoginsSettingsViewController: NSHostingController<LoginsSettingsView> {
    let model: LoginsSettingsModel

    init(store: LoginStore) {
        model = LoginsSettingsModel(store: store)
        super.init(rootView: LoginsSettingsView(model: model))
        title = "Logins"
        sizingOptions = [.standardBounds, .preferredContentSize]
    }
    required init?(coder: NSCoder) { nil }

    // The pane reads the keychain only when it shows, so that macOS asks for access where the logins appear.
    override func viewDidAppear() {
        super.viewDidAppear()
        model.reload()
    }
}

struct LoginsSettingsView: View {
    @Bindable var model: LoginsSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            List(selection: $model.selection) {
                ForEach(model.store.logins) { login in
                    LoginRow(login: login).tag(login.id)
                }
            }
            .listStyle(.bordered)
            .contextMenu(forSelectionType: SavedLogin.ID.self) { selection in
                if let id = selection.first {
                    Button("Edit…") { model.edit(id) }
                    Button("Delete…", role: .destructive) { confirmDeleting(id) }
                }
            } primaryAction: { selection in
                model.edit(selection.first)
            }
            .overlay { unavailable }
            HStack(spacing: 12) {
                ControlGroup {
                    Button("Add Login", systemImage: "plus", action: model.add)
                    Button("Delete Login", systemImage: "minus") { confirmDeleting(model.selection) }
                        .disabled(model.selectedLogin == nil)
                }
                .labelStyle(.iconOnly)
                .fixedSize()
                Button("Edit…") { model.edit(model.selection) }
                    .disabled(model.selectedLogin == nil)
                Spacer()
            }
            Text("Logins are saved in your login keychain.")
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 560, height: 400)
        .sheet(item: $model.draft) { _ in
            if let draft = Binding($model.draft) { LoginEditor(draft: draft, model: model) }
        }
        .confirmationDialog(
            "Delete the login “\(model.deleting?.label ?? "")”?",
            isPresented: Binding(get: { model.deleting != nil }, set: { if !$0 { model.deleting = nil } })
        ) {
            Button("Delete", role: .destructive) { Task { await model.delete() } }
        } message: {
            Text("The login is removed from your login keychain.")
        }
        .alert(
            "Unable to Delete Login",
            isPresented: Binding(get: { model.issue != nil }, set: { if !$0 { model.issue = nil } })
        ) {
            Button("OK") { model.issue = nil }
        } message: {
            Text(model.issue ?? "")
        }
    }

    private func confirmDeleting(_ id: SavedLogin.ID?) {
        model.deleting = model.store.logins.first { $0.id == id }
    }

    @ViewBuilder private var unavailable: some View {
        if let issue = model.store.issue {
            ContentUnavailableView {
                Label("Unable to Read Logins", systemImage: "exclamationmark.triangle")
            } description: {
                Text(issue)
            } actions: {
                Button("Retry", action: model.reload)
            }
        } else if model.store.logins.isEmpty {
            ContentUnavailableView(
                "No Logins", systemImage: "key",
                description: Text("Add a login for an app that you sign in to on a simulator."))
        }
    }
}

private struct LoginRow: View {
    let login: SavedLogin

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(login.label)
                Text(login.applicationIdentifier)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(login.userName)
                if !login.allowsAutomation {
                    Text("Automated sign-in off")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct LoginEditor: View {
    @Binding var draft: LoginsSettingsModel.Draft
    let model: LoginsSettingsModel

    var body: some View {
        Form {
            Section {
                TextField(
                    "App Bundle Identifier", text: $draft.applicationIdentifier,
                    prompt: Text(verbatim: "com.example.app"))
                TextField("Label", text: $draft.label)
                TextField("User Name", text: $draft.userName)
                SecureField(
                    "Password", text: $draft.password, prompt: draft.existing == nil ? nil : Text("Unchanged"))
            }
            Section {
                TextField(
                    "Web Origins", text: $draft.origins, prompt: Text(verbatim: "https://example.com"),
                    axis: .vertical)
            } footer: {
                Text("A web sign-in may type the login only on these origins. Separate origins with commas.")
            }
            Section {
                Toggle("Allow automated sign-in", isOn: $draft.allowsAutomation)
            }
            if let issue = draft.issue {
                Text(issue).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .autocorrectionDisabled()
        .disabled(model.isSaving)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { model.draft = nil }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await model.save() } }
                    .disabled(!draft.canSave || model.isSaving)
            }
        }
    }
}

#if DEBUG
    #Preview("Logins", traits: .sizeThatFitsLayout) {
        let store = LoginStore(keychain: InMemoryLoginKeychain())
        Task {
            _ = try? await store.save(
                SavedLogin(
                    applicationIdentifier: "com.example.app", label: "Premium", userName: "premium@example.com",
                    origins: [WebOrigin("https://login.example.com")].compactMap(\.self)),
                password: "preview")
        }
        return LoginsSettingsViewController(store: store)
    }

    #Preview("Logins — Editor", traits: .sizeThatFitsLayout) {
        @Previewable @State var draft = LoginsSettingsModel.Draft()
        LoginEditor(draft: $draft, model: LoginsSettingsModel(store: LoginStore(keychain: InMemoryLoginKeychain())))
    }

    #Preview("Logins — Empty", traits: .sizeThatFitsLayout) {
        LoginsSettingsViewController(store: LoginStore(keychain: InMemoryLoginKeychain()))
    }
#endif
