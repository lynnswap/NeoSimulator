import ABIBridge
import Darwin
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
        try self.init(source: CoreDeviceInventoryChangeSource())
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
    private let manager: NativeSwiftValue
    private let initializeManager: NativeSwiftMethod<() async -> Void>
    private let changes: NativeSwiftMethod<() -> NativeSwiftValue>

    init() throws {
        let binary = "/Library/Developer/PrivateFrameworks/CoreDevice.framework/CoreDevice"
        guard dlopen(binary, RTLD_NOW | RTLD_LOCAL) != nil else {
            let detail = dlerror().map { String(cString: $0) } ?? "Unknown loader error"
            throw CLIError.unavailable("coredevice-runtime", "Could not load CoreDevice: \(detail)")
        }
        let runtime = ABIRuntime.shared
        let managerType = try runtime.resolveSwiftTypeAndWait(named: "CoreDevice.DeviceManager")
        let shared = try managerType.resolveAndWait(.staticGetter("shared", as: (() -> NativeSwiftValue).self))
        manager = try unsafe shared.unsafeInvoke()
        initializeManager = try managerType.resolveAndWait(.method("awaitFullInitialization()", as: (() async -> Void).self))
        let remote = try runtime.resolveSwiftTypeAndWait(named: "CoreDevice.RemoteDevice")
        let dictionary = try runtime.resolveSwiftTypeAndWait(named: "Swift.Dictionary",
            genericArguments: [.type(UUID.self), .type(remote)])
        let stream = try runtime.resolveSwiftTypeAndWait(named: "Swift.AsyncThrowingStream",
            genericArguments: [.type(dictionary), .type((any Error).self)])
        // AsyncThrowingStream is not @frozen in the SDK; its getter returns the closed value indirectly.
        changes = try managerType.resolveAndWait(.getter("deviceChanges", as: (() -> NativeSwiftValue).self,
            valueABIs: [stream: try .opaque(named: stream.name)]))
    }

    func initialize() async throws {
        try await unsafe initializeManager.unsafeInvoke(on: manager)
        try Task.checkCancellation()
    }

    func follow(onChange: @escaping @MainActor () -> Void) async throws {
        let owner = try unsafe changes.unsafeInvoke(on: manager)
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
