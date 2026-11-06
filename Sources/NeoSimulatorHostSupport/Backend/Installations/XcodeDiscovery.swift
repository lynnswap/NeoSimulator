import NeoSimulatorKit
import Foundation

extension XcodeInstallationInspector {
    package nonisolated(nonsending) func discoverXcodes() async throws -> [XcodeInstallation] {
        var urls = Set<URL>()
        if let selected = try await selectedXcodeIfUsable() { urls.insert(selected.applicationURL) }
        for root in [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")] {
            let entries: [URL]
            do { entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) }
            catch CocoaError.fileReadNoSuchFile { continue }
            for entry in entries where entry.pathExtension == "app" {
                if let xcode = try? xcode(at: entry) { urls.insert(xcode.applicationURL) }
            }
        }
        let discovered: [XcodeInstallation] = try urls.map { try xcode(at: $0) }
        let installations = discovered.sorted { lhs, rhs in
            if lhs.version == rhs.version { return lhs.applicationURL.path < rhs.applicationURL.path }
            return rhs.version < lhs.version
        }
        guard !installations.isEmpty else { throw CLIError.unavailable("unsupported-xcode", "Install Xcode 27 or later and finish installing its developer tools.") }
        return installations
    }

}
