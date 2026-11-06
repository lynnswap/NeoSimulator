import ABIBridge
import Darwin
import Foundation
import NeoSimulatorDeviceIO
import ObjectiveC
import Synchronization
import XPC

/// A simulator belongs to one device set; a UDID alone is not a session key.
public struct SimulatorDeviceIdentifier: Hashable, Codable, Sendable, Comparable {
    public let identifier: String
    public let deviceSetPath: String?
    public init(_ identifier: String, deviceSetPath: String? = nil) {
        self.identifier = identifier
        self.deviceSetPath = deviceSetPath.map(DeviceAddress.normalized(path:))
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

/// Prepared CoreSimulator messages. NSError-out failures and Objective-C exceptions are surfaced as Swift errors. The
/// messages can be sent from any queue, and nearly all of them wait on one of CoreSimulator's queues or on its service, so
/// no Swift job may send them: only a `SimulatorDeviceSet`'s or a `SimulatorDevice`'s worker does.
package struct CoreSimulatorInterface: @unchecked Sendable {
    package let serviceClass: AnyClass
    package let sharedContext: NativeObjCMethod<AnyObject, String>
    package let defaultDeviceSet: NativeObjCMethod<AnyObject>
    /// An independent context with its own connection to CoreSimulatorService. Connection type 0 is what
    /// `sharedServiceContextForDeveloperDir:error:` passes.
    fileprivate let makeContext: NativeObjCMethod<AnyObject, String, Int>
    fileprivate let serviceConnection: NativeObjCMethod<AnyObject?>
    fileprivate let setConnectionEndHandler: NativeObjCMethod<Void, ConnectionEndHandler?>
    fileprivate let setServiceContext: NativeObjCMethod<Void, AnyObject?>
    fileprivate let devicePairsByUUID: NativeObjCMethod<NSDictionary>
    fileprivate let removeDevice: NativeObjCMethod<Void, AnyObject>
    fileprivate let removeDevicePair: NativeObjCMethod<Void, AnyObject>
    fileprivate let deviceSetWithPath: NativeObjCMethod<AnyObject, String>
    fileprivate let setPath: NativeObjCMethod<String?>
    fileprivate let supportedDeviceTypes: NativeObjCMethod<[AnyObject]>
    fileprivate let supportedRuntimes: NativeObjCMethod<[AnyObject]>
    fileprivate let availableDevices: NativeObjCMethod<[AnyObject]>
    fileprivate let devicesByUDID: NativeObjCMethod<NSDictionary>
    fileprivate let registerHandler: NativeObjCMethod<UInt64, DispatchQueue, NotificationHandler>
    fileprivate let unregisterHandler: NativeObjCMethod<Void, UInt64>
    fileprivate let name: NativeObjCMethod<String?>
    fileprivate let descriptiveName: NativeObjCMethod<String?>
    fileprivate let identifier: NativeObjCMethod<NSUUID?>
    fileprivate let deviceRuntimeIdentifier: NativeObjCMethod<String?>
    fileprivate let deviceRuntime: NativeObjCMethod<AnyObject?>
    fileprivate let deviceType: NativeObjCMethod<AnyObject?>
    /// What a device's own worker sends.
    fileprivate let guest: GuestMessages
    fileprivate let logPath: NativeObjCMethod<String?>
    fileprivate let memoryWarningFilePath: NativeObjCMethod<String?>
    fileprivate let dataPath: NativeObjCMethod<String?>
    fileprivate let runtimeName: NativeObjCMethod<String?>
    fileprivate let runtimeIdentifier: NativeObjCMethod<String?>
    fileprivate let systemRuntime: NativeObjCMethod<AnyObject?, String>
    fileprivate let runtimeBuildVersion: NativeObjCMethod<String?>
    fileprivate let runtimeAvailable: NativeObjCMethod<Bool>
    fileprivate let runtimeSupportsDeviceType: NativeObjCMethod<Bool, AnyObject>
    fileprivate let runtimeVersion: NativeObjCMethod<UInt32>
    fileprivate let productFamily: NativeObjCMethod<Int32>
    fileprivate let deviceTypeName: NativeObjCMethod<String?>
    fileprivate let framebufferMaskURL: NativeObjCMethod<NSURL?>
    fileprivate let deviceTypeCapabilities: NativeObjCMethod<NSDictionary?>
    fileprivate let deviceTypeIdentifier: NativeObjCMethod<String?>
    fileprivate let mainScreenDPI: NativeObjCMethod<CGSize>
    fileprivate let mainScreenScale: NativeObjCMethod<Float>
    fileprivate let userInterfaceIdentifier: NativeObjCMethod<String?>
    fileprivate let devicePairClass: AnyClass
    /// CoreSimulator pairing validation takes the watch type/runtime before the phone.
    fileprivate let testPossiblePairing: NativeObjCMethod<Void, AnyObject, AnyObject, AnyObject, AnyObject>

    package typealias NotificationHandler = @convention(block) (NSDictionary) -> Void
    package typealias CloudSyncCompletion = @convention(block) (NSError?) -> Void
    package typealias ConnectionEndHandler = @convention(block) (NSString?) -> Void

    @MainActor
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
        makeContext = try await runtime.resolve(
            .objc(.method("initWithDeveloperDir:connectionType:error:", as: ((String, Int) throws -> AnyObject).self)),
            on: serviceClass)
        serviceConnection = try await runtime.resolve(
            .objc(.method("serviceConnection", as: (() -> AnyObject?).self)), on: serviceClass)
        setConnectionEndHandler = try await runtime.resolve(
            .objc(.method("setConnectionInvalidationHandler:", as: ((ConnectionEndHandler?) -> Void).self)),
            on: serviceClass)
        setServiceContext = try await runtime.resolve(
            .objc(.method("setServiceContext:", as: ((AnyObject?) -> Void).self)), on: deviceSet)
        devicePairsByUUID = try await runtime.resolve(
            .objc(.method("devicePairsByUUID", as: (() -> NSDictionary).self)), on: deviceSet)
        removeDevice = try await runtime.resolve(
            .objc(.method("removeDeviceAsync:", as: ((AnyObject) -> Void).self)), on: deviceSet)
        removeDevicePair = try await runtime.resolve(
            .objc(.method("removeDevicePairAsync:", as: ((AnyObject) -> Void).self)), on: deviceSet)
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
        availableDevices = try await runtime.resolve(
            .objc(.method("availableDevices", as: (() -> [AnyObject]).self)),
            on: deviceSet)
        devicesByUDID = try await runtime.resolve(
            .objc(.method("devicesByUDID", as: (() -> NSDictionary).self)), on: deviceSet)
        registerHandler = try await runtime.resolve(
            .objc(.method("registerNotificationHandlerOnQueue:handler:",
                as: ((DispatchQueue, @escaping NotificationHandler) -> UInt64).self)),
            on: deviceSet)
        unregisterHandler = try await runtime.resolve(
            .objc(.method("unregisterNotificationHandler:error:", as: ((UInt64) throws -> Void).self)),
            on: deviceSet)
        name = try await runtime.resolve(.objc(.method("name", as: (() -> String?).self)), on: device)
        descriptiveName = try await runtime.resolve(
            .objc(.method("descriptiveName", as: (() -> String?).self)),
            on: device)
        identifier = try await runtime.resolve(.objc(.method("UDID", as: (() -> NSUUID?).self)), on: device)
        deviceRuntimeIdentifier = try await runtime.resolve(
            .objc(.method("runtimeIdentifier", as: (() -> String?).self)),
            on: device)
        deviceRuntime = try await runtime.resolve(
            .objc(.method("runtime", as: (() -> AnyObject?).self)),
            on: device)
        deviceType = try await runtime.resolve(
            .objc(.method("deviceType", as: (() -> AnyObject?).self)),
            on: device)
        guest = try await GuestMessages(runtime: runtime, device: device)
        logPath = try await runtime.resolve(.objc(.method("logPath", as: (() -> String?).self)), on: device)
        memoryWarningFilePath = try await runtime.resolve(
            .objc(.method("memoryWarningFilePath", as: (() -> String?).self)),
            on: device)
        dataPath = try await runtime.resolve(.objc(.method("dataPath", as: (() -> String?).self)), on: device)
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

/// A device's prepared messages that wait on its guest or on CoreSimulator's services: bridge requests, service lookups
/// and guest notifications. They block their thread for as long as the guest takes, which can be forever, so nothing on
/// the main actor can reach them. Prepared messages and SimDevice support being sent from another queue.
private struct GuestMessages: @unchecked Sendable {
    typealias CloudSyncCompletion = CoreSimulatorInterface.CloudSyncCompletion

    let state: NativeObjCMethod<UInt>
    let lastBootedAt: NativeObjCMethod<NSDate?>
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
    let caDebugOption: NativeObjCMethod<Bool, UInt32>
    let setCADebugOption: NativeObjCMethod<Void, UInt32, Bool>
    /// Requests the guest's counted CarPlay session through CoreSimulatorBridge.
    let enableCarPlay: NativeObjCMethod<Void, Bool>
    /// Scenario dictionaries with name and localizedName, or nil if unavailable.
    let availableLocationScenarios: NativeObjCMethod<[NSDictionary]?>
    let clearSimulatedLocation: NativeObjCMethod<Void>
    let setLocation: NativeObjCMethod<Void, Double, Double>
    let setLocationScenario: NativeObjCMethod<Void, String>
    /// The private keyboardType parameter is one byte.
    let setHardwareKeyboard: NativeObjCMethod<Void, Bool, UInt8>
    let setKeyboardLanguage: NativeObjCMethod<Void, String>
    /// The lookup:error: return is a Mach port, so its error slot must be passed explicitly.
    let lookup: NativeObjCMethod<UInt32, String, AutoreleasingUnsafeMutablePointer<NSError?>?>

    @MainActor
    init(runtime: ABIRuntime, device: AnyClass) async throws {
        state = try await runtime.resolve(.objc(.method("state", as: (() -> UInt).self)), on: device)
        lastBootedAt = try await runtime.resolve(.objc(.method("lastBootedAt", as: (() -> NSDate?).self)), on: device)
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
        caDebugOption = try await runtime.resolve(
            .objc(.method("getCADebugOption:", as: ((UInt32) -> Bool).self)),
            on: device)
        setCADebugOption = try await runtime.resolve(
            .objc(.method("setCADebugOption:enabled:", as: ((UInt32, Bool) -> Void).self)),
            on: device)
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
    }
}

/// One device's `GuestMessages`, whose calls only its channel's worker makes.
private struct GuestBridge: @unchecked Sendable {
    let client: NativeDeviceClient
    let messages: GuestMessages

    /// The SimDevice, or a failure once its client has ended.
    var device: AnyObject {
        get throws { try client.device() }
    }

    func notificationState(_ name: String) throws -> UInt64 {
        var state: UInt64 = 0
        try withUnsafeMutablePointer(to: &state) {
            try unsafe messages.darwinNotificationState.unsafeInvoke(on: device, $0, name)
        }
        return state
    }

    /// Sets a guest notification's state and posts it. A failure after the state changed says so.
    func send(_ state: UInt64, to name: String) throws {
        try unsafe messages.setDarwinNotificationState.unsafeInvoke(on: device, state, name)
        do { try post(name) } catch { throw GuestNotificationNotPosted(underlying: error) }
    }

    func post(_ name: String) throws {
        try unsafe messages.postDarwinNotification.unsafeInvoke(on: device, name)
    }

    func debugOption(_ option: CADebugOption) throws -> Bool {
        try unsafe messages.caDebugOption.unsafeInvoke(on: device, option.rawValue)
    }

    var lastBootDate: Date? { (try? unsafe messages.lastBootedAt.unsafeInvoke(on: device)).flatMap { $0 as Date? } }
}

/// A guest notification whose state changed, but which did not reach the guest.
package struct GuestNotificationNotPosted: LocalizedError {
    package let underlying: any Error
    package init(underlying: any Error) { self.underlying = underlying }
    package var errorDescription: String? {
        "The device's state changed, but it was not notified: \(underlying.localizedDescription)"
    }
}

/// What a request for a Core Animation debug option found: CoreSimulator drops the change's error, so only reading the
/// option back shows whether it applied.
package struct CADebugOptionChange: Equatable, Sendable {
    package let requested: Bool
    package let observed: Bool
    package init(requested: Bool, observed: Bool) {
        self.requested = requested
        self.observed = observed
    }
}

/// The guest values that the host's commands show, read together.
package struct GuestStateReading: Equatable, Sendable {
    package var notifications: [String: UInt64] = [:]
    package var debugOptions: [CADebugOption: Bool] = [:]
    package init(notifications: [String: UInt64] = [:], debugOptions: [CADebugOption: Bool] = [:]) {
        self.notifications = notifications
        self.debugOptions = debugOptions
    }
}

/// What a SimDevice reported when it was read. Its state, name, boot date, runtime and device type all wait on one of
/// CoreSimulator's queues, so this is captured on a worker. It holds only values, so what lists a set's devices cannot
/// reach a guest with them: that takes the device's ``SimulatorDevice``, from ``SimulatorDeviceSet/client(withIdentifier:)``.
package struct SimulatorDeviceRecord: Sendable {
    package let identifier: String
    package let name: String
    package let descriptiveName: String
    package let runtimeIdentifier: String
    package let runtimeName: String
    package let runtimeVersion: UInt32
    package let productFamily: Int
    package let deviceTypeName: String
    package let deviceTypeIdentifier: String
    package let hasFramebufferMask: Bool
    package let screenCornerRadius: Double
    package let supportsEnhancedMultitasking: Bool
    package let screenPointsPerInch: Double?
    package let hasUserInterfacePlugin: Bool
    package let deviceSetPath: String?
    package let lastBootDate: Date?
    /// SimDeviceState when it was read: 1 shut down, 2 booting, 3 booted, 4 shutting down.
    package var state: UInt
    package var identity: SimulatorDeviceIdentifier { SimulatorDeviceIdentifier(identifier, deviceSetPath: deviceSetPath) }

    fileprivate init?(_ object: AnyObject, deviceSetPath: String?, interface: CoreSimulatorInterface) throws {
        guard let identifier = try unsafe interface.identifier.unsafeInvoke(on: object) else { return nil }
        self.deviceSetPath = deviceSetPath
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
        lastBootDate = try unsafe interface.guest.lastBootedAt.unsafeInvoke(on: object).map { $0 as Date }
        state = try unsafe interface.guest.state.unsafeInvoke(on: object)
    }
}

/// A device's own connection to CoreSimulator, which everything that reaches the device shares, with what its set last
/// reported. Its set makes one when it is first asked for and updates it with each report, so reading these properties
/// waits for nothing and what holds the device sees its state change. It stays for closing and reopening a window and for
/// rebooting the guest. It ends only when its set reports the device's deletion or CoreSimulator ends its connection,
/// after which its requests fail unsent, and whoever asks the set next gets another. Its context and set stay until the
/// last thing holding it lets go, since a SimDevice holds its set weakly and SimulatorKit cannot use one without it.
@MainActor
package final class SimulatorDevice {
    package private(set) var record: SimulatorDeviceRecord
    /// The underlying SimDevice, of the device's own context.
    package let object: AnyObject
    package var identifier: String { record.identifier }
    package var name: String { record.name }
    /// Runtime, build, and type description shown while Option is held.
    package var descriptiveName: String { record.descriptiveName }
    package var runtimeIdentifier: String { record.runtimeIdentifier }
    package var runtimeName: String { record.runtimeName }
    /// `SimDeviceType.productFamilyID`: 1 iPhone, 2 iPad, 3 TV, 4 Watch, 7 Vision.
    package var productFamily: Int { record.productFamily }
    package var deviceTypeName: String { record.deviceTypeName }
    package var deviceTypeIdentifier: String { record.deviceTypeIdentifier }
    package var hasFramebufferMask: Bool { record.hasFramebufferMask }
    /// DeviceCornerRadius in points; zero for a square screen.
    package var screenCornerRadius: Double { record.screenCornerRadius }
    /// DeviceSupportsEnhancedMultitasking capability (Stage Manager).
    package var supportsEnhancedMultitasking: Bool { record.supportsEnhancedMultitasking }
    /// mainScreenDPI.width / mainScreenScale, or nil without a device type.
    package var screenPointsPerInch: Double? { record.screenPointsPerInch }
    /// `SimRuntime.version`, packed as major << 16 | minor << 8 | patch.
    package var runtimeVersion: UInt32 { record.runtimeVersion }
    /// Whether SimulatorKit should load the device type's user-interface profile.
    package var hasUserInterfacePlugin: Bool { record.hasUserInterfacePlugin }
    /// Nil denotes the default device set.
    package var deviceSetPath: String? { record.deviceSetPath }
    package var identity: SimulatorDeviceIdentifier { SimulatorDeviceIdentifier(identifier, deviceSetPath: deviceSetPath) }
    /// The owner of this device's requests, which every object made for the device shares.
    package let channel: SimulatorDeviceChannel
    private let interface: CoreSimulatorInterface
    private let client: NativeDeviceClient
    private let logPath: String?
    private let memoryWarningFilePath: String?
    private let dataPath: String?
    private var guest: GuestBridge { GuestBridge(client: client, messages: interface.guest) }

    fileprivate init(_ opened: NativeDeviceClient.OpenedDevice, client: NativeDeviceClient, interface: CoreSimulatorInterface) {
        record = opened.record
        object = opened.object
        logPath = opened.logPath
        memoryWarningFilePath = opened.memoryWarningFilePath
        dataPath = opened.dataPath
        self.client = client
        self.interface = interface
        channel = client.channel
    }

    /// Its set holds it until it ends, so this comes only after that.
    deinit { client.release() }

    fileprivate func update(_ record: SimulatorDeviceRecord) { self.record = record }
    fileprivate func removeFromSet() { record.state = 0 }

    /// SimDeviceState as the set last reported it; 3 means booted and 0 that the set no longer lists the device.
    package var state: UInt { record.state }

    /// Identifies a boot, as the set last reported it; nil if the device has none.
    package var lastBootDate: Date? { record.lastBootDate }

    /// The SimDeviceState that the device reports now, for when what it was last reported to be is not enough.
    package func currentState() async throws -> UInt {
        try await channel.read("read the device's state") { [guest] in
            try unsafe guest.messages.state.unsafeInvoke(on: guest.device)
        }
    }

    /// Which of `features` the device supports. `SimDevice supportsFeature:` reads its device type and runtime, which
    /// wait on CoreSimulator's queues.
    package func supportedFeatures(_ features: [String]) async throws -> Set<String> {
        try await channel.read("read the device's features") { [guest] in
            Set(try features.filter { try unsafe guest.messages.supportsFeature.unsafeInvoke(on: guest.device, $0) })
        }
    }

    /// Reads and flips the appearance as one step, so that no other request runs between them.
    package func toggleAppearance() async throws {
        try await channel.change("toggle the device's appearance") { [guest] in
            let style = try unsafe guest.messages.interfaceStyle.unsafeInvoke(on: guest.device)
            try unsafe guest.messages.setInterfaceStyle.unsafeInvoke(on: guest.device, style == 2 ? 1 : 2)
        }
    }

    package func postNotification(_ name: String) async throws {
        try await channel.change("post \(name) in the device") { [guest] in try guest.post(name) }
    }

    /// The guest's state of a Darwin notification.
    package func notificationState(_ name: String) async throws -> UInt64 {
        try await channel.read("read \(name) from the device") { [guest] in try guest.notificationState(name) }
    }

    /// Sets a guest notification's state and posts it as one step. Throws ``GuestNotificationNotPosted`` when the state
    /// changed and only the post failed.
    package func sendNotificationState(_ name: String, to state: UInt64) async throws {
        try await channel.change("change \(name) in the device") { [guest] in try guest.send(state, to: name) }
    }

    /// Reads a guest notification's state, then sets and posts what `change` makes of it, as one step. Returns the state
    /// it set. Throws ``GuestNotificationNotPosted`` when the state changed and only the post failed.
    package func updateNotificationState(_ name: String, _ change: @escaping @Sendable (UInt64) -> UInt64) async throws {
        try await channel.change("change \(name) in the device") { [guest] in
            try guest.send(change(try guest.notificationState(name)), to: name)
        }
    }

    /// CoreSimulator content-size values: 1–12, from Extra Small to Accessibility XXXL.
    package func contentSizeCategory() async throws -> Int {
        try await channel.read("read the device's text size") { [guest] in
            try unsafe guest.messages.contentSizeCategory.unsafeInvoke(on: guest.device)
        }
    }

    package func setContentSizeCategory(_ category: Int) async throws {
        try await channel.change("change the device's text size") { [guest] in
            try unsafe guest.messages.setContentSizeCategory.unsafeInvoke(on: guest.device, category)
        }
    }

    /// Reads the text size and sets what `change` makes of it, if anything, as one step.
    package func updateContentSizeCategory(_ change: @escaping @Sendable (Int) throws -> Int?) async throws {
        try await channel.change("change the device's text size") { [guest] in
            let category = try unsafe guest.messages.contentSizeCategory.unsafeInvoke(on: guest.device)
            if let updated = try change(category) {
                try unsafe guest.messages.setContentSizeCategory.unsafeInvoke(on: guest.device, updated)
            }
        }
    }

    /// Reads Increase Contrast's mode, 1 when it is off and 2 when it is on and 0 when unknown, and sets whether it is on
    /// as `change` decides, as one step.
    package func updateIncreaseContrast(_ change: @escaping @Sendable (Int) throws -> Bool) async throws {
        try await channel.change("change the device's Increase Contrast") { [guest] in
            let enabled = try change(try unsafe guest.messages.increaseContrastMode.unsafeInvoke(on: guest.device))
            try unsafe guest.messages.setIncreaseContrast.unsafeInvoke(on: guest.device, enabled)
        }
    }

    /// Waits for CoreSimulator's completion for at most ``DeviceOperationLimit/cloudSync``, and ends with its caller,
    /// since the sync goes on without being waited for.
    package func triggerCloudSync() async throws {
        let operation = "trigger an iCloud sync"
        let (answer, continuation) = AsyncThrowingStream.makeStream(of: Never.self)
        nonisolated(unsafe) let completion: CoreSimulatorInterface.CloudSyncCompletion = { error in
            continuation.finish(throwing: error)
        }
        try await channel.change(operation) { [guest] in
            try unsafe guest.messages.triggerCloudSync.unsafeInvoke(on: guest.device, .main, completion)
        }
        let limit = DeviceOperationLimit.cloudSync
        let deadline = Task {
            try await Task.sleep(for: limit)
            continuation.finish(throwing: DeviceOperationFailure.outcomeUnknown(operation: operation, cause: .timedOut(limit)))
        }
        defer { deadline.cancel() }
        for try await _ in answer {}
        if Task.isCancelled { throw DeviceOperationFailure.outcomeUnknown(operation: operation, cause: .cancelled) }
    }

    package func logDirectory() throws -> URL {
        guard let path = logPath else {
            throw SimulatorError.operation("The device did not report its log folder.")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Guest file used by SimDevice.simulateMemoryWarning.
    package func memoryWarningFile() throws -> URL {
        guard let path = memoryWarningFilePath else {
            throw SimulatorError.operation("The device did not report where to signal a memory warning.")
        }
        return URL(fileURLWithPath: path)
    }

    /// The guest reads extended_display.plist whenever TVOut modes change.
    /// Its stark flag marks the screen as a CarPlay display.
    package func extendedDisplayFile() throws -> URL {
        guard let path = dataPath else {
            throw SimulatorError.operation("The device did not report its data folder.")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
            .appendingPathComponent("Library/Application Support/Simulator/extended_display.plist")
    }

    /// Sends a counted CarPlay request; each start needs one end. Throws CarPlayRequestMoot if the device is no longer in
    /// `boot` when the request runs.
    package func setCarPlayEnabled(_ enabled: Bool, inBoot boot: Date?) async throws {
        try await channel.change(enabled ? "start CarPlay on the device" : "stop CarPlay on the device") { [guest] in
            // A restart between this check and guest delivery cannot be detected here.
            guard guest.lastBootDate == boot else { throw CarPlayRequestMoot() }
            try unsafe guest.messages.enableCarPlay.unsafeInvoke(on: guest.device, enabled)
        }
    }

    /// The guest values that `notifications` and `debugOptions` name, read as one step. CoreSimulator drops the error of a
    /// debug option's read, so false can also mean that it failed.
    package func guestState(notifications: [String], debugOptions: [CADebugOption]) async throws -> GuestStateReading {
        try await channel.read("read the device's state") { [guest] in
            var reading = GuestStateReading()
            for name in notifications { reading.notifications[name] = try guest.notificationState(name) }
            for option in debugOptions { reading.debugOptions[option] = try guest.debugOption(option) }
            return reading
        }
    }

    /// Reads a Core Animation debug option, sets the opposite and reads it back, as one step.
    package func toggleCADebugOption(_ option: CADebugOption) async throws -> CADebugOptionChange {
        try await channel.change("change \(option.title) on the device") { [guest] in
            let enabled = try !guest.debugOption(option)
            try unsafe guest.messages.setCADebugOption.unsafeInvoke(on: guest.device, option.rawValue, enabled)
            return CADebugOptionChange(requested: enabled, observed: try guest.debugOption(option))
        }
    }

    /// Recorded routes in runtime order; empty if none are reported.
    package func locationScenarios() async throws -> [LocationScenario] {
        try await channel.read("read the device's location scenarios") { [guest] in
            try unsafe guest.messages.availableLocationScenarios.unsafeInvoke(on: guest.device)?.compactMap { scenario in
                guard let name = scenario["name"] as? String else { return nil }
                return LocationScenario(name: name, localizedName: scenario["localizedName"] as? String ?? name)
            } ?? []
        }
    }

    package func clearSimulatedLocation() async throws {
        try await channel.change("clear the device's simulated location") { [guest] in
            try unsafe guest.messages.clearSimulatedLocation.unsafeInvoke(on: guest.device)
        }
    }

    package func setLocation(latitude: Double, longitude: Double) async throws {
        try await channel.change("set the device's simulated location") { [guest] in
            try unsafe guest.messages.setLocation.unsafeInvoke(on: guest.device, latitude, longitude)
        }
    }

    package func setLocationScenario(_ name: String) async throws {
        try await channel.change("run a location scenario on the device") { [guest] in
            try unsafe guest.messages.setLocationScenario.unsafeInvoke(on: guest.device, name)
        }
    }

    /// Uses the byte-sized keyboard type returned by IndigoHIDGetKeyboardType.
    package func setHardwareKeyboardEnabled(_ enabled: Bool, keyboardType: UInt8) async throws {
        try await channel.change("change the device's hardware keyboard") { [guest] in
            try unsafe guest.messages.setHardwareKeyboard.unsafeInvoke(on: guest.device, enabled, keyboardType)
        }
    }

    package func setKeyboardLanguage(_ language: String) async throws {
        try await channel.change("change the device's keyboard language") { [guest] in
            try unsafe guest.messages.setKeyboardLanguage.unsafeInvoke(on: guest.device, language)
        }
    }

    /// Returns a caller-owned send right. Fails unless the guest is booted. A lookup that returns after its caller stopped
    /// waiting releases the right it got.
    package func lookUp(_ name: String) async throws -> UInt32 {
        try await channel.read("look up the device's \(name) service", lateCompletion: { result in
            if case .success(let port) = result { mach_port_deallocate(mach_task_self_, port) }
        }) { [guest] in
            try autoreleasepool {
                // The method stores an autoreleased error, so the slot must not own it.
                let slot = UnsafeMutablePointer<Int>.allocate(capacity: 1)
                defer { slot.deallocate() }
                unsafe slot.initialize(to: 0)
                let error = unsafe AutoreleasingUnsafeMutablePointer<NSError?>(slot)
                let port = try unsafe guest.messages.lookup.unsafeInvoke(on: guest.device, name, error)
                // MACH_PORT_NULL and MACH_PORT_DEAD are not rights.
                guard port != 0, port != UInt32.max else {
                    throw unsafe error.pointee ?? SimulatorError.operation("The device did not provide \(name).")
                }
                return port
            }
        }
    }
}

/// Recorded location route supplied by the runtime.
package struct LocationScenario: Equatable, Sendable {
    /// CoreSimulator identifier.
    package let name: String
    /// Display title.
    package let localizedName: String
}

/// The owner of one device set of one developer directory, which every path to the set shares. CoreSimulator's context and
/// set are created and read only on the worker of the set's channel, since creating them, listing their devices and
/// reading a device's state all wait on CoreSimulator's queues or its service. What the set last reported stays readable
/// here as values, also while a call is held. Reads are shared: see ``CoalescedChannelRead``.
///
/// It also owns one ``SimulatorDevice`` per device that something asked to reach. Listing devices makes none.
@MainActor
package final class SimulatorDeviceSet {
    private static var sets: [DeviceSetAddress: SimulatorDeviceSet] = [:]

    /// The set's owner. This waits for nothing: the set opens on its worker when it is first used.
    package static func shared(interface: CoreSimulatorInterface, developerDirectory: String,
                               path: String? = nil) -> SimulatorDeviceSet {
        let address = DeviceSetAddress(developerDirectory: developerDirectory, path: path)
        if let set = sets[address] { return set }
        let set = SimulatorDeviceSet(interface: interface, address: address)
        sets[address] = set
        return set
    }

    package let address: DeviceSetAddress
    package let channel: SimulatorDeviceChannel
    /// Available devices as the set last reported them, ordered by runtime, type, and name.
    package private(set) var devices: [SimulatorDeviceRecord] = []
    private let interface: CoreSimulatorInterface
    private let native: NativeDeviceSet
    private let reads: CoalescedChannelRead<[SimulatorDeviceRecord]>
    /// By uppercased UDID. An entry outlives a failed or abandoned opening, so that a call still running on the device's
    /// worker leaves what it opens for the next request.
    private var clients: [String: DeviceClient] = [:]

    private struct DeviceClient {
        let native: NativeDeviceClient
        var device: SimulatorDevice?
        var opening: SharedTask<SimulatorDevice?>?
    }

    private init(interface: CoreSimulatorInterface, address: DeviceSetAddress) {
        self.interface = interface
        self.address = address
        let native = NativeDeviceSet(interface: interface, address: address)
        self.native = native
        channel = DeviceIOHub.shared.channel(for: .deviceSet(address))
        reads = CoalescedChannelRead(channel: channel, operation: "read the device set",
                                     limit: DeviceOperationLimit.deviceSet) { try native.readDevices() }
        reads.onRead = { [weak self] in self?.publish($0) }
    }

    /// Reads the set again and returns its devices. `limit` ends only this caller's wait: the read goes on, and what it
    /// finds is published when it returns.
    @discardableResult
    package func refresh(waitingAtMost limit: Duration? = nil) async throws -> [SimulatorDeviceRecord] {
        try await reads.refresh(waitingAtMost: limit)
        return devices
    }

    /// The set's path, resolved by CoreSimulator.
    package func resolvedPath() async throws -> String {
        try await channel.read("open the device set", limit: DeviceOperationLimit.deviceSet) { [native] in
            try native.open().path
        }
    }

    /// The creation catalog with every pairing CoreSimulator accepts, which it validates on the same worker.
    package func readCatalog() async throws -> SimulatorCatalog.Snapshot {
        try await channel.read("read the creation catalog", limit: DeviceOperationLimit.deviceSet) { [native] in
            try native.readCatalog()
        }
    }

    /// The device's own connection to CoreSimulator, opened on the device's worker when first asked for, and nil if the
    /// set does not hold the device. Whoever asks while it opens shares that opening, each for as long as it waits. A failure
    /// goes to those waiting, and the next request tries again on the same worker, so no two openings or their
    /// connections' requests ever overlap.
    package func client(withIdentifier identifier: String) async throws -> SimulatorDevice? {
        let key = identifier.uppercased()
        var client = clients[key] ?? DeviceClient(native: makeClient(key))
        if let device = client.device { return device }
        let opening = client.opening ?? open(client.native, key)
        client.opening = opening
        clients[key] = client
        return try await opening.value()
    }

    private func makeClient(_ key: String) -> NativeDeviceClient {
        let channel = DeviceIOHub.shared.channel(for: .device(DeviceAddress(identifier: key, deviceSetPath: address.path)))
        return NativeDeviceClient(identifier: key, address: address, channel: channel, interface: interface) {
            [weak self] client, deviceWasDeleted in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.clientEnded(client, key, deviceWasDeleted: deviceWasDeleted) }
            }
        }
    }

    private func open(_ client: NativeDeviceClient, _ key: String) -> SharedTask<SimulatorDevice?> {
        let operation = "open the device's connection to CoreSimulator"
        return SharedTask(operation) { [self] in
            defer { if clients[key]?.native === client { clients[key]?.opening = nil } }
            let opened = try await client.channel.read(operation, limit: DeviceOperationLimit.deviceSet) { try client.open() }
            guard clients[key]?.native === client else {
                throw SimulatorError.unavailable("The device's connection to CoreSimulator ended while it opened.")
            }
            guard let opened else {
                clients[key] = nil
                return nil
            }
            let device = SimulatorDevice(opened, client: client, interface: interface)
            clients[key]?.device = device
            return device
        }
    }

    /// The next request opens another client on the same worker, so it cannot overlap a held call of this one. One that no
    /// device was made from has no holder to release it.
    private func clientEnded(_ client: NativeDeviceClient, _ key: String, deviceWasDeleted: Bool) {
        if !deviceWasDeleted { hostLog("CoreSimulator ended the connection of the device \(key).") }
        guard let current = clients[key], current.native === client else { return client.release() }
        clients[key] = nil
        guard let device = current.device else { return client.release() }
        if deviceWasDeleted { device.removeFromSet() }
    }

    /// Registers `handler` for changes to the set's devices, on the main queue.
    package func observe(_ handler: @escaping @MainActor @Sendable () -> Void) async throws -> UInt64 {
        try await channel.read("observe the device set", limit: DeviceOperationLimit.deviceSet, lateCompletion: { [native] result in
            if case .success(let token) = result { native.stopObservingReportingFailure(token) }
        }) { [native] in try native.observe(handler) }
    }

    /// Removes a registration once no call holds the worker. The task ends when it has, for whoever has to report it.
    package func stopObserving(_ token: UInt64) -> Task<Void, Never> {
        let (removal, finished) = AsyncStream.makeStream(of: Never.self)
        channel.cleanUp("stop observing the device set") { [native] in
            native.stopObservingReportingFailure(token)
            finished.finish()
        }
        return Task { for await _ in removal {} }
    }

    package nonisolated func healthChanges() -> AsyncStream<DeviceChannelHealth> { channel.healthChanges() }

    /// A device that the available list omits may only have lost its runtime, so that says nothing about its client.
    private func publish(_ records: [SimulatorDeviceRecord]) {
        devices = records
        let listed = Dictionary(records.map { ($0.identifier.uppercased(), $0) }) { first, _ in first }
        for (key, client) in clients {
            if let record = listed[key] { client.device?.update(record) } else { client.device?.removeFromSet() }
        }
    }
}

/// CoreSimulator's context and set. Only the worker of the set's channel touches this.
private final class NativeDeviceSet: @unchecked Sendable {
    struct Opened {
        let context: AnyObject
        let object: AnyObject
        let path: String
        /// Tool argument; nil for the default device set.
        let toolPath: String?
    }

    private let interface: CoreSimulatorInterface
    private let address: DeviceSetAddress
    private var opened: Opened?

    init(interface: CoreSimulatorInterface, address: DeviceSetAddress) {
        self.interface = interface
        self.address = address
    }

    /// Opens the set once. A call that outlives its caller's wait still leaves it open for the next request.
    func open() throws -> Opened {
        if let opened { return opened }
        let context = try unsafe interface.sharedContext.unsafeInvoke(
            on: interface.serviceClass as AnyObject, address.developerDirectory)
        // SimServiceContext returns subscribed sets. Subscribing again replays every device's runtime policy.
        let object: AnyObject
        if let path = address.path {
            object = try unsafe interface.deviceSetWithPath.unsafeInvoke(on: context, path)
        } else {
            object = try unsafe interface.defaultDeviceSet.unsafeInvoke(on: context)
        }
        let path = try unsafe interface.setPath.unsafeInvoke(on: object) ?? address.path ?? ""
        let opened = Opened(context: context, object: object, path: path, toolPath: address.path == nil ? nil : path)
        self.opened = opened
        return opened
    }

    func readDevices() throws -> [SimulatorDeviceRecord] {
        let opened = try open()
        return try unsafe interface.availableDevices.unsafeInvoke(on: opened.object).compactMap {
            try SimulatorDeviceRecord($0, deviceSetPath: opened.toolPath, interface: interface)
        }
    }

    func readCatalog() throws -> SimulatorCatalog.Snapshot {
        let context = try open().context
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
        return SimulatorCatalog.Snapshot(deviceTypes: deviceTypes.map(\.type), runtimes: runtimes,
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

    func observe(_ handler: @escaping @MainActor @Sendable () -> Void) throws -> UInt64 {
        let block: CoreSimulatorInterface.NotificationHandler = { notification in
            switch notification["notification"] as? String {
            case "device_state", "device_added", "device_removed", "device_renamed", "device_runtime_changed", "runtime_policy_changed": break
            default: return
            }
            MainActor.assumeIsolated { handler() }
        }
        return try unsafe interface.registerHandler.unsafeInvoke(on: open().object, DispatchQueue.main, block)
    }

    /// Nothing waits for a registration to leave, so its failure can only be logged.
    func stopObservingReportingFailure(_ token: UInt64) {
        do { try unsafe interface.unregisterHandler.unsafeInvoke(on: open().object, token) }
        catch { hostLog("Could not unregister simulator notifications: \(error.localizedDescription)") }
    }
}

/// One device's own CoreSimulator context and set, whose connection to CoreSimulatorService no other device's calls wait
/// on. The worker of the device's channel opens and releases them and alone touches `opened`.
///
/// A context and its set retain each other, the connection retains the context, and each device and pair of the set holds a
/// handler that retains the set. So nothing frees them unless the connection is cancelled and the set lets go of its
/// context, devices and pairs. Whatever ends the connection, CoreSimulator reports it once, and only after that report and
/// after whatever holds the device has let go can they be released: a release before the report can leave the context
/// allocated, and one before the device is let go leaves SimulatorKit a SimDevice without a set, which throws when used.
/// Cancelling this connection ends only this client: it returns a lookup that the connection holds, but not a bridge call,
/// which keeps the worker until it returns.
private final class NativeDeviceClient: @unchecked Sendable {
    struct OpenedDevice: @unchecked Sendable {
        let object: AnyObject
        let record: SimulatorDeviceRecord
        // These come from the set, so they are read while the device still has it.
        let logPath: String?
        let memoryWarningFilePath: String?
        let dataPath: String?
    }

    private struct Connection: @unchecked Sendable {
        var object: xpc_connection_t?
        var deviceWasDeleted = false
        var hasEnded = false
    }

    let channel: SimulatorDeviceChannel
    private let identifier: String
    private let address: DeviceSetAddress
    private let interface: CoreSimulatorInterface
    private let onEnd: @Sendable (NativeDeviceClient, _ deviceWasDeleted: Bool) -> Void
    private let events: DispatchQueue
    private let connection = Mutex(Connection())
    private var opened: (context: AnyObject, set: AnyObject, device: AnyObject, toolPath: String?)?
    private var isReleased = false

    init(identifier: String, address: DeviceSetAddress, channel: SimulatorDeviceChannel, interface: CoreSimulatorInterface,
         onEnd: @escaping @Sendable (NativeDeviceClient, _ deviceWasDeleted: Bool) -> Void) {
        self.identifier = identifier
        self.address = address
        self.channel = channel
        self.interface = interface
        self.onEnd = onEnd
        events = DispatchQueue(label: "dev.lynnswap.NeoSimulator.device-client.\(identifier)", qos: .userInitiated,
                               autoreleaseFrequency: .workItem)
    }

    /// Opens once, and what a call opened after its caller stopped waiting stays for the next. Answers nil, with nothing
    /// left open, if the set does not hold the device.
    func open() throws -> OpenedDevice? {
        if let opened { return try read(opened.device, toolPath: opened.toolPath) }
        // A request that was waiting when this client ended belongs to no one who could release what it opened.
        guard !isReleased else { throw SimulatorError.unavailable("The device's connection to CoreSimulator ended while it opened.") }
        guard let uuid = NSUUID(uuidString: identifier) else { return nil }
        guard let allocated = allocate(interface.serviceClass) else {
            throw SimulatorError.unavailable("Could not allocate the device's connection to CoreSimulator.")
        }
        let context = try unsafe interface.makeContext.unsafeInvoke(on: allocated, address.developerDirectory, 0)
        let endpoint = try unsafe interface.serviceConnection.unsafeInvoke(on: context) as? xpc_connection_t
        guard let endpoint else { throw SimulatorError.unavailable("CoreSimulator gave the device no connection.") }
        connection.withLock { $0 = Connection(object: endpoint) }
        // It goes on before anything can end the connection, since one set on a dead context leaves that context allocated.
        let ended = ObjectIdentifier(endpoint)
        let handler: CoreSimulatorInterface.ConnectionEndHandler = { [weak self] _ in self?.connectionEnded(ended) }
        var set: AnyObject?
        do {
            try unsafe interface.setConnectionEndHandler.unsafeInvoke(on: context, handler)
            let object: AnyObject
            if let path = address.path {
                object = try unsafe interface.deviceSetWithPath.unsafeInvoke(on: context, path)
            } else {
                object = try unsafe interface.defaultDeviceSet.unsafeInvoke(on: context)
            }
            set = object
            try watchForDeletion(uuid, in: object)
            let toolPath = address.path == nil ? nil : try unsafe interface.setPath.unsafeInvoke(on: object) ?? address.path
            guard let device = try unsafe interface.devicesByUDID.unsafeInvoke(on: object)[uuid],
                  let read = try read(device as AnyObject, toolPath: toolPath) else {
                discard(context, set: object)
                return nil
            }
            opened = (context, object, device as AnyObject, toolPath)
            return read
        } catch {
            discard(context, set: set)
            throw error
        }
    }

    /// The SimDevice, for a request on the worker. CoreSimulator answers a message to a device whose context is gone as
    /// though nothing had failed, so a request after the end must not reach it.
    func device() throws -> AnyObject {
        guard let opened, !connection.withLock({ $0.hasEnded }) else {
            throw SimulatorError.unavailable("The simulator's connection to CoreSimulator has ended, so this request was not sent.")
        }
        return opened.device
    }

    /// Lets go of what is open, once no call holds the worker and before any request waiting there. Nothing waits for it.
    nonisolated func release() {
        channel.cleanUp("release the device's connection to CoreSimulator") { [self] in
            isReleased = true
            guard let opened else { return }
            self.opened = nil
            connection.withLock { $0.object = nil }
            letGo(of: opened.set)
        }
    }

    private func read(_ device: AnyObject, toolPath: String?) throws -> OpenedDevice? {
        try SimulatorDeviceRecord(device, deviceSetPath: toolPath, interface: interface).map {
            OpenedDevice(object: device, record: $0, logPath: try unsafe interface.logPath.unsafeInvoke(on: device),
                         memoryWarningFilePath: try unsafe interface.memoryWarningFilePath.unsafeInvoke(on: device),
                         dataPath: try unsafe interface.dataPath.unsafeInvoke(on: device))
        }
    }

    /// Only a removal that the set itself shows ends a client. It cannot be told from a failed read or a shorter list.
    private func watchForDeletion(_ uuid: NSUUID, in set: AnyObject) throws {
        let block: CoreSimulatorInterface.NotificationHandler = { [weak self, weak set, interface] notification in
            guard notification["notification"] as? String == "device_removed", let self, let set,
                  let devices = try? unsafe interface.devicesByUDID.unsafeInvoke(on: set), devices[uuid] == nil else { return }
            self.connection.withLock { connection in
                connection.deviceWasDeleted = true
                if let object = connection.object { xpc_connection_cancel(object) }
            }
        }
        _ = try unsafe interface.registerHandler.unsafeInvoke(on: set, events, block)
    }

    private func connectionEnded(_ ended: ObjectIdentifier) {
        let deviceWasDeleted = connection.withLock { connection -> Bool? in
            guard connection.object.map(ObjectIdentifier.init) == ended else { return nil }
            connection.hasEnded = true
            return connection.deviceWasDeleted
        }
        if let deviceWasDeleted { onEnd(self, deviceWasDeleted) }
    }

    /// Ends what an opening that failed had, which nobody is waiting to hear about. Without the handler its end cannot race this.
    private func discard(_ context: AnyObject, set: AnyObject?) {
        let endpoint = connection.withLock { connection in
            defer { connection = Connection() }
            return connection.object
        }
        do { try unsafe interface.setConnectionEndHandler.unsafeInvoke(on: context, nil) }
        catch { hostLog("Could not clear a device connection's handler: \(error.localizedDescription)") }
        if let endpoint { xpc_connection_cancel(endpoint) }
        if let set { letGo(of: set) }
    }

    /// Empties this client's own set, whose connection has ended. Removing only changes its maps and tells its handlers:
    /// CoreSimulatorService hears nothing of it, and neither does any other context's set.
    private func letGo(of set: AnyObject) {
        do {
            for device in try unsafe interface.devicesByUDID.unsafeInvoke(on: set).allValues {
                try unsafe interface.removeDevice.unsafeInvoke(on: set, device as AnyObject)
            }
            for pair in try unsafe interface.devicePairsByUUID.unsafeInvoke(on: set).allValues {
                try unsafe interface.removeDevicePair.unsafeInvoke(on: set, pair as AnyObject)
            }
            try unsafe interface.setServiceContext.unsafeInvoke(on: set, nil)
        } catch { hostLog("Could not release a device's connection to CoreSimulator: \(error.localizedDescription)") }
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
