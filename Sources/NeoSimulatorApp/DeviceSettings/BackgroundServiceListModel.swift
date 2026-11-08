import NeoSimulatorKit
import NeoSimulatorHostSupport
import Foundation
import Observation

@MainActor @Observable
final class BackgroundServiceListModel {
    struct Section {
        let category: BackgroundServiceCategoryModel
        let items: [BackgroundServiceItem]
    }

    private(set) var categories: [BackgroundServiceCategoryModel]
    private(set) var sections: [Section] = []
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            collapsedResults = []
            updateResults()
        }
    }
    var isFiltering: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// Results open every matching category; collapsing one lasts until the query changes.
    private var collapsedResults: Set<String> = []

    init(categories: [BackgroundServiceCategoryModel]) {
        self.categories = categories
        updateResults()
    }

    func setCategories(_ categories: [BackgroundServiceCategoryModel]) {
        guard self.categories.map(\.id) != categories.map(\.id)
            || zip(self.categories, categories).contains(where: { pair in pair.0 !== pair.1 }) else { return }
        self.categories = categories
        updateResults()
    }

    func isExpanded(_ category: BackgroundServiceCategoryModel) -> Bool {
        isFiltering ? !collapsedResults.contains(category.id) : category.isExpanded
    }

    func setExpanded(_ expanded: Bool, for category: BackgroundServiceCategoryModel) {
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
