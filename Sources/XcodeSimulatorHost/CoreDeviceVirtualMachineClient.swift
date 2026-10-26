import ABIBridge
import Foundation

extension DeviceManagementAction {
    var virtualMachineFeature: String? {
        switch self {
        case .start: "com.apple.dt.coredevice.device.boot"
        case .shutdown: "com.apple.dt.coredevice.device.shutdown"
        case .pause: "com.apple.dt.coredevice.virtualmachineplugin.pause"
        case .resume: "com.apple.dt.coredevice.virtualmachineplugin.resumeFromPause"
        case .remove: "com.apple.dt.coredevice.plugin.removedevice"
        default: nil
        }
    }
}

/// Native values and their device manager stay on one actor; callers exchange only inventory IDs and actions.
@MainActor
final class CoreDeviceVirtualMachineClient {
    private static var current: CoreDeviceVirtualMachineClient?
    private let runtime: ABIRuntime
    private let remoteType: NativeSwiftType
    private let manager: NativeSwiftValue
    private let initialize: NativeSwiftMethod<() async -> Void>
    private let devices: NativeSwiftMethod<() -> [UUID: NativeSwiftValue]>
    private let supportsFeature: NativeSwiftMethod<(String) -> Bool>

    static func perform(_ action: DeviceManagementAction, identifier: String) async throws {
        let client: CoreDeviceVirtualMachineClient
        if let current { client = current }
        else {
            client = try CoreDeviceVirtualMachineClient()
            current = client
        }
        try await client.perform(action, identifier: identifier)
    }

    private init() throws {
        manager = try CoreDeviceRuntime.deviceManagerIncludingSimulators()
        runtime = .shared
        let managerType = try runtime.resolveAndWait(.swift(.type("CoreDevice.DeviceManager")))
        initialize = try managerType.resolveAndWait(.swift(.method("awaitFullInitialization()", as: (() async -> Void).self)))
        devices = try managerType.resolveAndWait(.swift(.getter("devices", as: (() -> [UUID: NativeSwiftValue]).self)))
        remoteType = try runtime.resolveAndWait(.swift(.type("CoreDevice.RemoteDevice")))
        supportsFeature = try remoteType.resolveAndWait(.swift(.method("supportsFeature(identifiedBy:)", as: ((String) -> Bool).self)))
    }

    private func perform(_ action: DeviceManagementAction, identifier: String) async throws {
        try Task.checkCancellation()
        guard let feature = action.virtualMachineFeature else {
            throw CLIError.unavailable("virtual-machine-operation", "This operation is not provided by the virtual machine interface.")
        }
        guard let uuid = UUID(uuidString: identifier) else {
            throw CLIError.configuration("coredevice-identifier", "The selected CoreDevice identifier is not a UUID.")
        }
        try await unsafe initialize.unsafeInvoke(on: manager)
        try Task.checkCancellation()
        guard let remote = try unsafe devices.unsafeInvoke(on: manager)[uuid] else {
            throw CLIError.unavailable("coredevice-device", "The selected device is no longer available.")
        }
        guard try unsafe supportsFeature.unsafeInvoke(on: remote, feature) else {
            throw CLIError.unavailable("virtual-machine-capability", "The device no longer exposes the requested management operation.")
        }
        switch action {
        case .start:
            let implementation = try await implementation("BootCapability", on: remote)
            let snapshot = try runtime.resolveAndWait(.swift(.type("CoreDevice.DeviceStateSnapshot")))
            let boot = try implementation.type.resolveAndWait(.swift(.method(
                "VirtualMachineClientSupport.Bootable.boot()", as: (() async throws -> NativeSwiftValue).self,
                valueABIs: [snapshot: try .opaque(named: snapshot.name)])))
            _ = try await unsafe boot.unsafeInvoke(on: implementation)
        case .shutdown:
            let implementation = try await implementation("ShutdownCapability", on: remote)
            let shutdown = try implementation.type.resolveAndWait(.swift(.method(
                "VirtualMachineClientSupport.ShutdownDeviceProtocol.shutdown(forcefully:)", as: ((Bool) async throws -> Void).self)))
            try await unsafe shutdown.unsafeInvoke(on: implementation, false)
        case .pause, .resume:
            let pausing = action == .pause
            let implementation = try await implementation(pausing ? "PauseVirtualMachineCapability" : "ResumeVirtualMachineFromPauseCapability", on: remote)
            let operation = try implementation.type.resolveAndWait(.swift(.method(
                pausing ? "VirtualMachineClientSupport.PausableVirtualMachine.pause()" : "VirtualMachineClientSupport.ResumableFromPauseVirtualMachine.resume()",
                as: (() async throws -> Void).self)))
            try await unsafe operation.unsafeInvoke(on: implementation)
        case .remove:
            let remove = try remoteType.resolveAndWait(.swift(.method("remove()", as: (() async throws -> NativeSwiftValue).self)))
            _ = try await unsafe remove.unsafeInvoke(on: remote)
        default: break
        }
    }

    private func implementation(_ name: String, on remote: NativeSwiftValue) async throws -> NativeSwiftValue {
        let capability = try runtime.resolveAndWait(.swift(.type("VirtualMachineClientSupport." + name)))
        let markerType = try runtime.resolveAndWait(.swift(.type("CoreDevice.CapabilityStaticMember", genericArguments: [.type(capability)])))
        let abis: [NativeSwiftType: NativeType] = [markerType: try .opaque(named: markerType.name)]
        let makeMarker = try markerType.resolveAndWait(.swift(.initializer("init()", as: (() -> NativeSwiftValue).self, valueABIs: abis)))
        let marker = try unsafe makeMarker.unsafeInvoke()
        let get = try remoteType.resolveAndWait(.swift(.method("getImplementation(for:)",
            as: ((NativeSwiftValue) async throws -> NativeSwiftValue).self,
            genericArguments: [.type(capability)], valueABIs: abis)))
        return try await unsafe get.unsafeInvoke(on: remote, marker).copyUnderlyingValue()
    }
}
