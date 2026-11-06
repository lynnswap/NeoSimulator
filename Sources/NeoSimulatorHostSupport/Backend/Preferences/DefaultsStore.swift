import NeoSimulatorDeviceIO
import NeoSimulatorKit
import CoreFoundation
import Foundation

package protocol PreferenceDomainAccessing {
    nonisolated(nonsending) func readDomain(_ domain: String, keys: [String]) async throws -> [String: Any]
    nonisolated(nonsending) func write(_ value: StoredBoolean, to preference: ManagedPreference) async throws
}

package struct SystemPreferenceDomains: PreferenceDomainAccessing {
    private let runner: any CommandRunning
    package init(runner: any CommandRunning = SystemCommandRunner()) { self.runner = runner }

    package nonisolated(nonsending) func readDomain(_ domain: String, keys: [String]) async throws -> [String: Any] {
        let output = try await run(["export", domain, "-"], operation: "read")
        let values = try PropertyListSerialization.propertyList(from: output, options: [], format: nil)
        guard let dictionary = values as? [String: Any] else {
            throw CLIError.configuration("preference-domain-type", "Preferences for \(domain) are not a dictionary with String keys.")
        }
        return dictionary.filter { keys.contains($0.key) }
    }

    package nonisolated(nonsending) func write(_ value: StoredBoolean, to preference: ManagedPreference) async throws {
        let arguments = value.booleanValue.map {
            ["write", preference.domain, preference.key, "-bool", $0 ? "true" : "false"]
        } ?? ["delete", preference.domain, preference.key]
        _ = try await run(arguments, operation: "write")
    }

    /// A transaction reads and writes through here, and must be able to finish or roll back after its caller is cancelled.
    private nonisolated(nonsending) func run(_ arguments: [String], operation: String) async throws -> Data {
        let output = try await runner.run(SystemCommand(executable: URL(fileURLWithPath: "/usr/bin/defaults"), arguments: arguments, policy: .uninterrupted))
        guard output.terminationStatus == 0 else {
            throw CLIError.io("preference-\(operation)", output.stderrText)
        }
        return output.stdout
    }
}

package struct DefaultsStore {
    package struct StateMismatch: Error, Equatable {
        package let expected: [ManagedPreferenceState]
        package let observed: ManagedPreferenceState
    }

    private struct MutationStep {
        let preference: ManagedPreference
        let value: StoredBoolean
        let resultingState: ManagedPreferenceState
    }

    private let domains: any PreferenceDomainAccessing

    package init(domains: any PreferenceDomainAccessing = SystemPreferenceDomains()) {
        self.domains = domains
    }

    package nonisolated(nonsending) func readState() async throws -> ManagedPreferenceState {
        return ManagedPreferenceState(
            xcodeSession: try await read(
                ToolConstants.xcodePreference
            ),
            deviceHubAutoStartSuppression: try await read(
                ToolConstants.deviceHubPreference
            )
        )
    }

    @discardableResult
    package nonisolated(nonsending) func apply(
        _ target: ManagedPreferenceState,
        from expected: ManagedPreferenceState
    ) async throws -> Bool {
        try await apply(target, allowedCurrentStates: [expected])
    }

    package nonisolated(nonsending) func rollback(
        to before: ManagedPreferenceState,
        fromAttemptedTarget target: ManagedPreferenceState
    ) async throws -> Bool {
        return try await apply(
            before,
            allowedCurrentStates: [
                before,
                stateAfterXcodePreference(from: before, to: target),
                target,
            ]
        )
    }

    package func isAmbiguousIntermediate(
        _ observed: ManagedPreferenceState,
        from before: ManagedPreferenceState,
        to target: ManagedPreferenceState
    ) -> Bool {
        let intermediate = stateAfterXcodePreference(from: before, to: target)
        return intermediate != before
            && intermediate != target
            && observed == intermediate
    }

    private nonisolated(nonsending) func apply(
        _ target: ManagedPreferenceState,
        allowedCurrentStates: [ManagedPreferenceState]
    ) async throws -> Bool {
        let current = try await readState()
        guard allowedCurrentStates.contains(current) else {
            throw StateMismatch(
                expected: allowedCurrentStates,
                observed: current
            )
        }

        let steps = mutationSteps(from: current, to: target)
        var expected = current
        for step in steps {
            let observed = try await readState()
            guard observed == expected else {
                throw StateMismatch(expected: [expected], observed: observed)
            }
            try await write(step.value, to: step.preference)
            expected = step.resultingState
        }

        let observed = try await readState()
        guard observed == target else {
            throw StateMismatch(expected: [target], observed: observed)
        }
        return !steps.isEmpty
    }

    private func mutationSteps(
        from current: ManagedPreferenceState,
        to target: ManagedPreferenceState
    ) -> [MutationStep] {
        var state = current
        var steps: [MutationStep] = []

        if state.xcodeSession != target.xcodeSession {
            state = stateAfterXcodePreference(from: state, to: target)
            steps.append(
                MutationStep(
                    preference: ToolConstants.xcodePreference,
                    value: target.xcodeSession,
                    resultingState: state
                )
            )
        }
        if state.deviceHubAutoStartSuppression != target.deviceHubAutoStartSuppression {
            state = ManagedPreferenceState(
                xcodeSession: state.xcodeSession,
                deviceHubAutoStartSuppression: target.deviceHubAutoStartSuppression
            )
            steps.append(
                MutationStep(
                    preference: ToolConstants.deviceHubPreference,
                    value: target.deviceHubAutoStartSuppression,
                    resultingState: state
                )
            )
        }
        return steps
    }

    private func stateAfterXcodePreference(
        from before: ManagedPreferenceState,
        to target: ManagedPreferenceState
    ) -> ManagedPreferenceState {
        ManagedPreferenceState(
            xcodeSession: target.xcodeSession,
            deviceHubAutoStartSuppression: before.deviceHubAutoStartSuppression
        )
    }

    private nonisolated(nonsending) func read(_ preference: ManagedPreference) async throws -> StoredBoolean {
        let domain = try await domains.readDomain(preference.domain, keys: [preference.key])
        guard let rawValue = domain[preference.key] else {
            return .absent
        }

        let valueObject = rawValue as AnyObject
        guard CFGetTypeID(valueObject) == CFBooleanGetTypeID(),
              let number = valueObject as? NSNumber
        else {
            throw CLIError.configuration(
                "preference-value-type",
                "\(preference.domain).\(preference.key) is not Boolean"
            )
        }
        return StoredBoolean(number.boolValue)
    }

    private nonisolated(nonsending) func write(_ value: StoredBoolean, to preference: ManagedPreference) async throws {
        try await domains.write(value, to: preference)
    }
}
