import Foundation

/// Requests app-container access in the manager process before defaults reads or writes it.
@MainActor
struct HostPreferenceAccess {
    private let directory: URL
    private let readDirectory: (URL) throws -> Void

    init(directory: URL? = nil, readDirectory: @escaping (URL) throws -> Void = {
        _ = try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)
    }) {
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.apple.dt.Devices/Data", isDirectory: true)
        self.readDirectory = readDirectory
    }

    func request() throws {
        do {
            try readDirectory(directory)
        } catch CocoaError.fileReadNoSuchFile {
            // Device Hub has not created its container yet.
        }
    }
}
