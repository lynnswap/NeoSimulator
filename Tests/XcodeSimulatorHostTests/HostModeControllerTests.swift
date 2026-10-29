import Foundation
import Darwin
import Testing
import XCTest
import Synchronization

@_spi(NeoSimulator) @testable import XcodeSimulatorHost

@MainActor
@Suite
struct HostModeControllerTests {
    @Test(.timeLimit(.minutes(1))) func aCancelledQueuedOperationDoesNotRunOrBlockItsSuccessor() async throws {
        let controller = SimulatorHostController(rendererApplicationURL: URL(fileURLWithPath: "/Renderer.app"))
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let first = Task {
            try await controller.operation { @Sendable in
                entered.continuation.yield(())
                for await _ in release.stream { break }
            }
        }
        var events = entered.stream.makeAsyncIterator()
        await events.next()
        let cancelled = Task { try await controller.operation { @Sendable in true } }
        cancelled.cancel()
        release.continuation.yield(())
        try await first.value
        do {
            _ = try await cancelled.value
            Issue.record("A cancelled open entered the controller operation")
        } catch is CancellationError {}
        let value = try await controller.operation { @Sendable in 42 }
        #expect(value == 42)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func aCancelledRuntimeWaiterRetiresWithoutCancellingSharedPreparation(_ finishConcurrently: Bool) async throws {
        var finish: CheckedContinuation<Int, any Error>?
        let preparation = Task.immediate {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, any Error>) in
                finish = continuation
            }
        }
        let cancelled = XCTestExpectation(description: "Cancelled runtime consumer retires")
        let waiting = Task.immediate {
            defer { cancelled.fulfill() }
            return try await CoreDeviceRuntime.preparedValue(of: preparation)
        }
        let other = Task.immediate { try await CoreDeviceRuntime.preparedValue(of: preparation) }
        waiting.cancel()
        if finishConcurrently { finish?.resume(returning: 42); finish = nil }
        let result = await XCTWaiter.fulfillment(of: [cancelled], timeout: 5)
        #expect(result == .completed)
        #expect(!preparation.isCancelled)
        finish?.resume(returning: 42)
        do { #expect(try await waiting.value == 42 && finishConcurrently) }
        catch is CancellationError {}
        #expect(try await other.value == 42)

        let beforeRegistration = Task { try await CoreDeviceRuntime.preparedValue(of: preparation) }
        beforeRegistration.cancel()
        do { _ = try await beforeRegistration.value; Issue.record("A cancelled consumer registered a runtime wait") }
        catch is CancellationError {}
        #expect(try await CoreDeviceRuntime.preparedValue(of: preparation) == 42)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingAQueuedIntentAlsoRetiresAnOlderAutomaticOpen() async throws {
        let controller = SimulatorHostController(rendererApplicationURL: URL(fileURLWithPath: "/Renderer.app"))
        let device = DeviceInventoryID.simulator(udid: "A", deviceSetPath: nil)
        let automatic = controller.makeScreenOpenRequest(for: device)
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let completed = XCTestExpectation(description: "Older automatic open retired")
        let presented = Mutex(false)
        let opening = Task {
            defer { completed.fulfill() }
            try await controller.operation { @Sendable in
                try await controller.screenOpen(automatic) {
                    entered.continuation.yield(())
                    for await _ in release.stream { break }
                    try Task.checkCancellation()
                    presented.withLock { $0 = true }
                }
            }
        }
        var events = entered.stream.makeAsyncIterator()
        await events.next()
        // This request is still in the manager's queue, so it has never entered the controller.
        let queued = controller.makeScreenOpenRequest(for: device)
        let clone = controller.makeScreenOpenRequest(for: .simulator(udid: "A", deviceSetPath: "/other-set"))
        queued.cancel()
        let retired = await XCTWaiter.fulfillment(of: [completed], timeout: 2)
        #expect(retired == .completed)
        release.continuation.yield(())
        do { try await opening.value; Issue.record("The older automatic intent survived cancellation") }
        catch is CancellationError {}
        #expect(!presented.withLock { $0 })

        do {
            try await controller.operation { @Sendable in try await controller.screenOpen(queued) { presented.withLock { $0 = true } } }
            Issue.record("A cancelled queued intent entered the open pipeline")
        } catch is CancellationError {}
        #expect(!presented.withLock { $0 })
        // A new explicit request and a different device set are independent of the retired intent.
        let reopened = controller.makeScreenOpenRequest(for: device)
        try await controller.operation { @Sendable in try await controller.screenOpen(reopened) {} }
        try await controller.operation { @Sendable in try await controller.screenOpen(clone) {} }
    }

    @Test func cancellingAnOpenConsumesOnlyOlderXcodeConnections() async throws {
        let controller = SimulatorHostController(rendererApplicationURL: URL(fileURLWithPath: "/Renderer.app"))
        let tracker = XcodeConnectionTracker()
        let device = DeviceInventoryID.simulator(udid: "A", deviceSetPath: nil)
        let old = XcodeSimulatorConnection(event: .init(processIdentifier: 1, startSeconds: 1, startMicroseconds: 0),
                                          deviceIdentifier: "A", xcodeURL: URL(fileURLWithPath: "/Xcode.app"))
        let clone = XcodeSimulatorConnection(event: old.event, deviceIdentifier: "A", xcodeURL: old.xcodeURL, deviceSetPath: "/other-set")
        let newer = XcodeSimulatorConnection(event: .init(processIdentifier: 2, startSeconds: UInt64(Date().timeIntervalSince1970) + 1, startMicroseconds: 0),
                                            deviceIdentifier: "A", xcodeURL: old.xcodeURL)
        controller.makeScreenOpenRequest(for: device).cancel()
        var transferred: [XcodeSimulatorConnection] = []
        _ = try await tracker.synchronize(observations: [old, clone],
            runningDeviceIdentifiers: [device, clone.deviceID], testingDeviceSetPath: "/other-set",
            isCancelled: { controller.isCancelledScreenConnection($0) }) { transferred.append($0) }
        #expect(transferred == [clone])
        #expect(!tracker.hasPendingConnection(forDevice: device, isCancelled: { controller.isCancelledScreenConnection($0) }))
        _ = try await tracker.synchronize(observations: [newer], runningDeviceIdentifiers: [device, clone.deviceID],
            testingDeviceSetPath: "/other-set", isCancelled: { controller.isCancelledScreenConnection($0) }) { transferred.append($0) }
        #expect(transferred == [clone, newer])
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func cancelledLaunchWaitsForExitAndPreservesCleanupFailure(_ cleanupFails: Bool) async throws {
        let launch = AsyncStream<Void>.makeStream()
        let exit = AsyncStream<Void>.makeStream()
        let cleanupStarted = XCTestExpectation(description: "Renderer termination started")
        var finished = false
        let opening = Task.immediate {
            for await _ in launch.stream { break }
            defer { finished = true }
            try await WorkspaceClient.finishFailedNeoHostLaunch(CancellationError(), processIdentifier: 123) {
                cleanupStarted.fulfill()
                try Task.checkCancellation()
                for await _ in exit.stream { break }
                if cleanupFails { throw CLIError.temporary("termination", "Renderer did not exit") }
            }
        }
        opening.cancel()
        launch.continuation.yield(())
        let started = await XCTWaiter.fulfillment(of: [cleanupStarted], timeout: 5)
        #expect(started == .completed)
        #expect(!finished)
        exit.continuation.yield(())
        do { try await opening.value; Issue.record("A cancelled launch succeeded") }
        catch is CancellationError { #expect(!cleanupFails) }
        catch let error as CLIError {
            #expect(cleanupFails)
            #expect(error.identifier == "neo-host-launch-cleanup")
            #expect(error.message.contains("Renderer did not exit"))
        }
    }

    @Test func anExitedRendererRetainsItsStartupFailureAndRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = directory.appendingPathComponent("result")
        let reason = "Device Hub is running or launched during startup; close it before opening NeoSimulator"
        let recovery = "Close the other display app, then choose View Screen again."
        try JSONEncoder().encode(RendererStartupResult.failed(message: reason, recoverySuggestion: recovery))
            .write(to: result, options: .atomic)
        do {
            try await WorkspaceClient.waitForNeoHostStartup(resultURL: result, isTerminated: { true })
            Issue.record("An exited renderer reported successful startup")
        } catch {
            let failure = SimulatorHostFailure(error)
            #expect(failure.failureReason == reason)
            #expect(failure.recoverySuggestion == recovery)
        }
    }

    @Test func aStartupReadyResultRequiresTheRendererToRemainRunning() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = directory.appendingPathComponent("result")
        try JSONEncoder().encode(RendererStartupResult.ready).write(to: result, options: .atomic)
        try await WorkspaceClient.waitForNeoHostStartup(resultURL: result, isTerminated: { false })
        do {
            try await WorkspaceClient.waitForNeoHostStartup(resultURL: result, isTerminated: { true })
            Issue.record("A terminated renderer was accepted as ready")
        } catch let error as CLIError {
            #expect(error.identifier == "neo-host-startup")
            #expect(error.message == "NeoSimulator exited during startup")
        }
    }

    @Test func managedRendererLaunchIncludesTheManagersExactIdentity() throws {
        let owner = RendererOwnerIdentity(processIdentifier: 321, launchDate: Date(timeIntervalSinceReferenceDate: 123456.125))
        let arguments = WorkspaceClient.rendererLaunchArguments(owner: owner,
            startupResultURL: URL(fileURLWithPath: "/Startup/result"), xcodeURL: URL(fileURLWithPath: "/Xcode.app"),
            deviceIdentifier: "device-id")
        #expect(arguments == ["--managed", "--owner-pid", "321", "--owner-launch-date", "123456.125",
                              "--startup-result", "/Startup/result", "--xcode", "/Xcode.app", "--device", "device-id"])
        let headless = WorkspaceClient.rendererLaunchArguments(owner: owner,
            startupResultURL: URL(fileURLWithPath: "/Startup/result"), xcodeURL: URL(fileURLWithPath: "/Xcode.app"),
            deviceIdentifier: "device-id", headless: true)
        #expect(headless == arguments + ["--headless"])
    }

    @Test func rendererRegistrationNeverAdoptsAnotherManagerOrAReusedManagerPID() throws {
        let owner = RendererOwnerIdentity(processIdentifier: 321, launchDate: Date(timeIntervalSinceReferenceDate: 123456.125))
        let identities: [(Int32?, Date?)] = [(321, owner.launchDate), (nil, nil), (123, owner.launchDate),
                                           (321, owner.launchDate.addingTimeInterval(1))]
        let registrations = try identities.enumerated().map { index, identity in
            let registration = RendererRegistration(processIdentifier: Int32(index + 1), applicationPath: "/Renderer.app",
                xcodePath: "/Xcode.app", sessionIdentifier: "session-\(index)", deviceIdentifiers: [],
                ownerProcessIdentifier: identity.0, ownerLaunchDate: identity.1)
            return try JSONDecoder().decode(RendererRegistration.self, from: JSONEncoder().encode(registration))
        }
        #expect(registrations.filter { $0.isOwned(by: owner) }.map(\.sessionIdentifier) == ["session-0"])
    }

    @Test func aNewRendererWaitsForAnAbsentOwnersCleanupWithoutTouchingLiveOrUnknownOwners() async throws {
        let rendererURL = URL(fileURLWithPath: "/Renderer.app")
        let launchDate = Date(timeIntervalSinceReferenceDate: 123456.125)
        let applications = (1...5).map {
            RunningApplication(processIdentifier: Int32($0), bundleURL: $0 == 5 ? URL(fileURLWithPath: "/Other.app") : rendererURL,
                               bundleIdentifier: ToolConstants.neoHostBundleIdentifier)
        }
        var waiting: CheckedContinuation<Void, Never>?
        var cleanup: CheckedContinuation<Void, Never>?
        var launched = false
        var waited: [Int32] = []
        let operation = Task {
            try await WorkspaceClient.waitForPreviousRendererOwners(at: rendererURL, applications: applications,
                registration: { application in
                    #expect(application.processIdentifier != 5)
                    let pid = application.processIdentifier
                    return RendererRegistration(processIdentifier: pid, applicationPath: rendererURL.path, xcodePath: "/Xcode.app",
                        sessionIdentifier: "session-\(pid)", deviceIdentifiers: [],
                        ownerProcessIdentifier: pid == 3 ? nil : pid + 100,
                        ownerLaunchDate: pid == 3 ? nil : launchDate)
                }, ownerIsAbsent: { owner in
                    let owners = [Int32(102): launchDate, Int32(104): launchDate.addingTimeInterval(1)]
                    return owners[owner.processIdentifier] != owner.launchDate
                },
                waitForTermination: { application in
                    waited.append(application.processIdentifier)
                    if application.processIdentifier == 1 {
                        await withCheckedContinuation { cleanup = $0; waiting?.resume(); waiting = nil }
                    }
                })
            launched = true
        }
        await withCheckedContinuation { waiting = $0 }
        #expect(!launched && waited == [1])
        cleanup?.resume()
        try await operation.value
        #expect(launched && waited == [1, 4])
    }

    @Test func failedPreviousRendererCleanupDoesNotLaunchAReplacement() async throws {
        let rendererURL = URL(fileURLWithPath: "/Renderer.app")
        let application = RunningApplication(processIdentifier: 1, bundleURL: rendererURL,
            bundleIdentifier: ToolConstants.neoHostBundleIdentifier)
        let failure = CLIError.temporary("previous-renderer-termination-timeout", "fixture cleanup did not finish")
        var launched = false
        do {
            try await WorkspaceClient.waitForPreviousRendererOwners(at: rendererURL, applications: [application],
                registration: { _ in RendererRegistration(processIdentifier: 1, applicationPath: rendererURL.path,
                    xcodePath: "/Xcode.app", sessionIdentifier: "session", deviceIdentifiers: [], ownerProcessIdentifier: 101,
                    ownerLaunchDate: Date(timeIntervalSinceReferenceDate: 123456.125)) },
                ownerIsAbsent: { _ in true }, waitForTermination: { _ in throw failure })
            launched = true
            Issue.record("A replacement launched before the previous renderer finished cleanup")
        } catch { #expect((error as? CLIError)?.identifier == failure.identifier) }
        #expect(!launched)
    }

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

    @Test(arguments: [StoredBoolean.absent, .falseValue, .trueValue])
    func restoredCoreSimulatorRouteRequiresExplicitNeoSelection(suppression: StoredBoolean) async throws {
        let original = ManagedPreferenceState(xcodeSession: .trueValue, deviceHubAutoStartSuppression: suppression)
        let fixture = try ControllerFixture(initialState: original)
        _ = try await fixture.controller.use(suppression == .trueValue ? .deviceHub : .neo)
        _ = try await fixture.controller.restore()
        let restored = try fixture.controller.routeStatus()
        #expect(restored.preferences == original)
        #expect(restored.receiptStatus == .unmanaged)
        #expect(try fixture.controller.selectionStatus().host == .deviceHub)
        #expect(try !fixture.controller.selectionStatus().allowsAutomaticHosting)
        _ = try await fixture.controller.use(.neo)
        #expect(try fixture.controller.selectionStatus().host == .neo)
        #expect(try fixture.controller.selectionStatus().allowsAutomaticHosting)
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
        let reason = "Device Hub is running or launched during startup; close it before opening NeoSimulator"
        let recovery = "Close the other display app, then choose View Screen again."
        fixture.workspace.openNeoHostError = CLIError(category: .temporary, identifier: "neo-host-startup", message: reason,
            failureReason: reason, recoverySuggestion: recovery)

        do {
            _ = try await fixture.controller.use(.neo)
            Issue.record("expected standalone host launch failure")
        } catch let error as CLIError {
            #expect(error.identifier == "neo-host-launch-partial-success")
            let failure = SimulatorHostFailure(error)
            #expect(failure.kind == .partialSuccess)
            #expect(failure.failureReason == reason)
            #expect(failure.recoverySuggestion == recovery + " The preferences remain managed; use Restore Original Settings… to undo them.")
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
        fixture.runner.failPreferenceReads = true
        let status = try fixture.controller.selectionStatus()

        #expect(status.host == .deviceHub)
        #expect(!status.allowsAutomaticHosting)
        #expect(!status.restorationAvailable)
        #expect(fixture.runner.calls.isEmpty)
        #expect(fixture.runner.mutationCount == 0)
        #expect(try fixture.receiptStore.load() == nil)
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.receiptStore.directoryURL.path
            )
        )
    }

    @Test func savedNeoSelectionAndRendererLaunchDoNotAccessOtherAppsPreferences() async throws {
        let fixture = try ControllerFixture(initialState: .coreSimulator)
        _ = try await fixture.controller.use(.neo)
        #expect(try fixture.receiptStore.load() == nil)
        fixture.runner.failPreferenceReads = true
        let preferenceCalls = fixture.runner.calls.filter { $0.executable.path == "/usr/bin/defaults" }

        let selection = try fixture.controller.selectionStatus()
        #expect(selection.host == .neo && selection.allowsAutomaticHosting)
        try await fixture.controller.launch(selection.host, xcodeURL: nil)
        #expect(Array(fixture.workspace.events.suffix(1)) == ["open-neo-host"])
        #expect(fixture.runner.calls.filter { $0.executable.path == "/usr/bin/defaults" } == preferenceCalls)

        // An explicit host change still reads the actual values and preserves failures.
        await #expect(throws: CLIError.self) { try await fixture.controller.use(.deviceHub) }
        #expect(try fixture.controller.selectionStatus().host == .neo)
    }

    @Test func legacyReceiptsSelectNeoWithoutReadingLivePreferencesAndPendingWritesDoNotAutoAttach() throws {
        let fixture = try ControllerFixture()
        let xcode = try InstallationInspector(runner: fixture.runner,
            environment: ["DEVELOPER_DIR": fixture.installations.developerDirectoryURL.path],
            signatureValidator: .acceptingTestFixtures).validatedTargetXcode()
        var receipt = RestorationReceipt(capturedAt: Date(), xcode: xcode, original: .deviceHub)
        receipt.expectedCurrent = .coreSimulator
        try fixture.receiptStore.withExclusiveLock { try fixture.receiptStore.save(receipt) }
        fixture.runner.failPreferenceReads = true
        #expect(try fixture.controller.selectionStatus() == SimulatorHostSelectionStatus(host: .neo,
            restorationAvailable: true, allowsAutomaticHosting: true))
        receipt.pending = PendingMutation(before: .coreSimulator, target: .deviceHub)
        try fixture.receiptStore.save(receipt)
        #expect(try fixture.controller.selectionStatus() == SimulatorHostSelectionStatus(host: .neo,
            restorationAvailable: true, allowsAutomaticHosting: false))
        #expect(!fixture.runner.calls.contains { $0.executable.path == "/usr/bin/defaults" })
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
        let data = Data(#"""
        {
          "devicetypes": [
            {"identifier":"phone-type","productFamily":"iPhone","modelIdentifier":"iPhone19,2"},
            {"identifier":"tv-type","productFamily":"Apple TV"}
          ],
          "runtimes": [
            {"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-27-0","name":"Unavailable iOS 27.0","isAvailable":false},
            {"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-27-0","name":"iOS 27.0","isAvailable":true},
            {"identifier":"com.apple.CoreSimulator.SimRuntime.tvOS-27-0","name":"tvOS 27.0","isAvailable":true},
            {"identifier":"com.apple.CoreSimulator.SimRuntime.tvOS-27-0","name":"Another tvOS 27.0 build","isAvailable":true}
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
        """#.utf8)
        let devices = try SimulatorDeviceCatalog.decode(data)
        let clones = try SimulatorDeviceCatalog.decode(data, deviceSetPath: "/custom/XCTestDevices")
        #expect(clones.allSatisfy { $0.deviceSetPath == "/custom/XCTestDevices" })
        #expect(devices.allSatisfy { $0.deviceSetPath == nil })
        var reportedFailure = false
        let available = SimulatorDeviceCatalog.appendingTestingDevices(to: devices, readTesting: {
            throw CLIError.io("testing-catalog", "unavailable alternate device set")
        }, onFailure: { error in reportedFailure = (error as? CLIError)?.identifier == "testing-catalog" })
        #expect(available == devices)
        #expect(reportedFailure)
        #expect(Set(devices.map(\.identifier)) == ["phone", "tv"])
        #expect(devices.first(where: { $0.identifier == "phone" })?.state == "Booted")
        #expect(devices.first(where: { $0.identifier == "phone" })?.runtimeName == "iOS 27.0")
        #expect(devices.first(where: { $0.identifier == "phone" })?.modelIdentifier == "iPhone19,2")
        #expect(devices.first(where: { $0.identifier == "tv" })?.modelIdentifier == nil)
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
            }
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
