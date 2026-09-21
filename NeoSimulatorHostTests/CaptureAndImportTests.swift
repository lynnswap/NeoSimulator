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
        let destination = directory.appendingPathComponent("movie.mp4")
        let store = RecordingStore()
        store.onError = { _ in }
        func process(_ url: URL) -> Process {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "exit 1"]
            return process
        }
        _ = try store.start(to: destination, process: process, onFinished: {})
        var secondProcessCreated = false
        #expect(throws: (any Error).self) {
            try store.start(to: alias.appendingPathComponent("movie.mp4"), process: { url in
                secondProcessCreated = true
                return process(url)
            }, onFinished: {})
        }
        #expect(!secondProcessCreated)
        await store.finishAll()
        #expect(!store.hasActiveRecordings)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["alias"])
    }

    @Test func finishingRecordingsWaitsForCleanupAndKeepsDestination() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("movie.mp4")
        let original = Data("existing movie".utf8)
        try original.write(to: destination)
        let store = RecordingStore()
        var reported = false
        var finished = false
        store.onError = { _ in reported = true }
        _ = try store.start(to: destination, process: { _ in
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
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["movie.mp4"])
    }
}
