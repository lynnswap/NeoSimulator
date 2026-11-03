import AppKit
import Observation
import SwiftUI
@_spi(NeoSimulator) import XcodeSimulatorHost

@MainActor @Observable
final class ServiceProfilesSelection {
    var profileID: UUID? = ServiceProfile.default.id
}

@MainActor
final class ServiceProfilesSettingsViewController: NSHostingController<ServiceProfilesSettingsView> {
    init(store: ServiceProfileStore) {
        super.init(rootView: ServiceProfilesSettingsView(store: store, selection: ServiceProfilesSelection()))
        title = "Service Profiles"
        sizingOptions = [.standardBounds, .preferredContentSize]
    }

    required init?(coder: NSCoder) { nil }
}

struct ServiceProfileDraft: Identifiable {
    let id = UUID()
    var profileID: UUID?
    var name: String
    var configuration: ServiceConfiguration
}

struct ServiceProfilesSettingsView: View {
    let store: ServiceProfileStore
    @Bindable var selection: ServiceProfilesSelection
    @State private var draft: ServiceProfileDraft?
    @State private var deleting: ServiceProfile?
    @State private var error: String?

    private var selected: ServiceProfile { selection.profileID.flatMap(store.profile) ?? .default }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection.profileID) {
                    ForEach(store.availableProfiles) { profile in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(profile.name)
                            if profile.id == ServiceProfile.default.id {
                                Text("Built-in Profile").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("Used by \(store.usageCount(profile.id)) simulators")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tag(profile.id)
                    }
                }
                .listStyle(.sidebar)
                HStack {
                    Button {
                        draft = ServiceProfileDraft(name: "New Profile", configuration: ServiceConfiguration())
                    } label: { Image(systemName: "plus") }
                    .help("New Service Profile")
                    .accessibilityLabel("New Service Profile")
                    Button {
                        deleting = selected
                    } label: { Image(systemName: "minus") }
                    .help("Delete Service Profile")
                    .accessibilityLabel("Delete Service Profile")
                    .disabled(selected.id == ServiceProfile.default.id)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(12)
            }
            .frame(width: 210)
            Divider()
            if let issue = store.issue {
                ContentUnavailableView {
                    Label("Service Profiles Unavailable", systemImage: "cpu")
                } description: { Text(issue) } actions: {
                    Button("Try Again") { store.reload() }
                }
                .frame(maxWidth: .infinity)
            } else {
                ServiceProfileDetails(profile: selected, usageCount: store.usageCount(selected.id),
                                      edit: { draft = ServiceProfileDraft(profileID: selected.id, name: selected.name,
                                                                          configuration: selected.configuration) },
                                      duplicate: { draft = ServiceProfileDraft(name: "\(selected.name) Copy",
                                                                               configuration: selected.configuration) })
            }
        }
        .frame(width: 720, height: 520)
        .sheet(item: $draft) { draft in
            ServiceProfileEditor(draft: draft) { name, configuration in
                if let id = draft.profileID {
                    try store.update(id, name: name, configuration: configuration)
                    selection.profileID = id
                } else {
                    selection.profileID = try store.create(name: name, configuration: configuration).id
                }
            }
        }
        .confirmationDialog("Delete Service Profile?", isPresented: Binding(get: { deleting != nil },
                                                                           set: { if !$0 { deleting = nil } })) {
            if let deleting {
                Button("Delete", role: .destructive) {
                    do {
                        try store.delete(deleting.id)
                        selection.profileID = ServiceProfile.default.id
                    } catch { self.error = error.localizedDescription }
                    self.deleting = nil
                }
            }
        } message: {
            Text("The simulators keep their current services. Only the profile and its assignments are removed.")
        }
        .alert("Unable to Save Service Profiles", isPresented: Binding(get: { error != nil },
                                                                      set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }
}

private struct ServiceProfileDetails: View {
    let profile: ServiceProfile
    let usageCount: Int
    let edit: () -> Void
    let duplicate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(profile.name).font(.title2.bold())
            if profile.id == ServiceProfile.default.id {
                Text("Built-in Profile").foregroundStyle(.secondary)
            } else {
                Text("Used by \(usageCount) simulators").foregroundStyle(.secondary)
            }
            HStack {
                if profile.id != ServiceProfile.default.id {
                    Button("Edit…", action: edit)
                }
                Button("Duplicate…", action: duplicate)
            }
            Divider()
            List {
                ForEach(SimulatorBackgroundServiceCategory.all) { category in
                    LabeledContent(category.name) {
                        switch profile.configuration.state().state(of: category) {
                        case .enabled: Text("On")
                        case .disabled: Text("Off")
                        case .partiallyDisabled: Text("Custom")
                        }
                    }
                }
            }
            .listStyle(.plain)
            if profile.id == ServiceProfile.default.id {
                Text("Default enables all background services. Duplicate it to create your own profile.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Editing a profile does not change its simulators until you apply the update in Background Services.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct ServiceProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var configuration: ServiceConfiguration
    @State private var error: String?
    let save: (String, ServiceConfiguration) throws -> Void

    init(draft: ServiceProfileDraft, save: @escaping (String, ServiceConfiguration) throws -> Void) {
        _name = State(initialValue: draft.name)
        _configuration = State(initialValue: draft.configuration)
        self.save = save
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $name)
                }
                Section("Services") {
                    BackgroundServiceCategories(state: configuration.state()) { targets, enabled in
                        configuration.set(targets, enabled: enabled)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    do {
                        try save(name, configuration)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
        .frame(width: 560, height: 620)
        .alert("Unable to Save Service Profile", isPresented: Binding(get: { error != nil },
                                                                     set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }
}

#if DEBUG
#Preview("Service Profiles", traits: .sizeThatFitsLayout) {
    let store = ServiceProfileStore(defaults: UserDefaults(suiteName: "NeoSimulator.ServiceProfilesPreview")!)
    if store.profiles.isEmpty {
        let _ = try? store.create(name: "Development", configuration: ServiceConfiguration())
        let _ = try? store.create(name: "Lightweight", configuration: ServiceConfiguration(disabledLabels: ["com.apple.searchd"]))
    }
    let selection = ServiceProfilesSelection()
    selection.profileID = store.profiles.first?.id
    return ServiceProfilesSettingsView(store: store, selection: selection)
}

#Preview("Default Profile", traits: .sizeThatFitsLayout) {
    ServiceProfilesSettingsView(
        store: ServiceProfileStore(defaults: UserDefaults(suiteName: "NeoSimulator.DefaultServiceProfilePreview")!),
        selection: ServiceProfilesSelection())
}

#Preview("Edit Service Profile", traits: .sizeThatFitsLayout) {
    ServiceProfileEditor(draft: ServiceProfileDraft(name: "Development", configuration: ServiceConfiguration())) { _, _ in }
}
#endif
