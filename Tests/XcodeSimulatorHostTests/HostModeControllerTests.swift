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
            mode: .legacy
        )
        #expect(legacy.didChange)
        #expect(fixture.runner.storedBoolean(ToolConstants.xcodePreference) == .trueValue)
        #expect(fixture.runner.storedBoolean(ToolConstants.deviceHubPreference) == .trueValue)
        #expect(legacy.receiptURL != nil)
        #expect(legacy.terminatedDeviceHubCount == 1)
        #expect(legacy.rendered.contains("Xcode can remain open"))
        let legacyHost = try #require(legacy.legacyHost)
        #expect(
            fixture.workspace.openedLegacyHosts
                == [
                    WorkspaceRecorder.LegacyHostOpen(
                        applicationURL: legacyHost.applicationURL,
                        xcodeURL: fixture.installations.targetXcodeURL
                    ),
                ]
        )
        #expect(
            fixture.workspace.events
                == [
                    "terminate-legacy-hosts",
                    "terminate-device-hubs",
                    "open-legacy-host",
                ]
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

        fixture.workspace.legacyHostCount = 1
        let deviceHub = try await fixture.controller.use(
            mode: .deviceHub
        )
        #expect(deviceHub.didChange)
        #expect(fixture.runner.storedBoolean(ToolConstants.xcodePreference) == .absent)
        #expect(fixture.runner.storedBoolean(ToolConstants.deviceHubPreference) == .absent)
        #expect(deviceHub.receiptURL == nil)
        #expect(deviceHub.terminatedDeviceHubCount == 0)
        #expect(deviceHub.terminatedLegacyHostCount == 1)
        #expect(
            fixture.workspace.events
                == [
                    "terminate-legacy-hosts",
                    "terminate-device-hubs",
                    "open-legacy-host",
                    "terminate-legacy-hosts",
                ]
        )
        #expect(
            fixture.workspace.requestedLegacyHostURLs
                == [
                    fixture.installations.legacyHostURL,
                    fixture.installations.legacyHostURL,
                ]
        )
        #expect(try fixture.receiptStore.load() == nil)
    }

    @Test func restorePreservesExplicitFalseAndTrueValues() async throws {
        let original = ManagedPreferenceState(
            xcodeSession: .falseValue,
            deviceHubAutoStartSuppression: .trueValue
        )
        let fixture = try ControllerFixture(initialState: original)

        _ = try await fixture.controller.use(mode: .legacy)
        let loadedReceipt = try fixture.receiptStore.load()
        let receipt = try #require(loadedReceipt)
        #expect(receipt.original == original)

        fixture.workspace.legacyHostCount = 1
        fixture.workspace.onTerminateLegacyHosts = {
            #expect(
                fixture.runner.storedBoolean(ToolConstants.xcodePreference)
                    == .trueValue
            )
        }
        let restored = try await fixture.controller.restore()
        #expect(restored.didRestore)
        #expect(restored.terminatedLegacyHostCount == 1)
        #expect(restored.rendered.contains("Xcode can remain open"))
        #expect(fixture.runner.storedBoolean(ToolConstants.xcodePreference) == .falseValue)
        #expect(fixture.runner.storedBoolean(ToolConstants.deviceHubPreference) == .trueValue)
        #expect(try fixture.receiptStore.load() == nil)
        #expect(
            fixture.workspace.events
                == [
                    "terminate-legacy-hosts",
                    "terminate-device-hubs",
                    "open-legacy-host",
                    "terminate-legacy-hosts",
                ]
        )
    }

    @Test func restoringALegacyRouteDoesNotCloseTheStandaloneHost() async throws {
        let fixture = try ControllerFixture(initialState: .legacy)
        _ = try await fixture.controller.use(mode: .deviceHub)
        #expect(fixture.workspace.events == ["terminate-legacy-hosts"])

        let report = try await fixture.controller.restore()

        #expect(report.didRestore)
        #expect(report.restoredState == .legacy)
        #expect(report.terminatedLegacyHostCount == 0)
        #expect(fixture.workspace.events == ["terminate-legacy-hosts"])
        #expect(fixture.runner.storedBoolean(ToolConstants.xcodePreference) == .trueValue)
        #expect(
            fixture.runner.storedBoolean(ToolConstants.deviceHubPreference)
                == .trueValue
        )
    }

    @Test func repeatedLegacyUseRestartsTheHostWithTheSelectedXcode() async throws {
        let fixture = try ControllerFixture(initialState: .legacy)
        fixture.workspace.legacyHostCount = 1

        let report = try await fixture.controller.use(mode: .legacy)

        #expect(!report.didChange)
        #expect(report.terminatedLegacyHostCount == 1)
        #expect(report.legacyHost?.applicationURL == fixture.installations.legacyHostURL)
        #expect(
            fixture.workspace.events
                == [
                    "terminate-legacy-hosts",
                    "terminate-device-hubs",
                    "open-legacy-host",
                ]
        )
        #expect(fixture.workspace.openedLegacyHosts.count == 1)
        #expect(try fixture.receiptStore.load() == nil)
    }

    @Test func legacyModeRejectsAMissingHostBeforeChangingPreferences() async throws {
        let fixture = try ControllerFixture(includeLegacyHost: false)

        do {
            _ = try await fixture.controller.use(mode: .legacy)
            Issue.record("expected missing standalone host to fail")
        } catch let error as CLIError {
            #expect(error.identifier == "legacy-host-bundle")
            #expect(error.category == .unavailable)
        }

        #expect(fixture.runner.mutationCount == 0)
        #expect(fixture.workspace.events.isEmpty)
        #expect(try fixture.receiptStore.load() == nil)
    }

    @Test func legacyToolGateFailsBeforeChangingPreferencesOrProcesses() async throws {
        let fixture = try ControllerFixture()
        try Data("#!/bin/zsh\nEXPECTED_VERSION='642.15'\n".utf8).write(
            to: fixture.installations.devicectlWrapperURL
        )

        do {
            _ = try await fixture.controller.use(mode: .legacy)
            Issue.record("expected changed devicectl wrapper to fail")
        } catch let error as CLIError {
            #expect(error.identifier == "devicectl-wrapper-version")
            #expect(error.category == .unavailable)
        }

        #expect(fixture.runner.mutationCount == 0)
        #expect(fixture.workspace.events.isEmpty)
        #expect(try fixture.receiptStore.load() == nil)
    }

    @Test func deviceHubModeCanRecoverWhenThePackagedHostIsMissing() async throws {
        let fixture = try ControllerFixture(
            initialState: .legacy,
            includeLegacyHost: false
        )

        let report = try await fixture.controller.use(mode: .deviceHub)

        #expect(report.didChange)
        #expect(fixture.runner.storedBoolean(ToolConstants.xcodePreference) == .absent)
        #expect(fixture.workspace.events == ["terminate-legacy-hosts"])
        #expect(
            fixture.workspace.requestedLegacyHostURLs
                == [fixture.installations.legacyHostURL]
        )
    }

    @Test func deviceHubModeDoesNotDependOnTheLegacyToolGate() async throws {
        let fixture = try ControllerFixture(initialState: .legacy)
        try Data("#!/bin/zsh\nEXPECTED_VERSION='642.15'\n".utf8).write(
            to: fixture.installations.devicectlWrapperURL
        )

        let report = try await fixture.controller.use(mode: .deviceHub)

        #expect(report.didChange)
        #expect(fixture.runner.storedBoolean(ToolConstants.xcodePreference) == .absent)
        #expect(fixture.workspace.events == ["terminate-legacy-hosts"])
    }

    @Test func deviceHubModeDoesNotChangePreferencesWhenHostCannotClose() async throws {
        let fixture = try ControllerFixture(initialState: .legacy)
        fixture.workspace.terminateLegacyHostsError = CLIError.temporary(
            "injected-termination",
            "injected standalone host termination failure"
        )

        do {
            _ = try await fixture.controller.use(mode: .deviceHub)
            Issue.record("expected standalone host termination failure")
        } catch let error as CLIError {
            #expect(error.identifier == "injected-termination")
        }

        #expect(fixture.runner.mutationCount == 0)
        #expect(fixture.runner.storedBoolean(ToolConstants.xcodePreference) == .trueValue)
        #expect(
            fixture.runner.storedBoolean(ToolConstants.deviceHubPreference)
                == .trueValue
        )
        #expect(fixture.workspace.events == ["terminate-legacy-hosts"])
    }

    @Test func legacyModeDoesNotChangePreferencesWhenHostCannotRestart() async throws {
        let fixture = try ControllerFixture()
        fixture.workspace.terminateLegacyHostsError = CLIError.temporary(
            "injected-termination",
            "injected standalone host termination failure"
        )

        do {
            _ = try await fixture.controller.use(mode: .legacy)
            Issue.record("expected standalone host termination failure")
        } catch let error as CLIError {
            #expect(error.identifier == "injected-termination")
        }

        #expect(fixture.runner.mutationCount == 0)
        #expect(fixture.runner.storedBoolean(ToolConstants.xcodePreference) == .absent)
        #expect(fixture.runner.storedBoolean(ToolConstants.deviceHubPreference) == .absent)
        #expect(fixture.workspace.events == ["terminate-legacy-hosts"])
        #expect(fixture.workspace.openedLegacyHosts.isEmpty)
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
            mode: .legacy
        )

        #expect(report.didChange)
        #expect(fixture.runner.mutationCount == 2)
        #expect(try fixture.receiptStore.load() != nil)
        #expect(
            fixture.workspace.events
                == [
                    "terminate-legacy-hosts",
                    "terminate-device-hubs",
                    "open-legacy-host",
                ]
        )
    }

    @Test func secondPreferenceFailureRollsBackTheFirstPreference() async throws {
        let fixture = try ControllerFixture()
        fixture.runner.failMutationNumbers = [2]

        do {
            _ = try await fixture.controller.use(mode: .legacy)
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
            _ = try await fixture.controller.use(mode: .legacy)
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
        fixture.runner.failFirstExportAfterMutationCount = 2

        do {
            _ = try await fixture.controller.use(mode: .legacy)
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
            _ = try await fixture.controller.use(mode: .legacy)
            Issue.record("expected rollback failure")
        } catch let error as CLIError {
            #expect(error.identifier == "inconsistent-preferences")
        }

        #expect(fixture.runner.storedBoolean(ToolConstants.xcodePreference) == .trueValue)
        #expect(fixture.runner.storedBoolean(ToolConstants.deviceHubPreference) == .absent)
        let status = try fixture.controller.status()
        #expect(status.routeStatus.receiptStatus == .ambiguousIntermediate)
    }

    @Test func externalPreferenceChangeIsReportedAsAConflict() async throws {
        let fixture = try ControllerFixture()
        _ = try await fixture.controller.use(mode: .legacy)
        fixture.runner.setStoredValue(false, for: ToolConstants.xcodePreference)

        let status = try fixture.controller.status()
        #expect(status.routeStatus.receiptStatus.hasConflict)
        let eventsBeforeRestore = fixture.workspace.events

        do {
            _ = try await fixture.controller.restore()
            Issue.record("expected external conflict")
        } catch let error as CLIError {
            #expect(error.identifier == "preference-conflict")
            #expect(error.category == .configuration)
        }
        #expect(fixture.workspace.events == eventsBeforeRestore)
    }

    @Test func detectedChangeBetweenWritesIsNotRolledBack() async throws {
        let fixture = try ControllerFixture(initialState: .legacy)
        var injectedChange = false
        fixture.runner.beforeRun = { call in
            guard !injectedChange,
                  fixture.runner.mutationCount == 1,
                  call.executable.path == "/usr/bin/defaults",
                  call.arguments == ["domains"]
            else {
                return
            }
            injectedChange = true
            fixture.runner.setStoredValue(
                false,
                for: ToolConstants.deviceHubPreference
            )
        }

        do {
            _ = try await fixture.controller.use(
                mode: .deviceHub
            )
            Issue.record("expected external change to be reported")
        } catch let error as CLIError {
            #expect(error.identifier == "preference-conflict")
            #expect(error.category == .configuration)
        }

        #expect(injectedChange)
        #expect(fixture.runner.mutationCount == 1)
        #expect(fixture.runner.storedBoolean(ToolConstants.xcodePreference) == .absent)
        #expect(
            fixture.runner.storedBoolean(ToolConstants.deviceHubPreference)
                == .falseValue
        )
        #expect(try fixture.receiptStore.load()?.pending != nil)
    }

    @Test func changeBetweenReceiptCaptureAndApplyIsNotOverwritten() async throws {
        let fixture = try ControllerFixture()
        var stateReadCount = 0
        fixture.runner.beforeRun = { call in
            guard call.executable.path == "/usr/bin/defaults",
                  call.arguments == ["domains"]
            else {
                return
            }
            stateReadCount += 1
            if stateReadCount == 3 {
                fixture.runner.setStoredValue(
                    false,
                    for: ToolConstants.xcodePreference
                )
            }
        }

        do {
            _ = try await fixture.controller.use(mode: .legacy)
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
        var stateReadCount = 0
        fixture.runner.beforeRun = { call in
            guard call.executable.path == "/usr/bin/defaults",
                  call.arguments == ["domains"]
            else {
                return
            }
            stateReadCount += 1
            if stateReadCount == 3 {
                fixture.runner.setStoredValue(
                    true,
                    for: ToolConstants.xcodePreference
                )
            }
        }

        do {
            _ = try await fixture.controller.use(mode: .legacy)
            Issue.record("expected external change to be reported")
        } catch let error as CLIError {
            #expect(error.identifier == "preference-conflict")
        }
        fixture.runner.beforeRun = nil
        let eventsBeforeRetry = fixture.workspace.events

        do {
            _ = try await fixture.controller.use(mode: .legacy)
            Issue.record("expected ambiguous state to remain protected")
        } catch let error as CLIError {
            #expect(error.identifier == "ambiguous-intermediate")
        }

        #expect(fixture.runner.mutationCount == 0)
        #expect(fixture.workspace.events == eventsBeforeRetry)
        #expect(fixture.runner.storedBoolean(ToolConstants.xcodePreference) == .trueValue)
        #expect(fixture.runner.storedBoolean(ToolConstants.deviceHubPreference) == .absent)
    }

    @Test func pendingAppliedMutationIsFinalizedBeforeTheNextUse() async throws {
        let fixture = try ControllerFixture()
        let xcode = try InstallationInspector(
            runner: fixture.runner,
            environment: ["DEVELOPER_DIR": fixture.installations.developerDirectoryURL.path],
            signatureValidator: .acceptingTestFixtures
        ).validatedTargetXcode()
        var receipt = RestorationReceipt(
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            xcode: xcode,
            original: .deviceHub
        )
        receipt.pending = PendingMutation(before: .deviceHub, target: .legacy)
        try fixture.receiptStore.withExclusiveLock {
            try fixture.receiptStore.save(receipt)
        }
        fixture.runner.setStoredValue(true, for: ToolConstants.xcodePreference)
        fixture.runner.setStoredValue(true, for: ToolConstants.deviceHubPreference)

        let report = try await fixture.controller.use(mode: .legacy)
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
            signatureValidator: .acceptingTestFixtures
        ).validatedTargetXcode()
        var receipt = RestorationReceipt(
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            xcode: xcode,
            original: .deviceHub
        )
        receipt.pending = PendingMutation(before: .deviceHub, target: .legacy)
        try fixture.receiptStore.withExclusiveLock {
            try fixture.receiptStore.save(receipt)
        }
        fixture.runner.setStoredValue(true, for: ToolConstants.xcodePreference)

        do {
            _ = try await fixture.controller.use(mode: .legacy)
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

    @Test func forceRestoreCanResolveAnAmbiguousIntermediateState() async throws {
        let fixture = try ControllerFixture()
        let xcode = try InstallationInspector(
            runner: fixture.runner,
            environment: ["DEVELOPER_DIR": fixture.installations.developerDirectoryURL.path],
            signatureValidator: .acceptingTestFixtures
        ).validatedTargetXcode()
        var receipt = RestorationReceipt(
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            xcode: xcode,
            original: .deviceHub
        )
        receipt.pending = PendingMutation(before: .deviceHub, target: .legacy)
        try fixture.receiptStore.withExclusiveLock {
            try fixture.receiptStore.save(receipt)
        }
        fixture.runner.setStoredValue(true, for: ToolConstants.xcodePreference)

        do {
            _ = try await fixture.controller.restore()
            Issue.record("expected normal restore to preserve ambiguity")
        } catch let error as CLIError {
            #expect(error.identifier == "ambiguous-intermediate")
        }
        #expect(fixture.runner.mutationCount == 0)

        let report = try await fixture.controller.restore(force: true)

        #expect(report.didRestore)
        #expect(report.restoredState == .deviceHub)
        #expect(fixture.runner.storedBoolean(ToolConstants.xcodePreference) == .absent)
        #expect(fixture.runner.storedBoolean(ToolConstants.deviceHubPreference) == .absent)
        #expect(try fixture.receiptStore.load() == nil)
    }

    @Test func legacyHostLaunchFailureLeavesTheCommittedModeRestorable() async throws {
        let fixture = try ControllerFixture()
        fixture.workspace.openLegacyHostError = CLIError.io("open", "injected open failure")

        do {
            _ = try await fixture.controller.use(mode: .legacy)
            Issue.record("expected standalone host launch failure")
        } catch let error as CLIError {
            #expect(error.identifier == "legacy-host-launch-partial-success")
        }
        #expect(fixture.runner.storedBoolean(ToolConstants.xcodePreference) == .trueValue)
        #expect(try fixture.receiptStore.load() != nil)

        _ = try await fixture.controller.restore()
        #expect(fixture.runner.storedBoolean(ToolConstants.xcodePreference) == .absent)
    }

    @Test func deviceHubTerminationFailureDoesNotOpenTheStandaloneHost() async throws {
        let fixture = try ControllerFixture()
        fixture.workspace.terminateDeviceHubsError = CLIError.temporary(
            "injected-termination",
            "injected Device Hub termination failure"
        )

        do {
            _ = try await fixture.controller.use(mode: .legacy)
            Issue.record("expected Device Hub termination failure")
        } catch let error as CLIError {
            #expect(error.identifier == "device-hub-termination-partial-success")
            #expect(error.category == .temporary)
        }

        #expect(fixture.runner.storedBoolean(ToolConstants.xcodePreference) == .trueValue)
        #expect(fixture.workspace.openedLegacyHosts.isEmpty)
        #expect(
            fixture.workspace.events
                == ["terminate-legacy-hosts", "terminate-device-hubs"]
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
            _ = try await fixture.controller.use(mode: .legacy)
            Issue.record("expected Device Hub identity failure")
        } catch let error as CLIError {
            #expect(error.identifier == "device-hub-termination-partial-success")
            #expect(error.category == .configuration)
        }
        #expect(fixture.workspace.openedLegacyHosts.isEmpty)
    }

    @Test func deviceHubFailurePreventsAConfiguredHostLaunchFailure() async throws {
        let fixture = try ControllerFixture()
        fixture.workspace.terminateDeviceHubsError = CLIError.temporary(
            "injected-termination",
            "injected Device Hub termination failure"
        )
        fixture.workspace.openLegacyHostError = CLIError.io(
            "injected-open",
            "injected standalone host open failure"
        )

        do {
            _ = try await fixture.controller.use(mode: .legacy)
            Issue.record("expected Device Hub termination failure")
        } catch let error as CLIError {
            #expect(error.identifier == "device-hub-termination-partial-success")
            #expect(error.message.contains("Device Hub"))
        }
        #expect(fixture.workspace.openedLegacyHosts.isEmpty)
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
            _ = try await fixture.controller.use(mode: .legacy)
            Issue.record("expected post-await preference conflict")
        } catch let error as CLIError {
            #expect(error.identifier == "legacy-host-invalidated")
            #expect(error.category == .configuration)
        }

        #expect(fixture.workspace.openedLegacyHosts.isEmpty)
        #expect(
            fixture.workspace.events
                == ["terminate-legacy-hosts", "terminate-device-hubs"]
        )
    }

    @Test func legacyHostOpenHoldsTheOperationLockAgainstAnotherSwitch() async throws {
        let fixture = try ControllerFixture()
        fixture.workspace.onOpenLegacyHost = { _ in
            do {
                _ = try await fixture.controller.use(
                    mode: .deviceHub
                )
                Issue.record("expected concurrent switch to be serialized")
            } catch let error as CLIError {
                #expect(error.identifier == "operation-lock")
                #expect(error.category == .temporary)
            }
        }

        let report = try await fixture.controller.use(
            mode: .legacy
        )

        #expect(report.didChange)
        #expect(fixture.runner.storedBoolean(ToolConstants.xcodePreference) == .trueValue)
        #expect(fixture.runner.storedBoolean(ToolConstants.deviceHubPreference) == .trueValue)
    }

    @Test func deviceHubTerminationHoldsTheOperationLockAgainstNewMutations() async throws {
        let fixture = try ControllerFixture()
        fixture.workspace.onTerminateDeviceHubs = {
            do {
                _ = try await fixture.controller.use(
                    mode: .deviceHub
                )
                Issue.record("expected concurrent switch to be serialized")
            } catch let error as CLIError {
                #expect(error.identifier == "operation-lock")
                #expect(error.category == .temporary)
            } catch {
                Issue.record("unexpected switch error: \(error)")
            }

            do {
                _ = try await fixture.controller.restore()
                Issue.record("expected concurrent restore to be serialized")
            } catch let error as CLIError {
                #expect(error.identifier == "operation-lock")
                #expect(error.category == .temporary)
            } catch {
                Issue.record("unexpected restore error: \(error)")
            }
        }

        let report = try await fixture.controller.use(
            mode: .legacy
        )

        #expect(report.didChange)
        #expect(fixture.runner.storedBoolean(ToolConstants.xcodePreference) == .trueValue)
        #expect(fixture.runner.storedBoolean(ToolConstants.deviceHubPreference) == .trueValue)
    }

    @Test func legacyHostLaunchFailureWithoutAReceiptDoesNotSuggestRestore() async throws {
        let fixture = try ControllerFixture(initialState: .legacy)
        fixture.workspace.openLegacyHostError = CLIError.io("open", "injected open failure")

        do {
            _ = try await fixture.controller.use(mode: .legacy)
            Issue.record("expected standalone host launch failure")
        } catch let error as CLIError {
            #expect(error.identifier == "legacy-host-launch-partial-success")
            #expect(error.message.contains("No restoration receipt exists"))
            #expect(!error.message.contains("run restore"))
        }
        #expect(try fixture.receiptStore.load() == nil)
    }

    @Test func restoreWithoutAReceiptIsADocumentedNoOp() async throws {
        let fixture = try ControllerFixture()
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.receiptStore.directoryURL.path
            )
        )
        let report = try await fixture.controller.restore()

        #expect(!report.didRestore)
        #expect(fixture.runner.mutationCount == 0)
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.receiptStore.directoryURL.path
            )
        )
    }

    @Test func restoreWithoutAReceiptDoesNotReadInvalidPreferences() async throws {
        let fixture = try ControllerFixture()
        fixture.runner.setStoredValue("not-a-boolean", for: ToolConstants.xcodePreference)

        let report = try await fixture.controller.restore()

        #expect(!report.didRestore)
        #expect(fixture.runner.calls.isEmpty)
    }

    @Test func runningXcodeDoesNotBlockRestore() async throws {
        let fixture = try ControllerFixture()
        _ = try await fixture.controller.use(mode: .legacy)
        fixture.workspace.runningXcodes = [
            RunningApplication(
                processIdentifier: 42,
                bundleURL: URL(fileURLWithPath: "/Applications/Xcode_27.app")
            ),
        ]

        let report = try await fixture.controller.restore()

        #expect(report.didRestore)
        #expect(fixture.runner.mutationCount == 4)
        #expect(try fixture.receiptStore.load() == nil)
    }

    @Test func legacyHostTerminationHoldsTheOperationLockAgainstRestore() async throws {
        let fixture = try ControllerFixture()
        _ = try await fixture.controller.use(mode: .legacy)
        var checkedRestore = false
        fixture.workspace.onTerminateLegacyHosts = {
            checkedRestore = true
            do {
                _ = try await fixture.controller.restore()
                Issue.record("expected restore to observe the active operation lock")
            } catch let error as CLIError {
                #expect(error.identifier == "operation-lock")
                #expect(error.category == .temporary)
            } catch {
                Issue.record("unexpected restore error: \(error)")
            }
        }

        let report = try await fixture.controller.use(mode: .deviceHub)

        #expect(checkedRestore)
        #expect(report.didChange)
        #expect(fixture.runner.storedBoolean(ToolConstants.xcodePreference) == .absent)
        #expect(fixture.runner.storedBoolean(ToolConstants.deviceHubPreference) == .absent)
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
            mode: .deviceHub
        )

        #expect(report.didChange)
        #expect(fixture.runner.storedBoolean(ToolConstants.xcodePreference) == .absent)
        #expect(fixture.workspace.events == ["terminate-legacy-hosts"])
    }

    @Test func sudoIsRejectedBeforeMutation() async throws {
        let fixture = try ControllerFixture(effectiveUserID: 0)

        do {
            _ = try await fixture.controller.use(mode: .legacy)
            Issue.record("expected root user to be rejected")
        } catch let error as CLIError {
            #expect(error.identifier == "root-user")
        }
        #expect(fixture.runner.mutationCount == 0)
    }

    @Test func statusIsReadOnly() throws {
        let fixture = try ControllerFixture()
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.receiptStore.directoryURL.path
            )
        )
        fixture.workspace.runningXcodes = [
            RunningApplication(
                processIdentifier: 42,
                bundleURL: URL(fileURLWithPath: "/Applications/Xcode_27.app")
            ),
        ]
        let status = try fixture.controller.status()

        #expect(status.routeStatus.preferences == .deviceHub)
        #expect(status.legacyHost != nil)
        #expect(fixture.runner.mutationCount == 0)
        #expect(try fixture.receiptStore.load() == nil)
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.receiptStore.directoryURL.path
            )
        )
        #expect(status.rendered.contains("hot switching is supported"))
        #expect(!status.rendered.contains("mode changes are blocked"))
    }

    @Test func routeStatusRetriesWhenStateAppearsDuringTheOptimisticSnapshot() throws {
        let fixture = try ControllerFixture()
        var createdState = false
        fixture.runner.beforeRun = { call in
            guard !createdState,
                  call.executable.path == "/usr/bin/defaults",
                  call.arguments == ["domains"]
            else {
                return
            }
            createdState = true
            do {
                try fixture.receiptStore.withExclusiveLock {}
            } catch {
                Issue.record("could not create simulated concurrent state: \(error)")
            }
        }

        let status = try fixture.controller.routeStatus()

        #expect(createdState)
        #expect(status.preferences == .deviceHub)
        #expect(status.receiptStatus == .unmanaged)
        #expect(
            fixture.runner.calls.filter {
                $0.executable.path == "/usr/bin/defaults"
                    && $0.arguments == ["domains"]
            }.count == 2
        )
    }
}
