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

/// The app's registry of display layers, as its Objective-C names give it.
enum AppDisplayLayers {
    static let didChange = Notification.Name("NeoSimulatorDeviceKitDisplayLayersDidChange")

    /// The layer that the app offers for a display, read on the main thread, where the app keeps its registry.
    static func layer(device: UUID, display: UInt32) -> CALayer? {
        guard Thread.isMainThread else { return DispatchQueue.main.sync { layer(device: device, display: display) } }
        typealias Lookup = @convention(c) (AnyClass, Selector, NSUUID, UInt32) -> Unmanaged<CALayer>?
        let selector = NSSelectorFromString("layerForDevice:display:")
        guard let registry: AnyClass = NSClassFromString("NeoSimulatorDeviceKitDisplayLayers"),
              let method = class_getClassMethod(registry, selector) else { return nil }
        let lookup = unsafeBitCast(method_getImplementation(method), to: Lookup.self)
        return lookup(registry, selector, device as NSUUID, display)?.takeUnretainedValue()
    }
}

final class DisplayLayerProviderCreator: DisplayViewFramebufferProvider.Creator {
    let identifier = "dev.lynnswap.NeoSimulator.DisplayLayerProviderCreator"

    func createDisplayViewFramebufferProvider(forDeviceIdentifier device: UUID, display: DisplayIdentifier)
        -> (any DisplayViewFramebufferProvider.Instance)?
    {
        guard case .displayID(let identifier) = display,
              AppDisplayLayers.layer(device: device, display: identifier) != nil else { return nil }
        return DisplayLayerProvider(device: device, display: identifier)
    }
}

/// Shows the app's layer for one display. It is active while the app offers that layer.
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

    func canProvideView() async -> Bool { AppDisplayLayers.layer(device: device, display: display) != nil }

    /// Above DeviceKit's AVConference provider, which cannot receive this device's video in this app.
    func displayPriority() async -> DisplayViewFramebufferProvider.DisplayPriority { .optimal }

    func displayView() -> (any View)? { DisplayLayerView(device: device, display: display) }

    func view() -> (any View)? { displayView() }

    private func update() {
        let active = connected && AppDisplayLayers.layer(device: device, display: display) != nil
        switch (state, active) {
        case (.active, true), (.inactive, false): break
        default: state = active ? .active : .inactive
        }
    }
}

private struct DisplayLayerView: NSViewRepresentable {
    let device: UUID
    let display: UInt32

    func makeNSView(context: Context) -> DisplayLayerHostView { DisplayLayerHostView() }

    func updateNSView(_ view: DisplayLayerHostView, context: Context) {
        view.show(AppDisplayLayers.layer(device: device, display: display))
    }
}

/// Fills itself with the app's layer.
private final class DisplayLayerHostView: NSView {
    private var shown: CALayer?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { nil }

    func show(_ layer: CALayer?) {
        guard layer !== shown else { return }
        shown?.removeFromSuperlayer()
        shown = layer
        if let layer { self.layer?.addSublayer(layer) }
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
