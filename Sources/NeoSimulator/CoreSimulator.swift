import ABIBridge
import Foundation
import ObjectiveC

/// The CoreSimulator Objective-C messages the host sends, prepared once per process.
///
/// Methods that report failure through `NSError **` are prepared with `throws`
/// signatures, and exceptions raised by CoreSimulator arrive as Swift errors.
@MainActor
struct CoreSimulatorInterface {
    let serviceClass: AnyClass
    let sharedContext: NativeObjCMethod<AnyObject, String>
    let defaultDeviceSet: NativeObjCMethod<AnyObject>
    let subscribe: NativeObjCMethod<Void>
    let availableDevices: NativeObjCMethod<[AnyObject]>
    let registerHandler: NativeObjCMethod<UInt64, DispatchQueue, NotificationHandler>
    let unregisterHandler: NativeObjCMethod<Void, UInt64>
    let state: NativeObjCMethod<UInt>
    let name: NativeObjCMethod<String?>
    let identifier: NativeObjCMethod<NSUUID?>
    let deviceRuntime: NativeObjCMethod<AnyObject?>
    let deviceType: NativeObjCMethod<AnyObject?>
    let supportsFeature: NativeObjCMethod<Bool, String>
    let interfaceStyle: NativeObjCMethod<Int>
    let setInterfaceStyle: NativeObjCMethod<Void, Int>
    let postDarwinNotification: NativeObjCMethod<Void, String>
    let runtimeName: NativeObjCMethod<String?>
    let platformIdentifier: NativeObjCMethod<String?>
    let runtimeVersion: NativeObjCMethod<UInt32>
    let productFamily: NativeObjCMethod<Int32>

    typealias NotificationHandler = @convention(block) (NSDictionary) -> Void

    init(runtime: ABIRuntime) throws {
        func requireClass(_ name: String) throws -> AnyClass {
            guard let type = NSClassFromString(name) else {
                throw HostError.unavailable("Required private class \(name) is unavailable")
            }
            return type
        }
        serviceClass = try requireClass("SimServiceContext")
        let deviceSet: AnyClass = try requireClass("SimDeviceSet")
        let device: AnyClass = try requireClass("SimDevice")
        let simRuntime: AnyClass = try requireClass("SimRuntime")
        let simDeviceType: AnyClass = try requireClass("SimDeviceType")
        sharedContext = try runtime.resolveObjCMethodAndWait(
            on: serviceClass, selector: "sharedServiceContextForDeveloperDir:error:",
            as: ((String) throws -> AnyObject).self, classMethod: true)
        defaultDeviceSet = try runtime.resolveObjCMethodAndWait(
            on: serviceClass, selector: "defaultDeviceSetWithError:", as: (() throws -> AnyObject).self)
        subscribe = try runtime.resolveObjCMethodAndWait(
            on: deviceSet, selector: "subscribeToNotificationsWithError:", as: (() throws -> Void).self)
        availableDevices = try runtime.resolveObjCMethodAndWait(
            on: deviceSet, selector: "availableDevices", as: (() -> [AnyObject]).self)
        registerHandler = try runtime.resolveObjCMethodAndWait(
            on: deviceSet, selector: "registerNotificationHandlerOnQueue:handler:",
            as: ((DispatchQueue, @escaping NotificationHandler) -> UInt64).self)
        unregisterHandler = try runtime.resolveObjCMethodAndWait(
            on: deviceSet, selector: "unregisterNotificationHandler:error:", as: ((UInt64) throws -> Void).self)
        state = try runtime.resolveObjCMethodAndWait(on: device, selector: "state", as: (() -> UInt).self)
        name = try runtime.resolveObjCMethodAndWait(on: device, selector: "name", as: (() -> String?).self)
        identifier = try runtime.resolveObjCMethodAndWait(on: device, selector: "UDID", as: (() -> NSUUID?).self)
        deviceRuntime = try runtime.resolveObjCMethodAndWait(
            on: device, selector: "runtime", as: (() -> AnyObject?).self)
        deviceType = try runtime.resolveObjCMethodAndWait(
            on: device, selector: "deviceType", as: (() -> AnyObject?).self)
        supportsFeature = try runtime.resolveObjCMethodAndWait(
            on: device, selector: "supportsFeature:", as: ((String) -> Bool).self)
        interfaceStyle = try runtime.resolveObjCMethodAndWait(
            on: device, selector: "currentUIInterfaceStyle", as: (() -> Int).self)
        setInterfaceStyle = try runtime.resolveObjCMethodAndWait(
            on: device, selector: "setUIInterfaceStyle:error:", as: ((Int) throws -> Void).self)
        postDarwinNotification = try runtime.resolveObjCMethodAndWait(
            on: device, selector: "postDarwinNotification:error:", as: ((String) throws -> Void).self)
        runtimeName = try runtime.resolveObjCMethodAndWait(
            on: simRuntime, selector: "name", as: (() -> String?).self)
        platformIdentifier = try runtime.resolveObjCMethodAndWait(
            on: simRuntime, selector: "platformIdentifier", as: (() -> String?).self)
        runtimeVersion = try runtime.resolveObjCMethodAndWait(
            on: simRuntime, selector: "version", as: (() -> UInt32).self)
        productFamily = try runtime.resolveObjCMethodAndWait(
            on: simDeviceType, selector: "productFamilyID", as: (() -> Int32).self)
    }
}

/// A CoreSimulator device with the properties read when its device set was scanned.
@MainActor
final class SimulatorDevice {
    /// The `SimDevice` object.
    let object: AnyObject
    let identifier: String
    let name: String
    let runtimeName: String
    let platformIdentifier: String
    /// `SimDeviceType.productFamilyID`: 1 iPhone, 2 iPad, 3 TV, 4 Watch, 7 Vision.
    let productFamily: Int
    /// `SimRuntime.version`, packed as major << 16 | minor << 8 | patch.
    let runtimeVersion: UInt32
    private let interface: CoreSimulatorInterface

    fileprivate init?(_ object: AnyObject, interface: CoreSimulatorInterface) throws {
        guard let identifier = try unsafe interface.identifier.unsafeInvoke(on: object) else { return nil }
        self.object = object
        self.interface = interface
        self.identifier = identifier.uuidString
        name = try unsafe interface.name.unsafeInvoke(on: object) ?? "iOS Simulator"
        let runtime = try unsafe interface.deviceRuntime.unsafeInvoke(on: object)
        runtimeName = try runtime.flatMap { try unsafe interface.runtimeName.unsafeInvoke(on: $0) } ?? "iOS"
        platformIdentifier =
            try runtime.flatMap { try unsafe interface.platformIdentifier.unsafeInvoke(on: $0) } ?? ""
        runtimeVersion = try runtime.map { try unsafe interface.runtimeVersion.unsafeInvoke(on: $0) } ?? 0
        let deviceType = try unsafe interface.deviceType.unsafeInvoke(on: object)
        productFamily = Int(try deviceType.map { try unsafe interface.productFamily.unsafeInvoke(on: $0) } ?? 0)
    }

    /// `SimDeviceState`; 3 is Booted. A device whose state cannot be read is
    /// treated as shut down.
    var state: UInt { (try? unsafe interface.state.unsafeInvoke(on: object)) ?? 0 }

    func supportsFeature(_ feature: String) -> Bool {
        (try? unsafe interface.supportsFeature.unsafeInvoke(on: object, feature)) ?? false
    }

    func toggleAppearance() throws {
        let style = try unsafe interface.interfaceStyle.unsafeInvoke(on: object)
        try unsafe interface.setInterfaceStyle.unsafeInvoke(on: object, style == 2 ? 1 : 2)
    }

    func shake() throws {
        try unsafe interface.postDarwinNotification.unsafeInvoke(on: object, "com.apple.UIKit.SimulatorShake")
    }
}

/// The default CoreSimulator device set of one developer directory.
@MainActor
final class SimulatorDeviceSet {
    private let object: AnyObject
    private let interface: CoreSimulatorInterface

    init(interface: CoreSimulatorInterface, developerDirectory: String) throws {
        self.interface = interface
        let context = try unsafe interface.sharedContext.unsafeInvoke(
            on: interface.serviceClass as AnyObject, developerDirectory)
        object = try unsafe interface.defaultDeviceSet.unsafeInvoke(on: context)
        try unsafe interface.subscribe.unsafeInvoke(on: object)
    }

    func readDevices() throws -> [SimulatorDevice] {
        try unsafe interface.availableDevices.unsafeInvoke(on: object).compactMap {
            try SimulatorDevice($0, interface: interface)
        }
    }

    /// Calls `handler` on the main queue after each device-set change.
    func observe(_ handler: @escaping @MainActor () -> Void) throws -> UInt64 {
        let block: CoreSimulatorInterface.NotificationHandler = { _ in
            MainActor.assumeIsolated { handler() }
        }
        return try unsafe interface.registerHandler.unsafeInvoke(on: object, DispatchQueue.main, block)
    }

    func stopObserving(_ token: UInt64) throws {
        try unsafe interface.unregisterHandler.unsafeInvoke(on: object, token)
    }
}
