import ABIBridge
import AppKit
import NeoSimulatorDeviceIO
import NeoSimulatorKit
import Synchronization

/// The external display of one device, through SimulatorKit's
/// `SimDeviceScreen` and CoreSimDeviceIO's `SimScreen`.
@MainActor
package final class SimulatorExternalScreenConnection: SimulatorExternalScreen {
    /// The messages this connection sends to proxies, by protocol.
    package static let selectors = [
        ("SimScreen", ["setCurrentMode:pixelSize:carPlayProperties:completionQueue:completionHandler:",
                       "setPowerState:completionQueue:completionHandler:", "screenProperties"]),
        ("SimScreenProperties", ["screenID", "powerState", "screenType", "pixelSize", "currentMode",
                                 "supportedScreenModes", "carPlayProperties"]),
        ("SimScreenMode", ["sizeRule", "exactSize", "minSize", "maxSize", "allowedSizes", "preferredUIScale",
                           "refreshRate"]),
    ]

    package typealias Completion = @convention(block) (NSError?) -> Void

    package let screenID: UInt32
    private let device: SimulatorDevice
    /// The `SimDeviceScreen`.
    private let screen: AnyObject
    private let runtime: SimulatorPresentationRuntime
    /// The device's native keyboard, which this screen's displays share with its integrated screen.
    private let nativeKeyboard: SharedNativeKeyboard
    private let displays: SimulatorDisplaySet
    private let pasteboardRoute: SimulatorPasteboardRoute
    // A proxy's messages go to the device's I/O server, so only the device's worker sends them.
    private nonisolated(unsafe) let setCurrentMode: NativeObjCMethod<Void, AnyObject, CGSize, NSDictionary?, DispatchQueue, Completion>
    private nonisolated(unsafe) let setPowerState: NativeObjCMethod<Void, Int32, DispatchQueue, Completion>
    private var events: NativeSwiftValue?
    /// The HID client that sends the CarPlay service's messages, from the first.
    private var hidClient: WorkerOwned<AnyObject>?

    package init(device: SimulatorDevice, screen: (identifier: UInt32, object: AnyObject), runtime: SimulatorPresentationRuntime,
         displays: SimulatorDisplaySet, pasteboardRoute: SimulatorPasteboardRoute, nativeKeyboard: SharedNativeKeyboard,
         changed: @escaping @MainActor () -> Void) throws {
        self.device = device
        self.screen = screen.object
        self.runtime = runtime
        self.nativeKeyboard = nativeKeyboard
        self.displays = displays
        self.pasteboardRoute = pasteboardRoute
        screenID = screen.identifier
        let display = runtime.display
        guard let simScreen = try unsafe display.screen.unsafeInvoke(on: screen.object) else {
            throw SimulatorError.unavailable("The external display is not connected.")
        }
        // Every screen of a device is a proxy of one class.
        let proxy = ABIRuntime.shared.object(simScreen)
        setCurrentMode = try proxy.resolveAndWait(.objc(.method(
            "setCurrentMode:pixelSize:carPlayProperties:completionQueue:completionHandler:",
            as: ((AnyObject, CGSize, NSDictionary?, DispatchQueue, @escaping Completion) -> Void).self))).method
        setPowerState = try proxy.resolveAndWait(.objc(.method(
            "setPowerState:completionQueue:completionHandler:",
            as: ((Int32, DispatchQueue, @escaping Completion) -> Void).self))).method
        let handler = try SimulatorDisplayInterface.ScreenEventHandler { _, _ in
            MainActor.assumeIsolated { changed() }
        }
        events = try unsafe display.registerScreenEvents.unsafeInvoke(
            on: screen.object, display.screenPropertyEvents, .main, handler)
    }

    isolated deinit { disconnect() }

    package var deviceBootDate: Date? { device.lastBootDate }

    package func state() throws -> ExternalScreenState {
        let messages = runtime.display.screenMessages
        let properties = try self.properties()
        let currentMode = try messages.send("currentMode", to: properties, as: AnyObject?.self)
        return ExternalScreenState(
            isPoweredOn: try messages.send("powerState", to: properties, as: Int32.self) == 1,
            pixelSize: try messages.send("pixelSize", to: properties, as: CGSize.self),
            scale: try currentMode.map { CGFloat(try messages.send("preferredUIScale", to: $0, as: Double.self)) } ?? 0,
            isCarPlay: try messages.send("carPlayProperties", to: properties, as: NSDictionary?.self) != nil,
            refreshRate: try currentMode.map { try refreshRate(of: $0) } ?? 0)
    }

    package func supportedModes() throws -> [ExternalScreenMode] { try advertisedModes().map(mode) }

    package func setMode(pixelSize size: CGSize, scale: CGFloat, carPlay: Bool,
                 completion: @escaping @MainActor (Error?) -> Void) async throws {
        let simScreen = try connectedScreen()
        // One read of the modes, whose order the choice's index refers to.
        let advertised = try advertisedModes()
        let target: AnyObject? = switch try ExternalScreenMode.choice(
            for: size, scale: scale, current: try state(), among: try advertised.map(mode)) {
        case .current: try runtime.display.screenMessages.send("currentMode", to: try properties(), as: AnyObject?.self)
        case .advertised(let index): advertised[index]
        }
        guard let target else { throw SimulatorError.operation("The external display has no current mode.") }
        nonisolated(unsafe) let message = setCurrentMode, screen = simScreen, mode = target
        nonisolated(unsafe) let properties = carPlay ? runtime.display.carPlayProperties : nil
        nonisolated(unsafe) let completed = Self.completed(completion)
        try await device.channel.change("set the external display's mode") {
            try unsafe message.unsafeInvoke(on: screen, mode, size, properties, .main, completed)
        }
    }

    package func powerOff(completion: @escaping @MainActor (Error?) -> Void) async throws {
        nonisolated(unsafe) let message = setPowerState, screen = try connectedScreen()
        nonisolated(unsafe) let completed = Self.completed(completion)
        try await device.channel.change("turn off the external display") {
            try unsafe message.unsafeInvoke(on: screen, 0, .main, completed)
        }
    }

    package func saveCarPlayConfiguration(carPlay: Bool) throws {
        try CarPlayConfiguration.save(carPlay: carPlay, to: device.extendedDisplayFile())
    }

    package func setCarPlayEnabled(_ enabled: Bool, inBoot boot: Date?, completion: @escaping @MainActor (Error?) -> Void) {
        Task.immediate { [device] in
            do {
                try await device.setCarPlayEnabled(enabled, inBoot: boot)
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    package func setCarPlayService(connected: Bool, completion: @escaping @MainActor (Error?) -> Void) async throws {
        let client: WorkerOwned<AnyObject>
        if let hidClient { client = hidClient } else {
            client = try await runtime.input.connect(to: device)
            hidClient = client
        }
        try runtime.input.sendCarPlayService(connected: connected, hasTouchScreen: CarPlayConfiguration.hasTouchScreen,
                                             client: client.value, completion: completion)
    }

    package func makeDisplay() async throws -> any DeviceSessionDisplay {
        try await SimulatorConnection(device: device, screen: (screenID, screen), runtime: runtime, displays: displays,
                                      pasteboardRoute: pasteboardRoute, nativeKeyboard: nativeKeyboard)
    }

    package func disconnect() {
        // Releasing the registration ends the screen events.
        events = nil
    }

    private func properties() throws -> AnyObject {
        try unsafe runtime.display.screenProperties.unsafeInvoke(on: screen)
    }

    private func connectedScreen() throws -> AnyObject {
        guard let simScreen = try unsafe runtime.display.screen.unsafeInvoke(on: screen) else {
            throw SimulatorError.unavailable("The external display is not connected.")
        }
        return simScreen
    }

    /// A `SimScreenMode`, read as Simulator.app's mode choice reads it.
    private func mode(_ object: AnyObject) throws -> ExternalScreenMode {
        let messages = runtime.display.screenMessages
        let sizes: ExternalScreenMode.Sizes? = switch try messages.send("sizeRule", to: object, as: UInt64.self) {
        case 0: .exact(try messages.send("exactSize", to: object, as: CGSize.self))
        case 1: .range(minimum: try messages.send("minSize", to: object, as: CGSize.self),
                       maximum: try messages.send("maxSize", to: object, as: CGSize.self))
        case 2: .allowed((try messages.send("allowedSizes", to: object, as: [NSValue]?.self) ?? []).map(\.sizeValue))
        default: nil
        }
        return ExternalScreenMode(sizes: sizes,
                                  scale: CGFloat(try messages.send("preferredUIScale", to: object, as: Double.self)),
                                  refreshRate: try refreshRate(of: object))
    }

    /// A `SimScreenMode`'s `refreshRate`, which CoreSimulator gives in
    /// hundredths of a hertz, in hertz.
    private func refreshRate(of mode: AnyObject) throws -> Double {
        Double(try runtime.display.screenMessages.send("refreshRate", to: mode, as: UInt32.self)) / 100
    }

    private func advertisedModes() throws -> [AnyObject] {
        try runtime.display.screenMessages.send("supportedScreenModes", to: try properties(), as: [AnyObject]?.self) ?? []
    }

    // CoreSimDeviceIO may ignore the completion queue. Bridge back to the main actor explicitly. It also keeps the block
    // after calling it, so the block gives up the completion, which holds this connection and so its device.
    private nonisolated static func completed(_ completion: @escaping @MainActor (Error?) -> Void) -> Completion {
        let pending = Mutex<(@MainActor (Error?) -> Void)?>(completion)
        return { error in
            guard let completion = pending.withLock({ $0.take() }) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(error) } }
        }
    }
}
