import AppKit
@testable import NeoSimulatorDeviceIO
@testable import NeoSimulatorHostSupport
@testable import NeoSimulatorKit
@testable import NeoSimulatorPresentationAdapters
import Observation
import SwiftUI
import Testing
import XCTest

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
        for scale: CGFloat in [2, 1.37] {
            hosting.frame = NSRect(x: 100.25 - 200 * scale, y: 300.375 - 400 * scale,
                                   width: 400 * scale, height: 800 * scale)
            presentation.magnification = scale
            container.layoutSubtreeIfNeeded()
            #expect(presentation.naturalSize == CGSize(width: 400, height: 800))
            let enlarged = recorder.convert(recorder.bounds, to: hosting)
            #expect(abs(enlarged.midX - 200 * scale) < 0.5 && abs(enlarged.midY - 400 * scale) < 0.5)
            #expect(abs(enlarged.width - 40 * scale) < 0.5 && abs(enlarged.height - 40 * scale) < 0.5)
            let panned = hosting.convert(NSPoint(x: 210 * scale, y: 400 * scale), to: nil)
            let enlargedHit = container.hitTest(panned)
            #expect(enlargedHit.map { $0 === recorder || $0.isDescendant(of: recorder) } == true)
            let enlargedLocal = recorder.convert(panned, from: nil)
            #expect(abs(enlargedLocal.x - 30) < 0.5 && abs(enlargedLocal.y - 20) < 0.5)
        }
    }

    /// The window sets `onError` after the screen connects, which pose discovery does not wait for.
    @Test(.timeLimit(.minutes(1)))
    func poseControlsKeepADiscoveryFailureForTheWindowThatConnectsAfterIt() async {
        let (finished, finish) = AsyncStream.makeStream(of: Void.self)
        let poses = NativeDevicePoseControls { _ in
            defer { finish.finish() }
            throw RemoteScreenError.unavailable("fixture-poses", "DeviceKit's action providers are unavailable.")
        }
        #expect(!poses.isAvailable)
        for await _ in finished {}
        var errors: [String] = []
        poses.onError = { errors.append($0.localizedDescription) }
        #expect(errors == ["DeviceKit's action providers are unavailable."])
        // A window that reconnects to the same controls does not report it again.
        poses.onError = { errors.append($0.localizedDescription) }
        #expect(errors.count == 1)
    }

    /// DeviceKit's provider offers no controls until CoreDevice reports the device as booted.
    @Test(.timeLimit(.minutes(1)))
    func poseControlsAppearWhenTheProviderStartsOfferingThemAfterTheScreenOpened() async {
        let provider = PoseProviderFixture()
        let (read, finishRead) = AsyncStream.makeStream(of: Void.self)
        let poses = NativeDevicePoseControls { poses in
            try await poses.discover(readProviders: { [] }, prepareControls: { _ in
                {
                    defer { finishRead.finish() }
                    return provider.offersControls ? NativeDevicePoseControls.Controls(
                        rotation: AnyView(EmptyView()), postures: AnyView(EmptyView()), divider: nil) : nil
                }
            })
        }
        for await _ in read {}
        #expect(!poses.isAvailable)
        provider.offersControls = true
        while !poses.isAvailable { await Task.yield() }
        #expect(poses.actionBarControls.count == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func disconnectingPoseControlsEndsTheirDiscoveryWithoutReportingIt() async {
        let (finished, finish) = AsyncStream.makeStream(of: Void.self)
        let (started, start) = AsyncStream.makeStream(of: Void.self)
        let poses = NativeDevicePoseControls { _ in
            defer { finish.finish() }
            start.finish()
            // Native discovery does not stop for cancellation, and fails after the disconnect.
            try? await Task.sleep(for: .seconds(3600))
            #expect(Task.isCancelled)
            throw RemoteScreenError.unavailable("fixture-poses", "DeviceKit's action providers are unavailable.")
        }
        var errors: [String] = []
        poses.onError = { errors.append($0.localizedDescription) }
        for await _ in started {}
        poses.disconnect()
        for await _ in finished {}
        poses.onError = { errors.append($0.localizedDescription) }
        #expect(errors.isEmpty)
    }
}

@MainActor @Observable
private final class PoseProviderFixture {
    var offersControls = false
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
