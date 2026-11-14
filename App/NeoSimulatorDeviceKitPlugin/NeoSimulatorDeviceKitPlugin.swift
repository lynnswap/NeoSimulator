import AppKit
import DeviceKit
import ObjectiveC
import Observation
import SwiftUI

/// DeviceKit loads this plugin from the app's `PlugIns` directory. Its provider shows, in DeviceKit's device view,
/// the layer that the app offers for a display. The plugin shares no Swift module with the app, so it reads the
/// app's `DeviceKitDisplayLayers` through the Objective-C runtime.
@objc(NeoSimulatorDeviceKitPlugin)
public final class NeoSimulatorDeviceKitPlugin: NSObject, DeviceKitPlugin {
    public init(context: DeviceKitContext) async { super.init() }

    public var displayViewFramebufferProviderCreators: [any DisplayViewFramebufferProvider.Creator] {
        [DisplayLayerProviderCreator()]
    }
}

/// The app's registry of display layers, as its Objective-C names give it. The app keeps it on the main thread.
enum AppDisplayLayers {
    static let didChange = Notification.Name("NeoSimulatorDeviceKitDisplayLayersDidChange")
    private static let registry: AnyClass? = NSClassFromString("NeoSimulatorDeviceKitDisplayLayers")

    /// Whether the app offers the displays of a device.
    static func offers(_ device: UUID) -> Bool {
        guard Thread.isMainThread else { return DispatchQueue.main.sync { offers(device) } }
        typealias Offers = @convention(c) (AnyClass, Selector, NSUUID) -> ObjCBool
        let selector = NSSelectorFromString("offersDevice:")
        guard let registry, let method = class_getClassMethod(registry, selector) else { return false }
        return unsafeBitCast(method_getImplementation(method), to: Offers.self)(registry, selector, device as NSUUID).boolValue
    }

    /// A layer of its own for one view of a display, or nil when the app does not offer the device.
    static func makeLayer(device: UUID, display: UInt32) -> CALayer? {
        guard Thread.isMainThread else { return DispatchQueue.main.sync { makeLayer(device: device, display: display) } }
        typealias MakeLayer = @convention(c) (AnyClass, Selector, NSUUID, UInt32) -> Unmanaged<CALayer>?
        let selector = NSSelectorFromString("makeLayerForDevice:display:")
        guard let registry, let method = class_getClassMethod(registry, selector) else { return nil }
        let make = unsafeBitCast(method_getImplementation(method), to: MakeLayer.self)
        return make(registry, selector, device as NSUUID, display)?.takeUnretainedValue()
    }
}

final class DisplayLayerProviderCreator: DisplayViewFramebufferProvider.Creator {
    let identifier = "dev.lynnswap.NeoSimulator.DisplayLayerProviderCreator"

    func createDisplayViewFramebufferProvider(forDeviceIdentifier device: UUID, display: DisplayIdentifier)
        -> (any DisplayViewFramebufferProvider.Instance)?
    {
        guard case .displayID(let identifier) = display, AppDisplayLayers.offers(device) else { return nil }
        return DisplayLayerProvider(device: device, display: identifier)
    }
}

/// Shows one display of a device that the app offers. It is active while the app offers the device.
@Observable
final class DisplayLayerProvider: DisplayViewFramebufferProvider.Instance {
    let identifier: String
    private(set) var state = DisplayViewFramebufferProvider.State.inactive
    @ObservationIgnored private let device: UUID
    @ObservationIgnored private let display: UInt32
    @ObservationIgnored private var connected = false
    @ObservationIgnored private var observer: (any NSObjectProtocol)?

    init(device: UUID, display: UInt32) {
        self.device = device
        self.display = display
        identifier = "dev.lynnswap.NeoSimulator.DisplayLayerProvider.\(device.uuidString).\(display)"
        observer = NotificationCenter.default.addObserver(
            forName: AppDisplayLayers.didChange, object: nil, queue: .main
        ) { [weak self] _ in self?.update() }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func connect() async throws {
        await MainActor.run {
            connected = true
            update()
        }
    }

    func disconnect() async {
        await MainActor.run {
            connected = false
            update()
        }
    }

    func canProvideView() async -> Bool { AppDisplayLayers.offers(device) }

    /// Above DeviceKit's AVConference provider, which cannot receive this device's video in this app.
    func displayPriority() async -> DisplayViewFramebufferProvider.DisplayPriority { .optimal }

    func displayView() -> (any View)? { DisplayLayerView(device: device, display: display) }

    func view() -> (any View)? { displayView() }

    private func update() {
        let active = connected && AppDisplayLayers.offers(device)
        switch (state, active) {
        case (.active, true), (.inactive, false): break
        default: state = active ? .active : .inactive
        }
    }
}

private struct DisplayLayerView: NSViewRepresentable {
    let device: UUID
    let display: UInt32

    func makeNSView(context: Context) -> DisplayLayerHostView { DisplayLayerHostView(device: device, display: display) }

    func updateNSView(_ view: DisplayLayerHostView, context: Context) {}
}

/// Fills itself with a layer of the display, while the app offers the device.
private final class DisplayLayerHostView: NSView {
    private let device: UUID
    private let display: UInt32
    private var shown: CALayer?
    private var observer: (any NSObjectProtocol)?

    init(device: UUID, display: UInt32) {
        self.device = device
        self.display = display
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        observer = NotificationCenter.default.addObserver(
            forName: AppDisplayLayers.didChange, object: nil, queue: .main
        ) { [weak self] _ in self?.showOfferedLayer() }
        showOfferedLayer()
    }

    required init?(coder: NSCoder) { nil }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    private func showOfferedLayer() {
        let offered = AppDisplayLayers.offers(device)
        guard offered != (shown != nil) else { return }
        shown?.removeFromSuperlayer()
        shown = offered ? AppDisplayLayers.makeLayer(device: device, display: display) : nil
        if let shown { layer?.addSublayer(shown) }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shown?.frame = bounds
        CATransaction.commit()
    }
}
