import AppKit
import ObservationBridge
import SwiftUI

@MainActor
final class ServiceProfilesSettingsViewController: NSSplitViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
    let model: ServiceProfilesSettingsModel
    private let table = NSTableView()
    private let remove = NSButton(image: NSImage(systemSymbolName: "minus", accessibilityDescription: "Delete Service Profile")!,
                                  target: nil, action: nil)
    private let detailsController = NSViewController()
    private let listContainer = NSView()
    private var outline: BackgroundServiceOutlineController?
    private var displayedProfile: ServiceProfile?
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
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let add = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "New Service Profile")!,
                           target: self, action: #selector(addProfile))
        remove.target = self
        remove.action = #selector(removeProfile)
        for button in [add, remove] { button.isBordered = false }
        let controls = NSStackView(views: [add, remove, NSView()])
        controls.heightAnchor.constraint(equalToConstant: 36).isActive = true
        controls.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        let sidebar = NSStackView(views: [scroll, controls])
        sidebar.orientation = .vertical
        sidebar.alignment = .width
        sidebar.spacing = 0
        let details = OpaqueSettingsPane()
        detailsController.view = details
        listContainer.translatesAutoresizingMaskIntoConstraints = false
        details.addSubview(listContainer)
        NSLayoutConstraint.activate([
            listContainer.topAnchor.constraint(equalTo: details.topAnchor, constant: 8),
            listContainer.leadingAnchor.constraint(equalTo: details.leadingAnchor, constant: 8),
            listContainer.trailingAnchor.constraint(equalTo: details.trailingAnchor, constant: -8),
            listContainer.bottomAnchor.constraint(equalTo: details.bottomAnchor, constant: -8),
        ])
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
        sidebarBackground.addSubview(sidebar)
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: sidebarBackground.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: sidebarBackground.bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: sidebarBackground.leadingAnchor),
            sidebar.trailingAnchor.constraint(equalTo: sidebarBackground.trailingAnchor),
        ])
        let sidebarController = NSViewController()
        sidebarController.view = sidebarBackground
        let sidebarItem = NSSplitViewItem(viewController: sidebarController)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 240
        sidebarItem.holdingPriority = .defaultHigh
        addSplitViewItem(sidebarItem)
        addSplitViewItem(NSSplitViewItem(viewController: detailsController))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observation = withPortableContinuousObservation { [weak self] _ in self?.update() }
    }

    private func update() {
        let updated = model.store.availableProfiles
        if profiles.map(\.id) != updated.map(\.id) {
            profiles = updated
            table.reloadData()
        }
        selecting = true
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
        remove.isEnabled = model.canDelete
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
        outline?.view.removeFromSuperview()
        outline?.removeFromParent()
        displayedProfile = profile
        let outline = BackgroundServiceOutlineController(categories: profile.categories, showsDetails: true)
        outline.isEnabled = profile.canEdit
        self.outline = outline
        detailsController.addChild(outline)
        let view = outline.view
        view.translatesAutoresizingMaskIntoConstraints = false
        listContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
            view.topAnchor.constraint(equalTo: listContainer.topAnchor),
            view.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor),
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        beginRenaming()
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
        if profile.id != ServiceProfile.default.id {
            let rename = NSMenuItem(title: "Rename…", action: #selector(renameProfile(_:)), keyEquivalent: "")
            rename.target = self
            rename.representedObject = profile
            menu.addItem(rename)
            let delete = NSMenuItem(title: "Delete", action: #selector(deleteProfile(_:)), keyEquivalent: "")
            delete.target = self
            delete.representedObject = profile
            menu.addItem(delete)
        }
    }
    @objc private func addProfile() { model.create() }
    @objc private func renameProfile(_ sender: NSMenuItem) {
        if let profile = sender.representedObject as? ServiceProfile {
            model.selectedProfileID = profile.id
            model.editingProfileID = profile.id
        }
    }
    @objc private func removeProfile() { confirmDeletion(model.selectedProfile) }
    @objc private func duplicateProfile(_ sender: NSMenuItem) {
        if let profile = sender.representedObject as? ServiceProfile { model.duplicate(profile) }
    }
    @objc private func deleteProfile(_ sender: NSMenuItem) {
        if let profile = sender.representedObject as? ServiceProfile { confirmDeletion(profile) }
    }
    private func confirmDeletion(_ profile: ServiceProfile) {
        guard profile.id != ServiceProfile.default.id, let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Delete Service Profile?"
        alert.informativeText = "The simulators keep their current services. Only the profile and its assignments are removed."
        alert.addButton(withTitle: "Delete")
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
        let label = NSTextField(labelWithString: "")
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
        subtitle.isHidden = profile.id != ServiceProfile.default.id
        textField?.identifier = NSUserInterfaceItemIdentifier(profile.id.uuidString)
        textField?.isEditable = profile.canEdit
        textField?.isSelectable = profile.canEdit
        observation = withPortableContinuousObservation { [weak self, profile] _ in
            guard let field = self?.textField, field.currentEditor() == nil else { return }
            field.stringValue = profile.name
        }
    }
}

private final class OpaqueSettingsPane: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

#if DEBUG
#Preview("Service Profiles", traits: .sizeThatFitsLayout) {
    PreviewViewController {
        let store = ServiceProfileStore(defaults: UserDefaults(suiteName: "NeoSimulator.ServiceProfilesPreview")!)
        if store.profiles.isEmpty {
            let _ = try? store.create(name: "Development", configuration: ServiceConfiguration())
            let _ = try? store.create(name: "Lightweight", configuration: ServiceConfiguration(disabledLabels: ["com.apple.searchd"]))
        }
        let controller = ServiceProfilesSettingsViewController(store: store)
        controller.model.selectedProfileID = store.profiles.first?.id
        return controller
    }.frame(width: 720, height: 520)
}
#Preview("Default Profile", traits: .sizeThatFitsLayout) {
    PreviewViewController {
        ServiceProfilesSettingsViewController(store: ServiceProfileStore(defaults: UserDefaults(suiteName: "NeoSimulator.DefaultServiceProfilePreview")!))
    }.frame(width: 720, height: 520)
}
#endif
