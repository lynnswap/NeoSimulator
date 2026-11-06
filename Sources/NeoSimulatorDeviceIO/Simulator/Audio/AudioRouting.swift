import Foundation

/// Audio routes use CoreAudio device UIDs or the system-default sentinel.
package enum AudioRouting {
    /// CoreSimDeviceIO's SimAudioHostUseSystemDefaultDeviceUID, checked at startup.
    package static let systemDefault = "__sim__hostUseSystemDefaultDeviceUID"

    package static let recentRouteLimit = 5
}

/// SimAudioDeviceScope values, also used as the isDefaultInScopes bitmask.
package enum AudioScope: UInt64, Sendable {
    case input = 1, output = 2

    package var noun: String { self == .input ? "input" : "output" }
}

package enum AudioRouteChange: Sendable {
    case availableDevices, selectedDevice
}

/// Host audio device reported by CoreSimDeviceIO.
package struct HostAudioDevice: Equatable {
    package var uid: String
    package var name: String
    package var inputChannels: Int
    package var outputChannels: Int
    /// Bitmask of AudioScope values for which this device is the host default.
    package var defaultScopes: UInt64

    package func isDefault(in scope: AudioScope) -> Bool { defaultScopes & scope.rawValue != 0 }
}

/// Result of selecting among recent routes.
package enum AudioRouteDecision: Equatable {
    case current
    case route(String)
    case unavailable
}

/// Audio-port snapshot.
package struct AudioRouteState: Equatable {
    /// In port order.
    package var devices: [HostAudioDevice]
    package var inputRoute: String?
    package var outputRoute: String?
    /// Effective host defaults reported by the port.
    package var defaultInput: String?
    package var defaultOutput: String?

    package func devices(in scope: AudioScope) -> [HostAudioDevice] {
        devices.filter { (scope == .input ? $0.inputChannels : $0.outputChannels) > 0 }
    }

    package func route(in scope: AudioScope) -> String? { scope == .input ? inputRoute : outputRoute }

    package func usesSystemDefault(in scope: AudioScope) -> Bool { route(in: scope) == AudioRouting.systemDefault }

    /// Uses the guest's route, falling back to the host default.
    package func selectedDevice(in scope: AudioScope) -> HostAudioDevice? {
        let devices = devices(in: scope)
        return devices.first { $0.uid == route(in: scope) } ?? devices.first { $0.isDefault(in: scope) }
    }

    package func defaultDevice(in scope: AudioScope) -> HostAudioDevice? {
        let uid = scope == .input ? defaultInput : defaultOutput
        return devices(in: scope).first { $0.uid == uid }
    }

    /// Uses the first recent route already selected or currently available.
    /// The system-default sentinel is available only with a default device in this scope.
    package func decision(among recent: [String], in scope: AudioScope) -> AudioRouteDecision {
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
