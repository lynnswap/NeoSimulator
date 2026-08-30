import Foundation
import Security
import Testing

@testable import XcodeSimulatorHost

@Suite
struct CodeSignatureValidatorTests {
    @Test func liveValidationAcceptsApplePlatformSigningAndExactIdentity() throws {
        let calculatorURL = URL(
            fileURLWithPath: "/System/Applications/Calculator.app",
            isDirectory: true
        )
        try requireValidApplication(
            at: calculatorURL,
            satisfying: #"identifier "com.apple.calculator" and anchor apple"#
        )

        try CodeSignatureValidator.live.validateAppleApplication(
            calculatorURL,
            "com.apple.calculator"
        )
    }

    @Test func liveValidationRejectsAnIdentityMismatch() throws {
        let calculatorURL = URL(
            fileURLWithPath: "/System/Applications/Calculator.app",
            isDirectory: true
        )
        try requireValidApplication(
            at: calculatorURL,
            satisfying: #"identifier "com.apple.calculator" and anchor apple"#
        )

        #expect(throws: CLIError.self) {
            try CodeSignatureValidator.live.validateAppleApplication(
                calculatorURL,
                "com.example.NotCalculator"
            )
        }
    }

    @Test func liveValidationRejectsAdHocSignedApplications() throws {
        let directory = try TemporaryTestDirectory()
        let applicationURL = directory.url.appendingPathComponent(
            "AdHoc.app",
            isDirectory: true
        )
        let contentsURL = applicationURL.appendingPathComponent(
            "Contents",
            isDirectory: true
        )
        let executableURL = contentsURL.appendingPathComponent(
            "MacOS/AdHoc",
            isDirectory: false
        )
        try FileManager.default.createDirectory(
            at: executableURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/true"),
            to: executableURL
        )
        let info = [
            "CFBundleIdentifier": "com.example.AdHoc",
            "CFBundleExecutable": "AdHoc",
            "CFBundlePackageType": "APPL",
        ]
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try infoData.write(
            to: contentsURL.appendingPathComponent("Info.plist")
        )
        try runCodeSign(
            ["--force", "--sign", "-", applicationURL.path]
        )
        try requireValidApplication(at: applicationURL)

        #expect(throws: CLIError.self) {
            try CodeSignatureValidator.live.validateAppleApplication(
                applicationURL,
                "com.example.AdHoc"
            )
        }
    }

    @Test(
        .enabled(
            if: macAppStoreFixture != nil,
            "Set NEOSIMULATOR_TEST_MAC_APP_STORE_APPLICATION and NEOSIMULATOR_TEST_MAC_APP_STORE_IDENTIFIER to run against an intact Mac App Store application"
        )
    )
    func liveValidationAcceptsMacAppStoreSigning() throws {
        let fixture = try #require(macAppStoreFixture)
        try requireValidApplication(
            at: fixture.applicationURL,
            satisfying: #"identifier "\#(fixture.identifier)" and anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9] exists"#
        )

        try CodeSignatureValidator.live.validateAppleApplication(
            fixture.applicationURL,
            fixture.identifier
        )
        #expect(throws: CLIError.self) {
            try CodeSignatureValidator.live.validateAppleApplication(
                fixture.applicationURL,
                "com.example.IdentityMismatch"
            )
        }
        #expect(throws: CLIError.self) {
            try CodeSignatureValidator.live.validateAppleCode(
                fixture.applicationURL,
                fixture.identifier
            )
        }
    }

    @Test(
        .enabled(
            if: developerIDFixture != nil,
            "Set NEOSIMULATOR_TEST_DEVELOPER_ID_APPLICATION and NEOSIMULATOR_TEST_DEVELOPER_ID_IDENTIFIER to run against an intact Developer ID application"
        )
    )
    func liveValidationRejectsDeveloperIDSigning() throws {
        let fixture = try #require(developerIDFixture)
        try requireValidApplication(
            at: fixture.applicationURL,
            satisfying: #"identifier "\#(fixture.identifier)" and anchor apple generic"#
        )

        #expect(throws: CLIError.self) {
            try CodeSignatureValidator.live.validateAppleApplication(
                fixture.applicationURL,
                fixture.identifier
            )
        }
    }

    @Test func codeValidationRemainsRestrictedToApplePlatformSigning() {
        #expect(
            AppleCodeValidationPolicy.code.requirement(
                for: "com.example.Code"
            ) == #"identifier "com.example.Code" and anchor apple"#
        )
    }

    @Test func applicationValidationAcceptsOnlyAppleOfficialSigningForms() {
        #expect(
            AppleCodeValidationPolicy.application.requirement(
                for: "com.example.Application"
            ) == #"identifier "com.example.Application" and (anchor apple or (anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9] exists))"#
        )
    }

    @Test func validationPoliciesPreserveIntegrityAndApplicationFormChecks() {
        let commonFlags = kSecCSCheckAllArchitectures
            | kSecCSStrictValidate
            | kSecCSRestrictSymlinks

        #expect(
            AppleCodeValidationPolicy.code.validationFlags.rawValue
                == commonFlags
        )
        #expect(
            AppleCodeValidationPolicy.application.validationFlags.rawValue
                == commonFlags | kSecCSRestrictToAppLike
        )
    }

    @Test func codeRequirementsCompile() {
        for policy in [
            AppleCodeValidationPolicy.code,
            AppleCodeValidationPolicy.application,
        ] {
            var requirement: SecRequirement?
            let status = SecRequirementCreateWithString(
                policy.requirement(for: "com.example.Code") as CFString,
                SecCSFlags(),
                &requirement
            )

            #expect(status == errSecSuccess)
            #expect(requirement != nil)
        }
    }

    private func runCodeSign(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
    }

    private func requireValidApplication(
        at applicationURL: URL,
        satisfying requirementSource: String? = nil
    ) throws {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            applicationURL as CFURL,
            SecCSFlags(),
            &staticCode
        )
        try #require(createStatus == errSecSuccess)
        let code = try #require(staticCode)

        var requirement: SecRequirement?
        if let requirementSource {
            let requirementStatus = SecRequirementCreateWithString(
                requirementSource as CFString,
                SecCSFlags(),
                &requirement
            )
            try #require(requirementStatus == errSecSuccess)
            _ = try #require(requirement)
        }

        let validationStatus = SecStaticCodeCheckValidity(
            code,
            AppleCodeValidationPolicy.application.validationFlags,
            requirement
        )
        try #require(validationStatus == errSecSuccess)
    }
}

private let macAppStoreFixture: (applicationURL: URL, identifier: String)? = {
    let environment = ProcessInfo.processInfo.environment
    guard let applicationPath =
            environment["NEOSIMULATOR_TEST_MAC_APP_STORE_APPLICATION"],
          let identifier =
            environment["NEOSIMULATOR_TEST_MAC_APP_STORE_IDENTIFIER"]
    else {
        return nil
    }
    return (URL(fileURLWithPath: applicationPath, isDirectory: true), identifier)
}()

private let developerIDFixture: (applicationURL: URL, identifier: String)? = {
    let environment = ProcessInfo.processInfo.environment
    guard let applicationPath =
            environment["NEOSIMULATOR_TEST_DEVELOPER_ID_APPLICATION"],
          let identifier =
            environment["NEOSIMULATOR_TEST_DEVELOPER_ID_IDENTIFIER"]
    else {
        return nil
    }
    return (URL(fileURLWithPath: applicationPath, isDirectory: true), identifier)
}()
