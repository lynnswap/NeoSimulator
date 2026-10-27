import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Observation
@_spi(NeoSimulator) import XcodeSimulatorHost

@MainActor
final class ManagerDeviceInspectorController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
                                                       NSSearchFieldDelegate, NSMenuDelegate {
    typealias Page = DeviceInspectorModel.Page
    private typealias Content = DeviceInspectorModel.Content
    private let inspection = DeviceInspectorModel()
    private let model: SimulatorManagerModel
    private var device: InventoryDevice? { get { inspection.device } set { inspection.device = newValue } }
    private var inspector: DeviceInspector? { get { inspection.inspector } set { inspection.inspector = newValue } }
    private var page: Page { get { inspection.page } set { inspection.page = newValue } }
    private var content: Content { get { inspection.content } set { inspection.select(newValue) } }
    private var isManaging: Bool { get { inspection.isManaging } set { inspection.isManaging = newValue } }
    private var isVisible: Bool { get { inspection.isVisible } set { inspection.isVisible = newValue } }
    private var generation: Int { inspection.generation }
    private var revealTask: Task<Void, Never>?
    private var iconTask: Task<Void, Never>?
    private var applications: [DeviceApplication] { inspection.applications }
    private var profiles: [DeviceProfile] { get { inspection.profiles } set { inspection.profiles = newValue } }
    private var reports: [DeviceReport] { inspection.reports }
    private var reportRows: [DeviceReport] = []
    private let reportFilter = NSPopUpButton()
    private var reportTypeFilter: String?
    private var previewGeneration = 0
    private var activePreviewTask: Task<Void, Never>?
    private var previewWindow: ManagerReportPreviewWindowController?
    private var currentPreview: DeviceReportPreview?
    private var retainedPreviews: [URL: DeviceReportPreview] = [:]
    private var previewTasks: [UUID: Task<Void, Never>] = [:]
    private var cleanupInFlight: Set<URL> = []
    private var cleanupFailures: [URL: any Error] = [:]
    private var preparingToQuit = false
    private let previewButton = NSButton(image: NSImage(systemSymbolName: "eye", accessibilityDescription: "Quick Look")!, target: nil, action: nil)
    private let downloadButton = NSButton(image: NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: "Download Report")!, target: nil, action: nil)
    private var appRows: [DeviceApplication] = []
    private var profileRows: [DeviceProfile] = []
    private var selectedRecordID: String?
    private var reloadingTable = false
    private let profileKindPicker = NSPopUpButton()
    private let infoPicker = NSSegmentedControl(labels: ["Info", "Apps", "Profiles"], trackingMode: .selectOne, target: nil, action: nil)
    private let profileHeading = NSTextField(labelWithString: "Configuration")
    private let unavailableView = NSHostingView(rootView: AnyView(EmptyView()))
    private let search = NSSearchField()
    private let table = NSTableView()
    private let listScroll = NSScrollView()
    private let detail = ManagerInspectorPropertiesController()
    private let infoVisibility = DeviceInfoVisibility()
    var onPairingMenu: ((SimulatorHostDevice) -> NSMenu)?
    private lazy var info = NSHostingController(rootView: DeviceInformationView(
        manager: model, inspection: inspection, visibility: infoVisibility,
        pairingMenu: { [weak self] in self?.onPairingMenu?($0) ?? NSMenu() },
        unpair: { [weak self] in self?.model.manage(.unpair, devices: [.simulator($0)]) }))
    private var showingInfo: Bool { page == .info && content == .info }
    private var showingApplications: Bool { page == .info && content == .applications }
    private var showingProfiles: Bool { page == .info && (content == .configuration || content == .provisioning) }
    private var showingReports: Bool { page == .reports }
    private let headerImage = NSImageView()
    private let headerName = NSTextField(labelWithString: "")
    private let headerSubtitle = NSTextField(labelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let addButton = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Install")!, target: nil, action: nil)
    private let removeButton = NSButton(image: NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove")!, target: nil, action: nil)
    private let launchButton = NSButton(image: NSImage(systemSymbolName: "play", accessibilityDescription: "Launch Application")!, target: nil, action: nil)
    private let actions = NSPopUpButton(frame: .zero, pullsDown: true)
    private let reloadButton = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh Inspector")!, target: nil, action: nil)
    private let contentView = NSView()
    private let infoView = NSView()
    private var lastIssue: String? { get { inspection.lastIssue } set { inspection.lastIssue = newValue } }
    private var reading: Bool { inspection.reading }

    init(model: SimulatorManagerModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView()
        infoPicker.target = self
        infoPicker.action = #selector(changeInfoCategory(_:))
        infoPicker.segmentDistribution = .fill
        infoPicker.setAccessibilityLabel("Inspector Subcategory")
        profileKindPicker.addItems(withTitles: ["Configuration", "Provisioning"])
        profileKindPicker.target = self
        profileKindPicker.action = #selector(changeProfileKind(_:))
        profileKindPicker.setAccessibilityLabel("Profile Type")
        profileHeading.font = .systemFont(ofSize: 11, weight: .semibold)
        profileHeading.textColor = .secondaryLabelColor
        search.placeholderString = "Search Applications"
        search.delegate = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Record"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .inset
        table.rowHeight = 44
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelectedRecord(_:))
        table.setAccessibilityLabel("Installed Applications, Profiles, and Reports")
        listScroll.documentView = table
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.drawsBackground = false
        let listController = NSViewController()
        listController.view = listScroll
        let detailController = NSViewController()
        let header = NSStackView(views: [headerImage, NSStackView(views: [headerName, headerSubtitle])])
        header.orientation = .horizontal
        header.spacing = 8
        header.alignment = .centerY
        if let labels = header.views.last as? NSStackView {
            labels.orientation = .vertical
            labels.alignment = .leading
            labels.spacing = 3
        }
        headerName.font = .systemFont(ofSize: 13, weight: .semibold)
        headerName.lineBreakMode = .byTruncatingTail
        headerSubtitle.font = .systemFont(ofSize: 11)
        headerSubtitle.textColor = .secondaryLabelColor
        headerSubtitle.lineBreakMode = .byTruncatingMiddle
        headerImage.imageScaling = .scaleProportionallyUpOrDown
        headerImage.widthAnchor.constraint(equalToConstant: 32).isActive = true
        headerImage.heightAnchor.constraint(equalToConstant: 32).isActive = true
        let detailStack = NSStackView(views: [header, detail.view])
        detailStack.orientation = .vertical
        detailStack.distribution = .fill
        detailStack.alignment = .leading
        detailStack.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false
        detail.view.translatesAutoresizingMaskIntoConstraints = false
        detailController.view = detailStack
        NSLayoutConstraint.activate([
            header.widthAnchor.constraint(equalTo: detailStack.widthAnchor),
            detail.view.widthAnchor.constraint(equalTo: detailStack.widthAnchor),
        ])
        let contentSplit = NSSplitViewController()
        contentSplit.splitView.isVertical = false
        let listItem = NSSplitViewItem(viewController: listController)
        listItem.minimumThickness = 100
        listItem.preferredThicknessFraction = 0.45
        let detailItem = NSSplitViewItem(viewController: detailController)
        detailItem.minimumThickness = 120
        contentSplit.addSplitViewItem(listItem)
        contentSplit.addSplitViewItem(detailItem)
        addChild(contentSplit)
        addChild(detail)
        addChild(info)
        reportFilter.addItem(withTitle: "All Report Types")
        reportFilter.target = self
        reportFilter.action = #selector(changeReportFilter(_:))
        reportFilter.setAccessibilityLabel("Report Type")
        let contentStack = NSStackView(views: [profileHeading, profileKindPicker, search, reportFilter, contentSplit.view])
        contentStack.orientation = .vertical
        contentStack.distribution = .fill
        contentStack.alignment = .leading
        contentStack.spacing = 8
        pin(contentStack, in: contentView)
        for child in contentStack.views { child.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true }
        pin(info.view, in: infoView)
        for button in [addButton, removeButton, launchButton, previewButton, downloadButton, reloadButton] { button.bezelStyle = .automatic; button.target = self }
        addButton.action = #selector(install(_:))
        removeButton.action = #selector(remove(_:))
        launchButton.action = #selector(launch(_:))
        previewButton.action = #selector(quickLookReport(_:))
        downloadButton.action = #selector(downloadReport(_:))
        previewButton.toolTip = "Quick Look"
        downloadButton.toolTip = "Download Report…"
        reloadButton.action = #selector(refreshInspector(_:))
        addButton.toolTip = "Install…"
        removeButton.toolTip = "Remove…"
        launchButton.toolTip = "Launch Application"
        reloadButton.toolTip = "Refresh Inspector"
        actions.addItem(withTitle: "Actions")
        actions.menu?.delegate = self
        actions.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Application Actions")
        actions.imagePosition = .imageOnly
        actions.setAccessibilityLabel("Application Actions")
        let buttons = NSStackView(views: [addButton, removeButton, launchButton, actions, previewButton, downloadButton, NSView(), reloadButton])
        buttons.orientation = .horizontal
        buttons.spacing = 6
        let footer = NSStackView(views: [progress, status])
        footer.orientation = .horizontal
        footer.alignment = .top
        footer.spacing = 6
        progress.style = .spinning
        progress.controlSize = .small
        progress.widthAnchor.constraint(equalToConstant: 16).isActive = true
        progress.heightAnchor.constraint(equalToConstant: 16).isActive = true
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.setAccessibilityLabel("Inspector Status")
        let stack = NSStackView(views: [infoPicker, contentView, infoView, unavailableView, buttons, footer])
        stack.orientation = .vertical
        stack.distribution = .fill
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
        ])
        for child in stack.views { child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        updateVisibility()
        updateControls()
        observeRecords()
        observeInspectionState()
    }

    private func pin(_ child: NSView, in parent: NSView, inset: CGFloat = 0) {
        child.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
            child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset),
        ])
    }

    func setPage(_ page: Page) {
        guard self.page != page else { return }
        self.page = page
        _ = view
        changedContent()
    }

    func update(device: InventoryDevice?, isManaging: Bool, isVisible: Bool) {
        _ = view
        let changed = self.device != device
        let becameVisible = !self.isVisible && isVisible
        self.device = device
        self.isManaging = isManaging
        self.isVisible = isVisible
        if changed {
            dismissReportPreview()
            stopReading()
            inspection.reset()
            reportTypeFilter = nil
            rebuildReportFilter()
            selectedRecordID = nil
            lastIssue = nil
            updateRows()
        }
        if isVisible && (changed || becameVisible) { reload() }
        else if !isVisible { stopReading(); dismissReportPreview() }
        updateVisibility()
        updateControls()
    }

    func stopReading() {
        inspection.stopReading()
        revealTask?.cancel()
        revealTask = nil
        iconTask?.cancel()
        iconTask = nil
    }

    override func viewWillLayout() {
        super.viewWillLayout()
        updateControls()
    }

    private func observeRecords() {
        withObservationTracking {
            _ = inspection.applications
            _ = inspection.profiles
            _ = inspection.reports
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.rebuildReportFilter()
                self?.updateRows()
                self?.observeRecords()
            }
        }
    }

    private func observeInspectionState() {
        withObservationTracking {
            _ = inspection.reading
            _ = inspection.lastIssue
            _ = inspection.isManaging
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.updateVisibility()
                self.updateControls()
                self.observeInspectionState()
            }
        }
    }

    private var unavailableState: (title: String, message: String, symbol: String)? {
        guard let device else { return ("No Selection", "Select one device to inspect it.", "cursorarrow") }
        if showingApplications && !canReadApplications {
            let message = device.kind == .simulator ? "Start the simulator to add or customize apps."
                : inspection.canInstallApplications ? "Installed applications cannot be listed on this device."
                : "Connect and unlock this device to inspect its applications."
            return ("Apps", message, "app")
        }
        if showingProfiles && !canReadProfiles {
            let message: String
            if case .simulator(let simulator) = device {
                message = simulator.deviceSetPath != nil ? "Profiles are unavailable for simulators in custom device sets."
                    : "Start the simulator to edit configuration profiles."
            } else { message = "This device does not currently support \(content.title.lowercased())." }
            return ("Profiles", message, "checkmark.seal")
        }
        if showingReports, let inspector, device.kind != .simulator, !inspector.supportsReportListing {
            return ("Reports", "Connect and unlock this device to inspect its reports.", "text.document")
        }
        return nil
    }

    private func updateVisibility() {
        let unavailable = unavailableState
        infoPicker.isHidden = page == .reports || device == nil
        infoPicker.selectedSegment = content == .info ? 0 : (showingApplications ? 1 : 2)
        contentView.isHidden = showingInfo || unavailable != nil
        infoView.isHidden = !showingInfo || unavailable != nil
        unavailableView.isHidden = unavailable == nil
        if let unavailable {
            unavailableView.rootView = AnyView(ContentUnavailableView {
                Image(systemName: unavailable.symbol).accessibilityLabel(unavailable.title)
            } description: { Text(unavailable.message) })
        }
        let hasBothProfileKinds = supports("configurationprofiles") && supports("provisioningprofiles")
        profileKindPicker.isHidden = !showingProfiles || !hasBothProfileKinds
        profileHeading.isHidden = !showingProfiles || hasBothProfileKinds
        profileHeading.stringValue = content == .provisioning ? "Provisioning" : "Configuration"
        profileKindPicker.selectItem(at: content == .provisioning ? 1 : 0)
        addButton.isHidden = !showingApplications && !showingProfiles ||
            unavailable != nil && !(showingApplications && inspection.canInstallApplications)
        for control in [removeButton, launchButton, actions] {
            control.isHidden = !showingApplications && !showingProfiles || unavailable != nil
        }
        previewButton.isHidden = !showingReports || unavailable != nil
        downloadButton.isHidden = !showingReports || unavailable != nil
        reportFilter.isHidden = !showingReports
        if !showingReports { dismissReportPreview() }
    }

    private var selectedApp: DeviceApplication? { appRows.first { $0.id == selectedRecordID } }
    private var selectedProfile: DeviceProfile? { profileRows.first { $0.id == selectedRecordID } }
    private var selectedReport: DeviceReport? { reportRows.first { $0.relativePath == selectedRecordID } }
    private var simulatorIsRunning: Bool { inspection.simulatorIsRunning }
    private func supports(_ feature: String) -> Bool { inspection.supports(feature) }
    private var canReadApplications: Bool { inspection.canReadApplications }
    private var canReadProfiles: Bool { inspection.canReadProfiles }
    private var canTransferData: Bool { selectedApp?.isContainerAccessible == true && (simulatorIsRunning || supports("transferFiles")) }
    private var canReplaceData: Bool {
        canTransferData && (simulatorIsRunning || (supports("processcontrol") && supports("streamprocesslist") && canReadApplications))
    }
    private var available: Bool { device != nil && inspector != nil && !isManaging && !reading && !preparingToQuit }

    private func updateControls() {
        let apps = showingApplications
        infoPicker.isEnabled = !isManaging
        profileKindPicker.isEnabled = !isManaging
        addButton.isEnabled = available && (apps ? inspection.canInstallApplications : canReadProfiles)
        removeButton.isEnabled = available && (apps ? selectedApp != nil && selectedApp?.isRemovable != false && (simulatorIsRunning || supports("uninstallapp")) : selectedProfile != nil && canReadProfiles && selectedProfile?.metadata["removalDisallowed"]?.boolean != true)
        launchButton.isHidden = !apps || unavailableState != nil
        launchButton.isEnabled = available && selectedApp != nil && (simulatorIsRunning || supports("launchapplication") || supports("applicationcontrol"))
        actions.isHidden = !apps || unavailableState != nil
        actions.isEnabled = available && selectedApp != nil
        let reportTransfer = available && selectedReport?.resources.isReadable != false && inspector?.supportsReportDownload == true
        previewButton.isEnabled = reportTransfer && selectedReport != nil && selectedReport?.resources.isDirectory == false && activePreviewTask == nil
        downloadButton.isEnabled = reportTransfer && selectedReport != nil
        reportFilter.isEnabled = !reading
        reloadButton.isEnabled = device != nil && !reading && !isManaging
        progress.isHidden = !reading && !isManaging && activePreviewTask == nil
        if progress.isHidden { progress.stopAnimation(nil) } else { progress.startAnimation(nil) }
        let message: String
        if device == nil { message = "Select one device to inspect it." }
        else if isManaging { message = "An operation is in progress on this device…" }
        else if reading { message = "Loading…" }
        else if activePreviewTask != nil { message = "Preparing preview…" }
        else { message = lastIssue ?? "" }
        if status.stringValue != message { status.stringValue = message }
        status.isHidden = status.stringValue.isEmpty || unavailableState != nil
    }

    func reload() {
        guard !preparingToQuit else { return }
        stopReading()
        inspection.reload { [model] in try await model.inspector(for: $0) }
    }

    @objc private func changeInfoCategory(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 0: content = .info
        case 1: content = .applications
        default: if content != .provisioning { content = .configuration }
        }
        changedContent()
    }

    @objc private func changeProfileKind(_ sender: NSPopUpButton) {
        content = sender.indexOfSelectedItem == 1 ? .provisioning : .configuration
        changedContent()
    }

    private func changedContent() {
        dismissReportPreview()
        updateVisibility()
        selectedRecordID = nil
        profiles = []
        search.stringValue = ""
        search.placeholderString = showingApplications ? "Search Applications" : (showingReports ? "Search Reports" : "Search Profiles")
        updateRows()
        reload()
    }
    @objc private func refreshInspector(_ sender: Any?) { reload() }
    func controlTextDidChange(_ notification: Notification) { updateRows() }

    private func updateRows() {
        let query = search.stringValue
        appRows = showingApplications ? applications.filter { query.isEmpty || $0.name.localizedStandardContains(query) || $0.bundleIdentifier.localizedStandardContains(query) } : []
        profileRows = showingApplications || showingReports ? [] : profiles.filter { $0.kind == content.profileKind && (query.isEmpty || $0.name.localizedStandardContains(query) || $0.identifier.localizedStandardContains(query)) }
        reportRows = showingReports ? reports.filter { report in
            (reportTypeFilter == nil || reportType(report) == reportTypeFilter) && (query.isEmpty ||
                [report.name, report.relativePath, report.type.fileExtension, report.type.recordedLogType, report.type.bugType]
                    .compactMap { $0 }.contains { $0.localizedStandardContains(query) })
        } : []
        reloadingTable = true
        table.reloadData()
        let index = showingApplications ? appRows.firstIndex { $0.id == selectedRecordID }
            : showingReports ? reportRows.firstIndex { $0.relativePath == selectedRecordID } : profileRows.firstIndex { $0.id == selectedRecordID }
        if let index { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        else { table.deselectAll(nil); selectedRecordID = nil; dismissReportPreview() }
        reloadingTable = false
        updateDetail()
    }
    func numberOfRows(in tableView: NSTableView) -> Int {
        showingApplications ? appRows.count : (showingReports ? reportRows.count : profileRows.count)
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("InspectorRecord")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? ManagerInspectorRecordCell ?? ManagerInspectorRecordCell()
        cell.identifier = id
        if showingApplications {
            let app = appRows[row]
            cell.title.stringValue = app.name
            cell.subtitle.stringValue = app.bundleIdentifier
            if device?.kind == .simulator, let path = app.bundlePath { cell.icon.image = NSWorkspace.shared.icon(forFile: path) }
            else { cell.icon.image = NSImage(systemSymbolName: "app", accessibilityDescription: nil) }
        } else if showingReports {
            let report = reportRows[row]
            cell.title.stringValue = report.name
            cell.subtitle.stringValue = [report.modificationDate?.formatted(date: .abbreviated, time: .shortened),
                report.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }].compactMap { $0 }.joined(separator: " · ")
            cell.icon.image = NSImage(systemSymbolName: report.resources.isDirectory ? "folder" : "doc.text", accessibilityDescription: nil)
        } else {
            let profile = profileRows[row]
            cell.title.stringValue = profile.name
            cell.subtitle.stringValue = profile.identifier
            cell.icon.image = NSImage(systemSymbolName: "doc.badge.gearshape", accessibilityDescription: nil)
        }
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !reloadingTable else { return }
        let row = table.selectedRow
        let id = row < 0 ? nil : (showingApplications ? appRows[row].id : (showingReports ? reportRows[row].relativePath : profileRows[row].id))
        if selectedRecordID != id { dismissReportPreview() }
        selectedRecordID = id
        updateDetail()
    }

    private func updateDetail() {
        iconTask?.cancel()
        iconTask = nil
        headerImage.image = nil
        headerName.stringValue = showingApplications ? "Select an Application" : (showingReports ? "Select a Report" : "Select a Profile")
        headerSubtitle.stringValue = ""
        headerSubtitle.toolTip = nil
        detail.setProperties([:])
        if let app = selectedApp {
            headerName.stringValue = app.name
            headerSubtitle.stringValue = app.bundleIdentifier
            detail.setProperties(app.metadata)
            if device?.kind == .simulator, let path = app.bundlePath { headerImage.image = NSWorkspace.shared.icon(forFile: path) }
            else { headerImage.image = NSImage(systemSymbolName: "app", accessibilityDescription: nil) }
            if supports("fetchappicons"), let inspector {
                let request = generation
                iconTask = Task { [weak self] in
                    do {
                        let data = try await inspector.applicationIcon(bundleIdentifier: app.bundleIdentifier)
                        guard let self, !Task.isCancelled, generation == request, selectedApp?.id == app.id else { return }
                        if let image = NSImage(data: data) { headerImage.image = image }
                    } catch {
                        guard let self, !Task.isCancelled, generation == request, selectedApp?.id == app.id else { return }
                        if let failure = error as? DeviceInspectorFailure,
                           case .cleanupFailed = failure.error as? DeviceInspectorError {
                            lastIssue = error.localizedDescription
                            updateControls()
                        }
                    }
                }
            }
        } else if let profile = selectedProfile {
            headerName.stringValue = profile.name
            headerSubtitle.stringValue = "Installed Profile Metadata"
            headerSubtitle.toolTip = "Installed payload bodies and entitlement values are not supplied by the device's public profile list."
            headerImage.image = NSImage(systemSymbolName: "doc.badge.gearshape", accessibilityDescription: nil)
            detail.setProperties(profile.metadata)
        } else if let report = selectedReport {
            headerName.stringValue = report.name
            headerSubtitle.stringValue = report.relativePath
            headerImage.image = NSImage(systemSymbolName: report.resources.isDirectory ? "folder" : "doc.text", accessibilityDescription: nil)
            var properties = report.metadata
            properties["relativePath"] = .string(report.relativePath)
            properties["fileExtension"] = .string(report.type.fileExtension)
            if let type = report.type.recordedLogType { properties["recordedLogType"] = .string(type) }
            if let bug = report.type.bugType { properties["bugType"] = .string(bug) }
            var resources: [String: DeviceInspectorValue] = ["isDirectory": .boolean(report.resources.isDirectory)]
            if let value = report.resources.isReadable { resources["isReadable"] = .boolean(value) }
            if let value = report.resources.isHidden { resources["isHidden"] = .boolean(value) }
            if let value = report.resources.isSymbolicLink { resources["isSymbolicLink"] = .boolean(value) }
            if let value = report.resources.isWritable { resources["isWritable"] = .boolean(value) }
            properties["resources"] = .object(resources)
            detail.setProperties(properties)
        }
        updateControls()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(NSMenuItem(title: "Actions", action: nil, keyEquivalent: ""))
        let items: [(String, Selector, Bool)] = [
            ("Show Container in Finder", #selector(revealContainer(_:)), simulatorIsRunning && selectedApp?.isContainerAccessible == true),
            ("Export Data…", #selector(exportData(_:)), canTransferData),
            ("Replace Data…", #selector(importData(_:)), canReplaceData),
        ]
        for (title, action, enabled) in items {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = available && enabled
            menu.addItem(item)
        }
        menu.autoenablesItems = false
    }

    private func reportType(_ report: DeviceReport) -> String {
        if let type = report.type.recordedLogType { return "Log Type: " + type }
        return report.type.fileExtension.isEmpty ? "No File Extension" : "." + report.type.fileExtension
    }

    private func rebuildReportFilter() {
        let types = Set(reports.map(reportType)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        if let reportTypeFilter, !types.contains(reportTypeFilter) { self.reportTypeFilter = nil }
        reportFilter.removeAllItems()
        reportFilter.addItems(withTitles: ["All Report Types"] + types)
        if let reportTypeFilter { reportFilter.selectItem(withTitle: reportTypeFilter) }
    }

    @objc private func changeReportFilter(_ sender: NSPopUpButton) {
        reportTypeFilter = sender.indexOfSelectedItem == 0 ? nil : sender.titleOfSelectedItem
        updateRows()
    }

    @objc private func openSelectedRecord(_ sender: Any?) {
        if showingReports { quickLookReport(sender) }
        else if showingApplications { launch(sender) }
    }

    @objc private func downloadReport(_ sender: Any?) {
        guard available, downloadButton.isEnabled, let report = selectedReport, let inspector, let window = view.window else { return }
        let panel = NSSavePanel()
        panel.title = "Download Report"
        panel.message = "Download \(report.name) from \(inspector.device.name)."
        panel.nameFieldStringValue = (report.relativePath as NSString).lastPathComponent
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.mutate(using: inspector) { _ = try await $0.downloadReport(report, to: url, replacingExistingFile: true) }
        }
    }

    @objc private func quickLookReport(_ sender: Any?) {
        guard available, previewButton.isEnabled, !preparingToQuit, let report = selectedReport, let inspector else { return }
        dismissReportPreview()
        let request = previewGeneration
        let taskID = UUID()
        let cache = URL.cachesDirectory.appending(path: "dev.lynnswap.NeoSimulator/ReportPreviews", directoryHint: .isDirectory)
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                previewTasks.removeValue(forKey: taskID)
                if previewGeneration == request { activePreviewTask = nil; updateControls() }
            }
            do {
                let preview = try await inspector.previewReport(report, in: cache)
                retainedPreviews[preview.url] = preview
                guard !Task.isCancelled, previewGeneration == request, !preparingToQuit,
                      device?.id == report.deviceID, selectedReport?.id == report.id else {
                    removePreview(preview)
                    return
                }
                currentPreview = preview
                let window = ManagerReportPreviewWindowController(report: report, deviceName: inspector.device.name, url: preview.url)
                window.onClose = { [weak self] in self?.dismissReportPreview(closeWindow: false) }
                previewWindow = window
                window.showWindow(nil)
            } catch {
                if let failure = error as? DeviceInspectorFailure, case .cleanupFailed(let directory, _, _) = failure.error as? DeviceInspectorError {
                    cleanupFailures[directory] = error
                    if !preparingToQuit { model.onError?(InspectorOperationFailure(deviceName: inspector.device.name, error: error)) }
                } else if !Task.isCancelled, previewGeneration == request {
                    lastIssue = error.localizedDescription
                }
            }
        }
        activePreviewTask = task
        previewTasks[taskID] = task
        updateControls()
    }

    private func dismissReportPreview(closeWindow: Bool = true) {
        previewGeneration += 1
        activePreviewTask?.cancel()
        activePreviewTask = nil
        let window = previewWindow
        previewWindow = nil
        if closeWindow { window?.close() }
        if let preview = currentPreview {
            currentPreview = nil
            removePreview(preview)
        }
        if isViewLoaded { updateControls() }
    }

    private func removePreview(_ preview: DeviceReportPreview) {
        guard cleanupInFlight.insert(preview.url).inserted else { return }
        let taskID = UUID()
        previewTasks[taskID] = Task { [weak self] in
            guard let self else { return }
            defer { cleanupInFlight.remove(preview.url); previewTasks.removeValue(forKey: taskID) }
            do {
                try await preview.removeCachedCopy()
                retainedPreviews.removeValue(forKey: preview.url)
                cleanupFailures.removeValue(forKey: preview.url)
            } catch {
                cleanupFailures[preview.url] = error
                if !preparingToQuit { model.onError?(InspectorOperationFailure(deviceName: preview.report.name, error: error)) }
            }
        }
    }

    func finishPreviews() async throws {
        preparingToQuit = true
        dismissReportPreview()
        for preview in Array(retainedPreviews.values) { removePreview(preview) }
        // A cancelled download can finish by scheduling its cache removal; drain both.
        while !previewTasks.isEmpty {
            for task in Array(previewTasks.values) { await task.value }
        }
        for (directory, original) in cleanupFailures where retainedPreviews[directory] == nil {
            do {
                try await removeFailedReportPreviewDirectory(directory)
                cleanupFailures.removeValue(forKey: directory)
            } catch {
                cleanupFailures[directory] = DeviceInspectorError.cleanupFailed(directory: directory, operationError: original, cleanupError: error)
            }
        }
        if let failure = cleanupFailures.values.first { throw failure }
    }

    func resumeAfterCancelledQuit() {
        preparingToQuit = false
        reload()
    }

    private func mutate(using inspector: DeviceInspector, operation: @escaping @Sendable (DeviceInspector) async throws -> Void) {
        let destination = inspector.device
        model.performInspectorOperation(for: destination, operation: { try await operation(inspector) }) { [weak self] in
            guard let self, self.device?.id == destination.id else { return }
            self.reload()
        }
    }

    @objc private func install(_ sender: Any?) {
        guard available, let inspector, let window = view.window else { return }
        let content = self.content
        let installsApplication = showingApplications
        let panel = NSOpenPanel()
        panel.message = installsApplication ? "Choose an application to install on \(inspector.device.name)." : "Choose a profile to install on \(inspector.device.name)."
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = installsApplication
            ? [UTType.applicationBundle]
            : [UTType(filenameExtension: content == .configuration ? "mobileconfig" : "mobileprovision") ?? .data]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.mutate(using: inspector) { inspector in
                if installsApplication { try await inspector.installApplication(at: url) }
                else { try await inspector.installProfile(at: url, kind: content.profileKind) }
            }
        }
    }
    @objc private func remove(_ sender: Any?) {
        guard available, removeButton.isEnabled, let inspector, let window = view.window else { return }
        let app = selectedApp
        let profile = selectedProfile
        guard app != nil || profile != nil else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove \(app?.name ?? profile!.name) from \(inspector.device.name)?"
        alert.informativeText = app != nil ? "The application and its data will be removed." : "Settings supplied by this profile will be removed."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.mutate(using: inspector) { inspector in
                if let app { try await inspector.uninstallApplication(bundleIdentifier: app.bundleIdentifier) }
                else if let profile { try await inspector.removeProfile(identifier: profile.identifier, kind: profile.kind) }
            }
        }
    }
    @objc private func launch(_ sender: Any?) {
        guard available, launchButton.isEnabled, let app = selectedApp, let inspector else { return }
        mutate(using: inspector) { try await $0.launchApplication(bundleIdentifier: app.bundleIdentifier) }
    }
    @objc private func revealContainer(_ sender: Any?) {
        guard available, simulatorIsRunning, let app = selectedApp, let inspector else { return }
        let request = generation
        revealTask = Task { [weak self] in
            do {
                let url = try await inspector.applicationContainerURL(bundleIdentifier: app.bundleIdentifier)
                guard let self, generation == request, !Task.isCancelled else { return }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                guard let self, generation == request, !Task.isCancelled else { return }
                lastIssue = error.localizedDescription
                updateControls()
            }
        }
    }
    @objc private func exportData(_ sender: Any?) {
        guard available, canTransferData, let app = selectedApp, let inspector, let window = view.window else { return }
        let panel = NSSavePanel()
        panel.title = "Export Application Data"
        panel.message = "Export data for \(app.name) on \(inspector.device.name)."
        panel.nameFieldStringValue = app.bundleIdentifier + ".xcappdata"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if let type = UTType(filenameExtension: "xcappdata") { panel.allowedContentTypes = [type] }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.mutate(using: inspector) {
                try await $0.downloadApplicationData(bundleIdentifier: app.bundleIdentifier, to: url, replacingExistingFile: true)
            }
        }
    }
    @objc private func importData(_ sender: Any?) {
        guard available, canReplaceData, let app = selectedApp, let inspector, let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose application data to replace \(app.name)’s data on \(inspector.device.name)."
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Replace \(app.name)’s data on \(inspector.device.name)?"
            alert.informativeText = "The application will be stopped and its current data replaced with the selected data."
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                self?.mutate(using: inspector) { try await $0.replaceApplicationData(bundleIdentifier: app.bundleIdentifier, from: url) }
            }
        }
    }
}

@concurrent private func removeFailedReportPreviewDirectory(_ directory: URL) async throws {
    do { try FileManager.default.removeItem(at: directory) }
    catch let error as CocoaError where error.code == .fileNoSuchFile {}
}
