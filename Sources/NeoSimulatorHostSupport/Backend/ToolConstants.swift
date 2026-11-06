import NeoSimulatorKit
import Foundation

extension ToolConstants {
    package static let name = "xcode-simulator-host"


    package static let deviceHubBundleIdentifier = "com.apple.dt.Devices"
    package static let deviceKitBundleIdentifier = "com.apple.dt.DeviceKit"
    package static let simulatorBundleIdentifier = "com.apple.iphonesimulator"
    package static let neoManagerBundleIdentifier = "dev.lynnswap.NeoSimulator"
    package static let neoHostBundleIdentifier = "dev.lynnswap.NeoSimulator.Renderer"
    package static let coreSimulatorBundleIdentifier = "com.apple.CoreSimulator"
    package static let coreDeviceBundleIdentifier = "com.apple.CoreDevice"
    package static let simctlBundleIdentifier = "com.apple.CoreSimulator.simctl"
    package static let devicectlBundleIdentifier = "com.apple.CoreDevice.devicectl"
    package static let simulatorCoreDevicePluginBundleIdentifier =
        "com.apple.CoreSimulator.SimulatorCoreDevicePlugin"
    package static let simulatorKitBundleIdentifier = "com.apple.SimulatorKit"
    package static let idePlaygroundSimulatorBundleIdentifier =
        "com.apple.dt.IDE.IDEPlaygroundSimulator"

    package static var managerDefaults: UserDefaults? {
        // Foundation rejects the current app's bundle identifier as a suite name.
        Bundle.main.bundleIdentifier == neoManagerBundleIdentifier
            ? .standard : UserDefaults(suiteName: neoManagerBundleIdentifier)
    }

    package static let xcodePreference = ManagedPreference(
        domain: "com.apple.dt.Xcode",
        key: "DVTiPhoneSimulatorAlwaysLaunchInCoreSimulatorSession"
    )

    package static let deviceHubPreference = ManagedPreference(
        domain: "com.apple.dt.Devices",
        key: "disableAutoStartLiveDeviceView"
    )

    package static let ideIOSSupportCorePath =
        "Contents/PlugIns/IDEiOSSupportCore.framework/Versions/A/IDEiOSSupportCore"
    package static let deviceHubPath = "Contents/Applications/DeviceHub.app"
    package static let deviceHubImplementationPath = "Contents/MacOS/DeviceHub"
    package static let simulatorKitPath =
        "Contents/SharedFrameworks/SimulatorKit.framework"
    package static let idePlaygroundSimulatorPath =
        "Contents/Frameworks/IDEPlaygroundSimulator.framework"
    package static let simctlWrapperPath = "Contents/Developer/usr/bin/simctl"
    package static let devicectlWrapperPath = "Contents/Developer/usr/bin/devicectl"
    package static let simulatorCoreDevicePluginPath =
        "Versions/A/PlugIns/SimulatorCoreDevicePlugin.coredeviceplugin"
}
