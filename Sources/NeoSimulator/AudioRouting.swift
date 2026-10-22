import Foundation

/// I/O ▸ Audio Input and Audio Output: which Mac audio device a guest's audio
/// input or output uses.
///
/// A route is a Mac device's unique identifier, as CoreAudio's
/// `kAudioDevicePropertyDeviceUID` gives it, or `systemDefault`, which
/// follows the Mac's default device.
enum AudioRouting {
    /// CoreSimDeviceIO's `SimAudioHostUseSystemDefaultDeviceUID`. Simulator.app
    /// also saves it in its recent routes. `SimulatorRuntime` checks the value
    /// at startup.
    static let systemDefault = "__sim__hostUseSystemDefaultDeviceUID"

    /// How many recent routes Simulator.app keeps for each direction.
    static let recentRouteLimit = 5

    /// Posted with the preference store as its object after a route is
    /// chosen; `scopeKey` holds the scope's raw value.
    static let didChangeNotification = Notification.Name("dev.lynnswap.NeoSimulator.AudioRouteDidChange")
    static let scopeKey = "scope"
}

/// `SimAudioDeviceScope`: the direction of a guest audio route. A Mac
/// device's `isDefaultInScopes` combines the directions it is the default for.
enum AudioScope: UInt64 {
    case input = 1, output = 2

    var noun: String { self == .input ? "input" : "output" }
}

/// A Mac audio device, as CoreSimDeviceIO's `SimAudioHostDevice` describes it.
struct HostAudioDevice: Equatable {
    /// `uniqueIdentifier`, the route to the device.
    var uid: String
    /// `displayName`, the title Simulator.app shows.
    var name: String
    var inputChannels: Int
    var outputChannels: Int
    /// `isDefaultInScopes`: the `AudioScope` raw values of the directions the
    /// device is the Mac's default for.
    var defaultScopes: UInt64

    func isDefault(in scope: AudioScope) -> Bool { defaultScopes & scope.rawValue != 0 }
}

/// What routing a direction to the app's preferred device needs.
enum AudioRouteDecision: Equatable {
    /// The guest already uses the most recent route that the Mac has.
    case current
    /// The guest is to use this route.
    case route(String)
    /// The Mac has none of the recent routes.
    case unavailable
}

/// A device's audio routes as its audio port reports them, read the way
/// Simulator.app's SimulatorKit audio client reads them.
struct AudioRouteState: Equatable {
    /// `availableHostDevices`, in the port's order.
    var devices: [HostAudioDevice]
    /// `guestInputHostDeviceUID` and `guestOutputHostDeviceUID`.
    var inputRoute: String?
    var outputRoute: String?
    /// `effectiveDefaultInputDeviceUID` and `effectiveDefaultOutputDeviceUID`,
    /// the Mac's default devices.
    var defaultInput: String?
    var defaultOutput: String?

    /// The devices with channels in `scope`, which its menu lists.
    func devices(in scope: AudioScope) -> [HostAudioDevice] {
        devices.filter { (scope == .input ? $0.inputChannels : $0.outputChannels) > 0 }
    }

    func route(in scope: AudioScope) -> String? { scope == .input ? inputRoute : outputRoute }

    /// Whether the guest follows the Mac's default device.
    func usesSystemDefault(in scope: AudioScope) -> Bool { route(in: scope) == AudioRouting.systemDefault }

    /// The device the guest uses, as SimulatorKit's audio client selects it:
    /// the device of the guest's route, or else the Mac's default device.
    func selectedDevice(in scope: AudioScope) -> HostAudioDevice? {
        let devices = devices(in: scope)
        return devices.first { $0.uid == route(in: scope) } ?? devices.first { $0.isDefault(in: scope) }
    }

    /// The Mac's default device, which the System item names.
    func defaultDevice(in scope: AudioScope) -> HostAudioDevice? {
        let uid = scope == .input ? defaultInput : defaultOutput
        return devices(in: scope).first { $0.uid == uid }
    }

    /// Simulator.app's synchronization of a direction with the app's recent
    /// routes, most recent first: the first one that the guest already uses
    /// or that the Mac has decides. System Default counts as present while a
    /// device is the Mac's default for the direction.
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
    /// The routes chosen for `scope`, most recent first, under Simulator.app's
    /// `RecentAudioInputDeviceUIDs` and `RecentAudioOutputDeviceUIDs`. Like
    /// Simulator.app, a missing or empty list, or one that is not of strings,
    /// is System Default alone.
    func recentAudioRoutes(in scope: AudioScope) -> [String] {
        if let routes = object(forKey: Self.recentAudioRoutesKey(scope)) as? [String], !routes.isEmpty { return routes }
        return [AudioRouting.systemDefault]
    }

    /// I/O ▸ Audio Input or Audio Output: puts `route` first in the recent
    /// routes, which keep each route once and at most
    /// `AudioRouting.recentRouteLimit`, then reports the change. Like
    /// Simulator.app, the choice applies to every device window.
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
