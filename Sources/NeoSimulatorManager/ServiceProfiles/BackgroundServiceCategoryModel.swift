import NeoSimulatorKit
import NeoSimulatorHostSupport
import Foundation
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
        items =
            category.services.map { BackgroundServiceItem(label: $0.label, detail: $0.summary, source: source) }
            + category.requiredServices.map {
                BackgroundServiceItem(label: $0.label, detail: $0.reason, requiredReason: $0.reason, source: source)
            }
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

/// Turning off a service that keeps running, which changes nothing.
package struct BackgroundServiceKeptRunning: LocalizedError {
    package let label: String
    package let reason: String

    package var errorDescription: String? { String(localized: "“\(label)” can’t be turned off.") }
    package var recoverySuggestion: String? { reason }
}

@MainActor
package final class BackgroundServiceItem {
    package let label: String
    package let detail: String
    /// Why simulators need the service, for one that its category lists without turning it off.
    private let requiredReason: String?
    private weak var source: (any BackgroundServiceEditing)?

    package init(
        label: String, detail: String, requiredReason: String? = nil, source: any BackgroundServiceEditing
    ) {
        self.label = label
        self.detail = detail
        self.requiredReason = requiredReason
        self.source = source
    }

    package var isEnabled: Bool { source?.serviceState?.isEnabled(label) == true }
    /// Why turning the service off leaves it running, or nil when turning it off stops it.
    /// Turning such a service on still applies, which starts it again where something disabled it.
    package var keptRunningReason: String? {
        if let requiredReason { return requiredReason }
        guard source?.serviceState?.platformRequiredLabels.contains(label) == true else { return nil }
        return String(localized: "This simulator’s platform keeps the service running.")
    }
    /// What the service does, or why turning it off leaves it running.
    package var summary: String {
        keptRunningReason.map { String(localized: "Can’t be turned off. \($0)") } ?? detail
    }
    package var help: String {
        if isEnabled, source?.pendingRestartLabels.contains(label) == true {
            return summary + "\nStarts after the simulator restarts."
        }
        return summary
    }

    /// Turns the service on, or off unless it keeps running.
    /// - Throws: ``BackgroundServiceKeptRunning`` without changing anything when turning off a service that keeps running.
    package func setEnabled(_ enabled: Bool) throws(BackgroundServiceKeptRunning) {
        if !enabled, let keptRunningReason {
            throw BackgroundServiceKeptRunning(label: label, reason: keptRunningReason)
        }
        source?.setServices([.service(label)], enabled: enabled)
    }
}
