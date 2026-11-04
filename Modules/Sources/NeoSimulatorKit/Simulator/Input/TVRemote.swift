import AppKit

/// One app-wide, non-key Apple TV Remote panel. Targets the key or frontmost device window;
/// only Apple TV accepts its input. It hides while inactive and follows device-window changes.
@MainActor
final class TVRemoteController: NSWindowController, NSWindowDelegate {
    /// The device window whose device the remote controls now.
    private let target: @MainActor () -> DeviceWindowController?
    private let buttons: [TVRemoteButtonView]
    private let surface: TVRemoteTouchSurface
    /// Keeps a touch on its original target; the device session owns held-input cleanup.
    private weak var touchTarget: DeviceWindowController?
    /// Watches the modifier keys for the touch surface while the panel shows.
    private var optionMonitor: Any?
    /// Watch the app's windows becoming key and closing.
    private var windowObservers: [any NSObjectProtocol] = []

    /// Simulator-compatible frame autosave key.
    static let frameAutosaveName = "Apple TV Remote Window"

    /// Builds the 155×515-point remote layout with AppKit and SF Symbols.
    /// `target` selects the device window controlled by the remote.
    init(target: @escaping @MainActor () -> DeviceWindowController? = TVRemoteController.keyOrFrontmostDeviceWindow) {
        self.target = target
        let panel = TVRemotePanel(contentRect: NSRect(origin: .zero, size: TVRemoteLayout.size),
                                  styleMask: .borderless, backing: .buffered, defer: true)
        let body = TVRemoteBodyView(frame: NSRect(origin: .zero, size: TVRemoteLayout.size))
        // The hint lies below the surface, which takes the clicks over it.
        let hint = NSTextField(labelWithString: "Hold Option to touch")
        hint.font = .systemFont(ofSize: 13)
        hint.textColor = .white
        hint.alphaValue = 0.3
        hint.frame = TVRemoteLayout.hint
        body.addSubview(hint)
        surface = TVRemoteTouchSurface(frame: TVRemoteLayout.surface)
        body.addSubview(surface)
        buttons = TVRemoteLayout.buttons.map { button, frame, shape in
            let view = TVRemoteButtonView(button: button, shape: shape, frame: frame)
            body.addSubview(view)
            return view
        }
        panel.contentView = body
        super.init(window: panel)
        shouldCascadeWindows = false
        configure(panel)
        // External-display windows also determine the active remote target.
        windowObservers = [
            NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] notification in
                let window = notification.object as? NSWindow
                MainActor.assumeIsolated {
                    if let controller = DeviceWindowController.deviceWindow(for: window) {
                        self?.deviceWindowBecameKey(controller)
                    }
                }
            },
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] notification in
                let window = notification.object as? NSWindow
                MainActor.assumeIsolated {
                    if let controller = window?.windowController as? DeviceWindowController {
                        self?.deviceWindowWillClose(controller)
                    }
                }
            },
        ]
    }

    required init?(coder: NSCoder) { nil }

    isolated deinit {
        if let optionMonitor { NSEvent.removeMonitor(optionMonitor) }
        windowObservers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Finds the key device window, falling back to the frontmost.
    static func keyOrFrontmostDeviceWindow() -> DeviceWindowController? {
        DeviceWindowController.keyDeviceWindow
            ?? NSApp.orderedWindows.lazy.compactMap { $0.windowController as? DeviceWindowController }.first
    }

    /// Whether the panel shows, which Window ▸ Show Apple TV Remote's title follows.
    var isVisible: Bool { window?.isVisible == true }

    /// Window ▸ Show Apple TV Remote, or Hide Apple TV Remote while it shows.
    func toggle() {
        if isVisible { close() } else { showWindow(nil) }
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        // Forward app-wide modifier changes to the touch surface.
        if optionMonitor == nil {
            optionMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                self?.surface.optionChanged(isDown: event.modifierFlags.contains(.option))
                return event
            }
        }
    }

    /// Releases every device's remote inputs, including previously failed releases.
    func windowWillClose(_ notification: Notification) {
        if let optionMonitor { NSEvent.removeMonitor(optionMonitor) }
        optionMonitor = nil
        buttons.forEach { $0.reset() }
        surface.reset()
        touchTarget = nil
        Self.deviceSessions.forEach { $0.releaseRemoteInputs() }
    }

    /// The sessions of the device windows, which may hold the remote's
    /// buttons or touch.
    private static var deviceSessions: [DeviceSession] {
        NSApp.windows.compactMap { ($0.windowController as? DeviceWindowController)?.session }
    }

    /// Brings the panel forward for Apple TV and closes it for other devices.
    private func deviceWindowBecameKey(_ controller: DeviceWindowController) {
        guard isVisible else { return }
        if controller.session.capabilities.supportsFeature(DeviceCapabilities.tvRemote) {
            window?.orderFront(nil)
        } else {
            close()
        }
    }

    /// Closing the last Apple TV window closes the panel; otherwise the next key window decides.
    private func deviceWindowWillClose(_ controller: DeviceWindowController) {
        guard isVisible, controller.session.capabilities.supportsFeature(DeviceCapabilities.tvRemote) else { return }
        let othersRemain = NSApp.windows.contains { window in
            window !== controller.window && (window.isVisible || window.isMiniaturized)
                && window.windowController is DeviceWindowController
        }
        if !othersRemain { close() }
    }

    // MARK: Input

    /// A press goes to the device the remote controls; its release goes to
    /// every device, of which those that hold the button release it.
    private func setButton(_ button: TVRemoteButton, down: Bool) {
        if down {
            guard let controller = target() else { return }
            controller.session.pressRemoteButton(button) { [weak controller] in controller?.present($0) }
        } else {
            Self.deviceSessions.forEach { $0.releaseRemoteButton(button) }
        }
    }

    /// The surface's touch goes to the device the remote controls; one that
    /// had it before, until another device window became key, loses it.
    private func touch(at point: CGPoint) {
        let controller = target()
        if let touchTarget, touchTarget !== controller { touchTarget.session.liftRemoteTouch(at: point) }
        touchTarget = controller
        controller?.session.touchRemote(at: point) { [weak controller] in controller?.present($0) }
    }

    private func lift(at point: CGPoint) {
        touchTarget?.session.liftRemoteTouch(at: point)
    }

    // MARK: Panel

    /// Configures the panel, connects its controls, and restores geometry.
    private func configure(_ panel: NSPanel) {
        panel.title = "Apple TV Remote"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        surface.onSelect = { [weak self] in self?.setButton(.select, down: $0) }
        surface.onTouch = { [weak self] in self?.touch(at: $0) }
        surface.onLift = { [weak self] in self?.lift(at: $0) }
        for view in buttons {
            let button = view.button
            view.onChange = { [weak self] in self?.setButton(button, down: $0) }
        }
        // Default placement matches Simulator.app's nib on a 2560-point-wide screen.
        if !panel.setFrameUsingName(Self.frameAutosaveName), let screen = NSScreen.main?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: screen.maxX - 386 - TVRemoteLayout.size.width, y: screen.maxY))
        }
        panel.setFrameAutosaveName(Self.frameAutosaveName)
    }
}

/// A borderless panel that never takes keyboard focus.
private final class TVRemotePanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

/// Remote layout in panel coordinates, from the bottom-left corner.
private enum TVRemoteLayout {
    static let size = NSSize(width: 155, height: 515)
    static let surface = NSRect(x: 0, y: 354, width: 155, height: 161)
    static let hint = NSRect(x: 10, y: 475, width: 134, height: 17)
    /// Volume Up and Volume Down share a capsule.
    static let volume = NSRect(x: 85, y: 165, width: 55, height: 120)
    static let buttons: [(TVRemoteButton, NSRect, TVRemoteButtonView.Shape)] = [
        (.menu, NSRect(x: 19, y: 298, width: 55, height: 55), .circle),
        (.tv, NSRect(x: 85, y: 297, width: 55, height: 55), .circle),
        (.siri, NSRect(x: 19, y: 230, width: 55, height: 55), .circle),
        (.playPause, NSRect(x: 19, y: 165, width: 55, height: 55), .circle),
        (.volumeUp, NSRect(x: 85, y: 227, width: 55, height: 58), .upperHalf),
        (.volumeDown, NSRect(x: 85, y: 165, width: 55, height: 58), .lowerHalf),
    ]
    /// Scales the original two-point outline from 64-point artwork.
    static let lineWidth: CGFloat = 2 * 55 / 64
    static let outline = NSColor(white: 0.27, alpha: 0.9)
    static let pressed = NSColor(white: 1, alpha: 0.19)
    static let glyph = NSColor(white: 0.6, alpha: 1)
}

/// Draws the remote body and volume-button capsule.
private final class TVRemoteBodyView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let body = NSBezierPath(roundedRect: bounds, xRadius: 30, yRadius: 30)
        NSColor.black.setFill()
        body.fill()
        NSGraphicsContext.saveGraphicsState()
        body.addClip()
        NSColor(white: 0.09, alpha: 1).setFill()
        NSRect(x: bounds.minX, y: 290, width: bounds.width, height: bounds.maxY - 290).fill()
        NSGraphicsContext.restoreGraphicsState()
        let inset = TVRemoteLayout.lineWidth / 2
        let capsule = TVRemoteLayout.volume.insetBy(dx: inset, dy: inset)
        let outline = NSBezierPath(roundedRect: capsule, xRadius: capsule.width / 2, yRadius: capsule.width / 2)
        outline.lineWidth = TVRemoteLayout.lineWidth
        TVRemoteLayout.outline.setStroke()
        outline.stroke()
    }
}

/// Sends press on mouse-down and release on mouse-up, even outside the button.
private final class TVRemoteButtonView: NSView {
    enum Shape { case circle, upperHalf, lowerHalf }

    let button: TVRemoteButton
    private let shape: Shape
    private(set) var isPressed = false
    var onChange: (Bool) -> Void = { _ in }

    init(button: TVRemoteButton, shape: Shape, frame: NSRect) {
        self.button = button
        self.shape = shape
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
    }

    required init?(coder: NSCoder) { nil }

    private var label: String {
        switch button {
        case .select: "Select"
        case .menu: "Menu"
        case .tv: "TV"
        case .playPause: "Play/Pause"
        case .volumeUp: "Volume Up"
        case .volumeDown: "Volume Down"
        case .siri: "Siri"
        }
    }

    private var symbol: String? {
        switch button {
        case .tv: "tv"
        case .playPause: "playpause.fill"
        case .volumeUp: "plus"
        case .volumeDown: "minus"
        case .siri: "mic.fill"
        case .select, .menu: nil
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) { press() }
    override func mouseUp(with event: NSEvent) { release() }

    override func accessibilityPerformPress() -> Bool {
        press()
        release()
        return true
    }

    func press() { setPressed(true) }
    func release() { setPressed(false) }

    /// Shows the button up without releasing it, as the panel closes.
    func reset() {
        isPressed = false
        needsDisplay = true
    }

    private func setPressed(_ pressed: Bool) {
        guard pressed != isPressed else { return }
        isPressed = pressed
        needsDisplay = true
        onChange(pressed)
    }

    override func draw(_ dirtyRect: NSRect) {
        let inset = TVRemoteLayout.lineWidth / 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let path: NSBezierPath
        switch shape {
        case .circle: path = NSBezierPath(ovalIn: rect)
        case .upperHalf, .lowerHalf:
            // The half of the volume capsule, rounded at its end.
            let radius = rect.width / 2
            path = NSBezierPath()
            let upper = shape == .upperHalf
            let round = upper ? rect.maxY - radius : rect.minY + radius
            let flat = upper ? rect.minY : rect.maxY
            path.move(to: NSPoint(x: rect.minX, y: flat))
            path.line(to: NSPoint(x: rect.minX, y: round))
            path.appendArc(withCenter: NSPoint(x: rect.midX, y: round), radius: radius,
                           startAngle: 180, endAngle: 0, clockwise: !upper)
            path.line(to: NSPoint(x: rect.maxX, y: flat))
            path.close()
        }
        if isPressed {
            TVRemoteLayout.pressed.setFill()
            path.fill()
        }
        if shape == .circle {
            path.lineWidth = TVRemoteLayout.lineWidth
            TVRemoteLayout.outline.setStroke()
            path.stroke()
        }
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [TVRemoteLayout.glyph]))) {
            image.draw(in: NSRect(x: rect.midX - image.size.width / 2, y: rect.midY - image.size.height / 2,
                                  width: image.size.width, height: image.size.height))
        } else if button == .menu {
            let title = NSAttributedString(string: "MENU", attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .medium), .kern: 1, .foregroundColor: TVRemoteLayout.glyph,
            ])
            let size = title.size()
            title.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
        }
    }
}

/// Click presses Select; Option turns pointer motion into a touch.
/// Touches begin on entry/Option-down and end on exit/Option-up, with normalized coordinates.
final class TVRemoteTouchSurface: NSView {
    var onSelect: (Bool) -> Void = { _ in }
    var onTouch: (CGPoint) -> Void = { _ in }
    var onLift: (CGPoint) -> Void = { _ in }
    private var isPointerInside = false
    private var isSelectDown = false
    /// Last normalized point measured from the top-left corner.
    private(set) var point = CGPoint.zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp,
                                                             .inVisibleRect], owner: self, userInfo: nil))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Select")
    }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) { setSelect(true) }
    override func mouseUp(with event: NSEvent) { setSelect(false) }

    override func accessibilityPerformPress() -> Bool {
        setSelect(true)
        setSelect(false)
        return true
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        follow(event)
    }

    override func mouseMoved(with event: NSEvent) { follow(event) }

    /// Tracking areas omit entry/exit during a drag, so handle boundary crossings explicitly.
    override func mouseDragged(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            isPointerInside = true
            follow(event)
        } else if isPointerInside {
            mouseExited(with: event)
        }
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        move(to: event)
        onLift(point)
    }

    /// Option starts or ends a touch while the pointer is over the surface.
    func optionChanged(isDown: Bool) {
        guard isPointerInside else { return }
        if isDown { onTouch(point) } else { onLift(point) }
    }

    /// Forgets Select and the pointer without releasing or lifting, as the
    /// panel closes.
    func reset() {
        isSelectDown = false
        isPointerInside = false
    }

    private func follow(_ event: NSEvent) {
        move(to: event)
        if event.modifierFlags.contains(.option) { onTouch(point) } else { onLift(point) }
    }

    /// Takes the event's point, at the nearest edge for an event outside
    /// the surface, such as the exit of a fast move.
    private func move(to event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        func clamped(_ value: CGFloat) -> CGFloat { min(max(value, 0), 1) }
        point = CGPoint(x: clamped(location.x / bounds.width), y: clamped(1 - location.y / bounds.height))
    }

    private func setSelect(_ down: Bool) {
        guard down != isSelectDown else { return }
        isSelectDown = down
        onSelect(down)
    }
}
