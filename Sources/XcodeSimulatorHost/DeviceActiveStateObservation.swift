import ABIBridge
import Foundation
import Observation

/// DeviceKit's sidebar Active values for the devices that DeviceKit observes in this process.
public struct DeviceActiveStates: Equatable, Sendable {
    private let values: [UUID: Bool]

    /// No values, so every device is unknown.
    public init() { values = [:] }

    init(_ values: [UUID: Bool]) { self.values = values }

    /// DeviceKit's value for the device, or nil when DeviceKit reports none.
    ///
    /// DeviceKit identifies devices by their CoreDevice identifier. Simulators in a custom device set have no
    /// CoreDevice record, so they have no value even when a default-set simulator shares their UDID.
    public func isActive(_ device: InventoryDevice) -> Bool? {
        let identifier = switch device {
        case .simulator(let simulator): simulator.coreDevice?.identifier
        case .remote(let remote): remote.identifier
        }
        return identifier.flatMap(UUID.init(uuidString:)).flatMap { values[$0] }
    }
}

/// Reports DeviceKit's sidebar Active values in this process as their native inputs change.
///
/// DeviceKit computes each value from the device's state and from the interaction and activation of DeviceKit
/// views in this process, such as a native device canvas. Screens shown through SimulatorKit or Neo's remote-screen
/// transports, and other processes such as Device Hub, do not request that interaction. Starting reads DeviceKit's
/// device list, which starts its observation of every device, and the predicate creates a DeviceKit coordinator for
/// each device. DeviceKit exports no API to stop either, so they stay with DeviceKit for the rest of the process.
/// ``stop()`` ends only this object's reads and callbacks.
@MainActor
public final class DeviceActiveStateObservation {
    public var onChange: ((DeviceActiveStates) -> Void)?
    public var onError: ((any Error) -> Void)?

    private let source: any DeviceActiveStateSource
    private var startTask: Task<Void, Never>?
    private var stopped = false
    private var delivered: DeviceActiveStates?

    public convenience init() { self.init(source: DeviceKitActiveStateSource()) }

    init(source: any DeviceActiveStateSource) { self.source = source }

    deinit { startTask?.cancel() }

    /// Prepares DeviceKit, then reports the current values and each later change, or a failure through `onError`.
    public func start() {
        guard !stopped, startTask == nil else { return }
        startTask = Task { [weak self, source] in
            do {
                try await source.prepare()
                guard let self, !self.stopped, !Task.isCancelled else { return }
                self.observe()
            } catch {
                guard let self, !self.stopped, !Task.isCancelled else { return }
                self.onError?(error)
            }
        }
    }

    /// Stops reading and waits until no further callbacks can be delivered.
    public func stop() async {
        stopped = true
        startTask?.cancel()
        await startTask?.value
    }

    private func observe() {
        let result = withObservationTracking {
            Result { try source.read() }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                self.observe()
            }
        }
        switch result {
        case .success(let values):
            let states = DeviceActiveStates(values)
            guard states != delivered else { return }
            delivered = states
            onChange?(states)
        case .failure(let error):
            delivered = nil
            onError?(error)
        }
    }
}

@MainActor
protocol DeviceActiveStateSource {
    func prepare() async throws
    /// Reads the current values; Observation tracks the native properties that the read accesses.
    func read() throws -> [UUID: Bool]
}

@MainActor
final class DeviceKitActiveStateSource: DeviceActiveStateSource {
    /// Resolves the declarations only. Reading `ObservedDeviceManager.shared` starts DeviceKit's observation.
    struct Bindings {
        let shared: NativeSwiftFunction<() -> NativeSwiftValue>
        let devices: NativeSwiftMethod<() -> [NativeSwiftValue]>
        let identifier: NativeSwiftMethod<() -> UUID>
        let isActive: NativeSwiftFunction<(NativeSwiftValue) -> Bool>

        init(runtime: ABIRuntime) async throws {
            let manager = try await runtime.resolve(.swift(.type("DeviceKit.ObservedDeviceManager")))
            shared = try await manager.resolve(.swift(.staticGetter("shared", as: (() -> NativeSwiftValue).self)))
            devices = try await manager.resolve(.swift(.getter("devices", as: (() -> [NativeSwiftValue]).self)))
            let device = try await runtime.resolve(.swift(.type("DeviceKit.ObservedDevice")))
            identifier = try await device.resolve(.swift(.getter("deviceIdentifier", as: (() -> UUID).self)))
            let sidebar = try await runtime.resolve(.swift(.type("DeviceKit.SidebarModel")))
            // The same predicate orders Device Hub's sidebar rows and draws their active artwork.
            isActive = try await sidebar.resolve(.swift(.staticMethod("shouldRenderAsActive(_:)",
                as: ((NativeSwiftValue) -> Bool).self)))
        }
    }

    private var prepared: (bindings: Bindings, manager: NativeSwiftValue)?

    func prepare() async throws {
        try await CoreDeviceDisplayGeometry.loadRuntime()
        let bindings = try await Bindings(runtime: .shared)
        try Task.checkCancellation()
        prepared = (bindings, try unsafe bindings.shared.unsafeInvoke())
    }

    func read() throws -> [UUID: Bool] {
        guard let prepared else {
            throw CLIError.unavailable("device-active-state", "DeviceKit's device states have not been prepared.")
        }
        let bindings = prepared.bindings
        var values: [UUID: Bool] = [:]
        for device in try unsafe bindings.devices.unsafeInvoke(on: prepared.manager) {
            values[try unsafe bindings.identifier.unsafeInvoke(on: device)] = try unsafe bindings.isActive.unsafeInvoke(device)
        }
        return values
    }
}
