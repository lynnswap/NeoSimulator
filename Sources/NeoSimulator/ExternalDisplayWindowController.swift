import AppKit

/// The window of a device's external display while the display is on, as
/// Simulator.app's device window shows a TVOut screen: titled with the device
/// and "External Display", without a toolbar or a bezel, black around the
/// display, and opened where it last closed, under the device's
/// `ExternalWindowGeometry`. While the window is key, the Window menu's scale
/// commands scale it. Its display takes the pointer as touches and, while the
/// window is key and the device's hardware keyboard is connected, the Mac's
/// keyboard.
///
/// Closing the window turns the external display off, as Disabled does.
@MainActor
final class ExternalDisplayWindowController: NSWindowController, NSWindowDelegate, DisplayScaling {
    /// The subtitle's label, which Simulator.app shows where a device window
    /// shows the runtime.
    static let subtitle = "External Display"

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
    /// The screen's size in points. Without a bezel, the display's size at a
    /// scale is this size times the scale. SimulatorKit's display takes a new
    /// size of its screen a moment after CoreSimulator reports it, so the
    /// window follows the reported size.
    private var screenSize: NSSize
    /// Whether the window is key, while the display can take the Mac's keyboard.
    private(set) var isKey = false
    private let keyboard: DisplayKeyboardInput
    private let fitting: DisplayFitting
    private var observers: [any NSObjectProtocol] = []

    /// - Parameter state: The external display's state, which gives its size.
    init(session: DeviceSession, display: any SimulatorDisplay, state: ExternalScreenState,
         deviceWindow: DeviceWindowController?, preferences: any PreferenceStore = UserDefaults.standard,
         onClose: @escaping () -> Void) throws {
        self.session = session
        self.display = display
        self.deviceWindow = deviceWindow
        self.preferences = preferences
        self.onClose = onClose
        let saved = preferences.windowGeometry(forDevice: session.device.id, screens: Self.screenFrames,
                                               kind: .externalDisplay)
        savedCenter = saved.center
        savedScale = saved.scale
        content = ExternalDisplayContentView(display: display.view)
        screenSize = Self.points(of: state) ?? .zero
        guard screenSize.width > 0, screenSize.height > 0 else {
            display.disconnect()
            throw HostError.unavailable("The external display has no usable size")
        }
        // Like Simulator.app's window for a display without a bezel: titled,
        // with the content below the title bar, and resizable.
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: screenSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        keyboard = DisplayKeyboardInput(window: window, display: display)
        fitting = DisplayFitting(display: display, content: content)
        super.init(window: window)
        (window.title, window.subtitle) = deviceWindowTitles(name: session.device.name, runtimeName: Self.subtitle)
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarSeparatorStyle = .none
        window.tabbingMode = .disallowed
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary, .fullScreenAllowsTiling]
        window.delegate = self
        window.contentView = content
        // Like Simulator.app, every window follows Show Device Bezels;
        // SimulatorKit has no bezel for an external display.
        display.setChromeVisible(preferences.showsDeviceBezels)
        // Simulator.app takes touch pressure only on a device's own screen.
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

    /// Like Simulator.app, a new window opens at the saved scale or Point
    /// Accurate, reduced to Fit Screen's.
    private var initialScale: CGFloat { min(scale(for: .fitScreen) ?? .infinity, savedScale ?? 1) }

    private static var screenFrames: [NSRect] { NSScreen.screens.map(\.frame) }

    /// Shows the window centered where the device's external display window
    /// last closed in the current arrangement of screens, or else cascading
    /// from the device window, and makes it key, as Simulator.app does for a
    /// window that connects. The window then moves back inside its screen.
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
        // The window opened at the scale for the main screen; as the device
        // window does, it takes the scale for the screen it is placed on and
        // is placed again at its new size.
        display.setRenderScale(initialScale)
        updateWindowSize()
        place(window)
        moveWindowOntoScreen()
    }

    /// Closes the window without turning the external display off, as when
    /// the display turns off or its device disconnects. The window's geometry
    /// is saved for its next opening.
    func invalidate() {
        guard !closed else { return }
        saveWindowGeometry()
        disconnect()
        window?.delegate = nil
        window?.close()
    }

    // MARK: Window size

    /// The scale `mode` shows the display at, as Simulator.app computes it,
    /// or nil for Fit Screen without a screen.
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
                                         height: visible.height - titleBarHeight - ExternalDisplayContentView.gap - 20))
        }
    }

    /// The title bar's height, the window's frame less its content.
    private var titleBarHeight: CGFloat {
        guard let window else { return 0 }
        return window.frame.height - window.contentRect(forFrameRect: window.frame).height
    }

    /// The smallest scale Simulator.app gives a display that is not a
    /// device's own screen: the scale that fits it in 240 by 240 points.
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

    /// Like Simulator.app: a connected display outside full screen, and for
    /// Physical Size, a device's own screen, which an external display is not.
    private func validatesScale(_ mode: WindowScaleMode) -> Bool {
        !closed && display.isBooted && !fitting.isFullScreen && (mode != .physicalSize || display.displayClass == 0)
    }

    /// Whether a scale command can run, as Simulator.app validates it for a
    /// display without a bezel: a fixed scale from the minimum, at which the
    /// display fits its screen's visible frame below the title bar.
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

    /// Shows the display at `mode`'s scale and sizes the window to it below
    /// its top edge. Fit Screen then centers the window on its screen; the
    /// fixed scales move it back inside its screen.
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
        display.setRenderScale(scale)
        updateWindowSize()
    }

    /// Sizes the window to the display at its scale, as Simulator.app's
    /// geometry update does for a display without a bezel: the content is the
    /// display below the gap, the window keeps its bottom-left corner, takes
    /// the smallest integral frame around that, and moves down when its top
    /// would be above the screen. A drag on the window's edges keeps the
    /// screen's aspect ratio and stops at the minimum scale. In full screen
    /// and during a live resize, the display fits the window instead.
    private func updateWindowSize() {
        guard !closed, let window, !fitting.fitsWindow else { return resizeDisplay() }
        let size = displaySize(at: display.renderScale)
        let sized = window.frameRect(forContentRect: NSRect(
            x: 0, y: 0, width: size.width, height: size.height + ExternalDisplayContentView.gap))
        var frame = NSIntegralRect(NSRect(origin: window.frame.origin, size: sized.size))
        if let visible = window.screen?.visibleFrame, visible.maxY < frame.maxY {
            frame.origin.y = visible.maxY - frame.height
        }
        window.contentAspectRatio = screenSize
        let minimum = displaySize(at: minimumScale)
        window.contentMinSize = NSSize(width: minimum.width, height: minimum.height + ExternalDisplayContentView.gap)
        content.isSizedToDisplay = true
        isSizingWindow = true
        window.setFrame(frame, display: true)
        isSizingWindow = false
        fitting.layout()
    }

    /// Like Simulator.app, the window takes the display's new size when the
    /// screen's size changes, keeping the display's scale.
    func screenChanged(_ state: ExternalScreenState) {
        guard !closed, let size = Self.points(of: state), size != screenSize else { return }
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

    /// Like Simulator.app, the window returns to the display's scale and the
    /// window's origin from before full screen.
    func windowDidExitFullScreen(_ notification: Notification) {
        guard let geometry = fitting.didExitFullScreen() else { return }
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

    /// Like Simulator.app, the device's next external display window in the
    /// same arrangement of screens opens at this center and scale.
    private func saveWindowGeometry() {
        guard !closed, let window else { return }
        preferences.setWindowGeometry(center: NSPoint(x: window.frame.midX, y: window.frame.midY),
                                      scale: WindowScale.usable(display.renderScale),
                                      forDevice: session.device.id, screens: Self.screenFrames, kind: .externalDisplay)
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

/// The external display's window content: the display below a gap, on the
/// window's black background.
@MainActor
private final class ExternalDisplayContentView: NSView, DisplayContentView {
    /// The space Simulator.app keeps between the title bar and a display
    /// without a bezel.
    static let gap = WindowScale.displayGap(bezelPadding: nil)

    let display: NSView
    /// Whether the window has the display's size; the display then fills the
    /// window below the gap. In full screen and after a manual resize, the
    /// display keeps its own size, centered below the gap.
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

    var availableDisplaySize: NSSize {
        NSSize(width: max(1, bounds.width), height: max(1, bounds.height - Self.gap))
    }

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
