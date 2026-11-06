import Foundation
import NeoSimulatorNative

/// What a caller can do about a failure.
package enum FailureCategory: Int32, Equatable, Sendable {
    case unavailable = 69
    case software = 70
    case cannotCreate = 73
    case io = 74
    case temporary = 75
    case configuration = 78
}

/// A failure that names what failed in a stable identifier. Each layer has its own error type, and code above it reads
/// any of them through this protocol.
package protocol IdentifiedFailure: LocalizedError, Sendable {
    var category: FailureCategory { get }
    var identifier: String { get }
    var message: String { get }

    init(category: FailureCategory, identifier: String, message: String, failureReason: String?, recoverySuggestion: String?)
}

extension IdentifiedFailure {
    package var errorDescription: String? { message }

    package init(category: FailureCategory, identifier: String, message: String) {
        self.init(category: category, identifier: identifier, message: message, failureReason: nil, recoverySuggestion: nil)
    }

    package static func unavailable(_ identifier: String, _ message: String) -> Self {
        Self(category: .unavailable, identifier: identifier, message: message)
    }

    package static func software(_ identifier: String, _ message: String) -> Self {
        Self(category: .software, identifier: identifier, message: message)
    }

    package static func cannotCreate(_ identifier: String, _ message: String) -> Self {
        Self(category: .cannotCreate, identifier: identifier, message: message)
    }

    package static func io(_ identifier: String, _ message: String) -> Self {
        Self(category: .io, identifier: identifier, message: message)
    }

    package static func temporary(_ identifier: String, _ message: String) -> Self {
        Self(category: .temporary, identifier: identifier, message: message)
    }

    package static func configuration(_ identifier: String, _ message: String) -> Self {
        Self(category: .configuration, identifier: identifier, message: message)
    }
}

/// A failure of the device channels, CoreDevice clients and system tools this module runs.
package struct DeviceIOError: IdentifiedFailure, Equatable {
    package let category: FailureCategory
    package let identifier: String
    package let message: String
    package var failureReason: String?
    package var recoverySuggestion: String?
    /// The loader's own failure, when a private framework this operation needs could not be used.
    package var runtimeFailure: NativeRuntimeError?

    package init(category: FailureCategory, identifier: String, message: String,
                 failureReason: String? = nil, recoverySuggestion: String? = nil) {
        self.category = category
        self.identifier = identifier
        self.message = message
        self.failureReason = failureReason
        self.recoverySuggestion = recoverySuggestion
    }

    package static func runtime(_ identifier: String, _ failure: NativeRuntimeError) -> DeviceIOError {
        var error = DeviceIOError.unavailable(identifier, failure.localizedDescription)
        error.runtimeFailure = failure
        return error
    }
}

/// Reports what nothing waits for.
func hostLog(_ message: String) {
    FileHandle.standardError.write(Data("neo-simulator: \(message)\n".utf8))
}
