import AppKit
import Quartz
@_spi(NeoSimulator) import XcodeSimulatorHost

@MainActor
final class ManagerReportPreviewWindowController: NSWindowController, NSWindowDelegate {
    private let previewView: QLPreviewView
    private var closed = false
    var onClose: (() -> Void)?

    init(report: DeviceReport, deviceName: String, url: URL) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = report.name
        window.subtitle = deviceName
        window.minSize = NSSize(width: 360, height: 260)
        window.isReleasedWhenClosed = false
        previewView = QLPreviewView(frame: window.contentLayoutRect, style: .normal)
        super.init(window: window)
        previewView.shouldCloseWithWindow = false
        previewView.autostarts = false
        window.contentView = previewView
        window.delegate = self
        window.center()
        previewView.previewItem = url as NSURL
    }
    required init?(coder: NSCoder) { nil }
    func windowWillClose(_ notification: Notification) {
        guard !closed else { return }
        closed = true
        previewView.close()
        onClose?()
        onClose = nil
    }
}
