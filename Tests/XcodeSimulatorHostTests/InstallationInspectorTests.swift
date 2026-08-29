import Foundation
import Testing

@testable import XcodeSimulatorHost

@Suite
struct InstallationInspectorTests {
    @Test func validatesSelectedXcode27AndStandaloneHostComponents() throws {
        let fixture = try InstallationFixture()
        let inspector = makeInspector(fixture)

        let xcode = try inspector.validatedTargetXcode()
        let host = try inspector.validatedLegacyHost(for: xcode)

        #expect(xcode.applicationURL == fixture.targetXcodeURL)
        #expect(xcode.version == (try ToolVersion("27.0")))
        #expect(xcode.buildVersion == "27A5252f")
        #expect(host.applicationURL == fixture.legacyHostURL)
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
        let host = try inspector.validatedLegacyHost(for: xcode)

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
            commandExecutableURL: fixture.commandExecutableURL,
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
            commandExecutableURL: fixture.commandExecutableURL,
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
            _ = try inspector.validatedLegacyHost(for: xcode)
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

    @Test func packagedHostRuntimeValidationFailureIsRejected() throws {
        let fixture = try InstallationFixture()
        let runner = FakeSystemCommandRunner()
        runner.legacyHostRuntimeValidationStatus = 69
        runner.legacyHostRuntimeValidationError =
            "required private symbol is unavailable"
        let inspector = InstallationInspector(
            runner: runner,
            environment: ["DEVELOPER_DIR": fixture.developerDirectoryURL.path],
            commandExecutableURL: fixture.commandExecutableURL,
            coreSimulatorFrameworkURL: fixture.coreSimulatorFrameworkURL,
            coreDeviceFrameworkURL: fixture.coreDeviceFrameworkURL,
            signatureValidator: .acceptingTestFixtures
        )
        let xcode = try inspector.validatedTargetXcode()

        do {
            _ = try inspector.validatedLegacyHost(for: xcode)
            Issue.record("expected private runtime validation to fail")
        } catch let error as CLIError {
            #expect(error.identifier == "legacy-host-runtime")
            #expect(error.category == .unavailable)
            #expect(error.message.contains("required private symbol is unavailable"))
        }
    }

    @Test func globalCoreSimulatorMustMatchTheSelectedXcodeMajor() throws {
        let fixture = try InstallationFixture(
            targetVersion: "28.0",
            targetBuild: "28A100",
            coreSimulatorXcodeMajorVersion: 27
        )
        let inspector = makeInspector(fixture)
        let xcode = try inspector.validatedTargetXcode()

        do {
            _ = try inspector.validatedLegacyHost(for: xcode)
            Issue.record("expected mismatched CoreSimulator generation to fail")
        } catch let error as CLIError {
            #expect(error.identifier == "core-simulator-bundle")
        }
    }

    @Test func globalCoreDeviceMustMatchTheSelectedXcodeMajor() throws {
        let fixture = try InstallationFixture(
            targetVersion: "28.0",
            targetBuild: "28A100",
            coreDeviceXcodeMajorVersion: 27
        )
        let inspector = makeInspector(fixture)
        let xcode = try inspector.validatedTargetXcode()

        do {
            _ = try inspector.validatedLegacyHost(for: xcode)
            Issue.record("expected mismatched CoreDevice generation to fail")
        } catch let error as CLIError {
            #expect(error.identifier == "core-device-bundle")
        }
    }

    @Test func simulatorCoreDevicePluginMustMatchTheSelectedXcodeMajor() throws {
        let fixture = try InstallationFixture(
            targetVersion: "28.0",
            targetBuild: "28A100",
            simulatorCoreDevicePluginXcodeMajorVersion: 27
        )
        let inspector = makeInspector(fixture)
        let xcode = try inspector.validatedTargetXcode()

        do {
            _ = try inspector.validatedLegacyHost(for: xcode)
            Issue.record("expected mismatched plugin generation to fail")
        } catch let error as CLIError {
            #expect(error.identifier == "simulator-core-device-plugin-bundle")
        }
    }

    @Test func staleCoreSimulatorVersionIsRejected() throws {
        let fixture = try InstallationFixture(
            coreSimulatorBundleVersion: "1171.5"
        )
        let inspector = makeInspector(fixture)
        let xcode = try inspector.validatedTargetXcode()

        do {
            _ = try inspector.validatedLegacyHost(for: xcode)
            Issue.record("expected stale CoreSimulator version to fail")
        } catch let error as CLIError {
            #expect(error.identifier == "core-simulator-bundle")
        }
    }

    @Test func staleCoreDeviceVersionIsRejected() throws {
        let fixture = try InstallationFixture(
            coreDeviceBundleVersion: "642.14"
        )
        let inspector = makeInspector(fixture)
        let xcode = try inspector.validatedTargetXcode()

        do {
            _ = try inspector.validatedLegacyHost(for: xcode)
            Issue.record("expected stale CoreDevice version to fail")
        } catch let error as CLIError {
            #expect(error.identifier == "core-device-bundle")
        }
    }

    @Test func simulatorCoreDevicePluginMustMatchCoreSimulatorVersion() throws {
        let fixture = try InstallationFixture(
            simulatorCoreDevicePluginBundleVersion: "1171.5"
        )
        let inspector = makeInspector(fixture)
        let xcode = try inspector.validatedTargetXcode()

        do {
            _ = try inspector.validatedLegacyHost(for: xcode)
            Issue.record("expected stale simulator plugin version to fail")
        } catch let error as CLIError {
            #expect(error.identifier == "simulator-core-device-plugin-bundle")
        }
    }

    @Test func missingWrapperIsRejected() throws {
        let fixture = try InstallationFixture()
        try FileManager.default.removeItem(at: fixture.simctlWrapperURL)
        let inspector = makeInspector(fixture)
        let xcode = try inspector.validatedTargetXcode()

        do {
            _ = try inspector.validatedLegacyHost(for: xcode)
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
            _ = try inspector.validatedLegacyHost(for: xcode)
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
            _ = try inspector.validatedLegacyHost(for: xcode)
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
            _ = try inspector.validatedLegacyHost(for: xcode)
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
            _ = try inspector.validatedLegacyHost(for: xcode)
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
            _ = try inspector.validatedLegacyHost(for: xcode)
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
            _ = try inspector.validatedLegacyHost(for: xcode)
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
                _ = try inspector.validatedLegacyHost(for: xcode)
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
                _ = try inspector.validatedLegacyHost(for: xcode)
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
            commandExecutableURL: fixture.commandExecutableURL,
            coreSimulatorFrameworkURL: fixture.coreSimulatorFrameworkURL,
            coreDeviceFrameworkURL: fixture.coreDeviceFrameworkURL,
            signatureValidator: .acceptingTestFixtures
        )

        let xcode = try inspector.validatedTargetXcode()
        _ = try inspector.validatedLegacyHost(for: xcode)

        #expect(
            runner.calls
                == [
                    FakeSystemCommandRunner.Call(
                        executable: fixture.legacyHostExecutableURL,
                        arguments: [
                            "--validate-runtime",
                            "--xcode",
                            fixture.targetXcodeURL.path,
                        ]
                    ),
                ]
        )
    }

    @Test func packagedHostIsResolvedRelativeToTheCommandBinary() throws {
        let fixture = try InstallationFixture()
        let inspector = makeInspector(fixture)

        #expect(try inspector.legacyHostApplicationURL() == fixture.legacyHostURL)
    }

    @Test func packagedHostUsesTheResolvedCommandBinaryBehindASymlink() throws {
        let fixture = try InstallationFixture()
        let symlinkURL = fixture.directory.url.appendingPathComponent(
            "shim/bin/\(ToolConstants.name)"
        )
        try FileManager.default.createDirectory(
            at: symlinkURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: symlinkURL,
            withDestinationURL: fixture.commandExecutableURL
        )
        let inspector = InstallationInspector(
            runner: FakeSystemCommandRunner(),
            environment: ["DEVELOPER_DIR": fixture.developerDirectoryURL.path],
            commandExecutableURL: symlinkURL,
            coreSimulatorFrameworkURL: fixture.coreSimulatorFrameworkURL,
            coreDeviceFrameworkURL: fixture.coreDeviceFrameworkURL,
            signatureValidator: .acceptingTestFixtures
        )

        #expect(try inspector.legacyHostApplicationURL() == fixture.legacyHostURL)
    }

    @Test func missingPackagedHostFailsBeforeLegacyModeCanBeUsed() throws {
        let fixture = try InstallationFixture(includeLegacyHost: false)
        let inspector = makeInspector(fixture)
        let xcode = try inspector.validatedTargetXcode()

        do {
            _ = try inspector.validatedLegacyHost(for: xcode)
            Issue.record("expected missing packaged host to fail")
        } catch let error as CLIError {
            #expect(error.identifier == "legacy-host-bundle")
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
            commandExecutableURL: fixture.commandExecutableURL,
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
