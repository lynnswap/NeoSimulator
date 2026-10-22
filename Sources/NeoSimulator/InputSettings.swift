import AppKit
import Carbon
import IOKit
import IOKit.hidsystem

/// I/O ▸ Keyboard's and I/O ▸ Touch Pressure's preferences, under
/// Simulator.app's keys. Like `showsDeviceBezels`, each is on unless it was
/// turned off, as its registered default says.
extension PreferenceStore {
    /// Use the Same Keyboard Language as macOS: the app-wide `EnableKeyboardSync`.
    var syncsKeyboardLanguage: Bool { isOn(HostPreferences.enableKeyboardSync) }

    /// Connect Hardware Keyboard for a device: its own choice,
    /// `DevicePreferences[UDID].ConnectHardwareKeyboard`, which Simulator.app's
    /// command saves and its checkmark shows, or else the app-wide
    /// `ConnectHardwareKeyboard`. A choice that is not a Boolean, which
    /// Simulator.app also ignores, counts as none.
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
    /// Whether the Mac has one, found as Simulator.app finds it: a HID
    /// service of a multiple-point digitizer whose registry entry says
    /// `ForceSupported`.
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

/// I/O ▸ Touch Pressure's app-wide settings, which Simulator.app's app
/// delegate keeps and applies to the window of every device that takes
/// touch pressure. Each window applies them when its display connects and
/// when `didChangeNotification` reports a change.
@MainActor
final class TouchPressure {
    /// Posted with the settings as its object after Use Trackpad Force or
    /// the touch mode changes.
    static let didChangeNotification = Notification.Name("dev.lynnswap.NeoSimulator.TouchPressureDidChange")

    private let preferences: any PreferenceStore
    private let findsForceTouchTrackpad: () -> Bool
    /// Shallow Press or Deep Press. Like Simulator.app, the app keeps it
    /// only while it runs, starting with Shallow Press.
    private(set) var mode = SimulatedTouchMode.shallow

    /// - Parameter forceTouchTrackpad: Whether the Mac has a Force Touch
    ///   trackpad. Like Simulator.app, it is asked each time, so a trackpad
    ///   connected later counts.
    init(preferences: any PreferenceStore = UserDefaults.standard,
         forceTouchTrackpad: @escaping () -> Bool = ForceTouchTrackpad.isAvailable) {
        self.preferences = preferences
        findsForceTouchTrackpad = forceTouchTrackpad
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
