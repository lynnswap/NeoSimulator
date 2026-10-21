import AppKit
import AVFoundation
import Foundation
import ImageIO
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
        // A recording to a chosen file reserves that name until it finishes.
        _ = try store.start(to: .file(directory.appendingPathComponent("Recording #2.mov")), process: { _ in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "trap 'exit 0' INT; echo 'Recording started' >&2; while :; do sleep 0.05; done"]
            return process
        }, onFinished: {})
        var handedOver: [(url: URL, afterStop: Bool)] = []
        var stopped = false, finished = false
        let recording = try store.start(to: .capture { handedOver.append(($0, stopped)) }, process: { url in
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
        #expect(handedOver.isEmpty)
        stopped = true
        recording.stop()
        try await recording.waitUntilFinished()
        for _ in 0..<200 where !finished { try await Task.sleep(for: .milliseconds(10)) }
        #expect(errors.isEmpty)
        let temporary = try #require(handedOver.first)
        #expect(handedOver.count == 1 && temporary.afterStop)
        let capture = CapturedContent(.movie, file: temporary.url, name: "Recording.mov", defaultFolder: directory,
                                      isReserved: store.isReserved)
        #expect(try capture.saveToDefaultLocation().lastPathComponent == "Recording #3.mov")
        #expect(try Data(contentsOf: directory.appendingPathComponent("Recording #3.mov")) == Data(contentsOf: movie))
        await store.finishAll()
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
            // The brightest color channel of the first frame, which is black.
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
        // The fixture's frames are 0.1 seconds apart, which floating-point
        // differences of their times must not stretch to 0.11.
        let every = try await export(frameRate: 10)
        #expect(every.count == 12 && every.loop == 0)
        // Dithered in the movie's color space, black stays nearly black; a
        // linear working space lifts it to about 48.
        #expect(every.brightest <= 12)
        #expect(Array(every.delays.dropLast()) == Array(repeating: 0.1, count: 11))
        let thinned = try await export(frameRate: 5)
        #expect(thinned.count == 6)
        #expect(thinned.delays.first == 0.2)
    }

    /// Writes a short H.264 QuickTime movie.
    /// Writes a short H.264 QuickTime movie of black frames tagged BT.709.
    private func writeMovie(to url: URL, frames: Int = 3) async throws {
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
            CVPixelBufferLockBaseAddress(pixels, [])
            for row in 0..<64 {
                (CVPixelBufferGetBaseAddress(pixels)! + row * CVPixelBufferGetBytesPerRow(pixels))
                    .assumingMemoryBound(to: UInt32.self).update(repeating: 0xFF00_0000, count: 64)
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
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

/// Thumbnails share one app-wide list, so their tests run one at a time.
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
        // A quarter of the screen plus 10 points, beside the window's bottom.
        #expect(place(NSRect(x: 80, y: 100, width: 440, height: 980)) == (NSRect(x: 530, y: 120, width: 110, height: 210), .right))
        #expect(place(NSRect(x: 1400, y: 100, width: 190, height: 980)) == (NSRect(x: 1280, y: 120, width: 110, height: 210), .left))
        #expect(place(NSRect(x: 20, y: 100, width: 1560, height: 980)) == (NSRect(x: 1470, y: 100, width: 110, height: 210), .over))
        // Kept above the Dock by the horizontal spacing.
        #expect(place(NSRect(x: 80, y: 40, width: 440, height: 980)).0.minY == 90)
        // Full screen: right of the device screen, else the lower right corner
        // of that screen, which can be below the main screen.
        #expect(place(screen, fullScreen: true) == (NSRect(x: 510, y: 200, width: 110, height: 210), .over))
        let lower = CaptureThumbnail.placement(source: NSRect(x: 1200, y: -1000, width: 400, height: 800),
                                               window: NSRect(x: 0, y: -1200, width: 1600, height: 1200), fullScreen: true,
                                               screen: NSRect(x: 0, y: -1200, width: 1600, height: 1200),
                                               visible: NSRect(x: 0, y: -1200, width: 1600, height: 1200), spacing: spacing)
        #expect(lower.frame.origin == NSPoint(x: 1486, y: -1196))
    }

    /// A temporary capture file and a folder to save it in.
    private func capture(_ kind: CapturedContent.Kind = .screenshot, named name: String = "Shot.png",
                         in directory: URL) throws -> CapturedContent {
        let file = directory.appendingPathComponent(UUID().uuidString)
        try Data(name.utf8).write(to: file)
        let folder = directory.appendingPathComponent("Saved", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return CapturedContent(kind, file: file, name: name, defaultFolder: folder)
    }

    /// A visible window that fits the screen, as the test machine's screen
    /// can be small, and a device screen inside it.
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

    @Test func aNewCaptureEndsTheShownThumbnailAndSavesIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (window, source) = deviceWindow()
        defer { window.close() }
        let first = CaptureThumbnail(try capture(named: "First.png", in: directory), image: nil, parent: window,
                                     source: source, spacing: .zero) { _ in }
        first.show()
        #expect(CaptureThumbnail.active.map(ObjectIdentifier.init) == [ObjectIdentifier(first)])
        // Another window's capture also ends it, as Simulator.app keeps one app-wide list.
        let (other, _) = deviceWindow(offset: 300)
        defer { other.close() }
        let second = CaptureThumbnail(try capture(named: "Second.png", in: directory), image: nil, parent: other,
                                      source: source, spacing: .zero) { _ in }
        second.show()
        #expect(try savedNames(in: directory) == ["First.png"])
        #expect(CaptureThumbnail.active.map(ObjectIdentifier.init) == [ObjectIdentifier(second)])
        // Resizing the device window ends its thumbnail.
        other.setFrame(other.frame.insetBy(dx: -20, dy: -20), display: false)
        #expect(try savedNames(in: directory) == ["First.png", "Second.png"])
        #expect(CaptureThumbnail.active.isEmpty)

        let third = CaptureThumbnail(try capture(named: "Third.png", in: directory), image: nil, parent: window,
                                     source: source, spacing: .zero) { _ in }
        third.show()
        CaptureThumbnail.finishAll()
        #expect(try savedNames(in: directory) == ["First.png", "Second.png", "Third.png"])
        #expect(CaptureThumbnail.active.isEmpty)
    }

    @Test func thumbnailMenusOfferSimulatorAppsActions() throws {
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
            "Open in Mail", "Open in Preview", "Open in Photos", "-", "Show in Finder", "Delete", "-", "Close",
        ])
        let movie = thumbnail(try capture(.movie, named: "Movie.mov", in: directory)).menu()
        #expect(titles(movie) == [
            "Save to Shots", "Save to Desktop", "Save to Documents", "Save as Animated GIF",
            "Save Copy as Animated GIF", "-", "Show in Finder", "Delete", "-", "Close",
        ])
        #expect(movie.items.filter(\.isAlternate).map(\.keyEquivalentModifierMask) == [.option])
        // The Desktop has its own item, so a Desktop screenshot folder adds none.
        UserDefaults.standard.set(CaptureFile.desktop?.path, forKey: key)
        #expect(Array(titles(screenshot.menu()).prefix(3)) == ["Save to Desktop", "Save to Documents", "Copy to Clipboard"])
        UserDefaults.standard.set(shots.path, forKey: key)

        func choose(_ title: String, in thumbnail: CaptureThumbnail) throws {
            let item = try #require(thumbnail.menu().items.first { $0.title == title })
            #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
        }
        let deleted = try capture(in: directory)
        try choose("Delete", in: thumbnail(deleted))
        #expect(!FileManager.default.fileExists(atPath: deleted.file.path))
        try choose("Save to Shots", in: thumbnail(try capture(named: "Custom.png", in: directory)))
        #expect(FileManager.default.fileExists(atPath: shots.appendingPathComponent("Custom.png").path))
        try choose("Close", in: thumbnail(try capture(named: "Closed.png", in: directory)))
        #expect(try savedNames(in: directory) == ["Closed.png"])
    }

    @Test func aCompletedDragDeliversTheCaptureAndACancelledOneSavesIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 300, height: 600), styleMask: .titled,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // The destination may fulfil the promise after the drag ends, even
        // after the capture was saved.
        let delivered = try capture(named: "Dragged.png", in: directory)
        CaptureThumbnail(delivered, image: nil, parent: window, source: .zero, spacing: .zero) { _ in }.dragEnded(.copy)
        #expect(try savedNames(in: directory).isEmpty)
        // Quitting saves captures whose promises are still unfulfilled.
        let unclaimed = try capture(named: "Unclaimed.png", in: directory)
        CaptureThumbnail(unclaimed, image: nil, parent: window, source: .zero, spacing: .zero) { _ in }.dragEnded(.copy)
        #expect(CaptureThumbnail.finishAll().isEmpty)
        #expect(try savedNames(in: directory) == ["Dragged.png", "Unclaimed.png"])
        let destination = directory.appendingPathComponent("Dragged.png")
        try delivered.deliver(to: destination)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        // A delivery after the capture was saved copies the saved file.
        let late = try capture(named: "Late.png", in: directory)
        try late.saveToDefaultLocation()
        try late.deliver(to: directory.appendingPathComponent("Late.png"))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Late.png").path))
        #expect(try savedNames(in: directory) == ["Dragged.png", "Late.png", "Unclaimed.png"])
        // An animated GIF takes the next free name.
        try Data().write(to: directory.appendingPathComponent("Saved/Movie.gif"))
        #expect(try CaptureFile.unusedFile(in: directory.appendingPathComponent("Saved"), named: "Movie.gif").lastPathComponent
                == "Movie #2.gif")
        // A name another export is writing is taken too.
        #expect(try CaptureFile.unusedFile(in: directory.appendingPathComponent("Saved"), named: "Movie.gif",
                                           isReserved: { $0.lastPathComponent == "Movie #2.gif" }).lastPathComponent == "Movie #3.gif")
        let cancelled = try capture(named: "Cancelled.png", in: directory)
        CaptureThumbnail(cancelled, image: nil, parent: window, source: .zero, spacing: .zero) { _ in }.dragEnded([])
        #expect(try savedNames(in: directory) == ["Cancelled.png", "Dragged.png", "Late.png", "Movie.gif", "Unclaimed.png"])
    }

    /// A shown thumbnail beside a visible window, once its appearance ended.
    private func shownThumbnail(named name: String, in directory: URL) async throws -> (CaptureThumbnail, NSWindow, NSWindow) {
        let (window, source) = deviceWindow()
        let thumbnail = CaptureThumbnail(try capture(named: name, in: directory), image: nil, parent: window,
                                         source: source, spacing: NSSize(width: 10, height: 10)) { _ in }
        thumbnail.show()
        let shown = try #require(window.childWindows?.last)
        for _ in 0..<100 where !thumbnail.shown { try await Task.sleep(for: .milliseconds(20)) }
        #expect(thumbnail.shown)
        return (thumbnail, window, shown)
    }

    @Test func aThumbnailStaysWithItsWindowWhenTheWindowMoves() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (thumbnail, window, shown) = try await shownThumbnail(named: "Moved.png", in: directory)
        defer { window.close() }
        window.setFrameOrigin(NSPoint(x: window.frame.minX + 100, y: window.frame.minY + 50))
        let expected = NSRect(x: window.frame.maxX + 10, y: window.frame.minY + 10, width: 50, height: 80)
        #expect(shown.frame == expected)
        // A hover during the hide brings it back beside the moved window.
        thumbnail.hide(animated: true)
        try await Task.sleep(for: .milliseconds(100))
        thumbnail.pause()
        try await Task.sleep(for: .milliseconds(300))
        #expect(shown.frame == expected)
        thumbnail.resume()
        CaptureThumbnail.finishAll()
        #expect(try savedNames(in: directory) == ["Moved.png"])
    }

    @Test func quittingSavesAThumbnailThatIsHiding() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (thumbnail, window, _) = try await shownThumbnail(named: "Hiding.png", in: directory)
        defer { window.close() }
        thumbnail.hide(animated: true)
        #expect(CaptureThumbnail.finishAll().isEmpty)
        #expect(try savedNames(in: directory) == ["Hiding.png"])
        #expect(CaptureThumbnail.active.isEmpty)
    }

    @Test func aDraggedCaptureIsWrittenWhenAskedAfterItsThumbnailIsGone() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let content = try capture(named: "Promised.png", in: directory)
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
        let thumbnail = CaptureThumbnail(try capture(named: "Timed.png", in: directory), image: nil, parent: window,
                                         source: source, spacing: NSSize(width: 10, height: 10)) { _ in }
        thumbnail.show()
        let shown = try #require(window.childWindows?.last)
        // It starts over the device screen and shrinks beside the window.
        #expect(shown.frame == source.insetBy(dx: -5, dy: -5))
        for _ in 0..<100 where !thumbnail.shown { try await Task.sleep(for: .milliseconds(20)) }
        #expect(shown.frame == NSRect(x: window.frame.maxX + 10, y: window.frame.minY + 10, width: 50, height: 80))
        #expect(try savedNames(in: directory).isEmpty)
        for _ in 0..<400 where !CaptureThumbnail.active.isEmpty { try await Task.sleep(for: .milliseconds(25)) }
        #expect(CaptureThumbnail.active.isEmpty)
        #expect(try savedNames(in: directory) == ["Timed.png"])
    }

}
