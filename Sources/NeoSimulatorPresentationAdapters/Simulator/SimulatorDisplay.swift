import AppKit
import NeoSimulatorDeviceIO
import NeoSimulatorKit

/// `SimScreenUIOrientation`, the guest's interface orientation.
package enum SimScreenUIOrientation {
    /// The angle SimulatorKit's `SimScreenUIOrientation.toAngle()` gives a
    /// raw orientation: landscape 4 is shown at +90° and landscape 3 at -90°.
    package static func displayAngle(_ rawValue: UInt32) -> Double {
        switch rawValue {
        case 2: 180
        case 3: -90
        case 4: 90
        default: 0
        }
    }
}

/// Raw SimDigitizerInputView.TouchMode values used when trackpad force is unavailable.
package enum SimulatedTouchMode: Int {
    case shallow = 0, deep = 1
}

/// A connected display as what presents it sees it: its views, frames and scale, on top of what its session uses.
@MainActor
package protocol SimulatorDisplay: DeviceSessionDisplay {
    var view: NSView { get }
    /// The rendered device's rectangle, including visible chrome, in view coordinates.
    var deviceFrame: NSRect { get }
    /// The guest framebuffer rectangle in view coordinates; canvas resize handles stay outside it.
    var framebufferFrame: NSRect { get }
    var usesNativeCanvas: Bool { get }
    var nativePoseControls: NativeDevicePoseControls? { get }
    /// The input digitizer, or the loaded plugin's overlay.
    var inputView: NSView { get }
    /// Loaded device-profile plugin, or nil until available. Throws if unusable,
    /// including a plugin from another Xcode installation.
    func userInterfacePlugin() async throws -> SimulatorUserInterfacePlugin?
    /// `SimDisplayView.renderScale`: the display's size relative to the
    /// device's screen in points, which the screen's resolution does not change.
    var renderScale: CGFloat { get }
    func setRenderScale(_ scale: CGFloat)
    /// The embedded canvas magnification of a native composition presented outside the
    /// magnified document, which renders it after measuring; nil outside the canvas viewport.
    func setCanvasMagnification(_ magnification: CGFloat?)
    /// The display's size at `scale`, with the bezel when it is shown.
    func size(for scale: CGFloat) -> NSSize
    /// The largest scale at which the display fits `size`.
    func scale(for size: NSSize) -> CGFloat
    /// `SimDeviceScreen.scale`, the screen's pixels per point, or nil when unknown.
    var screenScale: CGFloat? { get }
    /// `SimDeviceScreen.displayClass`, or nil when unknown; 0 is a device's own screen.
    var displayClass: UInt16? { get }
    /// `SimDeviceChrome.images.padding`, or nil when no bezel is visible.
    var chromePadding: NSSize? { get }
    /// Controls SimulatorKit's own bezel resize cursors.
    func setShowsResizeCursors(_ shows: Bool)
    func setChromeVisible(_ visible: Bool)
    func setKeyboardEnabled(_ enabled: Bool)
    /// Gives the screen the Mac trackpads' scrolling and pinches through the device's native trackpad, when it has one,
    /// whatever the hardware keyboard's state. Taking them away ends the gestures in progress.
    func setTrackpadEnabled(_ enabled: Bool)
    /// Controls whether digitizer scrolling reaches the device's crown or dial.
    func setSupportsScrolling(_ supports: Bool)
    /// Sets and posts `com.apple.UIKit.SimulatorWantsEdgeSwipes`.
    /// When enabled, UIKit requires digitizer-marked edge starts; otherwise near-edge touches suffice.
    func setWantsEdgeSwipes(_ wants: Bool)
    /// `SimDigitizerInputView.supportTouchPressure`: whether clicks press
    /// the screen with a pressure.
    func setSupportsTouchPressure(_ supports: Bool)
    /// `SimDigitizerInputView.useForceTrackpadForPressure`: whether the
    /// pressure follows the force on a Force Touch trackpad.
    func setUsesTrackpadForce(_ uses: Bool)
    /// `SimDigitizerInputView.simulatedTouchMode`.
    func setSimulatedTouchMode(_ mode: SimulatedTouchMode)
    /// Adds `indicator`'s `DrawOption` to `SimDigitizerInputView.drawOptions`
    /// or removes it, keeping the other options.
    func setTouchIndicator(_ indicator: TouchIndicator, shown: Bool)
    func beginResize()
    func endResize()
}

extension SimulatorDisplay {
    package var deviceFrame: NSRect { view.bounds }
    package var framebufferFrame: NSRect { view.bounds }
    package var usesNativeCanvas: Bool { false }
    package var nativePoseControls: NativeDevicePoseControls? { nil }
    package func setCanvasMagnification(_ magnification: CGFloat?) {}
}

/// The full displays of the sessions a presenter presents, each found from what its session holds without a downcast.
/// Every display registers when it connects; this keeps none of them alive.
@MainActor
package final class SimulatorDisplaySet {
    private struct Entry { weak var display: (any SimulatorDisplay)? }
    private var entries: [ObjectIdentifier: Entry] = [:]

    package init() {}

    package func register(_ display: any SimulatorDisplay) {
        entries = entries.filter { $0.value.display != nil }
        entries[ObjectIdentifier(display)] = Entry(display: display)
    }

    /// `display`, which a display of this set's presenter connected and so registered.
    package func full(for display: any DeviceSessionDisplay) -> any SimulatorDisplay {
        guard let full = entries[ObjectIdentifier(display)]?.display else {
            preconditionFailure("A session's display was not connected through this display set.")
        }
        return full
    }
}
