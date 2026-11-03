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

    var body: some View {
        Picker("Service Profile", selection: Binding(get: { binding?.profileID },
                                                     set: { manager.selectServiceProfile($0, for: device.id) })) {
            Text("Custom (No Profile)").tag(UUID?.none)
            ForEach(store.profiles) { profile in
                Text(profile.name).tag(Optional(profile.id))
            }
        }
        .disabled(store.issue != nil)
        if let binding {
            if !binding.overrides.isEmpty {
                LabeledContent("\(binding.overrides.count) custom changes") {
                    Button("Revert All") { manager.resetServiceOverrides(for: device.id) }
                        .buttonStyle(.borderless)
                }
            }
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
        Menu {
            Button("Save Current Configuration as Profile…") {
                if let configuration = model.configuration {
                    draft = ServiceProfileDraft(name: "New Profile", configuration: configuration)
                }
            }
            .disabled(!device.canInspectBackgroundServices || model.configuration == nil || model.isChanging || store.issue != nil)
            Button("Manage Service Profiles…") { manager.onManageServiceProfiles?(binding?.profileID) }
        } label: {
            Label("Profile Actions", systemImage: "ellipsis")
        }
        .sheet(item: $draft) { draft in
            ServiceProfileEditor(draft: draft) { name, configuration in
                try store.create(name: name, configuration: configuration)
            }
        }
        Text("Individual changes affect only this simulator.")
            .font(.caption).foregroundStyle(.secondary)
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

#Preview("No Profile", traits: .sizeThatFitsLayout) {
    BackgroundServicesPreview(.noProfile)
}

#Preview("Stopped Simulator", traits: .sizeThatFitsLayout) {
    BackgroundServicesPreview(.stopped)
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
