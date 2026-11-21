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
    package var nativePoseControls: NativeDevicePoseControls? { showsCanvas ? canvas.poseControls : nil }
    package var visibleDisplays: [AnyHashable] { showsCanvas ? canvas.visibleDisplays : [] }
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
        let canvas: NativeDeviceCanvas
        do {
            let info = try await remote.type.resolve(.swift(.getter("deviceInfo", as: (() -> NativeSwiftValue).self)))
            let value = try unsafe info.unsafeInvoke(on: remote.object)
            let hardware = try await value.type.resolve(.swift(.getter("hardwareModel", as: (() -> String?).self)))
            guard DevicePosturePayload.isFoldingModel(try unsafe hardware.unsafeInvoke(on: value)) else { return nil }
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
package final class DeviceViewFittingView: NSView {
    private var canvas: NativeDeviceCanvas?
    /// The menu whose enabled commands come before the device's keys.
    package var commandMenu: () -> NSMenu? = { NSApp.mainMenu }

    /// DeviceKit's views take every key equivalent for the device, before the app's menu sees it. A key that an
    /// enabled command uses runs that command instead. A disabled command's key still reaches the device, where the
    /// menu alone would consume it: a simulator's Home command is disabled for a physical device, whose own
    /// keyboard shortcut the same key is.
    package override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let menu = commandMenu(), menu.performEnabledKeyEquivalent(with: event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

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

    package override func layout() {
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

/// Refreshes commands for the selected device before the app matches their shortcuts.
@MainActor package protocol DeviceKeyEquivalentMenuDelegate: NSMenuDelegate {
    func prepare(_ menu: NSMenu, forKeyEquivalent event: NSEvent)
}

/// AppKit can match a shortcut against the last contents of a submenu without asking its delegate to update it.
@MainActor package final class DeviceCommandMainMenu: NSMenu {
    package var dynamicShortcutMenus: [NSMenu] = []

    package override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // AppKit dispatches the key on the main thread. The event stays there for this synchronous override.
        nonisolated(unsafe) let menu = self
        nonisolated(unsafe) let input = event
        return MainActor.assumeIsolated { menu.dispatch(input, requiresEnabledCommand: false) }
    }

    fileprivate func dispatch(_ event: NSEvent, requiresEnabledCommand: Bool) -> Bool {
        for menu in dynamicShortcutMenus {
            (menu.delegate as? any DeviceKeyEquivalentMenuDelegate)?.prepare(menu, forKeyEquivalent: event)
        }
        if requiresEnabledCommand && !hasEnabledCommand(for: event) { return false }
        return super.performKeyEquivalent(with: event)
    }
}

extension NSMenu {
    @MainActor fileprivate func performEnabledKeyEquivalent(with event: NSEvent) -> Bool {
        if let menu = self as? DeviceCommandMainMenu { return menu.dispatch(event, requiresEnabledCommand: true) }
        return hasEnabledCommand(for: event) && performKeyEquivalent(with: event)
    }

    @MainActor fileprivate func hasEnabledCommand(for event: NSEvent) -> Bool {
        update()
        return items.contains { item in
            if let submenu = item.submenu { return submenu.hasEnabledCommand(for: event) }
            return item.isEnabled && !item.isHidden
                && event.matchesMenuKey(item.keyEquivalent, modifiers: item.keyEquivalentModifierMask)
        }
    }
}

extension NSEvent {
    /// AppKit's menu representation differs from the event's characters for the two Delete keys.
    private var menuCharacters: String? {
        switch charactersIgnoringModifiers {
        case "\u{7f}": "\u{8}"
        case "\u{f728}": "\u{7f}"
        default: charactersIgnoringModifiers
        }
    }

    package var unshiftedMenuKey: String? {
        if specialKey != nil || !modifierFlags.contains(.shift) { return menuCharacters }
        return characters(byApplyingModifiers: []) ?? menuCharacters
    }

    package func matchesMenuKey(_ key: String, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard !key.isEmpty else { return false }
        let mask: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let pressed = modifierFlags.intersection(mask)
        var required = modifiers.intersection(mask)
        if key != key.lowercased() { required.insert(.shift) }
        if required.contains(.shift) {
            return required == pressed && unshiftedMenuKey?.lowercased() == key.lowercased()
        }
        if pressed.contains(.shift), specialKey != nil { return false }
        return required == pressed.subtracting(.shift) && menuCharacters == key
    }
}
