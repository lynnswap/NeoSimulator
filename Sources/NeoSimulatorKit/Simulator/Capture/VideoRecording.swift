import AVFoundation
import Foundation
import NeoSimulatorDeviceIO
import Observation
import Darwin

@MainActor @Observable
package final class VideoRecording {
    private enum Event: Sendable {
        case output(Data)
        case drained
        case exited(Int32, Process.TerminationReason)
    }
    package private(set) var isStopping = false
    private var firstFrameAt: Date?
    package var hasStarted: Bool { firstFrameAt != nil }
    package var startDate: Date? { isStopping || completion != nil ? nil : firstFrameAt }
    private let process: Process
    private var completion: Result<Void, Error>?
    private var waiters: [CheckedContinuation<Void, Error>] = []
    private var timer: Task<Void, Never>?
    private var forcedError: Error?

    /// Launches `process` on `lane`, because launching waits for the system to read its executable.
    package init(process: Process, startupTimeout: Duration = DeviceOperationLimit.recordingStart,
                 lane: any CaptureLane = BlockingIOLane()) async throws {
        self.process = process
        let pipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = pipe
        let (events, continuation) = AsyncStream<Event>.makeStream()
        process.terminationHandler = { process in
            continuation.yield(.exited(process.terminationStatus, process.terminationReason))
        }
        nonisolated(unsafe) let launching = process
        do { try await lane.run { try launching.run() } }
        catch { process.terminationHandler = nil; continuation.finish(); throw error }
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                continuation.yield(.drained)
            } else {
                continuation.yield(.output(data))
            }
        }
        Task { [self] in
            var output = Data()
            var exit: (Int32, Process.TerminationReason)?
            var drained = false
            for await event in events {
                switch event {
                case .output(let data):
                    output = Data((output + data).suffix(8192))
                    if !hasStarted, String(decoding: output, as: UTF8.self).contains("Recording started") {
                        firstFrameAt = Date()
                        if isStopping {
                            if process.isRunning { process.interrupt() }
                        } else {
                            timer?.cancel()
                        }
                    }
                case .drained: drained = true
                case .exited(let status, let reason): exit = (status, reason)
                }
                if let (status, reason) = exit, drained {
                    let stoppedNormally = isStopping && hasStarted &&
                        ((reason == .exit && status == 130) || (reason == .uncaughtSignal && status == SIGINT))
                    let result: Result<Void, Error>
                    if let forcedError { result = .failure(forcedError) }
                    else if (reason == .exit && status == 0) || stoppedNormally { result = .success(()) }
                    else {
                        let diagnostic = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                        result = .failure(SimulatorError.operation(diagnostic.isEmpty ? "Video recording failed with status \(status)" : diagnostic))
                    }
                    timer?.cancel()
                    process.terminationHandler = nil
                    completion = result
                    let pending = waiters
                    waiters.removeAll()
                    for waiter in pending { waiter.resume(with: result) }
                    continuation.finish()
                    return
                }
            }
        }
        armTimeout(startupTimeout, message: "Video recording did not start")
    }

    package func stop() {
        guard completion == nil, !isStopping else { return }
        isStopping = true
        // simctl documents its first-frame acknowledgement as the safe point
        // for SIGINT. A Stop during startup waits for that acknowledgement.
        if hasStarted, process.isRunning { process.interrupt() }
        armTimeout(DeviceOperationLimit.recordingFinish, message: "Video recording did not finish")
    }

    package func waitUntilFinished() async throws {
        if let completion { return try completion.get() }
        try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    /// Stops the recording and waits until it has ended, whatever its outcome, which `waitUntilFinished()` then gives. Its
    /// timers bound that unless the process survives being killed: this then throws, and the recording goes on.
    package func finish(within limit: Duration = DeviceOperationLimit.recordingFinish + DeviceOperationLimit.recordingStopGrace * 2) async throws {
        stop()
        let ending = Task { try? await waitUntilFinished() }
        guard await ending.ends(before: .now + limit) else {
            throw SimulatorError.operation("The recording did not stop within its limit.")
        }
    }

    private func armTimeout(_ duration: Duration, message: String) {
        timer?.cancel()
        timer = Task { [weak self] in
            do { try await Task.sleep(for: duration) } catch { return }
            guard let self, self.completion == nil, self.process.isRunning else { return }
            self.forcedError = SimulatorError.operation(message)
            self.process.terminate()
            try? await Task.sleep(for: DeviceOperationLimit.recordingStopGrace)
            if self.process.isRunning { kill(self.process.processIdentifier, SIGKILL) }
        }
    }
}

@MainActor
package final class RecordingStore {
    private struct Entry {
        /// Nil until its process has launched.
        var recording: VideoRecording?
        /// The file it records into.
        let temporary: URL
        /// The chosen file, which another recording must not save to.
        let file: URL?
        let destinationKey: String?
    }
    private let lane: any CaptureLane
    private let finishLimit: Duration?
    private var entries: [UUID: Entry] = [:]
    /// The destinations that captures are being moved to, which a recording must not save to either.
    private var claims: Set<String> = []
    private var emptied: [CheckedContinuation<Void, Never>] = []
    private var isFinishing = false
    package var onError: (Error) -> Void = { hostLog($0.localizedDescription) }
    package var hasActiveRecordings: Bool { !entries.isEmpty }

    /// `finishLimit` defaults to TerminationTimeout.
    package init(lane: any CaptureLane = BlockingIOLane(), finishLimit: Duration? = nil) {
        self.lane = lane
        self.finishLimit = finishLimit
    }

    /// Where a finished recording is saved.
    package enum Destination {
        /// A file chosen in a save panel, replaced when the recording finishes.
        case file(URL)
        /// Hands off a finalized temporary movie; handoff failures are reported as save failures.
        case capture(@MainActor (URL) async throws -> Void)
    }

    /// Holds `file` for a capture being moved there until the returned closure runs, because a recording that chose the
    /// file meanwhile would replace the capture when it finishes. Returns nil if a recording will save there or another
    /// capture is being moved there. Captures are still saved while recordings finish.
    package func claim(_ file: URL) async throws -> (@MainActor () -> Void)? {
        let key = try await lane.run { try Self.destinationKey(for: file) }
        guard !claims.contains(key), !entries.values.contains(where: { $0.destinationKey == key }) else { return nil }
        claims.insert(key)
        return { [self] in _ = claims.remove(key) }
    }

    /// Reserves the destination, then creates its temporary file and launches the process away from the caller.
    /// The entry exists from the reservation on, so that quitting waits for a recording that is still launching.
    package func start(to destination: Destination, process: @MainActor (URL) -> Process,
               onFinished: @escaping @MainActor () -> Void) async throws -> VideoRecording {
        try checkNotFinishing()
        let identifier = UUID()
        let temporary: URL, chosenFile: URL?, destinationKey: String?
        switch destination {
        case .file(let file):
            let key = try await lane.run { try Self.destinationKey(for: file) }
            try checkNotFinishing()
            guard !entries.values.contains(where: { $0.destinationKey == key }) else {
                throw SimulatorError.operation("Another recording is saving to \(file.path). Choose a different filename.")
            }
            guard !claims.contains(key) else {
                throw SimulatorError.operation("A capture is being saved to \(file.path). Choose a different filename.")
            }
            chosenFile = file
            destinationKey = key
            temporary = file.deletingLastPathComponent()
                .appendingPathComponent(".neo-simulator-\(identifier.uuidString).mov")
        case .capture:
            chosenFile = nil
            destinationKey = nil
            temporary = FileManager.default.temporaryDirectory
                .appendingPathComponent("simulator_recording_\(identifier.uuidString).mov")
        }
        entries[identifier] = Entry(temporary: temporary, file: chosenFile, destinationKey: destinationKey)
        let recording: VideoRecording
        do {
            try await lane.run { try CaptureFile.createExclusively(temporary) }
        } catch {
            let thrown = failedStart(error)
            remove(identifier)
            throw thrown
        }
        do {
            recording = try await VideoRecording(process: process(temporary), lane: lane)
        } catch {
            let thrown = failedStart(await CaptureFile.removing(temporary, after: error, lane: lane))
            remove(identifier)
            throw thrown
        }
        entries[identifier]?.recording = recording
        if isFinishing { recording.stop() }

        Task { [self] in
            var readyToSave = false
            do {
                try await recording.waitUntilFinished()
                let asset = AVURLAsset(url: temporary)
                let duration = try await asset.load(.duration)
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard duration.isNumeric, duration.seconds > 0, !tracks.isEmpty else {
                    throw SimulatorError.operation("The recording contains no video frames")
                }
                readyToSave = true
                switch destination {
                case .file(let file):
                    try await lane.run {
                        guard rename(temporary.path, file.path) == 0 else {
                            throw SimulatorError.operation("Could not save \(file.lastPathComponent). The recording is available at \(temporary.path): \(String(cString: strerror(errno)))")
                        }
                    }
                case .capture(let handOver):
                    try await handOver(temporary)
                }
            } catch {
                onError(readyToSave ? error : await CaptureFile.removing(temporary, after: error, lane: lane))
            }
            remove(identifier)
            onFinished()
        }
        return recording
    }

    /// What a start throws for `error`. Nobody may be left to show the failure of one that finishing outlasted, so that goes
    /// to `onError`, like a recording's, and the start is merely cancelled.
    private func failedStart(_ error: any Error) -> any Error {
        guard isFinishing else { return error }
        onError(error)
        return CancellationError()
    }

    private func checkNotFinishing() throws {
        guard !isFinishing else { throw SimulatorError.operation("Recordings are finishing before NeoSimulator quits") }
    }

    private func remove(_ identifier: UUID) {
        entries.removeValue(forKey: identifier)
        guard entries.isEmpty else { return }
        for waiter in emptied { waiter.resume() }
        emptied.removeAll()
    }

    /// Identifies a file however its folder is spelled, and ignoring case on
    /// a case-insensitive volume.
    nonisolated private static func destinationKey(for file: URL) throws -> String {
        let canonical = file.deletingLastPathComponent()
            .standardizedFileURL.resolvingSymlinksInPath()
            .appendingPathComponent(file.lastPathComponent)
        let caseSensitive = try canonical.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames ?? true
        let path = canonical.path.precomposedStringWithCanonicalMapping
        return caseSensitive ? path : path.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Stops every recording, including one that is still launching, and waits up to the limit until each is saved or
    /// reported. A recording that outlasts it stays here and is returned as a failure naming its files: it goes on, stops
    /// itself once launched, gives its outcome to `onError`, and finishing again joins it.
    @discardableResult
    package func finishAll() async -> [any Error] {
        isFinishing = true
        for entry in entries.values { entry.recording?.stop() }
        let deadline = ContinuousClock.now + (finishLimit ?? HostPreferences.terminationLimit)
        let emptying = Task { [self] in
            if !entries.isEmpty { await withCheckedContinuation { emptied.append($0) } }
        }
        if await emptying.ends(before: deadline) || entries.isEmpty { return [] }
        let files = Set(entries.values.flatMap { [$0.temporary, $0.file].compactMap(\.self) }).map(\.path).sorted()
        return [SimulatorError.operation("A recording did not finish before the context stopped. Check these file locations:\n\(files.joined(separator: "\n"))")]
    }
}
