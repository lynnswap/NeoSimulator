import Foundation

struct XcodeInstallation: Equatable {
    let applicationURL: URL
    let version: ToolVersion
    let buildVersion: String
}

struct SimulatorInstallation: Equatable {
    let applicationURL: URL
    let xcode: XcodeInstallation
    let version: String
    let buildVersion: String
}
