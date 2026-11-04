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
        willSet { capture.stop() }
        didSet { isEnabled = false }
    }
    /// Whether the display takes the Mac's keyboard.
    private var isEnabled = false
    private var commandKeyUpMonitor: Any?
    private let captureTap: any KeyboardEventTap
    private let applicationIsActive: () -> Bool
    lazy var capture = KeyboardCapture(tap: captureTap, isEligible: { [weak self] in
        guard let self, self.isEnabled, self.display.isBooted, self.applicationIsActive(), let window = self.window,
              window.isKeyWindow, window.attachedSheet == nil else { return false }
        return window.firstResponder === self.display.inputView
    }, forward: { [weak self] event in
        guard let input = self?.display.inputView else { return }
        switch event.type {
        case .keyDown: input.keyDown(with: event)
        case .keyUp: input.keyUp(with: event)
        case .flagsChanged:
            // SimulatorKit processes keyboard modifiers in an application event monitor.
            NSApp.sendEvent(event)
        default: break
        }
    }, releaseModifiers: { [weak self] _ in self?.releaseModifiers() })

    init(window: NSWindow, display: any SimulatorDisplay, captureTap: any KeyboardEventTap = SystemKeyboardEventTap(),
         applicationIsActive: @escaping () -> Bool = { NSApp.isActive }) {
        self.window = window
        self.display = display
        self.captureTap = captureTap
        self.applicationIsActive = applicationIsActive
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
            if !capture.stop() { releaseModifiers() }
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
        capture.stop()
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
