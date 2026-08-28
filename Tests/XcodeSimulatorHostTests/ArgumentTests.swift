import ArgumentParser
import Foundation
import Testing

@testable import XcodeSimulatorHost

@Suite
struct ArgumentTests {
    @Test func publicHelpContainsTheSupportedCommands() {
        let help = XcodeSimulatorHostArguments.helpMessage(columns: 100)

        #expect(help.contains("status"))
        #expect(help.contains("use"))
        #expect(help.contains("restore"))
        #expect(help.contains("DEVELOPER_DIR"))
        #expect(help.contains("Xcode can remain open"))
        #expect(!help.contains("Quit all Xcode"))
    }

    @Test func statusParsesWithoutAnOverride() throws {
        #expect(
            try parseXcodeSimulatorHostCommand([ToolConstants.name, "status"])
                == .status(legacyXcode: nil)
        )
    }

    @Test func legacyParsesAnAbsoluteXcodePath() throws {
        let command = try parseXcodeSimulatorHostCommand([
            ToolConstants.name,
            "use",
            "legacy",
            "--legacy-xcode",
            "/Applications/Xcode 26.app",
        ])

        #expect(
            command == .use(
                mode: .legacy,
                legacyXcode: URL(
                    fileURLWithPath: "/Applications/Xcode 26.app",
                    isDirectory: true
                ).standardizedFileURL
            )
        )
    }

    @Test func deviceHubAndRestoreParse() throws {
        #expect(
            try parseXcodeSimulatorHostCommand([
                ToolConstants.name, "use", "device-hub",
            ]) == .use(mode: .deviceHub, legacyXcode: nil)
        )
        #expect(
            try parseXcodeSimulatorHostCommand([
                ToolConstants.name, "restore",
            ]) == .restore(force: false)
        )
        #expect(
            try parseXcodeSimulatorHostCommand([
                ToolConstants.name, "restore", "--force",
            ]) == .restore(force: true)
        )
    }

    @Test func relativeLegacyXcodePathFailsValidation() {
        do {
            _ = try parseXcodeSimulatorHostCommand([
                ToolConstants.name,
                "use",
                "legacy",
                "--legacy-xcode",
                "Xcode.app",
            ])
            Issue.record("expected relative path to fail")
        } catch {
            let message = XcodeSimulatorHostArguments.fullMessage(for: error)
            #expect(message.contains("Usage: xcode-simulator-host use legacy"))
        }
    }

    @Test func unknownModeUsesArgumentParserDiagnostics() {
        #expect(throws: (any Error).self) {
            try parseXcodeSimulatorHostCommand([
                ToolConstants.name, "use", "unknown",
            ])
        }
    }

    @MainActor
    @Test func helpDoesNotConstructTheLiveApplication() async {
        var didConstructApplication = false
        var output: [String] = []
        let status = await runXcodeSimulatorHostCommand(
            [ToolConstants.name, "--help"],
            applicationProvider: {
                didConstructApplication = true
                throw CLIError.software("unexpected", "unexpected")
            },
            outputLogger: { output.append($0) },
            errorLogger: { _ in }
        )

        #expect(status == 0)
        #expect(!didConstructApplication)
        #expect(output.joined(separator: "\n").contains("USAGE"))
    }

    @MainActor
    @Test func versionDoesNotConstructTheLiveApplication() async {
        var didConstructApplication = false
        var output: [String] = []
        let status = await runXcodeSimulatorHostCommand(
            [ToolConstants.name, "--version"],
            applicationProvider: {
                didConstructApplication = true
                throw CLIError.software("unexpected", "unexpected")
            },
            outputLogger: { output.append($0) },
            errorLogger: { _ in }
        )

        #expect(status == 0)
        #expect(!didConstructApplication)
        #expect(output == [ToolConstants.version])
    }
}
