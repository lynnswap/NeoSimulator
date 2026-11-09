import NeoSimulatorKit
import NeoSimulatorHostSupport
import AppKit
import ObservationBridge
import SwiftUI
import NeoSimulatorManager
import NeoSimulatorInspector
import UniformTypeIdentifiers

@MainActor
final class ServiceProfilesSettingsViewController: NSSplitViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
    let model: ServiceProfilesSettingsModel
    private let table = NSTableView()
    private let defaultProfileMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    nonisolated fileprivate static let profileDragType = NSPasteboard.PasteboardType(
        "dev.lynnswap.NeoSimulator.service-profile")
    private let profileActions = NSSegmentedControl(images: [
            NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Service Profile")!,
        NSImage(systemSymbolName: "minus", accessibilityDescription: "Delete Service Profile")!,
    ], trackingMode: .momentary, target: nil, action: nil)
    /// What the add button offers: a profile that starts from the selected one, or profiles from files.
    let addProfileMenu = NSMenu()
    private let detailsController = NSViewController()
    let services: ServiceProfileServicesViewController
    private var observation: PortableObservationTracking.Token?
    private var profiles: [ServiceProfile] = []
    private var selecting = false
    private let unavailable = NSHostingView(rootView: ServiceProfilesUnavailable(issue: "", reload: {}))

    init(store: ServiceProfileStore) {
        model = ServiceProfilesSettingsModel(store: store)
        services = ServiceProfileServicesViewController(model: model)
        super.init(nibName: nil, bundle: nil)
        title = "Service Profiles"
        preferredContentSize = NSSize(width: 860, height: 520)
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
        table.registerForDraggedTypes([Self.profileDragType, .fileURL])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        // Outside the app, a profile drops as a file.
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
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
        detailsController.addChild(services)
        let panes = services.view
        panes.translatesAutoresizingMaskIntoConstraints = false
        details.addSubview(panes, positioned: .below, relativeTo: unavailable)
        NSLayoutConstraint.activate([
            panes.leadingAnchor.constraint(equalTo: details.leadingAnchor),
            panes.trailingAnchor.constraint(equalTo: details.trailingAnchor),
            panes.topAnchor.constraint(equalTo: details.topAnchor),
            panes.bottomAnchor.constraint(equalTo: details.bottomAnchor),
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
        for (title, action) in [
            ("New Profile", #selector(newProfile(_:))), ("Import…", #selector(chooseProfilesToImport(_:))),
        ] {
            addProfileMenu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        let controls = NSStackView(views: [profileActions, NSView()])
        controls.frame.size = NSSize(width: 180, height: controls.fittingSize.height)
        actions.view = controls
        splitViewItems[0].addBottomAlignedAccessoryViewController(actions)
        // The filter spans the categories and their services, but not the profiles.
        splitViewItems[1].addTopAlignedAccessoryViewController(services.searchAccessory)
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
        // A profile's categories change when a custom category is added or removed.
        services.show(profile)
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
        guard profiles.indices.contains(row) else { return nil }
        let profile = profiles[row]
        // Encoding the profile's names and labels can't fail.
        guard let contents = try? model.store.exportedFile(for: profile) else { return nil }
        return ServiceProfileFilePromise(
            movedProfile: profile.isBuiltIn ? nil : profile.id,
            fileName: model.exportFileName(for: profile), contents: contents)
    }

    private func draggedProfile(_ info: any NSDraggingInfo) -> UUID? {
        guard let source = info.draggingSource as? NSTableView, source === table,
              let value = info.draggingPasteboard.string(forType: Self.profileDragType),
              let id = UUID(uuidString: value),
            profiles.contains(where: { $0.id == id && !$0.isBuiltIn })
        else { return nil }
        return id
    }

    private func droppedFiles(_ info: any NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.json.identifier],
        ]
        return info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        if draggedProfile(info) != nil {
            tableView.setDropRow(
                max(model.store.builtInProfiles.count, min(row, profiles.count)), dropOperation: .above)
            return .move
        }
        guard !droppedFiles(info).isEmpty else { return [] }
        // Files add profiles to the list rather than at a row.
        tableView.setDropRow(-1, dropOperation: .on)
        return .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo,
                   row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        if let id = draggedProfile(info) {
            guard dropOperation == .above, row >= model.store.builtInProfiles.count, row <= profiles.count else {
                return false
            }
            return model.move(id, before: row < profiles.count ? profiles[row].id : nil)
        }
        let files = droppedFiles(info)
        guard !files.isEmpty else { return false }
        importProfiles(from: files)
        return true
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
        if profile.canEdit {
            let rename = NSMenuItem(title: "Rename…", action: #selector(renameProfile(_:)), keyEquivalent: "")
            rename.target = self
            rename.representedObject = profile
            menu.addItem(rename)
        }
        let export = NSMenuItem(title: "Export…", action: #selector(exportProfile(_:)), keyEquivalent: "")
        export.target = self
        export.representedObject = profile
        menu.addItem(export)
        if profile.canEdit {
            menu.addItem(.separator())
            let delete = NSMenuItem(title: "Delete", action: #selector(deleteProfile(_:)), keyEquivalent: "")
            delete.target = self
            delete.representedObject = profile
            menu.addItem(delete)
        }
    }
    @objc private func performProfileAction(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 0:
            addProfileMenu.popUp(
                positioning: nil, at: NSPoint(x: 0, y: sender.isFlipped ? sender.bounds.maxY + 4 : -4), in: sender)
        case 1: confirmDeletion(model.selectedProfile)
        default: break
        }
    }
    // A new profile starts from the selected one, which can be the built-in profile.
    @objc private func newProfile(_ sender: Any?) { model.duplicate(model.selectedProfile) }
    @objc private func chooseProfilesToImport(_ sender: Any?) {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose JSON files of service profiles to add."
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self else { return }
            importProfiles(from: panel.urls)
        }
    }
    private func importProfiles(from urls: [URL]) {
        Task { [weak self, model] in
            do { try await model.importProfiles(from: urls) } catch {
                self?.showFailure("Unable to Import Service Profiles", error)
            }
        }
    }
    @objc private func exportProfile(_ sender: NSMenuItem) {
        guard let profile = sender.representedObject as? ServiceProfile, let window = view.window else { return }
        let panel = NSSavePanel()
        panel.title = "Export Service Profile"
        panel.nameFieldStringValue = model.exportFileName(for: profile)
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.beginSheetModal(for: window) { [weak self, model] response in
            guard response == .OK, let url = panel.url else { return }
            Task { [weak self] in
                do { try await model.export(profile, to: url) } catch {
                    self?.showFailure("Unable to Export “\(profile.name)”", error)
                }
            }
        }
    }
    private func showFailure(_ title: String, _ error: any Error) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: window)
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
        guard profile.canEdit, let window = view.window else { return }
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

/// A dragged profile, which moves within the list and becomes a JSON file where it drops outside the app. Its
/// file's contents come from when the drag starts.
private final class ServiceProfileFilePromise: NSFilePromiseProvider, NSFilePromiseProviderDelegate {
    /// The profile that the drag moves within the list, or `nil` for a built-in profile, which stays at the top.
    let movedProfile: UUID?
    private let fileName: String
    private let contents: Data
    private let writes = OperationQueue()

    init(movedProfile: UUID?, fileName: String, contents: Data) {
        self.movedProfile = movedProfile
        self.fileName = fileName
        self.contents = contents
        super.init()
        writes.qualityOfService = .userInitiated
        fileType = UTType.json.identifier
        // The provider holds what it writes, so the drag keeps the delegate as long as it needs it.
        delegate = self
    }

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard)
            + (movedProfile == nil ? [] : [ServiceProfilesSettingsViewController.profileDragType])
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        guard type == ServiceProfilesSettingsViewController.profileDragType else {
            return super.pasteboardPropertyList(forType: type)
        }
        return movedProfile?.uuidString
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        fileName
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { writes }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
        completionHandler: @escaping @Sendable ((any Error)?) -> Void
    ) {
        do {
            // The destination needn't be empty, and a file already there stays.
            try contents.write(to: url, options: .withoutOverwriting)
            completionHandler(nil)
        } catch { completionHandler(error) }
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
        subtitle.isHidden = !profile.isBuiltIn
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
#Preview("Service Profiles", traits: .fixedLayout(width: 720, height: 520)) {
    let store = ServiceProfileStore.preview(named: "NeoSimulator.ServiceProfilesPreview")
    _ = try? store.create(name: "Development", configuration: ServiceConfiguration())
    _ = try? store.create(
        name: "Lightweight", configuration: ServiceConfiguration(disabledLabels: ["com.apple.searchd"]))
    let controller = ServiceProfilesSettingsViewController(store: store)
    controller.model.selectedProfileID = store.profiles.first?.id
    return controller
}

#Preview("All Services", traits: .fixedLayout(width: 720, height: 520)) {
    ServiceProfilesSettingsViewController(store: .preview(named: "NeoSimulator.DefaultServiceProfilePreview"))
}
#endif
