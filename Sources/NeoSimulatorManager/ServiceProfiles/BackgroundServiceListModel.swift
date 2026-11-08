import NeoSimulatorKit
import NeoSimulatorHostSupport
import Foundation
import Observation

@MainActor @Observable
package final class BackgroundServiceListModel {
    package struct Section {
        package let category: BackgroundServiceCategoryModel
        package let items: [BackgroundServiceItem]
    }

    package private(set) var categories: [BackgroundServiceCategoryModel]
    package private(set) var sections: [Section] = []
    package var query = "" {
        didSet {
            guard query != oldValue else { return }
            collapsedResults = []
            updateResults()
        }
    }
    package var isFiltering: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// Results open every matching category; collapsing one lasts until the query changes.
    private var collapsedResults: Set<String> = []

    package init(categories: [BackgroundServiceCategoryModel]) {
        self.categories = categories
        updateResults()
    }

    package func setCategories(_ categories: [BackgroundServiceCategoryModel]) {
        guard self.categories.map(\.id) != categories.map(\.id)
            || zip(self.categories, categories).contains(where: { pair in pair.0 !== pair.1 }) else { return }
        self.categories = categories
        updateResults()
    }

    package func isExpanded(_ category: BackgroundServiceCategoryModel) -> Bool {
        isFiltering ? !collapsedResults.contains(category.id) : category.isExpanded
    }

    package func setExpanded(_ expanded: Bool, for category: BackgroundServiceCategoryModel) {
        if isFiltering {
            if expanded { collapsedResults.remove(category.id) } else { collapsedResults.insert(category.id) }
        } else {
            category.isExpanded = expanded
        }
    }

    private func updateResults() {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        sections = categories.compactMap { category in
            let items: [BackgroundServiceItem]
            if term.isEmpty || category.category.name.localizedStandardContains(term) {
                items = category.items
            } else {
                items = category.items.filter {
                    $0.label.localizedStandardContains(term) || $0.detail.localizedStandardContains(term)
                }
            }
            return items.isEmpty ? nil : Section(category: category, items: items)
        }
    }
}
