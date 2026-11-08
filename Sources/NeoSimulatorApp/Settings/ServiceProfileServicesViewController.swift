import AppKit
import NeoSimulatorInspector
import NeoSimulatorKit
import NeoSimulatorManager
import ObservationBridge
import SwiftUI

/// Shows a profile's categories beside the services of the selected category, and adds and removes the categories that
/// the app adds and their services. The filter that spans both panes goes in the split view item that shows this
/// controller.
@MainActor
final class ServiceProfileServicesViewController: NSSplitViewController {
    let model: ServiceProfilesSettingsModel
    var list: BackgroundServiceListModel { model.list }
    private(set) lazy var searchAccessory = BackgroundServiceSearchAccessoryViewController(model: list)
    private lazy var categories = ServiceCategoriesViewController(model: model)
    private lazy var services = ServiceItemsViewController(model: model)

    init(model: ServiceProfilesSettingsModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

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

    override func viewDidLoad() {
        super.viewDidLoad()
        // Finish the initial pane measurement before accessory wrappers install their constraints.
        splitViewItems[0].addBottomAlignedAccessoryViewController(categories.actions)
        splitViewItems[1].addBottomAlignedAccessoryViewController(services.actions)
    }

    /// Shows `profile`'s services, whose switches change it unless it is built in.
    func show(_ profile: ServiceProfile) {
        list.setCategories(profile.categories)
        categories.controlsEnabled = profile.canEdit
        services.controlsEnabled = profile.canEdit
    }
}

/// Lists the categories that match the filter, those that the app added above the built-in ones, and selects the one
/// whose services show.
@MainActor
private final class ServiceCategoriesViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
    NSMenuDelegate
{
    private enum Row: Equatable {
        case header(String)
        case category(BackgroundServiceCategoryModel)

        var category: BackgroundServiceCategoryModel? {
            if case .category(let category) = self { category } else { nil }
        }

        static func == (lhs: Row, rhs: Row) -> Bool {
            switch (lhs, rhs) {
            case (.header(let lhs), .header(let rhs)): lhs == rhs
            case (.category(let lhs), .category(let rhs)): lhs === rhs
            default: false
            }
        }
    }

    private let model: ServiceProfilesSettingsModel
    private var list: BackgroundServiceListModel { model.list }
    private let table = NSTableView()
    private let empty = NSHostingView(rootView: ContentUnavailableView.search(text: ""))
    private var rows: [Row] = []
    private var updatingSelection = false
    private var observation: PortableObservationTracking.Token?
    let actions = NSSplitViewItemAccessoryViewController()
    private let categoryActions = NSSegmentedControl(
        images: [
            NSImage(systemSymbolName: "plus", accessibilityDescription: "New Category")!,
            NSImage(systemSymbolName: "minus", accessibilityDescription: "Delete Category")!,
        ], trackingMode: .momentary, target: nil, action: nil)
    var controlsEnabled = true {
        didSet {
            guard controlsEnabled != oldValue else { return }
            setControlsEnabled(controlsEnabled, in: table)
        }
    }

    init(model: ServiceProfilesSettingsModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        // The split view item takes the accessory before this pane loads.
        categoryActions.target = self
        categoryActions.action = #selector(performCategoryAction(_:))
        actions.view = makeActionsView(categoryActions)
        actions.preferredScrollEdgeEffectStyle = .hard
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let scroll = makeServiceScrollView(for: table, accessibilityLabel: "Service Categories")
        table.rowHeight = 62
        table.dataSource = self
        table.delegate = self
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        empty.sizingOptions = []
        view = NSView()
        fill(view, with: [scroll, empty])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observation = withPortableContinuousObservation { [weak self] _ in
            self?.update()
        }
    }

    private func update() {
        let sections = list.sections
        let custom = sections.filter { $0.category.isCustom }.map { Row.category($0.category) }
        let builtIn = sections.filter { !$0.category.isCustom }.map { Row.category($0.category) }
        var shown = builtIn
        // Headers name the groups only while categories that the app added show.
        if !custom.isEmpty {
            shown = [Row.header("Custom")] + custom + (builtIn.isEmpty ? [] : [Row.header("Built-in")] + builtIn)
        }
        if shown != rows {
            rows = shown
            table.reloadData()
        }
        let selected = list.selectedSection.flatMap { section in
            rows.firstIndex { $0.category === section.category }
        }
        updatingSelection = true
        table.selectRowIndexes(selected.map { IndexSet(integer: $0) } ?? [], byExtendingSelection: false)
        updatingSelection = false
        if rows.isEmpty {
            empty.rootView = ContentUnavailableView.search(text: list.query)
        }
        empty.isHidden = !rows.isEmpty
        categoryActions.setEnabled(model.canEditCategories, forSegment: 0)
        categoryActions.setEnabled(model.selectedCustomCategory != nil, forSegment: 1)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { rows[row].category == nil }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { rows[row].category != nil }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        rows[row].category == nil ? 28 : tableView.rowHeight
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            let identifier = NSUserInterfaceItemIdentifier("ServiceCategoryGroup")
            let cell =
                tableView.makeView(withIdentifier: identifier, owner: nil) as? ServiceGroupCell ?? ServiceGroupCell()
            cell.identifier = identifier
            cell.textField?.stringValue = title
            return cell
        case .category(let category):
            return makeServiceCell(in: tableView, for: category, controlsEnabled: controlsEnabled)
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updatingSelection, rows.indices.contains(table.selectedRow),
            let category = rows[table.selectedRow].category
        else { return }
        list.selectedCategoryID = category.id
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard rows.indices.contains(table.clickedRow), let category = rows[table.clickedRow].category,
            category.isCustom
        else { return }
        let rename = NSMenuItem(title: "Rename…", action: #selector(renameCategory(_:)), keyEquivalent: "")
        rename.target = self
        rename.representedObject = category
        menu.addItem(rename)
        menu.addItem(.separator())
        let delete = NSMenuItem(title: "Delete", action: #selector(deleteCategory(_:)), keyEquivalent: "")
        delete.target = self
        delete.representedObject = category
        menu.addItem(delete)
    }

    @objc private func performCategoryAction(_ sender: NSSegmentedControl) {
        guard let window = view.window else { return }
        switch sender.selectedSegment {
        case 0:
            requestText(
                in: window, title: "New Category",
                message: "Every profile lists the category, and turns its services on and off.",
                value: model.newCategoryName, confirm: "Add"
            ) { [model] in try model.addCategory(named: $0) }
        case 1:
            if let category = model.selectedCustomCategory { confirmDeletion(of: category) }
        default: break
        }
    }

    @objc private func renameCategory(_ sender: NSMenuItem) {
        guard let window = view.window, let category = sender.representedObject as? BackgroundServiceCategoryModel
        else { return }
        requestText(
            in: window, title: "Rename Category", message: "", value: category.category.name, confirm: "Rename"
        ) { [model] in try model.renameCategory(category, to: $0) }
    }

    @objc private func deleteCategory(_ sender: NSMenuItem) {
        if let category = sender.representedObject as? BackgroundServiceCategoryModel { confirmDeletion(of: category) }
    }

    private func confirmDeletion(of category: BackgroundServiceCategoryModel) {
        guard let window = view.window else { return }
        confirmRemoval(
            in: window, title: "Delete “\(category.category.name)”?",
            message: "Every profile loses the category. " + removedServicesConsequence, confirm: "Delete"
        ) { [model] in try model.deleteCategory(category) }
    }
}

/// Lists the selected category's services that match the filter, and adds services to a category that the app added.
@MainActor
private final class ServiceItemsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
    NSMenuDelegate
{
    private let model: ServiceProfilesSettingsModel
    private var list: BackgroundServiceListModel { model.list }
    private let table = NSTableView()
    private let empty = NSHostingView(rootView: ServicesUnavailable())
    private var items: [BackgroundServiceItem] = []
    private var observation: PortableObservationTracking.Token?
    let actions = NSSplitViewItemAccessoryViewController()
    private let serviceActions = NSSegmentedControl(
        images: [NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Service")!],
        trackingMode: .momentary, target: nil, action: nil)
    var controlsEnabled = true {
        didSet {
            guard controlsEnabled != oldValue else { return }
            setControlsEnabled(controlsEnabled, in: table)
        }
    }

    init(model: ServiceProfilesSettingsModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        // The split view item takes the accessory before this pane loads.
        serviceActions.target = self
        serviceActions.action = #selector(addService(_:))
        actions.view = makeActionsView(serviceActions)
        actions.preferredScrollEdgeEffectStyle = .hard
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let scroll = makeServiceScrollView(for: table, accessibilityLabel: "Services")
        table.rowHeight = 48
        table.selectionHighlightStyle = .none
        table.dataSource = self
        table.delegate = self
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        empty.sizingOptions = []
        view = NSView()
        fill(view, with: [scroll, empty])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observation = withPortableContinuousObservation { [weak self] _ in
            self?.update()
        }
    }

    private func update() {
        let section = list.selectedSection
        let shown = section?.items ?? []
        serviceActions.setEnabled(model.selectedCustomCategory != nil, forSegment: 0)
        // Only a category that the app added can have no services, until one is added to it.
        empty.isHidden = section == nil || !shown.isEmpty
        guard shown.map(ObjectIdentifier.init) != items.map(ObjectIdentifier.init) else { return }
        items = shown
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        makeServiceCell(in: tableView, for: items[row], controlsEnabled: controlsEnabled)
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard items.indices.contains(table.clickedRow), model.selectedCustomCategory != nil else { return }
        let remove = NSMenuItem(title: "Remove from Category", action: #selector(removeService(_:)), keyEquivalent: "")
        remove.target = self
        remove.representedObject = items[table.clickedRow]
        menu.addItem(remove)
    }

    @objc private func addService(_ sender: NSSegmentedControl) {
        guard let category = model.selectedCustomCategory, let window = view.window else { return }
        requestText(
            in: window, title: "Add a Service to “\(category.category.name)”",
            message: "Enter the launchd label of a service in the simulator, such as com.example.agent.",
            value: "", confirm: "Add"
        ) { [model] in try model.addService($0) }
    }

    @objc private func removeService(_ sender: NSMenuItem) {
        guard let service = sender.representedObject as? BackgroundServiceItem,
            let category = model.selectedCustomCategory, let window = view.window
        else { return }
        confirmRemoval(
            in: window, title: "Remove “\(service.label)” from “\(category.category.name)”?",
            message: removedServicesConsequence, confirm: "Remove"
        ) { [model] in try model.removeService(service, from: category) }
    }
}

private struct ServicesUnavailable: View {
    var body: some View {
        ContentUnavailableView(
            "No Services", systemImage: "gearshape.2",
            description: Text("Add the launchd label of a service that this category turns on and off."))
    }
}

/// What removing services from the categories leaves, which a confirmation explains.
private let removedServicesConsequence =
    "A service that no other category lists leaves every profile. Simulators keep their current services, so one "
    + "that is off stays off."

@MainActor
private final class ServiceGroupCell: NSTableCellView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
}

/// Asks for a line of text in a sheet, and passes what was entered to `commit` unless the sheet is cancelled. A failure
/// shows its description.
@MainActor
private func requestText(
    in window: NSWindow, title: String, message: String, value: String, confirm: String,
    commit: @escaping @MainActor (String) throws -> Void
) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    let field = NSTextField(string: value)
    field.frame = NSRect(x: 0, y: 0, width: 300, height: 22)
    alert.accessoryView = field
    alert.addButton(withTitle: confirm)
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = field
    alert.beginSheetModal(for: window) { response in
        guard response == .alertFirstButtonReturn else { return }
        do { try commit(field.stringValue) } catch { NSAlert(error: error).beginSheetModal(for: window) }
    }
}

/// Confirms a removal that every profile takes, and shows why it failed if it does.
@MainActor
private func confirmRemoval(
    in window: NSWindow, title: String, message: String, confirm: String, remove: @escaping @MainActor () throws -> Void
) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: confirm).hasDestructiveAction = true
    alert.addButton(withTitle: "Cancel")
    alert.beginSheetModal(for: window) { response in
        guard response == .alertFirstButtonReturn else { return }
        do { try remove() } catch { NSAlert(error: error).beginSheetModal(for: window) }
    }
}

@MainActor
private func makeActionsView(_ control: NSSegmentedControl) -> NSView {
    control.segmentStyle = .smallSquare
    let controls = NSStackView(views: [control, NSView()])
    controls.frame.size = NSSize(width: 180, height: controls.fittingSize.height)
    return controls
}

@MainActor
private func fill(_ view: NSView, with children: [NSView]) {
    for child in children {
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
