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

struct SimulatorRouteStatus: Equatable {
    let preferences: ManagedPreferenceState
    let receiptStatus: ReceiptStatus

    var rendered: String {
        let route = routeLine
        switch receiptStatus {
        case .pendingBefore, .pendingTarget:
            return """
                \(route)
                Attention: an interrupted change needs recovery. Run 'xcode-simulator-host status --verbose'.
                """
        case .ambiguousIntermediate, .conflict:
            return """
                \(route)
                Attention: preferences need review. Run 'xcode-simulator-host status --verbose'.
                """
        case .unmanaged, .managed:
            return route
        }
    }

    fileprivate var routeLine: String {
        switch preferences.effectiveMode {
        case .deviceHub:
            "Simulator route: Device Hub"
        case .legacy:
            "Simulator route: CoreSimulator"
        }
    }
}

struct HostStatus: Equatable {
    let xcode: XcodeInstallation
    let routeStatus: SimulatorRouteStatus
    let legacyHost: LegacyHostInstallation?
    let receiptURL: URL
    let runningXcodes: [RunningApplication]
    let runningLegacyHosts: [RunningApplication]

    var rendered: String {
        var lines = [
            routeStatus.routeLine,
            "",
            "Selected Xcode: \(xcode.version) (\(xcode.buildVersion))",
            "  \(xcode.applicationURL.path)",
        ]

        if let legacyHost {
            lines.append("Standalone host: validated")
            lines.append("  \(legacyHost.applicationURL.path)")
            lines.append("  SimulatorKit: \(legacyHost.simulatorKitBinaryURL.path)")
            lines.append(
                "  IDEPlaygroundSimulator: \(legacyHost.idePlaygroundSimulatorBinaryURL.path)"
            )
            lines.append("  CoreSimulator: \(legacyHost.coreSimulatorBinaryURL.path)")
            lines.append("  CoreSimulator version: \(legacyHost.coreSimulatorVersion)")
            lines.append("  simctl wrapper: \(legacyHost.simctlWrapperURL.path)")
            lines.append("  simctl: \(legacyHost.simctlBinaryURL.path)")
            lines.append("  CoreDevice: \(legacyHost.coreDeviceBinaryURL.path)")
            lines.append("  CoreDevice version: \(legacyHost.coreDeviceVersion)")
            lines.append("  devicectl wrapper: \(legacyHost.devicectlWrapperURL.path)")
            lines.append("  devicectl: \(legacyHost.devicectlBinaryURL.path)")
            lines.append(
                "  Simulator CoreDevice plugin (\(legacyHost.coreSimulatorVersion)): \(legacyHost.simulatorCoreDevicePluginBinaryURL.path)"
            )
        } else {
            lines.append("Standalone host: unavailable")
        }

        lines.append("")
        switch routeStatus.receiptStatus {
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

        lines.append("")
        if runningXcodes.isEmpty {
            lines.append("Running Xcode processes: none")
        } else {
            lines.append("Running Xcode processes: \(runningXcodes.count) (hot switching is supported)")
            for application in runningXcodes {
                let path = application.bundleURL?.path ?? "unknown path"
                lines.append("  pid \(application.processIdentifier): \(path)")
            }
        }

        if runningLegacyHosts.isEmpty {
            lines.append("Running standalone host processes: none")
        } else {
            lines.append(
                "Running standalone host processes: \(runningLegacyHosts.count)"
            )
            for application in runningLegacyHosts {
                let path = application.bundleURL?.path ?? "unknown path"
                lines.append("  pid \(application.processIdentifier): \(path)")
            }
        }

        lines.append("")
        lines.append("Preference details:")
        lines.append(
            "  CoreSimulator session: \(routeStatus.preferences.xcodeSession.statusDescription)"
        )
        lines.append(
            "  Suppress Device Hub auto-start: \(routeStatus.preferences.deviceHubAutoStartSuppression.statusDescription)"
        )
        lines.append("  Scope: shared by all installed Xcode versions")
        return lines.joined(separator: "\n")
    }
}

private extension StoredBoolean {
    var statusDescription: String {
        switch self {
        case .absent:
            "not set (default)"
        case .falseValue:
            "false"
        case .trueValue:
            "true"
        }
    }
}

struct ModeChangeReport: Equatable {
    let mode: HostMode
    let didChange: Bool
    let xcode: XcodeInstallation
    let legacyHost: LegacyHostInstallation?
    let receiptURL: URL?
    let terminatedDeviceHubCount: Int
    let terminatedLegacyHostCount: Int

    var rendered: String {
        var lines: [String]
        if didChange {
            lines = ["Configured simulator host: \(mode.rawValue)"]
        } else {
            lines = ["Simulator host is already configured for \(mode.rawValue)."]
        }

        lines.append("Xcode: \(xcode.version) (\(xcode.buildVersion))")
        if let legacyHost {
            lines.append("Standalone host: \(legacyHost.applicationURL.path)")
        }
        if terminatedDeviceHubCount > 0 {
            lines.append("Closed Device Hub instances: \(terminatedDeviceHubCount)")
        }
        if terminatedLegacyHostCount > 0 {
            lines.append(
                "Closed standalone host instances: \(terminatedLegacyHostCount)"
            )
        }
        if let receiptURL {
            lines.append("Restoration receipt: saved at \(receiptURL.path)")
        } else if didChange {
            lines.append("Restoration receipt: removed after returning to the original state")
        } else {
            lines.append("Restoration receipt: none")
        }
        lines.append("Xcode can remain open; the next Run uses this mode.")
        return lines.joined(separator: "\n")
    }
}

struct RestoreReport: Equatable {
    let didRestore: Bool
    let restoredState: ManagedPreferenceState?
    let receiptURL: URL
    let terminatedLegacyHostCount: Int

    var rendered: String {
        guard let restoredState else {
            var lines = ["No restoration receipt exists; preferences did not change."]
            if terminatedLegacyHostCount > 0 {
                lines.append(
                    "Closed standalone host instances: \(terminatedLegacyHostCount)"
                )
            }
            return lines.joined(separator: "\n")
        }
        var lines: [String]
        if !didRestore {
            lines = [
                "Preferences already matched the saved original: \(restoredState)",
                "Removed restoration receipt: \(receiptURL.path)",
            ]
        } else {
            lines = [
                "Restored original preferences: \(restoredState)",
                "Removed restoration receipt: \(receiptURL.path)",
                "Xcode can remain open; the next Run uses the restored configuration.",
            ]
        }
        if terminatedLegacyHostCount > 0 {
            lines.append(
                "Closed standalone host instances: \(terminatedLegacyHostCount)"
            )
        }
        return lines.joined(separator: "\n")
    }
}
