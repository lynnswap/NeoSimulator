import AppKit

/// Keeps an explicitly granted directory available while host preferences are managed.
@MainActor
final class HostPreferenceAccess {
    private let defaults: UserDefaults
    private let directory: URL
    private let readDirectory: (URL) throws -> Void
    private let chooseDirectory: (URL) -> URL?
    private var scopedURL: URL?
    private static let bookmarkKey = "DeviceHubPreferencesAccess"

    init(defaults: UserDefaults = .standard, directory: URL? = nil,
         readDirectory: @escaping (URL) throws -> Void = {
             _ = try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)
         }, chooseDirectory: ((URL) -> URL?)? = nil) {
        self.defaults = defaults
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.apple.dt.Devices/Data", isDirectory: true)
        self.readDirectory = readDirectory
        self.chooseDirectory = chooseDirectory ?? Self.chooseDirectory
        if let data = defaults.data(forKey: Self.bookmarkKey) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                  bookmarkDataIsStale: &stale) {
                if url.startAccessingSecurityScopedResource() { scopedURL = url }
            }
        }
    }

    isolated deinit { scopedURL?.stopAccessingSecurityScopedResource() }

    func request() throws {
        do {
            // Access from the app itself lets macOS ask for consent before the defaults subprocess runs.
            try readDirectory(directory)
            return
        } catch CocoaError.fileReadNoSuchFile {
            // Device Hub has not created its container yet.
            return
        } catch CocoaError.fileReadNoPermission {
            // A file picker also grants access when a previous privacy request was denied.
        }

        guard let url = chooseDirectory(directory) else { throw CancellationError() }

        let started = url.startAccessingSecurityScopedResource()
        do {
            try readDirectory(directory)
            let bookmark = try url.bookmarkData(options: .withSecurityScope,
                                                includingResourceValuesForKeys: nil, relativeTo: nil)
            defaults.set(bookmark, forKey: Self.bookmarkKey)
            scopedURL?.stopAccessingSecurityScopedResource()
            scopedURL = started ? url : nil
        } catch {
            if started { url.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    private static func chooseDirectory(_ directory: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.message = "Allow access to Device Hub settings so NeoSimulator can switch the simulator display host."
        panel.prompt = "Allow Access"
        panel.directoryURL = directory
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        return panel.runModal() == .OK ? panel.url : nil
    }
}
