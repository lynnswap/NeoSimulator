import ArgumentParser
import Foundation

@MainActor
struct XcodeSimulatorHostApplication {
    let controller: HostModeController

    static func live() throws -> XcodeSimulatorHostApplication {
        let runner = SystemCommandRunner()
        let defaultsStore = DefaultsStore(runner: runner)
        let receiptStore = try ReceiptStore()
        let inspector = InstallationInspector(runner: runner)
        let controller = HostModeController(
            defaultsStore: defaultsStore,
            receiptStore: receiptStore,
            installationInspector: inspector,
            workspace: .live
        )
        return XcodeSimulatorHostApplication(controller: controller)
    }

    func run(_ command: XcodeSimulatorHostCommand) async throws -> (String, Int32) {
        switch command {
        case .status(.compact):
            let status = try controller.routeStatus()
            let exitCode = status.receiptStatus.hasConflict
                ? CLIError.Category.configuration.rawValue
                : 0
            return (status.rendered, exitCode)

        case .status(.verbose(let legacyXcode)):
            let status = try controller.status(explicitLegacyXcodeURL: legacyXcode)
            let exitCode = status.routeStatus.receiptStatus.hasConflict
                ? CLIError.Category.configuration.rawValue
                : 0
            return (status.rendered, exitCode)

        case .use(let mode, let legacyXcode):
            let report = try await controller.use(
                mode: mode,
                explicitLegacyXcodeURL: legacyXcode
            )
            return (report.rendered, 0)

        case .restore(let force):
            return (try controller.restore(force: force).rendered, 0)
        }
    }
}

@MainActor
func runXcodeSimulatorHostCommand(
    _ arguments: [String],
    applicationProvider: @MainActor () throws -> XcodeSimulatorHostApplication =
        XcodeSimulatorHostApplication.live,
    outputLogger: (String) -> Void = logStandardOutput,
    errorLogger: (String) -> Void = logStandardError
) async -> Int32 {
    let command: XcodeSimulatorHostCommand
    do {
        command = try parseXcodeSimulatorHostCommand(arguments)
    } catch {
        let message = XcodeSimulatorHostArguments.fullMessage(for: error)
        let exitCode = XcodeSimulatorHostArguments.exitCode(for: error).rawValue
        let logger = exitCode == 0 ? outputLogger : errorLogger
        logger(message)
        return exitCode
    }

    do {
        let application = try applicationProvider()
        let result = try await application.run(command)
        outputLogger(result.0)
        return result.1
    } catch let error as CLIError {
        errorLogger(error.rendered)
        return error.category.rawValue
    } catch {
        errorLogger(
            CLIError.software(
                "unexpected-error",
                error.localizedDescription
            ).rendered
        )
        return CLIError.Category.software.rawValue
    }
}

private func logStandardOutput(_ message: String) {
    print(message)
}

private func logStandardError(_ message: String) {
    guard let data = "\(message)\n".data(using: .utf8) else {
        return
    }
    FileHandle.standardError.write(data)
}
