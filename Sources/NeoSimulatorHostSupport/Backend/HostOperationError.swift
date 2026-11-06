import Foundation
import NeoSimulatorDeviceIO

/// A failure of what this host runs for its application: its installations, receipts, preferences, workspace and modes.
package struct HostOperationError: IdentifiedFailure, Equatable {
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
