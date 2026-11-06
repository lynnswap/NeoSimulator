import Foundation
import NeoSimulatorDeviceIO

/// A failure of a remote device's screen, input or pasteboard connection.
package struct RemoteScreenError: IdentifiedFailure, Equatable {
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
