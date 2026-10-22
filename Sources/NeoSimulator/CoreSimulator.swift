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
    /// `lastBootedAt`, when the device last booted.
    let lastBootedAt: NativeObjCMethod<NSDate?>
    let deviceRuntimeIdentifier: NativeObjCMethod<String?>
    let deviceRuntime: NativeObjCMethod<AnyObject?>
    let deviceType: NativeObjCMethod<AnyObject?>
    let supportsFeature: NativeObjCMethod<Bool, String>
    let interfaceStyle: NativeObjCMethod<Int>
    let setInterfaceStyle: NativeObjCMethod<Void, Int>
    let postDarwinNotification: NativeObjCMethod<Void, String>
    let darwinNotificationState: NativeObjCMethod<Void, UnsafeMutablePointer<UInt64>, String>
    let setDarwinNotificationState: NativeObjCMethod<Void, UInt64, String>
    let contentSizeCategory: NativeObjCMethod<Int>
    let setContentSizeCategory: NativeObjCMethod<Void, Int>
    let increaseContrastMode: NativeObjCMethod<Int>
    let setIncreaseContrast: NativeObjCMethod<Void, Bool>
    let triggerCloudSync: NativeObjCMethod<Void, DispatchQueue, CloudSyncCompletion>
    let logPath: NativeObjCMethod<String?>
    let memoryWarningFilePath: NativeObjCMethod<String?>
    let caDebugOption: NativeObjCMethod<Bool, UInt32>
    let setCADebugOption: NativeObjCMethod<Void, UInt32, Bool>
    /// `dataPath`, the folder of the device's own files.
    let dataPath: NativeObjCMethod<String?>
    /// `enableCarPlay:error:`, a request to the guest's CoreSimulatorBridge.
    let enableCarPlay: NativeObjCMethod<Void, Bool>
    /// An array of dictionaries with `name` and `localizedName` strings, or
    /// nil when the device cannot list them.
    let availableLocationScenarios: NativeObjCMethod<[NSDictionary]?>
    let clearSimulatedLocation: NativeObjCMethod<Void>
    let setLocation: NativeObjCMethod<Void, Double, Double>
    let setLocationScenario: NativeObjCMethod<Void, String>
    /// `setHardwareKeyboardEnabled:keyboardType:error:`, whose type is a byte.
    let setHardwareKeyboard: NativeObjCMethod<Void, Bool, UInt8>
    let setKeyboardLanguage: NativeObjCMethod<Void, String>
    /// `lookup:error:`, a send right to a Mach service of the guest. It
    /// returns a port, which a `throws` signature cannot carry, so the error
    /// slot is explicit.
    let lookup: NativeObjCMethod<UInt32, String, AutoreleasingUnsafeMutablePointer<NSError?>?>
    let runtimeName: NativeObjCMethod<String?>
    let runtimeIdentifier: NativeObjCMethod<String?>
    let runtimeAvailable: NativeObjCMethod<Bool>
    let runtimeSupportsDeviceType: NativeObjCMethod<Bool, AnyObject>
    let platformIdentifier: NativeObjCMethod<String?>
    let runtimeVersion: NativeObjCMethod<UInt32>
    let productFamily: NativeObjCMethod<Int32>
    let deviceTypeName: NativeObjCMethod<String?>
    let framebufferMaskURL: NativeObjCMethod<NSURL?>
    let deviceTypeCapabilities: NativeObjCMethod<NSDictionary?>
    let deviceTypeIdentifier: NativeObjCMethod<String?>
    let mainScreenDPI: NativeObjCMethod<CGSize>
    let mainScreenScale: NativeObjCMethod<Float>

    typealias NotificationHandler = @convention(block) (NSDictionary) -> Void
    typealias CloudSyncCompletion = @convention(block) (NSError?) -> Void

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
        lastBootedAt = try runtime.resolveObjCMethodAndWait(on: device, selector: "lastBootedAt", as: (() -> NSDate?).self)
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
        darwinNotificationState = try runtime.resolveObjCMethodAndWait(
            on: device, selector: "darwinNotificationGetState:name:error:",
            as: ((UnsafeMutablePointer<UInt64>, String) throws -> Void).self)
        setDarwinNotificationState = try runtime.resolveObjCMethodAndWait(
            on: device, selector: "darwinNotificationSetState:name:error:", as: ((UInt64, String) throws -> Void).self)
        contentSizeCategory = try runtime.resolveObjCMethodAndWait(
            on: device, selector: "currentContentSizeCategory", as: (() -> Int).self)
        setContentSizeCategory = try runtime.resolveObjCMethodAndWait(
            on: device, selector: "setContentSizeCategory:error:", as: ((Int) throws -> Void).self)
        increaseContrastMode = try runtime.resolveObjCMethodAndWait(
            on: device, selector: "currentIncreaseContrastMode", as: (() -> Int).self)
        setIncreaseContrast = try runtime.resolveObjCMethodAndWait(
            on: device, selector: "setIncreaseContrastEnabled:error:", as: ((Bool) throws -> Void).self)
        triggerCloudSync = try runtime.resolveObjCMethodAndWait(
            on: device, selector: "triggerCloudSyncWithCompletionQueue:completionHandler:",
            as: ((DispatchQueue, @escaping CloudSyncCompletion) -> Void).self)
        logPath = try runtime.resolveObjCMethodAndWait(on: device, selector: "logPath", as: (() -> String?).self)
        memoryWarningFilePath = try runtime.resolveObjCMethodAndWait(
            on: device, selector: "memoryWarningFilePath", as: (() -> String?).self)
        caDebugOption = try runtime.resolveObjCMethodAndWait(
            on: device, selector: "getCADebugOption:", as: ((UInt32) -> Bool).self)
        setCADebugOption = try runtime.resolveObjCMethodAndWait(
            on: device, selector: "setCADebugOption:enabled:", as: ((UInt32, Bool) -> Void).self)
        dataPath = try runtime.resolveObjCMethodAndWait(on: device, selector: "dataPath", as: (() -> String?).self)
        enableCarPlay = try runtime.resolveObjCMethodAndWait(
            on: device, selector: "enableCarPlay:error:", as: ((Bool) throws -> Void).self)
        availableLocationScenarios = try runtime.resolveObjCMethodAndWait(
            on: device, selector: "availableLocationScenarios", as: (() -> [NSDictionary]?).self)
        clearSimulatedLocation = try runtime.resolveObjCMethodAndWait(
            on: device, selector: "clearSimulatedLocationWithError:", as: (() throws -> Void).self)
        setLocation = try runtime.resolveObjCMethodAndWait(
            on: device, selector: "setLocationWithLatitude:andLongitude:error:", as: ((Double, Double) throws -> Void).self)
        setLocationScenario = try runtime.resolveObjCMethodAndWait(
            on: device, selector: "setLocationScenario:error:", as: ((String) throws -> Void).self)
        setHardwareKeyboard = try runtime.resolveObjCMethodAndWait(
            on: device, selector: "setHardwareKeyboardEnabled:keyboardType:error:", as: ((Bool, UInt8) throws -> Void).self)
        setKeyboardLanguage = try runtime.resolveObjCMethodAndWait(
            on: device, selector: "setKeyboardLanguage:error:", as: ((String) throws -> Void).self)
        lookup = try runtime.resolveObjCMethodAndWait(
            on: device, selector: "lookup:error:",
            as: ((String, AutoreleasingUnsafeMutablePointer<NSError?>?) -> UInt32).self)
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
        framebufferMaskURL = try runtime.resolveObjCMethodAndWait(
            on: simDeviceType, selector: "framebufferMaskURL", as: (() -> NSURL?).self)
        deviceTypeCapabilities = try runtime.resolveObjCMethodAndWait(
            on: simDeviceType, selector: "capabilities", as: (() -> NSDictionary?).self)
        deviceTypeIdentifier = try runtime.resolveObjCMethodAndWait(
            on: simDeviceType, selector: "identifier", as: (() -> String?).self)
        mainScreenDPI = try runtime.resolveObjCMethodAndWait(
            on: simDeviceType, selector: "mainScreenDPI", as: (() -> CGSize).self)
        mainScreenScale = try runtime.resolveObjCMethodAndWait(
            on: simDeviceType, selector: "mainScreenScale", as: (() -> Float).self)
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
    /// Whether the device type has a framebuffer mask, the screen's shape.
    let hasFramebufferMask: Bool
    /// The screen's corner radius in points, from the device type's
    /// `DeviceCornerRadius` capability; 0 for a square screen.
    let screenCornerRadius: Double
    /// The screen's points per inch, `SimDeviceType.mainScreenDPI`'s width
    /// over `mainScreenScale`, or nil without a device type.
    let screenPointsPerInch: Double?
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
        hasFramebufferMask = try deviceType.flatMap { try unsafe interface.framebufferMaskURL.unsafeInvoke(on: $0) } != nil
        let capabilities = try deviceType.flatMap { try unsafe interface.deviceTypeCapabilities.unsafeInvoke(on: $0) }
        screenCornerRadius = ((capabilities?["capabilities"] as? NSDictionary)?["DeviceCornerRadius"] as? NSNumber)?.doubleValue ?? 0
        screenPointsPerInch = try deviceType.map {
            Double(try unsafe interface.mainScreenDPI.unsafeInvoke(on: $0).width)
                / Double(try unsafe interface.mainScreenScale.unsafeInvoke(on: $0))
        }
    }

    /// `SimDeviceState`; 3 is Booted. A device whose state cannot be read is
    /// treated as shut down.
    var state: UInt { (try? unsafe interface.state.unsafeInvoke(on: object)) ?? 0 }

    /// When the device last booted, which tells its boots apart, or nil when
    /// it cannot be read.
    var lastBootDate: Date? { (try? unsafe interface.lastBootedAt.unsafeInvoke(on: object)).flatMap { $0 as Date? } }

    func supportsFeature(_ feature: String) -> Bool {
        (try? unsafe interface.supportsFeature.unsafeInvoke(on: object, feature)) ?? false
    }

    func toggleAppearance() throws {
        let style = try unsafe interface.interfaceStyle.unsafeInvoke(on: object)
        try unsafe interface.setInterfaceStyle.unsafeInvoke(on: object, style == 2 ? 1 : 2)
    }

    func postNotification(_ name: String) throws {
        try unsafe interface.postDarwinNotification.unsafeInvoke(on: object, name)
    }

    func notificationState(_ name: String) throws -> UInt64 {
        var state: UInt64 = 0
        try unsafe withUnsafeMutablePointer(to: &state) {
            try unsafe interface.darwinNotificationState.unsafeInvoke(on: object, $0, name)
        }
        return state
    }

    func setNotificationState(_ name: String, to state: UInt64) throws {
        try unsafe interface.setDarwinNotificationState.unsafeInvoke(on: object, state, name)
    }

    /// `UIContentSizeCategory` as CoreSimulator numbers it: 1 through 12 from
    /// Extra Small to Accessibility XXXL, other values when unknown or unsupported.
    func contentSizeCategory() throws -> Int { try unsafe interface.contentSizeCategory.unsafeInvoke(on: object) }

    func setContentSizeCategory(_ category: Int) throws {
        try unsafe interface.setContentSizeCategory.unsafeInvoke(on: object, category)
    }

    /// 1 when Increase Contrast is off and 2 when it is on; 0 when unknown.
    func increaseContrastMode() throws -> Int { try unsafe interface.increaseContrastMode.unsafeInvoke(on: object) }

    func setIncreaseContrast(_ enabled: Bool) throws {
        try unsafe interface.setIncreaseContrast.unsafeInvoke(on: object, enabled)
    }

    func triggerCloudSync() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let completion: CoreSimulatorInterface.CloudSyncCompletion = { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
            do { try unsafe interface.triggerCloudSync.unsafeInvoke(on: object, .main, completion) }
            catch { continuation.resume(throwing: error) }
        }
    }

    /// The folder of the device's logs.
    func logDirectory() throws -> URL {
        guard let path = try unsafe interface.logPath.unsafeInvoke(on: object) else {
            throw HostError.operation("The device did not report its log folder.")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// The file that `SimDevice.simulateMemoryWarning` writes to make the
    /// guest simulate a memory warning.
    func memoryWarningFile() throws -> URL {
        guard let path = try unsafe interface.memoryWarningFilePath.unsafeInvoke(on: object) else {
            throw HostError.operation("The device did not report where to signal a memory warning.")
        }
        return URL(fileURLWithPath: path)
    }

    /// `<dataPath>/Library/Application Support/Simulator/extended_display.plist`,
    /// the device's external display configuration. CoreSimulator gives the
    /// guest its path, and the guest reads it each time the TVOut screen's
    /// modes change: with `stark` on, it takes that screen as a car's display.
    func extendedDisplayFile() throws -> URL {
        guard let path = try unsafe interface.dataPath.unsafeInvoke(on: object) else {
            throw HostError.operation("The device did not report its data folder.")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
            .appendingPathComponent("Library/Application Support/Simulator/extended_display.plist")
    }

    /// Starts or ends a CarPlay session in the guest through its
    /// CoreSimulatorBridge, which counts them: each start needs one end. The
    /// request waits for the guest, so it runs off the main actor, and the
    /// requests reach the guest in the order they are made. A device whose
    /// last boot is no longer `boot` when the request runs gets nothing, and
    /// the request throws `CarPlayRequestMoot`.
    func setCarPlayEnabled(_ enabled: Bool, inBoot boot: Date?) async throws {
        nonisolated(unsafe) let lastBootedAt = interface.lastBootedAt
        try await call(interface.enableCarPlay, on: carPlayQueue) { method, device in
            // A restart between this check and CoreSimulator's delivery of
            // the request cannot be told apart from here.
            guard (try? unsafe lastBootedAt.unsafeInvoke(on: device)).flatMap({ $0 as Date? }) == boot else {
                throw CarPlayRequestMoot()
            }
            try unsafe method.unsafeInvoke(on: device, enabled)
        }
    }

    /// CoreSimulator drops the error of this read, so false can also mean that it failed.
    func caDebugOption(_ option: CADebugOption) throws -> Bool {
        try unsafe interface.caDebugOption.unsafeInvoke(on: object, option.rawValue)
    }

    /// CoreSimulator drops the error of this change; reading the option back
    /// is the only way to learn whether it applied.
    func setCADebugOption(_ option: CADebugOption, enabled: Bool) throws {
        try unsafe interface.setCADebugOption.unsafeInvoke(on: object, option.rawValue, enabled)
    }
    // Right after a boot, CoreSimulator takes up to a second to answer
    // location calls, so they run on this queue, as Simulator.app runs them on
    // a global queue. Being serial, it applies changes in the order they are made.
    private lazy var locationQueue = DispatchQueue(label: "dev.lynnswap.NeoSimulator.location")
    // Changing the keyboard's language takes CoreSimulator up to half a
    // second, so keyboard changes run on this queue, as Simulator.app runs
    // them on a global queue, also in the order they are made.
    private lazy var keyboardQueue = DispatchQueue(label: "dev.lynnswap.NeoSimulator.keyboard")
    private lazy var carPlayQueue = DispatchQueue(label: "dev.lynnswap.NeoSimulator.carplay")

    /// The runtime's recorded location routes in CoreSimulator's order, empty
    /// when the device lists none.
    func locationScenarios() async throws -> [LocationScenario] {
        try await call(interface.availableLocationScenarios, on: locationQueue) { method, device in
            try unsafe method.unsafeInvoke(on: device)?.compactMap { scenario in
                guard let name = scenario["name"] as? String else { return nil }
                return LocationScenario(name: name, localizedName: scenario["localizedName"] as? String ?? name)
            } ?? []
        }
    }

    func clearSimulatedLocation() async throws {
        try await call(interface.clearSimulatedLocation, on: locationQueue) { try unsafe $0.unsafeInvoke(on: $1) }
    }

    func setLocation(latitude: Double, longitude: Double) async throws {
        try await call(interface.setLocation, on: locationQueue) { try unsafe $0.unsafeInvoke(on: $1, latitude, longitude) }
    }

    func setLocationScenario(_ name: String) async throws {
        try await call(interface.setLocationScenario, on: locationQueue) { try unsafe $0.unsafeInvoke(on: $1, name) }
    }

    /// Connects or disconnects the guest's hardware keyboard, of a type that
    /// `IndigoHIDGetKeyboardType()` gives.
    func setHardwareKeyboardEnabled(_ enabled: Bool, keyboardType: UInt8) async throws {
        try await call(interface.setHardwareKeyboard, on: keyboardQueue) {
            try unsafe $0.unsafeInvoke(on: $1, enabled, keyboardType)
        }
    }

    func setKeyboardLanguage(_ language: String) async throws {
        try await call(interface.setKeyboardLanguage, on: keyboardQueue) { try unsafe $0.unsafeInvoke(on: $1, language) }
    }

    /// A send right to the guest's Mach service `name`, which the caller then
    /// owns. CoreSimulator fails while the device is not booted.
    func lookUp(_ name: String) throws -> UInt32 {
        try autoreleasepool {
            // The method stores an autoreleased error, so the slot must not own it.
            let slot = UnsafeMutablePointer<Int>.allocate(capacity: 1)
            defer { slot.deallocate() }
            unsafe slot.initialize(to: 0)
            let error = unsafe AutoreleasingUnsafeMutablePointer<NSError?>(slot)
            let port = try unsafe interface.lookup.unsafeInvoke(on: object, name, error)
            // MACH_PORT_NULL and MACH_PORT_DEAD are not rights.
            guard port != 0, port != UInt32.max else {
                throw unsafe error.pointee ?? HostError.operation("The device did not provide \(name).")
            }
            return port
        }
    }

    /// Sends `method` to the device on `queue`, queued before this suspends.
    /// SimDevice takes these calls on any thread, as Simulator.app makes them,
    /// and a prepared message can be sent from any thread.
    private func call<Method, Value: Sendable>(
        _ method: Method, on queue: DispatchQueue, _ call: @escaping @Sendable (Method, AnyObject) throws -> Value
    ) async throws -> Value {
        nonisolated(unsafe) let method = method, device = object
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try call(method, device) }) }
        }
    }
}

/// A recorded location route of a device's runtime, such as City Run.
struct LocationScenario: Equatable {
    /// The name that identifies the scenario to CoreSimulator.
    let name: String
    /// The title Features ▸ Location shows.
    let localizedName: String
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

/// CoreSimulator's GPU policy for rendering simulator displays: the
/// `FramebufferServerGPUPolicy` array of GPU kinds in the `com.apple.CoreSimulator`
/// defaults, in the order its render server tries them. File ▸ GPU Selection
/// edits it as Simulator.app does.
struct GPUPolicy {
    /// The kind of GPU the policy prefers, apart from an external one.
    enum Preference: String {
        case automatic
        case integrated = "lowPower"
        case discrete
    }

    static let suiteName = "com.apple.CoreSimulator"
    static let key = "FramebufferServerGPUPolicy"
    /// The policy while the key is unset, as Simulator.app reads it.
    static let defaultOrder = ["automatic", "external", "discrete", "lowPower", "headless"]
    private static let external = "external"

    let defaults: UserDefaults

    /// The stored order. Like Simulator.app, a single string is an order of one.
    var order: [String] {
        defaults.stringArray(forKey: Self.key) ?? defaults.string(forKey: Self.key).map { [$0] } ?? Self.defaultOrder
    }

    /// Whether an external GPU comes first.
    var prefersExternal: Bool { order.first == Self.external }

    /// The kind that comes first, after an external GPU.
    var preference: Preference? {
        let order = order
        return (prefersExternal ? order.dropFirst().first : order.first).flatMap(Preference.init(rawValue:))
    }

    func prefer(_ preference: Preference) { store(preference, external: prefersExternal) }

    func togglePrefersExternal() { store(preference, external: !prefersExternal) }

    /// Simulator.app replaces the whole order: the preferred kinds, with the
    /// external GPU first when it is preferred and last otherwise. Other kinds,
    /// such as `headless`, are dropped.
    private func store(_ preference: Preference?, external: Bool) {
        let kinds = switch preference {
        case .automatic: ["automatic"]
        case .integrated: ["lowPower", "discrete"]
        case .discrete: ["discrete", "lowPower"]
        case nil: [String]()
        }
        defaults.set(external ? [Self.external] + kinds : kinds + [Self.external], forKey: Self.key)
    }
}
