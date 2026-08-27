import Foundation
import Testing

@testable import XcodeSimulatorHost

@Suite
struct DefaultsStoreTests {
    @Test func absentFalseAndTrueRemainDistinct() throws {
        let runner = FakeSystemCommandRunner()
        let store = DefaultsStore(runner: runner)

        #expect(try store.readState() == .deviceHub)

        runner.setStoredValue(false, for: ToolConstants.xcodePreference)
        runner.setStoredValue(true, for: ToolConstants.deviceHubPreference)
        #expect(
            try store.readState()
                == ManagedPreferenceState(
                    xcodeSession: .falseValue,
                    deviceHubAutoStartSuppression: .trueValue
                )
        )
    }

    @Test func missingDomainsAreReadAsAbsentWhenExportFails() throws {
        let runner = FakeSystemCommandRunner()
        runner.failMissingDomainExports = true
        let store = DefaultsStore(runner: runner)

        #expect(try store.readState() == .deviceHub)
        #expect(
            runner.calls.filter {
                $0.executable.path == "/usr/bin/defaults"
                    && $0.arguments == ["domains"]
            }.count == 2
        )
    }

    @Test func exportFailureForAnExistingDomainIsNotTreatedAsAbsent() {
        let runner = FakeSystemCommandRunner()
        runner.setStoredValue(false, for: ToolConstants.xcodePreference)
        runner.failExportNumber = 1
        let store = DefaultsStore(runner: runner)

        do {
            _ = try store.readState()
            Issue.record("expected export failure")
        } catch let error as CLIError {
            #expect(error.identifier == "preference-read")
            #expect(error.category == .io)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func domainListingFailureIsNotTreatedAsAbsent() {
        let runner = FakeSystemCommandRunner()
        runner.failMissingDomainExports = true
        runner.failDomainListing = true
        let store = DefaultsStore(runner: runner)

        do {
            _ = try store.readState()
            Issue.record("expected domain listing failure")
        } catch let error as CLIError {
            #expect(error.identifier == "preference-read")
            #expect(error.category == .io)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func applyWritesAndVerifiesBothPreferences() throws {
        let runner = FakeSystemCommandRunner()
        let store = DefaultsStore(runner: runner)

        #expect(try store.apply(.legacy, from: .deviceHub))
        #expect(runner.storedBoolean(ToolConstants.xcodePreference) == .trueValue)
        #expect(runner.storedBoolean(ToolConstants.deviceHubPreference) == .trueValue)
        #expect(runner.mutationCount == 2)

        #expect(!(try store.apply(.legacy, from: .legacy)))
        #expect(runner.mutationCount == 2)

        #expect(try store.apply(.deviceHub, from: .legacy))
        #expect(runner.storedBoolean(ToolConstants.xcodePreference) == .absent)
        #expect(runner.storedBoolean(ToolConstants.deviceHubPreference) == .absent)
    }

    @Test func nonBooleanValueIsRejectedBeforeMutation() {
        let runner = FakeSystemCommandRunner()
        runner.setStoredValue("true", for: ToolConstants.xcodePreference)
        let store = DefaultsStore(runner: runner)

        do {
            _ = try store.apply(.legacy, from: .deviceHub)
            Issue.record("expected invalid preference type")
        } catch let error as CLIError {
            #expect(error.identifier == "preference-value-type")
            #expect(error.category == .configuration)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(runner.mutationCount == 0)
    }

    @Test func failedMutationLeavesVerificationToTheTransactionOwner() {
        let runner = FakeSystemCommandRunner()
        runner.failMutationNumbers = [2]
        let store = DefaultsStore(runner: runner)

        #expect(throws: CLIError.self) {
            try store.apply(.legacy, from: .deviceHub)
        }
        #expect(runner.storedBoolean(ToolConstants.xcodePreference) == .trueValue)
        #expect(runner.storedBoolean(ToolConstants.deviceHubPreference) == .absent)
    }

    @Test func unexpectedCurrentStateIsNeverOverwritten() throws {
        let runner = FakeSystemCommandRunner()
        runner.setStoredValue(false, for: ToolConstants.xcodePreference)
        let store = DefaultsStore(runner: runner)

        do {
            _ = try store.apply(.legacy, from: .deviceHub)
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
}
