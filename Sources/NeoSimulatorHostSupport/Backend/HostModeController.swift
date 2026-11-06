import Darwin
import Foundation
import NeoSimulatorDeviceIO
import NeoSimulatorKit

package struct HostModeController {
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

    package init(
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

    package nonisolated(nonsending) func routeStatus() async throws -> SimulatorRouteStatus {
        try await readStatusSnapshot {
            try await makeRouteStatus()
        }
    }

    /// Local metadata records preference only. Applying or releasing a session checks live settings;
    /// catalog polling does not open protected app containers.
    package nonisolated(nonsending) func selectionStatus() async throws -> SimulatorHostSelectionStatus {
        try await readStatusSnapshot { try makeSelectionStatus() }
    }

    private func makeSelectionStatus() throws -> SimulatorHostSelectionStatus {
        let receipt = try receiptStore.load()
        let host = try receiptStore.loadHostSelection()
            ?? receipt.map { $0.expectedCurrent == .coreSimulator ? SimulatorHost.neo : .deviceHub } ?? .neo
        return SimulatorHostSelectionStatus(host: host, restorationAvailable: receipt != nil,
            allowsAutomaticHosting: host == .neo && receipt?.pending == nil)
    }

    /// Applies the saved preference without opening a display. Screen requests start renderers as needed.
    package nonisolated(nonsending) func beginSession(xcodeURL: URL? = nil) async throws -> SimulatorHost {
        try rejectRootMutation()
        return try await receiptStore.withExclusiveLock {
            let host = try makeSelectionStatus().host
            _ = try await apply(host, xcodeURL: xcodeURL, launchDisplay: false, initialDeviceIdentifier: nil)
            return host
        }
    }

    /// Opens the chosen host without reapplying or inspecting Xcode's preferences.
    package nonisolated(nonsending) func launch(_ host: SimulatorHost, xcodeURL: URL?, initialDeviceIdentifier: String? = nil) async throws {
        let xcode = try await installationInspector.validatedTargetXcode(at: xcodeURL)
        switch host {
        case .neo:
            let renderer = try await installationInspector.validatedNeoHost(for: xcode)
            _ = try await workspace.openNeoHost(renderer.applicationURL, xcode.applicationURL, initialDeviceIdentifier)
        case .deviceHub:
            _ = try await workspace.openDeviceHub(xcode.deviceHubApplicationURL)
        }
    }

    private nonisolated(nonsending) func readStatusSnapshot<T>(_ makeSnapshot: () async throws -> T) async throws -> T {
        if try !receiptStore.stateDirectoryExists() {
            let snapshot = try await makeSnapshot()
            if try !receiptStore.stateDirectoryExists() {
                return snapshot
            }
        }

        return try await receiptStore.withExistingExclusiveLock {
            try await makeSnapshot()
        }
    }

    package nonisolated(nonsending) func use(_ request: SimulatorHost, xcodeURL: URL? = nil, launchDisplay: Bool = true, initialDeviceIdentifier: String? = nil) async throws -> ModeChangeReport {
        try rejectRootMutation()
        return try await receiptStore.withExclusiveLock {
            try await apply(request, xcodeURL: xcodeURL, launchDisplay: launchDisplay,
                            initialDeviceIdentifier: initialDeviceIdentifier)
        }
    }

    nonisolated(nonsending) private func apply(_ request: SimulatorHost, xcodeURL: URL?, launchDisplay: Bool,
                                             initialDeviceIdentifier: String?) async throws -> ModeChangeReport {
        let xcode = try await installationInspector.validatedTargetXcode(at: xcodeURL)
        let host: ResolvedHost = switch request {
        case .neo: .neo(try await installationInspector.validatedNeoHost(for: xcode))
        case .deviceHub: .deviceHub
        }
        _ = try await recoverManagedContext()
        let terminatedNeo = request == .deviceHub
            ? try await workspace.terminateNeoHosts(installationInspector.neoHostApplicationURL()) : 0
        let didChange = try await transition(to: host.mode.targetState, capturingWith: xcode)
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
            let observed = try await defaultsStore.readState()
            guard observed == host.mode.targetState else {
                throw conflictError(expected: host.mode.targetState, observed: observed)
            }
            switch host {
            case .neo(let renderer):
                if launchDisplay { _ = try await workspace.openNeoHost(renderer.applicationURL, xcode.applicationURL, initialDeviceIdentifier) }
            case .deviceHub:
                if launchDisplay { _ = try await workspace.openDeviceHub(xcode.deviceHubApplicationURL) }
            }
        } catch {
            let identifier = (error as? HostOperationError)?.identifier == "preference-conflict"
                ? "\(host.mode.rawValue)-host-invalidated" : "\(host.mode.rawValue)-host-launch-partial-success"
            throw hostPartialSuccessError(receiptURL: receiptURL, identifier: identifier, error: error, message: "\(host.mode.rawValue) mode is configured, but its UI host could not be opened")
        }
        return ModeChangeReport(host: host, didChangePreferences: didChange, xcode: xcode, receiptURL: receiptURL, terminatedDeviceHubCount: terminatedDeviceHub, terminatedNeoHostCount: terminatedNeo)
    }

    package nonisolated(nonsending) func restore(force: Bool = false) async throws -> RestoreReport {
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
            if force { _ = try await defaultsStore.readState() } else { _ = try await recoverManagedContext() }
            let terminatedNeo = originalReceipt.original.effectiveRoute == .deviceHub
                ? try await workspace.terminateNeoHosts(installationInspector.neoHostApplicationURL()) : 0
            if force {
                return try await forceRestore(originalReceipt, terminatedNeoHostCount: terminatedNeo)
            }
            guard let receipt = try await recoverManagedContext().receipt else {
                return RestoreReport(didRestore: false, restoredState: nil, receiptURL: receiptStore.receiptURL, terminatedNeoHostCount: terminatedNeo)
            }
            let didChange = try await transition(to: receipt.original, capturingWith: nil)
            return RestoreReport(didRestore: didChange, restoredState: receipt.original, receiptURL: receiptStore.receiptURL, terminatedNeoHostCount: terminatedNeo)
        }
    }

    private nonisolated(nonsending) func makeRouteStatus() async throws -> SimulatorRouteStatus {
        let preferences = try await defaultsStore.readState()
        let receipt = try receiptStore.load()
        return SimulatorRouteStatus(
            preferences: preferences,
            receiptStatus: classify(receipt: receipt, observed: preferences)
        )
    }

    private nonisolated(nonsending) func transition(
        to target: ManagedPreferenceState,
        capturingWith xcode: XcodeInstallation?
    ) async throws -> Bool {
        var context = try await recoverManagedContext()
        let before = context.observed

        if context.receipt == nil {
            guard before != target else {
                return false
            }
            guard let xcode else {
                throw HostOperationError.software(
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
            throw HostOperationError.software(
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
            _ = try await defaultsStore.apply(target, from: before)
        } catch let mismatch as DefaultsStore.StateMismatch {
            throw conflictError(
                expected: mismatch.expected.first ?? before,
                observed: mismatch.observed
            )
        } catch {
            try await rollback(
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

    private nonisolated(nonsending) func recoverManagedContext() async throws -> ManagedContext {
        guard var receipt = try receiptStore.load() else {
            return ManagedContext(
                receipt: nil,
                observed: try await defaultsStore.readState()
            )
        }

        let observed = try await defaultsStore.readState()
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
                throw HostOperationError.configuration(
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

    private nonisolated(nonsending) func forceRestore(
        _ receipt: RestorationReceipt,
        terminatedNeoHostCount: Int
    ) async throws -> RestoreReport {
        let observed = try await defaultsStore.readState()
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
            _ = try await defaultsStore.apply(receipt.original, from: observed)
        } catch let mismatch as DefaultsStore.StateMismatch {
            throw conflictError(expected: observed, observed: mismatch.observed)
        } catch {
            try await rollback(
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

    private nonisolated(nonsending) func rollback(
        after primaryError: any Error,
        to before: ManagedPreferenceState,
        attemptedTarget: ManagedPreferenceState,
        receipt: RestorationReceipt
    ) async throws -> Never {
        do {
            _ = try await defaultsStore.rollback(
                to: before,
                fromAttemptedTarget: attemptedTarget
            )
        } catch let mismatch as DefaultsStore.StateMismatch {
            throw HostOperationError.configuration(
                "inconsistent-preferences",
                "transition failed (\(errorMessage(primaryError))) and rollback refused to overwrite an unexpected state (\(mismatch.observed)). Recovery data remains at \(receiptStore.receiptURL.path)"
            )
        } catch {
            throw HostOperationError.configuration(
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
            throw HostOperationError.io(
                "rollback-receipt",
                "preferences were rolled back after \(errorMessage(primaryError)), but recovery metadata could not be finalized: \(errorMessage(error))"
            )
        }

        throw HostOperationError.io(
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
            throw HostOperationError.configuration(
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
    ) -> HostOperationError {
        let recoveryGuidance = if receiptURL != nil {
            "The preferences remain managed; use Restore Original Settings… to undo them."
        } else {
            "No restoration receipt exists because these are the original preferences."
        }

        return HostOperationError(
            category: (error as? HostOperationError)?.category ?? .io,
            identifier: identifier,
            message: "\(message): \(errorMessage(error)). \(recoveryGuidance)",
            failureReason: (error as? any LocalizedError)?.failureReason,
            recoverySuggestion: (error as? any LocalizedError)?.recoverySuggestion.map { "\($0) \(recoveryGuidance)" }
        )
    }

    private func conflictError(
        expected: ManagedPreferenceState,
        observed: ManagedPreferenceState
    ) -> HostOperationError {
        HostOperationError.configuration(
            "preference-conflict",
            "managed preferences changed outside this tool; expected \(expected), observed \(observed). Inspect \(receiptStore.receiptURL.path) before recovering."
        )
    }

    private func errorMessage(_ error: any Error) -> String {
        if let error = error as? HostOperationError {
            return error.message
        }
        return error.localizedDescription
    }
}
