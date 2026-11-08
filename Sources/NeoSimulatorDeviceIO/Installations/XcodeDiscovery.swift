import Foundation

extension XcodeInstallationInspector {
    package nonisolated(nonsending) func discoverXcodes() async throws -> [XcodeInstallation] {
        var discovered: [URL: XcodeInstallation] = [:]
        if let selected = try await selectedXcodeIfUsable() { discovered[selected.applicationURL] = selected }
        for root in [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")] {
            let entries: [URL]
            do { entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) }
            catch CocoaError.fileReadNoSuchFile { continue }
            for entry in entries where entry.pathExtension == "app" {
                let url = entry.resolvingSymlinksInPath().standardizedFileURL
                guard discovered[url] == nil, let xcode = try? xcode(at: url) else { continue }
                discovered[xcode.applicationURL] = xcode
            }
        }
        let installations = discovered.values.sorted { lhs, rhs in
            if lhs.version == rhs.version { return lhs.applicationURL.path < rhs.applicationURL.path }
            return rhs.version < lhs.version
        }
        guard !installations.isEmpty else { throw DeviceIOError.unavailable("unsupported-xcode", "Install Xcode 27 or later and finish installing its developer tools.") }
        return installations
    }

}
