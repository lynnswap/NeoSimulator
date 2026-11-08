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
    package private(set) var category: SimulatorBackgroundServiceCategory
    package private(set) var items: [BackgroundServiceItem]
    /// Whether the app added the category, which lets it gain and lose services.
    package let isCustom: Bool
    package var isExpanded = false
    @ObservationIgnored private weak var source: (any BackgroundServiceEditing)?
    package nonisolated let id: String

    package init(
        _ category: SimulatorBackgroundServiceCategory, isCustom: Bool = false, source: any BackgroundServiceEditing
    ) {
        id = category.id
        self.category = category
        self.isCustom = isCustom
        self.source = source
        items = Self.items(of: category, reusing: [], source: source)
    }

    /// Models for `catalog`'s categories, which keep the models in `existing` whose categories it still lists. Their
    /// identity holds what a list selects and expands, and the identity of their services' rows.
    /// - Parameter custom: The identifiers of the categories that the app added.
    package static func models(
        for catalog: BackgroundServiceCatalog, custom: Set<String>, reusing existing: [BackgroundServiceCategoryModel],
        source: any BackgroundServiceEditing
    ) -> [BackgroundServiceCategoryModel] {
        let models = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return catalog.categories.map { category in
            guard let model = models[category.id] else {
                return BackgroundServiceCategoryModel(category, isCustom: custom.contains(category.id), source: source)
            }
            model.update(category)
            return model
        }
    }

    private func update(_ category: SimulatorBackgroundServiceCategory) {
        guard category != self.category, let source else { return }
        self.category = category
        let items = Self.items(of: category, reusing: self.items, source: source)
        if items.map(ObjectIdentifier.init) != self.items.map(ObjectIdentifier.init) { self.items = items }
    }

    private static func items(
        of category: SimulatorBackgroundServiceCategory, reusing existing: [BackgroundServiceItem],
        source: any BackgroundServiceEditing
    ) -> [BackgroundServiceItem] {
        let items = Dictionary(existing.map { ($0.label, $0) }, uniquingKeysWith: { first, _ in first })
        return category.services.map {
            items[$0.label] ?? BackgroundServiceItem(label: $0.label, detail: $0.summary, source: source)
        }
            + category.requiredServices.map {
                items[$0.label]
                    ?? BackgroundServiceItem(
                        label: $0.label, detail: $0.reason, requiredReason: $0.reason, source: source)
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
