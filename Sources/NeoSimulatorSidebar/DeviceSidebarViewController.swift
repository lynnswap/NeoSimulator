import AppKit
import NeoSimulatorDeviceScreens
import NeoSimulatorHostSupport
import NeoSimulatorKit
import NeoSimulatorManager
import ObservationBridge
import SwiftUI

/// Lists the sidebar model's devices in an outline and reports the selection made there.
@MainActor
package final class DeviceSidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate,
                                                  NSSearchFieldDelegate, NSMenuDelegate {
    package static let filterToolbarIdentifier = NSToolbarItem.Identifier("FilterSimulators")

    package let model: DeviceSidebarModel
    /// Follows a change of the selection or of the devices it names. The flag tells whether the user chose it here.
    package var onSelectionChange: ((_ byUser: Bool) -> Void)?
    /// Fills the context menu with the actions for the devices it targets.
    package var populateDeviceMenu: ((NSMenu, [InventoryDevice]) -> Void)?
    private var manager: SimulatorManagerModel { model.manager }
    private let screens: DeviceScreens
    private let artworkCache: DeviceArtworkCache
    private let table = NSOutlineView()
    private let scroll = NSScrollView()
    private let status = NSHostingView(rootView: SidebarStatusView(content: .empty))
    private let issue = NSTextField(wrappingLabelWithString: "")
    private let issueStack = NSStackView()
    private let activityStack = NSStackView()
    private let activity = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let searchAccessory = NSSplitViewItemAccessoryViewController()
    private let issueAccessory = NSSplitViewItemAccessoryViewController()
    private let search = NSSearchField()
    private let thumbnails = DeviceThumbnailStore()
    private let deviceMenu = NSMenu(title: "Device Actions")
    private let filterMenu = NSMenu(title: "Filter and Sort Devices")
    private weak var filterItem: NSToolbarItem?
    private weak var splitViewItem: NSSplitViewItem?
    private var collapseObservation: NSKeyValueObservation?
    private var notificationObservers: [any NSObjectProtocol] = []
    private var inventoryObservation: PortableObservationTracking.Token?
    private var progressObservation: PortableObservationTracking.Token?
    private var screensObservation: PortableObservationTracking.Token?
    private var statusObservation: PortableObservationTracking.Token?
    private var shownStatus: DeviceSidebarModel.Status?
    private var thumbnailRefreshScheduled = false
    private var updatingSelection = false
    private var loadedRows = false
    private var displayedGrouping = false
    private var displayedProgressIDs: Set<DeviceInventoryID> = []
    private var displayedScreenIDs: Set<DeviceInventoryID> = []
    private var displayedArtworkXcodeURL: URL?
    private var rows: [DeviceRow] = []
    private var rowsByID: [DeviceInventoryID: DeviceRow] = [:]
    private var devicesByID: [DeviceInventoryID: InventoryDevice] = [:]
    /// The values that ordered the rows; their artwork reads the same values.
    private var displayedActiveStates = DeviceActiveStates()
    private var groups: [DeviceGroup] = []
    private var groupsByID: [String: DeviceGroup] = [:]
    private typealias SortOrder = DeviceBrowserPresentation.SortOrder

    private final class DeviceRow: NSObject {
        let id: DeviceInventoryID
        init(id: DeviceInventoryID) { self.id = id }
    }

    private final class DeviceGroup: NSObject {
        let id: String
        var title: String
        var rows: [DeviceRow] = []
        init(id: String, title: String) { self.id = id; self.title = title }
    }

    package init(model: DeviceSidebarModel, screens: DeviceScreens, artworkCache: DeviceArtworkCache) {
        self.model = model
        self.screens = screens
        self.artworkCache = artworkCache
        super.init(nibName: nil, bundle: nil)
        thumbnails.onChange = { [weak self] in self?.refreshThumbnail(for: $0) }
    }

    required init?(coder: NSCoder) { nil }

    isolated deinit {
        for observer in notificationObservers { NotificationCenter.default.removeObserver(observer) }
    }

    override package func loadView() {
        view = NSView()
        search.placeholderString = "Search Devices"
        search.delegate = self
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
        scroll.contentView.postsBoundsChangedNotifications = true
        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleThumbnailRefresh() }
        })
        // Thumbnails stream only while the window shows this list.
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification] {
            notificationObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let source = (notification.object as AnyObject?).map(ObjectIdentifier.init)
                MainActor.assumeIsolated {
                    guard let self, let window = self.view.window, source == ObjectIdentifier(window) else { return }
                    self.scheduleThumbnailRefresh()
                }
            })
        }
        status.sizingOptions = []
        for child in [scroll, status] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
            NSLayoutConstraint.activate([
                child.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                child.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                child.topAnchor.constraint(equalTo: view.topAnchor),
                child.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        }
        searchAccessory.automaticallyAppliesContentInsets = false
        searchAccessory.preferredScrollEdgeEffectStyle = .soft
        let searchContainer = NSStackView(views: [search])
        searchContainer.orientation = .vertical
        searchContainer.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        search.widthAnchor.constraint(equalTo: searchContainer.widthAnchor, constant: -24).isActive = true
        searchContainer.frame.size = NSSize(width: 260, height: search.fittingSize.height + 20)
        searchAccessory.view = searchContainer
        issue.font = .systemFont(ofSize: 11)
        issue.textColor = .secondaryLabelColor
        issue.maximumNumberOfLines = 3
        issue.lineBreakMode = .byTruncatingTail
        let retry = NSButton(title: String(localized: "Try Again"), target: self, action: #selector(retryInventory(_:)))
        retry.controlSize = .small
        issueStack.orientation = .vertical
        issueStack.alignment = .leading
        issueStack.spacing = 6
        issueStack.addArrangedSubview(issue)
        issueStack.addArrangedSubview(retry)
        progress.style = .spinning
        progress.controlSize = .small
        activity.font = .systemFont(ofSize: 11)
        activity.textColor = .secondaryLabelColor
        activity.lineBreakMode = .byTruncatingTail
        activityStack.spacing = 6
        activityStack.addArrangedSubview(progress)
        activityStack.addArrangedSubview(activity)
        let feedback = NSStackView(views: [activityStack, issueStack])
        feedback.orientation = .vertical
        feedback.alignment = .leading
        feedback.spacing = 8
        feedback.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        issue.widthAnchor.constraint(equalTo: feedback.widthAnchor, constant: -24).isActive = true
        activityStack.widthAnchor.constraint(equalTo: feedback.widthAnchor, constant: -24).isActive = true
        feedback.frame.size = NSSize(width: 260, height: 80)
        issueAccessory.view = feedback
        issueAccessory.automaticallyAppliesContentInsets = false
        issueAccessory.isHidden = true
    }

    override package func viewDidLoad() {
        super.viewDidLoad()
        observeInventory()
        observeProgress()
        observeScreens()
        statusObservation = withPortableContinuousObservation { [weak self] _ in self?.updateStatus() }
    }

    package func makeSplitViewItem() -> NSSplitViewItem {
        let item = NSSplitViewItem(sidebarWithViewController: self)
        item.minimumThickness = 260
        item.maximumThickness = 360
        item.preferredThicknessFraction = 0.26
        item.addTopAlignedAccessoryViewController(searchAccessory)
        item.addBottomAlignedAccessoryViewController(issueAccessory)
        splitViewItem = item
        collapseObservation = item.observe(\.isCollapsed, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.scheduleThumbnailRefresh() }
        }
        return item
    }

    package func makeFilterToolbarItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: Self.filterToolbarIdentifier)
        item.label = "Filter"
        item.toolTip = "Filter and Sort Devices"
        item.visibilityPriority = .high
        let button = NSButton(image: NSImage(systemSymbolName: "line.3.horizontal.decrease",
                                            accessibilityDescription: "Filter and Sort Devices")!,
                              target: self, action: #selector(showDeviceFilters(_:)))
        button.bezelStyle = .toolbar
        button.controlSize = .extraLarge
        button.setButtonType(.onOff)
        button.isBordered = true
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.setAccessibilityLabel("Filter and Sort Devices")
        item.image = button.image
        item.view = button
        filterMenu.delegate = self
        let menuItem = NSMenuItem(title: "Filter and Sort Devices", action: nil, keyEquivalent: "")
        menuItem.submenu = filterMenu
        item.menuFormRepresentation = menuItem
        filterItem = item
        updateFilterItem()
        return item
    }

    /// Lists the model's devices again and keeps the selection that they still contain.
    package func update(animated: Bool = false) {
        loadViewIfNeeded()
        rememberCollapsedGroups()
        updatingSelection = true
        NSAnimationContext.runAnimationGroup { context in
            let animates = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            if !animates { context.duration = 0 }
            reloadRows(effect: animates ? .effectFade : [])
            restoreGroupExpansion()
        }
        restoreVisibleSelection()
        updatingSelection = false
        loadedRows = true
        scheduleThumbnailRefresh()
        onSelectionChange?(false)
        updateFilterItem()
        updateStatus()
    }

    /// Selects one device and reveals its row. The caller follows the new selection.
    package func select(_ identifier: DeviceInventoryID) {
        loadViewIfNeeded()
        model.select([identifier])
        updatingSelection = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            reloadRows()
        }
        if model.options.showGroups, let group = groups.first(where: { $0.rows.contains { $0.id == identifier } }) {
            model.setCollapsed(false, group: group.id)
        }
        restoreGroupExpansion()
        restoreVisibleSelection()
        updatingSelection = false
        scheduleThumbnailRefresh()
        if let row = table.selectedRowIndexes.first { table.scrollRowToVisible(row) }
    }

    /// The devices of the rows that the outline selects, which excludes those its filters hide.
    package var visibleSelectedDevices: [InventoryDevice] {
        let identifiers = Set(table.selectedRowIndexes.compactMap { (table.item(atRow: $0) as? DeviceRow)?.id })
        return rows.compactMap { device(for: $0) }.filter { identifiers.contains($0.id) }
    }

    private func observeInventory() {
        inventoryObservation = withPortableContinuousObservation { [weak self, manager] event in
            _ = manager.inventory
            _ = manager.activeStates
            guard event.kind != .initial else { return }
            Task { @MainActor [weak self] in self?.update(animated: true) }
        }
    }

    private func observeProgress() {
        displayedProgressIDs = manager.progressingDeviceIDs
        progressObservation = withPortableContinuousObservation { [weak self, manager] event in
            _ = manager.progressingDeviceIDs
            guard event.kind != .initial else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let progressIDs = self.manager.progressingDeviceIDs
                let changed = self.displayedProgressIDs.symmetricDifference(progressIDs)
                self.displayedProgressIDs = progressIDs
                for identifier in changed {
                    if let row = self.rowsByID[identifier] { self.table.reloadItem(row) }
                }
            }
        }
    }

    /// Reloads the rows whose screens opened or closed, or every row when artwork comes from another Xcode.
    private func observeScreens() {
        displayedScreenIDs = screens.identifiers
        displayedArtworkXcodeURL = screens.displayXcodeURL
        screensObservation = withPortableContinuousObservation { [weak self, screens] event in
            _ = screens.identifiers
            _ = screens.displayXcodeURL
            guard event.kind != .initial else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.displayedArtworkXcodeURL != self.screens.displayXcodeURL {
                    for row in self.rows { self.table.reloadItem(row) }
                } else {
                    for identifier in self.displayedScreenIDs.symmetricDifference(self.screens.identifiers) {
                        if let row = self.rowsByID[identifier] { self.table.reloadItem(row) }
                    }
                }
                self.displayedScreenIDs = self.screens.identifiers
                self.displayedArtworkXcodeURL = self.screens.displayXcodeURL
            }
        }
    }

    private func device(for row: DeviceRow) -> InventoryDevice? { devicesByID[row.id] }

    private func rememberCollapsedGroups() {
        guard model.options.showGroups, loadedRows else { return }
        for group in groups where table.row(forItem: group) >= 0 {
            model.setCollapsed(!table.isItemExpanded(group), group: group.id)
        }
    }

    package func outlineViewItemDidExpand(_ notification: Notification) {
        guard !updatingSelection, let group = notification.userInfo?["NSObject"] as? DeviceGroup else { return }
        model.setCollapsed(false, group: group.id)
        updatingSelection = true
        restoreVisibleSelection()
        updatingSelection = false
    }

    package func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !updatingSelection, let group = notification.userInfo?["NSObject"] as? DeviceGroup else { return }
        model.setCollapsed(true, group: group.id)
    }

    private func reloadRows(effect: NSTableView.AnimationOptions = []) {
        let previousDevices = devicesByID
        let previousActiveStates = displayedActiveStates
        let previousRoots: [NSObject] = displayedGrouping ? groups : rows
        let previousChildren = Dictionary(uniqueKeysWithValues: groups.map { ($0, $0.rows) })
        let expanded = Set(groups.filter { table.isItemExpanded($0) })
        let showGroups = model.options.showGroups
        rebuildRows()
        if loadedRows {
            let roots: [NSObject] = showGroups ? groups : rows
            // AppKit ignores child insertions and removals under a collapsed parent.
            // Replace that parent so expanding it reads the current children.
            let replaced = Set(groups.filter { previousChildren[$0] != nil
                && !expanded.contains($0) && previousChildren[$0] != $0.rows })
            table.beginUpdates()
            updateChildren(of: nil, from: previousRoots, to: roots,
                           replacing: Set(replaced.map { $0 as NSObject }), effect: effect)
            if showGroups {
                for group in groups where expanded.contains(group) {
                    updateChildren(of: group, from: previousChildren[group] ?? [], to: group.rows, effect: effect)
                }
            }
            table.endUpdates()
            for row in rows {
                guard let device = devicesByID[row.id], previousDevices[row.id] != nil else { continue }
                if previousDevices[row.id] != device
                    || previousActiveStates.isActive(device) != displayedActiveStates.isActive(device) {
                    table.reloadItem(row)
                }
            }
        } else {
            table.reloadData()
        }
        displayedGrouping = showGroups
    }

    private func updateChildren(of parent: Any?, from previous: [NSObject], to current: [NSObject],
                                replacing replaced: Set<NSObject> = [], effect: NSTableView.AnimationOptions) {
        let retained = Set(current).subtracting(replaced)
        let removed = IndexSet(previous.indices.filter { !retained.contains(previous[$0]) })
        if !removed.isEmpty { table.removeItems(at: removed, inParent: parent, withAnimation: effect) }
        var working = previous.filter { retained.contains($0) }
        for (index, item) in current.enumerated() {
            if let source = working.firstIndex(of: item) {
                if source != index {
                    table.moveItem(at: source, inParent: parent, to: index, inParent: parent)
                    working.insert(working.remove(at: source), at: index)
                }
            } else {
                table.insertItems(at: IndexSet(integer: index), inParent: parent, withAnimation: effect)
                working.insert(item, at: index)
            }
        }
    }

    private func rebuildRows() {
        devicesByID = Dictionary(manager.inventory.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        rowsByID = rowsByID.filter { devicesByID[$0.key] != nil }
        displayedActiveStates = manager.activeStates
        let presentation = DeviceBrowserPresentation(devices: model.filteredDevices, sortOrder: model.options.sortOrder,
                                                     activeStates: displayedActiveStates)
        rows = presentation.devices.map { device in
            if let row = rowsByID[device.id] { return row }
            let row = DeviceRow(id: device.id)
            rowsByID[device.id] = row
            return row
        }
        groups = presentation.sections.map { section in
            let group = groupsByID[section.id] ?? DeviceGroup(id: section.id, title: section.title)
            group.title = section.title
            group.rows = section.devices.compactMap { rowsByID[$0.id] }
            return group
        }
        groupsByID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
    }

    private func restoreGroupExpansion() {
        guard model.options.showGroups else { return }
        for group in groups where !model.collapsedGroups.contains(group.id) { table.expandItem(group) }
    }

    private func restoreVisibleSelection() {
        let selected = model.selectedIdentifiers
        let indexes = IndexSet((0..<table.numberOfRows).filter { index in
            (table.item(atRow: index) as? DeviceRow).map { selected.contains($0.id) } ?? false
        })
        table.selectRowIndexes(indexes, byExtendingSelection: false)
    }

    private func updateStatus() {
        let content = model.status
        if shownStatus != content {
            shownStatus = content
            status.rootView = SidebarStatusView(content: content, retry: { [weak self] in self?.retryInventory(nil) })
        }
        status.isHidden = !rows.isEmpty
        scroll.isHidden = rows.isEmpty
        let hasInventory = !manager.inventory.isEmpty
        let issue = manager.backgroundIssue
        self.issue.stringValue = issue ?? ""
        self.issue.toolTip = issue
        issueStack.isHidden = issue == nil
        let activity = manager.globalActivity
        self.activity.stringValue = activity ?? ""
        activityStack.isHidden = activity == nil
        if hasInventory, activity != nil { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        issueAccessory.isHidden = !hasInventory || (issue == nil && activity == nil)
    }

    @objc private func retryInventory(_ sender: Any?) { model.retryInventory() }

    package func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let group = item as? DeviceGroup { return group.rows.count }
        return item == nil ? (model.options.showGroups ? groups.count : rows.count) : 0
    }

    package func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let group = item as? DeviceGroup { return group.rows[index] }
        return model.options.showGroups ? groups[index] as Any : rows[index] as Any
    }

    package func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { item is DeviceGroup }
    package func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { item is DeviceGroup }
    package func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { item is DeviceRow }
    package func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        item is DeviceGroup ? 26 : 52
    }

    package func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
        guard let row = item as? DeviceRow else { return nil }
        return device(for: row)?.name
    }

    package func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        guard item is DeviceRow else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("DeviceSelectionRow")
        let row = outlineView.makeView(withIdentifier: identifier, owner: self) as? SimulatorSidebarRowView
            ?? SimulatorSidebarRowView()
        row.identifier = identifier
        return row
    }

    package func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let group = item as? DeviceGroup {
            let identifier = NSUserInterfaceItemIdentifier("DeviceBrowserGroup")
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
        cell.setLabels(name: device.name, subtitle: device.kind == .simulator ? "Simulator" : (device.modelName ?? ""))
        cell.version.stringValue = device.versionTitle
        cell.setArtwork(artworkCache.artwork(for: device, screens: screens, manager: manager),
                        isActive: shouldRenderAsActive(device))
        cell.setThumbnail(thumbnails.frame(for: device.id), image: thumbnails.image(for: device.id))
        let managing = manager.progressingDeviceIDs.contains(device.id)
        cell.progress.isHidden = !managing
        if managing { cell.progress.startAnimation(nil) } else { cell.progress.stopAnimation(nil) }
        cell.setAccessibilityLabel("\(device.name), \(device.operatingSystem ?? device.kindTitle), \(DeviceBrowserPresentation.isAvailable(device) ? "Available" : "Unavailable")")
        return cell
    }

    package func outlineView(_ outlineView: NSOutlineView, didAdd rowView: NSTableRowView, forRow row: Int) {
        scheduleThumbnailRefresh()
    }

    package func outlineView(_ outlineView: NSOutlineView, didRemove rowView: NSTableRowView, forRow row: Int) {
        // A reused row must not carry a fading image of its previous device.
        (rowView.view(atColumn: 0) as? SimulatorSidebarCellView)?.setThumbnail(nil, image: nil, animated: false)
        scheduleThumbnailRefresh()
    }

    private func shouldRenderAsActive(_ device: InventoryDevice) -> Bool {
        if let active = displayedActiveStates.isActive(device) { return active }
        // Without DeviceKit's value, keep Neo's own screen and transition state, which do not reorder the row.
        if screens.screen(for: device.id) != nil { return true }
        switch device {
        case .simulator(let simulator):
            return ["Booting", "Shutting Down"].contains(simulator.state)
        case .remote(let remote):
            return ["booting", "shuttingDown"].contains(remote.bootState ?? "")
        }
    }

    private func scheduleThumbnailRefresh() {
        guard !thumbnailRefreshScheduled else { return }
        thumbnailRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.thumbnailRefreshScheduled = false
            self.updateThumbnails()
        }
    }

    private func updateThumbnails() {
        let booted = manager.inventory.compactMap { device -> SimulatorHostDevice? in
            guard case .simulator(let simulator) = device, simulator.state == "Booted" else { return nil }
            return simulator
        }
        var visible: [SimulatorHostDevice] = []
        let range = table.rows(in: table.visibleRect)
        let window = view.window
        if window?.isVisible == true, window?.occlusionState.contains(.visible) == true,
           splitViewItem?.isCollapsed == false, range.location != NSNotFound {
            for index in range.location..<NSMaxRange(range) {
                guard let row = table.item(atRow: index) as? DeviceRow,
                      case .simulator(let device) = devicesByID[row.id], device.state == "Booted" else { continue }
                visible.append(device)
            }
        }
        thumbnails.update(visible: visible, booted: booted)
        if range.location != NSNotFound {
            for index in range.location..<NSMaxRange(range) {
                if let row = table.item(atRow: index) as? DeviceRow { refreshThumbnail(for: row.id) }
            }
        }
    }

    private func refreshThumbnail(for identifier: DeviceInventoryID) {
        guard let row = rowsByID[identifier] else { return }
        let index = table.row(forItem: row)
        guard index >= 0, let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? SimulatorSidebarCellView else { return }
        cell.setThumbnail(thumbnails.frame(for: identifier), image: thumbnails.image(for: identifier))
    }

    package func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !updatingSelection else { return }
        let selection = Set(table.selectedRowIndexes.compactMap { (table.item(atRow: $0) as? DeviceRow)?.id })
        let selected = model.selectedIdentifiers
        let visibleSelection = Set(rows.filter { selected.contains($0.id) && table.row(forItem: $0) >= 0 }.map(\.id))
        guard selection != visibleSelection else { return }
        model.select(selection)
        scheduleThumbnailRefresh()
        onSelectionChange?(true)
    }

    package func controlTextDidChange(_ notification: Notification) {
        model.query = search.stringValue
        update()
    }

    @objc private func openSelectedDevice(_ sender: Any?) {
        let devices = visibleSelectedDevices
        guard !devices.contains(where: { screens.screen(for: $0.id) != nil }) else { return }
        model.open(devices)
    }

    /// Targets the clicked row, or the selection when it contains that row or no row was clicked.
    /// Opening the menu does not change selection or presentation.
    package func updateDeviceMenu(for clickedRow: Int) {
        guard clickedRow >= 0, !table.selectedRowIndexes.contains(clickedRow) else {
            populateDeviceMenu?(deviceMenu, visibleSelectedDevices)
            return
        }
        guard let row = table.item(atRow: clickedRow) as? DeviceRow, let device = device(for: row) else {
            deviceMenu.removeAllItems()
            return
        }
        populateDeviceMenu?(deviceMenu, [device])
    }

    private func updateFilterItem() {
        let active = model.isFiltering
        (filterItem?.view as? NSButton)?.state = active ? .on : .off
        filterItem?.menuFormRepresentation?.state = active ? .on : .off
    }

    @objc private func showDeviceFilters(_ sender: NSButton) {
        sender.state = .on
        filterMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY), in: sender)
        updateFilterItem()
    }

    package func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === deviceMenu { updateDeviceMenu(for: table.clickedRow); return }
        guard menu === filterMenu else { return }
        menu.removeAllItems()
        menu.addItem(.sectionHeader(title: "Devices"))
        for filter in DeviceSidebarModel.KindFilter.allCases {
            let item = NSMenuItem(title: filter.title, action: #selector(filterKind(_:)), keyEquivalent: "")
            item.target = self
            item.tag = filter.rawValue
            item.state = model.kindFilter == filter ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Availability"))
        for filter in DeviceSidebarModel.AvailabilityFilter.allCases {
            let item = NSMenuItem(title: filter.title, action: #selector(filterAvailability(_:)), keyEquivalent: "")
            item.target = self
            item.tag = filter.rawValue
            item.state = model.availabilityFilter == filter ? .on : .off
            menu.addItem(item)
        }
        let grouping = NSMenuItem(title: "Show Groups", action: #selector(toggleDeviceGroups(_:)), keyEquivalent: "")
        grouping.target = self
        grouping.state = model.options.showGroups ? .on : .off
        menu.addItem(grouping)
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Device Family"))
        let allTypes = NSMenuItem(title: "All Families", action: #selector(filterFamily(_:)), keyEquivalent: "")
        allTypes.target = self
        allTypes.state = model.familyFilter == nil ? .on : .off
        menu.addItem(allTypes)
        for family in model.families {
            let item = NSMenuItem(title: family, action: #selector(filterFamily(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = family
            item.state = model.familyFilter == family ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Sort By"))
        for order in SortOrder.allCases {
            let item = NSMenuItem(title: order.title, action: #selector(sortDevices(_:)), keyEquivalent: "")
            item.target = self
            item.tag = order.rawValue
            item.state = model.options.sortOrder == order ? .on : .off
            menu.addItem(item)
        }
    }

    @objc private func filterKind(_ sender: NSMenuItem) {
        guard let filter = DeviceSidebarModel.KindFilter(rawValue: sender.tag) else { return }
        model.kindFilter = filter
        update(animated: true)
    }

    @objc private func filterAvailability(_ sender: NSMenuItem) {
        guard let filter = DeviceSidebarModel.AvailabilityFilter(rawValue: sender.tag) else { return }
        model.availabilityFilter = filter
        update(animated: true)
    }

    @objc private func toggleDeviceGroups(_ sender: Any?) {
        rememberCollapsedGroups()
        model.options.showGroups.toggle()
        update(animated: true)
    }

    @objc private func filterFamily(_ sender: NSMenuItem) {
        model.familyFilter = sender.representedObject as? String
        update(animated: true)
    }

    @objc private func sortDevices(_ sender: NSMenuItem) {
        guard let order = SortOrder(rawValue: sender.tag) else { return }
        model.options.sortOrder = order
        update(animated: true)
    }
}

#if DEBUG
    #Preview("Devices", traits: .fixedLayout(width: 280, height: 600)) {
        let source = PreviewManagerSource(otherDevices: [
            .simulator(
                SimulatorHostDevice(
                    identifier: "preview-ipad",
                    name: "iPad Pro 11-inch (M5)",
                    descriptiveName: "iPad Pro 11-inch (M5)",
                    runtimeIdentifier: "preview-runtime",
                    runtimeName: "iPadOS 27.2",
                    productFamily: "iPad",
                    state: "Shutdown"
                )),
            .simulator(
                SimulatorHostDevice(
                    identifier: "preview-watch",
                    name: "Apple Watch Ultra 3 (49mm)",
                    descriptiveName: "Apple Watch Ultra 3 (49mm)",
                    runtimeIdentifier: "preview-watch-runtime",
                    runtimeName: "watchOS 27.2",
                    productFamily: "Apple Watch",
                    state: "Shutdown"
                )),
        ])
        let manager = SimulatorManagerModel(
            source: source, serviceProfiles: .preview(named: "NeoSimulator.SidebarPreview"))
        let sidebar = DeviceSidebarViewController(
            model: DeviceSidebarModel(
                manager: manager, defaults: UserDefaults(suiteName: "NeoSimulator.SidebarPreview")!),
            screens: DeviceScreens(model: manager),
            artworkCache: DeviceArtworkCache()
        )
        let split = NSSplitViewController()
        split.splitView.isVertical = true
        split.addSplitViewItem(sidebar.makeSplitViewItem())
        Task {
            await manager.refresh()
        }
        return split
    }
#endif
