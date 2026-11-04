import AppKit
import Carbon
import IOKit
import IOKit.hidsystem

/// Simulator-compatible keyboard and touch-pressure preferences; defaults are on.
extension PreferenceStore {
    /// Use the Same Keyboard Language as macOS: the app-wide `EnableKeyboardSync`.
    var syncsKeyboardLanguage: Bool { isOn(HostPreferences.enableKeyboardSync) }

    /// Per-device Boolean choice, falling back to the app-wide preference.
    func connectsHardwareKeyboard(forDevice identifier: String) -> Bool {
        preferences(forDevice: identifier)?[HostPreferences.connectHardwareKeyboard] as? Bool
            ?? isOn(HostPreferences.connectHardwareKeyboard)
    }

    func setConnectsHardwareKeyboard(_ connects: Bool, forDevice identifier: String) {
        updatePreferences(forDevice: identifier) { $0[HostPreferences.connectHardwareKeyboard] = connects }
    }

    /// Use Trackpad Force's app-wide `UseTrackpadForce`, which applies only
    /// with a Force Touch trackpad.
    var prefersTrackpadForce: Bool { isOn(HostPreferences.useTrackpadForce) }

    private func isOn(_ key: String) -> Bool { object(forKey: key) == nil || bool(forKey: key) }
}

/// The Mac's keyboard, as Simulator.app reads it for the guest's keyboard.
enum HostKeyboard {
    /// The first language of the current keyboard input source, such as `en`
    /// for ABC or `ja` for Japanese, or nil when it lists none.
    @MainActor
    static func language() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let languages = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages)
        else { return nil }
        return (Unmanaged<CFArray>.fromOpaque(languages).takeUnretainedValue() as? [String])?.first
    }
}

/// The Mac's Force Touch trackpad, which Use Trackpad Force needs.
enum ForceTouchTrackpad {
    /// Finds a multi-point HID digitizer whose registry entry has ForceSupported.
    static func isAvailable() -> Bool {
        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []
        return services.contains { service in
            func property(_ key: String) -> Int? { IOHIDServiceClientCopyProperty(service, key as CFString) as? Int }
            guard property(kIOHIDPrimaryUsagePageKey) == kHIDPage_Digitizer,
                  property(kIOHIDPrimaryUsageKey) == kHIDUsage_Dig_MultiplePointDigitizer,
                  let identifier = (IOHIDServiceClientGetRegistryID(service) as? NSNumber)?.uint64Value
            else { return false }
            let entry = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(identifier))
            guard entry != IO_OBJECT_NULL else { return false }
            defer { IOObjectRelease(entry) }
            let supported = IORegistryEntryCreateCFProperty(entry, "ForceSupported" as CFString, kCFAllocatorDefault, 0)
            return supported?.takeRetainedValue() as? Bool == true
        }
    }
}

extension ForceTouchTrackpad {
    /// Calls `changed` on the main thread after a HID event service, such as
    /// a trackpad, appears or goes away, until the returned object is released.
    static func observeChanges(_ changed: @escaping @MainActor () -> Void) -> AnyObject? {
        HIDEventServiceObserver(changed)
    }
}

/// Repeats notifications after a delay because the HID service list lags the I/O Registry.
private final class HIDEventServiceObserver {
    private let port: IONotificationPortRef
    private var iterators: [io_iterator_t] = []
    private let changed: @MainActor () -> Void

    init?(_ changed: @escaping @MainActor () -> Void) {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return nil }
        self.port = port
        self.changed = changed
        IONotificationPortSetDispatchQueue(port, .main)
        let observer = Unmanaged.passUnretained(self).toOpaque()
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator = io_iterator_t()
            let result = IOServiceAddMatchingNotification(port, type, IOServiceMatching("IOHIDEventService"), { observer, iterator in
                HIDEventServiceObserver.drain(iterator)
                guard let observer else { return }
                Unmanaged<HIDEventServiceObserver>.fromOpaque(observer).takeUnretainedValue().report()
            }, observer, &iterator)
            guard result == KERN_SUCCESS else { continue }
            // Draining the iterator arms its notification.
            Self.drain(iterator)
            iterators.append(iterator)
        }
    }

    deinit {
        iterators.forEach { IOObjectRelease($0) }
        IONotificationPortDestroy(port)
    }

    private func report() {
        let changed = changed
        MainActor.assumeIsolated { changed() }
        for delay in [0.5, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { changed() } }
        }
    }

    private static func drain(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL { IOObjectRelease(service) }
    }
}

/// App-wide touch-pressure settings, applied on connection and change notifications.
@MainActor
final class TouchPressure {
    /// Posted with the settings as its object after Use Trackpad Force or
    /// the touch mode changes.
    static let didChangeNotification = Notification.Name("dev.lynnswap.NeoSimulator.TouchPressureDidChange")

    private let preferences: any PreferenceStore
    private let findsForceTouchTrackpad: () -> Bool
    private var trackpadObservation: AnyObject?
    /// Whether the Mac had a Force Touch trackpad when trackpads last changed.
    private var hadForceTouchTrackpad = false
    /// Shallow Press or Deep Press. Like Simulator.app, the app keeps it
    /// only while it runs, starting with Shallow Press.
    private(set) var mode = SimulatedTouchMode.shallow

    /// Rechecks trackpad availability and reapplies settings after hot-plug changes.
    init(preferences: any PreferenceStore = HostPreferences.defaults,
         forceTouchTrackpad: @escaping () -> Bool = ForceTouchTrackpad.isAvailable,
         observeTrackpads: (@escaping @MainActor () -> Void) -> AnyObject? = ForceTouchTrackpad.observeChanges) {
        self.preferences = preferences
        findsForceTouchTrackpad = forceTouchTrackpad
        hadForceTouchTrackpad = forceTouchTrackpad()
        trackpadObservation = observeTrackpads { [weak self] in self?.trackpadsChanged() }
    }

    private func trackpadsChanged() {
        let has = hasForceTouchTrackpad
        guard has != hadForceTouchTrackpad else { return }
        hadForceTouchTrackpad = has
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    var hasForceTouchTrackpad: Bool { findsForceTouchTrackpad() }

    /// Use Trackpad Force's checkmark and the value windows apply: the
    /// preference, with a Force Touch trackpad.
    var usesTrackpadForce: Bool { preferences.prefersTrackpadForce && hasForceTouchTrackpad }

    /// Use Trackpad Force: like Simulator.app, saves the opposite of what the
    /// checkmark shows.
    func toggleTrackpadForce() {
        preferences.set(!usesTrackpadForce, forKey: HostPreferences.useTrackpadForce)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    /// Shallow Press or Deep Press.
    func setMode(_ mode: SimulatedTouchMode) {
        self.mode = mode
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}

/// SimulatorKit touch-indicator options backed by Simulator.app preferences.
/// Pinch pivot and edge indicators remain configurable through defaults write.
enum TouchIndicator: CaseIterable {
    /// `.normalTouch`: where the pointer touches the screen.
    case singleTouches
    /// `.pinchTouches`: the two touches of an Option-drag pinch.
    case pinches
    /// `.pinchPivotPoint`: the pivot point of a pinch.
    case pinchPivotPoint
    /// `.edgeGestures`: Highlight Edge Gestures.
    case edgeGestures

    var preferenceKey: String {
        switch self {
        case .singleTouches: HostPreferences.showSingleTouches
        case .pinches: HostPreferences.showPinches
        case .pinchPivotPoint: HostPreferences.showPinchPivotPoint
        case .edgeGestures: HostPreferences.highlightEdgeGestures
        }
    }

    /// Posted, with the preference store as its object, after a touch
    /// indicator's preference changes.
    static let didChangeNotification = Notification.Name("dev.lynnswap.NeoSimulator.TouchIndicatorsDidChange")
}

extension PreferenceStore {
    /// Pinch indicators default on; others default off. Uses UserDefaults Boolean coercion.
    func showsTouchIndicator(_ indicator: TouchIndicator) -> Bool {
        let key = indicator.preferenceKey
        return indicator == .pinches ? isOn(key) : bool(forKey: key)
    }
}

/// Observes keys on the main actor until released. KVO includes external defaults writes
/// that UserDefaults.didChangeNotification omits.
final class DefaultsObservation: NSObject {
    private let defaults: UserDefaults
    private let keys: [String]
    private let changed: @MainActor () -> Void

    init(_ defaults: UserDefaults, keys: [String], changed: @escaping @MainActor () -> Void) {
        self.defaults = defaults
        self.keys = keys
        self.changed = changed
        super.init()
        for key in keys { defaults.addObserver(self, forKeyPath: key, context: nil) }
    }

    deinit {
        for key in keys { defaults.removeObserver(self, forKeyPath: key) }
    }

    // A change in this process arrives on the thread that made it, and one
    // from another process on a thread of its own.
    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        let changed = changed
        if Thread.isMainThread {
            MainActor.assumeIsolated { changed() }
        } else {
            DispatchQueue.main.async { changed() }
        }
    }
}
