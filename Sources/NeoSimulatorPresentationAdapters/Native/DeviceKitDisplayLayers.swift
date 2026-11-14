import AppKit
import CoreVideo

/// The layers that DeviceKit's device view shows as the displays of devices whose video NeoSimulator receives
/// itself. DeviceKit's own provider for a physical device's display receives video through AVConference, which
/// needs an entitlement this app cannot have.
///
/// NeoSimulator's DeviceKit plugin shows these layers. The plugin shares no Swift module with the app, so it finds
/// this class, its two lookups, and its notification through the Objective-C runtime by the names declared here.
@MainActor @objc(NeoSimulatorDeviceKitDisplayLayers)
package final class DeviceKitDisplayLayers: NSObject {
    /// Posted when a device's displays start or stop being offered.
    package static let didChange = Notification.Name("NeoSimulatorDeviceKitDisplayLayersDidChange")
    private static let pluginName = "NeoSimulatorDeviceKitPlugin"

    /// What a display shows, on each layer that a view of it holds.
    private final class Display {
        let layers = NSHashTable<CALayer>.weakObjects()
        /// Kept while its surface is shown, so the decoder's pool does not draw another frame into the surface.
        var frame: CVPixelBuffer?
        var contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)

        func apply(to layer: CALayer) {
            layer.contents = frame.flatMap { CVPixelBufferGetIOSurface($0)?.takeUnretainedValue() }
            layer.contentsRect = contentsRect
        }
    }
    private struct Offer {
        var screens = 1
        var displays: [UInt32: Display] = [:]
    }
    private static var offers: [UUID: Offer] = [:]
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

    /// Offers the displays of a device, for one screen that shows the device. The plugin's provider for a display
    /// exists only while the device is offered, so DeviceKit keeps its own providers for every other device.
    package static func offer(_ device: UUID) {
        if offers[device] != nil {
            offers[device]?.screens += 1
        } else {
            offers[device] = Offer()
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    /// Ends one screen's offer. The device's displays stay offered while another screen shows the device.
    package static func withdraw(_ device: UUID) {
        guard let offer = offers[device] else { return }
        if offer.screens > 1 {
            offers[device]?.screens -= 1
        } else {
            offers[device] = nil
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    @objc(offersDevice:)
    package static func offers(_ device: UUID) -> Bool { offers[device] != nil }

    /// A layer that shows a display of an offered device, by CoreDevice's display identifier. Each view of the
    /// display holds its own layer, because a layer has one superlayer.
    @objc(makeLayerForDevice:display:)
    package static func makeLayer(forDevice device: UUID, display: UInt32) -> CALayer? {
        guard offers[device] != nil else { return nil }
        let layer = CALayer()
        layer.contentsGravity = .resize
        layer.backgroundColor = NSColor.black.cgColor
        layer.isOpaque = true
        let shown = offers[device]?.displays[display] ?? Display()
        offers[device]?.displays[display] = shown
        shown.layers.add(layer)
        shown.apply(to: layer)
        return layer
    }

    /// Shows a decoded frame as a display of an offered device. `visible` is the part of the frame, from its top
    /// left, that shows the display.
    package static func show(_ frame: CVPixelBuffer, visible: CGSize, on display: UInt32, of device: UUID) {
        guard offers[device] != nil else { return }
        let width = CGFloat(CVPixelBufferGetWidth(frame)), height = CGFloat(CVPixelBufferGetHeight(frame))
        guard width > 0, height > 0 else { return }
        let shown = offers[device]?.displays[display] ?? Display()
        offers[device]?.displays[display] = shown
        shown.frame = frame
        // A layer's unit space starts at its bottom left, and the frame's padding is at its right and bottom.
        let shownWidth = min(1, visible.width / width), shownHeight = min(1, visible.height / height)
        shown.contentsRect = CGRect(x: 0, y: 1 - shownHeight, width: shownWidth, height: shownHeight)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in shown.layers.allObjects { shown.apply(to: layer) }
        CATransaction.commit()
    }
}
