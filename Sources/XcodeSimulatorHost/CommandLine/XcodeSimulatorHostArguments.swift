import ArgumentParser
import Foundation

struct AbsolutePath: ExpressibleByArgument, Equatable {
    let url: URL

    init?(argument: String) {
        let path = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") else {
            return nil
        }
        url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }
}

struct XcodeSimulatorHostArguments: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: ToolConstants.name,
        abstract: "Select the simulator UI host used with Xcode 27 or later.",
        discussion: """
            Use 'xcode-simulator-host use neo' for the packaged CoreSimulator host,
            'use legacy' for Simulator.app from Xcode 26, or 'use device-hub'
            for Xcode's default host.

            Xcode is resolved from DEVELOPER_DIR or xcode-select. The managed
            com.apple.dt.Xcode preference is shared by every installed Xcode.
            Xcode can remain open while modes change.
            """,
        version: ToolConstants.version,
        subcommands: [StatusArguments.self, UseArguments.self, RestoreArguments.self]
    )
}

struct StatusArguments: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show whether the next Run uses Device Hub or CoreSimulator."
    )

    @Flag(
        help: "Show Xcode installations, preferences, restoration state, and running processes."
    )
    var verbose = false

    @Option(
        name: .customLong("legacy-xcode"),
        help: "Inspect a specific Xcode 26 application as the legacy Simulator host.",
        completion: .file(extensions: ["app"])
    )
    var legacyXcode: AbsolutePath?
}

struct UseArguments: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "use",
        abstract: "Select a simulator host mode.",
        subcommands: [
            UseNeoArguments.self,
            UseLegacyArguments.self,
            UseDeviceHubArguments.self,
        ]
    )
}

struct UseNeoArguments: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "neo",
        abstract: "Use CoreSimulator with the packaged Neo host."
    )
}

struct UseLegacyArguments: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "legacy",
        abstract: "Use CoreSimulator with Simulator.app from Xcode 26."
    )

    @Option(
        name: .customLong("legacy-xcode"),
        help: "Use a specific Xcode 26 application as the legacy Simulator host.",
        completion: .file(extensions: ["app"])
    )
    var legacyXcode: AbsolutePath?
}

struct UseDeviceHubArguments: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "device-hub",
        abstract: "Use the selected Xcode's default Device Hub route."
    )
}

struct RestoreArguments: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restore",
        abstract: "Restore the exact preferences captured before first use."
    )

    @Flag(
        help: "Overwrite a conflicting Boolean state with the saved original values."
    )
    var force = false
}

enum StatusOutput: Equatable {
    case compact
    case verbose(legacyXcodeURL: URL?)
}

enum XcodeSimulatorHostCommand: Equatable {
    case status(StatusOutput)
    case use(HostRequest)
    case restore(force: Bool)
}

func parseXcodeSimulatorHostCommand(_ arguments: [String]) throws -> XcodeSimulatorHostCommand {
    var parsed = try XcodeSimulatorHostArguments.parseAsRoot(Array(arguments.dropFirst()))
    switch parsed {
    case let command as StatusArguments:
        if command.verbose || command.legacyXcode != nil {
            return .status(.verbose(legacyXcodeURL: command.legacyXcode?.url))
        }
        return .status(.compact)
    case is UseNeoArguments:
        return .use(.neo)
    case let command as UseLegacyArguments:
        return .use(.legacy(xcodeURL: command.legacyXcode?.url))
    case is UseDeviceHubArguments:
        return .use(.deviceHub)
    case let command as RestoreArguments:
        return .restore(force: command.force)
    default:
        try parsed.run()
        preconditionFailure("ArgumentParser returned an unhandled command that did not exit")
    }
}
