import Foundation

/// Where preferences are kept: the app's user defaults, or a test's own store.
package protocol PreferenceStore: AnyObject {
    func object(forKey defaultName: String) -> Any?
    /// The value as `UserDefaults.bool(forKey:)` reads it.
    func bool(forKey defaultName: String) -> Bool
    func set(_ value: Any?, forKey defaultName: String)
}

extension UserDefaults: PreferenceStore {}

extension PreferenceStore {
    /// ShowChrome defaults on and uses UserDefaults Boolean coercion.
    package var showsDeviceBezels: Bool {
        object(forKey: HostPreferences.showChrome) == nil || bool(forKey: HostPreferences.showChrome)
    }

    /// Reads an independent record, falling back to the previous shared dictionary.
    package func preferences(forDevice identifier: String) -> [String: Any]? {
        object(forKey: devicePreferencesKey(for: identifier)) as? [String: Any]
            ?? (object(forKey: HostPreferences.devicePreferences) as? [String: Any])?[identifier] as? [String: Any]
    }

    /// Each renderer owns its devices; separate keys prevent another renderer's save
    /// from replacing this device's record. The legacy dictionary remains read-only.
    package func updatePreferences(forDevice identifier: String, _ change: (inout [String: Any]) -> Void) {
        var device = preferences(forDevice: identifier) ?? [:]
        change(&device)
        set(device, forKey: devicePreferencesKey(for: identifier))
    }

    private func devicePreferencesKey(for identifier: String) -> String {
        "\(HostPreferences.devicePreferences).\(identifier)"
    }
}

/// Simulator-compatible keyboard and touch-pressure preferences; defaults are on.
extension PreferenceStore {
    /// Use the Same Keyboard Language as macOS: the app-wide `EnableKeyboardSync`.
    package var syncsKeyboardLanguage: Bool { isOn(HostPreferences.enableKeyboardSync) }

    /// Per-device Boolean choice, falling back to the app-wide preference.
    package func connectsHardwareKeyboard(forDevice identifier: String) -> Bool {
        preferences(forDevice: identifier)?[HostPreferences.connectHardwareKeyboard] as? Bool
            ?? isOn(HostPreferences.connectHardwareKeyboard)
    }

    package func setConnectsHardwareKeyboard(_ connects: Bool, forDevice identifier: String) {
        updatePreferences(forDevice: identifier) { $0[HostPreferences.connectHardwareKeyboard] = connects }
    }

    /// Use Trackpad Force's app-wide `UseTrackpadForce`, which applies only
    /// with a Force Touch trackpad.
    package var prefersTrackpadForce: Bool { isOn(HostPreferences.useTrackpadForce) }

    fileprivate func isOn(_ key: String) -> Bool { object(forKey: key) == nil || bool(forKey: key) }
}

extension PreferenceStore {
    /// Pinch indicators default on; others default off. Uses UserDefaults Boolean coercion.
    package func showsTouchIndicator(_ indicator: TouchIndicator) -> Bool {
        let key = indicator.preferenceKey
        return indicator == .pinches ? isOn(key) : bool(forKey: key)
    }
}
