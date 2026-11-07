import ABIBridge
import Foundation
import NeoSimulatorNative
import ObjectiveC

/// Binds CoreSimDeviceIO's SimAudioHostRoutable port directly.
/// Xcode 27 removed SimulatorKit's SimDeviceAudioClient; this also supports custom device sets.
@MainActor
package struct SimulatorAudioInterface {
    /// `SimDevice.io`, the device's `SimDeviceIOClient`.
    let deviceIO: NativeObjCMethod<AnyObject?>
    /// `SimDeviceIOClient.ioPorts`, remote proxies of the device's I/O ports.
    let ioPorts: NativeObjCMethod<[AnyObject]>
    let routable: Protocol

    package typealias DevicesChanged = @convention(block) (NSArray?) -> Void
    package typealias RouteChanged = @convention(block) (UInt64, NSString?) -> Void
    package typealias RouteCompletion = @convention(block) (NSError?) -> Void

    package init(runtime: ABIRuntime) async throws {
        guard let device = NSClassFromString("SimDevice"), let client = NSClassFromString("SimDeviceIOClient") else {
            throw DeviceIOError.unavailable("simulator-runtime", "CoreSimulator's device I/O classes are unavailable")
        }
        deviceIO = try await runtime.resolve(.objc(.method("io", as: (() -> AnyObject?).self)), on: device)
        ioPorts = try await runtime.resolve(.objc(.method("ioPorts", as: (() -> [AnyObject]).self)), on: client)
        // Port and device objects are remote proxies, bound on connection through their protocols.
        let protocols = [("SimAudioHostRoutable", SimulatorAudioPort.selectors),
                         ("SimAudioHostDevice", HostAudioDeviceMembers.selectors)]
        for (name, selectors) in protocols {
            guard let declared = objc_getProtocol(name) else {
                throw DeviceIOError.unavailable("simulator-runtime", "Required private protocol \(name) is unavailable")
            }
            for selector in selectors
            where unsafe protocol_getMethodDescription(declared, NSSelectorFromString(selector), true, true).name == nil {
                throw DeviceIOError.unavailable("simulator-runtime", "\(name) does not declare \(selector)")
            }
        }
        guard let routable = objc_getProtocol("SimAudioHostRoutable") else {
            throw DeviceIOError.unavailable("simulator-runtime", "Required private protocol SimAudioHostRoutable is unavailable")
        }
        self.routable = routable
        // Recent routes are saved with this value, so it must not change.
        let symbol = try await runtime.resolve(.c(.symbol("SimAudioHostUseSystemDefaultDeviceUID", kind: .data)))
        let systemDefault = unsafe symbol.withUnsafeAddress {
            unsafe $0.load(as: Unmanaged<NSString>?.self)?.takeUnretainedValue() as String?
        }
        guard systemDefault == AudioRouting.systemDefault else {
            throw DeviceIOError.unavailable("simulator-runtime", "SimAudioHostUseSystemDefaultDeviceUID is \(systemDefault ?? "nil")")
        }
    }

    /// Loads CoreSimulator, which re-exports CoreSimDeviceIO, and binds its port.
    package static func load() async throws -> SimulatorAudioInterface {
        _ = try await CoreSimulatorInterface.load()
        return try await ABIRuntime.shared.prepare { try await SimulatorAudioInterface(runtime: $0) }
    }

    /// Connects to the device's audio route port, which a booted device that
    /// has `SimFeatureRoutableAudio` provides.
    package func connect(to device: SimulatorDevice,
                 changed: @escaping @MainActor (AudioRouteChange) -> Void) async throws -> SimulatorAudioConnection {
        nonisolated(unsafe) let deviceIO = deviceIO, ioPorts = ioPorts, routable = routable, object = device.handle.object
        let port = try await device.channel.read("connect the device's audio routes", lateCompletion: { result in
            if case .success(let port) = result { port.disconnect() }
        }) { () throws -> SimulatorAudioPort in
            guard let io = try unsafe deviceIO.unsafeInvoke(on: object) else {
                throw DeviceIOError.unavailable("simulator-runtime", "The device did not provide its I/O ports.")
            }
            var descriptor: NativeObjCMethod<AnyObject?>?
            for port in try unsafe ioPorts.unsafeInvoke(on: io) {
                // Every port is a proxy of one class.
                let method = try descriptor ?? ABIRuntime.shared.object(port)
                    .resolveAndWait(.objc(.method("descriptor", as: (() -> AnyObject?).self))).method
                descriptor = method
                if let found = try unsafe method.unsafeInvoke(on: port),
                   (found as? NSObjectProtocol)?.conforms(to: routable) == true {
                    return try SimulatorAudioPort(port: found, changed: changed)
                }
            }
            throw DeviceIOError.unavailable("simulator-runtime", "The device has no audio route port.")
        }
        return SimulatorAudioConnection(port: port, channel: device.channel)
    }
}

/// Observes host-device and guest-route changes, including those made by other processes.
@MainActor
package final class SimulatorAudioConnection: SimulatorAudioRoutes {
    package nonisolated static var portSelectors: [String] { SimulatorAudioPort.selectors }

    private let port: SimulatorAudioPort
    private let channel: SimulatorDeviceChannel
    private var isConnected = true

    fileprivate init(port: SimulatorAudioPort, channel: SimulatorDeviceChannel) {
        self.port = port
        self.channel = channel
    }

    isolated deinit { disconnect() }

    package func state() async throws -> AudioRouteState {
        try await channel.read("read the device's audio routes") { [port] in try port.state() }
    }

    package func route(_ scope: AudioScope, to route: String, completion: @escaping @MainActor (Error?) -> Void) async throws {
        try await channel.change("route the device's audio") { [port] in
            try port.route(scope, to: route, completion: completion)
        }
    }

    package func disconnect() {
        guard isConnected else { return }
        isConnected = false
        channel.cleanUp("stop the audio route reports") { [port] in port.disconnect() }
    }
}

/// The messages of a device's audio port, a proxy of its I/O server. Only the device's worker sends them, and it is the
/// only one to touch the members it caches.
private final class SimulatorAudioPort: @unchecked Sendable {
    static let selectors = [
        "availableHostDevices", "guestInputHostDeviceUID", "guestOutputHostDeviceUID",
        "effectiveDefaultInputDeviceUID", "effectiveDefaultOutputDeviceUID",
        "routeGuestDeviceScope:toHostDeviceUID:completionQueue:completionHandler:",
        "registerCallbackWithUUID:availableDevicesChangedCallback:",
        "registerCallbackWithUUID:selectedDeviceUIDChangedCallback:", "unregisterCallbackWithUUID:",
    ]

    private let availableDevices: NativeBoundObjCMethod<[AnyObject]?>
    private let inputRoute: NativeBoundObjCMethod<String?>
    private let outputRoute: NativeBoundObjCMethod<String?>
    private let defaultInput: NativeBoundObjCMethod<String?>
    private let defaultOutput: NativeBoundObjCMethod<String?>
    private let routeGuest: NativeBoundObjCMethod<Void, UInt64, String, DispatchQueue,
                                                  SimulatorAudioInterface.RouteCompletion>
    private let unregister: NativeBoundObjCMethod<Void, NSUUID>
    /// Identifies this connection's change reports.
    private let token = NSUUID()
    private var members: HostAudioDeviceMembers?

    init(port: AnyObject, changed: @escaping @MainActor (AudioRouteChange) -> Void) throws {
        let object = ABIRuntime.shared.object(port)
        availableDevices = try object.resolveAndWait(.objc(.method(
            "availableHostDevices", as: (() -> [AnyObject]?).self)))
        inputRoute = try object.resolveAndWait(.objc(.method("guestInputHostDeviceUID", as: (() -> String?).self)))
        outputRoute = try object.resolveAndWait(.objc(.method("guestOutputHostDeviceUID", as: (() -> String?).self)))
        defaultInput = try object.resolveAndWait(.objc(.method(
            "effectiveDefaultInputDeviceUID", as: (() -> String?).self)))
        defaultOutput = try object.resolveAndWait(.objc(.method(
            "effectiveDefaultOutputDeviceUID", as: (() -> String?).self)))
        routeGuest = try object.resolveAndWait(.objc(.method(
            "routeGuestDeviceScope:toHostDeviceUID:completionQueue:completionHandler:",
            as: ((UInt64, String, DispatchQueue, @escaping SimulatorAudioInterface.RouteCompletion) -> Void).self)))
        unregister = try object.resolveAndWait(.objc(.method("unregisterCallbackWithUUID:", as: ((NSUUID) -> Void).self)))
        let registerDevices = try object.resolveAndWait(.objc(.method(
            "registerCallbackWithUUID:availableDevicesChangedCallback:",
            as: ((NSUUID, @escaping SimulatorAudioInterface.DevicesChanged) -> Void).self)))
        let registerRoutes = try object.resolveAndWait(.objc(.method(
            "registerCallbackWithUUID:selectedDeviceUIDChangedCallback:",
            as: ((NSUUID, @escaping SimulatorAudioInterface.RouteChanged) -> Void).self)))
        try unsafe registerDevices.unsafeInvoke(token, Self.devicesChanged(changed))
        do {
            try unsafe registerRoutes.unsafeInvoke(token, Self.routeChanged(changed))
        } catch {
            disconnect()
            throw error
        }
    }

    // Audio-port callbacks may ignore the completion queue. Bridge to the main actor explicitly.
    private static func devicesChanged(
        _ changed: @escaping @MainActor (AudioRouteChange) -> Void
    ) -> SimulatorAudioInterface.DevicesChanged {
        { _ in DispatchQueue.main.async { MainActor.assumeIsolated { changed(.availableDevices) } } }
    }

    private static func routeChanged(
        _ changed: @escaping @MainActor (AudioRouteChange) -> Void
    ) -> SimulatorAudioInterface.RouteChanged {
        { _, _ in DispatchQueue.main.async { MainActor.assumeIsolated { changed(.selectedDevice) } } }
    }

    private static func routeCompleted(
        _ completion: @escaping @MainActor (Error?) -> Void
    ) -> SimulatorAudioInterface.RouteCompletion {
        { error in DispatchQueue.main.async { MainActor.assumeIsolated { completion(error) } } }
    }

    func state() throws -> AudioRouteState {
        var devices: [HostAudioDevice] = []
        for object in try unsafe availableDevices.unsafeInvoke() ?? [] {
            let members = try self.members ?? HostAudioDeviceMembers(object)
            self.members = members
            if let device = try members.device(object) { devices.append(device) }
        }
        return AudioRouteState(devices: devices,
                               inputRoute: try unsafe inputRoute.unsafeInvoke(),
                               outputRoute: try unsafe outputRoute.unsafeInvoke(),
                               defaultInput: try unsafe defaultInput.unsafeInvoke(),
                               defaultOutput: try unsafe defaultOutput.unsafeInvoke())
    }

    func route(_ scope: AudioScope, to route: String, completion: @escaping @MainActor (Error?) -> Void) throws {
        try unsafe routeGuest.unsafeInvoke(scope.rawValue, route, .main, Self.routeCompleted(completion))
    }

    func disconnect() {
        do { try unsafe unregister.unsafeInvoke(token) } catch {
            hostLog("Could not stop the audio route reports: \(error.localizedDescription)")
        }
    }
}

/// `SimAudioHostDevice`'s members. The Mac's devices are proxies of one
/// class, so the members are bound to the first and sent to each.
private struct HostAudioDeviceMembers {
    static let selectors = ["uniqueIdentifier", "displayName", "inputChannels", "outputChannels", "isDefaultInScopes"]

    let uniqueIdentifier: NativeObjCMethod<String?>
    let displayName: NativeObjCMethod<String?>
    let inputChannels: NativeObjCMethod<Int>
    let outputChannels: NativeObjCMethod<Int>
    let defaultScopes: NativeObjCMethod<UInt64>

    init(_ device: AnyObject) throws {
        let object = ABIRuntime.shared.object(device)
        uniqueIdentifier = try object.resolveAndWait(.objc(.method("uniqueIdentifier", as: (() -> String?).self))).method
        displayName = try object.resolveAndWait(.objc(.method("displayName", as: (() -> String?).self))).method
        inputChannels = try object.resolveAndWait(.objc(.method("inputChannels", as: (() -> Int).self))).method
        outputChannels = try object.resolveAndWait(.objc(.method("outputChannels", as: (() -> Int).self))).method
        defaultScopes = try object.resolveAndWait(.objc(.method("isDefaultInScopes", as: (() -> UInt64).self))).method
    }

    /// The device, or nil for one without an identifier, which no route can name.
    func device(_ object: AnyObject) throws -> HostAudioDevice? {
        guard let uid = try unsafe uniqueIdentifier.unsafeInvoke(on: object) else { return nil }
        return HostAudioDevice(uid: uid, name: try unsafe displayName.unsafeInvoke(on: object) ?? uid,
                               inputChannels: try unsafe inputChannels.unsafeInvoke(on: object),
                               outputChannels: try unsafe outputChannels.unsafeInvoke(on: object),
                               defaultScopes: try unsafe defaultScopes.unsafeInvoke(on: object))
    }
}
