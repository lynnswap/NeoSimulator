import Foundation
import Observation
import XcodeSimulatorHost

@MainActor @Observable
final class BackgroundServiceListModel {
    struct Section {
        let category: BackgroundServiceCategoryModel
        let items: [BackgroundServiceItem]
    }

    private(set) var categories: [BackgroundServiceCategoryModel]
    private(set) var sections: [Section] = []
    var query = "" {
        didSet { if query != oldValue { updateResults() } }
    }
    var isFiltering: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

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
