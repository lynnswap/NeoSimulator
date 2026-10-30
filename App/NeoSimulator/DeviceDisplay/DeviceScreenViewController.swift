import AppKit
import Observation
@_spi(NeoSimulator) import XcodeSimulatorHost

/// The manager's center pane, which shows the selected device's live screen or its preview.
/// The manager window owns the selection and toolbar, and attaches `canvasAccessory` to this pane's split view item.
/// The pane returns to the preview when `DeviceScreens` closes or replaces the screen it shows.
///
/// The pane runs screen moves in the order the window accepts them. The window passes each move a check of its
/// latest choice; the move repeats the check after each await and stops once it fails.
@MainActor
final class DeviceScreenViewController: NSViewController {
    private let model: SimulatorManagerModel
    private let screens: DeviceScreens
    let liveScreenContainer = NSViewController()
    let canvasAccessory = DeviceCanvasAccessoryViewController()
    /// The screen in `liveScreenContainer`, until the pane shows the preview again.
    private var displayedScreen: DeviceScreen?
    private var displayedScreenObservation = 0
    /// The displayed screen while it is still open; a closed or replaced screen no longer counts as live.
    var liveScreen: DeviceScreen? {
        guard let displayedScreen, screens.screen(for: displayedScreen.id) === displayedScreen else { return nil }
        return displayedScreen
    }
    var liveDeviceIdentifier: DeviceInventoryID? { liveScreen?.id }
    var liveCommandTarget: NSResponder? { liveScreen?.commandTarget }
    var onLiveScreenChange: (() -> Void)?
    var onViewScreen: (() -> Void)?
    private let previewStack = NSStackView()
    private let deviceImage = NSImageView()
    private let deviceName = NSTextField(labelWithString: "Select a Device")
    private let deviceRuntime = NSTextField(labelWithString: "")
    private let viewScreen = NSButton(title: "View Screen", target: nil, action: nil)
    private var previewTask: Task<Void, Never>?
    private var previewArtwork: DeviceArtworkModel?
    private let deviceFooter = NSStackView()
    private let activityStack = NSStackView()
    private let cancelOpening = NSButton(title: "Cancel Opening Screens", target: nil, action: nil)
    /// The footer's distance from the pane's safe area, and the space it leaves above itself.
    private static let footerInset: CGFloat = 8, footerSpacing: CGFloat = 12
    private let activity = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    /// The latest accepted move; each move starts after the one accepted before it.
    private var screenMove: Task<Void, any Error>?
    private var screenMoveGeneration = 0

    init(model: SimulatorManagerModel, screens: DeviceScreens) {
        self.model = model
        self.screens = screens
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let view = NSView()
        self.view = view
        liveScreenContainer.view = NSView()
        addChild(liveScreenContainer)
        let liveView = liveScreenContainer.view
        liveView.translatesAutoresizingMaskIntoConstraints = false
        liveView.isHidden = true
        liveView.clipsToBounds = true
        view.addSubview(liveView)
        // Presentations may draw behind the toolbar, bottom accessory and footer; each keeps its content in the safe area.
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
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        activity.font = .systemFont(ofSize: 12)
        activity.textColor = .secondaryLabelColor
        activity.lineBreakMode = .byTruncatingTail
        activityStack.addArrangedSubview(progress)
        activityStack.addArrangedSubview(activity)
        cancelOpening.controlSize = .small
        cancelOpening.bezelStyle = .rounded
        cancelOpening.target = self
        cancelOpening.action = #selector(cancelPendingScreenOpens(_:))
        cancelOpening.isHidden = true
        activityStack.addArrangedSubview(cancelOpening)
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
            previewStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            previewStack.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -24),
            previewStack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            previewStack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
            deviceName.widthAnchor.constraint(lessThanOrEqualTo: previewStack.widthAnchor),
            deviceRuntime.widthAnchor.constraint(lessThanOrEqualTo: previewStack.widthAnchor),
            deviceFooter.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            deviceFooter.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -Self.footerInset),
            deviceFooter.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            deviceFooter.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observeActivity()
    }

    private func observeActivity() {
        withObservationTracking { updateActivity() } onChange: { [weak self] in
            Task { @MainActor in self?.observeActivity() }
        }
    }

    private func updateActivity() {
        activity.stringValue = model.isBusy ? model.activity : (model.backgroundIssue ?? "")
        activity.toolTip = activity.stringValue
        activity.isHidden = activity.stringValue.isEmpty
        progress.isHidden = !model.isBusy
        if model.isBusy { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        cancelOpening.isHidden = model.openingDeviceIDs.isEmpty
        activityStack.isHidden = activity.isHidden && progress.isHidden && cancelOpening.isHidden
        updateDeviceFooter()
    }

    private func updateDeviceFooter() {
        deviceFooter.isHidden = activityStack.isHidden
        // A live screen keeps drawing behind the footer; the footer only narrows the area it fits within.
        let liveView = liveScreenContainer.view
        var insets = liveView.additionalSafeAreaInsets
        insets.bottom = deviceFooter.isHidden ? 0
            : Self.footerInset + deviceFooter.fittingSize.height + Self.footerSpacing
        liveView.additionalSafeAreaInsets = insets
    }

    func updatePreview(for device: InventoryDevice, details: String, artwork: DeviceArtworkModel, canViewScreen: Bool) {
        deviceName.stringValue = device.name
        deviceRuntime.stringValue = details
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
        deviceImage.contentTintColor = nil
        updateViewScreen(for: device, isEnabled: canViewScreen)
    }

    func updatePreview(selectionCount: Int) {
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
        deviceImage.contentTintColor = nil
        updateViewScreen(for: nil, isEnabled: false)
    }

    private func updateViewScreen(for device: InventoryDevice?, isEnabled: Bool) {
        let isOpening = device.map { model.openingDeviceIDs.contains($0.id) } == true
        let isShutdown: Bool
        if case .simulator(let simulator)? = device { isShutdown = simulator.state == "Shutdown" } else { isShutdown = false }
        viewScreen.title = isOpening ? "Cancel Opening" : (isShutdown ? "Start" : "View Screen")
        viewScreen.image = isShutdown ? nil : NSImage(systemSymbolName: "rectangle.badge.person.crop", accessibilityDescription: nil)
        viewScreen.isHidden = device == nil
        viewScreen.isEnabled = isEnabled
        viewScreen.toolTip = nil
    }

    /// Shows the screen embedded in `liveScreenContainer`.
    func showLiveScreen(_ screen: DeviceScreen) {
        displayedScreen = screen
        canvasAccessory.setControls(screen.canvasControls)
        liveScreenContainer.view.isHidden = false
        previewStack.isHidden = true
        onLiveScreenChange?()
        observeDisplayedScreen()
    }

    func showDevicePreview(ifDisplaying identifier: DeviceInventoryID) {
        guard displayedScreen?.id == identifier else { return }
        displayedScreen = nil
        displayedScreenObservation += 1
        canvasAccessory.setControls(nil)
        liveScreenContainer.view.isHidden = true
        previewStack.isHidden = false
        onLiveScreenChange?()
        updateDeviceFooter()
    }

    /// Fits the accessory to the screen's updated controls, and shows the preview once the screen closes.
    private func observeDisplayedScreen() {
        displayedScreenObservation += 1
        let observation = displayedScreenObservation
        guard let screen = displayedScreen else { return }
        let isOpen = withObservationTracking {
            _ = screen.canvasControlsUpdates
            return screens.screen(for: screen.id) === screen
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.displayedScreenObservation == observation else { return }
                self.canvasAccessory.refresh()
                self.observeDisplayedScreen()
            }
        }
        if !isOpen { showDevicePreview(ifDisplaying: screen.id) }
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
    func waitForScreenMoves() async {
        _ = await screenMove?.result
    }

    /// Embeds the device's open screen in place of the live screen. With `preservingFocus`, the window keeps its
    /// first responder. If the screen cannot embed, the previous screen returns while the move is still current.
    func embedScreen(for identifier: DeviceInventoryID, preservingFocus: Bool,
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
                        throw HostError.operation([error.localizedDescription,
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

    /// Moves the device's open screen to its compact window once the screen can leave the pane.
    func switchToCompactWindow(for identifier: DeviceInventoryID,
                               while isCurrent: @escaping @MainActor () -> Bool) async throws {
        try await performScreenMove { [self] in
            guard isCurrent(), let screen = screens.screen(for: identifier) else { return }
            try await screen.preparePresentationMove()
            guard isCurrent() else { return }
            try await screen.showCompactWindow()
            showDevicePreview(ifDisplaying: identifier)
        }
    }

    /// Shows the screen in its compact window, bringing that window forward. With `unlessCompact`, a screen already in
    /// its compact window stays as it is.
    func showCompactWindow(of screen: DeviceScreen, unlessCompact: Bool = false,
                           while isCurrent: @escaping @MainActor () -> Bool) async throws {
        try await performScreenMove { [self] in
            guard isCurrent() else { return }
            if !unlessCompact || screen.presentation != .compact { try await screen.showCompactWindow() }
            showDevicePreview(ifDisplaying: screen.id)
        }
    }

    /// Removes the screen from its presentation without ending its connection.
    func detachScreen(_ screen: DeviceScreen, while isCurrent: @escaping @MainActor () -> Bool) async throws {
        try await performScreenMove { [self] in
            guard isCurrent() else { return }
            try await screen.detach()
            showDevicePreview(ifDisplaying: screen.id)
        }
    }

    /// Detaches the live screen once it can leave the pane, and shows the preview.
    func detachLiveScreen(while isCurrent: @escaping @MainActor () -> Bool) async throws {
        try await performScreenMove { [self] in
            guard isCurrent(), let screen = liveScreen else { return }
            try await screen.preparePresentationMove()
            guard isCurrent() else { return }
            try await screen.detach()
            showDevicePreview(ifDisplaying: screen.id)
        }
    }

    @objc private func requestScreen(_ sender: Any?) { onViewScreen?() }

    @objc private func cancelPendingScreenOpens(_ sender: Any?) { model.cancelPendingOpens() }
}
