import AppKit
import CryptoKit
import NeoSimulatorKit
import Observation

/// The embedded viewport's scale is independent from compact-window geometry.
@Observable @MainActor
package final class CanvasZoom {
    package enum Mode: Equatable {
        case fit, physicalSize, fixed(CGFloat)
    }

    package enum Action: String, CaseIterable {
        case zoomOut, fit, physicalSize, zoomIn
    }

    package var mode = Mode.fit
    /// Target visual magnification of the embedded scroll view.
    package var scale: CGFloat = 1
    package var fitScale: CGFloat = 1
}

/// Window scaling modes; they resize the presentation without changing the guest screen.
package enum WindowScaleMode: String {
    case physicalSize, pointAccurate, pixelAccurate, fitScreen
}

/// A window whose display the Window menu's scale commands scale: a device
/// window, or the window of its external display.
@MainActor
package protocol DisplayScaling: AnyObject {
    /// Whether the command can run, as Simulator.app validates it.
    func canSetScale(_ mode: WindowScaleMode) -> Bool
    /// The command's checkmark, or nil to leave it as it is.
    func scaleState(_ mode: WindowScaleMode) -> NSControl.StateValue?
    func setScale(_ mode: WindowScaleMode)
}

/// Simulator.app's arithmetic for the window scale modes.
package enum WindowScale {
    /// The points per inch Physical Size assumes for a Mac screen and for a
    /// device when macOS or CoreSimulator does not report them.
    package static let defaultHostDensity: CGFloat = 110
    package static let defaultDeviceDensity: CGFloat = 163

    /// Host points per inch divided by device points per inch.
    /// Missing, zero, or invalid densities use defaults.
    package static func physicalSize(hostDensity: CGFloat?, deviceDensity: CGFloat?) -> CGFloat {
        (usable(hostDensity) ?? defaultHostDensity) / (usable(deviceDensity) ?? defaultDeviceDensity)
    }

    /// A Mac screen's points per inch: its width in points over its physical
    /// width, or nil when macOS does not report them.
    package static func density(of screen: NSScreen) -> CGFloat? {
        let description = screen.deviceDescription
        guard let display = description[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let size = (description[.size] as? NSValue)?.sizeValue else { return nil }
        return size.width / (CGDisplayScreenSize(display.uint32Value).width / 25.4)
    }

    /// Pixel Accurate: one pixel of the device's screen per pixel of the
    /// Mac's. A missing value counts as 1.
    package static func pixelAccurate(screenScale: CGFloat?, backingScaleFactor: CGFloat?) -> CGFloat {
        (screenScale ?? 1) / (backingScaleFactor ?? 1)
    }

    /// Simulator.app minimum scales: 0.4 iPhone, 0.25 iPad, 0.6 watch;
    /// other displays must fit within 240×240 points at minimum.
    package static func minimum(family: DeviceCapabilities.Family?, displayClass: UInt16?,
                        fitting240 fitting: @autoclosure () -> CGFloat) -> CGFloat {
        switch family {
        case .iPhone where displayClass == 0: 0.4
        case .iPad where displayClass == 0: 0.25
        case .watch: 0.6
        default: fitting()
        }
    }

    /// Unscaled gap above the display: 10 points minus bezel top padding, or zero without a bezel.
    package static func displayGap(bezelPadding: NSSize?) -> CGFloat { bezelPadding.map { 10 - $0.height } ?? 0 }

    /// Whether the display is at `target`, as Simulator.app compares scales.
    package static func matches(_ scale: CGFloat, _ target: CGFloat) -> Bool { abs(scale - target) < 0.001 }

    /// `value` when it is a positive finite number.
    package static func usable(_ value: CGFloat?) -> CGFloat? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    /// Moves overflowing axes into the visible frame; oversized windows align to the opposite edge.
    package static func origin(of frame: NSRect, within visible: NSRect) -> NSPoint {
        func position(_ origin: CGFloat, _ length: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
            if origin < lower { return min(upper - length, lower) }
            if origin + length > upper { return max(lower, upper - length) }
            return origin
        }
        return NSPoint(x: position(frame.minX, frame.width, visible.minX, visible.maxX),
                       y: position(frame.minY, frame.height, visible.minY, visible.maxY))
    }

    /// Keeps the bezel below the screen's visible top while allowing its padding and other edges beyond it.
    package static func frame(_ frame: NSRect, constrainedBelow visible: NSRect, topInset inset: CGFloat) -> NSRect {
        let height = frame.height - inset
        guard visible.maxY < frame.minY + height else { return frame }
        var constrained = frame
        constrained.origin.y = visible.minY + (visible.height - height)
        return constrained
    }
}

package enum DisplayResizeCorner: String {
    case lowerLeft, lowerRight, upperRight, upperLeft

    package var isLeft: Bool { self == .lowerLeft || self == .upperLeft }
    package var isLower: Bool { self == .lowerLeft || self == .lowerRight }
}

/// Converts a corner drag into a uniform display size.
package struct CanvasResize {
    package let corner: DisplayResizeCorner
    package let size: NSSize
    package let pointer: NSPoint

    package func requestedSize(pointerAt location: NSPoint) -> NSSize {
        let dx = (location.x - pointer.x) * (corner.isLeft ? -1 : 1)
        let dy = (location.y - pointer.y) * (corner.isLower ? -1 : 1)
        // Project the drag onto the corner's diagonal so either axis can scale the device.
        let factor = 1 + 2 * (dx * size.width + dy * size.height)
            / (size.width * size.width + size.height * size.height)
        return NSSize(width: size.width * factor, height: size.height * factor)
    }
}

extension PreferenceStore {
    /// `UseMonobar`, which lets a device window's toolbar take the unified
    /// style. It is on unless it was turned off, as its registered default says.
    package var usesMonobar: Bool {
        object(forKey: HostPreferences.useMonobar) == nil || bool(forKey: HostPreferences.useMonobar)
    }

    /// `UseCompactTitleBar`, which gives every device window's toolbar the
    /// compact unified style. It is off unless it was turned on.
    package var usesCompactTitleBar: Bool { bool(forKey: HostPreferences.useCompactTitleBar) }

    /// AllowsMoveByDragOnWindowChrome defaults on and is read for each press.
    package var movesWindowByDraggingBezel: Bool {
        object(forKey: HostPreferences.allowsMoveByDragOnWindowChrome) == nil
            || bool(forKey: HostPreferences.allowsMoveByDragOnWindowChrome)
    }
}

private let windowScaleKey = "WindowScale"
private let windowCenterKey = "WindowCenter"

/// Separate geometry storage for primary and external-display windows.
package enum WindowGeometryKind {
    case device, externalDisplay

    fileprivate var key: String { self == .device ? "SimulatorWindowGeometry" : "ExternalWindowGeometry" }
}

/// Geometry is stored per device and host-screen arrangement using Simulator.app keys.
extension PreferenceStore {
    /// Reads the saved center and scale for this screen arrangement.
    /// Zero/unreadable centers and nonpositive scales are absent.
    package func windowGeometry(forDevice identifier: String, screens: [NSRect],
                        kind: WindowGeometryKind = .device) -> (center: NSPoint?, scale: CGFloat?) {
        let configuration = screenConfiguration(for: screens)
        let geometry = (preferences(forDevice: identifier)?[kind.key] as? [String: Any])?[configuration]
            as? [String: Any]
        let center = (geometry?[windowCenterKey] as? String).map(NSPointFromString)
        let scale = (geometry?[windowScaleKey] as? NSNumber).map { CGFloat($0.doubleValue) }
        return (center == .zero ? nil : center, WindowScale.usable(scale))
    }

    /// Replaces geometry for this arrangement, preserving other arrangements and preferences.
    package func setWindowGeometry(center: NSPoint, scale: CGFloat?, forDevice identifier: String, screens: [NSRect],
                           kind: WindowGeometryKind = .device) {
        let configuration = screenConfiguration(for: screens)
        var saved: [String: Any] = [windowCenterKey: NSStringFromPoint(center)]
        if let scale { saved[windowScaleKey] = Double(scale) }
        updatePreferences(forDevice: identifier) { device in
            var geometry = device[kind.key] as? [String: Any] ?? [:]
            geometry[configuration] = saved
            device[kind.key] = geometry
        }
    }

    /// Keeps existing arrangement UUIDs so saved geometry remains reachable.
    /// New arrangements have a stable ID without a shared registry to race over.
    package func screenConfiguration(for screens: [NSRect]) -> String {
        let configurations = object(forKey: HostPreferences.screenConfigurations) as? [String: Any] ?? [:]
        let frames = screens.map(NSStringFromRect).sorted()
        for name in configurations.keys.sorted() {
            guard let saved = configurations[name] as? [String], let identifier = UUID(uuidString: name) else { continue }
            if saved.map({ NSStringFromRect(NSRectFromString($0)) }).sorted() == frames {
                return identifier.uuidString
            }
        }
        // NSStringFromRect emits a single line. Sorting and separating the frames
        // preserves screen order independence without process-randomized hashing.
        let digest = Array(SHA256.hash(data: Data(frames.joined(separator: "\n").utf8)))
        return UUID(uuid: (digest[0], digest[1], digest[2], digest[3],
                           digest[4], digest[5], digest[6], digest[7],
                           digest[8], digest[9], digest[10], digest[11],
                           digest[12], digest[13], digest[14], digest[15])).uuidString
    }
}
