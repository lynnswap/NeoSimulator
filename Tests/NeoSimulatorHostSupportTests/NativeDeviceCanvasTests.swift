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
    @Test func projectedCanvasUsesDevicePointsAndExcludesTheEmptyRenderingSurface() async throws {
        _ = NSApplication.shared
        let surface = CALayer()
        surface.bounds = CGRect(x: 0, y: 0, width: 2000, height: 2000)
        let screen = CALayer()
        screen.anchorPoint = .zero
        screen.bounds = CGRect(x: 0, y: 0, width: 400, height: 800)
        screen.position = CGPoint(x: 700, y: 700)
        screen.transform = CATransform3DMakeScale(0.5, 0.5, 1)
        surface.addSublayer(screen)
        let inactive = CALayer()
        inactive.bounds = surface.bounds
        inactive.isHidden = true
        surface.addSublayer(inactive)

        let presentation = NativeCanvasPresentation()
        presentation.compositionSize = CGSize(width: 1200, height: 1000)
        let viewport: CGRect = try #require(NativeCanvasProjection.viewport(
            for: [screen, inactive], frameMargin: nil, showsChrome: false))
        presentation.viewport = viewport
        presentation.pointScale = 2
        presentation.zoom = 1.25
        presentation.magnification = 0.6
        #expect(presentation.naturalSize == CGSize(width: 400, height: 800))
        let recorder = RecorderView()
        let composition = ZoomedComposition(size: CGSize(width: 1200, height: 1000)) {
            Recorder(view: recorder).frame(width: 200, height: 400)
                .padding(EdgeInsets(top: 200, leading: 300, bottom: 0, trailing: 0))
        }
        let hosting = NativeCanvasHostingView(rootView: AnyView(NativeCanvasRoot(
            presentation: presentation, shown: AnyView(composition), hidden: AnyView(composition),
            canvasPath: \.nativeCanvasTestFlag, zoomPath: \.nativeCanvasTestZoom)))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        let shown = recorder.convert(recorder.bounds, to: hosting)
        #expect(abs(shown.minX) < 0.5 && abs(shown.minY) < 0.5)
        #expect(abs(shown.width - 300) < 0.5 && abs(shown.height - 600) < 0.5)
        let point = hosting.convert(CGPoint(x: 225, y: 450), to: nil)
        #expect(hosting.hitTest(point).map { $0 === recorder || $0.isDescendant(of: recorder) } == true)
        let local = recorder.convert(point, from: nil)
        // The recorder uses AppKit's upward Y axis.
        #expect(abs(local.x - 150) < 0.5 && abs(local.y - 100) < 0.5)

        // A detached/rebuilding DeviceKit graph temporarily has no native screen layers.
        let projection = NativeCanvasProjection(hosting: hosting, presentation: presentation,
                                                pointsPerInch: nil, frameMargin: { 0 })
        projection.update()
        #expect(presentation.viewport == viewport && presentation.pointScale == 2)

        screen.isHidden = true
        inactive.isHidden = false
        inactive.bounds = CGRect(x: 0, y: 0, width: 600, height: 400)
        inactive.anchorPoint = .zero
        inactive.position = CGPoint(x: 200, y: 300)
        #expect(NativeCanvasProjection.viewport(for: [screen, inactive], frameMargin: 0)
            == CGRect(x: -800, y: -700, width: 600, height: 400))
    }

    @Test func projectedCanvasKeepsHiddenHoverControlsInsideItsHitArea() throws {
        _ = NSApplication.shared
        let surface = CALayer()
        surface.bounds = CGRect(x: 0, y: 0, width: 2000, height: 2000)
        let screen = CALayer()
        screen.anchorPoint = .zero
        screen.bounds = CGRect(x: 0, y: 0, width: 200, height: 400)
        screen.position = CGPoint(x: 700, y: 700)
        surface.addSublayer(screen)
        let presentation = NativeCanvasPresentation()
        // The device covers 200 × 400 points, from 300 to 100 points left of the surface's center.
        presentation.viewport = NativeCanvasProjection.viewport(for: [screen], frameMargin: 0)
        let margin = NativeCanvasProjection.hoverControlMargin(renderingHeight: surface.bounds.height)
        presentation.controlMargin = margin
        presentation.pointScale = 2
        // Outside a canvas viewport the natural size has the controls' room in it.
        #expect(presentation.naturalSize == CGSize(width: (200 + margin * 2) * 2, height: (400 + margin * 2) * 2))
        let control = RecorderView()
        control.isHidden = true
        let composition = ControlBesideDevice(view: control, size: CGSize(width: 1200, height: 1000),
                                              deviceEdge: CGPoint(x: -100, y: -100))
        let hosting = NativeCanvasHostingView(rootView: AnyView(NativeCanvasRoot(
            presentation: presentation, shown: AnyView(composition), hidden: AnyView(composition),
            canvasPath: \.nativeCanvasTestFlag, zoomPath: \.nativeCanvasTestZoom)))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = hosting
        for zoom: CGFloat in [0.5, 1, 2] {
            // A canvas viewport places the device's frame, and the view extends the controls' room beyond it.
            presentation.magnification = zoom
            #expect(presentation.naturalSize == CGSize(width: 400, height: 800))
            // DeviceKit has drawn the device at the app's scale.
            presentation.picture.ask(for: presentation.preferredZoom, from: CGSize(width: 200, height: 400))
            presentation.picture.arrived()
            window.setContentSize(CGSize(width: 400 * zoom + margin * 2, height: 800 * zoom + margin * 2))
            hosting.layoutSubtreeIfNeeded()
            control.isHidden = false
            hosting.layoutSubtreeIfNeeded()
            let frame = control.convert(control.bounds, to: hosting)
            // The control keeps its size and its distance from the device's right edge at any magnification.
            #expect(abs(frame.minX - (margin + 400 * zoom + 20)) < 0.5 && abs(frame.width - 30) < 0.5,
                    "Shown at \(NSStringFromRect(frame))")
            #expect(hosting.bounds.contains(frame))
            #expect(control.visibleRect.contains(control.bounds))
            let point = control.convert(NSPoint(x: control.bounds.midX, y: control.bounds.midY), to: nil)
            #expect(hosting.hitTest(point).map { $0 === control || $0.isDescendant(of: control) } == true)
            control.isHidden = true
        }
    }

    @Test func deviceKitIsAskedForTheAppsScaleBetweenTheDevicesPhysicalSizeAndTheRenderingSurface() {
        let presentation = NativeCanvasPresentation()
        presentation.viewport = CGRect(x: -400, y: -500, width: 800, height: 1000)
        presentation.surfaceSize = CGSize(width: 2000, height: 2000)
        presentation.pointScale = 1.25
        presentation.zoom = 1.2
        #expect(presentation.preferredZoom == 1.5)
        // Outside a canvas viewport the natural size has the room of DeviceKit's controls as it is at the device's
        // physical size, so the app reduces what DeviceKit drew at that size.
        presentation.zoom = 0.6
        #expect(presentation.scale == 0.75 && presentation.preferredZoom == 1)
        // A canvas viewport gives the controls their room at any zoom.
        presentation.magnification = 1
        #expect(presentation.scale == 0.75 && presentation.preferredZoom == 0.75)
        // The device is 500 points high from the surface's center, which is 1000 from its edge. The controls
        // need 100 of them.
        presentation.controlMargin = 100
        presentation.magnification = 4
        #expect(presentation.scale == 3 && presentation.preferredZoom == 1.8)
    }

    @Test func pictureThatDeviceKitMovesToAnotherZoomHasTheZoomThatTheDevicesExtentShows() {
        var picture = NativeCanvasPicture()
        picture.ask(for: 2, from: CGSize(width: 300, height: 400))
        #expect(picture.askedZoom == 2 && picture.zoom == 1 && picture.isMoving)
        picture.moved(to: CGSize(width: 450, height: 600))
        #expect(picture.zoom == 1.5 && picture.isMoving)
        // DeviceKit does not move while its window is hidden. The picture is where it stopped, and goes on later.
        picture.rested(at: CGSize(width: 450, height: 600))
        #expect(picture.zoom == 1.5 && picture.isMoving)
        // The nearer parts of the device grow a little faster than the zoom.
        picture.moved(to: CGSize(width: 603, height: 806))
        #expect(picture.zoom == 2 && !picture.isMoving)
    }

    @Test func pictureWhoseDeviceFoldsOnTheWayStaysInsideItsRoomAndHasArrivedOnceItRests() {
        var picture = NativeCanvasPicture()
        picture.ask(for: 2, from: CGSize(width: 300, height: 400))
        // The device opens to twice its width while DeviceKit zooms: its larger side shows how large it is.
        picture.moved(to: CGSize(width: 1200, height: 800))
        #expect(picture.zoom == 4 && picture.isMoving)
        picture.rested(at: CGSize(width: 1200, height: 800))
        #expect(picture.zoom == 2 && !picture.isMoving)
    }

    /// DeviceKit reports each step of a turning or folding device through its screen layers, and the projection reads
    /// them whenever its view is laid out.
    @Test func pictureWhoseDeviceTurnsWhileDeviceKitZoomsArrivesOnceTheDeviceRests() async throws {
        _ = NSApplication.shared
        let surface = CALayer()
        surface.bounds = CGRect(x: 0, y: 0, width: 2000, height: 2000)
        let screen = CALayer()
        screen.bounds = CGRect(x: 0, y: 0, width: 200, height: 400)
        screen.position = CGPoint(x: 1000, y: 1000)
        surface.addSublayer(screen)
        let presentation = NativeCanvasPresentation()
        let composition = ZoomedComposition(size: CGSize(width: 1200, height: 1000)) { Color.clear }
        let hosting = NativeCanvasHostingView(rootView: AnyView(NativeCanvasRoot(
            presentation: presentation, shown: AnyView(composition), hidden: AnyView(composition),
            canvasPath: \.nativeCanvasTestFlag, zoomPath: \.nativeCanvasTestZoom)))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = hosting
        hosting.projection = NativeCanvasProjection(hosting: hosting, presentation: presentation, pointsPerInch: nil,
                                                    frameMargin: { 0 }, screenLayers: { _ in [screen] })
        hosting.layoutSubtreeIfNeeded()
        func wait(for condition: @escaping @MainActor () -> Bool) async -> Bool {
            let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                MainActor.assumeIsolated { condition() }
            }, object: nil)
            return await XCTWaiter.fulfillment(of: [expectation], timeout: 5) == .completed
        }
        try #require(await wait { presentation.viewport?.size == CGSize(width: 200, height: 400) })
        presentation.magnification = 2
        hosting.projection?.scaleChanged()
        try #require(await wait { presentation.picture.askedZoom == 2 && presentation.picture.isMoving })
        // DeviceKit has drawn the device at twice the size and turned it meanwhile.
        screen.bounds = CGRect(x: 0, y: 0, width: 800, height: 400)
        #expect(await wait { !presentation.picture.isMoving && presentation.viewport?.size == CGSize(width: 400, height: 200) },
                "The picture is \(presentation.picture), of \(String(describing: presentation.viewport))")
    }

    /// The canvas frames the host at the scaled composition; Fit often shrinks a device below its natural size.
    @Test func shrunkenCanvasPresentsTheMeasuredCompositionInItsHostFrame() async throws {
        _ = NSApplication.shared
        let recorder = RecorderView()
        // A 400 × 800 composition with an AppKit-backed view centered at (200, 400), standing in for DeviceKit's.
        let composition = ZoomedComposition(size: CGSize(width: 400, height: 800)) {
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
        while !poses.isAvailable {
            await withCheckedContinuation { continuation in
                withObservationTracking { _ = poses.isAvailable } onChange: { continuation.resume() }
            }
        }
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

/// Stands in for one of DeviceKit's controls beside a device's button: a view that keeps its size, 20 points right of
/// the device's edge, which DeviceKit's surface draws at the canvas's zoom around its center.
private struct ControlBesideDevice: View {
    @Environment(\.nativeCanvasTestZoom) private var zoom
    let view: RecorderView
    let size: CGSize
    /// A point of the device's right edge at a zoom of 1, from the surface's center.
    let deviceEdge: CGPoint

    var body: some View {
        Recorder(view: view).frame(width: 30, height: 30)
            .position(x: size.width / 2 + deviceEdge.x * zoom + 35, y: size.height / 2 + deviceEdge.y * zoom)
            .frame(width: size.width, height: size.height)
    }
}

/// Stands in for DeviceKit's device view: a surface of a fixed size that draws its contents, which start at its top
/// left, at the canvas's zoom around its center.
private struct ZoomedComposition<Content: View>: View {
    @Environment(\.nativeCanvasTestZoom) private var zoom
    let size: CGSize
    @ViewBuilder let content: Content

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.frame(width: size.width, height: size.height)
            content
        }
        .scaleEffect(zoom)
        .frame(width: size.width, height: size.height)
    }
}

extension EnvironmentValues {
    @Entry fileprivate var nativeCanvasTestFlag = false
    @Entry fileprivate var nativeCanvasTestZoom: CGFloat = 1
}
