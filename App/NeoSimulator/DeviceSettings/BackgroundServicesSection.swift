import SwiftUI
@_spi(NeoSimulator) import XcodeSimulatorHost

/// The inspected simulator's background service categories. Expanding a category lists its services.
@MainActor
struct BackgroundServicesSection: View {
    let manager: SimulatorManagerModel
    let model: BackgroundServicesModel
    @State private var expandedCategories: Set<String> = []

    var body: some View {
        Section {
            if let services = model.services {
                ForEach(SimulatorBackgroundServiceCategory.all) { category in
                    categoryRow(category, services: services)
                }
            } else if let issue = model.issue {
                LabeledContent {
                    Button("Try Again") { model.requestRefresh() }
                        .disabled(model.isLoading)
                } label: {
                    Text("Background services could not be read.")
                    Text(issue)
                }
            } else {
                LabeledContent("Loading background services…") {
                    ProgressView().controlSize(.small)
                }
            }
        } header: {
            HStack {
                Text("Background Services")
                if model.isChanging { ProgressView().controlSize(.mini) }
            }
        } footer: {
            footer
        }
    }

    private func categoryRow(_ category: SimulatorBackgroundServiceCategory, services: SimulatorBackgroundServices) -> some View {
        DisclosureGroup(isExpanded: Binding(get: { expandedCategories.contains(category.id) }, set: {
            if $0 { expandedCategories.insert(category.id) } else { expandedCategories.remove(category.id) }
        })) {
            ForEach(category.services) { service in
                let enabled = model.isEnabled(service.label)
                Toggle(isOn: Binding(get: { model.isEnabled(service.label) },
                                     set: { change([.service(service.label)], enabled: $0) })) {
                    Text(service.summary)
                    Text(service.label).monospaced()
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(enabled && !services.canDisable(service.label))
                .help(enabled && !services.canDisable(service.label) ? "This platform needs this service." : "")
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
        if outcome != nil || (model.services != nil && model.issue != nil) {
            VStack(alignment: .leading, spacing: 4) {
                if let labels = outcome?.stillEnabledLabels, !labels.isEmpty {
                    Text("Kept on because another enabled category or the platform needs them:\(labels.joined(separator: ", "))")
                }
                if let labels = outcome?.notStartedLabels, !labels.isEmpty {
                    Text("Starts when the simulator next boots: \(labels.joined(separator: ", "))")
                }
                if model.services != nil, let issue = model.issue {
                    Text("Showing the last state read. \(issue)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func change(_ targets: [SimulatorBackgroundServiceTarget], enabled: Bool) {
        guard let identifier = model.device?.id else { return }
        manager.setBackgroundServices(targets, enabled: enabled, for: identifier)
    }
}
