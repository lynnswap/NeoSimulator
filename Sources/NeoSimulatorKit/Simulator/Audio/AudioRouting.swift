import Foundation
import NeoSimulatorDeviceIO

extension PreferenceStore {
    /// Per-device routes share the manager's defaults domain, including when the renderer reconnects.
    private func deviceAudioPreferences() throws -> any PreferenceStore {
        guard self is UserDefaults else { return self }
        guard let defaults = HostPreferences.deviceSettingsDefaults, defaults.synchronize() else {
            throw SimulatorError.operation("Could not read the saved simulator audio route.")
        }
        return defaults
    }

    package func preferredAudioRoutes(forDevice identifier: String, in scope: AudioScope) throws -> [String] {
        let saved = try deviceAudioPreferences().object(forKey: Self.deviceAudioRouteKey(identifier, scope)) as? String
        let route = saved == "systemDefault" ? AudioRouting.systemDefault : saved
        guard let route else { return recentAudioRoutes(in: scope) }
        return [route] + recentAudioRoutes(in: scope).filter { $0 != route }
    }

    package func saveAudioRoute(_ route: String, forDevice identifier: String, in scope: AudioScope) throws {
        let store = try deviceAudioPreferences()
        store.set(route == AudioRouting.systemDefault ? "systemDefault" : route,
                  forKey: Self.deviceAudioRouteKey(identifier, scope))
        if let defaults = store as? UserDefaults, !defaults.synchronize() {
            throw SimulatorError.operation("Could not save the simulator audio route for the next connection.")
        }
    }

    private static func deviceAudioRouteKey(_ identifier: String, _ scope: AudioScope) -> String {
        "DeviceAudioRoute.\(identifier).\(scope.noun)"
    }

    /// Most-recent-first routes; missing, empty, or malformed preferences mean System Default.
    package func recentAudioRoutes(in scope: AudioScope) -> [String] {
        if let routes = object(forKey: Self.recentAudioRoutesKey(scope)) as? [String], !routes.isEmpty { return routes }
        return [AudioRouting.systemDefault]
    }

    /// Saves a unique, bounded recent-route list and notifies every device window.
    package func chooseAudioRoute(_ route: String, in scope: AudioScope) {
        var seen = Set<String>()
        let routes = ([route] + recentAudioRoutes(in: scope)).filter { seen.insert($0).inserted }
        set(Array(routes.prefix(AudioRouting.recentRouteLimit)), forKey: Self.recentAudioRoutesKey(scope))
        NotificationCenter.default.post(name: AudioRouteChoice.didChangeNotification, object: self,
                                        userInfo: [AudioRouteChoice.scopeKey: scope.rawValue])
    }

    private static func recentAudioRoutesKey(_ scope: AudioScope) -> String {
        scope == .input ? HostPreferences.recentAudioInputDeviceUIDs : HostPreferences.recentAudioOutputDeviceUIDs
    }
}

/// That the app chose a new audio route, for every open device to take up through its session.
package struct AudioRouteChoice: Sendable {
    /// Posted with the preference store and the changed scope's raw value under `scopeKey`.
    fileprivate static let didChangeNotification = Notification.Name("dev.lynnswap.NeoSimulator.AudioRouteDidChange")
    fileprivate static let scopeKey = "scope"
    package let scope: AudioScope

    /// Reports each route that `preferences` saves as the app's choice on the main actor, until the observer is removed.
    package static func observe(in preferences: any PreferenceStore,
                                _ chosen: @escaping @MainActor (AudioRouteChoice) -> Void) -> any NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: didChangeNotification, object: preferences, queue: .main) { notification in
            let scope = (notification.userInfo?[scopeKey] as? UInt64).flatMap(AudioScope.init(rawValue:))
            MainActor.assumeIsolated { if let scope { chosen(AudioRouteChoice(scope: scope)) } }
        }
    }
}
