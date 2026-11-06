import Foundation
import NeoSimulatorDeviceIO

/// A discovered device's stable identity. CoreDevice identifiers are command destinations; a simulator's UDID belongs to
/// one device set, so both are part of its identity. Every way of making one normalizes it as the device's I/O channel
/// does, so a value from a URL, preferences, or a catalog compares equal to the same device's other values.
public struct DeviceInventoryID: Hashable, Sendable, Codable {
    public enum Destination: Hashable, Sendable {
        case simulator(udid: String, deviceSetPath: String?)
        case coreDevice(String)
    }

    public let destination: Destination

    private init(destination: Destination) { self.destination = destination }

    public static func simulator(udid: String, deviceSetPath: String?) -> Self {
        let address = DeviceAddress(identifier: udid, deviceSetPath: deviceSetPath)
        return Self(destination: .simulator(udid: address.identifier, deviceSetPath: address.deviceSetPath))
    }

    public static func simulator(_ identifier: SimulatorDeviceIdentifier) -> Self {
        simulator(udid: identifier.identifier, deviceSetPath: identifier.deviceSetPath)
    }

    public static func coreDevice(_ identifier: String) -> Self { Self(destination: .coreDevice(identifier)) }

    private enum CodingKeys: String, CodingKey { case identifier, deviceSetPath, coreDeviceIdentifier }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let identifier = try values.decodeIfPresent(String.self, forKey: .coreDeviceIdentifier) {
            self = .coreDevice(identifier)
        } else {
            self = .simulator(udid: try values.decode(String.self, forKey: .identifier),
                              deviceSetPath: try values.decodeIfPresent(String.self, forKey: .deviceSetPath))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch destination {
        case .simulator(let identifier, let path):
            try values.encode(identifier, forKey: .identifier)
            try values.encodeIfPresent(path, forKey: .deviceSetPath)
        case .coreDevice(let identifier): try values.encode(identifier, forKey: .coreDeviceIdentifier)
        }
    }

    public var isSimulator: Bool {
        if case .simulator = destination { true } else { false }
    }

    /// The simulator this identifies, for the APIs that open and control one.
    public var simulatorIdentifier: SimulatorDeviceIdentifier? {
        guard case .simulator(let identifier, let path) = destination else { return nil }
        return SimulatorDeviceIdentifier(identifier, deviceSetPath: path)
    }

    package var sortKey: String {
        switch destination {
        case .simulator(let identifier, let path): "simulator:\(identifier):\(path ?? "")"
        case .coreDevice(let identifier): "coredevice:\(identifier)"
        }
    }

    package var simulatorAddress: (identifier: String, deviceSetPath: String?) {
        get throws {
            guard case .simulator(let identifier, let path) = destination else {
                throw CLIError.configuration("simulator-device", "Choose a simulator for this operation.")
            }
            return (identifier, path)
        }
    }
}

public enum DeviceInventoryKind: Equatable, Sendable {
    case simulator, physical, virtualMachine
    /// An observed CoreDevice reality that this client does not classify yet.
    case other(String)
}
