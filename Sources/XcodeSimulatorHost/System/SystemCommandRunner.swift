import Foundation
import Darwin
import Synchronization

struct CommandOutput: Equatable, Sendable {
    let terminationStatus: Int32
    let stdout: Data
    let stderr: Data

    var stdoutText: String {
        String(decoding: stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var stderrText: String {
        String(decoding: stderr, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

protocol CommandRunning {
    func run(executable: URL, arguments: [String]) throws -> CommandOutput
}

struct SystemCommandRunner: CommandRunning {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func runSimctl(
        xcodeURL: URL,
        arguments: [String],
        deviceSetPath: String? = nil,
        coreSimulatorFrameworkURL: URL = URL(fileURLWithPath: ToolConstants.coreSimulatorFrameworkPath, isDirectory: true)
    ) throws -> CommandOutput {
        var environment = ProcessInfo.processInfo.environment
        environment["DEVELOPER_DIR"] = xcodeURL.appendingPathComponent("Contents/Developer", isDirectory: true).path
        // Xcode's shell wrapper can install global developer components before any command, including list.
        return try run(executable: coreSimulatorFrameworkURL.appendingPathComponent(ToolConstants.simctlBinaryPath),
                       arguments: deviceSetPath.map { ["--set", $0] + arguments } ?? arguments, environment: environment)
    }

    func runDevicectl(xcodeURL: URL, arguments: [String]) throws -> CommandOutput {
        var environment = ProcessInfo.processInfo.environment
        environment["DEVELOPER_DIR"] = xcodeURL.appendingPathComponent("Contents/Developer", isDirectory: true).path
        return try run(executable: URL(fileURLWithPath: "/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/Resources/bin/devicectl"),
                       arguments: arguments, environment: environment)
    }

    func run(executable: URL, arguments: [String]) throws -> CommandOutput {
        try run(executable: executable, arguments: arguments, environment: nil)
    }

    @concurrent
    static func runCancellable(executable: URL, arguments: [String], environment: [String: String]? = nil) async throws -> CommandOutput {
        let cancellation = CommandCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try SystemCommandRunner().run(executable: executable, arguments: arguments,
                                                 environment: environment, cancellation: cancellation)
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func run(executable: URL, arguments: [String], environment: [String: String]?,
                     cancellation: CommandCancellation? = nil) throws -> CommandOutput {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("\(ToolConstants.name)-\(UUID().uuidString)", isDirectory: true)

        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw CLIError.cannotCreate(
                "temporary-directory",
                "could not create command output directory: \(error.localizedDescription)"
            )
        }
        defer {
            try? fileManager.removeItem(at: directory)
        }

        let stdoutURL = directory.appendingPathComponent("stdout")
        let stderrURL = directory.appendingPathComponent("stderr")
        guard fileManager.createFile(
            atPath: stdoutURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ), fileManager.createFile(
            atPath: stderrURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CLIError.cannotCreate(
                "temporary-output",
                "could not create command output files"
            )
        }

        let stdoutHandle: FileHandle
        let stderrHandle: FileHandle
        do {
            stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
            stderrHandle = try FileHandle(forWritingTo: stderrURL)
        } catch {
            throw CLIError.io(
                "temporary-output",
                "could not open command output files: \(error.localizedDescription)"
            )
        }

        var handlesAreOpen = true
        defer {
            if handlesAreOpen {
                try? stdoutHandle.close()
                try? stderrHandle.close()
            }
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        do {
            if let cancellation { try cancellation.launch(process) }
            else { try process.run() }
            process.waitUntilExit()
            try stdoutHandle.close()
            try stderrHandle.close()
            handlesAreOpen = false
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CLIError.io(
                "command-execution",
                "could not run \(executable.path): \(error.localizedDescription)"
            )
        }
        try cancellation?.finish()

        do {
            return CommandOutput(
                terminationStatus: process.terminationStatus,
                stdout: try Data(contentsOf: stdoutURL),
                stderr: try Data(contentsOf: stderrURL)
            )
        } catch {
            throw CLIError.io(
                "command-output",
                "could not read output from \(executable.path): \(error.localizedDescription)"
            )
        }
    }
}

private final class CommandCancellation: Sendable {
    private struct State {
        var process: Process?
        var cancelled = false
        var failure: POSIXError?
    }
    private let state = Mutex(State())

    func launch(_ process: Process) throws {
        try state.withLock {
            if $0.cancelled { throw CancellationError() }
            try process.run()
            $0.process = process
        }
    }

    func cancel() {
        state.withLock {
            $0.cancelled = true
            // Only the owned request is killed; its guest may already have been forcibly stopped.
            if let process = $0.process, process.isRunning,
               kill(process.processIdentifier, SIGKILL) != 0, errno != ESRCH {
                $0.failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    func finish() throws {
        try state.withLock {
            $0.process = nil
            if let failure = $0.failure { throw failure }
            if $0.cancelled { throw CancellationError() }
        }
    }
}
