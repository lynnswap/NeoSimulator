import ABIBridge
import Foundation

/// Reports changes to connected devices so the caller can reload its inventory.
@MainActor
public final class DeviceInventoryObservation {
    public var onChange: (() -> Void)?
    public var onError: ((any Error) -> Void)?

    private let source: any DeviceInventoryChangeSource
    private var startTask: Task<Void, any Error>?
    private var observationTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var stopping = false

    public convenience init() throws {
        self.init(source: CoreDeviceInventoryChangeSource())
    }

    init(source: any DeviceInventoryChangeSource) { self.source = source }

    deinit {
        startTask?.cancel()
        observationTask?.cancel()
    }

    /// Initializes the device service and starts observing its connected-device changes.
    public func start() async throws {
        guard !stopping else { throw CancellationError() }
        if let startTask { try await startTask.value; return }
        guard observationTask == nil else { return }
        let task = Task { [self] in
            try await self.source.initialize()
            try Task.checkCancellation()
            guard !self.stopping else { throw CancellationError() }
            self.observationTask = Task { [weak self, source = self.source] in
                do {
                    try await source.follow { [weak self] in
                        guard let self, !self.stopping, !Task.isCancelled else { return }
                        self.onChange?()
                    }
                } catch {
                    guard let self, !self.stopping, !Task.isCancelled else { return }
                    self.onError?(error)
                }
            }
        }
        startTask = task
        defer { startTask = nil }
        try await task.value
    }

    /// Cancels observation and waits until no further callbacks can be delivered.
    public func stop() async {
        if let stopTask { await stopTask.value; return }
        stopping = true
        let starting = startTask
        let observing = observationTask
        starting?.cancel()
        observing?.cancel()
        let task = Task {
            _ = await starting?.result
            await observing?.value
        }
        stopTask = task
        await task.value
        startTask = nil
        observationTask = nil
    }
}

@MainActor
protocol DeviceInventoryChangeSource {
    func initialize() async throws
    func follow(onChange: @escaping @MainActor () -> Void) async throws
}

@MainActor
private final class CoreDeviceInventoryChangeSource: DeviceInventoryChangeSource {
    @MainActor
    private struct Bindings {
        let manager: NativeSwiftValue
        let initializeManager: NativeSwiftMethod<() async -> Void>
        let changes: NativeSwiftMethod<() -> NativeSwiftValue>

        init() async throws {
            manager = try CoreDeviceRuntime.deviceManagerIncludingSimulators()
            let runtime = ABIRuntime.shared
            let managerType = try await runtime.resolve(.swift(.type("CoreDevice.DeviceManager")))
            initializeManager = try await managerType.resolve(.swift(.method("awaitFullInitialization()", as: (() async -> Void).self)))
            let remote = try await runtime.resolve(.swift(.type("CoreDevice.RemoteDevice")))
            let dictionary = try await runtime.resolve(.swift(.type("Swift.Dictionary",
                genericArguments: [.type(UUID.self), .type(remote)])))
            let stream = try await runtime.resolve(.swift(.type("Swift.AsyncThrowingStream",
                genericArguments: [.type(dictionary), .type((any Error).self)])))
            // AsyncThrowingStream is not @frozen in the SDK; its getter returns the closed value indirectly.
            changes = try await managerType.resolve(.swift(.getter("deviceChanges", as: (() -> NativeSwiftValue).self,
                valueABIs: [stream: try .opaque(named: stream.name)])))
        }
    }

    private var bindings: Bindings?
    func initialize() async throws {
        let bindings = try await Bindings()
        try Task.checkCancellation()
        try await unsafe bindings.initializeManager.unsafeInvoke(on: bindings.manager)
        try Task.checkCancellation()
        self.bindings = bindings
    }

    func follow(onChange: @escaping @MainActor () -> Void) async throws {
        guard let bindings else {
            throw CLIError.unavailable("device-inventory-observation", "Device observation has not been initialized.")
        }
        let owner = try unsafe bindings.changes.unsafeInvoke(on: bindings.manager)
        defer { withExtendedLifetime(owner) {} }
        guard let sequence = try owner.withCopy({ $0 as? any AsyncSequence }) else {
            throw CLIError.unavailable("device-inventory-observation", "Connected-device changes could not be observed.")
        }
        try await follow(sequence, onChange: onChange)
    }

    private func follow<S: AsyncSequence>(_ sequence: S, onChange: @MainActor () -> Void) async throws {
        var iterator = sequence.makeAsyncIterator()
        while try await iterator.next(isolation: #isolation) != nil {
            try Task.checkCancellation()
            onChange()
        }
    }
}
