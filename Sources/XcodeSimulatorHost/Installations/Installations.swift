import Foundation

struct XcodeInstallation: Equatable {
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

struct LegacyHostInstallation: Equatable {
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
