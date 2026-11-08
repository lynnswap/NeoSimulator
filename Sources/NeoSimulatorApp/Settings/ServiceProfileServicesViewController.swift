import AppKit
import NeoSimulatorInspector
import NeoSimulatorManager
import ObservationBridge
import SwiftUI

/// Shows a profile's categories beside the services of the selected category.
/// The filter that spans both panes goes in the split view item that shows this controller.
@MainActor
final class ServiceProfileServicesViewController: NSSplitViewController {
    let list = BackgroundServiceListModel(categories: [])
    private(set) lazy var searchAccessory = BackgroundServiceSearchAccessoryViewController(model: list)
    private lazy var categories = ServiceCategoriesViewController(list: list)
    private lazy var services = ServiceItemsViewController(list: list)

    override func loadView() {
        super.loadView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        let categoriesItem = NSSplitViewItem(viewController: categories)
        categoriesItem.minimumThickness = 220
        // Resizing the window resizes the services first. A priority above dragging would fix the divider.
        categoriesItem.holdingPriority = NSLayoutConstraint.Priority(
            NSLayoutConstraint.Priority.defaultLow.rawValue + 1)
        addSplitViewItem(categoriesItem)
        let servicesItem = NSSplitViewItem(viewController: services)
        servicesItem.minimumThickness = 260
        addSplitViewItem(servicesItem)
    }

    /// Shows `profile`'s services, whose switches change it unless it is built in.
    func show(_ profile: ServiceProfile) {
        list.setCategories(profile.categories)
        categories.controlsEnabled = profile.canEdit
        services.controlsEnabled = profile.canEdit
    }
}

/// Lists the categories that match the filter and selects the one whose services show.
@MainActor
private final class ServiceCategoriesViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let list: BackgroundServiceListModel
    private let table = NSTableView()
    private let empty = NSHostingView(rootView: ContentUnavailableView.search(text: ""))
    private var categories: [BackgroundServiceCategoryModel] = []
    private var updatingSelection = false
    private var observation: PortableObservationTracking.Token?
    var controlsEnabled = true {
        didSet { setControlsEnabled(controlsEnabled, in: table) }
    }

    init(list: BackgroundServiceListModel) {
        self.list = list
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let scroll = makeServiceScrollView(for: table, accessibilityLabel: "Service Categories")
        table.rowHeight = 62
        table.dataSource = self
        table.delegate = self
        empty.sizingOptions = []
        view = NSView()
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
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observation = withPortableContinuousObservation { [weak self] _ in
            self?.update()
        }
    }

    private func update() {
        let shown = list.sections.map(\.category)
        if shown.map(ObjectIdentifier.init) != categories.map(ObjectIdentifier.init) {
            categories = shown
            table.reloadData()
        }
        let selected = list.selectedSection.flatMap { section in
            categories.firstIndex { $0 === section.category }
        }
        updatingSelection = true
        table.selectRowIndexes(selected.map { IndexSet(integer: $0) } ?? [], byExtendingSelection: false)
        updatingSelection = false
        if categories.isEmpty {
            empty.rootView = ContentUnavailableView.search(text: list.query)
        }
        empty.isHidden = !categories.isEmpty
    }

    func numberOfRows(in tableView: NSTableView) -> Int { categories.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        makeServiceCell(in: tableView, for: categories[row], controlsEnabled: controlsEnabled)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updatingSelection, categories.indices.contains(table.selectedRow) else { return }
        list.selectedCategoryID = categories[table.selectedRow].id
    }
}

/// Lists the selected category's services that match the filter.
@MainActor
private final class ServiceItemsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let list: BackgroundServiceListModel
    private let table = NSTableView()
    private var items: [BackgroundServiceItem] = []
    private var observation: PortableObservationTracking.Token?
    var controlsEnabled = true {
        didSet { setControlsEnabled(controlsEnabled, in: table) }
    }

    init(list: BackgroundServiceListModel) {
        self.list = list
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = makeServiceScrollView(for: table, accessibilityLabel: "Services")
        table.rowHeight = 48
        table.selectionHighlightStyle = .none
        table.dataSource = self
        table.delegate = self
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observation = withPortableContinuousObservation { [weak self] _ in
            self?.update()
        }
    }

    private func update() {
        let shown = list.selectedSection?.items ?? []
        guard shown.map(ObjectIdentifier.init) != items.map(ObjectIdentifier.init) else { return }
        items = shown
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        makeServiceCell(in: tableView, for: items[row], controlsEnabled: controlsEnabled)
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
}

@MainActor
private func makeServiceScrollView(for table: NSTableView, accessibilityLabel: String) -> NSScrollView {
    let column = NSTableColumn(identifier: .init("Service"))
    column.resizingMask = .autoresizingMask
    table.addTableColumn(column)
    table.headerView = nil
    table.style = .inset
    table.backgroundColor = .clear
    table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
    table.setAccessibilityLabel(accessibilityLabel)
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.drawsBackground = false
    scroll.documentView = table
    return scroll
}

@MainActor
private func makeServiceCell(in table: NSTableView, for item: Any, controlsEnabled: Bool) -> NSView {
    let identifier = NSUserInterfaceItemIdentifier("ServiceCell")
    let cell =
        table.makeView(withIdentifier: identifier, owner: nil) as? BackgroundServiceCell ?? BackgroundServiceCell()
    cell.identifier = identifier
    cell.configure(item: item, showsDetails: true)
    cell.controlsEnabled = controlsEnabled
    return cell
}

@MainActor
private func setControlsEnabled(_ enabled: Bool, in table: NSTableView) {
    for row in 0..<table.numberOfRows {
        (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? BackgroundServiceCell)?.controlsEnabled = enabled
    }
}
