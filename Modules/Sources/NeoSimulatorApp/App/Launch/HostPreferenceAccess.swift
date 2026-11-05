import AppKit
import Foundation

/// Retains access to the selected Device Hub settings file or its containing folder.
@MainActor
final class HostPreferenceAccess {
    private let defaults: UserDefaults
    private let file: URL
    private let chooseFile: (URL, NSWindow?) async throws -> URL?
    private var scopedURL: URL?
    private static let bookmarkKey = "DeviceHubSettingsAccess"

    init(defaults: UserDefaults = .standard, file: URL? = nil,
         chooseFile: ((URL, NSWindow?) async throws -> URL?)? = nil) {
        self.defaults = defaults
        self.file = file ?? FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Containers/com.apple.dt.Devices/Data/Library/Preferences/com.apple.dt.Devices.plist")
        self.chooseFile = chooseFile ?? Self.chooseFile
    }

    isolated deinit { scopedURL?.stopAccessingSecurityScopedResource() }

    func restore() -> Bool {
        if scopedURL != nil { return true }
        if let bookmark = defaults.data(forKey: Self.bookmarkKey) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                                  relativeTo: nil, bookmarkDataIsStale: &stale),
               url.startAccessingSecurityScopedResource() {
                do {
                    try validateSelection(url)
                    if stale { try saveBookmark(for: url) }
                    scopedURL = url
                    return true
                } catch {
                    url.stopAccessingSecurityScopedResource()
                }
            }
        }

        // Device Hub may not have created its preferences file yet.
        return !FileManager.default.fileExists(atPath: file.path)
    }

    func request(presenting window: NSWindow? = nil) async throws {
        try Task.checkCancellation()
        if restore() { return }
        guard let url = try await chooseFile(file, window) else { throw CancellationError() }
        do {
            try Task.checkCancellation()
            try validateSelection(url)
            try saveBookmark(for: url)
            scopedURL = url
        } catch {
            url.stopAccessingSecurityScopedResource()
            throw error
        }
    }

    private func saveBookmark(for url: URL) throws {
        let bookmark = try url.bookmarkData(options: .withSecurityScope,
                                            includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(bookmark, forKey: Self.bookmarkKey)
    }

    private func validateSelection(_ url: URL) throws {
        let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        let selected = try url.resourceValues(forKeys: keys).fileResourceIdentifier as? NSObject
        let expected = try [file, file.deletingLastPathComponent()].map {
            try $0.resourceValues(forKeys: keys).fileResourceIdentifier as? NSObject
        }
        guard let selected, expected.contains(where: { $0?.isEqual(selected) == true }) else {
            throw CocoaError(.fileReadInvalidFileName, userInfo: [
                NSLocalizedDescriptionKey: "Select the Device Hub settings file or its Preferences folder.",
                NSLocalizedRecoverySuggestionErrorKey: "Choose \(file.lastPathComponent) or its containing folder to allow NeoSimulator to change the simulator display host."
            ])
        }
    }

    private static func chooseFile(_ file: URL, presenting window: NSWindow?) async -> URL? {
        let panel = NSOpenPanel()
        panel.message = "Allow NeoSimulator to update Device Hub settings so simulators open in your preferred app."
        panel.prompt = "Allow Access"
        panel.directoryURL = file.deletingLastPathComponent()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.showsHiddenFiles = true
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        let response: NSApplication.ModalResponse
        if let window { response = await panel.beginSheetModal(for: window) }
        else { response = await panel.begin() }
        panel.orderOut(nil)
        return response == .OK ? panel.url : nil
    }
}
