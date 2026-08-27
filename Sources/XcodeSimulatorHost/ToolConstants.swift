import Foundation

enum ToolConstants {
    static let name = "xcode-simulator-host"
    static let version = "0.1.0"

    static let supportedXcodeMajorVersion = 27
    static let legacyXcodeMajorVersion = 26

    static let xcodeBundleIdentifier = "com.apple.dt.Xcode"
    static let deviceHubBundleIdentifier = "com.apple.dt.Devices"
    static let simulatorBundleIdentifier = "com.apple.iphonesimulator"

    static let xcodePreference = ManagedPreference(
        domain: "com.apple.dt.Xcode",
        key: "DVTiPhoneSimulatorAlwaysLaunchInCoreSimulatorSession"
    )

    static let deviceHubPreference = ManagedPreference(
        domain: "com.apple.dt.Devices",
        key: "disableAutoStartLiveDeviceView"
    )

    static let ideIOSSupportCorePath =
        "Contents/PlugIns/IDEiOSSupportCore.framework/Versions/A/IDEiOSSupportCore"
    static let deviceHubPath = "Contents/Applications/DeviceHub.app"
    static let deviceHubImplementationPath = "Contents/MacOS/DeviceHub"
    static let simulatorPath = "Contents/Developer/Applications/Simulator.app"
}
