import AppKit
import NeoSimulatorDeviceIO
import NeoSimulatorKit
import NeoSimulatorNative

/// Which transport carries a device's native input. This follows from what the device is, and never from whether a
/// transport answered: a failure to reach one is that route's failure, not a reason to take another.
package enum NativeInputPlan: Equatable, Sendable {
    /// DeviceKit's own view takes the screen's input. A device that needs it has no other screen.
    case canvas
    /// The Mach services that the device itself looks up, for a device in any set.
    case guest
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
            self = .guest
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

/// What a device's native input route connected. Connecting sends the guest nothing, so these can be let go until a
/// display activates them.
package struct NativeInputServices {
    package var keyboard: NativeDeviceKeyboard?
    package var trackpad: NativeDeviceTrackpad?
    package var touchRoute: NativeTouchRoute?

    package init(keyboard: NativeDeviceKeyboard? = nil, trackpad: NativeDeviceTrackpad? = nil, touchRoute: NativeTouchRoute? = nil) {
        self.keyboard = keyboard
        self.trackpad = trackpad
        self.touchRoute = touchRoute
    }
}

/// Connects a display's native input after the display opened and hands it over in place. Its state says how far that
/// came: `connect` returning nil is a device without the route, and a throw is a failure to reach it, which keeps the
/// display on SimulatorKit's input, says so, and can be retried.
@MainActor
package final class NativeInputActivation {
    private let services: DeviceOptionalServices
    private let connect: @MainActor () async throws -> NativeInputServices?
    private let activate: @MainActor (NativeInputServices) async throws -> Void
    private var running: Task<Void, Never>?

    package init(services: DeviceOptionalServices, connect: @escaping @MainActor () async throws -> NativeInputServices?,
                 activate: @escaping @MainActor (NativeInputServices) async throws -> Void) {
        self.services = services
        self.connect = connect
        self.activate = activate
        services.onRetryInput = { [weak self] in self?.start() }
        services.setInput(.pending)
    }

    /// Connects unless a connection is running or has finished. A failed one can start again.
    package func start() {
        guard running == nil else { return }
        services.setInput(.pending)
        let (connect, activate, services) = (connect, activate, services)
        running = Task { [weak self] in
            do {
                if let connected = try await connect() {
                    try Task.checkCancellation()
                    try await activate(connected)
                    services.setInput(.ready)
                } else {
                    services.setInput(.unsupported)
                }
            } catch where error.isCancellation {
                return
            } catch {
                services.setInput(.failed(error))
                self?.running = nil
            }
        }
    }

    package func cancel() { running?.cancel() }

    /// Whether a connection that was cancelled has returned by `deadline`. A native call that ignores its cancellation
    /// holds nothing of the display's, but does hold a guest service if it then answers.
    package func ends(before deadline: ContinuousClock.Instant) async -> Bool {
        guard let running else { return true }
        return await running.ends(before: deadline)
    }
}

/// The device's native keyboard, which each of its displays shares and takes up once it is ready.
@MainActor
package final class SharedNativeKeyboard {
    private struct Display { weak var connection: SimulatorConnection? }
    package private(set) var keyboard: NativeDeviceKeyboard?
    private var displays: [Display] = []

    package init() {}

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

/// How a device's pasteboard is reached: CoreDevice's transport for the default set, which a transfer waits for, and
/// SimPasteboardPlus where the device really has no other. A failure to reach CoreDevice's says nothing about whether the
/// device has it, so it falls back to nothing, and the next transfer asks again.
@MainActor
package final class SimulatorPasteboardRoute {
    private let services: DeviceOptionalServices
    private let make: (@MainActor () async throws -> (any PasteboardTransport)?)?
    private var resolved: (any PasteboardTransport)?
    private var isResolved = false

    /// With no `make`, nothing but SimPasteboardPlus is routed.
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

/// Connects a device's display and routes what its capabilities select. The display opens with what it itself needs, so
/// an optional service can neither delay nor fail it.
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
        // DeviceKit's view is the screen of a device that needs it, so opening fails without it.
        let nativeCanvas = plan == .canvas
            ? try await NativeDeviceCanvas.connect(simulatorUDID: device.identifier, lookUp: device.lookUp) : nil
        try Task.checkCancellation()
        let services = DeviceOptionalServices()
        // CoreDevice lists only the default set, so any other set has nothing to route.
        var makePasteboard: (@MainActor () async throws -> (any PasteboardTransport)?)?
        if device.deviceSetPath == nil {
            let identifier = device.identifier
            makePasteboard = { try await CoreDevicePasteboardTransport.make(simulatorUDID: identifier) }
        }
        let pasteboardRoute = SimulatorPasteboardRoute(services: services, make: makePasteboard)
        let connection = try await SimulatorConnection(device: device, screen: screen, runtime: runtime, displays: displays,
                                                       pasteboardRoute: pasteboardRoute, nativeCanvas: nativeCanvas)
        if nativeCanvas != nil { capabilities.controlsOrientation = false }
        let start: @MainActor () -> Void = { [weak connection] in
            guard let connection else { return }
            Self.startInput(on: connection, of: device, plan: plan, runtime: runtime, services: services)
        }
        return ConnectedDeviceDisplay(display: connection, capabilities: capabilities, optionalServices: services,
                                      startOptionalServices: start)
    }

    private static func startInput(on connection: SimulatorConnection, of device: SimulatorDevice, plan: NativeInputPlan,
                                   runtime: SimulatorPresentationRuntime, services: DeviceOptionalServices) {
        guard plan != .canvas, plan != .simulatorKit else { return }
        let connect: @MainActor () async throws -> NativeInputServices? = {
            try await connectInput(of: device, plan: plan, runtime: runtime)
        }
        let activate: @MainActor (NativeInputServices) async throws -> Void = { [weak connection] connected in
            guard let connection else { throw CancellationError() }
            try await connection.activateNativeInput(connected)
        }
        let activation = NativeInputActivation(services: services, connect: connect, activate: activate)
        connection.inputActivation = activation
        activation.start()
    }

    /// Connects `plan`'s services, or returns nil when the device lacks them. Connecting sends the guest nothing, so what
    /// connected before a later failure can be let go.
    private static func connectInput(of device: SimulatorDevice, plan: NativeInputPlan,
                                     runtime: SimulatorPresentationRuntime) async throws -> NativeInputServices? {
        let name = device.name
        var connected = NativeInputServices()
        switch plan {
        case .canvas, .simulatorKit:
            return nil
        case .guest:
            // They reach the guest's HID services through the Mach services that the device itself looks up, so they stay
            // with the device's own set.
            let interface = try await runtime.touchInterface()
            let guest = try await SimulatorGuestHID(lookUp: device.lookUp)
            connected.keyboard = try await NativeDeviceKeyboard.connect(guest: guest)
            connected.trackpad = try await NativeDeviceTrackpad.connect(guest: guest)
            connected.touchRoute = NativeTouchRoute(input: try await NativeDeviceScreenInput.connect(guest: guest), interface: interface)
        case .coreDevice(let keyboard, let trackpad, let touches):
            if keyboard { connected.keyboard = try await NativeDeviceKeyboard.connect(simulatorUDID: device.identifier) }
            if trackpad { connected.trackpad = try await NativeDeviceTrackpad.connect(simulatorUDID: device.identifier) }
            guard connected.keyboard != nil || connected.trackpad != nil else { return nil }
            if touches {
                // Without the native touchscreen the guest would lose SimulatorKit's touches to the other input.
                guard let input = try await NativeDeviceScreenInput.connect(simulatorUDID: device.identifier) else { return nil }
                connected.touchRoute = NativeTouchRoute(input: input, interface: try await runtime.touchInterface())
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
