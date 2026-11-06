import Foundation
import NeoSimulatorDeviceIO

/// A failure while preparing, displaying, or controlling a simulator.
public enum SimulatorError: LocalizedError, Sendable {
    case invalidArguments(String)
    case unavailable(String)
    case conflict(String)
    case operation(String)
    /// A request that changes the device was sent and did not answer in time or was given up on. It may yet apply, so
    /// reading the device, not repeating the request, is how to find out.
    case outcomeUnknown(String, underlying: any Error)
    /// A lower layer's failure, kept for what it can tell a caller that inspects it.
    case failed(String, underlying: any Error)

    public var errorDescription: String? {
        switch self {
        case .invalidArguments(let message), .unavailable(let message),
             .conflict(let message), .operation(let message),
             .outcomeUnknown(let message, _), .failed(let message, _): message
        }
    }

    public var recoverySuggestion: String? {
        if case .conflict = self { "Close the other display app, then try again." }
        else { nil }
    }

    /// What lower layers' `error` means to a caller of the public API, keeping `error` underneath.
    public init(mapping error: any Error) {
        switch error {
        case let error as SimulatorError: self = error
        case let error as DeviceOperationFailure:
            switch error {
            case .outcomeUnknown: self = .outcomeUnknown(error.localizedDescription, underlying: error)
            default: self = .failed(error.localizedDescription, underlying: error)
            }
        default: self = .failed(error.localizedDescription, underlying: error)
        }
    }
}

/// Runs a public operation. Its caller's cancellation stays a `CancellationError`, and any other failure becomes a
/// ``SimulatorError``.
@MainActor
package func mappingToSimulatorError<Value>(_ body: @MainActor () async throws -> Value) async throws -> Value {
    do { return try await body() }
    catch is CancellationError { throw CancellationError() }
    catch { throw SimulatorError(mapping: error) }
}

/// A failure of the device model: its inventory, settings and background services.
package struct DeviceDomainError: IdentifiedFailure, Equatable {
    package let category: FailureCategory
    package let identifier: String
    package let message: String
    package var failureReason: String?
    package var recoverySuggestion: String?

    package init(category: FailureCategory, identifier: String, message: String,
                 failureReason: String? = nil, recoverySuggestion: String? = nil) {
        self.category = category
        self.identifier = identifier
        self.message = message
        self.failureReason = failureReason
        self.recoverySuggestion = recoverySuggestion
    }
}

package func hostLog(_ message: String) {
    FileHandle.standardError.write(Data("neo-simulator: \(message)\n".utf8))
}

/// Whether `error` says that the caller stopped the operation, for a caller with nothing left to account for. A layer
/// above the device's transports asks here, as it does not see their failures.
package func isCallerCancellation(_ error: any Error) -> Bool { error.isCancellation }
