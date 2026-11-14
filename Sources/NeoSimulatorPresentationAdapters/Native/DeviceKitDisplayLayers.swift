import AppKit
import CoreVideo

/// The layers that DeviceKit's device view shows as the displays of devices whose video NeoSimulator receives
/// itself. DeviceKit's own provider for a physical device's display receives video through AVConference, which
/// needs an entitlement this app cannot have.
///
/// NeoSimulator's DeviceKit plugin shows these layers. The plugin shares no Swift module with the app, so it finds
/// this class, its lookup, and its notification through the Objective-C runtime by the names declared here.
@MainActor @objc(NeoSimulatorDeviceKitDisplayLayers)
package final class DeviceKitDisplayLayers: NSObject {
    /// Posted when a device's layers are offered or withdrawn.
    package static let didChange = Notification.Name("NeoSimulatorDeviceKitDisplayLayersDidChange")
    private static let pluginName = "NeoSimulatorDeviceKitPlugin"

    private static var devices: [UUID: [UInt32: CALayer]] = [:]
    private static var pluginLoads: Bool?

    /// Whether DeviceKit can load the app's plugin, which shows these layers. Library validation refuses it in a
    /// hardened app whose plugin has another team, as an ad hoc signature leaves it. DeviceKit must be loaded.
    package static var canBeShown: Bool {
        if let pluginLoads { return pluginLoads }
        let bundle = Bundle.main.builtInPlugInsURL
            .flatMap { Bundle(url: $0.appendingPathComponent("\(pluginName).devicekitplugin")) }
        let loads = bundle?.load() == true && NSClassFromString(pluginName) != nil
        pluginLoads = loads
        return loads
    }

    /// Offers a layer for each display of a device, by CoreDevice's display identifier. The plugin's provider for
    /// a display exists only while the device is offered, so DeviceKit keeps its own providers for every other
    /// device. A display's layer is made when it is first asked for.
    package static func offer(_ device: UUID) {
        guard devices[device] == nil else { return }
        devices[device] = [:]
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    package static func withdraw(_ device: UUID) {
        guard devices.removeValue(forKey: device) != nil else { return }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    @objc(layerForDevice:display:)
    package static func layer(forDevice device: UUID, display: UInt32) -> CALayer? {
        guard let layers = devices[device] else { return nil }
        if let layer = layers[display] { return layer }
        let layer = CALayer()
        layer.contentsGravity = .resize
        layer.backgroundColor = NSColor.black.cgColor
        layer.isOpaque = true
        devices[device]?[display] = layer
        return layer
    }

    /// Shows a decoded frame on a display's layer. `visible` is the part of the frame, from its top left, that
    /// shows the display.
    package static func show(_ frame: CVPixelBuffer, visible: CGSize, on display: UInt32, of device: UUID) {
        guard let layer = layer(forDevice: device, display: display) else { return }
        let width = CGFloat(CVPixelBufferGetWidth(frame)), height = CGFloat(CVPixelBufferGetHeight(frame))
        guard width > 0, height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = CVPixelBufferGetIOSurface(frame)?.takeUnretainedValue()
        layer.contentsRect = CGRect(x: 0, y: 0, width: min(1, visible.width / width), height: min(1, visible.height / height))
        CATransaction.commit()
    }
}
