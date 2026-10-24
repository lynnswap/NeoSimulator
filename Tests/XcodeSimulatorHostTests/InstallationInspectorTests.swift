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

    @Test func usesNewestRunPerDeviceAndRecognizesReusedPID() async throws {
        let tracker = XcodeConnectionTracker()
        let older = connection(pid: 1, start: 10)
        let newer = connection(pid: 2, start: 20, xcode: "Xcode27.2")
        let otherDevice = connection(pid: 3, start: 15, device: "B")
        var transfers: [XcodeSimulatorConnection] = []
        #expect(try await tracker.synchronize(observations: [newer, older, otherDevice]) { transfers.append($0) })
        #expect(transfers == [otherDevice, newer])
        #expect(try await !tracker.synchronize(observations: [older]) { transfers.append($0) })
        let reused = connection(pid: 2, start: 30)
        #expect(try await tracker.synchronize(observations: [reused]) { transfers.append($0) })
        #expect(transfers == [otherDevice, newer, reused])
    }

    @Test func failedTransferRetriesAndNewerRunSupersedesPendingSource() async throws {
        let tracker = XcodeConnectionTracker()
        let original = connection(pid: 1, start: 10)
        let otherDevice = connection(pid: 4, start: 15, device: "B")
        var transfers: [XcodeSimulatorConnection] = []
        await #expect(throws: CLIError.self) {
            _ = try await tracker.synchronize(observations: [original, otherDevice]) {
                if $0.deviceIdentifier == "A" { throw CLIError.io("test", "release failed") }
                transfers.append($0)
            }
        }
        #expect(try await tracker.synchronize(observations: []) { transfers.append($0) })
        #expect(transfers == [otherDevice, original])
        let pending = connection(pid: 2, start: 20)
        await #expect(throws: CLIError.self) {
            _ = try await tracker.synchronize(observations: [pending]) { _ in throw CLIError.io("test", "launch failed after release") }
        }
        let latest = connection(pid: 3, start: 30, xcode: "Xcode27.2")
        #expect(try await tracker.synchronize(observations: [latest]) { transfers.append($0) })
        #expect(transfers == [otherDevice, original, latest])
    }

    @Test func bootTransitionsRestoreOnceAndDoNotReopenClosedBootedWindows() {
        let tracker = SimulatorBootTracker()
        func device(_ identifier: String, _ state: String) -> SimulatorHostDevice {
            .init(identifier: identifier, name: identifier, descriptiveName: identifier, runtimeIdentifier: "runtime", runtimeName: "iOS", productFamily: "iPhone", state: state)
        }
        #expect(tracker.observe([device("A", "Booted"), device("B", "Shutdown")], attachInitially: false).devicesToAttach.isEmpty)
        #expect(tracker.observe([device("A", "Booted"), device("B", "Booted")], attachInitially: false).devicesToAttach == ["B"])
        #expect(tracker.observe([device("A", "Booted"), device("B", "Booted")], attachInitially: false).devicesToAttach == ["B"])
        tracker.didAttach("B")
        // Losing registry ownership while still Booted means a window was closed, not a new boot.
        #expect(tracker.observe([device("A", "Booted"), device("B", "Booted")], attachInitially: true).devicesToAttach.isEmpty)
        _ = tracker.observe([device("A", "Shutdown"), device("B", "Booted")], attachInitially: true)
        #expect(tracker.observe([device("A", "Booted"), device("B", "Booted")], attachInitially: true).devicesToAttach == ["A"])
        tracker.reset()
        #expect(tracker.observe([device("A", "Booted"), device("B", "Booted")], attachInitially: true).devicesToAttach == ["A", "B"])
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
        #expect(tracker.observe(current, attachInitially: false).devicesToAttach == ["pending"])
        // OFF and ON can both occur before another catalog snapshot is read.
        tracker.forgetTestingDevices()
        #expect(tracker.observe(current, attachInitially: false).devicesToAttach == ["pending", "testing"])
        tracker.didAttach("pending")
        tracker.didAttach("testing")
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
        #expect(SimulatorStartupSelection.device(in: [device], attachInitially: true, startsSession: true, startsLastDevice: true, current: device.identifier.lowercased(), hasOwnedDevices: false) == device)
        #expect(SimulatorStartupSelection.device(in: [device], attachInitially: true, startsSession: false, startsLastDevice: true, current: device.identifier, hasOwnedDevices: false) == nil)
        #expect(SimulatorStartupSelection.device(in: [device], attachInitially: true, startsSession: true, startsLastDevice: false, current: device.identifier, hasOwnedDevices: false) == nil)
        #expect(SimulatorStartupSelection.device(in: [device], attachInitially: true, startsSession: true, startsLastDevice: true, current: device.identifier, hasOwnedDevices: true) == nil)
        let booted = SimulatorHostDevice(identifier: "other", name: "iPad", descriptiveName: "iPad", runtimeIdentifier: "runtime", runtimeName: "iOS", productFamily: "iPad", state: "Booted")
        #expect(SimulatorStartupSelection.device(in: [device, booted], attachInitially: true, startsSession: true, startsLastDevice: true, current: device.identifier, hasOwnedDevices: false) == nil)
    }

    @Test func disablingTestingDevicesDiscardsPendingCloneConnections() async throws {
        let tracker = XcodeConnectionTracker()
        let clone = XcodeSimulatorConnection(event: .init(processIdentifier: 1, startSeconds: 10, startMicroseconds: 0),
            deviceIdentifier: "clone", xcodeURL: URL(fileURLWithPath: "/Applications/Xcode.app"), deviceSetPath: "/custom/XCTestDevices")
        await #expect(throws: CLIError.self) {
            _ = try await tracker.synchronize(observations: [clone], testingDeviceSetPath: clone.deviceSetPath) { _ in throw CLIError.io("test", "retry") }
        }
        #expect(try await !tracker.synchronize(observations: []) { _ in Issue.record("A hidden testing device must not be attached.") })
        #expect(!tracker.hasPendingConnection(forDevice: "clone"))
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
