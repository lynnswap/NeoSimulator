import AppKit

/// Presents a device's powered-on external screen without a bezel or toolbar.
/// Shares keyboard and scaling behavior with device windows, and saves separate geometry.
/// Closing the window powers off the external display.
@MainActor
final class ExternalDisplayWindowController: NSWindowController, NSWindowDelegate, DisplayScaling {
    /// Distinguishes CarPlay and guest-size mismatches in the subtitle.
    static func subtitle(isCarPlay: Bool, showsSize: Bool = true) -> String {
        isCarPlay ? "CarPlay" : showsSize ? "External Display" : "External Display – Size Not Shown by Device"
    }

    /// CarPlay accompanies another full-screen window instead of creating its own space.
    private static func collectionBehavior(isCarPlay: Bool) -> NSWindow.CollectionBehavior {
        isCarPlay ? [.fullScreenAuxiliary] : [.fullScreenPrimary, .fullScreenAllowsTiling]
    }

    let display: any SimulatorDisplay
    /// The device window, whose device the menus act on while this window is key.
    private(set) weak var deviceWindow: DeviceWindowController?
    private let session: DeviceSession
    private let preferences: any PreferenceStore
    private let onClose: () -> Void
    private let content: ExternalDisplayContentView
    /// Where the window last closed in the current arrangement of screens,
    /// and its display's scale then.
    private let savedCenter: NSPoint?
    private let savedScale: CGFloat?
    private var closed = false
    /// Set while the window takes the display's size, which the resize must not change.
    private var isSizingWindow = false
    /// Uses reported screen dimensions because SimulatorKit updates its display view asynchronously.
    private var screenSize: NSSize
    /// Whether the display is a CarPlay screen, which the subtitle names.
    private var isCarPlay: Bool
    /// Whether the guest shows the display's size, which the subtitle says when it does not.
    private var showsSize: Bool
    /// Whether the window is key, while the display can take the Mac's keyboard.
    private(set) var isKey = false
    let keyboard: DisplayKeyboardInput
    private let fitting: DisplayFitting
    private var observers: [any NSObjectProtocol] = []

    /// - Parameter state: The external display's state, which gives its size.
    init(session: DeviceSession, display: any SimulatorDisplay, state: ExternalScreenState,
         deviceWindow: DeviceWindowController?, preferences: any PreferenceStore = HostPreferences.defaults,
         keyboardCaptureTap: any KeyboardEventTap = SystemKeyboardEventTap(),
         applicationIsActive: @escaping () -> Bool = { NSApp.isActive },
         makeWindow: @MainActor (NSRect) -> NSWindow = ExternalDisplayWindowController.makeWindow,
         onClose: @escaping () -> Void) throws {
        self.session = session
        self.display = display
        self.deviceWindow = deviceWindow
        self.preferences = preferences
        self.onClose = onClose
        let saved = preferences.windowGeometry(forDevice: session.device.identity.preferenceIdentifier, screens: Self.screenFrames,
                                               kind: .externalDisplay)
        savedCenter = saved.center
        savedScale = saved.scale
        content = ExternalDisplayContentView(display: display.view)
        screenSize = Self.points(of: state) ?? .zero
        isCarPlay = state.isCarPlay
        showsSize = session.externalDisplayShowsItsSize(in: state)
        guard screenSize.width > 0, screenSize.height > 0 else {
            display.disconnect()
            throw HostError.unavailable("The external display has no usable size")
        }
        let window = makeWindow(NSRect(origin: .zero, size: screenSize))
        keyboard = DisplayKeyboardInput(window: window, display: display,
                                        captureTap: keyboardCaptureTap, applicationIsActive: applicationIsActive)
        fitting = DisplayFitting(display: display, content: content)
        super.init(window: window)
        (window.title, window.subtitle) = deviceWindowTitles(
            name: session.device.name, runtimeName: Self.subtitle(isCarPlay: isCarPlay, showsSize: showsSize))
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarSeparatorStyle = .none
        window.tabbingMode = .disallowed
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.collectionBehavior = Self.collectionBehavior(isCarPlay: isCarPlay)
        window.delegate = self
        window.contentView = content
        // External screens have no bezel even when the shared preference is on.
        display.setChromeVisible(preferences.showsDeviceBezels)
        // Touch pressure applies only to the device's own screen.
        display.setSupportsTouchPressure(false)
        showTouchIndicators()
        observers = [
            NotificationCenter.default.addObserver(
                forName: TouchIndicator.didChangeNotification, object: preferences, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.showTouchIndicators() }
            },
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.moveWindowOntoScreen() }
            },
        ]
        showDisplay(at: initialScale)
    }

    required init?(coder: NSCoder) { nil }

    static func makeWindow(_ frame: NSRect) -> NSWindow {
        NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                 backing: .buffered, defer: false)
    }

    /// Fits the saved scale, or Point Accurate for a new or CarPlay window, to the screen.
    private var initialScale: CGFloat { min(scale(for: .fitScreen) ?? .infinity, isCarPlay ? 1 : savedScale ?? 1) }

    private static var screenFrames: [NSRect] { NSScreen.screens.map(\.frame) }

    /// Restores the saved center or cascades from the device window, then keeps it on screen.
    func showNewWindow(cascadingFrom deviceWindow: NSWindow?) {
        guard let window else { return }
        let place: (NSWindow) -> Void
        if let center = savedCenter {
            place = { $0.setFrameOrigin(NSPoint(x: center.x - $0.frame.width / 2, y: center.y - $0.frame.height / 2)) }
        } else if let deviceWindow {
            let topLeft = window.cascadeTopLeft(from: NSPoint(x: deviceWindow.frame.minX, y: deviceWindow.frame.maxY))
            place = { _ = $0.cascadeTopLeft(from: topLeft) }
        } else {
            place = { $0.center() }
        }
        place(window)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        // Recompute fit for the destination screen after placement.
        fitting.setScale(initialScale)
        updateWindowSize()
        place(window)
        moveWindowOntoScreen()
    }

    /// Closes and saves geometry without sending a power-off request.
    func invalidate() {
        guard !closed else { return }
        saveWindowGeometry()
        disconnect()
        window?.delegate = nil
        window?.close()
    }

    // MARK: Window size

    /// Returns nil for Fit Screen when no host screen is available.
    func scale(for mode: WindowScaleMode) -> CGFloat? {
        let screen = window?.screen
        switch mode {
        case .physicalSize:
            return WindowScale.physicalSize(hostDensity: screen.flatMap(WindowScale.density(of:)),
                                            deviceDensity: session.capabilities.screenPointsPerInch.map { CGFloat($0) })
        case .pointAccurate:
            return 1
        case .pixelAccurate:
            return WindowScale.pixelAccurate(screenScale: display.screenScale, backingScaleFactor: screen?.backingScaleFactor)
        case .fitScreen:
            // The window keeps 10 points from each edge of the screen.
            guard let visible = (screen ?? NSScreen.main)?.visibleFrame else { return nil }
            return scale(fitting: NSSize(width: visible.width - 20,
                                         height: visible.height - titleBarHeight - 20))
        }
    }

    /// The title bar's height, the window's frame less its content.
    private var titleBarHeight: CGFloat {
        guard let window else { return 0 }
        return window.frame.height - window.contentRect(forFrameRect: window.frame).height
    }

    /// Minimum scale fits the display in 240×240 points.
    private var minimumScale: CGFloat {
        WindowScale.minimum(family: session.capabilities.family, displayClass: display.displayClass,
                            fitting240: scale(fitting: NSSize(width: 240, height: 240)))
    }

    /// The screen's size in points, its pixel size over its scale, or nil
    /// when either is unusable.
    private static func points(of state: ExternalScreenState) -> NSSize? {
        guard state.scale > 0, state.pixelSize.width > 0, state.pixelSize.height > 0 else { return nil }
        return NSSize(width: state.pixelSize.width / state.scale, height: state.pixelSize.height / state.scale)
    }

    /// The display's size at `scale`.
    private func displaySize(at scale: CGFloat) -> NSSize {
        NSSize(width: screenSize.width * scale, height: screenSize.height * scale)
    }

    /// The largest scale at which the display fits `size`.
    private func scale(fitting size: NSSize) -> CGFloat {
        min(size.width / screenSize.width, size.height / screenSize.height)
    }

    /// External displays support scaling only when connected and outside full screen; no Physical Size.
    private func validatesScale(_ mode: WindowScaleMode) -> Bool {
        !closed && display.isBooted && !fitting.isFullScreen && (mode != .physicalSize || display.displayClass == 0)
    }

    /// Checks minimum scale and fit below the title bar for a display without a bezel.
    func canSetScale(_ mode: WindowScaleMode) -> Bool {
        guard validatesScale(mode), let window else { return false }
        guard mode != .fitScreen else { return true }
        guard let scale = scale(for: mode), scale >= minimumScale else { return false }
        guard let visible = window.screen?.visibleFrame else { return true }
        let size = displaySize(at: scale)
        return size.width <= visible.width && size.height <= visible.height - titleBarHeight
    }

    func scaleState(_ mode: WindowScaleMode) -> NSControl.StateValue? {
        guard validatesScale(mode), let scale = scale(for: mode) else { return nil }
        return WindowScale.matches(display.renderScale, scale) ? .on : .off
    }

    /// Resizes below the top edge, centering Fit Screen and keeping fixed scales on screen.
    func setScale(_ mode: WindowScaleMode) {
        guard let window, let scale = scale(for: mode) else { return }
        let previous = window.frame
        showDisplay(at: scale)
        window.setFrameOrigin(NSPoint(x: previous.minX, y: previous.maxY - window.frame.height))
        guard mode == .fitScreen else { return moveWindowOntoScreen() }
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let frame = window.frame
        window.setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2))
    }

    private func showDisplay(at scale: CGFloat) {
        guard !closed else { return }
        fitting.setScale(scale)
        updateWindowSize()
    }

    /// Sizes to the scaled display and constrains the top edge.
    /// Manual resizing preserves aspect ratio and minimum scale; full screen and live resize fit the display.
    private func updateWindowSize() {
        guard !closed, let window else { return }
        if !fitting.isFullScreen {
            window.contentAspectRatio = screenSize
            window.contentMinSize = displaySize(at: minimumScale)
        }
        guard !fitting.fitsWindow else { return resizeDisplay() }
        let size = displaySize(at: display.renderScale)
        let sized = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        var frame = NSIntegralRect(NSRect(origin: window.frame.origin, size: sized.size))
        if let visible = window.screen?.visibleFrame, visible.maxY < frame.maxY {
            frame.origin.y = visible.maxY - frame.height
        }
        content.isSizedToDisplay = true
        isSizingWindow = true
        window.setFrame(frame, display: true)
        isSizingWindow = false
        fitting.layout()
    }

    /// Updates screen size and CarPlay state while preserving display scale.
    func screenChanged(_ state: ExternalScreenState) {
        guard !closed else { return }
        let showsSize = session.externalDisplayShowsItsSize(in: state)
        if state.isCarPlay != isCarPlay || showsSize != self.showsSize, let window {
            if state.isCarPlay != isCarPlay {
                window.collectionBehavior = Self.collectionBehavior(isCarPlay: state.isCarPlay)
            }
            isCarPlay = state.isCarPlay
            self.showsSize = showsSize
            (window.title, window.subtitle) = deviceWindowTitles(
                name: session.device.name, runtimeName: Self.subtitle(isCarPlay: isCarPlay, showsSize: showsSize))
        }
        guard let size = Self.points(of: state), size != screenSize else { return }
        screenSize = size
        updateWindowSize()
        moveWindowOntoScreen()
    }

    /// Moves the window inside its screen's visible frame along each axis
    /// where it crosses an edge, outside full screen.
    private func moveWindowOntoScreen() {
        guard !closed, let window, !window.styleMask.contains(.fullScreen),
              let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let origin = WindowScale.origin(of: window.frame, within: visible)
        if origin != window.frame.origin { window.setFrameOrigin(origin) }
    }

    private func resizeDisplay() {
        guard !closed else { return }
        fitting.fit()
    }

    // MARK: Input

    private func showTouchIndicators() {
        guard !closed else { return }
        for indicator in TouchIndicator.allCases {
            display.setTouchIndicator(indicator, shown: preferences.showsTouchIndicator(indicator))
        }
    }

    /// Gives the display the Mac's keyboard while the window is key and the
    /// device's hardware keyboard is connected, as the device window does.
    func updateKeyboardInput() {
        keyboard.setEnabled(!closed && isKey && session.connectsHardwareKeyboard)
    }

    func focusInput() {
        guard !closed, display.isBooted else { return }
        keyboard.focus()
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        guard !closed else { return }
        isKey = true
        updateKeyboardInput()
        focusInput()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !closed else { return }
        isKey = false
        updateKeyboardInput()
    }

    func windowWillStartLiveResize(_ notification: Notification) { if !closed { fitting.willStartLiveResize() } }
    func windowDidResize(_ notification: Notification) { if !isSizingWindow { resizeDisplay() } }
    func windowDidEndLiveResize(_ notification: Notification) { if !closed { fitting.didEndLiveResize() } }

    func windowWillEnterFullScreen(_ notification: Notification) { fitting.willEnterFullScreen() }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) { fitting.didFailToEnterFullScreen() }

    /// Restore the scale and origin from before full screen.
    func windowDidExitFullScreen(_ notification: Notification) {
        guard let geometry = fitting.didExitFullScreen(defaultScale: display.renderScale) else { return }
        showDisplay(at: geometry.scale)
        window?.setFrameOrigin(geometry.origin)
        moveWindowOntoScreen()
    }

    /// Closing the window turns the external display off.
    func windowWillClose(_ notification: Notification) {
        guard !closed else { return }
        saveWindowGeometry()
        disconnect()
        onClose()
    }

    /// Save center and scale for the current host-screen arrangement.
    private func saveWindowGeometry() {
        guard !closed, let window else { return }
        preferences.setWindowGeometry(center: NSPoint(x: window.frame.midX, y: window.frame.midY),
                                      scale: WindowScale.usable(display.renderScale),
                                      forDevice: session.device.identity.preferenceIdentifier, screens: Self.screenFrames, kind: .externalDisplay)
    }

    private func disconnect() {
        guard !closed else { return }
        closed = true
        keyboard.invalidate()
        fitting.invalidate()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        if let window, let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel) }
        display.disconnect()
    }

    isolated deinit { disconnect() }
}

/// External-screen content meets the title bar and uses the window's black background.
@MainActor
private final class ExternalDisplayContentView: NSView, DisplayContentView {
    let display: NSView
    /// Fills display-sized content; otherwise centers the display at its own size.
    var isSizedToDisplay = false {
        didSet { needsLayout = true }
    }

    init(display: NSView) {
        self.display = display
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(display)
    }

    required init?(coder: NSCoder) { nil }

    var availableDisplaySize: NSSize { NSSize(width: max(1, bounds.width), height: max(1, bounds.height)) }

    override func layout() {
        super.layout()
        let available = NSRect(origin: .zero, size: availableDisplaySize)
        if isSizedToDisplay {
            display.frame = available
        } else {
            let intrinsic = display.intrinsicContentSize
            let size = intrinsic.width > 0 && intrinsic.height > 0 ? intrinsic : display.frame.size
            display.frame = NSRect(x: available.midX - size.width / 2, y: available.midY - size.height / 2,
                                   width: size.width, height: size.height)
        }
    }
}
