import ABIBridge

@MainActor
protocol RemoteScreenInputCapabilitySource {
    func follow(onSubscribed: @escaping @MainActor () throws -> Void,
                onChange: @escaping @MainActor (Set<RemoteDeviceInputKind>) -> Void) async throws
}

/// Keeps the input owner's feature snapshot current for one screen connection.
@MainActor
final class RemoteScreenInputCapabilityObservation {
    private let source: any RemoteScreenInputCapabilitySource
    private let read: @MainActor () throws -> Set<RemoteDeviceInputKind>
    private let invalidateInputs: @MainActor (Set<RemoteDeviceInputKind>) -> Void
    private var task: Task<Void, Never>?
    private var stopped = false
    private(set) var capabilities: Set<RemoteDeviceInputKind> = []
    private var update: (@MainActor (Set<RemoteDeviceInputKind>) -> Void)?

    init(source: any RemoteScreenInputCapabilitySource,
         read: @escaping @MainActor () throws -> Set<RemoteDeviceInputKind>,
         invalidateInputs: @escaping @MainActor (Set<RemoteDeviceInputKind>) -> Void) {
        self.source = source
        self.read = read
        self.invalidateInputs = invalidateInputs
    }

    deinit { task?.cancel() }

    func start(update: @escaping @MainActor (Set<RemoteDeviceInputKind>) -> Void,
               failure: @escaping @MainActor (any Error) -> Void) throws {
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        self.update = update
        try reload()
        guard task == nil else { return }
        task = Task { [weak self, source] in
            do {
                try await source.follow(onSubscribed: { [weak self] in
                    guard let self, !self.stopped, !Task.isCancelled else { return }
                    try self.reload()
                }, onChange: { [weak self] snapshot in
                    guard let self, !self.stopped, !Task.isCancelled else { return }
                    self.apply(snapshot)
                })
                guard let self, !self.stopped, !Task.isCancelled else { return }
                failure(CLIError.unavailable("remote-input-observation", "The device's input capability observation ended."))
            } catch {
                guard let self, !self.stopped, !Task.isCancelled else { return }
                failure(error)
            }
        }
    }

    func stop() async {
        stopped = true
        update = nil
        capabilities = []
        let pending = task
        pending?.cancel()
        await pending?.value
        task = nil
    }

    private func reload() throws {
        apply(try read())
    }

    private func apply(_ current: Set<RemoteDeviceInputKind>) {
        guard current != capabilities else { return }
        let removed = capabilities.subtracting(current)
        if !removed.isEmpty { invalidateInputs(removed) }
        capabilities = current
        update?(removed)
    }
}

@MainActor
final class CoreDeviceInputCapabilitySource: RemoteScreenInputCapabilitySource {
    private let remote: CoreDeviceRemoteScreenDevice
    private let changes: NativeSwiftMethod<() -> NativeSwiftValue>
    private let markers: [RemoteDeviceInputKind: NativeSwiftValue]

    init(remote: CoreDeviceRemoteScreenDevice) throws {
        self.remote = remote
        let capability = try remote.runtime.resolveSwiftTypeAndWait(named: "CoreDevice.Capability")
        let markerTypes: [RemoteDeviceInputKind: String] = [
            .keyboard: "CoreDevice.KeyboardHIDCapability", .pointer: "CoreDevice.PointerHIDCapability",
            .digitizer: "CoreDevice.DigitizerHIDCapability", .button: "CoreDevice.ButtonHIDCapability",
        ]
        let capabilityABI = try NativeType.opaque(named: capability.name)
        markers = try markerTypes.mapValues { name in
            let type = try remote.runtime.resolveSwiftTypeAndWait(named: name)
            let read = try type.resolveAndWait(.staticGetter("capability", as: (() -> NativeSwiftValue).self,
                valueABIs: [capability: capabilityABI]))
            return try unsafe read.unsafeInvoke()
        }
        let set = try remote.runtime.resolveSwiftTypeAndWait(named: "Swift.Set", genericArguments: [.type(capability)])
        let stream = try remote.runtime.resolveSwiftTypeAndWait(named: "Swift.AsyncThrowingStream",
            genericArguments: [.type(set), .type((any Error).self)])
        // RemoteDevice exports AsyncThrowingStream<Set<Capability>, Error>; the resilient
        // stream getter returns indirectly, as in DeviceInventoryObservation.
        changes = try remote.type.resolveAndWait(.getter("capabilityChanges", as: (() -> NativeSwiftValue).self,
            valueABIs: [stream: try .opaque(named: stream.name)]))
    }

    func follow(onSubscribed: @escaping @MainActor () throws -> Void,
                onChange: @escaping @MainActor (Set<RemoteDeviceInputKind>) -> Void) async throws {
        let owner = try unsafe changes.unsafeInvoke(on: remote.object)
        defer { withExtendedLifetime(owner) {} }
        guard let sequence = try owner.withCopy({ $0 as? any AsyncSequence }) else {
            throw CLIError.unavailable("remote-input-observation", "The device's input capability changes could not be observed.")
        }
        // Subscribe before re-reading, so a change between startup's read and subscription
        // cannot leave the snapshot stale while waiting for the next native event.
        try onSubscribed()
        try await follow(sequence, onChange: onChange)
    }

    private func follow<S: AsyncSequence>(_ sequence: S, onChange: @MainActor (Set<RemoteDeviceInputKind>) -> Void) async throws {
        var iterator = sequence.makeAsyncIterator()
        while let snapshot = try await iterator.next(isolation: #isolation) {
            try Task.checkCancellation()
            // These are historical snapshots. Reading supportsFeature here would collapse
            // a buffered loss/recovery pair into the same restored current value.
            let values = try Self.hashableCapabilities(in: snapshot)
            let kinds = try markers.compactMap { kind, marker in
                try marker.withCopy { value -> RemoteDeviceInputKind? in
                    guard let value = value as? AnyHashable else {
                        throw CLIError.io("remote-input-snapshot", "An input capability marker is not Hashable.")
                    }
                    return values.contains(value) ? kind : nil
                }
            }
            onChange(Set(kinds))
        }
    }

    static func hashableCapabilities(in snapshot: Any) throws -> Set<AnyHashable> {
        guard let values = snapshot as? Set<AnyHashable> else {
            throw CLIError.io("remote-input-snapshot", "The device supplied an unexpected capability snapshot.")
        }
        return values
    }
}
