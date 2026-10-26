import Foundation

public enum DeviceManagementAction: Equatable, Sendable {
    case rename(String), clone(String)
    case start, shutdown, forceShutdown, restart, erase, remove, pair, unpair, pause, resume
}

public struct DeviceManagementResult: Sendable {
    public let deviceID: DeviceInventoryID
    public let completedSteps: [String]
    public let createdDeviceID: DeviceInventoryID?
    public let error: (any Error)?

    public func recordingDisplayCleanup(_ outcome: Result<Void, any Error>,
                                        completedStep: String = "Display disconnected") -> Self {
        switch outcome {
        case .success:
            return Self(deviceID: deviceID, completedSteps: completedSteps + [completedStep],
                        createdDeviceID: createdDeviceID, error: error)
        case .failure(let cleanup):
            let previous = error as? DeviceManagementCleanupError
            let operationError: (any Error)? = if let previous { previous.operationError } else { error }
            let combined = DeviceManagementCleanupError(operationError: operationError,
                cleanupErrors: (previous?.cleanupErrors ?? []) + [cleanup])
            return Self(deviceID: deviceID, completedSteps: completedSteps,
                        createdDeviceID: createdDeviceID, error: combined)
        }
    }
}

public struct DeviceManagementCleanupError: LocalizedError {
    public let operationError: (any Error)?
    public let cleanupErrors: [any Error]

    public var errorDescription: String? {
        ([operationError?.localizedDescription].compactMap { $0 }
            + cleanupErrors.map { "Display cleanup failed: \($0.localizedDescription)" }).joined(separator: "\n")
    }
}

public struct DeviceManagementReport: Sendable {
    public let results: [DeviceManagementResult]

    public init(results: [DeviceManagementResult]) { self.results = results }
}

extension InventoryDevice {
    /// Presentation eligibility from the current snapshot. The backend still reports actual operation failures.
    public func supports(_ action: DeviceManagementAction) -> Bool {
        switch self {
        case .simulator(let device):
            switch action {
            case .rename, .remove: return !["Booting", "Shutting Down"].contains(device.state)
            case .clone, .erase: return device.isAvailable && ["Booted", "Shutdown"].contains(device.state)
            case .start: return device.isAvailable && device.state == "Shutdown"
            case .shutdown: return ["Booted", "Booting"].contains(device.state)
            case .forceShutdown:
                return device.deviceSetPath == nil && ["Booted", "Booting", "Shutting Down"].contains(device.state)
                    && device.capabilities.contains("com.apple.dt.coredevice.device.shutdown")
            case .restart: return device.isAvailable && device.state == "Booted"
            case .pair: return device.isAvailable && ["Apple Watch", "iPhone"].contains(device.productFamily)
            case .unpair: return device.productFamily == "Apple Watch" && !device.pairIdentifiers.isEmpty
            case .pause, .resume: return false
            }
        case .remote(let device):
            if action == .forceShutdown, device.bootState == "shutdown" { return false }
            if let feature = action.coreDeviceFeature { return device.capabilities.contains(feature) }
            switch action {
            case .rename: return device.capabilities.contains("com.apple.coredevice.feature.renamedevice")
            case .restart: return device.capabilities.contains("com.apple.coredevice.feature.rebootdevice")
            case .pair: return false
            case .unpair: return device.capabilities.contains("com.apple.coredevice.feature.unpairdevice")
            default: return false
            }
        }
    }
}

struct DeviceManagementContext: Sendable {
    let device: SimulatorHostDevice
    let xcodeURL: URL
    let renderer: RendererRegistration?
}

struct SimulatorShutdownPreparation: Sendable {
    let context: Result<DeviceManagementContext, any Error>
    let completedSteps: [String]
}

extension SimulatorHostController {
    /// Runs each requested target once, preserving completed work and target-specific failures.
    /// Simulator mutations share the existing operation FIFO with opens and host changes.
    /// Force shutdown may join a matching all-simulator shutdown without giving up that FIFO ownership.
    public func manage(_ action: DeviceManagementAction, devices: [InventoryDevice]) async -> DeviceManagementReport {
        await manage(action, devices: devices, preparingDisplay: nil)
    }

    /// Prepares each target's display before its normal mutation, or after all native force requests.
    /// Escalation shares the pending shutdown's preparation and result instead of invoking this callback again.
    /// For simulator shutdown, accepted display preparation drains after caller cancellation; only its CLI is cancelled.
    public func manage(_ action: DeviceManagementAction, devices: [InventoryDevice],
                       preparingDisplay: (@isolated(any) @Sendable (InventoryDevice) async throws -> Void)?) async -> DeviceManagementReport {
        let backend = DeviceManagementBackend(
            context: { try await self.deviceManagementContext(for: $0, requiresRenderer: $1) },
            runSimctl: Self.runManagementSimctl, runDevicectl: Self.runManagementDevicectl,
            shutdownSimulator: Self.shutdownSimulator,
            manageCoreDevice: { action, identifier in try await CoreDeviceManagementClient.perform(action, deviceID: identifier) },
            release: { renderer, identifier in try await RendererDeviceRequestWaiter().release(identifier, from: renderer) },
            restart: { renderer, identifier, erasing in
                try await RendererDeviceRequestWaiter().restart(identifier, in: renderer, erasing: erasing)
            },
            attach: { renderer, identifier in try await RendererDeviceRequestWaiter().open(identifier, in: renderer) }
        )
        return await manage(action, devices: devices, preparingDisplay: preparingDisplay, using: backend)
    }

    func manage(_ action: DeviceManagementAction, devices: [InventoryDevice],
                preparingDisplay: (@isolated(any) @Sendable (InventoryDevice) async throws -> Void)? = nil,
                using backend: DeviceManagementBackend) async -> DeviceManagementReport {
        var seen = Set<DeviceInventoryID>()
        let devices = devices.filter { seen.insert($0.id).inserted }
        if action == .forceShutdown {
            for transaction in shutdownTransactions {
                if let report = await transaction.escalate(devices) { return report }
            }
        }
        guard devices.contains(where: { if case .simulator = $0 { true } else { false } }) else {
            if action == .forceShutdown { return await backend.forceShutdown(devices, preparingDisplay: preparingDisplay) }
            do { for device in devices { try await preparingDisplay?(device) } }
            catch {
                return DeviceManagementReport(results: devices.map {
                    DeviceManagementResult(deviceID: $0.id, completedSteps: [], createdDeviceID: nil, error: error)
                })
            }
            return await backend.manage(action, devices: devices)
        }
        let shutdown: SimulatorShutdownTransaction?
        if action == .shutdown, devices.allSatisfy({ if case .simulator = $0 { true } else { false } }) {
            let transaction = SimulatorShutdownTransaction(devices: devices, backend: backend, preparingDisplay: preparingDisplay)
            shutdownTransactions.append(transaction)
            shutdown = transaction
        } else { shutdown = nil }
        defer {
            if let shutdown { shutdownTransactions.removeAll { $0 === shutdown } }
        }
        do {
            return try await operation {
                if let shutdown { return await shutdown.run() }
                if action == .forceShutdown { return await backend.forceShutdown(devices, preparingDisplay: preparingDisplay) }
                for device in devices { try await preparingDisplay?(device) }
                return await backend.manage(action, devices: devices)
            }
        }
        catch {
            return DeviceManagementReport(results: devices.map {
                DeviceManagementResult(deviceID: $0.id, completedSteps: [], createdDeviceID: nil, error: error)
            })
        }
    }

    private static func shutdownSimulator(_ xcode: URL, _ identifier: String, _ path: String?) async throws {
        let arguments = (path.map { ["--set", $0] } ?? []) + ["shutdown", identifier]
        let environment = ProcessInfo.processInfo.environment.merging([
            "DEVELOPER_DIR": xcode.appendingPathComponent("Contents/Developer").path
        ]) { _, new in new }
        let output = try await SystemCommandRunner.runCancellable(
            executable: URL(fileURLWithPath: ToolConstants.coreSimulatorFrameworkPath)
                .appendingPathComponent(ToolConstants.simctlBinaryPath), arguments: arguments, environment: environment)
        guard output.terminationStatus == 0 else {
            throw CLIError.io("device-management", output.stderrText.isEmpty ? output.stdoutText : output.stderrText)
        }
    }

    @concurrent
    private static func runManagementSimctl(_ xcode: URL, _ arguments: [String], _ path: String?) async throws -> Data {
        let output = try SystemCommandRunner().runSimctl(xcodeURL: xcode, arguments: arguments, deviceSetPath: path)
        guard output.terminationStatus == 0 else {
            throw CLIError.io("device-management", output.stderrText.isEmpty ? output.stdoutText : output.stderrText)
        }
        return output.stdout
    }

    @concurrent
    private static func runManagementDevicectl(_ arguments: [String]) async throws -> Data {
        let output = try SystemCommandRunner().run(
            executable: URL(fileURLWithPath: "/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/Resources/bin/devicectl"),
            arguments: arguments + ["--json-output", "-", "--quiet", "--timeout", "300"])
        guard output.terminationStatus == 0 else {
            throw CLIError.io("device-management", output.stderrText.isEmpty ? output.stdoutText : output.stderrText)
        }
        return output.stdout
    }
}

struct DeviceManagementBackend: Sendable {
    var context: @Sendable (SimulatorHostDevice, Bool) async throws -> DeviceManagementContext
    var runSimctl: @Sendable (URL, [String], String?) async throws -> Data
    var runDevicectl: @Sendable ([String]) async throws -> Data
    var shutdownSimulator: @Sendable (URL, String, String?) async throws -> Void
    var manageCoreDevice: @Sendable (DeviceManagementAction, DeviceInventoryID) async throws -> Void
    var release: @Sendable (RendererRegistration, DeviceInventoryID) async throws -> Void
    /// False means the renderer had no existing window; the backend uses the release/CLI path instead.
    var restart: @Sendable (RendererRegistration, DeviceInventoryID, Bool) async throws -> Bool
    var attach: @Sendable (RendererRegistration, DeviceInventoryID) async throws -> Void

    func manage(_ action: DeviceManagementAction, devices: [InventoryDevice],
                preparingDisplay: (@isolated(any) @Sendable (InventoryDevice) async throws -> Void)? = nil) async -> DeviceManagementReport {
        var seen = Set<DeviceInventoryID>()
        let targets = devices.filter { seen.insert($0.id).inserted }
        if action == .forceShutdown { return await forceShutdown(targets, preparingDisplay: preparingDisplay) }
        var paired: [DeviceInventoryID: DeviceManagementResult] = [:]
        if action == .pair {
            let simulators = targets.compactMap { if case .simulator(let device) = $0 { device } else { nil } }
            if !simulators.isEmpty {
                let results = await pair(simulators)
                paired = Dictionary(uniqueKeysWithValues: results.map { ($0.deviceID, $0) })
            }
        }
        var results: [DeviceManagementResult] = []
        for target in targets {
            if let result = paired[target.id] { results.append(result); continue }
            results.append(await perform(action, on: target, preparingDisplay: preparingDisplay))
        }
        return DeviceManagementReport(results: results)
    }

    func forceShutdown(_ devices: [InventoryDevice],
                       preparingDisplay: (@isolated(any) @Sendable (InventoryDevice) async throws -> Void)? = nil) async -> DeviceManagementReport {
        var seen = Set<DeviceInventoryID>()
        let targets = devices.filter { seen.insert($0.id).inserted }
        let report = await requestForceShutdown(targets)
        // Caller cancellation cannot abandon display work after a native request has taken effect.
        let cleanup = Task { await finishForceShutdown(report, targets: targets, preparingDisplay: preparingDisplay) }
        return await cleanup.value
    }

    func requestForceShutdown(_ targets: [InventoryDevice]) async -> DeviceManagementReport {
        var results: [DeviceManagementResult] = []
        // A renderer may be unresponsive. Send every requested force operation before waiting for cleanup.
        for target in targets {
            var completed: [String] = []
            var failure: (any Error)?
            do {
                try Task.checkCancellation()
                if case .simulator(let device) = target, device.deviceSetPath != nil {
                    throw unavailable(.forceShutdown, target: target)
                }
                try await manageCoreDevice(.forceShutdown, target.id)
                completed.append("Forcibly shut down")
            } catch { failure = error }
            results.append(DeviceManagementResult(deviceID: target.id, completedSteps: completed,
                                                  createdDeviceID: nil, error: failure))
        }
        return DeviceManagementReport(results: results)
    }

    func finishForceShutdown(_ report: DeviceManagementReport, targets: [InventoryDevice],
                             preparingDisplay: (@isolated(any) @Sendable (InventoryDevice) async throws -> Void)? = nil) async -> DeviceManagementReport {
        var results = report.results
        for (index, target) in targets.enumerated() {
            if results[index].error is CancellationError, results[index].completedSteps.isEmpty { continue }
            if case .simulator(let device) = target, device.deviceSetPath == nil {
                do {
                    let resolved = try await context(device, true)
                    if let renderer = resolved.renderer {
                        try await release(renderer, device.inventoryID)
                        results[index] = results[index].recordingDisplayCleanup(.success(()))
                    }
                } catch {
                    results[index] = results[index].recordingDisplayCleanup(.failure(error))
                }
            }
            if let preparingDisplay, target.supports(.forceShutdown) {
                do {
                    try await preparingDisplay(target)
                    results[index] = results[index].recordingDisplayCleanup(.success(()), completedStep: "Display cleanup completed")
                } catch { results[index] = results[index].recordingDisplayCleanup(.failure(error)) }
            }
        }
        return DeviceManagementReport(results: results)
    }

    func prepareShutdown(_ device: SimulatorHostDevice,
                         preparingDisplay: (@isolated(any) @Sendable (InventoryDevice) async throws -> Void)?) async -> SimulatorShutdownPreparation {
        var completed: [String] = []
        do {
            if let preparingDisplay {
                try await preparingDisplay(.simulator(device))
                completed.append("Display cleanup completed")
            }
            let resolved = try await context(device, true)
            if let renderer = resolved.renderer {
                try await release(renderer, device.inventoryID)
                completed.append("Display disconnected")
            }
            return SimulatorShutdownPreparation(context: .success(resolved), completedSteps: completed)
        } catch {
            return SimulatorShutdownPreparation(context: .failure(error), completedSteps: completed)
        }
    }

    func finishShutdown(_ context: DeviceManagementContext, completedSteps: [String]) async -> DeviceManagementResult {
        var completed = completedSteps
        var failure: (any Error)?
        do {
            try Task.checkCancellation()
            try await shutdownSimulator(context.xcodeURL, context.device.identifier, context.device.deviceSetPath)
            completed.append("Shut down")
        } catch { failure = error }
        return DeviceManagementResult(deviceID: context.device.inventoryID, completedSteps: completed,
                                      createdDeviceID: nil, error: failure)
    }

    private func pair(_ devices: [SimulatorHostDevice]) async -> [DeviceManagementResult] {
        var completed: [String] = []
        var failure: (any Error)?
        do {
            try Task.checkCancellation()
            guard devices.count == 2,
                  let watch = devices.first(where: { $0.productFamily == "Apple Watch" }),
                  let phone = devices.first(where: { $0.productFamily == "iPhone" }),
                  watch.deviceSetPath == phone.deviceSetPath else {
                throw CLIError.configuration("simulator-pair", "Select one Apple Watch and one iPhone from the same device set to pair.")
            }
            let resolved = try await context(watch, false)
            _ = try await runSimctl(resolved.xcodeURL, ["pair", watch.identifier, phone.identifier], watch.deviceSetPath)
            completed.append("Paired")
        } catch { failure = error }
        return devices.map { DeviceManagementResult(deviceID: InventoryDevice.simulator($0).id,
            completedSteps: completed, createdDeviceID: nil, error: failure) }
    }

    private func perform(_ action: DeviceManagementAction, on target: InventoryDevice,
                         preparingDisplay: (@isolated(any) @Sendable (InventoryDevice) async throws -> Void)?) async -> DeviceManagementResult {
        var completed: [String] = []
        var created: DeviceInventoryID?
        do {
            try Task.checkCancellation()
            switch target {
            case .simulator(let original):
                let needsCleanup: Bool = switch action { case .restart, .erase, .remove: true; default: false }
                let resolved: DeviceManagementContext
                if action == .shutdown {
                    let preparation = await prepareShutdown(original, preparingDisplay: preparingDisplay)
                    completed = preparation.completedSteps
                    resolved = try preparation.context.get()
                } else { resolved = try await context(original, needsCleanup) }
                let device = resolved.device
                let identifier = device.identifier
                func command(_ arguments: [String], step: String) async throws -> Data {
                    try Task.checkCancellation()
                    let output = try await runSimctl(resolved.xcodeURL, arguments, device.deviceSetPath)
                    completed.append(step)
                    return output
                }
                let usesRestart: Bool = action == .restart || (action == .erase && device.state == "Booted")
                var handledByRenderer = false
                if usesRestart, let renderer = resolved.renderer {
                    handledByRenderer = try await restart(renderer, device.inventoryID, action == .erase)
                    if handledByRenderer { completed.append(action == .erase ? "Erased and restarted" : "Restarted") }
                }
                if !handledByRenderer {
                    if needsCleanup, let renderer = resolved.renderer {
                        try await release(renderer, device.inventoryID)
                        completed.append("Display disconnected")
                    }
                    switch action {
                    case .rename(let name): _ = try await command(["rename", identifier, name], step: "Renamed")
                    case .clone(let name):
                        let output = try await command(["clone", identifier, name], step: "Cloned")
                        let clone = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                        created = .simulator(udid: clone, deviceSetPath: device.deviceSetPath)
                    case .start: _ = try await command(["boot", identifier], step: "Started")
                    case .shutdown:
                        return await finishShutdown(resolved, completedSteps: completed)
                    case .restart, .erase, .remove:
                        let wasRunning = ["Booted", "Booting"].contains(device.state)
                        if wasRunning { _ = try await command(["shutdown", identifier], step: "Shut down") }
                        var eraseFailure: (any Error)?
                        if action == .erase {
                            do { _ = try await command(["erase", identifier], step: "Erased") }
                            catch { eraseFailure = error }
                        }
                        if action == .remove { _ = try await command(["delete", identifier], step: "Removed") }
                        if action == .restart || (action == .erase && wasRunning) {
                            do { _ = try await command(["boot", identifier], step: "Started") }
                            catch {
                                if let eraseFailure {
                                    throw CLIError.io("device-management", "Erasing failed: \(eraseFailure.localizedDescription) Restarting also failed: \(error.localizedDescription)")
                                }
                                throw error
                            }
                            if let renderer = resolved.renderer {
                                do {
                                    try await attach(renderer, device.inventoryID)
                                    completed.append("Display reopened")
                                } catch {
                                    if let eraseFailure {
                                        throw CLIError.io("device-management", "Erasing failed: \(eraseFailure.localizedDescription) Reopening the display also failed: \(error.localizedDescription)")
                                    }
                                    throw error
                                }
                            }
                        }
                        if let eraseFailure { throw eraseFailure }
                    case .unpair:
                        let data = try await runSimctl(resolved.xcodeURL, ["list", "pairs", "--json"], device.deviceSetPath)
                        let pairs = try JSONDecoder().decode(PairList.self, from: data).pairs
                        for (identifier, pair) in pairs.sorted(by: { $0.key < $1.key }) where pair.watch.udid == device.identifier || pair.phone.udid == device.identifier {
                            _ = try await command(["unpair", identifier], step: "Unpaired")
                        }
                    case .pair, .pause, .resume, .forceShutdown: throw unavailable(action, target: target)
                    }
                }
            case .remote(let device):
                if action.coreDeviceFeature != nil {
                    try await manageCoreDevice(action, target.id)
                    let step = switch action {
                    case .start: "Started"
                    case .shutdown: "Shut down"
                    case .forceShutdown: "Forcibly shut down"
                    case .pause: "Paused"
                    case .resume: "Resumed"
                    case .remove: "Removed"
                    default: "Completed"
                    }
                    completed.append(step)
                    break
                }
                let arguments: [String]
                switch action {
                case .rename(let name): arguments = ["device", "rename", "--device", device.identifier, "--name", name]
                case .restart: arguments = ["device", "reboot", "--device", device.identifier]
                case .unpair: arguments = ["manage", "unpair", "--device", device.identifier]
                default: throw unavailable(action, target: target)
                }
                _ = try await runDevicectl(arguments)
                let step = switch action {
                case .rename: "Renamed"
                case .restart: "Restart requested"
                case .unpair: "Unpaired"
                default: "Completed"
                }
                completed.append(step)
            }
            return DeviceManagementResult(deviceID: target.id, completedSteps: completed, createdDeviceID: created, error: nil)
        } catch {
            return DeviceManagementResult(deviceID: target.id, completedSteps: completed, createdDeviceID: created, error: error)
        }
    }

    private func unavailable(_ action: DeviceManagementAction, target: InventoryDevice) -> CLIError {
        CLIError.unavailable("device-action-unavailable", "This device does not expose the requested management operation.")
    }

    private struct PairList: Decodable {
        struct Pair: Decodable {
            struct Device: Decodable { let udid: String }
            let watch: Device
            let phone: Device
        }
        let pairs: [String: Pair]
    }
}

/// Owns display preparation and CLI shutdown until all admitted escalations have drained.
actor SimulatorShutdownTransaction {
    private struct Escalation {
        let identifiers: Set<DeviceInventoryID>
        let task: Task<DeviceManagementReport, Never>
    }
    private let devices: [InventoryDevice]
    private let identifiers: Set<DeviceInventoryID>
    private let backend: DeviceManagementBackend
    private let preparingDisplay: (@isolated(any) @Sendable (InventoryDevice) async throws -> Void)?
    private var accepting = true
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var preparations: [DeviceInventoryID: Task<SimulatorShutdownPreparation, Never>] = [:]
    private var shutdownTasks: [DeviceInventoryID: Task<DeviceManagementResult, Never>] = [:]
    private var escalations: [UUID: Escalation] = [:]
    private var forciblyStopped: Set<DeviceInventoryID> = []

    init(devices: [InventoryDevice], backend: DeviceManagementBackend,
         preparingDisplay: (@isolated(any) @Sendable (InventoryDevice) async throws -> Void)?) {
        var seen: Set<DeviceInventoryID> = []
        self.devices = devices.filter { seen.insert($0.id).inserted }
        identifiers = seen
        self.backend = backend
        self.preparingDisplay = preparingDisplay
    }

    func escalate(_ requested: [InventoryDevice]) async -> DeviceManagementReport? {
        var seen: Set<DeviceInventoryID> = []
        let targets = requested.filter { seen.insert($0.id).inserted }
        guard accepting, !targets.isEmpty, seen.isSubset(of: identifiers),
              targets.allSatisfy({ if case .simulator = $0 { true } else { false } }) else { return nil }
        if Task.isCancelled { return cancelled(targets) }
        let task = Task { await self.force(targets) }
        escalations[UUID()] = Escalation(identifiers: seen, task: task)
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func run() async -> DeviceManagementReport {
        started = true
        for waiter in startWaiters { waiter.resume() }
        startWaiters.removeAll()
        var results: [DeviceManagementResult] = []
        for target in devices {
            guard case .simulator(let device) = target else { continue }
            if Task.isCancelled, preparations[target.id] == nil,
               !escalations.values.contains(where: { $0.identifiers.contains(target.id) }) {
                results.append(cancelled([target]).results[0])
                continue
            }
            let preparation = await preparation(for: device).value
            for escalation in escalations.values where escalation.identifiers.contains(target.id) {
                _ = await escalation.task.value
            }
            if forciblyStopped.contains(target.id) {
                results.append(preparedResult(preparation, deviceID: target.id, forced: true))
                continue
            }
            switch preparation.context {
            case .failure:
                results.append(preparedResult(preparation, deviceID: target.id, forced: false))
            case .success(let context):
                if Task.isCancelled {
                    results.append(DeviceManagementResult(deviceID: target.id, completedSteps: preparation.completedSteps,
                                                          createdDeviceID: nil, error: CancellationError()))
                    continue
                }
                let task = Task { await self.backend.finishShutdown(context, completedSteps: preparation.completedSteps) }
                shutdownTasks[target.id] = task
                let result = await withTaskCancellationHandler {
                    await task.value
                } onCancel: {
                    task.cancel()
                }
                results.append(result)
                shutdownTasks.removeValue(forKey: target.id)
            }
        }
        accepting = false
        for escalation in escalations.values { _ = await escalation.task.value }
        for index in results.indices where results[index].error is CancellationError && forciblyStopped.contains(results[index].deviceID) {
            if let preparation = preparations[results[index].deviceID] {
                results[index] = preparedResult(await preparation.value, deviceID: results[index].deviceID, forced: true)
            }
        }
        return DeviceManagementReport(results: results)
    }

    private func preparation(for device: SimulatorHostDevice) -> Task<SimulatorShutdownPreparation, Never> {
        if let task = preparations[device.inventoryID] { return task }
        let task = Task { await backend.prepareShutdown(device, preparingDisplay: preparingDisplay) }
        preparations[device.inventoryID] = task
        return task
    }

    private func preparedResult(_ preparation: SimulatorShutdownPreparation, deviceID: DeviceInventoryID, forced: Bool) -> DeviceManagementResult {
        let failure: (any Error)?
        switch preparation.context {
        case .success: failure = nil
        case .failure(let error): failure = error
        }
        return DeviceManagementResult(deviceID: deviceID,
            completedSteps: preparation.completedSteps + (forced ? ["Forcibly shut down"] : []),
            createdDeviceID: nil, error: failure)
    }

    private func cancelled(_ targets: [InventoryDevice]) -> DeviceManagementReport {
        DeviceManagementReport(results: targets.map {
            DeviceManagementResult(deviceID: $0.id, completedSteps: [], createdDeviceID: nil, error: CancellationError())
        })
    }

    private func force(_ targets: [InventoryDevice]) async -> DeviceManagementReport {
        if !started { await withCheckedContinuation { startWaiters.append($0) } }
        if Task.isCancelled { return cancelled(targets) }
        let report = await backend.requestForceShutdown(targets)
        let completed = report.results.filter { $0.error == nil }.map(\.deviceID)
        for identifier in completed {
            forciblyStopped.insert(identifier)
            shutdownTasks[identifier]?.cancel()
        }
        for identifier in completed { _ = await shutdownTasks[identifier]?.value }
        var results = report.results
        for (index, target) in targets.enumerated() {
            guard let owned = devices.first(where: { $0.id == target.id }), case .simulator(let device) = owned else { continue }
            if results[index].error is CancellationError, results[index].completedSteps.isEmpty { continue }
            let preparation = await preparation(for: device).value
            let result = results[index]
            results[index] = DeviceManagementResult(deviceID: result.deviceID,
                completedSteps: result.completedSteps + preparation.completedSteps,
                createdDeviceID: result.createdDeviceID, error: result.error)
            if case .failure(let error) = preparation.context {
                results[index] = results[index].recordingDisplayCleanup(.failure(error))
            }
        }
        return DeviceManagementReport(results: results)
    }
}
