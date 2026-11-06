import ABIBridge
import AppKit

package enum AppResizeEligibility: Equatable, Sendable { case eligible, resizing, unavailable }

package struct AppResizeGeometry: Equatable, Sendable {
    package var minimumSize: CGSize
    package var maximumSize: CGSize
    package var preferredSize: CGSize
    package var resolvedSize: CGSize
    package var cornerRadius: CGFloat

    package init(minimumSize: CGSize, maximumSize: CGSize, preferredSize: CGSize, resolvedSize: CGSize, cornerRadius: CGFloat) {
        self.minimumSize = minimumSize
        self.maximumSize = maximumSize
        self.preferredSize = preferredSize
        self.resolvedSize = resolvedSize
        self.cornerRadius = cornerRadius
    }
}

@MainActor
package protocol AppResizeTransport: AnyObject {
    func eligibility() async throws -> AsyncThrowingStream<AppResizeEligibility, any Error>
    func start(size: CGSize, cornerRadius: CGFloat) async throws -> any AppResizeSession
}

@MainActor
package protocol AppResizeSession: AnyObject {
    var displayUniqueID: String { get }
    var geometry: AppResizeGeometry { get }
    func updates() throws -> AsyncThrowingStream<AppResizeGeometry, any Error>
    func adjust(size: CGSize, cornerRadius: CGFloat) async throws
    func awaitInvalidation() async throws
    func invalidate() throws
}

/// Connects native app resizing for a CoreDevice device or a mapped Simulator UDID.
@MainActor
package final class CoreDeviceAppResizeTransport: AppResizeTransport {
    private let remote: CoreDeviceRemoteScreenDevice
    private let implementation: NativeSwiftValue
    private let runtime: ABIRuntime
    private let bindings: Bindings
    private let failure: any Error

    package struct Bindings {
        package let abis: [NativeSwiftType: NativeType]
        package let stateType: NativeSwiftType
        package let sceneType: NativeSwiftType
        package let displayType: NativeSwiftType

        package init(runtime: ABIRuntime) async throws {
            stateType = try await runtime.resolve(.swift(.type("CoreDeviceUtilities.ResizabilityState")))
            sceneType = try await runtime.resolve(.swift(.type("CoreDeviceUtilities.ResizableSceneState")))
            displayType = try await runtime.resolve(.swift(.type("CoreDeviceUtilities.ResizableDisplayInfo")))
            abis = try Dictionary(uniqueKeysWithValues: [stateType, sceneType, displayType].map { ($0, try .opaque(named: $0.name)) })
        }
    }

    package struct GeometryBindings {
        private let sizes: [NativeSwiftMethod<() -> CGSize>]
        private let radius: NativeSwiftMethod<() -> CGFloat>

        package init(type: NativeSwiftType, abis: [NativeSwiftType: NativeType]) async throws {
            var sizes: [NativeSwiftMethod<() -> CGSize>] = []
            for name in ["minimumPossibleSize", "maximumPossibleSize", "preferredSize", "resolvedSize"] {
                sizes.append(try await type.resolve(.swift(.getter(name, as: (() -> CGSize).self, valueABIs: abis))))
            }
            self.sizes = sizes
            radius = try await type.resolve(.swift(.getter("cornerRadius", as: (() -> CGFloat).self, valueABIs: abis)))
        }

        package func read(_ value: NativeSwiftValue) throws -> AppResizeGeometry {
            let values = try sizes.map { try unsafe $0.unsafeInvoke(on: value) }
            return try AppResizeGeometry(minimumSize: values[0], maximumSize: values[1], preferredSize: values[2],
                resolvedSize: values[3], cornerRadius: unsafe radius.unsafeInvoke(on: value))
        }
    }

    package static let feature = "com.apple.coredevice.feature.resizableappmanagement"

    package static func make(simulatorUDID: String) async throws -> CoreDeviceAppResizeTransport? {
        guard let identifier = try await CoreDeviceRemoteScreenDevice.simulatorIdentifier(udid: simulatorUDID) else { return nil }
        return try await make(deviceIdentifier: identifier)
    }

    package static func make(deviceIdentifier: String) async throws -> CoreDeviceAppResizeTransport? {
        let remote = try await CoreDeviceRemoteScreenDevice(identifier: deviceIdentifier)
        guard try remote.supports(feature) else { return nil }
        let runtime = remote.runtime
        let implementation = try await remote.implementation(capability: "ResizableAppManagementCapability", feature: feature)
        let errorType = try await runtime.resolve(.swift(.type("CoreDevice.CoreDeviceError")))
        let sampleError = try await errorType.resolve(.swift(.staticGetter("ioError", as: (() -> NativeSwiftValue).self,
            valueABIs: [errorType: try .opaque(named: errorType.name)])))
        let owner = try unsafe sampleError.unsafeInvoke()
        guard let failure = try owner.withCopy({ $0 as? any Error }) else {
            throw CLIError.unavailable("app-resize-error", "The native app resize error type could not be resolved.")
        }
        return try await CoreDeviceAppResizeTransport(remote: remote, implementation: implementation, runtime: runtime, failure: failure)
    }

    private init(remote: CoreDeviceRemoteScreenDevice, implementation: NativeSwiftValue, runtime: ABIRuntime, failure: any Error) async throws {
        self.remote = remote
        self.implementation = implementation
        self.runtime = runtime
        self.failure = failure
        bindings = try await Bindings(runtime: runtime)
    }

    package func eligibility() async throws -> AsyncThrowingStream<AppResizeEligibility, any Error> {
        try await eligibility(failure: failure)
    }

    private func eligibility<Failure: Error>(failure: Failure) async throws -> AsyncThrowingStream<AppResizeEligibility, any Error> {
        let stateType = bindings.stateType
        let abis = bindings.abis
        let stream = try await runtime.prepare { try NativeAsyncStream(runtime: $0, element: stateType, throwing: true) }
        let observe = try await implementation.type.resolve(.swift(.method("CoreDevice.ResizableAppManagementProtocol.observeFrontmostAppResizability()",
            as: (() async throws(Failure) -> NativeSwiftValue).self, valueABIs: abis.merging(stream.abis) { a, _ in a })))
        let value = try await unsafe observe.unsafeInvoke(on: implementation)
        guard let resizing = try stateType.makeEnumCase(named: "resizing").withCopy({ $0 as? AnyHashable }) else {
            throw CLIError.unavailable("app-resize", "CoreDevice resizability state does not support equality.")
        }
        return try stream.values(value) { value in
            if try value.copyEnumPayloadAndWait(forCase: "hasResizableForegroundApplication") != nil { return .eligible }
            if try value.withCopy({ $0 as? AnyHashable }) == resizing { return .resizing }
            return .unavailable
        }
    }

    package func start(size: CGSize, cornerRadius: CGFloat) async throws -> any AppResizeSession {
        try await start(size: size, cornerRadius: cornerRadius, failure: failure)
    }

    private func start<Failure: Error>(size: CGSize, cornerRadius: CGFloat, failure: Failure) async throws -> any AppResizeSession {
        let abis = bindings.abis
        let displayType = bindings.displayType
        let getDisplay = try await implementation.type.resolve(.swift(.method("CoreDevice.ResizableAppManagementProtocol.getDisplayForResizing()",
            as: (() async throws(Failure) -> NativeSwiftValue).self, valueABIs: abis)))
        let display = try await unsafe getDisplay.unsafeInvoke(on: implementation)
        try Task.checkCancellation()
        let identifier = try await displayType.resolve(.swift(.getter("displayUniqueId", as: (() -> String).self,
            valueABIs: abis, receiverABI: .opaque(named: displayType.name))))
        let start = try await implementation.type.resolve(.swift(.method("CoreDevice.ResizableAppManagementProtocol.startResizableSession(withDisplayId:preferredSize:cornerRadius:)",
            as: ((String, CGSize, CGFloat) async throws(Failure) -> NativeSwiftValue).self, valueABIs: abis)))
        let assertion = try await unsafe start.unsafeInvoke(on: implementation, identifier.unsafeInvoke(on: display), size, cornerRadius).copyUnderlyingValue()
        // Do not check cancellation until the returned assertion has an invalidation owner.
        return try await CoreDeviceAppResizeSession(assertion: assertion, runtime: runtime, sceneType: bindings.sceneType, abis: abis, failure: failure)
    }
}

@MainActor
private final class CoreDeviceAppResizeSession: AppResizeSession {
    let displayUniqueID: String
    let geometry: AppResizeGeometry
    private let assertion: NativeSwiftValue
    private let invalidateNative: NativeSwiftMethod<() -> Void>
    private let adjustNative: (CGSize, CGFloat) async throws -> Void
    private let wait: NativeSwiftMethod<() async -> Void>
    private var invalidated = false
    private let geometryBindings: CoreDeviceAppResizeTransport.GeometryBindings
    private let updateStream: NativeAsyncStream
    private let sceneUpdates: NativeSwiftMethod<() -> NativeSwiftValue>

    init<Failure: Error>(assertion: NativeSwiftValue, runtime: ABIRuntime, sceneType: NativeSwiftType, abis: [NativeSwiftType: NativeType], failure: Failure) async throws {
        self.assertion = assertion
        invalidateNative = try await assertion.type.resolve(.swift(.method("CoreDevice.Invalidatable.invalidate()", as: (() -> Void).self)))
        do {
            let id = try await assertion.type.resolve(.swift(.getter("CoreDevice.ResizableAppSessionAssertion.displayUniqueId", as: (() -> String).self)))
            displayUniqueID = try unsafe id.unsafeInvoke(on: assertion)
            let scene = try await assertion.type.resolve(.swift(.getter("CoreDevice.ResizableAppSessionAssertion.sceneState", as: (() -> NativeSwiftValue).self, valueABIs: abis)))
            geometryBindings = try await CoreDeviceAppResizeTransport.GeometryBindings(type: sceneType, abis: abis)
            geometry = try geometryBindings.read(unsafe scene.unsafeInvoke(on: assertion))
            updateStream = try await runtime.prepare { try NativeAsyncStream(runtime: $0, element: sceneType, throwing: false) }
            sceneUpdates = try await assertion.type.resolve(.swift(.method("CoreDevice.ResizableAppSessionAssertion.sceneStateUpdates()",
                as: (() -> NativeSwiftValue).self, valueABIs: abis.merging(updateStream.abis) { a, _ in a })))
            let adjust = try await assertion.type.resolve(.swift(.method("CoreDevice.ResizableAppSessionAssertion.adjustGeometry(preferredSize:cornerRadius:)",
                as: ((CGSize, CGFloat) async throws(Failure) -> Void).self)))
            adjustNative = { size, radius in try await unsafe adjust.unsafeInvoke(on: assertion, size, radius) }
            wait = try await assertion.type.resolve(.swift(.method("CoreDevice.ResizableAppSessionAssertion.awaitInvalidation()", as: (() async -> Void).self)))
        } catch {
            do { try unsafe invalidateNative.unsafeInvoke(on: assertion) }
            catch let cleanup { throw CLIError.io("app-resize", "\(error.localizedDescription)\nResize cleanup failed: \(cleanup.localizedDescription)") }
            throw error
        }
    }

    func updates() throws -> AsyncThrowingStream<AppResizeGeometry, any Error> {
        let value = try unsafe sceneUpdates.unsafeInvoke(on: assertion)
        return try updateStream.values(value) { [geometryBindings] in try geometryBindings.read($0) }
    }

    func adjust(size: CGSize, cornerRadius: CGFloat) async throws {
        try await adjustNative(size, cornerRadius)
    }
    func awaitInvalidation() async throws { try await unsafe wait.unsafeInvoke(on: assertion) }
    func invalidate() throws {
        guard !invalidated else { return }
        try unsafe invalidateNative.unsafeInvoke(on: assertion)
        invalidated = true
    }
    isolated deinit {
        do { try invalidate() } catch { NSLog("Could not finish app resizing: %@", error.localizedDescription) }
    }
}

/// Keeps Swift's resilient AsyncStream and iterator values opaque across the ABI.
@MainActor
package struct NativeAsyncStream {
    package let abis: [NativeSwiftType: NativeType]
    private let isThrowing: Bool
    package nonisolated init(runtime: ABIRuntime, element: NativeSwiftType, throwing: Bool) throws {
        isThrowing = throwing
        let name = throwing ? "Swift.AsyncThrowingStream" : "Swift.AsyncStream"
        let arguments: [NativeSwiftGenericArgument] = throwing ? [.type(element), .type((any Error).self)] : [.type(element)]
        let stream = try runtime.resolveAndWait(.swift(.type(name, genericArguments: arguments)))
        let iterator = try runtime.resolveAndWait(.swift(.type(name + ".Iterator", genericArguments: arguments)))
        abis = try Dictionary(uniqueKeysWithValues: [element, stream, iterator].map { ($0, try .opaque(named: $0.name)) })
    }
    package func values<Value: Sendable>(_ value: NativeSwiftValue,
                                project: @escaping @MainActor (NativeSwiftValue) throws -> Value) throws -> AsyncThrowingStream<Value, any Error> {
        try Task.checkCancellation()
        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    let readNext = try await iterate(value)
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

    /// Hands each element to `body` in order, keeping it a native value for later native calls, until the sequence
    /// ends. Cancelling the task ends the sequence and throws.
    package func forEach(_ value: NativeSwiftValue, _ body: @MainActor (NativeSwiftValue) throws -> Void) async throws {
        let readNext = try await iterate(value)
        while let element = try await readNext() {
            try Task.checkCancellation()
            try body(element)
        }
        try Task.checkCancellation()
    }

    private func iterate(_ value: NativeSwiftValue) async throws -> @MainActor () async throws -> NativeSwiftValue? {
        let make = try await value.type.resolve(.swift(.method("makeAsyncIterator()", as: (() -> NativeSwiftValue).self,
            valueABIs: abis, receiverABI: .opaque(named: value.type.name))))
        let iterator = try unsafe make.unsafeInvoke(on: value)
        if isThrowing {
            let next = try await iterator.type.resolve(.swift(.method("next()", as: (() async throws -> NativeSwiftValue?).self,
                valueABIs: abis, receiverABI: .opaque(named: iterator.type.name))))
            return { try await unsafe next.unsafeInvoke(on: iterator) }
        }
        let next = try await iterator.type.resolve(.swift(.method("next()", as: (() async -> NativeSwiftValue?).self,
            valueABIs: abis, receiverABI: .opaque(named: iterator.type.name))))
        return { try await unsafe next.unsafeInvoke(on: iterator) }
    }
}
