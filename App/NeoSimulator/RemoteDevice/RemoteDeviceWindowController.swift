import AppKit
import ImageIO
import UniformTypeIdentifiers
@_spi(NeoSimulator) import XcodeSimulatorHost

@MainActor
final class RemoteDeviceWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuDelegate, NSMenuItemValidation {
    private enum RecordingDestination: Sendable {
        case automatic(URL), selected(URL)

        var url: URL {
            switch self {
            case .automatic(let url), .selected(let url): url
            }
        }
    }
    let device: CoreDeviceDevice
    let session: RemoteDeviceScreenSession
    var onClose: (() -> Void)?
    var onChange: (() -> Void)?
    var onConnect: (() async -> Void)?
    var onShowInMainWindow: (() -> Void)? { didSet { update() } }
    /// Application bundles dropped on the screen go to the device's installer, whichever window shows it.
    var canInstallApplications: () -> Bool = { false }
    var installApplications: ([URL]) -> Void = { _ in }
    let presentationViewController = RemoteDevicePresentationViewController()
    var isEmbedded: Bool { presentationViewController.parent != nil }
    private var presentationWindow: NSWindow? { presentationViewController.view.window }
    var canMovePresentation: Bool {
        guard !closing, !mayClose, stoppingTask == nil, appResizeTask == nil else { return false }
        guard let window = presentationWindow else { return true }
        return window.attachedSheet == nil && !window.styleMask.contains(.fullScreen)
    }
    private var presentationConstraints: [NSLayoutConstraint] = []
    private var changingPresentation = false
    private let viewport = RemoteDeviceViewport()
    private let canvasControlsContainer = NSStackView()
    var canvasControls: DeviceCanvasControls? {
        didSet {
            oldValue?.removeFromSuperview()
            if let canvasControls { canvasControlsContainer.addArrangedSubview(canvasControls) }
            canvasControls?.onLayoutChange = { [weak self] in
                guard let self else { return }
                self.canvasControlsContainer.isHidden = self.canvasControls?.superview !== self.canvasControlsContainer
                self.fitCanvasControls()
            }
            canvasControlsContainer.isHidden = canvasControls == nil
            fitCanvasControls()
            update()
        }
    }
    /// Covers the screen while it connects or is unavailable, with the actions that can restore it.
    private let statusView = NSStackView()
    private let progress = NSProgressIndicator()
    private let statusTitle = NSTextField(wrappingLabelWithString: "")
    private let statusDetail = NSTextField(wrappingLabelWithString: "")
    private let retryButton = NSButton(title: "Try Again", target: nil, action: nil)
    private let captureSourceButton = NSButton(title: "Choose Screen Source…", target: nil, action: nil)
    private var captureSourceTask: Task<Void, Never>?
    private var presentingIssue = false
    private let inputView: RemoteDeviceInputView
    // Keep key and modifier releases on the original responder after focus or native-view changes.
    private var capturedKeyboardResponder: NSView?
    private lazy var keyboardCapture = KeyboardCapture(isEligible: { [weak self] in
        guard let self, !self.closing, !self.changingPresentation, self.session.state == .connected,
              self.session.inputCapabilities.contains(.keyboard), NSApp.isActive,
              let window = self.presentationWindow, window.isKeyWindow, window.attachedSheet == nil else { return false }
        return self.focusedScreenInputResponder === self.capturedKeyboardResponder
            && self.capturedKeyboardResponder != nil
    }, forward: { [weak self] event in
        guard let input = self?.capturedKeyboardResponder else { return }
        switch event.type {
        case .keyDown: input.keyDown(with: event)
        case .keyUp: input.keyUp(with: event)
        case .flagsChanged: input.flagsChanged(with: event)
        default: break
        }
    }, releaseModifiers: { [weak self] releases in
        guard let self, let input = self.capturedKeyboardResponder else { return }
        if input === self.inputView {
            self.inputView.releaseModifiers(releases)
        } else {
            for event in releases { input.flagsChanged(with: event) }
        }
    })
    var capturesKeyboard: Bool { keyboardCapture.isCapturing }
    private var connectionTask: Task<Void, Never>?
    private var stoppingTask: Task<Void, any Error>?
    private var inputTask: Task<Void, Never>?
    private var captureTask: Task<Void, any Error>?
    private var appResizeTask: Task<Void, Never>?
    private var requestedAppSize: CGSize?
    private var completedScreenshot: CGImage?
    private var capturePanel: NSSavePanel?
    private var recordingTask: Task<Void, any Error>?
    private var recordingTaskIdentifier: UUID?
    private var finishingRecording = false
    private var recordingPanel: NSSavePanel?
    private var recordingDestination: RecordingDestination?
    private var closing = false
    private var mayClose = false
    private var inventoryAvailable = true
    private var toolbarItems: [String: NSToolbarItem] = [:]
    private let writeImage: @MainActor (CGImage, URL) async throws -> Void
    private let presentSavePanel: @MainActor (NSSavePanel, NSWindow) async -> NSApplication.ModalResponse
    private let presentAlert: @MainActor (NSAlert, NSWindow) async -> NSApplication.ModalResponse
    private let presentCompactWindow: @MainActor (NSWindow) -> Void

    init(device: CoreDeviceDevice, session: RemoteDeviceScreenSession? = nil,
         writeImage: @escaping @MainActor (CGImage, URL) async throws -> Void = { image, destination in
             try await RemoteDeviceWindowController.writeScreenshot(image, to: destination)
         },
         presentSavePanel: @escaping @MainActor (NSSavePanel, NSWindow) async -> NSApplication.ModalResponse = { panel, window in
             await withCheckedContinuation { continuation in
                 panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
             }
         },
         presentCompactWindow: @escaping @MainActor (NSWindow) -> Void = { $0.makeKeyAndOrderFront(nil) },
         presentAlert: @escaping @MainActor (NSAlert, NSWindow) async -> NSApplication.ModalResponse = { alert, window in
             await withCheckedContinuation { continuation in
                 alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
             }
         }) {
        self.device = device
        let session = session ?? RemoteDeviceScreenSession(device: device)
        self.session = session
        self.writeImage = writeImage
        self.presentSavePanel = presentSavePanel
        self.presentAlert = presentAlert
        self.presentCompactWindow = presentCompactWindow
        inputView = RemoteDeviceInputView(session: session)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = device.name
        window.subtitle = [device.platform, device.osVersion].compactMap { $0 }.joined(separator: " ")
        window.minSize = NSSize(width: 240, height: 280)
        window.isReleasedWhenClosed = false
        window.tabbingIdentifier = "NeoSimulatorRemoteDevice"
        window.tabbingMode = .automatic
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.acceptsMouseMovedEvents = true
        window.toolbarStyle = .unifiedCompact
        super.init(window: window)
        presentationViewController.owner = self
        window.delegate = self
        let root = NSView()
        viewport.translatesAutoresizingMaskIntoConstraints = false
        viewport.canInstallApplications = { [weak self] in self?.canInstallApplications() == true }
        viewport.installApplications = { [weak self] in self?.installApplications($0) }
        root.addSubview(viewport)
        session.contentView.translatesAutoresizingMaskIntoConstraints = false
        viewport.addSubview(session.contentView)
        inputView.translatesAutoresizingMaskIntoConstraints = false
        viewport.addSubview(inputView)
        // The status covers the device's dark screen in either system appearance.
        statusView.appearance = NSAppearance(named: .darkAqua)
        statusView.orientation = .vertical
        statusView.alignment = .centerX
        statusView.spacing = 8
        statusView.translatesAutoresizingMaskIntoConstraints = false
        let actions = NSStackView(views: [retryButton, captureSourceButton])
        actions.orientation = .vertical
        actions.spacing = 8
        statusView.addArrangedSubview(progress)
        statusView.addArrangedSubview(statusTitle)
        statusView.addArrangedSubview(statusDetail)
        statusView.addArrangedSubview(actions)
        statusView.setCustomSpacing(16, after: statusDetail)
        viewport.addSubview(statusView)
        canvasControlsContainer.orientation = .vertical
        canvasControlsContainer.alignment = .width
        canvasControlsContainer.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 8, right: 8)
        canvasControlsContainer.translatesAutoresizingMaskIntoConstraints = false
        canvasControlsContainer.isHidden = true
        // The stack detaches the hidden container, so the screen reaches the bottom without controls.
        let bottom = NSStackView(views: [canvasControlsContainer])
        bottom.orientation = .vertical
        bottom.alignment = .width
        bottom.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(bottom)
        progress.style = .spinning
        progress.controlSize = .regular
        statusTitle.font = .preferredFont(forTextStyle: .headline)
        statusDetail.font = .preferredFont(forTextStyle: .subheadline)
        statusDetail.textColor = .secondaryLabelColor
        for label in [statusTitle, statusDetail] {
            label.alignment = .center
            label.preferredMaxLayoutWidth = 260
        }
        retryButton.target = self
        retryButton.action = #selector(reconnect(_:))
        captureSourceButton.target = self
        captureSourceButton.action = #selector(chooseCaptureSource(_:))
        NSLayoutConstraint.activate([
            viewport.leadingAnchor.constraint(equalTo: root.leadingAnchor), viewport.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            viewport.topAnchor.constraint(equalTo: root.topAnchor), viewport.bottomAnchor.constraint(equalTo: bottom.topAnchor),
            bottom.leadingAnchor.constraint(equalTo: root.leadingAnchor), bottom.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            session.contentView.leadingAnchor.constraint(equalTo: viewport.leadingAnchor), session.contentView.trailingAnchor.constraint(equalTo: viewport.trailingAnchor),
            session.contentView.topAnchor.constraint(equalTo: viewport.topAnchor), session.contentView.bottomAnchor.constraint(equalTo: viewport.bottomAnchor),
            inputView.leadingAnchor.constraint(equalTo: viewport.leadingAnchor), inputView.trailingAnchor.constraint(equalTo: viewport.trailingAnchor),
            inputView.topAnchor.constraint(equalTo: viewport.topAnchor), inputView.bottomAnchor.constraint(equalTo: viewport.bottomAnchor),
            statusView.centerXAnchor.constraint(equalTo: viewport.centerXAnchor), statusView.centerYAnchor.constraint(equalTo: viewport.centerYAnchor),
            statusView.widthAnchor.constraint(lessThanOrEqualTo: viewport.widthAnchor, constant: -32),
        ])
        presentationViewController.view = root
        window.contentViewController = presentationViewController
        let toolbar = NSToolbar(identifier: "NeoSimulatorRemoteScreen")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        window.toolbar = toolbar
        window.center()
        inputView.enqueue = { [weak self] operation in self?.enqueueInput(operation) }
        session.onInputCapabilitiesLost = { [weak self] kinds in self?.inputView.invalidateInputs(for: kinds) }
        session.onStateChange = { [weak self] in self?.update() }
        session.onFrameButton = { [weak self] page, usage, state in self?.sendFrameButton(usagePage: page, usage: usage, state: state) }
        session.onFrameButtonFailure = { [weak self] in self?.showIssue($0) }
        let screenMenu = NSMenu(title: "Screen")
        screenMenu.delegate = self
        viewport.menu = screenMenu
        session.prepareForDisplayChange = { [weak self] in
            let acceptedInput = self?.inputTask
            await acceptedInput?.value
        }
        keyboardCapture.failure = { [weak self] in self?.showIssue($0) }
        keyboardCapture.didStop = { [weak self] in
            self?.capturedKeyboardResponder = nil
            self?.update()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(presentationWindowBecameKey(_:)),
            name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(presentationWindowResignedKey(_:)),
            name: NSWindow.didResignKeyNotification, object: nil)
        update()
    }
    required init?(coder: NSCoder) { nil }

    func embed(in parent: NSViewController) async throws {
        guard presentationViewController.parent !== parent else { return }
        try await changePresentation {
            self.removePresentation()
            parent.addChild(self.presentationViewController)
            let view = self.presentationViewController.view
            view.translatesAutoresizingMaskIntoConstraints = false
            parent.view.addSubview(view)
            // The main window's live container extends behind its toolbar and bottom accessory.
            let area = parent.view.safeAreaLayoutGuide
            self.presentationConstraints = [
                view.leadingAnchor.constraint(equalTo: area.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: area.trailingAnchor),
                view.topAnchor.constraint(equalTo: area.topAnchor),
                view.bottomAnchor.constraint(equalTo: area.bottomAnchor),
            ]
            NSLayoutConstraint.activate(self.presentationConstraints)
            self.window?.orderOut(nil)
        }
    }

    func showCompactWindow() async throws {
        guard !closing, !mayClose, stoppingTask == nil else { throw CancellationError() }
        if window?.contentViewController === presentationViewController {
            if let window { presentCompactWindow(window) }
            focusScreen()
            return
        }
        try await changePresentation {
            self.attachToCompactWindow()
            if let window = self.window { self.presentCompactWindow(window) }
        }
    }

    func detachPresentation() async throws {
        guard presentationViewController.view.superview != nil else { return }
        try await changePresentation {
            self.removePresentation()
            self.window?.orderOut(nil)
        }
    }

    func preparePresentationMove() async throws {
        guard !closing, !mayClose, stoppingTask == nil else { throw CancellationError() }
        if capturePanel != nil {
            do { try await captureTask?.value }
            catch is CancellationError {}
            catch { showIssue(error) }
        }
        if recordingPanel != nil {
            do { try await recordingTask?.value }
            catch is CancellationError {}
            catch { showIssue(error) }
        }
        guard !closing, !mayClose, stoppingTask == nil else { throw CancellationError() }
        guard canMovePresentation else {
            throw RemoteDeviceWindowError.unavailable("Close the device's dialog or leave full screen before moving its screen.")
        }
    }

    private func changePresentation(_ change: @MainActor () -> Void) async throws {
        try await preparePresentationMove()
        changingPresentation = true
        relinquishScreenFocus()
        update()
        defer {
            changingPresentation = false
            update()
            if presentationWindow?.isKeyWindow == true { focusScreen() }
        }
        await inputTask?.value
        try await session.releaseInputs()
        try Task.checkCancellation()
        guard !closing, !mayClose, stoppingTask == nil else { throw CancellationError() }
        guard canMovePresentation else {
            throw RemoteDeviceWindowError.unavailable("Close the device's dialog or leave full screen before moving its screen.")
        }
        change()
    }

    private func removePresentation() {
        NSLayoutConstraint.deactivate(presentationConstraints)
        presentationConstraints.removeAll()
        if window?.contentViewController === presentationViewController { window?.contentViewController = nil }
        presentationViewController.view.removeFromSuperview()
        presentationViewController.removeFromParent()
    }

    private func attachToCompactWindow() {
        let frame = window?.frame
        removePresentation()
        presentationViewController.view.translatesAutoresizingMaskIntoConstraints = true
        window?.contentViewController = presentationViewController
        if let canvasControls, canvasControls.superview !== canvasControlsContainer {
            canvasControls.removeFromSuperview()
            canvasControlsContainer.addArrangedSubview(canvasControls)
        }
        canvasControlsContainer.isHidden = canvasControls == nil
        if let frame { window?.setFrame(frame, display: false) }
        fitCanvasControls()
    }

    private func fitCanvasControls() {
        guard let window else { return }
        let width = canvasControls.flatMap { $0.isHidden ? nil : $0.fittingSize.width + canvasControlsContainer.edgeInsets.left + canvasControlsContainer.edgeInsets.right } ?? 0
        window.contentMinSize.width = max(240, width)
        guard !isEmbedded, !window.styleMask.contains(.fullScreen),
              let currentSize = window.contentView?.bounds.size, currentSize.width < width else { return }
        window.setContentSize(NSSize(width: width, height: currentSize.height))
    }

    private var focusedScreenInputResponder: NSView? {
        guard let responder = presentationWindow?.firstResponder as? NSView,
              responder === inputView || session.nativeInputView.map({ responder.isDescendant(of: $0) }) == true else { return nil }
        return responder
    }

    private var screenOwnsFocus: Bool { focusedScreenInputResponder != nil }

    private func startKeyboardCapture() throws {
        capturedKeyboardResponder = focusedScreenInputResponder
        do { try keyboardCapture.start() }
        catch { capturedKeyboardResponder = nil; throw error }
    }

    private func focusScreen() {
        guard !changingPresentation else { return }
        presentationWindow?.makeFirstResponder(session.nativeInputView ?? inputView)
    }

    private func relinquishScreenFocus() {
        keyboardCapture.stop()
        if screenOwnsFocus { presentationWindow?.makeFirstResponder(nil) }
        inputView.releaseFocus()
    }

    private func windowForSheet() -> NSWindow? {
        if let presentationWindow {
            if !presentationWindow.isVisible { presentCompactWindow(presentationWindow) }
            return presentationWindow
        }
        attachToCompactWindow()
        if let window { presentCompactWindow(window) }
        return window
    }

    func connectIfNeeded() {
        guard !closing, !mayClose, connectionTask == nil else { return }
        connectionTask = Task { [weak self] in
            guard let self else { return }
            defer { self.connectionTask = nil; self.update() }
            do {
                try await self.session.start()
                try Task.checkCancellation()
                await self.onConnect?()
            } catch {
                // The screen's status shows the session's failure and how to retry.
            }
        }
        update()
    }

    func updateInventory(_ snapshot: InventoryDevice?) {
        let wasAvailable = inventoryAvailable
        if case .remote(let current) = snapshot {
            window?.title = current.name
            inventoryAvailable = current.isAvailable
        } else { inventoryAvailable = false }
        if wasAvailable, !closing, !inventoryAvailable, session.state == .connected || session.state == .connecting {
            Task { [weak self] in
                do { try await self?.stop() }
                catch is CancellationError {}
                catch { self?.showIssue(error) }
            }
        }
        update()
    }

    private func update() {
        let connected = session.state == .connected && !session.isChangingDisplay && !closing && !changingPresentation
        if !connected || !session.inputCapabilities.contains(.keyboard) { keyboardCapture.stop() }
        let native = session.nativeInputView
        inputView.isHidden = native != nil
        native?.isHidden = closing
        if let native, !closing, !changingPresentation, presentationWindow?.isKeyWindow == true,
           !isEmbedded || screenOwnsFocus { presentationWindow?.makeFirstResponder(native) }
        inputView.isInputEnabled = connected && !changingPresentation && presentationWindow != nil
        for (identifier, item) in toolbarItems {
            item.isHidden = canvasControls != nil && ["home", "capture", "record"].contains(identifier)
                || identifier == "resizeApp" && !session.supportsAppResize && !session.isResizingApp
            item.isEnabled = isScreenActionEnabled(identifier)
            if let presentation = screenActionPresentation(identifier) {
                item.label = presentation.title
                item.toolTip = presentation.title
                item.image = NSImage(systemSymbolName: presentation.symbolName, accessibilityDescription: presentation.title)
                item.menuFormRepresentation?.title = presentation.title
            }
            if identifier == "captureKeyboard", let button = item.view as? NSButton {
                button.state = capturesKeyboard ? .on : .off
                button.isEnabled = item.isEnabled
            }
        }
        toolbarItems["captureKeyboard"]?.toolTip = capturesKeyboard ? "Release Keyboard — or hold Escape for one second." : "Capture Keyboard"
        if let size = session.appResizeGeometry?.resolvedSize {
            let width = Double(size.width).formatted(.number.precision(.fractionLength(0)))
            let height = Double(size.height).formatted(.number.precision(.fractionLength(0)))
            toolbarItems["resizeApp"]?.toolTip = "Stop Resize — the app is \(width) × \(height)"
        }
        toolbarItems["capture"]?.toolTip = completedScreenshot != nil ? "Save the captured screenshot…"
            : session.canCaptureScreenshot ? "Save Screenshot…" : "Screenshot capture is not available for this display yet."
        toolbarItems["record"]?.toolTip = session.canRecordScreen || session.hasUnfinishedRecording || session.completedRecording != nil
            ? screenActionPresentation("record")?.title : "Screen recording is not available for this display yet."
        updateStatus()
        for item in toolbarItems.values { item.menuFormRepresentation?.isEnabled = item.isEnabled }
        onChange?()
    }

    /// Covers the screen while it connects or cannot be shown, with the actions that can restore it.
    private func updateStatus() {
        let connecting = connectionTask != nil || session.state == .connecting || session.state == .stopping
        let unavailable = !inventoryAvailable || !connecting && session.state != .connected
        let waiting = !unavailable && (connecting || session.isChangingDisplay
            || session.nativeInputView == nil && !session.hasReceivedFrame)
        statusView.isHidden = closing || !unavailable && !waiting
        progress.isHidden = !waiting
        if waiting { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        let error = session.lastError.map { $0 as NSError }
        statusTitle.stringValue = if !inventoryAvailable { "The device is unavailable." }
            else if unavailable { error?.localizedDescription ?? "Disconnected" }
            else if session.state == .connecting { "Connecting…" }
            else { "" }
        statusTitle.isHidden = statusTitle.stringValue.isEmpty
        statusDetail.stringValue = unavailable && inventoryAvailable ? error?.localizedRecoverySuggestion ?? "" : ""
        statusDetail.isHidden = statusDetail.stringValue.isEmpty
        retryButton.title = error == nil ? "Connect" : "Try Again"
        retryButton.isHidden = !unavailable || !inventoryAvailable
        retryButton.isEnabled = isScreenActionEnabled("reconnect")
        captureSourceButton.isHidden = !unavailable || !session.needsCaptureSource
        captureSourceButton.isEnabled = canChooseCaptureSource
        statusView.setAccessibilityLabel(waiting && statusTitle.isHidden ? "Connecting" : nil)
    }

    /// Presents a failure as a sheet, unless the screen's status already shows it.
    private func showIssue(_ error: any Error) {
        if session.state != .connected, session.lastError?.localizedDescription == error.localizedDescription { return }
        guard !presentingIssue, let window = presentationWindow, window.isVisible else { return }
        presentingIssue = true
        let alert = NSAlert(error: error)
        Task { [weak self] in
            _ = await self?.presentAlert(alert, window)
            self?.presentingIssue = false
        }
    }

    private func enqueueInput(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !closing, !changingPresentation else { return }
        let preceding = inputTask
        inputTask = Task { [weak self] in
            await preceding?.value
            do { try await operation() }
            catch {
                // Input that fails because the screen disconnected is explained by its status.
                guard let self, self.session.state == .connected else { return }
                self.showIssue(error)
            }
        }
    }

    private func sendFrameButton(usagePage: Int, usage: Int, state: RemoteDeviceButtonState) {
        guard !closing, !changingPresentation, session.state == .connected, session.inputCapabilities.contains(.button) else { return }
        inputView.enqueueInput(for: .button) { [session] in
            try await session.sendButton(usagePage: usagePage, usage: usage, state: state)
        }
    }

    private func stop() async throws {
        if let stoppingTask { try await stoppingTask.value; return }
        closing = true
        capturePanel?.cancel(nil)
        capturePanel = nil
        recordingPanel?.cancel(nil)
        let restoreScreenFocus = screenOwnsFocus || !isEmbedded
        relinquishScreenFocus()
        connectionTask?.cancel()
        appResizeTask?.cancel()
        let acceptedCapture = captureTask
        let acceptedRecording = recordingTask
        update()
        let task = Task { [self] in
            await inputTask?.value
            try await session.releaseInputs()
            do { try await acceptedCapture?.value }
            catch is CancellationError {}
            catch {
                guard completedScreenshot != nil else { throw error }
                // A failed write keeps its pixels; resolve them before disconnecting below.
            }
            try await finishScreenshotBeforeDisconnect()
            try await acceptedRecording?.value
            try await finishRecordingBeforeDisconnect()
            var failure: (any Error)?
            do { try await session.stop() }
            catch {
                failure = error
            }
            await connectionTask?.value
            if let failure { throw failure }
        }
        stoppingTask = task
        defer {
            stoppingTask = nil
            closing = false
            update()
            if session.state == .connected, restoreScreenFocus { focusScreen() }
        }
        do { try await task.value }
        catch is CancellationError { throw CancellationError() }
        catch { showIssue(error); throw error }
    }

    func stopAndClose() async throws {
        try await stop()
        mayClose = true
        removePresentation()
        window?.close()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if mayClose { return true }
        Task { [weak self] in
            do { try await self?.stopAndClose() }
            catch is CancellationError {}
            catch { self?.showIssue(error) }
        }
        return false
    }
    func windowWillClose(_ notification: Notification) { onClose?(); onClose = nil }
    @objc private func presentationWindowBecameKey(_ notification: Notification) {
        guard notification.object as? NSWindow === presentationWindow else { return }
        if !isEmbedded || screenOwnsFocus { focusScreen() }
    }
    @objc private func presentationWindowResignedKey(_ notification: Notification) {
        guard notification.object as? NSWindow === presentationWindow else { return }
        keyboardCapture.stop()
        inputView.releaseFocus()
    }

    @objc private func reconnect(_ sender: Any?) { reconnect(choosing: nil) }

    private func reconnect(choosing source: RemoteScreenCaptureSource?) {
        guard !closing, stoppingTask == nil else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.stop()
                // Disconnecting can be cancelled at a pending capture's save prompt, so the current
                // connection keeps its source until it has ended.
                if let source { self.session.chooseCaptureSource(source) }
                self.connectIfNeeded()
            }
            catch is CancellationError {}
            catch { self.showIssue(error) }
        }
    }

    /// Changing the source reconnects the screen, so it follows Reconnect's availability.
    private var canChooseCaptureSource: Bool {
        captureSourceTask == nil && stoppingTask == nil && isScreenActionEnabled("reconnect")
    }

    @objc private func chooseCaptureSource(_ sender: Any?) {
        guard canChooseCaptureSource else { return }
        // A button shows the sources below itself; a context menu's item shows them where it was opened.
        let anchor = sender as? NSButton ?? viewport
        let location = sender is NSButton ? NSPoint(x: 0, y: anchor.bounds.maxY + 4)
            : anchor.convert(anchor.window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        captureSourceTask = Task { [weak self] in
            guard let self else { return }
            defer { self.captureSourceTask = nil; self.update() }
            do {
                let sources = try await self.session.availableCaptureSources()
                try Task.checkCancellation()
                guard !self.closing else { return }
                guard !sources.isEmpty else {
                    throw RemoteDeviceWindowError.unavailable("No device screens are available. Connect the device to this Mac with a cable, then try again.")
                }
                // macOS can list several devices under one name; numbering keeps each choice distinct.
                let chosen = self.session.captureSource
                let menu = NSMenu()
                for (index, source) in sources.enumerated() {
                    let earlier = sources[..<index].count { $0.name == source.name }
                    let item = NSMenuItem(title: earlier == 0 ? source.name : "\(source.name) (\(earlier + 1))",
                                          action: #selector(self.captureSourceSelected(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = source
                    item.state = source == chosen ? .on : .off
                    menu.addItem(item)
                }
                menu.popUp(positioning: nil, at: location, in: anchor)
            } catch is CancellationError {}
            catch { self.showIssue(error) }
        }
        update()
    }

    @objc private func captureSourceSelected(_ item: NSMenuItem) {
        guard let source = item.representedObject as? RemoteScreenCaptureSource, !closing, !mayClose else { return }
        if session.captureSource != source || session.state != .connected { reconnect(choosing: source) }
        update()
    }

    /// The canvas's context menu holds the screen's connection actions outside the device.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if session.captureSource != nil || session.needsCaptureSource {
            let source = NSMenuItem(title: "Choose Screen Source…", action: #selector(chooseCaptureSource(_:)), keyEquivalent: "")
            source.target = self
            menu.addItem(source)
        }
        let reconnect = NSMenuItem(title: "Reconnect", action: #selector(reconnect(_:)), keyEquivalent: "")
        reconnect.target = self
        menu.addItem(reconnect)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        ["captureKeyboard", "resizeApp", "home", "lock", "volumeDown", "volumeUp", NSToolbarItem.Identifier.flexibleSpace.rawValue, "capture", "record", "compact", "reconnect"].map { NSToolbarItem.Identifier($0) }
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let presentation = screenActionPresentation(itemIdentifier.rawValue) else { return nil }
        let (label, symbol) = presentation
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = label
        item.toolTip = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        if itemIdentifier.rawValue == "captureKeyboard" {
            let button = NSButton(image: item.image ?? NSImage(), target: self, action: #selector(toolbarAction(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(itemIdentifier.rawValue)
            button.setButtonType(.pushOnPushOff)
            button.bezelStyle = .toolbar
            button.setAccessibilityLabel(label)
            item.view = button
        }
        item.target = self
        item.action = #selector(toolbarAction(_:))
        item.autovalidates = false
        let menuItem = NSMenuItem(title: label, action: #selector(toolbarAction(_:)), keyEquivalent: "")
        menuItem.target = self
        menuItem.representedObject = itemIdentifier.rawValue
        item.menuFormRepresentation = menuItem
        toolbarItems[itemIdentifier.rawValue] = item
        update()
        return item
    }
    @objc private func toolbarAction(_ sender: Any) {
        guard let identifier = (sender as? NSToolbarItem)?.itemIdentifier.rawValue
            ?? (sender as? NSButton)?.identifier?.rawValue ?? (sender as? NSMenuItem)?.representedObject as? String else { return }
        performScreenAction(identifier)
    }

    func screenActionPresentation(_ identifier: String) -> (title: String, symbolName: String)? {
        if identifier == "resizeApp" { return (session.isResizingApp ? "Stop Resize" : "Resize App", "arrow.up.left.and.arrow.down.right") }
        if identifier == "captureKeyboard" { return (capturesKeyboard ? "Release Keyboard" : "Capture Keyboard", "keyboard") }
        if identifier == "record" {
            if session.hasUnfinishedRecording { return ("Stop Recording", "stop.circle") }
            if session.completedRecording != nil { return ("Save Recording…", "square.and.arrow.down") }
            return ("Record Screen", "record.circle")
        }
        let fixed: [String: (title: String, symbolName: String)] = [
            "home": ("Home", "house"), "lock": ("Lock", "lock"),
            "volumeDown": ("Volume Down", "speaker.minus"), "volumeUp": ("Volume Up", "speaker.plus"),
            "capture": ("Save Screenshot…", "camera"), "compact": ("Show in Main Window", "arrow.up.left.and.arrow.down.right"),
            "reconnect": ("Reconnect", "arrow.clockwise"),
        ]
        return fixed[identifier]
    }

    func isScreenActionEnabled(_ identifier: String) -> Bool {
        guard !closing, !mayClose, !changingPresentation else { return false }
        switch identifier {
        case "resizeApp": return session.canResizeApp && appResizeTask == nil && recordingTask == nil && capturePanel == nil && recordingPanel == nil
        case "captureKeyboard": return session.state == .connected && session.inputCapabilities.contains(.keyboard)
        case "home", "lock", "volumeDown", "volumeUp":
            return session.state == .connected && session.inputCapabilities.contains(.button)
        case "capture": return canSaveScreenshot
        case "record":
            if session.hasUnfinishedRecording { return canStopRecording }
            if session.completedRecording != nil { return canSaveRecording }
            return canStartRecording
        case "compact":
            return onShowInMainWindow != nil && presentationWindow?.attachedSheet == nil
                && presentationWindow?.styleMask.contains(.fullScreen) != true
        case "reconnect":
            return session.state != .connecting && session.state != .stopping && captureTask == nil && recordingTask == nil && inventoryAvailable
        default: return false
        }
    }

    func performScreenAction(_ identifier: String) {
        guard isScreenActionEnabled(identifier) else { return }
        switch identifier {
        case "captureKeyboard":
            if !keyboardCapture.stop() {
                focusScreen()
                do { try startKeyboardCapture() } catch { showIssue(error) }
            }
            update()
        case "resizeApp": toggleAppResize()
        case "compact": onShowInMainWindow?()
        case "reconnect": reconnect(nil)
        case "capture": saveScreenshot()
        case "record":
            if session.hasUnfinishedRecording { stopScreenRecording(nil) }
            else if session.completedRecording != nil { saveScreenRecording(nil) }
            else { recordScreen(nil) }
        default:
            let usage: Int? = switch identifier {
            case "home": 0x40
            case "lock": 0x30
            case "volumeDown": 0xea
            case "volumeUp": 0xe9
            default: nil
            }
            guard let usage, session.state == .connected, session.inputCapabilities.contains(.button) else { return }
            inputView.enqueueInput(for: .button) { [session] in
                try await session.sendButton(usagePage: 0x0c, usage: usage, state: .down)
                try await session.sendButton(usagePage: 0x0c, usage: usage, state: .up)
            }
        }
    }

    private func toggleAppResize() {
        appResizeTask = Task { [weak self] in
            guard let self else { return }
            let restoreScreenFocus = self.screenOwnsFocus
            self.changingPresentation = true
            self.relinquishScreenFocus()
            let releasedResponder = self.presentationWindow?.firstResponder
            self.update()
            defer {
                self.appResizeTask = nil
                self.changingPresentation = false
                self.requestedAppSize = nil
                self.update()
                if restoreScreenFocus, self.presentationWindow?.isKeyWindow == true,
                   self.presentationWindow?.firstResponder === releasedResponder { self.focusScreen() }
            }
            do {
                try await self.captureTask?.value
                try Task.checkCancellation()
                if self.session.isResizingApp { try await self.session.stopAppResize() }
                else { try await self.session.startAppResize(size: self.viewport.bounds.size) }
            } catch is CancellationError {}
            catch { self.showIssue(error) }
        }
        update()
    }

    func layoutScreen() {
        guard !changingPresentation, session.isResizingApp, !session.isChangingDisplay,
              viewport.bounds.width > 0, viewport.bounds.height > 0 else { return }
        let size = viewport.bounds.size
        guard requestedAppSize != size else { return }
        requestedAppSize = size
        session.resizeApp(to: size)
    }

    func windowDidResize(_ notification: Notification) { layoutScreen() }

    private var canStartRecording: Bool {
        !closing && !changingPresentation && inventoryAvailable && session.canRecordScreen && !session.hasUnfinishedRecording
            && session.completedRecording == nil && recordingTask == nil && recordingPanel == nil
    }

    private var canStopRecording: Bool {
        !closing && !changingPresentation && !finishingRecording && session.hasUnfinishedRecording && session.recordingState != .stopping
    }

    private var canSaveRecording: Bool {
        !closing && !changingPresentation && session.completedRecording != nil && recordingTask == nil
    }

    private var canDiscardScreenshot: Bool {
        !closing && !changingPresentation && completedScreenshot != nil && captureTask == nil && capturePanel == nil
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(saveScreenshot(_:)):
            return canSaveScreenshot
        case #selector(discardScreenshot(_:)):
            return canDiscardScreenshot
        case #selector(recordScreen(_:)), #selector(recordScreenTo(_:)): return canStartRecording
        case #selector(stopScreenRecording(_:)):
            return canStopRecording
        case #selector(saveScreenRecording(_:)), #selector(discardScreenRecording(_:)):
            return canSaveRecording
        case #selector(toolbarAction(_:)):
            guard let identifier = menuItem.representedObject as? String else { return false }
            return isScreenActionEnabled(identifier)
        case #selector(chooseCaptureSource(_:)): return canChooseCaptureSource
        case #selector(reconnect(_:)): return isScreenActionEnabled("reconnect")
        default: return true
        }
    }

    @objc func saveScreenshot(_ sender: Any?) { saveScreenshot() }

    @objc func recordScreen(_ sender: Any?) {
        guard canStartRecording else { return }
        guard let directory = captureDirectory else {
            showIssue(RemoteDeviceWindowError.unavailable("Choose a recording destination using File → Record Screen…."))
            return
        }
        startRecording(to: directory.appendingPathComponent(recordingFilename))
    }

    @objc func recordScreenTo(_ sender: Any?) {
        guard canStartRecording else { return }
        runRecordingOperation { [self] in
            let destination = try await chooseRecordingDestination()
            guard !closing, inventoryAvailable, session.canRecordScreen else { throw CancellationError() }
            recordingDestination = .selected(destination)
            try await session.startRecording()
        }
    }

    private func startRecording(to destination: URL) {
        guard canStartRecording else { return }
        recordingDestination = .automatic(destination)
        runRecordingOperation { [session] in try await session.startRecording() }
    }

    @objc func stopScreenRecording(_ sender: Any?) {
        guard canStopRecording else { return }
        let acceptedStart = recordingTask
        runRecordingOperation(finishing: true) { [self] in
            try await acceptedStart?.value
            _ = try await session.stopRecording()
            if let recordingDestination { try await saveCompletedRecording(to: recordingDestination) }
            else if session.completedRecording != nil {
                let destination = try await chooseRecordingDestination()
                try await saveCompletedRecording(to: .selected(destination))
            }
        }
    }

    @objc func saveScreenRecording(_ sender: Any?) {
        guard canSaveRecording else { return }
        runRecordingOperation { [self] in
            let destination = try await chooseRecordingDestination()
            try await saveCompletedRecording(to: .selected(destination))
        }
    }

    @objc func discardScreenRecording(_ sender: Any?) {
        guard canSaveRecording else { return }
        runRecordingOperation { [self] in
            let alert = NSAlert()
            alert.messageText = "Discard the recording?"
            alert.informativeText = "The recording has not been saved. This action cannot be undone."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Discard")
            guard await response(to: alert) == .alertSecondButtonReturn else { throw CancellationError() }
            session.discardCompletedRecording()
            recordingDestination = nil
        }
    }

    private func runRecordingOperation(finishing: Bool = false, _ operation: @escaping @MainActor () async throws -> Void) {
        let identifier = UUID()
        recordingTaskIdentifier = identifier
        finishingRecording = finishing
        recordingTask = Task { [self] in
            defer {
                if recordingTaskIdentifier == identifier {
                    recordingTask = nil
                    recordingTaskIdentifier = nil
                    finishingRecording = false
                    update()
                }
            }
            do { try await operation() }
            catch is CancellationError { throw CancellationError() }
            catch { showIssue(error); throw error }
        }
        update()
    }

    private func finishRecordingBeforeDisconnect() async throws {
        let wasRecording = session.hasUnfinishedRecording
        if wasRecording { _ = try await session.stopRecording() }
        guard session.completedRecording != nil else { return }
        if wasRecording, let recordingDestination {
            try await saveCompletedRecording(to: recordingDestination)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Save the recording before closing?"
        alert.informativeText = "Your recording will be lost if you don’t save it."
        alert.addButton(withTitle: "Save…")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        switch await response(to: alert) {
        case .alertFirstButtonReturn:
            let destination = try await chooseRecordingDestination()
            try await saveCompletedRecording(to: .selected(destination))
        case .alertThirdButtonReturn:
            session.discardCompletedRecording()
            recordingDestination = nil
        default: throw CancellationError()
        }
    }

    private func response(to alert: NSAlert) async -> NSApplication.ModalResponse {
        guard let window = windowForSheet() else { return .cancel }
        return await presentAlert(alert, window)
    }

    private var captureDirectory: URL? {
        let preferences = UserDefaults(suiteName: "dev.lynnswap.NeoSimulator.Renderer") ?? .standard
        if let path = preferences.string(forKey: "ScreenShotSaveLocation") {
            let expanded = NSString(string: path).expandingTildeInPath
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue {
                return URL(fileURLWithPath: expanded, isDirectory: true)
            }
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
    }

    private var recordingFilename: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let suffix = UTType.mpeg4Movie.preferredFilenameExtension ?? "mp4"
        return "Device Screen Recording - \(window?.title ?? device.name) - \(formatter.string(from: Date())).\(suffix)"
            .replacingOccurrences(of: "/", with: ".").replacingOccurrences(of: ":", with: ".")
    }

    private func chooseRecordingDestination() async throws -> URL {
        guard let window = windowForSheet() else { throw CancellationError() }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        panel.directoryURL = recordingDestination?.url.deletingLastPathComponent() ?? captureDirectory
        panel.nameFieldStringValue = recordingDestination?.url.lastPathComponent ?? recordingFilename
        recordingPanel = panel
        update()
        let result = await presentSavePanel(panel, window)
        recordingPanel = nil
        update()
        guard result == .OK, let destination = panel.url else { throw CancellationError() }
        let preferences = UserDefaults(suiteName: "dev.lynnswap.NeoSimulator.Renderer") ?? .standard
        preferences.set(destination.deletingLastPathComponent().path, forKey: "ScreenShotSaveLocation")
        return destination
    }

    private func saveCompletedRecording(to destination: RecordingDestination) async throws {
        guard let recording = session.completedRecording else { return }
        try await Self.writeRecording(recording, to: destination)
        session.discardCompletedRecording()
        recordingDestination = nil
    }

    @concurrent
    private nonisolated static func writeRecording(_ recording: RemoteDeviceRecording, to destination: RecordingDestination) async throws {
        switch destination {
        case .selected(let url):
            try recording.data.write(to: url, options: .atomic)
        case .automatic(let url):
            let manager = FileManager.default
            let folder = url.deletingLastPathComponent()
            let temporary = folder.appendingPathComponent(".NeoSimulatorRecording-\(UUID().uuidString).mp4")
            do {
                try recording.data.write(to: temporary, options: .atomic)
                let base = url.deletingPathExtension().lastPathComponent
                for number in 1...99 {
                    let candidate = number == 1 ? url : folder.appendingPathComponent("\(base) #\(number).\(url.pathExtension)")
                    do {
                        try manager.moveItem(at: temporary, to: candidate)
                        return
                    } catch CocoaError.fileWriteFileExists { continue }
                }
                throw RemoteDeviceWindowError.unavailable("Could not save \(url.lastPathComponent): names through #99 are already taken in \(folder.path).")
            } catch {
                do { try manager.removeItem(at: temporary) }
                catch let cleanup as CocoaError where cleanup.code == .fileNoSuchFile {}
                catch let cleanup {
                    throw RemoteDeviceWindowError.cleanup([error.localizedDescription,
                        "Temporary recording remains at \(temporary.path): \(cleanup.localizedDescription)"])
                }
                throw error
            }
        }
    }

    private var canSaveScreenshot: Bool {
        !closing && !changingPresentation && captureTask == nil && capturePanel == nil
            && (completedScreenshot != nil || inventoryAvailable && session.canCaptureScreenshot)
    }

    private func saveScreenshot() {
        guard canSaveScreenshot else { return }
        runCaptureOperation { [self] in
            let destination = try await chooseScreenshotDestination()
            guard !closing else { throw CancellationError() }
            try await captureAndSaveScreenshot(to: destination)
        }
    }

    private func captureScreenshot(to destination: URL) {
        guard canSaveScreenshot else { return }
        runCaptureOperation { [self] in try await captureAndSaveScreenshot(to: destination) }
    }

    private func runCaptureOperation(_ operation: @escaping @MainActor () async throws -> Void) {
        captureTask = Task { [self] in
            defer { captureTask = nil; update() }
            do { try await operation() }
            catch is CancellationError { throw CancellationError() }
            catch { showIssue(error); throw error }
        }
        update()
    }

    private func captureAndSaveScreenshot(to destination: URL) async throws {
        if completedScreenshot == nil {
            completedScreenshot = try await session.captureScreenshot()
        }
        try await saveCompletedScreenshot(to: destination)
    }

    private func saveCompletedScreenshot(to destination: URL) async throws {
        guard let image = completedScreenshot else {
            throw RemoteDeviceWindowError.unavailable("There is no screenshot to save.")
        }
        try await writeImage(image, destination)
        completedScreenshot = nil
    }

    private func chooseScreenshotDestination() async throws -> URL {
        guard let window = windowForSheet() else { throw CancellationError() }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.directoryURL = captureDirectory
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        panel.nameFieldStringValue = "Device Screenshot - \(self.window?.title ?? device.name) - \(formatter.string(from: Date())).png"
            .replacingOccurrences(of: "/", with: ".").replacingOccurrences(of: ":", with: ".")
        capturePanel = panel
        update()
        defer { capturePanel = nil; update() }
        guard await presentSavePanel(panel, window) == .OK, let destination = panel.url else { throw CancellationError() }
        let preferences = UserDefaults(suiteName: "dev.lynnswap.NeoSimulator.Renderer") ?? .standard
        preferences.set(destination.deletingLastPathComponent().path, forKey: "ScreenShotSaveLocation")
        return destination
    }

    @objc func discardScreenshot(_ sender: Any?) {
        guard canDiscardScreenshot else { return }
        runCaptureOperation { [self] in
            let alert = NSAlert()
            alert.messageText = "Discard the screenshot?"
            alert.informativeText = "The screenshot has not been saved. This action cannot be undone."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Discard")
            guard await response(to: alert) == .alertSecondButtonReturn else { throw CancellationError() }
            completedScreenshot = nil
        }
    }

    private func finishScreenshotBeforeDisconnect() async throws {
        guard completedScreenshot != nil else { return }
        let alert = NSAlert()
        alert.messageText = "Save the screenshot before closing?"
        alert.informativeText = "Your screenshot will be lost if you don’t save it."
        alert.addButton(withTitle: "Save…")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        switch await response(to: alert) {
        case .alertFirstButtonReturn:
            let destination = try await chooseScreenshotDestination()
            try await saveCompletedScreenshot(to: destination)
        case .alertThirdButtonReturn: completedScreenshot = nil
        default: throw CancellationError()
        }
    }

    @concurrent
    private nonisolated static func writeScreenshot(_ image: CGImage, to destination: URL) async throws {
        let data = NSMutableData()
        guard let output = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw RemoteDeviceWindowError.unavailable("The screenshot could not be encoded as PNG.")
        }
        CGImageDestinationAddImage(output, image, nil)
        guard CGImageDestinationFinalize(output) else {
            throw RemoteDeviceWindowError.unavailable("The screenshot could not be encoded as PNG.")
        }
        try (data as Data).write(to: destination, options: .atomic)
    }
}

/// Contains the screen with whichever input view it uses, and moves with the presentation between windows.
@MainActor
private final class RemoteDeviceViewport: NSView {
    var canInstallApplications: () -> Bool = { false }
    var installApplications: ([URL]) -> Void = { _ in }

    init() {
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { nil }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        canInstallApplications() && applications(in: sender) != nil ? .copy : []
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard canInstallApplications(), let urls = applications(in: sender) else { return false }
        installApplications(urls)
        return true
    }

    /// Rejects a drag that includes other files, rather than installing only some of what was dropped.
    private func applications(in sender: any NSDraggingInfo) -> [URL]? {
        let pasteboard = sender.draggingPasteboard
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let applications = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true, .urlReadingContentsConformToTypes: [UTType.applicationBundle.identifier],
        ]) as? [URL] ?? []
        return applications.isEmpty || applications.count != files.count ? nil : applications
    }
}
