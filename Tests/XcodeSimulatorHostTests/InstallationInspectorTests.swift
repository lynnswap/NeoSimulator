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
            targetBuild: "28A100"
        )
        let inspector = makeInspector(fixture)

        let xcode = try inspector.validatedTargetXcode()
        let host = try inspector.validatedLegacyHost(for: xcode)

        #expect(xcode.version == (try ToolVersion("28.0")))
        #expect(host.xcode == xcode)
    }

    @Test func selectedXcodeMustBeIntactAppleSignedCode() throws {
        let fixture = try InstallationFixture()
        let inspector = InstallationInspector(
            runner: FakeSystemCommandRunner(),
            environment: ["DEVELOPER_DIR": fixture.developerDirectoryURL.path],
            commandExecutableURL: fixture.commandExecutableURL,
            coreSimulatorFrameworkURL: fixture.coreSimulatorFrameworkURL,
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

    @Test func rejectsChangedSimulatorKitSurface() throws {
        let fixture = try InstallationFixture(includeSimulatorKitSurface: false)
        let inspector = makeInspector(fixture)
        let xcode = try inspector.validatedTargetXcode()

        do {
            _ = try inspector.validatedLegacyHost(for: xcode)
            Issue.record("expected changed SimulatorKit surface to fail")
        } catch let error as CLIError {
            #expect(error.identifier == "simulator-kit-surface")
        }
    }

    @Test func rejectsChangedIDEPlaygroundSimulatorSurface() throws {
        let fixture = try InstallationFixture(
            includeIDEPlaygroundSimulatorSurface: false
        )
        let inspector = makeInspector(fixture)
        let xcode = try inspector.validatedTargetXcode()

        do {
            _ = try inspector.validatedLegacyHost(for: xcode)
            Issue.record("expected changed IDEPlaygroundSimulator surface to fail")
        } catch let error as CLIError {
            #expect(error.identifier == "ide-playground-simulator-surface")
        }
    }

    @Test func rejectsChangedCoreSimulatorSurface() throws {
        let fixture = try InstallationFixture(includeCoreSimulatorSurface: false)
        let inspector = makeInspector(fixture)
        let xcode = try inspector.validatedTargetXcode()

        do {
            _ = try inspector.validatedLegacyHost(for: xcode)
            Issue.record("expected changed CoreSimulator surface to fail")
        } catch let error as CLIError {
            #expect(error.identifier == "core-simulator-surface")
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

    private func makeInspector(_ fixture: InstallationFixture) -> InstallationInspector {
        InstallationInspector(
            runner: FakeSystemCommandRunner(),
            environment: ["DEVELOPER_DIR": fixture.developerDirectoryURL.path],
            commandExecutableURL: fixture.commandExecutableURL,
            coreSimulatorFrameworkURL: fixture.coreSimulatorFrameworkURL,
            signatureValidator: .acceptingTestFixtures
        )
    }
}
