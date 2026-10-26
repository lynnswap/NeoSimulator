import ABIBridge
import AppKit
@_spi(NeoSimulator) import XcodeSimulatorHost

enum AppResizeEligibility: Equatable, Sendable { case eligible, resizing, unavailable }

struct AppResizeGeometry: Equatable, Sendable {
    var minimumSize: CGSize
    var maximumSize: CGSize
    var preferredSize: CGSize
    var resolvedSize: CGSize
    var cornerRadius: CGFloat
}

@MainActor
protocol SimulatorAppResizeTransport: AnyObject {
    func eligibility() async throws -> AsyncThrowingStream<AppResizeEligibility, any Error>
    func start(size: CGSize, cornerRadius: CGFloat) async throws -> any SimulatorAppResizeLease
}

@MainActor
protocol SimulatorAppResizeLease: AnyObject {
    var displayUniqueID: String { get }
    var geometry: AppResizeGeometry { get }
    func updates() throws -> AsyncThrowingStream<AppResizeGeometry, any Error>
    func adjust(size: CGSize, cornerRadius: CGFloat) async throws
    func awaitInvalidation() async throws
    func invalidate() throws
}

/// CoreDevice identifies simulators by DeviceInfo.udid. Its DeviceManager dictionary
/// is keyed by a different identifier; the selected SimulatorKit device remains the
/// authority for the Xcode, device set, screen, and input connection.
@MainActor
final class NativeSimulatorAppResizeTransport: SimulatorAppResizeTransport {
    private let manager: NativeSwiftValue
    private let remote: NativeSwiftValue
    private let implementation: NativeSwiftValue
    private let runtime: ABIRuntime
    private let abis: [NativeSwiftType: NativeType]
    private let stateType: NativeSwiftType
    private let sceneType: NativeSwiftType
    private let displayType: NativeSwiftType

    static let feature = "com.apple.coredevice.feature.resizableappmanagement"

    static func make(simulatorUDID: String) async throws -> (any SimulatorAppResizeTransport)? {
        let manager = try CoreDeviceRuntime.deviceManagerIncludingSimulators()
        let runtime = ABIRuntime.shared
        let managerType = try runtime.resolveAndWait(.swift(.type("CoreDevice.DeviceManager")))
        let initialize = try managerType.resolveAndWait(.swift(.method("awaitFullInitialization()", as: (() async -> Void).self)))
        try await unsafe initialize.unsafeInvoke(on: manager)
        try Task.checkCancellation()
        let devices = try managerType.resolveAndWait(.swift(.getter("devices", as: (() -> [UUID: NativeSwiftValue]).self)))
        let remoteType = try runtime.resolveAndWait(.swift(.type("CoreDevice.RemoteDevice")))
        let infoType = try runtime.resolveAndWait(.swift(.type("CoreDeviceProtocols.DeviceInfo")))
        let info = try remoteType.resolveAndWait(.swift(.getter("deviceInfo", as: (() -> NativeSwiftValue).self)))
        let udid = try infoType.resolveAndWait(.swift(.getter("udid", as: (() -> String?).self)))
        let matches = try unsafe devices.unsafeInvoke(on: manager).values.filter {
            try unsafe udid.unsafeInvoke(on: info.unsafeInvoke(on: $0))?.caseInsensitiveCompare(simulatorUDID) == .orderedSame
        }
        guard matches.count <= 1 else {
            throw HostError.unavailable("More than one CoreDevice device matches this simulator.")
        }
        guard let remote = matches.first else { return nil }
        let supports = try remoteType.resolveAndWait(.swift(.method("supportsFeature(identifiedBy:)", as: ((String) -> Bool).self)))
        guard try unsafe supports.unsafeInvoke(on: remote, feature) else { return nil }
        let capability = try runtime.resolveAndWait(.swift(.type("CoreDevice.ResizableAppManagementCapability")))
        let markerType = try runtime.resolveAndWait(.swift(.type("CoreDevice.CapabilityStaticMember", genericArguments: [.type(capability)])))
        let markerABIs = [markerType: try NativeType.opaque(named: markerType.name)]
        let marker = try markerType.resolveAndWait(.swift(.initializer("init()", as: (() -> NativeSwiftValue).self, valueABIs: markerABIs)))
        let get = try remoteType.resolveAndWait(.swift(.method("getImplementation(for:)",
            as: ((NativeSwiftValue) async throws -> NativeSwiftValue).self,
            genericArguments: [.type(capability)], valueABIs: markerABIs)))
        let implementation = try await unsafe get.unsafeInvoke(on: remote, marker.unsafeInvoke()).copyUnderlyingValue()
        return try NativeSimulatorAppResizeTransport(manager: manager, remote: remote, implementation: implementation, runtime: runtime)
    }

    private init(manager: NativeSwiftValue, remote: NativeSwiftValue, implementation: NativeSwiftValue, runtime: ABIRuntime) throws {
        self.manager = manager
        self.remote = remote
        self.implementation = implementation
        self.runtime = runtime
        stateType = try runtime.resolveAndWait(.swift(.type("CoreDeviceUtilities.ResizabilityState")))
        sceneType = try runtime.resolveAndWait(.swift(.type("CoreDeviceUtilities.ResizableSceneState")))
        displayType = try runtime.resolveAndWait(.swift(.type("CoreDeviceUtilities.ResizableDisplayInfo")))
        abis = try Dictionary(uniqueKeysWithValues: [stateType, sceneType, displayType].map { ($0, try .opaque(named: $0.name)) })
    }

    func eligibility() async throws -> AsyncThrowingStream<AppResizeEligibility, any Error> {
        let stream = try NativeResizeStream(runtime: runtime, element: stateType, throwing: true)
        let observe = try implementation.type.resolveAndWait(.swift(.method("CoreDevice.ResizableAppManagementProtocol.observeFrontmostAppResizability()",
            as: (() async throws -> NativeSwiftValue).self, valueABIs: abis.merging(stream.abis) { a, _ in a })))
        let value = try await unsafe observe.unsafeInvoke(on: implementation).copyUnderlyingValue()
        guard let resizing = try stateType.makeEnumCase(named: "resizing").withCopy({ $0 as? AnyHashable }) else {
            throw HostError.unavailable("CoreDevice resizability state does not support equality.")
        }
        return try stream.values(value) { value in
            if try value.copyEnumPayloadAndWait(forCase: "hasResizableForegroundApplication") != nil { return .eligible }
            if try value.withCopy({ $0 as? AnyHashable }) == resizing { return .resizing }
            return .unavailable
        }
    }

    func start(size: CGSize, cornerRadius: CGFloat) async throws -> any SimulatorAppResizeLease {
        let getDisplay = try implementation.type.resolveAndWait(.swift(.method("CoreDevice.ResizableAppManagementProtocol.getDisplayForResizing()",
            as: (() async throws -> NativeSwiftValue).self, valueABIs: abis)))
        let display = try await unsafe getDisplay.unsafeInvoke(on: implementation).copyUnderlyingValue()
        try Task.checkCancellation()
        let identifier = try displayType.resolveAndWait(.swift(.getter("displayUniqueId", as: (() -> String).self, valueABIs: abis)))
        let start = try implementation.type.resolveAndWait(.swift(.method("CoreDevice.ResizableAppManagementProtocol.startResizableSession(withDisplayId:preferredSize:cornerRadius:)",
            as: ((String, CGSize, CGFloat) async throws -> NativeSwiftValue).self, valueABIs: abis)))
        let assertion = try await unsafe start.unsafeInvoke(on: implementation, identifier.unsafeInvoke(on: display), size, cornerRadius).copyUnderlyingValue()
        // Do not check cancellation until the returned assertion has an invalidation owner.
        return try NativeSimulatorAppResizeLease(assertion: assertion, runtime: runtime, sceneType: sceneType, abis: abis)
    }
}

@MainActor
private final class NativeSimulatorAppResizeLease: SimulatorAppResizeLease {
    let displayUniqueID: String
    let geometry: AppResizeGeometry
    private let assertion: NativeSwiftValue
    private let runtime: ABIRuntime
    private let sceneType: NativeSwiftType
    private let abis: [NativeSwiftType: NativeType]
    private let invalidateNative: NativeSwiftMethod<() -> Void>
    private let adjustNative: NativeSwiftMethod<(CGSize, CGFloat) async throws -> Void>
    private let wait: NativeSwiftMethod<() async -> Void>
    private var invalidated = false

    init(assertion: NativeSwiftValue, runtime: ABIRuntime, sceneType: NativeSwiftType, abis: [NativeSwiftType: NativeType]) throws {
        self.assertion = assertion
        self.runtime = runtime
        self.sceneType = sceneType
        self.abis = abis
        invalidateNative = try assertion.type.resolveAndWait(.swift(.method("CoreDevice.Invalidatable.invalidate()", as: (() -> Void).self)))
        do {
            let id = try assertion.type.resolveAndWait(.swift(.getter("CoreDevice.ResizableAppSessionAssertion.displayUniqueId", as: (() -> String).self)))
            displayUniqueID = try unsafe id.unsafeInvoke(on: assertion)
            let scene = try assertion.type.resolveAndWait(.swift(.getter("CoreDevice.ResizableAppSessionAssertion.sceneState", as: (() -> NativeSwiftValue).self, valueABIs: abis)))
            geometry = try Self.geometry(unsafe scene.unsafeInvoke(on: assertion), type: sceneType, abis: abis)
            adjustNative = try assertion.type.resolveAndWait(.swift(.method("CoreDevice.ResizableAppSessionAssertion.adjustGeometry(preferredSize:cornerRadius:)",
                as: ((CGSize, CGFloat) async throws -> Void).self)))
            wait = try assertion.type.resolveAndWait(.swift(.method("CoreDevice.ResizableAppSessionAssertion.awaitInvalidation()", as: (() async -> Void).self)))
        } catch {
            do { try unsafe invalidateNative.unsafeInvoke(on: assertion) }
            catch let cleanup { throw HostError.operation("\(error.localizedDescription)\nResize cleanup failed: \(cleanup.localizedDescription)") }
            throw error
        }
    }

    func updates() throws -> AsyncThrowingStream<AppResizeGeometry, any Error> {
        let stream = try NativeResizeStream(runtime: runtime, element: sceneType, throwing: false)
        let observe = try assertion.type.resolveAndWait(.swift(.method("CoreDevice.ResizableAppSessionAssertion.sceneStateUpdates()",
            as: (() -> NativeSwiftValue).self, valueABIs: abis.merging(stream.abis) { a, _ in a })))
        let value = try unsafe observe.unsafeInvoke(on: assertion)
        return try stream.values(value) { [sceneType, abis] in try Self.geometry($0, type: sceneType, abis: abis) }
    }

    func adjust(size: CGSize, cornerRadius: CGFloat) async throws {
        try await unsafe adjustNative.unsafeInvoke(on: assertion, size, cornerRadius)
    }
    func awaitInvalidation() async throws { try await unsafe wait.unsafeInvoke(on: assertion) }
    func invalidate() throws {
        guard !invalidated else { return }
        try unsafe invalidateNative.unsafeInvoke(on: assertion)
        invalidated = true
    }
    isolated deinit {
        do { try invalidate() } catch { hostLog("Could not finish app resizing: \(error.localizedDescription)") }
    }

    private static func geometry(_ value: NativeSwiftValue, type: NativeSwiftType,
                                 abis: [NativeSwiftType: NativeType]) throws -> AppResizeGeometry {
        func size(_ name: String) throws -> CGSize {
            let getter = try type.resolveAndWait(.swift(.getter(name, as: (() -> CGSize).self, valueABIs: abis)))
            return try unsafe getter.unsafeInvoke(on: value)
        }
        let radius = try type.resolveAndWait(.swift(.getter("cornerRadius", as: (() -> CGFloat).self, valueABIs: abis)))
        return try AppResizeGeometry(minimumSize: size("minimumPossibleSize"), maximumSize: size("maximumPossibleSize"),
            preferredSize: size("preferredSize"), resolvedSize: size("resolvedSize"), cornerRadius: unsafe radius.unsafeInvoke(on: value))
    }
}

/// Keeps Swift's resilient AsyncStream and iterator values opaque across the ABI.
@MainActor
private struct NativeResizeStream {
    let abis: [NativeSwiftType: NativeType]
    private let isThrowing: Bool
    init(runtime: ABIRuntime, element: NativeSwiftType, throwing: Bool) throws {
        isThrowing = throwing
        let name = throwing ? "Swift.AsyncThrowingStream" : "Swift.AsyncStream"
        let arguments: [NativeSwiftGenericArgument] = throwing ? [.type(element), .type((any Error).self)] : [.type(element)]
        let stream = try runtime.resolveAndWait(.swift(.type(name, genericArguments: arguments)))
        let iterator = try runtime.resolveAndWait(.swift(.type(name + ".Iterator", genericArguments: arguments)))
        abis = try Dictionary(uniqueKeysWithValues: [element, stream, iterator].map { ($0, try .opaque(named: $0.name)) })
    }
    func values<Value: Sendable>(_ value: NativeSwiftValue,
                                project: @escaping @MainActor (NativeSwiftValue) throws -> Value) throws -> AsyncThrowingStream<Value, any Error> {
        let make = try value.type.resolveAndWait(.swift(.method("makeAsyncIterator()", as: (() -> NativeSwiftValue).self,
            valueABIs: abis, receiverABI: .opaque(named: value.type.name))))
        let iterator = try unsafe make.unsafeInvoke(on: value)
        let readNext: @MainActor () async throws -> NativeSwiftValue?
        if isThrowing {
            let next = try iterator.type.resolveAndWait(.swift(.method("next()", as: (() async throws -> NativeSwiftValue?).self,
                valueABIs: abis, receiverABI: .opaque(named: iterator.type.name))))
            readNext = { try await unsafe next.unsafeInvoke(on: iterator) }
        } else {
            let next = try iterator.type.resolveAndWait(.swift(.method("next()", as: (() async -> NativeSwiftValue?).self,
                valueABIs: abis, receiverABI: .opaque(named: iterator.type.name))))
            readNext = { try await unsafe next.unsafeInvoke(on: iterator) }
        }
        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    while let element = try await readNext() {
                        try Task.checkCancellation()
                        continuation.yield(try project(element))
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
