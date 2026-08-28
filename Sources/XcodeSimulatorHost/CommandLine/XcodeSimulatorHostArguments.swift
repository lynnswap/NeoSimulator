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
        abstract: "Select the simulator UI host used with Xcode 27.",
        discussion: """
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
        abstract: "Show the selected Xcode, managed preferences, and restoration receipt."
    )

    @Option(
        name: .customLong("legacy-xcode"),
        help: "Inspect a specific Xcode 26 application as the legacy host.",
        completion: .file(extensions: ["app"])
    )
    var legacyXcode: AbsolutePath?
}

struct UseArguments: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "use",
        abstract: "Select a simulator host mode.",
        subcommands: [UseLegacyArguments.self, UseDeviceHubArguments.self]
    )
}

struct UseLegacyArguments: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "legacy",
        abstract: "Bypass Device Hub and open the Simulator from Xcode 26."
    )

    @Option(
        name: .customLong("legacy-xcode"),
        help: "Use a specific Xcode 26 application as the legacy host.",
        completion: .file(extensions: ["app"])
    )
    var legacyXcode: AbsolutePath?
}

struct UseDeviceHubArguments: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "device-hub",
        abstract: "Use Xcode 27's default Device Hub route."
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

enum XcodeSimulatorHostCommand: Equatable {
    case status(legacyXcode: URL?)
    case use(mode: HostMode, legacyXcode: URL?)
    case restore(force: Bool)
}

func parseXcodeSimulatorHostCommand(_ arguments: [String]) throws -> XcodeSimulatorHostCommand {
    var parsed = try XcodeSimulatorHostArguments.parseAsRoot(Array(arguments.dropFirst()))
    switch parsed {
    case let command as StatusArguments:
        return .status(legacyXcode: command.legacyXcode?.url)
    case let command as UseLegacyArguments:
        return .use(mode: .legacy, legacyXcode: command.legacyXcode?.url)
    case is UseDeviceHubArguments:
        return .use(mode: .deviceHub, legacyXcode: nil)
    case let command as RestoreArguments:
        return .restore(force: command.force)
    default:
        try parsed.run()
        preconditionFailure("ArgumentParser returned an unhandled command that did not exit")
    }
}
