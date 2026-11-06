import Foundation
@testable import NeoSimulatorDeviceIO
@testable import NeoSimulatorHostSupport
@testable import NeoSimulatorKit
import Testing


@Suite
struct DefaultsStoreTests {
    @Test func systemPreferencesPreserveThreeStatesAtExactUserScope() async throws {
        let domains = SystemPreferenceDomains()
        let preference = ManagedPreference(domain: "dev.lynnswap.NeoSimulator.tests.\(UUID().uuidString)", key: "Boolean")
        do {
            #expect(try await domains.readDomain(preference.domain, keys: [preference.key]).isEmpty)
            try await domains.write(.falseValue, to: preference)
            #expect(try await domains.readDomain(preference.domain, keys: [preference.key])[preference.key] as? Bool == false)
            try await domains.write(.trueValue, to: preference)
            #expect(try await domains.readDomain(preference.domain, keys: [preference.key])[preference.key] as? Bool == true)
            try await domains.write(.absent, to: preference)
            #expect(try await domains.readDomain(preference.domain, keys: [preference.key]).isEmpty)
        } catch {
            try? await domains.write(.absent, to: preference)
            throw error
        }
    }

    /// Rollback runs after a failed write, so a transaction whose caller was cancelled must still reach the preferences.
    @Test func preferenceTransactionsReachTheDomainAfterTheirCallerIsCancelled() async throws {
        let domains = SystemPreferenceDomains()
        let preference = ManagedPreference(domain: "dev.lynnswap.NeoSimulator.tests.\(UUID().uuidString)", key: "Boolean")
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await domains.write(.trueValue, to: preference)
            let stored = try await domains.readDomain(preference.domain, keys: [preference.key])[preference.key] as? Bool
            try await domains.write(.absent, to: preference)
            return stored
        }
        #expect(try await cancelled.value == true)
    }

    @Test func absentFalseAndTrueRemainDistinct() async throws {
        let runner = FakeSystemCommandRunner()
        let store = DefaultsStore(domains: runner)

        #expect(try await store.readState() == .deviceHub)

        runner.setStoredValue(false, for: ToolConstants.xcodePreference)
        runner.setStoredValue(true, for: ToolConstants.deviceHubPreference)
        #expect(
            try await store.readState()
                == ManagedPreferenceState(
                    xcodeSession: .falseValue,
                    deviceHubAutoStartSuppression: .trueValue
                )
        )
    }

    @Test func missingDomainsAreReadAsAbsent() async throws {
        let runner = FakeSystemCommandRunner()
        let store = DefaultsStore(domains: runner)

        #expect(try await store.readState() == .deviceHub)

    }

    @Test func domainReadFailureIsNotTreatedAsAbsent() async {
        let runner = FakeSystemCommandRunner()
        runner.setStoredValue(false, for: ToolConstants.xcodePreference)
        runner.failPreferenceReadNumber = 1
        let store = DefaultsStore(domains: runner)

        do {
            _ = try await store.readState()
            Issue.record("expected export failure")
        } catch let error as HostOperationError {
            #expect(error.identifier == "preference-read")
            #expect(error.category == .io)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func preferenceReadFailureIsNotTreatedAsAbsent() async {
        let runner = FakeSystemCommandRunner()
        runner.failPreferenceReads = true
        let store = DefaultsStore(domains: runner)

        do {
            _ = try await store.readState()
            Issue.record("expected domain listing failure")
        } catch let error as HostOperationError {
            #expect(error.identifier == "preference-read")
            #expect(error.category == .io)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func applyWritesAndVerifiesBothPreferences() async throws {
        let runner = FakeSystemCommandRunner()
        let store = DefaultsStore(domains: runner)

        #expect(try await store.apply(.coreSimulator, from: .deviceHub))
        #expect(runner.storedBoolean(ToolConstants.xcodePreference) == .trueValue)
        #expect(runner.storedBoolean(ToolConstants.deviceHubPreference) == .trueValue)
        #expect(runner.mutationCount == 2)

        #expect(!(try await store.apply(.coreSimulator, from: .coreSimulator)))
        #expect(runner.mutationCount == 2)

        #expect(try await store.apply(.deviceHub, from: .coreSimulator))
        #expect(runner.storedBoolean(ToolConstants.xcodePreference) == .absent)
        #expect(runner.storedBoolean(ToolConstants.deviceHubPreference) == .absent)
    }

    @Test func nonBooleanValueIsRejectedBeforeMutation() async {
        let runner = FakeSystemCommandRunner()
        runner.setStoredValue("true", for: ToolConstants.xcodePreference)
        let store = DefaultsStore(domains: runner)

        do {
            _ = try await store.apply(.coreSimulator, from: .deviceHub)
            Issue.record("expected invalid preference type")
        } catch let error as HostOperationError {
            #expect(error.identifier == "preference-value-type")
            #expect(error.category == .configuration)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(runner.mutationCount == 0)
    }

    @Test func failedMutationLeavesVerificationToTheTransactionOwner() async {
        let runner = FakeSystemCommandRunner()
        runner.failMutationNumbers = [2]
        let store = DefaultsStore(domains: runner)

        await #expect(throws: HostOperationError.self) {
            try await store.apply(.coreSimulator, from: .deviceHub)
        }
        #expect(runner.storedBoolean(ToolConstants.xcodePreference) == .trueValue)
        #expect(runner.storedBoolean(ToolConstants.deviceHubPreference) == .absent)
    }

    @Test func unexpectedCurrentStateIsNeverOverwritten() async throws {
        let runner = FakeSystemCommandRunner()
        runner.setStoredValue(false, for: ToolConstants.xcodePreference)
        let store = DefaultsStore(domains: runner)

        do {
            _ = try await store.apply(.coreSimulator, from: .deviceHub)
            Issue.record("expected stale state to fail")
        } catch let mismatch as DefaultsStore.StateMismatch {
            #expect(mismatch.expected == [.deviceHub])
            #expect(
                mismatch.observed
                    == ManagedPreferenceState(
                        xcodeSession: .falseValue,
                        deviceHubAutoStartSuppression: .absent
                    )
            )
        }
        #expect(runner.mutationCount == 0)
    }

    @Test func externalChangeBeforeTheSecondWriteIsNotOverwritten() async {
        let runner = FakeSystemCommandRunner()
        runner.setStoredValue(true, for: ToolConstants.xcodePreference)
        runner.setStoredValue(true, for: ToolConstants.deviceHubPreference)
        var injectedChange = false
        runner.beforeRun = { call in
            guard !injectedChange,
                  runner.mutationCount == 1,
                  call.executable.path == "/usr/bin/defaults",
                  call.arguments == ["read", ToolConstants.xcodePreference.domain]
            else {
                return
            }
            injectedChange = true
            runner.setStoredValue(false, for: ToolConstants.deviceHubPreference)
        }
        let store = DefaultsStore(domains: runner)

        do {
            _ = try await store.apply(.deviceHub, from: .coreSimulator)
            Issue.record("expected external change to stop the transition")
        } catch let mismatch as DefaultsStore.StateMismatch {
            #expect(
                mismatch.observed
                    == ManagedPreferenceState(
                        xcodeSession: .absent,
                        deviceHubAutoStartSuppression: .falseValue
                    )
            )
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        #expect(injectedChange)
        #expect(runner.mutationCount == 1)
        #expect(runner.storedBoolean(ToolConstants.xcodePreference) == .absent)
        #expect(runner.storedBoolean(ToolConstants.deviceHubPreference) == .falseValue)
    }

    @Test func externalChangeDuringRollbackIsNotOverwritten() async {
        let runner = FakeSystemCommandRunner()
        runner.setStoredValue(true, for: ToolConstants.xcodePreference)
        runner.setStoredValue(true, for: ToolConstants.deviceHubPreference)
        var injectedChange = false
        runner.beforeRun = { call in
            guard !injectedChange,
                  runner.mutationCount == 1,
                  call.executable.path == "/usr/bin/defaults",
                  call.arguments == ["read", ToolConstants.xcodePreference.domain]
            else {
                return
            }
            injectedChange = true
            runner.setStoredValue(false, for: ToolConstants.deviceHubPreference)
        }
        let store = DefaultsStore(domains: runner)

        do {
            _ = try await store.rollback(
                to: .deviceHub,
                fromAttemptedTarget: .coreSimulator
            )
            Issue.record("expected external change to stop rollback")
        } catch let mismatch as DefaultsStore.StateMismatch {
            #expect(
                mismatch.observed
                    == ManagedPreferenceState(
                        xcodeSession: .absent,
                        deviceHubAutoStartSuppression: .falseValue
                    )
            )
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        #expect(injectedChange)
        #expect(runner.mutationCount == 1)
        #expect(runner.storedBoolean(ToolConstants.xcodePreference) == .absent)
        #expect(runner.storedBoolean(ToolConstants.deviceHubPreference) == .falseValue)
    }
}
