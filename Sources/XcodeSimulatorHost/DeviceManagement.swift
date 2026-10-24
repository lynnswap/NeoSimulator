import Foundation

public enum DeviceManagementAction: Equatable, Sendable {
    case rename(String), clone(String)
    case start, shutdown, restart, erase, remove, pair, unpair, pause, resume
}

public struct DeviceManagementResult: Sendable {
    public let deviceID: DeviceInventoryID
    public let completedSteps: [String]
    public let createdDeviceID: DeviceInventoryID?
    public let error: (any Error)?
}

public struct DeviceManagementReport: Sendable {
    public let results: [DeviceManagementResult]
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
            case .restart: return device.isAvailable && device.state == "Booted"
            case .pair: return device.isAvailable && ["Apple Watch", "iPhone"].contains(device.productFamily)
            case .unpair: return device.productFamily == "Apple Watch" && !device.pairIdentifiers.isEmpty
            case .pause, .resume: return false
            }
        case .remote(let device):
            if let feature = action.virtualMachineFeature { return device.capabilities.contains(feature) }
            switch action {
            case .rename: return device.capabilities.contains("com.apple.coredevice.feature.renamedevice")
            case .restart: return device.capabilities.contains("com.apple.coredevice.feature.rebootdevice")
            case .pair: return device.isAvailable && device.pairingState == "unpaired"
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

extension SimulatorHostController {
    /// Runs each requested target once, preserving completed work and target-specific failures.
    /// Simulator mutations share the existing operation FIFO with opens and host changes.
    public func manage(_ action: DeviceManagementAction, devices: [InventoryDevice]) async -> DeviceManagementReport {
        let backend = DeviceManagementBackend(
            context: { try await self.deviceManagementContext(for: $0, requiresRenderer: $1) },
            runSimctl: Self.runManagementSimctl, runDevicectl: Self.runManagementDevicectl,
            manageVirtualMachine: { action, identifier in try await CoreDeviceVirtualMachineClient.perform(action, identifier: identifier) },
            release: { renderer, identifier in try await RendererDeviceRequestWaiter().release(identifier, from: renderer) },
            restart: { renderer, identifier, erasing in
                try await RendererDeviceRequestWaiter().restart(identifier, in: renderer, erasing: erasing)
            },
            attach: { renderer, identifier in try await RendererDeviceRequestWaiter().open(identifier, in: renderer) }
        )
        guard devices.contains(where: { if case .simulator = $0 { true } else { false } }) else {
            return await backend.manage(action, devices: devices)
        }
        do { return try await operation { await backend.manage(action, devices: devices) } }
        catch {
            return DeviceManagementReport(results: devices.map {
                DeviceManagementResult(deviceID: $0.id, completedSteps: [], createdDeviceID: nil, error: error)
            })
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
    var manageVirtualMachine: @Sendable (DeviceManagementAction, String) async throws -> Void
    var release: @Sendable (RendererRegistration, String) async throws -> Void
    /// False means the renderer had no existing window; the backend uses the release/CLI path instead.
    var restart: @Sendable (RendererRegistration, String, Bool) async throws -> Bool
    var attach: @Sendable (RendererRegistration, String) async throws -> Void

    func manage(_ action: DeviceManagementAction, devices: [InventoryDevice]) async -> DeviceManagementReport {
        var seen = Set<DeviceInventoryID>()
        let targets = devices.filter { seen.insert($0.id).inserted }
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
            results.append(await perform(action, on: target))
        }
        return DeviceManagementReport(results: results)
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

    private func perform(_ action: DeviceManagementAction, on target: InventoryDevice) async -> DeviceManagementResult {
        var completed: [String] = []
        var created: DeviceInventoryID?
        do {
            try Task.checkCancellation()
            switch target {
            case .simulator(let original):
                let needsCleanup: Bool = switch action { case .shutdown, .restart, .erase, .remove: true; default: false }
                let resolved = try await context(original, needsCleanup)
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
                    handledByRenderer = try await restart(renderer, identifier, action == .erase)
                    if handledByRenderer { completed.append(action == .erase ? "Erased and restarted" : "Restarted") }
                }
                if !handledByRenderer {
                    if needsCleanup, let renderer = resolved.renderer {
                        try await release(renderer, identifier)
                        completed.append("Display disconnected")
                    }
                    switch action {
                    case .rename(let name): _ = try await command(["rename", identifier, name], step: "Renamed")
                    case .clone(let name):
                        let output = try await command(["clone", identifier, name], step: "Cloned")
                        let clone = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                        created = .simulator(udid: clone, deviceSetPath: device.deviceSetPath)
                    case .start: _ = try await command(["boot", identifier], step: "Started")
                    case .shutdown: _ = try await command(["shutdown", identifier], step: "Shut down")
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
                                    try await attach(renderer, identifier)
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
                    case .pair, .pause, .resume: throw unavailable(action, target: target)
                    }
                }
            case .remote(let device):
                if action.virtualMachineFeature != nil {
                    try await manageVirtualMachine(action, device.identifier)
                    let step = switch action {
                    case .start: "Started"
                    case .shutdown: "Shut down"
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
                case .pair: arguments = ["manage", "pair", "--device", device.identifier]
                case .unpair: arguments = ["manage", "unpair", "--device", device.identifier]
                default: throw unavailable(action, target: target)
                }
                _ = try await runDevicectl(arguments)
                let step = switch action {
                case .rename: "Renamed"
                case .restart: "Restart requested"
                case .pair: "Paired"
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
