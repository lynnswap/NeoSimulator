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
    /// change that a Mac did not send, `changed` receives the transfer that replaces `pasteboard` with it. The
    /// transfer returns `pasteboard`'s resulting change count, or nil when it leaves a change that `pasteboard` got
    /// during the transfer in place.
    func observeDeviceChanges(into pasteboard: NSPasteboard,
                              _ changed: @escaping @MainActor (_ write: @escaping @MainActor () async throws -> Int?) -> Void) async throws
    /// Observes `pasteboard`'s later changes until the observation ends or the task is cancelled. For each change that
    /// a device did not write, `changed` receives the transfer that replaces the device's pasteboard with it. A change
    /// that `pasteboard` no longer holds when it is reported, or when its transfer starts, does not transfer.
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
    /// The device pasteboard's version that the latest send left, as the device acknowledged it. A device change at or
    /// before it in the same lifetime is that send's own result or one that a send replaced. It belongs to the
    /// transport, not to its service, because concurrent first transfers can each resolve a service.
    private var acknowledgedVersion: Version?

    /// A pasteboard's change, as CoreDevice stamps a snapshot of it. Change counts order the changes of one
    /// pasteboard's lifetime, which its nonce and name identify, and no others.
    struct Version: Equatable {
        let nonce: String
        let pasteboardName: String
        let changeCount: Int64

        /// Whether this change came before `other` on the same pasteboard in the same lifetime.
        func precedes(_ other: Version) -> Bool {
            nonce == other.nonce && pasteboardName == other.pasteboardName && changeCount < other.changeCount
        }
    }

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
        /// Writes an `allResolved` snapshot without suspending, so that nothing on the main actor changes the Mac
        /// pasteboard between a check of it and the write.
        let write: @MainActor (NativeSwiftValue, NSPasteboard) throws -> Int
        let changes: @MainActor (NSPasteboard) throws -> NativeSwiftValue
        /// Whether a snapshot's items originated on another pasteboard. A pasteboard's own change names itself as its
        /// origin, and a transfer leaves its source's origin on its destination.
        let isTransferred: @MainActor (NativeSwiftValue) throws -> Bool
        /// The change of its pasteboard that a snapshot holds, or nil when the snapshot names none.
        let version: @MainActor (NativeSwiftValue) throws -> Version?
        /// A new snapshot of a snapshot's items that names neither the snapshot's change nor its origin, so that a
        /// pasteboard it is written to holds the items as its own change.
        let unstampedCopy: @MainActor (NativeSwiftValue) throws -> NativeSwiftValue
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
            let itemType = try runtime.resolveAndWait(.swift(.type("CoreDeviceUtilities.PasteboardItem")))
            let monitorType = try runtime.resolveAndWait(.swift(.type("CoreDevice.PasteboardMonitorSession")))
            let abis = try Dictionary(uniqueKeysWithValues: [snapshotType, metadataType, policyType, itemType].map {
                ($0, try NativeType.opaque(named: $0.name))
            })
            let deviceSnapshots = try NativeAsyncStream(runtime: runtime, element: snapshotType, throwing: true)
            let macSnapshots = try NativeAsyncStream(runtime: runtime, element: snapshotType, throwing: false)
            let policy = try policyType.makeEnumCase(named: "allResolved")
            let capture = try snapshotType.resolveAndWait(.swift(.initializer("init(from:dataPolicy:)",
                as: ((NSPasteboard, NativeSwiftValue) async throws(Failure) -> NativeSwiftValue).self, valueABIs: abis)))
            let write = try snapshotType.resolveAndWait(.swift(.method("write(to:)",
                as: ((NSPasteboard) throws(Failure) -> Int).self, valueABIs: abis,
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
            let nonce = try metadataType.resolveAndWait(.swift(.getter("nonce", as: (() -> String).self,
                valueABIs: abis, receiverABI: .opaque(named: metadataType.name))))
            let pasteboardName = try metadataType.resolveAndWait(.swift(.getter("pasteboardName", as: (() -> String).self,
                valueABIs: abis, receiverABI: .opaque(named: metadataType.name))))
            let changeCount = try metadataType.resolveAndWait(.swift(.getter("changeCount", as: (() -> Int64).self,
                valueABIs: abis, receiverABI: .opaque(named: metadataType.name))))
            let items = try snapshotType.resolveAndWait(.swift(.getter("items", as: (() -> [NativeSwiftValue]).self,
                valueABIs: abis, receiverABI: .opaque(named: snapshotType.name))))
            let makeSnapshot = try snapshotType.resolveAndWait(.swift(.initializer("init(items:metadata:sourceMetadata:)",
                as: (([NativeSwiftValue], NativeSwiftValue?, NativeSwiftValue?) -> NativeSwiftValue).self, valueABIs: abis)))
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
            self.write = { snapshot, pasteboard in try unsafe write.unsafeInvoke(on: snapshot, pasteboard) }
            self.changes = { pasteboard in try unsafe changes.unsafeInvoke(pasteboard, policy) }
            isTransferred = { snapshot in
                guard let origin = try unsafe source.unsafeInvoke(on: snapshot) else { return false }
                guard let own = try unsafe metadata.unsafeInvoke(on: snapshot) else { return true }
                return try unsafe !isSame.unsafeInvoke(origin, own)
            }
            version = { snapshot in
                guard let own = try unsafe metadata.unsafeInvoke(on: snapshot) else { return nil }
                return try unsafe Version(nonce: nonce.unsafeInvoke(on: own), pasteboardName: pasteboardName.unsafeInvoke(on: own),
                                          changeCount: changeCount.unsafeInvoke(on: own))
            }
            // Each call copies the items into a new array, which the initializer owns.
            unstampedCopy = { snapshot in try unsafe makeSnapshot.unsafeInvoke(items.unsafeInvoke(on: snapshot), nil, nil) }
            snapshotStream = { session in try unsafe stream.unsafeInvoke(on: session) }
            self.invalidate = { session in try unsafe invalidate.unsafeInvoke(on: session) }
        }
    }

    /// The device's pasteboard implementation, whose protocol witnesses only an actual device provides.
    @MainActor
    private struct Service {
        let current: @MainActor () async throws -> NativeSwiftValue
        /// Replaces the device's pasteboard and returns its resulting snapshot.
        let replace: @MainActor (NativeSwiftValue) async throws -> NativeSwiftValue
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
            self.replace = { snapshot in try await unsafe replace.unsafeInvoke(on: implementation, name, snapshot) }
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
        return try bindings.write(snapshot, pasteboard)
    }

    public func send(_ pasteboard: NSPasteboard) async throws {
        let snapshot = try await bindings.capture(pasteboard)
        try await replace(snapshot, on: service())
    }

    public func observeDeviceChanges(into pasteboard: NSPasteboard,
                                     _ changed: @escaping @MainActor (_ write: @escaping @MainActor () async throws -> Int?) -> Void) async throws {
        let bindings = bindings
        let session = try await service().monitor()
        do {
            try await bindings.deviceSnapshots.forEach(bindings.snapshotStream(session)) { snapshot in
                // The change that a send from the Mac made would only bring the Mac's pasteboard back.
                guard try !bindings.isTransferred(snapshot) else { return }
                // A change that an acknowledged send already replaced is reported late. It would carry the device's
                // older pasteboard over the send's, and cancel the transfers that the app queued after the send.
                let version = try bindings.version(snapshot)
                if let version, let acknowledgedVersion, version == acknowledgedVersion || version.precedes(acknowledgedVersion) {
                    return
                }
                changed { try await self.write(snapshot, version: version, into: pasteboard) }
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
            // The observation can report a copy after the pasteboard changed again, as when a device's write
            // replaced it. The copy would carry the older pasteboard over the device's, and reporting it would also
            // cancel the transfers queued for the later change.
            let version = try bindings.version(snapshot)
            guard Self.isCurrent(version, on: pasteboard) else { return }
            changed {
                let service = try await self.service()
                guard Self.isCurrent(version, on: pasteboard) else { return }
                try await self.replace(snapshot, on: service)
            }
        }
    }

    /// Writes a device change to `pasteboard`. A send that the device acknowledged after the change was observed
    /// replaced it there, so the change's items first go back to the device as the latest copy observed on it. The
    /// write then returns nil when `pasteboard` changed meanwhile, which keeps that later change. `pasteboard` gets the
    /// change itself, whose origin keeps the Mac's observation from sending it back.
    private func write(_ snapshot: NativeSwiftValue, version: Version?, into pasteboard: NSPasteboard) async throws -> Int? {
        if let version, let acknowledgedVersion, version.precedes(acknowledgedVersion) {
            let generation = pasteboard.changeCount
            // The device kept its pasteboard when it was sent its own change back. The items go from a pasteboard of
            // their own instead, as a Mac copy does, so that the device's resulting change names that pasteboard as
            // its origin and its observation does not report it, even before the device acknowledges it.
            let relay = NSPasteboard.withUniqueName()
            defer { relay.releaseGlobally() }
            _ = try bindings.write(bindings.unstampedCopy(snapshot), relay)
            try await replace(bindings.capture(relay), on: service())
            guard pasteboard.changeCount == generation else { return nil }
        }
        return try bindings.write(snapshot, pasteboard)
    }

    /// Replaces the device's pasteboard with `snapshot`, and keeps the version the device acknowledges for the result.
    private func replace(_ snapshot: NativeSwiftValue, on service: Service) async throws {
        let reply = try await service.replace(snapshot)
        guard let version = try bindings.version(reply) else { return }
        // A version of another lifetime replaces the last one, whose count no longer orders the device's changes.
        if let acknowledgedVersion, version == acknowledgedVersion || version.precedes(acknowledgedVersion) { return }
        acknowledgedVersion = version
    }

    /// Whether `pasteboard` still holds the change that `version` names. A change that names none counts as current.
    private static func isCurrent(_ version: Version?, on pasteboard: NSPasteboard) -> Bool {
        guard let version else { return true }
        return version.changeCount == Int64(pasteboard.changeCount)
    }

    private func service() async throws -> Service {
        if let resolvedService { return resolvedService }
        let implementation = try await remote.implementation(capability: "PasteboardCapability", feature: Self.feature)
        let service = try Service(implementation: implementation, bindings: bindings, failure: bindings.failure)
        resolvedService = service
        return service
    }
}
