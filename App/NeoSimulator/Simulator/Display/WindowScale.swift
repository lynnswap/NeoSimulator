import AppKit
import CryptoKit
import Observation

/// The embedded viewport's scale is independent from compact-window geometry.
@Observable @MainActor
final class CanvasZoom {
    enum Mode: Equatable {
        case fit, physicalSize, fixed(CGFloat)
    }

    enum Action: String, CaseIterable {
        case zoomOut, fit, physicalSize, zoomIn
    }

    var mode = Mode.fit
    var scale: CGFloat = 1
    var fitScale: CGFloat = 1
}

/// Window scaling modes; they resize the presentation without changing the guest screen.
enum WindowScaleMode: String {
    case physicalSize, pointAccurate, pixelAccurate, fitScreen
}

/// A window whose display the Window menu's scale commands scale: a device
/// window, or the window of its external display.
@MainActor
protocol DisplayScaling: AnyObject {
    /// Whether the command can run, as Simulator.app validates it.
    func canSetScale(_ mode: WindowScaleMode) -> Bool
    /// The command's checkmark, or nil to leave it as it is.
    func scaleState(_ mode: WindowScaleMode) -> NSControl.StateValue?
    func setScale(_ mode: WindowScaleMode)
}

/// Simulator.app's arithmetic for the window scale modes.
enum WindowScale {
    /// The points per inch Physical Size assumes for a Mac screen and for a
    /// device when macOS or CoreSimulator does not report them.
    static let defaultHostDensity: CGFloat = 110
    static let defaultDeviceDensity: CGFloat = 163

    /// Host points per inch divided by device points per inch.
    /// Missing, zero, or invalid densities use defaults.
    static func physicalSize(hostDensity: CGFloat?, deviceDensity: CGFloat?) -> CGFloat {
        (usable(hostDensity) ?? defaultHostDensity) / (usable(deviceDensity) ?? defaultDeviceDensity)
    }

    /// A Mac screen's points per inch: its width in points over its physical
    /// width, or nil when macOS does not report them.
    static func density(of screen: NSScreen) -> CGFloat? {
        let description = screen.deviceDescription
        guard let display = description[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let size = (description[.size] as? NSValue)?.sizeValue else { return nil }
        return size.width / (CGDisplayScreenSize(display.uint32Value).width / 25.4)
    }

    /// Pixel Accurate: one pixel of the device's screen per pixel of the
    /// Mac's. A missing value counts as 1.
    static func pixelAccurate(screenScale: CGFloat?, backingScaleFactor: CGFloat?) -> CGFloat {
        (screenScale ?? 1) / (backingScaleFactor ?? 1)
    }

    /// Simulator.app minimum scales: 0.4 iPhone, 0.25 iPad, 0.6 watch;
    /// other displays must fit within 240×240 points at minimum.
    static func minimum(family: DeviceCapabilities.Family?, displayClass: UInt16?,
                        fitting240 fitting: @autoclosure () -> CGFloat) -> CGFloat {
        switch family {
        case .iPhone where displayClass == 0: 0.4
        case .iPad where displayClass == 0: 0.25
        case .watch: 0.6
        default: fitting()
        }
    }

    /// Unscaled gap above the display: 10 points minus bezel top padding, or zero without a bezel.
    static func displayGap(bezelPadding: NSSize?) -> CGFloat { bezelPadding.map { 10 - $0.height } ?? 0 }

    /// Whether the display is at `target`, as Simulator.app compares scales.
    static func matches(_ scale: CGFloat, _ target: CGFloat) -> Bool { abs(scale - target) < 0.001 }

    /// `value` when it is a positive finite number.
    static func usable(_ value: CGFloat?) -> CGFloat? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    /// Moves overflowing axes into the visible frame; oversized windows align to the opposite edge.
    static func origin(of frame: NSRect, within visible: NSRect) -> NSPoint {
        func position(_ origin: CGFloat, _ length: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
            if origin < lower { return min(upper - length, lower) }
            if origin + length > upper { return max(lower, upper - length) }
            return origin
        }
        return NSPoint(x: position(frame.minX, frame.width, visible.minX, visible.maxX),
                       y: position(frame.minY, frame.height, visible.minY, visible.maxY))
    }

    /// Keeps part of a corner-resized window within the visible frame inset by 128 points.
    static func origin(of frame: NSRect, reaching visible: NSRect) -> NSPoint {
        let inset = visible.insetBy(dx: 128, dy: 128)
        guard !frame.intersects(inset) else { return frame.origin }
        func position(_ origin: CGFloat, _ length: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
            if origin > upper { return upper }
            if origin + length < lower { return lower - length }
            return origin
        }
        return NSPoint(x: position(frame.minX, frame.width, inset.minX, inset.maxX),
                       y: position(frame.minY, frame.height, inset.minY, inset.maxY))
    }

    /// Keeps the bezel below the screen's visible top while allowing its padding and other edges beyond it.
    static func frame(_ frame: NSRect, constrainedBelow visible: NSRect, topInset inset: CGFloat) -> NSRect {
        let height = frame.height - inset
        guard visible.maxY < frame.minY + height else { return frame }
        var constrained = frame
        constrained.origin.y = visible.minY + (visible.height - height)
        return constrained
    }
}

/// Corner drag with the opposite display corner fixed.
struct BezelResize {
    let corner: DisplayResizeRect.Corner
    /// The display's frame on the screen when the drag began.
    let start: NSRect
    /// Where the pointer was on the screen when the drag began.
    let pointer: NSPoint

    /// The display's size the drag asks for with the pointer at `location`.
    func requestedSize(pointerAt location: NSPoint) -> NSSize {
        let dx = location.x - pointer.x, dy = location.y - pointer.y
        return NSSize(width: start.width + (corner.isLeft ? -dx : dx),
                      height: start.height + (corner.isLower ? -dy : dy))
    }

    /// The display's largest size: the dragged corner may reach the edges of
    /// `visible`, the screen's visible frame.
    func largestSize(within visible: NSRect) -> NSSize {
        NSSize(width: corner.isLeft ? start.maxX - visible.minX : visible.maxX - start.minX,
               height: corner.isLower ? start.maxY - visible.minY : visible.maxY - start.minY)
    }

    /// The display's origin for a display of `size`, which keeps the opposite
    /// corner where it was.
    func origin(for size: NSSize) -> NSPoint {
        NSPoint(x: corner.isLeft ? start.maxX - size.width : start.minX,
                y: corner.isLower ? start.maxY - size.height : start.minY)
    }
}

/// Where preferences are kept: the app's user defaults, or a test's own store.
protocol PreferenceStore: AnyObject {
    func object(forKey defaultName: String) -> Any?
    /// The value as `UserDefaults.bool(forKey:)` reads it.
    func bool(forKey defaultName: String) -> Bool
    func set(_ value: Any?, forKey defaultName: String)
}

extension UserDefaults: PreferenceStore {}

extension PreferenceStore {
    /// ShowChrome defaults on and uses UserDefaults Boolean coercion.
    var showsDeviceBezels: Bool {
        object(forKey: HostPreferences.showChrome) == nil || bool(forKey: HostPreferences.showChrome)
    }

    /// `UseMonobar`, which lets a device window's toolbar take the unified
    /// style. It is on unless it was turned off, as its registered default says.
    var usesMonobar: Bool {
        object(forKey: HostPreferences.useMonobar) == nil || bool(forKey: HostPreferences.useMonobar)
    }

    /// `UseCompactTitleBar`, which gives every device window's toolbar the
    /// compact unified style. It is off unless it was turned on.
    var usesCompactTitleBar: Bool { bool(forKey: HostPreferences.useCompactTitleBar) }

    /// AllowsMoveByDragOnWindowChrome defaults on and is read for each press.
    var movesWindowByDraggingBezel: Bool {
        object(forKey: HostPreferences.allowsMoveByDragOnWindowChrome) == nil
            || bool(forKey: HostPreferences.allowsMoveByDragOnWindowChrome)
    }
}

private let windowScaleKey = "WindowScale"
private let windowCenterKey = "WindowCenter"

/// Separate geometry storage for primary and external-display windows.
enum WindowGeometryKind {
    case device, externalDisplay

    fileprivate var key: String { self == .device ? "SimulatorWindowGeometry" : "ExternalWindowGeometry" }
}

/// Geometry is stored per device and host-screen arrangement using Simulator.app keys.
extension PreferenceStore {
    /// Reads the saved center and scale for this screen arrangement.
    /// Zero/unreadable centers and nonpositive scales are absent.
    func windowGeometry(forDevice identifier: String, screens: [NSRect],
                        kind: WindowGeometryKind = .device) -> (center: NSPoint?, scale: CGFloat?) {
        let configuration = screenConfiguration(for: screens)
        let geometry = (preferences(forDevice: identifier)?[kind.key] as? [String: Any])?[configuration]
            as? [String: Any]
        let center = (geometry?[windowCenterKey] as? String).map(NSPointFromString)
        let scale = (geometry?[windowScaleKey] as? NSNumber).map { CGFloat($0.doubleValue) }
        return (center == .zero ? nil : center, WindowScale.usable(scale))
    }

    /// Replaces geometry for this arrangement, preserving other arrangements and preferences.
    func setWindowGeometry(center: NSPoint, scale: CGFloat?, forDevice identifier: String, screens: [NSRect],
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

    /// Reads an independent record, falling back to the previous shared dictionary.
    func preferences(forDevice identifier: String) -> [String: Any]? {
        object(forKey: devicePreferencesKey(for: identifier)) as? [String: Any]
            ?? (object(forKey: HostPreferences.devicePreferences) as? [String: Any])?[identifier] as? [String: Any]
    }

    /// Each renderer owns its devices; separate keys prevent another renderer's save
    /// from replacing this device's record. The legacy dictionary remains read-only.
    func updatePreferences(forDevice identifier: String, _ change: (inout [String: Any]) -> Void) {
        var device = preferences(forDevice: identifier) ?? [:]
        change(&device)
        set(device, forKey: devicePreferencesKey(for: identifier))
    }

    private func devicePreferencesKey(for identifier: String) -> String {
        "\(HostPreferences.devicePreferences).\(identifier)"
    }

    /// Keeps existing arrangement UUIDs so saved geometry remains reachable.
    /// New arrangements have a stable ID without a shared registry to race over.
    func screenConfiguration(for screens: [NSRect]) -> String {
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
