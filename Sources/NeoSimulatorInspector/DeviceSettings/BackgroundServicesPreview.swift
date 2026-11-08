#if DEBUG
    import AppKit
    import NeoSimulatorHostSupport
    import NeoSimulatorKit
    import NeoSimulatorManager

    /// The services page in an inspector item, reading in-memory host responses through the manager.
    @MainActor
    enum BackgroundServicesPreview {
        enum Scenario: String {
            case overrides, defaultProfile, defaultModified, stopped
        }

        private static var lightweightConfiguration: ServiceConfiguration {
            var configuration = ServiceConfiguration()
            configuration.set([.category("widgets"), .category("siri"), .category("search")], enabled: false)
            return configuration
        }

        static func make(_ scenario: Scenario) -> NSSplitViewController {
            var configuration = lightweightConfiguration
            if scenario == .overrides {
                configuration.set([.service("com.apple.searchd")], enabled: true)
            } else if scenario == .defaultProfile {
                configuration = ServiceConfiguration()
            }
            let source = PreviewManagerSource(configuration: configuration, stopped: scenario == .stopped)
            let manager = SimulatorManagerModel(
                source: source,
                serviceProfiles: .preview(named: "NeoSimulator.BackgroundServicesPreview.\(scenario.rawValue)")
            )
            let model = BackgroundServicesInspectorModel(manager: manager, showProfileSettings: { _ in })
            manager.onError = { [weak model] error in
                model?.actionIssue = error.localizedDescription
            }
            let controller = BackgroundServicesViewController(model: model)
            let item = NSSplitViewItem(inspectorWithViewController: controller)
            controller.addAccessories(to: item)
            let split = NSSplitViewController()
            split.splitView.isVertical = true
            split.addSplitViewItem(item)
            Task {
                do {
                    try await load(scenario, source: source, manager: manager)
                } catch {
                    model.actionIssue = error.localizedDescription
                }
            }
            return split
        }

        private static func load(
            _ scenario: Scenario,
            source: PreviewManagerSource,
            manager: SimulatorManagerModel
        ) async throws {
            let store = manager.serviceProfiles
            let lightweight = try store.create(name: "Lightweight", configuration: lightweightConfiguration)
            if scenario == .defaultModified {
                try store.record(
                    [.category("widgets"), .category("siri"), .category("search")],
                    enabled: false,
                    for: source.device.id,
                    productFamily: "iPhone"
                )
            } else if scenario != .defaultProfile {
                try store.assign(.profile(lightweight.id), to: source.device.id)
            }
            if scenario == .overrides {
                try store.record(
                    [.service("com.apple.searchd")],
                    enabled: true,
                    for: source.device.id,
                    productFamily: "iPhone"
                )
            }
            await manager.refresh()
            manager.inspect(source.device, selectionCount: 1)
            manager.selection.setServicesVisible(true)
            await manager.registry.finishReading()
        }
    }
#endif
