@testable import NeoSimulatorKit
@testable import NeoSimulatorHostSupport
@testable import NeoSimulatorApp
@testable import NeoSimulatorService
import AppKit
import AVFoundation
import Foundation
import ImageIO
import NeoSimulatorDeviceIO
import QuartzCore
import Synchronization
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
        let recording = try await VideoRecording(process: process, startupTimeout: .seconds(3))
        #expect(recording.startDate == nil)
        recording.stop()
        try await recording.waitUntilFinished()
        #expect(recording.hasStarted)
        #expect(recording.isStopping)
        #expect(recording.startDate == nil)
        #expect(!process.isRunning)
    }

    @Test func recordingStartupFailureAndTimeoutAreReported() async throws {
        let rejected = Process()
        rejected.executableURL = URL(fileURLWithPath: "/bin/sh")
        rejected.arguments = ["-c", "echo denied >&2; exit 7"]
        let recording = try await VideoRecording(process: rejected)
        await #expect(throws: (any Error).self) { try await recording.waitUntilFinished() }
        #expect(recording.startDate == nil)

        let interrupted = Process()
        interrupted.executableURL = URL(fileURLWithPath: "/bin/sh")
        interrupted.arguments = ["-c", "echo 'Recording started' >&2; exit 7"]
        let started = try await VideoRecording(process: interrupted)
        await #expect(throws: (any Error).self) { try await started.waitUntilFinished() }
        #expect(started.hasStarted && started.startDate == nil)

        let stalled = Process()
        stalled.executableURL = URL(fileURLWithPath: "/bin/sleep")
        stalled.arguments = ["30"]
        let timeout = try await VideoRecording(process: stalled, startupTimeout: .milliseconds(30))
        await #expect(throws: (any Error).self) { try await timeout.waitUntilFinished() }
        #expect(!stalled.isRunning)
    }

    @Test func failedImportsKeepSuccessfulResultsAndContinue() async throws {
        let urls = ["First.app", "Package.ipa", "Rejected.app", "Installed.ipa", "Photo.png", "Unsupported.txt"].map {
            URL(fileURLWithPath: "/tmp/\($0)")
        }
        var imported: [String] = []
        do {
            try await SimulatorFileImport.perform(urls) { url, kind in
                if url.lastPathComponent == "Rejected.app" { throw SimulatorError.operation("Not a simulator app") }
                if url.lastPathComponent == "Installed.ipa" {
                    throw DeviceInspectorError.cleanupFailed(directory: URL(fileURLWithPath: "/tmp/Staging"), operationError: nil,
                                                             cleanupError: CocoaError(.fileWriteNoPermission))
                }
                imported.append("\(url.lastPathComponent) \(kind)")
            }
            Issue.record("Expected partial failure")
        } catch {
            #expect(error.localizedDescription.contains("First.app, Package.ipa, Installed.ipa, Photo.png"))
            #expect(error.localizedDescription.contains("Rejected.app: Not a simulator app"))
            #expect(error.localizedDescription.contains("Installed.ipa: Could not remove /tmp/Staging"))
            #expect(error.localizedDescription.contains("Unsupported.txt"))
        }
        #expect(imported == ["First.app application", "Package.ipa application", "Photo.png media"])
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
        _ = try await store.start(to: .file(destination), process: process, onFinished: {})
        var secondProcessCreated = false
        await #expect(throws: (any Error).self) {
            _ = try await store.start(to: .file(alias.appendingPathComponent("movie.mov")), process: { url in
                secondProcessCreated = true
                return process(url)
            }, onFinished: {})
        }
        #expect(!secondProcessCreated)
        let caseSensitive = try directory.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            .volumeSupportsCaseSensitiveNames ?? true
        let differentlyCased = directory.appendingPathComponent("Movie.mov")
        if caseSensitive {
            _ = try await store.start(to: .file(differentlyCased), process: process, onFinished: {})
        } else {
            await #expect(throws: (any Error).self) {
                _ = try await store.start(to: .file(differentlyCased), process: process, onFinished: {})
            }
        }
        await store.finishAll()
        #expect(!store.hasActiveRecordings)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["alias"])
    }

    @Test func aHeldRecordingStartLeavesTheCallerResponsiveAndKeepsOneOwnerOfItsDestination() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lane = HeldCaptureLane()
        let store = RecordingStore(lane: lane)
        store.onError = { _ in }
        var processes = 0
        func process(_ url: URL) -> Process {
            processes += 1
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "exit 1"]
            return process
        }
        let destination = directory.appendingPathComponent("movie.mov")
        let first = Task.immediate { try await store.start(to: .file(destination), process: process, onFinished: {}) }
        let second = Task.immediate { try await store.start(to: .file(destination), process: process, onFinished: {}) }
        // Both are resolving their destination off the main actor, which still runs, and nothing has been created.
        await lane.untilHeld(2)
        #expect(processes == 0 && !store.hasActiveRecordings)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        lane.open()
        let outcomes = [await first.result, await second.result]
        #expect(outcomes.filter { (try? $0.get()) != nil }.count == 1)
        #expect(processes == 1)
        await store.finishAll()
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func quittingWaitsForARecordingThatIsStillLaunchingAndStopsIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = directory.appendingPathComponent("fixture.mov")
        try await writeMovie(to: movie)
        let lane = HeldCaptureLane()
        let store = RecordingStore(lane: lane)
        var errors: [Error] = []
        store.onError = { errors.append($0) }
        var finished = false
        var handedOver: [URL] = []
        let start = Task.immediate {
            try await store.start(to: .capture { handedOver.append($0) }, process: { url in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", """
                    trap 'cp "$1" "$2"; exit 0' INT
                    echo 'Recording started' >&2
                    while :; do sleep 0.05; done
                    """, "sh", movie.path, url.path]
                return process
            }, onFinished: { finished = true })
        }
        await lane.untilHeld(1)
        #expect(store.hasActiveRecordings)
        let finishing = Task.immediate { await store.finishAll() }
        // A new recording cannot begin once quitting has.
        await #expect(throws: SimulatorError.self) {
            _ = try await store.start(to: .file(directory.appendingPathComponent("Late.mov")), process: { _ in Process() }, onFinished: {})
        }
        #expect(!finished)
        lane.open()
        let recording = try await start.value
        #expect(recording.isStopping)
        await finishing.value
        #expect(finished && errors.isEmpty && !store.hasActiveRecordings)
        #expect(handedOver.count == 1)
        try FileManager.default.removeItem(at: try #require(handedOver.first))
    }

    @Test func aFailedLaunchRemovesItsFileAndReportsWhatCouldNotBeRemoved() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = RecordingStore()
        func unlaunchable(_ url: URL) -> Process {
            let process = Process()
            process.executableURL = directory.appendingPathComponent("missing")
            return process
        }
        await #expect(throws: (any Error).self) {
            _ = try await store.start(to: .file(directory.appendingPathComponent("movie.mov")), process: unlaunchable, onFinished: {})
        }
        #expect(!store.hasActiveRecordings)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        do {
            _ = try await store.start(to: .file(directory.appendingPathComponent("kept.mov")), process: { url in
                try? FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
                return unlaunchable(url)
            }, onFinished: {})
            Issue.record("Expected the launch to fail")
        } catch {
            #expect(error.localizedDescription.contains("Temporary file remains"))
        }
        #expect(!store.hasActiveRecordings)
    }

    @Test func aFailedCaptureWriteLeavesTheDestinationAndReportsWhatCouldNotBeRemoved() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let destination = directory.appendingPathComponent("capture.png")
        try Data("original".utf8).write(to: destination)
        // The move is one attempt, which is reported rather than repeated.
        var attempts = 0
        let locations = CaptureFile.Locations()
        do {
            try await CaptureFile.write(to: destination, extension: "png", locations: locations) { temporary in
                attempts += 1
                #expect(Set(locations.locations) == [temporary, destination])
                try Data("new".utf8).write(to: temporary)
                try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
            }
            Issue.record("Expected the replacement to fail")
        } catch {
            #expect(error.localizedDescription.contains("Temporary file remains"))
        }
        #expect(attempts == 1)
        #expect(try Data(contentsOf: destination) == Data("original".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try await CaptureFile.write(to: destination, extension: "png") { try Data("new".utf8).write(to: $0) }
        #expect(try Data(contentsOf: destination) == Data("new".utf8))
    }

    @Test func movingAcrossVolumesPublishesAWholeCopyBeforeRemovingTheOriginal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = directory.appendingPathComponent("folder"), other = directory.appendingPathComponent("other")
        for path in [folder, other] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
        defer {
            for path in [folder, other] { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path) }
            try? FileManager.default.removeItem(at: directory)
        }
        func names(_ url: URL) throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: url.path).sorted() }
        func capture() throws -> URL {
            let url = folder.appendingPathComponent(UUID().uuidString)
            try Data("capture".utf8).write(to: url)
            return url
        }
        // Only the first rename crosses volumes; the copy's own rename stays on its volume.
        func across(_ original: URL) -> (URL, URL) throws -> Void {
            { from, to in
                if from == original { throw POSIXError(.EXDEV) }
                try CaptureFile.renameExclusively(from, to: to)
            }
        }
        let moved = try capture()
        let destination = other.appendingPathComponent("Shot.png")
        let locations = CaptureFile.Locations()
        var stagedCopy: URL?
        try CaptureFile.relocate(moved, to: destination, renaming: { from, to in
            if from == moved { throw POSIXError(.EXDEV) }
            stagedCopy = from
            #expect(Set(locations.locations) == [from, destination])
            #expect(FileManager.default.fileExists(atPath: from.path))
            #expect(!FileManager.default.fileExists(atPath: destination.path))
            try CaptureFile.renameExclusively(from, to: to)
        }, locations: locations)
        #expect(stagedCopy != nil && locations.locations == [destination])
        locations.clear()
        #expect(!FileManager.default.fileExists(atPath: moved.path))
        #expect(try Data(contentsOf: destination) == Data("capture".utf8))
        #expect(try names(other) == ["Shot.png"])

        // A taken name is refused whole, whichever way the file would have travelled.
        let refused = try capture()
        #expect(throws: POSIXError.self) { try CaptureFile.relocate(refused, to: destination, renaming: across(refused)) }
        #expect(throws: POSIXError.self) { try CaptureFile.relocate(refused, to: destination) }
        #expect(FileManager.default.fileExists(atPath: refused.path))
        #expect(try names(other) == ["Shot.png"])

        // A destination that takes no copy leaves the original and no partial file.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: other.path)
        let kept = try capture()
        #expect(throws: (any Error).self) {
            try CaptureFile.relocate(kept, to: other.appendingPathComponent("Kept.png"), renaming: across(kept))
        }
        #expect(FileManager.default.fileExists(atPath: kept.path))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: other.path)
        #expect(try names(other) == ["Shot.png"])

        // An original that cannot be removed is reported, and the destination is whole.
        let stuck = try capture()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        let left = other.appendingPathComponent("Left.png")
        #expect(throws: CaptureLeftBehind.self) { try CaptureFile.relocate(stuck, to: left, renaming: across(stuck)) }
        #expect(FileManager.default.fileExists(atPath: stuck.path))
        #expect(try Data(contentsOf: left) == Data("capture".utf8))
        #expect(try names(other) == ["Left.png", "Shot.png"])
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

    @Test func capturesTakeTheNextFreeNumberAndStayPutWhenSavingFails() async throws {
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
        let saved = try await CaptureFile.move(try capture(), into: folder, named: "Shot.png")
        #expect(saved.lastPathComponent == "Shot #3.png")
        #expect(try Data(contentsOf: saved) == Data("capture".utf8))

        let kept = try capture()
        do {
            _ = try await CaptureFile.move(kept, into: directory.appendingPathComponent("missing"), named: "Shot.png")
            Issue.record("Expected the move to fail")
        } catch {
            #expect(error.localizedDescription.contains(kept.path))
        }
        #expect(FileManager.default.fileExists(atPath: kept.path))
    }

    @Test func aQuickRecordingIsHandedOverWhenItStopsAndSavedAroundReservedNames() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = directory.appendingPathComponent("fixture.mov")
        try await writeMovie(to: movie)
        try Data().write(to: directory.appendingPathComponent("Recording.mov"))
        let store = RecordingStore()
        var errors: [Error] = []
        store.onError = { errors.append($0) }
        _ = try await store.start(to: .file(directory.appendingPathComponent("Recording #2.mov")), process: { _ in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "trap 'exit 0' INT; echo 'Recording started' >&2; while :; do sleep 0.05; done"]
            return process
        }, onFinished: {})
        var handedOver: [(url: URL, afterStop: Bool)] = []
        @MainActor final class StopState { var stopped = false }
        let state = StopState()
        var finished = false
        let recording = try await store.start(to: .capture { handedOver.append(($0, state.stopped)) }, process: { url in
            // simctl finalizes the movie on SIGINT.
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
        let startedAt = try #require(recording.startDate)
        #expect(startedAt <= Date())
        #expect(handedOver.isEmpty)
        state.stopped = true
        recording.stop()
        #expect(recording.startDate == nil)
        try await recording.waitUntilFinished()
        for _ in 0..<200 where !finished { try await Task.sleep(for: .milliseconds(10)) }
        #expect(errors.isEmpty)
        let temporary = try #require(handedOver.first)
        #expect(handedOver.count == 1 && temporary.afterStop)
        let capture = CapturedContent(.movie, file: temporary.url, name: "Recording.mov", defaultFolder: directory,
                                      claim: store.claim)
        #expect(try await capture.saveToDefaultLocation().lastPathComponent == "Recording #3.mov")
        #expect(try Data(contentsOf: directory.appendingPathComponent("Recording #3.mov")) == Data(contentsOf: movie))
        let dropped = directory.appendingPathComponent("dropped")
        try Data().write(to: dropped)
        // A drag's destination is fixed, so a file that a recording will replace refuses it.
        let refused = CapturedContent(.movie, file: dropped, name: "Dropped.mov", defaultFolder: directory, claim: store.claim)
        await #expect(throws: SimulatorError.self) { try await refused.deliver(to: directory.appendingPathComponent("Recording #2.mov")) }
        #expect(FileManager.default.fileExists(atPath: dropped.path) && !refused.isResolved)
        await store.finishAll()
    }

    @Test func aRecordingCannotTakeADestinationWhileACaptureIsBeingMovedThere() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = directory.appendingPathComponent("fixture.mov")
        try await writeMovie(to: movie)
        let folder = directory.appendingPathComponent("Saved", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = RecordingStore()
        store.onError = { Issue.record($0) }
        let captured = directory.appendingPathComponent("captured")
        try Data("capture".utf8).write(to: captured)
        let lane = HeldCaptureLane()
        let content = CapturedContent(.movie, file: captured, name: "Recording.mov", defaultFolder: folder, lane: lane, claim: store.claim)
        let saving = Task.immediate { try await content.saveToDefaultLocation() }
        await lane.untilHeld(1)
        let destination = folder.appendingPathComponent("Recording.mov")
        // Were it allowed to start, this would replace the capture with the movie when it finishes.
        let started = try? await store.start(to: .file(destination), process: { url in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", """
                trap 'cp "$1" "$2"; exit 0' INT
                echo 'Recording started' >&2
                while :; do sleep 0.05; done
                """, "sh", movie.path, url.path]
            return process
        }, onFinished: {})
        lane.open()
        #expect(try await saving.value == destination)
        started?.stop()
        await store.finishAll()
        #expect(started == nil)
        #expect(try Data(contentsOf: destination) == Data("capture".utf8))
        // The move has ended, and the file is an ordinary one that a save panel asks about replacing.
        let release = try #require(try await store.claim(destination))
        release()
    }

    @Test func aDestinationWhoseClaimCannotBeAnsweredIsNotTaken() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = directory.appendingPathComponent("capture")
        try Data().write(to: capture)
        do {
            _ = try await CaptureFile.move(capture, into: directory, named: "Saved.mov", claim: { _ in throw POSIXError(.EIO) })
            Issue.record("Expected the move to fail")
        } catch {
            #expect(error.localizedDescription.contains(capture.path))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["capture"])
    }

    @Test func aHeldRecordingDoesNotHoldFinishingWhichNamesItsFilesAndItsLateOutcomeIsStillReported() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lane = HeldCaptureLane(passing: 1)
        let store = RecordingStore(lane: lane, finishLimit: .milliseconds(50))
        var errors: [Error] = []
        store.onError = { errors.append($0) }
        var finished = false
        let destination = directory.appendingPathComponent("Held.mov")
        // It exits without a frame, so the recording fails once it has been let go.
        let start = Task.immediate {
            try await store.start(to: .file(destination), process: { _ in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", "exit 0"]
                return process
            }, onFinished: { finished = true })
        }
        await lane.untilHeld(1)
        let failures = await store.finishAll()
        let description = try #require(failures.first?.localizedDescription)
        #expect(failures.count == 1 && description.contains(destination.path) && description.contains("\(directory.path)/.neo-simulator-"))
        #expect(store.hasActiveRecordings && errors.isEmpty && !finished)
        lane.open()
        #expect(try await start.value.isStopping)
        try await wait { finished }
        #expect(errors.count == 1 && !store.hasActiveRecordings)
        #expect(await store.finishAll().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)

        // A launch that fails after finishing gave up on it has nobody else to tell.
        let launching = HeldCaptureLane(passing: 1)
        let unlaunchable = RecordingStore(lane: launching, finishLimit: .milliseconds(50))
        unlaunchable.onError = { errors.append($0) }
        let failing = Task.immediate {
            try await unlaunchable.start(to: .file(destination), process: { _ in
                let process = Process()
                process.executableURL = directory.appendingPathComponent("missing")
                return process
            }, onFinished: {})
        }
        await launching.untilHeld(1)
        #expect(await unlaunchable.finishAll().count == 1)
        launching.open()
        await #expect(throws: CancellationError.self) { _ = try await failing.value }
        #expect(errors.count == 2 && !unlaunchable.hasActiveRecordings)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func aRecordingThatIgnoresBeingStoppedDoesNotHoldWhoeverFinishesIt() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap '' INT; echo 'Recording started' >&2; while :; do sleep 0.05; done"]
        let recording = try await VideoRecording(process: process)
        try await wait { recording.hasStarted }
        await #expect(throws: SimulatorError.self) { try await recording.finish(within: .milliseconds(50)) }
        process.terminate()
        try? await recording.waitUntilFinished()
    }

    @Test func animatedGIFsKeepTheMoviesFrameTimesUpToTheFrameRate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = directory.appendingPathComponent("movie.mov")
        try await writeMovie(to: movie, frames: 12)
        func export(frameRate: Double) async throws -> (count: Int, delays: [Double], loop: Int?, brightest: UInt8) {
            let gif = directory.appendingPathComponent("\(frameRate).gif")
            try await AnimatedGIF.export(movie, to: gif, options: .init(maximumFrameRate: frameRate, maximumFrameSize: 640,
                                                                        dithers: true, ditherDepth: 4))
            let source = try #require(CGImageSourceCreateWithURL(gif as CFURL, nil))
            func gifProperties(_ properties: CFDictionary?) -> [CFString: Any]? {
                (properties as? [CFString: Any])?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            }
            let count = CGImageSourceGetCount(source)
            let delays = (0..<count).compactMap {
                gifProperties(CGImageSourceCopyPropertiesAtIndex(source, $0, nil))?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
            }
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let rgba = NSBitmapImageRep(cgImage: image)
            var brightest: UInt8 = 0
            for x in 0..<rgba.pixelsWide {
                for y in 0..<rgba.pixelsHigh {
                    let color = try #require(rgba.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                    brightest = max(brightest, UInt8(max(color.redComponent, color.greenComponent, color.blueComponent) * 255))
                }
            }
            return (count, delays, gifProperties(CGImageSourceCopyProperties(source, nil))?[kCGImagePropertyGIFLoopCount] as? Int,
                    brightest)
        }
        // Floating-point subtraction must not stretch 0.1-second frames to 0.11.
        let every = try await export(frameRate: 10)
        #expect(every.count == 12 && every.loop == 0)
        // Linear-space dithering would lift black to about 48.
        #expect(every.brightest <= 12)
        #expect(Array(every.delays.dropLast()) == Array(repeating: 0.1, count: 11))
        let thinned = try await export(frameRate: 5)
        #expect(thinned.count == 6)
        #expect(thinned.delays.first == 0.2)
    }

    /// Writes black BT.709 frames to an H.264 QuickTime movie.
    fileprivate func writeMovie(to url: URL, frames: Int = 3) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<frames {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
            let pixels = try #require(buffer)
            do {
                CVPixelBufferLockBaseAddress(pixels, [])
                defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
                let baseAddress = try #require(CVPixelBufferGetBaseAddress(pixels))
                for row in 0..<64 {
                    (baseAddress + row * CVPixelBufferGetBytesPerRow(pixels))
                        .assumingMemoryBound(to: UInt32.self).update(repeating: 0xFF00_0000, count: 64)
                }
            }
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
        _ = try await store.start(to: .file(destination), process: { _ in
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

    @Test(arguments: [true, false])
    func recordingCleanupDistinguishesMissingOutputFromRemovalFailure(outputAlreadyRemoved: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = RecordingStore()
        var errors: [Error] = []
        var output: URL?
        store.onError = { errors.append($0) }
        _ = try await store.start(to: .file(directory.appendingPathComponent("movie.mov")), process: { url in
            output = url
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", (outputAlreadyRemoved ? "rm -- \"$1\"; " : "") + "echo recorder-denied >&2; exit 7", "sh", url.path]
            return process
        }, onFinished: {})
        if !outputAlreadyRemoved {
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        }
        await store.finishAll()
        let error = try #require(errors.first)
        #expect(errors.count == 1 && error.localizedDescription.contains("recorder-denied"))
        #expect(error.localizedDescription.contains("Temporary file remains") == !outputAlreadyRemoved)
        #expect(FileManager.default.fileExists(atPath: try #require(output).path) == !outputAlreadyRemoved)
    }
}

/// The active-thumbnail list is shared by all windows.
@Suite(.serialized) @MainActor
struct CaptureThumbnailTests {
    @Test func thumbnailsArePlacedLikeSimulatorApp() {
        let source = NSRect(x: 100, y: 200, width: 400, height: 800)
        let screen = NSRect(x: 0, y: 0, width: 1600, height: 1200)
        let visible = NSRect(x: 0, y: 80, width: 1600, height: 1100)
        let spacing = NSSize(width: 10, height: 20)
        func place(_ window: NSRect, fullScreen: Bool = false) -> (NSRect, CaptureThumbnail.Position) {
            let placement = CaptureThumbnail.placement(source: source, window: window, fullScreen: fullScreen,
                                                       screen: screen, visible: visible, spacing: spacing)
            return (placement.frame, placement.position)
        }
        #expect(place(NSRect(x: 80, y: 100, width: 440, height: 980)) == (NSRect(x: 530, y: 120, width: 110, height: 210), .right))
        #expect(place(NSRect(x: 1400, y: 100, width: 190, height: 980)) == (NSRect(x: 1280, y: 120, width: 110, height: 210), .left))
        #expect(place(NSRect(x: 20, y: 100, width: 1560, height: 980)) == (NSRect(x: 1470, y: 100, width: 110, height: 210), .over))
        #expect(place(NSRect(x: 80, y: 40, width: 440, height: 980)).0.minY == 90)
        // A secondary screen may be below the main screen.
        #expect(place(screen, fullScreen: true) == (NSRect(x: 510, y: 200, width: 110, height: 210), .over))
        let lower = CaptureThumbnail.placement(source: NSRect(x: 1200, y: -1000, width: 400, height: 800),
                                               window: NSRect(x: 0, y: -1200, width: 1600, height: 1200), fullScreen: true,
                                               screen: NSRect(x: 0, y: -1200, width: 1600, height: 1200),
                                               visible: NSRect(x: 0, y: -1200, width: 1600, height: 1200), spacing: spacing)
        #expect(lower.frame.origin == NSPoint(x: 1486, y: -1196))
    }

    private func capture(_ kind: CapturedContent.Kind = .screenshot, named name: String = "Shot.png",
                         in directory: URL, owner: UUID? = nil, lane: any CaptureLane = BlockingIOLane()) throws -> CapturedContent {
        let file = directory.appendingPathComponent(UUID().uuidString)
        try Data(name.utf8).write(to: file)
        let folder = directory.appendingPathComponent("Saved", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return CapturedContent(kind, file: file, name: name, defaultFolder: folder, owner: owner, lane: lane)
    }

    /// Fits within the test machine's screen, which may be small.
    private func deviceWindow(offset: CGFloat = 0) -> (window: NSWindow, screen: NSRect) {
        _ = NSApplication.shared
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        let window = NSWindow(contentRect: NSRect(x: visible.minX + 100 + offset, y: visible.minY + 40, width: 200, height: 360),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        let frame = window.frame
        return (window, NSRect(x: frame.minX + 20, y: frame.minY + 20, width: 160, height: 280))
    }

    private func savedNames(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Saved").path).sorted()
    }

    @Test func aNewCaptureEndsTheShownThumbnailAndSavesIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (window, source) = deviceWindow()
        defer { window.close() }
        let first = CaptureThumbnail(try capture(named: "First.png", in: directory), image: nil, parent: window,
                                     source: source, spacing: .zero) { _ in }
        first.show()
        #expect(CaptureThumbnail.active.map(ObjectIdentifier.init) == [ObjectIdentifier(first)])
        let (other, _) = deviceWindow(offset: 300)
        defer { other.close() }
        let second = CaptureThumbnail(try capture(named: "Second.png", in: directory), image: nil, parent: other,
                                      source: source, spacing: .zero) { _ in }
        second.show()
        await first.content.settled()
        #expect(try savedNames(in: directory) == ["First.png"])
        #expect(CaptureThumbnail.active.map(ObjectIdentifier.init) == [ObjectIdentifier(second)])
        other.setFrame(other.frame.insetBy(dx: -20, dy: -20), display: false)
        await second.content.settled()
        #expect(try savedNames(in: directory) == ["First.png", "Second.png"])
        #expect(CaptureThumbnail.active.isEmpty)

        let owner = UUID()
        let third = CaptureThumbnail(try capture(named: "Third.png", in: directory, owner: owner), image: nil, parent: window,
                                     source: source, spacing: .zero) { _ in }
        third.show()
        #expect(await CaptureThumbnail.finishAll(owner: UUID()).isEmpty)
        #expect(CaptureThumbnail.active.map(ObjectIdentifier.init) == [ObjectIdentifier(third)])
        #expect(try savedNames(in: directory) == ["First.png", "Second.png"])
        #expect(await CaptureThumbnail.finishAll(owner: owner).isEmpty)
        #expect(try savedNames(in: directory) == ["First.png", "Second.png", "Third.png"])
        #expect(CaptureThumbnail.active.isEmpty)
    }

    @Test func thumbnailMenusOfferSimulatorAppsActions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = NSApplication.shared
        let shots = directory.appendingPathComponent("Shots", isDirectory: true)
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        let key = HostPreferences.screenShotSaveLocation
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.set(shots.path, forKey: key)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 300, height: 600), styleMask: .titled,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        func thumbnail(_ capture: CapturedContent) -> CaptureThumbnail {
            CaptureThumbnail(capture, image: nil, parent: window, source: .zero, spacing: .zero) { _ in }
        }
        func titles(_ menu: NSMenu) -> [String] { menu.items.map { $0.isSeparatorItem ? "-" : $0.title } }
        let screenshot = thumbnail(try capture(in: directory))
        #expect(titles(screenshot.menu()) == [
            "Save to Shots", "Save to Desktop", "Save to Documents", "Copy to Clipboard", "-",
            "Open in Mail", "Open in Preview", "Open in Photos", "-", "Show in Finder", "-", "Delete", "-", "Close",
        ])
        let movie = thumbnail(try capture(.movie, named: "Movie.mov", in: directory)).menu()
        #expect(titles(movie) == [
            "Save to Shots", "Save to Desktop", "Save to Documents", "Save as Animated GIF",
            "Save Copy as Animated GIF", "-", "Show in Finder", "-", "Delete", "-", "Close",
        ])
        #expect(movie.items.filter(\.isAlternate).map(\.keyEquivalentModifierMask) == [.option])
        UserDefaults.standard.set(CaptureFile.desktop?.path, forKey: key)
        #expect(Array(titles(screenshot.menu()).prefix(3)) == ["Save to Desktop", "Save to Documents", "Copy to Clipboard"])
        UserDefaults.standard.set(shots.path, forKey: key)

        func choose(_ title: String, in thumbnail: CaptureThumbnail) async throws {
            let item = try #require(thumbnail.menu().items.first { $0.title == title })
            #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
            await thumbnail.action?.value
        }
        let deleted = try capture(in: directory)
        try await choose("Delete", in: thumbnail(deleted))
        #expect(!FileManager.default.fileExists(atPath: deleted.file.path))
        try await choose("Save to Shots", in: thumbnail(try capture(named: "Custom.png", in: directory)))
        #expect(FileManager.default.fileExists(atPath: shots.appendingPathComponent("Custom.png").path))
        try await choose("Close", in: thumbnail(try capture(named: "Closed.png", in: directory)))
        #expect(try savedNames(in: directory) == ["Closed.png"])
    }

    @Test func aCompletedDragDeliversTheCaptureAndACancelledOneSavesIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 300, height: 600), styleMask: .titled,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // File promises may be fulfilled after the drag ends or the capture is saved.
        let delivered = try capture(named: "Dragged.png", in: directory)
        CaptureThumbnail(delivered, image: nil, parent: window, source: .zero, spacing: .zero) { _ in }.dragEnded(.copy)
        #expect(try savedNames(in: directory).isEmpty)
        // Quit saves unfulfilled promises; moved files already belong to the drop target.
        let unclaimed = try capture(named: "Unclaimed.png", in: directory)
        CaptureThumbnail(unclaimed, image: nil, parent: window, source: .zero, spacing: .zero) { _ in }.dragEnded(.copy)
        let taken = try capture(named: "Taken.png", in: directory)
        CaptureThumbnail(taken, image: nil, parent: window, source: .zero, spacing: .zero) { _ in }.dragEnded(.move)
        try FileManager.default.moveItem(at: taken.file, to: directory.appendingPathComponent("Taken.png"))
        #expect(await CaptureThumbnail.finishAll().isEmpty)
        #expect(try savedNames(in: directory) == ["Dragged.png", "Unclaimed.png"])
        let destination = directory.appendingPathComponent("Dragged.png")
        try await delivered.deliver(to: destination)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        let late = try capture(named: "Late.png", in: directory)
        try await late.saveToDefaultLocation()
        try await late.deliver(to: directory.appendingPathComponent("Late.png"))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Late.png").path))
        #expect(try savedNames(in: directory) == ["Dragged.png", "Late.png", "Unclaimed.png"])
        try Data().write(to: directory.appendingPathComponent("Saved/Movie.gif"))
        #expect(try await CaptureFile.unusedFile(in: directory.appendingPathComponent("Saved"), named: "Movie.gif").lastPathComponent
                == "Movie #2.gif")
        #expect(try await CaptureFile.unusedFile(in: directory.appendingPathComponent("Saved"), named: "Movie.gif",
                                                 claim: { $0.lastPathComponent != "Movie #2.gif" }).lastPathComponent == "Movie #3.gif")
        let cancelled = try capture(named: "Cancelled.png", in: directory)
        CaptureThumbnail(cancelled, image: nil, parent: window, source: .zero, spacing: .zero) { _ in }.dragEnded([])
        await cancelled.settled()
        #expect(try savedNames(in: directory) == ["Cancelled.png", "Dragged.png", "Late.png", "Movie.gif", "Unclaimed.png"])
    }

    @Test func aHeldSaveKeepsOneOwnerAcrossADeleteAndALateDelivery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lane = HeldCaptureLane()
        let content = try capture(named: "Raced.png", in: directory, lane: lane)
        let saving = Task.immediate { try await content.saveToDefaultLocation() }
        let deleting = Task.immediate { try await content.delete() }
        let destination = directory.appendingPathComponent("Dropped.png")
        let delivering = Task.immediate { try await content.deliver(to: destination) }
        await lane.untilHeld(1)
        // The main actor runs while the move is held, and the capture is still where it was.
        #expect(!content.isResolved)
        #expect(FileManager.default.fileExists(atPath: content.file.path))
        #expect(try savedNames(in: directory).isEmpty)
        lane.open()
        let saved = try await saving.value
        try await deleting.value
        try await delivering.value
        #expect(content.isResolved)
        #expect(!FileManager.default.fileExists(atPath: content.file.path))
        #expect(try Data(contentsOf: saved) == Data("Raced.png".utf8))
        #expect(try Data(contentsOf: destination) == Data("Raced.png".utf8))
        #expect(try savedNames(in: directory) == ["Raced.png"])
    }

    @Test func aHeldDeleteDecidesWhatASaveAndADeliveryThenFind() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lane = HeldCaptureLane()
        let content = try capture(named: "Deleted.png", in: directory, lane: lane)
        let deleting = Task.immediate { try await content.delete() }
        let saving = Task.immediate { try await content.saveToDefaultLocation() }
        let destination = directory.appendingPathComponent("Dropped.png")
        let delivering = Task.immediate { try await content.deliver(to: destination) }
        await lane.untilHeld(1)
        #expect(!content.isResolved && FileManager.default.fileExists(atPath: content.file.path))
        lane.open()
        try await deleting.value
        await #expect(throws: SimulatorError.self) { _ = try await saving.value }
        await #expect(throws: SimulatorError.self) { try await delivering.value }
        #expect(content.isResolved)
        #expect(try savedNames(in: directory).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func aFailedSaveIsNotRepeatedUnlessAskedAgain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lane = HeldCaptureLane()
        lane.open()
        let content = try capture(named: "Kept.png", in: directory, lane: lane)
        let missing = directory.appendingPathComponent("missing")
        do {
            try await content.save(into: missing)
            Issue.record("Expected the save to fail")
        } catch {
            #expect(error.localizedDescription.contains(content.file.path))
        }
        #expect(lane.runs == 1)
        #expect(!content.isResolved && FileManager.default.fileExists(atPath: content.file.path))
        try await content.saveIfUnresolved()
        #expect(lane.runs == 2 && content.isResolved)
        #expect(try savedNames(in: directory) == ["Kept.png"])

        // A save nobody asked for is attempted once, whichever of a drag's timer, a delivery or a quit comes next.
        let file = directory.appendingPathComponent("Unsaved.png")
        try Data("unsaved".utf8).write(to: file)
        let unsaved = CapturedContent(.screenshot, file: file, name: "Unsaved.png", defaultFolder: missing, lane: lane)
        let before = lane.runs
        await #expect(throws: SimulatorError.self) { try await unsaved.saveIfUnresolved() }
        #expect(lane.runs == before + 1)
        try await unsaved.saveIfUnresolved()
        try await unsaved.settleAfterDrop()
        #expect(lane.runs == before + 1)
        #expect(!unsaved.isResolved && FileManager.default.fileExists(atPath: file.path))
        // Someone asking still can.
        try await unsaved.save(into: directory.appendingPathComponent("Saved"))
        #expect(unsaved.isResolved)
        #expect(try savedNames(in: directory) == ["Kept.png", "Unsaved.png"])
    }

    @Test func aCaptureSavedWithItsOriginalLeftBehindIsResolvedAndServesLateDeliveries() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let whole = directory.appendingPathComponent("Whole.png")
        try Data("whole".utf8).write(to: whole)
        // Its first work reports what a move across volumes reports when it cannot remove the original.
        final class LeavingBehind: CaptureLane, Sendable {
            let whole: URL
            let runs = Mutex(0)
            init(whole: URL) { self.whole = whole }
            @concurrent func run<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
                let run = runs.withLock { $0 += 1; return $0 }
                if run == 1 { throw CaptureLeftBehind(destination: whole, original: whole, cleanup: CocoaError(.fileWriteNoPermission)) }
                return try await performBlockingIO(work)
            }
        }
        let lane = LeavingBehind(whole: whole)
        let content = try capture(named: "Whole.png", in: directory, lane: lane)
        await #expect(throws: CaptureLeftBehind.self) { try await content.saveToDefaultLocation() }
        #expect(content.isResolved)
        // Nothing moves it again, and it stays where the failure said it is.
        try await content.saveIfUnresolved()
        try await content.settleAfterDrop()
        #expect(lane.runs.withLock { $0 } == 1)
        #expect(FileManager.default.fileExists(atPath: content.file.path))
        let destination = directory.appendingPathComponent("Dropped.png")
        try await content.deliver(to: destination)
        #expect(try Data(contentsOf: destination) == Data("whole".utf8))
        #expect(try savedNames(in: directory).isEmpty)
    }

    @Test func aHeldDeliveryAnswersItsPromiseOnlyWhenItsFileIsThere() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lane = HeldCaptureLane()
        let content = try capture(named: "Held.png", in: directory, lane: lane)
        let provider = CaptureThumbnail.dragProvider(for: content) { Issue.record($0) }
        let delegate = try #require(provider.delegate)
        let destination = directory.appendingPathComponent("Held.png")
        var answers: [(any Error)?] = []
        let answered = AsyncStream<Void>.makeStream()
        delegate.filePromiseProvider(provider, writePromiseTo: destination) { [answered] failure in
            MainActor.assumeIsolated { answers.append(failure) }
            answered.continuation.yield()
        }
        await lane.untilHeld(1)
        #expect(answers.isEmpty && !FileManager.default.fileExists(atPath: destination.path))
        lane.open()
        var iterator = answered.stream.makeAsyncIterator()
        #expect(await iterator.next() != nil)
        #expect(answers.count == 1 && answers.first.map { $0 == nil } == true)
        #expect(try Data(contentsOf: destination) == Data("Held.png".utf8))
        #expect(content.isResolved)
    }

    @Test func aFailedDeliveryKeepsTheCaptureAtItsDefaultLocationAndAnswersWithTheFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let content = try capture(named: "Failed.png", in: directory)
        var reported: [any Error] = []
        let provider = CaptureThumbnail.dragProvider(for: content) { reported.append($0) }
        let delegate = try #require(provider.delegate)
        let failure = await withCheckedContinuation { continuation in
            delegate.filePromiseProvider(provider, writePromiseTo: directory.appendingPathComponent("missing/Failed.png")) {
                continuation.resume(returning: $0)
            }
        }
        #expect(failure != nil && reported.isEmpty && content.isResolved)
        #expect(try savedNames(in: directory) == ["Failed.png"])
        // A later delivery copies it from where it was saved.
        let destination = directory.appendingPathComponent("Failed.png")
        try await content.deliver(to: destination)
        #expect(try Data(contentsOf: destination) == Data("Failed.png".utf8))
        #expect(try savedNames(in: directory) == ["Failed.png"])
    }

    @Test func quittingEndsThumbnailsAtOnceAndWaitsForTheirFilesAndReportsFailures() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (window, source) = deviceWindow()
        defer { window.close() }
        let owner = UUID()
        // A timer already began saving this one; quitting finds it in flight and must not save it twice.
        let lane = HeldCaptureLane()
        let earlier = try capture(named: "Earlier.png", in: directory, owner: owner, lane: lane)
        var reported: [any Error] = []
        CaptureThumbnail(earlier, image: nil, parent: window, source: source, spacing: .zero) { reported.append($0) }.hide(animated: false)
        await lane.untilHeld(1)
        let shown = try capture(named: "Shown.png", in: directory, owner: owner, lane: lane)
        let thumbnail = CaptureThumbnail(shown, image: nil, parent: window, source: source, spacing: .zero) { reported.append($0) }
        thumbnail.show()
        let quitting = Task.immediate { await CaptureThumbnail.finishAll(owner: owner) }
        // The thumbnail is gone before the first wait, while its capture is still being saved.
        #expect(CaptureThumbnail.active.isEmpty)
        #expect(window.childWindows?.isEmpty != false)
        #expect(try savedNames(in: directory).isEmpty)
        await lane.untilHeld(2)
        lane.open()
        #expect(await quitting.value.isEmpty)
        #expect(reported.isEmpty)
        #expect(try savedNames(in: directory) == ["Earlier.png", "Shown.png"])

        let failing = CapturedContent(.screenshot, file: directory.appendingPathComponent("Gone.png"), name: "Gone.png",
                                      defaultFolder: directory.appendingPathComponent("Saved"), owner: owner)
        let gone = CaptureThumbnail(failing, image: nil, parent: window, source: source, spacing: .zero) { reported.append($0) }
        gone.show()
        let failures = await CaptureThumbnail.finishAll(owner: owner)
        #expect(failures.count == 1 && reported.isEmpty)
        #expect(!failing.isResolved)
    }

    @Test func aQuitThatADiskHoldsPastItsLimitSaysWhereTheCaptureRemainsAndTheSaveCarriesOn() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (window, source) = deviceWindow()
        defer { window.close() }
        let owner = UUID()
        let lane = HeldCaptureLane()
        let content = try capture(named: "Held.png", in: directory, owner: owner, lane: lane)
        CaptureThumbnail(content, image: nil, parent: window, source: source, spacing: .zero) { _ in }.show()
        let finishing = Task.immediate { await CaptureThumbnail.finishAll(owner: owner) }
        await lane.untilHeld(1)
        let other = try capture(named: "Other.png", in: directory, owner: UUID(), lane: lane)
        let otherSave = Task.immediate { try await other.saveToDefaultLocation() }
        await lane.untilHeld(2)
        _ = TerminationAccount.shared.take()
        let failures = await CaptureThumbnail.failures(of: finishing, before: .now + .milliseconds(50), owner: owner)
        #expect(failures.count == 1 && failures[0].localizedDescription.contains(content.file.path))
        #expect(!failures[0].localizedDescription.contains(other.file.path))
        #expect(TerminationAccount.shared.take().isEmpty)
        #expect(CaptureThumbnail.unfinishedCaptures().contains(content.file))
        #expect(FileManager.default.fileExists(atPath: content.file.path))
        lane.open()
        _ = try await otherSave.value
        #expect(await CaptureThumbnail.failures(of: finishing, before: .now + .seconds(30)).isEmpty)
        #expect(TerminationAccount.shared.take().isEmpty)
        #expect(content.isResolved && !CaptureThumbnail.unfinishedCaptures().contains(content.file))
        #expect(try savedNames(in: directory) == ["Held.png", "Other.png"])
    }

    @Test func quittingWaitsForAnAnimatedGIFAndNamesItsFilesWhileADiskHoldsIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (window, source) = deviceWindow()
        defer { window.close() }
        let owner = UUID()
        let temporary = directory.appendingPathComponent("Temporary.mov")
        try await CaptureAndImportTests().writeMovie(to: temporary)
        let folder = directory.appendingPathComponent("Saved", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Saving the movie and naming the GIF pass; writing the GIF is held.
        let lane = HeldCaptureLane(passing: 2)
        let content = CapturedContent(.movie, file: temporary, name: "Movie.mov", defaultFolder: folder, owner: owner, lane: lane)
        var reported: [any Error] = []
        let thumbnail = CaptureThumbnail(content, image: nil, parent: window, source: source, spacing: .zero) { reported.append($0) }
        let item = try #require(thumbnail.menu().items.first { $0.title == "Save Copy as Animated GIF" })
        #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
        await thumbnail.action?.value
        await lane.untilHeld(1)
        #expect(content.isResolved)
        let finishing = Task.immediate { await CaptureThumbnail.finishAll(owner: owner) }
        let failures = await CaptureThumbnail.failures(of: finishing, before: .now + .milliseconds(50), owner: owner)
        let description = try #require(failures.first?.localizedDescription)
        #expect(failures.count == 1)
        #expect(description.contains(folder.appendingPathComponent("Movie.gif").path))
        #expect(description.contains(folder.appendingPathComponent("Movie.mov").path))
        #expect(description.contains("\(folder.path)/.neo-simulator-"))
        #expect(CaptureThumbnail.unfinishedCaptures(owner: UUID()).isEmpty)
        lane.open()
        #expect(await finishing.value.isEmpty)
        #expect(reported.isEmpty)
        #expect(try savedNames(in: directory) == ["Movie.gif", "Movie.mov"])
        #expect(CaptureThumbnail.unfinishedCaptures(owner: owner).isEmpty)
    }

    @Test func anAnimatedGIFReplacesItsMovieOnlyOnceWholeAndAFailedOneSavesTheMovie() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (window, source) = deviceWindow()
        defer { window.close() }
        let owner = UUID()
        let folder = directory.appendingPathComponent("Saved", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var reported: [any Error] = []
        func export(_ content: CapturedContent) async throws {
            let thumbnail = CaptureThumbnail(content, image: nil, parent: window, source: source, spacing: .zero) { reported.append($0) }
            let item = try #require(thumbnail.menu().items.first { $0.title == "Save as Animated GIF" })
            #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
            await thumbnail.action?.value
        }
        func movie(_ file: String, lane: any CaptureLane = BlockingIOLane()) async throws -> CapturedContent {
            let temporary = directory.appendingPathComponent(file)
            try await CaptureAndImportTests().writeMovie(to: temporary)
            return CapturedContent(.movie, file: temporary, name: "Movie.mov", defaultFolder: folder, owner: owner, lane: lane)
        }
        // Naming the first passes and writing it is held, so the second finds its name taken.
        let lane = HeldCaptureLane(passing: 1)
        let held = try await movie("Held.mov", lane: lane)
        try await export(held)
        await lane.untilHeld(1)
        #expect(FileManager.default.fileExists(atPath: held.file.path) && !held.isResolved)
        let other = try await movie("Other.mov")
        try await export(other)
        await other.settled()
        #expect(try savedNames(in: directory) == ["Movie #2.gif"])
        lane.open()
        #expect(await CaptureThumbnail.finishAll(owner: owner).isEmpty)
        #expect(held.isResolved && !FileManager.default.fileExists(atPath: held.file.path))
        #expect(try savedNames(in: directory) == ["Movie #2.gif", "Movie.gif"])
        #expect(reported.isEmpty)

        let broken = try capture(.movie, named: "Broken.mov", in: directory, owner: owner)
        try await export(broken)
        #expect(await CaptureThumbnail.finishAll(owner: owner).isEmpty)
        #expect(reported.count == 1 && broken.isResolved)
        #expect(try savedNames(in: directory) == ["Broken.mov", "Movie #2.gif", "Movie.gif"])
    }

    @Test func aMenuActionOwnsTheCaptureUntilItEndsEvenIfItsThumbnailEnds() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (window, source) = deviceWindow()
        defer { window.close() }
        let lane = HeldCaptureLane()
        let content = try capture(named: "Used.png", in: directory, lane: lane)
        let timing = ControlledThumbnailTiming()
        let thumbnail = CaptureThumbnail(content, image: nil, parent: window, source: source,
                                         spacing: NSSize(width: 10, height: 10), timing: timing) { _ in }
        thumbnail.show()
        timing.completeAnimations()
        let delete = try #require(thumbnail.menu().items.first { $0.title == "Delete" })
        #expect(NSApp.sendAction(try #require(delete.action), to: delete.target, from: delete))
        await lane.untilHeld(1)
        // Choosing again does nothing, the timer waits, and the window's end does not save what is being deleted.
        #expect(NSApp.sendAction(try #require(delete.action), to: delete.target, from: delete))
        #expect(timing.deadlineDurations.isEmpty)
        thumbnail.hide(animated: false)
        #expect(CaptureThumbnail.active.isEmpty)
        lane.open()
        await thumbnail.action?.value
        #expect(content.isResolved && !FileManager.default.fileExists(atPath: content.file.path))
        #expect(lane.runs == 1)
        #expect(try savedNames(in: directory).isEmpty)
    }

    @Test func aFailedActionOnAnEndedThumbnailSavesTheCaptureAndReportsTheFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (window, source) = deviceWindow()
        defer { window.close() }
        // The screenshot folder is gone by the time its menu item is used.
        let folder = directory.appendingPathComponent("Shots", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let key = HostPreferences.screenShotSaveLocation
        let previous = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        UserDefaults.standard.set(folder.path, forKey: key)
        let lane = HeldCaptureLane()
        let content = try capture(named: "Failed.png", in: directory, lane: lane)
        var reported: [any Error] = []
        let thumbnail = CaptureThumbnail(content, image: nil, parent: window, source: source, spacing: .zero,
                                         timing: ControlledThumbnailTiming()) { reported.append($0) }
        thumbnail.show()
        let save = try #require(thumbnail.menu().items.first { $0.title == "Save to Shots" })
        try FileManager.default.removeItem(at: folder)
        #expect(NSApp.sendAction(try #require(save.action), to: save.target, from: save))
        await lane.untilHeld(1)
        thumbnail.hide(animated: false)
        lane.open()
        await thumbnail.action?.value
        #expect(reported.count == 1)
        #expect(content.isResolved)
        #expect(try savedNames(in: directory) == ["Failed.png"])
    }

    @Test func aScreenshotsPreviewAndBytesAreLoadedOffTheMainActor() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try #require(CGContext(data: nil, width: 3, height: 2, bitsPerComponent: 8, bytesPerRow: 12,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let data = NSMutableData()
        let output = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(output, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(output))
        let file = directory.appendingPathComponent("capture")
        try (data as Data).write(to: file)
        let lane = HeldCaptureLane()
        let content = CapturedContent(.screenshot, file: file, name: "Shot.png", defaultFolder: directory, lane: lane)
        let loading = Task.immediate { await content.loadPreview() }
        await lane.untilHeld(1)
        #expect(content.png == nil)
        lane.open()
        let image = try #require(await loading.value)
        #expect(image.size == NSSize(width: 3, height: 2))
        #expect(content.png == data as Data)
        let provider = CaptureThumbnail.dragProvider(for: content) { _ in }
        #expect(provider.pasteboardPropertyList(forType: .png) as? Data == data as Data)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    /// Completes the real presentation pipeline without depending on WindowServer rendering.
    private func shownThumbnail(named name: String, in directory: URL)
        throws -> (CaptureThumbnail, NSWindow, NSWindow, ControlledThumbnailTiming) {
        let (window, source) = deviceWindow()
        let timing = ControlledThumbnailTiming()
        let thumbnail = CaptureThumbnail(try capture(named: name, in: directory), image: nil, parent: window,
                                         source: source, spacing: NSSize(width: 10, height: 10), timing: timing) { _ in }
        thumbnail.show()
        let shown = try #require(window.childWindows?.last)
        timing.completeAnimations()
        #expect(thumbnail.shown)
        return (thumbnail, window, shown, timing)
    }

    @Test func aThumbnailStaysWithItsWindowWhenTheWindowMoves() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (thumbnail, window, shown, timing) = try shownThumbnail(named: "Moved.png", in: directory)
        defer { window.close() }
        window.setFrameOrigin(NSPoint(x: window.frame.minX + 100, y: window.frame.minY + 50))
        let expected = NSRect(x: window.frame.maxX + 10, y: window.frame.minY + 10, width: 50, height: 80)
        #expect(shown.frame == expected)
        thumbnail.hide(animated: true)
        thumbnail.pause()
        timing.completeAnimations()
        #expect(shown.frame == expected)
        #expect(try savedNames(in: directory).isEmpty)
        thumbnail.resume()
        await CaptureThumbnail.finishAll()
        #expect(try savedNames(in: directory) == ["Moved.png"])
    }

    @Test func aHoverDoesNotBringBackAThumbnailTheUserDismissed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (thumbnail, window, _, timing) = try shownThumbnail(named: "Deleted.png", in: directory)
        defer { window.close() }
        let delete = try #require(thumbnail.menu().items.first { $0.title == "Delete" })
        #expect(NSApp.sendAction(try #require(delete.action), to: delete.target, from: delete))
        await thumbnail.action?.value
        thumbnail.pause()
        timing.completeAnimations()
        #expect(CaptureThumbnail.active.isEmpty)
        #expect(try savedNames(in: directory).isEmpty)
    }

    @Test func aNewCaptureEndsAThumbnailThatIsHiding() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (previous, window, _, timing) = try shownThumbnail(named: "Previous.png", in: directory)
        defer { window.close() }
        previous.hide(animated: true)
        let next = CaptureThumbnail(try capture(named: "Next.png", in: directory), image: nil, parent: window,
                                    source: window.frame.insetBy(dx: 20, dy: 40), spacing: .zero, timing: timing) { _ in }
        next.show()
        await previous.content.settled()
        #expect(try savedNames(in: directory) == ["Previous.png"])
        #expect(CaptureThumbnail.active.map(ObjectIdentifier.init) == [ObjectIdentifier(next)])
        previous.pause()
        timing.completeAnimations()
        #expect(CaptureThumbnail.active.map(ObjectIdentifier.init) == [ObjectIdentifier(next)])
        await CaptureThumbnail.finishAll()
    }

    @Test func quittingSavesAThumbnailThatIsHiding() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (thumbnail, window, _, timing) = try shownThumbnail(named: "Hiding.png", in: directory)
        defer { window.close() }
        thumbnail.hide(animated: true)
        #expect(await CaptureThumbnail.finishAll().isEmpty)
        timing.completeAnimations()
        #expect(try savedNames(in: directory) == ["Hiding.png"])
        #expect(CaptureThumbnail.active.isEmpty)
    }

    @Test func aDraggedCaptureIsWrittenWhenAskedAfterItsThumbnailIsGone() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let content = try capture(named: "Promised.png", in: directory)
        #expect(await content.loadPreview() == nil)
        let provider = CaptureThumbnail.dragProvider(for: content) { _ in }
        #expect(provider.writableTypes(for: .general).contains(.fileURL))
        #expect(provider.pasteboardPropertyList(forType: .png) as? Data == Data("Promised.png".utf8))
        let delegate = try #require(provider.delegate)
        let destination = directory.appendingPathComponent("Promised.png")
        let failure = await withCheckedContinuation { continuation in
            delegate.filePromiseProvider(provider, writePromiseTo: destination) { continuation.resume(returning: $0) }
        }
        #expect(failure == nil)
        #expect(try Data(contentsOf: destination) == Data("Promised.png".utf8))
    }

    @Test func aShownScreenshotShrinksBesideItsWindowAndSavesItselfWhenItsTimerEnds() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (window, source) = deviceWindow()
        defer { window.close() }
        let timing = ControlledThumbnailTiming()
        let thumbnail = CaptureThumbnail(try capture(named: "Timed.png", in: directory), image: nil, parent: window,
                                         source: source, spacing: NSSize(width: 10, height: 10), timing: timing) { _ in }
        thumbnail.show()
        let shown = try #require(window.childWindows?.last)
        #expect(shown.frame == source.insetBy(dx: -5, dy: -5))
        #expect(!thumbnail.shown && timing.deadlineDurations.isEmpty)
        timing.completeAnimations()
        #expect(thumbnail.shown)
        #expect(timing.deadlineDurations == [.seconds(5)])
        #expect(shown.frame == NSRect(x: window.frame.maxX + 10, y: window.frame.minY + 10, width: 50, height: 80))
        #expect(try savedNames(in: directory).isEmpty)
        thumbnail.pause()
        #expect(timing.deadlineDurations.isEmpty)
        timing.expireDeadlines()
        #expect(try savedNames(in: directory).isEmpty)
        thumbnail.resume()
        timing.expireDeadlines()
        #expect(try savedNames(in: directory).isEmpty)
        timing.completeAnimations()
        #expect(CaptureThumbnail.active.isEmpty)
        await thumbnail.content.settled()
        #expect(try savedNames(in: directory) == ["Timed.png"])
    }

}

/// Lets the first `passing` pieces of capture work through and holds the rest at the lane until it is opened, then runs
/// the real work on the real lane.
final class HeldCaptureLane: CaptureLane, Sendable {
    private struct State {
        var isOpen = false
        var passing: Int
        var runs = 0
        var held: [CheckedContinuation<Void, Never>] = []
        var watchers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    }
    private let state: Mutex<State>

    init(passing: Int = 0) { state = Mutex(State(passing: passing)) }

    /// How many pieces of work have reached the lane.
    var runs: Int { state.withLock { $0.runs } }

    @concurrent func run<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        await withCheckedContinuation { (passed: CheckedContinuation<Void, Never>) in
            let (proceed, ready) = state.withLock { state -> (Bool, [CheckedContinuation<Void, Never>]) in
                state.runs += 1
                let proceeds = state.isOpen || state.runs <= state.passing
                if !proceeds { state.held.append(passed) }
                let count = state.held.count
                let ready = state.watchers.filter { $0.count <= count }.map(\.continuation)
                state.watchers.removeAll { $0.count <= count }
                return (proceeds, ready)
            }
            for watcher in ready { watcher.resume() }
            if proceed { passed.resume() }
        }
        return try await performBlockingIO(work)
    }

    /// Waits until `count` pieces of work are held at the lane.
    nonisolated(nonsending) func untilHeld(_ count: Int) async {
        await withCheckedContinuation { (watcher: CheckedContinuation<Void, Never>) in
            let ready = state.withLock { state -> Bool in
                if state.held.count >= count { return true }
                state.watchers.append((count, watcher))
                return false
            }
            if ready { watcher.resume() }
        }
    }

    func open() {
        let held = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.isOpen = true
            defer { state.held.removeAll() }
            return state.held
        }
        for work in held { work.resume() }
    }
}

/// Models completion and deadlines; window/layer changes still use the production thumbnail pipeline.
@MainActor
private final class ControlledThumbnailTiming: CaptureThumbnailTiming {
    private var completions: [@MainActor () -> Void] = []
    private var deadlines: [UUID: (Duration, @MainActor () -> Void)] = [:]
    var deadlineDurations: [Duration] { deadlines.values.map { $0.0 } }

    func animateWindow(_ window: NSWindow, duration: Double, timing: CAMediaTimingFunctionName?, changes: (NSWindow) -> Void, completion: @escaping @MainActor () -> Void) {
        changes(window)
        completions.append(completion)
    }

    func animateLayer(duration: Double, timing: CAMediaTimingFunctionName, changes: () -> Void,
                      completion: @escaping @MainActor () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changes()
        CATransaction.commit()
        completions.append(completion)
    }

    func fadeIn(_ layer: CALayer, duration: Double, completion: @escaping @MainActor () -> Void) {
        completions.append(completion)
    }

    func schedule(after duration: Duration, action: @escaping @MainActor () -> Void) -> () -> Void {
        let identifier = UUID()
        deadlines[identifier] = (duration, action)
        return { [weak self] in self?.deadlines[identifier] = nil }
    }

    func completeAnimations() {
        while !completions.isEmpty { completions.removeFirst()() }
    }

    func expireDeadlines() {
        let current = deadlines.values.map { $0.1 }
        deadlines.removeAll()
        for action in current { action() }
    }
}
