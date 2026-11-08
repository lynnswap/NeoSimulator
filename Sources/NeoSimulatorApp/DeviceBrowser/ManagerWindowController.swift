import AppKit
import NeoSimulatorHostSupport
import NeoSimulatorKit
import NeoSimulatorPresentationAdapters
import NeoSimulatorUI
import Observation
import ObservationBridge
import SwiftUI
import NeoSimulatorManager
import NeoSimulatorCompactWindow
import NeoSimulatorDeviceScreens
import NeoSimulatorInspector
import NeoSimulatorSidebar

@MainActor
final class ManagerWindowController: NSWindowController, NSToolbarDelegate, NSToolbarItemValidation, NSMenuItemValidation,
                                     NSMenuDelegate {
    private let model: SimulatorManagerModel
    private let screens: DeviceScreens
    /// Device commands' shared shortcuts follow the live screen.
    private let menus: MenuController
    private let splitController = NSSplitViewController()
    private let artworkCache: DeviceArtworkCache
    let sidebar: DeviceSidebarViewController
    private(set) lazy var deviceScreenViewController: DeviceScreenViewController = {
        let pane = DeviceScreenViewController(model: model, screens: screens)
        pane.onViewScreen = { [weak self] in
            guard let self else { return }
            sidebar.model.open(selectedDevices)
        }
        pane.onLiveScreenChange = { [weak self] in
            self?.updateLiveScreenToolbarItems()
            self?.observeLiveScreenToolbar()
        }
        return pane
    }()
    var onNewCompanion: ((SimulatorHostDevice) -> Void)?
    var onShowServiceProfile: ((UUID) -> Void)?
    /// Reports a failed screen move that no caller awaits.
    var onError: ((any Error) -> Void)?
    /// The user's latest placement choice for the selected device's screen. Each choice advances the revision, so
    /// moves accepted for an earlier choice stop.
    private(set) var presentationIntent: (revision: Int, placement: SimulatorScreenRestoration.Presentation) = (0, .main)
    private var managementObservation: PortableObservationTracking.Token?
    private var liveScreenToolbarObservation: PortableObservationTracking.Token?
    /// The one selected device that the panes last showed.
    private var selectionIdentifier: DeviceInventoryID?
    private let compactIdentifier = NSToolbarItem.Identifier("CompactDeviceWindow")
    private let resizeAppIdentifier = NSToolbarItem.Identifier("resizeApp")
    private let captureKeyboardIdentifier = NSToolbarItem.Identifier("captureKeyboard")
    private let canvasZoomIdentifier = NSToolbarItem.Identifier("CanvasZoom")
    private let moreIdentifier = NSToolbarItem.Identifier("CanvasMoreActions")
    private var moreItem: NSMenuToolbarItem?
    private(set) lazy var inspectorController: InspectorViewController = {
        let inspector = InspectorModel(manager: model, screens: screens, defaults: defaults,
            showProfileSettings: { [weak self] in self?.onShowServiceProfile?($0) },
            showCustomLocation: { [weak self] in
                guard let self, let identifier = self.model.selection.device?.id else { return }
                self.presentLocationEditor(for: identifier)
            })
        return InspectorViewController(model: inspector, manager: model,
            pairingMenu: { [weak self] in self?.pairingMenu(for: $0) ?? NSMenu() },
            deviceMenu: { [weak self] device in
                let menu = NSMenu(title: "Device Actions")
                self?.populateDeviceMenu(menu, devices: [.simulator(device)])
                return menu
            })
    }()
    private let inspectorIdentifier = InspectorViewController.toolbarIdentifier
    /// The window's selection, which the sidebar makes.
    var selectedIdentifiers: Set<DeviceInventoryID> { sidebar.model.selectedIdentifiers }
    private var selectedDevices: [InventoryDevice] { sidebar.model.selectedDevices }
    private let defaults: UserDefaults
    private var sidebarObservation: NSKeyValueObservation?
    private var toolbarAppearanceObservation: NSKeyValueObservation?
    private var windowCommandObservers: [any NSObjectProtocol] = []
    private let settingsIdentifier = NSToolbarItem.Identifier("Settings")
    private let filterIdentifier = DeviceSidebarViewController.filterToolbarIdentifier

    init(model: SimulatorManagerModel, screens: DeviceScreens, menus: MenuController, defaults: UserDefaults = .standard,
         splitViewAutosaveName: NSSplitView.AutosaveName? = nil) {
        self.model = model
        self.screens = screens
        self.menus = menus
        self.defaults = defaults
        let artworkCache = DeviceArtworkCache()
        self.artworkCache = artworkCache
        sidebar = DeviceSidebarViewController(model: DeviceSidebarModel(manager: model, defaults: defaults),
                                              screens: screens, artworkCache: artworkCache)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "NeoSimulator"
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.toolbarStyle = .unified
        super.init(window: window)
        sidebar.onSelectionChange = { [weak self] in self?.sidebarSelectionChanged(byUser: $0) }
        sidebar.populateDeviceMenu = { [weak self] in self?.populateDeviceMenu($0, devices: $1) }
        let sidebarItem = sidebar.makeSplitViewItem()
        splitController.addSplitViewItem(sidebarItem)
        buildDevicePane()
        splitController.addSplitViewItem(inspectorController.makeSplitViewItem())
        splitController.splitView.autosaveName = splitViewAutosaveName
        splitController.view.heightAnchor.constraint(greaterThanOrEqualToConstant: 480).isActive = true
        window.contentViewController = splitController
        let toolbar = NSToolbar(identifier: "NeoSimulatorDevices")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        for name in [NSWindow.willBeginSheetNotification, NSWindow.didEndSheetNotification,
                     NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            windowCommandObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.updateLiveScreenToolbar() }
            })
        }
        toolbarAppearanceObservation = window.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.updateToolbarAppearance() }
        }
        sidebarObservation = sidebarItem.observe(\.isCollapsed, options: [.initial, .new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.updateSidebarToolbarItems() }
        }
        window.setContentSize(NSSize(width: 1040, height: 700))
        window.center()
        window.setFrameAutosaveName("NeoSimulatorDevices")
        sidebar.update()
        observeManagement()
    }

    required init?(coder: NSCoder) { nil }

    isolated deinit {
        for observer in windowCommandObservers { NotificationCenter.default.removeObserver(observer) }
    }

    /// Follows the sidebar's selection, and places the screen of a device that the user or the inventory newly selects.
    private func sidebarSelectionChanged(byUser: Bool) {
        if byUser { requestPresentation(.main) }
        let previous = selectionIdentifier
        updateSelection()
        if byUser || selectionIdentifier != previous { selectedDeviceChanged(selectionIdentifier) }
    }

    /// What can be done with the selection changes with what the manager is doing.
    private func observeManagement() {
        managementObservation = withPortableContinuousObservation { [weak self, model] event in
            _ = model.managingDeviceIDs
            _ = model.isBusy
            _ = model.holdsAllEdits
            _ = model.queuedDeviceIDs
            _ = model.openingDeviceIDs
            guard event.kind != .initial else { return }
            Task { @MainActor [weak self] in self?.updateSelection() }
        }
    }

    private func buildDevicePane() {
        let pane = deviceScreenViewController
        let content = NSSplitViewItem(viewController: pane)
        content.minimumThickness = 280
        content.holdingPriority = .defaultLow
        pane.canvasAccessory.onMinimumWidthChange = { [weak self] in self?.updateCanvasMinimumWidth($0) }
        content.addBottomAlignedAccessoryViewController(pane.canvasAccessory)
        splitController.addSplitViewItem(content)
    }

    func stopInspectorReads() { inspectorController.stopReading() }
    func finishInspectorPreviews() async throws { try await inspectorController.finishPreviews() }
    func resumeInspectorAfterCancelledQuit() { inspectorController.resumeAfterCancelledQuit() }

    private func updateSelection() {
        let selections = selectedDevices
        let selectedDevice = selections.count == 1 ? selections.first : nil
        window?.title = selectedDevice?.name ?? "NeoSimulator"
        window?.subtitle = selectedDevice?.operatingSystem ?? ""
        moreItem?.isHidden = selectedDevice == nil
        selectionIdentifier = selectedDevice?.id
        if let device = selectedDevice {
            let details: String
            if case .simulator(let simulator) = device { details = "\(simulator.runtimeName) Simulator" }
            else {
                details = [device.operatingSystem, device.modelName, device.kindTitle]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            }
            deviceScreenViewController.updatePreview(for: device, details: details,
                                                     artwork: artworkCache.artwork(for: device, screens: screens, manager: model),
                                                     canViewScreen: model.canViewScreen(device))
        } else {
            deviceScreenViewController.updatePreview(selectionCount: selections.count)
        }
        model.inspect(selectedDevice, selectionCount: selections.count)
    }

    func selectDevice(_ identifier: DeviceInventoryID) {
        sidebar.select(identifier)
        updateSelection()
    }

    /// Selects the device for the main window and shows its screen there once it is open, bringing the window forward.
    func showDevice(_ identifier: DeviceInventoryID) {
        requestPresentation(.main)
        selectDevice(identifier)
        selectedDeviceChanged(identifier, preservingFocus: false)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Places the selected screen using the latest choice. Other automatically connected
    /// screens keep `presentation`, or their current placement if none is supplied.
    func presentConnectedScreen(_ identifier: DeviceInventoryID, purpose: SimulatorPresentationContext.Purpose,
                                preserving presentation: SimulatorScreenRestoration.Presentation? = nil) async throws {
        try Task.checkCancellation()
        guard !screens.isQuitting, let screen = screens.screen(for: identifier) else { return }
        if sidebar.model.savedSelection.isEmpty, presentationIntent.revision == 0, purpose != .requested {
            selectDevice(identifier)
            requestPresentation(.main)
        }
        let revision = presentationIntent.revision
        let selected = selectedIdentifiers == [identifier]
        guard selected || purpose == .automatic else { return }
        switch selected ? presentationIntent.placement : presentation ?? screen.presentation {
        case .main:
            guard selected else { return }
            try await deviceScreenViewController.embedScreen(for: identifier, preservingFocus: purpose == .automatic,
                                                             while: { self.isCurrentPresentation(identifier, revision: revision) })
        case .compact:
            try await deviceScreenViewController.showCompactWindow(of: screen, unlessCompact: true, while: {
                self.presentationIntent.revision == revision || self.selectedIdentifiers != [identifier]
            })
        case .hidden: break
        }
    }

    /// Reopens a screen that was open before relaunching, in its saved presentation unless the user chooses one for
    /// the device first.
    func restoreScreen(_ restoration: SimulatorScreenRestoration) {
        let identifier = restoration.deviceID
        let revision = presentationIntent.revision
        model.restoreScreen(restoration) { [weak self] in
            guard let self, let screen = screens.screen(for: identifier) else { return }
            let pane = deviceScreenViewController
            let keepsRestoredPresentation: @MainActor () -> Bool = {
                self.presentationIntent.revision == revision || self.selectedIdentifiers != [identifier]
            }
            switch restoration.presentation {
            case .main:
                // Opening the screen already embeds it in the main window; the restore finishes after that move.
                await pane.waitForScreenMoves()
            case .compact:
                try await pane.showCompactWindow(of: screen, while: keepsRestoredPresentation)
                if presentationIntent.revision == revision { window?.orderOut(nil) }
            case .hidden:
                try await pane.detachScreen(screen, while: keepsRestoredPresentation)
            }
        }
    }

    private func requestPresentation(_ placement: SimulatorScreenRestoration.Presentation) {
        presentationIntent.revision += 1
        presentationIntent.placement = placement
    }

    private func isCurrentPresentation(_ identifier: DeviceInventoryID, revision: Int) -> Bool {
        !screens.isQuitting && presentationIntent.revision == revision && selectedIdentifiers == [identifier]
    }

    /// Embeds the selected device's open screen, or detaches the live screen when the selection has none.
    private func selectedDeviceChanged(_ identifier: DeviceInventoryID?, preservingFocus: Bool = true) {
        let revision = presentationIntent.revision
        Task { [weak self] in
            guard let self else { return }
            let pane = deviceScreenViewController
            do {
                if let identifier, screens.screen(for: identifier) != nil {
                    try await pane.embedScreen(for: identifier, preservingFocus: preservingFocus,
                                               while: { self.isCurrentPresentation(identifier, revision: revision) })
                } else {
                    try await pane.detachLiveScreen(while: { self.presentationIntent.revision == revision })
                }
            } catch is CancellationError {}
            catch { onError?(error) }
        }
    }

    private func updateLiveScreenToolbarItems() {
        let hasScreen = deviceScreenViewController.liveDeviceIdentifier != nil
        for item in window?.toolbar?.items ?? [] {
            switch item.itemIdentifier {
            case moreIdentifier:
                item.isHidden = selectedDevices.count != 1
                item.isEnabled = validateToolbarItem(item)
            case compactIdentifier:
                item.isHidden = !hasScreen
                item.isEnabled = validateToolbarItem(item)
            case resizeAppIdentifier, captureKeyboardIdentifier, canvasZoomIdentifier:
                if !hasScreen { item.isHidden = true; item.isEnabled = false }
            default: break
            }
        }
    }

    private func updateCanvasMinimumWidth(_ width: CGFloat) {
        let item = splitController.splitViewItems[1]
        let minimum = max(280, width)
        if item.minimumThickness != minimum { item.minimumThickness = minimum }
    }

    override func supplementalTarget(forAction action: Selector, sender: Any?) -> Any? {
        if let target = deviceScreenViewController.liveCommandTarget {
            switch action {
            case #selector(RemoteDeviceWindowController.saveScreenshot(_:)),
                 #selector(RemoteDeviceWindowController.discardScreenshot(_:)),
                 #selector(RemoteDeviceWindowController.recordScreen(_:)),
                 #selector(RemoteDeviceWindowController.recordScreenTo(_:)),
                 #selector(RemoteDeviceWindowController.stopScreenRecording(_:)),
                 #selector(RemoteDeviceWindowController.saveScreenRecording(_:)),
                 #selector(RemoteDeviceWindowController.discardScreenRecording(_:)),
                 #selector(RemoteDeviceWindowController.chooseCaptureSource(_:)):
                if target.responds(to: action) { return target }
            default: break
            }
        }
        return super.supplementalTarget(forAction: action, sender: sender)
    }

    /// Follows the live screen's state for its toolbar items and the device commands' shared shortcuts.
    private func observeLiveScreenToolbar() {
        liveScreenToolbarObservation?.cancel()
        liveScreenToolbarObservation = withPortableContinuousObservation { [weak self] _ in
            self?.updateLiveScreenToolbar()
        }
    }

    private func updateLiveScreenToolbar() {
        updateLiveScreenToolbarItems()
        guard let screen = deviceScreenViewController.liveScreen else { return }
        menus.updateKeyEquivalents(for: screen.simulatorCapabilities)
        let blocked = window?.attachedSheet != nil
        if let item = window?.toolbar?.items.first(where: { $0.itemIdentifier == resizeAppIdentifier }) {
            let resizingApp = screen.resizingApp
            let title = resizingApp ? "Stop Resize" : "Resize App"
            if item.label != title { item.label = title }
            if item.toolTip != title { item.toolTip = title }
            item.menuFormRepresentation?.title = title
            if let button = item.view as? NSButton {
                button.toolTip = title
                button.setAccessibilityLabel(title)
            }
            let hidden = !screen.supports("resizeApp")
            let enabled = screen.isEnabled("resizeApp") && !blocked
            if item.isHidden != hidden { item.isHidden = hidden }
            if item.isEnabled != enabled { item.isEnabled = enabled }
            item.menuFormRepresentation?.isEnabled = item.isEnabled
            item.menuFormRepresentation?.state = resizingApp ? .on : .off
            if let button = item.view as? NSButton {
                let state: NSControl.StateValue = resizingApp ? .on : .off
                if button.state != state { button.state = state }
                if button.isEnabled != item.isEnabled { button.isEnabled = item.isEnabled }
            }
        }
        if let item = window?.toolbar?.items.first(where: { $0.itemIdentifier == captureKeyboardIdentifier }) {
            let capturesKeyboard = screen.capturesKeyboard
            let hidden = !screen.supports("captureKeyboard")
            let enabled = screen.isEnabled("captureKeyboard") && !blocked
            if item.isHidden != hidden { item.isHidden = hidden }
            if item.isEnabled != enabled { item.isEnabled = enabled }
            item.menuFormRepresentation?.state = capturesKeyboard ? .on : .off
            item.menuFormRepresentation?.isEnabled = item.isEnabled
            if let button = item.view as? NSButton {
                let state: NSControl.StateValue = capturesKeyboard ? .on : .off
                if button.state != state { button.state = state }
                if button.isEnabled != item.isEnabled { button.isEnabled = item.isEnabled }
                button.toolTip = capturesKeyboard ? "Release Keyboard — or hold Escape for one second." : "Capture Keyboard"
            }
        }
        if let group = window?.toolbar?.items.first(where: { $0.itemIdentifier == canvasZoomIdentifier }) as? NSToolbarItemGroup {
            let hidden = !screen.supports(CanvasZoom.Action.fit.rawValue)
            if group.isHidden != hidden { group.isHidden = hidden }
            let enabledActions = CanvasZoom.Action.allCases.map { screen.isEnabled($0.rawValue) && !blocked }
            let enabled = enabledActions.contains(true)
            if group.isEnabled != enabled { group.isEnabled = enabled }
            for (index, enabled) in enabledActions.enumerated() {
                if group.subitems[index].isEnabled != enabled { group.subitems[index].isEnabled = enabled }
            }
            for action in group.menuFormRepresentation?.submenu?.items ?? [] {
                action.state = screen.canvasZoomIsSelected(CanvasZoom.Action.allCases[action.tag].rawValue) ? .on : .off
            }
            if let selected = CanvasZoom.Action.allCases.firstIndex(where: { screen.canvasZoomIsSelected($0.rawValue) }) {
                if !group.isSelected(at: selected) { group.setSelected(true, at: selected) }
            } else if group.selectedIndex >= 0 {
                // selectOne rejects clearing its last selection, including selectedIndex = -1.
                group.selectionMode = .selectAny
                for index in group.subitems.indices { group.setSelected(false, at: index) }
                group.selectionMode = .selectOne
            }
        }
    }

    @objc private func resizeApp(_ sender: Any?) {
        deviceScreenViewController.liveScreen?.perform("resizeApp")
    }

    @objc private func captureKeyboard(_ sender: Any?) { deviceScreenViewController.liveScreen?.perform("captureKeyboard") }

    @objc private func performCanvasZoom(_ sender: NSToolbarItemGroup) {
        performCanvasZoom(at: sender.selectedIndex)
    }

    @objc private func performCanvasZoomFromMenu(_ sender: NSMenuItem) {
        performCanvasZoom(at: sender.tag)
    }

    private func performCanvasZoom(at index: Int) {
        guard CanvasZoom.Action.allCases.indices.contains(index) else { return }
        deviceScreenViewController.liveScreen?.perform(CanvasZoom.Action.allCases[index].rawValue)
    }

    @objc private func showCompactDeviceWindow(_ sender: Any?) {
        guard let identifier = deviceScreenViewController.liveDeviceIdentifier, window?.attachedSheet == nil,
              window?.styleMask.contains(.fullScreen) == false, selectedIdentifiers == [identifier] else { return }
        requestPresentation(.compact)
        let revision = presentationIntent.revision
        Task { [weak self] in
            guard let self else { return }
            do {
                try await deviceScreenViewController.switchToCompactWindow(for: identifier, while: {
                    self.isCurrentPresentation(identifier, revision: revision)
                })
                // The compact window replaces this one, unless a later choice or the screen's close stopped the move.
                if isCurrentPresentation(identifier, revision: revision), screens.screen(for: identifier) != nil {
                    window?.orderOut(nil)
                }
            } catch is CancellationError {}
            catch { onError?(error) }
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let action: String
        switch item.action {
        case #selector(captureKeyboard(_:)): action = "captureKeyboard"
        case #selector(resizeApp(_:)): action = "resizeApp"
        case #selector(performCanvasZoomFromMenu(_:)):
            guard CanvasZoom.Action.allCases.indices.contains(item.tag) else { return false }
            action = CanvasZoom.Action.allCases[item.tag].rawValue
        case #selector(showCompactDeviceWindow(_:)):
            return deviceScreenViewController.liveDeviceIdentifier != nil && window?.attachedSheet == nil && window?.styleMask.contains(.fullScreen) == false
        default: return true
        }
        return deviceScreenViewController.liveScreen?.isEnabled(action) == true && window?.attachedSheet == nil
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        if item.itemIdentifier == moreIdentifier {
            return selectedDevices.count == 1 && window?.attachedSheet == nil
        }
        if item.itemIdentifier == compactIdentifier {
            return deviceScreenViewController.liveDeviceIdentifier != nil && window?.attachedSheet == nil && window?.styleMask.contains(.fullScreen) == false
        }
        return true
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
        for item in window?.toolbar?.items ?? [] where item.itemIdentifier == settingsIdentifier || item.itemIdentifier == filterIdentifier {
            item.isHidden = hidden
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .flexibleSpace, settingsIdentifier, filterIdentifier, .sidebarTrackingSeparator,
         .flexibleSpace, captureKeyboardIdentifier, resizeAppIdentifier, canvasZoomIdentifier, compactIdentifier, moreIdentifier, .inspectorTrackingSeparator, .flexibleSpace, inspectorIdentifier]
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
            item.isHidden = deviceScreenViewController.liveDeviceIdentifier == nil
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
            item.isHidden = deviceScreenViewController.liveDeviceIdentifier == nil
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
            item.controlRepresentation = .automatic
            item.isHidden = deviceScreenViewController.liveDeviceIdentifier == nil
            let menu = NSMenu(title: item.label)
            for (index, label) in labels.enumerated() {
                let action = NSMenuItem(title: label, action: #selector(performCanvasZoomFromMenu(_:)), keyEquivalent: "")
                action.target = self
                action.tag = index
                menu.addItem(action)
            }
            let representation = NSMenuItem(title: item.label, action: nil, keyEquivalent: "")
            representation.submenu = menu
            item.menuFormRepresentation = representation
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
            item.isHidden = deviceScreenViewController.liveDeviceIdentifier == nil
            return item
        }
        if itemIdentifier == inspectorIdentifier { return inspectorController.makeToolbarItem() }
        if itemIdentifier == settingsIdentifier {
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Settings"
            item.toolTip = "Settings"
            item.image = NSImage(systemSymbolName: "gear", accessibilityDescription: "Settings")
            item.target = NSApp.delegate
            item.action = #selector(AppDelegate.showSettings(_:))
            item.visibilityPriority = .high
            return item
        }
        if itemIdentifier == filterIdentifier { return sidebar.makeFilterToolbarItem() }
        return nil
    }

    private struct ManagementRequest {
        let action: DeviceManagementAction
        let identifiers: Set<DeviceInventoryID>
    }

    func menuForSelectedDevices() -> NSMenu {
        let menu = NSMenu(title: "Device")
        menu.autoenablesItems = false
        populateDeviceMenu(menu, devices: sidebar.visibleSelectedDevices)
        return menu
    }

    private func populateDeviceMenu(_ menu: NSMenu, devices: [InventoryDevice], includesViewScreen: Bool = true) {
        menu.removeAllItems()
        let identifiers = Set(devices.map(\.id))
        if includesViewScreen, devices.count == 1, model.canViewScreen(devices[0]) {
            let title = model.openingDeviceIDs.contains(devices[0].id) ? "Cancel Opening" : "View Screen"
            let item = NSMenuItem(title: title, action: #selector(openDeviceFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = devices[0].id
            item.isEnabled = true
            menu.addItem(item)
        }
        if devices.count == 1, case .remote = devices[0], devices[0].id == deviceScreenViewController.liveDeviceIdentifier,
           let controller = deviceScreenViewController.liveCommandTarget as? RemoteDeviceWindowController {
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
        var addedDestructiveSection = false
        for (title, action) in operations where model.supports(action, devices: devices) {
            if !menu.items.isEmpty, case .rename = action { menu.addItem(.separator()) }
            switch action {
            case .unpair, .erase, .remove:
                if !addedDestructiveSection && !menu.items.isEmpty { menu.addItem(.separator()) }
                addedDestructiveSection = true
            default: break
            }
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
            let submenu = pairingMenu(for: phone)
            pairing.submenu = submenu
            pairing.isEnabled = submenu.items.contains { $0.action != nil && $0.isEnabled }
            menu.addItem(pairing)
        }
        if device.supports(.remove) {
            separate()
            add("Remove…", symbol: "trash", action: .remove)
        }
    }

    func pairingMenu(for device: SimulatorHostDevice) -> NSMenu {
        SimulatorPairingMenu.make(for: device, model: model, target: self, action: #selector(performPairingMenuAction(_:)))
    }

    @objc func performPairingMenuAction(_ sender: NSMenuItem) {
        switch sender.representedObject as? SimulatorPairingMenu.Action {
        case .pair(let identifiers):
            let devices = model.inventory.filter { identifiers.contains($0.id) }
            guard model.supports(.pair, devices: devices),
                  let phone = devices.compactMap({ if case .simulator(let device) = $0, device.productFamily == "iPhone" { device } else { nil } }).first,
                  model.pairingCandidates(for: phone).contains(where: { identifiers.contains($0.inventoryID) }),
                  model.canManage(.pair, deviceIDs: identifiers) else { return }
            model.manage(.pair, devices: devices)
        case .newCompanion(let identifier):
            guard let device = model.inventory.first(where: { $0.id == identifier }),
                  case .simulator(let simulator) = device, model.canAddPairing(for: simulator),
                  model.canManage(.pair, deviceIDs: [identifier]) else { return }
            onNewCompanion?(simulator)
        case nil: break
        }
    }

    @objc private func openDeviceFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? DeviceInventoryID,
              let device = model.inventory.first(where: { $0.id == id }) else { return }
        sidebar.model.open([device])
    }

    @objc private func lockDeviceFromMenu(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? DeviceInventoryID,
              let screen = deviceScreenViewController.liveScreen, screen.id == identifier else { return }
        screen.perform("lock")
    }

    @objc private func performManagement(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? ManagementRequest else { return }
        let devices = model.inventory.filter { request.identifiers.contains($0.id) }
        guard devices.count == request.identifiers.count, model.supports(request.action, devices: devices),
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

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === moreItem?.menu { updateCanvasMenu(menu) }
    }
}
