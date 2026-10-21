import AVFoundation
import Foundation
import Testing

@Suite @MainActor
struct CaptureAndImportTests {
    @Test func earlyStopWaitsForTheFirstFrameAcknowledgement() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", """
            trap 'exit 0' INT
            sleep 0.1
            printf 'Recording ' >&2
            sleep 0.1
            printf 'started\\n' >&2
            while :; do sleep 0.1; done
            """]
        let recording = try VideoRecording(process: process, startupTimeout: .seconds(3))
        recording.stop()
        try await recording.waitUntilFinished()
        #expect(recording.hasStarted)
        #expect(recording.isStopping)
        #expect(!process.isRunning)
    }

    @Test func recordingStartupFailureAndTimeoutAreReported() async throws {
        let rejected = Process()
        rejected.executableURL = URL(fileURLWithPath: "/bin/sh")
        rejected.arguments = ["-c", "echo denied >&2; exit 7"]
        let recording = try VideoRecording(process: rejected)
        await #expect(throws: (any Error).self) { try await recording.waitUntilFinished() }

        let stalled = Process()
        stalled.executableURL = URL(fileURLWithPath: "/bin/sleep")
        stalled.arguments = ["30"]
        let timeout = try VideoRecording(process: stalled, startupTimeout: .milliseconds(30))
        await #expect(throws: (any Error).self) { try await timeout.waitUntilFinished() }
        #expect(!stalled.isRunning)
    }

    @Test func failedImportsKeepSuccessfulResultsAndContinue() async throws {
        let urls = ["First.app", "Rejected.app", "Photo.png", "Unsupported.txt"].map {
            URL(fileURLWithPath: "/tmp/\($0)")
        }
        var imported: [String] = []
        do {
            try await SimulatorFileImport.perform(urls) { url, _ in
                if url.lastPathComponent == "Rejected.app" { throw HostError.operation("Not a simulator app") }
                imported.append(url.lastPathComponent)
            }
            Issue.record("Expected partial failure")
        } catch {
            #expect(error.localizedDescription.contains("First.app, Photo.png"))
            #expect(error.localizedDescription.contains("Rejected.app: Not a simulator app"))
            #expect(error.localizedDescription.contains("Unsupported.txt"))
        }
        #expect(imported == ["First.app", "Photo.png"])
    }

    @Test func concurrentRecordingsCannotOverwriteTheSameDestination() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let alias = directory.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        let destination = directory.appendingPathComponent("movie.mov")
        let store = RecordingStore()
        store.onError = { _ in }
        func process(_ url: URL) -> Process {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "exit 1"]
            return process
        }
        _ = try store.start(to: .file(destination), process: process, onFinished: {})
        var secondProcessCreated = false
        #expect(throws: (any Error).self) {
            try store.start(to: .file(alias.appendingPathComponent("movie.mov")), process: { url in
                secondProcessCreated = true
                return process(url)
            }, onFinished: {})
        }
        #expect(!secondProcessCreated)
        let caseSensitive = try directory.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            .volumeSupportsCaseSensitiveNames ?? true
        let differentlyCased = directory.appendingPathComponent("Movie.mov")
        if caseSensitive {
            _ = try store.start(to: .file(differentlyCased), process: process, onFinished: {})
        } else {
            #expect(throws: (any Error).self) {
                try store.start(to: .file(differentlyCased), process: process, onFinished: {})
            }
        }
        await store.finishAll()
        #expect(!store.hasActiveRecordings)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["alias"])
    }

    @Test func captureNamesAndFoldersFollowSimulatorApp() throws {
        let date = try #require(Calendar.current.date(from: DateComponents(
            year: 2026, month: 1, day: 2, hour: 15, minute: 4, second: 5)))
        #expect(CaptureFile.screenshotName(device: "iPhone/Test:1", date: date)
                == "Simulator Screenshot - iPhone.Test.1 - 2026-01-02 at 15.04.05.png")
        #expect(CaptureFile.recordingName(device: "iPhone 17", date: date)
                == "Simulator Screen Recording - iPhone 17 - 2026-01-02 at 15.04.05.mov")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = HostPreferences.screenShotSaveLocation
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.set(directory.path, forKey: key)
        #expect(CaptureFile.screenshotFolder().path == directory.path)
        let file = directory.appendingPathComponent("file")
        try Data().write(to: file)
        for unusable in [file.path, directory.appendingPathComponent("missing").path, ""] {
            UserDefaults.standard.set(unusable, forKey: key)
            #expect(CaptureFile.screenshotFolder() == CaptureFile.desktop)
        }
    }

    @Test func capturesTakeTheNextFreeNumberAndStayPutWhenSavingFails() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = directory.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for taken in ["Shot.png", "Shot #2.png"] { try Data().write(to: folder.appendingPathComponent(taken)) }
        func capture() throws -> URL {
            let url = directory.appendingPathComponent(UUID().uuidString)
            try Data("capture".utf8).write(to: url)
            return url
        }
        let saved = try CaptureFile.move(try capture(), into: folder, named: "Shot.png")
        #expect(saved.lastPathComponent == "Shot #3.png")
        #expect(try Data(contentsOf: saved) == Data("capture".utf8))

        let kept = try capture()
        do {
            _ = try CaptureFile.move(kept, into: directory.appendingPathComponent("missing"), named: "Shot.png")
            Issue.record("Expected the move to fail")
        } catch {
            #expect(error.localizedDescription.contains(kept.path))
        }
        #expect(FileManager.default.fileExists(atPath: kept.path))
    }

    @Test func aFolderRecordingIsNamedWhenItStops() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = directory.appendingPathComponent("fixture.mov")
        try await writeMovie(to: movie)
        try Data().write(to: directory.appendingPathComponent("Recording.mov"))
        let store = RecordingStore()
        var errors: [Error] = []
        store.onError = { errors.append($0) }
        // A recording to a chosen file reserves that name until it finishes.
        _ = try store.start(to: .file(directory.appendingPathComponent("Recording #2.mov")), process: { _ in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "trap 'exit 0' INT; echo 'Recording started' >&2; while :; do sleep 0.05; done"]
            return process
        }, onFinished: {})
        var namedAfterStop: [Bool] = []
        var stopped = false, finished = false
        let recording = try store.start(to: .folder(directory, name: {
            namedAfterStop.append(stopped)
            return "Recording.mov"
        }), process: { url in
            // Writes the movie when stopped, as simctl finalizes it on SIGINT.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", """
                trap 'cp "$1" "$2"; exit 0' INT
                echo 'Recording started' >&2
                while :; do sleep 0.05; done
                """, "sh", movie.path, url.path]
            return process
        }, onFinished: { finished = true })
        for _ in 0..<100 where !recording.hasStarted { try await Task.sleep(for: .milliseconds(10)) }
        #expect(namedAfterStop.isEmpty)
        stopped = true
        recording.stop()
        try await recording.waitUntilFinished()
        for _ in 0..<200 where !finished { try await Task.sleep(for: .milliseconds(10)) }
        #expect(errors.isEmpty)
        #expect(namedAfterStop == [true])
        #expect(try Data(contentsOf: directory.appendingPathComponent("Recording #3.mov")) == Data(contentsOf: movie))
        await store.finishAll()
    }

    /// Writes a short H.264 QuickTime movie.
    private func writeMovie(to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<3 {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(10)) }
            #expect(adaptor.append(try #require(buffer), withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }

    @Test func finishingRecordingsWaitsForCleanupAndKeepsDestination() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("movie.mov")
        let original = Data("existing movie".utf8)
        try original.write(to: destination)
        let store = RecordingStore()
        var reported = false
        var finished = false
        store.onError = { _ in reported = true }
        _ = try store.start(to: .file(destination), process: { _ in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "echo failed >&2; exit 1"]
            return process
        }, onFinished: { finished = true })
        await store.finishAll()
        #expect(!store.hasActiveRecordings)
        #expect(reported)
        #expect(finished)
        #expect(try Data(contentsOf: destination) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["movie.mov"])
    }
}
