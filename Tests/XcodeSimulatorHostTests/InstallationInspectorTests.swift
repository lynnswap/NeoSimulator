import Foundation
import Testing

@testable import XcodeSimulatorHost

@Suite
struct InstallationInspectorTests {
    @Test func validatesTheSelectedXcodeAndHiddenKey() throws {
        let fixture = try InstallationFixture()
        let runner = FakeSystemCommandRunner()
        let inspector = InstallationInspector(
            runner: runner,
            environment: ["DEVELOPER_DIR": fixture.developerDirectoryURL.path],
            legacySearchRoots: [fixture.applicationsURL],
            signatureValidator: .acceptingTestFixtures
        )

        let xcode = try inspector.validatedTargetXcode()
        #expect(xcode.applicationURL == fixture.targetXcodeURL)
        #expect(xcode.version == (try ToolVersion("27.0")))
        #expect(xcode.buildVersion == "27A5252f")
    }

    @Test func rejectsAnUnverifiedXcodeMajor() throws {
        let fixture = try InstallationFixture(targetVersion: "28.0")
        let inspector = InstallationInspector(
            runner: FakeSystemCommandRunner(),
            environment: ["DEVELOPER_DIR": fixture.developerDirectoryURL.path],
            legacySearchRoots: [fixture.applicationsURL],
            signatureValidator: .acceptingTestFixtures
        )

        do {
            _ = try inspector.validatedTargetXcode()
            Issue.record("expected Xcode 28 to be rejected")
        } catch let error as CLIError {
            #expect(error.identifier == "unsupported-xcode")
            #expect(error.category == .unavailable)
        }
    }

    @Test func rejectsXcodeWhenTheHiddenKeyDisappears() throws {
        let fixture = try InstallationFixture(includeHiddenKey: false)
        let inspector = InstallationInspector(
            runner: FakeSystemCommandRunner(),
            environment: ["DEVELOPER_DIR": fixture.developerDirectoryURL.path],
            legacySearchRoots: [fixture.applicationsURL],
            signatureValidator: .acceptingTestFixtures
        )

        do {
            _ = try inspector.validatedTargetXcode()
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
        let inspector = InstallationInspector(
            runner: FakeSystemCommandRunner(),
            environment: ["DEVELOPER_DIR": fixture.developerDirectoryURL.path],
            legacySearchRoots: [fixture.applicationsURL],
            signatureValidator: .acceptingTestFixtures
        )

        do {
            _ = try inspector.validatedTargetXcode()
            Issue.record("expected missing Device Hub executable to fail")
        } catch let error as CLIError {
            #expect(error.identifier == "device-hub-executable")
        }
    }

    @Test func rejectsXcodeWhenTheDeviceHubKeyDisappears() throws {
        let fixture = try InstallationFixture(includeDeviceHubKey: false)
        let inspector = InstallationInspector(
            runner: FakeSystemCommandRunner(),
            environment: ["DEVELOPER_DIR": fixture.developerDirectoryURL.path],
            legacySearchRoots: [fixture.applicationsURL],
            signatureValidator: .acceptingTestFixtures
        )

        do {
            _ = try inspector.validatedTargetXcode()
            Issue.record("expected missing Device Hub key to fail")
        } catch let error as CLIError {
            #expect(error.identifier == "device-hub-preference-key")
        }
    }

    @Test func choosesTheHighestValidatedXcode26() throws {
        let fixture = try InstallationFixture(
            legacyVersions: [
                ("Xcode_26.3.app", "26.3", "17C529"),
                ("Xcode_26.5.app", "26.5", "17F42"),
                ("Xcode.app", "26.6", "17F109"),
            ]
        )
        let inspector = InstallationInspector(
            runner: FakeSystemCommandRunner(),
            environment: ["DEVELOPER_DIR": fixture.developerDirectoryURL.path],
            legacySearchRoots: [fixture.applicationsURL],
            signatureValidator: .acceptingTestFixtures
        )

        let simulator = try inspector.legacySimulator(explicitXcodeURL: nil)
        #expect(simulator.xcode.version == (try ToolVersion("26.6")))
        #expect(simulator.xcode.buildVersion == "17F109")
        #expect(simulator.applicationURL.path.hasSuffix(ToolConstants.simulatorPath))
    }

    @Test func explicitLegacyXcodeMustBeVersion26() throws {
        let fixture = try InstallationFixture()
        let inspector = InstallationInspector(
            runner: FakeSystemCommandRunner(),
            environment: ["DEVELOPER_DIR": fixture.developerDirectoryURL.path],
            legacySearchRoots: [fixture.applicationsURL],
            signatureValidator: .acceptingTestFixtures
        )

        do {
            _ = try inspector.legacySimulator(explicitXcodeURL: fixture.targetXcodeURL)
            Issue.record("expected Xcode 27 legacy host to fail")
        } catch let error as CLIError {
            #expect(error.identifier == "legacy-xcode-version")
        }
    }

    @Test func legacySimulatorMustHaveAnAppleCodeSignature() throws {
        let fixture = try InstallationFixture()
        let inspector = InstallationInspector(
            runner: FakeSystemCommandRunner(),
            environment: ["DEVELOPER_DIR": fixture.developerDirectoryURL.path],
            legacySearchRoots: [fixture.applicationsURL],
            signatureValidator: CodeSignatureValidator { _, _ in
                throw CLIError.unavailable(
                    "code-signature",
                    "injected invalid signature"
                )
            }
        )

        do {
            _ = try inspector.legacySimulator(
                explicitXcodeURL: fixture.legacyXcodeURL
            )
            Issue.record("expected invalid code signature to fail")
        } catch let error as CLIError {
            #expect(error.identifier == "code-signature")
        }
    }

    @Test func versionComparisonPadsMissingComponents() throws {
        #expect(try ToolVersion("26.6") == ToolVersion("26.6.0"))
        #expect(try ToolVersion("26.6.1") > ToolVersion("26.6"))
        #expect(try ToolVersion("27.0") > ToolVersion("26.99"))
    }
}
