import AppKit

/// The Mac's keyboard for the simulator display of a device window or of an
/// external display's window, which both windows share. As Simulator.app's
/// keyboard controller gives it, the display takes the keyboard while its
/// window is key and the device's hardware keyboard is connected. The guest's
/// modifier keys follow the Mac's when the display gains the keyboard or the
/// focus, and are released before it loses the keyboard. AppKit never
/// dispatches key-ups while Command is held, so the window's are forwarded to
/// the display.
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

    /// Makes the display's input the window's first responder and gives it
    /// the modifiers the Mac holds now, whose changes it missed while another
    /// window had the focus; the digitizer also uses them, with or without
    /// the keyboard. Returns false when the window keeps another responder.
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

    /// Releases the guest's modifier keys before the display stops taking the
    /// Mac's keyboard, as Simulator.app's `clearModifiers()` does when its
    /// window resigns key. SimulatorKit takes the release from the event the
    /// app sends, which AppKit passes to the app's key window; while the app
    /// deactivates, that is still this window. Like Simulator.app's, the
    /// digitizer does not see the release, which would stop a gesture in
    /// progress from following the pointer and keep its touches down after
    /// the button comes up.
    private func releaseModifiers() {
        let input = display.inputView
        let movesFocus = window?.firstResponder === input && window?.makeFirstResponder(nil) == true
        Self.sendModifiers([])
        if movesFocus { window?.makeFirstResponder(input) }
    }

    /// SimulatorKit applies modifier changes to every display with keyboard
    /// input and releases them only on displays that keep it. They are synced
    /// when a display gains keyboard input and released before it loses it.
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
    /// Whether the window has the display's size. Otherwise, as in full
    /// screen, during a live resize, and after a manual resize, the display
    /// keeps its own size, centered.
    var isSizedToDisplay: Bool { get set }
    /// The space the content leaves for the display.
    var availableDisplaySize: NSSize { get }
}

/// The simulator display of a device window or of an external display's
/// window fitting the window's content, which both windows share. The
/// display fits the content in full screen and during a live resize, where
/// the window does not take the display's size, and after a manual resize.
/// SimulatorKit's display takes a new size of its screen, such as an external
/// display's new resolution, a moment after CoreSimulator reports it, by
/// setting its view to that size at its scale; in full screen and during a
/// live resize, the display then fits the content again.
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
    /// The display's scale and the window's origin when the window entered
    /// full screen, which Simulator.app restores when the window leaves it.
    private var geometryBeforeFullScreen: (scale: CGFloat, origin: NSPoint)?

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
        display.resize(to: content.availableDisplaySize)
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
        display.beginResize()
    }

    func didEndLiveResize() {
        isLiveResizing = false
        fit()
        display.endResize()
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
        if fitsWindow { fit() }
    }
}
