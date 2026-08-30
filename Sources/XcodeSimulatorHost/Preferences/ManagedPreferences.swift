import Foundation

struct ManagedPreference: Equatable, Hashable {
    let domain: String
    let key: String
}

enum StoredBoolean: String, Codable, Equatable, CustomStringConvertible {
    case absent
    case falseValue = "false"
    case trueValue = "true"

    init(_ value: Bool) {
        self = value ? .trueValue : .falseValue
    }

    var booleanValue: Bool? {
        switch self {
        case .absent:
            nil
        case .falseValue:
            false
        case .trueValue:
            true
        }
    }

    var description: String {
        rawValue
    }
}

struct ManagedPreferenceState: Codable, Equatable, CustomStringConvertible {
    let xcodeSession: StoredBoolean
    let deviceHubAutoStartSuppression: StoredBoolean

    static let deviceHub = ManagedPreferenceState(
        xcodeSession: .absent,
        deviceHubAutoStartSuppression: .absent
    )

    static let coreSimulator = ManagedPreferenceState(
        xcodeSession: .trueValue,
        deviceHubAutoStartSuppression: .trueValue
    )

    var effectiveRoute: SimulatorRoute {
        xcodeSession == .trueValue ? .coreSimulator : .deviceHub
    }

    var description: String {
        "Xcode=\(xcodeSession), DeviceHubAutoStartSuppression=\(deviceHubAutoStartSuppression)"
    }
}

enum SimulatorRoute: Equatable {
    case coreSimulator
    case deviceHub
}

enum HostMode: String, Codable, Equatable {
    case neo
    case legacy
    case deviceHub = "device-hub"

    var targetState: ManagedPreferenceState {
        switch self {
        case .neo, .legacy:
            .coreSimulator
        case .deviceHub:
            .deviceHub
        }
    }
}

enum HostRequest: Equatable {
    case neo
    case legacy(xcodeURL: URL?)
    case deviceHub
}
