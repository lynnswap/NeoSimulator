import AppKit
@_spi(NeoSimulator) import XcodeSimulatorHost

/// A snapshot of a simulator in its Xcode device set.
public struct SimulatorDeviceSnapshot: Identifiable, Sendable {
    public let id: SimulatorDeviceIdentifier
    public let name: String
    public let runtimeName: String
    public let runtimeIdentifier: String
    public let modelName: String
    public let family: SimulatorDeviceFamily
    public let state: SimulatorDeviceState

    init(_ device: AvailableDevice) {
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
    case unknown = 0, iPhone = 1, iPad = 2, tv = 3, watch = 4, vision = 7
}

/// The current state reported by CoreSimulator.
public enum SimulatorDeviceState: UInt, Sendable {
    case unknown = 0, shutDown = 1, booting = 2, booted = 3, shuttingDown = 4
}

/// Whether booting was necessary.
public enum SimulatorBootOutcome: Sendable {
    case booted, alreadyRunning
}

/// Why a screen stopped presenting its device.
public enum SimulatorScreenEnd: Sendable {
    case closed, deviceStopped, hostConflict, contextInvalidated
}

/// Hardware buttons available on supported simulator models.
public enum SimulatorButton: Sendable {
    case home, lock, side, siri, volumeUp, volumeDown

    @MainActor var command: DeviceCommand.ID {
        switch self {
        case .home: .home
        case .lock: .lock
        case .side: .sideButton
        case .siri: .siri
        case .volumeUp: .increaseVolume
        case .volumeDown: .decreaseVolume
        }
    }

    var input: HardwareInput {
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

/// Owns simulator connections for one Xcode installation.
///
/// Keep the context alive while using its screens. Call `invalidate()` to finish
/// recordings and release input and display resources; this leaves guests running.
@MainActor
public final class SimulatorContext {
    private let engine: SimulatorScreenHost
    private var screens: [SimulatorDeviceIdentifier: SimulatorScreen] = [:]
    private var boots: [SimulatorDeviceIdentifier: Task<SimulatorBootOutcome, any Error>] = [:]
    private var invalidation: Task<Void, any Error>?
    private var isInvalidating = false
    private var endingScreens: Set<SimulatorDeviceIdentifier> = []

    /// Reports asynchronous connection failures, including a competing display host.
    public var onError: ((any Error) -> Void)?
    public var xcodeURL: URL { engine.runtime.xcodeURL }

    /// Selects the host's preferences before loading contexts. Device settings use the
    /// same store when `deviceSettings` is omitted.
    public static func configurePreferences(defaults: UserDefaults, deviceSettings: UserDefaults? = nil) {
        HostPreferences.configure(defaults: defaults, deviceSettingsDefaults: deviceSettings ?? defaults)
    }

    /// Chooses the process-wide SimulatorKit installation before the first context is loaded.
    public static func selectDisplayXcode(_ url: URL) throws {
        try CoreDeviceRuntime.configureUIFrameworks(xcodeURL: url)
    }

    /// Loads the selected Xcode's runtime, or the process's selected display Xcode when omitted.
    /// Loading does not boot devices or open windows.
    public static func load(xcodeURL: URL? = nil) async throws -> SimulatorContext {
        let displayURL = try await CoreDeviceRuntime.uiXcodeURL()
        let runtime = try await SimulatorRuntime.load(xcodeURL: xcodeURL ?? displayURL, uiXcodeURL: displayURL)
        try Task.checkCancellation()
        let engine = try SimulatorScreenHost(runtime: runtime, conflicts: HostConflictMonitor(), inProcess: true,
                                             offersLifetimeChoice: false)
        let context = SimulatorContext(engine: engine)
        try engine.start(attachingBootedDevices: false)
        return context
    }

    private init(engine: SimulatorScreenHost) {
        self.engine = engine
        engine.onChange = { [weak self] in self?.reconcileScreens() }
        engine.onClose = { [weak self] id, _, finishing in
            self?.finishScreen(id, reason: .closed)
            Task {
                do { try await finishing.value }
                catch { self?.report(error) }
            }
        }
        engine.onError = { [weak self] error in self?.report(error) }
        engine.onConflict = { [weak self] name, failure in
            guard let self else { return }
            Array(self.screens.keys).forEach { self.finishScreen($0, reason: .hostConflict) }
            let detail = failure.map { "\n\($0.localizedDescription)" } ?? ""
            self.report(SimulatorError.conflict("\(name) is now displaying the simulators.\(detail)"))
        }
        engine.onRestart = { [weak self] id, erasing in
            guard let self, let controller = self.engine.controller(for: id) else { return }
            self.engine.restartDevice(controller, erasing: erasing)
        }
        engine.onShutDown = { [weak self] id in
            Task {
                do { try await self?.shutDown(id) }
                catch { self?.report(error) }
            }
        }
    }

    /// Reads the devices currently available in this context.
    public func devices() async throws -> [SimulatorDeviceSnapshot] {
        try checkActive()
        return try engine.availableSimulatorDevices().map(SimulatorDeviceSnapshot.init)
    }

    /// Boots the guest and waits for CoreSimulator to report it running, without opening its screen.
    /// Concurrent callers for the same device share the boot operation.
    public func boot(_ id: SimulatorDeviceIdentifier) async throws -> SimulatorBootOutcome {
        try checkActive()
        if let task = boots[id] { return try await CoreDeviceRuntime.preparedValue(of: task) }
        let task = Task {
            defer { self.boots[id] = nil }
            let device = try self.device(id)
            if device.state == 3 { return SimulatorBootOutcome.alreadyRunning }
            if device.state != 2 {
                let tools = try DeviceTools(identifier: id.identifier, xcodeURL: self.xcodeURL, deviceSetPath: id.deviceSetPath)
                try await tools.boot()
            }
            let deadline = ContinuousClock.now + .seconds(120)
            while true {
                try Task.checkCancellation()
                let state = try self.device(id).state
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

    /// Attaches to an already running guest. Call `boot(_:)` first when necessary.
    /// Reopening an attached device returns the same screen.
    public func openScreen(_ id: SimulatorDeviceIdentifier) async throws -> SimulatorScreen {
        try checkActive()
        if let screen = screens[id] { return screen }
        let device = SimulatorDeviceSnapshot(try self.device(id))
        let controller = try await engine.openPresentation(for: id)
        try checkActive()
        if let screen = screens[id] { return screen }
        let screen = SimulatorScreen(device: device, controller: controller, context: self)
        screens[id] = screen
        return screen
    }

    /// Finishes this device's screen resources, then shuts down its guest.
    public func shutDown(_ id: SimulatorDeviceIdentifier) async throws {
        try checkActive()
        if let boot = boots[id] {
            boot.cancel()
            _ = await boot.result
        }
        endingScreens.insert(id)
        defer { endingScreens.remove(id) }
        try await engine.releasePresentation(for: id)
        finishScreen(id, reason: .deviceStopped)
        if try device(id).state != 1 {
            let tools = try DeviceTools(identifier: id.identifier, xcodeURL: xcodeURL, deviceSetPath: id.deviceSetPath)
            try await tools.shutdown()
        }
    }

    /// Releases every screen without shutting down guests.
    /// A failed call can be retried to finish resources that could not be released.
    public func invalidate() async throws {
        if let invalidation { try await invalidation.value; return }
        isInvalidating = true
        let task = Task {
            let pending = Array(self.boots.values)
            pending.forEach { $0.cancel() }
            for task in pending { _ = await task.result }
            Array(self.screens.keys).forEach { self.finishScreen($0, reason: .contextInvalidated) }
            try await self.engine.stop(keepingDevicesRunning: true)
        }
        invalidation = task
        defer { invalidation = nil }
        try await task.value
    }

    fileprivate func close(_ screen: SimulatorScreen) async throws {
        guard screens[screen.device.id] === screen else { return }
        let id = screen.device.id
        endingScreens.insert(id)
        defer { endingScreens.remove(id) }
        try await engine.releasePresentation(for: id)
        finishScreen(id, reason: .closed)
    }

    private func device(_ id: SimulatorDeviceIdentifier) throws -> AvailableDevice {
        guard let device = try engine.availableSimulatorDevices().first(where: { $0.identity == id }) else {
            throw SimulatorError.operation("The selected simulator is no longer available.")
        }
        return device
    }

    private func checkActive() throws {
        guard !isInvalidating, !engine.isStopped else {
            throw SimulatorError.operation("The simulator context has been invalidated.")
        }
    }

    private func reconcileScreens() {
        guard !engine.isStopped else { return }
        for id in screens.keys where !endingScreens.contains(id) && !engine.openedDeviceIdentifiers.contains(id) {
            finishScreen(id, reason: .deviceStopped)
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
        let engine = engine
        Task {
            do { try await engine.stop(keepingDevicesRunning: true) }
            catch { hostLog(error.localizedDescription) }
        }
    }
}

/// One connected simulator screen that can move between embedded and window presentations.
@MainActor
public final class SimulatorScreen {
    /// The device snapshot taken when this screen was opened.
    public let device: SimulatorDeviceSnapshot
    public private(set) var isClosed = false
    /// Called once after the screen ends. Closing a screen leaves its guest running.
    public var onEnd: ((SimulatorScreenEnd) -> Void)?
    private let controller: DeviceWindowController
    private weak var context: SimulatorContext?

    fileprivate init(device: SimulatorDeviceSnapshot, controller: DeviceWindowController, context: SimulatorContext) {
        self.device = device
        self.controller = controller
        self.context = context
    }

    /// Moves this screen into a view controller, replacing its previous presentation.
    /// One simulator screen can be embedded in each window.
    public func embed(in viewController: NSViewController) throws {
        try checkOpen()
        try controller.validatePresentationMove()
        controller.embed(in: viewController)
    }

    /// Moves this screen into its own window and brings it forward.
    public func showWindow() throws {
        try checkOpen()
        try controller.validatePresentationMove()
        controller.showCompactWindow()
    }

    /// Removes the current presentation while keeping the connection available.
    public func detach() throws {
        try checkOpen()
        try controller.validatePresentationMove()
        controller.detachPresentation()
    }

    public func focusInput() {
        guard !isClosed else { return }
        controller.focusInput()
    }

    /// Enqueues a hardware button press. Delivery errors arrive through `onFailure`.
    public func press(_ button: SimulatorButton, onFailure: @escaping @MainActor (any Error) -> Void) throws {
        try checkOpen()
        let command = DeviceCommand.command(button.command)
        guard command.isSupported(controller.session.capabilities), command.isEnabled(controller) else {
            throw SimulatorError.operation("This hardware button is unavailable for the simulator.")
        }
        controller.session.send(button.input, failure: onFailure)
    }

    /// Releases this screen's resources without shutting down the guest.
    public func close() async throws {
        try await context?.close(self)
    }

    fileprivate func finish(_ reason: SimulatorScreenEnd) {
        guard !isClosed else { return }
        isClosed = true
        onEnd?(reason)
    }

    private func checkOpen() throws {
        guard !isClosed, context != nil else {
            throw SimulatorError.operation("The simulator screen has been closed.")
        }
    }
}

/// An AppKit container that presents a simulator screen through its supported embedding path.
@MainActor
public final class SimulatorScreenViewController: NSViewController {
    public let screen: SimulatorScreen

    public init(screen: SimulatorScreen) throws {
        self.screen = screen
        super.init(nibName: nil, bundle: nil)
        try screen.embed(in: self)
    }

    public required init?(coder: NSCoder) { nil }

    public override func loadView() { view = NSView() }
}
