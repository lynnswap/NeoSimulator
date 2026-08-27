import Foundation

struct CommandOutput: Equatable {
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

    func run(executable: URL, arguments: [String]) throws -> CommandOutput {
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
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        do {
            try process.run()
            process.waitUntilExit()
            try stdoutHandle.close()
            try stderrHandle.close()
            handlesAreOpen = false
        } catch {
            throw CLIError.io(
                "command-execution",
                "could not run \(executable.path): \(error.localizedDescription)"
            )
        }

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
