import NeoSimulatorKit
import NeoSimulatorHostSupport
import AppKit
import ObservationBridge
import SwiftUI

@MainActor
final class ServiceProfilesSettingsViewController: NSSplitViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
    let model: ServiceProfilesSettingsModel
    private let table = NSTableView()
    private let defaultProfileMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    private static let profileDragType = NSPasteboard.PasteboardType("dev.lynnswap.NeoSimulator.service-profile")
    private let profileActions = NSSegmentedControl(images: [
        NSImage(systemSymbolName: "plus", accessibilityDescription: "New Service Profile")!,
        NSImage(systemSymbolName: "minus", accessibilityDescription: "Delete Service Profile")!,
    ], trackingMode: .momentary, target: nil, action: nil)
    private let detailsController = NSViewController()
    private lazy var outline = BackgroundServiceOutlineController(categories: model.selectedProfile.categories, showsDetails: true)
    private var displayedProfile: ServiceProfile?
    private lazy var searchField = BackgroundServiceSearchField(model: outline.model)
    private var observation: PortableObservationTracking.Token?
    private var profiles: [ServiceProfile] = []
    private var selecting = false
    private let unavailable = NSHostingView(rootView: ServiceProfilesUnavailable(issue: "", reload: {}))

    init(store: ServiceProfileStore) {
        model = ServiceProfilesSettingsModel(store: store)
        super.init(nibName: nil, bundle: nil)
        title = "Service Profiles"
        preferredContentSize = NSSize(width: 720, height: 520)
    }
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        super.loadView()
        view.frame = NSRect(origin: .zero, size: preferredContentSize)
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        let column = NSTableColumn(identifier: .init("Profile"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .inset
        table.backgroundColor = .clear
        table.rowHeight = 46
        table.dataSource = self
        table.delegate = self
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.setAccessibilityLabel("Service Profiles")
        table.registerForDraggedTypes([Self.profileDragType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.draggingDestinationFeedbackStyle = .gap
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let details = OpaqueSettingsPane()
        detailsController.view = details
        unavailable.sizingOptions = []
        unavailable.translatesAutoresizingMaskIntoConstraints = false
        unavailable.isHidden = true
        details.addSubview(unavailable)
        NSLayoutConstraint.activate([
            unavailable.leadingAnchor.constraint(equalTo: details.leadingAnchor),
            unavailable.trailingAnchor.constraint(equalTo: details.trailingAnchor),
            unavailable.topAnchor.constraint(equalTo: details.topAnchor),
            unavailable.bottomAnchor.constraint(equalTo: details.bottomAnchor),
        ])
        let sidebarBackground = OpaqueSettingsPane()
        sidebarBackground.addSubview(scroll)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: sidebarBackground.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: sidebarBackground.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: sidebarBackground.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: sidebarBackground.trailingAnchor),
        ])
        let sidebarController = NSViewController()
        sidebarController.view = sidebarBackground
        let sidebarItem = NSSplitViewItem(viewController: sidebarController)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 240
        sidebarItem.holdingPriority = .defaultHigh
        addSplitViewItem(sidebarItem)
        detailsController.addChild(outline)
        let list = outline.view
        list.translatesAutoresizingMaskIntoConstraints = false
        details.addSubview(list, positioned: .below, relativeTo: unavailable)
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: details.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: details.trailingAnchor),
            list.topAnchor.constraint(equalTo: details.topAnchor),
            list.bottomAnchor.constraint(equalTo: details.bottomAnchor),
        ])
        addSplitViewItem(NSSplitViewItem(viewController: detailsController))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Finish the initial pane measurement before accessory wrappers install their constraints.
        let defaults = NSSplitViewItemAccessoryViewController()
        defaults.preferredScrollEdgeEffectStyle = .hard
        defaultProfileMenu.target = self
        defaultProfileMenu.action = #selector(selectDefaultProfile(_:))
        defaultProfileMenu.setAccessibilityLabel(String(localized: "Default Profile", bundle: #bundle))
        defaultProfileMenu.toolTip = String(localized: "Used at the next simulator start.", bundle: #bundle)
        let defaultLabel = NSTextField(labelWithString: String(localized: "Default Profile", bundle: #bundle))
        defaultLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        defaultLabel.textColor = .secondaryLabelColor
        let defaultControls = NSStackView(views: [defaultLabel, defaultProfileMenu])
        defaultControls.orientation = .vertical
        defaultControls.alignment = .leading
        defaultControls.spacing = 6
        defaultProfileMenu.widthAnchor.constraint(equalTo: defaultControls.widthAnchor).isActive = true
        defaultControls.frame.size = NSSize(width: 180, height: defaultControls.fittingSize.height)
        defaults.view = defaultControls
        splitViewItems[0].addTopAlignedAccessoryViewController(defaults)
        let actions = NSSplitViewItemAccessoryViewController()
        actions.preferredScrollEdgeEffectStyle = .hard
        profileActions.target = self
        profileActions.action = #selector(performProfileAction(_:))
        profileActions.segmentStyle = .smallSquare
        let controls = NSStackView(views: [profileActions, NSView()])
        controls.frame.size = NSSize(width: 180, height: controls.fittingSize.height)
        actions.view = controls
        splitViewItems[0].addBottomAlignedAccessoryViewController(actions)
        let search = NSSplitViewItemAccessoryViewController()
        search.preferredScrollEdgeEffectStyle = .hard
        let searchControls = NSStackView(views: [searchField])
        searchControls.orientation = .vertical
        searchControls.alignment = .width
        searchControls.frame.size = searchControls.fittingSize
        search.view = searchControls
        splitViewItems[1].addTopAlignedAccessoryViewController(search)
        observation = withPortableContinuousObservation { [weak self] _ in self?.update() }
    }

    private func update() {
        selecting = true
        let updated = model.store.availableProfiles
        if profiles.map(\.id) != updated.map(\.id) {
            profiles = updated
            table.reloadData()
        }
        if defaultProfileMenu.itemArray.map(\.title) != updated.map(\.name)
            || defaultProfileMenu.itemArray.compactMap({ $0.representedObject as? UUID }) != updated.map(\.id) {
            let menu = NSMenu()
            for profile in updated {
                let item = NSMenuItem(title: profile.name, action: nil, keyEquivalent: "")
                item.representedObject = profile.id
                menu.addItem(item)
            }
            defaultProfileMenu.menu = menu
        }
        if let index = updated.firstIndex(where: { $0.id == model.defaultProfileID }) {
            defaultProfileMenu.selectItem(at: index)
        }
        defaultProfileMenu.isEnabled = model.store.issue == nil
        if let index = profiles.firstIndex(where: { $0.id == model.selectedProfile.id }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        selecting = false
        if let issue = model.store.issue {
            unavailable.rootView = ServiceProfilesUnavailable(issue: issue, reload: model.store.reload)
            unavailable.isHidden = false
        } else { unavailable.isHidden = true }
        let profile = model.selectedProfile
        showProfile(profile)
        profileActions.setEnabled(model.canDelete, forSegment: 1)
        beginRenaming()
        if let issue = model.issue ?? profile.issue, let window = view.window {
            model.issue = nil
            profile.issue = nil
            let alert = NSAlert()
            alert.messageText = "Unable to Save Service Profile"
            alert.informativeText = issue
            alert.beginSheetModal(for: window)
        }
    }

    private func showProfile(_ profile: ServiceProfile) {
        guard displayedProfile !== profile else { return }
        displayedProfile = profile
        outline.model.setCategories(profile.categories)
        outline.isEnabled = profile.canEdit
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        beginRenaming()
    }

    @objc private func selectDefaultProfile(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? UUID else { return }
        model.defaultProfileID = id
    }

    private func beginRenaming() {
        guard let id = model.editingProfileID, view.window != nil,
              let row = profiles.firstIndex(where: { $0.id == id }) else { return }
        model.editingProfileID = nil
        table.scrollRowToVisible(row)
        table.editColumn(0, row: row, with: nil, select: true)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        guard let rawID = field.identifier?.rawValue, let id = UUID(uuidString: rawID),
              let profile = model.store.profile(id) else { return }
        model.rename(profile, to: field.stringValue)
        field.stringValue = profile.name
    }

    func numberOfRows(in tableView: NSTableView) -> Int { profiles.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("Profile")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? ServiceProfileCell ?? ServiceProfileCell()
        cell.identifier = id
        cell.configure(profile: profiles[row])
        cell.textField?.delegate = self
        return cell
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard profiles.indices.contains(row), profiles[row].id != ServiceProfile.allServices.id else { return nil }
        let item = NSPasteboardItem()
        item.setString(profiles[row].id.uuidString, forType: Self.profileDragType)
        return item
    }

    private func draggedProfile(_ info: any NSDraggingInfo) -> UUID? {
        guard let source = info.draggingSource as? NSTableView, source === table,
              let value = info.draggingPasteboard.string(forType: Self.profileDragType),
              let id = UUID(uuidString: value),
              id != ServiceProfile.allServices.id,
              profiles.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard draggedProfile(info) != nil else { return [] }
        tableView.setDropRow(max(1, min(row, profiles.count)), dropOperation: .above)
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo,
                   row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard dropOperation == .above, row >= 1, row <= profiles.count,
              let id = draggedProfile(info) else { return false }
        return model.move(id, before: row < profiles.count ? profiles[row].id : nil)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !selecting, profiles.indices.contains(table.selectedRow) else { return }
        model.selectedProfileID = profiles[table.selectedRow].id
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard profiles.indices.contains(table.clickedRow) else { return }
        let profile = profiles[table.clickedRow]
        let duplicate = NSMenuItem(title: "Duplicate", action: #selector(duplicateProfile(_:)), keyEquivalent: "")
        duplicate.target = self
        duplicate.representedObject = profile
        menu.addItem(duplicate)
        if profile.id != ServiceProfile.allServices.id {
            let rename = NSMenuItem(title: "Rename…", action: #selector(renameProfile(_:)), keyEquivalent: "")
            rename.target = self
            rename.representedObject = profile
            menu.addItem(rename)
            menu.addItem(.separator())
            let delete = NSMenuItem(title: "Delete", action: #selector(deleteProfile(_:)), keyEquivalent: "")
            delete.target = self
            delete.representedObject = profile
            menu.addItem(delete)
        }
    }
    @objc private func performProfileAction(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 0: model.create()
        case 1: confirmDeletion(model.selectedProfile)
        default: break
        }
    }
    @objc private func renameProfile(_ sender: NSMenuItem) {
        if let profile = sender.representedObject as? ServiceProfile {
            model.selectedProfileID = profile.id
            model.editingProfileID = profile.id
        }
    }
    @objc private func duplicateProfile(_ sender: NSMenuItem) {
        if let profile = sender.representedObject as? ServiceProfile { model.duplicate(profile) }
    }
    @objc private func deleteProfile(_ sender: NSMenuItem) {
        if let profile = sender.representedObject as? ServiceProfile { confirmDeletion(profile) }
    }
    private func confirmDeletion(_ profile: ServiceProfile) {
        guard profile.id != ServiceProfile.allServices.id, let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Delete Service Profile?"
        alert.informativeText = "The simulators keep their current services. Devices using this profile will follow the default profile at their next start."
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            model.deleting = profile
            model.delete()
            if let issue = model.issue, let window = view.window {
                let failure = NSAlert()
                failure.messageText = "Unable to Delete Service Profile"
                failure.informativeText = issue
                failure.beginSheetModal(for: window)
                model.issue = nil
            }
        }
    }
}

private struct ServiceProfilesUnavailable: View {
    let issue: String
    let reload: () -> Void
    var body: some View {
        ContentUnavailableView {
            Label("Service Profiles Unavailable", systemImage: "cpu")
        } description: {
            Text(issue)
        } actions: {
            Button("Try Again", action: reload)
        }
    }
}

@MainActor
private final class ServiceProfileCell: NSTableCellView {
    private let subtitle = NSTextField(labelWithString: "Built-in Profile")
    private var observation: PortableObservationTracking.Token?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let label = LiteralTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        subtitle.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        subtitle.textColor = .secondaryLabelColor
        let labels = NSStackView(views: [label, subtitle])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        labels.translatesAutoresizingMaskIntoConstraints = false
        addSubview(labels)
        textField = label
        NSLayoutConstraint.activate([
            labels.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            labels.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }

    func configure(profile: ServiceProfile) {
        subtitle.isHidden = profile.id != ServiceProfile.allServices.id
        textField?.identifier = NSUserInterfaceItemIdentifier(profile.id.uuidString)
        textField?.isEditable = profile.canEdit
        textField?.isSelectable = profile.canEdit
        observation = withPortableContinuousObservation { [weak self, profile] _ in
            guard let field = self?.textField, field.currentEditor() == nil else { return }
            field.stringValue = profile.name
        }
    }
}

final class OpaqueSettingsPane: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

#if DEBUG
#Preview("Service Profiles", traits: .sizeThatFitsLayout) {
    PreviewViewController {
        let store = ServiceProfileStore(fileURL: URL.temporaryDirectory
            .appending(path: "NeoSimulator.ServiceProfilesPreview", directoryHint: .isDirectory)
            .appending(path: "ServiceProfiles.json"), legacyDefaults: nil)
        if store.profiles.isEmpty {
            let _ = try? store.create(name: "Development", configuration: ServiceConfiguration())
            let _ = try? store.create(name: "Lightweight", configuration: ServiceConfiguration(disabledLabels: ["com.apple.searchd"]))
        }
        let controller = ServiceProfilesSettingsViewController(store: store)
        controller.model.selectedProfileID = store.profiles.first?.id
        return controller
    }.frame(width: 720, height: 520)
}
#Preview("All Services", traits: .sizeThatFitsLayout) {
    PreviewViewController {
        ServiceProfilesSettingsViewController(store: ServiceProfileStore(fileURL: URL.temporaryDirectory
            .appending(path: "NeoSimulator.DefaultServiceProfilePreview", directoryHint: .isDirectory)
            .appending(path: "ServiceProfiles.json"), legacyDefaults: nil))
    }.frame(width: 720, height: 520)
}
#endif
