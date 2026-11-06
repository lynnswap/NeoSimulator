import ABIBridge
import Foundation

@MainActor
package protocol DeviceInventoryChangeSource {
    func initialize() async throws
    func follow(onChange: @escaping @MainActor () -> Void) async throws
}

@MainActor
package final class CoreDeviceInventoryChangeSource: DeviceInventoryChangeSource {
    package init() {}

    @MainActor
    private struct Bindings {
        let manager: NativeSwiftValue
        let changes: NativeSwiftMethod<() -> NativeSwiftValue>

        init() async throws {
            manager = try await CoreDeviceRuntime.deviceManagerIncludingSimulators()
            let runtime = ABIRuntime.shared
            let managerType = try await runtime.resolve(.swift(.type("CoreDevice.DeviceManager")))
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
    package func initialize() async throws {
        let bindings = try await Bindings()
        try Task.checkCancellation()
        try await CoreDeviceRuntime.initializeDeviceManager()
        try Task.checkCancellation()
        self.bindings = bindings
    }

    package func follow(onChange: @escaping @MainActor () -> Void) async throws {
        guard let bindings else {
            throw DeviceIOError.unavailable("device-inventory-observation", "Device observation has not been initialized.")
        }
        let owner = try unsafe bindings.changes.unsafeInvoke(on: bindings.manager)
        defer { withExtendedLifetime(owner) {} }
        guard let sequence = try owner.withCopy({ $0 as? any AsyncSequence }) else {
            throw DeviceIOError.unavailable("device-inventory-observation", "Connected-device changes could not be observed.")
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
