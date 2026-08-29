import Foundation

enum ToolConstants {
    static let name = "xcode-simulator-host"
    static let version = "0.0.1"

    static let minimumSupportedXcodeMajorVersion = 27

    static let xcodeBundleIdentifier = "com.apple.dt.Xcode"
    static let deviceHubBundleIdentifier = "com.apple.dt.Devices"
    static let legacyHostBundleIdentifier = "dev.lynnswap.XcodeSimulatorLegacyHost"
    static let coreSimulatorBundleIdentifier = "com.apple.CoreSimulator"
    static let simulatorKitBundleIdentifier = "com.apple.SimulatorKit"
    static let idePlaygroundSimulatorBundleIdentifier =
        "com.apple.dt.IDE.IDEPlaygroundSimulator"

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
    static let simulatorKitPath =
        "Contents/SharedFrameworks/SimulatorKit.framework"
    static let idePlaygroundSimulatorPath =
        "Contents/Frameworks/IDEPlaygroundSimulator.framework"
    static let coreSimulatorFrameworkPath =
        "/Library/Developer/PrivateFrameworks/CoreSimulator.framework"
    static let legacyHostRelativePath =
        "../libexec/xcode-simulator-host/XcodeSimulatorLegacyHost.app"
}
