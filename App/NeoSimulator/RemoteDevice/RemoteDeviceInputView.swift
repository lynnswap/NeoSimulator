import AppKit
import Quartz
import Carbon
import IOKit.hid
@_spi(NeoSimulator) import XcodeSimulatorHost

@MainActor
final class RemoteDeviceInputView: NSView {
    let session: RemoteDeviceScreenSession
    var enqueue: ((@escaping @MainActor () async throws -> Void) -> Void)?
    var isInputEnabled = false {
        didSet { if oldValue && !isInputEnabled { releaseFocus() } }
    }
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    init(session: RemoteDeviceScreenSession) {
        self.session = session
        super.init(frame: .zero)
        setAccessibilityLabel("Remote Device Screen")
        setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { nil }
    /// Only the screen takes the device's pointer input; the frame around it keeps its own buttons.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isInputEnabled, let superview,
              session.inputLocations(atWindowPoint: superview.convert(point, to: nil)) != nil else { return nil }
        return super.hitTest(point)
    }
    func releaseFocus() {
        resetMouseGestures()
        enqueue? { [session] in try await session.releaseInputs() }
    }
    override func resignFirstResponder() -> Bool { releaseFocus(); return super.resignFirstResponder() }

    func releaseModifiers(_ events: [NSEvent]) {
        for event in events {
            guard let usage = Self.keyUsage[event.keyCode] else { continue }
            enqueueInput(for: .keyboard) { [session] in try await session.sendKey(usage, state: .up) }
        }
    }

    override func keyDown(with event: NSEvent) {
        guard isInputEnabled, session.inputCapabilities.contains(.keyboard), !event.isARepeat,
              let usage = Self.keyUsage[event.keyCode] else { return }
        enqueueInput(for: .keyboard) { [session] in try await session.sendKey(usage, state: .down) }
    }
    override func keyUp(with event: NSEvent) {
        guard isInputEnabled, session.inputCapabilities.contains(.keyboard), let usage = Self.keyUsage[event.keyCode] else { return }
        enqueueInput(for: .keyboard) { [session] in try await session.sendKey(usage, state: .up) }
    }
    override func flagsChanged(with event: NSEvent) {
        guard isInputEnabled, session.inputCapabilities.contains(.keyboard), let usage = Self.keyUsage[event.keyCode] else { return }
        if event.keyCode == UInt16(kVK_CapsLock) {
            enqueueInput(for: .keyboard) { [session] in
                try await session.sendKey(usage, state: .down)
                try await session.sendKey(usage, state: .up)
            }
        } else {
            let state: RemoteDeviceButtonState = CGEventSource.keyState(.combinedSessionState, key: event.keyCode) ? .down : .up
            enqueueInput(for: .keyboard) { [session] in try await session.sendKey(usage, state: state) }
        }
    }

    func invalidateInputs(for kinds: Set<RemoteDeviceInputKind>) {
        for kind in kinds { capabilityGenerations[kind, default: 0] += 1 }
        mouseGestures = mouseGestures.filter { !kinds.contains($0.value.kind.capability) }
        if kinds.contains(.gesture) { interruptTrackpadGestures() }
    }

    func enqueueInput(for kind: RemoteDeviceInputKind, _ operation: @escaping @MainActor () async throws -> Void) {
        let generation = capabilityGenerations[kind, default: 0]
        enqueue? { [weak self] in
            guard self?.capabilityGenerations[kind, default: 0] == generation else { return }
            try await operation()
        }
    }

    private enum MouseInputKind {
        case touch, pointer
        var capability: RemoteDeviceInputKind {
            switch self { case .touch: .digitizer; case .pointer: .pointer }
        }
    }
    private struct MouseGesture {
        let kind: MouseInputKind
        let clicks: Int
    }
    private var mouseGestures: [Int: MouseGesture] = [:]
    /// A gesture keeps its original destination until it ends, including momentum after the fingers lift.
    /// Losing input consumes its remaining events so they do not reach the device or the surrounding canvas.
    private enum TrackpadGesture { case forwarding, interrupted }
    private var scrollGesture: TrackpadGesture?
    private var pinchGesture: TrackpadGesture?
    private var inputGeneration = 0
    private var capabilityGenerations: [RemoteDeviceInputKind: Int] = [:]
    private var pointerTracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking)
        pointerTracking = tracking
    }

    private func resetMouseGestures() {
        inputGeneration += 1
        mouseGestures.removeAll()
        interruptTrackpadGestures()
    }

    private func interruptTrackpadGestures() {
        if scrollGesture != nil { scrollGesture = .interrupted }
        if pinchGesture != nil { pinchGesture = .interrupted }
    }

    private func enqueueMouseInput(kind: MouseInputKind, _ operation: @escaping @MainActor () async throws -> Void) {
        enqueueGestureInput(for: kind.capability, operation)
    }

    /// Sends a step of a gesture. A failure ends the view's gestures and releases what the device holds.
    private func enqueueGestureInput(for capability: RemoteDeviceInputKind, _ operation: @escaping @MainActor () async throws -> Void) {
        let generation = inputGeneration
        let capabilityGeneration = capabilityGenerations[capability, default: 0]
        enqueueInput(for: capability) { [weak self, session] in
            guard self?.inputGeneration == generation else { return }
            do { try await operation() }
            catch {
                guard self?.capabilityGenerations[capability, default: 0] == capabilityGeneration else { throw error }
                if self?.inputGeneration == generation { self?.resetMouseGestures() }
                do { try await session.releaseInputs() }
                catch let cleanup {
                    throw RemoteDeviceWindowError.cleanup([error.localizedDescription, cleanup.localizedDescription])
                }
                throw error
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isInputEnabled else { return }
        window?.makeFirstResponder(self)
        let kind: MouseInputKind
        if event.buttonNumber == 0, session.inputCapabilities.contains(.digitizer) { kind = .touch }
        else if session.inputCapabilities.contains(.pointer) { kind = .pointer }
        else { return }
        guard let locations = session.inputLocations(atWindowPoint: event.locationInWindow) else { return }
        let button = event.buttonNumber
        let clicks = event.clickCount
        mouseGestures[button] = MouseGesture(kind: kind, clicks: clicks)
        enqueueMouseInput(kind: kind) { [session] in
            switch kind {
            case .touch: try await session.sendTouch(at: locations.touch, phase: .began)
            case .pointer: try await session.sendPointerButton(button, phase: .down, clicks: clicks, at: locations.pointer)
            }
        }
    }
    override func rightMouseDown(with event: NSEvent) { mouseDown(with: event) }
    override func otherMouseDown(with event: NSEvent) { mouseDown(with: event) }

    override func mouseDragged(with event: NSEvent) {
        guard isInputEnabled, let gesture = mouseGestures[event.buttonNumber] else { return }
        guard let locations = session.inputLocations(atWindowPoint: event.locationInWindow, clampingToDisplay: true) else { return }
        let button = event.buttonNumber
        enqueueMouseInput(kind: gesture.kind) { [session] in
            switch gesture.kind {
            case .touch: try await session.sendTouch(at: locations.touch, phase: .moved)
            case .pointer: try await session.sendPointerButton(button, phase: .dragged, clicks: gesture.clicks, at: locations.pointer)
            }
        }
    }
    override func rightMouseDragged(with event: NSEvent) { mouseDragged(with: event) }
    override func otherMouseDragged(with event: NSEvent) { mouseDragged(with: event) }

    override func mouseUp(with event: NSEvent) {
        guard isInputEnabled, let gesture = mouseGestures.removeValue(forKey: event.buttonNumber) else { return }
        guard let locations = session.inputLocations(atWindowPoint: event.locationInWindow, clampingToDisplay: true) else {
            releaseFocus()
            return
        }
        let button = event.buttonNumber
        enqueueMouseInput(kind: gesture.kind) { [session] in
            switch gesture.kind {
            case .touch: try await session.sendTouch(at: locations.touch, phase: .ended)
            case .pointer: try await session.sendPointerButton(button, phase: .up, clicks: gesture.clicks, at: locations.pointer)
            }
        }
    }
    override func rightMouseUp(with event: NSEvent) { mouseUp(with: event) }
    override func otherMouseUp(with event: NSEvent) { mouseUp(with: event) }

    override func scrollWheel(with event: NSEvent) {
        let begins = !event.phase.isDisjoint(with: [.mayBegin, .began])
            || (event.phase.isEmpty && event.momentumPhase.isEmpty)
        if begins {
            scrollGesture = nil
            guard isInputEnabled, session.inputCapabilities.contains(.gesture),
                  session.inputLocations(atWindowPoint: event.locationInWindow) != nil else {
                return super.scrollWheel(with: event)
            }
            scrollGesture = .forwarding
        } else {
            guard let gesture = scrollGesture else { return super.scrollWheel(with: event) }
            guard gesture == .forwarding else { return }
        }
        // A physical ended event can be followed by momentum, which belongs to the same destination.
        if event.phase.contains(.cancelled) || event.momentumPhase.contains(.ended) { scrollGesture = nil }
        enqueueGestureInput(for: .gesture) { [session] in try await session.sendTrackpadGesture(event) }
    }

    /// A pinch that begins over the screen pinches the device's app; others magnify whatever contains the screen.
    override func magnify(with event: NSEvent) {
        if event.phase.contains(.began) {
            pinchGesture = nil
            guard isInputEnabled, session.inputCapabilities.contains(.gesture),
                  session.inputLocations(atWindowPoint: event.locationInWindow) != nil else { return super.magnify(with: event) }
            pinchGesture = .forwarding
        } else if let gesture = pinchGesture {
            if !event.phase.isDisjoint(with: [.ended, .cancelled]) { pinchGesture = nil }
            guard gesture == .forwarding else { return }
        } else {
            return super.magnify(with: event)
        }
        enqueueGestureInput(for: .gesture) { [session] in try await session.sendTrackpadGesture(event) }
    }

    override func mouseMoved(with event: NSEvent) {
        guard isInputEnabled, let locations = session.inputLocations(atWindowPoint: event.locationInWindow) else { return }
        if session.inputCapabilities.contains(.pointer) {
            enqueueMouseInput(kind: .pointer) { [session] in try await session.movePointer(to: locations.pointer) }
        } else if session.inputCapabilities.contains(.gesture) {
            // Without a pointer connection, as on a dedicated display, the mouse still places the trackpad's pinches.
            enqueueGestureInput(for: .gesture) { [session] in try await session.moveGesturePointer(with: event, at: locations) }
        }
    }

    private static let keyUsage: [UInt16: UInt16] = {
        let pairs: [(Int, Int)] = [
            (kVK_ANSI_A, kHIDUsage_KeyboardA), (kVK_ANSI_B, kHIDUsage_KeyboardB), (kVK_ANSI_C, kHIDUsage_KeyboardC),
            (kVK_ANSI_D, kHIDUsage_KeyboardD), (kVK_ANSI_E, kHIDUsage_KeyboardE), (kVK_ANSI_F, kHIDUsage_KeyboardF),
            (kVK_ANSI_G, kHIDUsage_KeyboardG), (kVK_ANSI_H, kHIDUsage_KeyboardH), (kVK_ANSI_I, kHIDUsage_KeyboardI),
            (kVK_ANSI_J, kHIDUsage_KeyboardJ), (kVK_ANSI_K, kHIDUsage_KeyboardK), (kVK_ANSI_L, kHIDUsage_KeyboardL),
            (kVK_ANSI_M, kHIDUsage_KeyboardM), (kVK_ANSI_N, kHIDUsage_KeyboardN), (kVK_ANSI_O, kHIDUsage_KeyboardO),
            (kVK_ANSI_P, kHIDUsage_KeyboardP), (kVK_ANSI_Q, kHIDUsage_KeyboardQ), (kVK_ANSI_R, kHIDUsage_KeyboardR),
            (kVK_ANSI_S, kHIDUsage_KeyboardS), (kVK_ANSI_T, kHIDUsage_KeyboardT), (kVK_ANSI_U, kHIDUsage_KeyboardU),
            (kVK_ANSI_V, kHIDUsage_KeyboardV), (kVK_ANSI_W, kHIDUsage_KeyboardW), (kVK_ANSI_X, kHIDUsage_KeyboardX),
            (kVK_ANSI_Y, kHIDUsage_KeyboardY), (kVK_ANSI_Z, kHIDUsage_KeyboardZ),
            (kVK_ANSI_1, kHIDUsage_Keyboard1), (kVK_ANSI_2, kHIDUsage_Keyboard2), (kVK_ANSI_3, kHIDUsage_Keyboard3),
            (kVK_ANSI_4, kHIDUsage_Keyboard4), (kVK_ANSI_5, kHIDUsage_Keyboard5), (kVK_ANSI_6, kHIDUsage_Keyboard6),
            (kVK_ANSI_7, kHIDUsage_Keyboard7), (kVK_ANSI_8, kHIDUsage_Keyboard8), (kVK_ANSI_9, kHIDUsage_Keyboard9), (kVK_ANSI_0, kHIDUsage_Keyboard0),
            (kVK_Return, kHIDUsage_KeyboardReturnOrEnter), (kVK_Escape, kHIDUsage_KeyboardEscape), (kVK_Delete, kHIDUsage_KeyboardDeleteOrBackspace),
            (kVK_Tab, kHIDUsage_KeyboardTab), (kVK_Space, kHIDUsage_KeyboardSpacebar), (kVK_ANSI_Minus, kHIDUsage_KeyboardHyphen),
            (kVK_ANSI_Equal, kHIDUsage_KeyboardEqualSign), (kVK_ANSI_LeftBracket, kHIDUsage_KeyboardOpenBracket),
            (kVK_ANSI_RightBracket, kHIDUsage_KeyboardCloseBracket), (kVK_ANSI_Backslash, kHIDUsage_KeyboardBackslash),
            (kVK_ANSI_Semicolon, kHIDUsage_KeyboardSemicolon), (kVK_ANSI_Quote, kHIDUsage_KeyboardQuote),
            (kVK_ANSI_Grave, kHIDUsage_KeyboardGraveAccentAndTilde), (kVK_ANSI_Comma, kHIDUsage_KeyboardComma),
            (kVK_ANSI_Period, kHIDUsage_KeyboardPeriod), (kVK_ANSI_Slash, kHIDUsage_KeyboardSlash), (kVK_CapsLock, kHIDUsage_KeyboardCapsLock),
            (kVK_JIS_Eisu, kHIDUsage_KeyboardLANG2), (kVK_JIS_Kana, kHIDUsage_KeyboardLANG1),
            (kVK_F1, kHIDUsage_KeyboardF1), (kVK_F2, kHIDUsage_KeyboardF2), (kVK_F3, kHIDUsage_KeyboardF3), (kVK_F4, kHIDUsage_KeyboardF4),
            (kVK_F5, kHIDUsage_KeyboardF5), (kVK_F6, kHIDUsage_KeyboardF6), (kVK_F7, kHIDUsage_KeyboardF7), (kVK_F8, kHIDUsage_KeyboardF8),
            (kVK_F9, kHIDUsage_KeyboardF9), (kVK_F10, kHIDUsage_KeyboardF10), (kVK_F11, kHIDUsage_KeyboardF11), (kVK_F12, kHIDUsage_KeyboardF12),
            (kVK_Home, kHIDUsage_KeyboardHome), (kVK_End, kHIDUsage_KeyboardEnd), (kVK_PageUp, kHIDUsage_KeyboardPageUp),
            (kVK_PageDown, kHIDUsage_KeyboardPageDown), (kVK_ForwardDelete, kHIDUsage_KeyboardDeleteForward),
            (kVK_RightArrow, kHIDUsage_KeyboardRightArrow), (kVK_LeftArrow, kHIDUsage_KeyboardLeftArrow),
            (kVK_DownArrow, kHIDUsage_KeyboardDownArrow), (kVK_UpArrow, kHIDUsage_KeyboardUpArrow),
            (kVK_Control, kHIDUsage_KeyboardLeftControl), (kVK_Shift, kHIDUsage_KeyboardLeftShift),
            (kVK_Option, kHIDUsage_KeyboardLeftAlt), (kVK_Command, kHIDUsage_KeyboardLeftGUI),
            (kVK_RightControl, kHIDUsage_KeyboardRightControl), (kVK_RightShift, kHIDUsage_KeyboardRightShift),
            (kVK_RightOption, kHIDUsage_KeyboardRightAlt), (kVK_RightCommand, kHIDUsage_KeyboardRightGUI),
        ]
        return Dictionary(uniqueKeysWithValues: pairs.map { (UInt16($0.0), UInt16($0.1)) })
    }()
}
