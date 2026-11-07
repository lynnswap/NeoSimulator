import Foundation
import NeoSimulatorDeviceIO

/// A simulator belongs to one device set; a UDID alone is not a session key.
public struct SimulatorDeviceIdentifier: Hashable, Codable, Sendable, Comparable {
    public let identifier: String
    public let deviceSetPath: String?
    public init(_ identifier: String, deviceSetPath: String? = nil) {
        self.identifier = identifier
        self.deviceSetPath = deviceSetPath.map(DeviceAddress.normalized(path:))
    }
    package var queryItems: [URLQueryItem] {
        [URLQueryItem(name: "udid", value: identifier)]
            + (deviceSetPath.map { [URLQueryItem(name: "deviceSetPath", value: $0)] } ?? [])
    }
    package var preferenceIdentifier: String {
        guard let path = deviceSetPath else { return identifier }
        return "set:\(path.utf8.count):\(path):\(identifier)"
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.preferenceIdentifier < rhs.preferenceIdentifier }
}

extension SimulatorDevice {
    package var identity: SimulatorDeviceIdentifier { SimulatorDeviceIdentifier(identifier, deviceSetPath: deviceSetPath) }
}

extension SimulatorDeviceRecord {
    package var identity: SimulatorDeviceIdentifier { SimulatorDeviceIdentifier(identifier, deviceSetPath: deviceSetPath) }
}

package struct AvailableDevice: Identifiable {
    package let identifier: String
    package let deviceSetPath: String?
    package var identity: SimulatorDeviceIdentifier { SimulatorDeviceIdentifier(identifier, deviceSetPath: deviceSetPath) }
    package let name: String
    package let descriptiveName: String
    package let runtimeIdentifier: String
    package let runtimeName: String
    /// `SimDeviceType.productFamilyID`, as in `SimulatorDevice.productFamily`.
    package let productFamily: Int
    package let deviceTypeName: String
    package var state: UInt
    package let lastBootDate: Date?
    package var id: String { identifier }
    package var isBooted: Bool { state == 3 }
    /// The SF Symbol of the device's product family.
    package var symbolName: String {
        switch DeviceCapabilities.Family(rawValue: productFamily) {
        case .iPad: "ipad"
        case .tv: "appletv"
        case .watch: "applewatch"
        case .vision: "visionpro"
        case .iPhone, nil: "iphone"
        }
    }
    package var canOpen: Bool { state == 1 || state == 3 }
    package var stateLabel: String {
        switch state {
        case 1: "Shut Down"
        case 2: "Starting…"
        case 3: "Running"
        case 4: "Shutting Down…"
        default: "Unavailable"
        }
    }

    package init(identifier: String, name: String, descriptiveName: String, runtimeIdentifier: String,
         runtimeName: String, productFamily: Int, deviceTypeName: String, state: UInt, deviceSetPath: String? = nil, lastBootDate: Date? = nil) {
        self.identifier = identifier
        self.deviceSetPath = deviceSetPath
        self.name = name
        self.descriptiveName = descriptiveName
        self.runtimeIdentifier = runtimeIdentifier
        self.runtimeName = runtimeName
        self.productFamily = productFamily
        self.deviceTypeName = deviceTypeName
        self.state = state
        self.lastBootDate = lastBootDate
    }
}
