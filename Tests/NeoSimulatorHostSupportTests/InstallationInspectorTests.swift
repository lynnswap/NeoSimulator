@testable import NeoSimulatorDeviceIO
@testable import NeoSimulatorKit
@testable import NeoSimulatorHostSupport
import Foundation
import Synchronization
import Testing


@Suite
struct InstallationInspectorTests {
    @Test func UIFrameworksUseSelectedXcodeUnlessExplicitlyOverridden() async throws {
        let selected = try InstallationFixture(targetVersion: "27.1")
        let alternate = try InstallationFixture(targetVersion: "27.2")
        let inspector = makeInspector(selected).xcodes
        #expect(try await inspector.xcodeForUIFrameworks(override: nil).applicationURL == selected.targetXcodeURL)
        #expect(try await inspector.xcodeForUIFrameworks(override: alternate.targetXcodeURL).applicationURL == alternate.targetXcodeURL)
        await #expect(throws: (any Error).self) {
            try await inspector.xcodeForUIFrameworks(override: alternate.targetXcodeURL.appendingPathComponent("Missing.app"))
        }
    }

    @Test func simulatorCommandsPreserveXcodeSelectionWithoutInvokingInstallingWrapper() async throws {
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
        let output = try await SystemCommandRunner().run(.simctl(
            xcodeURL: fixture.targetXcodeURL, arguments: ["list", "--json"], policy: .uninterrupted,
            coreSimulatorFrameworkURL: fixture.coreSimulatorFrameworkURL
        ))
        #expect(output.terminationStatus == 0)
        #expect(output.stdoutText == "\(fixture.developerDirectoryURL.path)\nlist\n--json")
        #expect(!FileManager.default.fileExists(atPath: fixture.simctlWrapperURL.path + ".install"))
    }

    @Test(arguments: [["boot", "clone"], ["create", "My Watch", "watch-type", "watch-runtime"], ["pair", "watch", "phone"]])
    func simulatorCommandsUseTheRecordedDeviceSet(_ arguments: [String]) async throws {
        let fixture = try InstallationFixture()
        try Data(#"""
        #!/bin/sh
        printf '%s\n' "$@"
        """#.utf8).write(to: fixture.simctlBinaryURL)
        let output = try await SystemCommandRunner().run(.simctl(
            xcodeURL: fixture.targetXcodeURL, arguments: arguments, deviceSetPath: "/custom/XCTestDevices", policy: .uninterrupted,
            coreSimulatorFrameworkURL: fixture.coreSimulatorFrameworkURL
        ))
        #expect(output.terminationStatus == 0)
        #expect(output.stdoutText == (["--set", "/custom/XCTestDevices"] + arguments).joined(separator: "\n"))
    }

    @Test func validatesSelectedXcode27AndNeoHostComponents() async throws {
        let fixture = try InstallationFixture()
        let inspector = makeInspector(fixture)

        let xcode = try await inspector.validatedTargetXcode()
        let host = try await inspector.validatedNeoHost(for: xcode)

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

    @Test func rejectsXcode26() async throws {
        let fixture = try InstallationFixture(
            targetVersion: "26.4",
            targetBuild: "17E214"
        )

        do {
            _ = try await makeInspector(fixture).validatedTargetXcode()
            Issue.record("expected Xcode 26 to be rejected")
        } catch let error as DeviceIOError {
            #expect(error.identifier == "unsupported-xcode")
            #expect(error.category == .unavailable)
        }
    }

    @Test func acceptsXcode28WhenTheVerifiedSurfaceMatches() async throws {
        let fixture = try InstallationFixture(
            targetVersion: "28.0",
            targetBuild: "28A100",
            simctlExpectedVersion: "1280.1",
            devicectlExpectedVersion: "700.2"
        )
        let inspector = makeInspector(fixture)

        let xcode = try await inspector.validatedTargetXcode()
        let host = try await inspector.validatedNeoHost(for: xcode)

        #expect(xcode.version == (try ToolVersion("28.0")))
        #expect(host.xcode == xcode)
        #expect(host.coreSimulatorVersion == "1280.1")
        #expect(host.coreDeviceVersion == "700.2")
    }

    @Test func selectedXcodeMustBeIntactAppleSignedCode() async throws {
        let fixture = try InstallationFixture()
        let inspector = InstallationInspector(
            runner: FakeSystemCommandRunner(),
            environment: ["DEVELOPER_DIR": fixture.developerDirectoryURL.path],
            rendererApplicationURL: fixture.neoHostURL,
            coreSimulatorFrameworkURL: fixture.coreSimulatorFrameworkURL,
            coreDeviceFrameworkURL: fixture.coreDeviceFrameworkURL,
            signatureValidator: CodeSignatureValidator { _, identifier in
                if identifier == ToolConstants.xcodeBundleIdentifier {
                    throw HostOperationError.unavailable(
                        "code-signature",
                        "injected invalid Xcode signature"
                    )
                }
            }
        )

        await #expect(throws: HostOperationError.self) {
            _ = try await inspector.validatedTargetXcode()
        }
    }

    @Test func loadedPrivateFrameworksMustBeIntactAppleSignedCode() async throws {
        let fixture = try InstallationFixture()
        let inspector = InstallationInspector(
            runner: FakeSystemCommandRunner(),
            environment: ["DEVELOPER_DIR": fixture.developerDirectoryURL.path],
            rendererApplicationURL: fixture.neoHostURL,
            coreSimulatorFrameworkURL: fixture.coreSimulatorFrameworkURL,
            coreDeviceFrameworkURL: fixture.coreDeviceFrameworkURL,
            signatureValidator: CodeSignatureValidator { _, identifier in
                if identifier == ToolConstants.simulatorKitBundleIdentifier {
                    throw HostOperationError.unavailable(
                        "code-signature",
                        "injected invalid SimulatorKit signature"
                    )
                }
            }
        )
        let xcode = try await inspector.validatedTargetXcode()

        do {
            _ = try await inspector.validatedNeoHost(for: xcode)
            Issue.record("expected invalid SimulatorKit signature to fail")
        } catch let error as HostOperationError {
            #expect(error.identifier == "code-signature")
        }
    }

    @Test func rejectsXcodeWhenThePreferenceSurfaceDisappears() async throws {
        let fixture = try InstallationFixture(includeHiddenKey: false)

        do {
            _ = try await makeInspector(fixture).validatedTargetXcode()
            Issue.record("expected missing key to fail")
        } catch let error as HostOperationError {
            #expect(error.identifier == "xcode-preference-key")
        }
    }

    @Test func rejectsXcodeWhenDeviceHubIsNotLaunchable() async throws {
        let fixture = try InstallationFixture()
        let executableURL = fixture.targetXcodeURL
            .appendingPathComponent(ToolConstants.deviceHubPath, isDirectory: true)
            .appendingPathComponent("Contents/MacOS/DevicesTrampoline")
        try FileManager.default.removeItem(at: executableURL)

        do {
            _ = try await makeInspector(fixture).validatedTargetXcode()
            Issue.record("expected missing Device Hub executable to fail")
        } catch let error as HostOperationError {
            #expect(error.identifier == "device-hub-executable")
        }
    }

    @Test func rejectsXcodeWhenTheDeviceHubPreferenceSurfaceDisappears() async throws {
        let fixture = try InstallationFixture(includeDeviceHubKey: false)

        do {
            _ = try await makeInspector(fixture).validatedTargetXcode()
            Issue.record("expected missing Device Hub key to fail")
        } catch let error as HostOperationError {
            #expect(error.identifier == "device-hub-preference-key")
        }
    }

    @Test func optionalBindingDiagnosticsDoNotRejectASuccessfulRuntimeValidation() async throws {
        let fixture = try InstallationFixture()
        let runner = FakeSystemCommandRunner()
        runner.neoHostRuntimeValidationOutput = #"""
        {"optionalBindings":[
          {"surface":"nativeCanvas","stage":"preparingBindings","status":"prepared","unverified":["DeviceView construction and rendering"]},
          {"surface":"nativePoseControls","stage":"loadingFramework","status":"unavailable","detail":"Optional framework unavailable","unverified":["Provider discovery"]},
          {"surface":"appResize","stage":"preparingBindings","status":"failed","detail":"Optional binding preparation failed","unverified":["Device capability and implementation witnesses"]}
        ]}
        """#
        let inspector = InstallationInspector(
            runner: runner,
            environment: ["DEVELOPER_DIR": fixture.developerDirectoryURL.path],
            rendererApplicationURL: fixture.neoHostURL,
            coreSimulatorFrameworkURL: fixture.coreSimulatorFrameworkURL,
            coreDeviceFrameworkURL: fixture.coreDeviceFrameworkURL,
            signatureValidator: .acceptingTestFixtures
        )
        let xcode = try await inspector.validatedTargetXcode()

        #expect(try await inspector.validatedNeoHost(for: xcode).applicationURL == fixture.neoHostURL)
    }

    @Test func neoHostRuntimeValidationFailureIsRejected() async throws {
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
        let xcode = try await inspector.validatedTargetXcode()

        do {
            _ = try await inspector.validatedNeoHost(for: xcode)
            Issue.record("expected private runtime validation to fail")
        } catch let error as HostOperationError {
            #expect(error.identifier == "neo-host-runtime")
            #expect(error.category == .unavailable)
            #expect(error.message.contains("required private symbol is unavailable"))
        }
    }

    @Test func actualRuntimeProbeDecidesCompatibilityAcrossInstalledFrameworkVersions() async throws {
        let fixture = try InstallationFixture(coreSimulatorXcodeMajorVersion: 28, coreDeviceXcodeMajorVersion: 28, simulatorCoreDevicePluginXcodeMajorVersion: 28, coreSimulatorBundleVersion: "1171.5", coreDeviceBundleVersion: "642.14", simulatorCoreDevicePluginBundleVersion: "1171.8")
        let inspector = makeInspector(fixture)
        let xcode = try await inspector.validatedTargetXcode()
        #expect(try await inspector.validatedNeoHost(for: xcode).xcode == xcode)
    }

    @Test func missingWrapperIsRejected() async throws {
        let fixture = try InstallationFixture()
        try FileManager.default.removeItem(at: fixture.simctlWrapperURL)
        let inspector = makeInspector(fixture)
        let xcode = try await inspector.validatedTargetXcode()

        do {
            _ = try await inspector.validatedNeoHost(for: xcode)
            Issue.record("expected missing simctl wrapper to fail")
        } catch let error as HostOperationError {
            #expect(error.identifier == "simctl-wrapper")
        }
    }

    @Test func changedWrapperAssignmentFormatIsRejected() async throws {
        let fixture = try InstallationFixture()
        try overwrite(
            "#!/bin/zsh\nEXPECTED_VERSION = \"642.15\"\n",
            at: fixture.devicectlWrapperURL
        )
        let inspector = makeInspector(fixture)
        let xcode = try await inspector.validatedTargetXcode()

        do {
            _ = try await inspector.validatedNeoHost(for: xcode)
            Issue.record("expected changed devicectl wrapper format to fail")
        } catch let error as HostOperationError {
            #expect(error.identifier == "devicectl-wrapper-version")
        }
    }

    @Test func nonnumericWrapperVersionIsRejected() async throws {
        let fixture = try InstallationFixture()
        try overwrite(
            "#!/bin/zsh\nEXPECTED_VERSION=\"642.beta\"\n",
            at: fixture.devicectlWrapperURL
        )
        let inspector = makeInspector(fixture)
        let xcode = try await inspector.validatedTargetXcode()

        do {
            _ = try await inspector.validatedNeoHost(for: xcode)
            Issue.record("expected nonnumeric devicectl version to fail")
        } catch let error as HostOperationError {
            #expect(error.identifier == "devicectl-wrapper-version")
        }
    }

    @Test func ambiguousWrapperVersionAssignmentsAreRejected() async throws {
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
        let xcode = try await inspector.validatedTargetXcode()

        do {
            _ = try await inspector.validatedNeoHost(for: xcode)
            Issue.record("expected ambiguous simctl wrapper version to fail")
        } catch let error as HostOperationError {
            #expect(error.identifier == "simctl-wrapper-version")
        }
    }

    @Test func directSimctlMustBeIntactAppleSignedCode() async throws {
        let fixture = try InstallationFixture()
        let inspector = makeInspector(
            fixture,
            rejectingSignatureIdentifier: ToolConstants.simctlBundleIdentifier
        )
        let xcode = try await inspector.validatedTargetXcode()

        do {
            _ = try await inspector.validatedNeoHost(for: xcode)
            Issue.record("expected invalid simctl signature to fail")
        } catch let error as HostOperationError {
            #expect(error.identifier == "code-signature")
        }
    }

    @Test func directDevicectlMustBeIntactAppleSignedCode() async throws {
        let fixture = try InstallationFixture()
        let inspector = makeInspector(
            fixture,
            rejectingSignatureIdentifier: ToolConstants.devicectlBundleIdentifier
        )
        let xcode = try await inspector.validatedTargetXcode()

        do {
            _ = try await inspector.validatedNeoHost(for: xcode)
            Issue.record("expected invalid devicectl signature to fail")
        } catch let error as HostOperationError {
            #expect(error.identifier == "code-signature")
        }
    }

    @Test func simulatorCoreDevicePluginMustBeIntactAppleSignedCode() async throws {
        let fixture = try InstallationFixture()
        let inspector = makeInspector(
            fixture,
            rejectingSignatureIdentifier:
                ToolConstants.simulatorCoreDevicePluginBundleIdentifier
        )
        let xcode = try await inspector.validatedTargetXcode()

        do {
            _ = try await inspector.validatedNeoHost(for: xcode)
            Issue.record("expected invalid simulator plugin signature to fail")
        } catch let error as HostOperationError {
            #expect(error.identifier == "code-signature")
        }
    }

    @Test func devicectlMustNotLinkDeviceKitOrDeviceHub() async throws {
        for fragment in [
            "@rpath/DeviceKit.framework/Versions/A/DeviceKit",
            "/Applications/Xcode.app/Contents/Applications/DeviceHub.app/Contents/MacOS/DeviceHub",
        ] {
            let fixture = try InstallationFixture()
            try overwrite(fragment, at: fixture.devicectlBinaryURL)
            let inspector = makeInspector(fixture)
            let xcode = try await inspector.validatedTargetXcode()

            do {
                _ = try await inspector.validatedNeoHost(for: xcode)
                Issue.record("expected forbidden devicectl linkage to fail")
            } catch let error as HostOperationError {
                #expect(error.identifier == "devicectl-linkage")
            }
        }
    }

    @Test func simulatorCoreDevicePluginMustNotLinkDeviceKitOrDeviceHub() async throws {
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
            let xcode = try await inspector.validatedTargetXcode()

            do {
                _ = try await inspector.validatedNeoHost(for: xcode)
                Issue.record("expected forbidden simulator plugin linkage to fail")
            } catch let error as HostOperationError {
                #expect(
                    error.identifier == "simulator-core-device-plugin-linkage"
                )
            }
        }
    }

    @Test func compatibilityGateExecutesOnlyThePackagedRuntimeValidator() async throws {
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

        let xcode = try await inspector.validatedTargetXcode()
        _ = try await inspector.validatedNeoHost(for: xcode)

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

    @Test func missingPackagedHostFailsBeforeNeoModeCanBeUsed() async throws {
        let fixture = try InstallationFixture(includeNeoHost: false)
        let inspector = makeInspector(fixture)
        let xcode = try await inspector.validatedTargetXcode()

        do {
            _ = try await inspector.validatedNeoHost(for: xcode)
            Issue.record("expected missing packaged host to fail")
        } catch let error as HostOperationError {
            #expect(error.identifier == "neo-host-bundle")
            #expect(error.category == .unavailable)
        }
    }

    @Test func versionComparisonPadsMissingComponents() async throws {
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
                throw HostOperationError.unavailable(
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

    @Test func customSetSettingsNeverAddressADefaultSetDeviceThroughDevicectl() async throws {
        let commands = Mutex<[[String]]>([])
        let backend = SimulatorSettingsBackend(run: { tool, arguments in
            if case .devicectl = tool { throw HostOperationError.io("wrong-device", "devicectl cannot distinguish this device set") }
            if tool == .guestSettings { return Data(#"{"success":true,"modes":[],"current":null}"#.utf8) }
            commands.withLock { $0.append(arguments) }
            if arguments.first == "spawn" { return Data(#"<plist version="1.0"><dict/></plist>"#.utf8) }
            let output = switch arguments.last {
            case "appearance": "light"
            case "increase_contrast": "disabled"
            default: ""
            }
            return Data(output.utf8)
        }, readGuest: { group in
            switch group {
            case .textSize: .values(group) { $0.contentSize = .medium }
            case .accessibility: .values(group) { $0.reduceMotion = true }
            default: .values(group) { _ in }
            }
        }, writeGuest: { change in
            commands.withLock { $0.append(["guest", "\(change)"]) }
        }, audioDevices: { Issue.record("Unsupported custom-set audio must not be queried"); return ([], []) })
        let device = InventoryDevice.simulator(SimulatorHostDevice(identifier: "same-udid", name: "Clone", descriptiveName: "Clone",
            runtimeIdentifier: "runtime", runtimeName: "iOS", productFamily: "iPhone", state: "Booted", deviceSetPath: "/custom/XCTestDevices"))
        let (settings, issues, _) = await backend.merged(of: device)
        #expect(settings.appearance == .light && settings.contentSize == .medium && settings.increaseContrast == false)
        #expect(settings.reduceMotion == true && settings.audioOutputDevice == nil && issues.isEmpty)
        try await backend.set(.appearance(.dark), device: device)
        try await backend.set(.location(latitude: 1, longitude: 2), device: device)
        let count = commands.withLock { $0.count }
        try await backend.set(.reduceMotion(true), device: device)
        #expect(commands.withLock { $0.count } == count + 1)
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
            #expect(info["udid"] == "SAME-UDID" && info["deviceSetPath"] == path)
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

    @Test(.timeLimit(.minutes(1)), arguments: [false, true]) @MainActor
    func cancellingAnOpenWaitsForItsRendererCleanup(_ cleanupFails: Bool) async throws {
        let center = NotificationCenter()
        let device = DeviceInventoryID.simulator(udid: "device-id", deviceSetPath: "/custom-set")
        let renderer = RendererRegistration(processIdentifier: 1, applicationPath: "/Renderer.app", xcodePath: "/Xcode.app",
                                            sessionIdentifier: "session", deviceIdentifiers: [])
        let started = AsyncStream<Void>.makeStream()
        var events = started.stream.makeAsyncIterator()
        var original: [String: String] = [:]
        var cancellationSent = false
        var completed = false
        let waiter = RendererDeviceRequestWaiter(acknowledgements: center, scheduleTimeout: { _, _ in {} }) { info, session in
            #expect(session == renderer.sessionIdentifier)
            if info["action"] == "cancel-open" {
                cancellationSent = true
                #expect(info["requestIdentifier"] == original["requestIdentifier"])
                #expect(info["deviceSetPath"] == "/custom-set")
                started.continuation.yield(())
            } else {
                original = info
                started.continuation.yield(())
            }
        }
        let opening = Task {
            defer { completed = true }
            try await waiter.open(device, in: renderer)
        }
        await events.next()
        opening.cancel()
        await events.next()
        #expect(!completed)
        var result = ["udid": "device-id", "deviceSetPath": "/custom-set"]
        if cleanupFails { result["error"] = "Owned cleanup failed" }
        center.post(name: .init("dev.lynnswap.NeoSimulator.RendererOpened"),
                    object: original["requestIdentifier"], userInfo: result)
        do {
            try await opening.value
            Issue.record("A cancelled open succeeded")
        } catch is CancellationError { #expect(!cleanupFails) }
        catch let error as HostOperationError { #expect(cleanupFails && error.message == "Owned cleanup failed") }
        #expect(cancellationSent)
        // The retired acknowledgement must not complete another request or resume twice.
        center.post(name: .init("dev.lynnswap.NeoSimulator.RendererOpened"), object: original["requestIdentifier"],
                    userInfo: ["udid": "device-id", "deviceSetPath": "/custom-set"])
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true]) @MainActor
    func aRendererExitFinishesRequestsThatItCanNoLongerAcknowledge(_ cancelled: Bool) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["60"]
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let device = DeviceInventoryID.simulator(udid: "device-id", deviceSetPath: "/custom-set")
        let renderer = RendererRegistration(processIdentifier: process.processIdentifier, applicationPath: "/Renderer.app",
                                            xcodePath: "/Xcode.app", sessionIdentifier: "session", deviceIdentifiers: [])
        let sent = AsyncStream<String?>.makeStream()
        var actions = sent.stream.makeAsyncIterator()
        // Stands in for the 450 s open deadline. Reaching it means the exit was not observed.
        let waiter = RendererDeviceRequestWaiter(acknowledgements: NotificationCenter(), scheduleTimeout: { _, expire in
            let deadline = Task { try await Task.sleep(for: .seconds(10)); expire() }
            return { deadline.cancel() }
        }) { info, _ in sent.continuation.yield(info["action"]) }
        let opening = Task { try await waiter.open(device, in: renderer) }
        #expect(await actions.next() == "open-device")
        if cancelled {
            opening.cancel()
            #expect(await actions.next() == "cancel-open")
        }
        process.terminate()
        do {
            try await opening.value
            Issue.record("An open succeeded without its renderer")
        } catch is CancellationError { #expect(cancelled) }
        catch let error as HostOperationError { #expect(!cancelled && error.identifier == "renderer-device-exit") }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [true, false]) @MainActor
    func aCancelledOpenReleasesItsScreenUnlessTheRendererHasExited(_ rendererExits: Bool) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["60"]
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let center = NotificationCenter()
        let device = DeviceInventoryID.simulator(udid: "device-id", deviceSetPath: "/custom-set")
        let renderer = RendererRegistration(processIdentifier: process.processIdentifier, applicationPath: "/Renderer.app",
                                            xcodePath: "/Xcode.app", sessionIdentifier: "session", deviceIdentifiers: [])
        let sent = AsyncStream<[String: String]>.makeStream()
        var requests = sent.stream.makeAsyncIterator()
        // Stands in for the 450 s and 120 s request deadlines. Reaching it means the exit was not observed.
        let makeWaiter: @MainActor () -> RendererDeviceRequestWaiter = {
            RendererDeviceRequestWaiter(acknowledgements: center, scheduleTimeout: { _, expire in
                let deadline = Task { try await Task.sleep(for: .seconds(10)); expire() }
                return { deadline.cancel() }
            }) { info, _ in sent.continuation.yield(info) }
        }
        let opening = Task {
            try await SimulatorHostController.openRendererDevice(device, in: renderer, bootIfNeeded: true, launchesRenderer: false,
                                                                makeWaiter: makeWaiter) { Issue.record("A cancelled open was presented") }
        }
        let open = try #require(await requests.next())
        #expect(open["action"] == "open-device")
        opening.cancel()
        #expect(await requests.next()?["action"] == "cancel-open")
        let reply = ["udid": "device-id", "deviceSetPath": "/custom-set"]
        if rendererExits { process.terminate() }
        else { center.post(name: .init("dev.lynnswap.NeoSimulator.RendererOpened"), object: open["requestIdentifier"], userInfo: reply) }
        // The renderer did not own the device before this open, so cancellation releases it.
        let release = try #require(await requests.next())
        #expect(release["action"] == "release-device")
        if !rendererExits {
            center.post(name: .init("dev.lynnswap.NeoSimulator.RendererReleased"), object: release["requestIdentifier"],
                        userInfo: reply.merging(["error": "Recording cleanup failed"]) { $1 })
        }
        do {
            try await opening.value
            Issue.record("A cancelled open succeeded")
        } catch is CancellationError { #expect(rendererExits) }
        catch let error as HostOperationError {
            #expect(!rendererExits && error.identifier == "renderer-device-request" && error.message == "Recording cleanup failed")
        }
    }

    @Test @MainActor func closeDeviceAcknowledgementPreservesFailureAndAllowsRetry() async throws {
        let center = NotificationCenter()
        let target = DeviceInventoryID.simulator(udid: "device-id", deviceSetPath: nil)
        let renderer = RendererRegistration(processIdentifier: 1, applicationPath: "/Renderer.app", xcodePath: "/Xcode.app",
                                            sessionIdentifier: "owner-session", deviceIdentifiers: [target])
        var requests = 0
        let waiter = RendererDeviceRequestWaiter(acknowledgements: center, scheduleTimeout: { _, _ in {} }) { info, session in
            requests += 1
            #expect(session == renderer.sessionIdentifier && info["action"] == "close-device")
            #expect(info["udid"] == "DEVICE-ID" && info["deviceSetPath"] == nil && info["keepRunning"] == "false")
            var reply = ["udid": "device-id"]
            if requests == 1 { reply["error"] = "Fixture guest shutdown failed" }
            center.post(name: Notification.Name("dev.lynnswap.NeoSimulator.RendererClosed"),
                        object: info["requestIdentifier"], userInfo: reply)
        }
        do {
            try await waiter.close(target, in: renderer, keepingDeviceRunning: false)
            Issue.record("A failed close acknowledgement was accepted")
        } catch let error as HostOperationError {
            #expect(error.identifier == "renderer-device-request")
            #expect(error.message == "Fixture guest shutdown failed")
        }
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
        await #expect(throws: HostOperationError.self) {
            _ = try await tracker.synchronize(observations: [original, otherDevice], runningDeviceIdentifiers: [.simulator(udid: "A", deviceSetPath: nil), .simulator(udid: "B", deviceSetPath: nil)]) {
                if $0.deviceIdentifier == "A" { throw HostOperationError.io("test", "release failed") }
                transfers.append($0)
            }
        }
        #expect(try await tracker.synchronize(observations: [], runningDeviceIdentifiers: [.simulator(udid: "A", deviceSetPath: nil), .simulator(udid: "B", deviceSetPath: nil)]) { transfers.append($0) })
        #expect(transfers == [otherDevice, original])
        let pending = connection(pid: 2, start: 20)
        await #expect(throws: HostOperationError.self) {
            _ = try await tracker.synchronize(observations: [pending], runningDeviceIdentifiers: [.simulator(udid: "A", deviceSetPath: nil), .simulator(udid: "B", deviceSetPath: nil)]) { _ in throw HostOperationError.io("test", "launch failed after release") }
        }
        let latest = connection(pid: 3, start: 30, xcode: "Xcode27.2")
        #expect(try await tracker.synchronize(observations: [latest], runningDeviceIdentifiers: [.simulator(udid: "A", deviceSetPath: nil), .simulator(udid: "B", deviceSetPath: nil)]) { transfers.append($0) })
        #expect(transfers == [otherDevice, original, latest])
    }

    @Test func shutdownCancelsFailedTransferWithoutReplayingItAfterReboot() async throws {
        let tracker = XcodeConnectionTracker()
        let pending = connection(pid: 1, start: 10)
        await #expect(throws: HostOperationError.self) {
            _ = try await tracker.synchronize(observations: [pending], runningDeviceIdentifiers: [.simulator(udid: "A", deviceSetPath: nil)]) { _ in
                throw HostOperationError.io("test", "launch failed after release")
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

    @Test func aCancelledAttachmentStaysRetiredForOnlyItsBootAndDeviceSet() {
        let tracker = SimulatorBootTracker()
        func device(_ state: String, set: String? = nil) -> SimulatorHostDevice {
            .init(identifier: "A", name: "A", descriptiveName: "A", runtimeIdentifier: "runtime", runtimeName: "iOS",
                  productFamily: "iPhone", state: state, deviceSetPath: set)
        }
        let normal = device("Booted")
        let clone = device("Booted", set: "/custom-set")
        _ = tracker.observe([device("Shutdown"), device("Shutdown", set: "/custom-set")], attachInitially: false)
        // Cleanup can finish before the booted state reaches the next catalog snapshot.
        tracker.didCancelAttachment(normal.inventoryID)
        #expect(tracker.observe([normal, clone], attachInitially: true).devicesToAttach == [clone.inventoryID])
        tracker.didAttach(clone.inventoryID)
        #expect(tracker.observe([normal, clone], attachInitially: true).devicesToAttach.isEmpty)
        _ = tracker.observe([device("Shutdown"), clone], attachInitially: true)
        #expect(tracker.observe([normal, clone], attachInitially: true).devicesToAttach == [normal.inventoryID])
        tracker.didCancelAttachment(normal.inventoryID)
        tracker.reset()
        #expect(tracker.observe([normal, clone], attachInitially: true).devicesToAttach == [normal.inventoryID, clone.inventoryID])
        tracker.didCancelAttachment(clone.inventoryID)
        tracker.didAttach(normal.inventoryID)
        tracker.forgetTestingDevices()
        #expect(tracker.observe([normal, clone], attachInitially: true).devicesToAttach == [clone.inventoryID])
    }

    @Test func aChangeToADeviceLeavesItsCancelledAttachmentRetired() {
        let tracker = SimulatorBootTracker()
        func device(_ state: String) -> SimulatorHostDevice {
            .init(identifier: "A", name: "A", descriptiveName: "A", runtimeIdentifier: "runtime", runtimeName: "iOS",
                  productFamily: "iPhone", state: state)
        }
        let identifier = device("Booted").inventoryID
        _ = tracker.observe([device("Shutdown")], attachInitially: false)
        // The cancelled open booted the device, but a read during a rename keeps the catalog's older Shutdown.
        tracker.didCancelAttachment(identifier)
        #expect(tracker.observe([device("Booted")], attachInitially: false, changing: [identifier]).devicesToAttach.isEmpty)
        #expect(tracker.observe([device("Booted")], attachInitially: false).devicesToAttach.isEmpty)
        // A read outside the change can establish that this boot ended, so the next boot attaches.
        _ = tracker.observe([device("Shutdown")], attachInitially: false)
        #expect(tracker.observe([device("Booted")], attachInitially: false).devicesToAttach == [identifier])
    }

    @Test(arguments: ["Booted", "Shutdown"])
    func aFirstObservationDuringAChangeKeepsThatDevicesInitialAttachment(_ observed: String) {
        func device(_ identifier: String, _ state: String) -> SimulatorHostDevice {
            .init(identifier: identifier, name: identifier, descriptiveName: identifier, runtimeIdentifier: "runtime", runtimeName: "iOS",
                  productFamily: "iPhone", state: state)
        }
        let a = device("A", "Booted").inventoryID
        let b = device("B", "Booted").inventoryID
        let running = [device("A", "Booted"), device("B", "Booted")]

        // With attachment on start off, whatever step of the change the read saw, A attaches only after a later stop.
        let off = SimulatorBootTracker()
        let first = off.observe([device("A", observed), device("B", "Booted")], attachInitially: false, changing: [a])
        #expect(first.catalogChanged && first.devicesToAttach.isEmpty)
        #expect(off.observe(running, attachInitially: false).devicesToAttach.isEmpty)
        _ = off.observe([device("A", "Shutdown"), device("B", "Booted")], attachInitially: false)
        #expect(off.observe(running, attachInitially: false).devicesToAttach == [a])

        // With it on, B attaches now, and A once the change has settled if it is running then.
        let on = SimulatorBootTracker()
        #expect(on.observe([device("A", observed), device("B", "Booted")], attachInitially: true, changing: [a]).devicesToAttach == [b])
        on.didAttach(b)
        #expect(on.observe(running, attachInitially: true).devicesToAttach == [a])
        let stopped = SimulatorBootTracker()
        #expect(stopped.observe([device("A", observed)], attachInitially: true, changing: [a]).devicesToAttach.isEmpty)
        #expect(stopped.observe([device("A", "Shutdown")], attachInitially: true).devicesToAttach.isEmpty)

        // A cancelled open still retires that boot.
        let cancelled = SimulatorBootTracker()
        cancelled.didCancelAttachment(a)
        #expect(cancelled.observe([device("A", observed)], attachInitially: true, changing: [a]).devicesToAttach.isEmpty)
        #expect(cancelled.observe([device("A", "Booted")], attachInitially: true).devicesToAttach.isEmpty)

        // A device that first appears after the first read and during a change is a new device once that settles.
        let later = SimulatorBootTracker()
        _ = later.observe([], attachInitially: false)
        #expect(later.observe([device("A", observed)], attachInitially: false, changing: [a]).devicesToAttach.isEmpty)
        #expect(later.observe([device("A", "Booted")], attachInitially: false).devicesToAttach == [a])
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
        await #expect(throws: HostOperationError.self) {
            _ = try await tracker.synchronize(observations: [clone], runningDeviceIdentifiers: [.simulator(udid: "clone", deviceSetPath: clone.deviceSetPath)], testingDeviceSetPath: clone.deviceSetPath) { _ in throw HostOperationError.io("test", "retry") }
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

private extension SimulatorSettingsBackend {
    /// What one read published, merged over `settings` as a device's state merges it.
    func merged(_ groups: Set<DeviceSettingsGroup> = Set(DeviceSettingsGroup.allCases), of device: InventoryDevice,
                over settings: SimulatorDeviceSettings = SimulatorDeviceSettings()) async
        -> (settings: SimulatorDeviceSettings, issues: [String], unsupported: Set<DeviceSettingsGroup>) {
        let reads = Mutex<[DeviceSettingsGroupRead]>([])
        await read(groups, of: device) { read in reads.withLock { $0.append(read) } }
        var settings = settings, issues: [String] = [], unsupported = Set<DeviceSettingsGroup>()
        for read in reads.withLock({ $0 }) {
            read.apply(&settings)
            issues += read.failures
            switch read.outcome {
            case .values: break
            case .failed(let reason): issues.append(reason)
            case .unsupported: unsupported.insert(read.group)
            }
        }
        return (settings, issues.sorted(), unsupported)
    }
}

@Suite
struct SimulatorSettingsBackendTests {
    private func envelope(_ value: String) -> Data { Data(("{\"result\":" + value + "}").utf8) }
    private func simulator(_ identifier: String, deviceSetPath: String? = nil) -> InventoryDevice {
        .simulator(SimulatorHostDevice(identifier: identifier, name: "Fixture", descriptiveName: "Fixture",
            runtimeIdentifier: "runtime", runtimeName: "iOS", productFamily: "iPhone", state: "Booted", deviceSetPath: deviceSetPath))
    }

    private func remote(_ reality: String, features: [String], connection: String = "connected") throws -> InventoryDevice {
        let data = try JSONSerialization.data(withJSONObject: ["result": ["devices": [[
            "identifier": "core-device", "properties": [
                "hardware": ["fidelity": reality, "udid": "hardware-udid"],
                "state": ["name": "Fixture Device"], "connection": ["state": connection]],
            "capabilities": features.map { ["featureIdentifier": "com.apple.coredevice.feature." + $0] }
        ]]]])
        return .remote(try #require(CoreDeviceInventoryDecoder.decode(data).first))
    }

    @Test(.timeLimit(.minutes(1))) func aCancelledReadPublishesNothing() async {
        let device = simulator("device-A")
        let started = AsyncStream<Void>.makeStream()
        var events = started.stream.makeAsyncIterator()
        let published = Mutex(0)
        let reading = Task {
            let backend = SimulatorSettingsBackend(run: { _, _ in
                Issue.record("A settings read used the write transport.")
                return Data()
            }, readCommand: { _, arguments in
                started.continuation.yield(())
                let pending = AsyncStream<Void>.makeStream()
                var waiting = pending.stream.makeAsyncIterator()
                await waiting.next()
                try Task.checkCancellation()
                return Data()
            }, audioDevices: { Issue.record("Audio choices were queried after cancellation."); return ([], []) })
            await backend.read([.appearance], of: device) { _ in published.withLock { $0 += 1 } }
        }
        defer { reading.cancel() }
        await events.next()
        reading.cancel()
        await reading.value
        #expect(published.withLock { $0 } == 0)
    }

    @Test(.timeLimit(.minutes(1))) func aGroupPublishesWhileAnotherIsPending() async {
        let boldTextPublished = AsyncStream<Void>.makeStream()
        let backend = SimulatorSettingsBackend(run: { _, _ in
            Issue.record("A settings read used the write transport.")
            return Data()
        }, readCommand: { tool, arguments in
            if tool == .guestSettings {
                var published = boldTextPublished.stream.makeAsyncIterator()
                await published.next()
                return Data(#"{"success":true,"modes":[],"current":{"rawMode":1,"nativeName":"Larger Text","width":960,"height":2079}}"#.utf8)
            }
            guard arguments.first == "spawn" else { throw HostOperationError.io("fixture-query", "Unavailable.") }
            return Data(#"<plist version="1.0"><dict><key>EnhancedTextLegibilityEnabled</key><integer>1</integer></dict></plist>"#.utf8)
        }, audioDevices: { ([], []) })
        let settings = Mutex(SimulatorDeviceSettings())
        await backend.read([.boldText, .displayZoom], of: simulator("device-A")) { read in
            settings.withLock { read.apply(&$0) }
            if read.group == .boldText { boldTextPublished.continuation.yield(()) }
        }
        let value = settings.withLock { $0 }
        #expect(value.boldText == true && value.displayZoom?.rawMode == 1)
    }

    @Test func extendedQueriesReturnSupportedValuesAndHostAudioChoices() async {
        let microphone = SimulatorAudioDevice(identifier: "mic-uid", name: "Microphone")
        let speaker = SimulatorAudioDevice(identifier: "speaker-uid", name: "Speaker")
        let backend = SimulatorSettingsBackend(run: { tool, arguments in
            if tool == .guestSettings { return Data(#"{"success":true,"modes":[],"current":null}"#.utf8) }
            if tool == .simctl {
                if arguments.first == "location" { return Data("Name                 Description\n========================================================\nCity Run             City Run localized\n".utf8) }
                if arguments.first == "spawn" { return Data(#"<plist version="1.0"><dict><key>EnhancedTextLegibilityEnabled</key><integer>1</integer></dict></plist>"#.utf8) }
                return Data((arguments.last == "appearance" ? "dark" : "enabled").utf8)
            }
            throw HostOperationError.io("unexpected-tool", "Simulator settings must not use devicectl.")
        }, readGuest: { group in
            switch group {
            case .textSize: return .values(group) { $0.contentSize = .large }
            case .accessibility:
                return .values(group) {
                    $0.lookAndFeel = "Tinted Liquid Glass"
                    $0.supportedLooksAndFeels = [.clear, .tinted]
                    $0.liquidGlassOpacity = 0.6
                    $0.colorFilter = .protanopia
                    $0.colorFilterIntensity = 0.75
                    $0.reduceMotion = true
                    $0.reduceTransparency = false
                    $0.showBorders = true
                }
            case .voiceOver: return .values(group) { $0.voiceOver = false }
            case .audio:
                return .values(group) {
                    $0.volume = 60
                    $0.updateAudioRoutes(AudioRouteState(devices: [
                        HostAudioDevice(uid: microphone.identifier, name: microphone.name, inputChannels: 1, outputChannels: 0, defaultScopes: 1),
                        HostAudioDevice(uid: speaker.identifier, name: speaker.name, inputChannels: 0, outputChannels: 2, defaultScopes: 2),
                    ], inputRoute: AudioRouting.systemDefault, outputRoute: speaker.identifier,
                       defaultInput: microphone.identifier, defaultOutput: speaker.identifier))
                }
            default:
                Issue.record("Unexpected native query")
                throw SimulatorSettingsBackend.noGuest
            }
        }, audioDevices: { ([microphone], [speaker]) })
        let (value, issues, unsupported) = await backend.merged(of: simulator("device-A"))
        #expect(value.appearance == .dark && value.contentSize == .large && value.increaseContrast == true && value.boldText == true)
        #expect(value.supportedLooksAndFeels == [.clear, .tinted])
        #expect(value.lookAndFeel == "Tinted Liquid Glass" && value.liquidGlassOpacity == 0.6)
        #expect(value.colorFilter == .protanopia && value.colorFilterIntensity == 0.75)
        #expect(value.reduceMotion == true && value.reduceTransparency == false && value.showBorders == true)
        #expect(value.voiceOver == false && value.volume == 60)
        #expect(value.audioInputDevice == "systemDefault" && value.audioOutputDevice == "speaker-uid")
        let systemDefault = SimulatorAudioDevice(identifier: "systemDefault", name: "System Default")
        #expect(value.audioInputDevices == [systemDefault, microphone] && value.audioOutputDevices == [systemDefault, speaker])
        #expect(value.locationAvailable && value.locationScenarios == [.init(name: "City Run", displayName: "City Run localized")])
        #expect(issues.isEmpty && unsupported.isEmpty)
    }

    @Test func unavailableGuestQueriesFailOnlyTheirGroups() async {
        let queried = Mutex<[DeviceSettingsGroup]>([])
        let backend = SimulatorSettingsBackend(run: { tool, arguments in
            if tool == .guestSettings { return Data(#"{"success":true,"modes":[],"current":null}"#.utf8) }
            if arguments.first == "spawn" { return Data(#"<plist version="1.0"><dict/></plist>"#.utf8) }
            if arguments.first == "location" { return Data("Name                 Description\n========================================================\nCity Run             City Run\n".utf8) }
            return Data((arguments.last == "appearance" ? "light" : "disabled").utf8)
        }, readGuest: { group in
            queried.withLock { $0.append(group) }
            guard group == .textSize else { throw HostOperationError.unavailable("unsupported", "This device is unavailable to CoreDevice.") }
            return .values(group) { $0.contentSize = .small }
        }, audioDevices: { ([], []) })
        let (value, issues, _) = await backend.merged(of: simulator("custom-set-device"))
        #expect(value.appearance == .light && value.contentSize == .small && value.increaseContrast == false)
        #expect(value.reduceMotion == nil && value.voiceOver == nil && value.volume == nil && value.colorFilter == nil)
        #expect(value.locationAvailable && value.locationScenarios.map(\.name) == ["City Run"])
        #expect(issues.count == 3)
        #expect(Set(queried.withLock { $0 }) == [.textSize, .accessibility, .voiceOver, .audio])
        let custom = simulator("custom-set-device", deviceSetPath: "/tmp/FixtureDeviceSet")
        let (customValue, customIssues, _) = await backend.merged(of: custom)
        #expect(customValue.appearance == .light && customValue.locationAvailable && customValue.boldText == false)
        #expect(queried.withLock { $0.count } == 8 && customIssues.count == 3)
        await #expect(throws: DeviceDomainError.self) { try await backend.set(.liquidGlassOpacity(0.75), device: custom) }
    }

    @Test func aGroupReadsOnlyItsActualValueAndSetsNothingElse() async {
        var original = SimulatorDeviceSettings()
        original.appearance = .light
        original.volume = 60
        original.reduceMotion = true
        original.locationScenarios = [.init(name: "City Run", displayName: "City Run")]
        let backend = SimulatorSettingsBackend(run: { tool, arguments in
            guard tool == .simctl, arguments == ["ui", "device-A", "appearance"] else {
                Issue.record("An unrelated settings query ran.")
                throw HostOperationError.io("unrelated-query", "Unavailable.")
            }
            return Data("dark".utf8)
        }, readGuest: { _ in
            Issue.record("An unrelated settings query ran.")
            throw SimulatorSettingsBackend.noGuest
        }, audioDevices: { Issue.record("Audio choices were queried."); return ([], []) })
        let (updated, issues, _) = await backend.merged([.appearance], of: simulator("device-A"), over: original)
        #expect(updated.appearance == .dark)
        #expect(updated.volume == 60 && updated.reduceMotion == true)
        #expect(updated.locationScenarios == original.locationScenarios)
        #expect(issues.isEmpty)
    }

    @Test func anUnlistedRemoteAudioDeviceKeepsTheChoicesAlreadyKnown() async throws {
        let microphone = SimulatorAudioDevice(identifier: "mic-uid", name: "Microphone")
        let speaker = SimulatorAudioDevice(identifier: "speaker-uid", name: "Speaker")
        var original = SimulatorDeviceSettings()
        original.volume = 60
        original.appearance = .dark
        original.audioInputDevices = [microphone]
        original.audioOutputDevices = [speaker]
        let backend = SimulatorSettingsBackend(run: { tool, arguments in
            guard tool == .devicectl, arguments.starts(with: ["device", "info", "audio"]) else {
                Issue.record("An unrelated settings query ran.")
                throw HostOperationError.io("unrelated-query", "Unavailable.")
            }
            return envelope(#"{"volume":45,"audioInputDevice":{"systemDefault":{}},"audioOutputDevice":{"device":{"_0":"speaker-uid"}}}"#)
        }, audioDevices: { throw DeviceDomainError.io("host-audio-devices", "Device enumeration failed.") })
        let device = try remote("virtual", features: ["audioinput", "audiooutput"])
        let (updated, issues, _) = await backend.merged([.audio], of: device, over: original)
        #expect(updated.volume == 45 && updated.appearance == .dark)
        #expect(updated.audioInputDevice == "systemDefault" && updated.audioOutputDevice == "speaker-uid")
        #expect(updated.audioInputDevices == [microphone] && updated.audioOutputDevices == [speaker])
        #expect(issues.count == 1 && issues[0].hasPrefix("audio devices: "))
    }

    @Test func aFailedGroupReadKeepsItsValuesAndReportsWhy() async {
        var original = SimulatorDeviceSettings()
        original.appearance = .light
        original.reduceMotion = false
        original.colorFilter = .grayscale
        original.volume = 60
        let fails = Mutex(true)
        let backend = SimulatorSettingsBackend(run: { _, _ in
            Issue.record("An unrelated settings query ran.")
            throw HostOperationError.io("unrelated-query", "Unavailable.")
        }, readGuest: { group in
            #expect(group == .accessibility)
            if fails.withLock({ $0 }) { throw HostOperationError.io("appearance-query", "Current failure.") }
            return .values(group) {
                $0.reduceMotion = true
                $0.colorFilter = SimulatorColorFilter.none
            }
        }, audioDevices: { ([], []) })
        let failed = await backend.merged([.accessibility], of: simulator("device-A"), over: original)
        #expect(failed.settings == original)
        #expect(failed.issues.count == 1 && failed.issues[0].hasPrefix("appearance settings: "))
        fails.withLock { $0 = false }
        let recovered = await backend.merged([.accessibility], of: simulator("device-A"), over: failed.settings)
        #expect(recovered.settings.reduceMotion == true && recovered.settings.colorFilter == SimulatorColorFilter.none)
        #expect(recovered.issues.isEmpty)
    }

    @Test func displayZoomRetainsNativeModesAndReportsPartialApplyFailures() async throws {
        let modes = #"[{"rawMode":0,"nativeName":"Default","width":1170,"height":2532},{"rawMode":1,"nativeName":"Larger Text","width":960,"height":2079}]"#
        let response = Mutex(Data(("{\"success\":true,\"modes\":" + modes + ",\"current\":{\"rawMode\":0,\"nativeName\":\"Default\",\"width\":1170,\"height\":2532}}").utf8))
        let commands = Mutex<[[String]]>([])
        let backend = SimulatorSettingsBackend(run: { tool, arguments in
            #expect(tool == .guestSettings)
            commands.withLock { $0.append(arguments) }
            return response.withLock { $0 }
        }, audioDevices: { Issue.record("An unrelated query ran."); return ([], []) })
        let device = simulator("device-A", deviceSetPath: "/custom/Devices")
        let read = await backend.merged([.displayZoom], of: device, over: SimulatorDeviceSettings(volume: 60))
        #expect(read.settings.displayZoom?.rawMode == 0 && read.settings.supportedDisplayZoomModes.map(\.rawMode) == [0, 1])
        #expect(read.settings.applying(.displayZoom(1)).displayZoom?.nativeName == "Larger Text")
        #expect(read.settings.volume == 60 && read.issues.isEmpty)
        try await backend.set(.displayZoom(1), device: device)
        #expect(commands.withLock { $0 } == [["device-A", "display-zoom", "read"], ["device-A", "display-zoom", "set", "1"]])
        response.withLock { $0 = Data(#"{"success":false,"modes":[],"current":null,"canvasApplied":true,"error":{"description":"The relaunch request failed."}}"#.utf8) }
        do { try await backend.set(.displayZoom(1), device: device); Issue.record("The partial failure was lost.") }
        catch { #expect(error.localizedDescription.contains("was applied") && error.localizedDescription.contains("relaunch request failed")) }
        let failed = await backend.merged([.displayZoom], of: device, over: read.settings)
        #expect(failed.settings == read.settings)
        #expect(failed.issues.count == 1 && failed.issues[0].hasPrefix("Display Zoom: "))
        response.withLock { $0 = Data(#"{"success":true,"modes":[],"current":null}"#.utf8) }
        let noModes = await backend.merged([.displayZoom], of: device, over: read.settings)
        #expect(noModes.settings.displayZoom == nil && noModes.settings.volume == 60 && noModes.issues.isEmpty)
        let unsupported = try remote("physical", features: [])
        let count = commands.withLock { $0.count }
        await #expect(throws: DeviceDomainError.self) { try await backend.set(.displayZoom(1), device: unsupported) }
        #expect(commands.withLock { $0.count } == count)
    }

    @Test func boldTextUsesTheSimulatorPreferenceAndScopedConfirmation() async throws {
        let commands = Mutex<[[String]]>([])
        let actualBoldText = Mutex(false)
        let failure = Mutex<String?>(nil)
        let backend = SimulatorSettingsBackend(run: { tool, arguments in
            #expect(tool == .simctl)
            commands.withLock { $0.append(arguments) }
            let failing = failure.withLock { $0 }
            if failing == "notifyutil", arguments.contains("write") { actualBoldText.withLock { $0 = arguments.last == "1" } }
            if let failing, arguments.contains(failing) { throw HostOperationError.io("fixture-bold-text", "The command failed.") }
            return Data()
        }, readCommand: { tool, arguments in
            #expect(tool == .simctl && arguments == ["spawn", "device-A", "defaults", "export", "com.apple.Accessibility", "-"])
            if failure.withLock({ $0 }) == "export" { throw HostOperationError.io("fixture-bold-text", "The read failed.") }
            let enabled = actualBoldText.withLock { $0 }
            return Data("<plist version=\"1.0\"><dict><key>EnhancedTextLegibilityEnabled</key><integer>\(enabled ? 1 : 0)</integer></dict></plist>".utf8)
        }, audioDevices: { Issue.record("Unrelated audio choices were queried."); return ([], []) })
        let device = simulator("device-A", deviceSetPath: "/custom/Devices")
        let original = SimulatorDeviceSettings(boldText: true, volume: 60)
        #expect(original.applying(.boldText(false)).boldText == false)
        try await backend.set(.boldText(true), device: device)
        #expect(commands.withLock { $0 } == [
            ["spawn", "device-A", "defaults", "write", "com.apple.Accessibility", "EnhancedTextLegibilityEnabled", "-int", "1"],
            ["spawn", "device-A", "notifyutil", "-p", "com.apple.accessibility.cache.enhance.text.legibility"]
        ])
        let updated = await backend.merged([.boldText], of: device, over: original)
        #expect(updated.settings.boldText == false && updated.settings.volume == 60 && updated.issues.isEmpty)
        failure.withLock { $0 = "export" }
        let unreadable = await backend.merged([.boldText], of: device, over: updated.settings)
        #expect(unreadable.settings.boldText == false && unreadable.settings.volume == 60)
        #expect(unreadable.issues == ["Bold Text: The read failed."])
        failure.withLock { $0 = "write" }
        let writes = commands.withLock { $0.count }
        do { try await backend.set(.boldText(false), device: device); Issue.record("The write failure was lost.") }
        catch { #expect((error as? HostOperationError)?.identifier == "fixture-bold-text") }
        #expect(commands.withLock { $0.count } == writes + 1)
        failure.withLock { $0 = "notifyutil" }
        // What was saved stays honest, and the read that follows a failed change reports the value it took.
        do { try await backend.set(.boldText(true), device: device); Issue.record("The partial failure was lost.") }
        catch {
            #expect((error as? DeviceDomainError)?.identifier == "bold-text-notification")
            #expect(error.localizedDescription.contains("saved"))
        }
        let saved = await backend.merged([.boldText], of: device, over: updated.settings)
        #expect(saved.settings.boldText == true)
    }

    @Test func writesUseTheTargetDeviceAndPreserveCommandFailures() async throws {
        let recorded = Mutex<[(SimulatorSettingsBackend.Tool, [String])]>([])
        let changes = Mutex<[DeviceSettingChange]>([])
        let fail = Mutex(false)
        let backend = SimulatorSettingsBackend(run: { tool, arguments in
            recorded.withLock { $0.append((tool, arguments)) }
            return Data()
        }, writeGuest: { change in
            changes.withLock { $0.append(change) }
            if fail.withLock({ $0 }) { throw DeviceDomainError.io("device-setting", "The device rejected this setting.") }
        }, audioDevices: { ([], []) })
        try await backend.set(.colorFilter(.deuteranopia, intensity: 0.75), device: simulator("device-B"))
        try await backend.set(.voiceOver(true), device: simulator("device-B"))
        try await backend.set(.audioOutputDevice("speaker-uid"), device: simulator("device-B"))
        try await backend.set(.contentSize(.accessibilityLarge), device: simulator("device-B"))
        try await backend.set(.locationScenario("City Run"), device: simulator("device-B"))
        #expect(changes.withLock { $0 } == [.colorFilter(.deuteranopia, intensity: 0.75), .voiceOver(true),
                                             .audioOutputDevice("speaker-uid"), .contentSize(.accessibilityLarge)])
        let commands = recorded.withLock { $0 }
        #expect(commands.count == 1 && commands[0].0 == .simctl && commands[0].1 == ["location", "device-B", "run", "City Run"])
        fail.withLock { $0 = true }
        await #expect(throws: DeviceDomainError.self) { try await backend.set(.liquidGlassOpacity(0.75), device: simulator("device-B")) }
    }

    @Test func remoteQueriesKeepAvailableValuesWhenAnotherQueryFails() async throws {
        let physical = try remote("physical", features: ["customizeuistyle", "customizeappearancesettings",
            "customizeliquidglass", "voiceover", "simulatelocation"])
        let recorded = Mutex<[[String]]>([])
        let backend = SimulatorSettingsBackend(run: { tool, arguments in
            #expect(tool == .devicectl)
            #expect(arguments.contains("core-device") && !arguments.contains("hardware-udid"))
            recorded.withLock { $0.append(arguments) }
            if arguments.contains("appearance") {
                return envelope("""
                {"userInterfaceStyle":"dark","textSize":"Accessibility Large","increaseContrast":true,
                 "liquidGlassOpacity":0.5,"reduceMotion":{"enabled":false},"showBorders":{"enabled":true},
                 "colorFilter":{"enabled":false}}
                """)
            }
            if arguments.contains("voiceover") { return envelope("{\"enabled\":true}") }
            throw HostOperationError.io("fixture-location", "Location query failed.")
        }, audioDevices: { Issue.record("Physical device did not advertise host audio routing"); return ([], []) })
        let (settings, issues, unsupported) = await backend.merged(of: physical)
        #expect(settings.appearance == .dark && settings.contentSize == .accessibilityLarge)
        #expect(settings.increaseContrast == true && settings.liquidGlassOpacity == 0.5)
        #expect(settings.reduceMotion == false && settings.showBorders == true && settings.colorFilter == SimulatorColorFilter.none)
        #expect(settings.voiceOver == true && settings.volume == nil && settings.audioOutputDevice == nil)
        #expect(settings.locationAvailable && settings.locationScenarios.isEmpty && issues.count == 1)
        #expect(issues.first?.contains("Location query failed.") == true)
        #expect(unsupported == [.audio, .boldText, .displayZoom])
        // One query answers every group of the appearance settings.
        let queries = recorded.withLock { $0 }
        #expect(queries.count == 3 && !queries.contains { $0.contains("audio") })
    }

    @Test func virtualSettingsUsePublicCommandsAndRetainNativeCommandFailures() async throws {
        let virtual = try remote("virtual", features: ["customizeuistyle", "customizeappearancesettings", "audiooutput", "simulatelocation"])
        let recorded = Mutex<[[String]]>([])
        let fail = Mutex(false)
        let backend = SimulatorSettingsBackend(run: { tool, arguments in
            #expect(tool == .devicectl)
            recorded.withLock { $0.append(arguments) }
            if fail.withLock({ $0 }) { throw HostOperationError.io("fixture-settings", "The device rejected the write.") }
            return Data()
        }, audioDevices: { ([], []) })
        try await backend.set(.appearance(.dark), device: virtual)
        try await backend.set(.contentSize(.accessibilityLarge), device: virtual)
        try await backend.set(.audioOutputDevice("speaker-uid"), device: virtual)
        try await backend.set(.location(latitude: 35, longitude: -120), device: virtual)
        try await backend.set(.locationScenario("City Run"), device: virtual)
        try await backend.set(.clearLocation, device: virtual)
        let target = ["--device", "core-device", "--quiet", "--timeout", "10", "--json-output", "-"]
        let commands = recorded.withLock { $0 }
        #expect(commands[0] == ["device", "settings", "appearance", "--mode", "dark"] + target)
        #expect(commands[1] == ["device", "settings", "appearance", "--text-size", "accessibility-large", "--larger-accessibility-sizes", "on"] + target)
        #expect(commands[2] == ["device", "settings", "audio", "--output-device", "speaker-uid"] + target)
        #expect(commands[3] == ["device", "simulate", "location", "coordinate", "--latitude", "35.0", "--longitude", "-120.0"] + target)
        #expect(commands[4] == ["device", "simulate", "location", "scenario", "City Run"] + target)
        #expect(commands[5] == ["device", "simulate", "location", "clear"] + target)
        fail.withLock { $0 = true }
        do { try await backend.set(.appearance(.light), device: virtual); Issue.record("The write failure was lost") }
        catch { #expect((error as? HostOperationError)?.identifier == "fixture-settings") }
    }

    @Test func unavailableOrUnsupportedRemoteSettingsDoNotRunCommands() async throws {
        let ran = Mutex(false)
        let backend = SimulatorSettingsBackend(run: { _, _ in ran.withLock { $0 = true }; return Data() }, audioDevices: { ([], []) })
        let unsupported = try remote("physical", features: ["startaudiooutput"])
        let unsupportedValues = await backend.merged(of: unsupported)
        #expect(unsupportedValues.settings.volume == nil && unsupportedValues.settings.boldText == nil)
        #expect(unsupportedValues.unsupported == Set(DeviceSettingsGroup.allCases))
        await #expect(throws: DeviceDomainError.self) { try await backend.set(.boldText(true), device: unsupported) }
        await #expect(throws: DeviceDomainError.self) { try await backend.set(.audioOutputDevice("systemDefault"), device: unsupported) }
        let unavailable = try remote("virtual", features: ["customizeuistyle"], connection: "unavailable")
        #expect(await backend.merged(of: unavailable).settings.appearance == nil)
        await #expect(throws: DeviceDomainError.self) { try await backend.set(.appearance(.dark), device: unavailable) }
        let watch = InventoryDevice.simulator(SimulatorHostDevice(identifier: "watch", name: "Watch", descriptiveName: "Watch",
            runtimeIdentifier: "watchOS", runtimeName: "watchOS", productFamily: "Apple Watch", state: "Booted"))
        let watchValues = await backend.merged([.boldText], of: watch, over: SimulatorDeviceSettings(boldText: true))
        #expect(watchValues.unsupported == [.boldText])
        await #expect(throws: DeviceDomainError.self) { try await backend.set(.boldText(true), device: watch) }
        #expect(!ran.withLock { $0 })
    }
}
