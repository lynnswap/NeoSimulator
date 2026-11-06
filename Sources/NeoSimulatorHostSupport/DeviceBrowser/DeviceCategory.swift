import NeoSimulatorDeviceIO
import NeoSimulatorKit

private let iPhoneDuoDeviceType = "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo"
private let iPhoneDuoModel = "iPhone19,4"

/// How device pickers group creatable devices. iPhone Duo has its own category because its runtimes
/// differ from other iPhones'; capability and pairing decisions keep using its native iPhone family.
package struct DeviceCategory: RawRepresentable, Hashable, Sendable {
    package static let iPhone = Self(productFamily: 1)
    package static let iPhoneDuo = Self(rawValue: "iPhoneDuo")
    package static let iPad = Self(productFamily: 2)
    package static let appleTV = Self(productFamily: 3)
    package static let appleWatch = Self(productFamily: 4)
    package static let appleVision = Self(productFamily: 7)

    /// The form saved in preferences.
    package let rawValue: String

    package init(rawValue: String) { self.rawValue = rawValue }
    fileprivate init(productFamily: Int) { rawValue = String(productFamily) }
}

extension SimulatorCatalog.DeviceType {
    package var category: DeviceCategory {
        identifier == iPhoneDuoDeviceType ? .iPhoneDuo : DeviceCategory(productFamily: productFamily)
    }
}

extension InventoryDevice {
    /// Reads metadata that stays the same when the device is renamed or unavailable, or has no CoreDevice record.
    package var isIPhoneDuo: Bool {
        switch self {
        case .simulator(let device): device.deviceTypeIdentifier == iPhoneDuoDeviceType
        case .remote(let device): device.modelIdentifier == iPhoneDuoModel
        }
    }
}
