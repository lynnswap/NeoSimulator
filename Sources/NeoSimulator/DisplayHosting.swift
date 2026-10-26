import AppKit

/// Shares host keyboard routing between primary and external display windows.
/// Only a key window with a connected hardware keyboard receives keys.
/// Modifier state is synchronized on focus changes; Command key-ups require explicit forwarding.
@MainActor
final class DisplayKeyboardInput {
    private weak var window: NSWindow?
    /// The window's display. A device window gets a new display when its
    /// device reconnects, which takes no keyboard until the window gives it.
    var display: any SimulatorDisplay {
        didSet { isEnabled = false }
    }
    /// Whether the display takes the Mac's keyboard.
    private var isEnabled = false
    private var commandKeyUpMonitor: Any?

    init(window: NSWindow, display: any SimulatorDisplay) {
        self.window = window
        self.display = display
        commandKeyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            guard let self, event.modifierFlags.contains(.command), let window = self.window,
                  event.window === window, window.firstResponder === self.display.inputView else { return event }
            self.display.inputView.keyUp(with: event)
            return nil
        }
    }

    isolated deinit { invalidate() }

    /// Transfers keyboard ownership together with the display's presentation.
    func attach(to window: NSWindow?) {
        guard self.window !== window else { return }
        setEnabled(false)
        self.window = window
    }

    /// Gives the display the Mac's keyboard with the modifiers held now, or
    /// takes the keyboard away after releasing the guest's modifiers.
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            display.setKeyboardEnabled(true)
            Self.sendModifiers(NSEvent.modifierFlags)
        } else {
            releaseModifiers()
            display.setKeyboardEnabled(false)
        }
    }

    /// Focuses the display and synchronizes held modifiers, including for digitizer gestures.
    /// Returns false if another responder retains focus.
    @discardableResult
    func focus() -> Bool {
        guard let window else { return false }
        let input = display.inputView
        window.makeFirstResponder(input)
        guard window.firstResponder === input else { return false }
        if let event = NSEvent.keyEvent(with: .flagsChanged, location: window.mouseLocationOutsideOfEventStream,
            modifierFlags: NSEvent.modifierFlags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "",
            charactersIgnoringModifiers: "", isARepeat: false, keyCode: 0) {
            input.flagsChanged(with: event)
        }
        return true
    }

    /// Stops forwarding the window's key-ups.
    func invalidate() {
        if let commandKeyUpMonitor { NSEvent.removeMonitor(commandKeyUpMonitor) }
        commandKeyUpMonitor = nil
    }

    /// Releases modifiers before keyboard ownership is lost.
    /// Do not send this release through the digitizer: it would interrupt an active gesture
    /// and could leave touches held after mouse-up.
    private func releaseModifiers() {
        let input = display.inputView
        let movesFocus = window?.firstResponder === input && window?.makeFirstResponder(nil) == true
        Self.sendModifiers([])
        if movesFocus { window?.makeFirstResponder(input) }
    }

    /// Synchronizes modifiers only for displays receiving keyboard input.
    static func sendModifiers(_ flags: NSEvent.ModifierFlags) {
        guard let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 0) else { return }
        NSApp.sendEvent(event)
    }
}

/// The content of a window that shows a simulator display: either the window
/// has the display's size, or the display fits the content.
@MainActor
protocol DisplayContentView: NSView {
    /// Fills a display-sized window; otherwise centers the display at its own size.
    var isSizedToDisplay: Bool { get set }
    /// The space the content leaves for the display.
    var availableDisplaySize: NSSize { get }
}

/// Fits a shared simulator display during full screen or manual resizing.
/// SimulatorKit applies new screen dimensions asynchronously, requiring another fit afterward.
@MainActor
final class DisplayFitting {
    private(set) var display: any SimulatorDisplay
    private var content: any DisplayContentView
    /// The display's size at scale 1 when its view last changed.
    private var size: NSSize
    private var observer: (any NSObjectProtocol)?
    /// Whether the window is in full screen or moving into or out of it.
    private(set) var isFullScreen = false
    /// Whether the window is between `windowWillStartLiveResize` and
    /// `windowDidEndLiveResize`.
    private var isLiveResizing = false
    /// App resize mode sends point geometry to the guest; its framebuffer keeps scale 1.
    var scalesDisplay = true
    /// The display's scale and the window's origin when the window entered
    /// full screen, which Simulator.app restores when the window leaves it.
    private var geometryBeforeFullScreen: (scale: CGFloat, origin: NSPoint)?
    /// An embedded presentation may preserve a fixed scale after a native size change.
    var onNaturalSizeChange: (() -> Void)?

    init(display: any SimulatorDisplay, content: any DisplayContentView) {
        self.display = display
        self.content = content
        size = display.size(for: 1)
        observe()
    }

    isolated deinit { invalidate() }

    /// Fits a device's next display, in new content, as after a restart.
    func attach(_ display: any SimulatorDisplay, content: any DisplayContentView) {
        invalidate()
        self.display = display
        self.content = content
        size = display.size(for: 1)
        observe()
    }

    /// Whether the display fits the window instead of the window taking the
    /// display's size.
    var fitsWindow: Bool { isFullScreen || isLiveResizing }

    /// Gives the display the largest scale at which it fits the content.
    func fit() {
        content.isSizedToDisplay = false
        if scalesDisplay { display.resize(to: content.availableDisplaySize) }
        layout()
    }

    /// Lays the display out in the content again.
    func layout() {
        content.needsLayout = true
        content.layoutSubtreeIfNeeded()
        content.window?.invalidateShadow()
    }

    func willStartLiveResize() {
        isLiveResizing = true
        if scalesDisplay { display.beginResize() }
    }

    func didEndLiveResize() {
        isLiveResizing = false
        fit()
        if scalesDisplay { display.endResize() }
    }

    func willEnterFullScreen() {
        isFullScreen = true
        guard let window = content.window else { return }
        geometryBeforeFullScreen = (display.renderScale, window.frame.origin)
    }

    func didFailToEnterFullScreen() {
        isFullScreen = false
        geometryBeforeFullScreen = nil
    }

    /// Leaves full screen, returning the display's scale and the window's
    /// origin from before it, which the window returns to.
    func didExitFullScreen() -> (scale: CGFloat, origin: NSPoint)? {
        isFullScreen = false
        defer { geometryBeforeFullScreen = nil }
        return geometryBeforeFullScreen
    }

    /// Stops following the display's size.
    func invalidate() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    private func observe() {
        display.view.postsFrameChangedNotifications = true
        observer = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: display.view, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.displayViewChanged() }
        }
    }

    private func displayViewChanged() {
        let size = display.size(for: 1)
        guard size != self.size else { return }
        self.size = size
        if fitsWindow { fit() } else { onNaturalSizeChange?() }
    }
}
