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

/// The changes sent to one device's external display, which `HostApplication`
/// keeps for the device across its sessions, so that a session's changes
/// follow the power-off that the previous session's close sent. CoreSimulator
/// completes each change later, so they are sent one at a time and the last
/// choice wins: a change asked for while one is in flight waits for it and
/// replaces an earlier change that waits. Each change goes through the screen
/// connection of the session that asked for it.
///
/// Disabled always sends the power-off. Simulator.app sends it only while the
/// display's window is connected; CoreSimulator completes a power-off of a
/// display that is already off without an error, so no record of the
/// display's power, which reports and completions arriving in either order
/// could leave wrong, decides it.
@MainActor
final class ExternalDisplayChanges {
    private struct Change {
        let mode: ExternalDisplayMode
        let screen: any SimulatorExternalScreen
        let report: @MainActor (Error) -> Void
    }

    private var isSending = false
    private var waiting: Change?
    /// What waits for no change to be in flight or waiting.
    private var idleWaits: [@MainActor () -> Void] = []

    /// Whether a change is in flight or waiting.
    var isBusy: Bool { isSending || waiting != nil }

    /// Sends `mode`'s change through `screen`, or makes it wait for the change
    /// in flight. `report` receives a failure, also one CoreSimulator reports
    /// later.
    func apply(_ mode: ExternalDisplayMode, through screen: any SimulatorExternalScreen,
               report: @escaping @MainActor (Error) -> Void) {
        let change = Change(mode: mode, screen: screen, report: report)
        if isSending { waiting = change } else { send(change) }
    }

    /// Drops the change that waits, as when its session disconnects from a
    /// device that is shutting down.
    func discardWaiting() {
        waiting = nil
        finishIfIdle()
    }

    /// Waits until no change is in flight or waiting, or until `deadline`.
    /// Returns whether the changes completed.
    func idle(before deadline: ContinuousClock.Instant) async -> Bool {
        guard isBusy else { return true }
        return await withCheckedContinuation { continuation in
            let wait = IdleWait(continuation)
            idleWaits.append { wait.finish(true) }
            wait.timer = Task { [wait] in
                guard (try? await Task.sleep(until: deadline)) != nil else { return }
                wait.finish(false)
            }
        }
    }

    private func send(_ change: Change) {
        // The completion keeps these changes until CoreSimulator calls it.
        let completion: @MainActor (Error?) -> Void = { error in self.completed(error: error, report: change.report) }
        isSending = true
        do {
            if let size = change.mode.pixelSize {
                try change.screen.setMode(pixelSize: size, scale: ExternalDisplayMode.scale, carPlayProperties: nil,
                                          completion: completion)
            } else {
                try change.screen.powerOff(completion: completion)
            }
        } catch {
            isSending = false
            change.report(error)
        }
    }

    private func completed(error: Error?, report: @MainActor (Error) -> Void) {
        isSending = false
        if let error { report(error) }
        if let waiting {
            self.waiting = nil
            send(waiting)
        }
        finishIfIdle()
    }

    private func finishIfIdle() {
        guard !isBusy, !idleWaits.isEmpty else { return }
        let waits = idleWaits
        idleWaits = []
        for wait in waits { wait() }
    }
}

/// One wait for a device's external display changes, which their completion
/// or the wait's deadline ends, whichever comes first.
@MainActor
private final class IdleWait {
    private var continuation: CheckedContinuation<Bool, Never>?
    var timer: Task<Void, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }

    func finish(_ idle: Bool) {
        timer?.cancel()
        continuation?.resume(returning: idle)
        continuation = nil
    }
}
