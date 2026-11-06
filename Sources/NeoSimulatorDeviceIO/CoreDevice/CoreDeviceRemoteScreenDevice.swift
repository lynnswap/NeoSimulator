import ABIBridge
import Foundation
import NeoSimulatorNative

@MainActor
package enum CoreDeviceRuntime {
    private static var manager: NativeSwiftValue?
    private static var managerPreparation: Task<Void, any Error>?
    private static let managerInitialization = makeInitialization {
        let manager = try await deviceManagerIncludingSimulators()
        let type = try await ABIRuntime.shared.resolve(.swift(.type("CoreDevice.DeviceManager")))
        let initialize = try await type.resolve(.swift(.method("awaitFullInitialization()", as: (() async -> Void).self)))
        try await unsafe initialize.unsafeInvoke(on: manager)
    }
    private static var uiXcodeOverride: URL?
    private static var uiXcodePreparation: Task<URL, any Error>?

    /// Reports a prolonged initialization and clears the notice when initialization finishes.
    package static var onInitializationDelayChanged: (@MainActor (Bool) -> Void)?

    /// Overrides the UI framework installation before any device screen is opened.
    /// Device runtimes and their owning Xcode processes are selected independently.
    package static func configureUIFrameworks(xcodeURL: URL?) throws {
        guard uiXcodePreparation == nil else {
            throw DeviceIOError.configuration("ui-frameworks-loaded", "Restart the application to change its UI framework installation.")
        }
        uiXcodeOverride = xcodeURL
    }

    /// Uses one installation for SimulatorKit and DeviceKit throughout this process.
    package static func uiXcodeURL() async throws -> URL {
        try Task.checkCancellation()
        if let uiXcodePreparation { return try await preparedValue(of: uiXcodePreparation) }
        let override = uiXcodeOverride
        let task = Task {
            do { return try await resolveUIXcode(override: override) }
            catch { uiXcodePreparation = nil; throw error }
        }
        uiXcodePreparation = task
        return try await preparedValue(of: task)
    }

    /// Cancels only this consumer's wait; the shared runtime preparation keeps its other consumers.
    package static func preparedValue<Value: Sendable>(of preparation: Task<Value, any Error>) async throws -> Value {
        try await PreparationWaiter<Value>().value(of: preparation)
    }

    /// Shares CoreDevice's one initialization. Neither a consumer's cancellation nor its limit stops the native
    /// initializer, and no consumer starts another or a new client while it is pending.
    package static func initializeDeviceManager() async throws {
        try await managerInitialization.value(limit: DeviceOperationLimit.coreDeviceInitialization)
    }

    /// One initialization, whose delay is reported until it actually finishes.
    package static func makeInitialization(
        waitUntilDelayed: @escaping @MainActor () async throws -> Void = {
            try await Task.sleep(for: DeviceOperationLimit.coreDeviceInitialization)
        },
        _ initialize: @escaping @MainActor () async throws -> Void
    ) -> SharedTask<Void> {
        SharedTask("finish CoreDevice's initialization") {
            try await reportInitializationDelay(during: initialize, waitUntilDelayed: waitUntilDelayed,
                                                onChange: { onInitializationDelayChanged?($0) })
        }
    }

    /// A delay offers recovery guidance without ending the native initialization or its consumers' waits.
    package static func reportInitializationDelay(during initialize: @MainActor () async throws -> Void,
                                          waitUntilDelayed: @escaping @MainActor () async throws -> Void,
                                          onChange: @escaping @MainActor (Bool) -> Void) async throws {
        var delayed = false
        let notice = Task {
            try await waitUntilDelayed()
            try Task.checkCancellation()
            delayed = true
            onChange(true)
        }
        defer {
            notice.cancel()
            if delayed { onChange(false) }
        }
        try await initialize()
    }

    @MainActor
    private final class PreparationWaiter<Value: Sendable> {
        private var continuation: CheckedContinuation<Value, any Error>?

        func value(of preparation: Task<Value, any Error>) async throws -> Value {
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { continuation in
                    self.continuation = continuation
                    Task { [weak self] in
                        let result = await preparation.result
                        self?.finish(result)
                    }
                }
            } onCancel: {
                Task { @MainActor in self.finish(.failure(CancellationError())) }
            }
        }

        private func finish(_ result: Result<Value, any Error>) {
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(with: result)
        }
    }

    /// Runs a framework load, reporting what the loader said under `identifier`.
    package nonisolated static func loading<Value: Sendable>(_ identifier: String,
                                                             _ load: @Sendable () async throws -> Value) async throws -> Value {
        do { return try await load() }
        catch let failure as NativeRuntimeError { throw DeviceIOError.runtime(identifier, failure) }
    }

    /// Loads DeviceKit of the process's UI installation, which DeviceKit's load also fixes for SimulatorKit.
    package static func loadDeviceKit() async throws {
        guard !deviceKitLoaded else { return }
        let xcodeURL = try await uiXcodeURL()
        try await loading("device-kit-runtime") { try await NativeFrameworks.loadDeviceKit(from: xcodeURL) }
        deviceKitLoaded = true
    }

    private static var deviceKitLoaded = false

    @concurrent
    private static func resolveUIXcode(override: URL?) async throws -> URL {
        let inspector = XcodeInstallationInspector()
        return try await inspector.xcodeForUIFrameworks(override: override).applicationURL
    }

    /// Returns the retained, shared manager for default devices and simulators.
    ///
    /// Callers must await the manager's `awaitFullInitialization()` before reading
    /// its devices or observing device changes. This method does not wait for initialization.
    package static func deviceManagerIncludingSimulators() async throws -> NativeSwiftValue {
        try Task.checkCancellation()
        if let manager { return manager }
        if let preparation = managerPreparation {
            try await preparedValue(of: preparation)
            return manager!
        }
        let preparation = Task {
            defer { managerPreparation = nil }
            let value = try await makeDeviceManager()
            manager = value
        }
        managerPreparation = preparation
        try await preparedValue(of: preparation)
        return manager!
    }

    private static func makeDeviceManager() async throws -> NativeSwiftValue {
        try await loading("coredevice-runtime") {
            try await NativeFrameworks.load("/Library/Developer/PrivateFrameworks/CoreDevice.framework/CoreDevice")
        }
        let runtime = ABIRuntime.shared
        let service = try await runtime.resolve(.swift(.type("CoreDevice.CoreDeviceService")))
        let sharedConnection = try await service.resolve(.swift(.staticGetter("sharedConnection", as: (() -> NativeSwiftValue).self)))
        let connection = try unsafe sharedConnection.unsafeInvoke()
        let visibility = try await runtime.resolve(.swift(.type("CoreDevice.DeviceVisibilityClass")))
        let classes = try ["default", "simulators"].map { try visibility.makeEnumCase(named: $0) }
        let type = try await runtime.resolve(.swift(.type("CoreDevice.DeviceManager")))
        let make = try await type.resolve(.swift(.initializer("init(serviceConnection:allowedDeviceVisibilityClasses:)",
            as: ((NativeSwiftValue, [NativeSwiftValue]) -> NativeSwiftValue).self)))
        let manager = try unsafe make.unsafeInvoke(connection, classes)
        return manager
    }
}

@MainActor
package final class CoreDeviceRemoteScreenDevice: CoreDeviceFeatureRecord {
    package let identifier: String
    package let runtime: ABIRuntime
    package let object: NativeSwiftValue
    package let type: NativeSwiftType
    private let manager: NativeSwiftValue
    private let supportsFeature: NativeSwiftMethod<(String) -> Bool>

    package init(identifier: String) async throws {
        let manager = try await CoreDeviceRuntime.deviceManagerIncludingSimulators()
        let runtime = ABIRuntime.shared
        let managerType = try await runtime.resolve(.swift(.type("CoreDevice.DeviceManager")))
        try await CoreDeviceRuntime.initializeDeviceManager()
        try Task.checkCancellation()
        guard let uuid = UUID(uuidString: identifier) else {
            throw DeviceIOError.configuration("coredevice-identifier", "The selected CoreDevice identifier is not a UUID.")
        }
        let devices = try await managerType.resolve(.swift(.getter("devices", as: (() -> [UUID: NativeSwiftValue]).self)))
        guard let object = try unsafe devices.unsafeInvoke(on: manager)[uuid] else {
            throw DeviceIOError.unavailable("remote-screen-device", "The selected device is no longer available.")
        }
        self.identifier = identifier
        self.runtime = runtime
        self.manager = manager
        self.object = object
        type = try await runtime.resolve(.swift(.type("CoreDevice.RemoteDevice")))
        supportsFeature = try await type.resolve(.swift(.method("supportsFeature(identifiedBy:)", as: ((String) -> Bool).self)))
    }

    package func supports(_ feature: String) throws -> Bool {
        try unsafe supportsFeature.unsafeInvoke(on: object, feature)
    }

    /// Whether CoreDevice is connected to the device. Its features say what the device has only while it is.
    package func isConnected() async throws -> Bool {
        let infoType = try await runtime.resolve(.swift(.type("CoreDeviceProtocols.DeviceInfo")))
        let stateType = try await runtime.resolve(.swift(.type("CoreDeviceProtocols.DeviceState")))
        let abis: [NativeSwiftType: NativeType] = [stateType: try .opaque(named: stateType.name)]
        let deviceInfo = try await type.resolve(.swift(.getter("deviceInfo", as: (() -> NativeSwiftValue).self)))
        let state = try await infoType.resolve(.swift(.getter("state", as: (() -> NativeSwiftValue).self, valueABIs: abis)))
        let rawValue = try await stateType.resolve(.swift(.getter("rawValue", as: (() -> String).self,
            valueABIs: abis, receiverABI: abis[stateType])))
        let connected = try stateType.makeEnumCase(named: "connected")
        let info = try unsafe deviceInfo.unsafeInvoke(on: object)
        return try unsafe rawValue.unsafeInvoke(on: state.unsafeInvoke(on: info)) == rawValue.unsafeInvoke(on: connected)
    }

    /// Calls `changed` with each change of what CoreDevice knows of the device, starting with what it knows now, until
    /// the stream ends or the caller is cancelled.
    package func followInfoChanges(_ changed: @escaping @MainActor () -> Void) async throws {
        let info = try await runtime.resolve(.swift(.type("CoreDeviceProtocols.DeviceInfo")))
        let stream = try await runtime.resolve(.swift(.type("Swift.AsyncThrowingStream",
            genericArguments: [.type(info), .type((any Error).self)])))
        let changes = try await type.resolve(.swift(.getter("deviceInfoChanges", as: (() -> NativeSwiftValue).self,
            valueABIs: [stream: try .opaque(named: stream.name)])))
        let owner = try unsafe changes.unsafeInvoke(on: object)
        defer { withExtendedLifetime(owner) {} }
        guard let sequence = try owner.withCopy({ $0 as? any AsyncSequence }) else {
            throw DeviceIOError.unavailable("device-info-observation", "The device's changes could not be observed.")
        }
        try await follow(sequence, changed)
    }

    private func follow<S: AsyncSequence>(_ sequence: S, _ changed: @MainActor () -> Void) async throws {
        var iterator = sequence.makeAsyncIterator()
        while try await iterator.next(isolation: #isolation) != nil {
            try Task.checkCancellation()
            changed()
        }
    }

    /// Simulator UDIDs identify hardware records, not keys in DeviceManager.devices.
    package static func simulatorIdentifier(udid: String) async throws -> String? {
        let manager = try await CoreDeviceRuntime.deviceManagerIncludingSimulators()
        let runtime = ABIRuntime.shared
        let managerType = try await runtime.resolve(.swift(.type("CoreDevice.DeviceManager")))
        try await CoreDeviceRuntime.initializeDeviceManager()
        try Task.checkCancellation()
        let devices = try await managerType.resolve(.swift(.getter("devices", as: (() -> [UUID: NativeSwiftValue]).self)))
        let remote = try await runtime.resolve(.swift(.type("CoreDevice.RemoteDevice")))
        let deviceInfo = try await remote.resolve(.swift(.getter("deviceInfo", as: (() -> NativeSwiftValue).self)))
        let infoType = try await runtime.resolve(.swift(.type("CoreDeviceProtocols.DeviceInfo")))
        let readUDID = try await infoType.resolve(.swift(.getter("udid", as: (() -> String?).self)))
        var match: String?
        for (identifier, object) in try unsafe devices.unsafeInvoke(on: manager) {
            let info = try unsafe deviceInfo.unsafeInvoke(on: object)
            if try unsafe readUDID.unsafeInvoke(on: info)?.caseInsensitiveCompare(udid) == .orderedSame {
                guard match == nil else {
                    throw DeviceIOError.unavailable("device-posture-identity", "More than one CoreDevice record matches this simulator's UDID.")
                }
                match = identifier.uuidString
            }
        }
        return match
    }

    package func vncURL() async throws -> URL? {
        let readInfo = try await type.resolve(.swift(.getter("deviceInfo", as: (() -> NativeSwiftValue).self)))
        let info = try unsafe readInfo.unsafeInvoke(on: object)
        let helper = try await runtime.resolve(.swift(.type("CoreDevice.ScreenViewingURLHelper")))
        let urlType = try await runtime.resolve(.swift(.type("CoreDevice.ScreenViewingURLHelper.ScreenViewingURLType")))
        let url = try await helper.resolve(.swift(.staticMethod("url(for:withType:)",
            as: ((NativeSwiftValue, NativeSwiftValue) -> URL?).self)))
        return try unsafe url.unsafeInvoke(info, urlType.makeEnumCase(named: "VNC"))
    }

    package func implementation(capability name: String, feature: String) async throws -> NativeSwiftValue {
        guard try supports(feature) else {
            throw DeviceIOError.unavailable("remote-input-capability", "The device does not currently expose the requested input operation.")
        }
        let capability = try await runtime.resolve(.swift(.type("CoreDevice." + name)))
        let markerType = try await runtime.resolve(.swift(.type("CoreDevice.CapabilityStaticMember", genericArguments: [.type(capability)])))
        let abis: [NativeSwiftType: NativeType] = [markerType: try .opaque(named: markerType.name)]
        let make = try await markerType.resolve(.swift(.initializer("init()", as: (() -> NativeSwiftValue).self, valueABIs: abis)))
        let marker = try unsafe make.unsafeInvoke()
        let get = try await type.resolve(.swift(.method("getImplementation(for:)",
            as: ((NativeSwiftValue) async throws -> NativeSwiftValue).self,
            genericArguments: [.type(capability)], valueABIs: abis)))
        return try await unsafe get.unsafeInvoke(on: object, marker).copyUnderlyingValue()
    }

    package nonisolated static func load(_ path: String) async throws {
        try await CoreDeviceRuntime.loading("remote-screen-runtime") { try await NativeFrameworks.load(path) }
    }
}
