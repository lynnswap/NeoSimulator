import Foundation

struct PendingMutation: Codable, Equatable {
    let before: ManagedPreferenceState
    let target: ManagedPreferenceState
}

struct RestorationReceipt: Codable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let toolIdentifier: String
    let capturedAt: Date
    let xcodeVersionAtCapture: String
    let xcodeBuildAtCapture: String
    let original: ManagedPreferenceState
    var expectedCurrent: ManagedPreferenceState
    var pending: PendingMutation?

    init(
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

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw CLIError.configuration(
                "receipt-schema",
                "unsupported receipt schema \(schemaVersion)"
            )
        }
        guard toolIdentifier == ToolConstants.name else {
            throw CLIError.configuration(
                "receipt-owner",
                "receipt belongs to '\(toolIdentifier)', not \(ToolConstants.name)"
            )
        }
        if let pending {
            guard pending.before == expectedCurrent else {
                throw CLIError.configuration(
                    "receipt-pending-before",
                    "pending mutation starts at \(pending.before), but the receipt expects \(expectedCurrent)"
                )
            }
            guard pending.before != pending.target else {
                throw CLIError.configuration(
                    "receipt-pending-noop",
                    "pending mutation has identical before and target states"
                )
            }
        }
    }
}
