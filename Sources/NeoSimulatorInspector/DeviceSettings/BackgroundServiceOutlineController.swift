import NeoSimulatorKit
import NeoSimulatorHostSupport
import AppKit
import ObservationBridge
import SwiftUI
import NeoSimulatorManager

@MainActor
package final class BackgroundServiceOutlineController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    package let model: BackgroundServiceListModel
    package lazy var searchAccessory = BackgroundServiceSearchAccessoryViewController(model: model)
    package let outline = NSOutlineView()
    package var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            for row in 0..<outline.numberOfRows {
                (outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? BackgroundServiceCell)?.controlsEnabled = isEnabled
            }
        }
    }
    private var observations: [PortableObservationTracking.Token] = []
    private var resultsObservation: PortableObservationTracking.Token?
    private var observedCategories: [BackgroundServiceCategoryModel] = []
    private var updatingRows = false
    private var displayedRows: [[ObjectIdentifier]] = []
    private var displayedQuery: String?
    private var sections: [BackgroundServiceListModel.Section] = []
    private let empty = NSHostingView(rootView: ContentUnavailableView.search(text: ""))

    package init(categories: [BackgroundServiceCategoryModel]) {
        model = BackgroundServiceListModel(categories: categories)
        super.init(nibName: nil, bundle: nil)
    }

    package required init?(coder: NSCoder) { nil }

    package override func loadView() {
        let column = NSTableColumn(identifier: .init("Service"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.setAccessibilityLabel("Background Services")
        outline.delegate = self
        outline.dataSource = self
        outline.style = .sourceList
        outline.rowHeight = 32
        outline.selectionHighlightStyle = .none
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outline.autoresizesOutlineColumn = false
        outline.intercellSpacing = NSSize(width: 0, height: 4)
        outline.indentationPerLevel = 14
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = outline
        view = NSView()
        empty.sizingOptions = []
        for child in [scroll, empty] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
            NSLayoutConstraint.activate([
                child.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                child.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                child.topAnchor.constraint(equalTo: view.topAnchor),
                child.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        }
        resultsObservation = withPortableContinuousObservation { [weak self] _ in self?.updateResults() }
    }

    private func updateResults() {
        let categories = model.categories
        if observedCategories.count != categories.count
            || zip(observedCategories, categories).contains(where: { pair in pair.0 !== pair.1 }) {
            observedCategories = categories
            observations = categories.map { category in
                withPortableContinuousObservation { [weak self, category] _ in
                    let expanded = category.isExpanded
                    guard let self, !model.isFiltering, outline.row(forItem: category) >= 0 else { return }
                    if expanded { outline.expandItem(category) }
                    else { outline.collapseItem(category) }
                }
            }
        }
        let sections = model.sections
        let rows = sections.map { [ObjectIdentifier($0.category)] + $0.items.map(ObjectIdentifier.init) }
        guard rows != displayedRows || model.query != displayedQuery else { return }
        let initial = displayedQuery == nil
        let previous = self.sections
        self.sections = sections
        displayedRows = rows
        displayedQuery = model.query
        updatingRows = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            if initial { outline.reloadData() }
            else { updateRows(from: previous, to: sections) }
            for section in sections {
                let expanded = model.isExpanded(section.category)
                if expanded != outline.isItemExpanded(section.category) {
                    if expanded { outline.expandItem(section.category) }
                    else { outline.collapseItem(section.category) }
                }
            }
        }
        updatingRows = false
        if sections.isEmpty { empty.rootView = ContentUnavailableView.search(text: model.query) }
        empty.isHidden = !sections.isEmpty
    }

    private func updateRows(from previous: [BackgroundServiceListModel.Section],
                            to current: [BackgroundServiceListModel.Section]) {
        let oldCategories = previous.map { ObjectIdentifier($0.category) }
        let newCategories = current.map { ObjectIdentifier($0.category) }
        outline.beginUpdates()
        let removed = IndexSet(oldCategories.indices.filter { !newCategories.contains(oldCategories[$0]) })
        let inserted = IndexSet(newCategories.indices.filter { !oldCategories.contains(newCategories[$0]) })
        if !removed.isEmpty { outline.removeItems(at: removed, inParent: nil, withAnimation: []) }
        if !inserted.isEmpty { outline.insertItems(at: inserted, inParent: nil, withAnimation: []) }
        for section in current {
            guard let old = previous.first(where: { $0.category === section.category }) else { continue }
            let oldItems = old.items.map(ObjectIdentifier.init)
            let newItems = section.items.map(ObjectIdentifier.init)
            let oldSet = Set(oldItems)
            let newSet = Set(newItems)
            let removed = IndexSet(oldItems.indices.filter { !newSet.contains(oldItems[$0]) })
            let inserted = IndexSet(newItems.indices.filter { !oldSet.contains(newItems[$0]) })
            if !removed.isEmpty { outline.removeItems(at: removed, inParent: section.category, withAnimation: []) }
            if !inserted.isEmpty { outline.insertItems(at: inserted, inParent: section.category, withAnimation: []) }
        }
        outline.endUpdates()
        // A category that gains its first service or loses its last one changes whether it expands.
        for section in current {
            guard let old = previous.first(where: { $0.category === section.category }),
                old.items.isEmpty != section.items.isEmpty
            else { continue }
            outline.reloadItem(section.category)
        }
    }

    private func items(in category: BackgroundServiceCategoryModel) -> [BackgroundServiceItem] {
        sections.first { $0.category === category }?.items ?? []
    }

    package func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let category = item as? BackgroundServiceCategoryModel { return items(in: category).count }
        return item == nil ? sections.count : 0
    }

    package func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let category = item as? BackgroundServiceCategoryModel { return items(in: category)[index] }
        return sections[index].category
    }

    package func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? BackgroundServiceCategoryModel).map { !items(in: $0).isEmpty } ?? false
    }

    package func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { false }

    package func outlineViewItemDidExpand(_ notification: Notification) {
        guard !updatingRows, let category = notification.userInfo?["NSObject"] as? BackgroundServiceCategoryModel else { return }
        model.setExpanded(true, for: category)
    }

    package func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !updatingRows, let category = notification.userInfo?["NSObject"] as? BackgroundServiceCategoryModel else { return }
        model.setExpanded(false, for: category)
    }

    package func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("ServiceCell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? BackgroundServiceCell
            ?? BackgroundServiceCell()
        cell.identifier = identifier
        cell.configure(item: item, showsDetails: false)
        cell.controlsEnabled = isEnabled
        return cell
    }
}
