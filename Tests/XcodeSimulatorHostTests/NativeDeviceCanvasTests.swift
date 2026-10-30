import AppKit
import SwiftUI
import Testing
import XCTest
@_spi(NeoSimulator) @testable import XcodeSimulatorHost

@MainActor
struct NativeDeviceCanvasTests {
    /// The canvas frames the host at the scaled composition; Fit often shrinks a device below its natural size.
    @Test func shrunkenCanvasPresentsTheMeasuredCompositionInItsHostFrame() async throws {
        _ = NSApplication.shared
        let recorder = RecorderView()
        // A 400 × 800 composition with an AppKit-backed view centered at (200, 400), standing in for DeviceKit's.
        let composition = ZStack(alignment: .topLeading) {
            Color.clear.frame(width: 400, height: 800)
            Recorder(view: recorder)
                .frame(width: 40, height: 40)
                .padding(EdgeInsets(top: 380, leading: 180, bottom: 0, trailing: 0))
        }
        let presentation = NativeCanvasPresentation()
        presentation.magnification = 0.5
        let hosting = NativeCanvasHostingView(rootView: AnyView(NativeCanvasRoot(
            presentation: presentation, shown: AnyView(composition), hidden: AnyView(composition),
            canvasPath: \.nativeCanvasTestFlag, zoomPath: \.nativeCanvasTestZoom)))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        window.contentView = container
        hosting.frame = NSRect(x: 50, y: 60, width: 200, height: 400)
        container.addSubview(hosting)
        hosting.layoutSubtreeIfNeeded()
        let measured = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated { presentation.naturalSize == CGSize(width: 400, height: 800) }
        }, object: nil)
        try #require(await XCTWaiter.fulfillment(of: [measured], timeout: 5) == .completed)
        hosting.layoutSubtreeIfNeeded()
        let shown = recorder.convert(recorder.bounds, to: hosting)
        #expect(abs(shown.midX - 100) < 0.5 && abs(shown.midY - 200) < 0.5, "Shown at \(NSStringFromRect(shown))")
        #expect(abs(shown.width - 20) < 0.5 && abs(shown.height - 20) < 0.5, "Shown at \(NSStringFromRect(shown))")
        let point = hosting.convert(NSPoint(x: 100, y: 200), to: nil)
        let hit = container.hitTest(point)
        #expect(hit.map { $0 === recorder || $0.isDescendant(of: recorder) } == true)
        let local = recorder.convert(point, from: nil)
        #expect(abs(local.x - 20) < 0.5 && abs(local.y - 20) < 0.5, "Local \(NSStringFromPoint(local))")
    }
}

private final class RecorderView: NSView {}

private struct Recorder: NSViewRepresentable {
    let view: RecorderView
    func makeNSView(context: Context) -> RecorderView { view }
    func updateNSView(_ nsView: RecorderView, context: Context) {}
}

extension EnvironmentValues {
    @Entry fileprivate var nativeCanvasTestFlag = false
    @Entry fileprivate var nativeCanvasTestZoom: CGFloat = 1
}
