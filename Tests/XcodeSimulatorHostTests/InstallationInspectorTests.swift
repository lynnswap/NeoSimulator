import Foundation
import Testing

@testable import XcodeSimulatorHost

@Suite
struct InstallationInspectorTests {
    @Test func simulatorCommandsPreserveXcodeSelectionWithoutInvokingInstallingWrapper() throws {
        let fixture = try InstallationFixture(simctlExpectedVersion: "9999", coreSimulatorBundleVersion: "1174.9.2")
        try Data(#"""
        #!/bin/sh
        printf install > "$0.install"
        exit 99
        """#.utf8).write(to: fixture.simctlWrapperURL)
        try Data(#"""
        #!/bin/sh
        printf '%s\n' "$DEVELOPER_DIR" "$@"
        """#.utf8).write(to: fixture.simctlBinaryURL)
        let output = try SystemCommandRunner().runSimctl(
            xcodeURL: fixture.targetXcodeURL, arguments: ["list", "--json"],
            coreSimulatorFrameworkURL: fixture.coreSimulatorFrameworkURL
        )
        #expect(output.terminationStatus == 0)
        #expect(output.stdoutText == "\(fixture.developerDirectoryURL.path)\nlist\n--json")
        #expect(!FileManager.default.fileExists(atPath: fixture.simctlWrapperURL.path + ".install"))
    }

    @Test func testingCloneBootUsesTheRecordedDeviceSet() throws {
        let fixture = try InstallationFixture()
        try Data(#"""
        #!/bin/sh
        printf '%s\n' "$@"
        """#.utf8).write(to: fixture.simctlBinaryURL)
        let output = try SystemCommandRunner().runSimctl(
            xcodeURL: fixture.targetXcodeURL, arguments: ["boot", "clone"], deviceSetPath: "/custom/XCTestDevices",
            coreSimulatorFrameworkURL: fixture.coreSimulatorFrameworkURL
        )
        #expect(output.terminationStatus == 0)
        #expect(output.stdoutText == "--set\n/custom/XCTestDevices\nboot\nclone")
    }

    @Test func validatesSelectedXcode27AndNeoHostComponents() throws {
        let fixture = try InstallationFixture()
        let inspector = makeInspector(fixture)

        let xcode = try inspector.validatedTargetXcode()
        let host = try inspector.validatedNeoHost(for: xcode)

        #expect(xcode.applicationURL == fixture.targetXcodeURL)
        #expect(xcode.version == (try ToolVersion("27.0")))
        #expect(xcode.buildVersion == "27A5252f")
        #expect(host.applicationURL == fixture.neoHostURL)
        #expect(host.xcode == xcode)
        #expect(host.simulatorKitBinaryURL.lastPathComponent == "SimulatorKit")
        #expect(
            host.idePlaygroundSimulatorBinaryURL.lastPathComponent
                == "IDEPlaygroundSimulator"
        )
        #expect(host.coreSimulatorBinaryURL.lastPathComponent == "CoreSimulator")
        #expect(host.coreSimulatorVersion == "1171.6")
        #expect(host.simctlWrapperURL == fixture.simctlWrapperURL)
        #expect(host.simctlBinaryURL == fixture.simctlBinaryURL)
        #expect(host.coreDeviceBinaryURL.lastPathComponent == "CoreDevice")
        #expect(host.coreDeviceVersion == "642.15")
        #expect(host.devicectlWrapperURL == fixture.devicectlWrapperURL)
        #expect(host.devicectlBinaryURL == fixture.devicectlBinaryURL)
        #expect(
            host.simulatorCoreDevicePluginBinaryURL
                == fixture.simulatorCoreDevicePluginBinaryURL
        )
    }

    @Test func rejectsXcode26() throws {
        let fixture = try InstallationFixture(
            targetVersion: "26.4",
            targetBuild: "17E214"
        )

        do {
            _ = try makeInspector(fixture).validatedTargetXcode()
            Issue.record("expected Xcode 26 to be rejected")
        } catch let error as CLIError {
            #expect(error.identifier == "unsupported-xcode")
            #expect(error.category == .unavailable)
        }
    }

    @Test func acceptsXcode28WhenTheVerifiedSurfaceMatches() throws {
        let fixture = try InstallationFixture(
            targetVersion: "28.0",
            targetBuild: "28A100",
            simctlExpectedVersion: "1280.1",
            devicectlExpectedVersion: "700.2"
        )
        let inspector = makeInspector(fixture)

        let xcode = try inspector.validatedTargetXcode()
        let host = try inspector.validatedNeoHost(for: xcode)

        #expect(xcode.version == (try ToolVersion("28.0")))
        #expect(host.xcode == xcode)
        #expect(host.coreSimulatorVersion == "1280.1")
        #expect(host.coreDeviceVersion == "700.2")
    }

    @Test func selectedXcodeMustBeIntactAppleSignedCode() throws {
        let fixture = try InstallationFixture()
        let inspector = InstallationInspector(
            runner: FakeSystemCommandRunner(),
            environment: ["DEVELOPER_DIR": fixture.developerDirectoryURL.path],
            rendererApplicationURL: fixture.neoHostURL,
            coreSimulatorFrameworkURL: fixture.coreSimulatorFrameworkURL,
            coreDeviceFrameworkURL: fixture.coreDeviceFrameworkURL,
            signatureValidator: CodeSignatureValidator { _, identifier in
                if identifier == ToolConstants.xcodeBundleIdentifier {
                    throw CLIError.unavailable(
                        "code-signature",
                        "injected invalid Xcode signature"
                    )
                }
            }
        )

        #expect(throws: CLIError.self) {
            _ = try inspector.validatedTargetXcode()
        }
    }

    @Test func loadedPrivateFrameworksMustBeIntactAppleSignedCode() throws {
        let fixture = try InstallationFixture()
        let inspector = InstallationInspector(
            runner: FakeSystemCommandRunner(),
            environment: ["DEVELOPER_DIR": fixture.developerDirectoryURL.path],
            rendererApplicationURL: fixture.neoHostURL,
            coreSimulatorFrameworkURL: fixture.coreSimulatorFrameworkURL,
            coreDeviceFrameworkURL: fixture.coreDeviceFrameworkURL,
            signatureValidator: CodeSignatureValidator { _, identifier in
                if identifier == ToolConstants.simulatorKitBundleIdentifier {
                    throw CLIError.unavailable(
                        "code-signature",
                        "injected invalid SimulatorKit signature"
                    )
                }
            }
        )
        let xcode = try inspector.validatedTargetXcode()

        do {
            _ = try inspector.validatedNeoHost(for: xcode)
            Issue.record("expected invalid SimulatorKit signature to fail")
        } catch let error as CLIError {
            #expect(error.identifier == "code-signature")
        }
    }

    @Test func rejectsXcodeWhenThePreferenceSurfaceDisappears() throws {
        let fixture = try InstallationFixture(includeHiddenKey: false)

        do {
            _ = try makeInspector(fixture).validatedTargetXcode()
            Issue.record("expected missing key to fail")
        } catch let error as CLIError {
            #expect(error.identifier == "xcode-preference-key")
        }
    }

    @Test func rejectsXcodeWhenDeviceHubIsNotLaunchable() throws {
        let fixture = try InstallationFixture()
        let executableURL = fixture.targetXcodeURL
            .appendingPathComponent(ToolConstants.deviceHubPath, isDirectory: true)
            .appendingPathComponent("Contents/MacOS/DevicesTrampoline")
        try FileManager.default.removeItem(at: executableURL)

        do {
            _ = try makeInspector(fixture).validatedTargetXcode()
            Issue.record("expected missing Device Hub executable to fail")
        } catch let error as CLIError {
            #expect(error.identifier == "device-hub-executable")
        }
    }

    @Test func rejectsXcodeWhenTheDeviceHubPreferenceSurfaceDisappears() throws {
        let fixture = try InstallationFixture(includeDeviceHubKey: false)

        do {
            _ = try makeInspector(fixture).validatedTargetXcode()
            Issue.record("expected missing Device Hub key to fail")
        } catch let error as CLIError {
            #expect(error.identifier == "device-hub-preference-key")
        }
    }

    @Test func neoHostRuntimeValidationFailureIsRejected() throws {
        let fixture = try InstallationFixture()
        let runner = FakeSystemCommandRunner()
        runner.neoHostRuntimeValidationStatus = 69
        runner.neoHostRuntimeValidationError =
            "required private symbol is unavailable"
        let inspector = InstallationInspector(
            runner: runner,
            environment: ["DEVELOPER_DIR": fixture.developerDirectoryURL.path],
            rendererApplicationURL: fixture.neoHostURL,
            coreSimulatorFrameworkURL: fixture.coreSimulatorFrameworkURL,
            coreDeviceFrameworkURL: fixture.coreDeviceFrameworkURL,
            signatureValidator: .acceptingTestFixtures
        )
        let xcode = try inspector.validatedTargetXcode()

        do {
            _ = try inspector.validatedNeoHost(for: xcode)
            Issue.record("expected private runtime validation to fail")
        } catch let error as CLIError {
            #expect(error.identifier == "neo-host-runtime")
            #expect(error.category == .unavailable)
            #expect(error.message.contains("required private symbol is unavailable"))
        }
    }

    @Test func actualRuntimeProbeDecidesCompatibilityAcrossInstalledFrameworkVersions() throws {
        let fixture = try InstallationFixture(coreSimulatorXcodeMajorVersion: 28, coreDeviceXcodeMajorVersion: 28, simulatorCoreDevicePluginXcodeMajorVersion: 28, coreSimulatorBundleVersion: "1171.5", coreDeviceBundleVersion: "642.14", simulatorCoreDevicePluginBundleVersion: "1171.8")
        let inspector = makeInspector(fixture)
        let xcode = try inspector.validatedTargetXcode()
        #expect(try inspector.validatedNeoHost(for: xcode).xcode == xcode)
    }

    @Test func missingWrapperIsRejected() throws {
        let fixture = try InstallationFixture()
        try FileManager.default.removeItem(at: fixture.simctlWrapperURL)
        let inspector = makeInspector(fixture)
        let xcode = try inspector.validatedTargetXcode()

        do {
            _ = try inspector.validatedNeoHost(for: xcode)
            Issue.record("expected missing simctl wrapper to fail")
        } catch let error as CLIError {
            #expect(error.identifier == "simctl-wrapper")
        }
    }

    @Test func changedWrapperAssignmentFormatIsRejected() throws {
        let fixture = try InstallationFixture()
        try overwrite(
            "#!/bin/zsh\nEXPECTED_VERSION = \"642.15\"\n",
            at: fixture.devicectlWrapperURL
        )
        let inspector = makeInspector(fixture)
        let xcode = try inspector.validatedTargetXcode()

        do {
            _ = try inspector.validatedNeoHost(for: xcode)
            Issue.record("expected changed devicectl wrapper format to fail")
        } catch let error as CLIError {
            #expect(error.identifier == "devicectl-wrapper-version")
        }
    }

    @Test func nonnumericWrapperVersionIsRejected() throws {
        let fixture = try InstallationFixture()
        try overwrite(
            "#!/bin/zsh\nEXPECTED_VERSION=\"642.beta\"\n",
            at: fixture.devicectlWrapperURL
        )
        let inspector = makeInspector(fixture)
        let xcode = try inspector.validatedTargetXcode()

        do {
            _ = try inspector.validatedNeoHost(for: xcode)
            Issue.record("expected nonnumeric devicectl version to fail")
        } catch let error as CLIError {
            #expect(error.identifier == "devicectl-wrapper-version")
        }
    }

    @Test func ambiguousWrapperVersionAssignmentsAreRejected() throws {
        let fixture = try InstallationFixture()
        try overwrite(
            """
            #!/bin/bash
            EXPECTED_VERSION="1171.6"
            export EXPECTED_VERSION="1171.7"
            """,
            at: fixture.simctlWrapperURL
        )
        let inspector = makeInspector(fixture)
        let xcode = try inspector.validatedTargetXcode()

        do {
            _ = try inspector.validatedNeoHost(for: xcode)
            Issue.record("expected ambiguous simctl wrapper version to fail")
        } catch let error as CLIError {
            #expect(error.identifier == "simctl-wrapper-version")
        }
    }

    @Test func directSimctlMustBeIntactAppleSignedCode() throws {
        let fixture = try InstallationFixture()
        let inspector = makeInspector(
            fixture,
            rejectingSignatureIdentifier: ToolConstants.simctlBundleIdentifier
        )
        let xcode = try inspector.validatedTargetXcode()

        do {
            _ = try inspector.validatedNeoHost(for: xcode)
            Issue.record("expected invalid simctl signature to fail")
        } catch let error as CLIError {
            #expect(error.identifier == "code-signature")
        }
    }

    @Test func directDevicectlMustBeIntactAppleSignedCode() throws {
        let fixture = try InstallationFixture()
        let inspector = makeInspector(
            fixture,
            rejectingSignatureIdentifier: ToolConstants.devicectlBundleIdentifier
        )
        let xcode = try inspector.validatedTargetXcode()

        do {
            _ = try inspector.validatedNeoHost(for: xcode)
            Issue.record("expected invalid devicectl signature to fail")
        } catch let error as CLIError {
            #expect(error.identifier == "code-signature")
        }
    }

    @Test func simulatorCoreDevicePluginMustBeIntactAppleSignedCode() throws {
        let fixture = try InstallationFixture()
        let inspector = makeInspector(
            fixture,
            rejectingSignatureIdentifier:
                ToolConstants.simulatorCoreDevicePluginBundleIdentifier
        )
        let xcode = try inspector.validatedTargetXcode()

        do {
            _ = try inspector.validatedNeoHost(for: xcode)
            Issue.record("expected invalid simulator plugin signature to fail")
        } catch let error as CLIError {
            #expect(error.identifier == "code-signature")
        }
    }

    @Test func devicectlMustNotLinkDeviceKitOrDeviceHub() throws {
        for fragment in [
            "@rpath/DeviceKit.framework/Versions/A/DeviceKit",
            "/Applications/Xcode.app/Contents/Applications/DeviceHub.app/Contents/MacOS/DeviceHub",
        ] {
            let fixture = try InstallationFixture()
            try overwrite(fragment, at: fixture.devicectlBinaryURL)
            let inspector = makeInspector(fixture)
            let xcode = try inspector.validatedTargetXcode()

            do {
                _ = try inspector.validatedNeoHost(for: xcode)
                Issue.record("expected forbidden devicectl linkage to fail")
            } catch let error as CLIError {
                #expect(error.identifier == "devicectl-linkage")
            }
        }
    }

    @Test func simulatorCoreDevicePluginMustNotLinkDeviceKitOrDeviceHub() throws {
        for fragment in [
            "@rpath/DeviceKit.framework/Versions/A/DeviceKit",
            "/Applications/Xcode.app/Contents/Applications/DeviceHub.app/Contents/MacOS/DeviceHub",
        ] {
            let fixture = try InstallationFixture()
            try overwrite(
                fragment,
                at: fixture.simulatorCoreDevicePluginBinaryURL
            )
            let inspector = makeInspector(fixture)
            let xcode = try inspector.validatedTargetXcode()

            do {
                _ = try inspector.validatedNeoHost(for: xcode)
                Issue.record("expected forbidden simulator plugin linkage to fail")
            } catch let error as CLIError {
                #expect(
                    error.identifier == "simulator-core-device-plugin-linkage"
                )
            }
        }
    }

    @Test func compatibilityGateExecutesOnlyThePackagedRuntimeValidator() throws {
        let fixture = try InstallationFixture()
        let runner = FakeSystemCommandRunner()
        let inspector = InstallationInspector(
            runner: runner,
            environment: ["DEVELOPER_DIR": fixture.developerDirectoryURL.path],
            rendererApplicationURL: fixture.neoHostURL,
            coreSimulatorFrameworkURL: fixture.coreSimulatorFrameworkURL,
            coreDeviceFrameworkURL: fixture.coreDeviceFrameworkURL,
            signatureValidator: .acceptingTestFixtures
        )

        let xcode = try inspector.validatedTargetXcode()
        _ = try inspector.validatedNeoHost(for: xcode)

        #expect(
            runner.calls
                == [
                    FakeSystemCommandRunner.Call(
                        executable: fixture.neoHostExecutableURL,
                        arguments: [
                            "--validate-runtime",
                            "--xcode",
                            fixture.targetXcodeURL.path,
                        ]
                    ),
                ]
        )
    }

    @Test func missingPackagedHostFailsBeforeNeoModeCanBeUsed() throws {
        let fixture = try InstallationFixture(includeNeoHost: false)
        let inspector = makeInspector(fixture)
        let xcode = try inspector.validatedTargetXcode()

        do {
            _ = try inspector.validatedNeoHost(for: xcode)
            Issue.record("expected missing packaged host to fail")
        } catch let error as CLIError {
            #expect(error.identifier == "neo-host-bundle")
            #expect(error.category == .unavailable)
        }
    }

    @Test func versionComparisonPadsMissingComponents() throws {
        #expect(try ToolVersion("26.6") == ToolVersion("26.6.0"))
        #expect(try ToolVersion("26.6.1") > ToolVersion("26.6"))
        #expect(try ToolVersion("27.0") > ToolVersion("26.99"))
    }

    private func makeInspector(
        _ fixture: InstallationFixture,
        rejectingSignatureIdentifier: String? = nil
    ) -> InstallationInspector {
        InstallationInspector(
            runner: FakeSystemCommandRunner(),
            environment: ["DEVELOPER_DIR": fixture.developerDirectoryURL.path],
            rendererApplicationURL: fixture.neoHostURL,
            coreSimulatorFrameworkURL: fixture.coreSimulatorFrameworkURL,
            coreDeviceFrameworkURL: fixture.coreDeviceFrameworkURL,
            signatureValidator: CodeSignatureValidator { _, identifier in
                guard identifier == rejectingSignatureIdentifier else {
                    return
                }
                throw CLIError.unavailable(
                    "code-signature",
                    "injected invalid signature for \(identifier)"
                )
            }
        )
    }

    private func overwrite(_ content: String, at url: URL) throws {
        try Data(content.utf8).write(to: url)
    }
}

@Suite
struct XcodeConnectionsTests {
    private func connection(pid: Int32, start: UInt64, device: String = "A", xcode: String = "Xcode27.1") -> XcodeSimulatorConnection {
        .init(event: .init(processIdentifier: pid, startSeconds: start, startMicroseconds: 0), deviceIdentifier: device, xcodeURL: URL(fileURLWithPath: "/Applications/\(xcode).app"))
    }

    @Test func sameUDIDConnectionsAndBootsRemainIndependentAcrossDeviceSets() async throws {
        let path = "/custom/XCTestDevices"
        let normal = connection(pid: 1, start: 10)
        let clone = XcodeSimulatorConnection(event: .init(processIdentifier: 2, startSeconds: 20, startMicroseconds: 0),
            deviceIdentifier: normal.deviceIdentifier, xcodeURL: URL(fileURLWithPath: "/Applications/OtherXcode.app"), deviceSetPath: path)
        let tracker = XcodeConnectionTracker()
        var routed: [XcodeSimulatorConnection] = []
        _ = try await tracker.synchronize(observations: [normal, clone], runningDeviceIdentifiers: [normal.deviceID, clone.deviceID], testingDeviceSetPath: path) { routed.append($0) }
        #expect(routed == [normal, clone])
        #expect(tracker.xcodeURL(forDevice: normal.deviceID) == normal.xcodeURL)
        #expect(tracker.xcodeURL(forDevice: clone.deviceID) == clone.xcodeURL)
        let normalDevice = SimulatorHostDevice(identifier: "A", name: "Normal", descriptiveName: "Normal", runtimeIdentifier: "runtime", runtimeName: "iOS", productFamily: "iPhone", state: "Booted")
        let cloneDevice = SimulatorHostDevice(identifier: "A", name: "Clone", descriptiveName: "Clone", runtimeIdentifier: "runtime", runtimeName: "iOS", productFamily: "iPhone", state: "Booted", deviceSetPath: path)
        let boots = SimulatorBootTracker()
        let initial = boots.observe([normalDevice, cloneDevice], attachInitially: true)
        #expect(Set(initial.devicesToAttach) == [normal.deviceID, clone.deviceID])
        boots.didAttach(normal.deviceID)
        #expect(boots.observe([normalDevice, cloneDevice], attachInitially: true).devicesToAttach == [clone.deviceID])
        boots.didAttach(clone.deviceID)
        boots.forgetTestingDevices()
        #expect(boots.observe([normalDevice, cloneDevice], attachInitially: true).devicesToAttach == [clone.deviceID])
        let registrations = [normal, clone].enumerated().map { index, connection in
            RendererRegistration(processIdentifier: Int32(index + 1), applicationPath: "/Renderer.app", xcodePath: connection.xcodeURL.path,
                                 sessionIdentifier: "session\(index)", deviceIdentifiers: [connection.deviceID])
        }
        #expect(normalDevice.inventoryCopy(owners: registrations).ownerXcodeURL == normal.xcodeURL)
        #expect(cloneDevice.inventoryCopy(owners: registrations).ownerXcodeURL == clone.xcodeURL)
        #expect(try JSONDecoder().decode([RendererRegistration].self, from: JSONEncoder().encode(registrations)).flatMap(\.deviceIdentifiers) == [normal.deviceID, clone.deviceID])
    }

    @Test func customSetSettingsNeverAddressADefaultSetDeviceThroughDevicectl() throws {
        var commands: [[String]] = []
        let backend = SimulatorSettingsBackend(run: { tool, arguments in
            if case .devicectl = tool { throw CLIError.io("wrong-device", "devicectl cannot distinguish this device set") }
            commands.append(arguments)
            let output = switch arguments.last {
            case "appearance": "light"
            case "content_size": "medium"
            case "increase_contrast": "disabled"
            default: ""
            }
            return Data(output.utf8)
        }, audioDevices: { Issue.record("Unsupported custom-set audio must not be queried"); return ([], []) })
        let device = InventoryDevice.simulator(SimulatorHostDevice(identifier: "same-udid", name: "Clone", descriptiveName: "Clone",
            runtimeIdentifier: "runtime", runtimeName: "iOS", productFamily: "iPhone", state: "Booted", deviceSetPath: "/custom/XCTestDevices"))
        let settings = backend.read(device: device)
        #expect(settings.appearance == "light" && settings.contentSize == "medium" && settings.increaseContrast == false)
        #expect(settings.reduceMotion == nil && settings.audioOutputDevice == nil && settings.issues.isEmpty)
        try backend.set(.appearance("dark"), device: device)
        try backend.set(.location(latitude: 1, longitude: 2), device: device)
        let count = commands.count
        #expect(throws: CLIError.self) { try backend.set(.reduceMotion(true), device: device) }
        #expect(commands.count == count)
    }

    @Test @MainActor func rendererRequestsDoNotAcceptAnAcknowledgementFromTheOtherDeviceSet() async throws {
        let center = NotificationCenter()
        let path = "/custom/XCTestDevices"
        let target = DeviceInventoryID.simulator(udid: "same-udid", deviceSetPath: path)
        let renderer = RendererRegistration(processIdentifier: 1, applicationPath: "/Renderer.app", xcodePath: "/Xcode.app",
                                            sessionIdentifier: "owner-session", deviceIdentifiers: [target])
        var requests: [[String: String]] = []
        let waiter = RendererDeviceRequestWaiter(acknowledgements: center, scheduleTimeout: { _, _ in {} }) { info, session in
            requests.append(info)
            #expect(session == renderer.sessionIdentifier)
            #expect(info["udid"] == "same-udid" && info["deviceSetPath"] == path)
            let acknowledgement = switch info["action"] {
            case "release-device": "RendererReleased"
            case "restart-device": "RendererManaged"
            case "close-device": "RendererClosed"
            default: "RendererOpened"
            }
            let name = Notification.Name("dev.lynnswap.NeoSimulator.\(acknowledgement)")
            center.post(name: name, object: info["requestIdentifier"],
                        userInfo: ["udid": "same-udid", "error": "Wrong set acknowledged the request"])
            center.post(name: name, object: info["requestIdentifier"],
                        userInfo: ["udid": "same-udid", "deviceSetPath": path])
        }
        try await waiter.open(target, in: renderer)
        try await waiter.attach(target, in: renderer)
        try await waiter.release(target, from: renderer)
        #expect(try await waiter.restart(target, in: renderer, erasing: false))
        try await waiter.close(target, in: renderer, keepingDeviceRunning: true)
        try await waiter.close(target, in: renderer, keepingDeviceRunning: false)
        #expect(requests.compactMap { $0["action"] } == ["open-device", "attach-device", "release-device", "restart-device", "close-device", "close-device"])
        #expect(requests.suffix(2).compactMap { $0["keepRunning"] } == ["true", "false"])
    }

    @Test @MainActor func closeDeviceAcknowledgementPreservesFailureAndAllowsRetry() async throws {
        let center = NotificationCenter()
        let target = DeviceInventoryID.simulator(udid: "device-id", deviceSetPath: nil)
        let renderer = RendererRegistration(processIdentifier: 1, applicationPath: "/Renderer.app", xcodePath: "/Xcode.app",
                                            sessionIdentifier: "owner-session", deviceIdentifiers: [target])
        var rejected = true
        var requests = 0
        let waiter = RendererDeviceRequestWaiter(acknowledgements: center, scheduleTimeout: { _, _ in {} }) { info, session in
            requests += 1
            #expect(session == renderer.sessionIdentifier && info["action"] == "close-device")
            #expect(info["udid"] == "device-id" && info["deviceSetPath"] == nil && info["keepRunning"] == "false")
            var reply = ["udid": "device-id"]
            if rejected { reply["error"] = "Fixture guest shutdown failed" }
            center.post(name: Notification.Name("dev.lynnswap.NeoSimulator.RendererClosed"),
                        object: info["requestIdentifier"], userInfo: reply)
        }
        do {
            try await waiter.close(target, in: renderer, keepingDeviceRunning: false)
            Issue.record("A failed close acknowledgement was accepted")
        } catch let error as CLIError {
            #expect(error.identifier == "renderer-device-request")
            #expect(error.message == "Fixture guest shutdown failed")
        }
        rejected = false
        try await waiter.close(target, in: renderer, keepingDeviceRunning: false)
        #expect(requests == 2)
    }

    @Test func usesNewestRunPerDeviceAndRecognizesReusedPID() async throws {
        let tracker = XcodeConnectionTracker()
        let older = connection(pid: 1, start: 10)
        let newer = connection(pid: 2, start: 20, xcode: "Xcode27.2")
        let otherDevice = connection(pid: 3, start: 15, device: "B")
        var transfers: [XcodeSimulatorConnection] = []
        #expect(try await tracker.synchronize(observations: [newer, older, otherDevice], runningDeviceIdentifiers: [.simulator(udid: "A", deviceSetPath: nil), .simulator(udid: "B", deviceSetPath: nil)]) { transfers.append($0) })
        #expect(transfers == [otherDevice, newer])
        #expect(try await !tracker.synchronize(observations: [older], runningDeviceIdentifiers: [.simulator(udid: "A", deviceSetPath: nil), .simulator(udid: "B", deviceSetPath: nil)]) { transfers.append($0) })
        let reused = connection(pid: 2, start: 30)
        #expect(try await tracker.synchronize(observations: [reused], runningDeviceIdentifiers: [.simulator(udid: "A", deviceSetPath: nil), .simulator(udid: "B", deviceSetPath: nil)]) { transfers.append($0) })
        #expect(transfers == [otherDevice, newer, reused])
    }

    @Test func failedTransferRetriesAndNewerRunSupersedesPendingSource() async throws {
        let tracker = XcodeConnectionTracker()
        let original = connection(pid: 1, start: 10)
        let otherDevice = connection(pid: 4, start: 15, device: "B")
        var transfers: [XcodeSimulatorConnection] = []
        await #expect(throws: CLIError.self) {
            _ = try await tracker.synchronize(observations: [original, otherDevice], runningDeviceIdentifiers: [.simulator(udid: "A", deviceSetPath: nil), .simulator(udid: "B", deviceSetPath: nil)]) {
                if $0.deviceIdentifier == "A" { throw CLIError.io("test", "release failed") }
                transfers.append($0)
            }
        }
        #expect(try await tracker.synchronize(observations: [], runningDeviceIdentifiers: [.simulator(udid: "A", deviceSetPath: nil), .simulator(udid: "B", deviceSetPath: nil)]) { transfers.append($0) })
        #expect(transfers == [otherDevice, original])
        let pending = connection(pid: 2, start: 20)
        await #expect(throws: CLIError.self) {
            _ = try await tracker.synchronize(observations: [pending], runningDeviceIdentifiers: [.simulator(udid: "A", deviceSetPath: nil), .simulator(udid: "B", deviceSetPath: nil)]) { _ in throw CLIError.io("test", "launch failed after release") }
        }
        let latest = connection(pid: 3, start: 30, xcode: "Xcode27.2")
        #expect(try await tracker.synchronize(observations: [latest], runningDeviceIdentifiers: [.simulator(udid: "A", deviceSetPath: nil), .simulator(udid: "B", deviceSetPath: nil)]) { transfers.append($0) })
        #expect(transfers == [otherDevice, original, latest])
    }

    @Test func shutdownCancelsFailedTransferWithoutReplayingItAfterReboot() async throws {
        let tracker = XcodeConnectionTracker()
        let pending = connection(pid: 1, start: 10)
        await #expect(throws: CLIError.self) {
            _ = try await tracker.synchronize(observations: [pending], runningDeviceIdentifiers: [.simulator(udid: "A", deviceSetPath: nil)]) { _ in
                throw CLIError.io("test", "launch failed after release")
            }
        }
        #expect(tracker.hasPendingConnection(forDevice: .simulator(udid: "A", deviceSetPath: nil)))
        var transfers: [XcodeSimulatorConnection] = []
        #expect(try await !tracker.synchronize(observations: [], runningDeviceIdentifiers: []) { transfers.append($0) })
        #expect(!tracker.hasPendingConnection(forDevice: .simulator(udid: "A", deviceSetPath: nil)))
        #expect(tracker.xcodeURL(forDevice: .simulator(udid: "A", deviceSetPath: nil)) == pending.xcodeURL)
        #expect(try await !tracker.synchronize(observations: [pending], runningDeviceIdentifiers: [.simulator(udid: "A", deviceSetPath: nil)]) { transfers.append($0) })
        let nextRun = connection(pid: 2, start: 20)
        #expect(try await tracker.synchronize(observations: [nextRun], runningDeviceIdentifiers: [.simulator(udid: "A", deviceSetPath: nil)]) { transfers.append($0) })
        #expect(transfers == [nextRun])
    }

    @Test func bootTransitionsRestoreOnceAndDoNotReopenClosedBootedWindows() {
        let tracker = SimulatorBootTracker()
        func device(_ identifier: String, _ state: String) -> SimulatorHostDevice {
            .init(identifier: identifier, name: identifier, descriptiveName: identifier, runtimeIdentifier: "runtime", runtimeName: "iOS", productFamily: "iPhone", state: state)
        }
        #expect(tracker.observe([device("A", "Booted"), device("B", "Shutdown")], attachInitially: false).devicesToAttach.isEmpty)
        #expect(tracker.observe([device("A", "Booted"), device("B", "Booted")], attachInitially: false).devicesToAttach == [.simulator(udid: "B", deviceSetPath: nil)])
        #expect(tracker.observe([device("A", "Booted"), device("B", "Booted")], attachInitially: false).devicesToAttach == [.simulator(udid: "B", deviceSetPath: nil)])
        tracker.didAttach(.simulator(udid: "B", deviceSetPath: nil))
        // Losing registry ownership while still Booted means a window was closed, not a new boot.
        #expect(tracker.observe([device("A", "Booted"), device("B", "Booted")], attachInitially: true).devicesToAttach.isEmpty)
        _ = tracker.observe([device("A", "Shutdown"), device("B", "Booted")], attachInitially: true)
        #expect(tracker.observe([device("A", "Booted"), device("B", "Booted")], attachInitially: true).devicesToAttach == [.simulator(udid: "A", deviceSetPath: nil)])
        tracker.reset()
        #expect(tracker.observe([device("A", "Booted"), device("B", "Booted")], attachInitially: true).devicesToAttach == [.simulator(udid: "A", deviceSetPath: nil), .simulator(udid: "B", deviceSetPath: nil)])
    }

    @Test func testingVisibilityChangesReattachClonesAndPreserveNormalWindowChoices() {
        let tracker = SimulatorBootTracker()
        func device(_ identifier: String, _ state: String = "Booted", testing: Bool = false) -> SimulatorHostDevice {
            .init(identifier: identifier, name: identifier, descriptiveName: identifier, runtimeIdentifier: "runtime", runtimeName: "iOS", productFamily: "iPhone", state: state, deviceSetPath: testing ? "/custom/XCTestDevices" : nil)
        }
        let closedNormal = device("closed")
        let clone = device("testing", testing: true)
        #expect(tracker.observe([closedNormal, device("pending", "Shutdown"), clone], attachInitially: false).devicesToAttach.isEmpty)
        let current = [closedNormal, device("pending"), clone]
        #expect(tracker.observe(current, attachInitially: false).devicesToAttach == [.simulator(udid: "pending", deviceSetPath: nil)])
        // OFF and ON can both occur before another catalog snapshot is read.
        tracker.forgetTestingDevices()
        #expect(tracker.observe(current, attachInitially: false).devicesToAttach == [.simulator(udid: "pending", deviceSetPath: nil), .simulator(udid: "testing", deviceSetPath: clone.deviceSetPath)])
        tracker.didAttach(.simulator(udid: "pending", deviceSetPath: nil))
        tracker.didAttach(.simulator(udid: "testing", deviceSetPath: clone.deviceSetPath))
        #expect(tracker.observe(current, attachInitially: false).devicesToAttach.isEmpty)
    }

    @Test func catalogChangesRefreshUnownedDevicesWithoutAttachingThem() {
        let tracker = SimulatorBootTracker()
        func device(_ identifier: String, _ state: String, name: String = "iPhone") -> SimulatorHostDevice {
            .init(identifier: identifier, name: name, descriptiveName: name, runtimeIdentifier: "runtime", runtimeName: "iOS", productFamily: "iPhone", state: state)
        }
        let original = device("A", "Booted")
        #expect(tracker.observe([original, original], attachInitially: false).catalogChanged)
        let unchanged = tracker.observe([original], attachInitially: false)
        #expect(!unchanged.catalogChanged)
        #expect(unchanged.devicesToAttach.isEmpty)
        let shutdown = tracker.observe([device("A", "Shutdown")], attachInitially: false)
        #expect(shutdown.catalogChanged)
        #expect(shutdown.devicesToAttach.isEmpty)
        let renamed = tracker.observe([device("A", "Shutdown", name: "Renamed")], attachInitially: false)
        #expect(renamed.catalogChanged)
        #expect(renamed.devicesToAttach.isEmpty)
        let created = tracker.observe([device("A", "Shutdown", name: "Renamed"), device("B", "Shutdown")], attachInitially: false)
        #expect(created.catalogChanged)
        #expect(created.devicesToAttach.isEmpty)
        #expect(tracker.observe([], attachInitially: false).catalogChanged)
        let deviceHub = tracker.observe([original], attachInitially: false, allowsAttachments: false)
        #expect(deviceHub.catalogChanged)
        #expect(deviceHub.devicesToAttach.isEmpty)
        #expect(!tracker.observe([original], attachInitially: false, allowsAttachments: false).catalogChanged)
    }

    @Test func startupLastDeviceRespectsSavedSelectionAndDisabledPreferences() {
        let device = SimulatorHostDevice(identifier: "CFB0DFE8-2184-4B1C-A6EF-9B4AEEDCB823", name: "iPhone", descriptiveName: "iPhone", runtimeIdentifier: "runtime", runtimeName: "iOS", productFamily: "iPhone", state: "Shutdown")
        #expect(SimulatorStartupSelection.device(in: [device], attachInitially: true, startsSession: true, startsLastDevice: true, current: .simulator(udid: device.identifier.lowercased(), deviceSetPath: nil), hasOwnedDevices: false) == device)
        #expect(SimulatorStartupSelection.device(in: [device], attachInitially: true, startsSession: false, startsLastDevice: true, current: device.inventoryID, hasOwnedDevices: false) == nil)
        #expect(SimulatorStartupSelection.device(in: [device], attachInitially: true, startsSession: true, startsLastDevice: false, current: device.inventoryID, hasOwnedDevices: false) == nil)
        #expect(SimulatorStartupSelection.device(in: [device], attachInitially: true, startsSession: true, startsLastDevice: true, current: device.inventoryID, hasOwnedDevices: true) == nil)
        let path = "/fixture/TestingDevices"
        let clone = SimulatorHostDevice(identifier: device.identifier, name: "Testing iPad", descriptiveName: "Testing iPad", runtimeIdentifier: "runtime", runtimeName: "iOS", productFamily: "iPad", state: "Shutdown", deviceSetPath: path)
        let fallback = SimulatorHostDevice(identifier: "fallback", name: "Fallback iPhone", descriptiveName: "Fallback iPhone", runtimeIdentifier: "runtime", runtimeName: "iOS", productFamily: "iPhone", state: "Shutdown")
        let saved = DeviceInventoryID.simulator(udid: device.identifier.lowercased(), deviceSetPath: path)
        #expect(SimulatorStartupSelection.device(in: [device, fallback, clone], attachInitially: true, startsSession: true, startsLastDevice: true, current: saved, hasOwnedDevices: false) == clone)
        #expect(SimulatorStartupSelection.device(in: [device, fallback], attachInitially: true, startsSession: true, startsLastDevice: true, current: saved, hasOwnedDevices: false) == fallback)
        let booted = SimulatorHostDevice(identifier: "other", name: "iPad", descriptiveName: "iPad", runtimeIdentifier: "runtime", runtimeName: "iOS", productFamily: "iPad", state: "Booted")
        #expect(SimulatorStartupSelection.device(in: [device, booted], attachInitially: true, startsSession: true, startsLastDevice: true, current: device.inventoryID, hasOwnedDevices: false) == nil)
    }

    @Test func disablingTestingDevicesDiscardsPendingCloneConnections() async throws {
        let tracker = XcodeConnectionTracker()
        let clone = XcodeSimulatorConnection(event: .init(processIdentifier: 1, startSeconds: 10, startMicroseconds: 0),
            deviceIdentifier: "clone", xcodeURL: URL(fileURLWithPath: "/Applications/Xcode.app"), deviceSetPath: "/custom/XCTestDevices")
        await #expect(throws: CLIError.self) {
            _ = try await tracker.synchronize(observations: [clone], runningDeviceIdentifiers: [.simulator(udid: "clone", deviceSetPath: clone.deviceSetPath)], testingDeviceSetPath: clone.deviceSetPath) { _ in throw CLIError.io("test", "retry") }
        }
        #expect(try await !tracker.synchronize(observations: [], runningDeviceIdentifiers: [.simulator(udid: "clone", deviceSetPath: clone.deviceSetPath)]) { _ in Issue.record("A hidden testing device must not be attached.") })
        #expect(!tracker.hasPendingConnection(forDevice: clone.deviceID))
    }

    @Test func launchEnvironmentRequiresMatchingDeviceAndUnambiguousXcodeFootprint() {
        let identifier = "CFB0DFE8-2184-4B1C-A6EF-9B4AEEDCB823"
        let executable = "/Users/test/Library/Developer/CoreSimulator/Devices/\(identifier)/data/Containers/Bundle/Application/ID/App.app/App"
        let event = XcodeSimulatorConnection.Event(processIdentifier: 42, startSeconds: 10, startMicroseconds: 20)
        func arguments(_ environment: [String]) -> Data {
            var result = withUnsafeBytes(of: Int32(2)) { Data($0) }
            result.append(Data((executable + "\0\0" + executable + "\0argument with spaces\0" + environment.joined(separator: "\0") + "\0\0").utf8))
            return result
        }
        let device = "SIMULATOR_UDID=\(identifier)"
        let footprint = "DYLD_FRAMEWORK_PATH=/build/Debug:/Applications/Xcode 27.1.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/Library/Frameworks"
        let result = SimulatorProcessConnections.decode(arguments([device, footprint]), executablePath: executable, event: event)
        #expect(result?.deviceIdentifier == identifier)
        #expect(result?.xcodeURL.path == "/Applications/Xcode 27.1.app")
        let testingPath = "/custom/XCTestDevices"
        let cloneExecutable = "\(testingPath)/\(identifier)/data/Containers/Bundle/Application/ID/App.app/App"
        let enabledPath = SimulatorDeviceSets.testingPath(showTesting: true, customPath: testingPath)
        #expect(SimulatorProcessConnections.decode(arguments([device, footprint]), executablePath: cloneExecutable, event: event, testingDeviceSetPath: enabledPath)?.deviceSetPath == testingPath)
        let disabledPath = SimulatorDeviceSets.testingPath(showTesting: false, customPath: testingPath)
        #expect(disabledPath == nil)
        #expect(SimulatorProcessConnections.decode(arguments([device, footprint]), executablePath: cloneExecutable, event: event, testingDeviceSetPath: disabledPath) == nil)
        #expect(SimulatorProcessConnections.decode(arguments([device, footprint]), executablePath: cloneExecutable, event: event, testingDeviceSetPath: "/other/XCTestDevices") == nil)
        #expect(SimulatorProcessConnections.decode(arguments([device]), executablePath: executable, event: event) == nil)
        #expect(SimulatorProcessConnections.decode(arguments([device, footprint]), executablePath: executable.replacingOccurrences(of: identifier, with: "OTHER"), event: event) == nil)
        #expect(SimulatorProcessConnections.decode(arguments([device, footprint, "GPUTOOLS_XCODE_DEVELOPER_PATH=/Applications/Other.app/Contents/Developer"]), executablePath: executable, event: event) == nil)
    }
}

@Suite
struct SimulatorSettingsBackendTests {
    private func envelope(_ value: String) -> Data { Data(("{\"result\":" + value + "}").utf8) }
    private func simulator(_ identifier: String, deviceSetPath: String? = nil) -> InventoryDevice {
        .simulator(SimulatorHostDevice(identifier: identifier, name: "Fixture", descriptiveName: "Fixture",
            runtimeIdentifier: "runtime", runtimeName: "iOS", productFamily: "iPhone", state: "Booted", deviceSetPath: deviceSetPath))
    }
    private let defaultRoute = "{\"systemDefault\":{}}"

    private func remote(_ reality: String, features: [String], connection: String = "connected") throws -> InventoryDevice {
        let data = try JSONSerialization.data(withJSONObject: ["result": ["devices": [[
            "identifier": "core-device", "properties": [
                "hardware": ["reality": reality, "udid": "hardware-udid"],
                "state": ["name": "Fixture Device"], "connection": ["state": connection]],
            "capabilities": features.map { ["featureIdentifier": "com.apple.coredevice.feature." + $0] }
        ]]]])
        return .remote(try #require(CoreDeviceInventoryDecoder.decode(data).first))
    }

    @Test func extendedQueriesReturnSupportedValuesAndHostAudioChoices() {
        let microphone = SimulatorAudioDevice(identifier: "mic-uid", name: "Microphone")
        let speaker = SimulatorAudioDevice(identifier: "speaker-uid", name: "Speaker")
        let backend = SimulatorSettingsBackend(run: { tool, arguments in
            if tool == .simctl {
                return Data((arguments.last == "appearance" ? "dark" : arguments.last == "content_size" ? "large" : "enabled").utf8)
            }
            if arguments.contains("appearance") {
                return envelope("""
                {"lookAndFeel":"Tinted Liquid Glass","supportedLooksAndFeels":["Clear Liquid Glass","Tinted Liquid Glass"],
                 "liquidGlassOpacity":0.6,"colorFilter":{"enabled":true,"filterType":{"name":"Protanopia"},"intensity":0.75},
                 "reduceMotion":{"enabled":true},"reduceTransparency":{"enabled":false},"showBorders":{"enabled":true}}
                """)
            }
            if arguments.contains("voiceover") { return envelope("{\"enabled\":false}") }
            if arguments.contains("audio") {
                return envelope("{\"volume\":60,\"audioInputDevice\":\(defaultRoute),\"audioOutputDevice\":{\"device\":{\"_0\":\"speaker-uid\"}}}")
            }
            return envelope("{\"availableScenarios\":[{\"name\":\"City Run\",\"localizedName\":\"City Run localized\"}]}")
        }, audioDevices: { ([microphone], [speaker]) })
        let value = backend.read(device: simulator("device-A"))
        #expect(value.appearance == "dark" && value.contentSize == "large" && value.increaseContrast == true)
        #expect(value.supportedLooksAndFeels == [.clear, .tinted])
        #expect(value.lookAndFeel == "Tinted Liquid Glass" && value.liquidGlassOpacity == 0.6)
        #expect(value.colorFilter == .protanopia && value.colorFilterIntensity == 0.75)
        #expect(value.reduceMotion == true && value.reduceTransparency == false && value.showBorders == true)
        #expect(value.voiceOver == false && value.volume == 60)
        #expect(value.audioInputDevice == "systemDefault" && value.audioOutputDevice == "speaker-uid")
        #expect(value.audioInputDevices == [microphone] && value.audioOutputDevices == [speaker])
        #expect(value.locationAvailable && value.locationScenarios == [.init(name: "City Run", displayName: "City Run localized")])
        #expect(value.issues.isEmpty)
    }

    @Test func unavailableExtendedQueriesPreserveLegacySettingsAndLocationWithDiagnostics() {
        var queried: [[String]] = []
        let backend = SimulatorSettingsBackend(run: { tool, arguments in
            if tool == .devicectl {
                queried.append(arguments)
                throw CLIError.unavailable("unsupported", "This device is unavailable to CoreDevice.")
            }
            if arguments.first == "location" { return Data("Name                 Description\n========================================================\nCity Run             City Run\n".utf8) }
            return Data((arguments.last == "appearance" ? "light" : arguments.last == "content_size" ? "small" : "disabled").utf8)
        }, audioDevices: { ([], []) })
        let value = backend.read(device: simulator("custom-set-device"))
        #expect(value.appearance == "light" && value.contentSize == "small" && value.increaseContrast == false)
        #expect(value.reduceMotion == nil && value.voiceOver == nil && value.volume == nil && value.colorFilter == nil)
        #expect(value.locationAvailable && value.locationScenarios.map(\.name) == ["City Run"])
        #expect(value.issues.count == 4)
        #expect(queried.count == 4 && queried.allSatisfy { $0.contains("custom-set-device") })
        let custom = simulator("custom-set-device", deviceSetPath: "/tmp/FixtureDeviceSet")
        let customValue = backend.read(device: custom)
        #expect(customValue.appearance == "light" && customValue.locationAvailable)
        #expect(queried.count == 4 && customValue.issues.isEmpty)
        #expect(throws: CLIError.self) { try backend.set(.liquidGlassOpacity(0.75), device: custom) }
    }

    @Test func writesUseTheTargetDeviceAndPreserveCommandFailures() throws {
        var commands: [(SimulatorSettingsBackend.Tool, [String])] = []
        var fail = false
        let backend = SimulatorSettingsBackend(run: { tool, arguments in
            commands.append((tool, arguments))
            if fail { throw CLIError.io("device-setting", "The device rejected this setting.") }
            return Data()
        }, audioDevices: { ([], []) })
        try backend.set(.colorFilter(.deuteranopia, intensity: 0.75), device: simulator("device-B"))
        try backend.set(.voiceOver(true), device: simulator("device-B"))
        try backend.set(.audioOutputDevice("speaker-uid"), device: simulator("device-B"))
        try backend.set(.contentSize("accessibility-large"), device: simulator("device-B"))
        try backend.set(.locationScenario("City Run"), device: simulator("device-B"))
        let suffix = ["--device", "device-B", "--quiet", "--timeout", "10", "--json-output", "-"]
        #expect(commands[0].1 == ["device", "settings", "appearance", "--color-filter", "on", "--color-filter-type", "deuteranopia", "--color-filter-intensity", "0.75"] + suffix)
        #expect(commands[1].1 == ["device", "settings", "voiceover", "--enable"] + suffix)
        #expect(commands[2].1 == ["device", "settings", "audio", "--output-device", "speaker-uid"] + suffix)
        #expect(commands[0...2].allSatisfy { $0.0 == .devicectl })
        #expect(commands[3].0 == .simctl && commands[3].1 == ["ui", "device-B", "content_size", "accessibility-large"])
        #expect(commands[4].0 == .simctl && commands[4].1 == ["location", "device-B", "run", "City Run"])
        fail = true
        #expect(throws: CLIError.self) { try backend.set(.liquidGlassOpacity(0.75), device: simulator("device-B")) }
    }

    @Test func remoteQueriesKeepAvailableValuesWhenAnotherQueryFails() throws {
        let physical = try remote("physical", features: ["customizeuistyle", "customizeappearancesettings",
            "customizeliquidglass", "voiceover", "simulatelocation"])
        var queries: [[String]] = []
        let backend = SimulatorSettingsBackend(run: { tool, arguments in
            #expect(tool == .devicectl)
            #expect(arguments.contains("core-device") && !arguments.contains("hardware-udid"))
            queries.append(arguments)
            if arguments.contains("appearance") {
                return envelope("""
                {"userInterfaceStyle":"dark","textSize":"Accessibility Large","increaseContrast":true,
                 "liquidGlassOpacity":0.5,"reduceMotion":{"enabled":false},"showBorders":{"enabled":true},
                 "colorFilter":{"enabled":false}}
                """)
            }
            if arguments.contains("voiceover") { return envelope("{\"enabled\":true}") }
            throw CLIError.io("fixture-location", "Location query failed.")
        }, audioDevices: { Issue.record("Physical device did not advertise host audio routing"); return ([], []) })
        let settings = backend.read(device: physical)
        #expect(settings.appearance == "dark" && settings.contentSize == "accessibility-large")
        #expect(settings.increaseContrast == true && settings.liquidGlassOpacity == 0.5)
        #expect(settings.reduceMotion == false && settings.showBorders == true && settings.colorFilter == SimulatorColorFilter.none)
        #expect(settings.voiceOver == true && settings.volume == nil && settings.audioOutputDevice == nil)
        #expect(settings.locationAvailable && settings.locationScenarios.isEmpty && settings.issues.count == 1)
        #expect(settings.issues.first?.contains("Location query failed.") == true)
        #expect(queries.count == 3 && !queries.contains { $0.contains("audio") })
    }

    @Test func virtualSettingsUsePublicCommandsAndRetainNativeCommandFailures() throws {
        let virtual = try remote("virtual", features: ["customizeuistyle", "customizeappearancesettings", "audiooutput", "simulatelocation"])
        var commands: [[String]] = []
        var fail = false
        let backend = SimulatorSettingsBackend(run: { tool, arguments in
            #expect(tool == .devicectl)
            commands.append(arguments)
            if fail { throw CLIError.io("fixture-settings", "The device rejected the write.") }
            return Data()
        }, audioDevices: { ([], []) })
        try backend.set(.appearance("dark"), device: virtual)
        try backend.set(.contentSize("accessibility-large"), device: virtual)
        try backend.set(.audioOutputDevice("speaker-uid"), device: virtual)
        try backend.set(.location(latitude: 35, longitude: -120), device: virtual)
        try backend.set(.locationScenario("City Run"), device: virtual)
        try backend.set(.clearLocation, device: virtual)
        let target = ["--device", "core-device", "--quiet", "--timeout", "10", "--json-output", "-"]
        #expect(commands[0] == ["device", "settings", "appearance", "--mode", "dark"] + target)
        #expect(commands[1] == ["device", "settings", "appearance", "--text-size", "accessibility-large", "--larger-accessibility-sizes", "on"] + target)
        #expect(commands[2] == ["device", "settings", "audio", "--output-device", "speaker-uid"] + target)
        #expect(commands[3] == ["device", "simulate", "location", "coordinate", "--latitude", "35.0", "--longitude", "-120.0"] + target)
        #expect(commands[4] == ["device", "simulate", "location", "scenario", "City Run"] + target)
        #expect(commands[5] == ["device", "simulate", "location", "clear"] + target)
        fail = true
        do { try backend.set(.appearance("light"), device: virtual); Issue.record("The write failure was lost") }
        catch { #expect((error as? CLIError)?.identifier == "fixture-settings") }
    }

    @Test func unavailableOrUnsupportedRemoteSettingsDoNotRunCommands() throws {
        var ran = false
        let backend = SimulatorSettingsBackend(run: { _, _ in ran = true; return Data() }, audioDevices: { ([], []) })
        let unsupported = try remote("physical", features: ["startaudiooutput"])
        #expect(backend.read(device: unsupported).volume == nil)
        #expect(throws: CLIError.self) { try backend.set(.audioOutputDevice("systemDefault"), device: unsupported) }
        let unavailable = try remote("virtual", features: ["customizeuistyle"], connection: "unavailable")
        #expect(backend.read(device: unavailable).appearance == nil)
        #expect(throws: CLIError.self) { try backend.set(.appearance("dark"), device: unavailable) }
        #expect(!ran)
    }
}
