import AppKit
import NeoSimulatorCompactWindow
import NeoSimulatorDeviceDisplay
import NeoSimulatorDeviceScreens
import NeoSimulatorHostSupport
import NeoSimulatorInspector
import NeoSimulatorKit
import NeoSimulatorManager
import NeoSimulatorSidebar
import ObservationBridge

/// Composes the sidebar, the device pane, and the inspector in the manager window. The sidebar's selection decides
/// what the other panes describe, and the window places the selected device's screen.
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
        let pane = DeviceScreenViewController(model: model, screens: screens, artworkCache: artworkCache)
        pane.onViewScreen = { [weak self] in
            guard let self else { return }
            if selectedDevices.count == 1, model.needsHostPairing(selectedDevices[0]) {
                deviceActions.pairDevice(selectedDevices[0])
            } else {
                sidebar.model.open(selectedDevices)
            }
        }
        pane.onLiveScreenChange = { [weak self] in
            self?.updateLiveScreenToolbarItems()
            self?.observeLiveScreenToolbar()
        }
        return pane
    }()
    private(set) lazy var deviceActions = DeviceActions(model: model, window: window,
        liveScreen: { [weak self] in self?.deviceScreenViewController.liveScreen })
    var onShowServiceProfile: ((UUID) -> Void)?
    /// Reports a failed screen move that no caller awaits.
    var onError: ((any Error) -> Void)?
    /// The user's latest placement choice for the selected device's screen. Each choice advances the revision, so
    /// moves accepted for an earlier choice stop.
    private(set) var presentationIntent: (revision: Int, placement: SimulatorScreenRestoration.Presentation) = (0, .main)
    private var liveScreenToolbarObservation: PortableObservationTracking.Token?
    /// The one selected device that the panes last showed.
    private var selectionIdentifier: DeviceInventoryID?
    private let compactIdentifier = NSToolbarItem.Identifier("CompactDeviceWindow")
    private let resizeAppIdentifier = DeviceScreenViewController.resizeAppIdentifier
    private let captureKeyboardIdentifier = DeviceScreenViewController.captureKeyboardIdentifier
    private let canvasZoomIdentifier = DeviceScreenViewController.canvasZoomIdentifier
    private let moreIdentifier = NSToolbarItem.Identifier("CanvasMoreActions")
    private var moreItem: NSMenuToolbarItem?
    private(set) lazy var inspectorController: InspectorViewController = {
        let inspector = InspectorModel(manager: model, screens: screens, defaults: defaults,
            showProfileSettings: { [weak self] in self?.onShowServiceProfile?($0) },
            showCustomLocation: { [weak self] in
                guard let self, let identifier = self.model.selection.device?.id else { return }
                self.deviceActions.presentLocationEditor(for: identifier)
            })
        return InspectorViewController(model: inspector, manager: model,
            pairingMenu: { [weak self] in self?.deviceActions.pairingMenu(for: $0) ?? NSMenu() },
            deviceMenu: { [weak self] device in
                let menu = NSMenu(title: "Device Actions")
                self?.deviceActions.populate(menu, devices: [.simulator(device)])
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
        sidebar.onOpenCompactScreen = { [weak self] in self?.openCompactScreen(for: $0) }
        screens.onCompactWindowClosed = { [weak self] identifier in
            guard let self, self.selectedIdentifiers == [identifier], self.presentationIntent.placement == .compact
            else { return }
            self.requestPresentation(.main)
        }
        model.onScreenOpenFailure = { [weak screens] in screens?.showCompactWindowFailure($1, for: $0) }
        screens.makeCompactPreview = { [weak self] device in
            guard let self else { return NSViewController() }
            let preview = DeviceScreenViewController(
                model: self.model, screens: self.screens, artworkCache: self.artworkCache, previewVerticalOffset: 24)
            preview.showPreview(of: device, selectionCount: 1)
            preview.onViewScreen = { [weak self] in
                guard let self, let device = self.model.inventory.first(where: { $0.id == device.id }) else { return }
                if self.model.needsHostPairing(device) {
                    self.deviceActions.pairDevice(device, in: self.screens.compactWindow(for: device.id))
                } else {
                    self.model.toggleScreen(for: device)
                }
                self.screens.compactWindow(for: device.id)?.makeKeyAndOrderFront(nil)
            }
            return preview
        }
        screens.makeCompactDeviceMenu = { [weak self] device, window in
            let menu = NSMenu(title: "Device Actions")
            guard let self, let current = self.model.inventory.first(where: { $0.id == device.id }) else { return menu }
            self.deviceActions.populate(menu, devices: [current], window: window)
            return menu
        }
        sidebar.populateDeviceMenu = { [weak self] in
            self?.deviceActions.populate($0, devices: $1, includesViewScreen: false)
        }
        let sidebarItem = sidebar.makeSplitViewItem()
        splitController.addSplitViewItem(sidebarItem)
        splitController.addSplitViewItem(deviceScreenViewController.makeSplitViewItem())
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
        deviceScreenViewController.showPreview(of: selectedDevice, selectionCount: selections.count)
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
        let compactWindow = screens.compactWindow(for: identifier)
        let hasCompactWindow = compactWindow != nil
        guard selected || purpose == .automatic || hasCompactWindow else { return }
        switch hasCompactWindow
            ? .compact : selected ? presentationIntent.placement : presentation ?? screen.presentation
        {
        case .main:
            guard selected else { return }
            try await deviceScreenViewController.embedScreen(for: identifier, preservingFocus: purpose == .automatic,
                                                             while: { self.isCurrentPresentation(identifier, revision: revision) })
        case .compact:
            var embeddingFailure: (any Error)?
            if selected {
                do {
                    try await deviceScreenViewController.embedScreen(
                        for: identifier, preservingFocus: purpose == .automatic,
                        while: { self.isCurrentPresentation(identifier, revision: revision) })
                } catch { embeddingFailure = error }
            }
            try await deviceScreenViewController.showCompactWindow(of: screen, unlessCompact: true, while: {
                    !self.screens.isQuitting && self.screens.screen(for: identifier) === screen
                        && (compactWindow == nil || self.screens.compactWindow(for: identifier) === compactWindow)
            })
            if let embeddingFailure { throw embeddingFailure }
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

    /// The window's items that follow the live screen: its compact window and the selected device's actions.
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
            default: break
            }
        }
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

    /// Follows the live screen for the window's toolbar items and the device commands' shared shortcuts.
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
    }

    private func openCompactScreen(for device: InventoryDevice) {
        screens.prepareCompactWindow(for: device)
        if screens.screen(for: device.id) == nil {
            if !model.openingDeviceIDs.contains(device.id) { model.openScreen(for: device) }
            requestPresentation(.compact)
            screens.prepareCompactWindow(for: device)
        } else {
            showCompactScreen(for: device.id)
        }
    }

    @objc private func showCompactDeviceWindow(_ sender: Any?) {
        guard let identifier = deviceScreenViewController.liveDeviceIdentifier else { return }
        showCompactScreen(for: identifier)
    }

    private func showCompactScreen(for identifier: DeviceInventoryID) {
        guard selectedIdentifiers == [identifier] else { return }
        if let device = selectedDevices.first { screens.prepareCompactWindow(for: device) }
        requestPresentation(.compact)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await deviceScreenViewController.switchToCompactWindow(for: identifier, while: {
                        !self.screens.isQuitting && self.screens.compactWindow(for: identifier) != nil
                })
            } catch is CancellationError {}
            catch { onError?(error) }
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(showCompactDeviceWindow(_:)):
            return deviceScreenViewController.liveDeviceIdentifier != nil
        case #selector(saveServiceProfile(_:)):
            return canSaveServiceProfile
        default:
            return true
        }
    }

    private var canSaveServiceProfile: Bool {
        window?.attachedSheet == nil && inspectorController.canSaveServiceProfile
    }

    @objc func saveServiceProfile(_ sender: Any?) {
        guard canSaveServiceProfile else { return }
        inspectorController.saveServiceProfile()
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        if item.itemIdentifier == moreIdentifier {
            return selectedDevices.count == 1 && window?.attachedSheet == nil
        }
        if item.itemIdentifier == compactIdentifier {
            return deviceScreenViewController.liveDeviceIdentifier != nil && window?.attachedSheet == nil
        }
        return true
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
        if [resizeAppIdentifier, captureKeyboardIdentifier, canvasZoomIdentifier].contains(itemIdentifier) {
            return deviceScreenViewController.makeToolbarItem(itemIdentifier)
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
            item.label = "Open Compact Window"
            item.toolTip = "Open Compact Window"
            item.image = NSImage(
                systemSymbolName: "arrow.up.forward.and.arrow.down.backward",
                accessibilityDescription: "Open Compact Window")
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

    func menuForSelectedDevices() -> NSMenu {
        let menu = NSMenu(title: "Device")
        menu.autoenablesItems = false
        deviceActions.populate(menu, devices: sidebar.visibleSelectedDevices)
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === moreItem?.menu else { return }
        menu.removeAllItems()
        guard selectedDevices.count == 1, let device = selectedDevices.first else { return }
        deviceActions.populateScreenMenu(menu, for: device)
    }
}
