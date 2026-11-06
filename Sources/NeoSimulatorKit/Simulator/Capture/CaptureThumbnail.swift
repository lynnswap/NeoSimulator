import AppKit
import AVFoundation
import CoreImage
import ImageIO
import NeoSimulatorDeviceIO
import QuartzCore
import UniformTypeIdentifiers

/// Temporary screenshot or recording, owned until saved, deleted, or handed off.
///
/// This object is the capture's one owner. File work runs away from the main actor, one operation at a time in the order
/// they were asked for, and each reads what the one before it settled. So a save, a delete and a late delivery that race
/// cannot move or remove the file twice, and none repeats what another attempted.
@MainActor
package final class CapturedContent {
    package enum Kind { case screenshot, movie }

    package let kind: Kind
    package let owner: UUID?
    /// The temporary capture, which saving moves and deleting removes.
    package let file: URL
    /// The file name it is saved under.
    package let name: String
    /// Where dismissing the thumbnail saves it, chosen when it was captured.
    package let defaultFolder: URL
    /// Holds a name against recordings for as long as saving may take it.
    private let claim: CaptureFile.Claim
    private let lane: any CaptureLane
    private let locations = CaptureFile.Locations()
    /// Whether the capture has been saved, deleted, or handed to another app. Set once that has succeeded.
    package private(set) var isResolved = false
    /// Where it was saved, from which a late drag delivery copies it.
    private var saved: URL?
    /// Whether a save nobody asked for has failed and been reported. Only someone asking moves the capture after that.
    private var automaticSaveFailed = false
    /// The animated GIF being written from it, whose name other exports must not take.
    private var exportingGIF: URL?
    /// A screenshot's bytes, read before its thumbnail appears, because a drag cannot wait to offer them.
    package private(set) var png: Data?
    private var lastOperation: Task<Void, Never>?
    private var operations = 0
    /// Captures with file work in flight, which quitting waits for.
    private static var working: [ObjectIdentifier: CapturedContent] = [:]

    package init(_ kind: Kind, file: URL, name: String, defaultFolder: URL, owner: UUID? = nil, lane: any CaptureLane = BlockingIOLane(),
         claim: @escaping CaptureFile.Claim = { _ in {} }) {
        self.kind = kind
        self.owner = owner
        self.file = file
        self.name = name
        self.defaultFolder = defaultFolder
        self.lane = lane
        self.claim = claim
    }

    /// Runs after the operations asked for so far. It goes on if its caller is cancelled, because its outcome decides
    /// who owns the file.
    private func inOrder<Value: Sendable>(_ operation: @escaping @MainActor () async throws -> Value) async throws -> Value {
        let previous = lastOperation
        let task = Task { @MainActor [self] in
            await previous?.value
            defer { locations.clear() }
            return try await operation()
        }
        operations += 1
        Self.working[ObjectIdentifier(self)] = self
        lastOperation = Task { @MainActor [self] in
            _ = await task.result
            operations -= 1
            if operations == 0 { Self.working.removeValue(forKey: ObjectIdentifier(self)) }
        }
        return try await task.value
    }

    /// Waits for the operations asked for so far.
    package func settled() async { await lastOperation?.value }

    /// Waits for captures' file work in flight.
    package static func finishOperations(owner: UUID?) async {
        for content in working.values where owner == nil || content.owner == owner { await content.settled() }
    }

    /// The captures with file work in flight.
    fileprivate static var inFlight: [CapturedContent] { Array(working.values) }

    fileprivate var unfinishedFiles: [URL] { [saved ?? file] + locations.locations + [exportingGIF].compactMap(\.self) }

    /// Reads a screenshot and returns its decoded image, away from the main actor, and holds its bytes.
    package func loadPreview() async -> NSImage? {
        let file = file, lane = lane
        let loaded = try? await inOrder {
            try await lane.run { () -> (Data, CGImage?) in
                let png = try Data(contentsOf: file)
                let image = CGImageSourceCreateWithData(png as CFData, nil).flatMap {
                    CGImageSourceCreateImageAtIndex($0, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
                }
                return (png, image)
            }
        }
        guard let loaded else { return nil }
        png = loaded.0
        return loaded.1.map { NSImage(cgImage: $0, size: .zero) }
    }

    /// The temporary file's bytes.
    package func read() async throws -> Data {
        let file = file, lane = lane
        return try await inOrder { try await lane.run { try Data(contentsOf: file) } }
    }

    /// Moves the capture into `folder`, numbering a taken name. A failure
    /// keeps the capture where it is and names that location.
    @discardableResult
    package func save(into folder: URL) async throws -> URL {
        try await inOrder { [self] in
            guard !isResolved else { throw SimulatorError.operation("\(name) was already saved or deleted.") }
            return try await move(into: folder)
        }
    }

    @discardableResult
    package func saveToDefaultLocation() async throws -> URL { try await save(into: defaultFolder) }

    /// Saves the capture where dismissing would, once, unless something has resolved it by the time this runs.
    package func saveIfUnresolved() async throws {
        try await inOrder { [self] in
            guard !isResolved, !automaticSaveFailed else { return }
            try await saveAutomatically()
        }
    }

    /// Does the same for a capture that a drop may have taken through its file URL, which moved the temporary file away
    /// and resolves it.
    package func settleAfterDrop() async throws {
        try await inOrder { [self] in
            guard !isResolved, !automaticSaveFailed else { return }
            let file = file
            guard try await lane.run({ FileManager.default.fileExists(atPath: file.path) }) else {
                isResolved = true
                return
            }
            try await saveAutomatically()
        }
    }

    private func saveAutomatically() async throws {
        do { _ = try await move(into: defaultFolder) }
        catch {
            automaticSaveFailed = !isResolved
            throw error
        }
    }

    private func move(into folder: URL) async throws -> URL {
        do {
            let saved = try await CaptureFile.move(file, into: folder, named: name, lane: lane, claim: claim, locations: locations)
            isResolved = true
            self.saved = saved
            return saved
        } catch let failure as CaptureLeftBehind {
            isResolved = true
            saved = failure.destination
            throw failure
        }
    }

    package func delete() async throws {
        try await inOrder { [self] in
            guard !isResolved else { return }
            let file = file
            try await lane.run { try FileManager.default.removeItem(at: file) }
            isResolved = true
        }
    }

    /// Writes the capture to `destination`, which a drag or another app asked
    /// for, and gives up the temporary file.
    package func deliver(to destination: URL) async throws {
        try await inOrder { [self] in
            guard let release = try await claim(destination) else {
                throw SimulatorError.operation("Could not save \(name) to \(destination.path): a recording or another capture is saving to that file.")
            }
            defer { release() }
            if let saved {
                let locations = locations
                return try await lane.run { try CaptureFile.copy(saved, to: destination, locations: locations) }
            }
            guard !isResolved else { throw SimulatorError.operation("\(name) was already saved or deleted.") }
            let file = file
            let locations = locations
            do {
                try await lane.run { try CaptureFile.relocate(file, to: destination, locations: locations) }
                isResolved = true
                saved = destination
            } catch let failure as CaptureLeftBehind {
                isResolved = true
                saved = failure.destination
                throw failure
            }
        }
    }

    /// Names an animated GIF where the movie is saved, saving a kept movie first, and begins writing the GIF, which takes
    /// its turn after this returns. As an operation of this capture it is waited for and located like any other, and
    /// `report` receives its failure. The temporary movie goes only after a successful export; a failed one saves it.
    fileprivate func beginAnimatedGIF(keepingMovie: Bool, report: @escaping (Error) -> Void) async throws {
        try await inOrder { [self] in
            var folder = defaultFolder, movieName = name
            if keepingMovie {
                guard !isResolved else { throw SimulatorError.operation("\(name) was already saved or deleted.") }
                let movie = try await move(into: defaultFolder)
                folder = movie.deletingLastPathComponent()
                movieName = movie.lastPathComponent
            }
            let gif = try await CaptureFile.unusedFile(in: folder, named: (movieName as NSString).deletingPathExtension + ".gif",
                                                       lane: lane) { candidate in
                guard !Self.working.values.contains(where: { $0.exportingGIF == candidate }) else { return false }
                exportingGIF = candidate
                return true
            }
            Task.immediate { [self] in
                _ = try? await inOrder { [self] in
                    defer { exportingGIF = nil }
                    await writeAnimatedGIF(gif, keepingMovie: keepingMovie, report: report)
                }
            }
        }
    }

    private func writeAnimatedGIF(_ gif: URL, keepingMovie: Bool, report: (Error) -> Void) async {
        let movie = saved ?? file, lane = lane
        do {
            try await CaptureFile.write(to: gif, extension: "gif", lane: lane, locations: locations) { staged in
                try await AnimatedGIF.export(movie, to: staged, options: .preferred, lane: lane)
            }
            guard !keepingMovie, !isResolved else { return }
            try await lane.run { try FileManager.default.removeItem(at: movie) }
            isResolved = true
        } catch {
            hostLog("Could not save an animated GIF: \(error.localizedDescription)")
            var failure = error
            if !keepingMovie, !isResolved, !automaticSaveFailed {
                do { try await saveAutomatically() }
                catch { failure = SimulatorError.operation("\(failure.localizedDescription) \(error.localizedDescription)") }
            }
            report(failure)
        }
    }

    /// Hands the screenshot to another app as a file of its own, and removes
    /// the temporary capture.
    fileprivate func handOff() async throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try await lane.run { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let copy = folder.appendingPathComponent(name)
        do {
            try await deliver(to: copy)
        } catch {
            throw await CaptureFile.removing(folder, after: error, lane: lane)
        }
        return copy
    }
}

/// Runs presentation effects and deadlines independently of the thumbnail's lifecycle.
@MainActor
package protocol CaptureThumbnailTiming {
    func animateWindow(_ window: NSWindow, duration: Double, timing: CAMediaTimingFunctionName?, changes: (NSWindow) -> Void, completion: @escaping @MainActor () -> Void)
    func animateLayer(duration: Double, timing: CAMediaTimingFunctionName, changes: () -> Void,
                      completion: @escaping @MainActor () -> Void)
    func fadeIn(_ layer: CALayer, duration: Double, completion: @escaping @MainActor () -> Void)
    func schedule(after duration: Duration, action: @escaping @MainActor () -> Void) -> () -> Void
}

@MainActor
private struct AppKitCaptureThumbnailTiming: CaptureThumbnailTiming {
    func animateWindow(_ window: NSWindow, duration: Double, timing: CAMediaTimingFunctionName?, changes: (NSWindow) -> Void, completion: @escaping @MainActor () -> Void) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            if let timing { context.timingFunction = CAMediaTimingFunction(name: timing) }
            changes(window.animator())
        }, completionHandler: { MainActor.assumeIsolated { completion() } })
    }

    func animateLayer(duration: Double, timing: CAMediaTimingFunctionName, changes: () -> Void,
                      completion: @escaping @MainActor () -> Void) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: timing))
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion() } }
        changes()
        CATransaction.commit()
    }

    func fadeIn(_ layer: CALayer, duration: Double, completion: @escaping @MainActor () -> Void) {
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion() } }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(fade, forKey: "fadeIn")
        CATransaction.commit()
    }

    func schedule(after duration: Duration, action: @escaping @MainActor () -> Void) -> () -> Void {
        let task = Task {
            do { try await Task.sleep(for: duration) } catch { return }
            action()
        }
        return { task.cancel() }
    }
}

/// Floating capture preview. Dismissal saves to the default folder;
/// menu actions and dragging can consume the capture instead.
@MainActor
package final class CaptureThumbnail: NSObject {
    /// A new capture dismisses existing thumbnails.
    package private(set) static var active: [CaptureThumbnail] = []
    /// Captures whose thumbnail has ended but that wait for a drag's file
    /// promise; quitting saves those still unresolved.
    private static var pending: [CapturedContent] = []
    /// Thumbnails whose menu action is using their capture, which quitting waits for.
    private static var performing: Set<CaptureThumbnail> = []
    /// Reports a failure of a thumbnail whose device window has closed.
    package static var reportDetached: (Error) -> Void = { hostLog($0.localizedDescription) }
    /// Set while NeoSimulator quits: captures are saved instead of shown.
    package static var savesImmediately = false

    package enum Position { case right, left, over }

    package let content: CapturedContent
    private weak var parent: NSWindow?
    private let window: NSWindow
    private let view: CaptureThumbnailView
    private let source: NSRect
    private let spacing: NSSize
    /// The device screen's corner radius in points, which the thumbnail
    /// shrinks with and slides past when it hides.
    private let cornerRadius: CGFloat
    private var position = Position.right
    private var destination = NSRect.zero
    /// The destination relative to the device window, which can move.
    private var parentOffset = NSPoint.zero
    private let report: (Error) -> Void
    private let timing: any CaptureThumbnailTiming
    private var cancelTimer: (() -> Void)?
    private var pauses = 0
    private var hiding = false
    /// Whether it has appeared and its timer runs.
    package private(set) var shown = false
    private var dismissedExplicitly = false
    private var finished = false
    private var observers: [any NSObjectProtocol] = []
    private var moveCount = 0
    private var moveWatch: Task<Void, Never>?
    /// The menu action last chosen, which owns the capture until it ends.
    package private(set) var action: Task<Void, Never>?

    /// Animates from `source` in screen coordinates. `rotation` corrects the unrotated framebuffer.
    /// `spacing` is the offset from the device window; `report` receives save/use failures.
    package init(_ content: CapturedContent, image: NSImage?, parent: NSWindow, source: NSRect, rotation: Double = 0,
         cornerRadius: CGFloat = 0, spacing: NSSize, timing: any CaptureThumbnailTiming = AppKitCaptureThumbnailTiming(),
         report: @escaping (Error) -> Void) {
        self.content = content
        self.timing = timing
        self.parent = parent
        self.source = source
        self.cornerRadius = cornerRadius
        self.spacing = content.kind == .movie ? .zero : spacing
        self.report = report
        window = NSWindow(contentRect: source, styleMask: .borderless, backing: .buffered, defer: false)
        view = CaptureThumbnailView(content: content, image: image, rotation: rotation, cornerRadius: cornerRadius,
                                    timing: timing, report: report)
        super.init()
        window.animationBehavior = .none
        window.isMovableByWindowBackground = false
        window.hasShadow = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.owner = self
    }

    /// Shows the thumbnail after dismissing every other one.
    package func show() {
        for other in Self.active { other.hide(animated: false) }
        Self.active.append(self)
        guard let parent else { finish(); return }
        destination = placement(in: parent)
        parentOffset = NSPoint(x: destination.minX - parent.frame.minX, y: destination.minY - parent.frame.minY)
        observeParent(parent)
        parent.addChildWindow(window, ordered: .above)
        switch content.kind {
        case .screenshot:
            window.setFrame(source.insetBy(dx: -5, dy: -5), display: true)
            window.orderFront(nil)
            view.flash { [weak self] in
                guard let self, !self.hiding else { return }
                self.timing.animateWindow(self.window, duration: 0.3, timing: .easeInEaseOut, changes: { target in
                    target.setFrame(self.currentDestination, display: true)
                    self.view.showAsThumbnail()
                }, completion: { [weak self] in self?.didShow() })
            }
        case .movie:
            window.setFrame(destination, display: true)
            view.showAsThumbnail()
            window.orderFront(nil)
            view.fadeIn(duration: 1) { [weak self] in self?.didShow() }
        }
    }

    /// The destination, following the device window when it moved.
    private var currentDestination: NSRect {
        guard let parent, position != .over || !parent.styleMask.contains(.fullScreen) else { return destination }
        return NSRect(origin: NSPoint(x: parent.frame.minX + parentOffset.x, y: parent.frame.minY + parentOffset.y),
                      size: destination.size)
    }

    private func placement(in parent: NSWindow) -> NSRect {
        let screen = parent.screen ?? NSScreen.main
        let placement = Self.placement(source: source, window: parent.frame, fullScreen: parent.styleMask.contains(.fullScreen),
                                       screen: screen?.frame ?? .infinite, visible: screen?.visibleFrame ?? .infinite,
                                       spacing: spacing)
        position = placement.position
        return placement.frame
    }

    /// Places a quarter-size preview beside the window, falling back to its lower-right corner.
    /// Full-screen placement uses the display bounds and stays above the Dock.
    package static func placement(source: NSRect, window frame: NSRect, fullScreen: Bool, screen bounds: NSRect,
                          visible: NSRect, spacing: NSSize) -> (frame: NSRect, position: Position) {
        let size = NSSize(width: source.width * 0.25 + 10, height: source.height * 0.25 + 10)
        var origin: NSPoint
        let position: Position
        if fullScreen {
            position = .over
            origin = source.maxX + spacing.width + size.width < bounds.maxX
                ? NSPoint(x: source.maxX + spacing.width, y: source.minY)
                : NSPoint(x: frame.maxX - size.width - 4, y: bounds.minY + 4)
        } else if frame.maxX + spacing.width + size.width < bounds.maxX {
            position = .right
            origin = NSPoint(x: frame.maxX + spacing.width, y: frame.minY + spacing.height)
        } else if frame.minX - spacing.width - size.width > bounds.minX {
            position = .left
            origin = NSPoint(x: frame.minX - spacing.width - size.width, y: frame.minY + spacing.height)
        } else {
            position = .over
            origin = NSPoint(x: frame.maxX - size.width, y: frame.minY)
        }
        if origin.y < visible.minY { origin.y = visible.minY + spacing.width }
        return (NSRect(origin: origin, size: size), position)
    }

    private func didShow() {
        guard !finished, !hiding, let parent else { return }
        shown = true
        // A thumbnail beside the window hides by sliding under it.
        if position != .over, window.parent === parent {
            parent.removeChildWindow(window)
            parent.addChildWindow(window, ordered: .below)
        }
        startTimer()
    }

    // MARK: Dismissal

    private var duration: Duration {
        guard content.kind == .movie else { return .seconds(5) }
        let seconds = view.movieDuration.map { Int($0) } ?? 0
        return .seconds(max(seconds, 5))
    }

    private func startTimer() {
        cancelTimer?()
        guard shown, pauses == 0, !finished else { return }
        cancelTimer = timing.schedule(after: duration) { [weak self] in self?.hide(animated: true) }
    }

    /// Hover, an open menu, a drag, or a moving device window keeps the
    /// thumbnail up; the timer starts again when they end.
    package func pause() {
        pauses += 1
        cancelTimer?()
        // Only the timer's hide can be taken back; a capture the user used is done.
        if hiding, !finished, !dismissedExplicitly, !content.isResolved { cancelHide() }
    }

    package func resume() {
        pauses = max(pauses - 1, 0)
        if pauses == 0 { startTimer() }
    }

    private func cancelHide() {
        hiding = false
        timing.animateWindow(window, duration: 0.1, timing: nil, changes: { target in
            target.setFrame(currentDestination, display: true)
            target.alphaValue = 1
        }, completion: {})
    }

    /// Ends the thumbnail. Unless the user dismissed it through its menu or a
    /// drag, the capture is saved to its default location.
    package func hide(animated: Bool) {
        // Ending at once also ends a hide in progress.
        guard !finished, !hiding || !animated else { return }
        hiding = true
        cancelTimer?()
        guard animated, shown, let parent, parent.isVisible else { finish(); return }
        // Beside the window, it slides under it from where it is now.
        let frame = window.frame
        let distance = frame.width + spacing.width + cornerRadius
        timing.animateWindow(window, duration: 0.35, timing: .easeInEaseOut, changes: { target in
            switch position {
            case .right: target.setFrame(frame.offsetBy(dx: -distance, dy: 0), display: true)
            case .left: target.setFrame(frame.offsetBy(dx: distance, dy: 0), display: true)
            case .over: target.alphaValue = 0
            }
        }, completion: { [weak self] in
            guard let self, self.hiding else { return }
            self.finish()
        })
    }

    /// Ends the thumbnail after the user used the capture.
    private func dismiss() {
        dismissedExplicitly = true
        hide(animated: true)
    }

    /// Ends the thumbnail now. Saving what it holds has then begun, in the order asked for, and the returned task ends with
    /// its failure. A menu action in progress keeps the capture instead, and saves it if it fails.
    @discardableResult
    private func finish(reporting: Bool = true) -> Task<(any Error)?, Never>? {
        guard !finished else { return nil }
        finished = true
        hiding = true
        cancelTimer?()
        moveWatch?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        view.stop()
        parent?.removeChildWindow(window)
        window.orderOut(nil)
        window.close()
        Self.active.removeAll { $0 === self }
        guard !dismissedExplicitly, !Self.performing.contains(self), !content.isResolved else { return nil }
        let content = content, report = report
        return Task.immediate {
            do {
                try await content.saveIfUnresolved()
                return nil
            } catch {
                hostLog(error.localizedDescription)
                if reporting { report(error) }
                return error
            }
        }
    }

    /// Ends thumbnails before it first waits, then saves unresolved captures before quitting, and waits for every file
    /// operation of theirs in flight, including an animated GIF being written. Failures of what it began are returned;
    /// those of what was already running go to whoever asked for it.
    @discardableResult
    package static func finishAll(owner: UUID? = nil) async -> [Error] {
        func belongs(_ content: CapturedContent) -> Bool { owner == nil || content.owner == owner }
        let saves = active.filter { belongs($0.content) }.compactMap { $0.finish(reporting: false) }
        let settling = pending.filter(belongs).map { content in
            Task.immediate { () -> (any Error)? in
                do { try await content.settleAfterDrop(); return nil } catch { return error }
            }
        }
        pending.removeAll(where: belongs)
        for thumbnail in performing where belongs(thumbnail.content) { await thumbnail.action?.value }
        var failures: [Error] = []
        for task in saves + settling { if let failure = await task.value { failures.append(failure) } }
        await CapturedContent.finishOperations(owner: owner)
        return failures
    }

    /// What `finishing` reports if it ends before `deadline`. A disk that holds it longer does not hold a quit, which then
    /// says where each capture remains; the work carries on until the process ends, and cannot lose the original.
    package static func failures(of finishing: Task<[Error], Never>, before deadline: ContinuousClock.Instant,
                                 owner: UUID? = nil) async -> [Error] {
        if await finishing.ends(before: deadline) { return await finishing.value }
        let locations = unfinishedCaptures(owner: owner).map(\.path).joined(separator: "\n")
        let detail = locations.isEmpty ? "" : " Check these file locations:\n\(locations)"
        return [SimulatorError.operation("Capture file work did not finish before the context stopped.\(detail)")]
    }

    /// Original, saved and staged files that unfinished capture work may still be using.
    package static func unfinishedCaptures(owner: UUID? = nil) -> [URL] {
        func belongs(_ content: CapturedContent) -> Bool { owner == nil || content.owner == owner }
        let unresolved = (active.map(\.content) + pending).filter { belongs($0) && !$0.isResolved }.map(\.file)
        let working = CapturedContent.inFlight.filter(belongs).flatMap(\.unfinishedFiles)
        return Set(unresolved + working).sorted { $0.path < $1.path }
    }

    // MARK: Device window

    private func observeParent(_ parent: NSWindow) {
        let center = NotificationCenter.default
        let ends: [Notification.Name] = [
            NSWindow.didResizeNotification, NSWindow.willStartLiveResizeNotification,
            NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification,
            NSWindow.willMiniaturizeNotification, NSWindow.willCloseNotification,
        ]
        for name in ends {
            observers.append(center.addObserver(forName: name, object: parent, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.hide(animated: false) }
            })
        }
        observers.append(center.addObserver(forName: NSWindow.willMoveNotification, object: parent, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.parentWillMove() }
        })
        observers.append(center.addObserver(forName: NSWindow.didMoveNotification, object: parent, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.moveCount += 1 }
        })
    }

    /// Waits for the window to stop moving for one second before dismissing.
    private func parentWillMove() {
        guard moveWatch == nil else { return }
        pause()
        moveWatch = Task { [weak self] in
            var count = -1
            while let self, !Task.isCancelled, count != self.moveCount {
                count = self.moveCount
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
            guard let self, !Task.isCancelled else { return }
            self.moveWatch = nil
            self.resume()
        }
    }

    // MARK: Menu actions

    package func menu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: @escaping @MainActor (CaptureThumbnail) async throws -> Void) -> NSMenuItem {
            let item = menu.addItem(withTitle: title, action: #selector(performAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = CaptureThumbnailAction(action)
            return item
        }
        if let custom = Self.customFolder() {
            _ = add("Save to \(custom.lastPathComponent)") { try await $0.content.save(into: custom) }
        }
        if let desktop = CaptureFile.desktop {
            _ = add("Save to Desktop") { try await $0.content.save(into: desktop) }
        }
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            _ = add("Save to Documents") { try await $0.content.save(into: documents) }
        }
        switch content.kind {
        case .screenshot:
            _ = add("Copy to Clipboard") { thumbnail in
                let png = try await thumbnail.content.read()
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setData(png, forType: .png)
                try await thumbnail.content.delete()
            }
            menu.addItem(.separator())
            _ = add("Open in Mail") { try await $0.open(handingOffTo: "com.apple.mail") }
            _ = add("Open in Preview") { try await $0.open(handingOffTo: "com.apple.Preview") }
            _ = add("Open in Photos") { thumbnail in
                try thumbnail.open(try await thumbnail.content.saveToDefaultLocation(), with: "com.apple.Photos")
            }
        case .movie:
            _ = add("Save as Animated GIF") { try await $0.content.beginAnimatedGIF(keepingMovie: false, report: $0.report) }
            let copy = add("Save Copy as Animated GIF") { try await $0.content.beginAnimatedGIF(keepingMovie: true, report: $0.report) }
            copy.isAlternate = true
            copy.keyEquivalentModifierMask = .option
        }
        menu.addItem(.separator())
        _ = add("Show in Finder") { thumbnail in
            NSWorkspace.shared.activateFileViewerSelecting([try await thumbnail.content.saveToDefaultLocation()])
        }
        menu.addItem(.separator())
        _ = add("Delete") { try await $0.content.delete() }
        menu.addItem(.separator())
        _ = add("Close") { try await $0.content.saveToDefaultLocation() }
        return menu
    }

    /// The screenshot folder when it is not the Desktop, which has its own item.
    private static func customFolder() -> URL? {
        guard let folder = CaptureFile.configuredScreenshotFolder else { return nil }
        let desktop = CaptureFile.desktop?.lastPathComponent
        return folder.lastPathComponent.caseInsensitiveCompare(desktop ?? "") == .orderedSame ? nil : folder
    }

    /// The chosen action owns the capture until it ends, and its file work starts before this returns. Its timer waits,
    /// and the thumbnail stays up for an alert about a failure; if the thumbnail has ended by then, the capture is saved
    /// where dismissing would have, and the failure is reported instead.
    @objc private func performAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? CaptureThumbnailAction, !finished, !Self.performing.contains(self) else { return }
        Self.performing.insert(self)
        pause()
        self.action = Task.immediate { [self] in
            defer {
                Self.performing.remove(self)
                resume()
            }
            do {
                try await action.body(self)
                dismiss()
            } catch {
                guard finished else {
                    NSAlert(presenting: error).runModal()
                    return
                }
                report(error)
                do { try await content.saveIfUnresolved() } catch { report(error) }
            }
        }
    }

    private func open(handingOffTo bundleIdentifier: String) async throws {
        let application = try Self.application(bundleIdentifier, toOpen: content.name)
        NSWorkspace.shared.open([try await content.handOff()], withApplicationAt: application,
                                configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

    private func open(_ file: URL, with bundleIdentifier: String) throws {
        NSWorkspace.shared.open([file], withApplicationAt: try Self.application(bundleIdentifier, toOpen: file.lastPathComponent),
                                configuration: NSWorkspace.OpenConfiguration())
    }

    private static func application(_ bundleIdentifier: String, toOpen name: String) throws -> URL {
        guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            throw SimulatorError.unavailable("The app to open \(name) is not installed.")
        }
        return application
    }

    // MARK: Dragging

    /// Offers a file promise, file URL, and screenshot PNG when dragging.
    package static func dragProvider(for content: CapturedContent, report: @escaping (Error) -> Void) -> NSFilePromiseProvider {
        let type: UTType = content.kind == .screenshot ? .png : .quickTimeMovie
        let delivery = CaptureDelivery(content: content, report: report)
        let provider = CaptureFilePromiseProvider(fileType: type.identifier, delegate: delivery)
        // The provider's delegate is weak, and the destination can ask for the
        // file after the thumbnail has gone.
        provider.delivery = delivery
        provider.file = content.file
        if content.kind == .screenshot { provider.png = content.png }
        return provider
    }

    package func dragBegan() {
        pause()
        window.orderOut(nil)
    }

    /// A completed drag has delivered the capture; a cancelled one saves it.
    package func dragEnded(_ operation: NSDragOperation) {
        if !operation.isEmpty { dismissedExplicitly = true }
        if !operation.isEmpty, !content.isResolved {
            // A late promise delivery may follow thumbnail dismissal, so preserve the capture
            // and copy from its saved location if delivery arrives later.
            let content = content, report = report
            Self.pending.append(content)
            Task {
                try? await Task.sleep(for: .seconds(5))
                Self.pending.removeAll { $0 === content }
                do { try await content.settleAfterDrop() } catch { report(error) }
            }
        }
        finish()
    }
}

/// A thumbnail menu item's action.
private final class CaptureThumbnailAction {
    let body: @MainActor (CaptureThumbnail) async throws -> Void
    init(_ body: @escaping @MainActor (CaptureThumbnail) async throws -> Void) { self.body = body }
}

/// The thumbnail's content: the image or playing movie inside a black frame,
/// with the white flash a screenshot shows.
@MainActor
private final class CaptureThumbnailView: NSView, NSMenuDelegate, NSDraggingSource {
    weak var owner: CaptureThumbnail?
    private let timing: any CaptureThumbnailTiming
    private let content: CapturedContent
    private let image: NSImage?
    private let contentLayer = CALayer()
    private let mediaLayer: CALayer
    private let whiteLayer = CALayer()
    private let player: AVPlayer?
    private let rotation: Double
    private let cornerRadius: CGFloat
    private let report: (Error) -> Void
    /// A frame of the movie, which dragging shows; AVPlayerLayer does not draw
    /// into a cached display.
    private var movieFrame: NSImage?
    private var mouseDownLocation: NSPoint?

    init(content: CapturedContent, image: NSImage?, rotation: Double, cornerRadius: CGFloat, timing: any CaptureThumbnailTiming,
         report: @escaping (Error) -> Void) {
        self.timing = timing
        self.content = content
        self.image = image
        self.rotation = rotation
        self.cornerRadius = cornerRadius
        self.report = report
        if content.kind == .movie {
            let player = AVPlayer(url: content.file)
            let layer = AVPlayerLayer(player: player)
            layer.videoGravity = .resize
            self.player = player
            mediaLayer = layer
        } else {
            let layer = CALayer()
            layer.contents = image
            layer.contentsGravity = .resize
            player = nil
            mediaLayer = layer
        }
        super.init(frame: .zero)
        let root = CALayer()
        layer = root
        wantsLayer = true
        root.masksToBounds = true
        root.cornerCurve = .continuous
        contentLayer.masksToBounds = true
        contentLayer.cornerCurve = .continuous
        contentLayer.addSublayer(mediaLayer)
        whiteLayer.backgroundColor = NSColor.white.cgColor
        whiteLayer.opacity = 0
        contentLayer.addSublayer(whiteLayer)
        root.addSublayer(contentLayer)
        // The flash starts with the device screen's shape.
        root.cornerRadius = cornerRadius
        contentLayer.cornerRadius = cornerRadius
        if content.kind == .movie {
            root.backgroundColor = NSColor.black.cgColor
            let movie = content.file
            Task { [weak self] in
                guard let frame = await Self.firstFrame(of: movie) else { return }
                self?.movieFrame = NSImage(cgImage: frame, size: .zero)
            }
        }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
        player?.play()
    }

    required init?(coder: NSCoder) { nil }

    nonisolated private static func firstFrame(of movie: URL) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: movie))
        generator.appliesPreferredTrackTransform = true
        return try? await generator.image(at: .zero).image
    }

    var movieDuration: Double? {
        guard let seconds = player?.currentItem?.duration.seconds, seconds.isFinite else { return nil }
        return seconds
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.frame = bounds.insetBy(dx: 5, dy: 5)
        let area = contentLayer.bounds
        // The framebuffer is upright; rotate screenshots to match the display.
        let quarterTurn = abs(rotation.truncatingRemainder(dividingBy: 180)) == 90
        mediaLayer.setAffineTransform(.identity)
        mediaLayer.bounds = quarterTurn && content.kind == .screenshot
            ? CGRect(x: 0, y: 0, width: area.height, height: area.width) : area
        mediaLayer.position = CGPoint(x: area.midX, y: area.midY)
        if content.kind == .screenshot { mediaLayer.setAffineTransform(CGAffineTransform(rotationAngle: rotation * .pi / 180)) }
        whiteLayer.frame = area
        CATransaction.commit()
    }

    /// The white flash: half opacity in 0.15 seconds, then gone in 0.15.
    func flash(then completion: @escaping @MainActor () -> Void) {
        timing.animateLayer(duration: 0.15, timing: .easeIn, changes: {
            whiteLayer.opacity = 0.5
        }, completion: { [self] in
            timing.animateLayer(duration: 0.15, timing: .easeOut, changes: {
                whiteLayer.opacity = 0
            }, completion: completion)
        })
    }

    /// The thumbnail's black 4-point frame. Its corners are a quarter of the
    /// screen's, or 4 points for a square screen.
    func showAsThumbnail() {
        let root = layer!
        root.backgroundColor = NSColor.black.cgColor
        root.borderColor = NSColor.black.cgColor
        root.borderWidth = 4
        let inner = cornerRadius > 0 ? cornerRadius * 0.25 : 4
        contentLayer.cornerRadius = inner
        root.cornerRadius = inner + 5
    }

    func fadeIn(duration: Double, then completion: @escaping @MainActor () -> Void) {
        timing.fadeIn(layer!, duration: duration, completion: completion)
    }

    func stop() { player?.pause() }

    // MARK: Pointer

    override func mouseEntered(with event: NSEvent) { owner?.pause() }
    override func mouseExited(with event: NSEvent) { owner?.resume() }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let menu = owner?.menu() else { return nil }
        menu.delegate = self
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) { owner?.pause() }
    func menuDidClose(_ menu: NSMenu) { owner?.resume() }

    override func mouseDown(with event: NSEvent) { mouseDownLocation = event.locationInWindow }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownLocation, let owner else { return }
        let location = event.locationInWindow
        guard abs(location.x - start.x) > 3 || abs(location.y - start.y) > 3 else { return }
        mouseDownLocation = nil
        let item = NSDraggingItem(pasteboardWriter: CaptureThumbnail.dragProvider(for: content, report: report))
        item.setDraggingFrame(bounds, contents: image ?? movieFrame ?? snapshot())
        owner.dragBegan()
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = false
    }

    override func mouseUp(with event: NSEvent) { mouseDownLocation = nil }

    private func snapshot() -> NSImage {
        let image = NSImage(size: bounds.size)
        if let representation = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: representation)
            image.addRepresentation(representation)
        }
        return image
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        owner?.dragEnded(operation)
    }
}

/// Writes a dragged capture where the destination asks for it.
@MainActor
private final class CaptureDelivery: NSObject, NSFilePromiseProviderDelegate {
    private let content: CapturedContent
    private let report: (Error) -> Void

    init(content: CapturedContent, report: @escaping (Error) -> Void) {
        self.content = content
        self.report = report
    }

    nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        MainActor.assumeIsolated { content.name }
    }

    nonisolated func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue { .main }

    nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL,
                                         completionHandler: @escaping ((any Error)?) -> Void) {
        nonisolated(unsafe) let completionHandler = completionHandler
        MainActor.assumeIsolated {
            // The destination waits for the completion handler, while the main actor goes on.
            _ = Task.immediate { [content, report] in
                do {
                    try await content.deliver(to: url)
                    completionHandler(nil)
                } catch let failure as CaptureLeftBehind {
                    // The destination has the whole file, so its promise is kept.
                    report(failure)
                    completionHandler(nil)
                } catch {
                    // A failed delivery keeps the capture by saving it where dismissing would.
                    do { try await content.saveIfUnresolved() } catch { report(error) }
                    completionHandler(error)
                }
            }
        }
    }
}

/// A file promise that also offers the capture's file URL and PNG data.
private final class CaptureFilePromiseProvider: NSFilePromiseProvider {
    var delivery: CaptureDelivery?
    var file: URL?
    var png: Data?

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        var types = super.writableTypes(for: pasteboard)
        if file != nil { types.append(.fileURL) }
        if png != nil { types.append(.png) }
        return types
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        switch type {
        case .fileURL: (file as NSURL?)?.pasteboardPropertyList(forType: .fileURL)
        case .png: png
        default: super.pasteboardPropertyList(forType: type)
        }
    }
}

/// Exports looping GIFs from movie sample times, with frame-rate and size limits and optional dithering.
package enum AnimatedGIF {
    package struct Options: Sendable {
        package var maximumFrameRate: Double
        package var maximumFrameSize: Double
        package var dithers: Bool
        package var ditherDepth: Double

        /// The `GifMaxFramerate`, `GifMaxFrameSize`, `GifUseDither`, and
        /// `GifDitherDepth` preferences.
        package static var preferred: Options {
            let defaults = HostPreferences.defaults
            let rate = defaults.double(forKey: HostPreferences.gifMaxFramerate)
            return Options(maximumFrameRate: rate > 0 ? min(rate, 100) : 30,
                           maximumFrameSize: min(max(defaults.double(forKey: HostPreferences.gifMaxFrameSize), 100), 2000),
                           dithers: defaults.bool(forKey: HostPreferences.gifUseDither),
                           ditherDepth: max(defaults.double(forKey: HostPreferences.gifDitherDepth), 0))
        }
    }

    package static func export(_ movie: URL, to gif: URL, options: Options, lane: any CaptureLane = BlockingIOLane()) async throws {
        let asset = AVURLAsset(url: movie)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw SimulatorError.operation("The recording contains no video track")
        }
        let duration = try await track.load(.timeRange).duration.seconds
        // Reading and encoding every frame blocks for as long as the movie takes. Only that work uses the track from here.
        nonisolated(unsafe) let videoTrack = track
        try await lane.run { try encode(asset, track: videoTrack, duration: duration, to: gif, options: options) }
    }

    private static func encode(_ asset: AVURLAsset, track: AVAssetTrack, duration: Double, to gif: URL, options: Options) throws {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? SimulatorError.operation("The recording could not be read")
        }
        guard let destination = CGImageDestinationCreateWithURL(gif as CFURL, UTType.gif.identifier as CFString, 0, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary) else {
            throw SimulatorError.operation("Could not create \(gif.lastPathComponent)")
        }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        // Dither in the source color space; linear working space roughens dark areas.
        var context: CIContext?
        let interval = 1 / options.maximumFrameRate
        var held: (image: CGImage, time: CMTime)?
        // GIF delays round up to hundredths. The tolerance suppresses floating-point noise.
        func add(_ image: CGImage, delay: Double) {
            CGImageDestinationAddImage(destination, image, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: (delay * 100 - 1e-6).rounded(.up) / 100],
            ] as CFDictionary)
        }
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetOutputPresentationTimeStamp(sample)
            if let current = held {
                let elapsed = CMTimeSubtract(time, current.time).seconds
                guard elapsed + 0.001 >= interval else { continue }
                add(current.image, delay: elapsed)
            }
            let image = CIImage(cvPixelBuffer: buffer)
            let renderer = context ?? CIContext(options: image.colorSpace.map { [.workingColorSpace: $0] } ?? [:])
            context = renderer
            held = (try frame(image, options: options, context: renderer), time)
        }
        if let last = held { add(last.image, delay: max(duration - last.time.seconds, interval)) }
        if reader.status == .failed { throw reader.error ?? SimulatorError.operation("The recording could not be read") }
        guard CGImageDestinationFinalize(destination) else {
            throw SimulatorError.operation("Could not write \(gif.lastPathComponent)")
        }
    }

    private static func frame(_ source: CIImage, options: Options, context: CIContext) throws -> CGImage {
        var image = source
        let scale = options.maximumFrameSize / max(image.extent.width, image.extent.height)
        if scale < 1 {
            let filter = CIFilter(name: "CILanczosScaleTransform")!
            filter.setValue(image, forKey: kCIInputImageKey)
            filter.setValue(scale, forKey: kCIInputScaleKey)
            filter.setValue(1, forKey: kCIInputAspectRatioKey)
            image = filter.outputImage ?? image
        }
        let intensity = exp2(-options.ditherDepth)
        if options.dithers, intensity > 1.0 / 1024, let dither = CIFilter(name: "CIDither") {
            let colorSpace = source.colorSpace
            dither.setValue(colorSpace.flatMap { image.matchedFromWorkingSpace(to: $0) } ?? image, forKey: kCIInputImageKey)
            dither.setValue(intensity, forKey: kCIInputIntensityKey)
            if let dithered = dither.outputImage?.cropped(to: image.extent) {
                image = colorSpace.flatMap { dithered.matchedToWorkingSpace(from: $0) } ?? dithered
            }
        }
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let cgImage = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: srgb)
        else { throw SimulatorError.operation("Could not render a GIF frame") }
        return cgImage
    }
}
