import ABIBridge
import AppKit
import Darwin

@MainActor
final class CoreDeviceRemoteScreenDevice {
    let runtime: ABIRuntime
    let object: NativeSwiftValue
    let type: NativeSwiftType
    private let manager: NativeSwiftValue
    private let supportsFeature: NativeSwiftMethod<(String) -> Bool>

    init(identifier: String) async throws {
        try Self.load("/Library/Developer/PrivateFrameworks/CoreDevice.framework/CoreDevice")
        let runtime = ABIRuntime.shared
        let managerType = try runtime.resolveSwiftTypeAndWait(named: "CoreDevice.DeviceManager")
        let shared = try managerType.resolveAndWait(.staticGetter("shared", as: (() -> NativeSwiftValue).self))
        let manager = try unsafe shared.unsafeInvoke()
        let initialize = try managerType.resolveAndWait(.method("awaitFullInitialization()", as: (() async -> Void).self))
        try await unsafe initialize.unsafeInvoke(on: manager)
        try Task.checkCancellation()
        guard let uuid = UUID(uuidString: identifier) else {
            throw CLIError.configuration("coredevice-identifier", "The selected CoreDevice identifier is not a UUID.")
        }
        let devices = try managerType.resolveAndWait(.getter("devices", as: (() -> [UUID: NativeSwiftValue]).self))
        guard let object = try unsafe devices.unsafeInvoke(on: manager)[uuid] else {
            throw CLIError.unavailable("remote-screen-device", "The selected device is no longer available.")
        }
        self.runtime = runtime
        self.manager = manager
        self.object = object
        type = try runtime.resolveSwiftTypeAndWait(named: "CoreDevice.RemoteDevice")
        supportsFeature = try type.resolveAndWait(.method("supportsFeature(identifiedBy:)", as: ((String) -> Bool).self))
    }

    func supports(_ feature: String) throws -> Bool {
        try unsafe supportsFeature.unsafeInvoke(on: object, feature)
    }

    func vncURL() throws -> URL? {
        let readInfo = try type.resolveAndWait(.getter("deviceInfo", as: (() -> NativeSwiftValue).self))
        let info = try unsafe readInfo.unsafeInvoke(on: object)
        let helper = try runtime.resolveSwiftTypeAndWait(named: "CoreDevice.ScreenViewingURLHelper")
        let urlType = try runtime.resolveSwiftTypeAndWait(named: "CoreDevice.ScreenViewingURLHelper.ScreenViewingURLType")
        let url = try helper.resolveAndWait(.staticMethod("url(for:withType:)",
            as: ((NativeSwiftValue, NativeSwiftValue) -> URL?).self))
        return try unsafe url.unsafeInvoke(info, urlType.makeEnumCase(named: "VNC"))
    }

    func implementation(capability name: String, feature: String) async throws -> NativeSwiftValue {
        guard try supports(feature) else {
            throw CLIError.unavailable("remote-input-capability", "The device does not currently expose the requested input operation.")
        }
        let capability = try runtime.resolveSwiftTypeAndWait(named: "CoreDevice." + name)
        let markerType = try runtime.resolveSwiftTypeAndWait(named: "CoreDevice.CapabilityStaticMember", genericArguments: [.type(capability)])
        let abis: [NativeSwiftType: NativeType] = [markerType: try .opaque(named: markerType.name)]
        let make = try markerType.resolveAndWait(.initializer("init()", as: (() -> NativeSwiftValue).self, valueABIs: abis))
        let marker = try unsafe make.unsafeInvoke()
        let get = try type.resolveAndWait(.method("getImplementation(for:)",
            as: ((NativeSwiftValue) async throws -> NativeSwiftValue).self,
            genericArguments: [.type(capability)], valueABIs: abis))
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
