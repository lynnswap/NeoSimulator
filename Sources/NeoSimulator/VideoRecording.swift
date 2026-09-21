import AVFoundation
import Foundation
import Observation
import Darwin

@MainActor @Observable
final class VideoRecording {
    private enum Event: Sendable {
        case output(Data)
        case drained
        case exited(Int32, Process.TerminationReason)
    }
    private(set) var isStopping = false
    private(set) var hasStarted = false
    private let process: Process
    private var completion: Result<Void, Error>?
    private var waiters: [CheckedContinuation<Void, Error>] = []
    private var timer: Task<Void, Never>?
    private var forcedError: Error?

    init(process: Process, startupTimeout: Duration = .seconds(30)) throws {
        self.process = process
        let pipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = pipe
        let (events, continuation) = AsyncStream<Event>.makeStream()
        process.terminationHandler = { process in
            continuation.yield(.exited(process.terminationStatus, process.terminationReason))
        }
        do { try process.run() }
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
                        hasStarted = true
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
                        result = .failure(HostError.operation(diagnostic.isEmpty ? "Video recording failed with status \(status)" : diagnostic))
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

    func stop() {
        guard completion == nil, !isStopping else { return }
        isStopping = true
        // simctl documents its first-frame acknowledgement as the safe point
        // for SIGINT. A Stop during startup waits for that acknowledgement.
        if hasStarted, process.isRunning { process.interrupt() }
        armTimeout(.seconds(30), message: "Video recording did not finish")
    }

    func waitUntilFinished() async throws {
        if let completion { return try completion.get() }
        try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    private func armTimeout(_ duration: Duration, message: String) {
        timer?.cancel()
        timer = Task { [weak self] in
            do { try await Task.sleep(for: duration) } catch { return }
            guard let self, self.completion == nil, self.process.isRunning else { return }
            self.forcedError = HostError.operation(message)
            self.process.terminate()
            try? await Task.sleep(for: .seconds(2))
            if self.process.isRunning { kill(self.process.processIdentifier, SIGKILL) }
        }
    }
}

@MainActor
final class RecordingStore {
    private struct Entry {
        let recording: VideoRecording
        let destination: URL
        let completion: Task<Void, Never>
    }
    private var entries: [UUID: Entry] = [:]
    private var isFinishing = false
    var onError: (Error) -> Void = { hostLog($0.localizedDescription) }
    var hasActiveRecordings: Bool { !entries.isEmpty }

    func start(to destination: URL, process: (URL) -> Process,
               onFinished: @escaping @MainActor () -> Void) throws -> VideoRecording {
        guard !isFinishing else { throw HostError.operation("Recordings are finishing before NeoSimulator quits") }
        let canonicalDestination = destination.deletingLastPathComponent()
            .standardizedFileURL.resolvingSymlinksInPath()
            .appendingPathComponent(destination.lastPathComponent)
        guard !entries.values.contains(where: { $0.destination == canonicalDestination }) else {
            throw HostError.operation("Another recording is saving to \(destination.path). Choose a different filename.")
        }
        let identifier = UUID()
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".neo-simulator-\(identifier.uuidString).mp4")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        close(descriptor)
        let recording: VideoRecording
        do { recording = try VideoRecording(process: process(temporary)) }
        catch {
            do { try FileManager.default.removeItem(at: temporary) }
            catch let cleanup {
                throw HostError.operation("\(error.localizedDescription) Temporary file remains at \(temporary.path): \(cleanup.localizedDescription)")
            }
            throw error
        }

        let completion = Task { [self] in
            var readyToSave = false
            do {
                try await recording.waitUntilFinished()
                let asset = AVURLAsset(url: temporary)
                let duration = try await asset.load(.duration)
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard duration.isNumeric, duration.seconds > 0, !tracks.isEmpty else {
                    throw HostError.operation("The recording contains no video frames")
                }
                readyToSave = true
                guard rename(temporary.path, destination.path) == 0 else {
                    throw HostError.operation("Could not save \(destination.lastPathComponent). The recording is available at \(temporary.path): \(String(cString: strerror(errno)))")
                }
            } catch {
                var reported: Error = error
                if !readyToSave {
                    do { try FileManager.default.removeItem(at: temporary) }
                    catch let cleanup {
                        reported = HostError.operation("\(error.localizedDescription) Temporary file remains at \(temporary.path): \(cleanup.localizedDescription)")
                    }
                }
                onError(reported)
            }
            entries.removeValue(forKey: identifier)
            onFinished()
        }
        entries[identifier] = Entry(recording: recording, destination: canonicalDestination, completion: completion)
        return recording
    }

    func finishAll() async {
        isFinishing = true
        let pending = Array(entries.values)
        for entry in pending { entry.recording.stop() }
        for entry in pending { await entry.completion.value }
    }
}
