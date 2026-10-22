import AppKit

/// I/O ▸ External Displays: the external display Simulator.app connects to a
/// device, by the menu tag that Simulator.app also saves for the device. Each
/// size is shown at a point per pixel. Simulator.app's CarPlay, tag 2714,
/// comes with CarPlay itself.
enum ExternalDisplayMode: Int, CaseIterable {
    case disabled = 2114
    case size640x480 = 2214
    case size720x480 = 2514
    case size1024x768 = 2314
    case size1280x720 = 2414
    case size1920x1080 = 2614
    case size3840x2160 = 2664

    /// The scale, in pixels per point, of every size Simulator.app offers.
    static let scale: CGFloat = 1

    /// The title in Simulator.app's MainMenu.nib.
    var title: String {
        switch self {
        case .disabled: "Disabled"
        case .size640x480: "640×480"
        case .size720x480: "720×480"
        case .size1024x768: "1024×768"
        case .size1280x720: "1280×720 (720p)"
        case .size1920x1080: "1920×1080 (1080p)"
        case .size3840x2160: "3840×2160 (4K)"
        }
    }

    /// The screen's pixel size, or nil for Disabled.
    var pixelSize: CGSize? {
        switch self {
        case .disabled: nil
        case .size640x480: CGSize(width: 640, height: 480)
        case .size720x480: CGSize(width: 720, height: 480)
        case .size1024x768: CGSize(width: 1024, height: 768)
        case .size1280x720: CGSize(width: 1280, height: 720)
        case .size1920x1080: CGSize(width: 1920, height: 1080)
        case .size3840x2160: CGSize(width: 3840, height: 2160)
        }
    }
}

/// A device's external display, CoreSimulator's TVOut screen, as its
/// `SimScreenProperties` report it.
struct ExternalScreenState: Equatable {
    /// `powerState` is 1. CoreSimulator turns the screen on when its mode is set.
    var isPoweredOn: Bool
    /// `pixelSize`.
    var pixelSize: CGSize
    /// `currentMode.preferredUIScale`, the screen's pixels per point.
    var scale: CGFloat

    /// The External Displays item this state is: Disabled while the screen is
    /// off, otherwise the size it shows at a point per pixel, or nil for a size
    /// or scale that the menu does not offer, such as one that `simctl io
    /// screenConfig` set.
    var mode: ExternalDisplayMode? {
        guard isPoweredOn else { return .disabled }
        guard scale == ExternalDisplayMode.scale else { return nil }
        return ExternalDisplayMode.allCases.first { $0.pixelSize == pixelSize }
    }
}

/// A mode that a screen advertises, `SimScreenMode`: the pixel sizes it
/// takes, by its `sizeRule`, at its `preferredUIScale`.
struct ExternalScreenMode: Equatable {
    enum Sizes: Equatable {
        /// Size rule 0: `exactSize`.
        case exact(CGSize)
        /// Size rule 1: from `minSize` through `maxSize` in each dimension.
        case range(minimum: CGSize, maximum: CGSize)
        /// Size rule 2: one of `allowedSizes`.
        case allowed([CGSize])
    }

    /// The sizes the mode takes, or nil for a size rule this host does not
    /// know. Simulator.app traps on such a rule; here the mode takes no size.
    var sizes: Sizes?
    var scale: CGFloat

    func accepts(_ size: CGSize, scale: CGFloat) -> Bool {
        guard scale == self.scale, let sizes else { return false }
        switch sizes {
        case .exact(let exact): return exact == size
        case .range(let minimum, let maximum):
            return minimum.width <= size.width && minimum.height <= size.height
                && size.width <= maximum.width && size.height <= maximum.height
        case .allowed(let allowed): return allowed.contains(size)
        }
    }

    /// Which mode Simulator.app sets for `size` at `scale`: the screen's
    /// current mode when the screen already has that size and that mode has
    /// that scale, otherwise the first advertised mode that takes both. Nil
    /// when none does.
    enum Choice: Equatable {
        case current
        case advertised(Int)
    }

    static func choice(for size: CGSize, scale: CGFloat, currentSize: CGSize, currentScale: CGFloat,
                       among modes: [ExternalScreenMode]) -> Choice? {
        if currentSize == size, currentScale == scale { return .current }
        return modes.firstIndex { $0.accepts(size, scale: scale) }.map(Choice.advertised)
    }
}

private let externalDisplayKey = "SimulatorExternalDisplay"

extension PreferenceStore {
    /// The External Displays tag last chosen for the device, Simulator.app's
    /// `DevicePreferences[UDID].SimulatorExternalDisplay`. Like Simulator.app,
    /// a missing value or one that is not an integer is Disabled's. A tag
    /// that this host does not know, such as CarPlay's, is returned as is.
    func externalDisplayTag(forDevice identifier: String) -> Int {
        preferences(forDevice: identifier)?[externalDisplayKey] as? Int ?? ExternalDisplayMode.disabled.rawValue
    }

    /// Saves the device's External Displays choice, keeping its other
    /// preferences and the other devices'.
    func setExternalDisplayTag(_ tag: Int, forDevice identifier: String) {
        updatePreferences(forDevice: identifier) { $0[externalDisplayKey] = tag }
    }
}

/// The changes a session sends to its device's external display.
/// CoreSimulator completes each change later, so they are sent one at a
/// time and the last choice wins: a choice made while a change is in flight
/// waits for it and replaces an earlier choice that waits.
///
/// Disabled always sends the power-off. Simulator.app sends it only while the
/// display's window is connected; CoreSimulator completes a power-off of a
/// display that is already off without an error, so the session keeps no
/// record of the display's power that reports and completions arriving in
/// either order could leave wrong.
@MainActor
final class ExternalDisplayChanges {
    let screen: any SimulatorExternalScreen
    private var isSending = false
    private var waiting: (mode: ExternalDisplayMode, report: @MainActor (Error) -> Void)?
    private var isClosed = false

    init(screen: any SimulatorExternalScreen) { self.screen = screen }

    /// Sends `mode`'s change, or makes it wait for the change in flight.
    /// `report` receives a failure, also one CoreSimulator reports later.
    func apply(_ mode: ExternalDisplayMode, report: @escaping @MainActor (Error) -> Void) {
        guard !isClosed else { return }
        if isSending { waiting = (mode, report) } else { send(mode, report: report) }
    }

    /// Stops taking choices and the display's reports. With `poweringOff`,
    /// turns the display off once the change in flight completes.
    func close(poweringOff: Bool, report: @escaping @MainActor (Error) -> Void) {
        guard !isClosed else { return }
        isClosed = true
        screen.disconnect()
        waiting = poweringOff ? (.disabled, report) : nil
        if !isSending { sendWaiting() }
    }

    private func send(_ mode: ExternalDisplayMode, report: @escaping @MainActor (Error) -> Void) {
        // The completion keeps these changes until CoreSimulator calls it.
        let completion: @MainActor (Error?) -> Void = { error in self.completed(error: error, report: report) }
        isSending = true
        do {
            if let size = mode.pixelSize {
                try screen.setMode(pixelSize: size, scale: ExternalDisplayMode.scale, carPlayProperties: nil,
                                   completion: completion)
            } else {
                try screen.powerOff(completion: completion)
            }
        } catch {
            isSending = false
            report(error)
        }
    }

    private func completed(error: Error?, report: @MainActor (Error) -> Void) {
        isSending = false
        if let error { report(error) }
        sendWaiting()
    }

    private func sendWaiting() {
        guard let waiting else { return }
        self.waiting = nil
        send(waiting.mode, report: waiting.report)
    }
}
