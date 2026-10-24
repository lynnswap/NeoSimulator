import Foundation

struct XcodeInstallation: Equatable, Sendable {
    let applicationURL: URL
    let version: ToolVersion
    let buildVersion: String

    var deviceHubApplicationURL: URL {
        applicationURL.appendingPathComponent(
            ToolConstants.deviceHubPath,
            isDirectory: true
        )
    }
}

struct NeoHostInstallation: Equatable, Sendable {
    let applicationURL: URL
    let xcode: XcodeInstallation
    let simulatorKitBinaryURL: URL
    let idePlaygroundSimulatorBinaryURL: URL
    let coreSimulatorBinaryURL: URL
    let coreSimulatorVersion: String
    let simctlWrapperURL: URL
    let simctlBinaryURL: URL
    let coreDeviceBinaryURL: URL
    let coreDeviceVersion: String
    let devicectlWrapperURL: URL
    let devicectlBinaryURL: URL
    let simulatorCoreDevicePluginBinaryURL: URL
}

enum ResolvedHost: Equatable, Sendable {
    case neo(NeoHostInstallation)
    case deviceHub

    var mode: SimulatorHost {
        switch self {
        case .neo:
            .neo
        case .deviceHub:
            .deviceHub
        }
    }
}
