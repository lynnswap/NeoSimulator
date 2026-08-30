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
        switch preferences.effectiveRoute {
        case .deviceHub:
            "Simulator route: Device Hub"
        case .coreSimulator:
            "Simulator route: CoreSimulator"
        }
    }
}

struct HostStatus: Equatable {
    let xcode: XcodeInstallation
    let routeStatus: SimulatorRouteStatus
    let neoHost: NeoHostInstallation?
    let legacySimulator: SimulatorInstallation?
    let receiptURL: URL
    let runningXcodes: [RunningApplication]
    let runningNeoHosts: [RunningApplication]
    let runningLegacySimulators: [RunningApplication]

    var rendered: String {
        var lines = [
            routeStatus.routeLine,
            "",
            "Selected Xcode: \(xcode.version) (\(xcode.buildVersion))",
            "  \(xcode.applicationURL.path)",
        ]

        if let neoHost {
            lines.append("NeoSimulator: validated")
            lines.append("  \(neoHost.applicationURL.path)")
            lines.append("  SimulatorKit: \(neoHost.simulatorKitBinaryURL.path)")
            lines.append(
                "  IDEPlaygroundSimulator: \(neoHost.idePlaygroundSimulatorBinaryURL.path)"
            )
            lines.append("  CoreSimulator: \(neoHost.coreSimulatorBinaryURL.path)")
            lines.append("  CoreSimulator version: \(neoHost.coreSimulatorVersion)")
            lines.append("  simctl wrapper: \(neoHost.simctlWrapperURL.path)")
            lines.append("  simctl: \(neoHost.simctlBinaryURL.path)")
            lines.append("  CoreDevice: \(neoHost.coreDeviceBinaryURL.path)")
            lines.append("  CoreDevice version: \(neoHost.coreDeviceVersion)")
            lines.append("  devicectl wrapper: \(neoHost.devicectlWrapperURL.path)")
            lines.append("  devicectl: \(neoHost.devicectlBinaryURL.path)")
            lines.append(
                "  Simulator CoreDevice plugin (\(neoHost.coreSimulatorVersion)): \(neoHost.simulatorCoreDevicePluginBinaryURL.path)"
            )
        } else {
            lines.append("NeoSimulator: unavailable")
        }

        if let legacySimulator {
            lines.append("Legacy Simulator: validated")
            lines.append("  Simulator \(legacySimulator.version) (\(legacySimulator.buildVersion))")
            lines.append("  \(legacySimulator.applicationURL.path)")
            lines.append(
                "  Xcode \(legacySimulator.xcode.version) (\(legacySimulator.xcode.buildVersion)): \(legacySimulator.xcode.applicationURL.path)"
            )
        } else {
            lines.append("Legacy Simulator: unavailable")
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

        if runningNeoHosts.isEmpty {
            lines.append("Running NeoSimulator processes: none")
        } else {
            lines.append(
                "Running NeoSimulator processes: \(runningNeoHosts.count)"
            )
            for application in runningNeoHosts {
                let path = application.bundleURL?.path ?? "unknown path"
                lines.append("  pid \(application.processIdentifier): \(path)")
            }
        }

        if runningLegacySimulators.isEmpty {
            lines.append("Running legacy Simulator processes: none")
        } else {
            lines.append(
                "Running legacy Simulator processes: \(runningLegacySimulators.count)"
            )
            for application in runningLegacySimulators {
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
    let host: ResolvedHost
    let didChangePreferences: Bool
    let xcode: XcodeInstallation
    let receiptURL: URL?
    let terminatedDeviceHubCount: Int
    let terminatedNeoHostCount: Int
    let terminatedLegacySimulatorCount: Int

    var rendered: String {
        var lines = ["Selected simulator host: \(host.mode.rawValue)"]

        lines.append("Xcode: \(xcode.version) (\(xcode.buildVersion))")
        switch host {
        case .neo(let neoHost):
            lines.append("NeoSimulator: \(neoHost.applicationURL.path)")
        case .legacy(let simulator):
            lines.append("Legacy Simulator: \(simulator.applicationURL.path)")
        case .deviceHub:
            break
        }
        let routeName = host.mode.targetState.effectiveRoute == .coreSimulator
            ? "CoreSimulator"
            : "Device Hub"
        lines.append(
            didChangePreferences
                ? "Preference route: changed to \(routeName)"
                : "Preference route: already \(routeName)"
        )
        if terminatedDeviceHubCount > 0 {
            lines.append("Closed Device Hub instances: \(terminatedDeviceHubCount)")
        }
        if terminatedNeoHostCount > 0 {
            lines.append(
                "Closed NeoSimulator instances: \(terminatedNeoHostCount)"
            )
        }
        if terminatedLegacySimulatorCount > 0 {
            lines.append(
                "Closed legacy Simulator instances: \(terminatedLegacySimulatorCount)"
            )
        }
        if let receiptURL {
            lines.append("Restoration receipt: saved at \(receiptURL.path)")
        } else if didChangePreferences {
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
    let terminatedNeoHostCount: Int
    let terminatedLegacySimulatorCount: Int

    var rendered: String {
        guard let restoredState else {
            var lines = ["No restoration receipt exists; preferences did not change."]
            if terminatedNeoHostCount > 0 {
                lines.append(
                    "Closed NeoSimulator instances: \(terminatedNeoHostCount)"
                )
            }
            if terminatedLegacySimulatorCount > 0 {
                lines.append(
                    "Closed legacy Simulator instances: \(terminatedLegacySimulatorCount)"
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
        if terminatedNeoHostCount > 0 {
            lines.append(
                "Closed NeoSimulator instances: \(terminatedNeoHostCount)"
            )
        }
        if terminatedLegacySimulatorCount > 0 {
            lines.append(
                "Closed legacy Simulator instances: \(terminatedLegacySimulatorCount)"
            )
        }
        return lines.joined(separator: "\n")
    }
}
