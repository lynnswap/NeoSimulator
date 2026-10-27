import AppKit
import SwiftUI
import Observation
@_spi(NeoSimulator) import XcodeSimulatorHost

@MainActor
final class ManagerWindowController: NSWindowController, NSOutlineViewDataSource, NSOutlineViewDelegate,
                                     NSSearchFieldDelegate, NSToolbarDelegate, NSToolbarItemValidation, NSMenuDelegate {
    private let model: SimulatorManagerModel
    private let splitController = NSSplitViewController()
    private let table = NSOutlineView()
    private let search = NSSearchField()
    private let deviceImage = NSImageView()
    private let artworkCache = DeviceArtworkCache()
    private var previewTask: Task<Void, Never>?
    private var previewArtwork: DeviceArtworkModel?
    var isDeviceActivated: (DeviceInventoryID) -> Bool = { _ in false }
    var preferredArtworkXcodeURL: () -> URL? = { nil }
    private let deviceName = NSTextField(labelWithString: "Select a Device")
    private let deviceRuntime = NSTextField(labelWithString: "")
    private let viewScreen = NSButton(title: "View Screen", target: nil, action: nil)
    let liveScreenContainer = NSViewController()
    private(set) var liveDeviceIdentifier: DeviceInventoryID?
    var onShowCompactWindow: ((DeviceInventoryID) -> Void)?
    var onSelectionChange: ((DeviceInventoryID?) -> Void)?
    var onScreenAction: ((String) -> Void)?
    weak var activeScreenCommandTarget: NSResponder?
    private var selectionIdentifier: DeviceInventoryID?
    private var previewStack: NSStackView?
    private let compactIdentifier = NSToolbarItem.Identifier("CompactDeviceWindow")
    private let resizeAppIdentifier = NSToolbarItem.Identifier("resizeApp")
    private let captureKeyboardIdentifier = NSToolbarItem.Identifier("captureKeyboard")
    private let canvasZoomIdentifier = NSToolbarItem.Identifier("CanvasZoom")
    private let moreIdentifier = NSToolbarItem.Identifier("CanvasMoreActions")
    private var moreItem: NSMenuToolbarItem?
    private let deviceFooter = NSStackView()
    private let activityStack = NSStackView()
    private var canvasBottomToPane: NSLayoutConstraint?
    private var canvasBottomToFooter: NSLayoutConstraint?
    private let activity = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private var inspectorHost: NSHostingController<ManagerDeviceSettingsView>?
    private let inspectorContainer = NSViewController()
    private lazy var deviceInspector = ManagerDeviceInspectorController(model: model)
    private var inspectorMode = 0
    private let inspectorIdentifier = NSToolbarItem.Identifier("DeviceInspector")
    private var updatingSelection = false
    private var rows: [DeviceRow] = []
    private var rowsByID: [DeviceInventoryID: DeviceRow] = [:]
    private var devicesByID: [DeviceInventoryID: InventoryDevice] = [:]
    private var availableRows: [DeviceRow] = []
    private var unavailableRows: [DeviceRow] = []
    private var displayedManagingIDs: Set<DeviceInventoryID> = []
    private var selectedIdentifiers = Set<DeviceInventoryID>()
    private let availableGroup = AvailabilityGroup(available: true)
    private let unavailableGroup = AvailabilityGroup(available: false)
    private var expandedGroups: Set<Bool> = [true, false]
    private var loadedRows = false
    private var displayedGrouping = false
    private var displayedGroups: [Bool] = []
    private var groupByAvailability = true
    private let deviceMenu = NSMenu(title: "Device Actions")
    private var sidebarObservation: NSKeyValueObservation?
    private var toolbarAppearanceObservation: NSKeyValueObservation?
    private let newSimulatorIdentifier = NSToolbarItem.Identifier("NewSimulator")
    private let filterIdentifier = NSToolbarItem.Identifier("FilterSimulators")
    private var filterItem: NSMenuToolbarItem?
    private var kindFilter = DeviceKindFilter.all
    private var availabilityFilter = DeviceAvailabilityFilter.all
    private var familyFilter: String?
    private var sortOrder = DeviceSortOrder.name

    private final class DeviceRow: NSObject {
        let id: DeviceInventoryID
        init(id: DeviceInventoryID) { self.id = id }
    }

    private final class AvailabilityGroup: NSObject {
        let available: Bool
        var title: String { available ? "Available" : "Unavailable" }
        init(available: Bool) { self.available = available }
    }

    private enum DeviceKindFilter: Int, CaseIterable {
        case all, simulators, physical, virtualMachines

        var title: String {
            switch self {
            case .all: "All Devices"
            case .simulators: "Simulators"
            case .physical: "Physical Devices"
            case .virtualMachines: "Virtual Machines"
            }
        }

        func includes(_ device: InventoryDevice) -> Bool {
            switch self {
            case .all: true
            case .simulators: device.kind == .simulator
            case .physical: device.kind == .physical
            case .virtualMachines: device.kind == .virtualMachine
            }
        }
    }

    private enum DeviceAvailabilityFilter: Int, CaseIterable {
        case all, available, unavailable

        var title: String {
            switch self {
            case .all: "All Availability"
            case .available: "Available"
            case .unavailable: "Unavailable"
            }
        }

        func includes(_ device: InventoryDevice) -> Bool {
            switch self {
            case .all: true
            case .available: device.isAvailable
            case .unavailable: !device.isAvailable
            }
        }
    }

    private enum DeviceSortOrder: Int, CaseIterable {
        case availability, recent, name, fidelity, platform, operatingSystem

        var title: String {
            switch self {
            case .availability: "Availability"
            case .recent: "Recent"
            case .name: "Name"
            case .fidelity: "Fidelity"
            case .platform: "Platform"
            case .operatingSystem: "Operating System"
            }
        }
    }

    init(model: SimulatorManagerModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "NeoSimulator"
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.toolbarStyle = .unified
        super.init(window: window)
        buildSidebar()
        buildDevicePane()
        buildInspector()
        splitController.view.heightAnchor.constraint(greaterThanOrEqualToConstant: 480).isActive = true
        window.contentViewController = splitController
        let toolbar = NSToolbar(identifier: "NeoSimulatorDevices")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        toolbarAppearanceObservation = window.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.updateToolbarAppearance() }
        }
        sidebarObservation = splitController.splitViewItems[0].observe(\.isCollapsed, options: [.initial, .new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.updateSidebarToolbarItems() }
        }
        window.center()
        window.setFrameAutosaveName("NeoSimulatorDevices")
        update()
        observeInventory()
        observeActivity()
        observeManagement()
    }

    required init?(coder: NSCoder) { nil }

    func update() {
        selectedIdentifiers.formIntersection(Set(model.inventory.map(\.id)))
        if groupByAvailability, loadedRows {
            for group in availabilityGroups where table.row(forItem: group) >= 0 {
                if table.isItemExpanded(group) { expandedGroups.insert(group.available) }
                else { expandedGroups.remove(group.available) }
            }
        }
        updatingSelection = true
        reloadRows()
        if groupByAvailability {
            for group in availabilityGroups where expandedGroups.contains(group.available) { table.expandItem(group) }
        }
        restoreVisibleSelection()
        updatingSelection = false
        loadedRows = true
        updateSelection()
        updateFilterItem()
        updateActivity()
    }

    private func observeInventory() {
        withObservationTracking { _ = model.inventory } onChange: { [weak self] in
            Task { @MainActor in
                self?.update()
                self?.observeInventory()
            }
        }
    }

    private func observeActivity() {
        withObservationTracking { updateActivity() } onChange: { [weak self] in
            Task { @MainActor in self?.observeActivity() }
        }
    }

    private func observeManagement() {
        displayedManagingIDs = model.managingDeviceIDs
        withObservationTracking {
            _ = model.managingDeviceIDs
            _ = model.isBusy
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let changed = self.displayedManagingIDs.symmetricDifference(self.model.managingDeviceIDs)
                self.displayedManagingIDs = self.model.managingDeviceIDs
                for identifier in changed {
                    if let row = self.rowsByID[identifier] { self.table.reloadItem(row) }
                }
                let selection = self.selectedDevices
                self.viewScreen.isEnabled = selection.count == 1 && selection.first.map(self.canViewScreen) == true
                self.updateDeviceSettings()
                self.observeManagement()
            }
        }
    }

    private func updateActivity() {
        activity.stringValue = model.isBusy ? model.activity : (model.backgroundIssue ?? "")
        activity.toolTip = activity.stringValue
        activity.isHidden = activity.stringValue.isEmpty
        progress.isHidden = !model.isBusy
        if model.isBusy { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        activityStack.isHidden = activity.isHidden && progress.isHidden
        updateDeviceFooter()
    }

    private func updateDeviceFooter() {
        deviceFooter.isHidden = activityStack.isHidden
        let showsFooter = !deviceFooter.isHidden
        if canvasBottomToFooter?.isActive != showsFooter {
            (showsFooter ? canvasBottomToPane : canvasBottomToFooter)?.isActive = false
            (showsFooter ? canvasBottomToFooter : canvasBottomToPane)?.isActive = true
        }
    }

    private var filteredDevices: [InventoryDevice] {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.inventory.filter {
            kindFilter.includes($0) && availabilityFilter.includes($0)
                && (familyFilter == nil || family(of: $0) == familyFilter)
                && (query.isEmpty || $0.name.localizedStandardContains(query)
                    || ($0.operatingSystem?.localizedStandardContains(query) ?? false)
                    || (modelName(of: $0)?.localizedStandardContains(query) ?? false))
        }.sorted(by: precedes)
    }

    private func precedes(_ lhs: InventoryDevice, _ rhs: InventoryDevice) -> Bool {
        switch sortOrder {
        case .availability:
            if lhs.isAvailable != rhs.isAvailable { return lhs.isAvailable }
        case .recent:
            let a = lhs.lastActivityDate ?? .distantPast, b = rhs.lastActivityDate ?? .distantPast
            if a != b { return a > b }
        case .fidelity:
            let a = fidelity(of: lhs), b = fidelity(of: rhs)
            if a != b { return a < b }
        case .platform:
            let order = platform(of: lhs).localizedStandardCompare(platform(of: rhs))
            if order != .orderedSame { return order == .orderedAscending }
        case .operatingSystem:
            let order = (lhs.operatingSystem ?? "").compare(rhs.operatingSystem ?? "", options: .numeric)
            if order != .orderedSame { return order == .orderedDescending }
        case .name: break
        }
        let names = lhs.name.localizedStandardCompare(rhs.name)
        if names != .orderedSame { return names == .orderedAscending }
        let versions = version(of: lhs).compare(version(of: rhs), options: .numeric)
        if versions != .orderedSame { return versions == .orderedDescending }
        return stableKey(lhs.id) < stableKey(rhs.id)
    }

    private var availabilityGroups: [AvailabilityGroup] {
        [availableGroup, unavailableGroup].filter { group in
            switch availabilityFilter {
            case .all: true
            case .available: group.available
            case .unavailable: !group.available
            }
        }
    }

    private func device(for row: DeviceRow) -> InventoryDevice? { devicesByID[row.id] }

    private func children(of group: AvailabilityGroup) -> [DeviceRow] {
        group.available ? availableRows : unavailableRows
    }

    private func reloadRows() {
        let previousDevices = devicesByID
        let previousRows = rows.map(\.id)
        let previousAvailable = availableRows.map(\.id)
        let previousUnavailable = unavailableRows.map(\.id)
        rebuildRows()
        let groups = availabilityGroups.map(\.available)
        let sameStructure = loadedRows && displayedGrouping == groupByAvailability
            && previousRows == rows.map(\.id)
            && (!groupByAvailability || (displayedGroups == groups
                && previousAvailable == availableRows.map(\.id)
                && previousUnavailable == unavailableRows.map(\.id)))
        if sameStructure {
            for row in rows where previousDevices[row.id] != devicesByID[row.id] { table.reloadItem(row) }
        } else { table.reloadData() }
        displayedGrouping = groupByAvailability
        displayedGroups = groups
    }

    private func rebuildRows() {
        devicesByID = Dictionary(model.inventory.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        rowsByID = rowsByID.filter { devicesByID[$0.key] != nil }
        rows = filteredDevices.map { device in
            if let row = rowsByID[device.id] { return row }
            let row = DeviceRow(id: device.id)
            rowsByID[device.id] = row
            return row
        }
        availableRows = rows.filter { devicesByID[$0.id]?.isAvailable == true }
        unavailableRows = rows.filter { devicesByID[$0.id]?.isAvailable == false }
    }

    private func restoreVisibleSelection() {
        let indexes = IndexSet((0..<table.numberOfRows).filter { index in
            (table.item(atRow: index) as? DeviceRow).map { selectedIdentifiers.contains($0.id) } ?? false
        })
        table.selectRowIndexes(indexes, byExtendingSelection: false)
    }

    private func buildSidebar() {
        let controller = NSViewController()
        search.placeholderString = "Search Devices"
        search.delegate = self
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Device"))
        table.addTableColumn(column)
        table.outlineTableColumn = column
        table.headerView = nil
        table.style = .sourceList
        table.rowHeight = 52
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelectedDevice(_:))
        table.setAccessibilityLabel("Devices")
        deviceMenu.delegate = self
        deviceMenu.autoenablesItems = false
        table.menu = deviceMenu
        scroll.documentView = table
        controller.view = scroll
        let sidebar = NSSplitViewItem(sidebarWithViewController: controller)
        sidebar.minimumThickness = 260
        sidebar.maximumThickness = 360
        sidebar.preferredThicknessFraction = 0.26
        let searchAccessory = NSSplitViewItemAccessoryViewController()
        searchAccessory.automaticallyAppliesContentInsets = false
        searchAccessory.preferredScrollEdgeEffectStyle = .soft
        let searchContainer = NSStackView(views: [search])
        searchContainer.orientation = .vertical
        searchContainer.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        search.widthAnchor.constraint(equalTo: searchContainer.widthAnchor, constant: -24).isActive = true
        searchContainer.frame.size = NSSize(width: 260, height: search.fittingSize.height + 20)
        searchAccessory.view = searchContainer
        sidebar.addTopAlignedAccessoryViewController(searchAccessory)
        splitController.addSplitViewItem(sidebar)
    }

    private func buildDevicePane() {
        let controller = NSViewController()
        let view = NSView()
        controller.view = view
        liveScreenContainer.view = NSView()
        controller.addChild(liveScreenContainer)
        let liveView = liveScreenContainer.view
        liveView.translatesAutoresizingMaskIntoConstraints = false
        liveView.isHidden = true
        view.addSubview(liveView)
        canvasBottomToPane = liveView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        canvasBottomToFooter = liveView.bottomAnchor.constraint(equalTo: deviceFooter.topAnchor, constant: -12)
        NSLayoutConstraint.activate([
            liveView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            liveView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            liveView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
        ])
        canvasBottomToPane?.isActive = true
        deviceImage.imageScaling = .scaleProportionallyUpOrDown
        deviceImage.translatesAutoresizingMaskIntoConstraints = false
        deviceImage.setAccessibilityHidden(true)
        deviceName.font = .systemFont(ofSize: 17, weight: .semibold)
        deviceName.alignment = .center
        deviceName.lineBreakMode = .byTruncatingTail
        deviceRuntime.font = .systemFont(ofSize: 13)
        deviceRuntime.textColor = .secondaryLabelColor
        deviceRuntime.alignment = .center
        deviceRuntime.lineBreakMode = .byTruncatingTail
        viewScreen.bezelStyle = .rounded
        viewScreen.controlSize = .large
        viewScreen.image = NSImage(systemSymbolName: "rectangle.badge.person.crop", accessibilityDescription: nil)
        viewScreen.imagePosition = .imageLeading
        viewScreen.target = self
        viewScreen.action = #selector(openSelectedDevice(_:))
        let stack = NSStackView(views: [deviceImage, deviceName, deviceRuntime, viewScreen])
        previewStack = stack
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(24, after: deviceImage)
        stack.setCustomSpacing(20, after: deviceRuntime)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        activity.font = .systemFont(ofSize: 12)
        activity.textColor = .secondaryLabelColor
        activity.lineBreakMode = .byTruncatingTail
        activityStack.addArrangedSubview(progress)
        activityStack.addArrangedSubview(activity)
        activityStack.orientation = .horizontal
        activityStack.alignment = .centerY
        activityStack.spacing = 7
        activityStack.isHidden = true
        deviceFooter.orientation = .vertical
        deviceFooter.alignment = .centerX
        deviceFooter.spacing = 8
        deviceFooter.translatesAutoresizingMaskIntoConstraints = false
        deviceFooter.addArrangedSubview(activityStack)
        deviceFooter.isHidden = true
        view.addSubview(deviceFooter)
        NSLayoutConstraint.activate([
            deviceImage.widthAnchor.constraint(equalToConstant: 192),
            deviceImage.heightAnchor.constraint(equalToConstant: 192),
            viewScreen.widthAnchor.constraint(greaterThanOrEqualToConstant: 112),
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -24),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
            deviceName.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            deviceRuntime.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            deviceFooter.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            deviceFooter.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            deviceFooter.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            deviceFooter.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
        ])
        let content = NSSplitViewItem(viewController: controller)
        content.minimumThickness = 280
        content.holdingPriority = .defaultLow
        splitController.addSplitViewItem(content)
    }

    private func buildInspector() {
        let host = NSHostingController(rootView: makeDeviceSettingsView())
        // AppKit owns the pane size; content-derived bounds must not constrain the window.
        host.sizingOptions = []
        inspectorHost = host
        inspectorContainer.view = NSView()
        let inspector = NSSplitViewItem(inspectorWithViewController: inspectorContainer)
        inspector.minimumThickness = 280
        inspector.maximumThickness = 440
        inspector.canCollapse = false
        splitController.addSplitViewItem(inspector)
        showInspectorController(host)
    }

    private func showInspectorController(_ controller: NSViewController) {
        guard inspectorContainer.children.first !== controller else { return }
        for child in inspectorContainer.children {
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
        inspectorContainer.addChild(controller)
        let view = controller.view
        view.translatesAutoresizingMaskIntoConstraints = false
        inspectorContainer.view.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: inspectorContainer.view.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: inspectorContainer.view.trailingAnchor),
            view.topAnchor.constraint(equalTo: inspectorContainer.view.topAnchor),
            view.bottomAnchor.constraint(equalTo: inspectorContainer.view.bottomAnchor),
        ])
    }

    @objc private func changeInspector(_ sender: NSToolbarItemGroup) {
        inspectorMode = sender.selectedIndex
        if inspectorMode == 0, let inspectorHost { showInspectorController(inspectorHost) }
        else {
            deviceInspector.setPage(inspectorMode == 1 ? .content : .info)
            showInspectorController(deviceInspector)
        }
        updateDeviceSettings()
    }

    func stopInspectorReads() { deviceInspector.stopReading() }
    func finishInspectorPreviews() async throws { try await deviceInspector.finishPreviews() }
    func resumeInspectorAfterCancelledQuit() { deviceInspector.resumeAfterCancelledQuit() }

    private func makeDeviceSettingsView() -> ManagerDeviceSettingsView {
        ManagerDeviceSettingsView(manager: model, model: model.settings, customLocation: { [weak self] in
            guard let self, let identifier = self.model.settings.device?.id else { return }
            self.presentLocationEditor(for: identifier)
        })
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let group = item as? AvailabilityGroup { return children(of: group).count }
        return item == nil ? (groupByAvailability ? availabilityGroups.count : rows.count) : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let group = item as? AvailabilityGroup { return children(of: group)[index] }
        return groupByAvailability ? availabilityGroups[index] as Any : rows[index] as Any
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { item is AvailabilityGroup }
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { item is AvailabilityGroup }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { item is DeviceRow }
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        item is AvailabilityGroup ? 26 : 52
    }

    func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
        guard let row = item as? DeviceRow else { return nil }
        return device(for: row)?.name
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        guard item is DeviceRow else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("DeviceSelectionRow")
        let row = outlineView.makeView(withIdentifier: identifier, owner: self) as? SimulatorSidebarRowView
            ?? SimulatorSidebarRowView()
        row.identifier = identifier
        return row
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let group = item as? AvailabilityGroup {
            let identifier = NSUserInterfaceItemIdentifier("DeviceAvailabilityGroup")
            let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
            cell.identifier = identifier
            if cell.textField == nil {
                let label = NSTextField(labelWithString: "")
                label.font = .systemFont(ofSize: 11, weight: .semibold)
                label.textColor = .secondaryLabelColor
                label.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(label)
                cell.textField = label
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
                    label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }
            cell.textField?.stringValue = group.title
            return cell
        }
        guard let row = item as? DeviceRow, let device = device(for: row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("DeviceRow")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? SimulatorSidebarCellView
            ?? SimulatorSidebarCellView()
        cell.identifier = identifier
        cell.setLabels(name: device.name, subtitle: device.kind == .simulator ? "Simulator" : (modelName(of: device) ?? ""))
        cell.version.stringValue = version(of: device)
        cell.setArtwork(artwork(for: device), isActive: shouldRenderAsActive(device))
        let managing = model.managingDeviceIDs.contains(device.id)
        cell.progress.isHidden = !managing
        if managing { cell.progress.startAnimation(nil) } else { cell.progress.stopAnimation(nil) }
        cell.setAccessibilityLabel("\(device.name), \(device.operatingSystem ?? kindTitle(device)), \(device.isAvailable ? "Available" : "Unavailable")")
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !updatingSelection else { return }
        selectedIdentifiers = Set(table.selectedRowIndexes.compactMap { (table.item(atRow: $0) as? DeviceRow)?.id })
        updateSelection()
    }

    func controlTextDidChange(_ notification: Notification) { update() }

    private var selectedDevices: [InventoryDevice] {
        model.inventory.filter { selectedIdentifiers.contains($0.id) }.sorted(by: precedes)
    }

    private var visibleSelectedDevices: [InventoryDevice] {
        let identifiers = Set(table.selectedRowIndexes.compactMap { (table.item(atRow: $0) as? DeviceRow)?.id })
        return model.inventory.filter { identifiers.contains($0.id) }.sorted(by: precedes)
    }

    private var selectedSimulator: SimulatorHostDevice? {
        guard selectedDevices.count == 1, case .simulator(let device) = selectedDevices[0] else { return nil }
        return device
    }

    private func updateSelection() {
        let selections = selectedDevices
        let selectedDevice = selections.count == 1 ? selections.first : nil
        window?.title = selectedDevice?.name ?? "NeoSimulator"
        window?.subtitle = selectedDevice?.operatingSystem ?? ""
        let identifier = selectedDevice?.id
        moreItem?.isHidden = selectedDevice == nil
        if identifier != selectionIdentifier {
            selectionIdentifier = identifier
            onSelectionChange?(identifier)
        }
        if selectedDevice == nil {
            previewTask?.cancel()
            previewTask = nil
            previewArtwork = nil
        }
        if let device = selectedDevice {
            deviceName.stringValue = device.name
            if case .simulator(let simulator) = device { deviceRuntime.stringValue = "\(simulator.runtimeName) Simulator" }
            else {
                deviceRuntime.stringValue = [device.operatingSystem, modelName(of: device), kindTitle(device)]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            }
            let artwork = artwork(for: device)
            if previewArtwork !== artwork {
                previewTask?.cancel()
                previewArtwork = artwork
                deviceImage.image = nil
                previewTask = Task { [weak self] in
                    let image = await artwork.hardwarePreview()
                    guard !Task.isCancelled, let self else { return }
                    self.deviceImage.image = image
                }
            }
        } else if selections.isEmpty {
            deviceName.stringValue = "Select a Device"
            deviceRuntime.stringValue = "Choose a device in the sidebar to view its details."
            deviceImage.image = nil
        } else {
            deviceName.stringValue = "\(selections.count) Devices"
            deviceRuntime.stringValue = "Select one device to view its details."
            deviceImage.image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: nil)
        }
        deviceImage.contentTintColor = nil
        let isShutdown = selectedSimulator?.state == "Shutdown"
        viewScreen.title = isShutdown ? "Start" : "View Screen"
        viewScreen.image = isShutdown ? nil : NSImage(systemSymbolName: "rectangle.badge.person.crop", accessibilityDescription: nil)
        viewScreen.isHidden = selections.count != 1
        viewScreen.isEnabled = selections.count == 1 && selections.first.map(canViewScreen) == true
        viewScreen.toolTip = nil
        updateDeviceSettings()
        model.settings.inspect(selectedDevice, selectionCount: selections.count)
    }

    func selectDevice(_ identifier: DeviceInventoryID) {
        selectedIdentifiers = [identifier]
        updatingSelection = true
        reloadRows()
        if groupByAvailability, rows.contains(where: { $0.id == identifier }), let device = devicesByID[identifier] {
            table.expandItem(device.isAvailable ? availableGroup : unavailableGroup)
        }
        restoreVisibleSelection()
        updatingSelection = false
        selectionIdentifier = identifier
        updateSelection()
        if let row = table.selectedRowIndexes.first { table.scrollRowToVisible(row) }
    }

    func showLiveScreen(for identifier: DeviceInventoryID) {
        liveDeviceIdentifier = identifier
        liveScreenContainer.view.isHidden = false
        previewStack?.isHidden = true
        for item in window?.toolbar?.items ?? [] where item.itemIdentifier == compactIdentifier || item.itemIdentifier == moreIdentifier {
            item.isHidden = false
        }
    }

    func showDevicePreview(ifDisplaying identifier: DeviceInventoryID) {
        guard liveDeviceIdentifier == identifier else { return }
        liveDeviceIdentifier = nil
        activeScreenCommandTarget = nil
        liveScreenContainer.view.isHidden = true
        previewStack?.isHidden = false
        for item in window?.toolbar?.items ?? [] where item.itemIdentifier == resizeAppIdentifier || item.itemIdentifier == captureKeyboardIdentifier || item.itemIdentifier == compactIdentifier || item.itemIdentifier == canvasZoomIdentifier {
            item.isHidden = true
        }
        updateDeviceFooter()
    }

    override func supplementalTarget(forAction action: Selector, sender: Any?) -> Any? {
        if let target = activeScreenCommandTarget {
            switch action {
            case #selector(RemoteDeviceWindowController.saveScreenshot(_:)),
                 #selector(RemoteDeviceWindowController.discardScreenshot(_:)),
                 #selector(RemoteDeviceWindowController.recordScreen(_:)),
                 #selector(RemoteDeviceWindowController.recordScreenTo(_:)),
                 #selector(RemoteDeviceWindowController.stopScreenRecording(_:)),
                 #selector(RemoteDeviceWindowController.saveScreenRecording(_:)),
                 #selector(RemoteDeviceWindowController.discardScreenRecording(_:)):
                if target.responds(to: action) { return target }
            default: break
            }
        }
        return super.supplementalTarget(forAction: action, sender: sender)
    }

    func updateScreenToolbar(supports: (String) -> Bool, isEnabled: (String) -> Bool,
                             resizingApp: Bool = false, capturesKeyboard: Bool = false) {
        if let item = window?.toolbar?.items.first(where: { $0.itemIdentifier == resizeAppIdentifier }) {
            item.isHidden = liveDeviceIdentifier == nil || !supports("resizeApp")
            item.isEnabled = isEnabled("resizeApp")
            item.menuFormRepresentation?.isEnabled = item.isEnabled
            item.menuFormRepresentation?.state = resizingApp ? .on : .off
            if let button = item.view as? NSButton {
                button.state = resizingApp ? .on : .off
                button.isEnabled = item.isEnabled
            }
        }
        if let item = window?.toolbar?.items.first(where: { $0.itemIdentifier == captureKeyboardIdentifier }) {
            item.isHidden = liveDeviceIdentifier == nil || !supports("captureKeyboard")
            item.isEnabled = isEnabled("captureKeyboard")
            item.menuFormRepresentation?.state = capturesKeyboard ? .on : .off
            item.menuFormRepresentation?.isEnabled = item.isEnabled
            if let button = item.view as? NSButton {
                button.state = capturesKeyboard ? .on : .off
                button.isEnabled = item.isEnabled
                button.toolTip = capturesKeyboard ? "Release Keyboard — or hold Escape for one second." : "Capture Keyboard"
            }
        }
    }

    @objc private func resizeApp(_ sender: Any?) {
        onScreenAction?("resizeApp")
    }

    @objc private func captureKeyboard(_ sender: Any?) { onScreenAction?("captureKeyboard") }
    func updateCanvasZoom(supports: (String) -> Bool, isEnabled: (String) -> Bool, isSelected: (String) -> Bool) {
        guard let group = window?.toolbar?.items.first(where: { $0.itemIdentifier == canvasZoomIdentifier }) as? NSToolbarItemGroup else { return }
        group.isHidden = liveDeviceIdentifier == nil || !supports(CanvasZoom.Action.fit.rawValue)
        for (index, action) in CanvasZoom.Action.allCases.enumerated() {
            group.subitems[index].isEnabled = isEnabled(action.rawValue)
        }
        if let selected = CanvasZoom.Action.allCases.firstIndex(where: { isSelected($0.rawValue) }) {
            group.setSelected(true, at: selected)
        } else {
            // selectOne rejects clearing its last selection, including selectedIndex = -1.
            group.selectionMode = .selectAny
            for index in group.subitems.indices { group.setSelected(false, at: index) }
            group.selectionMode = .selectOne
        }
    }

    @objc private func performCanvasZoom(_ sender: NSToolbarItemGroup) {
        guard CanvasZoom.Action.allCases.indices.contains(sender.selectedIndex) else { return }
        onScreenAction?(CanvasZoom.Action.allCases[sender.selectedIndex].rawValue)
    }

    @objc private func showCompactDeviceWindow(_ sender: Any?) {
        guard let identifier = liveDeviceIdentifier, window?.attachedSheet == nil,
              window?.styleMask.contains(.fullScreen) == false else { return }
        onShowCompactWindow?(identifier)
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        if item.itemIdentifier == moreIdentifier {
            return liveDeviceIdentifier.map { id in model.inventory.contains { $0.id == id } } == true
                && window?.attachedSheet == nil
        }
        if item.itemIdentifier == compactIdentifier {
            return liveDeviceIdentifier != nil && window?.attachedSheet == nil && window?.styleMask.contains(.fullScreen) == false
        }
        return true
    }

    func updateDeviceSettings() {
        let selection = selectedDevices.count == 1 ? selectedDevices.first : nil
        deviceInspector.update(device: selection, isManaging: selection.map { model.managingDeviceIDs.contains($0.id) } == true,
                               isVisible: inspectorMode != 0)
    }

    private func presentLocationEditor(for identifier: DeviceInventoryID, latitude: String = "0", longitude: String = "0") {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Set Location"
        alert.informativeText = "Enter a latitude and longitude for the selected device."
        alert.addButton(withTitle: "Set Location")
        alert.addButton(withTitle: "Cancel")
        let latitudeField = NSTextField(string: latitude)
        let longitudeField = NSTextField(string: longitude)
        for field in [latitudeField, longitudeField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 190).isActive = true
        }
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Latitude:"), latitudeField],
            [NSTextField(labelWithString: "Longitude:"), longitudeField],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing
        grid.frame.size = grid.fittingSize
        alert.accessoryView = grid
        alert.window.initialFirstResponder = latitudeField
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            guard let latitude = Double(latitudeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let longitude = Double(longitudeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
                  (-90...90).contains(latitude), (-180...180).contains(longitude) else {
                let invalid = NSAlert()
                invalid.messageText = "Enter valid coordinates."
                invalid.informativeText = "Latitude must be between −90 and 90. Longitude must be between −180 and 180."
                invalid.runModal()
                self.presentLocationEditor(for: identifier, latitude: latitudeField.stringValue, longitude: longitudeField.stringValue)
                return
            }
            self.model.setLocation(latitude: latitude, longitude: longitude, for: identifier)
        }
    }

    private func artwork(for device: InventoryDevice) -> DeviceArtworkModel {
        let xcodeURL: URL?
        if let preferred = preferredArtworkXcodeURL() { xcodeURL = preferred }
        else if case .simulator(let simulator) = device { xcodeURL = simulator.ownerXcodeURL }
        else { xcodeURL = nil }
        return artworkCache.artwork(modelIdentifier: device.modelIdentifier, family: family(of: device), xcodeURL: xcodeURL,
                                    resolveXcodeURLs: { [weak model] in await model?.artworkXcodeURLs(for: device) ?? [] })
    }

    func reloadDeviceArtwork() {
        for row in rows { table.reloadItem(row) }
    }

    private func shouldRenderAsActive(_ device: InventoryDevice) -> Bool {
        if isDeviceActivated(device.id) { return true }
        switch device {
        case .simulator(let simulator):
            return ["Booting", "Shutting Down"].contains(simulator.state)
        case .remote(let remote):
            return ["booting", "shuttingDown"].contains(remote.bootState ?? "")
        }
    }

    private func modelName(of device: InventoryDevice) -> String? {
        if case .remote(let remote) = device { return remote.modelName }
        return nil
    }

    private func family(of device: InventoryDevice) -> String {
        if case .simulator(let simulator) = device { return simulator.productFamily }
        let identifier = device.modelIdentifier ?? ""
        if identifier.hasPrefix("iPad") { return "iPad" }
        if identifier.hasPrefix("iPhone") { return "iPhone" }
        if identifier.hasPrefix("Watch") { return "Apple Watch" }
        if identifier.hasPrefix("AppleTV") { return "Apple TV" }
        if identifier.hasPrefix("Reality") { return "Apple Vision" }
        if platform(of: device).localizedCaseInsensitiveContains("mac") { return "Mac" }
        return platform(of: device).isEmpty ? "Other" : platform(of: device)
    }

    private func platform(of device: InventoryDevice) -> String {
        switch device {
        case .simulator(let simulator): simulator.runtimeName.split(separator: " ").first.map(String.init) ?? ""
        case .remote(let remote): remote.platform ?? ""
        }
    }

    private func version(of device: InventoryDevice) -> String {
        switch device {
        case .simulator(let simulator):
            simulator.runtimeName.split(separator: " ").first { $0.first?.isNumber == true }.map(String.init) ?? ""
        case .remote(let remote): remote.osVersion ?? ""
        }
    }

    private func kindTitle(_ device: InventoryDevice) -> String {
        switch device.kind {
        case .simulator: "Simulator"
        case .physical: "Physical"
        case .virtualMachine: "Virtual Machine"
        case .other: "Other"
        }
    }

    private func fidelity(of device: InventoryDevice) -> Int {
        switch device.kind {
        case .physical: 0
        case .virtualMachine: 1
        case .simulator: 2
        case .other: 3
        }
    }

    private func stableKey(_ identifier: DeviceInventoryID) -> String {
        switch identifier {
        case .simulator(let udid, let path): "simulator:\(udid):\(path.map { "set:\($0)" } ?? "default")"
        case .coreDevice(let identifier): "coredevice:\(identifier)"
        }
    }

    private func canViewScreen(_ device: InventoryDevice) -> Bool {
        guard !model.isBusy, !model.managingDeviceIDs.contains(device.id) else { return false }
        switch device {
        case .simulator(let simulator):
            return simulator.isAvailable && ["Booted", "Shutdown"].contains(simulator.state)
        case .remote(let remote):
            return remote.isAvailable && (remote.kind == .virtualMachine || remote.capabilities.contains("com.apple.coredevice.feature.viewdevicescreen"))
        }
    }

    @objc private func openSelectedDevice(_ sender: Any?) {
        let selection = sender is NSOutlineView ? visibleSelectedDevices : selectedDevices
        guard selection.count == 1, let device = selection.first, canViewScreen(device) else { return }
        model.openScreen(for: device)
    }

    private func updateToolbarAppearance() {
        guard let window else { return }
        // Individual toolbar items can retain their prior template tint on macOS 26.
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            for item in window.toolbar?.items ?? [] {
                if let image = item.image, image.isTemplate, let refreshed = image.copy() as? NSImage {
                    item.image = refreshed
                }
            }
        }
    }

    private func updateSidebarToolbarItems() {
        let hidden = splitController.splitViewItems[0].isCollapsed
        for item in window?.toolbar?.items ?? [] where item.itemIdentifier == newSimulatorIdentifier || item.itemIdentifier == filterIdentifier {
            item.isHidden = hidden
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .flexibleSpace, newSimulatorIdentifier, filterIdentifier, .sidebarTrackingSeparator,
         .flexibleSpace, captureKeyboardIdentifier, resizeAppIdentifier, canvasZoomIdentifier, compactIdentifier, moreIdentifier, .inspectorTrackingSeparator, inspectorIdentifier]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if itemIdentifier == resizeAppIdentifier {
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Resize App"
            item.toolTip = "Resize App"
            item.image = NSImage(systemSymbolName: "aspectratio", accessibilityDescription: item.label)
            item.target = self
            item.action = #selector(resizeApp(_:))
            let menuItem = NSMenuItem(title: item.label, action: item.action, keyEquivalent: "")
            menuItem.target = self
            item.menuFormRepresentation = menuItem
            let button = NSButton(image: item.image ?? NSImage(), target: self, action: #selector(resizeApp(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(itemIdentifier.rawValue)
            button.bezelStyle = .toolbar
            button.setButtonType(.pushOnPushOff)
            button.toolTip = item.toolTip
            button.setAccessibilityLabel(item.label)
            item.view = button
            item.autovalidates = false
            item.isHidden = liveDeviceIdentifier == nil
            return item
        }
        if itemIdentifier == captureKeyboardIdentifier {
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Capture Keyboard"
            item.toolTip = "Capture Keyboard"
            item.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Capture Keyboard")
            item.target = self
            item.action = #selector(captureKeyboard(_:))
            let menuItem = NSMenuItem(title: item.label, action: item.action, keyEquivalent: "")
            menuItem.target = self
            item.menuFormRepresentation = menuItem
            let button = NSButton(image: item.image ?? NSImage(), target: self, action: #selector(captureKeyboard(_:)))
            button.setButtonType(.pushOnPushOff)
            button.bezelStyle = .toolbar
            button.toolTip = item.toolTip
            button.setAccessibilityLabel(item.label)
            item.view = button
            item.autovalidates = false
            item.isHidden = liveDeviceIdentifier == nil
            return item
        }
        if itemIdentifier == canvasZoomIdentifier {
            let labels = ["Zoom Out", "Fit", "Physical Size", "Zoom In"]
            let symbols = ["minus.magnifyingglass", "arrowtriangles.up.right.down.left.magnifyingglass", "1.magnifyingglass", "plus.magnifyingglass"]
            let images = zip(symbols, labels).compactMap { NSImage.deviceControlSymbol(named: $0, accessibilityDescription: $1) }
            let item: NSToolbarItemGroup
            if images.count == labels.count {
                item = NSToolbarItemGroup(itemIdentifier: itemIdentifier, images: images, selectionMode: .selectOne,
                                           labels: labels, target: self, action: #selector(performCanvasZoom(_:)))
            } else {
                item = NSToolbarItemGroup(itemIdentifier: itemIdentifier, titles: labels, selectionMode: .selectOne,
                                           labels: labels, target: self, action: #selector(performCanvasZoom(_:)))
            }
            item.label = "Canvas Zoom"
            item.autovalidates = false
            for subitem in item.subitems { subitem.autovalidates = false }
            item.controlRepresentation = .expanded
            item.isHidden = liveDeviceIdentifier == nil
            return item
        }
        if itemIdentifier == moreIdentifier {
            let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "More Actions"
            item.toolTip = "More Actions"
            item.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "More Actions")
            item.showsIndicator = false
            item.menu = NSMenu(title: "Device Actions")
            item.menu.autoenablesItems = false
            item.menu.delegate = self
            item.isHidden = selectedDevices.count != 1
            moreItem = item
            return item
        }
        if itemIdentifier == compactIdentifier {
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Switch to Compact Window"
            item.toolTip = "Switch to Compact Window"
            item.image = NSImage(systemSymbolName: "arrow.up.forward.and.arrow.down.backward", accessibilityDescription: "Switch to Compact Window")
            item.target = self
            item.action = #selector(showCompactDeviceWindow(_:))
            item.isHidden = liveDeviceIdentifier == nil
            return item
        }
        if itemIdentifier == inspectorIdentifier {
            let images = ["slider.horizontal.3", "doc", "info.circle"].compactMap {
                NSImage(systemSymbolName: $0, accessibilityDescription: nil)
            }
            let item = NSToolbarItemGroup(itemIdentifier: itemIdentifier, images: images, selectionMode: .selectOne,
                                          labels: ["Settings", "Content", "Info"], target: self, action: #selector(changeInspector(_:)))
            item.label = "Device Inspector"
            item.selectedIndex = inspectorMode
            item.visibilityPriority = .high
            return item
        }
        if itemIdentifier == newSimulatorIdentifier {
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "New Simulator"
            item.toolTip = "New Simulator"
            item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Simulator")
            item.target = NSApp.delegate
            item.action = #selector(AppDelegate.showNewSimulator(_:))
            item.visibilityPriority = .high
            return item
        }
        if itemIdentifier == filterIdentifier {
            let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Filter"
            item.toolTip = "Filter and Sort Devices"
            item.showsIndicator = false
            item.visibilityPriority = .high
            item.menu = NSMenu(title: "Filter and Sort Devices")
            item.menu.delegate = self
            filterItem = item
            updateFilterItem()
            return item
        }
        return nil
    }

    private struct ManagementRequest {
        let action: DeviceManagementAction
        let identifiers: Set<DeviceInventoryID>
    }

    func menuForSelectedDevices() -> NSMenu {
        let menu = NSMenu(title: "Device")
        menu.autoenablesItems = false
        populateDeviceMenu(menu, devices: visibleSelectedDevices)
        return menu
    }

    private func updateDeviceMenu() {
        if table.clickedRow >= 0 {
            guard let row = table.item(atRow: table.clickedRow) as? DeviceRow else {
                deviceMenu.removeAllItems()
                return
            }
            if !selectedIdentifiers.contains(row.id) {
                selectedIdentifiers = [row.id]
                updatingSelection = true
                restoreVisibleSelection()
                updatingSelection = false
                updateSelection()
            }
        }
        populateDeviceMenu(deviceMenu, devices: visibleSelectedDevices)
    }

    private func populateDeviceMenu(_ menu: NSMenu, devices: [InventoryDevice], includesViewScreen: Bool = true) {
        menu.removeAllItems()
        let identifiers = Set(devices.map(\.id))
        let idle = !model.isBusy && identifiers.isDisjoint(with: model.managingDeviceIDs)
        if includesViewScreen, devices.count == 1, canViewScreen(devices[0]) {
            let item = NSMenuItem(title: "View Screen", action: #selector(openDeviceFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = devices[0].id
            item.isEnabled = idle
            menu.addItem(item)
        }
        if devices.count == 1, case .remote = devices[0], devices[0].id == liveDeviceIdentifier,
           let controller = activeScreenCommandTarget as? RemoteDeviceWindowController {
            let item = NSMenuItem(title: "Lock", action: #selector(lockDeviceFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = devices[0].id
            item.isEnabled = controller.isScreenActionEnabled("lock")
            menu.addItem(item)
        }
        let name = devices.first?.name ?? ""
        let operations: [(String, DeviceManagementAction)] = [
            ("Rename…", .rename(name)), ("Clone…", .clone("\(name) Copy")),
            ("Start", .start), ("Shut Down", .shutdown), ("Force Shut Down", .forceShutdown), ("Restart", .restart),
            ("Pause", .pause), ("Resume", .resume),
            ("Pair Simulators", .pair), ("Unpair", .unpair),
            ("Erase Content and Settings…", .erase), ("Remove…", .remove),
        ]
        for (title, action) in operations where supports(action, devices: devices) {
            if !menu.items.isEmpty, case .rename = action { menu.addItem(.separator()) }
            if case .erase = action, !menu.items.isEmpty { menu.addItem(.separator()) }
            let item = NSMenuItem(title: title, action: #selector(performManagement(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ManagementRequest(action: action, identifiers: identifiers)
            item.isEnabled = model.canManage(action, deviceIDs: identifiers)
            menu.addItem(item)
        }
        if menu.items.isEmpty {
            let item = NSMenuItem(title: devices.isEmpty ? "No Devices Selected" : "No Actions Available", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
    }

    private func updateCanvasMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        guard selectedDevices.count == 1, let device = selectedDevices.first else { return }
        // NSMenuToolbarItem's pull-down cell hides the first item as its button title.
        defer { menu.insertItem(NSMenuItem(title: "", action: nil, keyEquivalent: ""), at: 0) }
        if case .remote = device {
            populateDeviceMenu(menu, devices: [device], includesViewScreen: false)
            return
        }
        func add(_ title: String, symbol: String, action: DeviceManagementAction, alternate: Bool = false) {
            guard device.supports(action) else { return }
            let item = NSMenuItem(title: title, action: #selector(performManagement(_:)), keyEquivalent: "")
            item.target = self
            item.image = NSImage.deviceControlSymbol(named: symbol, accessibilityDescription: title)
            item.representedObject = ManagementRequest(action: action, identifiers: [device.id])
            item.isEnabled = model.canManage(action, deviceIDs: [device.id])
            item.keyEquivalentModifierMask = []
            item.isAlternate = alternate
            if alternate { item.keyEquivalentModifierMask = .option }
            menu.addItem(item)
        }
        func separate() { if !menu.items.isEmpty { menu.addItem(.separator()) } }
        add("Start", symbol: "play", action: .start)
        add("Shut Down", symbol: "power", action: .shutdown)
        add("Force Shut Down", symbol: "power", action: .forceShutdown, alternate: device.supports(.shutdown))
        if device.supports(.restart) {
            separate()
            add("Restart", symbol: "restart", action: .restart)
        }
        if device.supports(.rename(device.name)) {
            separate()
            add("Rename…", symbol: "pencil", action: .rename(device.name))
        }
        if device.supports(.erase) {
            separate()
            add("Reset Content and Settings…", symbol: "eraser", action: .erase)
        }
        if case .simulator(let phone) = device, phone.productFamily == "iPhone", device.supports(.pair) {
            separate()
            let pairing = NSMenuItem(title: "Pair Apple Watch", action: nil, keyEquivalent: "")
            pairing.image = NSImage.deviceControlSymbol(named: "iphone.and.applewatch", accessibilityDescription: pairing.title)
            let watches = model.inventory.filter { candidate in
                guard case .simulator(let watch) = candidate, watch.productFamily == "Apple Watch" else { return false }
                return supports(.pair, devices: [device, candidate])
            }.sorted(by: precedes)
            let submenu = NSMenu(title: pairing.title)
            submenu.autoenablesItems = false
            submenu.addItem(.sectionHeader(title: "Simulators"))
            for watch in watches {
                let identifiers: Set<DeviceInventoryID> = [device.id, watch.id]
                let item = NSMenuItem(title: watch.name, action: #selector(performManagement(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = ManagementRequest(action: .pair, identifiers: identifiers)
                item.isEnabled = model.canManage(.pair, deviceIDs: identifiers)
                submenu.addItem(item)
            }
            pairing.submenu = submenu
            pairing.isEnabled = !watches.isEmpty && model.canManage(.pair, deviceIDs: [device.id])
            menu.addItem(pairing)
        }
        if device.supports(.remove) {
            separate()
            add("Remove…", symbol: "trash", action: .remove)
        }
    }

    private func supports(_ action: DeviceManagementAction, devices: [InventoryDevice]) -> Bool {
        guard !devices.isEmpty, devices.allSatisfy({ $0.supports(action) }) else { return false }
        switch action {
        case .rename, .clone: return devices.count == 1
        case .pair:
            guard devices.count == 2,
                  case .simulator(let first) = devices[0], case .simulator(let second) = devices[1] else { return false }
            return Set([first.productFamily, second.productFamily]) == Set(["iPhone", "Apple Watch"])
                && first.deviceSetPath == second.deviceSetPath
        default: return true
        }
    }

    @objc private func openDeviceFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? DeviceInventoryID,
              let device = model.inventory.first(where: { $0.id == id }), canViewScreen(device) else { return }
        model.openScreen(for: device)
    }

    @objc private func lockDeviceFromMenu(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? DeviceInventoryID,
              identifier == liveDeviceIdentifier else { return }
        onScreenAction?("lock")
    }

    @objc private func performManagement(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? ManagementRequest else { return }
        let devices = model.inventory.filter { request.identifiers.contains($0.id) }
        guard devices.count == request.identifiers.count, supports(request.action, devices: devices),
              model.canManage(request.action, deviceIDs: request.identifiers) else { return }
        switch request.action {
        case .rename: presentNameEditor(for: devices[0], cloning: false)
        case .clone: presentNameEditor(for: devices[0], cloning: true)
        case .erase, .remove: confirmManagement(request.action, devices: devices)
        default: model.manage(request.action, devices: devices)
        }
    }

    private func presentNameEditor(for device: InventoryDevice, cloning: Bool) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = cloning ? "Clone \(device.name)" : "Rename \(device.name)"
        alert.informativeText = cloning ? "Enter a name for the new simulator." : "Enter a new device name."
        alert.addButton(withTitle: cloning ? "Clone" : "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: cloning ? "\(device.name) Copy" : device.name)
        field.frame.size = NSSize(width: 300, height: field.fittingSize.height)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let submit = alert.buttons[0]
        let observer = NotificationCenter.default.addObserver(forName: NSControl.textDidChangeNotification,
            object: field, queue: .main) { _ in
                MainActor.assumeIsolated { submit.isEnabled = !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            }
        alert.beginSheetModal(for: window) { [weak self] response in
            NotificationCenter.default.removeObserver(observer)
            guard response == .alertFirstButtonReturn, let self else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, let current = self.model.inventory.first(where: { $0.id == device.id }) else { return }
            self.model.manage(cloning ? .clone(name) : .rename(name), devices: [current])
        }
    }

    private func confirmManagement(_ action: DeviceManagementAction, devices: [InventoryDevice]) {
        guard let window else { return }
        let removing: Bool
        if case .remove = action { removing = true } else { removing = false }
        let subject = devices.count == 1 ? "“\(devices[0].name)”" : "\(devices.count) devices"
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = removing ? "Remove \(subject)?" : "Erase \(subject)?"
        if removing {
            alert.informativeText = devices.contains { $0.kind == .virtualMachine }
                ? "The selected devices and their stored data will be permanently removed. Removing a virtual machine also deletes its associated assets. This cannot be undone."
                : "The selected devices and their data will be permanently removed. This cannot be undone."
        } else {
            alert.informativeText = "All content and settings on the selected devices will be permanently erased. This cannot be undone."
        }
        alert.addButton(withTitle: removing ? "Remove" : "Erase")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let identifiers = Set(devices.map(\.id))
            let current = self.model.inventory.filter { identifiers.contains($0.id) }
            guard current.count == identifiers.count else { return }
            self.model.manage(action, devices: current)
        }
    }

    private func updateFilterItem() {
        let active = kindFilter != .all || availabilityFilter != .all || familyFilter != nil
        filterItem?.image = NSImage(systemSymbolName: active ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease",
                                   accessibilityDescription: active ? "Filter, active" : "Filter")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === deviceMenu { updateDeviceMenu(); return }
        if menu === moreItem?.menu { updateCanvasMenu(menu); return }
        guard menu === filterItem?.menu else { return }
        menu.removeAllItems()
        menu.addItem(.sectionHeader(title: "Devices"))
        for filter in DeviceKindFilter.allCases {
            let item = NSMenuItem(title: filter.title, action: #selector(filterKind(_:)), keyEquivalent: "")
            item.target = self
            item.tag = filter.rawValue
            item.state = kindFilter == filter ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Availability"))
        for filter in DeviceAvailabilityFilter.allCases {
            let item = NSMenuItem(title: filter.title, action: #selector(filterAvailability(_:)), keyEquivalent: "")
            item.target = self
            item.tag = filter.rawValue
            item.state = availabilityFilter == filter ? .on : .off
            menu.addItem(item)
        }
        let grouping = NSMenuItem(title: "Group by Availability", action: #selector(toggleAvailabilityGroups(_:)), keyEquivalent: "")
        grouping.target = self
        grouping.state = groupByAvailability ? .on : .off
        menu.addItem(grouping)
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Device Family"))
        let allTypes = NSMenuItem(title: "All Families", action: #selector(filterFamily(_:)), keyEquivalent: "")
        allTypes.target = self
        allTypes.state = familyFilter == nil ? .on : .off
        menu.addItem(allTypes)
        for family in Set(model.inventory.map { family(of: $0) }).sorted() {
            let item = NSMenuItem(title: family, action: #selector(filterFamily(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = family
            item.state = familyFilter == family ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Sort By"))
        for order in DeviceSortOrder.allCases {
            let item = NSMenuItem(title: order.title, action: #selector(sortDevices(_:)), keyEquivalent: "")
            item.target = self
            item.tag = order.rawValue
            item.state = sortOrder == order ? .on : .off
            menu.addItem(item)
        }
    }

    @objc private func filterKind(_ sender: NSMenuItem) {
        guard let filter = DeviceKindFilter(rawValue: sender.tag) else { return }
        kindFilter = filter
        update()
    }

    @objc private func filterAvailability(_ sender: NSMenuItem) {
        guard let filter = DeviceAvailabilityFilter(rawValue: sender.tag) else { return }
        availabilityFilter = filter
        update()
    }

    @objc private func toggleAvailabilityGroups(_ sender: Any?) {
        if groupByAvailability {
            for group in availabilityGroups {
                if table.isItemExpanded(group) { expandedGroups.insert(group.available) }
                else { expandedGroups.remove(group.available) }
            }
        }
        groupByAvailability.toggle()
        loadedRows = false
        update()
    }

    @objc private func filterFamily(_ sender: NSMenuItem) {
        familyFilter = sender.representedObject as? String
        update()
    }

    @objc private func sortDevices(_ sender: NSMenuItem) {
        guard let order = DeviceSortOrder(rawValue: sender.tag) else { return }
        sortOrder = order
        update()
    }

}
