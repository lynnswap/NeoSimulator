import AppKit
import NeoSimulatorDeviceIO
import NeoSimulatorKit

/// Keeps key releases with SimulatorKit until the display can hand its keyboard to the native transport.
@MainActor
package final class SimulatorKeyboardInput {
    private weak var view: NSView?
    private var monitor: Any?
    private var pressed: [UInt16: NSEvent] = [:]

    package var hasPressedKeys: Bool { !pressed.isEmpty }

    package func start(for view: NSView) {
        guard monitor == nil else { return }
        self.view = view
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, let view = self.view else { return event }
            if event.type == .keyUp {
                self.pressed[event.keyCode] = nil
            } else if let window = view.window, event.window === window, window.firstResponder === view {
                self.pressed[event.keyCode] = event
            }
            return event
        }
    }

    /// Captured keyboard events bypass application monitors, so their submission belongs here too.
    package func send(_ event: NSEvent, to view: NSView) {
        if monitor != nil, event.type == .keyDown { pressed[event.keyCode] = event }
        switch event.type {
        case .keyDown: view.keyDown(with: event)
        case .keyUp:
            view.keyUp(with: event)
            pressed[event.keyCode] = nil
        default: break
        }
    }

    package func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        let held = pressed.values
        pressed = [:]
        if let view {
            for event in held {
                if let release = NSEvent.keyEvent(with: .keyUp, location: event.locationInWindow,
                    modifierFlags: event.modifierFlags, timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: event.windowNumber, context: nil, characters: event.characters ?? "",
                    charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "", isARepeat: false,
                    keyCode: event.keyCode) {
                    view.keyUp(with: release)
                }
            }
        }
        view = nil
    }

    isolated deinit { stop() }
}

/// Follows a SimulatorKit display's digitizer in its responder chain. The digitizer passes key-downs and key-ups
/// it does not handle to its next responder, including those `DisplayKeyboardInput` forwards and those AppKit
/// delivers after menu key equivalents. `handle` takes them for the native keyboard; events it declines continue
/// along the chain, as they did before.
@MainActor
package final class NativeKeyboardResponder: NSResponder {
    private let handle: (NSEvent) -> Bool
    private weak var view: NSView?

    package init(handle: @escaping (NSEvent) -> Bool) {
        self.handle = handle
        super.init()
    }
    package required init?(coder: NSCoder) { nil }

    /// AppKit resets a view's next responder when the view moves to another superview, so this attaches again then.
    package func attach(after view: NSView) {
        guard view.nextResponder !== self else { return }
        detach()
        nextResponder = view.nextResponder
        view.nextResponder = self
        self.view = view
    }

    package func detach() {
        if let view, view.nextResponder === self { view.nextResponder = nextResponder }
        view = nil
    }

    package override func keyDown(with event: NSEvent) {
        if !handle(event) { super.keyDown(with: event) }
    }
    package override func keyUp(with event: NSEvent) {
        if !handle(event) { super.keyUp(with: event) }
    }
}

/// Takes the Mac trackpads' scrolling and pinches that begin over a SimulatorKit display's framebuffer, before its
/// digitizer drops them, and the mouse movements over the framebuffer that place them, for the device's native trackpad.
/// Events that begin elsewhere, such as over the bezel or a bar above the canvas, and Option-scrolling, which pans the
/// canvas, continue as before.
@MainActor
package final class NativeTrackpadInput: NSResponder {
    private weak var display: NSView?
    private weak var framebuffer: NSView?
    private let send: @MainActor (NSEvent, CGAffineTransform) -> Void
    private let endGestures: @MainActor () -> Void
    private var monitor: Any?
    private var tracking: NSTrackingArea?
    /// Whether the scroll or the pinch in progress began over the framebuffer. AppKit delivers the rest of a gesture,
    /// including a scroll's momentum, where it began, so those events follow it wherever the pointer goes.
    private var takesScroll = false
    private var takesPinch = false

    /// While enabled, the device takes the gestures; disabling ends those in progress.
    package var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled { start() } else { stop() }
        }
    }

    package init(display: NSView, framebuffer: NSView, send: @escaping @MainActor (NSEvent, CGAffineTransform) -> Void,
         endGestures: @escaping @MainActor () -> Void) {
        self.display = display
        self.framebuffer = framebuffer
        self.send = send
        self.endGestures = endGestures
        super.init()
    }
    package required init?(coder: NSCoder) { nil }

    isolated deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let tracking { framebuffer?.removeTrackingArea(tracking) }
    }

    private func start() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
            self?.take(event) == true ? nil : event
        }
        guard let framebuffer else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        framebuffer.addTrackingArea(area)
        tracking = area
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let tracking { framebuffer?.removeTrackingArea(tracking) }
        tracking = nil
        takesScroll = false
        takesPinch = false
        endGestures()
    }

    /// Sends `event` to the device when it belongs to a gesture over the framebuffer, which AppKit then does not deliver.
    private func take(_ event: NSEvent) -> Bool {
        guard let framebuffer else { return false }
        switch event.type {
        case .scrollWheel:
            // A trackpad's scroll begins with one of these phases; each of a mouse wheel's phaseless events stands alone.
            if !event.phase.isDisjoint(with: [.mayBegin, .began]) || (event.phase.isEmpty && event.momentumPhase.isEmpty) {
                takesScroll = !event.modifierFlags.contains(.option) && isOverFramebuffer(event)
            }
            guard takesScroll else { return false }
        case .magnify:
            if event.phase.contains(.began) { takesPinch = isOverFramebuffer(event) }
            guard takesPinch else { return false }
            if !event.phase.isDisjoint(with: [.ended, .cancelled]) { takesPinch = false }
        default:
            return false
        }
        send(event, NativeDeviceTrackpad.coordinateTransform(fromWindowTo: framebuffer))
        return true
    }

    package override func mouseMoved(with event: NSEvent) {
        guard isEnabled, let framebuffer, isOverFramebuffer(event) else { return }
        send(event, NativeDeviceTrackpad.coordinateTransform(fromWindowTo: framebuffer))
    }

    /// Whether `event` is over the framebuffer where nothing above the display, such as a bar over the canvas, takes it.
    private func isOverFramebuffer(_ event: NSEvent) -> Bool {
        guard let display, let framebuffer, let window = display.window, event.window === window,
              window.contentView?.superview?.hitTest(event.locationInWindow)?.isDescendant(of: display) == true
        else { return false }
        return framebuffer.bounds.contains(framebuffer.convert(event.locationInWindow, from: nil))
    }
}
