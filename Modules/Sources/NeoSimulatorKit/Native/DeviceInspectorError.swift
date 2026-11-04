import Foundation

package enum DeviceInspectorError: Error, LocalizedError, Sendable {
    case unsupported(String)
    case commandFailed(status: Int32, stdout: String, stderr: String)
    case invalidResponse(String)
    case applicationNotFound(String)
    case profileNotFound(String)
    case reportNotFound(String)
    case invalidApplicationData(String)
    case cleanupFailed(directory: URL, operationError: (any Error)?, cleanupError: any Error)

    package var errorDescription: String? {
        switch self {
        case .unsupported(let detail), .invalidResponse(let detail), .invalidApplicationData(let detail): detail
        case .commandFailed(let status, let stdout, let stderr): "Command failed (\(status)): \(stderr.isEmpty ? stdout : stderr)"
        case .applicationNotFound(let identifier): "The application \(identifier) is no longer installed."
        case .profileNotFound(let identifier): "The profile \(identifier) is no longer installed."
        case .reportNotFound(let path): "The report \(path) is no longer available."
        case .cleanupFailed(let directory, let operationError, let cleanupError):
            [operationError?.localizedDescription, "Could not remove \(directory.path): \(cleanupError.localizedDescription)"].compactMap { $0 }.joined(separator: "\n")
        }
    }
}

