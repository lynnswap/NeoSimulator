import Foundation
import NeoSimulatorDeviceIO

/// Runs one tool at a time for a device and lets its owner cancel the running one. A command stopped after its child
/// started throws ``CommandFailure``, because what it changed is unknown; one cancelled before that throws `CancellationError`.
@MainActor
package final class DeviceToolRunner {
    private var current: Task<CommandOutput, any Error>?

    package func run(_ executable: URL, arguments: [String], environment: [String: String] = [:],
                     policy: CommandPolicy = .deviceTool) async throws -> Data {
        try Task.checkCancellation()
        guard current == nil else { throw SimulatorError.operation("Another device operation is in progress") }
        let command = SystemCommand(executable: executable, arguments: arguments,
                                    environment: ProcessInfo.processInfo.environment.merging(environment) { _, new in new }, policy: policy)
        let task = Task { try await SystemCommandRunner().run(command) }
        current = task
        defer { current = nil }
        let output = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        guard output.terminationStatus == 0 else {
            let text = String(decoding: output.stderr + output.stdout, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw SimulatorError.operation(text.isEmpty ? "Device operation failed with status \(output.terminationStatus)" : String(text.suffix(4096)))
        }
        return output.stdout
    }

    package func cancel() { current?.cancel() }
}

/// A restart that cancellation stopped after it began changing the device, with how far it got.
package struct DeviceRestartInterruption: LocalizedError {
    /// A ``CommandFailure`` when a running stage was stopped, or `CancellationError` when one never started.
    package let cause: any Error
    package let errorDescription: String?
}

@MainActor
package final class DeviceTools {
    package static let simctl = DeviceToolPaths.simctl
    package static let devicectl = DeviceToolPaths.devicectl
    package let identifier: String
    /// The device's set when it is not the default set.
    package let deviceSetPath: String?
    package let environment: [String: String]
    private let simctlURL: URL
    private let devicectlURL: URL
    private let runner = DeviceToolRunner()
    private let lookUp: (@MainActor (String) throws -> UInt32)?
    private var guestOrientation: GuestDeviceOrientation?

    /// `deviceSetPath` selects a custom set for simctl; devicectl cannot address it.
    /// Executable arguments allow test substitution.
    package init(identifier: String, xcodeURL: URL, deviceSetPath: String? = nil, simctl: URL = DeviceTools.simctl,
         devicectl: URL = DeviceTools.devicectl, lookUp: (@MainActor (String) throws -> UInt32)? = nil) throws {
        let developerDirectory = xcodeURL.appendingPathComponent("Contents/Developer").path
        simctlURL = simctl
        devicectlURL = devicectl
        for tool in [simctl, devicectl] {
            guard FileManager.default.isExecutableFile(atPath: tool.path) else {
                throw SimulatorError.unavailable("Required device tool is unavailable: \(tool.path)")
            }
        }
        self.identifier = identifier
        self.lookUp = lookUp
        self.deviceSetPath = deviceSetPath
        environment = ["DEVELOPER_DIR": developerDirectory]
    }

    /// Creates a device in the default device set, or in the set at
    /// `deviceSetPath`, and returns its identifier.
    package static func createDevice(named name: String, deviceType: String, runtime: String, xcodeURL: URL,
                             deviceSetPath: String? = nil, simctl: URL = DeviceTools.simctl) async throws -> String {
        let output = try await run(simctl, ["create", name, deviceType, runtime], xcodeURL: xcodeURL,
                                   deviceSetPath: deviceSetPath)
        return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Pairs a watch with a phone, both in the default device set or in the
    /// set at `deviceSetPath`.
    package static func pairDevices(watch: String, phone: String, xcodeURL: URL, deviceSetPath: String? = nil,
                            simctl: URL = DeviceTools.simctl) async throws {
        _ = try await run(simctl, ["pair", watch, phone], xcodeURL: xcodeURL, deviceSetPath: deviceSetPath)
    }

    private static func run(_ simctl: URL, _ arguments: [String], xcodeURL: URL,
                            deviceSetPath: String?) async throws -> Data {
        try await DeviceToolRunner().run(
            simctl, arguments: (deviceSetPath.map { ["--set", $0] } ?? []) + arguments,
            environment: ["DEVELOPER_DIR": xcodeURL.appendingPathComponent("Contents/Developer").path],
            policy: .deviceLifecycleTool)
    }

    package func boot() async throws {
        _ = try await endingOnCancellation { try await bootTool() }
    }
    package func shutdown() async throws { _ = try await simctl(["shutdown", identifier], policy: .deviceLifecycleTool) }
    package func erase() async throws { _ = try await simctl(["erase", identifier], policy: .deviceLifecycleTool) }
    /// How `simctl io` renders the area outside the device's screen shape:
    /// not at all, transparent, or black.
    package enum ScreenMask: String { case ignored, alpha, black }
    package enum VideoCodec: String { case h264, hevc }

    package func screenshot(to url: URL, mask: ScreenMask, displayID: UInt32? = nil) async throws {
        _ = try await endingOnCancellation {
            try await simctl(["io", identifier, "screenshot", "--type=png", "--mask=\(mask.rawValue)"] + (displayID.map { ["--display=\($0)"] } ?? []) + [url.path])
        }
    }
    package func rotate(left: Bool) async throws -> OrientationReading {
        if let guest = try await orientationConnection() { return try await guest.rotate(left: left) }
        _ = try await runner.run(devicectlURL,
            arguments: ["device", "orientation", "rotate", "--device", identifier, left ? "left" : "right", "--quiet"],
            environment: environment)
        return try await orientation()
    }
    package func setOrientation(_ orientation: DeviceOrientation) async throws -> OrientationReading {
        if let guest = try await orientationConnection() { return try await guest.set(orientation) }
        _ = try await runner.run(devicectlURL,
            arguments: ["device", "orientation", "set", "--device", identifier, orientation.rawValue, "--quiet"],
            environment: environment)
        return try await self.orientation()
    }
    package func orientation() async throws -> OrientationReading {
        if let guest = try await orientationConnection() { return try await guest.read() }
        return try OrientationReading(devicectlOutput: await endingOnCancellation {
            try await runner.run(devicectlURL,
                arguments: ["device", "orientation", "get", "--device", identifier, "--json-output", "-", "--quiet"],
                environment: environment)
        })
    }

    private func orientationConnection() async throws -> GuestDeviceOrientation? {
        if let guestOrientation { return guestOrientation }
        guard let lookUp else { return nil }
        let guest = try await SimulatorGuestHID(lookUp: lookUp)
        let orientation = try GuestDeviceOrientation(guest: guest)
        guestOrientation = orientation
        return orientation
    }
    /// Shutdown failure stops the restart; erase failure is reported but still allows boot. Cancellation stops it at any stage
    /// and throws ``DeviceRestartInterruption``, unless it arrived before the shutdown started and nothing changed.
    package func restart(erasing: Bool) async throws {
        let operation = erasing ? "Erase All Content and Settings" : "Restart"
        var eraseFailure: Error?
        func progress(_ completed: [String]) -> String {
            completed.isEmpty ? "" : " The device was \(completed.joined(separator: " and "))."
        }
        func failure(_ stage: String, completed: [String], _ error: Error) -> SimulatorError {
            SimulatorError.operation("\(operation) failed while \(stage): \(error.localizedDescription)\(progress(completed))")
        }
        func interruption(_ stage: String, completed: [String], _ error: Error) -> DeviceRestartInterruption {
            let subject = eraseFailure.map { "\(operation) failed while erasing: \($0.localizedDescription) Restarting also" } ?? operation
            let outcome = error is CancellationError ? "stopped before \(stage)." : "stopped while \(stage): \(error.localizedDescription)"
            return DeviceRestartInterruption(cause: error, errorDescription: "\(subject) \(outcome)\(progress(completed))")
        }
        do { try await shutdown() } catch {
            if error is CancellationError { throw error }
            if error.isCancellation { throw interruption("shutting down", completed: [], error) }
            throw failure("shutting down", completed: [], error)
        }
        if erasing {
            do { try await erase() } catch {
                if error.isCancellation { throw interruption("erasing", completed: ["shut down"], error) }
                eraseFailure = error
            }
        }
        // Unlike a boot on its own, whose callers read the device's state next, a restart reports how its boot ended.
        do { _ = try await bootTool() } catch {
            let completed = erasing && eraseFailure == nil ? ["shut down", "erased"] : ["shut down"]
            if error.isCancellation { throw interruption("booting", completed: completed, error) }
            if let eraseFailure {
                throw SimulatorError.operation("\(operation) failed while erasing: \(eraseFailure.localizedDescription) Restarting also failed while booting: \(error.localizedDescription) The device was shut down.")
            }
            throw failure("booting", completed: completed, error)
        }
        if let eraseFailure { throw failure("erasing", completed: ["shut down", "booted again"], eraseFailure) }
    }

    package func installApplication(at url: URL) async throws {
        try await withInstallableApplication(at: url) { application in
            _ = try await simctl(["install", identifier, application.path])
        }
    }
    package func importMedia(at url: URL) async throws {
        _ = try await simctl(["addmedia", identifier, url.path])
    }
    package func openURL(_ url: URL) async throws {
        _ = try await simctl(["openurl", identifier, url.absoluteString])
    }
    /// Stops PineBoard, an Apple TV's system UI, which launchd restarts.
    package func stopSystemUI() async throws {
        _ = try await simctl(["spawn", identifier, "launchctl", "stop", "com.apple.PineBoard"])
    }
    package func recordingProcess(to url: URL, mask: ScreenMask, codec: VideoCodec, displayID: UInt32? = nil) -> Process {
        let process = Process()
        process.executableURL = simctlURL
        process.arguments = simctlSet + ["io", identifier, "recordVideo", "--codec=\(codec.rawValue)",
                                         "--mask=\(mask.rawValue)", "--force"] + (displayID.map { ["--display=\($0)"] } ?? []) + [url.path]
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        return process
    }
    package func cancel() { runner.cancel() }
    /// For a read, or a boot whose callers all read the device's state next, where a stopped child leaves nothing to account for.
    private func endingOnCancellation(_ command: @MainActor () async throws -> Data) async throws -> Data {
        do { return try await command() }
        catch let failure as CommandFailure where failure.interruption == .cancelled { throw CancellationError() }
    }
    private func bootTool() async throws -> Data {
        try await simctl(["boot", identifier], policy: .deviceLifecycleTool)
    }
    private var simctlSet: [String] { deviceSetPath.map { ["--set", $0] } ?? [] }
    private func simctl(_ arguments: [String], policy: CommandPolicy = .deviceTool) async throws -> Data {
        try await runner.run(simctlURL, arguments: simctlSet + arguments, environment: environment, policy: policy)
    }
}
