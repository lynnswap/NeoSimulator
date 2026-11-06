import ABIBridge
import Foundation
import Observation

@MainActor
package protocol DeviceActiveStateSource {
    func prepare() async throws
    /// Reads the current values of the devices in `identifiers`, or of every device when it is nil, evaluating no
    /// other device. Observation tracks the native properties that the read accesses.
    func read(_ identifiers: Set<UUID>?) throws -> [UUID: Bool]
}

@MainActor
package final class DeviceKitActiveStateSource: DeviceActiveStateSource {
    /// Resolves the declarations only. Reading `ObservedDeviceManager.shared` starts DeviceKit's observation.
    package struct Bindings {
        let shared: NativeSwiftFunction<() -> NativeSwiftValue>
        let devices: NativeSwiftMethod<() -> [NativeSwiftValue]>
        let identifier: NativeSwiftMethod<() -> UUID>
        let isActive: NativeSwiftFunction<(NativeSwiftValue) -> Bool>

        package init(runtime: ABIRuntime) async throws {
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

    package init() {}

    package func prepare() async throws {
        try await CoreDeviceRuntime.loadDeviceKit()
        let bindings = try await Bindings(runtime: .shared)
        try Task.checkCancellation()
        prepared = (bindings, try unsafe bindings.shared.unsafeInvoke())
    }

    package func read(_ identifiers: Set<UUID>?) throws -> [UUID: Bool] {
        guard let prepared else {
            throw DeviceIOError.unavailable("device-active-state", "DeviceKit's device states have not been prepared.")
        }
        let bindings = prepared.bindings
        var values: [UUID: Bool] = [:]
        for device in try unsafe bindings.devices.unsafeInvoke(on: prepared.manager) {
            let identifier = try unsafe bindings.identifier.unsafeInvoke(on: device)
            // The predicate creates the device's DeviceKit coordinator, so an unrequested device must not reach it.
            guard identifiers?.contains(identifier) ?? true else { continue }
            values[identifier] = try unsafe bindings.isActive.unsafeInvoke(device)
        }
        return values
    }
}
