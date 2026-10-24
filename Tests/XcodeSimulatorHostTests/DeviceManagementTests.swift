import Foundation
import Testing

@testable import XcodeSimulatorHost

@Suite
struct DeviceManagementTests {
    @Test func batchPreservesPartialSuccessAndUsesNamespacedCommandDestinations() async throws {
        let fixture = ManagementFixture(failingCommand: "rename", failingIdentifier: "fails")
        let remote = try Self.remote(identifier: "same", reality: "physical")
        let targets: [InventoryDevice] = [.simulator(Self.simulator("same", path: "/testing")), .simulator(Self.simulator("fails")), .remote(remote)]
        let report = await fixture.backend.manage(.rename("New Name"), devices: targets + [targets[0]])
        #expect(report.results.map(\.deviceID) == targets.map(\.id))
        #expect(report.results[0].completedSteps == ["Renamed"] && report.results[0].error == nil)
        #expect(report.results[1].completedSteps.isEmpty && report.results[1].error != nil)
        #expect(report.results[2].completedSteps == ["Renamed"] && report.results[2].error == nil)
        let commands = await fixture.commands
        #expect(commands.contains { $0.arguments == ["rename", "same", "New Name"] && $0.path == "/testing" })
        #expect(commands.contains { $0.arguments == ["device", "rename", "--device", "same", "--name", "New Name"] })
        #expect(!commands.contains { $0.arguments.contains("hardware-udid") })
    }

    @Test func managementUsesAnAvailableCatalogAndRetainsUnavailableMetadataTargets() async throws {
        let newer = URL(fileURLWithPath: "/NewerXcode.app")
        let compatible = URL(fileURLWithPath: "/CompatibleXcode.app")
        let unavailable = Self.simulator("A", path: "/testing", isAvailable: false)
        let available = Self.simulator("A", path: "/testing")
        let fixture = ManagementFixture(managementCatalogs: [(newer, [unavailable]), (compatible, [available])])
        let report = await fixture.backend.manage(.start, devices: [.simulator(available)])
        #expect(report.results.first?.error == nil)
        let command = try #require(await fixture.commands.first)
        #expect(command.xcodeURL == compatible && command.arguments == ["boot", "A"] && command.path == "/testing")

        let metadata = ManagementFixture(managementCatalogs: [(newer, [unavailable]), (compatible, [unavailable])])
        let renamed = await metadata.backend.manage(.rename("Renamed"), devices: [.simulator(unavailable)])
        #expect(renamed.results.first?.error == nil)
        let rename = try #require(await metadata.commands.first)
        #expect(rename.xcodeURL == newer && rename.arguments == ["rename", "A", "Renamed"])
    }

    @Test func failedRendererCleanupPreventsShutdownAndPreservesTheFailure() async throws {
        let fixture = ManagementFixture(hasRenderer: true, failsRelease: true)
        let report = await fixture.backend.manage(.shutdown, devices: [.simulator(Self.simulator("A", state: "Booted"))])
        let result = try #require(report.results.first)
        #expect((result.error as? CLIError)?.identifier == "release-fixture")
        #expect(result.completedSteps.isEmpty)
        #expect(await fixture.commands.isEmpty)
        #expect(await fixture.displayConnected)
    }

    @Test func existingRendererRestartKeepsItsWindowAndDoesNotRestartTwice() async throws {
        let fixture = ManagementFixture(hasRenderer: true)
        let report = await fixture.backend.manage(.restart, devices: [.simulator(Self.simulator("A", state: "Booted"))])
        #expect(report.results.first?.error == nil)
        #expect(report.results.first?.completedSteps == ["Restarted"])
        #expect(await fixture.restartRequests == 1)
        #expect(await fixture.displayConnected)
        #expect(await fixture.commands.isEmpty)
    }

    @Test func restartWithoutAWindowAwaitsReleaseAndRetainsShutdownWhenBootFails() async throws {
        let fixture = ManagementFixture(hasRenderer: true, restartHasWindow: false, failingCommand: "boot")
        let report = await fixture.backend.manage(.restart, devices: [.simulator(Self.simulator("A", state: "Booted", path: "/testing"))])
        let result = try #require(report.results.first)
        #expect(result.error != nil)
        #expect(result.completedSteps == ["Display disconnected", "Shut down"])
        #expect(!(await fixture.displayConnected))
        #expect(await fixture.attachRequests == 0)
        #expect(await fixture.commands.allSatisfy { $0.path == "/testing" })
    }

    @Test func watchPairingUsesBothDevicesAndUnpairingUsesThePairUUID() async throws {
        let fixture = ManagementFixture()
        let watch = Self.simulator("watch-device", family: "Apple Watch", pairIDs: ["actual-pair-id"])
        let phone = Self.simulator("phone-device")
        let pair = await fixture.backend.manage(.pair, devices: [.simulator(watch), .simulator(phone)])
        #expect(pair.results.count == 2 && pair.results.allSatisfy { $0.error == nil })
        #expect(InventoryDevice.simulator(watch).supports(.unpair))
        #expect(!InventoryDevice.simulator(Self.simulator("unpaired-watch", family: "Apple Watch")).supports(.unpair))
        #expect(!InventoryDevice.simulator(phone).supports(.unpair))
        let unpair = await fixture.backend.manage(.unpair, devices: [.simulator(watch)])
        #expect(unpair.results.first?.error == nil)
        let commands = await fixture.commands.map(\.arguments)
        #expect(commands.contains(["pair", "watch-device", "phone-device"]))
        #expect(commands.contains(["unpair", "actual-pair-id"]))
        #expect(!commands.contains(["unpair", "watch-device"]))
    }

    @Test func unsupportedVirtualOperationsDoNotInvokePhysicalOrSimulatorTransports() async throws {
        let fixture = ManagementFixture()
        let vm = InventoryDevice.remote(try Self.remote(identifier: "vm", reality: "virtual"))
        #expect(!vm.supports(.pause) && !vm.supports(.resume) && !vm.supports(.restart))
        let report = await fixture.backend.manage(.pause, devices: [vm])
        #expect((report.results.first?.error as? CLIError)?.identifier == "virtual-machine-capability")
        #expect(await fixture.commands.isEmpty)
        #expect(vm.supports(.rename("VM")) && vm.supports(.unpair) && !vm.supports(.remove))
        let forgotten = await fixture.backend.manage(.unpair, devices: [vm])
        #expect(forgotten.results.first?.error == nil)
        let other = InventoryDevice.remote(try Self.remote(identifier: "other", reality: "anotherReality"))
        #expect(other.supports(.rename("Other")) && !other.supports(.pair))
        let renamed = await fixture.backend.manage(.rename("Other"), devices: [other])
        #expect(renamed.results.first?.error == nil)
        let publicCommands = await fixture.commands.map(\.arguments)
        #expect(publicCommands.contains(["manage", "unpair", "--device", "vm"]))
        #expect(publicCommands.contains(["device", "rename", "--device", "other", "--name", "Other"]))
        let physical = InventoryDevice.remote(try Self.remote(identifier: "phone", reality: "physical"))
        #expect(physical.supports(.rename("Name")) && physical.supports(.unpair))
        #expect(!physical.supports(.erase) && !physical.supports(.start))
    }

    @Test func virtualManagementUsesLatestCapabilitiesAndKeepsLaterTargetsAfterFailure() async throws {
        let feature = try #require(DeviceManagementAction.pause.virtualMachineFeature)
        let fixture = ManagementFixture(virtualFeatures: ["ready-vm": [feature]])
        let stale = InventoryDevice.remote(try Self.remote(identifier: "stale-vm", reality: "virtual", features: [feature]))
        let ready = InventoryDevice.remote(try Self.remote(identifier: "ready-vm", reality: "virtual", features: [feature]))
        #expect(stale.supports(.pause) && ready.supports(.pause))
        let report = await fixture.backend.manage(.pause, devices: [stale, ready])
        #expect((report.results[0].error as? CLIError)?.identifier == "virtual-machine-capability")
        #expect(report.results[0].completedSteps.isEmpty)
        #expect(report.results[1].error == nil && report.results[1].completedSteps == ["Paused"])
        #expect(await fixture.virtualOperations == ["ready-vm"])
        #expect(await fixture.commands.isEmpty)
    }

    private static func simulator(_ identifier: String, state: String = "Shutdown", path: String? = nil,
                                  family: String = "iPhone", pairIDs: Set<String> = [], isAvailable: Bool = true) -> SimulatorHostDevice {
        SimulatorHostDevice(identifier: identifier, name: identifier, descriptiveName: identifier,
            runtimeIdentifier: "runtime", runtimeName: "iOS 27.0", productFamily: family, state: state,
            deviceSetPath: path, isAvailable: isAvailable, pairIdentifiers: pairIDs)
    }

    private static func remote(identifier: String, reality: String, features: [String] = [
        "com.apple.coredevice.feature.renamedevice", "com.apple.coredevice.feature.unpairdevice"
    ]) throws -> CoreDeviceDevice {
        let data = try JSONSerialization.data(withJSONObject: ["result": ["devices": [[
            "identifier": identifier,
            "properties": ["hardware": ["reality": reality, "udid": "hardware-udid"],
                           "state": ["name": "Synthetic Device"], "connection": ["state": "connected", "pairingState": "paired"]],
            "capabilities": features.map { ["featureIdentifier": $0] }
        ]]]])
        return try #require(CoreDeviceInventoryDecoder.decode(data).first)
    }
}

private actor ManagementFixture {
    struct Command: Sendable { let arguments: [String]; let path: String?; let xcodeURL: URL? }
    let hasRenderer: Bool
    let failsRelease: Bool
    let restartHasWindow: Bool
    let failingCommand: String?
    let failingIdentifier: String?
    let virtualFeatures: [String: Set<String>]
    let managementCatalogs: [(URL, [SimulatorHostDevice])]
    private(set) var commands: [Command] = []
    private(set) var displayConnected: Bool
    private(set) var restartRequests = 0
    private(set) var attachRequests = 0
    private(set) var virtualOperations: [String] = []

    init(hasRenderer: Bool = false, failsRelease: Bool = false, restartHasWindow: Bool = true,
         failingCommand: String? = nil, failingIdentifier: String? = nil, virtualFeatures: [String: Set<String>] = [:],
         managementCatalogs: [(URL, [SimulatorHostDevice])] = []) {
        self.hasRenderer = hasRenderer
        self.displayConnected = hasRenderer
        self.failsRelease = failsRelease
        self.restartHasWindow = restartHasWindow
        self.failingCommand = failingCommand
        self.failingIdentifier = failingIdentifier
        self.virtualFeatures = virtualFeatures
        self.managementCatalogs = managementCatalogs
    }

    nonisolated var backend: DeviceManagementBackend {
        DeviceManagementBackend(context: { device, requiresRenderer in try await self.context(device, requiresRenderer: requiresRenderer) }, runSimctl: { xcode, arguments, path in
            try await self.run(arguments, path: path, xcodeURL: xcode)
        }, runDevicectl: { try await self.run($0, path: nil) }, manageVirtualMachine: { action, identifier in
            try await self.manageVirtualMachine(action, identifier: identifier)
        }, release: { _, _ in
            try await self.release()
        }, restart: { _, _, _ in await self.restart() }, attach: { _, _ in await self.attach() })
    }

    private func context(_ device: SimulatorHostDevice, requiresRenderer: Bool) async throws -> DeviceManagementContext {
        let renderer = hasRenderer && requiresRenderer ? RendererRegistration(processIdentifier: 1, applicationPath: "/Renderer.app",
            xcodePath: "/Xcode.app", sessionIdentifier: "session", deviceIdentifiers: [device.inventoryID]) : nil
        if !managementCatalogs.isEmpty {
            let catalogs = managementCatalogs
            let selected = try await SimulatorHostController.managementDevice(for: device, xcodeURLs: catalogs.map { $0.0 }) { xcode, path in
                return catalogs.first { $0.0 == xcode }?.1.filter { $0.deviceSetPath == path } ?? []
            }
            return DeviceManagementContext(device: selected.device, xcodeURL: selected.xcodeURL, renderer: renderer)
        }
        return DeviceManagementContext(device: device, xcodeURL: URL(fileURLWithPath: "/Xcode.app"), renderer: renderer)
    }

    private func release() throws {
        if failsRelease { throw CLIError.io("release-fixture", "Recording cleanup failed") }
        displayConnected = false
    }

    private func restart() -> Bool {
        restartRequests += 1
        return restartHasWindow
    }

    private func attach() { attachRequests += 1; displayConnected = true }

    private func manageVirtualMachine(_ action: DeviceManagementAction, identifier: String) throws {
        guard let feature = action.virtualMachineFeature, virtualFeatures[identifier]?.contains(feature) == true else {
            throw CLIError.unavailable("virtual-machine-capability", "The device no longer exposes the requested management operation.")
        }
        virtualOperations.append(identifier)
    }

    private func run(_ arguments: [String], path: String?, xcodeURL: URL? = nil) throws -> Data {
        if ["shutdown", "erase", "delete"].contains(arguments.first ?? ""), displayConnected {
            throw CLIError.io("unsafe-mutation", "The live display was not released before mutation")
        }
        commands.append(Command(arguments: arguments, path: path, xcodeURL: xcodeURL))
        if arguments.first == failingCommand,
           failingIdentifier == nil || arguments.dropFirst().first == failingIdentifier {
            throw CLIError.io("mutation-fixture", "Synthetic command failure")
        }
        if arguments == ["list", "pairs", "--json"] {
            return Data(#"{"pairs":{"actual-pair-id":{"watch":{"udid":"watch-device"},"phone":{"udid":"phone-device"}}}}"#.utf8)
        }
        return Data()
    }
}
