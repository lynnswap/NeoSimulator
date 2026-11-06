import Foundation

/// A failure while preparing, displaying, or controlling a simulator.
public enum SimulatorError: LocalizedError, Sendable {
    case invalidArguments(String)
    case unavailable(String)
    case conflict(String)
    case operation(String)

    public var errorDescription: String? {
        switch self {
        case .invalidArguments(let message), .unavailable(let message),
             .conflict(let message), .operation(let message): message
        }
    }

    public var recoverySuggestion: String? {
        if case .conflict = self { "Close the other display app, then try again." }
        else { nil }
    }

}

package func hostLog(_ message: String) {
    FileHandle.standardError.write(Data("neo-simulator: \(message)\n".utf8))
}
