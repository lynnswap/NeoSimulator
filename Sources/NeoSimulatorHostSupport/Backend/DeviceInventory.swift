import NeoSimulatorDeviceIO
import NeoSimulatorKit
import Foundation

extension SimulatorHostController {
    /// Reads simulator catalogs and one CoreDevice snapshot without joining the operation order.
    /// Inventory I/O executes outside this actor; existing renderer registrations remain the ownership source.
    /// Only cancellation throws: a stopped read observed nothing, so it has no devices or issues to publish.
    package func inventory() async throws -> DeviceInventorySnapshot {
        async let snapshot = LiveDeviceInventory.read(using: reads)
        let owners: [RendererRegistration]
        var issues: [DeviceInventoryIssue] = []
        do { owners = try await registeredRenderers() }
        catch {
            owners = []
            issues.append(DeviceInventoryIssue(source: .rendererOwnership, error: error))
        }
        let result = try await snapshot
        let devices = result.devices.map { item -> InventoryDevice in
            guard case .simulator(let device) = item else { return item }
            return .simulator(device.inventoryCopy(owners: owners))
        }
        return DeviceInventorySnapshot(devices: devices, issues: result.issues + issues, sources: result.sources)
    }
}

/// A device with a running renderer answers through that renderer's Xcode, as its inspector does.
extension SimulatorHostController: DeviceStateSource {
    private var liveState: LiveDeviceStateSource {
        LiveDeviceStateSource(reads: reads, xcodeURL: { device in try await self.inspector(for: device).simulatorXcodeURL })
    }

    package func readSettings(_ groups: Set<DeviceSettingsGroup>, of device: InventoryDevice,
                              publish: @escaping @Sendable (DeviceSettingsGroupRead) async -> Void) async {
        await liveState.readSettings(groups, of: device, publish: publish)
    }

    package func write(_ change: DeviceSettingChange, to device: InventoryDevice) async throws {
        try await liveState.write(change, to: device)
    }

    package func backgroundServices(for device: InventoryDevice) async throws -> SimulatorBackgroundServices {
        try await liveState.backgroundServices(for: device)
    }

    package func setBackgroundServices(_ targets: [SimulatorBackgroundServiceTarget], enabled: Bool,
                                       for device: InventoryDevice) async throws -> SimulatorBackgroundServicesUpdate {
        try await liveState.setBackgroundServices(targets, enabled: enabled, for: device)
    }
}

extension SimulatorHostDevice {
    package func inventoryCopy(owners: [RendererRegistration]) -> Self {
        let owner = owners.first { $0.deviceIdentifiers.contains(inventoryID) }
        return inventoryCopy(ownerXcodeURL: owner.map { URL(fileURLWithPath: $0.xcodePath) })
    }
}
