import Foundation
import NeoSimulatorDeviceIO

/// A discovered device's stable identity. CoreDevice identifiers are command destinations; a simulator's UDID belongs to
/// one device set, so both are part of its identity. Every way of making one normalizes it as the device's I/O channel
/// does, so a value from a URL, preferences, or a catalog compares equal to the same device's other values.
public struct DeviceInventoryID: Hashable, Sendable, Codable {
    /// Where a device's commands go.
    public enum Destination: Hashable, Sendable {
        /// A simulator, by its UDID and the path of its device set. A `nil` path means Xcode's default device set.
        case simulator(udid: String, deviceSetPath: String?)
        /// A device, by its CoreDevice identifier.
        case coreDevice(String)
    }

    /// Where this device's commands go.
    public let destination: Destination

    private init(destination: Destination) { self.destination = destination }

    /// Creates the identity of a simulator.
    ///
    /// - Parameters:
    ///   - udid: The simulator's UDID.
    ///   - deviceSetPath: The path of the simulator's device set, or `nil` for Xcode's default device set.
    /// - Returns: The identity, in normalized form.
    public static func simulator(udid: String, deviceSetPath: String?) -> Self {
        let address = DeviceAddress(identifier: udid, deviceSetPath: deviceSetPath)
        return Self(destination: .simulator(udid: address.identifier, deviceSetPath: address.deviceSetPath))
    }

    /// Creates the identity of a simulator from its identifier.
    ///
    /// - Parameter identifier: The simulator's identifier.
    /// - Returns: The identity, in normalized form.
    public static func simulator(_ identifier: SimulatorDeviceIdentifier) -> Self {
        simulator(udid: identifier.identifier, deviceSetPath: identifier.deviceSetPath)
    }

    /// Creates the identity of a device that CoreDevice lists.
    ///
    /// - Parameter identifier: The device's CoreDevice identifier.
    /// - Returns: The identity.
    public static func coreDevice(_ identifier: String) -> Self { Self(destination: .coreDevice(identifier)) }

    private enum CodingKeys: String, CodingKey { case identifier, deviceSetPath, coreDeviceIdentifier }

    /// Decodes an identity, normalizing it as ``simulator(udid:deviceSetPath:)`` does.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let identifier = try values.decodeIfPresent(String.self, forKey: .coreDeviceIdentifier) {
            self = .coreDevice(identifier)
        } else {
            self = .simulator(udid: try values.decode(String.self, forKey: .identifier),
                              deviceSetPath: try values.decodeIfPresent(String.self, forKey: .deviceSetPath))
        }
    }

    /// Encodes this identity.
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch destination {
        case .simulator(let identifier, let path):
            try values.encode(identifier, forKey: .identifier)
            try values.encodeIfPresent(path, forKey: .deviceSetPath)
        case .coreDevice(let identifier): try values.encode(identifier, forKey: .coreDeviceIdentifier)
        }
    }

    /// Whether this identifies a simulator.
    public var isSimulator: Bool {
        if case .simulator = destination { true } else { false }
    }

    /// The simulator this identifies, for the APIs that open and control one, or `nil` for a CoreDevice destination.
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
                throw DeviceDomainError.configuration("simulator-device", "Choose a simulator for this operation.")
            }
            return (identifier, path)
        }
    }
}

/// The kind of a discovered device.
public enum DeviceInventoryKind: Equatable, Sendable {
    /// A simulator.
    case simulator
    /// A physical device.
    case physical
    /// A virtual machine.
    case virtualMachine
    /// An observed CoreDevice reality that this client does not classify yet.
    case other(String)
}
