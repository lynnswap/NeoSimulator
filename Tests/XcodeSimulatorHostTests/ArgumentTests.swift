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
        #expect(!help.contains("legacy-xcode"))
    }

    @Test func statusParsesWithoutAnOverride() throws {
        #expect(
            try parseXcodeSimulatorHostCommand([ToolConstants.name, "status"])
                == .status(.compact)
        )
    }

    @Test func verboseStatusParses() throws {
        #expect(
            try parseXcodeSimulatorHostCommand([
                ToolConstants.name, "status", "--verbose",
            ]) == .status(.verbose)
        )
    }

    @Test func legacyUsesThePackagedHostWithoutAnOverride() throws {
        let command = try parseXcodeSimulatorHostCommand([
            ToolConstants.name,
            "use",
            "legacy",
        ])

        #expect(command == .use(mode: .legacy))
    }

    @Test func deviceHubAndRestoreParse() throws {
        #expect(
            try parseXcodeSimulatorHostCommand([
                ToolConstants.name, "use", "device-hub",
            ]) == .use(mode: .deviceHub)
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

    @Test func removedLegacyXcodeOptionsAreRejected() {
        #expect(throws: (any Error).self) {
            _ = try parseXcodeSimulatorHostCommand([
                ToolConstants.name,
                "use",
                "legacy",
                "--legacy-xcode",
                "/Applications/Xcode_26.app",
            ])
        }
        #expect(throws: (any Error).self) {
            _ = try parseXcodeSimulatorHostCommand([
                ToolConstants.name,
                "status",
                "--legacy-xcode",
                "/Applications/Xcode_26.app",
            ])
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
