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

    static let legacy = ManagedPreferenceState(
        xcodeSession: .trueValue,
        deviceHubAutoStartSuppression: .trueValue
    )

    var effectiveMode: HostMode {
        xcodeSession == .trueValue ? .legacy : .deviceHub
    }

    var description: String {
        "Xcode=\(xcodeSession), DeviceHubAutoStartSuppression=\(deviceHubAutoStartSuppression)"
    }
}

enum HostMode: String, Codable, Equatable {
    case legacy
    case deviceHub = "device-hub"

    var targetState: ManagedPreferenceState {
        switch self {
        case .legacy:
            .legacy
        case .deviceHub:
            .deviceHub
        }
    }
}
