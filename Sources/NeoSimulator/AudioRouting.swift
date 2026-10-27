import Foundation

/// Audio routes use CoreAudio device UIDs or the system-default sentinel.
enum AudioRouting {
    /// CoreSimDeviceIO's SimAudioHostUseSystemDefaultDeviceUID, checked at startup.
    static let systemDefault = "__sim__hostUseSystemDefaultDeviceUID"

    static let recentRouteLimit = 5

    /// Posted with the preference store and the changed scope's raw value under `scopeKey`.
    static let didChangeNotification = Notification.Name("dev.lynnswap.NeoSimulator.AudioRouteDidChange")
    static let scopeKey = "scope"
}

/// SimAudioDeviceScope values, also used as the isDefaultInScopes bitmask.
enum AudioScope: UInt64 {
    case input = 1, output = 2

    var noun: String { self == .input ? "input" : "output" }
}

enum AudioRouteChange: Sendable {
    case availableDevices, selectedDevice
}

/// Host audio device reported by CoreSimDeviceIO.
struct HostAudioDevice: Equatable {
    var uid: String
    var name: String
    var inputChannels: Int
    var outputChannels: Int
    /// Bitmask of AudioScope values for which this device is the host default.
    var defaultScopes: UInt64

    func isDefault(in scope: AudioScope) -> Bool { defaultScopes & scope.rawValue != 0 }
}

/// Result of selecting among recent routes.
enum AudioRouteDecision: Equatable {
    case current
    case route(String)
    case unavailable
}

/// Audio-port snapshot.
struct AudioRouteState: Equatable {
    /// In port order.
    var devices: [HostAudioDevice]
    var inputRoute: String?
    var outputRoute: String?
    /// Effective host defaults reported by the port.
    var defaultInput: String?
    var defaultOutput: String?

    func devices(in scope: AudioScope) -> [HostAudioDevice] {
        devices.filter { (scope == .input ? $0.inputChannels : $0.outputChannels) > 0 }
    }

    func route(in scope: AudioScope) -> String? { scope == .input ? inputRoute : outputRoute }

    func usesSystemDefault(in scope: AudioScope) -> Bool { route(in: scope) == AudioRouting.systemDefault }

    /// Uses the guest's route, falling back to the host default.
    func selectedDevice(in scope: AudioScope) -> HostAudioDevice? {
        let devices = devices(in: scope)
        return devices.first { $0.uid == route(in: scope) } ?? devices.first { $0.isDefault(in: scope) }
    }

    func defaultDevice(in scope: AudioScope) -> HostAudioDevice? {
        let uid = scope == .input ? defaultInput : defaultOutput
        return devices(in: scope).first { $0.uid == uid }
    }

    /// Uses the first recent route already selected or currently available.
    /// The system-default sentinel is available only with a default device in this scope.
    func decision(among recent: [String], in scope: AudioScope) -> AudioRouteDecision {
        let usesSystemDefault = usesSystemDefault(in: scope)
        let selected = selectedDevice(in: scope)?.uid
        let devices = devices(in: scope)
        for route in recent {
            if route == AudioRouting.systemDefault {
                if usesSystemDefault { return .current }
                if devices.contains(where: { $0.isDefault(in: scope) }) { return .route(route) }
            } else {
                if !usesSystemDefault && selected == route { return .current }
                if devices.contains(where: { $0.uid == route }) { return .route(route) }
            }
        }
        return .unavailable
    }
}

extension PreferenceStore {
    /// Per-device routes share the manager's defaults domain, including when the renderer reconnects.
    private func deviceAudioPreferences() throws -> any PreferenceStore {
        guard self is UserDefaults else { return self }
        guard let defaults = HostPreferences.deviceSettingsDefaults, defaults.synchronize() else {
            throw HostError.operation("Could not read the saved simulator audio route.")
        }
        return defaults
    }

    func preferredAudioRoutes(forDevice identifier: String, in scope: AudioScope) throws -> [String] {
        let saved = try deviceAudioPreferences().object(forKey: Self.deviceAudioRouteKey(identifier, scope)) as? String
        let route = saved == "systemDefault" ? AudioRouting.systemDefault : saved
        guard let route else { return recentAudioRoutes(in: scope) }
        return [route] + recentAudioRoutes(in: scope).filter { $0 != route }
    }

    func saveAudioRoute(_ route: String, forDevice identifier: String, in scope: AudioScope) throws {
        let store = try deviceAudioPreferences()
        store.set(route == AudioRouting.systemDefault ? "systemDefault" : route,
                  forKey: Self.deviceAudioRouteKey(identifier, scope))
        if let defaults = store as? UserDefaults, !defaults.synchronize() {
            throw HostError.operation("Could not save the simulator audio route for the next connection.")
        }
    }

    private static func deviceAudioRouteKey(_ identifier: String, _ scope: AudioScope) -> String {
        "DeviceAudioRoute.\(identifier).\(scope.noun)"
    }

    /// Most-recent-first routes; missing, empty, or malformed preferences mean System Default.
    func recentAudioRoutes(in scope: AudioScope) -> [String] {
        if let routes = object(forKey: Self.recentAudioRoutesKey(scope)) as? [String], !routes.isEmpty { return routes }
        return [AudioRouting.systemDefault]
    }

    /// Saves a unique, bounded recent-route list and notifies every device window.
    func chooseAudioRoute(_ route: String, in scope: AudioScope) {
        var seen = Set<String>()
        let routes = ([route] + recentAudioRoutes(in: scope)).filter { seen.insert($0).inserted }
        set(Array(routes.prefix(AudioRouting.recentRouteLimit)), forKey: Self.recentAudioRoutesKey(scope))
        NotificationCenter.default.post(name: AudioRouting.didChangeNotification, object: self,
                                        userInfo: [AudioRouting.scopeKey: scope.rawValue])
    }

    private static func recentAudioRoutesKey(_ scope: AudioScope) -> String {
        scope == .input ? HostPreferences.recentAudioInputDeviceUIDs : HostPreferences.recentAudioOutputDeviceUIDs
    }
}
