import Foundation
import Darwin
import Testing
import Synchronization

@testable import XcodeSimulatorHost

@Suite
struct DeviceManagementTests {
    enum ReleaseOutcome: Sendable { case acknowledged, failed, cancelledCaller }

    @MainActor @Test(.timeLimit(.minutes(1)), arguments: [ReleaseOutcome.acknowledged, .failed, .cancelledCaller])
    func escalationDrainsTheOriginalRendererRelease(_ outcome: ReleaseOutcome) async throws {
        let device = Self.simulator("A", state: "Booted", features: ["com.apple.dt.coredevice.device.shutdown"])
        let fixture = ManagementFixture(hasRenderer: true,
            nativeFeatures: [device.inventoryID: ["com.apple.dt.coredevice.device.shutdown"]])
        let release = PendingRendererRelease()
        var backend = fixture.backend
        backend.release = { renderer, identifier in try await release.release(identifier, from: renderer) }
        let preparedBackend = backend
        let controller = SimulatorHostController(rendererApplicationURL: URL(fileURLWithPath: "/Renderer.app"))
        var requests = release.sent.makeAsyncIterator()
        var events = fixture.events.makeAsyncIterator()
        let normal = Task { await controller.manage(.shutdown, devices: [.simulator(device)], using: preparedBackend) }
        #expect(await requests.next() != nil)
        let queued = Task { try await controller.operation { @Sendable in await release.finished } }
        let force = Task { await controller.manage(.forceShutdown, devices: [.simulator(device)], using: preparedBackend) }
        #expect(await events.next() == .native(device.inventoryID))
        if outcome == .cancelledCaller { force.cancel() }
        #expect(await controller.shutdownTransactions.count == 1)
        release.finishOriginal(error: outcome == .failed ? "Recording cleanup failed" : nil)
        let forced = await force.value.results[0]
        let original = await normal.value.results[0]
        #expect(release.requests.count == 1)
        if outcome == .failed {
            let cleanup = try #require(forced.error as? DeviceManagementCleanupError)
            #expect((cleanup.cleanupErrors.first as? CLIError)?.identifier == "renderer-device-request")
            #expect((original.error as? CLIError)?.identifier == "renderer-device-request")
        } else {
            #expect(forced.error == nil && original.error == nil)
            #expect(forced.completedSteps.contains("Display disconnected"))
            #expect(original.completedSteps.contains("Display disconnected"))
        }
        #expect(forced.completedSteps.contains("Forcibly shut down") && original.completedSteps.contains("Forcibly shut down"))
        #expect(try await queued.value)
        #expect(await fixture.commands.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func forceEscalatesDuringPreparationWithoutStartingALaterNormalShutdown(preparationFails: Bool) async throws {
        let device = Self.simulator("A", state: "Booted", features: ["com.apple.dt.coredevice.device.shutdown"])
        let fixture = ManagementFixture(nativeFeatures: [device.inventoryID: ["com.apple.dt.coredevice.device.shutdown"]])
        let controller = SimulatorHostController(rendererApplicationURL: URL(fileURLWithPath: "/Renderer.app"))
        let preparing = AsyncStream<CheckedContinuation<Void, any Error>>.makeStream()
        var preparations = preparing.stream.makeAsyncIterator()
        let normal = Task {
            await controller.manage(.shutdown, devices: [.simulator(device)], preparingDisplay: { _ in
                try await withCheckedThrowingContinuation { preparing.continuation.yield($0) }
            }, using: fixture.backend)
        }
        let preparation = try #require(await preparations.next())
        var events = fixture.events.makeAsyncIterator()
        let force = Task {
            await controller.manage(.forceShutdown, devices: [.simulator(device)], preparingDisplay: { _ in
                Issue.record("Escalation must reuse the admitted display preparation.")
            }, using: fixture.backend)
        }
        #expect(await events.next() == .native(device.inventoryID))
        if preparationFails { preparation.resume(throwing: CLIError.io("preparation-fixture", "Display cleanup failed")) }
        else { preparation.resume() }
        let forced = await force.value.results[0]
        let result = await normal.value.results[0]
        #expect(forced.completedSteps.contains("Forcibly shut down"))
        #expect((forced.error as? DeviceManagementCleanupError)?.cleanupErrors.count == (preparationFails ? 1 : nil))
        #expect(result.completedSteps.contains("Forcibly shut down"))
        #expect((result.error as? CLIError)?.identifier == (preparationFails ? "preparation-fixture" : nil))
        #expect(await fixture.commands.isEmpty)
        #expect(await fixture.coreDeviceOperations.count == 1)
        #expect(await controller.shutdownTransactions.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func cancellationReachesAnAcceptedEscalationBeforeItsNativeRequest() async throws {
        let device = Self.simulator("A", state: "Booted", features: ["com.apple.dt.coredevice.device.shutdown"])
        let fixture = ManagementFixture(holdsShutdown: true,
            nativeFeatures: [device.inventoryID: ["com.apple.dt.coredevice.device.shutdown"]])
        var backend = fixture.backend
        let native = backend.manageCoreDevice
        let pending = AsyncStream<CheckedContinuation<Void, Never>>.makeStream()
        var requests = pending.stream.makeAsyncIterator()
        backend.manageCoreDevice = { action, identifier in
            await withCheckedContinuation { pending.continuation.yield($0) }
            try Task.checkCancellation()
            try await native(action, identifier)
        }
        let preparedBackend = backend
        let controller = SimulatorHostController(rendererApplicationURL: URL(fileURLWithPath: "/Renderer.app"))
        var events = fixture.events.makeAsyncIterator()
        let normal = Task { await controller.manage(.shutdown, devices: [.simulator(device)], using: preparedBackend) }
        #expect(await events.next() == .command("shutdown", "A"))
        let force = Task { await controller.manage(.forceShutdown, devices: [.simulator(device)], using: preparedBackend) }
        let request = try #require(await requests.next())
        force.cancel()
        request.resume()
        #expect(await force.value.results[0].error is CancellationError)
        #expect(await fixture.coreDeviceOperations.isEmpty)
        await fixture.completeShutdown("A")
        #expect(await normal.value.results[0].error == nil)
    }

    @Test(.timeLimit(.minutes(1))) func forceEscalatesAnOwnedShutdownAndReapsOnlyItsCommand() async throws {
        let device = Self.simulator("A", state: "Booted", features: ["com.apple.dt.coredevice.device.shutdown"])
        let fixture = ManagementFixture(holdsShutdown: true,
            nativeFeatures: [device.inventoryID: ["com.apple.dt.coredevice.device.shutdown"]])
        let controller = SimulatorHostController(rendererApplicationURL: URL(fileURLWithPath: "/Renderer.app"))
        var events = fixture.events.makeAsyncIterator()
        let normal = Task { await controller.manage(.shutdown, devices: [.simulator(device)], using: fixture.backend) }
        #expect(await events.next() == .command("shutdown", "A"))
        let force = Task { await controller.manage(.forceShutdown, devices: [.simulator(device)], using: fixture.backend) }
        #expect(await events.next() == .native(device.inventoryID))
        #expect(await events.next() == .cancelledShutdown("A"))
        let forced = await force.value
        let original = await normal.value
        #expect(forced.results[0].error == nil && forced.results[0].completedSteps == ["Forcibly shut down"])
        #expect(original.results[0].error == nil && original.results[0].completedSteps == ["Forcibly shut down"])
        #expect(await controller.shutdownTransactions.isEmpty)
    }

    @Test(arguments: [DeviceManagementAction.restart, .erase, .remove])
    func forceDoesNotPreemptShutdownStepsOwnedByOtherActions(_ action: DeviceManagementAction) async throws {
        let device = Self.simulator("A", state: "Booted", features: ["com.apple.dt.coredevice.device.shutdown"])
        let fixture = ManagementFixture(holdsShutdown: true,
            nativeFeatures: [device.inventoryID: ["com.apple.dt.coredevice.device.shutdown"]])
        let controller = SimulatorHostController(rendererApplicationURL: URL(fileURLWithPath: "/Renderer.app"))
        var events = fixture.events.makeAsyncIterator()
        let original = Task { await controller.manage(action, devices: [.simulator(device)], using: fixture.backend) }
        #expect(await events.next() == .command("shutdown", "A"))
        let force = Task { await controller.manage(.forceShutdown, devices: [.simulator(device)], using: fixture.backend) }
        await fixture.completeShutdown("A")
        let remaining: [String] = switch action {
        case .restart: ["boot"]
        case .erase: ["erase", "boot"]
        default: ["delete"]
        }
        for command in remaining { #expect(await events.next() == .command(command, "A")) }
        #expect(await events.next() == .native(device.inventoryID))
        #expect(await original.value.results[0].error == nil)
        #expect(await force.value.results[0].error == nil)
    }

    @Test(.timeLimit(.minutes(1))) func failedEscalationKeepsTheOriginalShutdownAndItsResult() async throws {
        let device = Self.simulator("A", state: "Booted", features: ["com.apple.dt.coredevice.device.shutdown"])
        let fixture = ManagementFixture(holdsShutdown: true)
        let controller = SimulatorHostController(rendererApplicationURL: URL(fileURLWithPath: "/Renderer.app"))
        var events = fixture.events.makeAsyncIterator()
        let normal = Task { await controller.manage(.shutdown, devices: [.simulator(device)], using: fixture.backend) }
        #expect(await events.next() == .command("shutdown", "A"))
        let failed = await controller.manage(.forceShutdown, devices: [.simulator(device)], using: fixture.backend)
        #expect((failed.results[0].error as? CLIError)?.identifier == "virtual-machine-capability")
        await fixture.completeShutdown("A")
        let report = await normal.value
        #expect(report.results[0].completedSteps == ["Shut down"] && report.results[0].error == nil)
    }

    @Test(.timeLimit(.minutes(1))) func cancelledEscalationDoesNotSendAForceRequest() async throws {
        let device = Self.simulator("A", state: "Booted", features: ["com.apple.dt.coredevice.device.shutdown"])
        let fixture = ManagementFixture(holdsShutdown: true,
            nativeFeatures: [device.inventoryID: ["com.apple.dt.coredevice.device.shutdown"]])
        let controller = SimulatorHostController(rendererApplicationURL: URL(fileURLWithPath: "/Renderer.app"))
        var events = fixture.events.makeAsyncIterator()
        let normal = Task { await controller.manage(.shutdown, devices: [.simulator(device)], using: fixture.backend) }
        #expect(await events.next() == .command("shutdown", "A"))
        let force = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await controller.manage(.forceShutdown, devices: [.simulator(device)], using: fixture.backend)
        }
        #expect(await force.value.results[0].error is CancellationError)
        #expect(await fixture.coreDeviceOperations.isEmpty)
        await fixture.completeShutdown("A")
        #expect(await normal.value.results[0].error == nil)
    }

    @Test(.timeLimit(.minutes(1))) func cancellableCommandsReapTheirOwnedChildWhenItIgnoresTermination() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ready = directory.appendingPathComponent("ready")
        try #require(mkfifo(ready.path, 0o600) == 0)
        let pid = Task.detached {
            let handle = try FileHandle(forReadingFrom: ready)
            defer { try? handle.close() }
            return try handle.readToEnd() ?? Data()
        }
        let launched = Mutex(false)
        let command = Task {
            try await SimulatorHostController.openDeviceHub(boot: {
                _ = try await SystemCommandRunner.runCancellable(executable: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "trap '' TERM; printf '%s\\n' \"$$\" > \"$1\"; exec /bin/sleep 300", "fixture", ready.path])
            }, launch: { launched.withLock { $0 = true } })
        }
        defer { command.cancel() }
        let child = try #require(Int32(String(decoding: try await pid.value, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        command.cancel()
        await #expect(throws: CancellationError.self) { _ = try await command.value }
        #expect(kill(child, 0) == -1 && errno == ESRCH)
        #expect(!launched.withLock { $0 })
    }

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

    @Test func failedRendererCleanupPreventsNormalShutdownAndPreservesTheFailure() async throws {
        let fixture = ManagementFixture(hasRenderer: true, failsRelease: true)
        let report = await fixture.backend.manage(.shutdown, devices: [.simulator(Self.simulator("A", state: "Booted"))])
        let result = try #require(report.results.first)
        #expect((result.error as? CLIError)?.identifier == "release-fixture")
        #expect(result.completedSteps.isEmpty)
        #expect(await fixture.commands.isEmpty)
        #expect(await fixture.coreDeviceOperations.isEmpty)
        #expect(await fixture.displayConnected)
    }

    @Test func forceShutdownIsDistinctAndTargetsOnlyTheRequestedDevice() async throws {
        let device = Self.simulator("simulator-udid", state: "Shutting Down", features: ["com.apple.dt.coredevice.device.shutdown"])
        let fixture = ManagementFixture(hasRenderer: true, nativeFeatures: [device.inventoryID: ["com.apple.dt.coredevice.device.shutdown"]])
        #expect(InventoryDevice.simulator(device).supports(.forceShutdown))
        #expect(!InventoryDevice.simulator(device).supports(.shutdown))
        let result = await fixture.backend.manage(.forceShutdown, devices: [.simulator(device), .simulator(device)])
        #expect(result.results.count == 1 && result.results[0].deviceID == device.inventoryID)
        #expect(result.results[0].error == nil && result.results[0].completedSteps == ["Forcibly shut down", "Display disconnected"])
        #expect(await fixture.coreDeviceOperations == [.init(action: .forceShutdown, deviceID: device.inventoryID)])
        #expect(await fixture.releasedDevices == [device.inventoryID])
        #expect(await fixture.commands.isEmpty)

        let normal = ManagementFixture()
        let normalDevice = Self.simulator("simulator-udid", state: "Booted")
        let normalResult = await normal.backend.manage(.shutdown, devices: [.simulator(normalDevice)])
        #expect(normalResult.results[0].completedSteps == ["Shut down"])
        #expect(await normal.commands.map(\.arguments) == [["shutdown", "simulator-udid"]])
        #expect(await normal.coreDeviceOperations.isEmpty)
        #expect(!InventoryDevice.simulator(normalDevice).supports(.forceShutdown))
        let custom = Self.simulator("simulator-udid", state: "Booted", path: "/custom", features: ["com.apple.dt.coredevice.device.shutdown"])
        #expect(!InventoryDevice.simulator(custom).supports(.forceShutdown))
        let rejected = await fixture.backend.manage(.forceShutdown, devices: [.simulator(custom)])
        #expect(rejected.results[0].error != nil && rejected.results[0].completedSteps.isEmpty)
        #expect(await fixture.releasedDevices == [device.inventoryID])
    }

    @Test func forceShutdownRetainsPartialFailureAndContinuesOtherTargets() async throws {
        let device = Self.simulator("stale-device", state: "Booted", features: ["com.apple.dt.coredevice.device.shutdown"])
        let other = InventoryDevice.remote(try Self.remote(identifier: "other-command-id", reality: "virtual", features: ["com.apple.dt.coredevice.device.shutdown"]))
        let fixture = ManagementFixture(hasRenderer: true, failsRelease: true,
            virtualFeatures: ["other-command-id": ["com.apple.dt.coredevice.device.shutdown"]])
        let report = await fixture.backend.manage(.forceShutdown, devices: [.simulator(device), other])
        let failure = try #require(report.results[0].error as? DeviceManagementCleanupError)
        #expect((failure.operationError as? CLIError)?.identifier == "virtual-machine-capability")
        #expect((failure.cleanupErrors.first as? CLIError)?.identifier == "release-fixture")
        #expect(report.results[0].completedSteps.isEmpty)
        #expect(report.results[1].error == nil && report.results[1].completedSteps == ["Forcibly shut down"])
        #expect(await fixture.coreDeviceOperations == [.init(action: .forceShutdown, deviceID: other.id)])
        #expect(await fixture.commands.isEmpty)
    }

    @Test func forceRequestsPrecedeBlockedRendererCleanupAndKeepCleanupFailure() async throws {
        let first = Self.simulator("A", state: "Booted")
        let second = Self.simulator("B", state: "Booted")
        let feature: Set<String> = ["com.apple.dt.coredevice.device.shutdown"]
        let fixture = ManagementFixture(hasRenderer: true, holdsRelease: true,
            nativeFeatures: [first.inventoryID: feature, second.inventoryID: feature])
        var events = fixture.events.makeAsyncIterator()
        let managing = Task { await fixture.backend.manage(.forceShutdown, devices: [.simulator(first), .simulator(second)]) }
        #expect(await events.next() == .native(first.inventoryID))
        #expect(await events.next() == .native(second.inventoryID))
        #expect(await events.next() == .release(first.inventoryID))
        #expect(await fixture.releasedDevices.isEmpty)
        await fixture.completeRelease(failing: true)
        #expect(await events.next() == .release(second.inventoryID))
        await fixture.completeRelease(failing: false)
        let report = await managing.value
        let failure = try #require(report.results[0].error as? DeviceManagementCleanupError)
        #expect(failure.operationError == nil)
        #expect((failure.cleanupErrors.first as? CLIError)?.identifier == "release-fixture")
        #expect(report.results[0].completedSteps == ["Forcibly shut down"])
        let presentationFailure = report.results[0].recordingDisplayCleanup(.failure(
            CLIError.io("presentation-fixture", "Local display cleanup failed")))
        let combined = try #require(presentationFailure.error as? DeviceManagementCleanupError)
        #expect(combined.operationError == nil)
        #expect(combined.cleanupErrors.compactMap { ($0 as? CLIError)?.identifier } == ["release-fixture", "presentation-fixture"])
        #expect(report.results[1].error == nil)
        #expect(report.results[1].completedSteps == ["Forcibly shut down", "Display disconnected"])
        #expect(await fixture.coreDeviceOperations.map(\.deviceID) == [first.inventoryID, second.inventoryID])
        #expect(await fixture.commands.isEmpty)
    }

    @MainActor @Test func nativeCommandIdentityIsResolvedWithoutAssumingTheSimulatorUDIDIsACoreDeviceID() async throws {
        var lookup: String?
        let identifier = try await CoreDeviceManagementClient.commandIdentifier(for: .simulator(udid: "hardware-udid", deviceSetPath: nil)) {
            lookup = $0
            return "different-coredevice-command-id"
        }
        #expect(lookup == "hardware-udid" && identifier == "different-coredevice-command-id")
        let remote = try await CoreDeviceManagementClient.commandIdentifier(for: .coreDevice("command-id")) { _ in
            Issue.record("A CoreDevice command identity must not be looked up as a simulator UDID.")
            return nil
        }
        #expect(remote == "command-id")
        await #expect(throws: CLIError.self) {
            _ = try await CoreDeviceManagementClient.commandIdentifier(for: .simulator(udid: "missing", deviceSetPath: nil)) { _ in nil }
        }
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
        let feature = try #require(DeviceManagementAction.pause.coreDeviceFeature)
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
                                  family: String = "iPhone", pairIDs: Set<String> = [], isAvailable: Bool = true,
                                  features: Set<String> = []) -> SimulatorHostDevice {
        SimulatorHostDevice(identifier: identifier, name: identifier, descriptiveName: identifier,
            runtimeIdentifier: "runtime", runtimeName: "iOS 27.0", productFamily: family, state: state,
            deviceSetPath: path, isAvailable: isAvailable, capabilities: features, pairIdentifiers: pairIDs)
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

@MainActor private final class PendingRendererRelease {
    let sent: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let acknowledgements = NotificationCenter()
    private(set) var requests: [[String: String]] = []
    private(set) var finished = false

    init() { (sent, continuation) = AsyncStream.makeStream() }

    func release(_ identifier: DeviceInventoryID, from renderer: RendererRegistration) async throws {
        let waiter = RendererDeviceRequestWaiter(acknowledgements: acknowledgements, scheduleTimeout: { _, _ in {} }) { [self] info, _ in
            requests.append(info)
            continuation.yield(())
            if requests.count > 1 { acknowledge(info, error: finished ? nil : "This simulator is already being handed over.") }
        }
        try await waiter.release(identifier, from: renderer)
    }

    func finishOriginal(error: String? = nil) {
        finished = true
        if let request = requests.first { acknowledge(request, error: error) }
    }

    private func acknowledge(_ request: [String: String], error: String?) {
        var info = request
        info["error"] = error
        acknowledgements.post(name: Notification.Name("dev.lynnswap.NeoSimulator.RendererReleased"),
            object: request["requestIdentifier"], userInfo: info)
    }
}

private actor ManagementFixture {
    enum Event: Equatable, Sendable {
        case native(DeviceInventoryID), release(DeviceInventoryID), command(String, String), cancelledShutdown(String)
    }
    nonisolated let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private var releaseContinuation: CheckedContinuation<Void, any Error>?
    private let holdsRelease: Bool
    private let holdsShutdown: Bool
    private var shutdownWaiters: [String: CheckedContinuation<Void, any Error>] = [:]
    struct Command: Sendable { let arguments: [String]; let path: String?; let xcodeURL: URL? }
    struct NativeOperation: Equatable, Sendable { let action: DeviceManagementAction; let deviceID: DeviceInventoryID }
    let hasRenderer: Bool
    let failsRelease: Bool
    let restartHasWindow: Bool
    let failingCommand: String?
    let failingIdentifier: String?
    let nativeFeatures: [DeviceInventoryID: Set<String>]
    let managementCatalogs: [(URL, [SimulatorHostDevice])]
    private(set) var commands: [Command] = []
    private(set) var displayConnected: Bool
    private(set) var restartRequests = 0
    private(set) var attachRequests = 0
    private(set) var coreDeviceOperations: [NativeOperation] = []
    private(set) var releasedDevices: [DeviceInventoryID] = []
    var virtualOperations: [String] { coreDeviceOperations.compactMap { if case .coreDevice(let id) = $0.deviceID { id } else { nil } } }

    init(hasRenderer: Bool = false, failsRelease: Bool = false, holdsRelease: Bool = false, holdsShutdown: Bool = false, restartHasWindow: Bool = true,
         failingCommand: String? = nil, failingIdentifier: String? = nil, virtualFeatures: [String: Set<String>] = [:],
         managementCatalogs: [(URL, [SimulatorHostDevice])] = [], nativeFeatures: [DeviceInventoryID: Set<String>] = [:]) {
        (events, continuation) = AsyncStream.makeStream()
        self.holdsRelease = holdsRelease
        self.holdsShutdown = holdsShutdown
        self.hasRenderer = hasRenderer
        self.displayConnected = hasRenderer
        self.failsRelease = failsRelease
        self.restartHasWindow = restartHasWindow
        self.failingCommand = failingCommand
        self.failingIdentifier = failingIdentifier
        self.nativeFeatures = nativeFeatures.merging(Dictionary(uniqueKeysWithValues: virtualFeatures.map { (.coreDevice($0.key), $0.value) }), uniquingKeysWith: { _, newer in newer })
        self.managementCatalogs = managementCatalogs
    }

    nonisolated var backend: DeviceManagementBackend {
        DeviceManagementBackend(context: { device, requiresRenderer in try await self.context(device, requiresRenderer: requiresRenderer) }, runSimctl: { xcode, arguments, path in
            try await self.run(arguments, path: path, xcodeURL: xcode)
        }, runDevicectl: { try await self.run($0, path: nil) }, shutdownSimulator: { xcode, identifier, path in
            _ = try await self.run(["shutdown", identifier], path: path, xcodeURL: xcode)
        }, manageCoreDevice: { action, identifier in
            try await self.manageCoreDevice(action, identifier: identifier)
        }, release: { _, identifier in
            try await self.release(identifier)
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

    private func release(_ identifier: DeviceInventoryID) async throws {
        if holdsRelease {
            try await withCheckedThrowingContinuation { waiting in
                releaseContinuation = waiting
                continuation.yield(.release(identifier))
            }
        }
        if failsRelease { throw CLIError.io("release-fixture", "Recording cleanup failed") }
        displayConnected = false
        releasedDevices.append(identifier)
    }

    func completeRelease(failing: Bool) {
        let waiting = releaseContinuation
        releaseContinuation = nil
        if failing { waiting?.resume(throwing: CLIError.io("release-fixture", "Recording cleanup failed")) }
        else { waiting?.resume() }
    }

    private func restart() -> Bool {
        restartRequests += 1
        return restartHasWindow
    }

    private func attach() { attachRequests += 1; displayConnected = true }

    private func manageCoreDevice(_ action: DeviceManagementAction, identifier: DeviceInventoryID) throws {
        guard let feature = action.coreDeviceFeature, nativeFeatures[identifier]?.contains(feature) == true else {
            throw CLIError.unavailable("virtual-machine-capability", "The device no longer exposes the requested management operation.")
        }
        coreDeviceOperations.append(NativeOperation(action: action, deviceID: identifier))
        continuation.yield(.native(identifier))
    }

    private func run(_ arguments: [String], path: String?, xcodeURL: URL? = nil) async throws -> Data {
        if ["shutdown", "erase", "delete"].contains(arguments.first ?? ""), displayConnected {
            throw CLIError.io("unsafe-mutation", "The live display was not released before mutation")
        }
        commands.append(Command(arguments: arguments, path: path, xcodeURL: xcodeURL))
        if arguments.first == failingCommand,
           failingIdentifier == nil || arguments.dropFirst().first == failingIdentifier {
            throw CLIError.io("mutation-fixture", "Synthetic command failure")
        }
        if holdsShutdown, arguments.first == "shutdown", let identifier = arguments.dropFirst().first {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (waiting: CheckedContinuation<Void, any Error>) in
                    if Task.isCancelled { waiting.resume(throwing: CancellationError()); return }
                    shutdownWaiters[identifier] = waiting
                    continuation.yield(.command("shutdown", identifier))
                }
            } onCancel: {
                Task { await self.cancelShutdown(identifier) }
            }
        } else if let command = arguments.first, let identifier = arguments.dropFirst().first {
            continuation.yield(.command(command, identifier))
        }
        if arguments == ["list", "pairs", "--json"] {
            return Data(#"{"pairs":{"actual-pair-id":{"watch":{"udid":"watch-device"},"phone":{"udid":"phone-device"}}}}"#.utf8)
        }
        return Data()
    }

    func completeShutdown(_ identifier: String) { shutdownWaiters.removeValue(forKey: identifier)?.resume() }

    private func cancelShutdown(_ identifier: String) {
        guard let waiter = shutdownWaiters.removeValue(forKey: identifier) else { return }
        continuation.yield(.cancelledShutdown(identifier))
        waiter.resume(throwing: CancellationError())
    }
}
