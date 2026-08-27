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

    func status(explicitLegacyXcodeURL: URL?) throws -> HostStatus {
        try receiptStore.withExclusiveLock {
            let xcode = try installationInspector.validatedTargetXcode()
            let preferences = try defaultsStore.readState()
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

            let receipt = try receiptStore.load()
            let receiptStatus = classify(receipt: receipt, observed: preferences)
            return HostStatus(
                xcode: xcode,
                preferences: preferences,
                legacySimulator: legacySimulator,
                receiptStatus: receiptStatus,
                receiptURL: receiptStore.receiptURL,
                runningXcodes: workspace.runningXcodes()
            )
        }
    }

    func use(
        mode: HostMode,
        explicitLegacyXcodeURL: URL?
    ) async throws -> ModeChangeReport {
        try rejectRootMutation()

        let prepared = try receiptStore.withExclusiveLock {
            let xcode = try installationInspector.validatedTargetXcode()
            let simulator: SimulatorInstallation?
            switch mode {
            case .legacy:
                simulator = try installationInspector.legacySimulator(
                    explicitXcodeURL: explicitLegacyXcodeURL
                )
            case .deviceHub:
                simulator = nil
            }

            try rejectRunningXcodes()

            let didChange = try transition(
                to: mode.targetState,
                capturingWith: xcode
            )
            let receiptURL: URL? = try receiptStore.load() == nil
                ? nil
                : receiptStore.receiptURL
            return (
                xcode: xcode,
                simulator: simulator,
                didChange: didChange,
                receiptURL: receiptURL
            )
        }

        if let simulator = prepared.simulator {
            do {
                _ = try await workspace.openApplication(simulator.applicationURL)
            } catch {
                let detail = errorMessage(error)
                let recoveryGuidance: String
                if prepared.receiptURL != nil {
                    recoveryGuidance = "The preferences remain managed; run restore to undo them."
                } else {
                    recoveryGuidance = "No restoration receipt exists because these are the original preferences."
                }
                throw CLIError.io(
                    "simulator-launch-partial-success",
                    "legacy mode is configured, but Simulator could not be opened: \(detail). \(recoveryGuidance)"
                )
            }
        }

        return ModeChangeReport(
            mode: mode,
            didChange: prepared.didChange,
            xcode: prepared.xcode,
            simulator: prepared.simulator,
            receiptURL: prepared.receiptURL
        )
    }

    func restore(force: Bool = false) throws -> RestoreReport {
        try rejectRootMutation()

        return try receiptStore.withExclusiveLock {
            guard let receipt = try receiptStore.load() else {
                return RestoreReport(
                    didRestore: false,
                    restoredState: nil,
                    receiptURL: receiptStore.receiptURL
                )
            }
            try rejectRunningXcodes()

            if force {
                return try forceRestore(receipt)
            }

            let context = try recoverManagedContext()
            guard let receipt = context.receipt else {
                return RestoreReport(
                    didRestore: false,
                    restoredState: nil,
                    receiptURL: receiptStore.receiptURL
                )
            }

            let didChange = try transition(
                to: receipt.original,
                capturingWith: nil
            )
            return RestoreReport(
                didRestore: didChange,
                restoredState: receipt.original,
                receiptURL: receiptStore.receiptURL
            )
        }
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
                expected: before,
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

    private func forceRestore(_ receipt: RestorationReceipt) throws -> RestoreReport {
        let observed = try defaultsStore.readState()
        guard observed != receipt.original else {
            try receiptStore.deleteReceipt()
            return RestoreReport(
                didRestore: false,
                restoredState: receipt.original,
                receiptURL: receiptStore.receiptURL
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
            receiptURL: receiptStore.receiptURL
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

    private func rejectRunningXcodes() throws {
        let runningXcodes = workspace.runningXcodes()
        guard runningXcodes.isEmpty else {
            let details = runningXcodes.map { application in
                application.bundleURL?.path ?? "pid \(application.processIdentifier)"
            }.joined(separator: ", ")
            throw CLIError.temporary(
                "xcode-running",
                "quit every Xcode process before changing modes: \(details)"
            )
        }
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
