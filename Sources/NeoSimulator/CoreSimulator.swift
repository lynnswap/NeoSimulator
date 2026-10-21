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
    let deviceSetWithPath: NativeObjCMethod<AnyObject, String>
    let setPath: NativeObjCMethod<String?>
    let supportedDeviceTypes: NativeObjCMethod<[AnyObject]>
    let supportedRuntimes: NativeObjCMethod<[AnyObject]>
    let subscribe: NativeObjCMethod<Void>
    let availableDevices: NativeObjCMethod<[AnyObject]>
    let registerHandler: NativeObjCMethod<UInt64, DispatchQueue, NotificationHandler>
    let unregisterHandler: NativeObjCMethod<Void, UInt64>
    let state: NativeObjCMethod<UInt>
    let name: NativeObjCMethod<String?>
    let descriptiveName: NativeObjCMethod<String?>
    let identifier: NativeObjCMethod<NSUUID?>
    let deviceRuntimeIdentifier: NativeObjCMethod<String?>
    let deviceRuntime: NativeObjCMethod<AnyObject?>
    let deviceType: NativeObjCMethod<AnyObject?>
    let supportsFeature: NativeObjCMethod<Bool, String>
    let interfaceStyle: NativeObjCMethod<Int>
    let setInterfaceStyle: NativeObjCMethod<Void, Int>
    let postDarwinNotification: NativeObjCMethod<Void, String>
    let runtimeName: NativeObjCMethod<String?>
    let runtimeIdentifier: NativeObjCMethod<String?>
    let runtimeAvailable: NativeObjCMethod<Bool>
    let runtimeSupportsDeviceType: NativeObjCMethod<Bool, AnyObject>
    let platformIdentifier: NativeObjCMethod<String?>
    let runtimeVersion: NativeObjCMethod<UInt32>
    let productFamily: NativeObjCMethod<Int32>
    let deviceTypeName: NativeObjCMethod<String?>
    let deviceTypeIdentifier: NativeObjCMethod<String?>

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
        deviceSetWithPath = try runtime.resolveObjCMethodAndWait(
            on: serviceClass, selector: "deviceSetWithPath:error:", as: ((String) throws -> AnyObject).self)
        setPath = try runtime.resolveObjCMethodAndWait(on: deviceSet, selector: "setPath", as: (() -> String?).self)
        supportedDeviceTypes = try runtime.resolveObjCMethodAndWait(
            on: serviceClass, selector: "supportedDeviceTypes", as: (() -> [AnyObject]).self)
        supportedRuntimes = try runtime.resolveObjCMethodAndWait(
            on: serviceClass, selector: "supportedRuntimes", as: (() -> [AnyObject]).self)
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
        descriptiveName = try runtime.resolveObjCMethodAndWait(
            on: device, selector: "descriptiveName", as: (() -> String?).self)
        identifier = try runtime.resolveObjCMethodAndWait(on: device, selector: "UDID", as: (() -> NSUUID?).self)
        deviceRuntimeIdentifier = try runtime.resolveObjCMethodAndWait(
            on: device, selector: "runtimeIdentifier", as: (() -> String?).self)
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
        runtimeIdentifier = try runtime.resolveObjCMethodAndWait(
            on: simRuntime, selector: "identifier", as: (() -> String?).self)
        runtimeAvailable = try runtime.resolveObjCMethodAndWait(
            on: simRuntime, selector: "available", as: (() -> Bool).self)
        runtimeSupportsDeviceType = try runtime.resolveObjCMethodAndWait(
            on: simRuntime, selector: "supportsDeviceType:", as: ((AnyObject) -> Bool).self)
        platformIdentifier = try runtime.resolveObjCMethodAndWait(
            on: simRuntime, selector: "platformIdentifier", as: (() -> String?).self)
        runtimeVersion = try runtime.resolveObjCMethodAndWait(
            on: simRuntime, selector: "version", as: (() -> UInt32).self)
        productFamily = try runtime.resolveObjCMethodAndWait(
            on: simDeviceType, selector: "productFamilyID", as: (() -> Int32).self)
        deviceTypeName = try runtime.resolveObjCMethodAndWait(
            on: simDeviceType, selector: "name", as: (() -> String?).self)
        deviceTypeIdentifier = try runtime.resolveObjCMethodAndWait(
            on: simDeviceType, selector: "identifier", as: (() -> String?).self)
    }
}

/// A CoreSimulator device with the properties read when its device set was scanned.
@MainActor
final class SimulatorDevice {
    /// The `SimDevice` object.
    let object: AnyObject
    let identifier: String
    let name: String
    /// The runtime, its build, and the device type, such as
    /// "iOS 27.0 (24A434) - iPhone 17 Pro". Simulator.app shows it in File ▸
    /// Open Simulator while Option is held.
    let descriptiveName: String
    let runtimeIdentifier: String
    let runtimeName: String
    let platformIdentifier: String
    /// `SimDeviceType.productFamilyID`: 1 iPhone, 2 iPad, 3 TV, 4 Watch, 7 Vision.
    let productFamily: Int
    let deviceTypeName: String
    /// `SimRuntime.version`, packed as major << 16 | minor << 8 | patch.
    let runtimeVersion: UInt32
    /// The path of the device's set, or nil for the default set.
    let deviceSetPath: String?
    private let interface: CoreSimulatorInterface

    fileprivate init?(_ object: AnyObject, deviceSetPath: String?, interface: CoreSimulatorInterface) throws {
        guard let identifier = try unsafe interface.identifier.unsafeInvoke(on: object) else { return nil }
        self.object = object
        self.deviceSetPath = deviceSetPath
        self.interface = interface
        self.identifier = identifier.uuidString
        name = try unsafe interface.name.unsafeInvoke(on: object) ?? "iOS Simulator"
        descriptiveName = try unsafe interface.descriptiveName.unsafeInvoke(on: object) ?? name
        runtimeIdentifier = try unsafe interface.deviceRuntimeIdentifier.unsafeInvoke(on: object) ?? ""
        let runtime = try unsafe interface.deviceRuntime.unsafeInvoke(on: object)
        runtimeName = try runtime.flatMap { try unsafe interface.runtimeName.unsafeInvoke(on: $0) } ?? "iOS"
        platformIdentifier =
            try runtime.flatMap { try unsafe interface.platformIdentifier.unsafeInvoke(on: $0) } ?? ""
        runtimeVersion = try runtime.map { try unsafe interface.runtimeVersion.unsafeInvoke(on: $0) } ?? 0
        let deviceType = try unsafe interface.deviceType.unsafeInvoke(on: object)
        productFamily = Int(try deviceType.map { try unsafe interface.productFamily.unsafeInvoke(on: $0) } ?? 0)
        deviceTypeName = try deviceType.flatMap { try unsafe interface.deviceTypeName.unsafeInvoke(on: $0) } ?? ""
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

/// The device types and runtimes that File ▸ New Simulator… offers, in
/// CoreSimulator's order.
struct SimulatorCatalog {
    struct DeviceType: Equatable {
        let identifier: String
        let name: String
        /// `productFamilyID`, as in `SimulatorDevice.productFamily`.
        let productFamily: Int
    }

    struct Runtime: Equatable {
        let identifier: String
        let name: String
    }

    let deviceTypes: [DeviceType]
    /// The available runtimes.
    let runtimes: [Runtime]
    /// The device types each runtime supports, by identifier.
    let supportedDeviceTypes: [String: Set<String>]

    func runtime(_ runtime: String, supports deviceType: String) -> Bool {
        supportedDeviceTypes[runtime]?.contains(deviceType) == true
    }
}

/// A CoreSimulator device set of one developer directory: the default set,
/// or a set at another path such as Xcode's parallel testing devices.
@MainActor
final class SimulatorDeviceSet {
    /// The set's directory.
    let path: String
    /// The path tools need to address this set's devices, or nil for the default set.
    let toolPath: String?
    private let context: AnyObject
    private let object: AnyObject
    private let interface: CoreSimulatorInterface

    init(interface: CoreSimulatorInterface, developerDirectory: String, path: String? = nil) throws {
        self.interface = interface
        context = try unsafe interface.sharedContext.unsafeInvoke(
            on: interface.serviceClass as AnyObject, developerDirectory)
        if let path {
            object = try unsafe interface.deviceSetWithPath.unsafeInvoke(on: context, path)
        } else {
            object = try unsafe interface.defaultDeviceSet.unsafeInvoke(on: context)
        }
        self.path = try unsafe interface.setPath.unsafeInvoke(on: object) ?? path ?? ""
        toolPath = path == nil ? nil : self.path
        try unsafe interface.subscribe.unsafeInvoke(on: object)
    }

    func readCatalog() throws -> SimulatorCatalog {
        var deviceTypes: [(object: AnyObject, type: SimulatorCatalog.DeviceType)] = []
        for object in try unsafe interface.supportedDeviceTypes.unsafeInvoke(on: context) {
            guard let identifier = try unsafe interface.deviceTypeIdentifier.unsafeInvoke(on: object) else { continue }
            deviceTypes.append((object, SimulatorCatalog.DeviceType(
                identifier: identifier,
                name: try unsafe interface.deviceTypeName.unsafeInvoke(on: object) ?? identifier,
                productFamily: Int(try unsafe interface.productFamily.unsafeInvoke(on: object)))))
        }
        var runtimes: [SimulatorCatalog.Runtime] = []
        var supported: [String: Set<String>] = [:]
        for object in try unsafe interface.supportedRuntimes.unsafeInvoke(on: context) {
            guard try unsafe interface.runtimeAvailable.unsafeInvoke(on: object),
                  let identifier = try unsafe interface.runtimeIdentifier.unsafeInvoke(on: object) else { continue }
            runtimes.append(SimulatorCatalog.Runtime(
                identifier: identifier, name: try unsafe interface.runtimeName.unsafeInvoke(on: object) ?? identifier))
            supported[identifier] = Set(try deviceTypes.filter {
                try unsafe interface.runtimeSupportsDeviceType.unsafeInvoke(on: object, $0.object)
            }.map(\.type.identifier))
        }
        return SimulatorCatalog(deviceTypes: deviceTypes.map(\.type), runtimes: runtimes,
                                supportedDeviceTypes: supported)
    }

    /// The set's available devices in CoreSimulator's order: by runtime, then
    /// device type, then name.
    func readDevices() throws -> [SimulatorDevice] {
        try unsafe interface.availableDevices.unsafeInvoke(on: object).compactMap {
            try SimulatorDevice($0, deviceSetPath: toolPath, interface: interface)
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
