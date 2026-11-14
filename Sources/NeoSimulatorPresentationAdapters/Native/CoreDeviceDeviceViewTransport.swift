import ABIBridge
import AppKit
import CoreVideo
import NeoSimulatorDeviceIO
import NeoSimulatorKit
import OSLog
import Synchronization

/// Shows a physical device in DeviceKit's device view, which draws a device-specific model such as a folding
/// iPhone's, with the device's own video on the model's displays.
///
/// DeviceKit's view draws the device, follows its posture, and sends its touches. The video, the device's buttons,
/// screenshots, and recording stay with the capture transport, whose frames reach DeviceKit's displays through
/// `DeviceKitDisplayLayers`.
@MainActor
package final class CoreDeviceDeviceViewTransport: RemoteScreenTransport {
    private let remote: CoreDeviceRemoteScreenDevice
    private let device: UUID
    private let capture: CoreDeviceCaptureTransport
    private let contentView: NSView
    /// The capture transport draws its own screen here, which this transport does not show.
    private let unshownScreen = NSView()
    private let canvasView = DeviceViewFittingView()
    private let canvas: NativeDeviceCanvas
    private var showsCanvas = false
    private var stopped = false
    /// Whether this transport's offer of the device's displays stands. Other screens of the device count their own.
    private var offersDisplays = false
    /// The newest decoded frame that the main actor has not shown yet. A newer frame replaces it, so a busy main
    /// actor shows the latest frame instead of every frame.
    private struct PendingFrame: @unchecked Sendable {
        let buffer: CVPixelBuffer
        let visible: CGSize
        let display: UInt32?
    }
    private nonisolated let pendingFrame = Mutex<PendingFrame?>(nil)

    package var drawsDevice: Bool { true }
    package var nativeInputView: NSView? { showsCanvas ? canvas.inputView : nil }
    /// DeviceKit's view sends the touches and pointer movements that reach it.
    package var inputCapabilities: Set<RemoteDeviceInputKind> { capture.inputCapabilities.subtracting([.pointer, .digitizer]) }
    package var canCaptureScreenshot: Bool { capture.canCaptureScreenshot }
    package var canRecordScreen: Bool { capture.canRecordScreen }

    private static let logger = Logger(subsystem: "dev.lynnswap.NeoSimulator", category: "RemoteScreen")

    /// Makes the transport for a device that DeviceKit draws with a device-specific view, when the app's video can
    /// be shown in it. The result is nil for every other device, and when DeviceKit's view cannot be composed, so
    /// that the device keeps its framed screen. DeviceKit must be loaded.
    package static func make(remote: CoreDeviceRemoteScreenDevice, connection: CoreDeviceScreenConnection,
                             contentView: NSView) async throws -> CoreDeviceDeviceViewTransport? {
        guard let device = UUID(uuidString: remote.identifier), DeviceKitDisplayLayers.canBeShown else { return nil }
        let info = try await remote.type.resolve(.swift(.getter("deviceInfo", as: (() -> NativeSwiftValue).self)))
        let value = try unsafe info.unsafeInvoke(on: remote.object)
        let hardware = try await value.type.resolve(.swift(.getter("hardwareModel", as: (() -> String?).self)))
        guard DevicePosturePayload.isFoldingModel(try unsafe hardware.unsafeInvoke(on: value)) else { return nil }
        let canvas: NativeDeviceCanvas
        do {
            canvas = try await NativeDeviceCanvas.connect(remote: remote,
                buttons: NativeDeviceScreenInput(input: CoreDeviceScreenInput(remote: remote)))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.error("DeviceKit's device view is unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        do {
            return try await CoreDeviceDeviceViewTransport(
                remote: remote, device: device, connection: connection, contentView: contentView, canvas: canvas)
        } catch {
            canvas.disconnect()
            throw error
        }
    }

    private init(remote: CoreDeviceRemoteScreenDevice, device: UUID, connection: CoreDeviceScreenConnection,
                 contentView: NSView, canvas: NativeDeviceCanvas) async throws {
        self.remote = remote
        self.device = device
        self.contentView = contentView
        self.canvas = canvas
        unshownScreen.isHidden = true
        capture = try await CoreDeviceCaptureTransport(remote: remote, connection: connection, contentView: unshownScreen)
    }

    package func start(events: @escaping @MainActor (RemoteScreenTransportEvent) -> Void) async throws {
        guard !stopped else { throw CancellationError() }
        DeviceKitDisplayLayers.offer(device)
        offersDisplays = true
        contentView.addSubview(unshownScreen)
        capture.decodedFrames = { [weak self] buffer, visible, display in
            guard let self else { return }
            let frame = PendingFrame(buffer: buffer, visible: visible, display: display)
            let scheduled = self.pendingFrame.withLock { pending in
                defer { pending = frame }
                return pending != nil
            }
            if !scheduled { DispatchQueue.main.async { [weak self] in self?.showPendingFrame() } }
        }
        try await capture.start { event in
            switch event {
            // DeviceKit's view places and turns the displays itself.
            case .displayShown, .displayAngle: break
            default: events(event)
            }
        }
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        // DeviceKit asks for a display's provider when its view appears, which the offer above precedes.
        showsCanvas = true
        canvasView.frame = contentView.bounds
        canvasView.autoresizingMask = [.width, .height]
        canvasView.show(canvas)
        contentView.addSubview(canvasView)
        events(.inputGeometryChanged)
    }

    private func showPendingFrame() {
        guard let frame = pendingFrame.withLock({ pending in defer { pending = nil }; return pending }), !stopped else { return }
        // A frame that does not show which display it carries is the shown display's.
        guard let display = frame.display ?? capture.shownDisplay else { return }
        DeviceKitDisplayLayers.show(frame.buffer, visible: frame.visible, on: display, of: device)
    }

    package func captureScreenshot() async throws -> CGImage { try await capture.captureScreenshot() }
    package func startRecording(displayUniqueID: String?) async throws -> any RemoteScreenRecordingHandle {
        try await capture.startRecording(displayUniqueID: displayUniqueID)
    }
    package func send(_ input: RemoteScreenInput) async throws { try await capture.send(input) }
    package func releaseInputs() async throws { try await capture.releaseInputs() }

    package func stop() async throws {
        stopped = true
        showsCanvas = false
        canvasView.show(nil)
        canvasView.removeFromSuperview()
        canvas.disconnect()
        if offersDisplays {
            offersDisplays = false
            DeviceKitDisplayLayers.withdraw(device)
        }
        defer { unshownScreen.removeFromSuperview() }
        try await capture.stop()
    }
}

/// Fits DeviceKit's device view, which has a natural size, inside the screen's area.
@MainActor
private final class DeviceViewFittingView: NSView {
    private var canvas: NativeDeviceCanvas?

    func show(_ canvas: NativeDeviceCanvas?) {
        self.canvas?.onSizeChange = nil
        self.canvas?.view.removeFromSuperview()
        self.canvas = canvas
        if let canvas {
            addSubview(canvas.view)
            canvas.onSizeChange = { [weak self] in self?.needsLayout = true }
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let canvas else { return }
        let natural = canvas.naturalSize
        guard natural.width > 0, natural.height > 0, bounds.width > 0, bounds.height > 0 else { return }
        let zoom = min(bounds.width / natural.width, bounds.height / natural.height)
        canvas.setZoom(zoom)
        let size = CGSize(width: natural.width * zoom, height: natural.height * zoom)
        canvas.view.frame = CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                                   width: size.width, height: size.height)
    }
}
