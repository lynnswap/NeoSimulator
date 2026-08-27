import Foundation

enum ReceiptStatus: Equatable {
    case unmanaged
    case managed(original: ManagedPreferenceState)
    case pendingBefore
    case pendingTarget
    case ambiguousIntermediate
    case conflict(expected: ManagedPreferenceState, observed: ManagedPreferenceState)

    var hasConflict: Bool {
        if case .conflict = self {
            return true
        }
        return self == .ambiguousIntermediate
    }
}

struct HostStatus: Equatable {
    let xcode: XcodeInstallation
    let preferences: ManagedPreferenceState
    let legacySimulator: SimulatorInstallation?
    let receiptStatus: ReceiptStatus
    let receiptURL: URL
    let runningXcodes: [RunningApplication]

    var rendered: String {
        var lines = [
            "Selected Xcode: \(xcode.version) (\(xcode.buildVersion))",
            "  \(xcode.applicationURL.path)",
            "Configured host: \(preferences.effectiveMode.rawValue)",
            "Xcode preference: \(preferences.xcodeSession)",
            "Device Hub auto-start suppression: \(preferences.deviceHubAutoStartSuppression)",
        ]

        if let legacySimulator {
            lines.append(
                "Legacy Simulator: Xcode \(legacySimulator.xcode.version), Simulator \(legacySimulator.version) (\(legacySimulator.buildVersion))"
            )
            lines.append("  \(legacySimulator.applicationURL.path)")
        } else {
            lines.append("Legacy Simulator: not found")
        }

        switch receiptStatus {
        case .unmanaged:
            lines.append("Restoration receipt: none")
        case .managed(let original):
            lines.append("Restoration receipt: managed (original: \(original))")
            lines.append("  \(receiptURL.path)")
        case .pendingBefore:
            lines.append("Restoration receipt: pending mutation not applied; run a use or restore command to recover")
            lines.append("  \(receiptURL.path)")
        case .pendingTarget:
            lines.append("Restoration receipt: pending mutation applied; run a use or restore command to recover")
            lines.append("  \(receiptURL.path)")
        case .ambiguousIntermediate:
            lines.append("Restoration receipt: AMBIGUOUS INTERMEDIATE STATE")
            lines.append("  This may be an interrupted write or an external change; nothing will be overwritten automatically.")
            lines.append("  Inspect the receipt, then use restore --force only if the saved original should win.")
            lines.append("  \(receiptURL.path)")
        case .conflict(let expected, let observed):
            lines.append("Restoration receipt: CONFLICT")
            lines.append("  expected: \(expected)")
            lines.append("  observed: \(observed)")
            lines.append("  \(receiptURL.path)")
        }

        if runningXcodes.isEmpty {
            lines.append("Running Xcode processes: none")
        } else {
            lines.append("Running Xcode processes: \(runningXcodes.count) (mode changes are blocked)")
            for application in runningXcodes {
                let path = application.bundleURL?.path ?? "unknown path"
                lines.append("  pid \(application.processIdentifier): \(path)")
            }
        }

        lines.append("Note: com.apple.dt.Xcode preferences are shared by all installed Xcode versions.")
        return lines.joined(separator: "\n")
    }
}

struct ModeChangeReport: Equatable {
    let mode: HostMode
    let didChange: Bool
    let xcode: XcodeInstallation
    let simulator: SimulatorInstallation?
    let receiptURL: URL?

    var rendered: String {
        var lines: [String]
        if didChange {
            lines = ["Configured simulator host: \(mode.rawValue)"]
        } else {
            lines = ["Simulator host is already configured for \(mode.rawValue)."]
        }

        lines.append("Xcode: \(xcode.version) (\(xcode.buildVersion))")
        if let simulator {
            lines.append("Simulator: \(simulator.applicationURL.path)")
        }
        if let receiptURL {
            lines.append("Restoration receipt: saved at \(receiptURL.path)")
        } else if didChange {
            lines.append("Restoration receipt: removed after returning to the original state")
        } else {
            lines.append("Restoration receipt: none")
        }
        lines.append("Launch Xcode 27 after changing modes.")
        return lines.joined(separator: "\n")
    }
}

struct RestoreReport: Equatable {
    let didRestore: Bool
    let restoredState: ManagedPreferenceState?
    let receiptURL: URL

    var rendered: String {
        guard let restoredState else {
            return "No restoration receipt exists; nothing changed."
        }
        if !didRestore {
            return """
                Preferences already matched the saved original: \(restoredState)
                Removed restoration receipt: \(receiptURL.path)
                """
        }
        return """
            Restored original preferences: \(restoredState)
            Removed restoration receipt: \(receiptURL.path)
            Launch Xcode again to use the restored configuration.
            """
    }
}
