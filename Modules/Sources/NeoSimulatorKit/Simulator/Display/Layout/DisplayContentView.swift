import AppKit

/// The content of a window that shows a simulator display: either the window
/// has the display's size, or the display fits the content.
@MainActor
protocol DisplayContentView: NSView {
    /// Fills a display-sized window; otherwise centers the display at its own size.
    var isSizedToDisplay: Bool { get set }
    /// The space the content leaves for the display.
    var availableDisplaySize: NSSize { get }
}
