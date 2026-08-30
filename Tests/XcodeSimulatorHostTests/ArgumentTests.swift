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
        #expect(help.contains("neo"))
        #expect(help.contains("legacy"))
        #expect(help.contains("device-hub"))
        #expect(help.contains("DEVELOPER_DIR"))
        #expect(help.contains("Xcode can remain open"))
        #expect(!help.contains("Quit all Xcode"))
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
            ]) == .status(.verbose(legacyXcodeURL: nil))
        )
    }

    @Test func neoAndLegacyParseAsDistinctHosts() throws {
        #expect(
            try parseXcodeSimulatorHostCommand([
                ToolConstants.name,
                "use",
                "neo",
            ]) == .use(.neo)
        )

        let command = try parseXcodeSimulatorHostCommand([
            ToolConstants.name,
            "use",
            "legacy",
        ])

        #expect(command == .use(.legacy(xcodeURL: nil)))
    }

    @Test func deviceHubAndRestoreParse() throws {
        #expect(
            try parseXcodeSimulatorHostCommand([
                ToolConstants.name, "use", "device-hub",
            ]) == .use(.deviceHub)
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

    @Test func legacyXcodeOverridesRequireAbsolutePaths() throws {
        let path = "/Applications/Xcode_26.app"
        let expectedURL = URL(
            fileURLWithPath: path,
            isDirectory: true
        ).standardizedFileURL
        #expect(
            try parseXcodeSimulatorHostCommand([
                ToolConstants.name,
                "use",
                "legacy",
                "--legacy-xcode",
                path,
            ]) == .use(.legacy(xcodeURL: expectedURL))
        )
        #expect(
            try parseXcodeSimulatorHostCommand([
                ToolConstants.name,
                "status",
                "--legacy-xcode",
                path,
            ]) == .status(
                .verbose(legacyXcodeURL: expectedURL)
            )
        )

        #expect(throws: (any Error).self) {
            _ = try parseXcodeSimulatorHostCommand([
                ToolConstants.name,
                "use",
                "legacy",
                "--legacy-xcode",
                "Xcode_26.app",
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
