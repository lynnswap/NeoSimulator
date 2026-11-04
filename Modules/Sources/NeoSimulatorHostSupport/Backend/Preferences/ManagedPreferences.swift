import NeoSimulatorKit
import Foundation

package struct ManagedPreference: Equatable, Hashable {
    package let domain: String
    package let key: String
}

package enum StoredBoolean: String, Codable, Equatable, CustomStringConvertible {
    case absent
    case falseValue = "false"
    case trueValue = "true"

    package init(_ value: Bool) {
        self = value ? .trueValue : .falseValue
    }

    package var booleanValue: Bool? {
        switch self {
        case .absent:
            nil
        case .falseValue:
            false
        case .trueValue:
            true
        }
    }

    package var description: String {
        rawValue
    }
}

package struct ManagedPreferenceState: Codable, Equatable, CustomStringConvertible {
    package let xcodeSession: StoredBoolean
    package let deviceHubAutoStartSuppression: StoredBoolean

    package static let deviceHub = ManagedPreferenceState(
        xcodeSession: .absent,
        deviceHubAutoStartSuppression: .absent
    )

    package static let coreSimulator = ManagedPreferenceState(
        xcodeSession: .trueValue,
        deviceHubAutoStartSuppression: .trueValue
    )

    package var effectiveRoute: SimulatorRoute {
        xcodeSession == .trueValue ? .coreSimulator : .deviceHub
    }

    package var description: String {
        "Xcode=\(xcodeSession), DeviceHubAutoStartSuppression=\(deviceHubAutoStartSuppression)"
    }
}

package enum SimulatorRoute: Equatable {
    case coreSimulator
    case deviceHub
}

package enum SimulatorHost: String, CaseIterable, Sendable {
    case neo
    case deviceHub = "device-hub"

    package var targetState: ManagedPreferenceState {
        switch self {
        case .neo: .coreSimulator
        case .deviceHub: .deviceHub
        }
    }
}
