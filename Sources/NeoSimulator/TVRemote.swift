import AppKit

/// Window ▸ Show Apple TV Remote's panel: Simulator.app's onscreen Apple TV
/// Remote, `AppleRemoteWindowController` and its nib, rebuilt with AppKit.
/// The app has one remote. It controls the device of the key device window,
/// or else of the frontmost one, as Simulator.app's `keyDeviceCoordinator`
/// chooses; only an Apple TV takes its input.
///
/// Like Simulator.app's `AppleRemotePanel`, the panel never becomes key, so
/// the device window keeps the keyboard, and it moves by its background and
/// hides while the app is inactive. Every window that becomes key or closes
/// is checked against Simulator.app's rules, which bring the panel to the
/// front or close it: see `deviceWindowBecameKey(_:)` and
/// `deviceWindowWillClose(_:)`.
@MainActor
final class TVRemoteController: NSWindowController, NSWindowDelegate {
    /// The device window whose device the remote controls now.
    private let target: @MainActor () -> DeviceWindowController?
    private let buttons: [TVRemoteButtonView]
    private let surface: TVRemoteTouchSurface
    /// The device window that each held button went to, which receives its
    /// release, and the one that has the surface's touch.
    private var pressTargets: [TVRemoteButton: WeakDeviceWindow] = [:]
    private weak var touchTarget: DeviceWindowController?
    /// Watches the modifier keys for the touch surface while the panel shows.
    private var optionMonitor: Any?
    /// Watch the app's windows becoming key and closing.
    private var windowObservers: [any NSObjectProtocol] = []

    /// Where AppKit saves the panel's frame, Simulator.app's name.
    static let frameAutosaveName = "Apple TV Remote Window"

    /// Builds the remote with the layout of Simulator.app's nib, 155 by 515
    /// points: the touch surface at the top, then Menu and TV, Siri and
    /// Volume Up, and Play/Pause and Volume Down. AppKit drawing and SF
    /// Symbols stand in for Simulator.app's artwork.
    ///
    /// - Parameter target: The device window whose device the remote
    ///   controls, by default `keyOrFrontmostDeviceWindow()`.
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
        // In Simulator.app, an external display's window is a device window
        // too, so the window of any device, or of its external display,
        // decides when it becomes key.
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

    /// Simulator.app's `keyDeviceCoordinator`: the key device window, or
    /// else the frontmost device window.
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
        // Like Simulator.app's `SimulatorApp`, which tells the surface about
        // each modifier change the app receives.
        if optionMonitor == nil {
            optionMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                self?.surface.optionChanged(isDown: event.modifierFlags.contains(.option))
                return event
            }
        }
    }

    /// A closing panel releases what it holds down.
    func windowWillClose(_ notification: Notification) {
        if let optionMonitor { NSEvent.removeMonitor(optionMonitor) }
        optionMonitor = nil
        for button in buttons { button.release() }
        surface.end()
    }

    /// Like Simulator.app's `deviceWindowBecameKey:`, a shown panel comes to
    /// the front of the window of a device that takes the remote, and closes
    /// for another device.
    private func deviceWindowBecameKey(_ controller: DeviceWindowController) {
        guard isVisible else { return }
        if controller.session.capabilities.supportsFeature(DeviceCapabilities.tvRemote) {
            window?.orderFront(nil)
        } else {
            close()
        }
    }

    /// Like Simulator.app, closing the last device window, of a device that
    /// takes the remote, closes the panel; with other device windows open,
    /// the next key one decides.
    private func deviceWindowWillClose(_ controller: DeviceWindowController) {
        guard isVisible, controller.session.capabilities.supportsFeature(DeviceCapabilities.tvRemote) else { return }
        let othersRemain = NSApp.windows.contains { window in
            window !== controller.window && (window.isVisible || window.isMiniaturized)
                && window.windowController is DeviceWindowController
        }
        if !othersRemain { close() }
    }

    // MARK: Input

    private func setButton(_ button: TVRemoteButton, down: Bool) {
        if down {
            guard let controller = target() else { return }
            pressTargets[button] = WeakDeviceWindow(controller: controller)
            controller.session.pressRemoteButton(button) { [weak controller] in controller?.present($0) }
        } else if let controller = pressTargets.removeValue(forKey: button)?.controller {
            controller.session.releaseRemoteButton(button)
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
        touchTarget = nil
    }

    // MARK: Panel

    /// Gives the panel the properties of Simulator.app's, connects its
    /// controls, and restores its frame.
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
        // A remote without a saved frame opens at the top of the screen, 386
        // points left of its right edge, where Simulator.app's nib places it
        // on a 2560-point-wide screen.
        if !panel.setFrameUsingName(Self.frameAutosaveName), let screen = NSScreen.main?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: screen.maxX - 386 - TVRemoteLayout.size.width, y: screen.maxY))
        }
        panel.setFrameAutosaveName(Self.frameAutosaveName)
    }
}

private struct WeakDeviceWindow {
    weak var controller: DeviceWindowController?
}

/// Simulator.app's `AppleRemotePanel`: a borderless panel that never becomes key.
private final class TVRemotePanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

/// Where Simulator.app's nib places the remote's views, from the panel's
/// bottom-left corner.
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
    /// The outline of the buttons, 2 points in Simulator.app's 64-point images.
    static let lineWidth: CGFloat = 2 * 55 / 64
    static let outline = NSColor(white: 0.27, alpha: 0.9)
    static let pressed = NSColor(white: 1, alpha: 0.19)
    static let glyph = NSColor(white: 0.6, alpha: 1)
}

/// The remote's body: Simulator.app's `Remote Chrome`, a rounded black
/// panel whose upper part, around the touch surface, is dark gray, and the
/// volume buttons' capsule.
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

/// A button of the remote, Simulator.app's `AppleRemoteMouseDownTrackingControl`:
/// pressing it presses the remote's button, and releasing the mouse releases
/// it, wherever the pointer then is.
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

/// The remote's touch surface, Simulator.app's `AppleRemoteControlSurface`.
/// A click presses Select. While Option is held with the pointer over it,
/// the pointer touches the surface: the touch starts when the pointer enters
/// or Option goes down, moves with the pointer, and ends when the pointer
/// leaves, also by a drag, or Option goes up. Its points stay within the
/// surface.
final class TVRemoteTouchSurface: NSView {
    var onSelect: (Bool) -> Void = { _ in }
    var onTouch: (CGPoint) -> Void = { _ in }
    var onLift: (CGPoint) -> Void = { _ in }
    private var isPointerInside = false
    private var isSelectDown = false
    /// Where the pointer last was, from 0 to 1 from the top-left corner,
    /// Simulator.app's `lastValidTrackpadPoint`.
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

    /// The tracking area reports no exit or entry while the mouse is down, so
    /// a drag that leaves the surface, onto a button or off the panel, ends
    /// the touch at the edge it crosses, and one that comes back touches
    /// again. Simulator.app's surface keeps following such a drag, past its
    /// edges.
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

    /// Like Simulator.app's `optionButtonDidChangeState:`, Option starts or
    /// ends the touch while the pointer is over the surface.
    func optionChanged(isDown: Bool) {
        guard isPointerInside else { return }
        if isDown { onTouch(point) } else { onLift(point) }
    }

    /// Releases Select and ends the touch, as the panel closes.
    func end() {
        setSelect(false)
        isPointerInside = false
        onLift(point)
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
