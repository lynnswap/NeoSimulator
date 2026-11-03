import SwiftUI
@_spi(NeoSimulator) import XcodeSimulatorHost

/// The inspector's Background Services page for the selected simulator. Expanding a category lists its services.
@MainActor
struct ManagerBackgroundServicesView: View {
    let manager: SimulatorManagerModel
    let model: BackgroundServicesModel
    @State private var expandedCategories: Set<String> = []
    private var device: InventoryDevice? { model.device }
    private var holdsChanges: Bool {
        manager.holdsSettingsEdits || device.map { manager.managingDeviceIDs.contains($0.id) } == true
    }

    var body: some View {
        if model.selectionCount != 1 || device == nil {
            ContentUnavailableView(model.selectionCount > 1 ? "Multiple Devices Selected" : "Select a Device",
                                   systemImage: "gearshape.2",
                                   description: Text("Select one simulator to change its background services."))
        } else if let unavailableReason {
            ContentUnavailableView("Background Services Unavailable", systemImage: "gearshape.2",
                                   description: Text(unavailableReason))
        } else if let services = model.services {
            servicesForm(services)
        } else if let issue = model.issue {
            ContentUnavailableView {
                Label("Background Services Unavailable", systemImage: "gearshape.2")
            } description: {
                Text(issue)
            } actions: {
                Button("Try Again") { model.requestRefresh() }
                    .disabled(model.isLoading)
            }
        } else {
            ProgressView("Loading background services…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var unavailableReason: String? {
        switch device {
        case .simulator(let simulator):
            guard simulator.isAvailable else { return "Install a compatible runtime to use this simulator." }
            guard simulator.state == "Booted" else { return "Start this simulator to change its background services." }
            return nil
        case .remote: return "Background services can be changed only on simulators."
        case nil: return nil
        }
    }

    private func servicesForm(_ services: SimulatorBackgroundServices) -> some View {
        Form {
            Section {
                ForEach(SimulatorBackgroundServiceCategory.all) { category in
                    categoryRow(category, services: services)
                }
            } header: {
                HStack(spacing: 6) {
                    Text("Categories")
                    if model.isChanging { ProgressView().controlSize(.mini) }
                }
            } footer: {
                footer
            }
        }
        .formStyle(.grouped)
        .disabled(holdsChanges)
    }

    private func categoryRow(_ category: SimulatorBackgroundServiceCategory, services: SimulatorBackgroundServices) -> some View {
        DisclosureGroup(isExpanded: Binding(get: { expandedCategories.contains(category.id) }, set: {
            if $0 { expandedCategories.insert(category.id) } else { expandedCategories.remove(category.id) }
        })) {
            ForEach(category.services) { service in
                let required = model.isEnabled(service.label) && !services.canDisable(service.label)
                Toggle(isOn: Binding(get: { model.isEnabled(service.label) },
                                     set: { change([.service(service.label)], enabled: $0) })) {
                    Text(service.summary)
                    Text(service.label).monospaced()
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(required)
                .help(required ? "This platform needs this service." : "")
            }
            ForEach(category.requiredServices) { service in
                LabeledContent {
                    Text("Always On").foregroundStyle(.secondary)
                } label: {
                    Text(service.reason)
                    Text(service.label).monospaced()
                }
            }
        } label: {
            Toggle(isOn: Binding(get: { model.isEnabled(category) }, set: { change([.category(category.id)], enabled: $0) })) {
                Text(category.name)
                Text("When off: \(category.consequence)")
                if !model.isEnabled(category), services.state(of: category) == .partiallyDisabled {
                    Text("Some of these services are off.")
                }
            }
            .toggleStyle(.switch)
            .help(category.summary)
        }
    }

    @ViewBuilder
    private var footer: some View {
        let outcome = model.outcome
        if outcome != nil || model.issue != nil {
            VStack(alignment: .leading, spacing: 4) {
                if let labels = outcome?.stillEnabledLabels, !labels.isEmpty {
                    Text("Kept on because another enabled category or the platform needs them: \(labels.joined(separator: ", "))")
                }
                if let labels = outcome?.notStartedLabels, !labels.isEmpty {
                    Text("Starts when the simulator next boots: \(labels.joined(separator: ", "))")
                }
                if let issue = model.issue {
                    Text("Showing the last state read. \(issue)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func change(_ targets: [SimulatorBackgroundServiceTarget], enabled: Bool) {
        guard let identifier = device?.id else { return }
        manager.setBackgroundServices(targets, enabled: enabled, for: identifier)
    }
}
