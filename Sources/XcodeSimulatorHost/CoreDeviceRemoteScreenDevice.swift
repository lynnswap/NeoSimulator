import ABIBridge
import AppKit
import Darwin

@_spi(NeoSimulator)
@MainActor
public enum CoreDeviceRuntime {
    private static var manager: NativeSwiftValue?

    /// Returns the retained, shared manager for default devices and simulators.
    ///
    /// Callers must await the manager's `awaitFullInitialization()` before reading
    /// its devices or observing device changes. This method does not wait for initialization.
    public static func deviceManagerIncludingSimulators() throws -> NativeSwiftValue {
        if let manager { return manager }
        let binary = "/Library/Developer/PrivateFrameworks/CoreDevice.framework/CoreDevice"
        // Apple runtime metadata and registered classes outlive the handle.
        guard dlopen(binary, RTLD_NOW | RTLD_LOCAL) != nil else {
            let detail = dlerror().map { String(cString: $0) } ?? "Unknown loader error"
            throw CLIError.unavailable("coredevice-runtime", "Could not load CoreDevice: \(detail)")
        }
        let runtime = ABIRuntime.shared
        let service = try runtime.resolveAndWait(.swift(.type("CoreDevice.CoreDeviceService")))
        let sharedConnection = try service.resolveAndWait(.swift(.staticGetter("sharedConnection", as: (() -> NativeSwiftValue).self)))
        let connection = try unsafe sharedConnection.unsafeInvoke()
        let visibility = try runtime.resolveAndWait(.swift(.type("CoreDevice.DeviceVisibilityClass")))
        let classes = try ["default", "simulators"].map { try visibility.makeEnumCase(named: $0) }
        let type = try runtime.resolveAndWait(.swift(.type("CoreDevice.DeviceManager")))
        let make = try type.resolveAndWait(.swift(.initializer("init(serviceConnection:allowedDeviceVisibilityClasses:)",
            as: ((NativeSwiftValue, [NativeSwiftValue]) -> NativeSwiftValue).self)))
        let manager = try unsafe make.unsafeInvoke(connection, classes)
        self.manager = manager
        return manager
    }
}

@MainActor
final class CoreDeviceRemoteScreenDevice {
    let runtime: ABIRuntime
    let object: NativeSwiftValue
    let type: NativeSwiftType
    private let manager: NativeSwiftValue
    private let supportsFeature: NativeSwiftMethod<(String) -> Bool>

    init(identifier: String) async throws {
        let manager = try CoreDeviceRuntime.deviceManagerIncludingSimulators()
        let runtime = ABIRuntime.shared
        let managerType = try runtime.resolveAndWait(.swift(.type("CoreDevice.DeviceManager")))
        let initialize = try managerType.resolveAndWait(.swift(.method("awaitFullInitialization()", as: (() async -> Void).self)))
        try await unsafe initialize.unsafeInvoke(on: manager)
        try Task.checkCancellation()
        guard let uuid = UUID(uuidString: identifier) else {
            throw CLIError.configuration("coredevice-identifier", "The selected CoreDevice identifier is not a UUID.")
        }
        let devices = try managerType.resolveAndWait(.swift(.getter("devices", as: (() -> [UUID: NativeSwiftValue]).self)))
        guard let object = try unsafe devices.unsafeInvoke(on: manager)[uuid] else {
            throw CLIError.unavailable("remote-screen-device", "The selected device is no longer available.")
        }
        self.runtime = runtime
        self.manager = manager
        self.object = object
        type = try runtime.resolveAndWait(.swift(.type("CoreDevice.RemoteDevice")))
        supportsFeature = try type.resolveAndWait(.swift(.method("supportsFeature(identifiedBy:)", as: ((String) -> Bool).self)))
    }

    func supports(_ feature: String) throws -> Bool {
        try unsafe supportsFeature.unsafeInvoke(on: object, feature)
    }

    func vncURL() throws -> URL? {
        let readInfo = try type.resolveAndWait(.swift(.getter("deviceInfo", as: (() -> NativeSwiftValue).self)))
        let info = try unsafe readInfo.unsafeInvoke(on: object)
        let helper = try runtime.resolveAndWait(.swift(.type("CoreDevice.ScreenViewingURLHelper")))
        let urlType = try runtime.resolveAndWait(.swift(.type("CoreDevice.ScreenViewingURLHelper.ScreenViewingURLType")))
        let url = try helper.resolveAndWait(.swift(.staticMethod("url(for:withType:)",
            as: ((NativeSwiftValue, NativeSwiftValue) -> URL?).self)))
        return try unsafe url.unsafeInvoke(info, urlType.makeEnumCase(named: "VNC"))
    }

    func implementation(capability name: String, feature: String) async throws -> NativeSwiftValue {
        guard try supports(feature) else {
            throw CLIError.unavailable("remote-input-capability", "The device does not currently expose the requested input operation.")
        }
        let capability = try runtime.resolveAndWait(.swift(.type("CoreDevice." + name)))
        let markerType = try runtime.resolveAndWait(.swift(.type("CoreDevice.CapabilityStaticMember", genericArguments: [.type(capability)])))
        let abis: [NativeSwiftType: NativeType] = [markerType: try .opaque(named: markerType.name)]
        let make = try markerType.resolveAndWait(.swift(.initializer("init()", as: (() -> NativeSwiftValue).self, valueABIs: abis)))
        let marker = try unsafe make.unsafeInvoke()
        let get = try type.resolveAndWait(.swift(.method("getImplementation(for:)",
            as: ((NativeSwiftValue) async throws -> NativeSwiftValue).self,
            genericArguments: [.type(capability)], valueABIs: abis)))
        return try await unsafe get.unsafeInvoke(on: object, marker).copyUnderlyingValue()
    }

    static func load(_ path: String) throws {
        guard dlopen(path, RTLD_NOW | RTLD_LOCAL) != nil else {
            let detail = dlerror().map { String(cString: $0) } ?? "Unknown loader error"
            throw CLIError.unavailable("remote-screen-runtime", "Could not load \(path): \(detail)")
        }
    }
}

@MainActor
enum CoreDeviceScreenTransport {
    static func make(_ device: CoreDeviceDevice, contentView: NSView) async throws -> any RemoteScreenTransport {
        let remote = try await CoreDeviceRemoteScreenDevice(identifier: device.identifier)
        if let url = try remote.vncURL() {
            return try ScreenSharingDeviceTransport(remote: remote, url: url, contentView: contentView)
        }
        guard try remote.supports("com.apple.coredevice.feature.viewdevicescreen") else {
            throw CLIError.unavailable("remote-screen-capability", "The device does not currently expose a screen connection.")
        }
        try await CoreDeviceDisplayGeometry.loadRuntime()
        return try CoreDeviceMediaStreamTransport(remote: remote, contentView: contentView)
    }
}
