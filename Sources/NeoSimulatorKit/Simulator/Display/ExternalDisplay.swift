import AppKit
import NeoSimulatorDeviceIO

/// External display choices, using Simulator.app's persisted menu tags.
/// Fixed sizes use one point per pixel; CarPlay uses `CarPlayConfiguration`.
package enum ExternalDisplayMode: Int, CaseIterable {
    case disabled = 2114
    case size640x480 = 2214
    case size720x480 = 2514
    case size1024x768 = 2314
    case size1280x720 = 2414
    case size1920x1080 = 2614
    case size3840x2160 = 2664
    case carPlay = 2714

    /// The sizes, in the menu's order.
    package static let sizes: [ExternalDisplayMode] = [
        .size640x480, .size720x480, .size1024x768, .size1280x720, .size1920x1080, .size3840x2160,
    ]

    /// The title in Simulator.app's MainMenu.nib.
    package var title: String {
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
    package var pixelSize: CGSize? {
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
    package var scale: CGFloat { self == .carPlay ? CarPlayConfiguration.scale : 1 }
}

/// Simulator.app's default `StarkConfig`: 800×480 at scale 2, touch enabled, no wheel/back/home controls.
package enum CarPlayConfiguration {
    package static let pixelSize = CGSize(width: 800, height: 480)
    package static let scale: CGFloat = 2
    package static let hasTouchScreen = true

    /// The configuration as Simulator.app writes it to the device's
    /// `extended_display.plist`, under its plain keys.
    package static var file: [String: Any] {
        ["stark": true, "width": Int(pixelSize.width), "height": Int(pixelSize.height), "scale": Double(scale),
         "hasBackButton": false, "hasHomeButton": false, "hasWheel": false, "hasWheelBump": false,
         "hasTouchScreen": hasTouchScreen, "hasTouchScreenLofi": false, "protocols": [String]()]
    }

    /// What Simulator.app writes there for every other choice.
    package static var disabledFile: [String: Any] { ["stark": 0] }

    /// Writes the configuration in place, creating its parent directory.
    package static func save(carPlay: Bool, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: carPlay ? file : disabledFile, format: .xml, options: 0)
            .write(to: url)
    }
}

/// A device's external display, CoreSimulator's TVOut screen, as its
/// `SimScreenProperties` report it.
package struct ExternalScreenState: Equatable {
    /// `powerState` is 1. CoreSimulator turns the screen on when its mode is set.
    package var isPoweredOn: Bool
    /// `pixelSize`.
    package var pixelSize: CGSize
    /// `currentMode.preferredUIScale`, the screen's pixels per point.
    package var scale: CGFloat
    /// `carPlayProperties` is not nil: the screen is a CarPlay screen, as
    /// SimulatorKit's `SimDeviceScreen.isCarPlay` says of a TVOut screen.
    package var isCarPlay = false
    /// `currentMode.refreshRate` in hertz, which decides what the guest
    /// shows (see `ExternalScreenMode.guestSize(for:refreshRate:among:)`).
    package var refreshRate: Double = 60

    /// Derives the menu choice from actual screen state. Returns nil for unlisted sizes or scales.
    package var mode: ExternalDisplayMode? {
        guard isPoweredOn else { return .disabled }
        guard !isCarPlay else { return .carPlay }
        return ExternalDisplayMode.sizes.first { $0.pixelSize == pixelSize && $0.scale == scale }
    }
}

/// A mode that a screen advertises, `SimScreenMode`: the pixel sizes it
/// takes, by its `sizeRule`, at its `preferredUIScale` and `refreshRate`.
package struct ExternalScreenMode: Equatable {
    package enum Sizes: Equatable {
        /// Size rule 0: `exactSize`.
        case exact(CGSize)
        /// Size rule 1: from `minSize` through `maxSize` in each dimension.
        case range(minimum: CGSize, maximum: CGSize)
        /// Size rule 2: one of `allowedSizes`.
        case allowed([CGSize])
    }

    /// The sizes the mode takes, or nil for a size rule this host does not
    /// know. Simulator.app traps on such a rule; here the mode takes no size.
    package var sizes: Sizes?
    package var scale: CGFloat
    /// In hertz; CoreSimulator reports hundredths of a hertz.
    package var refreshRate: Double

    package func accepts(_ size: CGSize, scale: CGFloat) -> Bool {
        guard scale == self.scale, let sizes else { return false }
        switch sizes {
        case .exact(let exact): return exact == size
        case .range(let minimum, let maximum):
            return minimum.width <= size.width && minimum.height <= size.height
                && size.width <= maximum.width && size.height <= maximum.height
        case .allowed(let allowed): return allowed.contains(size)
        }
    }

    /// Guest CoreAnimation accepts 49–60.5 Hz for SpringBoard's external display selection
    /// (`ModeSet::preferred_mode_with_criteria_internal`, iOS 18.5, 26.0, and 26.5).
    package static let guestRefreshRates: ClosedRange<Double> = 49...60.5

    /// Predicts SpringBoard's mode: the highest width × height × whole-hertz value at an accepted rate.
    /// An unsupported rate or a size below the advertised 720×480 mode therefore yields 720×480,
    /// even though the host window retains the requested size.
    package static func guestSize(for size: CGSize, refreshRate: Double, among modes: [ExternalScreenMode]) -> CGSize {
        let exact = modes.compactMap { mode -> (size: CGSize, rate: Double)? in
            guard case .exact(let size) = mode.sizes else { return nil }
            return (size, mode.refreshRate)
        }
        func pixelRate(_ mode: (size: CGSize, rate: Double)) -> Double {
            mode.size.width * mode.size.height * mode.rate.rounded(.down)
        }
        // The display's own mode comes first and so wins a tie.
        var shown: (size: CGSize, rate: Double)?
        for mode in [(size, refreshRate)] + exact where guestRefreshRates.contains(mode.rate) {
            if shown.map({ pixelRate(mode) > pixelRate($0) }) ?? true { shown = mode }
        }
        return shown?.size ?? size
    }

    /// Which mode NeoSimulator sets for `size` at `scale`, with that size.
    package enum Choice: Equatable {
        case current
        case advertised(Int)
    }

    /// Chooses a mode at the requested size and scale with a refresh rate the guest accepts.
    /// TVOut may advertise only 120 Hz while accepting 60 Hz, so a compatible mode
    /// can supply the rate and format for the requested size. Rejects unsupported sizes
    /// and modes the guest would replace; see `guestSize(for:refreshRate:among:)`.
    package static func choice(for size: CGSize, scale: CGFloat, current: ExternalScreenState?,
                       among modes: [ExternalScreenMode]) throws(ExternalDisplayLimit) -> Choice {
        let keeps = { (rate: Double) in guestRefreshRates.contains(rate) }
        let takes = { (mode: ExternalScreenMode) in mode.accepts(size, scale: scale) }
        let choice: Choice
        let rate: Double
        if let current, current.pixelSize == size, current.scale == scale, keeps(current.refreshRate) {
            (choice, rate) = (.current, current.refreshRate)
        } else if let index = modes.firstIndex(where: { takes($0) && keeps($0.refreshRate) }) {
            (choice, rate) = (.advertised(index), modes[index].refreshRate)
        } else if modes.contains(where: takes),
                  let index = modes.firstIndex(where: { $0.scale == scale && keeps($0.refreshRate) }) {
            (choice, rate) = (.advertised(index), modes[index].refreshRate)
        } else if let index = modes.firstIndex(where: takes) {
            // Only at rates the guest drops: the check below reports what it shows instead.
            (choice, rate) = (.advertised(index), modes[index].refreshRate)
        } else {
            throw .noMode
        }
        let shown = guestSize(for: size, refreshRate: rate, among: modes)
        guard shown == size else { throw .showsInstead(shown) }
        return choice
    }
}

/// Why a device cannot show an External Displays item, which the item says
/// and a choice of it reports instead of changing the display.
package enum ExternalDisplayLimit: LocalizedError, Equatable {
    /// No mode of the device's external display takes the item's size at its scale.
    case noMode
    /// The guest shows its mode of this size instead (see
    /// `ExternalScreenMode.guestSize(for:refreshRate:among:)`).
    case showsInstead(CGSize)
    /// Pre-iPadOS 27 Stage Manager aborts when a 3840×2160 60 Hz display changes or turns off
    /// (`SBSystemShellExtendedDisplayControllerPolicy.m:199`; observed on 18.6, 26.0, and 26.5).
    case extendedDisplay

    package var errorDescription: String? {
        switch self {
        case .noMode: "The external display has no mode for this size."
        case .showsInstead(let size):
            "The device would show its own \(Self.name(size)) mode instead, which has more pixels at up to 60 Hz."
        case .extendedDisplay:
            "The device would make it an extended display, and its SpringBoard quits when such a display changes or turns off."
        }
    }

    /// What the item's subtitle says.
    package var menuSubtitle: String {
        switch self {
        case .noMode, .extendedDisplay: "Not available on this device"
        case .showsInstead(let size): "This device shows \(Self.name(size))"
        }
    }

    package static func name(_ size: CGSize) -> String { "\(Int(size.width))×\(Int(size.height))" }
}

private let externalDisplayKey = "SimulatorExternalDisplay"

extension PreferenceStore {
    /// Persisted SimulatorExternalDisplay tag, or nil if the device has no choice saved or what is saved is malformed.
    /// Unknown integer tags are preserved.
    package func externalDisplayTag(forDevice identifier: String) -> Int? {
        preferences(forDevice: identifier)?[externalDisplayKey] as? Int
    }

    /// Saves the device's External Displays choice, keeping its other
    /// preferences and the other devices'.
    package func setExternalDisplayTag(_ tag: Int, forDevice identifier: String) {
        updatePreferences(forDevice: identifier) { $0[externalDisplayKey] = tag }
    }
}

/// Independently failing steps of a display change, including CarPlay configuration and services.
package enum ExternalDisplayStep: Equatable {
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
package struct ExternalDisplayFailure {
    package let step: ExternalDisplayStep
    package let error: Error
}

/// Serializes external-display changes across a device's sessions; the latest pending choice wins.
/// Each change uses its originating session's screen connection. Power-off is idempotent
/// and always sent, because property reports can lag completion.
///
/// CarPlay configuration is written before mode changes. HID service removal precedes
/// session end; session start precedes HID service creation. Failures are collected,
/// but failed screen changes stop the operation and failed starts skip service creation.
///
/// Disconnection from a stopped device or `completionTimeout` abandons stalled work.
/// Late completions are ignored so later sessions can proceed.
@MainActor
package final class ExternalDisplayChanges {
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
        /// The boot that the waiting CarPlay request was decided for.
        var requestBoot: Date?

        init(_ change: Change) { self.change = change }

        func fail(_ step: ExternalDisplayStep, _ error: Error) {
            failures.append(ExternalDisplayFailure(step: step, error: error))
        }
    }

    /// Bounds completion waits beyond observed delays of up to 4.5 seconds across restarts.
    package static let defaultCompletionTimeout: Duration = .seconds(10)
    /// Allows the guest to process power-off before CarPlay reconnects.
    /// Without a delay, iOS 26.5 may retain the old display and never render CarPlay.
    package static let defaultCarPlayReconnectionDelay: Duration = .seconds(1)

    private let completionTimeout: Duration
    private let carPlayReconnectionDelay: Duration
    private var inFlight: Run?
    private var waiting: Change?
    /// What waits for no change to be in flight or waiting.
    private var idleWaits: [@MainActor () -> Void] = []
    /// The guest's CarPlay session that this host started in the device's
    /// current boot, and the HID service it created.
    private var carPlay = CarPlaySessionState()
    /// When a change last turned the display off.
    private var lastPowerOff: ContinuousClock.Instant?

    package init(completionTimeout: Duration = ExternalDisplayChanges.defaultCompletionTimeout,
         carPlayReconnectionDelay: Duration = ExternalDisplayChanges.defaultCarPlayReconnectionDelay) {
        self.completionTimeout = completionTimeout
        self.carPlayReconnectionDelay = carPlayReconnectionDelay
    }

    /// Whether a change is in flight or waiting.
    package var isBusy: Bool { inFlight != nil || waiting != nil }

    /// Queues the latest choice and reports its collected failures after completion.
    /// `savesCarPlayConfiguration` writes the guest configuration before changing its mode.
    package func apply(_ mode: ExternalDisplayMode, through screen: any SimulatorExternalScreen,
               savesCarPlayConfiguration: Bool, report: @escaping @MainActor ([ExternalDisplayFailure]) -> Void) {
        let change = Change(mode: mode, screen: screen, savesCarPlayConfiguration: savesCarPlayConfiguration,
                            report: report)
        if inFlight != nil { waiting = change } else { send(change) }
    }

    /// Drops pending and abandons in-flight changes owned by this screen connection.
    package func abandon(changesThrough screen: any SimulatorExternalScreen) {
        if waiting?.screen === screen { waiting = nil }
        if let inFlight, inFlight.change.screen === screen {
            abandon(inFlight, reason: "its device is no longer booted", reporting: false)
        }
        finishIfIdle()
    }

    /// Waits until no change is in flight or waiting, or until `deadline`.
    /// Returns whether the changes completed.
    package func idle(before deadline: ContinuousClock.Instant) async -> Bool {
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
            return perform(.screen, in: run, { try await screen.powerOff(completion: $0) }) { [self] turnedOff in
                guard turnedOff else { return finish(run) }
                lastPowerOff = .now
                endCarPlay(in: run) { [self] in finish(run) }
            }
        }
        let carPlay = change.mode == .carPlay
        let setMode: @MainActor () -> Void = { [self] in
            perform(.screen, in: run, {
                try await screen.setMode(pixelSize: size, scale: change.mode.scale, carPlay: carPlay, completion: $0)
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

    /// Removes this host's HID service before ending its CarPlay session.
    /// Failures are reported; a failed end preserves the session for the next choice.
    /// Boot-scoped requests cannot end a session in a newly restarted guest.
    private func endCarPlay(in run: Run, then next: @escaping @MainActor () -> Void) {
        let screen = run.change.screen
        let boot = screen.deviceBootDate
        guard carPlay.hasService(in: boot) || carPlay.session(in: boot) == .started else { return next() }
        run.requestBoot = boot
        perform(.carPlayService(creating: false), in: run, {
            try await screen.setCarPlayService(connected: false, completion: $0)
        }) { [self] removed in
            carPlay.serviceAnswered(created: false, succeeded: removed, in: boot)
            guard carPlay.session(in: boot) == .started else { return next() }
            sendCarPlaySession(starting: false, for: boot, in: run) { _ in next() }
        }
    }

    /// Starts CarPlay before creating the HID service. Reuses an existing session
    /// and sends no request when a previous timeout left its state unknown.
    private func startCarPlay(in run: Run, then next: @escaping @MainActor () -> Void) {
        let screen = run.change.screen
        let boot = screen.deviceBootDate
        let createService: @MainActor () -> Void = { [self] in
            guard screen.deviceBootDate == boot else { return next() }
            run.requestBoot = boot
            perform(.carPlayService(creating: true), in: run, {
                try await screen.setCarPlayService(connected: true, completion: $0)
            }) { [self] created in
                carPlay.serviceAnswered(created: true, succeeded: created, in: boot)
                next()
            }
        }
        guard carPlay.session(in: boot) == .none else { return createService() }
        sendCarPlaySession(starting: true, for: boot, in: run) { started in
            guard started else { return next() }
            createService()
        }
    }

    /// Serializes boot-scoped session requests. A timeout leaves the session unknown
    /// for that boot; a restart makes the pending request moot.
    private func sendCarPlaySession(starting: Bool, for boot: Date?, in run: Run,
                                    then next: @escaping @MainActor (Bool) -> Void) {
        let screen = run.change.screen
        guard screen.deviceBootDate == boot else { return next(false) }
        carPlay.willSend(in: boot)
        run.requestBoot = boot
        perform(.carPlaySession(starting: starting), in: run, {
            screen.setCarPlayEnabled(starting, inBoot: boot, completion: $0)
        }) { [self] succeeded in
            carPlay.sessionAnswered(starting: starting, succeeded: succeeded, in: boot)
            next(succeeded)
        }
    }

    /// Power-cycles an existing non-CarPlay display so the guest recognizes CarPlay.
    /// A failed power-off stops the change.
    private func turnOffForCarPlay(in run: Run, then next: @escaping @MainActor () -> Void) {
        // A state that cannot be read leaves the display as it is.
        guard let state = try? run.change.screen.state(), state.isPoweredOn, !state.isCarPlay else { return next() }
        perform(.screen, in: run, { try await run.change.screen.powerOff(completion: $0) }) { [self] turnedOff in
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

    /// Runs a step, collects failure, and passes success to `next`. A thrown error means no completion follows, and
    /// that nothing was sent unless it is an unknown outcome; a missing completion abandons the change.
    private func perform(_ step: ExternalDisplayStep, in run: Run,
                         _ operation: @escaping @MainActor (@escaping @MainActor (Error?) -> Void) async throws -> Void,
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
            // A request that a restart made moot is not a failure.
            if let error, !(error is CarPlayRequestMoot) {
                self.noteUnknownOutcome(of: step, in: run, error)
                run.fail(step, error)
            }
            next(error == nil)
        }
        // A step's request enters the device's queue before this returns, so steps keep their order.
        Task.immediate {
            do { try await operation(completion) } catch {
                guard self.inFlight === run, run.steps == number else {
                    hostLog("An abandoned external display change failed: \(error.localizedDescription)")
                    return
                }
                run.timer?.cancel()
                self.noteUnknownOutcome(of: step, in: run, error)
                run.fail(step, error)
                // The native call can still complete; that is no longer this step's answer.
                run.steps += 1
                next(false)
            }
        }
    }

    /// A request the device may have acted on leaves the CarPlay state as an unanswered one does.
    private func noteUnknownOutcome(of step: ExternalDisplayStep, in run: Run, _ error: any Error) {
        guard case .outcomeUnknown? = error as? DeviceOperationFailure else { return }
        switch step {
        case .carPlaySession: carPlay.timedOut(in: run.requestBoot)
        case .carPlayService: carPlay.serviceUnanswered(in: run.requestBoot)
        case .carPlayConfiguration, .screen: break
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
            if case .carPlaySession = run.step {
                // The session may or may not have changed; no request is
                // sent for it again in this boot.
                carPlay.timedOut(in: run.requestBoot)
                run.fail(run.step, SimulatorError.operation("""
                    The device did not answer, so NeoSimulator leaves its CarPlay session as it is until the \
                    device restarts.
                    """))
            } else {
                if case .carPlayService = run.step { carPlay.serviceUnanswered(in: run.requestBoot) }
                run.fail(run.step, SimulatorError.operation("CoreSimulator did not complete the change."))
            }
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

/// Tracks only this host's CarPlay session and HID service for one guest boot.
/// CoreSimulatorBridge counts starts and ends; an unmatched end prevents the next start.
/// State advances only on replies. Timeout makes it unknown until restart, preventing
/// further session requests. Replies from earlier boots or after timeout are ignored.
package struct CarPlaySessionState {
    package enum Session: Equatable {
        case none, started
        /// A start or an end was not answered in time.
        case unknown
    }

    /// `SimDevice.lastBootedAt` of the boot the state belongs to.
    private var boot: Date?
    private var session = Session.none
    /// Whether the HID service was created and not removed since.
    private var service = false

    package init() {}

    private init(boot: Date?) { self.boot = boot }

    /// The session in `boot`; none in a boot without a request.
    package func session(in boot: Date?) -> Session { boot == self.boot ? session : .none }

    package func hasService(in boot: Date?) -> Bool { boot == self.boot && service }

    /// Notes that a session request is sent in `boot`, which replaces the
    /// state of an earlier boot.
    package mutating func willSend(in boot: Date?) {
        if boot != self.boot { self = CarPlaySessionState(boot: boot) }
    }

    package mutating func sessionAnswered(starting: Bool, succeeded: Bool, in boot: Date?) {
        guard boot == self.boot, session != .unknown else { return }
        if succeeded { session = starting ? .started : .none }
    }

    package mutating func timedOut(in boot: Date?) {
        if boot == self.boot { session = .unknown }
    }

    /// Notes the answer to a creation or a removal of the HID service.
    package mutating func serviceAnswered(created: Bool, succeeded: Bool, in boot: Date?) {
        if boot == self.boot, succeeded { service = created }
    }

    /// Treats an unanswered HID change as potentially created so cleanup removes it.
    /// The guest safely ignores removal when no service exists.
    package mutating func serviceUnanswered(in boot: Date?) {
        if boot == self.boot { service = true }
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
