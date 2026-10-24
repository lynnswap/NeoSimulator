import Foundation
import Darwin
import Testing

@testable import XcodeSimulatorHost

@MainActor
@Suite
struct HostModeControllerTests {
    @Test func neoAndDeviceHubModesRoundTripTheOriginalAbsentState() async throws {
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

        let neo = try await fixture.controller.use(.neo)
        #expect(neo.didChangePreferences)
        #expect(fixture.runner.storedBoolean(ToolConstants.xcodePreference) == .trueValue)
        #expect(fixture.runner.storedBoolean(ToolConstants.deviceHubPreference) == .trueValue)
        #expect(neo.receiptURL != nil)
        #expect(neo.terminatedDeviceHubCount == 1)
        guard case .neo(let neoHost) = neo.host else {
            Issue.record("expected resolved NeoSimulator")
            return
        }
        #expect(
            fixture.workspace.openedNeoHosts
                == [
                    WorkspaceRecorder.NeoHostOpen(
                        applicationURL: neoHost.applicationURL,
                        xcodeURL: fixture.installations.targetXcodeURL
                    ),
                ]
        )
        #expect(
            fixture.workspace.events
                == [
                    "terminate-device-hubs",
                    "open-neo-host",
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

        fixture.workspace.neoHostCount = 1
        let deviceHub = try await fixture.controller.use(.deviceHub)
        #expect(deviceHub.didChangePreferences)
        #expect(fixture.runner.storedBoolean(ToolConstants.xcodePreference) == .absent)
        #expect(fixture.runner.storedBoolean(ToolConstants.deviceHubPreference) == .absent)
        #expect(deviceHub.receiptURL == nil)
        #expect(deviceHub.terminatedDeviceHubCount == 0)
        #expect(deviceHub.terminatedNeoHostCount == 1)
        #expect(
            fixture.workspace.events
                == [
                    "terminate-device-hubs",
                    "open-neo-host",
                    "terminate-neo-hosts",
                    "open-device-hub",
                ]
        )
        #expect(
            fixture.workspace.requestedNeoHostURLs
                == [
                    fixture.installations.neoHostURL,
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

        _ = try await fixture.controller.use(.neo)
        let loadedReceipt = try fixture.receiptStore.load()
        let receipt = try #require(loadedReceipt)
        #expect(receipt.original == original)

        fixture.workspace.neoHostCount = 1
        fixture.workspace.onTerminateNeoHosts = {
            #expect(
                fixture.runner.storedBoolean(ToolConstants.xcodePreference)
                    == .trueValue
            )
        }
        let restored = try await fixture.controller.restore()
        #expect(restored.didRestore)
        #expect(restored.terminatedNeoHostCount == 1)
        #expect(fixture.runner.storedBoolean(ToolConstants.xcodePreference) == .falseValue)
        #expect(fixture.runner.storedBoolean(ToolConstants.deviceHubPreference) == .trueValue)
        #expect(try fixture.receiptStore.load() == nil)
        #expect(
            fixture.workspace.events
                == [
                    "terminate-device-hubs",
                    "open-neo-host",
                    "terminate-neo-hosts",
                ]
        )
    }

    @Test func restoringACoreSimulatorRouteDoesNotCloseTheNeoHost() async throws {
        let fixture = try ControllerFixture(initialState: .coreSimulator)
        _ = try await fixture.controller.use(.deviceHub)
        #expect(
            fixture.workspace.events
                == ["terminate-neo-hosts", "open-device-hub"]
        )

        let report = try await fixture.controller.restore()

        #expect(report.didRestore)
        #expect(report.restoredState == .coreSimulator)
        #expect(report.terminatedNeoHostCount == 0)
        #expect(
            fixture.workspace.events
                == ["terminate-neo-hosts", "open-device-hub"]
        )
        #expect(fixture.runner.storedBoolean(ToolConstants.xcodePreference) == .trueValue)
        #expect(
            fixture.runner.storedBoolean(ToolConstants.deviceHubPreference)
                == .trueValue
        )
    }

    @Test func differentXcodesLaunchIndependentRenderersAndReuseKeepsThemRunning() async throws {
        let fixture = try ControllerFixture(targetVersion: "27.1")
        let otherXcode = fixture.installations.applicationsURL.appendingPathComponent("Xcode_27.2.app", isDirectory: true)
        try InstallationFixture.makeTargetXcode(at: otherXcode, version: "27.2", build: "27C100", includeHiddenKey: true,
            includeDeviceHubKey: true, simctlExpectedVersion: "1171.9", devicectlExpectedVersion: "642.18", dtXcode: 2720)
        let first = try await fixture.controller.use(.neo)
        let second = try await fixture.controller.use(.neo, xcodeURL: otherXcode)
        _ = try await fixture.controller.use(.neo, xcodeURL: otherXcode, launchNeoHost: false)
        #expect(first.terminatedNeoHostCount == 0)
        #expect(second.terminatedNeoHostCount == 0)
        #expect(fixture.workspace.requestedNeoHostURLs.isEmpty)
        #expect(fixture.workspace.openedNeoHosts.map(\.xcodeURL) == [fixture.installations.targetXcodeURL, otherXcode])
        #expect(try fixture.receiptStore.load()?.original == .deviceHub)
    }

    @Test func neoModeRejectsAMissingHostBeforeChangingPreferences() async throws {
        let fixture = try ControllerFixture(includeNeoHost: false)

        do {
            _ = try await fixture.controller.use(.neo)
            Issue.record("expected missing standalone host to fail")
        } catch let error as CLIError {
            #expect(error.identifier == "neo-host-bundle")
            #expect(error.category == .unavailable)
        }

        #expect(fixture.runner.mutationCount == 0)
        #expect(fixture.workspace.events.isEmpty)
        #expect(try fixture.receiptStore.load() == nil)
    }

    @Test func neoToolGateFailsBeforeChangingPreferencesOrProcesses() async throws {
        let fixture = try ControllerFixture()
        try Data("#!/bin/zsh\nEXPECTED_VERSION='642.15'\n".utf8).write(
            to: fixture.installations.devicectlWrapperURL
        )

        do {
            _ = try await fixture.controller.use(.neo)
            Issue.record("expected changed devicectl wrapper to fail")
        } catch let error as CLIError {
            #expect(error.identifier == "devicectl-wrapper-version")
            #expect(error.category == .unavailable)
        }

        #expect(fixture.runner.mutationCount == 0)
        #expect(fixture.workspace.events.isEmpty)
        #expect(try fixture.receiptStore.load() == nil)
    }

    @Test func missingRuntimeSymbolFailsBeforeChangingPreferencesOrProcesses() async throws {
        let fixture = try ControllerFixture(
            neoHostRuntimeValidationStatus: 69
        )

        do {
            _ = try await fixture.controller.use(.neo)
            Issue.record("expected missing SimulatorKit runtime symbols to fail")
        } catch let error as CLIError {
            #expect(error.identifier == "neo-host-runtime")
            #expect(error.category == .unavailable)
        }

        #expect(fixture.runner.mutationCount == 0)
        #expect(fixture.workspace.events.isEmpty)
        #expect(try fixture.receiptStore.load() == nil)
    }

    @Test func deviceHubModeCanRecoverWhenThePackagedHostIsMissing() async throws {
        let fixture = try ControllerFixture(
            initialState: .coreSimulator,
            includeNeoHost: false
        )

        let report = try await fixture.controller.use(.deviceHub)

        #expect(report.didChangePreferences)
        #expect(fixture.runner.storedBoolean(ToolConstants.xcodePreference) == .absent)
        #expect(
            fixture.workspace.events
                == ["terminate-neo-hosts", "open-device-hub"]
        )
        #expect(
            fixture.workspace.requestedNeoHostURLs
                == [fixture.installations.neoHostURL]
        )
    }

    @Test func deviceHubModeDoesNotDependOnTheNeoToolGate() async throws {
        let fixture = try ControllerFixture(initialState: .coreSimulator)
        try Data("#!/bin/zsh\nEXPECTED_VERSION='642.15'\n".utf8).write(
            to: fixture.installations.devicectlWrapperURL
        )

        let report = try await fixture.controller.use(.deviceHub)

        #expect(report.didChangePreferences)
        #expect(fixture.runner.storedBoolean(ToolConstants.xcodePreference) == .absent)
        #expect(
            fixture.workspace.events
                == ["terminate-neo-hosts", "open-device-hub"]
        )
    }

    @Test func deviceHubLaunchFailureReportsConfiguredRouteAndRecoveryReceipt() async throws {
        let fixture = try ControllerFixture(initialState: .coreSimulator)
        fixture.workspace.openDeviceHubError = CLIError.io("launch", "injected Device Hub launch failure")
        do {
            _ = try await fixture.controller.use(.deviceHub)
            Issue.record("expected launch failure")
        } catch let error as CLIError {
            #expect(error.identifier == "device-hub-host-launch-partial-success")
            #expect(error.message.contains("Restore Original Settings"))
        }
        #expect(fixture.runner.storedBoolean(ToolConstants.xcodePreference) == .absent)
        #expect(try fixture.receiptStore.load()?.original == .coreSimulator)
    }

    @Test func deviceHubModeDoesNotChangePreferencesWhenHostCannotClose() async throws {
        let fixture = try ControllerFixture(initialState: .coreSimulator)
        fixture.workspace.terminateNeoHostsError = CLIError.temporary(
            "injected-termination",
            "injected standalone host termination failure"
        )

        do {
            _ = try await fixture.controller.use(.deviceHub)
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
        #expect(fixture.workspace.events == ["terminate-neo-hosts"])
    }

    @Test func runningXcodeDoesNotBlockNeoMode() async throws {
        let fixture = try ControllerFixture()
        fixture.workspace.runningXcodes = [
            RunningApplication(
                processIdentifier: 42,
                bundleURL: URL(fileURLWithPath: "/Applications/Xcode_27.app")
            ),
        ]

        let report = try await fixture.controller.use(.neo)

        #expect(report.didChangePreferences)
        #expect(fixture.runner.mutationCount == 2)
        #expect(try fixture.receiptStore.load() != nil)
        #expect(
            fixture.workspace.events
                == [
                    "terminate-device-hubs",
                    "open-neo-host",
                ]
        )
    }

    @Test func secondPreferenceFailureRollsBackTheFirstPreference() async throws {
        let fixture = try ControllerFixture()
        fixture.runner.failMutationNumbers = [2]

        do {
            _ = try await fixture.controller.use(.neo)
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
            _ = try await fixture.controller.use(.neo)
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
        fixture.runner.failFirstPreferenceReadAfterMutationCount = 2

        do {
            _ = try await fixture.controller.use(.neo)
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
            _ = try await fixture.controller.use(.neo)
            Issue.record("expected rollback failure")
        } catch let error as CLIError {
            #expect(error.identifier == "inconsistent-preferences")
        }

        #expect(fixture.runner.storedBoolean(ToolConstants.xcodePreference) == .trueValue)
        #expect(fixture.runner.storedBoolean(ToolConstants.deviceHubPreference) == .absent)
        let status = try fixture.controller.routeStatus()
        #expect(status.receiptStatus == .ambiguousIntermediate)
    }

    @Test func externalPreferenceChangeIsReportedAsAConflict() async throws {
        let fixture = try ControllerFixture()
        _ = try await fixture.controller.use(.neo)
        fixture.runner.setStoredValue(false, for: ToolConstants.xcodePreference)

        let status = try fixture.controller.routeStatus()
        #expect(status.receiptStatus.hasConflict)
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
        let fixture = try ControllerFixture(initialState: .coreSimulator)
        var injectedChange = false
        fixture.runner.beforeRun = { call in
            guard !injectedChange,
                  fixture.runner.mutationCount == 1,
                  call.executable.path == "/usr/bin/defaults",
                  call.arguments == ["read", ToolConstants.xcodePreference.domain]
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
            _ = try await fixture.controller.use(.deviceHub)
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
                  call.arguments == ["read", ToolConstants.xcodePreference.domain]
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
            _ = try await fixture.controller.use(.neo)
            Issue.record("expected external change to be reported")
        } catch let error as CLIError {
            #expect(error.identifier == "preference-conflict")
        }

        #expect(fixture.runner.mutationCount == 0)
        #expect(fixture.runner.storedBoolean(ToolConstants.xcodePreference) == .falseValue)
        let loadedReceipt = try fixture.receiptStore.load()
        let receipt = try #require(loadedReceipt)
        #expect(
            receipt.pending
                == PendingMutation(before: .deviceHub, target: .coreSimulator)
        )
    }

    @Test func externalChangeMatchingAnIntermediateIsNeverAssumedToBeOurs() async throws {
        let fixture = try ControllerFixture()
        var stateReadCount = 0
        fixture.runner.beforeRun = { call in
            guard call.executable.path == "/usr/bin/defaults",
                  call.arguments == ["read", ToolConstants.xcodePreference.domain]
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
            _ = try await fixture.controller.use(.neo)
            Issue.record("expected external change to be reported")
        } catch let error as CLIError {
            #expect(error.identifier == "preference-conflict")
        }
        fixture.runner.beforeRun = nil
        let eventsBeforeRetry = fixture.workspace.events

        do {
            _ = try await fixture.controller.use(.neo)
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
        receipt.pending = PendingMutation(
            before: .deviceHub,
            target: .coreSimulator
        )
        try fixture.receiptStore.withExclusiveLock {
            try fixture.receiptStore.save(receipt)
        }
        fixture.runner.setStoredValue(true, for: ToolConstants.xcodePreference)
        fixture.runner.setStoredValue(true, for: ToolConstants.deviceHubPreference)

        let report = try await fixture.controller.use(.neo)
        #expect(!report.didChangePreferences)
        let loadedReceipt = try fixture.receiptStore.load()
        let recovered = try #require(loadedReceipt)
        #expect(recovered.expectedCurrent == .coreSimulator)
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
        receipt.pending = PendingMutation(
            before: .deviceHub,
            target: .coreSimulator
        )
        try fixture.receiptStore.withExclusiveLock {
            try fixture.receiptStore.save(receipt)
        }
        fixture.runner.setStoredValue(true, for: ToolConstants.xcodePreference)

        do {
            _ = try await fixture.controller.use(.neo)
            Issue.record("expected ambiguous intermediate state")
        } catch let error as CLIError {
            #expect(error.identifier == "ambiguous-intermediate")
        }

        #expect(fixture.runner.storedBoolean(ToolConstants.xcodePreference) == .trueValue)
        #expect(fixture.runner.storedBoolean(ToolConstants.deviceHubPreference) == .absent)
        let loadedReceipt = try fixture.receiptStore.load()
        let recovered = try #require(loadedReceipt)
        #expect(recovered.expectedCurrent == .deviceHub)
        #expect(
            recovered.pending
                == PendingMutation(before: .deviceHub, target: .coreSimulator)
        )
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
        receipt.pending = PendingMutation(
            before: .deviceHub,
            target: .coreSimulator
        )
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

    @Test func neoHostLaunchFailureLeavesTheCommittedModeRestorable() async throws {
        let fixture = try ControllerFixture()
        fixture.workspace.openNeoHostError = CLIError.io("open", "injected open failure")

        do {
            _ = try await fixture.controller.use(.neo)
            Issue.record("expected standalone host launch failure")
        } catch let error as CLIError {
            #expect(error.identifier == "neo-host-launch-partial-success")
            #expect(SimulatorHostFailure(error).kind == .partialSuccess)
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
            _ = try await fixture.controller.use(.neo)
            Issue.record("expected Device Hub termination failure")
        } catch let error as CLIError {
            #expect(error.identifier == "device-hub-termination-partial-success")
            #expect(error.category == .temporary)
        }

        #expect(fixture.runner.storedBoolean(ToolConstants.xcodePreference) == .trueValue)
        #expect(fixture.workspace.openedNeoHosts.isEmpty)
        #expect(
            fixture.workspace.events
                == [
                    "terminate-device-hubs",
                ]
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
            _ = try await fixture.controller.use(.neo)
            Issue.record("expected Device Hub identity failure")
        } catch let error as CLIError {
            #expect(error.identifier == "device-hub-termination-partial-success")
            #expect(error.category == .configuration)
        }
        #expect(fixture.workspace.openedNeoHosts.isEmpty)
    }

    @Test func deviceHubFailurePreventsAConfiguredHostLaunchFailure() async throws {
        let fixture = try ControllerFixture()
        fixture.workspace.terminateDeviceHubsError = CLIError.temporary(
            "injected-termination",
            "injected Device Hub termination failure"
        )
        fixture.workspace.openNeoHostError = CLIError.io(
            "injected-open",
            "injected standalone host open failure"
        )

        do {
            _ = try await fixture.controller.use(.neo)
            Issue.record("expected Device Hub termination failure")
        } catch let error as CLIError {
            #expect(error.identifier == "device-hub-termination-partial-success")
            #expect(error.message.contains("Device Hub"))
        }
        #expect(fixture.workspace.openedNeoHosts.isEmpty)
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
            _ = try await fixture.controller.use(.neo)
            Issue.record("expected post-await preference conflict")
        } catch let error as CLIError {
            #expect(error.identifier == "neo-host-invalidated")
            #expect(error.category == .configuration)
        }

        #expect(fixture.workspace.openedNeoHosts.isEmpty)
        #expect(
            fixture.workspace.events
                == [
                    "terminate-device-hubs",
                ]
        )
    }

    @Test func neoHostOpenHoldsTheOperationLockAgainstAnotherSwitch() async throws {
        let fixture = try ControllerFixture()
        fixture.workspace.onOpenNeoHost = { _ in
            do {
                _ = try await fixture.controller.use(.deviceHub)
                Issue.record("expected concurrent switch to be serialized")
            } catch let error as CLIError {
                #expect(error.identifier == "operation-lock")
                #expect(error.category == .temporary)
            }
        }

        let report = try await fixture.controller.use(.neo)

        #expect(report.didChangePreferences)
        #expect(fixture.runner.storedBoolean(ToolConstants.xcodePreference) == .trueValue)
        #expect(fixture.runner.storedBoolean(ToolConstants.deviceHubPreference) == .trueValue)
    }

    @Test func deviceHubTerminationHoldsTheOperationLockAgainstNewMutations() async throws {
        let fixture = try ControllerFixture()
        fixture.workspace.onTerminateDeviceHubs = {
            do {
                _ = try await fixture.controller.use(.deviceHub)
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

        let report = try await fixture.controller.use(.neo)

        #expect(report.didChangePreferences)
        #expect(fixture.runner.storedBoolean(ToolConstants.xcodePreference) == .trueValue)
        #expect(fixture.runner.storedBoolean(ToolConstants.deviceHubPreference) == .trueValue)
    }

    @Test func neoHostLaunchFailureWithoutAReceiptDoesNotSuggestRestore() async throws {
        let fixture = try ControllerFixture(initialState: .coreSimulator)
        fixture.workspace.openNeoHostError = CLIError.io("open", "injected open failure")

        do {
            _ = try await fixture.controller.use(.neo)
            Issue.record("expected standalone host launch failure")
        } catch let error as CLIError {
            #expect(error.identifier == "neo-host-launch-partial-success")
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
        _ = try await fixture.controller.use(.neo)
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

    @Test func neoHostTerminationHoldsTheOperationLockAgainstRestore() async throws {
        let fixture = try ControllerFixture()
        _ = try await fixture.controller.use(.neo)
        var checkedRestore = false
        fixture.workspace.onTerminateNeoHosts = {
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

        let report = try await fixture.controller.use(.deviceHub)

        #expect(checkedRestore)
        #expect(report.didChangePreferences)
        #expect(fixture.runner.storedBoolean(ToolConstants.xcodePreference) == .absent)
        #expect(fixture.runner.storedBoolean(ToolConstants.deviceHubPreference) == .absent)
    }

    @Test func runningXcodeDoesNotBlockDeviceHubMode() async throws {
        let fixture = try ControllerFixture(initialState: .coreSimulator)
        fixture.workspace.runningXcodes = [
            RunningApplication(
                processIdentifier: 42,
                bundleURL: URL(fileURLWithPath: "/Applications/Xcode_27.app")
            ),
        ]

        let report = try await fixture.controller.use(.deviceHub)

        #expect(report.didChangePreferences)
        #expect(fixture.runner.storedBoolean(ToolConstants.xcodePreference) == .absent)
        #expect(
            fixture.workspace.events
                == ["terminate-neo-hosts", "open-device-hub"]
        )
    }

    @Test func sudoIsRejectedBeforeMutation() async throws {
        let fixture = try ControllerFixture(effectiveUserID: 0)

        do {
            _ = try await fixture.controller.use(.neo)
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
        let status = try fixture.controller.routeStatus()

        #expect(status.preferences == .deviceHub)
        #expect(fixture.runner.mutationCount == 0)
        #expect(try fixture.receiptStore.load() == nil)
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.receiptStore.directoryURL.path
            )
        )
    }

    @Test func routeStatusRetriesWhenStateAppearsDuringTheOptimisticSnapshot() throws {
        let fixture = try ControllerFixture()
        var createdState = false
        fixture.runner.beforeRun = { call in
            guard !createdState,
                  call.executable.path == "/usr/bin/defaults",
                  call.arguments == ["read", ToolConstants.xcodePreference.domain]
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
                    && $0.arguments == ["read", ToolConstants.xcodePreference.domain]
            }.count == 2
        )
    }
}

@Suite struct SimulatorDeviceCatalogTests {
    @Test func menusListAvailableDevicesAcrossSupportedFamilies() throws {
        let devices = try SimulatorDeviceCatalog.decode(Data(#"""
        {
          "devicetypes": [
            {"identifier":"phone-type","productFamily":"iPhone"},
            {"identifier":"tv-type","productFamily":"Apple TV"}
          ],
          "runtimes": [
            {"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-27-0","name":"iOS 27.0","isAvailable":true},
            {"identifier":"com.apple.CoreSimulator.SimRuntime.tvOS-27-0","name":"tvOS 27.0","isAvailable":true}
          ],
          "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
              {"udid":"phone","deviceTypeIdentifier":"phone-type","name":"iPhone","state":"Booted","isAvailable":true},
              {"udid":"missing","deviceTypeIdentifier":"phone-type","name":"Unavailable","state":"Shutdown","isAvailable":false}
            ],
            "com.apple.CoreSimulator.SimRuntime.tvOS-27-0": [
              {"udid":"tv","deviceTypeIdentifier":"tv-type","name":"Apple TV","state":"Shutdown","isAvailable":true}
            ]
          }
        }
        """#.utf8))
        #expect(Set(devices.map(\.identifier)) == ["phone", "tv"])
        #expect(devices.first(where: { $0.identifier == "phone" })?.state == "Booted")
        #expect(devices.first(where: { $0.identifier == "tv" })?.runtimeName == "tvOS 27.0")
    }
}

@Suite
struct HostHandoffTerminationTests {
    @Test(arguments: [HostTerminationRequest.deviceHubHandoff, .rendererHandoff])
    func handoffsAvoidUserQuit(_ request: HostTerminationRequest) throws {
        let directory = try TemporaryTestDirectory()
        let cleanup = directory.url.appendingPathComponent("signal-cleanup")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import signal,sys,pathlib\ndef shutdown(*args):\n pathlib.Path(sys.argv[1]).write_text('shutdown')\n sys.exit(0)\nsignal.signal(signal.SIGTERM, shutdown)\nprint('ready', flush=True)\nsignal.pause()", cleanup.path]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        defer { if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() } }
        #expect(try output.fileHandleForReading.read(upToCount: 6) == Data("ready\n".utf8))
        var requestedNormalQuit = false
        #expect(request.perform(
            processIdentifier: process.processIdentifier,
            normalQuit: {
                requestedNormalQuit = true
                process.terminate()
                return true
            },
            forceQuit: { kill(process.processIdentifier, SIGKILL) == 0 }
        ))
        process.waitUntilExit()
        #expect(!requestedNormalQuit)
        switch request {
        case .deviceHubHandoff:
            #expect(process.terminationReason == .uncaughtSignal)
            #expect(process.terminationStatus == SIGKILL)
            #expect(!FileManager.default.fileExists(atPath: cleanup.path))
        case .rendererHandoff:
            #expect(process.terminationReason == .exit)
            #expect(process.terminationStatus == 0)
            #expect(FileManager.default.fileExists(atPath: cleanup.path))
        case .normalQuit: Issue.record("A handoff must not request a normal user quit.")
        }
    }
}
