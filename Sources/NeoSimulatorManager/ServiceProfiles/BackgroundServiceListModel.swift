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
    package var query = "" {
        didSet {
            guard query != oldValue else { return }
            collapsedResults = []
        }
    }
    package var isFiltering: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// The category whose services show beside the categories.
    package var selectedCategoryID: String?
    /// The selected category's results, or the first category's while the query leaves out the selected one.
    package var selectedSection: Section? {
        sections.first { $0.category.id == selectedCategoryID } ?? sections.first
    }
    /// Results open every matching category; collapsing one lasts until the query changes.
    private var collapsedResults: Set<String> = []

    package init(categories: [BackgroundServiceCategoryModel]) {
        self.categories = categories
    }

    package func setCategories(_ categories: [BackgroundServiceCategoryModel]) {
        guard self.categories.map(\.id) != categories.map(\.id)
            || zip(self.categories, categories).contains(where: { pair in pair.0 !== pair.1 }) else { return }
        self.categories = categories
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

    /// The categories that match the filter, with their services that match it.
    ///
    /// A category shows all its services while nothing is filtered or its name matches, even when it has none, so that
    /// one just added can be selected to add its first service.
    package var sections: [Section] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return categories.compactMap { category in
            if term.isEmpty || category.category.name.localizedStandardContains(term) {
                return Section(category: category, items: category.items)
            }
            let items = category.items.filter {
                $0.label.localizedStandardContains(term) || $0.detail.localizedStandardContains(term)
            }
            return items.isEmpty ? nil : Section(category: category, items: items)
        }
    }
}
