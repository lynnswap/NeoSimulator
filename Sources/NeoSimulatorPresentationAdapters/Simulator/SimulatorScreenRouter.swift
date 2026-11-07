import AppKit
import NeoSimulatorDeviceIO
import NeoSimulatorKit
import NeoSimulatorNative

/// Selects native input by device capability. Connection failures preserve the selected route.
package enum NativeInputPlan: Equatable, Sendable {
    /// DeviceKit's own view takes the screen's input. A device that needs it has no other screen.
    case canvas
    /// The Mach services that the device itself looks up, for a device in any set.
    case guest(touchscreenGestures: Bool)
    /// CoreDevice's services, which list only the default device set.
    case coreDevice(keyboard: Bool, trackpad: Bool, touches: Bool)
    case simulatorKit

    package static let duoDeviceType = "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo"

    package init(capabilities: DeviceCapabilities, deviceTypeIdentifier: String, isInDefaultSet: Bool) {
        let isDuo = deviceTypeIdentifier == Self.duoDeviceType
        let hasKeyboard = capabilities.supportsFeature(DeviceCapabilities.keyboard)
        // A crown or dial takes the pointer's scrolling, and a device UI plugin's overlay takes the
        // screen's input, through SimulatorKit.
        let takesTrackpad = !capabilities.hasCrownOrDial && !capabilities.hasUserInterfacePlugin
        // Once native keyboard or trackpad input starts, the guest drops SimulatorKit's touches and
        // buttons, so they go to the native touchscreen and buttons too. The native touchscreen has
        // no pressure, so a screen with touch pressure keeps SimulatorKit's touches.
        let hasPressure = capabilities.supportsFeature(DeviceCapabilities.touchPressure)
        let takesTouches = capabilities.isPhoneOrPad && !hasPressure
        if isDuo, isInDefaultSet {
            self = .canvas
        } else if !isDuo, hasKeyboard, takesTrackpad, takesTouches {
            // CoreDevice may omit a default-set simulator too. Reach the guest that owns the screen.
            // Older iPhone UIKit does not consistently deliver indirect scroll/pinch reports.
            self = .guest(touchscreenGestures: capabilities.family == .iPhone && capabilities.runtimeVersion < 0x1B_00_00)
        } else if !isInDefaultSet {
            self = .simulatorKit
        } else if capabilities.isPhoneOrPad, hasPressure {
            // Native keyboard or trackpad input would make the guest drop SimulatorKit's touches, which
            // keep their pressure, and its buttons. The screen therefore keeps SimulatorKit's keyboard,
            // which the guest reads with a US layout, and its digitizer, which drops trackpad scrolling
            // and pinches.
            self = .simulatorKit
        } else if hasKeyboard || takesTrackpad {
            self = .coreDevice(keyboard: hasKeyboard, trackpad: takesTrackpad, touches: takesTouches)
        } else {
            self = .simulatorKit
        }
    }
}

/// The native route of an integrated screen's touches and buttons: the device's services, and the SimulatorKit members
/// that take the screen's digitizer touches for them.
package struct NativeTouchRoute {
    package let input: NativeDeviceScreenInput
    package let interface: SimulatorTouchInterface

    package init(input: NativeDeviceScreenInput, interface: SimulatorTouchInterface) {
        self.input = input
        self.interface = interface
    }
}

/// Connected input services. Until a display adopts them, the caller must stop them.
/// Connecting alone sends nothing to the guest.
package struct NativeInputServices {
    package var keyboard: NativeDeviceKeyboard?
    package var trackpad: NativeDeviceTrackpad?
    package var touchRoute: NativeTouchRoute?

    package init(keyboard: NativeDeviceKeyboard? = nil, trackpad: NativeDeviceTrackpad? = nil, touchRoute: NativeTouchRoute? = nil) {
        self.keyboard = keyboard
        self.trackpad = trackpad
        self.touchRoute = touchRoute
    }

    /// Stops each service whatever the others do. What could not be stopped is retried by the next call.
    package func stop() async throws {
        var failures: [String] = []
        do { try await keyboard?.stop() } catch { failures.append(error.localizedDescription) }
        do { try await trackpad?.stop() } catch { failures.append(error.localizedDescription) }
        do { try await touchRoute?.input.stop() } catch { failures.append(error.localizedDescription) }
        if !failures.isEmpty { throw RemoteScreenError.io("native-input-removal", failures.joined(separator: "\n")) }
    }
}

/// Connects native input after display opening and hands it over in place.
/// Nil means unsupported; failures retain SimulatorKit input and allow retry.
/// An overdue channel call fails the attempt and blocks retry until it returns, then
/// triggers one new attempt.
@MainActor
package final class NativeInputActivation {
    private let services: DeviceOptionalServices
    private let connect: @MainActor () async throws -> NativeInputServices?
    private let activate: @MainActor (NativeInputServices) async throws -> Void
    private let healthChanges: (@MainActor () -> AsyncStream<DeviceChannelHealth>)?
    private var running: Task<Void, Never>?
    private var recovery: Task<Void, Never>?
    private var isCancelled = false
    /// What connected but no display took up and could not be stopped, which `stopUnactivated()` retries.
    private var unstopped: [NativeInputServices] = []

    /// `healthChanges` is the channel of a route that `connect` reaches through one.
    package init(services: DeviceOptionalServices, connect: @escaping @MainActor () async throws -> NativeInputServices?,
                 activate: @escaping @MainActor (NativeInputServices) async throws -> Void,
                 healthChanges: (@MainActor () -> AsyncStream<DeviceChannelHealth>)? = nil) {
        self.services = services
        self.connect = connect
        self.activate = activate
        self.healthChanges = healthChanges
        services.onRetryInput = { [weak self] in self?.start() }
        services.setInput(.pending)
    }

    /// Connects unless a connection is running or has finished, or the display has ended. A failed one can start again.
    package func start() {
        guard running == nil, !isCancelled else { return }
        recovery?.cancel()
        recovery = nil
        services.setInput(.pending)
        let (connect, activate, services) = (connect, activate, services)
        running = Task { [weak self] in
            var connected: NativeInputServices?
            do {
                connected = try await connect()
                guard let connected else {
                    services.setInput(.unsupported)
                    return
                }
                try Task.checkCancellation()
                try await activate(connected)
                services.setInput(.ready)
            } catch {
                // Nothing else owns what connected but no display took up, however late it arrived.
                if let connected {
                    do { try await connected.stop() } catch {
                        hostLog("Could not stop the native input that no display took up: \(error.localizedDescription)")
                        self?.unstopped.append(connected)
                    }
                }
                guard !error.isCancellation else { return }
                services.setInput(.failed(error))
                self?.running = nil
                self?.startWhenAnsweringAgain(after: error)
            }
        }
    }

    /// Ends what waits, and starts nothing more: what answers later is stopped rather than activated.
    package func cancel() {
        isCancelled = true
        running?.cancel()
        recovery?.cancel()
        recovery = nil
    }

    /// Whether a connection that was cancelled has returned by `deadline`, having stopped what it connected. A native call
    /// that ignores its cancellation holds nothing of the display's, and what it answers with is stopped when it does.
    package func ends(before deadline: ContinuousClock.Instant) async -> Bool {
        guard let running else { return true }
        return await running.ends(before: deadline)
    }

    /// Stops what an earlier attempt could not, and throws what still could not be stopped.
    package func stopUnactivated() async throws {
        let stopping = unstopped
        unstopped = []
        var failures: [String] = []
        for connected in stopping {
            do { try await connected.stop() } catch {
                unstopped.append(connected)
                failures.append(error.localizedDescription)
            }
        }
        if !failures.isEmpty { throw RemoteScreenError.io("native-input-removal", failures.joined(separator: "\n")) }
    }

    private func startWhenAnsweringAgain(after error: any Error) {
        guard error is DeviceOperationFailure, let healthChanges else { return }
        let changes = healthChanges()
        recovery = Task { [weak self] in
            for await health in changes where health == .ready {
                self?.start()
                return
            }
        }
    }
}

/// The device's native keyboard, which each of its displays shares and takes up once it is ready.
@MainActor
package final class SharedNativeKeyboard {
    private struct Display { weak var connection: SimulatorConnection? }
    package private(set) var keyboard: NativeDeviceKeyboard?
    private var displays: [Display] = []

    package init() {}

    var hasPressedSimulatorKeys: Bool { displays.contains { $0.connection?.hasPressedSimulatorKeys == true } }

    /// A display that joins after the keyboard became ready takes it up now.
    func add(_ connection: SimulatorConnection) {
        displays = displays.filter { $0.connection != nil } + [Display(connection: connection)]
        if let keyboard { connection.keyboardActivated(keyboard) }
    }

    func activate(_ keyboard: NativeDeviceKeyboard) {
        self.keyboard = keyboard
        for display in displays { display.connection?.keyboardActivated(keyboard) }
    }
}

/// Selects CoreDevice pasteboard for supported default-set devices, otherwise SimPasteboardPlus.
/// Transfers wait for CoreDevice capability discovery. Failure preserves the route;
/// the next transfer retries discovery.
@MainActor
package final class SimulatorPasteboardRoute {
    private let services: DeviceOptionalServices
    private let make: (@MainActor () async throws -> (any PasteboardTransport)?)?
    private var resolved: (any PasteboardTransport)?
    private var isResolved = false

    /// With no `make`, nothing but SimPasteboardPlus is routed. `make` returning nil says the device has no routed transport.
    package init(services: DeviceOptionalServices, make: (@MainActor () async throws -> (any PasteboardTransport)?)?) {
        self.services = services
        self.make = make
        isResolved = make == nil
        if make != nil { services.setPasteboard(.pending) }
    }

    /// The routed transport, or nil for SimPasteboardPlus.
    package func transport() async throws -> (any PasteboardTransport)? {
        if isResolved { return resolved }
        guard let make else { return nil }
        services.setPasteboard(.pending)
        do {
            resolved = try await make()
            isResolved = true
            services.setPasteboard(resolved == nil ? .unsupported : .ready)
            return resolved
        } catch where error.isCancellation {
            throw error
        } catch {
            services.setPasteboard(.failed(error))
            throw error
        }
    }
}

/// Connects a display and its capability-selected transports.
/// Optional services connect separately so they cannot delay or fail display opening.
@MainActor
package final class SimulatorScreenRouter {
    private let displays: SimulatorDisplaySet

    package init(displays: SimulatorDisplaySet) { self.displays = displays }

    package func connect(_ request: DeviceConnectionRequest) async throws -> ConnectedDeviceDisplay {
        let device = request.device
        let runtime = try await SimulatorPresentationRuntime.load(io: request.runtime, uiXcodeURL: try await CoreDeviceRuntime.uiXcodeURL())
        try await runtime.display.screenAdapter.prepare(for: device.handle.object)
        // CoreSimulator reports Booted before its integrated screen is ready.
        var screenFailure: (any Error)?
        for _ in 0..<40 {
            try request.checkWanted()
            let defaultScreen: (identifier: UInt32, object: AnyObject)?
            do {
                defaultScreen = try runtime.display.defaultScreen(of: device)
                screenFailure = nil
            } catch {
                defaultScreen = nil
                screenFailure = error
            }
            if let defaultScreen { return try await connect(device, screen: defaultScreen, runtime: runtime) }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw await IntegratedScreenUnavailable(deviceName: device.name, lastFailure: screenFailure)
    }

    private func connect(_ device: SimulatorDevice, screen: (identifier: UInt32, object: AnyObject),
                         runtime: SimulatorPresentationRuntime) async throws -> ConnectedDeviceDisplay {
        let features = try await device.supportedFeatures(DeviceCapabilities.allFeatures)
        var capabilities = Self.capabilities(of: device, features: features)
        let plan = NativeInputPlan(capabilities: capabilities, deviceTypeIdentifier: device.deviceTypeIdentifier,
                                   isInDefaultSet: device.deviceSetPath == nil)
        // What this connection routes by CoreDevice's word about the device asks here. It ends with the connection.
        let record = CoreDeviceSimulatorRecord(simulatorUDID: device.identifier)
        // DeviceKit's view is the screen of a device that needs it, so opening waits for its record and fails without it.
        let nativeCanvas = plan == .canvas ? try await NativeDeviceCanvas.connect(record: record,
            pointsPerInch: device.screenPointsPerInch.map { CGFloat($0) }, lookUp: device.lookUp) : nil
        try Task.checkCancellation()
        let services = DeviceOptionalServices()
        record.onAwaitingChange = { [weak services] in services?.setAwaitingDeviceRecord($0) }
        // CoreDevice lists only the default set, so any other set has nothing to route.
        var makePasteboard: (@MainActor () async throws -> (any PasteboardTransport)?)?
        if device.deviceSetPath == nil {
            makePasteboard = {
                guard case .supported(let remote) = try await record.answer(for: [CoreDevicePasteboardTransport.feature]) else { return nil }
                return try await CoreDevicePasteboardTransport.make(remote: remote)
            }
        }
        let pasteboardRoute = SimulatorPasteboardRoute(services: services, make: makePasteboard)
        let connection = try await SimulatorConnection(device: device, screen: screen, runtime: runtime, displays: displays,
                                                       pasteboardRoute: pasteboardRoute, nativeCanvas: nativeCanvas,
                                                       deviceRecord: record)
        if nativeCanvas != nil { capabilities.controlsOrientation = false }
        let start: @MainActor () -> Void = { [weak connection] in
            guard let connection else { return }
            Self.startInput(on: connection, of: device, plan: plan, record: record, runtime: runtime, services: services)
        }
        return ConnectedDeviceDisplay(display: connection, capabilities: capabilities, optionalServices: services,
                                      startOptionalServices: start)
    }

    private static func startInput(on connection: SimulatorConnection, of device: SimulatorDevice, plan: NativeInputPlan,
                                   record: CoreDeviceSimulatorRecord, runtime: SimulatorPresentationRuntime,
                                   services: DeviceOptionalServices) {
        guard plan != .canvas, plan != .simulatorKit else { return }
        let connect: @MainActor () async throws -> NativeInputServices? = {
            try await connectInput(of: device, plan: plan, record: record, runtime: runtime)
        }
        let activate: @MainActor (NativeInputServices) async throws -> Void = { [weak connection] connected in
            guard let connection else { throw CancellationError() }
            try await connection.activateNativeInput(connected)
        }
        // Only the guest's route reaches the device through its channel.
        var healthChanges: (@MainActor () -> AsyncStream<DeviceChannelHealth>)?
        if case .guest = plan { healthChanges = { device.channel.healthChanges() } }
        let activation = NativeInputActivation(services: services, connect: connect, activate: activate, healthChanges: healthChanges)
        connection.inputActivation = activation
        activation.start()
    }

    /// Connects `plan`'s services, or returns nil when CoreDevice has said the device lacks them. Connecting sends the guest
    /// nothing, so what connected before a later failure can be let go.
    private static func connectInput(of device: SimulatorDevice, plan: NativeInputPlan, record: CoreDeviceSimulatorRecord,
                                     runtime: SimulatorPresentationRuntime) async throws -> NativeInputServices? {
        let name = device.name
        var connected = NativeInputServices()
        switch plan {
        case .canvas, .simulatorKit:
            return nil
        case .guest(let touchscreenGestures):
            // They reach the guest's HID services through the Mach services that the device itself looks up, so they stay
            // with the device's own set.
            let interface = try await runtime.touchInterface()
            let guest = try await SimulatorGuestHID(lookUp: device.lookUp)
            connected.keyboard = try await NativeDeviceKeyboard.connect(guest: guest)
            let touchscreen = try await NativeDeviceScreenInput.connect(guest: guest)
            connected.touchRoute = NativeTouchRoute(input: touchscreen, interface: interface)
            connected.trackpad = try await NativeDeviceTrackpad.connect(guest: guest, touchscreen: touchscreenGestures ? touchscreen : nil)
        case .coreDevice(let keyboard, let trackpad, let touches):
            // Without the native touchscreen the guest would lose SimulatorKit's touches to the other input.
            var features = [CoreDeviceScreenInput.universalHIDFeature]
            if touches { features += [CoreDeviceScreenInput.features[.digitizer]!, CoreDeviceScreenInput.features[.button]!] }
            guard case .supported(let remote) = try await record.answer(for: features) else { return nil }
            if keyboard { connected.keyboard = try await NativeDeviceKeyboard.connect(remote: remote) }
            if trackpad { connected.trackpad = try await NativeDeviceTrackpad.connect(remote: remote) }
            if touches {
                connected.touchRoute = NativeTouchRoute(input: try await NativeDeviceScreenInput.connect(remote: remote),
                                                        interface: try await runtime.touchInterface())
            }
        }
        connected.keyboard?.onFailure = { hostLog("Could not send keyboard input to \(name): \($0.localizedDescription)") }
        connected.trackpad?.onFailure = { hostLog("Could not send trackpad input to \(name): \($0.localizedDescription)") }
        connected.touchRoute?.input.onFailure = { hostLog("Could not send touches to \(name): \($0.localizedDescription)") }
        return connected
    }

    private static func capabilities(of device: SimulatorDevice, features: Set<String>) -> DeviceCapabilities {
        DeviceCapabilities(family: DeviceCapabilities.Family(rawValue: device.productFamily),
                           runtimeVersion: device.runtimeVersion,
                           supportsFeature: { features.contains($0) },
                           controlsOrientation: device.deviceSetPath == nil,
                           hasFramebufferMask: device.hasFramebufferMask,
                           screenCornerRadius: device.screenCornerRadius,
                           screenPointsPerInch: device.screenPointsPerInch,
                           hasUserInterfacePlugin: device.hasUserInterfacePlugin,
                           supportsEnhancedMultitasking: device.supportsEnhancedMultitasking)
    }
}

extension DevicePostureModel {
    /// A model of `deviceID`'s posture, through CoreDevice's hinge services.
    package convenience init(deviceID: DeviceInventoryID) {
        self.init(deviceID: deviceID, makeTransport: NativeDevicePostureTransport.make)
    }
}
