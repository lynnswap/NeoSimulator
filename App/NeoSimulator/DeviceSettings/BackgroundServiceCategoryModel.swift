import AppKit
import Observation
import XcodeSimulatorHost

@MainActor
protocol BackgroundServiceEditing: AnyObject {
    var serviceState: SimulatorBackgroundServices? { get }
    var pendingRestartLabels: Set<String> { get }
    func setServices(_ targets: [SimulatorBackgroundServiceTarget], enabled: Bool)
}

extension BackgroundServiceEditing {
    var pendingRestartLabels: Set<String> { [] }
}

@MainActor @Observable
final class BackgroundServiceCategoryModel: Identifiable {
    let category: SimulatorBackgroundServiceCategory
    let items: [BackgroundServiceItem]
    var isExpanded = false
    @ObservationIgnored private weak var source: (any BackgroundServiceEditing)?
    nonisolated var id: String { category.id }

    init(_ category: SimulatorBackgroundServiceCategory, source: any BackgroundServiceEditing) {
        self.category = category
        self.source = source
        items = category.services.map { BackgroundServiceItem(label: $0.label, detail: $0.summary, required: false, source: source) }
            + category.requiredServices.map { BackgroundServiceItem(label: $0.label, detail: $0.reason, required: true, source: source) }
    }

    var state: NSControl.StateValue {
        switch source?.serviceState?.state(of: category) {
        case .enabled: .on
        case .partiallyDisabled: .mixed
        default: .off
        }
    }

    func setEnabled(_ enabled: Bool) { source?.setServices([.category(id)], enabled: enabled) }
}

@MainActor
final class BackgroundServiceItem {
    let label: String
    let detail: String
    let required: Bool
    private weak var source: (any BackgroundServiceEditing)?

    init(label: String, detail: String, required: Bool, source: any BackgroundServiceEditing) {
        self.label = label
        self.detail = detail
        self.required = required
        self.source = source
    }

    var isEnabled: Bool { required || source?.serviceState?.isEnabled(label) == true }
    var help: String {
        if isEnabled, source?.pendingRestartLabels.contains(label) == true {
            return detail + "\nStarts after the simulator restarts."
        }
        return detail
    }
    var canChange: Bool {
        guard !required, let state = source?.serviceState else { return false }
        return !state.isEnabled(label) || state.canDisable(label)
    }
    func setEnabled(_ enabled: Bool) { source?.setServices([.service(label)], enabled: enabled) }
}
