import ABIBridge
import Foundation
import ObjectiveC

/// A simulator belongs to one device set; a UDID alone is not a session key.
public struct SimulatorDeviceIdentifier: Hashable, Codable, Sendable, Comparable {
    public let identifier: String
    public let deviceSetPath: String?
    public init(_ identifier: String, deviceSetPath: String? = nil) {
        self.identifier = identifier
        self.deviceSetPath = deviceSetPath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path }
    }
    package var queryItems: [URLQueryItem] {
        [URLQueryItem(name: "udid", value: identifier)]
            + (deviceSetPath.map { [URLQueryItem(name: "deviceSetPath", value: $0)] } ?? [])
    }
    package var preferenceIdentifier: String {
        guard let path = deviceSetPath else { return identifier }
        return "set:\(path.utf8.count):\(path):\(identifier)"
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.preferenceIdentifier < rhs.preferenceIdentifier }
}

package struct AvailableDevice: Identifiable {
    package let identifier: String
    package let deviceSetPath: String?
    package var identity: SimulatorDeviceIdentifier { SimulatorDeviceIdentifier(identifier, deviceSetPath: deviceSetPath) }
    package let name: String
    package let descriptiveName: String
    package let runtimeIdentifier: String
    package let runtimeName: String
    /// `SimDeviceType.productFamilyID`, as in `SimulatorDevice.productFamily`.
    package let productFamily: Int
    package let deviceTypeName: String
    package var state: UInt
    package var id: String { identifier }
    package var isBooted: Bool { state == 3 }
    /// The SF Symbol of the device's product family.
    package var symbolName: String {
        switch DeviceCapabilities.Family(rawValue: productFamily) {
        case .iPad: "ipad"
        case .tv: "appletv"
        case .watch: "applewatch"
        case .vision: "visionpro"
        case .iPhone, nil: "iphone"
        }
    }
    package var canOpen: Bool { state == 1 || state == 3 }
    package var stateLabel: String {
        switch state {
        case 1: "Shut Down"
        case 2: "Starting…"
        case 3: "Running"
        case 4: "Shutting Down…"
        default: "Unavailable"
        }
    }

    package init(identifier: String, name: String, descriptiveName: String, runtimeIdentifier: String,
         runtimeName: String, productFamily: Int, deviceTypeName: String, state: UInt, deviceSetPath: String? = nil) {
        self.identifier = identifier
        self.deviceSetPath = deviceSetPath
        self.name = name
        self.descriptiveName = descriptiveName
        self.runtimeIdentifier = runtimeIdentifier
        self.runtimeName = runtimeName
        self.productFamily = productFamily
        self.deviceTypeName = deviceTypeName
        self.state = state
    }
}

/// Prepared CoreSimulator messages. NSError-out failures and Objective-C exceptions
/// are surfaced as Swift errors.
@MainActor
package struct CoreSimulatorInterface {
    package let serviceClass: AnyClass
    package let sharedContext: NativeObjCMethod<AnyObject, String>
    package let defaultDeviceSet: NativeObjCMethod<AnyObject>
    package let deviceSetWithPath: NativeObjCMethod<AnyObject, String>
    package let setPath: NativeObjCMethod<String?>
    package let supportedDeviceTypes: NativeObjCMethod<[AnyObject]>
    package let supportedRuntimes: NativeObjCMethod<[AnyObject]>
    package let subscribe: NativeObjCMethod<Void>
    package let availableDevices: NativeObjCMethod<[AnyObject]>
    package let registerHandler: NativeObjCMethod<UInt64, DispatchQueue, NotificationHandler>
    package let unregisterHandler: NativeObjCMethod<Void, UInt64>
    package let state: NativeObjCMethod<UInt>
    package let name: NativeObjCMethod<String?>
    package let descriptiveName: NativeObjCMethod<String?>
    package let identifier: NativeObjCMethod<NSUUID?>
    package let lastBootedAt: NativeObjCMethod<NSDate?>
    package let deviceRuntimeIdentifier: NativeObjCMethod<String?>
    package let deviceRuntime: NativeObjCMethod<AnyObject?>
    package let deviceType: NativeObjCMethod<AnyObject?>
    package let supportsFeature: NativeObjCMethod<Bool, String>
    package let interfaceStyle: NativeObjCMethod<Int>
    package let setInterfaceStyle: NativeObjCMethod<Void, Int>
    package let postDarwinNotification: NativeObjCMethod<Void, String>
    package let darwinNotificationState: NativeObjCMethod<Void, UnsafeMutablePointer<UInt64>, String>
    package let setDarwinNotificationState: NativeObjCMethod<Void, UInt64, String>
    package let contentSizeCategory: NativeObjCMethod<Int>
    package let setContentSizeCategory: NativeObjCMethod<Void, Int>
    package let increaseContrastMode: NativeObjCMethod<Int>
    package let setIncreaseContrast: NativeObjCMethod<Void, Bool>
    package let triggerCloudSync: NativeObjCMethod<Void, DispatchQueue, CloudSyncCompletion>
    package let logPath: NativeObjCMethod<String?>
    package let memoryWarningFilePath: NativeObjCMethod<String?>
    package let caDebugOption: NativeObjCMethod<Bool, UInt32>
    package let setCADebugOption: NativeObjCMethod<Void, UInt32, Bool>
    package let dataPath: NativeObjCMethod<String?>
    /// Requests the guest's counted CarPlay session through CoreSimulatorBridge.
    package let enableCarPlay: NativeObjCMethod<Void, Bool>
    /// Scenario dictionaries with name and localizedName, or nil if unavailable.
    package let availableLocationScenarios: NativeObjCMethod<[NSDictionary]?>
    package let clearSimulatedLocation: NativeObjCMethod<Void>
    package let setLocation: NativeObjCMethod<Void, Double, Double>
    package let setLocationScenario: NativeObjCMethod<Void, String>
    /// The private keyboardType parameter is one byte.
    package let setHardwareKeyboard: NativeObjCMethod<Void, Bool, UInt8>
    package let setKeyboardLanguage: NativeObjCMethod<Void, String>
    /// The lookup:error: return is a Mach port, so its error slot must be passed explicitly.
    package let lookup: NativeObjCMethod<UInt32, String, AutoreleasingUnsafeMutablePointer<NSError?>?>
    package let runtimeName: NativeObjCMethod<String?>
    package let runtimeIdentifier: NativeObjCMethod<String?>
    package let systemRuntime: NativeObjCMethod<AnyObject?, String>
    package let runtimeBuildVersion: NativeObjCMethod<String?>
    package let runtimeAvailable: NativeObjCMethod<Bool>
    package let runtimeSupportsDeviceType: NativeObjCMethod<Bool, AnyObject>
    package let runtimeVersion: NativeObjCMethod<UInt32>
    package let productFamily: NativeObjCMethod<Int32>
    package let deviceTypeName: NativeObjCMethod<String?>
    package let framebufferMaskURL: NativeObjCMethod<NSURL?>
    package let deviceTypeCapabilities: NativeObjCMethod<NSDictionary?>
    package let deviceTypeIdentifier: NativeObjCMethod<String?>
    package let mainScreenDPI: NativeObjCMethod<CGSize>
    package let mainScreenScale: NativeObjCMethod<Float>
    package let userInterfaceIdentifier: NativeObjCMethod<String?>
    package let devicePairClass: AnyClass
    /// CoreSimulator pairing validation takes the watch type/runtime before the phone.
    package let testPossiblePairing: NativeObjCMethod<Void, AnyObject, AnyObject, AnyObject, AnyObject>

    package typealias NotificationHandler = @convention(block) (NSDictionary) -> Void
    package typealias CloudSyncCompletion = @convention(block) (NSError?) -> Void

    package init(runtime: ABIRuntime) async throws {
        func requireClass(_ name: String) throws -> AnyClass {
            guard let type = NSClassFromString(name) else {
                throw SimulatorError.unavailable("Required private class \(name) is unavailable")
            }
            return type
        }
        serviceClass = try requireClass("SimServiceContext")
        let deviceSet: AnyClass = try requireClass("SimDeviceSet")
        let device: AnyClass = try requireClass("SimDevice")
        let simRuntime: AnyClass = try requireClass("SimRuntime")
        let simDeviceType: AnyClass = try requireClass("SimDeviceType")
        sharedContext = try await runtime.resolve(
            .objc(.method("sharedServiceContextForDeveloperDir:error:", as: ((String) throws -> AnyObject).self)),
            on: serviceClass, classMethod: true)
        defaultDeviceSet = try await runtime.resolve(
            .objc(.method("defaultDeviceSetWithError:", as: (() throws -> AnyObject).self)),
            on: serviceClass)
        deviceSetWithPath = try await runtime.resolve(
            .objc(.method("deviceSetWithPath:error:", as: ((String) throws -> AnyObject).self)),
            on: serviceClass)
        setPath = try await runtime.resolve(.objc(.method("setPath", as: (() -> String?).self)), on: deviceSet)
        supportedDeviceTypes = try await runtime.resolve(
            .objc(.method("supportedDeviceTypes", as: (() -> [AnyObject]).self)),
            on: serviceClass)
        supportedRuntimes = try await runtime.resolve(
            .objc(.method("supportedRuntimes", as: (() -> [AnyObject]).self)),
            on: serviceClass)
        subscribe = try await runtime.resolve(
            .objc(.method("subscribeToNotificationsWithError:", as: (() throws -> Void).self)),
            on: deviceSet)
        availableDevices = try await runtime.resolve(
            .objc(.method("availableDevices", as: (() -> [AnyObject]).self)),
            on: deviceSet)
        registerHandler = try await runtime.resolve(
            .objc(.method("registerNotificationHandlerOnQueue:handler:",
                as: ((DispatchQueue, @escaping NotificationHandler) -> UInt64).self)),
            on: deviceSet)
        unregisterHandler = try await runtime.resolve(
            .objc(.method("unregisterNotificationHandler:error:", as: ((UInt64) throws -> Void).self)),
            on: deviceSet)
        state = try await runtime.resolve(.objc(.method("state", as: (() -> UInt).self)), on: device)
        name = try await runtime.resolve(.objc(.method("name", as: (() -> String?).self)), on: device)
        descriptiveName = try await runtime.resolve(
            .objc(.method("descriptiveName", as: (() -> String?).self)),
            on: device)
        identifier = try await runtime.resolve(.objc(.method("UDID", as: (() -> NSUUID?).self)), on: device)
        lastBootedAt = try await runtime.resolve(.objc(.method("lastBootedAt", as: (() -> NSDate?).self)), on: device)
        deviceRuntimeIdentifier = try await runtime.resolve(
            .objc(.method("runtimeIdentifier", as: (() -> String?).self)),
            on: device)
        deviceRuntime = try await runtime.resolve(
            .objc(.method("runtime", as: (() -> AnyObject?).self)),
            on: device)
        deviceType = try await runtime.resolve(
            .objc(.method("deviceType", as: (() -> AnyObject?).self)),
            on: device)
        supportsFeature = try await runtime.resolve(
            .objc(.method("supportsFeature:", as: ((String) -> Bool).self)),
            on: device)
        interfaceStyle = try await runtime.resolve(
            .objc(.method("currentUIInterfaceStyle", as: (() -> Int).self)),
            on: device)
        setInterfaceStyle = try await runtime.resolve(
            .objc(.method("setUIInterfaceStyle:error:", as: ((Int) throws -> Void).self)),
            on: device)
        postDarwinNotification = try await runtime.resolve(
            .objc(.method("postDarwinNotification:error:", as: ((String) throws -> Void).self)),
            on: device)
        darwinNotificationState = try await runtime.resolve(
            .objc(.method("darwinNotificationGetState:name:error:",
                as: ((UnsafeMutablePointer<UInt64>, String) throws -> Void).self)),
            on: device)
        setDarwinNotificationState = try await runtime.resolve(
            .objc(.method("darwinNotificationSetState:name:error:", as: ((UInt64, String) throws -> Void).self)),
            on: device)
        contentSizeCategory = try await runtime.resolve(
            .objc(.method("currentContentSizeCategory", as: (() -> Int).self)),
            on: device)
        setContentSizeCategory = try await runtime.resolve(
            .objc(.method("setContentSizeCategory:error:", as: ((Int) throws -> Void).self)),
            on: device)
        increaseContrastMode = try await runtime.resolve(
            .objc(.method("currentIncreaseContrastMode", as: (() -> Int).self)),
            on: device)
        setIncreaseContrast = try await runtime.resolve(
            .objc(.method("setIncreaseContrastEnabled:error:", as: ((Bool) throws -> Void).self)),
            on: device)
        triggerCloudSync = try await runtime.resolve(
            .objc(.method("triggerCloudSyncWithCompletionQueue:completionHandler:",
                as: ((DispatchQueue, @escaping CloudSyncCompletion) -> Void).self)),
            on: device)
        logPath = try await runtime.resolve(.objc(.method("logPath", as: (() -> String?).self)), on: device)
        memoryWarningFilePath = try await runtime.resolve(
            .objc(.method("memoryWarningFilePath", as: (() -> String?).self)),
            on: device)
        caDebugOption = try await runtime.resolve(
            .objc(.method("getCADebugOption:", as: ((UInt32) -> Bool).self)),
            on: device)
        setCADebugOption = try await runtime.resolve(
            .objc(.method("setCADebugOption:enabled:", as: ((UInt32, Bool) -> Void).self)),
            on: device)
        dataPath = try await runtime.resolve(.objc(.method("dataPath", as: (() -> String?).self)), on: device)
        enableCarPlay = try await runtime.resolve(
            .objc(.method("enableCarPlay:error:", as: ((Bool) throws -> Void).self)),
            on: device)
        availableLocationScenarios = try await runtime.resolve(
            .objc(.method("availableLocationScenarios", as: (() -> [NSDictionary]?).self)),
            on: device)
        clearSimulatedLocation = try await runtime.resolve(
            .objc(.method("clearSimulatedLocationWithError:", as: (() throws -> Void).self)),
            on: device)
        setLocation = try await runtime.resolve(
            .objc(.method("setLocationWithLatitude:andLongitude:error:", as: ((Double, Double) throws -> Void).self)),
            on: device)
        setLocationScenario = try await runtime.resolve(
            .objc(.method("setLocationScenario:error:", as: ((String) throws -> Void).self)),
            on: device)
        setHardwareKeyboard = try await runtime.resolve(
            .objc(.method("setHardwareKeyboardEnabled:keyboardType:error:", as: ((Bool, UInt8) throws -> Void).self)),
            on: device)
        setKeyboardLanguage = try await runtime.resolve(
            .objc(.method("setKeyboardLanguage:error:", as: ((String) throws -> Void).self)),
            on: device)
        lookup = try await runtime.resolve(
            .objc(.method("lookup:error:", as: ((String, AutoreleasingUnsafeMutablePointer<NSError?>?) -> UInt32).self)),
            on: device)
        runtimeName = try await runtime.resolve(
            .objc(.method("name", as: (() -> String?).self)),
            on: simRuntime)
        runtimeIdentifier = try await runtime.resolve(
            .objc(.method("identifier", as: (() -> String?).self)),
            on: simRuntime)
        systemRuntime = try await runtime.resolve(
            .objc(.method("_runtimeMatchingSystemPolicyForIdentifier:", as: ((String) -> AnyObject?).self)),
            on: serviceClass)
        runtimeBuildVersion = try await runtime.resolve(
            .objc(.method("buildVersionString", as: (() -> String?).self)),
            on: simRuntime)
        runtimeAvailable = try await runtime.resolve(
            .objc(.method("available", as: (() -> Bool).self)),
            on: simRuntime)
        runtimeSupportsDeviceType = try await runtime.resolve(
            .objc(.method("supportsDeviceType:", as: ((AnyObject) -> Bool).self)),
            on: simRuntime)
        runtimeVersion = try await runtime.resolve(
            .objc(.method("version", as: (() -> UInt32).self)),
            on: simRuntime)
        productFamily = try await runtime.resolve(
            .objc(.method("productFamilyID", as: (() -> Int32).self)),
            on: simDeviceType)
        deviceTypeName = try await runtime.resolve(
            .objc(.method("name", as: (() -> String?).self)),
            on: simDeviceType)
        framebufferMaskURL = try await runtime.resolve(
            .objc(.method("framebufferMaskURL", as: (() -> NSURL?).self)),
            on: simDeviceType)
        deviceTypeCapabilities = try await runtime.resolve(
            .objc(.method("capabilities", as: (() -> NSDictionary?).self)),
            on: simDeviceType)
        deviceTypeIdentifier = try await runtime.resolve(
            .objc(.method("identifier", as: (() -> String?).self)),
            on: simDeviceType)
        mainScreenDPI = try await runtime.resolve(
            .objc(.method("mainScreenDPI", as: (() -> CGSize).self)),
            on: simDeviceType)
        mainScreenScale = try await runtime.resolve(
            .objc(.method("mainScreenScale", as: (() -> Float).self)),
            on: simDeviceType)
        userInterfaceIdentifier = try await runtime.resolve(
            .objc(.method("userInterfaceIdentifier", as: (() -> String?).self)),
            on: simDeviceType)
        devicePairClass = try requireClass("SimDevicePair")
        testPossiblePairing = try await runtime.resolve(
            .objc(.method("testPossiblePairingWithDeviceTypeA:RuntimeA:DeviceTypeB:RuntimeB:error:",
                as: ((AnyObject, AnyObject, AnyObject, AnyObject) throws -> Void).self)),
            on: devicePairClass, classMethod: true)
    }
}

/// A device with catalog properties captured when its set was scanned.
@MainActor
package final class SimulatorDevice {
    /// The underlying SimDevice.
    package let object: AnyObject
    package let identifier: String
    package let name: String
    /// Runtime, build, and type description shown while Option is held.
    package let descriptiveName: String
    package let runtimeIdentifier: String
    package let runtimeName: String
    /// `SimDeviceType.productFamilyID`: 1 iPhone, 2 iPad, 3 TV, 4 Watch, 7 Vision.
    package let productFamily: Int
    package let deviceTypeName: String
    package let deviceTypeIdentifier: String
    package let hasFramebufferMask: Bool
    /// DeviceCornerRadius in points; zero for a square screen.
    package let screenCornerRadius: Double
    /// DeviceSupportsEnhancedMultitasking capability (Stage Manager).
    package let supportsEnhancedMultitasking: Bool
    /// mainScreenDPI.width / mainScreenScale, or nil without a device type.
    package let screenPointsPerInch: Double?
    /// `SimRuntime.version`, packed as major << 16 | minor << 8 | patch.
    package let runtimeVersion: UInt32
    /// Whether SimulatorKit should load the device type's user-interface profile.
    package let hasUserInterfacePlugin: Bool
    /// Nil denotes the default device set.
    package let deviceSetPath: String?
    package var identity: SimulatorDeviceIdentifier { SimulatorDeviceIdentifier(identifier, deviceSetPath: deviceSetPath) }
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
        runtimeVersion = try runtime.map { try unsafe interface.runtimeVersion.unsafeInvoke(on: $0) } ?? 0
        let deviceType = try unsafe interface.deviceType.unsafeInvoke(on: object)
        productFamily = Int(try deviceType.map { try unsafe interface.productFamily.unsafeInvoke(on: $0) } ?? 0)
        deviceTypeName = try deviceType.flatMap { try unsafe interface.deviceTypeName.unsafeInvoke(on: $0) } ?? ""
        deviceTypeIdentifier = try deviceType.flatMap { try unsafe interface.deviceTypeIdentifier.unsafeInvoke(on: $0) } ?? ""
        hasFramebufferMask = try deviceType.flatMap { try unsafe interface.framebufferMaskURL.unsafeInvoke(on: $0) } != nil
        let capabilities = try deviceType.flatMap { try unsafe interface.deviceTypeCapabilities.unsafeInvoke(on: $0) }
        let deviceCapabilities = capabilities?["capabilities"] as? NSDictionary
        screenCornerRadius = (deviceCapabilities?["DeviceCornerRadius"] as? NSNumber)?.doubleValue ?? 0
        supportsEnhancedMultitasking = deviceCapabilities?["DeviceSupportsEnhancedMultitasking"] as? Bool ?? false
        screenPointsPerInch = try deviceType.map {
            Double(try unsafe interface.mainScreenDPI.unsafeInvoke(on: $0).width)
                / Double(try unsafe interface.mainScreenScale.unsafeInvoke(on: $0))
        }
        hasUserInterfacePlugin =
            try deviceType.flatMap { try unsafe interface.userInterfaceIdentifier.unsafeInvoke(on: $0) } != nil
    }

    /// SimDeviceState; 3 means booted. Read failures are treated as shutdown.
    package var state: UInt { (try? unsafe interface.state.unsafeInvoke(on: object)) ?? 0 }

    /// Identifies a boot; nil if unreadable.
    package var lastBootDate: Date? { (try? unsafe interface.lastBootedAt.unsafeInvoke(on: object)).flatMap { $0 as Date? } }

    package func supportsFeature(_ feature: String) -> Bool {
        (try? unsafe interface.supportsFeature.unsafeInvoke(on: object, feature)) ?? false
    }

    package func toggleAppearance() throws {
        let style = try unsafe interface.interfaceStyle.unsafeInvoke(on: object)
        try unsafe interface.setInterfaceStyle.unsafeInvoke(on: object, style == 2 ? 1 : 2)
    }

    package func postNotification(_ name: String) async throws {
        try await call(interface.postDarwinNotification, on: notificationQueue) {
            try unsafe $0.unsafeInvoke(on: $1, name)
        }
    }

    package func notificationState(_ name: String) throws -> UInt64 {
        var state: UInt64 = 0
        try withUnsafeMutablePointer(to: &state) {
            try unsafe interface.darwinNotificationState.unsafeInvoke(on: object, $0, name)
        }
        return state
    }

    package func setNotificationState(_ name: String, to state: UInt64) async throws {
        try await call(interface.setDarwinNotificationState, on: notificationQueue) {
            try unsafe $0.unsafeInvoke(on: $1, state, name)
        }
    }

    /// CoreSimulator content-size values: 1–12, from Extra Small to Accessibility XXXL.
    package func contentSizeCategory() throws -> Int { try unsafe interface.contentSizeCategory.unsafeInvoke(on: object) }

    package func setContentSizeCategory(_ category: Int) throws {
        try unsafe interface.setContentSizeCategory.unsafeInvoke(on: object, category)
    }

    /// 1 when Increase Contrast is off and 2 when it is on; 0 when unknown.
    package func increaseContrastMode() throws -> Int { try unsafe interface.increaseContrastMode.unsafeInvoke(on: object) }

    package func setIncreaseContrast(_ enabled: Bool) throws {
        try unsafe interface.setIncreaseContrast.unsafeInvoke(on: object, enabled)
    }

    package func triggerCloudSync() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let completion: CoreSimulatorInterface.CloudSyncCompletion = { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
            do { try unsafe interface.triggerCloudSync.unsafeInvoke(on: object, .main, completion) }
            catch { continuation.resume(throwing: error) }
        }
    }

    package func logDirectory() throws -> URL {
        guard let path = try unsafe interface.logPath.unsafeInvoke(on: object) else {
            throw SimulatorError.operation("The device did not report its log folder.")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Guest file used by SimDevice.simulateMemoryWarning.
    package func memoryWarningFile() throws -> URL {
        guard let path = try unsafe interface.memoryWarningFilePath.unsafeInvoke(on: object) else {
            throw SimulatorError.operation("The device did not report where to signal a memory warning.")
        }
        return URL(fileURLWithPath: path)
    }

    /// The guest reads extended_display.plist whenever TVOut modes change.
    /// Its stark flag marks the screen as a CarPlay display.
    package func extendedDisplayFile() throws -> URL {
        guard let path = try unsafe interface.dataPath.unsafeInvoke(on: object) else {
            throw SimulatorError.operation("The device did not report its data folder.")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
            .appendingPathComponent("Library/Application Support/Simulator/extended_display.plist")
    }

    /// Sends a counted CarPlay request serially off the main actor; each start needs one end.
    /// Throws CarPlayRequestMoot if the device is no longer in `boot` when the request runs.
    package func setCarPlayEnabled(_ enabled: Bool, inBoot boot: Date?) async throws {
        nonisolated(unsafe) let lastBootedAt = interface.lastBootedAt
        try await call(interface.enableCarPlay, on: carPlayQueue) { method, device in
            // A restart between this check and guest delivery cannot be detected here.
            guard (try? unsafe lastBootedAt.unsafeInvoke(on: device)).flatMap({ $0 as Date? }) == boot else {
                throw CarPlayRequestMoot()
            }
            try unsafe method.unsafeInvoke(on: device, enabled)
        }
    }

    /// CoreSimulator drops the error of this read, so false can also mean that it failed.
    package func caDebugOption(_ option: CADebugOption) throws -> Bool {
        try unsafe interface.caDebugOption.unsafeInvoke(on: object, option.rawValue)
    }

    /// CoreSimulator drops the error of this change; reading the option back
    /// is the only way to learn whether it applied.
    package func setCADebugOption(_ option: CADebugOption, enabled: Bool) throws {
        try unsafe interface.setCADebugOption.unsafeInvoke(on: object, option.rawValue, enabled)
    }
    // Location calls can block after boot; serialize them off the main actor to preserve order.
    private lazy var locationQueue = DispatchQueue(label: "dev.lynnswap.NeoSimulator.location")
    // Keyboard-language changes can block; serialize them off the main actor to preserve order.
    private lazy var keyboardQueue = DispatchQueue(label: "dev.lynnswap.NeoSimulator.keyboard")
    // Guest notification IPC can block during boot; keep writes ordered off the main actor.
    private lazy var notificationQueue = DispatchQueue(label: "dev.lynnswap.NeoSimulator.notifications")
    private lazy var carPlayQueue = DispatchQueue(label: "dev.lynnswap.NeoSimulator.carplay")

    /// Recorded routes in runtime order; empty if none are reported.
    package func locationScenarios() async throws -> [LocationScenario] {
        try await call(interface.availableLocationScenarios, on: locationQueue) { method, device in
            try unsafe method.unsafeInvoke(on: device)?.compactMap { scenario in
                guard let name = scenario["name"] as? String else { return nil }
                return LocationScenario(name: name, localizedName: scenario["localizedName"] as? String ?? name)
            } ?? []
        }
    }

    package func clearSimulatedLocation() async throws {
        try await call(interface.clearSimulatedLocation, on: locationQueue) { try unsafe $0.unsafeInvoke(on: $1) }
    }

    package func setLocation(latitude: Double, longitude: Double) async throws {
        try await call(interface.setLocation, on: locationQueue) { try unsafe $0.unsafeInvoke(on: $1, latitude, longitude) }
    }

    package func setLocationScenario(_ name: String) async throws {
        try await call(interface.setLocationScenario, on: locationQueue) { try unsafe $0.unsafeInvoke(on: $1, name) }
    }

    /// Uses the byte-sized keyboard type returned by IndigoHIDGetKeyboardType.
    package func setHardwareKeyboardEnabled(_ enabled: Bool, keyboardType: UInt8) async throws {
        try await call(interface.setHardwareKeyboard, on: keyboardQueue) {
            try unsafe $0.unsafeInvoke(on: $1, enabled, keyboardType)
        }
    }

    package func setKeyboardLanguage(_ language: String) async throws {
        try await call(interface.setKeyboardLanguage, on: keyboardQueue) { try unsafe $0.unsafeInvoke(on: $1, language) }
    }

    /// Returns a caller-owned send right. Fails unless the guest is booted.
    package func lookUp(_ name: String) throws -> UInt32 {
        try autoreleasepool {
            // The method stores an autoreleased error, so the slot must not own it.
            let slot = UnsafeMutablePointer<Int>.allocate(capacity: 1)
            defer { slot.deallocate() }
            unsafe slot.initialize(to: 0)
            let error = unsafe AutoreleasingUnsafeMutablePointer<NSError?>(slot)
            let port = try unsafe interface.lookup.unsafeInvoke(on: object, name, error)
            // MACH_PORT_NULL and MACH_PORT_DEAD are not rights.
            guard port != 0, port != UInt32.max else {
                throw unsafe error.pointee ?? SimulatorError.operation("The device did not provide \(name).")
            }
            return port
        }
    }

    /// Queues before suspending to preserve call order. Prepared messages and SimDevice
    /// support calls from this queue.
    private func call<Method, Value: Sendable>(
        _ method: Method, on queue: DispatchQueue, _ call: @escaping @Sendable (Method, AnyObject) throws -> Value
    ) async throws -> Value {
        nonisolated(unsafe) let method = method, device = object
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try call(method, device) }) }
        }
    }
}

/// Recorded location route supplied by the runtime.
package struct LocationScenario: Equatable {
    /// CoreSimulator identifier.
    package let name: String
    /// Display title.
    package let localizedName: String
}

/// Device set owned by one developer directory.
@MainActor
package final class SimulatorDeviceSet {
    package let path: String
    /// Tool argument; nil for the default device set.
    package let toolPath: String?
    private let context: AnyObject
    private let object: AnyObject
    private let interface: CoreSimulatorInterface

    package init(interface: CoreSimulatorInterface, developerDirectory: String, path: String? = nil) throws {
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

    package func readCatalog() throws -> SimulatorCatalog {
        var deviceTypes: [(object: AnyObject, type: SimulatorCatalog.DeviceType)] = []
        for object in try unsafe interface.supportedDeviceTypes.unsafeInvoke(on: context) {
            guard let identifier = try unsafe interface.deviceTypeIdentifier.unsafeInvoke(on: object) else { continue }
            deviceTypes.append((object, SimulatorCatalog.DeviceType(
                identifier: identifier,
                name: try unsafe interface.deviceTypeName.unsafeInvoke(on: object) ?? identifier,
                productFamily: Int(try unsafe interface.productFamily.unsafeInvoke(on: object)))))
        }
        var runtimes: [SimulatorCatalog.Runtime] = []
        var runtimeObjects: [String: AnyObject] = [:]
        var supported: [String: Set<String>] = [:]
        for runtime in try unsafe interface.supportedRuntimes.unsafeInvoke(on: context) {
            guard let identifier = try unsafe interface.runtimeIdentifier.unsafeInvoke(on: runtime),
                  runtimeObjects[identifier] == nil,
                  let object = try unsafe interface.systemRuntime.unsafeInvoke(on: context, identifier),
                  try unsafe interface.runtimeAvailable.unsafeInvoke(on: object) else { continue }
            // Creation uses the system policy even when simctl receives another build's bundle path.
            runtimes.append(SimulatorCatalog.Runtime(
                identifier: identifier, name: try unsafe interface.runtimeName.unsafeInvoke(on: object) ?? identifier,
                buildVersion: try unsafe interface.runtimeBuildVersion.unsafeInvoke(on: object)))
            runtimeObjects[identifier] = object
            supported[identifier] = Set(try deviceTypes.filter {
                try unsafe interface.runtimeSupportsDeviceType.unsafeInvoke(on: object, $0.object)
            }.map(\.type.identifier))
        }
        let typeObjects = Dictionary(deviceTypes.map { ($0.type.identifier, $0.object) }) { first, _ in first }
        let interface = interface
        return SimulatorCatalog(deviceTypes: deviceTypes.map(\.type), runtimes: runtimes,
                                supportedDeviceTypes: supported) { watchType, watchRuntime, phoneType, phoneRuntime in
            guard let watchType = typeObjects[watchType], let watchRuntime = runtimeObjects[watchRuntime],
                  let phoneType = typeObjects[phoneType], let phoneRuntime = runtimeObjects[phoneRuntime] else {
                return false
            }
            // Pairing validation errors mean the pair is unavailable.
            return (try? unsafe interface.testPossiblePairing.unsafeInvoke(
                on: interface.devicePairClass as AnyObject, watchType, watchRuntime, phoneType, phoneRuntime)) != nil
        }
    }

    /// Available devices ordered by runtime, type, and name.
    package func readDevices() throws -> [SimulatorDevice] {
        try unsafe interface.availableDevices.unsafeInvoke(on: object).compactMap {
            try SimulatorDevice($0, deviceSetPath: toolPath, interface: interface)
        }
    }

    package func observe(_ handler: @escaping @MainActor () -> Void) throws -> UInt64 {
        let block: CoreSimulatorInterface.NotificationHandler = { _ in
            MainActor.assumeIsolated { handler() }
        }
        return try unsafe interface.registerHandler.unsafeInvoke(on: object, DispatchQueue.main, block)
    }

    package func stopObserving(_ token: UInt64) throws {
        try unsafe interface.unregisterHandler.unsafeInvoke(on: object, token)
    }
}

/// Render-server GPU preference order in com.apple.CoreSimulator defaults.
package struct GPUPolicy {
    /// Preferred GPU kind after any leading external GPU.
    package enum Preference: String {
        case automatic
        case integrated = "lowPower"
        case discrete
    }

    package static let suiteName = "com.apple.CoreSimulator"
    package static let key = "FramebufferServerGPUPolicy"
    package static let defaultOrder = ["automatic", "external", "discrete", "lowPower", "headless"]
    private static let external = "external"

    package let defaults: UserDefaults

    package init(defaults: UserDefaults) { self.defaults = defaults }

    /// A single string is accepted as a one-element order.
    package var order: [String] {
        defaults.stringArray(forKey: Self.key) ?? defaults.string(forKey: Self.key).map { [$0] } ?? Self.defaultOrder
    }

    package var prefersExternal: Bool { order.first == Self.external }

    package var preference: Preference? {
        let order = order
        return (prefersExternal ? order.dropFirst().first : order.first).flatMap(Preference.init(rawValue:))
    }

    package func prefer(_ preference: Preference) { store(preference, external: prefersExternal) }

    package func togglePrefersExternal() { store(preference, external: !prefersExternal) }

    /// Replaces the order with the chosen kinds and external GPU; drops others such as headless.
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
