import NeoSimulatorKit
import NeoSimulatorHostSupport
import Observation

@MainActor
package protocol BackgroundServiceEditing: AnyObject {
    var serviceState: SimulatorBackgroundServices? { get }
    var pendingRestartLabels: Set<String> { get }
    func setServices(_ targets: [SimulatorBackgroundServiceTarget], enabled: Bool)
}

extension BackgroundServiceEditing {
    package var pendingRestartLabels: Set<String> { [] }
}

@MainActor @Observable
package final class BackgroundServiceCategoryModel: Identifiable {
    package let category: SimulatorBackgroundServiceCategory
    package let items: [BackgroundServiceItem]
    package var isExpanded = false
    @ObservationIgnored private weak var source: (any BackgroundServiceEditing)?
    package nonisolated var id: String { category.id }

    package init(_ category: SimulatorBackgroundServiceCategory, source: any BackgroundServiceEditing) {
        self.category = category
        self.source = source
        items = category.services.map { BackgroundServiceItem(label: $0.label, detail: $0.summary, required: false, source: source) }
            + category.requiredServices.map { BackgroundServiceItem(label: $0.label, detail: $0.reason, required: true, source: source) }
    }

    /// A partially disabled category stays on, as a switch shows a mixed state.
    package var isEnabled: Bool {
        switch source?.serviceState?.state(of: category) {
        case .enabled, .partiallyDisabled: true
        case .disabled, nil: false
        }
    }

    package func setEnabled(_ enabled: Bool) { source?.setServices([.category(id)], enabled: enabled) }
}

@MainActor
package final class BackgroundServiceItem {
    package let label: String
    package let detail: String
    package let required: Bool
    private weak var source: (any BackgroundServiceEditing)?

    package init(label: String, detail: String, required: Bool, source: any BackgroundServiceEditing) {
        self.label = label
        self.detail = detail
        self.required = required
        self.source = source
    }

    package var isEnabled: Bool { required || source?.serviceState?.isEnabled(label) == true }
    package var help: String {
        if isEnabled, source?.pendingRestartLabels.contains(label) == true {
            return detail + "\nStarts after the simulator restarts."
        }
        return detail
    }
    package var canChange: Bool {
        guard !required, let state = source?.serviceState else { return false }
        return !state.isEnabled(label) || state.canDisable(label)
    }
    package func setEnabled(_ enabled: Bool) { source?.setServices([.service(label)], enabled: enabled) }
}
