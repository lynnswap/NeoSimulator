import ABIBridge
import Foundation

/// What CoreDevice's virtual machine interface can do to a device.
package enum CoreDeviceManagementOperation: Equatable, Sendable {
    case start, shutdown, forceShutdown, pause, resume, remove

    package var feature: String {
        switch self {
        case .start: "com.apple.dt.coredevice.device.boot"
        case .shutdown, .forceShutdown: "com.apple.dt.coredevice.device.shutdown"
        case .pause: "com.apple.dt.coredevice.virtualmachineplugin.pause"
        case .resume: "com.apple.dt.coredevice.virtualmachineplugin.resumeFromPause"
        case .remove: "com.apple.dt.coredevice.plugin.removedevice"
        }
    }
}

/// Native values and their device manager stay on one actor; callers exchange only identifiers and operations.
@MainActor
package final class CoreDeviceManagementClient {
    private static var current: CoreDeviceManagementClient?
    private let runtime: ABIRuntime
    private let remoteType: NativeSwiftType
    private let manager: NativeSwiftValue
    private let devices: NativeSwiftMethod<() -> [UUID: NativeSwiftValue]>
    private let supportsFeature: NativeSwiftMethod<(String) -> Bool>

    package static func perform(_ operation: CoreDeviceManagementOperation, identifier: String) async throws {
        let client: CoreDeviceManagementClient
        if let current { client = current }
        else {
            client = try await ABIRuntime.shared.prepare { _ in try await CoreDeviceManagementClient() }
            current = client
        }
        try await client.run(operation, identifier: identifier)
    }

    private init() async throws {
        manager = try await CoreDeviceRuntime.deviceManagerIncludingSimulators()
        runtime = .shared
        let managerType = try await runtime.resolve(.swift(.type("CoreDevice.DeviceManager")))
        devices = try await managerType.resolve(.swift(.getter("devices", as: (() -> [UUID: NativeSwiftValue]).self)))
        remoteType = try await runtime.resolve(.swift(.type("CoreDevice.RemoteDevice")))
        supportsFeature = try await remoteType.resolve(.swift(.method("supportsFeature(identifiedBy:)", as: ((String) -> Bool).self)))
    }

    private func run(_ operation: CoreDeviceManagementOperation, identifier: String) async throws {
        try Task.checkCancellation()
        let feature = operation.feature
        guard let uuid = UUID(uuidString: identifier) else {
            throw DeviceIOError.configuration("coredevice-identifier", "The selected CoreDevice identifier is not a UUID.")
        }
        try await CoreDeviceRuntime.initializeDeviceManager()
        try Task.checkCancellation()
        guard let remote = try unsafe devices.unsafeInvoke(on: manager)[uuid] else {
            throw DeviceIOError.unavailable("coredevice-device", "The selected device is no longer available.")
        }
        guard try unsafe supportsFeature.unsafeInvoke(on: remote, feature) else {
            throw DeviceIOError.unavailable("virtual-machine-capability", "The device no longer exposes the requested management operation.")
        }
        switch operation {
        case .start:
            let implementation = try await implementation("BootCapability", on: remote)
            let snapshot = try await runtime.resolve(.swift(.type("CoreDevice.DeviceStateSnapshot")))
            let boot = try await implementation.type.resolve(.swift(.method(
                "VirtualMachineClientSupport.Bootable.boot()", as: (() async throws -> NativeSwiftValue).self,
                valueABIs: [snapshot: try .opaque(named: snapshot.name)])))
            _ = try await unsafe boot.unsafeInvoke(on: implementation)
        case .shutdown, .forceShutdown:
            let implementation = try await implementation("ShutdownCapability", on: remote)
            let shutdown = try await implementation.type.resolve(.swift(.method(
                "VirtualMachineClientSupport.ShutdownDeviceProtocol.shutdown(forcefully:)", as: ((Bool) async throws -> Void).self)))
            try Task.checkCancellation()
            guard try unsafe supportsFeature.unsafeInvoke(on: remote, feature) else {
                throw DeviceIOError.unavailable("virtual-machine-capability", "The device no longer exposes the requested management operation.")
            }
            try await unsafe shutdown.unsafeInvoke(on: implementation, operation == .forceShutdown)
        case .pause, .resume:
            let pausing = operation == .pause
            let implementation = try await implementation(pausing ? "PauseVirtualMachineCapability" : "ResumeVirtualMachineFromPauseCapability", on: remote)
            let operation = try await implementation.type.resolve(.swift(.method(
                pausing ? "VirtualMachineClientSupport.PausableVirtualMachine.pause()" : "VirtualMachineClientSupport.ResumableFromPauseVirtualMachine.resume()",
                as: (() async throws -> Void).self)))
            try await unsafe operation.unsafeInvoke(on: implementation)
        case .remove:
            let remove = try await remoteType.resolve(.swift(.method("remove()", as: (() async throws -> NativeSwiftValue).self)))
            _ = try await unsafe remove.unsafeInvoke(on: remote)
        }
    }

    private func implementation(_ name: String, on remote: NativeSwiftValue) async throws -> NativeSwiftValue {
        let capability = try await runtime.resolve(.swift(.type("VirtualMachineClientSupport." + name)))
        let markerType = try await runtime.resolve(.swift(.type("CoreDevice.CapabilityStaticMember", genericArguments: [.type(capability)])))
        let abis: [NativeSwiftType: NativeType] = [markerType: try .opaque(named: markerType.name)]
        let makeMarker = try await markerType.resolve(.swift(.initializer("init()", as: (() -> NativeSwiftValue).self, valueABIs: abis)))
        let marker = try unsafe makeMarker.unsafeInvoke()
        let get = try await remoteType.resolve(.swift(.method("getImplementation(for:)",
            as: ((NativeSwiftValue) async throws -> NativeSwiftValue).self,
            genericArguments: [.type(capability)], valueABIs: abis)))
        return try await unsafe get.unsafeInvoke(on: remote, marker).copyUnderlyingValue()
    }
}
