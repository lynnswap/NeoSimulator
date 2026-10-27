import AppKit
import Carbon
import Observation
import IOKit.hidsystem

/// A synchronous filter: returning true consumes an event before AppKit handles shortcuts.
@MainActor
protocol KeyboardEventTap: AnyObject {
    func start(receive: @escaping @MainActor (CGEventType, CGEvent) -> Bool) throws
    func stop()
}

@MainActor
final class SystemKeyboardEventTap: KeyboardEventTap {
    private struct StartFailure: LocalizedError {
        let errorDescription: String?
        let recoverySuggestion: String?
    }

    private let applicationName: String
    private let access: () -> IOHIDAccessType
    private let createTap: (CGEventMask, CGEventTapCallBack, UnsafeMutableRawPointer?) -> CFMachPort?
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var receive: (@MainActor (CGEventType, CGEvent) -> Bool)?

    init(applicationName: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? ProcessInfo.processInfo.processName,
         access: @escaping () -> IOHIDAccessType = { IOHIDCheckAccess(kIOHIDRequestTypePostEvent) },
         createTap: @escaping (CGEventMask, CGEventTapCallBack, UnsafeMutableRawPointer?) -> CFMachPort? = { mask, callback, context in
             CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                               eventsOfInterest: mask, callback: callback, userInfo: context)
         }) {
        self.applicationName = applicationName
        self.access = access
        self.createTap = createTap
    }

    func start(receive: @escaping @MainActor (CGEventType, CGEvent) -> Bool) throws {
        self.receive = receive
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        guard let port = createTap(CGEventMask(mask), { _, type, event, context in
                // The source is installed exclusively on the main run loop below.
                let consumed = MainActor.assumeIsolated {
                    guard let context else { return false }
                    let tap = Unmanaged<SystemKeyboardEventTap>.fromOpaque(context).takeUnretainedValue()
                    return tap.receive?(type, event) ?? false
                }
                return consumed ? nil : Unmanaged.passUnretained(event)
            }, Unmanaged.passUnretained(self).toOpaque()) else {
            self.receive = nil
            // A nil tap also has non-permission causes. Query access only to diagnose its failure.
            let authorization = access()
            if authorization == kIOHIDAccessTypeGranted {
                throw StartFailure(errorDescription: "Unable to Create Keyboard Event Tap.",
                    recoverySuggestion: "macOS reports keyboard event access is allowed for “\(applicationName)”. Try Capture Keyboard again. If it still fails, quit and reopen the app. You can still type in the focused device screen.")
            }
            let title = authorization == kIOHIDAccessTypeDenied
                ? "Keyboard Capture Access Was Denied."
                : "Keyboard Capture Access Is Not Authorized."
            throw StartFailure(errorDescription: title,
                recoverySuggestion: "Allow “\(applicationName)” in System Settings > Privacy & Security > Accessibility, then try Capture Keyboard again. You can still type in the focused device screen.")
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            self.receive = nil
            throw HostError.operation("Unable to Capture Keyboard. The keyboard event source could not be created.")
        }
        self.port = port
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    func stop() {
        receive = nil
        if let port { CGEvent.tapEnable(tap: port, enable: false); CFMachPortInvalidate(port) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
        port = nil
    }

    isolated deinit { stop() }
}

/// Captures shortcuts only while its displayed device owns focus. Escape remains a way out.
@Observable @MainActor
final class KeyboardCapture {
    private(set) var isCapturing = false
    @ObservationIgnored var failure: (any Error) -> Void = { _ in }
    @ObservationIgnored var didStop: () -> Void = {}
    private let tap: any KeyboardEventTap
    private let isEligible: () -> Bool
    private let forward: (NSEvent) -> Void
    private let releaseModifiers: ([NSEvent]) -> Void
    private let waitForEscapeHold: () async throws -> Void
    private let initialModifierFlags: () -> NSEvent.ModifierFlags
    @ObservationIgnored private var pressed: [UInt16: NSEvent] = [:]
    @ObservationIgnored private var modifiers: [UInt16: NSEvent] = [:]
    @ObservationIgnored private var escapeHold: Task<Void, Never>?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    private static let modifierKeys: [(Int, NSEvent.ModifierFlags)] = [
        (kVK_Command, .command), (kVK_RightCommand, .command),
        (kVK_Shift, .shift), (kVK_RightShift, .shift),
        (kVK_Option, .option), (kVK_RightOption, .option),
        (kVK_Control, .control), (kVK_RightControl, .control), (kVK_Function, .function),
    ]

    init(tap: any KeyboardEventTap = SystemKeyboardEventTap(), isEligible: @escaping () -> Bool,
         forward: @escaping (NSEvent) -> Void, releaseModifiers: @escaping ([NSEvent]) -> Void,
         initialModifierFlags: @escaping () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags },
         waitForEscapeHold: @escaping () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }) {
        self.tap = tap
        self.isEligible = isEligible
        self.forward = forward
        self.releaseModifiers = releaseModifiers
        self.waitForEscapeHold = waitForEscapeHold
        self.initialModifierFlags = initialModifierFlags
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willResignActiveNotification,
            object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { _ = self?.stop() } })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isCapturing, !self.isEligible() else { return }
                    self.stop()
                }
            })
    }

    func start() throws {
        guard !isCapturing else { return }
        guard isEligible() else { throw HostError.operation("Focus the device screen before capturing its keyboard.") }
        try tap.start { [weak self] type, event in self?.receive(type, event) ?? false }
        isCapturing = true
        // Focus may already have sent modifiers held before the tap started.
        let flags = initialModifierFlags()
        for (code, flag) in Self.modifierKeys where flags.contains(flag) {
            if let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(code)) {
                modifiers[UInt16(code)] = event
            }
        }
    }

    @discardableResult
    func stop() -> Bool {
        guard isCapturing else { return false }
        isCapturing = false
        tap.stop()
        escapeHold?.cancel()
        escapeHold = nil
        let keys = pressed.values
        pressed.removeAll()
        for event in keys {
            if let up = NSEvent.keyEvent(with: .keyUp, location: event.locationInWindow, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: event.windowNumber, context: nil,
                characters: event.characters ?? "", charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: false, keyCode: event.keyCode) { forward(up) }
        }
        let releases = modifiers.values.compactMap { event in
            NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: event.windowNumber, context: nil,
                characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: event.keyCode)
        }
        modifiers.removeAll()
        releaseModifiers(releases)
        didStop()
        return true
    }

    private func receive(_ type: CGEventType, _ cgEvent: CGEvent) -> Bool {
        guard isCapturing else { return false }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            stop()
            failure(HostError.operation("Keyboard capture stopped because macOS disabled its event tap. Try Capture Keyboard again."))
            return false
        }
        guard isEligible() else { stop(); return false }
        guard let event = NSEvent(cgEvent: cgEvent) else { return false }
        switch event.type {
        case .keyDown:
            pressed[event.keyCode] = event
            if event.keyCode == UInt16(kVK_Escape), !event.isARepeat, escapeHold == nil {
                escapeHold = Task { [weak self, waitForEscapeHold] in
                    do {
                        try await waitForEscapeHold()
                        try Task.checkCancellation()
                        self?.stop()
                    } catch is CancellationError {} catch { self?.stop(); self?.failure(error) }
                }
            }
        case .keyUp:
            pressed.removeValue(forKey: event.keyCode)
            if event.keyCode == UInt16(kVK_Escape) { escapeHold?.cancel(); escapeHold = nil }
        case .flagsChanged:
            let flag = Self.modifierKeys.first { $0.0 == Int(event.keyCode) }?.1
            if let flag, event.modifierFlags.contains(flag) { modifiers[event.keyCode] = event }
            else { modifiers.removeValue(forKey: event.keyCode) }
        default: return false
        }
        forward(event)
        return true
    }

    isolated deinit {
        stop()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}

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
    private var geometryBeforeFullScreen: (scale: CGFloat?, origin: NSPoint)?
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
        if scalesDisplay, let geometry = geometryBeforeFullScreen, geometry.scale == nil {
            // Keep the returning primary's scale before full-screen fitting overwrites it.
            geometryBeforeFullScreen = (display.renderScale, geometry.origin)
        }
        observe()
    }

    /// Whether the display fits the window instead of the window taking the
    /// display's size.
    var fitsWindow: Bool { isFullScreen || isLiveResizing }

    /// Gives the display the largest scale at which it fits the content.
    func fit() {
        content.isSizedToDisplay = false
        resize(to: content.availableDisplaySize)
        layout()
    }

    /// Applies the presentation policy to every explicit scale request.
    func setScale(_ scale: CGFloat) {
        display.setRenderScale(scalesDisplay ? scale : 1)
    }

    func resize(to size: NSSize) {
        if scalesDisplay { display.resize(to: size) } else { setScale(1) }
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
        geometryBeforeFullScreen = (scalesDisplay ? display.renderScale : nil, window.frame.origin)
    }

    func didFailToEnterFullScreen() {
        isFullScreen = false
        geometryBeforeFullScreen = nil
    }

    /// Leaves full screen, returning the display's scale and the window's
    /// origin from before it, which the window returns to.
    func didExitFullScreen(defaultScale: CGFloat) -> (scale: CGFloat, origin: NSPoint)? {
        isFullScreen = false
        defer { geometryBeforeFullScreen = nil }
        guard let geometry = geometryBeforeFullScreen else { return nil }
        return (geometry.scale ?? defaultScale, geometry.origin)
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
