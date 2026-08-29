import ArgumentParser

struct XcodeSimulatorHostArguments: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: ToolConstants.name,
        abstract: "Select the simulator UI host used with Xcode 27 or later.",
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
        abstract: "Show whether the next Run uses Device Hub or CoreSimulator."
    )

    @Flag(
        help: "Show Xcode installations, preferences, restoration state, and running processes."
    )
    var verbose = false
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
        abstract: "Use CoreSimulator with the packaged standalone host."
    )
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
    case verbose
}

enum XcodeSimulatorHostCommand: Equatable {
    case status(StatusOutput)
    case use(mode: HostMode)
    case restore(force: Bool)
}

func parseXcodeSimulatorHostCommand(_ arguments: [String]) throws -> XcodeSimulatorHostCommand {
    var parsed = try XcodeSimulatorHostArguments.parseAsRoot(Array(arguments.dropFirst()))
    switch parsed {
    case let command as StatusArguments:
        if command.verbose {
            return .status(.verbose)
        }
        return .status(.compact)
    case is UseLegacyArguments:
        return .use(mode: .legacy)
    case is UseDeviceHubArguments:
        return .use(mode: .deviceHub)
    case let command as RestoreArguments:
        return .restore(force: command.force)
    default:
        try parsed.run()
        preconditionFailure("ArgumentParser returned an unhandled command that did not exit")
    }
}
