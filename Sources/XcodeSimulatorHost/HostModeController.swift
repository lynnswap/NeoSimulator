import Darwin
import Foundation

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

    /// Local metadata records intent only. External changes are checked by use/restore,
    /// so ordinary startup and catalog polling do not open protected app containers.
    func selectionStatus() throws -> SimulatorHostSelectionStatus {
        try readStatusSnapshot {
            let receipt = try receiptStore.load()
            let host = try receipt.map { $0.expectedCurrent == .coreSimulator ? SimulatorHost.neo : .deviceHub }
                ?? receiptStore.loadHostSelection() ?? .deviceHub
            return SimulatorHostSelectionStatus(host: host, restorationAvailable: receipt != nil,
                allowsAutomaticHosting: host == .neo && receipt?.pending == nil)
        }
    }

    /// Opens the chosen host without reapplying or inspecting Xcode's preferences.
    nonisolated(nonsending) func launch(_ host: SimulatorHost, xcodeURL: URL?, initialDeviceIdentifier: String? = nil) async throws {
        let xcode = try installationInspector.validatedTargetXcode(at: xcodeURL)
        switch host {
        case .neo:
            let renderer = try installationInspector.validatedNeoHost(for: xcode)
            _ = try await workspace.openNeoHost(renderer.applicationURL, xcode.applicationURL, initialDeviceIdentifier)
        case .deviceHub:
            _ = try await workspace.openDeviceHub(xcode.deviceHubApplicationURL)
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

    nonisolated(nonsending) func use(_ request: SimulatorHost, xcodeURL: URL? = nil, launchNeoHost: Bool = true, initialDeviceIdentifier: String? = nil) async throws -> ModeChangeReport {
        try rejectRootMutation()
        return try await receiptStore.withExclusiveLock {
            let xcode = try installationInspector.validatedTargetXcode(at: xcodeURL)
            let host: ResolvedHost = switch request {
            case .neo: .neo(try installationInspector.validatedNeoHost(for: xcode))
            case .deviceHub: .deviceHub
            }
            _ = try recoverManagedContext()
            let terminatedNeo = request == .deviceHub
                ? try await workspace.terminateNeoHosts(installationInspector.neoHostApplicationURL()) : 0
            let didChange = try transition(to: host.mode.targetState, capturingWith: xcode)
            let receiptURL = try receiptStore.load() == nil ? nil : receiptStore.receiptURL
            do { try receiptStore.saveHostSelection(request) }
            catch {
                throw hostPartialSuccessError(receiptURL: receiptURL, identifier: "host-selection-partial-success", error: error,
                    message: "The route is configured, but the display choice could not be saved and its UI host was not opened")
            }
            var terminatedDeviceHub = 0
            if case .neo = host {
                do {
                    terminatedDeviceHub = try await workspace.terminateDeviceHubs(xcode.deviceHubApplicationURL)
                } catch {
                    throw hostPartialSuccessError(receiptURL: receiptURL, identifier: "device-hub-termination-partial-success", error: error, message: "NeoSimulator mode is configured, but Device Hub could not be closed and the renderer was not opened")
                }
            }
            do {
                let observed = try defaultsStore.readState()
                guard observed == host.mode.targetState else {
                    throw conflictError(expected: host.mode.targetState, observed: observed)
                }
                switch host {
                case .neo(let renderer):
                    if launchNeoHost { _ = try await workspace.openNeoHost(renderer.applicationURL, xcode.applicationURL, initialDeviceIdentifier) }
                case .deviceHub: _ = try await workspace.openDeviceHub(xcode.deviceHubApplicationURL)
                }
            } catch {
                let identifier = (error as? CLIError)?.identifier == "preference-conflict"
                    ? "\(host.mode.rawValue)-host-invalidated" : "\(host.mode.rawValue)-host-launch-partial-success"
                throw hostPartialSuccessError(receiptURL: receiptURL, identifier: identifier, error: error, message: "\(host.mode.rawValue) mode is configured, but its UI host could not be opened")
            }
            return ModeChangeReport(host: host, didChangePreferences: didChange, xcode: xcode, receiptURL: receiptURL, terminatedDeviceHubCount: terminatedDeviceHub, terminatedNeoHostCount: terminatedNeo)
        }
    }

    nonisolated(nonsending) func restore(force: Bool = false) async throws -> RestoreReport {
        try rejectRootMutation()
        guard try receiptStore.stateDirectoryExists() else {
            return RestoreReport(didRestore: false, restoredState: nil, receiptURL: receiptStore.receiptURL, terminatedNeoHostCount: 0)
        }
        return try await receiptStore.withExistingExclusiveLock {
            guard let originalReceipt = try receiptStore.load() else {
                try receiptStore.saveHostSelection(.deviceHub)
                return RestoreReport(didRestore: false, restoredState: nil, receiptURL: receiptStore.receiptURL, terminatedNeoHostCount: 0)
            }
            // The receipt remains authoritative until recovery succeeds. Persist the
            // post-restore choice before recovery can remove that receipt.
            try receiptStore.saveHostSelection(.deviceHub)
            if force { _ = try defaultsStore.readState() } else { _ = try recoverManagedContext() }
            let terminatedNeo = originalReceipt.original.effectiveRoute == .deviceHub
                ? try await workspace.terminateNeoHosts(installationInspector.neoHostApplicationURL()) : 0
            if force {
                return try forceRestore(originalReceipt, terminatedNeoHostCount: terminatedNeo)
            }
            guard let receipt = try recoverManagedContext().receipt else {
                return RestoreReport(didRestore: false, restoredState: nil, receiptURL: receiptStore.receiptURL, terminatedNeoHostCount: terminatedNeo)
            }
            let didChange = try transition(to: receipt.original, capturingWith: nil)
            return RestoreReport(didRestore: didChange, restoredState: receipt.original, receiptURL: receiptStore.receiptURL, terminatedNeoHostCount: terminatedNeo)
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
                    "the live preferences match a possible interrupted write, but the tool cannot distinguish that from an external change. Nothing was overwritten. Inspect \(receiptStore.receiptURL.path), then choose Restore Original Settings…, then Restore Saved Values… only if the saved original should win."
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
        terminatedNeoHostCount: Int
    ) throws -> RestoreReport {
        let observed = try defaultsStore.readState()
        guard observed != receipt.original else {
            try receiptStore.deleteReceipt()
            return RestoreReport(
                didRestore: false,
                restoredState: receipt.original,
                receiptURL: receiptStore.receiptURL,
                terminatedNeoHostCount: terminatedNeoHostCount
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
            terminatedNeoHostCount: terminatedNeoHostCount
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
                "NeoSimulator manages per-user Xcode preferences and cannot change them while running as root."
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
            "The preferences remain managed; use Restore Original Settings… to undo them."
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
