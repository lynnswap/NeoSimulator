import AppKit
import AVFoundation
import CoreImage
import ImageIO
import QuartzCore
import UniformTypeIdentifiers

/// A screenshot or quick recording kept in a temporary file until its
/// thumbnail is dismissed or used, as in Simulator.app.
@MainActor
final class CapturedContent {
    enum Kind { case screenshot, movie }

    let kind: Kind
    /// The temporary capture, which saving moves and deleting removes.
    let file: URL
    /// The file name it is saved under.
    let name: String
    /// Where dismissing the thumbnail saves it, chosen when it was captured.
    let defaultFolder: URL
    /// Names another capture will take, which saving skips.
    private let isReserved: (URL) -> Bool
    /// Whether the capture has been saved, deleted, or handed to another app.
    private(set) var isResolved = false
    /// Where it was saved, from which a late drag delivery copies it.
    private var saved: URL?

    init(_ kind: Kind, file: URL, name: String, defaultFolder: URL, isReserved: @escaping (URL) -> Bool = { _ in false }) {
        self.kind = kind
        self.file = file
        self.name = name
        self.defaultFolder = defaultFolder
        self.isReserved = isReserved
    }

    /// Moves the capture into `folder`, numbering a taken name. A failure
    /// keeps the capture where it is and names that location.
    @discardableResult
    func save(into folder: URL) throws -> URL {
        guard !isResolved else { throw HostError.operation("\(name) was already saved or deleted.") }
        let saved = try CaptureFile.move(file, into: folder, named: name, isReserved: isReserved)
        isResolved = true
        self.saved = saved
        return saved
    }

    @discardableResult
    func saveToDefaultLocation() throws -> URL { try save(into: defaultFolder) }

    func delete() throws {
        guard !isResolved else { return }
        try FileManager.default.removeItem(at: file)
        isResolved = true
    }

    /// Writes the capture to `destination`, which a drag or another app asked
    /// for, and gives up the temporary file.
    func deliver(to destination: URL) throws {
        if let saved { return try FileManager.default.copyItem(at: saved, to: destination) }
        guard !isResolved else { throw HostError.operation("\(name) was already saved or deleted.") }
        try FileManager.default.moveItem(at: file, to: destination)
        isResolved = true
    }

    /// Hands the screenshot to another app as a file of its own, and removes
    /// the temporary capture.
    fileprivate func handOff() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent(name)
        try deliver(to: copy)
        return copy
    }
}

/// The floating thumbnail Simulator.app shows beside a device window after a
/// screenshot or a quick recording. Dismissing it, by its timer or by the
/// device window resizing, entering or leaving full screen, or minimizing,
/// saves the capture to its default location; its menu and dragging it out
/// use the capture instead.
@MainActor
final class CaptureThumbnail: NSObject {
    /// Simulator.app keeps one app-wide list; a new capture dismisses the others.
    private(set) static var active: [CaptureThumbnail] = []
    /// Captures whose thumbnail has ended but that wait for an animated GIF
    /// or a drag's file promise; quitting saves those still unresolved.
    private static var pending: [CapturedContent] = []
    /// Animated GIFs being written, whose names other exports must not take.
    private static var exportingGIFs: Set<URL> = []
    /// Reports a failure of a thumbnail whose device window has closed.
    static var reportDetached: (Error) -> Void = { hostLog($0.localizedDescription) }
    /// Set while NeoSimulator quits: captures are saved instead of shown.
    static var savesImmediately = false

    enum Position { case right, left, over }

    let content: CapturedContent
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
    private var timer: Task<Void, Never>?
    private var pauses = 0
    private var hiding = false
    /// Whether it has appeared and its timer runs.
    private(set) var shown = false
    private var dismissedExplicitly = false
    private var finished = false
    private var observers: [any NSObjectProtocol] = []
    private var moveCount = 0
    private var moveWatch: Task<Void, Never>?

    /// - Parameters:
    ///   - source: The device screen in screen coordinates; the thumbnail
    ///     shrinks from it to a quarter of its size plus 10 points.
    ///   - rotation: The angle the device screen is shown at, which the
    ///     screenshot, taken from the unrotated framebuffer, is turned by.
    ///   - cornerRadius: The device screen's corner radius in points.
    ///   - spacing: Its distance from the device window. Simulator.app uses
    ///     (10, ceil(scale × 10 or 20)) for screenshots and none for movies.
    ///   - report: Shows a failure to save or use the capture.
    init(_ content: CapturedContent, image: NSImage?, parent: NSWindow, source: NSRect, rotation: Double = 0,
         cornerRadius: CGFloat = 0, spacing: NSSize, report: @escaping (Error) -> Void) {
        self.content = content
        self.parent = parent
        self.source = source
        self.cornerRadius = cornerRadius
        self.spacing = content.kind == .movie ? .zero : spacing
        self.report = report
        window = NSWindow(contentRect: source, styleMask: .borderless, backing: .buffered, defer: false)
        view = CaptureThumbnailView(content: content, image: image, rotation: rotation, cornerRadius: cornerRadius,
                                    report: report)
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
    func show() {
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
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.3
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    self.window.animator().setFrame(self.currentDestination, display: true)
                    self.view.showAsThumbnail()
                }, completionHandler: { [weak self] in self?.didShow() })
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

    /// The thumbnail's frame, a quarter of the device screen's size plus 10
    /// points: right of the device window, else left of it, else over its
    /// lower right corner, and in full screen right of the device screen or
    /// in the lower right corner. It is kept above the Dock.
    static func placement(source: NSRect, window frame: NSRect, fullScreen: Bool, screen bounds: NSRect,
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
        timer?.cancel()
        guard shown, pauses == 0, !finished else { return }
        let duration = duration
        timer = Task { [weak self] in
            do { try await Task.sleep(for: duration) } catch { return }
            self?.hide(animated: true)
        }
    }

    /// Hover, an open menu, a drag, or a moving device window keeps the
    /// thumbnail up; the timer starts again when they end.
    func pause() {
        pauses += 1
        timer?.cancel()
        if hiding, !finished { cancelHide() }
    }

    func resume() {
        pauses = max(pauses - 1, 0)
        if pauses == 0 { startTimer() }
    }

    private func cancelHide() {
        hiding = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            window.animator().setFrame(currentDestination, display: true)
            window.animator().alphaValue = 1
        }
    }

    /// Ends the thumbnail. Unless the user dismissed it through its menu or a
    /// drag, the capture is saved to its default location.
    func hide(animated: Bool) {
        guard !finished, !hiding else { return }
        hiding = true
        timer?.cancel()
        guard animated, shown, let parent, parent.isVisible else { finish(); return }
        // Beside the window, it slides under it from where it is now.
        let frame = window.frame
        let distance = frame.width + spacing.width + cornerRadius
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.35
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            switch position {
            case .right: window.animator().setFrame(frame.offsetBy(dx: -distance, dy: 0), display: true)
            case .left: window.animator().setFrame(frame.offsetBy(dx: distance, dy: 0), display: true)
            case .over: window.animator().alphaValue = 0
            }
        }, completionHandler: { [weak self] in
            guard let self, self.hiding else { return }
            self.finish()
        })
    }

    /// Ends the thumbnail after the user used the capture.
    private func dismiss() {
        dismissedExplicitly = true
        hide(animated: true)
    }

    @discardableResult
    private func finish(reporting: Bool = true) -> Error? {
        guard !finished else { return nil }
        finished = true
        hiding = true
        timer?.cancel()
        moveWatch?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        view.stop()
        parent?.removeChildWindow(window)
        window.orderOut(nil)
        window.close()
        Self.active.removeAll { $0 === self }
        guard !dismissedExplicitly, !content.isResolved else { return nil }
        do {
            try content.saveToDefaultLocation()
            return nil
        } catch {
            hostLog(error.localizedDescription)
            if reporting { report(error) }
            return error
        }
    }

    /// Saves every pending capture, including recordings whose GIF is still
    /// being written, before NeoSimulator quits, and returns the failures.
    /// Simulator.app leaves them in the temporary folder.
    @discardableResult
    static func finishAll() -> [Error] {
        var failures = active.compactMap { $0.finish(reporting: false) }
        for content in pending where !content.isResolved {
            do { try content.saveToDefaultLocation() } catch { failures.append(error) }
        }
        pending.removeAll()
        return failures
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

    /// Like Simulator.app, the timer waits until the window has stopped
    /// moving for a second.
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

    func menu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: @escaping (CaptureThumbnail) throws -> Void) -> NSMenuItem {
            let item = menu.addItem(withTitle: title, action: #selector(performAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = CaptureThumbnailAction(action)
            return item
        }
        if let custom = Self.customFolder() {
            _ = add("Save to \(custom.lastPathComponent)") { try $0.content.save(into: custom) }
        }
        if let desktop = CaptureFile.desktop {
            _ = add("Save to Desktop") { try $0.content.save(into: desktop) }
        }
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            _ = add("Save to Documents") { try $0.content.save(into: documents) }
        }
        switch content.kind {
        case .screenshot:
            _ = add("Copy to Clipboard") { thumbnail in
                let png = try Data(contentsOf: thumbnail.content.file)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setData(png, forType: .png)
                try thumbnail.content.delete()
            }
            menu.addItem(.separator())
            _ = add("Open in Mail") { try $0.open(handingOffTo: "com.apple.mail") }
            _ = add("Open in Preview") { try $0.open(handingOffTo: "com.apple.Preview") }
            _ = add("Open in Photos") { thumbnail in
                try thumbnail.open(thumbnail.content.saveToDefaultLocation(), with: "com.apple.Photos")
            }
        case .movie:
            _ = add("Save as Animated GIF") { try $0.saveAnimatedGIF(keepingMovie: false) }
            let copy = add("Save Copy as Animated GIF") { try $0.saveAnimatedGIF(keepingMovie: true) }
            copy.isAlternate = true
            copy.keyEquivalentModifierMask = .option
        }
        menu.addItem(.separator())
        _ = add("Show in Finder") { thumbnail in
            NSWorkspace.shared.activateFileViewerSelecting([try thumbnail.content.saveToDefaultLocation()])
        }
        _ = add("Delete") { try $0.content.delete() }
        menu.addItem(.separator())
        _ = add("Close") { try $0.content.saveToDefaultLocation() }
        return menu
    }

    /// The screenshot folder when it is not the Desktop, which has its own item.
    private static func customFolder() -> URL? {
        guard UserDefaults.standard.string(forKey: HostPreferences.screenShotSaveLocation) != nil else { return nil }
        let folder = CaptureFile.screenshotFolder()
        let desktop = CaptureFile.desktop?.lastPathComponent
        return folder.lastPathComponent.caseInsensitiveCompare(desktop ?? "") == .orderedSame ? nil : folder
    }

    @objc private func performAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? CaptureThumbnailAction, !finished else { return }
        do {
            try action.body(self)
            dismiss()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func open(handingOffTo bundleIdentifier: String) throws {
        let application = try Self.application(bundleIdentifier, toOpen: content.name)
        NSWorkspace.shared.open([try content.handOff()], withApplicationAt: application,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    private func open(_ file: URL, with bundleIdentifier: String) throws {
        NSWorkspace.shared.open([file], withApplicationAt: try Self.application(bundleIdentifier, toOpen: file.lastPathComponent),
                                configuration: NSWorkspace.OpenConfiguration())
    }

    private static func application(_ bundleIdentifier: String, toOpen name: String) throws -> URL {
        guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            throw HostError.unavailable("The app to open \(name) is not installed.")
        }
        return application
    }

    /// Writes an animated GIF of the movie next to where the movie would be
    /// saved. Keeping the movie saves it first; otherwise the temporary movie
    /// is removed once the GIF is written, or saved when writing fails.
    private func saveAnimatedGIF(keepingMovie: Bool) throws {
        let content = content
        let movie: URL, gif: URL
        if keepingMovie {
            movie = try content.saveToDefaultLocation()
            gif = try CaptureFile.unusedFile(in: movie.deletingLastPathComponent(),
                                             named: movie.deletingPathExtension().appendingPathExtension("gif").lastPathComponent,
                                             isReserved: Self.exportingGIFs.contains)
        } else {
            movie = content.file
            gif = try CaptureFile.unusedFile(in: content.defaultFolder,
                                             named: (content.name as NSString).deletingPathExtension + ".gif",
                                             isReserved: Self.exportingGIFs.contains)
        }
        Self.exportingGIFs.insert(gif)
        let report = report
        if !keepingMovie { Self.pending.append(content) }
        Task {
            defer {
                Self.pending.removeAll { $0 === content }
                Self.exportingGIFs.remove(gif)
            }
            do {
                try await AnimatedGIF.export(movie, to: gif, options: .preferred)
                if !keepingMovie { try content.delete() }
            } catch {
                hostLog("Could not save an animated GIF: \(error.localizedDescription)")
                var failure = error
                if !keepingMovie, !content.isResolved {
                    do { try content.saveToDefaultLocation() }
                    catch { failure = HostError.operation("\(failure.localizedDescription) \(error.localizedDescription)") }
                }
                report(failure)
            }
        }
    }

    // MARK: Dragging

    func dragBegan() {
        pause()
        window.orderOut(nil)
    }

    /// A completed drag has delivered the capture; a cancelled one saves it.
    func dragEnded(_ operation: NSDragOperation) {
        if !operation.isEmpty { dismissedExplicitly = true }
        if !operation.isEmpty, !content.isResolved {
            // The destination fulfils the promise shortly. Simulator.app then
            // deletes an unclaimed capture after five seconds; NeoSimulator
            // saves it instead, and a later delivery copies the saved file.
            let content = content, report = report
            Self.pending.append(content)
            Task {
                try? await Task.sleep(for: .seconds(5))
                Self.pending.removeAll { $0 === content }
                guard !content.isResolved else { return }
                do { try content.saveToDefaultLocation() } catch { report(error) }
            }
        }
        finish()
    }
}

/// A thumbnail menu item's action.
private final class CaptureThumbnailAction {
    let body: (CaptureThumbnail) throws -> Void
    init(_ body: @escaping (CaptureThumbnail) throws -> Void) { self.body = body }
}

/// The thumbnail's content: the image or playing movie inside a black frame,
/// with the white flash a screenshot shows.
@MainActor
private final class CaptureThumbnailView: NSView, NSMenuDelegate, NSDraggingSource, NSFilePromiseProviderDelegate {
    weak var owner: CaptureThumbnail?
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

    init(content: CapturedContent, image: NSImage?, rotation: Double, cornerRadius: CGFloat,
         report: @escaping (Error) -> Void) {
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
        // A screenshot is the framebuffer as the device holds it upright; it
        // is turned the way the display shows it, like Simulator.app.
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
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeIn))
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated {
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.15)
                CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
                CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion() } }
                self.whiteLayer.opacity = 0
                CATransaction.commit()
            }
        }
        whiteLayer.opacity = 0.5
        CATransaction.commit()
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
        let root = layer!
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion() } }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        root.add(fade, forKey: "fadeIn")
        CATransaction.commit()
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
        let type: UTType = content.kind == .screenshot ? .png : .quickTimeMovie
        let provider = CaptureFilePromiseProvider(fileType: type.identifier, delegate: self)
        // Like Simulator.app, the drag also offers the file and a screenshot's PNG.
        provider.file = content.file
        if content.kind == .screenshot { provider.png = try? Data(contentsOf: content.file) }
        let item = NSDraggingItem(pasteboardWriter: provider)
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

    nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        MainActor.assumeIsolated { content.name }
    }

    nonisolated func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue { .main }

    nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL,
                                         completionHandler: @escaping ((any Error)?) -> Void) {
        // A failed delivery keeps the capture by saving it where dismissing would.
        let failure: (any Error)? = MainActor.assumeIsolated {
            do { try content.deliver(to: url) } catch {
                if !content.isResolved {
                    do { try content.saveToDefaultLocation() } catch { report(error) }
                }
                return error
            }
            return nil
        }
        completionHandler(failure)
    }
}

/// A file promise that also offers the capture's file URL and PNG data.
private final class CaptureFilePromiseProvider: NSFilePromiseProvider {
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

/// Simulator.app's animated GIF export: frames at most `maximumFrameRate`
/// apart taken from the movie's own sample times, scaled down to
/// `maximumFrameSize` pixels, dithered, and looped.
enum AnimatedGIF {
    struct Options {
        var maximumFrameRate: Double
        var maximumFrameSize: Double
        var dithers: Bool
        var ditherDepth: Double

        /// The `GifMaxFramerate`, `GifMaxFrameSize`, `GifUseDither`, and
        /// `GifDitherDepth` preferences.
        static var preferred: Options {
            let defaults = UserDefaults.standard
            let rate = defaults.double(forKey: HostPreferences.gifMaxFramerate)
            return Options(maximumFrameRate: rate > 0 ? min(rate, 100) : 30,
                           maximumFrameSize: min(max(defaults.double(forKey: HostPreferences.gifMaxFrameSize), 100), 2000),
                           dithers: defaults.bool(forKey: HostPreferences.gifUseDither),
                           ditherDepth: max(defaults.double(forKey: HostPreferences.gifDitherDepth), 0))
        }
    }

    static func export(_ movie: URL, to gif: URL, options: Options) async throws {
        let asset = AVURLAsset(url: movie)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw HostError.operation("The recording contains no video track")
        }
        let duration = try await track.load(.timeRange).duration.seconds
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? HostError.operation("The recording could not be read")
        }
        guard let destination = CGImageDestinationCreateWithURL(gif as CFURL, UTType.gif.identifier as CFString, 0, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary) else {
            throw HostError.operation("Could not create \(gif.lastPathComponent)")
        }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        // Like Simulator.app, frames are dithered in the movie's own color
        // space; a linear working space would roughen dark areas.
        var context: CIContext?
        let interval = 1 / options.maximumFrameRate
        var held: (image: CGImage, time: CMTime)?
        // Delays are whole hundredths, rounded up as Simulator.app does; the
        // tolerance keeps floating-point noise from adding a hundredth.
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
        if reader.status == .failed { throw reader.error ?? HostError.operation("The recording could not be read") }
        guard CGImageDestinationFinalize(destination) else {
            throw HostError.operation("Could not write \(gif.lastPathComponent)")
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
        else { throw HostError.operation("Could not render a GIF frame") }
        return cgImage
    }
}
