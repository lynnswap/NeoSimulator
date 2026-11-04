import AppKit

@MainActor
final class SimulatorSidebarRowView: NSTableRowView {
    // Keep AppKit's selection geometry without the sidebar template's extra vibrancy.
    override func drawSelection(in dirtyRect: NSRect) {
        super.drawSelection(in: dirtyRect)
    }
}
