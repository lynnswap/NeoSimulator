import AppKit
import ObservationBridge
import SwiftUI
import XcodeSimulatorHost

@MainActor
final class BackgroundServiceOutlineController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let model: BackgroundServiceListModel
    lazy var searchAccessory = BackgroundServiceSearchAccessoryViewController(model: model)
    let showsDetails: Bool
    let outline = NSOutlineView()
    var isEnabled = true {
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

    init(categories: [BackgroundServiceCategoryModel], showsDetails: Bool) {
        model = BackgroundServiceListModel(categories: categories)
        self.showsDetails = showsDetails
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let column = NSTableColumn(identifier: .init("Service"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.setAccessibilityLabel("Background Services")
        outline.delegate = self
        outline.dataSource = self
        outline.style = showsDetails ? .inset : .sourceList
        if showsDetails { outline.backgroundColor = .clear }
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
                let expanded = model.isFiltering || section.category.isExpanded
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
    }

    private func items(in category: BackgroundServiceCategoryModel) -> [BackgroundServiceItem] {
        sections.first { $0.category === category }?.items ?? []
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let category = item as? BackgroundServiceCategoryModel { return items(in: category).count }
        return item == nil ? sections.count : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let category = item as? BackgroundServiceCategoryModel { return items(in: category)[index] }
        return sections[index].category
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? BackgroundServiceCategoryModel).map { !items(in: $0).isEmpty } ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { false }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !updatingRows, !model.isFiltering else { return }
        (notification.userInfo?["NSObject"] as? BackgroundServiceCategoryModel)?.isExpanded = true
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !updatingRows, !model.isFiltering else { return }
        (notification.userInfo?["NSObject"] as? BackgroundServiceCategoryModel)?.isExpanded = false
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        showsDetails ? (item is BackgroundServiceCategoryModel ? 62 : 48) : 32
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("ServiceCell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? BackgroundServiceCell
            ?? BackgroundServiceCell()
        cell.identifier = identifier
        cell.configure(item: item, showsDetails: showsDetails)
        cell.controlsEnabled = isEnabled
        return cell
    }
}

@MainActor
private final class BackgroundServiceCell: NSTableCellView {
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let toggle = NSSwitch()
    private var observation: PortableObservationTracking.Token?
    private var change: ((Bool) -> Void)?
    private var editable = true
    private weak var representedItem: AnyObject?
    private var showsDetails = false
    var controlsEnabled = true { didSet { toggle.isEnabled = controlsEnabled && editable } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title.lineBreakMode = .byTruncatingMiddle
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 2
        let labels = NSStackView(views: [title, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        labels.translatesAutoresizingMaskIntoConstraints = false
        toggle.translatesAutoresizingMaskIntoConstraints = false
        toggle.controlSize = .small
        toggle.target = self
        toggle.action = #selector(toggleChanged)
        addSubview(labels)
        addSubview(toggle)
        NSLayoutConstraint.activate([
            labels.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -8),
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        toggle.setContentHuggingPriority(.required, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }

    func configure(item: Any, showsDetails: Bool) {
        let object = item as AnyObject
        guard representedItem !== object || self.showsDetails != showsDetails else { return }
        representedItem = object
        self.showsDetails = showsDetails
        observation?.cancel()
        if let category = item as? BackgroundServiceCategoryModel {
            title.stringValue = category.category.name
            title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            detail.stringValue = showsDetails ? "When off: " + category.category.consequence : ""
            toggle.setAccessibilityLabel(category.category.name)
            change = { [weak category] in category?.setEnabled($0) }
            observation = withPortableContinuousObservation { [weak self, category] _ in
                self?.toggle.state = category.state
            }
            editable = true
        } else if let service = item as? BackgroundServiceItem {
            title.stringValue = service.label
            title.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            detail.stringValue = showsDetails ? service.detail : ""
            toggle.setAccessibilityLabel(service.label)
            toolTip = service.detail
            change = { [weak service] in service?.setEnabled($0) }
            observation = withPortableContinuousObservation { [weak self, service] _ in
                guard let self else { return }
                toggle.state = service.isEnabled ? .on : .off
                editable = service.canChange
                toggle.isEnabled = controlsEnabled && editable
            }
        }
        detail.isHidden = !showsDetails
        toggle.isEnabled = controlsEnabled && editable
    }

    @objc private func toggleChanged() { change?(toggle.state == .on) }
}
