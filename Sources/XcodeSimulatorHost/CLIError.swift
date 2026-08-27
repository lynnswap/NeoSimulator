import Foundation

struct CLIError: Error, Equatable, LocalizedError {
    enum Category: Int32, Equatable {
        case usage = 64
        case unavailable = 69
        case software = 70
        case cannotCreate = 73
        case io = 74
        case temporary = 75
        case configuration = 78
    }

    let category: Category
    let identifier: String
    let message: String

    var errorDescription: String? {
        message
    }

    var rendered: String {
        "error[\(identifier)]: \(message)"
    }

    static func usage(_ message: String) -> CLIError {
        CLIError(category: .usage, identifier: "usage", message: message)
    }

    static func unavailable(_ identifier: String, _ message: String) -> CLIError {
        CLIError(category: .unavailable, identifier: identifier, message: message)
    }

    static func software(_ identifier: String, _ message: String) -> CLIError {
        CLIError(category: .software, identifier: identifier, message: message)
    }

    static func cannotCreate(_ identifier: String, _ message: String) -> CLIError {
        CLIError(category: .cannotCreate, identifier: identifier, message: message)
    }

    static func io(_ identifier: String, _ message: String) -> CLIError {
        CLIError(category: .io, identifier: identifier, message: message)
    }

    static func temporary(_ identifier: String, _ message: String) -> CLIError {
        CLIError(category: .temporary, identifier: identifier, message: message)
    }

    static func configuration(_ identifier: String, _ message: String) -> CLIError {
        CLIError(category: .configuration, identifier: identifier, message: message)
    }
}
