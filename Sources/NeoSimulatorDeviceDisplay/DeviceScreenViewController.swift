import AppKit
import NeoSimulatorDeviceScreens
import NeoSimulatorHostSupport
import NeoSimulatorKit
import NeoSimulatorManager
import NeoSimulatorPresentationAdapters
import NeoSimulatorUI
import Observation
import ObservationBridge

/// Shows the selected device's screen or preview in the manager's center pane, with the toolbar items and the
/// canvas accessory that act on that screen. The window owns the selection and where each screen goes.
/// Closing or replacing the screen restores the preview.
///
/// Screen moves follow acceptance order and recheck the window's latest choice after each await.
@MainActor
package final class DeviceScreenViewController: NSViewController, NSMenuItemValidation {
    package static let resizeAppIdentifier = NSToolbarItem.Identifier("resizeApp")
    package static let captureKeyboardIdentifier = NSToolbarItem.Identifier("captureKeyboard")
    package static let canvasZoomIdentifier = NSToolbarItem.Identifier("CanvasZoom")

    private let model: SimulatorManagerModel
    private let screens: DeviceScreens
    private let artworkCache: DeviceArtworkCache
    private let previewVerticalOffset: CGFloat
    let liveScreenContainer = NSViewController()
    let canvasAccessory = DeviceCanvasAccessoryViewController()
    private weak var splitViewItem: NSSplitViewItem?
    private weak var resizeAppItem: NSToolbarItem?
    private weak var captureKeyboardItem: NSToolbarItem?
    private weak var canvasZoomItem: NSToolbarItemGroup?
    private var toolbarObservation: PortableObservationTracking.Token?
    private var windowObservers: [any NSObjectProtocol] = []
    /// The screen in `liveScreenContainer`, until the pane shows the preview again.
    private var displayedScreen: DeviceScreen?
    private var displayedScreenObservation: PortableObservationTracking.Token?
    /// The displayed screen while it is still open; a closed or replaced screen no longer counts as live.
    package var liveScreen: DeviceScreen? {
        guard let displayedScreen, screens.screen(for: displayedScreen.id) === displayedScreen else { return nil }
        return displayedScreen
    }
    package var liveDeviceIdentifier: DeviceInventoryID? { liveScreen?.id }
    package var liveCommandTarget: NSResponder? { liveScreen?.commandTarget }
    package var onLiveScreenChange: (() -> Void)?
    package var onViewScreen: (() -> Void)?
    /// The one selected device that the preview describes.
    private var previewDevice: InventoryDevice?
    private var previewObservation: PortableObservationTracking.Token?
    private let previewStack = NSStackView()
    private let deviceImage = NSImageView()
    private let deviceName = NSTextField(labelWithString: "Select a Device")
    private let deviceRuntime = NSTextField(labelWithString: "")
    private let viewScreen = NSButton(title: "View Screen", target: nil, action: nil)
    private var previewTask: Task<Void, Never>?
    private var previewArtwork: DeviceArtworkModel?
    /// The latest accepted move; each move starts after the one accepted before it.
    private var screenMove: Task<Void, any Error>?
    private var screenMoveGeneration = 0

    package init(
        model: SimulatorManagerModel, screens: DeviceScreens, artworkCache: DeviceArtworkCache,
        previewVerticalOffset: CGFloat = -24
    ) {
        self.model = model
        self.screens = screens
        self.artworkCache = artworkCache
        self.previewVerticalOffset = previewVerticalOffset
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    isolated deinit {
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
    }

    package func makeSplitViewItem() -> NSSplitViewItem {
        let item = NSSplitViewItem(viewController: self)
        item.minimumThickness = 280
        item.holdingPriority = .defaultLow
        canvasAccessory.onMinimumWidthChange = { [weak item] width in
            let minimum = max(280, width)
            if let item, item.minimumThickness != minimum { item.minimumThickness = minimum }
        }
        item.addBottomAlignedAccessoryViewController(canvasAccessory)
        splitViewItem = item
        return item
    }

    override package func loadView() {
        let view = NSView()
        self.view = view
        liveScreenContainer.view = NSView()
        addChild(liveScreenContainer)
        let liveView = liveScreenContainer.view
        liveView.translatesAutoresizingMaskIntoConstraints = false
        liveView.isHidden = true
        liveView.clipsToBounds = true
        view.addSubview(liveView)
        // Presentations may draw behind the toolbar and bottom accessory; each keeps its content in the safe area.
        NSLayoutConstraint.activate([
            liveView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            liveView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            liveView.topAnchor.constraint(equalTo: view.topAnchor),
            liveView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
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
        viewScreen.action = #selector(requestScreen(_:))
        for preview in [deviceImage, deviceName, deviceRuntime, viewScreen] { previewStack.addArrangedSubview(preview) }
        previewStack.orientation = .vertical
        previewStack.alignment = .centerX
        previewStack.spacing = 10
        previewStack.setCustomSpacing(24, after: deviceImage)
        previewStack.setCustomSpacing(20, after: deviceRuntime)
        previewStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(previewStack)
        NSLayoutConstraint.activate([
            deviceImage.widthAnchor.constraint(equalToConstant: 192),
            deviceImage.heightAnchor.constraint(equalToConstant: 192),
            viewScreen.widthAnchor.constraint(greaterThanOrEqualToConstant: 112),
            previewStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            previewStack.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: previewVerticalOffset),
            previewStack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            previewStack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
            deviceName.widthAnchor.constraint(lessThanOrEqualTo: previewStack.widthAnchor),
            deviceRuntime.widthAnchor.constraint(lessThanOrEqualTo: previewStack.widthAnchor),
        ])
    }

    /// Describes the one selected device, or how many devices are selected.
    package func showPreview(of device: InventoryDevice?, selectionCount: Int) {
        loadViewIfNeeded()
        previewDevice = device
        if let device {
            deviceName.stringValue = device.name
            if case .simulator(let simulator) = device { deviceRuntime.stringValue = "\(simulator.runtimeName) Simulator" }
            else {
                deviceRuntime.stringValue = [device.operatingSystem, device.modelName, device.kindTitle]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            }
            let artwork = artworkCache.artwork(for: device, screens: screens, manager: model)
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
        } else {
            previewTask?.cancel()
            previewTask = nil
            previewArtwork = nil
            if selectionCount == 0 {
                deviceName.stringValue = "Select a Device"
                deviceRuntime.stringValue = "Choose a device in the sidebar to view its details."
                deviceImage.image = nil
            } else {
                deviceName.stringValue = "\(selectionCount) Devices"
                deviceRuntime.stringValue = "Select one device to view its details."
                deviceImage.image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: nil)
            }
        }
        deviceImage.contentTintColor = nil
        // Whether the screen can open follows what the manager is doing with the device.
        previewObservation = withPortableContinuousObservation { [weak self] _ in self?.updateViewScreen() }
    }

    private func updateViewScreen() {
        let device = previewDevice.flatMap { preview in model.inventory.first { $0.id == preview.id } }
        let isOpening = device.map { model.openingDeviceIDs.contains($0.id) } == true
        let isShutdown: Bool
        if case .simulator(let simulator)? = device { isShutdown = simulator.state == "Shutdown" } else { isShutdown = false }
        let needsPairing = device.map(model.needsHostPairing) == true
        viewScreen.title =
            needsPairing ? "Pair" : (isOpening ? "Cancel Opening" : (isShutdown ? "Start" : "View Screen"))
        viewScreen.image =
            isShutdown || needsPairing
            ? nil : NSImage(systemSymbolName: "rectangle.badge.person.crop", accessibilityDescription: nil)
        viewScreen.isHidden = device == nil
        viewScreen.isEnabled =
            device.map { needsPairing ? model.canPairWithHost($0) : model.canViewScreen($0) } ?? false
        viewScreen.toolTip = nil
    }

    /// Shows the screen embedded in `liveScreenContainer`.
    package func showLiveScreen(_ screen: DeviceScreen) {
        displayedScreen = screen
        canvasAccessory.setControls(screen.canvasControls)
        liveScreenContainer.view.isHidden = false
        previewStack.isHidden = true
        observeToolbarItems()
        onLiveScreenChange?()
        observeDisplayedScreen()
    }

    package func showDevicePreview(ifDisplaying identifier: DeviceInventoryID) {
        guard displayedScreen?.id == identifier else { return }
        displayedScreen = nil
        displayedScreenObservation?.cancel()
        displayedScreenObservation = nil
        canvasAccessory.setControls(nil)
        liveScreenContainer.view.isHidden = true
        previewStack.isHidden = false
        observeToolbarItems()
        onLiveScreenChange?()
    }

    /// Fits the accessory to the screen's updated controls, and shows the preview once the screen closes.
    private func observeDisplayedScreen() {
        displayedScreenObservation?.cancel()
        guard let screen = displayedScreen else { return }
        guard screens.screen(for: screen.id) === screen else {
            showDevicePreview(ifDisplaying: screen.id)
            return
        }
        displayedScreenObservation = withPortableContinuousObservation { [weak self, screen, screens] _ in
            _ = screen.canvasControlsUpdates
            let isOpen = screens.screen(for: screen.id) === screen
            guard let self else { return }
            canvasAccessory.refresh()
            if !isOpen { showDevicePreview(ifDisplaying: screen.id) }
        }
    }

    // MARK: Toolbar

    package func makeToolbarItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem? {
        switch identifier {
        case Self.resizeAppIdentifier:
            let item = makeToggleItem(identifier, label: "Resize App", symbol: "aspectratio", action: #selector(resizeApp(_:)))
            resizeAppItem = item
            return item
        case Self.captureKeyboardIdentifier:
            let item = makeToggleItem(identifier, label: "Capture Keyboard", symbol: "keyboard",
                                      action: #selector(captureKeyboard(_:)))
            captureKeyboardItem = item
            return item
        case Self.canvasZoomIdentifier:
            let labels = ["Zoom Out", "Fit", "Physical Size", "Zoom In"]
            let symbols = ["minus.magnifyingglass", "arrowtriangles.up.right.down.left.magnifyingglass", "1.magnifyingglass", "plus.magnifyingglass"]
            let images = zip(symbols, labels).compactMap { NSImage.deviceControlSymbol(named: $0, accessibilityDescription: $1) }
            let item: NSToolbarItemGroup
            if images.count == labels.count {
                item = NSToolbarItemGroup(itemIdentifier: identifier, images: images, selectionMode: .selectOne,
                                          labels: labels, target: self, action: #selector(performCanvasZoom(_:)))
            } else {
                item = NSToolbarItemGroup(itemIdentifier: identifier, titles: labels, selectionMode: .selectOne,
                                          labels: labels, target: self, action: #selector(performCanvasZoom(_:)))
            }
            item.label = "Canvas Zoom"
            item.autovalidates = false
            for subitem in item.subitems { subitem.autovalidates = false }
            item.controlRepresentation = .automatic
            item.isHidden = liveDeviceIdentifier == nil
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
            canvasZoomItem = item
            return item
        default:
            return nil
        }
    }

    private func makeToggleItem(_ identifier: NSToolbarItem.Identifier, label: String, symbol: String,
                                action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.toolTip = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.target = self
        item.action = action
        let menuItem = NSMenuItem(title: item.label, action: action, keyEquivalent: "")
        menuItem.target = self
        item.menuFormRepresentation = menuItem
        let button = NSButton(image: item.image ?? NSImage(), target: self, action: action)
        button.identifier = NSUserInterfaceItemIdentifier(identifier.rawValue)
        button.bezelStyle = .toolbar
        button.setButtonType(.pushOnPushOff)
        button.toolTip = item.toolTip
        button.setAccessibilityLabel(item.label)
        item.view = button
        item.autovalidates = false
        item.isHidden = liveDeviceIdentifier == nil
        return item
    }

    /// Follows the live screen's state, and the window's sheets that block its commands.
    private func observeToolbarItems() {
        if windowObservers.isEmpty {
            for name in [NSWindow.willBeginSheetNotification, NSWindow.didEndSheetNotification] {
                windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                    let source = (notification.object as AnyObject?).map(ObjectIdentifier.init)
                    Task { @MainActor [weak self] in
                        guard let self, let window = self.view.window, source == ObjectIdentifier(window) else { return }
                        self.updateToolbarItems()
                    }
                })
            }
        }
        toolbarObservation?.cancel()
        toolbarObservation = withPortableContinuousObservation { [weak self] _ in self?.updateToolbarItems() }
    }

    private func updateToolbarItems() {
        guard let screen = liveScreen else {
            for item in [resizeAppItem, captureKeyboardItem, canvasZoomItem].compactMap({ $0 }) {
                item.isHidden = true
                item.isEnabled = false
            }
            return
        }
        let blocked = view.window?.attachedSheet != nil
        if let item = resizeAppItem {
            let resizingApp = screen.resizingApp
            let title = resizingApp ? "Stop Resize" : "Resize App"
            if item.label != title { item.label = title }
            if item.toolTip != title { item.toolTip = title }
            item.menuFormRepresentation?.title = title
            if let button = item.view as? NSButton {
                button.toolTip = title
                button.setAccessibilityLabel(title)
            }
            update(item, hidden: !screen.supports("resizeApp"), enabled: screen.isEnabled("resizeApp") && !blocked,
                   on: resizingApp)
        }
        if let item = captureKeyboardItem {
            let capturesKeyboard = screen.capturesKeyboard
            update(item, hidden: !screen.supports("captureKeyboard"),
                   enabled: screen.isEnabled("captureKeyboard") && !blocked, on: capturesKeyboard)
            (item.view as? NSButton)?.toolTip = capturesKeyboard ? "Release Keyboard — or hold Escape for one second." : "Capture Keyboard"
        }
        if let group = canvasZoomItem {
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

    private func update(_ item: NSToolbarItem, hidden: Bool, enabled: Bool, on: Bool) {
        if item.isHidden != hidden { item.isHidden = hidden }
        if item.isEnabled != enabled { item.isEnabled = enabled }
        item.menuFormRepresentation?.isEnabled = item.isEnabled
        item.menuFormRepresentation?.state = on ? .on : .off
        if let button = item.view as? NSButton {
            let state: NSControl.StateValue = on ? .on : .off
            if button.state != state { button.state = state }
            if button.isEnabled != item.isEnabled { button.isEnabled = item.isEnabled }
        }
    }

    @objc private func resizeApp(_ sender: Any?) { liveScreen?.perform("resizeApp") }

    @objc private func captureKeyboard(_ sender: Any?) { liveScreen?.perform("captureKeyboard") }

    @objc private func performCanvasZoom(_ sender: NSToolbarItemGroup) { performCanvasZoom(at: sender.selectedIndex) }

    @objc private func performCanvasZoomFromMenu(_ sender: NSMenuItem) { performCanvasZoom(at: sender.tag) }

    private func performCanvasZoom(at index: Int) {
        guard CanvasZoom.Action.allCases.indices.contains(index) else { return }
        liveScreen?.perform(CanvasZoom.Action.allCases[index].rawValue)
    }

    package func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let action: String
        switch item.action {
        case #selector(captureKeyboard(_:)): action = "captureKeyboard"
        case #selector(resizeApp(_:)): action = "resizeApp"
        case #selector(performCanvasZoomFromMenu(_:)):
            guard CanvasZoom.Action.allCases.indices.contains(item.tag) else { return false }
            action = CanvasZoom.Action.allCases[item.tag].rawValue
        default: return true
        }
        return liveScreen?.isEnabled(action) == true && view.window?.attachedSheet == nil
    }

    // MARK: Screen moves

    private func performScreenMove(_ move: @escaping @MainActor () async throws -> Void) async throws {
        let previous = screenMove
        screenMoveGeneration += 1
        let generation = screenMoveGeneration
        let task = Task { @MainActor in
            _ = await previous?.result
            try Task.checkCancellation()
            try await move()
        }
        screenMove = task
        defer { if screenMoveGeneration == generation { screenMove = nil } }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    /// Waits for the moves accepted so far to finish.
    package func waitForScreenMoves() async {
        _ = await screenMove?.result
    }

    /// Embeds the screen, optionally preserving the first responder.
    /// On failure, restores the previous screen if this move is still current.
    package func embedScreen(for identifier: DeviceInventoryID, preservingFocus: Bool,
                     while isCurrent: @escaping @MainActor () -> Bool) async throws {
        try await performScreenMove { [self] in
            guard isCurrent(), let screen = screens.screen(for: identifier) else { return }
            defer {
                if let current = liveScreen, !current.isEmbedded(in: liveScreenContainer) {
                    showDevicePreview(ifDisplaying: current.id)
                }
            }
            if liveScreen === screen, screen.isEmbedded(in: liveScreenContainer) {
                return
            }
            try await screen.preparePresentationMove()
            guard isCurrent() else { return }
            let previousResponder = preservingFocus ? view.window?.firstResponder : nil
            let previous = liveScreen
            try await previous?.preparePresentationMove()
            guard isCurrent() else { return }
            try screen.validatePresentationMove()
            try previous?.validatePresentationMove()
            try await previous?.detach()
            guard isCurrent() else { return }
            do { try await screen.embed(in: liveScreenContainer) }
            catch {
                if let previous, isCurrent() {
                    do { try await previous.embed(in: liveScreenContainer) }
                    catch let restorationError {
                        if let current = liveDeviceIdentifier { showDevicePreview(ifDisplaying: current) }
                        throw SimulatorError.operation([error.localizedDescription,
                            "Could not restore the previous device screen: \(restorationError.localizedDescription)"].joined(separator: "\n"))
                    }
                }
                if let previousResponder { view.window?.makeFirstResponder(previousResponder) }
                throw error
            }
            guard isCurrent() else {
                try await screen.detach()
                return
            }
            showLiveScreen(screen)
            if let previousResponder { view.window?.makeFirstResponder(previousResponder) }
        }
    }

    /// Opens a separate interactive window while the selected screen stays in the pane.
    package func switchToCompactWindow(for identifier: DeviceInventoryID,
                               while isCurrent: @escaping @MainActor () -> Bool) async throws {
        guard isCurrent() else { return }
        try await screens.showCompactWindow(for: identifier, while: isCurrent)
    }

    /// Shows the screen in its compact window, bringing that window forward. With `unlessCompact`, a screen already in
    /// its compact window stays as it is.
    package func showCompactWindow(of screen: DeviceScreen, unlessCompact: Bool = false,
                           while isCurrent: @escaping @MainActor () -> Bool) async throws {
        guard isCurrent() else { return }
        if !unlessCompact || screen.presentation != .compact {
            try await screens.showCompactWindow(for: screen.id, while: isCurrent)
        }
    }

    /// Removes the screen from its presentation without ending its connection.
    package func detachScreen(_ screen: DeviceScreen, while isCurrent: @escaping @MainActor () -> Bool) async throws {
        try await performScreenMove { [self] in
            guard isCurrent() else { return }
            try await screen.detach()
            showDevicePreview(ifDisplaying: screen.id)
        }
    }

    /// Detaches the live screen once it can leave the pane, and shows the preview.
    package func detachLiveScreen(while isCurrent: @escaping @MainActor () -> Bool) async throws {
        try await performScreenMove { [self] in
            guard isCurrent(), let screen = liveScreen else { return }
            try await screen.preparePresentationMove()
            guard isCurrent() else { return }
            try await screen.detach()
            showDevicePreview(ifDisplaying: screen.id)
        }
    }

    @objc private func requestScreen(_ sender: Any?) { onViewScreen?() }

}

#if DEBUG
    #Preview("Selected Device", traits: .fixedLayout(width: 600, height: 700)) {
        DeviceScreenViewController.preview(showsDevice: true)
    }

    #Preview("No Selection", traits: .fixedLayout(width: 600, height: 700)) {
        DeviceScreenViewController.preview(showsDevice: false)
    }

    extension DeviceScreenViewController {
        /// The device pane in its split view item, previewing a simulator that in-memory host responses supply.
        fileprivate static func preview(showsDevice: Bool) -> NSSplitViewController {
            let source = PreviewManagerSource()
            let manager = SimulatorManagerModel(
                source: source,
                serviceProfiles: .preview(named: "NeoSimulator.DeviceScreenPreview")
            )
            let screen = DeviceScreenViewController(
                model: manager,
                screens: DeviceScreens(model: manager),
                artworkCache: DeviceArtworkCache()
            )
            let split = NSSplitViewController()
            split.splitView.isVertical = true
            split.addSplitViewItem(screen.makeSplitViewItem())
            Task {
                await manager.refresh()
                screen.showPreview(of: showsDevice ? source.device : nil, selectionCount: showsDevice ? 1 : 0)
            }
            return split
        }
    }
#endif
