import Foundation
import Testing

@testable import XcodeSimulatorHost

@MainActor
@Suite
struct HostModeControllerTests {
    @Test func legacyAndDeviceHubModesRoundTripTheOriginalAbsentState() async throws {
        let fixture = try ControllerFixture()
        fixture.workspace.deviceHubCount = 1
        fixture.workspace.onTerminateDeviceHubs = {
            #expect(
                fixture.runner.storedBoolean(ToolConstants.xcodePreference)
                    == .trueValue
            )
            #expect(
                fixture.runner.storedBoolean(ToolConstants.deviceHubPreference)
                    == .trueValue
            )
        }

        let legacy = try await fixture.controller.use(
            mode: .legacy,
            explicitLegacyXcodeURL: nil
        )
        #expect(legacy.didChange)
        #expect(fixture.runner.storedBoolean(ToolConstants.xcodePreference) == .trueValue)
        #expect(fixture.runner.storedBoolean(ToolConstants.deviceHubPreference) == .trueValue)
        #expect(legacy.receiptURL != nil)
        #expect(legacy.terminatedDeviceHubCount == 1)
        #expect(legacy.rendered.contains("Xcode 27 can remain open"))
        let simulator = try #require(legacy.simulator)
        #expect(fixture.workspace.openedApplications == [simulator.applicationURL])
        #expect(
            fixture.workspace.events
                == ["terminate-device-hubs", "open-simulator"]
        )
        #expect(
            fixture.workspace.requestedDeviceHubURLs
                == [
                    fixture.installations.targetXcodeURL.appendingPathComponent(
                        ToolConstants.deviceHubPath,
                        isDirectory: true
                    ),
                ]
        )
        #expect(try fixture.receiptStore.load()?.original == .deviceHub)

        let deviceHub = try await fixture.controller.use(
            mode: .deviceHub,
            explicitLegacyXcodeURL: nil
        )
        #expect(deviceHub.didChange)
        #expect(fixture.runner.storedBoolean(ToolConstants.xcodePreference) == .absent)
        #expect(fixture.runner.storedBoolean(ToolConstants.deviceHubPreference) == .absent)
        #expect(deviceHub.receiptURL == nil)
        #expect(deviceHub.terminatedDeviceHubCount == 0)
        #expect(
            fixture.workspace.events
                == ["terminate-device-hubs", "open-simulator"]
        )
        #expect(try fixture.receiptStore.load() == nil)
    }

    @Test func restorePreservesExplicitFalseAndTrueValues() async throws {
        let original = ManagedPreferenceState(
            xcodeSession: .falseValue,
            deviceHubAutoStartSuppression: .trueValue
        )
        let fixture = try ControllerFixture(initialState: original)

        _ = try await fixture.controller.use(mode: .legacy, explicitLegacyXcodeURL: nil)
        let loadedReceipt = try fixture.receiptStore.load()
        let receipt = try #require(loadedReceipt)
        #expect(receipt.original == original)

        let restored = try fixture.controller.restore()
        #expect(restored.didRestore)
        #expect(restored.rendered.contains("Xcode can remain open"))
        #expect(fixture.runner.storedBoolean(ToolConstants.xcodePreference) == .falseValue)
        #expect(fixture.runner.storedBoolean(ToolConstants.deviceHubPreference) == .trueValue)
        #expect(try fixture.receiptStore.load() == nil)
    }

    @Test func runningXcodeDoesNotBlockLegacyMode() async throws {
        let fixture = try ControllerFixture()
        fixture.workspace.runningXcodes = [
            RunningApplication(
                processIdentifier: 42,
                bundleURL: URL(fileURLWithPath: "/Applications/Xcode_27.app")
            ),
        ]

        let report = try await fixture.controller.use(
            mode: .legacy,
            explicitLegacyXcodeURL: nil
        )

        #expect(report.didChange)
        #expect(fixture.runner.mutationCount == 2)
        #expect(try fixture.receiptStore.load() != nil)
        #expect(
            fixture.workspace.events
                == ["terminate-device-hubs", "open-simulator"]
        )
    }

    @Test func secondPreferenceFailureRollsBackTheFirstPreference() async throws {
        let fixture = try ControllerFixture()
        fixture.runner.failMutationNumbers = [2]

        do {
            _ = try await fixture.controller.use(mode: .legacy, explicitLegacyXcodeURL: nil)
            Issue.record("expected injected transition failure")
        } catch let error as CLIError {
            #expect(error.identifier == "transition-rolled-back")
        }

        #expect(fixture.runner.storedBoolean(ToolConstants.xcodePreference) == .absent)
        #expect(fixture.runner.storedBoolean(ToolConstants.deviceHubPreference) == .absent)
        #expect(try fixture.receiptStore.load() == nil)
    }

    @Test func failureReportedAfterAWriteIsStillRolledBack() async throws {
        let fixture = try ControllerFixture()
        fixture.runner.failMutationNumbers = [1]
        fixture.runner.failureTiming = .afterMutation

        do {
            _ = try await fixture.controller.use(mode: .legacy, explicitLegacyXcodeURL: nil)
            Issue.record("expected injected transition failure")
        } catch let error as CLIError {
            #expect(error.identifier == "transition-rolled-back")
        }

        #expect(fixture.runner.storedBoolean(ToolConstants.xcodePreference) == .absent)
        #expect(fixture.runner.storedBoolean(ToolConstants.deviceHubPreference) == .absent)
        #expect(try fixture.receiptStore.load() == nil)
    }

    @Test func verificationReadFailureIsRolledBack() async throws {
        let fixture = try ControllerFixture()
        fixture.runner.failExportNumber = 5

        do {
            _ = try await fixture.controller.use(mode: .legacy, explicitLegacyXcodeURL: nil)
            Issue.record("expected injected verification failure")
        } catch let error as CLIError {
            #expect(error.identifier == "transition-rolled-back")
        }

        #expect(fixture.runner.storedBoolean(ToolConstants.xcodePreference) == .absent)
        #expect(fixture.runner.storedBoolean(ToolConstants.deviceHubPreference) == .absent)
        #expect(try fixture.receiptStore.load() == nil)
    }

    @Test func rollbackFailureRetainsAnInterruptedJournal() async throws {
        let fixture = try ControllerFixture()
        fixture.runner.failMutationNumbers = [2, 3]

        do {
            _ = try await fixture.controller.use(mode: .legacy, explicitLegacyXcodeURL: nil)
            Issue.record("expected rollback failure")
        } catch let error as CLIError {
            #expect(error.identifier == "inconsistent-preferences")
        }

        #expect(fixture.runner.storedBoolean(ToolConstants.xcodePreference) == .trueValue)
        #expect(fixture.runner.storedBoolean(ToolConstants.deviceHubPreference) == .absent)
        let status = try fixture.controller.status(explicitLegacyXcodeURL: nil)
        #expect(status.receiptStatus == .ambiguousIntermediate)
    }

    @Test func externalPreferenceChangeIsReportedAsAConflict() async throws {
        let fixture = try ControllerFixture()
        _ = try await fixture.controller.use(mode: .legacy, explicitLegacyXcodeURL: nil)
        fixture.runner.setStoredValue(false, for: ToolConstants.xcodePreference)

        let status = try fixture.controller.status(explicitLegacyXcodeURL: nil)
        #expect(status.receiptStatus.hasConflict)

        do {
            _ = try fixture.controller.restore()
            Issue.record("expected external conflict")
        } catch let error as CLIError {
            #expect(error.identifier == "preference-conflict")
            #expect(error.category == .configuration)
        }
    }

    @Test func changeBetweenReceiptCaptureAndApplyIsNotOverwritten() async throws {
        let fixture = try ControllerFixture()
        var exportCount = 0
        fixture.runner.beforeRun = { call in
            guard call.executable.path == "/usr/bin/defaults",
                  call.arguments.first == "export"
            else {
                return
            }
            exportCount += 1
            if exportCount == 3 {
                fixture.runner.setStoredValue(
                    false,
                    for: ToolConstants.xcodePreference
                )
            }
        }

        do {
            _ = try await fixture.controller.use(mode: .legacy, explicitLegacyXcodeURL: nil)
            Issue.record("expected external change to be reported")
        } catch let error as CLIError {
            #expect(error.identifier == "preference-conflict")
        }

        #expect(fixture.runner.mutationCount == 0)
        #expect(fixture.runner.storedBoolean(ToolConstants.xcodePreference) == .falseValue)
        let loadedReceipt = try fixture.receiptStore.load()
        let receipt = try #require(loadedReceipt)
        #expect(receipt.pending == PendingMutation(before: .deviceHub, target: .legacy))
    }

    @Test func externalChangeMatchingAnIntermediateIsNeverAssumedToBeOurs() async throws {
        let fixture = try ControllerFixture()
        var exportCount = 0
        fixture.runner.beforeRun = { call in
            guard call.executable.path == "/usr/bin/defaults",
                  call.arguments.first == "export"
            else {
                return
            }
            exportCount += 1
            if exportCount == 3 {
                fixture.runner.setStoredValue(
                    true,
                    for: ToolConstants.xcodePreference
                )
            }
        }

        do {
            _ = try await fixture.controller.use(mode: .legacy, explicitLegacyXcodeURL: nil)
            Issue.record("expected external change to be reported")
        } catch let error as CLIError {
            #expect(error.identifier == "preference-conflict")
        }
        fixture.runner.beforeRun = nil

        do {
            _ = try await fixture.controller.use(mode: .legacy, explicitLegacyXcodeURL: nil)
            Issue.record("expected ambiguous state to remain protected")
        } catch let error as CLIError {
            #expect(error.identifier == "ambiguous-intermediate")
        }

        #expect(fixture.runner.mutationCount == 0)
        #expect(fixture.runner.storedBoolean(ToolConstants.xcodePreference) == .trueValue)
        #expect(fixture.runner.storedBoolean(ToolConstants.deviceHubPreference) == .absent)
    }

    @Test func pendingAppliedMutationIsFinalizedBeforeTheNextUse() async throws {
        let fixture = try ControllerFixture()
        let xcode = try InstallationInspector(
            runner: fixture.runner,
            environment: ["DEVELOPER_DIR": fixture.installations.developerDirectoryURL.path],
            legacySearchRoots: [fixture.installations.applicationsURL],
            signatureValidator: .acceptingTestFixtures
        ).validatedTargetXcode()
        var receipt = RestorationReceipt(
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            xcode: xcode,
            original: .deviceHub
        )
        receipt.pending = PendingMutation(before: .deviceHub, target: .legacy)
        try fixture.receiptStore.save(receipt)
        fixture.runner.setStoredValue(true, for: ToolConstants.xcodePreference)
        fixture.runner.setStoredValue(true, for: ToolConstants.deviceHubPreference)

        let report = try await fixture.controller.use(mode: .legacy, explicitLegacyXcodeURL: nil)
        #expect(!report.didChange)
        let loadedReceipt = try fixture.receiptStore.load()
        let recovered = try #require(loadedReceipt)
        #expect(recovered.expectedCurrent == .legacy)
        #expect(recovered.pending == nil)
    }

    @Test func ambiguousIntermediateIsNotOverwrittenByTheNextUse() async throws {
        let fixture = try ControllerFixture()
        let xcode = try InstallationInspector(
            runner: fixture.runner,
            environment: ["DEVELOPER_DIR": fixture.installations.developerDirectoryURL.path],
            legacySearchRoots: [fixture.installations.applicationsURL],
            signatureValidator: .acceptingTestFixtures
        ).validatedTargetXcode()
        var receipt = RestorationReceipt(
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            xcode: xcode,
            original: .deviceHub
        )
        receipt.pending = PendingMutation(before: .deviceHub, target: .legacy)
        try fixture.receiptStore.save(receipt)
        fixture.runner.setStoredValue(true, for: ToolConstants.xcodePreference)

        do {
            _ = try await fixture.controller.use(mode: .legacy, explicitLegacyXcodeURL: nil)
            Issue.record("expected ambiguous intermediate state")
        } catch let error as CLIError {
            #expect(error.identifier == "ambiguous-intermediate")
        }

        #expect(fixture.runner.storedBoolean(ToolConstants.xcodePreference) == .trueValue)
        #expect(fixture.runner.storedBoolean(ToolConstants.deviceHubPreference) == .absent)
        let loadedReceipt = try fixture.receiptStore.load()
        let recovered = try #require(loadedReceipt)
        #expect(recovered.expectedCurrent == .deviceHub)
        #expect(recovered.pending == PendingMutation(before: .deviceHub, target: .legacy))
    }

    @Test func forceRestoreCanResolveAnAmbiguousIntermediateState() throws {
        let fixture = try ControllerFixture()
        let xcode = try InstallationInspector(
            runner: fixture.runner,
            environment: ["DEVELOPER_DIR": fixture.installations.developerDirectoryURL.path],
            legacySearchRoots: [fixture.installations.applicationsURL],
            signatureValidator: .acceptingTestFixtures
        ).validatedTargetXcode()
        var receipt = RestorationReceipt(
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            xcode: xcode,
            original: .deviceHub
        )
        receipt.pending = PendingMutation(before: .deviceHub, target: .legacy)
        try fixture.receiptStore.save(receipt)
        fixture.runner.setStoredValue(true, for: ToolConstants.xcodePreference)

        do {
            _ = try fixture.controller.restore()
            Issue.record("expected normal restore to preserve ambiguity")
        } catch let error as CLIError {
            #expect(error.identifier == "ambiguous-intermediate")
        }
        #expect(fixture.runner.mutationCount == 0)

        let report = try fixture.controller.restore(force: true)

        #expect(report.didRestore)
        #expect(report.restoredState == .deviceHub)
        #expect(fixture.runner.storedBoolean(ToolConstants.xcodePreference) == .absent)
        #expect(fixture.runner.storedBoolean(ToolConstants.deviceHubPreference) == .absent)
        #expect(try fixture.receiptStore.load() == nil)
    }

    @Test func simulatorLaunchFailureLeavesTheCommittedModeRestorable() async throws {
        let fixture = try ControllerFixture()
        fixture.workspace.openError = CLIError.io("open", "injected open failure")

        do {
            _ = try await fixture.controller.use(mode: .legacy, explicitLegacyXcodeURL: nil)
            Issue.record("expected Simulator launch failure")
        } catch let error as CLIError {
            #expect(error.identifier == "simulator-launch-partial-success")
        }
        #expect(fixture.runner.storedBoolean(ToolConstants.xcodePreference) == .trueValue)
        #expect(try fixture.receiptStore.load() != nil)

        _ = try fixture.controller.restore()
        #expect(fixture.runner.storedBoolean(ToolConstants.xcodePreference) == .absent)
    }

    @Test func deviceHubTerminationFailureStillOpensSimulator() async throws {
        let fixture = try ControllerFixture()
        fixture.workspace.terminateDeviceHubsError = CLIError.temporary(
            "injected-termination",
            "injected Device Hub termination failure"
        )

        do {
            _ = try await fixture.controller.use(mode: .legacy, explicitLegacyXcodeURL: nil)
            Issue.record("expected Device Hub termination failure")
        } catch let error as CLIError {
            #expect(error.identifier == "device-hub-termination-partial-success")
            #expect(error.category == .temporary)
        }

        #expect(fixture.runner.storedBoolean(ToolConstants.xcodePreference) == .trueValue)
        #expect(fixture.workspace.openedApplications.count == 1)
        #expect(
            fixture.workspace.events
                == ["terminate-device-hubs", "open-simulator"]
        )
        #expect(try fixture.receiptStore.load() != nil)
    }

    @Test func deviceHubIdentityFailurePreservesConfigurationExitCategory() async throws {
        let fixture = try ControllerFixture()
        fixture.workspace.terminateDeviceHubsError = CLIError.configuration(
            "device-hub-substitution",
            "injected mismatched Device Hub"
        )

        do {
            _ = try await fixture.controller.use(mode: .legacy, explicitLegacyXcodeURL: nil)
            Issue.record("expected Device Hub identity failure")
        } catch let error as CLIError {
            #expect(error.identifier == "device-hub-termination-partial-success")
            #expect(error.category == .configuration)
        }
        #expect(fixture.workspace.openedApplications.count == 1)
    }

    @Test func deviceHubAndSimulatorFailuresAreReportedTogether() async throws {
        let fixture = try ControllerFixture()
        fixture.workspace.terminateDeviceHubsError = CLIError.temporary(
            "injected-termination",
            "injected Device Hub termination failure"
        )
        fixture.workspace.openError = CLIError.io(
            "injected-open",
            "injected Simulator open failure"
        )

        do {
            _ = try await fixture.controller.use(mode: .legacy, explicitLegacyXcodeURL: nil)
            Issue.record("expected combined legacy host failure")
        } catch let error as CLIError {
            #expect(error.identifier == "legacy-host-partial-success")
            #expect(error.message.contains("Device Hub"))
            #expect(error.message.contains("Simulator"))
        }
    }

    @Test func modeIsRevalidatedAfterClosingDeviceHub() async throws {
        let fixture = try ControllerFixture()
        fixture.workspace.onTerminateDeviceHubs = {
            fixture.runner.setStoredValue(
                nil,
                for: ToolConstants.xcodePreference
            )
            fixture.runner.setStoredValue(
                nil,
                for: ToolConstants.deviceHubPreference
            )
        }

        do {
            _ = try await fixture.controller.use(mode: .legacy, explicitLegacyXcodeURL: nil)
            Issue.record("expected post-await preference conflict")
        } catch let error as CLIError {
            #expect(error.identifier == "legacy-host-invalidated")
            #expect(error.category == .configuration)
        }

        #expect(fixture.workspace.openedApplications.isEmpty)
        #expect(fixture.workspace.events == ["terminate-device-hubs"])
    }

    @Test func simulatorOpenHoldsTheOperationLockAgainstAnotherSwitch() async throws {
        let fixture = try ControllerFixture()
        fixture.workspace.onOpenApplication = { _ in
            do {
                _ = try await fixture.controller.use(
                    mode: .deviceHub,
                    explicitLegacyXcodeURL: nil
                )
                Issue.record("expected concurrent switch to be serialized")
            } catch let error as CLIError {
                #expect(error.identifier == "operation-lock")
                #expect(error.category == .temporary)
            }
        }

        let report = try await fixture.controller.use(
            mode: .legacy,
            explicitLegacyXcodeURL: nil
        )

        #expect(report.didChange)
        #expect(fixture.runner.storedBoolean(ToolConstants.xcodePreference) == .trueValue)
        #expect(fixture.runner.storedBoolean(ToolConstants.deviceHubPreference) == .trueValue)
    }

    @Test func simulatorLaunchFailureWithoutAReceiptDoesNotSuggestRestore() async throws {
        let fixture = try ControllerFixture(initialState: .legacy)
        fixture.workspace.openError = CLIError.io("open", "injected open failure")

        do {
            _ = try await fixture.controller.use(mode: .legacy, explicitLegacyXcodeURL: nil)
            Issue.record("expected Simulator launch failure")
        } catch let error as CLIError {
            #expect(error.identifier == "simulator-launch-partial-success")
            #expect(error.message.contains("No restoration receipt exists"))
            #expect(!error.message.contains("run restore"))
        }
        #expect(try fixture.receiptStore.load() == nil)
    }

    @Test func restoreWithoutAReceiptIsADocumentedNoOp() throws {
        let fixture = try ControllerFixture()
        let report = try fixture.controller.restore()

        #expect(!report.didRestore)
        #expect(fixture.runner.mutationCount == 0)
    }

    @Test func restoreWithoutAReceiptDoesNotReadInvalidPreferences() throws {
        let fixture = try ControllerFixture()
        fixture.runner.setStoredValue("not-a-boolean", for: ToolConstants.xcodePreference)

        let report = try fixture.controller.restore()

        #expect(!report.didRestore)
        #expect(fixture.runner.calls.isEmpty)
    }

    @Test func runningXcodeDoesNotBlockRestore() async throws {
        let fixture = try ControllerFixture()
        _ = try await fixture.controller.use(mode: .legacy, explicitLegacyXcodeURL: nil)
        fixture.workspace.runningXcodes = [
            RunningApplication(
                processIdentifier: 42,
                bundleURL: URL(fileURLWithPath: "/Applications/Xcode_27.app")
            ),
        ]

        let report = try fixture.controller.restore()

        #expect(report.didRestore)
        #expect(fixture.runner.mutationCount == 4)
        #expect(try fixture.receiptStore.load() == nil)
    }

    @Test func runningXcodeDoesNotBlockDeviceHubMode() async throws {
        let fixture = try ControllerFixture(initialState: .legacy)
        fixture.workspace.runningXcodes = [
            RunningApplication(
                processIdentifier: 42,
                bundleURL: URL(fileURLWithPath: "/Applications/Xcode_27.app")
            ),
        ]

        let report = try await fixture.controller.use(
            mode: .deviceHub,
            explicitLegacyXcodeURL: nil
        )

        #expect(report.didChange)
        #expect(fixture.runner.storedBoolean(ToolConstants.xcodePreference) == .absent)
        #expect(fixture.workspace.events.isEmpty)
    }

    @Test func sudoIsRejectedBeforeMutation() async throws {
        let fixture = try ControllerFixture(effectiveUserID: 0)

        do {
            _ = try await fixture.controller.use(mode: .legacy, explicitLegacyXcodeURL: nil)
            Issue.record("expected root user to be rejected")
        } catch let error as CLIError {
            #expect(error.identifier == "root-user")
        }
        #expect(fixture.runner.mutationCount == 0)
    }

    @Test func statusIsReadOnly() throws {
        let fixture = try ControllerFixture()
        fixture.workspace.runningXcodes = [
            RunningApplication(
                processIdentifier: 42,
                bundleURL: URL(fileURLWithPath: "/Applications/Xcode_27.app")
            ),
        ]
        let status = try fixture.controller.status(explicitLegacyXcodeURL: nil)

        #expect(status.preferences == .deviceHub)
        #expect(status.legacySimulator != nil)
        #expect(fixture.runner.mutationCount == 0)
        #expect(try fixture.receiptStore.load() == nil)
        #expect(status.rendered.contains("hot switching is supported"))
        #expect(!status.rendered.contains("mode changes are blocked"))
    }
}
