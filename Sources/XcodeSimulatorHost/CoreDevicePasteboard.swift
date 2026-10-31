import ABIBridge
import AppKit

/// A device pasteboard's transfers with a Mac pasteboard. A transfer replaces the destination with all of the
/// source's items and types.
@_spi(NeoSimulator)
@MainActor
public protocol PasteboardTransport: AnyObject {
    /// Replaces `pasteboard` with the device's pasteboard and returns `pasteboard`'s resulting change count.
    func read(into pasteboard: NSPasteboard) async throws -> Int
    /// Replaces the device's pasteboard with `pasteboard`'s.
    func send(_ pasteboard: NSPasteboard) async throws
    /// Observes the device's later pasteboard changes until the observation ends or the task is cancelled. For each
    /// change that a Mac did not send, `changed` receives the transfer that replaces `pasteboard` with it and returns
    /// `pasteboard`'s resulting change count.
    func observeDeviceChanges(into pasteboard: NSPasteboard,
                              _ changed: @escaping @MainActor (_ write: @escaping @MainActor () async throws -> Int) -> Void) async throws
    /// Observes `pasteboard`'s later changes until the observation ends or the task is cancelled. For each change that
    /// a device did not write, `changed` receives the transfer that replaces the device's pasteboard with it.
    func observeChanges(of pasteboard: NSPasteboard,
                        _ changed: @escaping @MainActor (_ send: @escaping @MainActor () async throws -> Void) -> Void) async throws
}

/// Transfers a default-set simulator's pasteboard through CoreDevice, as `devicectl device pasteboard` does.
/// SimPasteboardPlus, which Simulator.app uses, still reads an iOS 27.2 guest's pasteboard, but its sends no longer
/// replace it.
@_spi(NeoSimulator)
@MainActor
public final class CoreDevicePasteboardTransport: PasteboardTransport {
    static let feature = "com.apple.coredevice.feature.pasteboard"
    /// The device's general pasteboard, as CoreDevice's pasteboard service names it.
    static let devicePasteboard = "general"

    private let remote: CoreDeviceRemoteScreenDevice
    private let bindings: Bindings
    /// The device's pasteboard implementation, which the first transfer or observation resolves.
    private var resolvedService: Service?

    /// Declarations that need no device: Mac pasteboard snapshots, their writing and origin, and a device monitor's
    /// snapshots.
    @MainActor
    struct Bindings {
        let abis: [NativeSwiftType: NativeType]
        /// The framework's error, which the device's pasteboard witnesses throw.
        let failure: any Error
        /// `allResolved`: every type's data, so that neither pasteboard keeps promises that the other side must
        /// resolve after the transfer.
        let policy: NativeSwiftValue
        let deviceSnapshots: NativeAsyncStream
        let macSnapshots: NativeAsyncStream
        let capture: @MainActor (NSPasteboard) async throws -> NativeSwiftValue
        let write: @MainActor (NativeSwiftValue, NSPasteboard) async throws -> Int
        let changes: @MainActor (NSPasteboard) throws -> NativeSwiftValue
        /// Whether a snapshot's items originated on another pasteboard. A pasteboard's own change names itself as its
        /// origin, and a transfer leaves its source's origin on its destination.
        let isTransferred: @MainActor (NativeSwiftValue) throws -> Bool
        let snapshotStream: @MainActor (NativeSwiftValue) throws -> NativeSwiftValue
        let invalidate: @MainActor (NativeSwiftValue) throws -> Void

        init(runtime: ABIRuntime) throws {
            let errorType = try runtime.resolveAndWait(.swift(.type("CoreDevice.CoreDeviceError")))
            let sampleError = try errorType.resolveAndWait(.swift(.staticGetter("ioError", as: (() -> NativeSwiftValue).self,
                valueABIs: [errorType: try .opaque(named: errorType.name)])))
            let owner = try unsafe sampleError.unsafeInvoke()
            // Open the framework's actual Error representation instead of mirroring its resilient layout.
            guard let failure = try owner.withCopy({ $0 as? any Error }) else {
                throw CLIError.unavailable("pasteboard-error-type", "The native pasteboard error type could not be resolved.")
            }
            try self.init(runtime: runtime, failure: failure)
        }

        private init<Failure: Error>(runtime: ABIRuntime, failure: Failure) throws {
            let snapshotType = try runtime.resolveAndWait(.swift(.type("CoreDeviceUtilities.PasteboardSnapshot")))
            let metadataType = try runtime.resolveAndWait(.swift(.type("CoreDeviceUtilities.PasteboardSnapshotMetadata")))
            let policyType = try runtime.resolveAndWait(.swift(.type("CoreDeviceUtilities.PasteboardDataInclusionPolicy")))
            let monitorType = try runtime.resolveAndWait(.swift(.type("CoreDevice.PasteboardMonitorSession")))
            let abis = try Dictionary(uniqueKeysWithValues: [snapshotType, metadataType, policyType].map {
                ($0, try NativeType.opaque(named: $0.name))
            })
            let deviceSnapshots = try NativeAsyncStream(runtime: runtime, element: snapshotType, throwing: true)
            let macSnapshots = try NativeAsyncStream(runtime: runtime, element: snapshotType, throwing: false)
            let policy = try policyType.makeEnumCase(named: "allResolved")
            let capture = try snapshotType.resolveAndWait(.swift(.initializer("init(from:dataPolicy:)",
                as: ((NSPasteboard, NativeSwiftValue) async throws(Failure) -> NativeSwiftValue).self, valueABIs: abis)))
            let write = try snapshotType.resolveAndWait(.swift(.method("write(to:)",
                as: ((NSPasteboard) async throws(Failure) -> Int).self, valueABIs: abis,
                receiverABI: .opaque(named: snapshotType.name))))
            let changes = try snapshotType.resolveAndWait(.swift(.staticMethod("changes(on:dataPolicy:)",
                as: ((NSPasteboard, NativeSwiftValue) -> NativeSwiftValue).self,
                valueABIs: abis.merging(macSnapshots.abis) { a, _ in a })))
            let metadata = try snapshotType.resolveAndWait(.swift(.getter("metadata", as: (() -> NativeSwiftValue?).self,
                valueABIs: abis, receiverABI: .opaque(named: snapshotType.name))))
            let source = try snapshotType.resolveAndWait(.swift(.getter("sourceMetadata", as: (() -> NativeSwiftValue?).self,
                valueABIs: abis, receiverABI: .opaque(named: snapshotType.name))))
            let isSame = try metadataType.resolveAndWait(.swift(.staticMethod("==(_:_:)",
                as: ((NativeSwiftValue, NativeSwiftValue) -> Bool).self, valueABIs: abis)))
            let stream = try monitorType.resolveAndWait(.swift(.getter("snapshotStream", as: (() -> NativeSwiftValue).self,
                valueABIs: deviceSnapshots.abis)))
            let invalidate = try monitorType.resolveAndWait(.swift(.method("invalidate()", as: (() -> Void).self)))
            self.abis = abis
            self.failure = failure
            self.policy = policy
            self.deviceSnapshots = deviceSnapshots
            self.macSnapshots = macSnapshots
            // An initializer owns its arguments, so passing the shared policy would consume it for every later call.
            self.capture = { pasteboard in try await unsafe capture.unsafeInvoke(pasteboard, policy.copy()) }
            self.write = { snapshot, pasteboard in try await unsafe write.unsafeInvoke(on: snapshot, pasteboard) }
            self.changes = { pasteboard in try unsafe changes.unsafeInvoke(pasteboard, policy) }
            isTransferred = { snapshot in
                guard let origin = try unsafe source.unsafeInvoke(on: snapshot) else { return false }
                guard let own = try unsafe metadata.unsafeInvoke(on: snapshot) else { return true }
                return try unsafe !isSame.unsafeInvoke(origin, own)
            }
            snapshotStream = { session in try unsafe stream.unsafeInvoke(on: session) }
            self.invalidate = { session in try unsafe invalidate.unsafeInvoke(on: session) }
        }
    }

    /// The device's pasteboard implementation, whose protocol witnesses only an actual device provides.
    @MainActor
    private struct Service {
        let current: @MainActor () async throws -> NativeSwiftValue
        let replace: @MainActor (NativeSwiftValue) async throws -> Void
        let monitor: @MainActor () async throws -> NativeSwiftValue

        init<Failure: Error>(implementation: NativeSwiftValue, bindings: Bindings, failure: Failure) throws {
            let (name, policy, abis) = (CoreDevicePasteboardTransport.devicePasteboard, bindings.policy, bindings.abis)
            let current = try implementation.type.resolveAndWait(.swift(.method(
                "CoreDevice.PasteboardProtocol.currentPasteboardSnapshot(pasteboardName:dataPolicy:)",
                as: ((String, NativeSwiftValue) async throws(Failure) -> NativeSwiftValue).self, valueABIs: abis)))
            let replace = try implementation.type.resolveAndWait(.swift(.method(
                "CoreDevice.PasteboardProtocol.setPasteboardContents(pasteboardName:pasteboardSnapshot:)",
                as: ((String, NativeSwiftValue) async throws(Failure) -> NativeSwiftValue).self, valueABIs: abis)))
            let monitor = try implementation.type.resolveAndWait(.swift(.method(
                "CoreDevice.PasteboardProtocol.monitorPasteboardChanges(pasteboardName:dataPolicy:includeInitialState:)",
                as: ((String, NativeSwiftValue, Bool) async throws(Failure) -> NativeSwiftValue).self, valueABIs: abis)))
            self.current = { try await unsafe current.unsafeInvoke(on: implementation, name, policy) }
            self.replace = { snapshot in _ = try await unsafe replace.unsafeInvoke(on: implementation, name, snapshot) }
            // Turning synchronization on transfers nothing until the next change.
            self.monitor = { try await unsafe monitor.unsafeInvoke(on: implementation, name, policy, false) }
        }
    }

    /// The pasteboard of a default-set simulator, or nil when CoreDevice does not list it or its pasteboard.
    public static func make(simulatorUDID: String) async throws -> CoreDevicePasteboardTransport? {
        guard let identifier = try await CoreDeviceRemoteScreenDevice.simulatorIdentifier(udid: simulatorUDID) else { return nil }
        let remote = try await CoreDeviceRemoteScreenDevice(identifier: identifier)
        guard try remote.supports(feature) else { return nil }
        return try CoreDevicePasteboardTransport(remote: remote, bindings: Bindings(runtime: remote.runtime))
    }

    private init(remote: CoreDeviceRemoteScreenDevice, bindings: Bindings) {
        self.remote = remote
        self.bindings = bindings
    }

    public func read(into pasteboard: NSPasteboard) async throws -> Int {
        let snapshot = try await service().current()
        return try await bindings.write(snapshot, pasteboard)
    }

    public func send(_ pasteboard: NSPasteboard) async throws {
        let snapshot = try await bindings.capture(pasteboard)
        try await service().replace(snapshot)
    }

    public func observeDeviceChanges(into pasteboard: NSPasteboard,
                                     _ changed: @escaping @MainActor (_ write: @escaping @MainActor () async throws -> Int) -> Void) async throws {
        let bindings = bindings
        let session = try await service().monitor()
        do {
            try await bindings.deviceSnapshots.forEach(bindings.snapshotStream(session)) { snapshot in
                // The change that a send from the Mac made would only bring the Mac's pasteboard back.
                guard try !bindings.isTransferred(snapshot) else { return }
                changed { try await bindings.write(snapshot, pasteboard) }
            }
        } catch {
            do { try bindings.invalidate(session) }
            catch let cleanup {
                throw CLIError.io("pasteboard-observation", "\(error.localizedDescription)\nPasteboard observation cleanup failed: \(cleanup.localizedDescription)")
            }
            throw error
        }
        try bindings.invalidate(session)
    }

    public func observeChanges(of pasteboard: NSPasteboard,
                               _ changed: @escaping @MainActor (_ send: @escaping @MainActor () async throws -> Void) -> Void) async throws {
        let bindings = bindings
        try await bindings.macSnapshots.forEach(bindings.changes(pasteboard)) { snapshot in
            // A device's pasteboard that a transfer wrote here would only go back to a device.
            guard try !bindings.isTransferred(snapshot) else { return }
            changed { try await self.service().replace(snapshot) }
        }
    }

    private func service() async throws -> Service {
        if let resolvedService { return resolvedService }
        let implementation = try await remote.implementation(capability: "PasteboardCapability", feature: Self.feature)
        let service = try Service(implementation: implementation, bindings: bindings, failure: bindings.failure)
        resolvedService = service
        return service
    }
}
