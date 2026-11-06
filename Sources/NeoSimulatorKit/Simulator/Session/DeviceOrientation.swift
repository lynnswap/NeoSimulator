import Foundation
import NeoSimulatorDeviceIO

/// A physical device orientation, named as `devicectl` names it.
package enum DeviceOrientation: String, CaseIterable {
    case portrait, landscapeRight, portraitUpsideDown, landscapeLeft, faceUp, faceDown

    /// Display rotation for an upright view of this orientation. Flat orientations keep the previous angle.
    package var displayAngle: Double? {
        switch self {
        case .portrait: 0
        case .landscapeLeft: 90
        case .portraitUpsideDown: 180
        case .landscapeRight: -90
        case .faceUp, .faceDown: nil
        }
    }
}

/// The device's orientation and the display angle that follows it.
package struct OrientationReading: Equatable {
    package var physical: DeviceOrientation
    /// The angle of the last upright orientation, kept while the device is flat.
    package var displayAngle: Double

    /// Reads the JSON output of `devicectl device orientation get`.
    package init(devicectlOutput data: Data) throws {
        struct Output: Decodable {
            struct Result: Decodable {
                var deviceOrientation: String
                var deviceOrientationNonFlat: String
            }
            var result: Result
        }
        let result = try JSONDecoder().decode(Output.self, from: data).result
        try self.init(physical: result.deviceOrientation, nonFlat: result.deviceOrientationNonFlat)
    }

    package init(_ guest: GuestOrientationReading) throws {
        try self.init(physical: guest.physical, nonFlat: guest.nonFlat)
    }

    package init(physical: String, nonFlat: String) throws {
        guard let upright = DeviceOrientation(rawValue: nonFlat),
              let angle = upright.displayAngle else {
            throw DeviceDomainError.io("device-orientation", "Unsupported orientation: \(nonFlat)")
        }
        // Before an orientation is set, devicectl reports `unknown` for the
        // physical orientation; the device is then upright.
        self.physical = DeviceOrientation(rawValue: physical) ?? upright
        displayAngle = angle
    }
}
