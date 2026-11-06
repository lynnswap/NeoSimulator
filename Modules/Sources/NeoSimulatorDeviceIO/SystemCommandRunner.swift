import Darwin
import Dispatch
import Foundation
import Synchronization

package struct CommandOutput: Equatable, Sendable {
    package let terminationStatus: Int32
    package let stdout: Data
    package let stderr: Data

    package init(terminationStatus: Int32, stdout: Data, stderr: Data) {
        self.terminationStatus = terminationStatus
        self.stdout = stdout
        self.stderr = stderr
    }

    package var stdoutText: String {
        String(decoding: stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    package var stderrText: String {
        String(decoding: stderr, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

package enum DeviceToolPaths {
    package static let coreSimulatorFramework = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework"
    package static let coreDeviceFramework = "/Library/Developer/PrivateFrameworks/CoreDevice.framework"
    package static let simctlBinary = "Versions/A/Resources/bin/simctl"
    package static let devicectlBinary = "Versions/A/Resources/bin/devicectl"
    package static let simctl = URL(fileURLWithPath: coreSimulatorFramework, isDirectory: true).appendingPathComponent(simctlBinary)
    package static let devicectl = URL(fileURLWithPath: coreDeviceFramework, isDirectory: true).appendingPathComponent(devicectlBinary)
}

package struct SystemCommand: Sendable {
    package let executable: URL
    package let arguments: [String]
    /// Nil inherits this process's environment.
    package let environment: [String: String]?
    package let policy: CommandPolicy

    package init(executable: URL, arguments: [String], environment: [String: String]? = nil, policy: CommandPolicy) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.policy = policy
    }

    package static func simctl(xcodeURL: URL, arguments: [String], deviceSetPath: String? = nil, policy: CommandPolicy,
                               coreSimulatorFrameworkURL: URL = URL(fileURLWithPath: DeviceToolPaths.coreSimulatorFramework, isDirectory: true)) -> Self {
        // Xcode's shell wrapper can install global developer components before any command, including list.
        Self(executable: coreSimulatorFrameworkURL.appendingPathComponent(DeviceToolPaths.simctlBinary),
             arguments: deviceSetPath.map { ["--set", $0] + arguments } ?? arguments,
             environment: developerEnvironment(xcodeURL), policy: policy)
    }

    /// A nil Xcode leaves the developer directory to this process's environment.
    package static func devicectl(xcodeURL: URL? = nil, arguments: [String], policy: CommandPolicy) -> Self {
        Self(executable: DeviceToolPaths.devicectl, arguments: arguments, environment: xcodeURL.map(developerEnvironment), policy: policy)
    }

    private static func developerEnvironment(_ xcodeURL: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["DEVELOPER_DIR"] = xcodeURL.appendingPathComponent("Contents/Developer", isDirectory: true).path
        return environment
    }
}

/// How a command that returned no output ended, separating what it cannot have changed from what it may have.
/// A command cancelled before its child started throws `CancellationError` instead; it also changed nothing.
package enum CommandFailure: LocalizedError {
    package enum Interruption: Equatable, Sendable {
        case cancelled
        case timedOut(Duration)
    }

    /// No child started, so the command changed nothing.
    case notStarted(executable: URL, underlying: any Error)
    /// The child started and was stopped before it finished, so what it changed is unknown.
    /// `output` is what it wrote until then, or nil when that could not be read.
    case interrupted(executable: URL, cause: Interruption, output: CommandOutput?)
    /// The child ran to its own exit, so what it changed is done, but its output could not be read.
    case outputUnavailable(executable: URL, terminationStatus: Int32, underlying: any Error)
    /// `result` is how the command itself ended, kept beside what could not be stopped, closed or removed.
    case cleanupFailed(executable: URL, result: Result<CommandOutput, any Error>, cleanupErrors: [any Error])

    package var interruption: Interruption? {
        if case .interrupted(_, let cause, _) = self { cause } else { nil }
    }

    package var errorDescription: String? {
        switch self {
        case .notStarted(let executable, let underlying):
            "Could not run \(executable.lastPathComponent): \(underlying.localizedDescription)"
        case .interrupted(let executable, .cancelled, _):
            "\(executable.lastPathComponent) was stopped before it finished, so what it changed is unknown."
        case .interrupted(let executable, .timedOut(let limit), _):
            "\(executable.lastPathComponent) did not finish within \(limit.formatted(.units(width: .wide))) and was stopped, so what it changed is unknown."
        case .outputUnavailable(let executable, let status, let underlying):
            "\(executable.lastPathComponent) finished with status \(status), but its output could not be read: \(underlying.localizedDescription)"
        case .cleanupFailed(let executable, let result, let cleanupErrors):
            {
                let outcome = switch result {
                case .success(let output): "\(executable.lastPathComponent) finished with status \(output.terminationStatus)."
                case .failure(let error): error.localizedDescription
                }
                let details = cleanupErrors.map(\.localizedDescription).joined(separator: " ")
                return "\(outcome) Cleaning up after it failed: \(details)"
            }()
        }
    }
}

extension Error {
    /// Whether the caller stopped the operation. A child stopped after it started leaves its outcome unknown,
    /// unlike a command cancelled before that, so only a caller with nothing left to account for treats them alike.
    package var isCancellation: Bool {
        self is CancellationError || (self as? CommandFailure)?.interruption == .cancelled
    }
}

package protocol CommandRunning {
    /// Throws ``CommandFailure`` when the command returned no output, and returns the output
    /// of any child that ran to its own exit, whatever its status.
    nonisolated(nonsending) func run(_ command: SystemCommand) async throws -> CommandOutput
}

extension CommandRunning {
    /// For a caller that ends its own operation when cancelled and reads current state afterward,
    /// so a stopped child needs no accounting beyond `CancellationError`.
    package nonisolated(nonsending) func runCancellable(_ command: SystemCommand) async throws -> CommandOutput {
        do { return try await run(command) }
        catch let failure as CommandFailure where failure.interruption == .cancelled { throw CancellationError() }
    }
}

package struct SystemCommandRunner: CommandRunning, Sendable {
    /// FileManager documents that its methods can be called from any thread on a shared instance.
    private nonisolated(unsafe) let fileManager: FileManager

    package init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    package nonisolated(nonsending) func run(_ command: SystemCommand) async throws -> CommandOutput {
        let execution = CommandExecution(command: command, fileManager: fileManager)
        guard command.policy.cancellation == .stopsChild else { return try await execution.run() }
        return try await withTaskCancellationHandler {
            try await execution.run()
        } onCancel: {
            execution.cancel()
        }
    }
}

/// Runs commands that only read state, so their owner can stop them all at once without stopping the operations
/// that asked for them. A read that is stopped or cancelled ends as `CancellationError`, since it observed nothing.
package final class CommandReads: CommandRunning, Sendable {
    private struct State {
        var stopped = false
        var running: [UUID: Task<CommandOutput, any Error>] = [:]
    }
    private let runner: SystemCommandRunner
    private let state = Mutex(State())

    package init(runner: SystemCommandRunner = SystemCommandRunner()) {
        self.runner = runner
    }

    package nonisolated(nonsending) func run(_ command: SystemCommand) async throws -> CommandOutput {
        let identifier = UUID()
        let runner = runner
        let read = try state.withLock { state in
            guard !state.stopped else { throw CancellationError() }
            let read = Task { try await runner.runCancellable(command) }
            state.running[identifier] = read
            return read
        }
        defer { _ = state.withLock { $0.running.removeValue(forKey: identifier) } }
        return try await withTaskCancellationHandler { try await read.value } onCancel: { read.cancel() }
    }

    /// Stops the running reads and refuses new ones until ``resume()``.
    package func stop() {
        let running = state.withLock { state in
            state.stopped = true
            return Array(state.running.values)
        }
        // A task's cancellation handlers run here, so never under the lock.
        for read in running { read.cancel() }
    }

    package func resume() {
        state.withLock { $0.stopped = false }
    }
}

/// Owns one child from launch until it is reaped and its output files are gone. The actor runs on its own queue,
/// so the launch, signal and file calls never occupy the caller's executor or the cooperative pool.
private actor CommandExecution {
    private let queue = DispatchSerialQueue(label: "dev.lynnswap.NeoSimulator.command", autoreleaseFrequency: .workItem)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let command: SystemCommand
    private let fileManager: FileManager
    private var process: Process?
    private var hasExited = false
    private var interruption: CommandFailure.Interruption?
    private var timers: [DispatchWorkItem] = []
    private var cleanupErrors: [any Error] = []

    init(command: SystemCommand, fileManager: FileManager) {
        self.command = command
        self.fileManager = fileManager
    }

    /// Returns at once on any thread, because a cancellation handler can run on the main thread.
    nonisolated func cancel() {
        queue.async { self.assumeIsolated { $0.stop(.cancelled) } }
    }

    func run() async throws -> CommandOutput {
        if interruption != nil { throw CancellationError() }
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("NeoSimulator-command-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch {
            throw CommandFailure.notStarted(executable: command.executable, underlying: error)
        }
        let result: Result<CommandOutput, any Error>
        do { result = .success(try await runChild(writingTo: directory)) }
        catch { result = .failure(error) }
        do { try fileManager.removeItem(at: directory) }
        catch { cleanupErrors.append(error) }
        guard cleanupErrors.isEmpty else {
            throw CommandFailure.cleanupFailed(executable: command.executable, result: result, cleanupErrors: cleanupErrors)
        }
        return try result.get()
    }

    /// Output goes to files rather than pipes: a descendant that inherits them cannot delay completion past the
    /// child's own exit, and a child that writes more than a pipe holds cannot stall on a reader.
    private func runChild(writingTo directory: URL) async throws -> CommandOutput {
        let stdoutURL = directory.appendingPathComponent("stdout")
        let stderrURL = directory.appendingPathComponent("stderr")
        let stdoutHandle: FileHandle
        let stderrHandle: FileHandle
        do {
            for url in [stdoutURL, stderrURL] {
                guard fileManager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
                }
            }
            stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
            stderrHandle = try FileHandle(forWritingTo: stderrURL)
        } catch {
            throw CommandFailure.notStarted(executable: command.executable, underlying: error)
        }

        let process = Process()
        process.executableURL = command.executable
        process.arguments = command.arguments
        process.environment = command.environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        let (status, reason) = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<(Int32, Process.TerminationReason), any Error>) in
            process.terminationHandler = { continuation.resume(returning: ($0.terminationStatus, $0.terminationReason)) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                close(stdoutHandle, stderrHandle)
                continuation.resume(throwing: CommandFailure.notStarted(executable: command.executable, underlying: error))
                return
            }
            self.process = process
            close(stdoutHandle, stderrHandle)
            if let limit = command.policy.limit {
                schedule(after: limit) { $0.stop(.timedOut(limit)) }
            }
        }
        hasExited = true
        timers.forEach { $0.cancel() }
        timers.removeAll()

        let output = Result {
            CommandOutput(terminationStatus: status, stdout: try Data(contentsOf: stdoutURL), stderr: try Data(contentsOf: stderrURL))
        }
        // SIGKILL cannot produce a normal exit, so that child finished before the signal arrived.
        // A child sent SIGTERM may have exited early from its own handler, so it counts as stopped.
        if let interruption, reason == .uncaughtSignal || command.policy.stopGrace != nil {
            throw CommandFailure.interrupted(executable: command.executable, cause: interruption, output: try? output.get())
        }
        do { return try output.get() }
        catch { throw CommandFailure.outputUnavailable(executable: command.executable, terminationStatus: status, underlying: error) }
    }

    /// The child keeps the descriptors it inherited, so this process does not need its copies once it has started.
    private func close(_ handles: FileHandle...) {
        for handle in handles {
            do { try handle.close() }
            catch { cleanupErrors.append(error) }
        }
    }

    /// The first cause is the one reported, and a child that has already exited is not stopped at all.
    private func stop(_ cause: CommandFailure.Interruption) {
        guard interruption == nil, !hasExited else { return }
        guard let process else {
            interruption = cause
            return
        }
        guard process.isRunning else { return }
        interruption = cause
        if let grace = command.policy.stopGrace {
            send(SIGTERM)
            schedule(after: grace) { $0.send(SIGKILL) }
        } else {
            send(SIGKILL)
        }
    }

    /// Only the owned child is signalled; its guest may already have been forcibly stopped.
    private func send(_ signal: Int32) {
        guard let process, process.isRunning else { return }
        if kill(process.processIdentifier, signal) != 0, errno != ESRCH {
            cleanupErrors.append(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
        }
    }

    private func schedule(after delay: Duration, _ action: @escaping @Sendable (isolated CommandExecution) -> Void) {
        let timer = DispatchWorkItem { [weak self] in self?.assumeIsolated { action($0) } }
        timers.append(timer)
        let (seconds, attoseconds) = delay.components
        queue.asyncAfter(deadline: .now() + Double(seconds) + Double(attoseconds) / 1e18, execute: timer)
    }
}
