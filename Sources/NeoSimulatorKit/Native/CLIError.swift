import Foundation

package struct CLIError: Error, Equatable, LocalizedError {
    package enum Category: Int32, Equatable {
        case unavailable = 69
        case software = 70
        case cannotCreate = 73
        case io = 74
        case temporary = 75
        case configuration = 78
    }

    package let category: Category
    package let identifier: String
    package let message: String
    package var failureReason: String? = nil
    package var recoverySuggestion: String? = nil

    package init(category: Category, identifier: String, message: String,
                 failureReason: String? = nil, recoverySuggestion: String? = nil) {
        self.category = category
        self.identifier = identifier
        self.message = message
        self.failureReason = failureReason
        self.recoverySuggestion = recoverySuggestion
    }

    package var errorDescription: String? {
        message
    }

    package static func unavailable(_ identifier: String, _ message: String) -> CLIError {
        CLIError(category: .unavailable, identifier: identifier, message: message)
    }

    package static func software(_ identifier: String, _ message: String) -> CLIError {
        CLIError(category: .software, identifier: identifier, message: message)
    }

    package static func cannotCreate(_ identifier: String, _ message: String) -> CLIError {
        CLIError(category: .cannotCreate, identifier: identifier, message: message)
    }

    package static func io(_ identifier: String, _ message: String) -> CLIError {
        CLIError(category: .io, identifier: identifier, message: message)
    }

    package static func temporary(_ identifier: String, _ message: String) -> CLIError {
        CLIError(category: .temporary, identifier: identifier, message: message)
    }

    package static func configuration(_ identifier: String, _ message: String) -> CLIError {
        CLIError(category: .configuration, identifier: identifier, message: message)
    }
}
