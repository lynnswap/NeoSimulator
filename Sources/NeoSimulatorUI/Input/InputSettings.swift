import AppKit
import Carbon
import IOKit
import IOKit.hidsystem
import NeoSimulatorKit
import NeoSimulatorPresentationAdapters

/// The Mac's keyboard, as Simulator.app reads it for the guest's keyboard.
package enum HostKeyboard {
    /// The first language of the current keyboard input source, such as `en`
    /// for ABC or `ja` for Japanese, or nil when it lists none.
    @MainActor
    package static func language() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let languages = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages)
        else { return nil }
        return (Unmanaged<CFArray>.fromOpaque(languages).takeUnretainedValue() as? [String])?.first
    }
}

/// The Mac's Force Touch trackpad, which Use Trackpad Force needs.
package enum ForceTouchTrackpad {
    /// Finds a multi-point HID digitizer whose registry entry has ForceSupported.
    package static func isAvailable() -> Bool {
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
    package static func observeChanges(_ changed: @escaping @MainActor () -> Void) -> AnyObject? {
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
package final class TouchPressure {
    /// Posted with the settings as its object after Use Trackpad Force or
    /// the touch mode changes.
    package static let didChangeNotification = Notification.Name("dev.lynnswap.NeoSimulator.TouchPressureDidChange")

    private let preferences: any PreferenceStore
    private let findsForceTouchTrackpad: () -> Bool
    private var trackpadObservation: AnyObject?
    /// Whether the Mac had a Force Touch trackpad when trackpads last changed.
    private var hadForceTouchTrackpad = false
    /// Shallow Press or Deep Press. Like Simulator.app, the app keeps it
    /// only while it runs, starting with Shallow Press.
    package private(set) var mode = SimulatedTouchMode.shallow

    /// Rechecks trackpad availability and reapplies settings after hot-plug changes.
    package init(preferences: any PreferenceStore = HostPreferences.defaults,
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

    package var hasForceTouchTrackpad: Bool { findsForceTouchTrackpad() }

    /// Use Trackpad Force's checkmark and the value windows apply: the
    /// preference, with a Force Touch trackpad.
    package var usesTrackpadForce: Bool { preferences.prefersTrackpadForce && hasForceTouchTrackpad }

    /// Use Trackpad Force: like Simulator.app, saves the opposite of what the
    /// checkmark shows.
    package func toggleTrackpadForce() {
        preferences.set(!usesTrackpadForce, forKey: HostPreferences.useTrackpadForce)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    /// Shallow Press or Deep Press.
    package func setMode(_ mode: SimulatedTouchMode) {
        self.mode = mode
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}
