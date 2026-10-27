import AppKit
import UniformTypeIdentifiers
@_spi(NeoSimulator) import XcodeSimulatorHost

@MainActor
final class DeviceWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, NSToolbarItemValidation, DisplayScaling {
    /// The device's current connection. A restart replaces it after the
    /// device boots again, keeping this window.
    private(set) var session: DeviceSession
    private var closed = false
    /// Suppresses geometry saving from restart until the next device connection.
    private var isRestarting = false
    private enum OrientationRead { case notStarted, pending, finished }
    private var orientationRead = OrientationRead.notStarted
    /// Distinguishes a previously presented compact frame from its unplaced initial frame.
    private var hasPresentedCompactWindow = false
    private let onClose: (DeviceWindowController, DeviceLifetimeChoice?) -> Void
    /// The choice File ▸ Close Window… made for this close, which takes
    /// precedence over the default close action.
    private var closeChoice: DeviceLifetimeChoice?
    private let onRestart: (DeviceWindowController, _ erasing: Bool) -> Void
    private let onShutDown: ((DeviceWindowController) -> Void)?
    private var content: DeviceContentView
    private let fitting: DisplayFitting
    let canvasZoom = CanvasZoom()
    private let keyboard: DisplayKeyboardInput
    private let makeKeyboardCaptureTap: @MainActor () -> any KeyboardEventTap
    private let makeExternalDisplayWindow: @MainActor (NSRect) -> NSWindow
    private let applicationIsActive: () -> Bool
    private var deviceToolbar: DeviceToolbar?
    private var customLocation: CustomLocationWindowController?
    /// Keeps where each device's window closes and its display scale.
    private let preferences: any PreferenceStore
    /// Where the device's window last closed in the current arrangement of
    /// screens, which a new window is centered at.
    private let savedCenter: NSPoint?
    /// The last compact-window scale in the current arrangement of screens.
    private var savedScale: CGFloat?
    /// Initial placement and the frame it produced, until the first orientation reading.
    private var initialPlacement: (place: ((NSWindow) -> Void)?, frame: NSRect)?
    /// Includes full-screen transitions, when scaling and bezel resizing are unavailable.
    private var isFullScreen: Bool { fitting.isFullScreen }
    /// The drag on a corner of the bezel in progress, and the largest scale it
    /// may give the display.
    private var bezelResize: (drag: BezelResize, maximumScale: CGFloat)?
    /// Injectable window-server drag operation.
    private let performWindowDrag: (NSWindow, NSEvent) -> Void
    private let presentCompactWindow: (NSWindow) -> Void
    private var screenParametersObserver: (any NSObjectProtocol)?
    /// Set while the window takes the size of a chosen display scale, which
    /// the resize must not change.
    private var isSizingWindow = false
    /// The title bar's height for each toolbar style, as the window last laid
    /// it out, and macOS 26's heights for the styles it has not taken yet.
    private var titleBarHeights: [NSWindow.ToolbarStyle: CGFloat] = [.unified: 52, .expanded: 76, .unifiedCompact: 40]
    /// I/O ▸ Touch Pressure's app-wide settings, which every window shares.
    let touchPressure: TouchPressure
    /// Window ▸ Show Apple TV Remote's panel, which every window shares.
    let tvRemote: TVRemoteController
    private var touchPressureObserver: (any NSObjectProtocol)?
    private var touchIndicatorObserver: (any NSObjectProtocol)?
    private var keyboardSelectionObserver: (any NSObjectProtocol)?
    private var audioRouteObserver: (any NSObjectProtocol)?
    /// Only the key window receives host keyboard input and input-source changes.
    private var isKey = false
    private weak var embeddedContainer: NSView?
    private weak var embeddedParent: NSViewController?
    private(set) lazy var presentationViewController: NSViewController = {
        let controller = SimulatorPresentationViewController(owner: self)
        controller.view = content
        return controller
    }()
    private var presentationObservers: [NSObjectProtocol] = []
    private static weak var embeddedController: DeviceWindowController?
    var isEmbedded: Bool { embeddedContainer != nil }
    var presentationWindow: NSWindow? { isEmbedded ? content.window : window }
    var onShowInMainWindow: (() -> Void)? {
        didSet { deviceToolbar?.setShowsMainWindowAction(onShowInMainWindow != nil) }
    }
    var canMovePresentation: Bool {
        guard !closed, !isFullScreen, let window = presentationWindow else { return false }
        return window.attachedSheet == nil && !window.styleMask.contains(.fullScreen)
    }
    private var canShowInMainWindow: Bool { canMovePresentation && onShowInMainWindow != nil }
    @objc func showInMainWindow(_ sender: Any?) {
        guard canShowInMainWindow else { return }
        onShowInMainWindow?()
    }
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        item.action != #selector(showInMainWindow(_:)) || canShowInMainWindow
    }
    /// The window of the device's external display while the display is on.
    private(set) var externalDisplayWindow: ExternalDisplayWindowController?
    /// How often and how long the window looks for its display's
    /// user-interface plugin.
    private let userInterfacePluginLookUp: (attempts: Int, interval: Duration)
    var staysOnTop: Bool { window?.level == .floating }
    private var activeKeyboardInput: DisplayKeyboardInput {
        if let externalDisplayWindow, externalDisplayWindow.isKey { return externalDisplayWindow.keyboard }
        return keyboard
    }
    var capturesKeyboard: Bool { activeKeyboardInput.capture.isCapturing }

    /// The device window of the key window, whose device the menus act on:
    /// see `deviceWindow(for:)`.
    static var keyDeviceWindow: DeviceWindowController? { deviceWindow(for: NSApp.keyWindow) }

    /// Finds the owning device window, including for an external display window.
    static func deviceWindow(for window: NSWindow?) -> DeviceWindowController? {
        if let embeddedController, let window, embeddedController.presentationWindow === window {
            return embeddedController
        }
        return switch window?.windowController {
        case let controller as DeviceWindowController: controller
        case let controller as ExternalDisplayWindowController: controller.deviceWindow
        default: nil
        }
    }

    init(session: DeviceSession, preferences: any PreferenceStore = HostPreferences.defaults,
         touchPressure: TouchPressure, tvRemote: TVRemoteController,
         performWindowDrag: @escaping (NSWindow, NSEvent) -> Void = { $0.performDrag(with: $1) },
         presentCompactWindow: @escaping (NSWindow) -> Void = { $0.makeKeyAndOrderFront(nil) },
         makeKeyboardCaptureTap: @escaping @MainActor () -> any KeyboardEventTap = { SystemKeyboardEventTap() },
         applicationIsActive: @escaping () -> Bool = { NSApp.isActive },
         makeExternalDisplayWindow: @escaping @MainActor (NSRect) -> NSWindow = ExternalDisplayWindowController.makeWindow,
         userInterfacePluginLookUp: (attempts: Int, interval: Duration) = (40, .milliseconds(250)),
         onClose: @escaping (DeviceWindowController, DeviceLifetimeChoice?) -> Void,
         onRestart: @escaping (DeviceWindowController, _ erasing: Bool) -> Void = { _, _ in },
         onShutDown: ((DeviceWindowController) -> Void)? = nil) throws {
        self.session = session
        self.userInterfacePluginLookUp = userInterfacePluginLookUp
        self.preferences = preferences
        self.touchPressure = touchPressure
        self.tvRemote = tvRemote
        self.performWindowDrag = performWindowDrag
        self.presentCompactWindow = presentCompactWindow
        self.makeKeyboardCaptureTap = makeKeyboardCaptureTap
        self.makeExternalDisplayWindow = makeExternalDisplayWindow
        self.applicationIsActive = applicationIsActive
        // Read geometry once per connection for the current screen arrangement.
        let saved = preferences.windowGeometry(forDevice: session.device.identity.preferenceIdentifier, screens: Self.screenFrames)
        savedCenter = saved.center
        savedScale = saved.scale
        self.onClose = onClose
        self.onRestart = onRestart
        self.onShutDown = onShutDown
        content = DeviceContentView(display: session.display.view, usesNativeCanvas: session.display.usesNativeCanvas)
        let natural = session.display.size(for: 1)
        guard natural.width > 0, natural.height > 0 else {
            session.disconnect()
            throw HostError.unavailable("Simulator display has no usable size")
        }
        // Initial width determines toolbar style before display scaling.
        let window = DeviceWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        fitting = DisplayFitting(display: session.display, content: content)
        keyboard = DisplayKeyboardInput(window: window, display: session.display,
                                        captureTap: makeKeyboardCaptureTap(), applicationIsActive: applicationIsActive)
        super.init(window: window)
        keyboard.capture.failure = { [weak self] in self?.present($0) }
        (window.title, window.subtitle) = deviceWindowTitles(name: session.device.name, runtimeName: session.device.runtimeName)
        window.appearance = NSAppearance(named: .darkAqua)
        // AppKit draws the opaque title bar; see `updateHeaderShape()`.
        window.titlebarSeparatorStyle = .none
        window.tabbingMode = .disallowed
        window.backgroundColor = session.display.usesNativeCanvas ? .windowBackgroundColor : .clear
        window.isOpaque = session.display.usesNativeCanvas
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        // Full screen remains available even when the bezel disables resizing.
        window.collectionBehavior = [.fullScreenPrimary, .fullScreenAllowsTiling]
        window.delegate = self
        window.displayScale = { [weak self] in self?.session.display.renderScale ?? 1 }
        window.handleMouseEvent = { [weak self] in self?.handleBezelDrag($0) ?? false }
        attachSession()
        // Apply the bezel before computing display scale.
        session.display.setChromeVisible(preferences.showsDeviceBezels)
        bezelChanged()
        updateToolbarStyle(forWidth: window.frame.width)
        // The smallest size a manual resize leaves the window at.
        updateContentMinimumSize()
        // Keep the window on screen after display or Dock geometry changes.
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updateContentMinimumSize()
                if self.isEmbedded { self.updateEmbeddedScale() }
                else {
                    if !self.fitting.scalesDisplay { self.updateWindowSize() }
                    self.moveWindowOntoScreen()
                }
            }
        }
        touchPressureObserver = NotificationCenter.default.addObserver(
            forName: TouchPressure.didChangeNotification, object: touchPressure, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.touchPressureChanged() }
        }
        touchIndicatorObserver = NotificationCenter.default.addObserver(
            forName: TouchIndicator.didChangeNotification, object: preferences, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showTouchIndicators() }
        }
        keyboardSelectionObserver = NotificationCenter.default.addObserver(
            forName: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keyboardSelectionChanged() }
        }
        // Audio-route preferences apply across windows.
        audioRouteObserver = NotificationCenter.default.addObserver(
            forName: AudioRouting.didChangeNotification, object: preferences, queue: .main) { [weak self] notification in
            let scope = (notification.userInfo?[AudioRouting.scopeKey] as? UInt64).flatMap(AudioScope.init(rawValue:))
            MainActor.assumeIsolated { if let scope { self?.audioRouteChosen(in: scope) } }
        }
        showInitialDisplay()
    }

    private var initialScale: CGFloat {
        min(scale(for: .fitScreen) ?? .infinity, savedScale ?? 1)
    }

    private func showInitialDisplay() {
        // DeviceKit initially lays out its loading indicator. Preserve the
        // window's viewport while the device composition becomes available.
        if session.display.usesNativeCanvas { resizeDisplay(); return }
        showDisplay(fitting: { self.initialScale })
    }

    /// Recomputes fit if a narrower window switches to the taller expanded title bar.
    private func showDisplay(fitting scale: () -> CGFloat?) {
        guard let first = scale() else { return }
        showDisplay(at: first)
        if let second = scale(), second < first { showDisplay(at: second) }
    }

    /// Recomputes initial placement if scaling changes the title-bar height.
    private func placeAtInitialScale(_ place: ((NSWindow) -> Void)?) {
        if session.display.usesNativeCanvas { displayGeometryChanged(placing: place); return }
        let scale = initialScale
        fitting.setScale(scale)
        displayGeometryChanged(placing: place)
        let refit = initialScale
        guard refit < scale else { return }
        fitting.setScale(refit)
        displayGeometryChanged(placing: place)
    }

    /// The frames of the Mac's screens, whose arrangement keys the saved
    /// window geometry.
    private static var screenFrames: [NSRect] { NSScreen.screens.map(\.frame) }

    /// Restores the saved center or cascades a new window, keeping it on screen.
    /// The first orientation reading may resize and recenter it unless the user has moved or resized it.
    /// Cascaded windows retain their top-left corner.
    func showNewWindow(cascadingFrom cascadePoint: inout NSPoint) {
        guard let window else { return }
        let place: ((NSWindow) -> Void)?
        if let center = savedCenter {
            place = { $0.setFrameOrigin(NSPoint(x: center.x - $0.frame.width * 0.5, y: center.y - $0.frame.height * 0.5)) }
            place?(window)
        } else {
            place = cascadePoint == .zero ? { $0.center() } : nil
            place?(window)
            cascadePoint = window.cascadeTopLeft(from: cascadePoint)
        }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        // The window opened at the scale for the main screen; it takes the
        // scale for the screen it is placed on.
        placeAtInitialScale(place)
        initialPlacement = orientationRead == .finished ? nil : (place, window.frame)
        readInitialOrientation()
    }

    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        hasPresentedCompactWindow = true
    }

    /// Changes only the presentation; the owner retains the session and its operations.
    func embed(in parent: NSViewController) {
        guard !closed else { return }
        let container = parent.view
        saveWindowGeometry()
        releasePresentationFocus()
        window?.orderOut(nil)
        content.removeFromSuperview()
        window?.contentView = nil
        presentationViewController.removeFromParent()
        parent.addChild(presentationViewController)
        embeddedParent = parent
        embeddedContainer = container
        Self.embeddedController = self
        content.isEmbedded = true
        deviceToolbar?.updateNativeRotation()
        content.isSizedToDisplay = false
        content.displayGap = 0
        content.frame = container.bounds
        content.autoresizingMask = [.width, .height]
        container.addSubview(content)
        keyboard.attach(to: content.window)
        observePresentationWindow()
        updateEmbeddedScale()
        if content.window?.isKeyWindow == true { activateDisplay() }
        readInitialOrientation()
    }

    /// Presents the same native display in its standalone window.
    func showCompactWindow() {
        guard !closed else { return }
        let needsInitialPlacement = !hasPresentedCompactWindow
        releasePresentationFocus()
        content.removeFromSuperview()
        presentationViewController.removeFromParent()
        embeddedParent = nil
        embeddedContainer = nil
        if Self.embeddedController === self { Self.embeddedController = nil }
        content.isEmbedded = false
        deviceToolbar?.updateNativeRotation()
        content.autoresizingMask = []
        window?.contentView = content
        keyboard.attach(to: window)
        observePresentationWindow()
        bezelChanged()
        showInitialDisplay()
        if let window {
            let place: ((NSWindow) -> Void)?
            if needsInitialPlacement {
                if let center = savedCenter {
                    place = { $0.setFrameOrigin(NSPoint(x: center.x - $0.frame.width * 0.5, y: center.y - $0.frame.height * 0.5)) }
                } else { place = { $0.center() } }
                place?(window)
            } else { place = nil }
            presentCompactWindow(window)
            hasPresentedCompactWindow = true
            if needsInitialPlacement {
                placeAtInitialScale(place)
                initialPlacement = orientationRead == .finished ? nil : (place, window.frame)
            }
        }
        readInitialOrientation()
    }

    /// Removes a scene without ending its device connection.
    func detachPresentation() {
        session.stopAppResize()
        releasePresentationFocus()
        window?.orderOut(nil)
        content.removeFromSuperview()
        presentationViewController.removeFromParent()
        embeddedParent = nil
        embeddedContainer = nil
        if Self.embeddedController === self { Self.embeddedController = nil }
        keyboard.attach(to: nil)
        observePresentationWindow()
    }

    private func releasePresentationFocus() {
        if let view = presentationWindow?.firstResponder as? NSView, view.isDescendant(of: content) {
            presentationWindow?.makeFirstResponder(nil)
        }
        isKey = false
        keyboard.setEnabled(false)
    }

    private func observePresentationWindow() {
        for observer in presentationObservers { NotificationCenter.default.removeObserver(observer) }
        presentationObservers.removeAll()
        guard let presented = presentationWindow else { return }
        if isEmbedded {
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                presentationObservers.append(NotificationCenter.default.addObserver(
                    forName: name, object: presented, queue: .main) { [weak self] notification in
                        let becameKey = notification.name == NSWindow.didBecomeKeyNotification
                        MainActor.assumeIsolated {
                            guard let self else { return }
                            if becameKey {
                                self.activateDisplay(focusingInput: presented.firstResponder === self.session.display.inputView)
                            }
                            else { self.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification)) }
                        }
                    })
            }
        }
        for name in [NSWindow.didChangeScreenNotification, NSWindow.didChangeBackingPropertiesNotification] {
            presentationObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: presented, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.updateContentMinimumSize()
                        if self.isEmbedded { self.updateEmbeddedScale() }
                        else if !self.fitting.scalesDisplay { self.updateWindowSize() }
                    }
                })
        }
    }

    /// Connects the window's toolbar, content, and display events to `session`.
    private func attachSession() {
        guard let window else { return }
        let toolbar = DeviceToolbar(controller: self)
        deviceToolbar = toolbar
        toolbar.attach(to: window)
        toolbar.setShowsMainWindowAction(onShowInMainWindow != nil)
        session.display.onPropertiesChange = { [weak self] in self?.displayPropertiesChanged() }
        session.display.nativePoseControls?.onError = { [weak self] in self?.present($0) }
        session.onAppResizeError = { [weak self] in self?.present($0) }
        session.onDisplayWillChange = { [weak self] in
            guard let self else { return }
            if !self.isFullScreen { self.saveWindowGeometry() }
            self.keyboard.setEnabled(false)
            self.session.display.onPropertiesChange = nil
        }
        session.onDisplayChange = { [weak self] in self?.appDisplayChanged() }
        session.onAppResizeGeometryChange = { [weak self] in self?.appGeometryChanged() }
        session.onExternalScreenChange = { [weak self] in self?.syncExternalDisplayWindow() }
        content.canImport = { [weak self] in self?.session.canPerformToolOperation == true }
        content.importFiles = { [weak self] in self?.importFiles($0) }
        content.onDisplaySizeChange = { [weak self] in
            guard let self else { return }
            if self.session.isResizingApp { self.session.resizeApp(to: self.content.availableDisplaySize) }
            else if self.isEmbedded { self.updateEmbeddedScale(layout: false) }
        }
        fitting.onNaturalSizeChange = { [weak self] in
            guard let self, self.isEmbedded else { return }
            self.updateEmbeddedScale()
        }
        presentationViewController.view = content
        content.onWindowChange = { [weak self] in
            guard let self else { return }
            self.keyboard.attach(to: self.presentationWindow)
            self.observePresentationWindow()
            if let window = self.presentationWindow, window.isKeyWindow {
                self.activateDisplay(focusingInput: !self.isEmbedded || window.firstResponder === self.session.display.inputView)
            }
        }
        if let embeddedContainer {
            content.isEmbedded = true
            content.frame = embeddedContainer.bounds
            content.autoresizingMask = [.width, .height]
            embeddedContainer.addSubview(content)
        } else { window.contentView = content }
        keyboard.attach(to: presentationWindow)
        observePresentationWindow()
        showResizeCursors()
        connectTouchPressure()
        showTouchIndicators()
        session.followBacklight()
        attachUserInterfacePlugin()
    }

    func toggleAppResize() {
        session.toggleAppResize(size: content.availableDisplaySize)
    }

    private func appDisplayChanged() {
        guard !closed else { return }
        let restoreInputFocus = (presentationWindow?.firstResponder as? NSView)?.isDescendant(of: content.display) == true
        content.setDisplay(session.display.view, usesNativeCanvas: session.display.usesNativeCanvas)
        content.scrollsDisplay = session.isResizingApp
        fitting.scalesDisplay = !session.isResizingApp
        fitting.attach(session.display, content: content)
        content.isSizedToDisplay = false
        keyboard.display = session.display
        session.display.onPropertiesChange = { [weak self] in self?.displayPropertiesChanged() }
        session.display.nativePoseControls?.onError = { [weak self] in self?.present($0) }
        if !session.isResizingApp { session.display.setChromeVisible(preferences.showsDeviceBezels) }
        bezelChanged()
        connectTouchPressure()
        showTouchIndicators()
        updateContentMinimumSize()
        if isEmbedded { updateEmbeddedScale() }
        else if session.isResizingApp || session.display.usesNativeCanvas { resizeDisplay() }
        else { updateWindowSize() }
        if presentationWindow?.isKeyWindow == true { activateDisplay(focusingInput: restoreInputFocus) }
    }

    private func appGeometryChanged() {
        guard session.isResizingApp else { return }
        session.display.view.invalidateIntrinsicContentSize()
        updateContentMinimumSize()
        content.needsLayout = true
    }

    // MARK: User-interface plugin

    private var pluginLookUp: Task<Void, Never>?

    /// Attaches the loaded plugin's toolbar. SimulatorKit owns its overlay and input focus.
    /// A failed plugin leaves the screen usable without its controls and reports the error.
    private func attachUserInterfacePlugin() {
        pluginLookUp?.cancel()
        pluginLookUp = nil
        guard session.capabilities.hasUserInterfacePlugin else { return }
        let session = self.session
        let schedule = userInterfacePluginLookUp
        pluginLookUp = Task.immediate { [weak self] in
            for attempt in 1...schedule.attempts {
                guard let self, !self.closed, self.session === session, session.isConnected else { return }
                do {
                    if let plugin = try session.display.userInterfacePlugin() {
                        self.showUserInterfacePlugin(plugin)
                        return
                    }
                } catch {
                    self.present(HostError.operation(
                        "The controls of \(session.device.name) are unavailable: \(error.localizedDescription)"))
                    return
                }
                if attempt < schedule.attempts { try? await Task.sleep(for: schedule.interval) }
            }
            guard let self, !self.closed, self.session === session, session.isConnected else { return }
            self.present(HostError.unavailable(
                "The controls of \(session.device.name) are unavailable: SimulatorKit did not load its user interface plugin."))
        }
    }

    private func showUserInterfacePlugin(_ plugin: SimulatorUserInterfacePlugin) {
        guard let window else { return }
        if let toolbar = plugin.toolbar {
            deviceToolbar?.attachPluginToolbar(toolbar, to: window)
            // The plugin's toolbar takes the window's toolbar style.
            deviceToolbar?.apply(window.toolbarStyle, to: window)
        }
        // The overlay is the display's input view now.
        if let presented = presentationWindow, presented.isKeyWindow,
           !isEmbedded || (presented.firstResponder as? NSView)?.isDescendant(of: content) == true { focusInput() }
    }

    /// Plugin-toolbar Home action.
    @objc func homeButtonPressed(_ sender: Any?) { perform(.home) }

    /// Plugin-toolbar Save Screen action.
    @objc func saveFramebufferImage(_ sender: Any?) { perform(.saveScreen) }

    /// Plugin-toolbar recording action, including Option-click on Save Screen.
    @objc func toggleVideoRecording(_ sender: Any?) {
        perform(session.recording == nil ? .recordScreen : .stopRecording)
    }

    // MARK: Restart

    /// Finishes an active recording, then disconnects from the device so that
    /// it can shut down. The window stays open for `reconnect(_:)`.
    func prepareForRestart() async {
        isRestarting = true
        if let window = presentationWindow, let sheet = window.attachedSheet {
            window.endSheet(sheet, returnCode: .cancel)
        }
        await session.finishRecording()
        guard !closed else { return }
        customLocation?.close()
        closeExternalDisplayWindow()
        keyboard.capture.stop()
        session.disconnect()
        fitting.invalidate()
        window?.subtitle = "Restarting…"
    }

    /// Shows the device again after a restart, through its new connection.
    func reconnect(_ session: DeviceSession, present: Bool = true) {
        guard !closed else {
            session.disconnect()
            return
        }
        // Preserve scale across reconnection, then fit the new display shape below the window's top edge.
        let scale = WindowScale.usable(self.session.display.renderScale) ?? 1
        let restoreInputFocus = !isEmbedded || presentationWindow?.firstResponder === self.session.display.inputView
        isRestarting = false
        self.session = session
        content.removeFromSuperview()
        content = DeviceContentView(display: session.display.view, usesNativeCanvas: session.display.usesNativeCanvas)
        fitting.attach(session.display, content: content)
        fitting.scalesDisplay = !session.isResizingApp
        keyboard.display = session.display
        attachSession()
        if let window {
            (window.title, window.subtitle) = deviceWindowTitles(
                name: session.device.name, runtimeName: session.device.runtimeName)
        }
        session.display.setChromeVisible(preferences.showsDeviceBezels)
        bezelChanged()
        orientationRead = .notStarted
        initialPlacement = nil
        fitting.setScale(scale)
        displayGeometryChanged()
        if present { showAndActivate() } else { readInitialOrientation() }
        // A window that stayed key gets no new key notification.
        if presentationWindow?.isKeyWindow == true { activateDisplay(focusingInput: restoreInputFocus) }
    }

    func showAndActivate() {
        if !isEmbedded { showWindow(nil) }
        presentationWindow?.makeKeyAndOrderFront(nil)
        readInitialOrientation()
    }

    /// Reads orientation once per connection and updates untouched initial placement.
    /// Devices without rotation keep their upright display.
    private func readInitialOrientation() {
        guard session.capabilities.rotates else {
            initialPlacement = nil
            return
        }
        // A reading in progress keeps the placement for its result.
        guard orientationRead == .notStarted else { return }
        let session = self.session
        guard session.canPerformToolOperation else { return }
        orientationRead = .pending
        session.run({ [weak self] in
            guard let self, self.session === session else { return }
            defer {
                if self.session === session {
                    self.orientationRead = .finished
                    self.initialPlacement = nil
                }
            }
            try await session.readOrientation()
            guard self.session === session else { return }
            if !self.isEmbedded, let placement = self.initialPlacement, self.window?.frame == placement.frame {
                self.placeAtInitialScale(placement.place)
            } else {
                self.displayGeometryChanged()
            }
        }, failure: { [weak self] in
            guard let self, self.session === session else { return }
            self.initialPlacement = nil
            hostLog($0.localizedDescription)
        })
    }

    // MARK: Commands

    @objc func saveScreenshot(_ sender: Any?) { perform(.saveScreen) }
    @objc func recordScreen(_ sender: Any?) { perform(.recordScreen) }
    @objc func recordScreenTo(_ sender: Any?) { perform(.recordScreenAs) }
    @objc func stopScreenRecording(_ sender: Any?) { perform(.stopRecording) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let command: DeviceCommand.ID?
        switch item.action {
        case #selector(saveScreenshot(_:)): command = .saveScreen
        case #selector(recordScreen(_:)): command = .recordScreen
        case #selector(recordScreenTo(_:)): command = .recordScreenAs
        case #selector(stopScreenRecording(_:)): command = .stopRecording
        case #selector(showInMainWindow(_:)): return canShowInMainWindow
        default: return !closed && session.canPerformCommands
        }
        guard let command, !closed else { return false }
        let description = DeviceCommand.command(command)
        return description.isSupported(session.capabilities) && description.isEnabled(self)
    }

    func perform(_ id: DeviceCommand.ID) {
        let command = DeviceCommand.command(id)
        guard !closed, command.isSupported(session.capabilities), command.isEnabled(self) else { return }
        command.perform(self)
        if let externalDisplayWindow, externalDisplayWindow.isKey {
            externalDisplayWindow.focusInput()
        } else {
            focusInput()
        }
    }

    func send(_ input: HardwareInput) { session.send(input) { [weak self] in self?.present($0) } }

    /// Runs an immediate device action and presents its failure on this window.
    func run(_ action: () throws -> Void) {
        do { try action() } catch { present(error) }
    }

    /// Debug ▸ Open System Log…. Opening Console is not a device operation, so
    /// it does not take the device-operation slot.
    func openSystemLog() {
        Task { [weak self, session] in
            do { try await session.openSystemLog() } catch { self?.present(error) }
        }
    }

    func rotate(left: Bool) {
        session.run({ [weak self] in
            guard let self else { return }
            try await self.session.rotate(left: left)
            self.displayGeometryChanged()
        }, failure: { [weak self] in self?.present($0) })
    }

    func setOrientation(_ orientation: DeviceOrientation) {
        session.run({ [weak self] in
            guard let self else { return }
            try await self.session.setOrientation(orientation)
            self.displayGeometryChanged()
        }, failure: { [weak self] in self?.present($0) })
    }

    func shutDown() {
        if let onShutDown { onShutDown(self); return }
        session.run({ [session] in try await session.shutDown() }, failure: { [weak self] in self?.present($0) })
    }

    func restart() { onRestart(self, false) }

    func eraseAllContentAndSettings() {
        guard let window = presentationWindow, session.reserve() else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Erase all content and settings on \(session.device.name)?"
        alert.informativeText = "The device restarts, and all of its apps, data, and settings are removed."
        alert.addButton(withTitle: "Erase")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.session.release()
            guard response == .alertFirstButtonReturn, !self.closed else { return }
            self.onRestart(self, true)
        }
    }

    /// Changes the bezel while preserving display scale.
    func setDeviceBezelVisible(_ visible: Bool) {
        session.display.setChromeVisible(visible)
        bezelChanged()
        if isEmbedded { updateEmbeddedScale() }
        else if session.display.usesNativeCanvas { resizeDisplay() }
        else { updateWindowSize() }
    }

    /// Applies bezel padding, background, header shape, and resize behavior.
    /// Full-screen windows stay resizable until they leave full screen.
    private func bezelChanged() {
        guard let window = window as? DeviceWindow else { return }
        let padding = session.display.chromePadding
        // Scrolling controls a crown or dial; without a bezel, SimulatorKit filters unsupported devices.
        session.display.setSupportsScrolling(padding == nil || session.capabilities.hasCrownOrDial)
        // With a bezel, guest edge gestures must start on it.
        session.display.setWantsEdgeSwipes(padding != nil)
        content.displayGap = isEmbedded ? 0 : WindowScale.displayGap(bezelPadding: padding)
        window.chromeTopPadding = padding?.height ?? 0
        updateHeaderShape()
        if session.display.usesNativeCanvas { window.backgroundColor = .windowBackgroundColor }
        else if padding != nil { window.backgroundColor = .clear }
        else if !isFullScreen { window.backgroundColor = .black }
        updateContentMinimumSize()
        guard !isFullScreen else { return }
        if padding == nil { window.styleMask.insert(.resizable) } else { window.styleMask.remove(.resizable) }
    }

    /// Lays out the toolbar immediately so size calculations use its final header height.
    private func updateToolbarStyle(forWidth width: CGFloat) {
        guard let window, let deviceToolbar else { return }
        let titles = deviceWindowTitles(name: session.device.name, runtimeName: session.device.runtimeName)
        deviceToolbar.apply(deviceToolbar.style(forWidth: width, title: titles.title, subtitle: titles.subtitle,
                                                preferences: preferences), to: window)
        window.layoutIfNeeded()
        titleBarHeights[window.toolbarStyle] = content.headerHeight
        updateContentMinimumSize()
        updateHeaderShape()
    }

    private func updateContentMinimumSize() {
        guard let window else { return }
        guard let geometry = session.appResizeGeometry else {
            window.contentMinSize = NSSize(width: 320, height: 300)
            return
        }
        var minimum = NSSize(width: geometry.minimumSize.width,
                             height: geometry.minimumSize.height + content.heightAboveDisplay)
        // Oversized guest minima remain reachable through the canvas viewport.
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            let maximum = window.contentRect(forFrameRect: visible).size
            minimum.width = min(minimum.width, maximum.width)
            minimum.height = min(minimum.height, maximum.height)
        }
        window.contentMinSize = minimum
    }

    /// Rounds the header below a visible bezel outside full screen.
    private func updateHeaderShape() {
        (window as? DeviceWindow)?.roundHeader(session.display.chromePadding != nil && !isFullScreen)
    }

    func toggleStayOnTop() {
        window?.level = staysOnTop ? .normal : .floating
        customLocation?.window?.level = window?.level ?? .normal
    }

    // MARK: Keyboard and touch pressure

    func toggleKeyboardCapture() {
        let keyboard = activeKeyboardInput
        if keyboard.capture.stop() { return }
        keyboard.focus()
        do { try keyboard.capture.start() } catch { present(error) }
    }

    /// Updates host keyboard input immediately; applies the saved choice to the guest asynchronously.
    func toggleHardwareKeyboard() {
        Task.immediate { [weak self, session] in
            do { try await session.toggleHardwareKeyboard() } catch { self?.present(error) }
        }
        updateKeyboardInput()
        externalDisplayWindow?.updateKeyboardInput()
    }

    /// The key window receives keyboard input only when the device's hardware keyboard is connected.
    private func updateKeyboardInput() {
        keyboard.setEnabled(isKey && session.connectsHardwareKeyboard)
    }

    /// Starts changes before returning to preserve input-source order. Failures are logged.
    private func keyboardSelectionChanged() {
        guard !closed, isKey || externalDisplayWindow?.isKey == true else { return }
        Task.immediate { [session] in
            do { try await session.syncKeyboardLanguage() } catch {
                hostLog("Could not set the keyboard language of \(session.device.name): \(error.localizedDescription)")
            }
        }
    }

    /// Applies the app's current touch mode and trackpad-force setting on each connection.
    private func connectTouchPressure() {
        let display = session.display
        display.setSupportsTouchPressure(
            display.displayClass == 0 && session.capabilities.supportsFeature(DeviceCapabilities.touchPressure))
        applyTouchPressure()
    }

    private func touchPressureChanged() {
        guard !closed, session.capabilities.supportsFeature(DeviceCapabilities.touchPressure) else { return }
        applyTouchPressure()
    }

    private func applyTouchPressure() {
        session.display.setUsesTrackpadForce(touchPressure.usesTrackpadForce)
        session.display.setSimulatedTouchMode(touchPressure.mode)
    }

    /// Applies indicator preferences on connection and whenever they change.
    private func showTouchIndicators() {
        for indicator in TouchIndicator.allCases {
            session.display.setTouchIndicator(indicator, shown: preferences.showsTouchIndicator(indicator))
        }
    }

    /// Features ▸ Location: Custom Location… asks for a coordinate first.
    func selectLocation(_ selection: LocationSelection) {
        guard !closed, session.canPerformCommands else { return }
        guard selection == .custom else {
            changeLocation { [session] in try await session.selectLocation(selection) }
            focusInput()
            return
        }
        let customLocation = customLocation ?? CustomLocationWindowController { [weak self] latitude, longitude in
            guard let self else { return }
            changeLocation { [session] in try await session.setCustomLocation(latitude: latitude, longitude: longitude) }
        }
        self.customLocation = customLocation
        // The window takes its device window's level, also when Stay on Top
        // changes, so that the device window cannot hide it.
        customLocation.window?.level = window?.level ?? .normal
        let defaults = HostPreferences.defaults
        do {
            let coordinate = try DeviceLocationPreset.load(for: session.device.identity.preferenceIdentifier, among: session.locationScenarios)?.coordinate
            customLocation.show(latitude: coordinate?.latitude ?? defaults.double(forKey: HostPreferences.locationLatitude),
                                longitude: coordinate?.longitude ?? defaults.double(forKey: HostPreferences.locationLongitude))
        } catch { present(error) }
    }

    /// I/O ▸ Audio Input or Audio Output: saves `route` as the app's most
    /// recent route for `scope`, which every device window then applies.
    func selectAudioRoute(_ route: String, in scope: AudioScope) {
        guard !closed else { return }
        preferences.chooseAudioRoute(route, in: scope)
        focusInput()
    }

    /// Routes the device to the app's new choice, presenting a failure on this window.
    private func audioRouteChosen(in scope: AudioScope) {
        guard !closed else { return }
        session.applyChosenAudioRoute(in: scope) { [weak self] in self?.present($0) }
    }

    /// Starts a location change before returning, so that changes reach the
    /// device in the order they are chosen, and presents its failure on this window.
    private func changeLocation(_ change: @escaping @MainActor () async throws -> Void) {
        Task.immediate { [weak self] in
            do { try await change() } catch { self?.present(error) }
        }
    }

    /// Whether captures apply the device's mask by default: the device has
    /// one and `ScreenShotUseMask` is on.
    private var usesDeviceMask: Bool {
        !session.isResizingApp && session.capabilities.hasFramebufferMask && HostPreferences.defaults.bool(forKey: HostPreferences.screenShotUseMask)
    }

    /// File ▸ Save Screen: captures the screen without asking and shows its
    /// thumbnail, which saves it to the screenshot folder when dismissed.
    func saveScreen() {
        let name = CaptureFile.screenshotName(device: session.device.name, date: Date())
        let folder = CaptureFile.screenshotFolder()
        let mask: DeviceTools.ScreenMask = usesDeviceMask ? .alpha : .ignored
        session.run({ [weak self, session] in
            let file = try await session.screenshot(mask: mask)
            let capture = CapturedContent(.screenshot, file: file, name: name, defaultFolder: folder)
            guard let self else {
                try capture.saveToDefaultLocation()
                return
            }
            try self.showThumbnail(of: capture, image: NSImage(contentsOf: file))
        }, failure: { [weak self] in self?.present($0) })
    }

    /// Shows a capture's thumbnail beside this window, or saves the capture
    /// when the window has closed.
    private func showThumbnail(of capture: CapturedContent, image: NSImage?) throws {
        guard !closed, let window = presentationWindow, window.isVisible, !CaptureThumbnail.savesImmediately else {
            try capture.saveToDefaultLocation()
            return
        }
        let display = session.display.view, screen = session.display.inputView
        // The thumbnail shrinks from the device screen, without the bezel.
        let source = window.convertToScreen(screen.convert(screen.bounds, to: nil))
        let displayFrame = window.convertToScreen(display.convert(display.bounds, to: nil))
        // Thumbnail spacing follows scale, doubling for landscape, TV, and watch displays.
        let scale = session.display.renderScale
        let landscape = abs(session.displayAngle.truncatingRemainder(dividingBy: 180)) == 90
        let family = session.capabilities.family
        let base: CGFloat = landscape || family == .tv || family == .watch ? 20 : 10
        let horizontal = window.styleMask.contains(.fullScreen) ? displayFrame.maxX - source.maxX + 10 : 10
        let thumbnail = CaptureThumbnail(capture, image: image, parent: window, source: source,
                                         rotation: session.isResizingApp ? 0 : session.displayAngle,
                                         cornerRadius: (session.appResizeGeometry?.cornerRadius ?? CGFloat(session.capabilities.screenCornerRadius)) * scale,
                                         spacing: NSSize(width: horizontal, height: ceil(scale * base))) { [weak self] error in
            if let self, !self.closed { self.present(error) } else { CaptureThumbnail.reportDetached(error) }
        }
        thumbnail.show()
    }

    /// File ▸ Save Screen…: asks where to save, starting in the screenshot
    /// folder, and whether to apply the device's mask. Saving remembers both.
    func chooseScreenshotDestination() {
        guard let window = presentationWindow, session.reserve() else { return }
        let hasMask = session.capabilities.hasFramebufferMask
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.directoryURL = CaptureFile.screenshotFolder()
        panel.nameFieldStringValue = CaptureFile.screenshotName(device: session.device.name, date: Date())
        let applyMask = NSButton(checkboxWithTitle: "Apply device mask to screenshot", target: nil, action: nil)
        applyMask.toolTip = "Apply device mask to non-rectangular screens when taking screenshots."
        applyMask.state = HostPreferences.defaults.bool(forKey: HostPreferences.screenShotUseMask) ? .on : .off
        if hasMask { panel.accessoryView = Self.accessory(applyMask) }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.session.release()
            guard response == .OK, let destination = panel.url, !self.closed else { return }
            let useMask = hasMask && applyMask.state == .on
            HostPreferences.defaults.set(destination.deletingLastPathComponent().path,
                                      forKey: HostPreferences.screenShotSaveLocation)
            if hasMask { HostPreferences.defaults.set(useMask, forKey: HostPreferences.screenShotUseMask) }
            self.session.run({ [session] in try await session.saveScreenshot(to: destination, mask: useMask ? .alpha : .ignored) },
                             failure: { [weak self] in self?.present($0) })
        }
    }

    /// Edit ▸ Copy Screen: puts a PNG of the screen on the Mac pasteboard,
    /// leaving the simulator's pasteboard alone.
    func copyScreen() {
        session.run({ [session] in
            let png = try await session.screenPNG()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(png, forType: .png)
        }, failure: { [weak self] in self?.present($0) })
    }

    /// Edit ▸ Get Pasteboard or Send Pasteboard. A failure that the device
    /// reports later is also presented on this window.
    func transferPasteboard(_ transfer: PasteboardTransfer) {
        session.transferPasteboard(transfer) { [weak self] in self?.present($0) }
    }

    /// Records immediately; stopping creates a thumbnail that saves on dismissal.
    func recordScreen() {
        guard let desktop = CaptureFile.desktop else {
            present(HostError.operation("Could not find the Desktop folder to save the recording in."))
            return
        }
        let device = session.device.name
        let isReserved = session.isRecordingDestination
        run {
            try session.startRecording(to: .capture { [weak self] file in
                let capture = CapturedContent(.movie, file: file, name: CaptureFile.recordingName(device: device, date: Date()),
                                              defaultFolder: desktop, isReserved: isReserved)
                if let self { try self.showThumbnail(of: capture, image: nil) } else { try capture.saveToDefaultLocation() }
            }, mask: usesDeviceMask ? .black : .ignored)
        }
    }

    /// File ▸ Record Screen…: asks where to save the movie and whether to
    /// apply the device's mask, then starts recording.
    func chooseRecordingDestination() {
        guard let window = presentationWindow, session.reserve() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = CaptureFile.recordingName(device: session.device.name, date: Date())
        // This option defaults on and is not persisted.
        let applyMask = NSButton(checkboxWithTitle: "Apply device mask to recording", target: nil, action: nil)
        applyMask.state = .on
        panel.accessoryView = Self.accessory(applyMask)
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.session.release()
            guard response == .OK, let destination = panel.url, !self.closed else { return }
            self.run { try self.session.startRecording(to: .file(destination), mask: applyMask.state == .on ? .black : .ignored) }
        }
    }

    private static func accessory(_ option: NSButton) -> NSView {
        let view = NSView()
        option.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(option)
        NSLayoutConstraint.activate([
            option.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            option.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
            option.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            option.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
        ])
        return view
    }

    func chooseFilesToImport() {
        guard let window = presentationWindow, session.reserve() else { return }
        let panel = NSOpenPanel()
        panel.title = "Install App or Import Media"
        panel.prompt = "Import"
        panel.allowedContentTypes = [.applicationBundle, .image, .movie, .vCard]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.session.release()
            if response == .OK, !self.closed { self.importFiles(panel.urls) }
        }
    }

    private func importFiles(_ urls: [URL]) {
        session.run({ [session] in try await session.importFiles(urls) }, failure: { [weak self] in self?.present($0) })
    }

    func chooseURLToOpen() {
        guard let window = presentationWindow, session.reserve() else { return }
        let alert = NSAlert()
        alert.messageText = "Open URL in Simulator"
        alert.informativeText = "Enter a web address or an app's URL scheme."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        field.placeholderString = "https://example.com"
        alert.accessoryView = field
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.session.release()
            guard response == .alertFirstButtonReturn, !self.closed else { return }
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: text), url.scheme != nil else {
                self.present(HostError.operation("Enter a URL with a scheme, such as https://example.com"))
                return
            }
            self.session.run({ [session] in try await session.openURL(url) }, failure: { [weak self] in self?.present($0) })
        }
    }

    // MARK: External display

    /// I/O ▸ External Displays. A failure, also one that CoreSimulator
    /// reports later, is presented on this window.
    func chooseExternalDisplay(_ mode: ExternalDisplayMode) {
        guard !closed else { return }
        session.chooseExternalDisplay(mode) { [weak self] in self?.present($0) }
    }

    /// The window that the Window menu's scale commands scale: the external
    /// display's window while it is key, otherwise this one.
    var scaledWindow: any DisplayScaling {
        guard let externalDisplayWindow, externalDisplayWindow.isKey else { return self }
        return externalDisplayWindow
    }

    /// Follows actual external-display power and size, including changes from other tools.
    private func syncExternalDisplayWindow() {
        guard !closed else { return }
        guard let state = session.externalScreen, state.isPoweredOn else { return closeExternalDisplayWindow() }
        if let externalDisplayWindow { return externalDisplayWindow.screenChanged(state) }
        do {
            let controller = try ExternalDisplayWindowController(
                session: session, display: session.makeExternalDisplay(), state: state, deviceWindow: self,
                preferences: preferences, keyboardCaptureTap: makeKeyboardCaptureTap(),
                applicationIsActive: applicationIsActive, makeWindow: makeExternalDisplayWindow) { [weak self] in
                    self?.externalDisplayWindowClosed()
                }
            controller.keyboard.capture.failure = { [weak self] in self?.present($0) }
            externalDisplayWindow = controller
            controller.showNewWindow(cascadingFrom: window)
        } catch {
            present(HostError.operation(
                "Could not show the external display of \(session.device.name): \(error.localizedDescription)"))
        }
    }

    private func closeExternalDisplayWindow() {
        externalDisplayWindow?.invalidate()
        externalDisplayWindow = nil
    }

    /// Closing selects Disabled. A failed power-off reopens the window.
    private func externalDisplayWindowClosed() {
        externalDisplayWindow = nil
        session.chooseExternalDisplay(.disabled) { [weak self] error in
            self?.present(error)
            self?.syncExternalDisplayWindow()
        }
    }

    // MARK: Presentation

    // Only orientation changes resize the window; other properties preserve its frame.
    private func displayPropertiesChanged() {
        guard !closed else { return }
        if session.display.usesNativeCanvas { displayGeometryChanged(); return }
        if session.isResizingApp { appGeometryChanged(); return }
        session.followBacklight()
        let enabled = HostPreferences.defaults.bool(forKey: HostPreferences.rotateWindowWhenSignaledByGuest)
        guard session.followGuestInterfaceOrientation(enabled: enabled) else { return }
        // A guest rotation before the first orientation reading does not
        // count as a change to the new window's placement.
        let untouched = initialPlacement.map { window?.frame == $0.frame } ?? false
        displayGeometryChanged()
        if untouched, let frame = window?.frame { initialPlacement?.frame = frame }
    }

    /// Native compositions fit their existing viewport as readiness and posture change.
    /// Legacy displays preserve scale and the window's top edge during rotation.
    private func displayGeometryChanged(placing place: ((NSWindow) -> Void)? = nil) {
        if isEmbedded { updateEmbeddedScale(); return }
        guard !closed, let window else { return }
        if session.display.usesNativeCanvas || fitting.fitsWindow {
            resizeDisplay()
            place?(window)
            return
        }
        let previous = window.frame
        updateWindowSize()
        if let place {
            place(window)
        } else {
            let height = window.frame.height
            var y = previous.maxY - height
            if let visible = window.screen?.visibleFrame, visible.maxY < height + y { y -= height + y - visible.maxY }
            window.setFrameOrigin(NSPoint(x: previous.minX.rounded(.toNearestOrEven), y: y.rounded(.toNearestOrEven)))
        }
        moveWindowOntoScreen()
    }

    // MARK: Window scale

    private var canvasFitScale: CGFloat { session.display.scale(for: content.availableDisplaySize) }

    private var canvasScaleRange: ClosedRange<CGFloat> {
        min(canvasZoom.fitScale, minimumScale)...max(canvasZoom.fitScale, 4)
    }

    func canPerformCanvasZoom(_ action: CanvasZoom.Action) -> Bool {
        guard isEmbedded, fitting.scalesDisplay, session.canPerformCommands else { return false }
        switch action {
        case .fit: return true
        case .physicalSize: return session.display.displayClass == 0
        case .zoomOut: return canvasZoom.scale > canvasScaleRange.lowerBound + 0.001
        case .zoomIn: return canvasZoom.scale < canvasScaleRange.upperBound - 0.001
        }
    }

    func canvasZoomIsSelected(_ action: CanvasZoom.Action) -> Bool {
        switch (action, canvasZoom.mode) {
        case (.fit, .fit), (.physicalSize, .physicalSize): true
        default: false
        }
    }

    func performCanvasZoom(_ action: CanvasZoom.Action) {
        guard canPerformCanvasZoom(action) else { return }
        switch action {
        case .fit:
            canvasZoom.mode = .fit
            content.centerCanvas()
        case .physicalSize: canvasZoom.mode = .physicalSize
        case .zoomOut:
            canvasZoom.mode = .fixed(max(canvasScaleRange.lowerBound, session.display.renderScale / 1.25))
        case .zoomIn:
            canvasZoom.mode = .fixed(min(canvasScaleRange.upperBound, session.display.renderScale * 1.25))
        }
        updateEmbeddedScale()
    }

    private func updateEmbeddedScale(layout: Bool = true) {
        guard isEmbedded, !closed else { return }
        canvasZoom.fitScale = canvasFitScale
        switch canvasZoom.mode {
        case .fit: fitting.resize(to: content.availableDisplaySize)
        case .physicalSize:
            if let scale = scale(for: .physicalSize) { fitting.setScale(scale) }
        case .fixed(let scale): fitting.setScale(scale)
        }
        canvasZoom.scale = session.display.renderScale
        content.needsLayout = true
        if layout, !content.isLayingOutCanvas { content.layoutSubtreeIfNeeded() }
    }

    /// Returns nil for Fit Screen when no host screen is available.
    func scale(for mode: WindowScaleMode) -> CGFloat? {
        let screen = presentationWindow?.screen
        switch mode {
        case .physicalSize:
            return WindowScale.physicalSize(hostDensity: screen.flatMap(WindowScale.density(of:)),
                                            deviceDensity: session.capabilities.screenPointsPerInch.map { CGFloat($0) })
        case .pointAccurate:
            return 1
        case .pixelAccurate:
            return WindowScale.pixelAccurate(screenScale: session.display.screenScale,
                                             backingScaleFactor: screen?.backingScaleFactor)
        case .fitScreen:
            if isEmbedded { return canvasFitScale }
            // The window keeps 10 points from each edge of the screen.
            guard let space = displaySpace(on: screen ?? NSScreen.main) else { return nil }
            return session.display.scale(for: NSSize(width: space.width - 20, height: space.height - 20))
        }
    }

    /// Available display space below the header and display gap.
    private func displaySpace(on screen: NSScreen?) -> NSSize? {
        guard let visible = screen?.visibleFrame else { return nil }
        return NSSize(width: visible.width, height: visible.height - content.heightAboveDisplay)
    }

    /// Minimum scale for fixed scaling and bezel resizing.
    private var minimumScale: CGFloat {
        WindowScale.minimum(family: session.capabilities.family, displayClass: session.display.displayClass,
                            fitting240: session.display.scale(for: NSSize(width: 240, height: 240)))
    }

    /// Checks prerequisites without changing unavailable commands' checkmarks.
    private func validatesScale(_ mode: WindowScaleMode) -> Bool {
        session.canPerformCommands && fitting.scalesDisplay && (isEmbedded || !isFullScreen)
            && (mode != .physicalSize || session.display.displayClass == 0)
    }

    /// Checks minimum scale and screen fit; a window with a bezel may extend beyond the screen.
    func canSetScale(_ mode: WindowScaleMode) -> Bool {
        guard validatesScale(mode), let window else { return false }
        if isEmbedded { return true }
        guard mode != .fitScreen else { return true }
        guard let scale = scale(for: mode), scale >= minimumScale else { return false }
        guard session.display.chromePadding == nil, let visible = window.screen?.visibleFrame else { return true }
        let size = session.display.size(for: scale)
        return size.width <= visible.width && size.height <= visible.height - titleBarHeight(forDisplayWidth: size.width)
    }

    /// Measures the title bar at the requested width, since scaling may change toolbar style.
    private func titleBarHeight(forDisplayWidth width: CGFloat) -> CGFloat {
        guard let deviceToolbar else { return content.headerHeight }
        let titles = deviceWindowTitles(name: session.device.name, runtimeName: session.device.runtimeName)
        let style = deviceToolbar.style(forWidth: width, title: titles.title, subtitle: titles.subtitle,
                                        preferences: preferences)
        return titleBarHeights[style] ?? content.headerHeight
    }

    /// Checks actual scale even when the command is unavailable.
    /// Returns nil when prerequisite validation requires preserving the previous checkmark.
    func scaleState(_ mode: WindowScaleMode) -> NSControl.StateValue? {
        guard validatesScale(mode), let scale = scale(for: mode) else { return nil }
        return WindowScale.matches(session.display.renderScale, scale) ? .on : .off
    }

    /// Resizes below the top edge. Fit Screen centers; fixed scales keep the window on screen.
    func setScale(_ mode: WindowScaleMode) {
        if isEmbedded {
            guard canSetScale(mode), let scale = scale(for: mode) else { return }
            switch mode {
            case .fitScreen: performCanvasZoom(.fit)
            case .physicalSize: performCanvasZoom(.physicalSize)
            case .pointAccurate, .pixelAccurate:
                canvasZoom.mode = .fixed(scale)
                updateEmbeddedScale()
            }
            return
        }
        guard let window, let scale = scale(for: mode) else { return }
        let previous = window.frame
        if mode == .fitScreen {
            showDisplay(fitting: { self.scale(for: .fitScreen) })
        } else {
            showDisplay(at: scale)
        }
        window.setFrameOrigin(NSPoint(x: previous.minX, y: previous.maxY - window.frame.height))
        guard mode == .fitScreen else {
            moveWindowOntoScreen()
            return
        }
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let frame = window.frame
        window.setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2))
    }

    /// Moves overflowing window edges inside the visible screen outside full screen.
    private func moveWindowOntoScreen() {
        guard let window, !window.styleMask.contains(.fullScreen),
              let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let origin = WindowScale.origin(of: window.frame, within: visible)
        if origin != window.frame.origin { window.setFrameOrigin(origin) }
    }

    /// Shows the display at `scale` and sizes the window to it.
    private func showDisplay(at scale: CGFloat) {
        guard !closed else { return }
        fitting.setScale(scale)
        updateWindowSize()
    }

    /// Sizes the window to the scaled display, gap, and final toolbar height.
    /// Keeps its bottom-left origin unless supplied and rounds outward to an integral frame.
    /// Full screen and live resize fit the display into the window instead.
    private func updateWindowSize(origin: NSPoint? = nil) {
        guard !closed, let window, !fitting.fitsWindow else {
            resizeDisplay()
            return
        }
        let size = session.display.size(for: session.display.renderScale)
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame
        let width = fitting.scalesDisplay ? size.width : min(size.width, visible?.width ?? size.width)
        updateToolbarStyle(forWidth: width)
        var sized = window.frameRect(forContentRect: NSRect(x: 0, y: 0,
            width: size.width, height: size.height + content.heightAboveDisplay))
        if !fitting.scalesDisplay, let visible {
            sized.size.width = min(sized.width, visible.width)
            sized.size.height = min(sized.height, visible.height)
        }
        content.isSizedToDisplay = true
        setFrame(around: NSRect(origin: origin ?? window.frame.origin, size: sized.size))
        fitting.layout()
    }

    /// Rounds the frame outward and constrains its top edge.
    private func setFrame(around frame: NSRect) {
        guard let window else { return }
        var frame = NSIntegralRect(frame)
        if let visible = window.screen?.visibleFrame, visible.maxY < frame.maxY {
            frame.origin.y = visible.maxY - frame.height
        }
        isSizingWindow = true
        window.setFrame(frame, display: true)
        isSizingWindow = false
    }

    // MARK: Bezel dragging

    /// Routes unhandled presses to bezel resizing or window dragging.
    private func handleBezelDrag(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown: return beginBezelResize(with: event) || moveWindow(with: event)
        case .leftMouseDragged where bezelResize != nil: continueBezelResize(with: event)
        case .leftMouseUp where bezelResize != nil: endBezelResize()
        default: return false
        }
        return true
    }

    /// Drags outside the bezel corners when enabled. SimulatorKit forwards bezel presses
    /// while retaining screen input; AppKit may also forward presses outside the display.
    private func moveWindow(with event: NSEvent) -> Bool {
        guard !closed, !isFullScreen, preferences.movesWindowByDraggingBezel, let window else { return false }
        performWindowDrag(window, event)
        return true
    }

    /// Begins a corner drag outside full screen, bounded by the visible screen.
    private func beginBezelResize(with event: NSEvent) -> Bool {
        guard !closed, !isFullScreen, fitting.scalesDisplay, let window else { return false }
        let display = session.display
        let point = display.view.convert(event.locationInWindow, from: nil)
        guard let corner = display.resizeRects.first(where: { $0.rect.contains(point) })?.corner else { return false }
        let drag = BezelResize(corner: corner,
                               start: NSRect(origin: window.frame.origin,
                                             size: NSSize(width: window.frame.width, height: display.view.frame.height)),
                               pointer: Self.screenLocation(of: event, in: window))
        let maximumScale = (window.screen ?? NSScreen.main).map {
            display.scale(for: drag.largestSize(within: $0.visibleFrame))
        } ?? 1000
        bezelResize = (drag, maximumScale)
        display.beginResize()
        return true
    }

    /// Scales between the device minimum and drag maximum, keeping the opposite corner fixed.
    private func continueBezelResize(with event: NSEvent) {
        guard let resize = bezelResize, let window else { return }
        let display = session.display
        let requested = resize.drag.requestedSize(pointerAt: Self.screenLocation(of: event, in: window))
        fitting.setScale(min(resize.maximumScale, max(minimumScale, display.scale(for: requested))))
        updateWindowSize(origin: resize.drag.origin(for: display.size(for: display.renderScale)))
    }

    /// After the drag, keep the window within reach of the screen.
    private func endBezelResize() {
        bezelResize = nil
        session.display.endResize()
        guard let window, !window.styleMask.contains(.fullScreen),
              let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let origin = WindowScale.origin(of: window.frame, reaching: visible)
        if origin != window.frame.origin { window.setFrameOrigin(origin) }
    }

    /// Uses the event's screen coordinates; window-local coordinates can become stale during dragging.
    private static func screenLocation(of event: NSEvent, in window: NSWindow) -> NSPoint {
        event.cgEvent?.unflippedLocation ?? window.convertPoint(toScreen: event.locationInWindow)
    }

    private func showResizeCursors() {
        session.display.setShowsResizeCursors(!isFullScreen)
        window?.invalidateCursorRects(for: session.display.view)
    }

    private func resizeDisplay() {
        guard !closed else { return }
        if session.isResizingApp { session.resizeApp(to: content.availableDisplaySize) }
        fitting.fit()
    }

    func focusInput() {
        guard session.canPerformCommands, presentationWindow != nil else { return }
        if !keyboard.focus() { hostLog("Could not focus simulator input for \(session.device.id)") }
    }

    func present(_ error: Error) {
        guard !closed, let window = presentationWindow else { return }
        let alert = NSAlert(error: error)
        alert.beginSheetModal(for: window)
    }

    func windowDidBecomeKey(_ notification: Notification) { activateDisplay() }

    private func activateDisplay(focusingInput: Bool = true) {
        guard !closed else { return }
        isKey = true
        updateKeyboardInput()
        if focusingInput { focusInput() }
    }
    func windowDidResignKey(_ notification: Notification) {
        guard !closed else { return }
        isKey = false
        updateKeyboardInput()
    }
    func windowWillStartLiveResize(_ notification: Notification) { if !closed { fitting.willStartLiveResize() } }
    /// A manual resize updates toolbar style while preserving content height, then fits the display.
    func windowDidResize(_ notification: Notification) {
        guard !isSizingWindow else { return }
        if !closed, !isFullScreen, let window {
            let below = window.frame.height - content.headerHeight
            updateToolbarStyle(forWidth: window.frame.width)
            let height = below + content.headerHeight
            if height != window.frame.height {
                setFrame(around: NSRect(origin: window.frame.origin, size: NSSize(width: window.frame.width, height: height)))
            }
        }
        resizeDisplay()
    }
    // AppKit requires resizability to fill the screen during its full-screen transition.
    func windowWillEnterFullScreen(_ notification: Notification) {
        saveWindowGeometry()
        fitting.willEnterFullScreen()
        showResizeCursors()
        updateHeaderShape()
        window?.styleMask.insert(.resizable)
    }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        fitting.didFailToEnterFullScreen()
        showResizeCursors()
        updateHeaderShape()
        bezelChanged()
    }
    /// Restores scale and origin explicitly; AppKit loses the origin of windows taller than the screen.
    func windowDidExitFullScreen(_ notification: Notification) {
        let geometry = fitting.didExitFullScreen(defaultScale: session.primaryDisplay.renderScale)
        showResizeCursors()
        updateHeaderShape()
        bezelChanged()
        guard let geometry else { return }
        if session.isResizingApp {
            session.primaryDisplay.setRenderScale(geometry.scale)
            resizeDisplay()
        }
        else { showDisplay(at: geometry.scale) }
        window?.setFrameOrigin(geometry.origin)
        // The screen the window was on may be gone, and the screen changes
        // that happened meanwhile did not move it.
        moveWindowOntoScreen()
    }
    func windowDidEndLiveResize(_ notification: Notification) {
        if !closed { fitting.didEndLiveResize() }
    }
    /// File ▸ Close Window…: asks whether to shut the device down, and closes
    /// the window unless the choice is Cancel.
    func closeAsking() {
        guard let window, window.attachedSheet == nil, !closed else { return }
        let alert = DeviceLifetimeChoice.alert(
            quitting: false, keepsRunningByDefault: HostPreferences.defaults.bool(forKey: HostPreferences.detachOnWindowClose))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, let choice = DeviceLifetimeChoice.choice(
                for: response, of: alert, rememberingAs: HostPreferences.detachOnWindowClose) else { return }
            self.closeChoice = choice
            self.window?.close()
        }
    }

    // Control-close asks which device lifetime to use.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard NSEvent.modifierFlags.contains(.control) else { return true }
        closeAsking()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard !closed else { return }
        saveWindowGeometry()
        disconnect()
        onClose(self, closeChoice)
    }
    func invalidate() {
        saveWindowGeometry()
        disconnect()
        window?.delegate = nil
        window?.close()
    }
    /// Saves the primary device's compact geometry per screen arrangement.
    private func saveWindowGeometry() {
        guard !closed, !isRestarting, !isEmbedded, !session.isResizingApp, hasPresentedCompactWindow,
              let window, window.contentView === content else { return }
        savedScale = WindowScale.usable(session.display.renderScale)
        preferences.setWindowGeometry(center: NSPoint(x: window.frame.midX, y: window.frame.midY),
                                      scale: savedScale,
                                      forDevice: session.device.identity.preferenceIdentifier, screens: Self.screenFrames)
    }
    private func disconnect() {
        guard !closed else { return }
        closed = true
        if let window = presentationWindow, let sheet = window.attachedSheet {
            window.endSheet(sheet, returnCode: .cancel)
        }
        pluginLookUp?.cancel()
        pluginLookUp = nil
        keyboard.invalidate()
        for observer in presentationObservers { NotificationCenter.default.removeObserver(observer) }
        presentationObservers.removeAll()
        content.removeFromSuperview()
        embeddedContainer = nil
        presentationViewController.removeFromParent()
        embeddedParent = nil
        if Self.embeddedController === self { Self.embeddedController = nil }
        fitting.invalidate()
        for observer in [screenParametersObserver, touchPressureObserver, touchIndicatorObserver,
                         keyboardSelectionObserver, audioRouteObserver].compactMap(\.self) {
            NotificationCenter.default.removeObserver(observer)
        }
        screenParametersObserver = nil
        touchPressureObserver = nil
        touchIndicatorObserver = nil
        keyboardSelectionObserver = nil
        audioRouteObserver = nil
        customLocation?.close()
        closeExternalDisplayWindow()
        session.disconnect()
    }
    /// An unshown controller discarded during a host conflict disconnects without saving geometry.
    isolated deinit { disconnect() }
}

@MainActor
private final class SimulatorPresentationViewController: NSViewController {
    private weak var owner: DeviceWindowController?
    init(owner: DeviceWindowController) {
        self.owner = owner
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    override func supplementalTarget(forAction action: Selector, sender: Any?) -> Any? {
        if let owner, owner.responds(to: action) { return owner }
        return super.supplementalTarget(forAction: action, sender: sender)
    }
}

/// Allows bezel padding beyond the screen and handles unconsumed bezel drags.
@MainActor
final class DeviceWindow: NSWindow {
    /// The top padding of the display's bezel at scale 1,
    /// `SimDeviceChrome.images.padding.height`; 0 without a bezel.
    var chromeTopPadding: CGFloat = 0
    /// The display's scale, which the padding scales with.
    var displayScale: () -> CGFloat = { 1 }
    /// Handles mouse events left unconsumed by the window's views.
    var handleMouseEvent: (NSEvent) -> Bool = { _ in false }

    override func mouseDown(with event: NSEvent) {
        if !handleMouseEvent(event) { super.mouseDown(with: event) }
    }

    override func mouseDragged(with event: NSEvent) {
        if !handleMouseEvent(event) { super.mouseDragged(with: event) }
    }

    override func mouseUp(with event: NSEvent) {
        if !handleMouseEvent(event) { super.mouseUp(with: event) }
    }

    /// Allows top bezel padding beyond the screen; otherwise uses AppKit's frame constraint.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        guard let target = screen ?? self.screen, chromeTopPadding > 0 else {
            return super.constrainFrameRect(frameRect, to: screen)
        }
        return WindowScale.frame(frameRect, constrainedBelow: target.visibleFrame,
                                 topInset: chromeTopPadding * displayScale())
    }

    /// Uses private `NSWindow._cornerRadius`, falling back to macOS 26 style radii.
    private var cornerRadius: CGFloat {
        let selector = NSSelectorFromString("_cornerRadius")
        if responds(to: selector) {
            typealias Getter = @convention(c) (NSWindow, Selector) -> CGFloat
            return unsafe unsafeBitCast(method(for: selector), to: Getter.self)(self, selector)
        }
        switch toolbarStyle {
        case .unified: return 26
        case .unifiedCompact: return 20
        default: return 16
        }
    }

    /// Finds the close button's title-bar ancestor; nil when full screen moves it to another window.
    private var titlebarContainer: NSView? {
        guard let frameView = contentView?.superview else { return nil }
        var view: NSView? = standardWindowButton(.closeButton)
        while let current = view, current.superview !== frameView { view = current.superview }
        return view
    }

    /// Matches the header's lower corners to the window or makes them square.
    func roundHeader(_ rounded: Bool) {
        guard let layer = titlebarContainer?.layer else { return }
        guard rounded else {
            layer.cornerRadius = 0
            return
        }
        layer.cornerRadius = cornerRadius
        layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        layer.masksToBounds = true
    }
}

@MainActor
private final class DeviceContentView: NSView, DisplayContentView {
    private(set) var display: NSView
    private var usesNativeCanvas: Bool
    func setDisplay(_ display: NSView, usesNativeCanvas: Bool) {
        self.usesNativeCanvas = usesNativeCanvas
        self.display.removeFromSuperview()
        self.display = display
        previousDisplaySize = nil
        if usesViewport { canvasDocumentView.addSubview(display) } else { addSubview(display) }
        needsLayout = true
    }
    private let canvasScrollView = NSScrollView()
    private let canvasDocumentView = NSView()
    private var canvasDisplayFrame = NSRect.zero
    private var retainedCanvasCenter: NSPoint?
    private var scrollMonitor: Any?
    private(set) var isLayingOutCanvas = false
    var canImport: () -> Bool = { false }
    var importFiles: ([URL]) -> Void = { _ in }
    var isEmbedded = false { didSet { if isEmbedded != oldValue { updateViewport() } } }
    var scrollsDisplay = false { didSet { if scrollsDisplay != oldValue { updateViewport() } } }
    private var usesViewport: Bool { isEmbedded || scrollsDisplay }
    private func updateViewport() {
        retainedCanvasCenter = canvasCenter
        let parent = usesViewport ? canvasDocumentView : self
        if display.superview !== parent {
            display.removeFromSuperview()
            parent.addSubview(display)
        }
        canvasScrollView.isHidden = !usesViewport
        updateScrollMonitor()
        needsLayout = true
    }
    var onDisplaySizeChange: () -> Void = {}
    var onWindowChange: () -> Void = {}
    private var previousDisplaySize: NSSize?
    /// The space between the header and the display, which follows the bezel.
    var displayGap = WindowScale.displayGap(bezelPadding: nil) {
        didSet { needsLayout = true }
    }
    /// Fills integral-frame rounding gaps when sized to the display.
    /// Otherwise centers the display at its own size, including after manual resizing.
    var isSizedToDisplay = false {
        didSet { needsLayout = true }
    }
    /// The title bar's height, which follows the toolbar's style: 52 points
    /// unified, 76 expanded, and 40 compact on macOS 26.
    var headerHeight: CGFloat {
        if isEmbedded { return 0 }
        guard let window else { return 52 }
        return max(0, bounds.height - window.contentLayoutRect.height)
    }
    /// The window's height above the display: the header and the gap below it.
    var heightAboveDisplay: CGFloat { headerHeight + displayGap }
    init(display: NSView, usesNativeCanvas: Bool) {
        self.usesNativeCanvas = usesNativeCanvas
        self.display = display
        super.init(frame: .zero)
        wantsLayer = true
        canvasScrollView.drawsBackground = false
        canvasScrollView.contentView.drawsBackground = false
        canvasScrollView.hasHorizontalScroller = true
        canvasScrollView.hasVerticalScroller = true
        canvasScrollView.autohidesScrollers = true
        canvasScrollView.scrollerStyle = .overlay
        canvasScrollView.horizontalScrollElasticity = .none
        canvasScrollView.verticalScrollElasticity = .none
        canvasScrollView.usesPredominantAxisScrolling = false
        canvasScrollView.automaticallyAdjustsContentInsets = false
        canvasScrollView.documentView = canvasDocumentView
        canvasScrollView.isHidden = true
        canvasScrollView.toolTip = "Use the scroll bars or Option-scroll to pan the device."
        addSubview(canvasScrollView)
        addSubview(display)
        registerForDraggedTypes([.fileURL])
    }
    isolated deinit {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateScrollMonitor()
        onWindowChange()
    }
    private func updateScrollMonitor() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        guard usesViewport, window != nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.modifierFlags.contains(.option), let window = self.window,
                  event.window === window, self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
            self.canvasScrollView.scrollWheel(with: event)
            return nil
        }
    }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        canImport() ? .copy : []
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard canImport(), let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
        importFiles(urls)
        return true
    }
    required init?(coder: NSCoder) { nil }

    var availableDisplaySize: NSSize {
        NSSize(width: max(1, bounds.width), height: max(1, bounds.height - heightAboveDisplay))
    }

    private var canvasCenter: NSPoint? {
        guard canvasDisplayFrame.width > 0, canvasDisplayFrame.height > 0 else { return nil }
        let visible = canvasScrollView.contentView.bounds
        return NSPoint(x: (visible.midX - canvasDisplayFrame.minX) / canvasDisplayFrame.width,
                       y: (visible.midY - canvasDisplayFrame.minY) / canvasDisplayFrame.height)
    }

    func centerCanvas() {
        retainedCanvasCenter = NSPoint(x: 0.5, y: 0.5)
        needsLayout = true
    }

    override func layout() {
        guard !isLayingOutCanvas else { return }
        isLayingOutCanvas = true
        defer { isLayingOutCanvas = false }
        super.layout()
        if previousDisplaySize != availableDisplaySize {
            previousDisplaySize = availableDisplaySize
            onDisplaySizeChange()
        }
        let available = NSRect(origin: .zero, size: availableDisplaySize)
        if usesViewport {
            let center = retainedCanvasCenter ?? canvasCenter ?? NSPoint(x: 0.5, y: 0.5)
            retainedCanvasCenter = nil
            canvasScrollView.frame = available
            let intrinsic = display.intrinsicContentSize
            let size = intrinsic.width > 0 && intrinsic.height > 0 ? intrinsic : display.frame.size
            let viewport = canvasScrollView.contentSize
            let documentSize = NSSize(width: max(viewport.width, size.width), height: max(viewport.height, size.height))
            canvasDocumentView.setFrameSize(documentSize)
            canvasDisplayFrame = NSRect(x: (documentSize.width - size.width) / 2,
                                       y: (documentSize.height - size.height) / 2,
                                       width: size.width, height: size.height)
            display.frame = canvasDisplayFrame
            let clip = canvasScrollView.contentView
            let proposed = NSRect(x: canvasDisplayFrame.minX + size.width * center.x - clip.bounds.width / 2,
                                  y: canvasDisplayFrame.minY + size.height * center.y - clip.bounds.height / 2,
                                  width: clip.bounds.width, height: clip.bounds.height)
            clip.scroll(to: clip.constrainBoundsRect(proposed).origin)
            canvasScrollView.reflectScrolledClipView(clip)
            return
        }
        if isSizedToDisplay || usesNativeCanvas {
            display.frame = available
        } else {
            let intrinsic = display.intrinsicContentSize
            let size = intrinsic.width > 0 && intrinsic.height > 0 ? intrinsic : display.frame.size
            display.frame = NSRect(x: available.midX - size.width / 2, y: available.midY - size.height / 2,
                                   width: size.width, height: size.height)
        }
    }
}

enum CaptureFile {
    /// Screenshot filename in local time.
    static func screenshotName(device: String, date: Date) -> String {
        name("Simulator Screenshot", device: device, date: date, extension: "png")
    }

    /// Recording filename in local time.
    static func recordingName(device: String, date: Date) -> String {
        name("Simulator Screen Recording", device: device, date: date, extension: "mov")
    }

    // `:` and `/` become `.`, so a date reads `2026-10-21 at 23.17.05`.
    private static func name(_ kind: String, device: String, date: Date, extension suffix: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH:mm:ss"
        return "\(kind) - \(device) - \(formatter.string(from: date)).\(suffix)"
            .replacingOccurrences(of: ":", with: ".")
            .replacingOccurrences(of: "/", with: ".")
    }

    static var desktop: URL? { FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first }

    /// Uses an existing ScreenShotSaveLocation, then Desktop, then /private/tmp.
    static func screenshotFolder() -> URL {
        if let location = HostPreferences.defaults.string(forKey: HostPreferences.screenShotSaveLocation) {
            let path = NSString(string: location).expandingTildeInPath
            var isDirectory: ObjCBool = false
            if !path.isEmpty, FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        return desktop ?? URL(fileURLWithPath: "/private/tmp", isDirectory: true)
    }

    /// The first of `name`, "name #2" through "name #99" that is free in
    /// `folder` and not reserved.
    static func unusedFile(in folder: URL, named name: String, isReserved: (URL) -> Bool = { _ in false }) throws -> URL {
        let base = (name as NSString).deletingPathExtension, suffix = (name as NSString).pathExtension
        for number in 1...99 {
            let candidate = folder.appendingPathComponent(number == 1 ? name : "\(base) #\(number).\(suffix)")
            if !FileManager.default.fileExists(atPath: candidate.path), !isReserved(candidate) { return candidate }
        }
        throw HostError.operation("Could not save \(name): \(folder.path) already has files of that name through #99.")
    }

    /// Moves the capture without overwriting, trying suffixes #2 through #99.
    /// A failure preserves the original file and reports its location.
    static func move(_ capture: URL, into folder: URL, named name: String,
                     isReserved: (URL) -> Bool = { _ in false }) throws -> URL {
        let base = (name as NSString).deletingPathExtension, suffix = (name as NSString).pathExtension
        for number in 1...99 {
            let candidate = folder.appendingPathComponent(number == 1 ? name : "\(base) #\(number).\(suffix)")
            if isReserved(candidate) { continue }
            do {
                try FileManager.default.moveItem(at: capture, to: candidate)
                return candidate
            } catch CocoaError.fileWriteFileExists {
                continue
            } catch {
                throw HostError.operation("Could not save \(name) in \(folder.path): \(error.localizedDescription) The capture is at \(capture.path).")
            }
        }
        throw HostError.operation("Could not save \(name): \(folder.path) already has files of that name through #99. The capture is at \(capture.path).")
    }

    @MainActor
    static func write(to destination: URL, extension suffix: String,
                      produce: (URL) async throws -> Void) async throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".neo-simulator-\(UUID().uuidString).\(suffix)")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        close(descriptor)
        do {
            try await produce(temporary)
            try Task.checkCancellation()
            guard rename(temporary.path, destination.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            if FileManager.default.fileExists(atPath: temporary.path) {
                do { try FileManager.default.removeItem(at: temporary) }
                catch let cleanup {
                    throw HostError.operation("\(error.localizedDescription) Temporary file remains at \(temporary.path): \(cleanup.localizedDescription)")
                }
            }
            throw error
        }
    }
}

/// Device lifetime selected when closing a window or quitting.
enum DeviceLifetimeChoice: Equatable {
    case shutDown, keepRunning

    /// Return chooses the default action.
    static func alert(quitting: Bool, keepsRunningByDefault: Bool) -> NSAlert {
        let alert = NSAlert()
        if quitting {
            alert.messageText = "Do you want to shut down the simulated devices?"
            alert.informativeText = "You may choose to shut down all running simulated devices or keep them running."
            alert.alertStyle = .informational
        } else {
            alert.messageText = "Do you want to shutdown the simulated device?"
            alert.informativeText = "When closing a window, you can either shut down the device or keep it running."
        }
        alert.addButton(withTitle: quitting ? "Shut Down" : "Shut down")
        alert.addButton(withTitle: "Keep Running")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title =
            quitting ? "Remember as the default quit action." : "Remember as the default close action."
        if keepsRunningByDefault {
            alert.buttons[0].keyEquivalent = ""
            alert.buttons[1].keyEquivalent = "\r"
        }
        return alert
    }

    /// The choice an alert response names, saved as the default under `key`
    /// when the suppression box is checked. Cancel names none.
    static func choice(for response: NSApplication.ModalResponse, of alert: NSAlert,
                       rememberingAs key: String) -> Self? {
        let choice: Self
        switch response {
        case .alertFirstButtonReturn: choice = .shutDown
        case .alertSecondButtonReturn: choice = .keepRunning
        default: return nil
        }
        if alert.suppressionButton?.state == .on { HostPreferences.defaults.set(choice == .keepRunning, forKey: key) }
        return choice
    }
}
