import AppKit

/// I/O ▸ External Displays: the external display Simulator.app connects to a
/// device, by the menu tag that Simulator.app also saves for the device. Each
/// size is shown at a point per pixel; CarPlay makes the display a car's
/// CarPlay display in Simulator.app's default CarPlay configuration.
enum ExternalDisplayMode: Int, CaseIterable {
    case disabled = 2114
    case size640x480 = 2214
    case size720x480 = 2514
    case size1024x768 = 2314
    case size1280x720 = 2414
    case size1920x1080 = 2614
    case size3840x2160 = 2664
    case carPlay = 2714

    /// The sizes, in the menu's order.
    static let sizes: [ExternalDisplayMode] = [
        .size640x480, .size720x480, .size1024x768, .size1280x720, .size1920x1080, .size3840x2160,
    ]

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
        case .carPlay: "CarPlay"
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
        case .carPlay: CarPlayConfiguration.pixelSize
        }
    }

    /// The screen's scale, in pixels per point: 1 for every size, as
    /// Simulator.app sets them, and the CarPlay configuration's for CarPlay.
    var scale: CGFloat { self == .carPlay ? CarPlayConfiguration.scale : 1 }
}

/// Simulator.app's default CarPlay configuration (`StarkConfig`), which its
/// CarPlay item uses unless `CarPlayExtraOptions` lets an options panel change
/// it: an 800×480 screen at a scale of 2 with a touch screen, and no wheel,
/// back, or home controls.
enum CarPlayConfiguration {
    static let pixelSize = CGSize(width: 800, height: 480)
    static let scale: CGFloat = 2
    static let hasTouchScreen = true

    /// The configuration as Simulator.app writes it to the device's
    /// `extended_display.plist`, under its plain keys.
    static var file: [String: Any] {
        ["stark": true, "width": Int(pixelSize.width), "height": Int(pixelSize.height), "scale": Double(scale),
         "hasBackButton": false, "hasHomeButton": false, "hasWheel": false, "hasWheelBump": false,
         "hasTouchScreen": hasTouchScreen, "hasTouchScreenLofi": false, "protocols": [String]()]
    }

    /// What Simulator.app writes there for every other choice.
    static var disabledFile: [String: Any] { ["stark": 0] }

    /// Writes `file` for CarPlay, or `disabledFile`, to a device's
    /// `extended_display.plist` at `url`, creating its folder. Like
    /// Simulator.app, the file is written in place.
    static func save(carPlay: Bool, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: carPlay ? file : disabledFile, format: .xml, options: 0)
            .write(to: url)
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
    /// `carPlayProperties` is not nil: the screen is a CarPlay screen, as
    /// SimulatorKit's `SimDeviceScreen.isCarPlay` says of a TVOut screen.
    var isCarPlay = false

    /// The External Displays item this state is: Disabled while the screen is
    /// off, CarPlay while it is a CarPlay screen, otherwise the size it shows
    /// at a point per pixel, or nil for a size or scale that the menu does not
    /// offer, such as one that `simctl io screenConfig` set.
    var mode: ExternalDisplayMode? {
        guard isPoweredOn else { return .disabled }
        guard !isCarPlay else { return .carPlay }
        return ExternalDisplayMode.sizes.first { $0.pixelSize == pixelSize && $0.scale == scale }
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
    /// that this host does not know is returned as is.
    func externalDisplayTag(forDevice identifier: String) -> Int {
        preferences(forDevice: identifier)?[externalDisplayKey] as? Int ?? ExternalDisplayMode.disabled.rawValue
    }

    /// Saves the device's External Displays choice, keeping its other
    /// preferences and the other devices'.
    func setExternalDisplayTag(_ tag: Int, forDevice identifier: String) {
        updatePreferences(forDevice: identifier) { $0[externalDisplayKey] = tag }
    }
}

/// A part of an external display change that can fail on its own. A size or
/// Disabled sets the screen; CarPlay also writes the guest's configuration and
/// starts its CarPlay session and HID service, which a later change ends.
enum ExternalDisplayStep: Equatable {
    /// Writing the device's `extended_display.plist`.
    case carPlayConfiguration
    /// Setting the screen's mode, or turning it off.
    case screen
    /// Starting or ending the guest's CarPlay session.
    case carPlaySession(starting: Bool)
    /// Creating or removing the guest's CarPlay HID service.
    case carPlayService(creating: Bool)
}

/// A step of an external display change that failed, and why.
struct ExternalDisplayFailure {
    let step: ExternalDisplayStep
    let error: Error
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
///
/// CarPlay follows Simulator.app's steps: a choice writes the device's
/// `extended_display.plist` first, CarPlay's configuration for CarPlay and
/// `{stark: 0}` for every other item, since the guest reads it when the
/// screen's modes change. A size or CarPlay then ends the guest's CarPlay
/// session that this host started, removing its HID service first, and
/// Disabled ends it once the screen is off. Once the screen is a CarPlay
/// screen, CarPlay starts the session, then creates the HID service that takes
/// the display's touches. Each step's failure is reported and the change goes
/// on, except that a screen that did not change ends it and a session that did
/// not start leaves the HID service uncreated.
///
/// A change whose completion does not come must not stop the device's later
/// sessions. CoreSimulator completed every change sent while its device shut
/// down, after it shut down, and after it booted again, the last ones with an
/// error and up to 4.5 seconds late. The queue still stops waiting for a
/// change in flight when the session that sent it disconnects from a device
/// that is no longer booted, and, as a last resort for a completion that
/// never comes, after `completionTimeout`. It logs the change, and ignores its
/// completion if one comes later.
@MainActor
final class ExternalDisplayChanges {
    private struct Change {
        let mode: ExternalDisplayMode
        let screen: any SimulatorExternalScreen
        let savesCarPlayConfiguration: Bool
        let report: @MainActor ([ExternalDisplayFailure]) -> Void
    }

    /// The change in flight: its failures so far, the step that waits for a
    /// completion, and the timer that abandons it.
    private final class Run {
        let change: Change
        var failures: [ExternalDisplayFailure] = []
        var step = ExternalDisplayStep.screen
        /// The number of steps sent, which a completion must match.
        var steps = 0
        var timer: Task<Void, Never>?

        init(_ change: Change) { self.change = change }

        func fail(_ step: ExternalDisplayStep, _ error: Error) {
            failures.append(ExternalDisplayFailure(step: step, error: error))
        }
    }

    /// How long a step may wait for its completion: more than twice the
    /// longest completion seen, through a connection made before its device
    /// restarted.
    static let defaultCompletionTimeout: Duration = .seconds(10)
    /// How long the display stays off before it turns on as a CarPlay screen.
    /// The iOS 26.5 guest takes a display that becomes a CarPlay screen in
    /// place, or that turns on again before the guest has handled its
    /// power-off, as a display it already showed, and CarPlay never draws on
    /// it; 0.2 seconds off sufficed in every try.
    static let defaultCarPlayReconnectionDelay: Duration = .seconds(1)

    private let completionTimeout: Duration
    private let carPlayReconnectionDelay: Duration
    private var inFlight: Run?
    private var waiting: Change?
    /// What waits for no change to be in flight or waiting.
    private var idleWaits: [@MainActor () -> Void] = []
    /// Whether this host started the guest's CarPlay session, with its HID
    /// service, and has not ended it, and the device's boot then. The guest's
    /// CoreSimulatorBridge counts the sessions that hosts start, and a new
    /// boot starts it again without any, so a change ends only this session
    /// and only in that boot: an end without a session would count below
    /// zero and stop the next start.
    private var startedCarPlay = false
    private var carPlayBoot: Date?
    /// When a change last turned the display off.
    private var lastPowerOff: ContinuousClock.Instant?

    init(completionTimeout: Duration = ExternalDisplayChanges.defaultCompletionTimeout,
         carPlayReconnectionDelay: Duration = ExternalDisplayChanges.defaultCarPlayReconnectionDelay) {
        self.completionTimeout = completionTimeout
        self.carPlayReconnectionDelay = carPlayReconnectionDelay
    }

    /// Whether a change is in flight or waiting.
    var isBusy: Bool { inFlight != nil || waiting != nil }

    /// Sends `mode`'s change through `screen`, or makes it wait for the change
    /// in flight. With `savesCarPlayConfiguration`, as for a choice on a device
    /// with CarPlay, the change first writes the device's
    /// `extended_display.plist`. `report` receives the change's failures, also
    /// those CoreSimulator reports later, once the change ends.
    func apply(_ mode: ExternalDisplayMode, through screen: any SimulatorExternalScreen,
               savesCarPlayConfiguration: Bool, report: @escaping @MainActor ([ExternalDisplayFailure]) -> Void) {
        let change = Change(mode: mode, screen: screen, savesCarPlayConfiguration: savesCarPlayConfiguration,
                            report: report)
        if inFlight != nil { waiting = change } else { send(change) }
    }

    /// Stops waiting for the changes that `screen`'s session asked for, as
    /// when the session disconnects from a device that is no longer booted:
    /// the change that waits is dropped, and the one in flight abandoned.
    func abandon(changesThrough screen: any SimulatorExternalScreen) {
        if waiting?.screen === screen { waiting = nil }
        if let inFlight, inFlight.change.screen === screen {
            abandon(inFlight, reason: "its device is no longer booted", reporting: false)
        }
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

    // MARK: Steps

    private func send(_ change: Change) {
        let run = Run(change)
        inFlight = run
        let screen = change.screen
        if change.savesCarPlayConfiguration {
            do { try screen.saveCarPlayConfiguration(carPlay: change.mode == .carPlay) }
            catch { run.fail(.carPlayConfiguration, error) }
        }
        guard let size = change.mode.pixelSize else {
            // Like Simulator.app, CarPlay ends once the screen is off.
            return perform(.screen, in: run, { try screen.powerOff(completion: $0) }) { [self] turnedOff in
                guard turnedOff else { return finish(run) }
                lastPowerOff = .now
                endCarPlay(in: run) { [self] in finish(run) }
            }
        }
        let carPlay = change.mode == .carPlay
        let setMode: @MainActor () -> Void = { [self] in
            perform(.screen, in: run, {
                try screen.setMode(pixelSize: size, scale: change.mode.scale, carPlay: carPlay, completion: $0)
            }) { [self] changed in
                guard changed, carPlay else { return finish(run) }
                startCarPlay(in: run) { [self] in finish(run) }
            }
        }
        endCarPlay(in: run) { [self] in
            guard carPlay else { return setMode() }
            turnOffForCarPlay(in: run) { [self] in afterCarPlayReconnectionDelay(in: run, then: setMode) }
        }
    }

    /// Like Simulator.app before the display changes, ends the CarPlay
    /// session that this host started in the device's current boot: removes
    /// its HID service, then ends the session. Their failures are reported,
    /// and the change goes on.
    private func endCarPlay(in run: Run, then next: @escaping @MainActor () -> Void) {
        let screen = run.change.screen
        guard startedCarPlay, carPlayBoot == screen.deviceBootDate else {
            startedCarPlay = false
            return next()
        }
        perform(.carPlayService(creating: false), in: run, { try screen.setCarPlayService(connected: false, completion: $0) }) { [self] _ in
            perform(.carPlaySession(starting: false), in: run, { screen.setCarPlayEnabled(false, completion: $0) }) { [self] ended in
                if ended { startedCarPlay = false }
                next()
            }
        }
    }

    /// Like Simulator.app once the screen is a CarPlay screen, starts the
    /// guest's CarPlay session, then creates the HID service that takes the
    /// display's touches. Unlike Simulator.app, which creates it either way,
    /// the service waits for a session that started.
    private func startCarPlay(in run: Run, then next: @escaping @MainActor () -> Void) {
        let screen = run.change.screen
        perform(.carPlaySession(starting: true), in: run, { screen.setCarPlayEnabled(true, completion: $0) }) { [self] started in
            guard started else { return next() }
            startedCarPlay = true
            carPlayBoot = screen.deviceBootDate
            perform(.carPlayService(creating: true), in: run, { try screen.setCarPlayService(connected: true, completion: $0) }) { _ in next() }
        }
    }

    /// Turns off a display that shows something other than CarPlay, so that
    /// the guest takes it as a new display when it turns on as a CarPlay
    /// screen (see `defaultCarPlayReconnectionDelay`). Simulator.app changes
    /// the mode in place. A display that does not turn off ends the change.
    private func turnOffForCarPlay(in run: Run, then next: @escaping @MainActor () -> Void) {
        // A state that cannot be read leaves the display as it is.
        guard let state = try? run.change.screen.state(), state.isPoweredOn, !state.isCarPlay else { return next() }
        perform(.screen, in: run, { try run.change.screen.powerOff(completion: $0) }) { [self] turnedOff in
            guard turnedOff else { return finish(run) }
            lastPowerOff = .now
            next()
        }
    }

    /// Goes on once the display has been off for `carPlayReconnectionDelay`
    /// since a change last turned it off.
    private func afterCarPlayReconnectionDelay(in run: Run, then next: @escaping @MainActor () -> Void) {
        guard let lastPowerOff, lastPowerOff + carPlayReconnectionDelay > .now else { return next() }
        let deadline = lastPowerOff + carPlayReconnectionDelay
        Task { [weak self] in
            try? await Task.sleep(until: deadline)
            guard let self, self.inFlight === run else { return }
            next()
        }
    }

    /// Sends one step through `operation`, which throws when it sends nothing
    /// and otherwise calls its completion later, then calls `next` with
    /// whether the step succeeded. A failure joins the change's. A step whose
    /// completion does not come within `completionTimeout` abandons the change.
    private func perform(_ step: ExternalDisplayStep, in run: Run,
                         _ operation: (@escaping @MainActor (Error?) -> Void) throws -> Void,
                         then next: @escaping @MainActor (Bool) -> Void) {
        guard inFlight === run else { return }
        run.steps += 1
        let number = run.steps
        run.step = step
        let timeout = completionTimeout
        run.timer = Task { [weak self] in
            guard (try? await Task.sleep(for: timeout)) != nil else { return }
            self?.abandon(run, reason: "CoreSimulator did not complete it within \(timeout)", reporting: true)
        }
        // The completion keeps these changes until CoreSimulator calls it.
        let completion: @MainActor (Error?) -> Void = { error in
            guard self.inFlight === run, run.steps == number else {
                hostLog("An abandoned external display change completed\(error.map { " with an error: \($0.localizedDescription)" } ?? ".")")
                return
            }
            run.timer?.cancel()
            if let error { run.fail(step, error) }
            next(error == nil)
        }
        do { try operation(completion) } catch {
            run.timer?.cancel()
            run.fail(step, error)
            next(false)
        }
    }

    private func finish(_ run: Run) {
        guard inFlight === run else { return }
        run.timer?.cancel()
        inFlight = nil
        if !run.failures.isEmpty { run.change.report(run.failures) }
        sendWaiting()
    }

    private func abandon(_ run: Run, reason: String, reporting: Bool) {
        guard inFlight === run else { return }
        run.timer?.cancel()
        inFlight = nil
        hostLog("Stopped waiting for the external display change to \(run.change.mode.title): \(reason).")
        if reporting {
            run.fail(run.step, HostError.operation("CoreSimulator did not complete the change."))
            run.change.report(run.failures)
        }
        sendWaiting()
    }

    private func sendWaiting() {
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
