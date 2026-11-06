import Darwin
import Foundation
@testable import NeoSimulatorDeviceIO
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(1)))
struct SystemCommandRunnerTests {
    /// Starts more children than the cooperative pool has threads, so a wait that occupied a thread would stop everything here.
    @Test func heldChildrenLeaveUnrelatedWorkRunning() async throws {
        let scope = try CommandScope()
        let held = try HeldChildren(in: scope.directory)
        defer { held.release() }
        let count = ProcessInfo.processInfo.activeProcessorCount + 1
        let children = (0..<count).map { _ in
            Task { try await scope.runner.run(held.command(then: "printf finished", policy: .uninterrupted)) }
        }
        let identifiers = try await held.waitUntilStarted(count)
        #expect(identifiers.count == count)

        #expect(await Task.detached { true }.value)
        #expect(await Task { @MainActor in true }.value)
        let unrelated = try await scope.runner.run(SystemCommand(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["unrelated"], policy: .uninterrupted))
        #expect(unrelated.stdoutText == "unrelated")

        held.release()
        for child in children {
            let output = try await child.value
            #expect(output.terminationStatus == 0 && output.stdoutText == "finished")
        }
        for identifier in identifiers { #expect(isGone(identifier)) }
        #expect(try scope.leftovers().isEmpty)
    }

    @Test func outputAndStatusOfAFailingCommandAreReportedSeparately() async throws {
        let scope = try CommandScope()
        let output = try await scope.runner.run(SystemCommand(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '%s' \"$FIXTURE\"; printf rejected >&2; exit 7"],
            environment: ["FIXTURE": "written"], policy: .uninterrupted))
        #expect(output == CommandOutput(terminationStatus: 7, stdout: Data("written".utf8), stderr: Data("rejected".utf8)))
        #expect(try scope.leftovers().isEmpty)
    }

    /// A child that exceeds what a pipe holds finishes without anything reading it.
    @Test func outputLargerThanAPipeIsCollectedInFull() async throws {
        let scope = try CommandScope()
        let output = try await scope.runner.run(SystemCommand(
            executable: URL(fileURLWithPath: "/bin/dd"), arguments: ["if=/dev/zero", "bs=1024", "count=512"], policy: .uninterrupted))
        #expect(output.terminationStatus == 0 && output.stdout.count == 512 * 1024)
    }

    /// The background descendant keeps both output descriptors open after the owned child exits.
    @Test func aDescendantHoldingTheOutputDoesNotDelayCompletion() async throws {
        let scope = try CommandScope()
        let held = try HeldChildren(in: scope.directory)
        defer { held.release() }
        let holdPath = try held.makeHold()
        let output = try await scope.runner.run(SystemCommand(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exec 3<\"$1\"; printf started; /bin/cat <&3 &", "fixture", holdPath], policy: .uninterrupted))
        #expect(output.terminationStatus == 0 && output.stdoutText == "started")
        #expect(try scope.leftovers().isEmpty)
    }

    @Test func aCommandCancelledBeforeItsChildStartsChangesNothing() async throws {
        let scope = try CommandScope()
        let marker = scope.directory.appendingPathComponent("marker")
        let attempt = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await scope.runner.run(SystemCommand(executable: URL(fileURLWithPath: "/usr/bin/touch"), arguments: [marker.path], policy: .cancellable))
        }
        await #expect(throws: CancellationError.self) { try await attempt.value }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(try scope.leftovers().isEmpty)
    }

    @Test func aChildThatCannotStartIsDistinctFromOneThatWasStopped() async throws {
        let scope = try CommandScope()
        let missing = scope.directory.appendingPathComponent("missing")
        let failure = try await #require(throws: CommandFailure.self) {
            try await scope.runner.run(SystemCommand(executable: missing, arguments: [], policy: .cancellable))
        }
        guard case .notStarted(let executable, _) = failure else {
            Issue.record("Expected a command that never started, but got \(failure)")
            return
        }
        #expect(executable == missing)
        #expect(try scope.leftovers().isEmpty)
    }

    /// The child ignores SIGTERM, so only the owned kill can end it.
    @Test func cancellationReapsTheChildAndKeepsWhatItWrote() async throws {
        let scope = try CommandScope()
        let held = try HeldChildren(in: scope.directory)
        defer { held.release() }
        let running = Task {
            try await scope.runner.run(held.command(then: "", prefix: "trap '' TERM; printf partial;", policy: .cancellable))
        }
        let identifier = try #require(try await held.waitUntilStarted(1).first)
        running.cancel()
        let failure = try await interruption(of: running)
        #expect(failure.cause == .cancelled)
        #expect(failure.output?.terminationStatus == SIGKILL && failure.output?.stdoutText == "partial")
        #expect(isGone(identifier))
        #expect(try scope.leftovers().isEmpty)
    }

    @Test func callersThatEndOnCancellationSeeCancellationError() async throws {
        let scope = try CommandScope()
        let held = try HeldChildren(in: scope.directory)
        defer { held.release() }
        let running = Task { try await scope.runner.runCancellable(held.command(then: "", policy: .cancellable)) }
        let identifier = try #require(try await held.waitUntilStarted(1).first)
        running.cancel()
        await #expect(throws: CancellationError.self) { try await running.value }
        #expect(isGone(identifier))
    }

    /// The caller is not cancelled, because a stopped read must leave the rest of its operation to decide what happens next.
    @Test func stoppingReadsEndsThemWithoutCancellingTheirCallersAndRefusesNewOnesUntilResumed() async throws {
        let scope = try CommandScope()
        let held = try HeldChildren(in: scope.directory)
        defer { held.release() }
        let reads = CommandReads(runner: scope.runner)
        let callerWasCancelled = Mutex<[Bool]>([])
        let callers = try (0..<2).map { _ in
            let command = try held.command(then: "", policy: .cancellable)
            return Task {
                defer { callerWasCancelled.withLock { $0.append(Task.isCancelled) } }
                return try await reads.run(command)
            }
        }
        let identifiers = try await held.waitUntilStarted(callers.count)
        reads.stop()
        for caller in callers { await #expect(throws: CancellationError.self) { try await caller.value } }
        for identifier in identifiers { #expect(isGone(identifier)) }
        #expect(callerWasCancelled.withLock { $0 } == [false, false])
        #expect(try scope.leftovers().isEmpty)

        let marker = scope.directory.appendingPathComponent("marker")
        let touch = SystemCommand(executable: URL(fileURLWithPath: "/usr/bin/touch"), arguments: [marker.path], policy: .cancellable)
        await #expect(throws: CancellationError.self) { try await reads.run(touch) }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        reads.resume()
        _ = try await reads.run(touch)
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func cancellingACallerStopsOnlyItsOwnRead() async throws {
        let scope = try CommandScope()
        let held = try HeldChildren(in: scope.directory)
        defer { held.release() }
        let reads = CommandReads(runner: scope.runner)
        let first = try held.command(then: "", policy: .cancellable)
        let cancelled = Task { try await reads.run(first) }
        let cancelledIdentifier = try #require(try await held.waitUntilStarted(1).first)
        let second = try held.command(then: "printf finished", policy: .cancellable)
        let kept = Task { try await reads.run(second) }
        _ = try await held.waitUntilStarted(1)
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(isGone(cancelledIdentifier))
        held.release()
        #expect(try await kept.value.stdoutText == "finished")
    }

    /// The child ignores SIGTERM, so the limit has to escalate to SIGKILL once the grace period ends.
    @Test func aLimitEscalatesAndReapsAChildThatIgnoresTermination() async throws {
        let scope = try CommandScope()
        let policy = CommandPolicy(limit: .seconds(1), cancellation: .stopsChild, stopGrace: .milliseconds(50))
        let running = Task {
            try await scope.runner.run(SystemCommand(executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "trap '' TERM; printf '%s' \"$$\"; exec /bin/sleep 300"], policy: policy))
        }
        let failure = try await interruption(of: running)
        #expect(failure.cause == .timedOut(.seconds(1)))
        #expect(failure.output?.terminationStatus == SIGKILL)
        let identifier = try #require(failure.output.flatMap { Int32($0.stdoutText) })
        #expect(isGone(identifier))
        #expect(try scope.leftovers().isEmpty)
    }

    /// A handler can end a child early with any status, so its normal exit still leaves the outcome unknown.
    @Test func aChildStoppedThroughItsTerminationHandlerIsStillInterrupted() async throws {
        let scope = try CommandScope()
        let held = try HeldChildren(in: scope.directory)
        defer { held.release() }
        let policy = CommandPolicy(limit: nil, cancellation: .stopsChild, stopGrace: .seconds(30))
        let running = Task {
            try await scope.runner.run(held.command(then: "", prefix: "trap 'exit 0' TERM;", waitsInBackground: true, policy: policy))
        }
        _ = try await held.waitUntilStarted(1)
        running.cancel()
        let failure = try await interruption(of: running)
        #expect(failure.cause == .cancelled && failure.output?.terminationStatus == 0)
    }

    @Test func aChildThatIgnoresCancellationByPolicyFinishesAndReportsItsResult() async throws {
        let scope = try CommandScope()
        let held = try HeldChildren(in: scope.directory)
        defer { held.release() }
        let running = Task { try await scope.runner.run(held.command(then: "printf finished", policy: .uninterrupted)) }
        let identifier = try #require(try await held.waitUntilStarted(1).first)
        running.cancel()
        #expect(!isGone(identifier))
        held.release()
        let output = try await running.value
        #expect(output.terminationStatus == 0 && output.stdoutText == "finished")
    }

    @Test func aCleanupFailureKeepsTheCompletedResult() async throws {
        let scope = try CommandScope(failsRemoval: true)
        let failure = try await #require(throws: CommandFailure.self) {
            try await scope.runner.run(SystemCommand(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["done"], policy: .uninterrupted))
        }
        guard case .cleanupFailed(_, .success(let output), let cleanupErrors) = failure else {
            Issue.record("Expected the completed result beside the cleanup failure, but got \(failure)")
            return
        }
        #expect(output.stdoutText == "done" && cleanupErrors.count == 1)
    }

    @Test func aCleanupFailureKeepsTheInterruptionAndIsNotReportedAsCancellation() async throws {
        let scope = try CommandScope(failsRemoval: true)
        let held = try HeldChildren(in: scope.directory)
        defer { held.release() }
        let running = Task { try await scope.runner.runCancellable(held.command(then: "", policy: .cancellable)) }
        let identifier = try #require(try await held.waitUntilStarted(1).first)
        running.cancel()
        let failure = try await #require(throws: CommandFailure.self) { try await running.value }
        guard case .cleanupFailed(_, .failure(let original), _) = failure else {
            Issue.record("Expected the interruption beside the cleanup failure, but got \(failure)")
            return
        }
        #expect((original as? CommandFailure)?.interruption == .cancelled)
        #expect(isGone(identifier))
    }

    @Test func aCleanupFailureKeepsTheLaunchFailure() async throws {
        let scope = try CommandScope(failsRemoval: true)
        let failure = try await #require(throws: CommandFailure.self) {
            try await scope.runner.run(SystemCommand(executable: scope.directory.appendingPathComponent("missing"), arguments: [], policy: .cancellable))
        }
        guard case .cleanupFailed(_, .failure(let original), _) = failure, case .notStarted = original as? CommandFailure else {
            Issue.record("Expected the launch failure beside the cleanup failure, but got \(failure)")
            return
        }
    }

    /// Blocks more reads than the cooperative pool has threads, so reads that occupied its threads would stop the test here.
    @Test func blockingIOLeavesTheCooperativePoolRunning() async throws {
        let pipes = (0...ProcessInfo.processInfo.activeProcessorCount).map { _ in Pipe() }
        let (started, reportStarted) = AsyncStream.makeStream(of: Void.self)
        let reads = pipes.map { pipe in
            let reader = pipe.fileHandleForReading
            return Task {
                try await performBlockingIO {
                    reportStarted.yield()
                    return try reader.readToEnd() ?? Data()
                }
            }
        }
        for await _ in started.prefix(pipes.count) {}
        #expect(await Task.detached { true }.value)
        for pipe in pipes { try pipe.fileHandleForWriting.close() }
        for read in reads { _ = try await read.value }
    }

    private func interruption(of task: Task<CommandOutput, any Error>) async throws -> (cause: CommandFailure.Interruption, output: CommandOutput?) {
        do {
            let output = try await task.value
            Issue.record("Expected an interrupted command, but it returned \(output)")
            throw CancellationError()
        } catch CommandFailure.interrupted(_, let cause, let output) {
            return (cause, output)
        }
    }

    private func isGone(_ identifier: Int32) -> Bool {
        kill(identifier, 0) == -1 && errno == ESRCH
    }
}

/// Gives a runner a temporary directory of its own, so what a command leaves behind can be counted.
private final class CommandScope: Sendable {
    private final class ScopedFileManager: FileManager, @unchecked Sendable {
        let root: URL
        let failsRemoval: Bool

        init(root: URL, failsRemoval: Bool) {
            self.root = root
            self.failsRemoval = failsRemoval
            super.init()
        }

        override var temporaryDirectory: URL { root }

        override func removeItem(at url: URL) throws {
            if failsRemoval, url.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL {
                throw CocoaError(.fileWriteNoPermission)
            }
            try super.removeItem(at: url)
        }
    }

    /// For the fixture's FIFOs and markers, outside what the runner writes.
    let directory: URL
    private let root: URL
    let runner: SystemCommandRunner

    init(failsRemoval: Bool = false) throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("SystemCommandRunnerTests-\(UUID().uuidString)", isDirectory: true)
        directory = base.appendingPathComponent("fixture", isDirectory: true)
        root = base.appendingPathComponent("temporary", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        runner = SystemCommandRunner(fileManager: ScopedFileManager(root: root, failsRemoval: failsRemoval))
    }

    deinit { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

    func leftovers() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path)
    }
}

/// Children that report their process identifiers and then wait until the test releases them. The test's own
/// descriptors keep the FIFOs open, so neither side blocks in open(2). Each child gets a FIFO of its own because
/// closing a FIFO's last writer can leave all but some of its blocked readers asleep on Darwin.
final class HeldChildren: Sendable {
    private let directory: URL
    private let readyPath: String
    private let ready: Int32
    private let holds = Mutex<[Int32]>([])

    init(in directory: URL) throws {
        self.directory = directory
        readyPath = directory.appendingPathComponent("ready-\(UUID().uuidString)").path
        guard mkfifo(readyPath, 0o600) == 0 else { throw POSIXError(.EIO) }
        ready = open(readyPath, O_RDWR | O_CLOEXEC)
        guard ready >= 0 else { throw POSIXError(.EIO) }
    }

    deinit {
        release()
        close(ready)
    }

    /// A FIFO that a reader can wait on until ``release()``.
    func makeHold() throws -> String {
        let path = directory.appendingPathComponent("hold-\(UUID().uuidString)").path
        guard mkfifo(path, 0o600) == 0 else { throw POSIXError(.EIO) }
        let hold = open(path, O_RDWR | O_CLOEXEC)
        guard hold >= 0 else { throw POSIXError(.EIO) }
        holds.withLock { $0.append(hold) }
        return path
    }

    /// `prefix` runs before the child reports itself. `waitsInBackground` leaves the shell itself free to run a trap.
    func command(then finish: String, prefix: String = "", waitsInBackground: Bool = false, policy: CommandPolicy) throws -> SystemCommand {
        let wait = waitsInBackground ? "/bin/cat <&3 & wait $!" : "/bin/cat <&3 >/dev/null"
        let script = "exec 3<\"$1\"; \(prefix) printf '%s\\n' \"$$\" > \"$2\"; \(wait); \(finish)"
        return SystemCommand(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script, "fixture", try makeHold(), readyPath], policy: policy)
    }

    /// Writes an executable that behaves like ``command(then:prefix:waitsInBackground:policy:)``, for code that chooses its own arguments.
    func writeExecutable(to url: URL) throws {
        try "#!/bin/sh\nexec 3<\"\(try makeHold())\"\nprintf '%s\\n' \"$$\" > \"\(readyPath)\"\n/bin/cat <&3 >/dev/null\n"
            .write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    func waitUntilStarted(_ count: Int) async throws -> [Int32] {
        let ready = ready
        return try await performBlockingIO {
            var text = Data()
            var buffer = [UInt8](repeating: 0, count: 256)
            while text.count(where: { $0 == UInt8(ascii: "\n") }) < count {
                let received = read(ready, &buffer, buffer.count)
                guard received > 0 else { throw POSIXError(.EIO) }
                text.append(contentsOf: buffer[..<received])
            }
            return String(decoding: text, as: UTF8.self).split(separator: "\n").compactMap { Int32($0) }
        }
    }

    func release() {
        holds.withLock { holds in
            for hold in holds { close(hold) }
            holds.removeAll()
        }
    }
}
