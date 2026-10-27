import AppKit

/// Fits a shared simulator display during full screen or manual resizing.
/// SimulatorKit applies new screen dimensions asynchronously, requiring another fit afterward.
@MainActor
final class DisplayFitting {
    private(set) var display: any SimulatorDisplay
    private var content: any DisplayContentView
    /// The display's size at scale 1 when its view last changed.
    private var size: NSSize
    private var observer: (any NSObjectProtocol)?
    /// Whether the window is in full screen or moving into or out of it.
    private(set) var isFullScreen = false
    /// Whether the window is between `windowWillStartLiveResize` and
    /// `windowDidEndLiveResize`.
    private var isLiveResizing = false
    /// App resize mode sends point geometry to the guest; its framebuffer keeps scale 1.
    var scalesDisplay = true
    /// The display's scale and the window's origin when the window entered
    /// full screen, which Simulator.app restores when the window leaves it.
    private var geometryBeforeFullScreen: (scale: CGFloat?, origin: NSPoint)?
    /// An embedded presentation may preserve a fixed scale after a native size change.
    var onNaturalSizeChange: (() -> Void)?

    init(display: any SimulatorDisplay, content: any DisplayContentView) {
        self.display = display
        self.content = content
        size = display.size(for: 1)
        observe()
    }

    isolated deinit { invalidate() }

    /// Fits a device's next display, in new content, as after a restart.
    func attach(_ display: any SimulatorDisplay, content: any DisplayContentView) {
        invalidate()
        self.display = display
        self.content = content
        size = display.size(for: 1)
        if scalesDisplay, let geometry = geometryBeforeFullScreen, geometry.scale == nil {
            // Keep the returning primary's scale before full-screen fitting overwrites it.
            geometryBeforeFullScreen = (display.renderScale, geometry.origin)
        }
        observe()
    }

    /// Whether the display fits the window instead of the window taking the
    /// display's size.
    var fitsWindow: Bool { isFullScreen || isLiveResizing }

    /// Gives the display the largest scale at which it fits the content.
    func fit() {
        content.isSizedToDisplay = false
        resize(to: content.availableDisplaySize)
        layout()
    }

    /// Applies the presentation policy to every explicit scale request.
    func setScale(_ scale: CGFloat) {
        display.setRenderScale(scalesDisplay ? scale : 1)
    }

    func resize(to size: NSSize) {
        if scalesDisplay { display.resize(to: size) } else { setScale(1) }
    }

    /// Lays the display out in the content again.
    func layout() {
        content.needsLayout = true
        content.layoutSubtreeIfNeeded()
        content.window?.invalidateShadow()
    }

    func willStartLiveResize() {
        isLiveResizing = true
        if scalesDisplay { display.beginResize() }
    }

    func didEndLiveResize() {
        isLiveResizing = false
        fit()
        if scalesDisplay { display.endResize() }
    }

    func willEnterFullScreen() {
        isFullScreen = true
        guard let window = content.window else { return }
        geometryBeforeFullScreen = (scalesDisplay ? display.renderScale : nil, window.frame.origin)
    }

    func didFailToEnterFullScreen() {
        isFullScreen = false
        geometryBeforeFullScreen = nil
    }

    /// Leaves full screen, returning the display's scale and the window's
    /// origin from before it, which the window returns to.
    func didExitFullScreen(defaultScale: CGFloat) -> (scale: CGFloat, origin: NSPoint)? {
        isFullScreen = false
        defer { geometryBeforeFullScreen = nil }
        guard let geometry = geometryBeforeFullScreen else { return nil }
        return (geometry.scale ?? defaultScale, geometry.origin)
    }

    /// Stops following the display's size.
    func invalidate() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    private func observe() {
        display.view.postsFrameChangedNotifications = true
        observer = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: display.view, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.displayViewChanged() }
        }
    }

    private func displayViewChanged() {
        let size = display.size(for: 1)
        guard size != self.size else { return }
        self.size = size
        if fitsWindow { fit() } else { onNaturalSizeChange?() }
    }
}
