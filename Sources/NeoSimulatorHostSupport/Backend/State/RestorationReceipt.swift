import Foundation
import NeoSimulatorDeviceIO
import NeoSimulatorKit

package struct PendingMutation: Codable, Equatable {
    package let before: ManagedPreferenceState
    package let target: ManagedPreferenceState
}

package struct RestorationReceipt: Codable, Equatable {
    package static let currentSchemaVersion = 1

    package let schemaVersion: Int
    package let toolIdentifier: String
    package let capturedAt: Date
    package let xcodeVersionAtCapture: String
    package let xcodeBuildAtCapture: String
    package let original: ManagedPreferenceState
    package var expectedCurrent: ManagedPreferenceState
    package var pending: PendingMutation?

    package init(
        capturedAt: Date,
        xcode: XcodeInstallation,
        original: ManagedPreferenceState
    ) {
        schemaVersion = Self.currentSchemaVersion
        toolIdentifier = ToolConstants.name
        self.capturedAt = capturedAt
        xcodeVersionAtCapture = xcode.version.description
        xcodeBuildAtCapture = xcode.buildVersion
        self.original = original
        expectedCurrent = original
        pending = nil
    }

    package func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw HostOperationError.configuration(
                "receipt-schema",
                "unsupported receipt schema \(schemaVersion)"
            )
        }
        guard toolIdentifier == ToolConstants.name else {
            throw HostOperationError.configuration(
                "receipt-owner",
                "receipt belongs to '\(toolIdentifier)', not \(ToolConstants.name)"
            )
        }
        if let pending {
            guard pending.before == expectedCurrent else {
                throw HostOperationError.configuration(
                    "receipt-pending-before",
                    "pending mutation starts at \(pending.before), but the receipt expects \(expectedCurrent)"
                )
            }
            guard pending.before != pending.target else {
                throw HostOperationError.configuration(
                    "receipt-pending-noop",
                    "pending mutation has identical before and target states"
                )
            }
        }
    }
}
