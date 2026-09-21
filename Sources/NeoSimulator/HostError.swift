import Foundation

enum HostError: LocalizedError {
    case invalidArguments(String)
    case unavailable(String)
    case conflict(String)
    case operation(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let message), .unavailable(let message),
             .conflict(let message), .operation(let message): message
        }
    }
}

func hostLog(_ message: String) {
    FileHandle.standardError.write(Data("neo-simulator: \(message)\n".utf8))
}
