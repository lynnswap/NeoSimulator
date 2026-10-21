import AppKit

/// Window ▸ Physical Size, Point Accurate, Pixel Accurate, and Fit Screen.
/// Each shows the display at a scale and sizes the window to it, without
/// changing the device's screen.
enum WindowScaleMode: String {
    case physicalSize, pointAccurate, pixelAccurate, fitScreen
}

/// Simulator.app's arithmetic for the window scale modes.
enum WindowScale {
    /// The points per inch Physical Size assumes for a Mac screen and for a
    /// device when macOS or CoreSimulator does not report them.
    static let defaultHostDensity: CGFloat = 110
    static let defaultDeviceDensity: CGFloat = 163

    /// Physical Size: the Mac screen's points per inch over the device's, so
    /// that an inch of the device's screen covers an inch of the Mac's.
    /// Simulator.app uses the defaults only for missing values and divides by
    /// a zero size; NeoSimulator also uses them for a zero or invalid value.
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

    /// The smallest scale Simulator.app lets Physical Size, Point Accurate,
    /// and Pixel Accurate set: 0.4 for an iPhone and 0.25 for an iPad on its
    /// own screen, 0.6 for a watch, and otherwise the scale that fits the
    /// display in 240 by 240 points.
    static func minimum(family: DeviceCapabilities.Family?, displayClass: UInt16?,
                        fitting240 fitting: @autoclosure () -> CGFloat) -> CGFloat {
        switch family {
        case .iPhone where displayClass == 0: 0.4
        case .iPad where displayClass == 0: 0.25
        case .watch: 0.6
        default: fitting()
        }
    }

    /// Whether the display is at `target`, as Simulator.app compares scales.
    static func matches(_ scale: CGFloat, _ target: CGFloat) -> Bool { abs(scale - target) < 0.001 }

    /// `value` when it is a positive finite number.
    static func usable(_ value: CGFloat?) -> CGFloat? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    /// Where Simulator.app moves a window after a fixed scale: inside
    /// `visible` along each axis where the window crosses an edge. A window
    /// longer than `visible` lines up with the opposite edge instead.
    static func origin(of frame: NSRect, within visible: NSRect) -> NSPoint {
        func position(_ origin: CGFloat, _ length: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
            if origin < lower { return min(upper - length, lower) }
            if origin + length > upper { return max(lower, upper - length) }
            return origin
        }
        return NSPoint(x: position(frame.minX, frame.width, visible.minX, visible.maxX),
                       y: position(frame.minY, frame.height, visible.minY, visible.maxY))
    }

    /// Simulator.app's `DeviceWindow.constrainFrameRect(_:to:)` for a window
    /// whose bezel has top padding: `frame` keeps its size and moves down only
    /// when its top, less `inset`, is above `visible`. The window may extend
    /// past every other edge of the screen.
    static func frame(_ frame: NSRect, constrainedBelow visible: NSRect, topInset inset: CGFloat) -> NSRect {
        let height = frame.height - inset
        guard visible.maxY < frame.minY + height else { return frame }
        var constrained = frame
        constrained.origin.y = visible.minY + (visible.height - height)
        return constrained
    }
}

/// Where preferences are kept: the app's user defaults, or a test's own store.
protocol PreferenceStore: AnyObject {
    func object(forKey defaultName: String) -> Any?
    func set(_ value: Any?, forKey defaultName: String)
}

extension UserDefaults: PreferenceStore {}

extension PreferenceStore {
    /// Window ▸ Show Device Bezels: Simulator.app's app-wide `ShowChrome`,
    /// which each device window follows when it opens or reconnects and when
    /// the command changes it. It is on unless it was turned off, as its
    /// registered default says.
    var showsDeviceBezels: Bool { object(forKey: HostPreferences.showChrome) as? Bool ?? true }
}

private let windowGeometryKey = "SimulatorWindowGeometry"
private let windowScaleKey = "WindowScale"
private let windowCenterKey = "WindowCenter"

/// A device's window geometry under Simulator.app's keys:
/// `DevicePreferences[UDID].SimulatorWindowGeometry`.
extension PreferenceStore {
    /// The display scale the device's window last closed at, `WindowScale`.
    /// Nil when none was saved or it is not a positive number.
    func windowScale(forDevice identifier: String) -> CGFloat? {
        WindowScale.usable((windowGeometry(forDevice: identifier)?[windowScaleKey] as? NSNumber)
            .map { CGFloat($0.doubleValue) })
    }

    /// The center of the device's window when it last closed, `WindowCenter`
    /// as `NSStringFromPoint` writes it. Like Simulator.app, the zero point
    /// counts as none, which is also what `NSPointFromString` reads from an
    /// unreadable string.
    func windowCenter(forDevice identifier: String) -> NSPoint? {
        guard let string = windowGeometry(forDevice: identifier)?[windowCenterKey] as? String else { return nil }
        let center = NSPointFromString(string)
        return center == .zero ? nil : center
    }

    /// Saves where the device's window closed and, when given, its display
    /// scale, keeping the device's other preferences.
    func setWindowGeometry(center: NSPoint, scale: CGFloat?, forDevice identifier: String) {
        var devices = object(forKey: HostPreferences.devicePreferences) as? [String: Any] ?? [:]
        var device = devices[identifier] as? [String: Any] ?? [:]
        var geometry = device[windowGeometryKey] as? [String: Any] ?? [:]
        geometry[windowCenterKey] = NSStringFromPoint(center)
        if let scale { geometry[windowScaleKey] = Double(scale) }
        device[windowGeometryKey] = geometry
        devices[identifier] = device
        set(devices, forKey: HostPreferences.devicePreferences)
    }

    private func windowGeometry(forDevice identifier: String) -> [String: Any]? {
        let devices = object(forKey: HostPreferences.devicePreferences) as? [String: Any]
        return (devices?[identifier] as? [String: Any])?[windowGeometryKey] as? [String: Any]
    }
}
