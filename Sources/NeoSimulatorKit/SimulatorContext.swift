import Foundation
import NeoSimulatorDeviceIO

/// A snapshot of a simulator in its Xcode device set.
public struct SimulatorDeviceSnapshot: Identifiable, Sendable {
    /// The identifier to pass to operations on this simulator.
    public let id: SimulatorDeviceIdentifier
    /// The simulator's name.
    public var name: String
    /// The display name of the simulator's runtime.
    public var runtimeName: String
    /// CoreSimulator's identifier for the simulator's runtime.
    public var runtimeIdentifier: String
    /// The name of the simulator's device type.
    public var modelName: String
    /// The simulator's product family.
    public var family: SimulatorDeviceFamily
    /// The simulator's state when this snapshot was read. Call ``SimulatorContext/devices()`` for a newer reading.
    public var state: SimulatorDeviceState

    package init(_ device: AvailableDevice) {
        id = device.identity
        name = device.name
        runtimeName = device.runtimeName
        runtimeIdentifier = device.runtimeIdentifier
        modelName = device.deviceTypeName
        family = SimulatorDeviceFamily(rawValue: device.productFamily) ?? .unknown
        state = SimulatorDeviceState(rawValue: device.state) ?? .unknown
    }
}

/// The simulator's product family.
public enum SimulatorDeviceFamily: Int, Sendable {
    /// A product family that this SDK does not recognize.
    case unknown = 0
    /// iPhone.
    case iPhone = 1
    /// iPad.
    case iPad = 2
    /// Apple TV.
    case tv = 3
    /// Apple Watch.
    case watch = 4
    /// Apple Vision Pro.
    case vision = 7
}

/// The current state reported by CoreSimulator.
public enum SimulatorDeviceState: UInt, Sendable {
    /// A state that this SDK does not recognize.
    case unknown = 0
    /// The guest is not running.
    case shutDown = 1
    /// The guest is starting.
    case booting = 2
    /// The guest is running.
    case booted = 3
    /// The guest is stopping.
    case shuttingDown = 4
}

/// Whether booting was necessary.
public enum SimulatorBootOutcome: Sendable {
    /// The guest was not running when the call began, and it is running now.
    case booted
    /// The guest was already running, so the call changed nothing.
    case alreadyRunning
}

/// Why a screen stopped presenting its device.
public enum SimulatorScreenEnd: Sendable {
    /// A caller or the screen's window closed it, or its display connection ended while the guest was not stopping.
    /// Closing a screen leaves its guest running.
    case closed
    /// The guest has begun shutting down, and its display has disconnected.
    case deviceStopping
    /// The guest has reached the shut-down state.
    case deviceStopped
    /// Another app began displaying simulators, which stopped the context. Its guests keep running.
    case hostConflict
    /// The context was invalidated or released. Its guests keep running.
    case contextInvalidated
}

/// Hardware buttons available on supported simulator models.
public enum SimulatorButton: Sendable {
    /// The Home button, which every simulator accepts.
    case home
    /// The lock button of iPhone, iPad, and Apple Watch simulators.
    case lock
    /// The side button of Apple Watch simulators.
    case side
    /// The Siri button, on simulators that support Siri.
    case siri
    /// The volume-up button, on simulators with routable audio.
    case volumeUp
    /// The volume-down button, on simulators with routable audio.
    case volumeDown

    /// Whether the device has this button.
    package func isSupported(by capabilities: DeviceCapabilities) -> Bool {
        switch self {
        case .home: true
        case .lock: capabilities.isPhoneOrPad || capabilities.family == .watch
        case .side: capabilities.family == .watch
        case .siri: capabilities.supportsFeature(DeviceCapabilities.siri)
        case .volumeUp, .volumeDown: capabilities.supportsFeature(DeviceCapabilities.routableAudio)
        }
    }

    package var input: HardwareInput {
        switch self {
        case .home: .press(.button(.home))
        case .lock: .press(.button(.lock))
        case .side: .press(.button(.side))
        case .siri: .press(.button(.siri))
        case .volumeUp: .press(.volumeUp)
        case .volumeDown: .press(.volumeDown)
        }
    }
}

@MainActor
package struct SimulatorContextConfiguration {
    package var pasteboardSync: PasteboardSync?
    package var offersLifetimeChoice = false
    package var onOpen: ((SimulatorDeviceIdentifier) -> Void)?
    package var onError: ((any Error) -> Void)?
    package var guestLifetime: ManagedGuestLifetime?
    package var onHostConflictBegan: ((SimulatorContext, String) -> Void)?
    package var onHostConflictEnded: ((SimulatorContext, (any Error)?) -> Void)?
    package var deviceRegistry: DeviceRegistry?

    package init() {}
}

@MainActor
package struct ManagedGuestLifetime {
    package let windowClosed: (SimulatorDeviceIdentifier, DeviceLifetimeChoice?, Task<Void, any Error>) -> Void
    package let restart: (SimulatorDeviceIdentifier, Bool) -> Void
    package let shutDown: (SimulatorDeviceIdentifier) -> Void

    package init(windowClosed: @escaping (SimulatorDeviceIdentifier, DeviceLifetimeChoice?, Task<Void, any Error>) -> Void,
                 restart: @escaping (SimulatorDeviceIdentifier, Bool) -> Void,
                 shutDown: @escaping (SimulatorDeviceIdentifier) -> Void) {
        self.windowClosed = windowClosed
        self.restart = restart
        self.shutDown = shutDown
    }
}

/// An open device's model, guest commands, and lifetime.
///
/// `SimulatorScreens` in NeoSimulatorUI opens and presents sessions. ``onEnd`` reports when
/// and why a session ends.
///
/// Guest commands throw ``SimulatorError/operation(_:)`` after the session ends or its context is released. While the
/// session is open but its display is disconnected or its guest is not running, the asynchronous commands return
/// without sending anything. A command whose request may still apply throws
/// ``SimulatorError/outcomeUnknown(_:underlying:)``; read the device's state before repeating it.
@MainActor
public final class SimulatorDeviceSession {
    /// The device snapshot taken when this session opened.
    public let device: SimulatorDeviceSnapshot
    /// Whether the session has ended. It becomes `true` before ``onEnd`` is called, and ``close()`` can throw after it does.
    public private(set) var isClosed = false
    /// Called once after the session ends. Closing a session leaves its guest running.
    ///
    /// A closure set after the session has ended is not called.
    public var onEnd: ((SimulatorScreenEnd) -> Void)?
    package let presentation: any DevicePresentation
    private weak var context: SimulatorContext?
    private var session: DeviceSession { presentation.session }

    fileprivate init(device: SimulatorDeviceSnapshot, presentation: any DevicePresentation, context: SimulatorContext) {
        self.device = device
        self.presentation = presentation
        self.context = context
    }

    /// Enqueues a hardware button press. Delivery errors arrive through `onFailure`.
    ///
    /// - Parameters:
    ///   - button: The button to press.
    ///   - onFailure: Receives the press's first delivery failure, which can arrive after this method returns.
    /// - Throws: ``SimulatorError/operation(_:)`` if the session has ended, the device does not have `button`, or the
    ///   device cannot accept commands now.
    public func press(_ button: SimulatorButton, onFailure: @escaping @MainActor (any Error) -> Void) throws {
        try checkOpen()
        guard button.isSupported(by: session.capabilities), session.canPerformCommands else {
            throw SimulatorError.operation("This hardware button is unavailable for the simulator.")
        }
        session.send(button.input, failure: onFailure)
    }

    /// The cached model shared with the context's device registry.
    /// Use ``DeviceModel/revalidate(_:)`` to refresh command state.
    public var deviceModel: DeviceModel { session.model }

    /// Native input readiness. SimulatorKit input remains active while native input prepares.
    ///
    /// This property is observable.
    public var inputReadiness: SimulatorServiceReadiness { session.optionalServices.input }
    /// Pasteboard readiness. Transfers wait for this service and report connection failures.
    ///
    /// This property is observable.
    public var pasteboardReadiness: SimulatorServiceReadiness { session.optionalServices.pasteboard }
    /// Connects the native input again after ``inputReadiness`` failed. In any other state, this does nothing.
    public func retryInput() { session.optionalServices.retryInput() }

    /// Flips the guest between its light and dark appearance.
    ///
    /// - Throws: ``SimulatorError`` if the session has ended or the change fails, or `CancellationError` if the caller
    ///   is cancelled.
    public func toggleAppearance() async throws {
        try checkOpen()
        try await mappingToSimulatorError { try await session.toggleAppearance() }
    }

    /// Changes the guest's preferred text size by `delta` steps.
    ///
    /// A change that would leave the guest's range of sizes does nothing, so a `delta` of 2 from the second-largest size
    /// leaves the size as it is.
    ///
    /// - Parameter delta: The number of steps. A positive value makes text larger, and a negative value makes it smaller.
    /// - Throws: ``SimulatorError`` if the session has ended, the device does not report its text size, or the change
    ///   fails, or `CancellationError` if the caller is cancelled.
    public func changeTextSize(by delta: Int) async throws {
        try checkOpen()
        try await mappingToSimulatorError { try await session.changeTextSize(by: delta) }
    }

    /// Flips the guest's Increase Contrast setting.
    ///
    /// - Throws: ``SimulatorError`` if the session has ended, the device does not report the setting, or the change
    ///   fails, or `CancellationError` if the caller is cancelled.
    public func toggleIncreaseContrast() async throws {
        try checkOpen()
        try await mappingToSimulatorError { try await session.toggleIncreaseContrast() }
    }

    /// Toggles the enrollment state shared by Touch ID, Face ID, and Optic ID, where supported.
    ///
    /// ``DeviceModel/isBiometricEnrolled`` reports the state that the device reads back.
    ///
    /// - Throws: ``SimulatorError`` if the session has ended or the change fails, or `CancellationError` if the caller
    ///   is cancelled.
    public func toggleBiometricEnrollment() async throws {
        try checkOpen()
        try await mappingToSimulatorError { try await session.toggleBiometricEnrollment() }
    }

    /// Flips a Core Animation debug option, and throws if the device does not report the new state.
    ///
    /// - Parameter option: The option to flip.
    /// - Throws: ``SimulatorError`` if the session has ended, the change fails, or the device reports the old state, or
    ///   `CancellationError` if the caller is cancelled.
    public func toggle(_ option: CADebugOption) async throws {
        try checkOpen()
        try await mappingToSimulatorError { try await session.toggle(option) }
    }

    /// Releases this session's resources without shutting down the guest.
    /// If cleanup fails after the session closes, this throws and `isClosed` remains true.
    /// Call again, or invalidate the context, to retry the unfinished cleanup.
    ///
    /// Calling this on a closed session with no unfinished cleanup does nothing. Concurrent close and shutdown calls
    /// join the same cleanup.
    ///
    /// - Throws: ``SimulatorError`` if cleanup fails, or `CancellationError` if the cleanup is cancelled.
    public func close() async throws {
        try await mappingToSimulatorError { try await context?.close(self) }
    }

    fileprivate func finish(_ reason: SimulatorScreenEnd) {
        guard !isClosed else { return }
        isClosed = true
        onEnd?(reason)
    }

    /// Throws once the session has ended or its context has gone.
    package func checkOpen() throws {
        guard !isClosed, context != nil else {
            throw SimulatorError.operation("The simulator screen has been closed.")
        }
    }
}

/// Owns simulator connections for one Xcode installation.
///
/// Keep the context alive while using its sessions; releasing it ends them with
/// ``SimulatorScreenEnd/contextInvalidated``. Call ``invalidate()`` to finish recordings and release input and display
/// resources; this leaves guests running.
///
/// While `SimulatorScreens` in NeoSimulatorUI presents the context's devices, an app that starts displaying simulators
/// stops the context and ends its sessions with ``SimulatorScreenEnd/hostConflict``. After a context stops, its
/// operations throw ``SimulatorError/operation(_:)``; load a new context to continue.
@MainActor
public final class SimulatorContext {
    private let engine: SimulatorScreenHost
    private let guestLifetime: ManagedGuestLifetime?
    private var screens: [SimulatorDeviceIdentifier: SimulatorDeviceSession] = [:]
    private var boots: [SimulatorDeviceIdentifier: Task<SimulatorBootOutcome, any Error>] = [:]
    private var invalidation: Task<Void, any Error>?
    private var isInvalidating = false
    private var isInstallingPresentation = false
    private var openings: [SimulatorDeviceIdentifier: Task<SimulatorDeviceSession, any Error>] = [:]
    private final class ReleaseIntent { var shutsDownGuest = false }
    private var releases: [SimulatorDeviceIdentifier: (intent: ReleaseIntent, task: Task<Void, any Error>)] = [:]

    /// Reports asynchronous connection failures, including a competing display host.
    ///
    /// Without a handler, these failures go to standard error.
    public var onError: ((any Error) -> Void)?
    /// The Xcode application that this context uses for CoreSimulator and its tools.
    public var xcodeURL: URL { engine.runtime.xcodeURL }

    /// Selects the host's preferences before loading contexts. Device settings use the
    /// same store when `deviceSettings` is omitted.
    ///
    /// The selection applies to the whole process.
    ///
    /// - Parameters:
    ///   - defaults: The store for host preferences, such as device bezels and touch indicators.
    ///   - deviceSettings: The store for saved per-device settings, such as audio routes and locations.
    public static func configurePreferences(defaults: UserDefaults, deviceSettings: UserDefaults? = nil) {
        HostPreferences.configure(defaults: defaults, deviceSettingsDefaults: deviceSettings ?? defaults)
    }

    /// Chooses the process-wide SimulatorKit installation before the first context is loaded.
    ///
    /// - Parameter url: The Xcode application that provides SimulatorKit.
    /// - Throws: An error if the process has already begun preparing its display Xcode. Restart the app to choose another.
    public static func selectDisplayXcode(_ url: URL) throws {
        try CoreDeviceRuntime.configureUIFrameworks(xcodeURL: url)
    }

    /// Loads `xcodeURL`, or the process's selected display Xcode when omitted.
    ///
    /// Loading neither boots devices nor loads a UI toolkit. Pass your application's registry
    /// to share device models with other views; otherwise the context creates its own.
    ///
    /// - Parameters:
    ///   - xcodeURL: The Xcode application to use. When `nil`, the context uses the installation chosen with
    ///     ``selectDisplayXcode(_:)`` or, without a selection, the one that `DEVELOPER_DIR` or `xcode-select` names.
    ///   - deviceRegistry: The registry whose models this context's sessions share.
    /// - Returns: A context that can read and boot devices.
    /// - Throws: An error if the Xcode is missing or older than Xcode 27 or its frameworks cannot load, or
    ///   `CancellationError` if the caller is cancelled.
    public static func load(xcodeURL: URL? = nil, deviceRegistry: DeviceRegistry? = nil) async throws -> SimulatorContext {
        var configuration = SimulatorContextConfiguration()
        configuration.deviceRegistry = deviceRegistry
        return try await load(xcodeURL: xcodeURL, configuration: configuration)
    }

    package static func load(xcodeURL: URL?, configuration: SimulatorContextConfiguration) async throws -> SimulatorContext {
        let runtime = if let xcodeURL { try await SimulatorIORuntime.load(xcodeURL: xcodeURL) }
            else { try await SimulatorIORuntime.load(xcodeURL: try await CoreDeviceRuntime.uiXcodeURL()) }
        try Task.checkCancellation()
        let engine = try SimulatorScreenHost(runtime: runtime, inProcess: true,
                                             pasteboardSync: configuration.pasteboardSync,
                                             offersLifetimeChoice: configuration.offersLifetimeChoice,
                                             deviceRegistry: configuration.deviceRegistry ?? DeviceRegistry())
        let context = SimulatorContext(engine: engine, configuration: configuration)
        try await engine.start(attachingBootedDevices: false)
        return context
    }

    private init(engine: SimulatorScreenHost, configuration: SimulatorContextConfiguration) {
        self.engine = engine
        guestLifetime = configuration.guestLifetime
        onError = configuration.onError
        engine.onOpen = configuration.onOpen
        engine.onChange = { [weak self] in self?.reconcileScreens() }
        engine.onClose = { [weak self] id, choice, finishing in
            guard let self else { return }
            if self.isInvalidating {
                self.finishScreen(id, reason: .contextInvalidated)
                self.guestLifetime?.windowClosed(id, choice, finishing)
                return
            }
            let task = self.beginRelease(id, shutsDownGuest: false, finishing: finishing)
            self.finishScreen(id, reason: .closed)
            if let guestLifetime = self.guestLifetime {
                guestLifetime.windowClosed(id, choice, task)
            } else {
                Task {
                    do { try await task.value }
                    catch { self.report(error) }
                }
            }
        }
        engine.onError = { [weak self] error in self?.report(error) }
        engine.onConflictBegan = { [weak self] name in
            guard let self else { return }
            configuration.onHostConflictBegan?(self, name)
        }
        engine.onConflict = { [weak self] name, failure in
            guard let self else { return }
            Array(self.screens.keys).forEach { self.finishScreen($0, reason: .hostConflict) }
            if let ended = configuration.onHostConflictEnded {
                ended(self, failure)
                return
            }
            let detail = failure.map { "\n\($0.localizedDescription)" } ?? ""
            self.report(SimulatorError.conflict("\(name) is now displaying the simulators.\(detail)"))
        }
        engine.onRestart = { [weak self] id, erasing in
            guard let self else { return }
            if let guestLifetime = self.guestLifetime {
                guestLifetime.restart(id, erasing)
                return
            }
            guard let controller = self.engine.presentation(for: id) else { return }
            self.engine.restartDevice(controller, erasing: erasing)
        }
        engine.onShutDown = { [weak self] id in
            guard let self else { return }
            if let guestLifetime = self.guestLifetime {
                guestLifetime.shutDown(id)
                return
            }
            Task {
                do { try await self.shutDown(id) }
                catch { self.report(error) }
            }
        }
    }

    /// Gives this context what presents its devices, which `conflicts` can stop.
    package func install(presenter: any DevicePresenter, conflicts: any HostConflictChecking) throws {
        try engine.install(presenter: presenter, conflicts: conflicts)
    }

    /// Runs `load`, what the presenter needs before it can connect anything, and gives this context the presenter. A
    /// context takes one, and a second attempt while the first is loading fails without loading anything.
    package func installPresentation(load: @escaping @MainActor () async throws -> Void, presenter: any DevicePresenter,
                                     conflicts: any HostConflictChecking) async throws {
        try checkActive()
        guard engine.presenter == nil, !isInstallingPresentation else {
            throw SimulatorError.operation("This simulator context already has its screens.")
        }
        isInstallingPresentation = true
        defer { isInstallingPresentation = false }
        try conflicts.check()
        try await load()
        try checkActive()
        try engine.install(presenter: presenter, conflicts: conflicts)
    }

    package func checkForHostConflict() { engine.handleHostConflict() }

    package var isStopped: Bool { isInvalidating || engine.isStopped || engine.isTerminating }
    package var openSessions: [SimulatorDeviceSession] { Array(screens.values) }

    package func session(for id: SimulatorDeviceIdentifier) -> SimulatorDeviceSession? { screens[id] }

    package func releaseSession(_ id: SimulatorDeviceIdentifier) async throws {
        try await beginRelease(id, shutsDownGuest: false).value
    }

    package func prepareForManagedRestart(_ id: SimulatorDeviceIdentifier) async throws {
        guard !isStopped else { throw CancellationError() }
        while let release = releases[id] {
            try await CoreDeviceRuntime.preparedValue(of: release.task)
            guard !isStopped else { throw CancellationError() }
        }
        try await engine.preparePresentationForRestart(for: id)
    }

    package func finishManagedRestart(_ id: SimulatorDeviceIdentifier) async throws {
        guard !isStopped else { throw CancellationError() }
        while let release = releases[id] {
            try await CoreDeviceRuntime.preparedValue(of: release.task)
            guard !isStopped else { throw CancellationError() }
        }
        try await engine.finishPresentationRestart(for: id)
    }

    /// Reads the devices currently available in this context.
    ///
    /// The list contains simulators of supported product families from Xcode's default device set and, by default, its
    /// parallel testing device set, whose simulators have a ``SimulatorDeviceIdentifier/deviceSetPath``.
    ///
    /// - Returns: A snapshot of each simulator.
    /// - Throws: ``SimulatorError`` if the context has stopped or the read fails, or `CancellationError` if the caller
    ///   is cancelled.
    public func devices() async throws -> [SimulatorDeviceSnapshot] {
        try checkActive()
        return try await mappingToSimulatorError { try await engine.readAvailableDevices().map(SimulatorDeviceSnapshot.init) }
    }

    /// Boots the guest and waits for CoreSimulator to report it running, without opening its screen.
    /// Concurrent callers for the same device share the boot operation, and cancelling one caller ends only its wait.
    ///
    /// A close or shutdown of the device that is in progress finishes first.
    ///
    /// - Parameter id: The simulator to boot.
    /// - Returns: Whether booting was necessary.
    /// - Throws: ``SimulatorError`` if the context has stopped, the simulator is no longer available, it does not finish
    ///   starting in time, or the boot fails, or `CancellationError` if the caller is cancelled.
    public func boot(_ id: SimulatorDeviceIdentifier) async throws -> SimulatorBootOutcome {
        try await mappingToSimulatorError { try await bootDevice(id) }
    }

    private func bootDevice(_ id: SimulatorDeviceIdentifier) async throws -> SimulatorBootOutcome {
        try checkActive()
        while let release = releases[id] {
            try await CoreDeviceRuntime.preparedValue(of: release.task)
            try checkActive()
        }
        try Task.checkCancellation()
        if let task = boots[id] { return try await CoreDeviceRuntime.preparedValue(of: task) }
        let task = Task {
            defer { self.boots[id] = nil }
            let device = try await self.device(id)
            if device.state == 3 { return SimulatorBootOutcome.alreadyRunning }
            if device.state != 2 {
                let tools = try DeviceTools(identifier: id.identifier, xcodeURL: self.xcodeURL, deviceSetPath: id.deviceSetPath)
                try await tools.boot()
            }
            let deadline = ContinuousClock.now + .seconds(120)
            while true {
                try Task.checkCancellation()
                let state = try await self.device(id).state
                if state == 3 { return SimulatorBootOutcome.booted }
                guard state == 2, ContinuousClock.now < deadline else {
                    throw SimulatorError.operation("The simulator did not finish starting.")
                }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        boots[id] = task
        return try await CoreDeviceRuntime.preparedValue(of: task)
    }

    /// Attaches to an already running guest through the installed presenter. `boot(_:)` it first when necessary.
    /// Reopening an attached device returns the same session. Concurrent callers share
    /// the connection; canceling one caller only cancels that caller's wait.
    package func openSession(_ id: SimulatorDeviceIdentifier) async throws -> SimulatorDeviceSession {
        try checkActive()
        while let release = releases[id] {
            try await CoreDeviceRuntime.preparedValue(of: release.task)
            try checkActive()
        }
        try Task.checkCancellation()
        if let opening = openings[id] {
            engine.didSelectDevice(id)
            return try await waitForScreen(opening)
        }
        let task = Task {
            defer { self.openings[id] = nil }
            if self.engine.hasUnfinishedCleanup(for: id) { try await self.engine.releasePresentation(for: id) }
            let device = SimulatorDeviceSnapshot(try await self.device(id))
            let presentation = try await self.engine.openPresentation(for: id)
            try self.checkActive()
            if let screen = self.screens[id] { return screen }
            let screen = SimulatorDeviceSession(device: device, presentation: presentation, context: self)
            self.screens[id] = screen
            return screen
        }
        openings[id] = task
        return try await waitForScreen(task)
    }

    private func waitForScreen(_ opening: Task<SimulatorDeviceSession, any Error>) async throws -> SimulatorDeviceSession {
        do { return try await CoreDeviceRuntime.preparedValue(of: opening) }
        catch is CancellationError where !Task.isCancelled {
            try checkActive()
            throw SimulatorError.operation("The simulator screen was closed before it finished opening.")
        }
    }

    /// Finishes this device's screen resources, then shuts down its guest.
    /// Concurrent close and shutdown calls join the same cleanup operation.
    ///
    /// An open session ends with ``SimulatorScreenEnd/deviceStopped`` after a successful shutdown, or
    /// ``SimulatorScreenEnd/closed`` if cleanup or shutdown fails. Once the operation has begun, cancelling the caller
    /// does not stop it, and this method waits for it to finish.
    ///
    /// - Parameter id: The simulator to shut down.
    /// - Throws: ``SimulatorError`` if the context has stopped, the simulator is no longer available, it does not finish
    ///   shutting down in time, or the cleanup or shutdown fails, or `CancellationError` if the caller was already cancelled.
    public func shutDown(_ id: SimulatorDeviceIdentifier) async throws {
        try checkActive()
        try Task.checkCancellation()
        try await mappingToSimulatorError { try await beginRelease(id, shutsDownGuest: true).value }
    }

    private func beginRelease(_ id: SimulatorDeviceIdentifier, shutsDownGuest: Bool,
                              finishing: Task<Void, any Error>? = nil) -> Task<Void, any Error> {
        if let release = releases[id] {
            if shutsDownGuest { release.intent.shutsDownGuest = true }
            return release.task
        }
        let intent = ReleaseIntent()
        intent.shutsDownGuest = shutsDownGuest
        let task = Task {
            defer {
                if self.releases[id]?.intent === intent { self.releases[id] = nil }
            }
            do {
                if let opening = self.openings[id] { opening.cancel(); _ = await opening.result }
                if let boot = self.boots[id] { boot.cancel(); _ = await boot.result }
                try await finishing?.value
                try await self.engine.releasePresentation(for: id)
                let reason: SimulatorScreenEnd
                if intent.shutsDownGuest {
                    await self.engine.cancelRestart(for: id)
                    let state = try await self.device(id).state
                    if state != 1 && state != 4 {
                        let tools = try DeviceTools(identifier: id.identifier, xcodeURL: self.xcodeURL,
                                                    deviceSetPath: id.deviceSetPath)
                        try await tools.shutdown()
                    }
                    let deadline = ContinuousClock.now + .seconds(120)
                    while try await self.device(id).state != 1 {
                        guard ContinuousClock.now < deadline else {
                            throw SimulatorError.operation("The simulator did not finish shutting down.")
                        }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    reason = .deviceStopped
                } else {
                    reason = .closed
                }
                // Callbacks may start the next operation for this device.
                self.releases[id] = nil
                self.finishScreen(id, reason: reason)
            } catch {
                if !self.engine.openedDeviceIdentifiers.contains(id) {
                    self.releases[id] = nil
                    self.finishScreen(id, reason: .closed)
                }
                throw error
            }
        }
        releases[id] = (intent, task)
        return task
    }

    /// Releases all screens without shutting down guests. Retry to finish incomplete cleanup.
    ///
    /// Recording and capture work may outlast the wait; the error identifies its files.
    /// ``onError`` reports late failures, and the next call joins unfinished work.
    /// Failed capture saves are not retried automatically. Each call reports them until the
    /// file is moved from the reported location or ``acknowledgeCaptureFailures()`` is called.
    ///
    /// Open sessions end with ``SimulatorScreenEnd/contextInvalidated``, and the context's other operations throw from
    /// the time this is first called.
    ///
    /// - Throws: ``SimulatorError/operation(_:)`` describing each unfinished cleanup or unsaved capture, or
    ///   `CancellationError` if the cleanup is cancelled.
    public func invalidate() async throws {
        try await mappingToSimulatorError { try await invalidateResources() }
    }

    private func invalidateResources() async throws {
        if let invalidation { try await invalidation.value; return }
        isInvalidating = true
        let task = Task {
            let pendingBoots = Array(self.boots.values)
            let pendingOpens = Array(self.openings.values)
            pendingBoots.forEach { $0.cancel() }
            pendingOpens.forEach { $0.cancel() }
            for task in pendingBoots { _ = await task.result }
            for task in pendingOpens { _ = await task.result }
            var failures: [String] = []
            for release in Array(self.releases.values) {
                do { try await release.task.value } catch { failures.append(error.localizedDescription) }
            }
            Array(self.screens.keys).forEach { self.finishScreen($0, reason: .contextInvalidated) }
            do { try await self.engine.stop(keepingDevicesRunning: true) }
            catch { failures.append(error.localizedDescription) }
            if !failures.isEmpty { throw SimulatorError.operation(failures.joined(separator: "\n")) }
        }
        invalidation = task
        defer { invalidation = nil }
        try await task.value
    }

    /// Acknowledges capture failures already reported to the user, so another ``invalidate()`` does not repeat them.
    /// This leaves the files at the locations in the errors. Work still in progress can report a later failure.
    public func acknowledgeCaptureFailures() { engine.acknowledgeCaptureFailures() }

    fileprivate func close(_ screen: SimulatorDeviceSession) async throws {
        if let invalidation { try await invalidation.value; return }
        let id = screen.device.id
        if let release = releases[id] { try await release.task.value; return }
        guard screens[id] === screen else {
            if openings[id] == nil, engine.hasUnfinishedCleanup(for: id) {
                try await beginRelease(id, shutsDownGuest: false).value
            }
            return
        }
        try await beginRelease(id, shutsDownGuest: false).value
    }

    private func device(_ id: SimulatorDeviceIdentifier) async throws -> AvailableDevice {
        guard let device = try await engine.readAvailableDevices().first(where: { $0.identity == id }) else {
            throw SimulatorError.operation("The selected simulator is no longer available.")
        }
        return device
    }

    private func checkActive() throws {
        guard !isStopped else {
            throw SimulatorError.operation("The simulator context has been invalidated.")
        }
    }

    private func reconcileScreens() {
        guard !engine.isStopped, !engine.isTerminating else { return }
        let opened = engine.openedDeviceIdentifiers
        let ended = screens.keys.filter { releases[$0] == nil && !opened.contains($0) }
        guard !ended.isEmpty else { return }
        let devices = engine.availableSimulatorDevices()
        for id in ended {
            let state = devices.first { $0.identity == id }?.state
            let reason: SimulatorScreenEnd = switch state {
            case 1: .deviceStopped
            case 4: .deviceStopping
            default: .closed
            }
            finishScreen(id, reason: reason)
        }
    }

    private func finishScreen(_ id: SimulatorDeviceIdentifier, reason: SimulatorScreenEnd) {
        screens.removeValue(forKey: id)?.finish(reason)
    }

    private func report(_ error: any Error) {
        if let onError { onError(error) } else { hostLog(error.localizedDescription) }
    }

    isolated deinit {
        Array(screens.values).forEach { $0.finish(.contextInvalidated) }
        boots.values.forEach { $0.cancel() }
        openings.values.forEach { $0.cancel() }
        let engine = engine
        Task {
            do { try await engine.stop(keepingDevicesRunning: true) }
            catch { hostLog(error.localizedDescription) }
        }
    }
}
