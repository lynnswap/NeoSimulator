import Foundation

package enum ToolConstants {
    package static let minimumSupportedXcodeMajorVersion = 27
    package static let xcodeBundleIdentifier = "com.apple.dt.Xcode"
    package static let deviceKitPath = "Contents/SharedFrameworks/DeviceKit.framework"
    package static let coreSimulatorFrameworkPath =
        "/Library/Developer/PrivateFrameworks/CoreSimulator.framework"
    package static let coreDeviceFrameworkPath =
        "/Library/Developer/PrivateFrameworks/CoreDevice.framework"
    package static let simctlBinaryPath = "Versions/A/Resources/bin/simctl"
    package static let devicectlBinaryPath = "Versions/A/Resources/bin/devicectl"
}
