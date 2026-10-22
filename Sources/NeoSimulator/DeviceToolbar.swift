import AppKit
import Observation

/// The device window's toolbar, built from the command catalog.
@MainActor
final class DeviceToolbar: NSObject, NSToolbarDelegate {
    let toolbar = NSToolbar(identifier: "DeviceToolbar")
    private weak var controller: DeviceWindowController?
    private let commands: [DeviceCommand.ID]
    /// The modifier keys held now, which the buttons follow.
    var modifierFlags: () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }
    /// The toolbar's view, whose tracking area reports the pointer over it.
    private var pointerTracking: (view: NSView, area: NSTrackingArea)?
    /// Watches the modifier keys while the pointer is over the toolbar.
    private var modifierMonitor: Any?
    /// Whether the buttons show their Option alternates.
    private var showsOptionAlternates = false

    init(controller: DeviceWindowController) {
        self.controller = controller
        commands = DeviceCommand.toolbarItems.filter {
            DeviceCommand.command($0).isSupported(controller.session.capabilities)
        }
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        // Like Simulator.app, a unified title bar truncates the title before
        // it moves buttons into the overflow menu. The property is private
        // AppKit API; without it, AppKit keeps its own minimum.
        if toolbar.responds(to: NSSelectorFromString("setMinimumInlineWindowTitleWidth:")) {
            toolbar.setValue(0.0, forKey: "minimumInlineWindowTitleWidth")
        }
        updateItems()
    }

    isolated deinit {
        if let modifierMonitor { NSEvent.removeMonitor(modifierMonitor) }
        if let pointerTracking { pointerTracking.view.removeTrackingArea(pointerTracking.area) }
    }

    /// Gives `window` the toolbar and, like Simulator.app's `SimToolbar`,
    /// tracks the pointer over the toolbar's view while the app is active, in
    /// any of its windows, so that the buttons follow Option there. The view
    /// is private AppKit API, as in Simulator.app: it spans the title bar with
    /// the unified styles and the row below the title with the expanded one.
    /// Without it, the buttons keep their faces.
    func attach(to window: NSWindow) {
        window.toolbar = toolbar
        guard toolbar.responds(to: NSSelectorFromString("_toolbarView")),
              let view = toolbar.value(forKey: "_toolbarView") as? NSView else { return }
        let area = NSTrackingArea(rect: view.bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        view.addTrackingArea(area)
        pointerTracking = (view, area)
    }

    /// The pointer entered the toolbar: until it leaves, the buttons show
    /// their Option alternates while Option is down. Like Simulator.app's,
    /// they read the keys when the pointer enters and at each modifier change
    /// that reaches the app. They read the keys held rather than the event's,
    /// so that the modifier release a window sends its device when it resigns
    /// key does not turn the alternates off while Option is held.
    @objc(mouseEntered:) func mouseEntered(with event: NSEvent) {
        if modifierMonitor == nil {
            modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                self?.followOption()
                return event
            }
        }
        followOption()
    }

    @objc(mouseExited:) func mouseExited(with event: NSEvent) {
        if let modifierMonitor { NSEvent.removeMonitor(modifierMonitor) }
        modifierMonitor = nil
        showOptionAlternates(false)
    }

    private func followOption() { showOptionAlternates(modifierFlags().contains(.option)) }

    private func showOptionAlternates(_ shows: Bool) {
        guard shows != showsOptionAlternates else { return }
        showsOptionAlternates = shows
        configureItems()
    }

    /// Like Simulator.app's toolbar nibs, the buttons sit between two flexible
    /// spaces; `apply(_:to:)` hides the last one.
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace] + commands.map { NSToolbarItem.Identifier($0.rawValue) } + [.flexibleSpace]
    }

    /// What Simulator.app's toolbar style threshold counts for the toolbar's
    /// buttons (`_toolbarItemWidth`): the width of each button in its toolbar
    /// nib plus 4 points, for the commands this toolbar has.
    private var buttonsWidth: CGFloat {
        commands.compactMap { DeviceCommand.command($0).toolbar?.buttonWidth }.reduce(0) { $0 + $1 + 4 }
    }

    /// The narrowest display with which Simulator.app keeps the unified style
    /// (`_minWidth`): the buttons, the wider of `title` in the headline font
    /// and `subtitle` in the subheadline font, and 130 points.
    private func unifiedWidth(title: String, subtitle: String) -> CGFloat {
        func width(_ text: String, _ style: NSFont.TextStyle) -> CGFloat {
            let font = NSFont.preferredFont(forTextStyle: style, options: [:])
            return NSAttributedString(string: text, attributes: [.font: font]).size().width
        }
        return buttonsWidth + max(width(title, .headline), width(subtitle, .subheadline)) + 130
    }

    /// The style Simulator.app's geometry update gives the toolbar of a window
    /// whose display is `width` points wide: compact with `UseCompactTitleBar`,
    /// otherwise unified while `UseMonobar` is on and the display is at least
    /// `unifiedWidth(title:subtitle:)` wide, and expanded below that.
    func style(forWidth width: CGFloat, title: String, subtitle: String,
               preferences: any PreferenceStore) -> NSWindow.ToolbarStyle {
        if preferences.usesCompactTitleBar { return .unifiedCompact }
        return preferences.usesMonobar && unifiedWidth(title: title, subtitle: subtitle) <= width ? .unified : .expanded
    }

    /// Gives `window` `style` and, as Simulator.app does on macOS 26, hides
    /// the last flexible space of the window's toolbar unless the style is
    /// expanded, so that the buttons follow the title in a unified title bar
    /// and are centered in the row below it in an expanded one. The window's
    /// toolbar is this one, or the toolbar of a user-interface plugin, which
    /// Simulator.app also styles so.
    func apply(_ style: NSWindow.ToolbarStyle, to window: NSWindow) {
        window.toolbarStyle = style
        if let last = window.toolbar?.items.last, last.itemIdentifier == .flexibleSpace {
            last.isHidden = style != .expanded
        }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let id = DeviceCommand.ID(rawValue: itemIdentifier.rawValue),
              let presentation = DeviceCommand.command(id).toolbar else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = presentation.label
        // Like Simulator.app's Always On, a command with a state is a button
        // that stays on while the state is on. The item gives the button its
        // target and action.
        if DeviceCommand.command(id).state != nil {
            let button = NSButton()
            button.bezelStyle = .toolbar
            button.setButtonType(.pushOnPushOff)
            button.identifier = NSUserInterfaceItemIdentifier(id.rawValue)
            item.view = button
        }
        item.target = self
        item.action = #selector(activate(_:))
        item.autovalidates = false
        configure(item, id)
        return item
    }

    /// What `id`'s button shows and performs now: its alternate while that
    /// can run, as Save Screen stops a recording whether or not Option is
    /// down; otherwise its Option alternate while the buttons show those; and
    /// otherwise its own command.
    private func shown(_ id: DeviceCommand.ID, for controller: DeviceWindowController) -> DeviceCommand.Toolbar.Face? {
        guard let presentation = DeviceCommand.command(id).toolbar else { return nil }
        if let alternate = presentation.alternate, DeviceCommand.command(alternate.id).isEnabled(controller) {
            return alternate
        }
        if showsOptionAlternates, let alternate = presentation.optionAlternate { return alternate }
        return .init(id: id, symbol: presentation.symbol, imageDescription: presentation.imageDescription)
    }

    /// Like Simulator.app's buttons, a button keeps its item's label while
    /// its tooltip and image, and the image's description, follow the command
    /// it performs.
    private func configure(_ item: NSToolbarItem, _ id: DeviceCommand.ID) {
        guard let controller, let shown = shown(id, for: controller) else { return }
        let command = DeviceCommand.command(shown.id)
        item.toolTip = shown.toolTip ?? command.toolbar?.toolTip ?? item.label
        item.image = NSImage(systemSymbolName: shown.symbol, accessibilityDescription: shown.imageDescription)
        item.isEnabled = command.isEnabled(controller)
        guard let button = item.view as? NSButton else { return }
        button.image = item.image
        button.toolTip = item.toolTip
        button.isEnabled = item.isEnabled
        button.state = command.state?(controller) ?? .off
    }

    private func updateItems() {
        withObservationTracking {
            guard let controller else { return }
            // Read these even before AppKit has asked the delegate to create items.
            _ = controller.session.isBusy
            _ = controller.session.isConnected
            _ = controller.session.recording?.isStopping
            _ = controller.session.showsAlwaysOn
            configureItems()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.updateItems() }
        }
    }

    private func configureItems() {
        for item in toolbar.items {
            if let id = DeviceCommand.ID(rawValue: item.itemIdentifier.rawValue) { configure(item, id) }
        }
    }

    /// Performs what the item's button shows. A button that shows a state
    /// then shows the command's state again, which a click changed.
    @objc private func activate(_ sender: Any) {
        let identifier = (sender as? NSToolbarItem)?.itemIdentifier.rawValue ?? (sender as? NSButton)?.identifier?.rawValue
        guard let controller, let id = identifier.flatMap(DeviceCommand.ID.init(rawValue:)),
              let shown = shown(id, for: controller) else { return }
        controller.perform(shown.id)
        configureItems()
    }
}

// MARK: - Apple TV Remote

/// Window ▸ Show Apple TV Remote's panel: Simulator.app's onscreen Apple TV
/// Remote, `AppleRemoteWindowController` and its nib, rebuilt with AppKit.
/// The app has one remote. It controls the device of the key device window,
/// or else of the frontmost one, as Simulator.app's `keyDeviceCoordinator`
/// chooses; only an Apple TV takes its input.
///
/// Like Simulator.app's `AppleRemotePanel`, the panel never becomes key, so
/// the device window keeps the keyboard, and it moves by its background and
/// hides while the app is inactive. Device windows report when they become
/// key and when they close, which brings the panel to the front or closes
/// it: see `deviceWindowBecameKey(_:)` and `deviceWindowWillClose(_:)`.
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
    }

    required init?(coder: NSCoder) { nil }

    isolated deinit {
        if let optionMonitor { NSEvent.removeMonitor(optionMonitor) }
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
    func deviceWindowBecameKey(_ controller: DeviceWindowController) {
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
    func deviceWindowWillClose(_ controller: DeviceWindowController) {
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
/// leaves or Option goes up.
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
    override func mouseDragged(with event: NSEvent) { follow(event) }

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

    private func move(to event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        point = CGPoint(x: location.x / bounds.width, y: 1 - location.y / bounds.height)
    }

    private func setSelect(_ down: Bool) {
        guard down != isSelectDown else { return }
        isSelectDown = down
        onSelect(down)
    }
}
