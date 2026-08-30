import Darwin
import Foundation

@MainActor
struct HostModeController {
    private struct ManagedContext {
        var receipt: RestorationReceipt?
        let observed: ManagedPreferenceState
    }

    private let defaultsStore: DefaultsStore
    private let receiptStore: ReceiptStore
    private let installationInspector: InstallationInspector
    private let workspace: WorkspaceClient
    private let now: () -> Date
    private let effectiveUserID: uid_t

    init(
        defaultsStore: DefaultsStore,
        receiptStore: ReceiptStore,
        installationInspector: InstallationInspector,
        workspace: WorkspaceClient,
        now: @escaping () -> Date = Date.init,
        effectiveUserID: uid_t = Darwin.geteuid()
    ) {
        self.defaultsStore = defaultsStore
        self.receiptStore = receiptStore
        self.installationInspector = installationInspector
        self.workspace = workspace
        self.now = now
        self.effectiveUserID = effectiveUserID
    }

    func routeStatus() throws -> SimulatorRouteStatus {
        try readStatusSnapshot {
            try makeRouteStatus()
        }
    }

    func status(explicitLegacyXcodeURL: URL?) throws -> HostStatus {
        try readStatusSnapshot {
            try makeStatus(explicitLegacyXcodeURL: explicitLegacyXcodeURL)
        }
    }

    private func readStatusSnapshot<T>(_ makeSnapshot: () throws -> T) throws -> T {
        if try !receiptStore.stateDirectoryExists() {
            let snapshot = try makeSnapshot()
            if try !receiptStore.stateDirectoryExists() {
                return snapshot
            }
        }

        return try receiptStore.withExistingExclusiveLock {
            try makeSnapshot()
        }
    }

    func use(_ request: HostRequest) async throws -> ModeChangeReport {
        try rejectRootMutation()

        return try await receiptStore.withExclusiveLock {
            let xcode = try installationInspector.validatedTargetXcode()
            let host: ResolvedHost = switch request {
            case .neo:
                .neo(try installationInspector.validatedNeoHost(for: xcode))
            case .legacy(let explicitXcodeURL):
                .legacy(
                    try installationInspector.legacySimulator(
                        explicitXcodeURL: explicitXcodeURL
                    )
                )
            case .deviceHub:
                .deviceHub
            }

            // Process lifecycle changes are not part of the preference rollback.
            // Resolve every process identity and reject an existing receipt conflict
            // before closing a healthy host.
            let runningLegacySimulatorURLs = try validatedRunningLegacySimulatorURLs()
            _ = try recoverManagedContext()
            let terminatedHosts = try await closeUIHosts(
                for: host,
                runningLegacySimulatorURLs: runningLegacySimulatorURLs
            )

            let didChangePreferences = try transition(
                to: host.mode.targetState,
                capturingWith: xcode
            )
            let receiptURL: URL? = try receiptStore.load() == nil
                ? nil
                : receiptStore.receiptURL

            let terminatedDeviceHubCount: Int
            switch host {
            case .deviceHub:
                terminatedDeviceHubCount = 0

            case .neo, .legacy:
                do {
                    terminatedDeviceHubCount = try await workspace.terminateDeviceHubs(
                        xcode.deviceHubApplicationURL
                    )
                } catch {
                    throw hostPartialSuccessError(
                        receiptURL: receiptURL,
                        identifier: "device-hub-termination-partial-success",
                        error: error,
                        message: "\(host.mode.rawValue) mode is configured, but Device Hub could not be closed and its UI host was not opened"
                    )
                }

                do {
                    let observed = try defaultsStore.readState()
                    guard observed == host.mode.targetState else {
                        throw conflictError(
                            expected: host.mode.targetState,
                            observed: observed
                        )
                    }
                    switch host {
                    case .neo(let neoHost):
                        _ = try await workspace.openNeoHost(
                            neoHost.applicationURL,
                            xcode.applicationURL
                        )
                    case .legacy(let simulator):
                        _ = try await workspace.openLegacySimulator(
                            simulator.applicationURL
                        )
                    case .deviceHub:
                        break
                    }
                } catch {
                    let identifier = if (error as? CLIError)?.identifier
                        == "preference-conflict"
                    {
                        "\(host.mode.rawValue)-host-invalidated"
                    } else {
                        "\(host.mode.rawValue)-host-launch-partial-success"
                    }
                    throw hostPartialSuccessError(
                        receiptURL: receiptURL,
                        identifier: identifier,
                        error: error,
                        message: "\(host.mode.rawValue) mode is configured, but its UI host could not be opened"
                    )
                }
            }

            return ModeChangeReport(
                host: host,
                didChangePreferences: didChangePreferences,
                xcode: xcode,
                receiptURL: receiptURL,
                terminatedDeviceHubCount: terminatedDeviceHubCount,
                terminatedNeoHostCount: terminatedHosts.neo,
                terminatedLegacySimulatorCount: terminatedHosts.legacy
            )
        }
    }

    func restore(force: Bool = false) async throws -> RestoreReport {
        try rejectRootMutation()

        guard try receiptStore.stateDirectoryExists() else {
            return RestoreReport(
                didRestore: false,
                restoredState: nil,
                receiptURL: receiptStore.receiptURL,
                terminatedNeoHostCount: 0,
                terminatedLegacySimulatorCount: 0
            )
        }

        return try await receiptStore.withExistingExclusiveLock {
            guard let receipt = try receiptStore.load() else {
                return RestoreReport(
                    didRestore: false,
                    restoredState: nil,
                    receiptURL: receiptStore.receiptURL,
                    terminatedNeoHostCount: 0,
                    terminatedLegacySimulatorCount: 0
                )
            }

            if force {
                // Validate the live tri-state values before closing the host. A
                // force restore may intentionally proceed through a receipt conflict.
                _ = try defaultsStore.readState()
            } else {
                _ = try recoverManagedContext()
            }
            let terminatedHosts: (neo: Int, legacy: Int)
            if receipt.original.effectiveRoute == .deviceHub {
                let runningLegacySimulatorURLs = try validatedRunningLegacySimulatorURLs()
                terminatedHosts = try await closeUIHosts(
                    for: .deviceHub,
                    runningLegacySimulatorURLs: runningLegacySimulatorURLs
                )
            } else {
                terminatedHosts = (0, 0)
            }
            if force {
                return try forceRestore(
                    receipt,
                    terminatedNeoHostCount: terminatedHosts.neo,
                    terminatedLegacySimulatorCount: terminatedHosts.legacy
                )
            }

            let context = try recoverManagedContext()
            guard let receipt = context.receipt else {
                return RestoreReport(
                    didRestore: false,
                    restoredState: nil,
                    receiptURL: receiptStore.receiptURL,
                    terminatedNeoHostCount: terminatedHosts.neo,
                    terminatedLegacySimulatorCount: terminatedHosts.legacy
                )
            }

            let didChange = try transition(
                to: receipt.original,
                capturingWith: nil
            )
            return RestoreReport(
                didRestore: didChange,
                restoredState: receipt.original,
                receiptURL: receiptStore.receiptURL,
                terminatedNeoHostCount: terminatedHosts.neo,
                terminatedLegacySimulatorCount: terminatedHosts.legacy
            )
        }
    }

    private func makeStatus(explicitLegacyXcodeURL: URL?) throws -> HostStatus {
        let xcode = try installationInspector.validatedTargetXcode()
        let routeStatus = try makeRouteStatus()
        let neoHost = try? installationInspector.validatedNeoHost(for: xcode)
        let legacySimulator: SimulatorInstallation?
        if let explicitLegacyXcodeURL {
            legacySimulator = try installationInspector.legacySimulator(
                explicitXcodeURL: explicitLegacyXcodeURL
            )
        } else {
            legacySimulator = try? installationInspector.legacySimulator(
                explicitXcodeURL: nil
            )
        }
        return HostStatus(
            xcode: xcode,
            routeStatus: routeStatus,
            neoHost: neoHost,
            legacySimulator: legacySimulator,
            receiptURL: receiptStore.receiptURL,
            runningXcodes: workspace.runningXcodes(),
            runningNeoHosts: workspace.runningNeoHosts(),
            runningLegacySimulators: workspace.runningLegacySimulators()
        )
    }

    private func validatedRunningLegacySimulatorURLs() throws -> [URL] {
        var urls = Set<URL>()
        for application in workspace.runningLegacySimulators() {
            guard application.bundleIdentifier == ToolConstants.simulatorBundleIdentifier,
                  let bundleURL = application.bundleURL
            else {
                throw CLIError.configuration(
                    "legacy-simulator-identity",
                    "refusing to manage legacy Simulator pid \(application.processIdentifier) because its process identity is incomplete"
                )
            }
            let installation = try installationInspector.validatedLegacySimulator(
                at: bundleURL
            )
            urls.insert(installation.applicationURL)
        }
        return urls.sorted { $0.path < $1.path }
    }

    private func closeUIHosts(
        for target: ResolvedHost,
        runningLegacySimulatorURLs: [URL]
    ) async throws -> (neo: Int, legacy: Int) {
        let neoHostURL = try installationInspector.neoHostApplicationURL()
        switch target {
        case .neo:
            let legacy = try await workspace.terminateLegacySimulators(
                runningLegacySimulatorURLs
            )
            let neo = try await workspace.terminateNeoHosts(neoHostURL)
            return (neo, legacy)

        case .legacy, .deviceHub:
            let neo = try await workspace.terminateNeoHosts(neoHostURL)
            let legacy = try await workspace.terminateLegacySimulators(
                runningLegacySimulatorURLs
            )
            return (neo, legacy)
        }
    }

    private func makeRouteStatus() throws -> SimulatorRouteStatus {
        let preferences = try defaultsStore.readState()
        let receipt = try receiptStore.load()
        return SimulatorRouteStatus(
            preferences: preferences,
            receiptStatus: classify(receipt: receipt, observed: preferences)
        )
    }

    private func transition(
        to target: ManagedPreferenceState,
        capturingWith xcode: XcodeInstallation?
    ) throws -> Bool {
        var context = try recoverManagedContext()
        let before = context.observed

        if context.receipt == nil {
            guard before != target else {
                return false
            }
            guard let xcode else {
                throw CLIError.software(
                    "missing-capture-xcode",
                    "a new restoration receipt requires a validated Xcode"
                )
            }
            let receipt = RestorationReceipt(
                capturedAt: now(),
                xcode: xcode,
                original: before
            )
            try receiptStore.save(receipt)
            context.receipt = receipt
        }

        guard var receipt = context.receipt else {
            throw CLIError.software(
                "missing-receipt",
                "preference transition lost its restoration receipt"
            )
        }
        guard before == receipt.expectedCurrent else {
            throw conflictError(expected: receipt.expectedCurrent, observed: before)
        }
        guard before != target else {
            return false
        }

        receipt.pending = PendingMutation(before: before, target: target)
        try receiptStore.save(receipt)

        do {
            _ = try defaultsStore.apply(target, from: before)
        } catch let mismatch as DefaultsStore.StateMismatch {
            throw conflictError(
                expected: mismatch.expected.first ?? before,
                observed: mismatch.observed
            )
        } catch {
            try rollback(
                after: error,
                to: before,
                attemptedTarget: target,
                receipt: receipt
            )
        }

        if target == receipt.original {
            try receiptStore.deleteReceipt()
        } else {
            receipt.expectedCurrent = target
            receipt.pending = nil
            try receiptStore.save(receipt)
        }
        return true
    }

    private func recoverManagedContext() throws -> ManagedContext {
        guard var receipt = try receiptStore.load() else {
            return ManagedContext(
                receipt: nil,
                observed: try defaultsStore.readState()
            )
        }

        let observed = try defaultsStore.readState()
        if let pending = receipt.pending {
            if observed == pending.before {
                if observed == receipt.original {
                    try receiptStore.deleteReceipt()
                    return ManagedContext(
                        receipt: nil,
                        observed: observed
                    )
                }
                receipt.expectedCurrent = observed
                receipt.pending = nil
                try receiptStore.save(receipt)
                return ManagedContext(
                    receipt: receipt,
                    observed: observed
                )
            }
            if observed == pending.target {
                if observed == receipt.original {
                    try receiptStore.deleteReceipt()
                    return ManagedContext(
                        receipt: nil,
                        observed: observed
                    )
                }
                receipt.expectedCurrent = observed
                receipt.pending = nil
                try receiptStore.save(receipt)
                return ManagedContext(
                    receipt: receipt,
                    observed: observed
                )
            }
            if defaultsStore.isAmbiguousIntermediate(
                observed,
                from: pending.before,
                to: pending.target
            ) {
                throw CLIError.configuration(
                    "ambiguous-intermediate",
                    "the live preferences match a possible interrupted write, but the tool cannot distinguish that from an external change. Nothing was overwritten. Inspect \(receiptStore.receiptURL.path), then use restore --force only if the saved original should win."
                )
            }
            throw conflictError(
                expected: receipt.expectedCurrent,
                observed: observed
            )
        }

        guard observed == receipt.expectedCurrent else {
            throw conflictError(expected: receipt.expectedCurrent, observed: observed)
        }
        if observed == receipt.original {
            try receiptStore.deleteReceipt()
            return ManagedContext(
                receipt: nil,
                observed: observed
            )
        }
        return ManagedContext(
            receipt: receipt,
            observed: observed
        )
    }

    private func forceRestore(
        _ receipt: RestorationReceipt,
        terminatedNeoHostCount: Int,
        terminatedLegacySimulatorCount: Int
    ) throws -> RestoreReport {
        let observed = try defaultsStore.readState()
        guard observed != receipt.original else {
            try receiptStore.deleteReceipt()
            return RestoreReport(
                didRestore: false,
                restoredState: receipt.original,
                receiptURL: receiptStore.receiptURL,
                terminatedNeoHostCount: terminatedNeoHostCount,
                terminatedLegacySimulatorCount: terminatedLegacySimulatorCount
            )
        }

        var forcedReceipt = receipt
        forcedReceipt.expectedCurrent = observed
        forcedReceipt.pending = PendingMutation(
            before: observed,
            target: receipt.original
        )
        try receiptStore.save(forcedReceipt)

        do {
            _ = try defaultsStore.apply(receipt.original, from: observed)
        } catch let mismatch as DefaultsStore.StateMismatch {
            throw conflictError(expected: observed, observed: mismatch.observed)
        } catch {
            try rollback(
                after: error,
                to: observed,
                attemptedTarget: receipt.original,
                receipt: forcedReceipt
            )
        }

        try receiptStore.deleteReceipt()
        return RestoreReport(
            didRestore: true,
            restoredState: receipt.original,
            receiptURL: receiptStore.receiptURL,
            terminatedNeoHostCount: terminatedNeoHostCount,
            terminatedLegacySimulatorCount: terminatedLegacySimulatorCount
        )
    }

    private func rollback(
        after primaryError: any Error,
        to before: ManagedPreferenceState,
        attemptedTarget: ManagedPreferenceState,
        receipt: RestorationReceipt
    ) throws -> Never {
        do {
            _ = try defaultsStore.rollback(
                to: before,
                fromAttemptedTarget: attemptedTarget
            )
        } catch let mismatch as DefaultsStore.StateMismatch {
            throw CLIError.configuration(
                "inconsistent-preferences",
                "transition failed (\(errorMessage(primaryError))) and rollback refused to overwrite an unexpected state (\(mismatch.observed)). Recovery data remains at \(receiptStore.receiptURL.path)"
            )
        } catch {
            throw CLIError.configuration(
                "inconsistent-preferences",
                "transition failed (\(errorMessage(primaryError))) and rollback failed (\(errorMessage(error))). Recovery data remains at \(receiptStore.receiptURL.path)"
            )
        }

        do {
            if before == receipt.original {
                try receiptStore.deleteReceipt()
            } else {
                var restoredReceipt = receipt
                restoredReceipt.expectedCurrent = before
                restoredReceipt.pending = nil
                try receiptStore.save(restoredReceipt)
            }
        } catch {
            throw CLIError.io(
                "rollback-receipt",
                "preferences were rolled back after \(errorMessage(primaryError)), but recovery metadata could not be finalized: \(errorMessage(error))"
            )
        }

        throw CLIError.io(
            "transition-rolled-back",
            "preference transition failed and was rolled back: \(errorMessage(primaryError))"
        )
    }

    private func classify(
        receipt: RestorationReceipt?,
        observed: ManagedPreferenceState
    ) -> ReceiptStatus {
        guard let receipt else {
            return .unmanaged
        }
        if let pending = receipt.pending {
            if observed == pending.before {
                return .pendingBefore
            }
            if observed == pending.target {
                return .pendingTarget
            }
            if defaultsStore.isAmbiguousIntermediate(
                observed,
                from: pending.before,
                to: pending.target
            ) {
                return .ambiguousIntermediate
            }
            return .conflict(expected: receipt.expectedCurrent, observed: observed)
        }
        guard observed == receipt.expectedCurrent else {
            return .conflict(expected: receipt.expectedCurrent, observed: observed)
        }
        return .managed(original: receipt.original)
    }

    private func rejectRootMutation() throws {
        guard effectiveUserID != 0 else {
            throw CLIError.configuration(
                "root-user",
                "do not run this command with sudo; it manages per-user Xcode preferences"
            )
        }
    }

    private func hostPartialSuccessError(
        receiptURL: URL?,
        identifier: String,
        error: any Error,
        message: String
    ) -> CLIError {
        let recoveryGuidance = if receiptURL != nil {
            "The preferences remain managed; run restore to undo them."
        } else {
            "No restoration receipt exists because these are the original preferences."
        }

        return CLIError(
            category: (error as? CLIError)?.category ?? .io,
            identifier: identifier,
            message: "\(message): \(errorMessage(error)). \(recoveryGuidance)"
        )
    }

    private func conflictError(
        expected: ManagedPreferenceState,
        observed: ManagedPreferenceState
    ) -> CLIError {
        CLIError.configuration(
            "preference-conflict",
            "managed preferences changed outside this tool; expected \(expected), observed \(observed). Inspect \(receiptStore.receiptURL.path) before recovering."
        )
    }

    private func errorMessage(_ error: any Error) -> String {
        if let error = error as? CLIError {
            return error.message
        }
        return error.localizedDescription
    }
}
