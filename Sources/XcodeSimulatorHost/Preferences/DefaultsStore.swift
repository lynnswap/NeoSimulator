import CoreFoundation
import Foundation

protocol PreferenceDomainAccessing {
    func readDomain(_ domain: String, keys: [String]) throws -> [String: Any]
    func write(_ value: StoredBoolean, to preference: ManagedPreference) throws
}

struct SystemPreferenceDomains: PreferenceDomainAccessing {
    private let runner: any CommandRunning
    init(runner: any CommandRunning = SystemCommandRunner()) { self.runner = runner }

    func readDomain(_ domain: String, keys: [String]) throws -> [String: Any] {
        let output = try run(["export", domain, "-"], operation: "read")
        let values = try PropertyListSerialization.propertyList(from: output, options: [], format: nil)
        guard let dictionary = values as? [String: Any] else {
            throw CLIError.configuration("preference-domain-type", "Preferences for \(domain) are not a dictionary with String keys.")
        }
        return dictionary.filter { keys.contains($0.key) }
    }

    func write(_ value: StoredBoolean, to preference: ManagedPreference) throws {
        let arguments = value.booleanValue.map {
            ["write", preference.domain, preference.key, "-bool", $0 ? "true" : "false"]
        } ?? ["delete", preference.domain, preference.key]
        _ = try run(arguments, operation: "write")
    }

    private func run(_ arguments: [String], operation: String) throws -> Data {
        let output = try runner.run(executable: URL(fileURLWithPath: "/usr/bin/defaults"), arguments: arguments)
        guard output.terminationStatus == 0 else {
            throw CLIError.io("preference-\(operation)", output.stderrText)
        }
        return output.stdout
    }
}

struct DefaultsStore {
    struct StateMismatch: Error, Equatable {
        let expected: [ManagedPreferenceState]
        let observed: ManagedPreferenceState
    }

    private struct MutationStep {
        let preference: ManagedPreference
        let value: StoredBoolean
        let resultingState: ManagedPreferenceState
    }

    private let domains: any PreferenceDomainAccessing

    init(domains: any PreferenceDomainAccessing = SystemPreferenceDomains()) {
        self.domains = domains
    }

    func readState() throws -> ManagedPreferenceState {
        return ManagedPreferenceState(
            xcodeSession: try read(
                ToolConstants.xcodePreference
            ),
            deviceHubAutoStartSuppression: try read(
                ToolConstants.deviceHubPreference
            )
        )
    }

    @discardableResult
    func apply(
        _ target: ManagedPreferenceState,
        from expected: ManagedPreferenceState
    ) throws -> Bool {
        try apply(target, allowedCurrentStates: [expected])
    }

    func rollback(
        to before: ManagedPreferenceState,
        fromAttemptedTarget target: ManagedPreferenceState
    ) throws -> Bool {
        return try apply(
            before,
            allowedCurrentStates: [
                before,
                stateAfterXcodePreference(from: before, to: target),
                target,
            ]
        )
    }

    func isAmbiguousIntermediate(
        _ observed: ManagedPreferenceState,
        from before: ManagedPreferenceState,
        to target: ManagedPreferenceState
    ) -> Bool {
        let intermediate = stateAfterXcodePreference(from: before, to: target)
        return intermediate != before
            && intermediate != target
            && observed == intermediate
    }

    private func apply(
        _ target: ManagedPreferenceState,
        allowedCurrentStates: [ManagedPreferenceState]
    ) throws -> Bool {
        let current = try readState()
        guard allowedCurrentStates.contains(current) else {
            throw StateMismatch(
                expected: allowedCurrentStates,
                observed: current
            )
        }

        let steps = mutationSteps(from: current, to: target)
        var expected = current
        for step in steps {
            let observed = try readState()
            guard observed == expected else {
                throw StateMismatch(expected: [expected], observed: observed)
            }
            try write(step.value, to: step.preference)
            expected = step.resultingState
        }

        let observed = try readState()
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

    private func read(_ preference: ManagedPreference) throws -> StoredBoolean {
        let domain = try domains.readDomain(preference.domain, keys: [preference.key])
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

    private func write(_ value: StoredBoolean, to preference: ManagedPreference) throws {
        try domains.write(value, to: preference)
    }
}
