import SwiftUI
@_spi(NeoSimulator) import XcodeSimulatorHost

/// The same service controls edit a reusable definition or the selected simulator.
struct BackgroundServiceCategories: View {
    let state: SimulatorBackgroundServices
    var overrides: Set<String> = []
    let change: ([SimulatorBackgroundServiceTarget], Bool) -> Void
    var reset: ((Set<String>) -> Void)?

    var body: some View {
        ForEach(SimulatorBackgroundServiceCategory.all) { category in
            BackgroundServiceCategoryRow(category: category, state: state, overrides: overrides, change: change, reset: reset)
        }
    }
}

private struct BackgroundServiceCategoryRow: View {
    let category: SimulatorBackgroundServiceCategory
    let state: SimulatorBackgroundServices
    let overrides: Set<String>
    let change: ([SimulatorBackgroundServiceTarget], Bool) -> Void
    let reset: ((Set<String>) -> Void)?
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(category.services) { service in
                HStack {
                    Toggle(isOn: Binding(get: { state.isEnabled(service.label) },
                                         set: { change([.service(service.label)], $0) })) {
                        Text(service.summary)
                        Text(service.label).monospaced()
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(state.isEnabled(service.label) && !state.canDisable(service.label))
                    .help(state.canDisable(service.label) ? "" : "This platform needs this service.")
                    if overrides.contains(service.label), let reset {
                        Text("Custom").font(.caption).foregroundStyle(.secondary)
                        Button { reset([service.label]) } label: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        .buttonStyle(.borderless)
                        .help("Revert to Service Profile")
                        .accessibilityLabel("Revert \(service.summary) to Service Profile")
                    }
                }
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
            VStack(alignment: .leading, spacing: 3) {
                Toggle(isOn: Binding(get: { state.state(of: category) == .enabled },
                                     set: { change([.category(category.id)], $0) })) {
                    Text(category.name)
                    Text("When off: \(category.consequence)")
                    if state.state(of: category) == .partiallyDisabled {
                        Text("Some of these services are off.")
                    }
                }
                .toggleStyle(.switch)
                .help(category.summary)
                let count = category.services.filter { overrides.contains($0.label) }.count
                if count > 0 {
                    Text("\(count) custom changes").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
