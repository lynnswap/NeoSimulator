import Darwin

@main
struct XcodeSimulatorHostMain {
    @MainActor
    static func main() async {
        Darwin.exit(await runXcodeSimulatorHostCommand(CommandLine.arguments))
    }
}
