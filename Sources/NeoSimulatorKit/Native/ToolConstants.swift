import Foundation

package enum ToolConstants {
    package static let minimumSupportedXcodeMajorVersion = 27
    package static let xcodeBundleIdentifier = "com.apple.dt.Xcode"
    package static let deviceKitPath = "Contents/SharedFrameworks/DeviceKit.framework"
    package static let neoManagerBundleIdentifier = "dev.lynnswap.NeoSimulator"
    package static let neoHostBundleIdentifier = "dev.lynnswap.NeoSimulator.Renderer"

    package static var managerDefaults: UserDefaults? {
        // Foundation rejects the current app's bundle identifier as a suite name.
        Bundle.main.bundleIdentifier == neoManagerBundleIdentifier
            ? .standard : UserDefaults(suiteName: neoManagerBundleIdentifier)
    }
}
