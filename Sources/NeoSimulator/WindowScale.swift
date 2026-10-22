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

    /// The space Simulator.app keeps between a device window's header and its
    /// display: 10 points less the top padding of the bezel's images,
    /// `SimDeviceChrome.images.padding.height`, which `bezelPadding` gives,
    /// or nil without a bezel. It does not change with the display's scale.
    static func displayGap(bezelPadding: NSSize?) -> CGFloat { 10 - (bezelPadding?.height ?? 0) }

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

    /// Where Simulator.app moves a window after a drag on a corner of its
    /// bezel: a window that does not reach into `visible` inset by 128
    /// points moves along each axis until it touches that inset frame.
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

/// A drag on a corner of the bezel, as Simulator.app's `DeviceWindow`
/// tracks it: the dragged corner of the display follows the pointer, and the
/// opposite corner stays where it was.
struct BezelResize {
    let corner: DisplayResizeRect.Corner
    /// The window's frame on the screen when the drag began, as tall as the
    /// display below the window's header.
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

    /// The window's origin for a display of `size`, which keeps the opposite
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
    /// Window ▸ Show Device Bezels: Simulator.app's app-wide `ShowChrome`,
    /// which each device window follows when it opens or reconnects and when
    /// the command changes it. Like Simulator.app's `boolForKey:`, a value
    /// that `defaults write` saves as a string, such as `NO`, reads as
    /// `UserDefaults` reads it. It is on unless it was turned off, as its
    /// registered default says.
    var showsDeviceBezels: Bool {
        object(forKey: HostPreferences.showChrome) == nil || bool(forKey: HostPreferences.showChrome)
    }

    /// Simulator.app's app-wide `AllowsMoveByDragOnWindowChrome`: whether a
    /// press on a device window's bezel outside its corners moves the window.
    /// Like Simulator.app, which reads it with `boolForKey:` at each press, a
    /// change applies to the next press. It is on unless it was turned off, as
    /// its registered default says.
    var movesWindowByDraggingBezel: Bool {
        object(forKey: HostPreferences.allowsMoveByDragOnWindowChrome) == nil
            || bool(forKey: HostPreferences.allowsMoveByDragOnWindowChrome)
    }
}

private let windowGeometryKey = "SimulatorWindowGeometry"
private let windowScaleKey = "WindowScale"
private let windowCenterKey = "WindowCenter"

/// A device's window geometry under Simulator.app's keys, saved separately
/// for each arrangement of the Mac's screens:
/// `DevicePreferences[UDID].SimulatorWindowGeometry[configuration]`, where
/// `configuration` names the arrangement in `ScreenConfigurations`.
extension PreferenceStore {
    /// Where the device's window last closed while the Mac's screens had
    /// `screens` as their frames, and the display's scale then.
    ///
    /// `center` is `WindowCenter` as `NSStringFromPoint` writes it. Like
    /// Simulator.app, the zero point counts as none, which is also what
    /// `NSPointFromString` reads from an unreadable string. `scale` is
    /// `WindowScale`, nil when it is not a positive number. Both are nil when
    /// the window has not closed in this arrangement of screens. Like
    /// Simulator.app, reading saves a new arrangement, as
    /// `screenConfiguration(for:)` does.
    func windowGeometry(forDevice identifier: String, screens: [NSRect]) -> (center: NSPoint?, scale: CGFloat?) {
        let configuration = screenConfiguration(for: screens)
        let geometry = (preferences(forDevice: identifier)?[windowGeometryKey] as? [String: Any])?[configuration]
            as? [String: Any]
        let center = (geometry?[windowCenterKey] as? String).map(NSPointFromString)
        let scale = (geometry?[windowScaleKey] as? NSNumber).map { CGFloat($0.doubleValue) }
        return (center == .zero ? nil : center, WindowScale.usable(scale))
    }

    /// Saves where the device's window closed and, when given, its display
    /// scale, for the arrangement of screens with `screens` as their frames.
    /// Like Simulator.app, this replaces what was saved for the arrangement
    /// and keeps what was saved for others and the device's other preferences.
    func setWindowGeometry(center: NSPoint, scale: CGFloat?, forDevice identifier: String, screens: [NSRect]) {
        let configuration = screenConfiguration(for: screens)
        var saved: [String: Any] = [windowCenterKey: NSStringFromPoint(center)]
        if let scale { saved[windowScaleKey] = Double(scale) }
        updatePreferences(forDevice: identifier) { device in
            var geometry = device[windowGeometryKey] as? [String: Any] ?? [:]
            geometry[configuration] = saved
            device[windowGeometryKey] = geometry
        }
    }

    /// The device's own preferences, `DevicePreferences[UDID]`, or nil when
    /// it has none.
    func preferences(forDevice identifier: String) -> [String: Any]? {
        (object(forKey: HostPreferences.devicePreferences) as? [String: Any])?[identifier] as? [String: Any]
    }

    /// Changes the device's own preferences, keeping the other devices'.
    func updatePreferences(forDevice identifier: String, _ change: (inout [String: Any]) -> Void) {
        var devices = object(forKey: HostPreferences.devicePreferences) as? [String: Any] ?? [:]
        var device = devices[identifier] as? [String: Any] ?? [:]
        change(&device)
        devices[identifier] = device
        set(devices, forKey: HostPreferences.devicePreferences)
    }

    /// The UUID string that names the arrangement of screens with `screens`
    /// as their frames, as Simulator.app finds it in `ScreenConfigurations`:
    /// an entry that lists as many frames, as `NSStringFromRect` strings,
    /// with each of `screens` among them, in any order. Without one, a new
    /// UUID is saved with the frames. Like Simulator.app, the entries are read
    /// only when every one is a list of strings; otherwise the new UUID
    /// replaces them. An entry whose name is not a UUID, where Simulator.app
    /// stops, is skipped.
    func screenConfiguration(for screens: [NSRect]) -> String {
        var configurations = object(forKey: HostPreferences.screenConfigurations) as? [String: [String]] ?? [:]
        for (name, frames) in configurations where frames.count == screens.count {
            let saved = frames.map(NSRectFromString)
            if screens.allSatisfy(saved.contains), let identifier = UUID(uuidString: name) {
                return identifier.uuidString
            }
        }
        let identifier = UUID().uuidString
        configurations[identifier] = screens.map(NSStringFromRect)
        set(configurations, forKey: HostPreferences.screenConfigurations)
        return identifier
    }
}
