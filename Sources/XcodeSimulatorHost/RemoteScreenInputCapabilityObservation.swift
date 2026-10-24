import ABIBridge

@MainActor
protocol RemoteScreenInputCapabilitySource {
    func follow(onChange: @escaping @MainActor () throws -> Void) async throws
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
                try await source.follow { [weak self] in
                    guard let self, !self.stopped, !Task.isCancelled else { return }
                    try self.reload()
                }
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
        let current = try read()
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

    init(remote: CoreDeviceRemoteScreenDevice) throws {
        self.remote = remote
        let capability = try remote.runtime.resolveSwiftTypeAndWait(named: "CoreDevice.Capability")
        let set = try remote.runtime.resolveSwiftTypeAndWait(named: "Swift.Set", genericArguments: [.type(capability)])
        let stream = try remote.runtime.resolveSwiftTypeAndWait(named: "Swift.AsyncThrowingStream",
            genericArguments: [.type(set), .type((any Error).self)])
        // RemoteDevice exports AsyncThrowingStream<Set<Capability>, Error>; the resilient
        // stream getter returns indirectly, as in DeviceInventoryObservation.
        changes = try remote.type.resolveAndWait(.getter("capabilityChanges", as: (() -> NativeSwiftValue).self,
            valueABIs: [stream: try .opaque(named: stream.name)]))
    }

    func follow(onChange: @escaping @MainActor () throws -> Void) async throws {
        let owner = try unsafe changes.unsafeInvoke(on: remote.object)
        defer { withExtendedLifetime(owner) {} }
        guard let sequence = try owner.withCopy({ $0 as? any AsyncSequence }) else {
            throw CLIError.unavailable("remote-input-observation", "The device's input capability changes could not be observed.")
        }
        // Subscribe before re-reading, so a change between startup's read and subscription
        // cannot leave the snapshot stale while waiting for the next native event.
        try onChange()
        try await follow(sequence, onChange: onChange)
    }

    private func follow<S: AsyncSequence>(_ sequence: S, onChange: @MainActor () throws -> Void) async throws {
        var iterator = sequence.makeAsyncIterator()
        while try await iterator.next(isolation: #isolation) != nil {
            try Task.checkCancellation()
            try onChange()
        }
    }
}
