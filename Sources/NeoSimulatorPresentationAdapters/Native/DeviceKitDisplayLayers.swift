import AppKit

/// The layers that DeviceKit's device view shows as the displays of devices whose video NeoSimulator receives
/// itself. DeviceKit's own provider for a physical device's display receives video through AVConference, which
/// needs an entitlement this app cannot have.
///
/// NeoSimulator's DeviceKit plugin shows these layers. The plugin shares no Swift module with the app, so it finds
/// this class, its lookup, and its notification through the Objective-C runtime by the names declared here.
@MainActor @objc(NeoSimulatorDeviceKitDisplayLayers)
package final class DeviceKitDisplayLayers: NSObject {
    /// Posted when a device's layers are registered or withdrawn.
    package static let didChange = Notification.Name("NeoSimulatorDeviceKitDisplayLayersDidChange")

    private struct Display: Hashable {
        let device: UUID
        let identifier: UInt32
    }
    private static var layers: [Display: CALayer] = [:]

    /// Offers a layer for each of a device's displays, by CoreDevice's display identifier. The plugin's provider
    /// for a display exists only while the display has a layer here, so DeviceKit keeps its own providers for
    /// every other device.
    package static func register(_ displays: [UInt32: CALayer], for device: UUID) {
        layers = layers.filter { $0.key.device != device }
        for (identifier, layer) in displays { layers[Display(device: device, identifier: identifier)] = layer }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    package static func withdraw(_ device: UUID) {
        guard layers.keys.contains(where: { $0.device == device }) else { return }
        layers = layers.filter { $0.key.device != device }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    @objc(layerForDevice:display:)
    package static func layer(forDevice device: UUID, display: UInt32) -> CALayer? {
        layers[Display(device: device, identifier: display)]
    }
}
