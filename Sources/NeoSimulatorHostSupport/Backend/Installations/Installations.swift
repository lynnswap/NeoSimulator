import NeoSimulatorKit
import Foundation

extension XcodeInstallation {
    package var deviceHubApplicationURL: URL {
        applicationURL.appendingPathComponent(
            ToolConstants.deviceHubPath,
            isDirectory: true
        )
    }
}

package struct NeoHostInstallation: Equatable, Sendable {
    package let applicationURL: URL
    package let xcode: XcodeInstallation
    package let simulatorKitBinaryURL: URL
    package let idePlaygroundSimulatorBinaryURL: URL
    package let coreSimulatorBinaryURL: URL
    package let coreSimulatorVersion: String
    package let simctlWrapperURL: URL
    package let simctlBinaryURL: URL
    package let coreDeviceBinaryURL: URL
    package let coreDeviceVersion: String
    package let devicectlWrapperURL: URL
    package let devicectlBinaryURL: URL
    package let simulatorCoreDevicePluginBinaryURL: URL
}

package enum ResolvedHost: Equatable, Sendable {
    case neo(NeoHostInstallation)
    case deviceHub

    package var mode: SimulatorHost {
        switch self {
        case .neo:
            .neo
        case .deviceHub:
            .deviceHub
        }
    }
}
