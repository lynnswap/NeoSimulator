import Foundation

package struct XcodeInstallation: Equatable, Sendable {
    package let applicationURL: URL
    package let version: ToolVersion
    package let buildVersion: String

}
