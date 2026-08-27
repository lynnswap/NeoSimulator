import CoreFoundation
import Foundation

struct DefaultsStore {
    struct StateMismatch: Error, Equatable {
        let expected: [ManagedPreferenceState]
        let observed: ManagedPreferenceState
    }

    private static let executable = URL(fileURLWithPath: "/usr/bin/defaults")

    private let runner: any CommandRunning

    init(runner: any CommandRunning) {
        self.runner = runner
    }

    func readState() throws -> ManagedPreferenceState {
        ManagedPreferenceState(
            xcodeSession: try read(ToolConstants.xcodePreference),
            deviceHubAutoStartSuppression: try read(ToolConstants.deviceHubPreference)
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
        var didChange = false

        if current.xcodeSession != target.xcodeSession {
            try write(target.xcodeSession, to: ToolConstants.xcodePreference)
            didChange = true
        }
        if current.deviceHubAutoStartSuppression != target.deviceHubAutoStartSuppression {
            try write(target.deviceHubAutoStartSuppression, to: ToolConstants.deviceHubPreference)
            didChange = true
        }

        let observed = try readState()
        guard observed == target else {
            throw CLIError.io(
                "preference-verification",
                "expected \(target), observed \(observed)"
            )
        }
        return didChange
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
        let output = try runner.run(
            executable: Self.executable,
            arguments: ["export", preference.domain, "-"]
        )
        guard output.terminationStatus == 0 else {
            if try !domainExists(preference.domain) {
                return .absent
            }
            throw commandFailure(
                identifier: "preference-read",
                action: "read \(preference.domain).\(preference.key)",
                output: output
            )
        }

        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(
                from: output.stdout,
                options: [],
                format: nil
            )
        } catch {
            throw CLIError.io(
                "preference-decode",
                "could not decode \(preference.domain): \(error.localizedDescription)"
            )
        }
        guard let domain = object as? [String: Any] else {
            throw CLIError.configuration(
                "preference-domain-type",
                "\(preference.domain) is not a property-list dictionary"
            )
        }
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

    private func domainExists(_ domain: String) throws -> Bool {
        let output = try runner.run(
            executable: Self.executable,
            arguments: ["domains"]
        )
        guard output.terminationStatus == 0 else {
            throw commandFailure(
                identifier: "preference-read",
                action: "list preference domains",
                output: output
            )
        }

        return output.stdoutText
            .split(separator: ",")
            .contains { candidate in
                candidate.trimmingCharacters(in: .whitespacesAndNewlines) == domain
            }
    }

    private func write(_ value: StoredBoolean, to preference: ManagedPreference) throws {
        let arguments: [String]
        switch value {
        case .absent:
            arguments = ["delete", preference.domain, preference.key]
        case .falseValue:
            arguments = ["write", preference.domain, preference.key, "-bool", "false"]
        case .trueValue:
            arguments = ["write", preference.domain, preference.key, "-bool", "true"]
        }

        let output = try runner.run(executable: Self.executable, arguments: arguments)
        guard output.terminationStatus == 0 else {
            throw commandFailure(
                identifier: "preference-write",
                action: "write \(preference.domain).\(preference.key)",
                output: output
            )
        }
    }

    private func commandFailure(
        identifier: String,
        action: String,
        output: CommandOutput
    ) -> CLIError {
        let detail = output.stderrText.isEmpty
            ? "exit status \(output.terminationStatus)"
            : output.stderrText
        return CLIError.io(identifier, "could not \(action): \(detail)")
    }
}
