import SwiftUI
@_spi(NeoSimulator) import XcodeSimulatorHost

@MainActor
struct ManagerBackgroundServicesView: View {
    let manager: SimulatorManagerModel
    let model: BackgroundServicesModel

    private var holdsChanges: Bool {
        manager.holdsSettingsEdits || model.device.map { manager.managingDeviceIDs.contains($0.id) } == true
    }

    var body: some View {
        if model.selectionCount != 1 || model.device == nil {
            ContentUnavailableView(model.selectionCount > 1 ? "Multiple Devices Selected" : "Select a Device",
                                   systemImage: "cpu",
                                   description: Text("Select one simulator to change its background services."))
        } else if let device = model.device, case .simulator(let simulator) = device {
            Form {
                Section {
                    ServiceProfileControls(manager: manager, model: model, device: device)
                } footer: {
                    Text("Individual changes affect only this simulator.")
                }
                if !simulator.isAvailable {
                    Section { Text("Install a compatible runtime to use this simulator.") }
                } else if simulator.state != "Booted" {
                    Section { Text("Start this simulator to change individual services.") }
                } else if let configuration = model.configuration {
                    Section {
                        BackgroundServiceCategories(
                            state: SimulatorBackgroundServices(disabled: configuration.disabledLabels,
                                loaded: model.services?.loadedLabels ?? [], productFamily: simulator.productFamily),
                            overrides: Set(manager.serviceProfiles.binding(for: device.id)?.overrides.keys.map { $0 } ?? []),
                            change: { manager.setBackgroundServices($0, enabled: $1, for: device.id) },
                            reset: { manager.resetServiceOverrides(for: device.id, labels: $0) })
                    } header: {
                        HStack(spacing: 6) {
                            Text("Categories")
                            if model.isChanging { ProgressView().controlSize(.mini) }
                        }
                    } footer: {
                        BackgroundServiceOutcomeView(outcome: model.outcome, issue: model.issue)
                    }
                } else if let issue = model.issue {
                    Section {
                        Text(issue)
                        Button("Try Again") { model.requestRefresh() }.disabled(model.isLoading)
                    }
                } else {
                    Section { ProgressView("Loading background services…") }
                }
            }
            .formStyle(.grouped)
            .disabled(holdsChanges)
        } else {
            ContentUnavailableView("Background Services Unavailable", systemImage: "cpu",
                                   description: Text("Background services can be changed only on simulators."))
        }
    }
}

private struct ServiceProfileControls: View {
    let manager: SimulatorManagerModel
    let model: BackgroundServicesModel
    let device: InventoryDevice
    @State private var draft: ServiceProfileDraft?

    private var store: ServiceProfileStore { manager.serviceProfiles }
    private var binding: DeviceServiceProfile? { store.binding(for: device.id) }
    private var selectedProfileID: UUID { binding?.profileID ?? ServiceProfile.default.id }
    private var isModified: Bool {
        if let binding { return !binding.overrides.isEmpty }
        return model.configuration?.disabledLabels.isEmpty == false
    }

    var body: some View {
        Picker("Profile", selection: Binding(get: { selectedProfileID },
                                            set: { manager.selectServiceProfile($0, for: device.id) })) {
            ForEach([ServiceProfile.default] + store.profiles) { profile in
                if selectedProfileID == profile.id && isModified {
                    Text("\(profile.name) (Modified)").tag(profile.id)
                } else {
                    Text(profile.name).tag(profile.id)
                }
            }
        }
        .disabled(store.issue != nil)
        if let binding {
            if binding.pendingApplication {
                Text("This configuration will be applied when the simulator starts in NeoSimulator.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if store.hasUpdate(for: device.id) {
                LabeledContent("Profile update available") {
                    Button("Apply Update") { manager.applyServiceProfile(for: device.id, latest: true) }
                        .buttonStyle(.borderless)
                }
            }
            let count = model.unappliedLabels(for: binding.configuration).count
            if device.canInspectBackgroundServices, count > 0, !model.isChanging {
                LabeledContent("\(count) unapplied changes") {
                    Button("Apply") { manager.applyServiceProfile(for: device.id, latest: false) }
                        .buttonStyle(.borderless)
                }
            }
        }
        if let issue = store.issue {
            Text(issue).font(.caption).foregroundStyle(.secondary)
        }
        HStack {
            Button("Save as Profile…") {
                if let configuration = model.configuration {
                    draft = ServiceProfileDraft(name: "", configuration: configuration)
                }
            }
            .buttonStyle(.bordered)
            .disabled(!device.canInspectBackgroundServices || model.configuration == nil || model.isChanging || store.issue != nil)
            Spacer()
            if isModified {
                Button("Revert") {
                    if selectedProfileID == ServiceProfile.default.id {
                        manager.selectServiceProfile(ServiceProfile.default.id, for: device.id)
                    } else {
                        manager.resetServiceOverrides(for: device.id)
                    }
                }
                .buttonStyle(.borderless)
            }
        }
        Button("Manage Profiles…") {
            manager.onManageServiceProfiles?(selectedProfileID == ServiceProfile.default.id ? nil : selectedProfileID)
        }
        .buttonStyle(.borderless)
        .sheet(item: $draft) { draft in
            SaveServiceProfileSheet { name in
                try store.create(name: name, configuration: draft.configuration, assigningTo: device.id)
            }
        }
    }
}

private struct SaveServiceProfileSheet: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameFocused: Bool
    @State private var name = ""
    @State private var issue: String?
    let save: (String) throws -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Save Service Profile").font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    do {
                        try save(name)
                        dismiss()
                    } catch { issue = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .defaultFocus($nameFocused, true)
        .alert("Unable to Save Service Profile", isPresented: Binding(get: { issue != nil },
                                                                     set: { if !$0 { issue = nil } })) {
            Button("OK") { issue = nil }
        } message: { Text(issue ?? "") }
    }
}

#if DEBUG
#Preview("Profile + Overrides", traits: .sizeThatFitsLayout) {
    BackgroundServicesPreview(.overrides)
}

#Preview("Profile Update Available", traits: .sizeThatFitsLayout) {
    BackgroundServicesPreview(.profileUpdate)
}

#Preview("Unapplied Changes", traits: .sizeThatFitsLayout) {
    BackgroundServicesPreview(.unapplied)
}

#Preview("Default", traits: .sizeThatFitsLayout) {
    BackgroundServicesPreview(.defaultProfile)
}

#Preview("Default Modified", traits: .sizeThatFitsLayout) {
    BackgroundServicesPreview(.defaultModified)
}

#Preview("Stopped Simulator", traits: .sizeThatFitsLayout) {
    BackgroundServicesPreview(.stopped)
}

#Preview("Save Profile", traits: .sizeThatFitsLayout) {
    SaveServiceProfileSheet { _ in }
}
#endif

private struct BackgroundServiceOutcomeView: View {
    let outcome: BackgroundServicesModel.Outcome?
    let issue: String?

    var body: some View {
        if outcome != nil || issue != nil {
            VStack(alignment: .leading, spacing: 4) {
                if let labels = outcome?.stillEnabledLabels, !labels.isEmpty {
                    Text("Kept on because another enabled category or the platform needs them: \(labels.joined(separator: ", "))")
                }
                if let labels = outcome?.notStartedLabels, !labels.isEmpty {
                    Text("Starts when the simulator next boots: \(labels.joined(separator: ", "))")
                }
                if let issue {
                    Text("Showing the last state read. \(issue)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
