import Foundation

/// Checks access in the manager process before its defaults subprocess reads or writes Device Hub settings.
@MainActor
struct HostPreferenceAccess {
    private let directory: URL
    private let verifyDirectory: (URL) throws -> Void

    init(directory: URL? = nil, verifyAccess: @escaping (URL) throws -> Void = {
        _ = try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)
        let probe = $0.appending(path: ".neosimulator-access-\(UUID().uuidString)")
        try Data().write(to: probe, options: .withoutOverwriting)
        try FileManager.default.removeItem(at: probe)
    }) {
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Containers/com.apple.dt.Devices/Data", directoryHint: .isDirectory)
        verifyDirectory = verifyAccess
    }

    func request() throws {
        do { try verifyDirectory(directory) }
        catch CocoaError.fileReadNoSuchFile {
            // Device Hub has not created a protected container yet.
            return
        } catch let error as CocoaError where error.code == .fileReadNoPermission || error.code == .fileWriteNoPermission {
            throw Failure(underlyingError: error)
        }
    }

    struct Failure: LocalizedError {
        static let recoveryCommand = "tccutil reset SystemPolicyAppData dev.lynnswap.NeoSimulator"
        let underlyingError: any Error

        var errorDescription: String? { "NeoSimulator couldn’t access Device Hub settings." }
        var failureReason: String? { underlyingError.localizedDescription }
        var recoverySuggestion: String? {
            "Quit NeoSimulator, run \(Self.recoveryCommand) in Terminal, then reopen NeoSimulator and allow access."
        }

    }
}
