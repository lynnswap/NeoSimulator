import Foundation
import Darwin

@MainActor
final class DeviceToolRunner {
    private(set) var process: Process?
    private var cancellationRequested = false
    private var timedOut = false

    func run(_ executable: URL, arguments: [String], environment: [String: String] = [:],
             timeout: Duration = .seconds(30)) async throws -> Data {
        try Task.checkCancellation()
        guard process == nil else { throw HostError.operation("Another device operation is in progress") }
        let task = Process()
        task.executableURL = executable
        task.arguments = arguments
        task.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        task.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let diagnostic = Pipe()
        task.standardOutput = output
        task.standardError = diagnostic
        process = task
        cancellationRequested = false
        timedOut = false
        var timeoutTask: Task<Void, Never>?
        defer {
            timeoutTask?.cancel()
            task.terminationHandler = nil
            process = nil
        }

        let outputReader = Task.detached { try output.fileHandleForReading.readToEnd() ?? Data() }
        let diagnosticReader = Task.detached { try diagnostic.fileHandleForReading.readToEnd() ?? Data() }
        let exit: Result<Int32, Error> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                task.terminationHandler = { process in
                    continuation.resume(returning: .success(process.terminationStatus))
                }
                do {
                    try task.run()
                    timeoutTask = Task { [weak self] in
                        do { try await Task.sleep(for: timeout) } catch { return }
                        guard let self, self.process === task, task.isRunning else { return }
                        self.timedOut = true
                        self.terminate(task)
                    }
                } catch {
                    task.terminationHandler = nil
                    output.fileHandleForWriting.closeFile()
                    diagnostic.fileHandleForWriting.closeFile()
                    continuation.resume(returning: .failure(error))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
        let data = try await outputReader.value
        let errors = try await diagnosticReader.value
        if timedOut { throw HostError.operation("Device operation timed out") }
        if cancellationRequested || Task.isCancelled { throw CancellationError() }
        let status = try exit.get()
        guard status == 0, task.terminationReason == .exit else {
            let text = String(decoding: errors + data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw HostError.operation(text.isEmpty ? "Device operation failed with status \(status)" : String(text.suffix(4096)))
        }
        return data
    }

    func cancel() {
        guard let process else { return }
        cancellationRequested = true
        terminate(process)
    }

    private func terminate(_ process: Process) {
        if process.isRunning { process.terminate() }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            if self?.process === process, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }
}

@MainActor
final class DeviceTools {
    static let simctl = URL(fileURLWithPath: "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl")
    static let devicectl = URL(fileURLWithPath: "/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/Resources/bin/devicectl")
    let identifier: String
    /// The device's set when it is not the default set.
    let deviceSetPath: String?
    let environment: [String: String]
    private let simctlURL: URL
    private let devicectlURL: URL
    private let runner = DeviceToolRunner()

    /// `deviceSetPath` selects a custom set for simctl; devicectl cannot address it.
    /// Executable arguments allow test substitution.
    init(identifier: String, xcodeURL: URL, deviceSetPath: String? = nil, simctl: URL = DeviceTools.simctl,
         devicectl: URL = DeviceTools.devicectl) throws {
        let developerDirectory = xcodeURL.appendingPathComponent("Contents/Developer").path
        simctlURL = simctl
        devicectlURL = devicectl
        for tool in [simctl, devicectl] {
            guard FileManager.default.isExecutableFile(atPath: tool.path) else {
                throw HostError.unavailable("Required device tool is unavailable: \(tool.path)")
            }
        }
        self.identifier = identifier
        self.deviceSetPath = deviceSetPath
        environment = ["DEVELOPER_DIR": developerDirectory]
    }

    /// Creates a device in the default device set, or in the set at
    /// `deviceSetPath`, and returns its identifier.
    static func createDevice(named name: String, deviceType: String, runtime: String, xcodeURL: URL,
                             deviceSetPath: String? = nil, simctl: URL = DeviceTools.simctl) async throws -> String {
        let output = try await run(simctl, ["create", name, deviceType, runtime], xcodeURL: xcodeURL,
                                   deviceSetPath: deviceSetPath)
        return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Pairs a watch with a phone, both in the default device set or in the
    /// set at `deviceSetPath`.
    static func pairDevices(watch: String, phone: String, xcodeURL: URL, deviceSetPath: String? = nil,
                            simctl: URL = DeviceTools.simctl) async throws {
        _ = try await run(simctl, ["pair", watch, phone], xcodeURL: xcodeURL, deviceSetPath: deviceSetPath)
    }

    private static func run(_ simctl: URL, _ arguments: [String], xcodeURL: URL,
                            deviceSetPath: String?) async throws -> Data {
        try await DeviceToolRunner().run(
            simctl, arguments: (deviceSetPath.map { ["--set", $0] } ?? []) + arguments,
            environment: ["DEVELOPER_DIR": xcodeURL.appendingPathComponent("Contents/Developer").path],
            timeout: .seconds(300))
    }

    // Booting can migrate data first, and erasing removes the whole device.
    func boot() async throws { _ = try await simctl(["boot", identifier], timeout: .seconds(300)) }
    func shutdown() async throws { _ = try await simctl(["shutdown", identifier], timeout: .seconds(300)) }
    func erase() async throws { _ = try await simctl(["erase", identifier], timeout: .seconds(300)) }
    /// How `simctl io` renders the area outside the device's screen shape:
    /// not at all, transparent, or black.
    enum ScreenMask: String { case ignored, alpha, black }
    enum VideoCodec: String { case h264, hevc }

    func screenshot(to url: URL, mask: ScreenMask) async throws {
        _ = try await simctl(["io", identifier, "screenshot", "--type=png", "--mask=\(mask.rawValue)", url.path])
    }
    func rotate(left: Bool) async throws -> OrientationReading {
        _ = try await runner.run(devicectlURL,
            arguments: ["device", "orientation", "rotate", "--device", identifier, left ? "left" : "right", "--quiet"],
            environment: environment)
        return try await orientation()
    }
    func setOrientation(_ orientation: DeviceOrientation) async throws -> OrientationReading {
        _ = try await runner.run(devicectlURL,
            arguments: ["device", "orientation", "set", "--device", identifier, orientation.rawValue, "--quiet"],
            environment: environment)
        return try await self.orientation()
    }
    func orientation() async throws -> OrientationReading {
        try OrientationReading(devicectlOutput: await runner.run(devicectlURL,
            arguments: ["device", "orientation", "get", "--device", identifier, "--json-output", "-", "--quiet"],
            environment: environment))
    }
    /// Shutdown failure stops the restart; erase failure is reported but still allows boot.
    func restart(erasing: Bool) async throws {
        let operation = erasing ? "Erase All Content and Settings" : "Restart"
        func failure(_ stage: String, completed: [String], _ error: Error) -> HostError {
            let progress = completed.isEmpty ? "" : " The device was \(completed.joined(separator: " and "))."
            return HostError.operation("\(operation) failed while \(stage): \(error.localizedDescription)\(progress)")
        }
        do { try await shutdown() } catch {
            if error is CancellationError { throw error }
            throw failure("shutting down", completed: [], error)
        }
        var eraseFailure: Error?
        if erasing {
            do { try await erase() } catch {
                if error is CancellationError { throw error }
                eraseFailure = error
            }
        }
        do { try await boot() } catch {
            if error is CancellationError { throw error }
            throw failure("booting", completed: erasing && eraseFailure == nil ? ["shut down", "erased"] : ["shut down"], error)
        }
        if let eraseFailure { throw failure("erasing", completed: ["shut down", "booted again"], eraseFailure) }
    }

    func installApplication(at url: URL) async throws {
        _ = try await simctl(["install", identifier, url.path])
    }
    func importMedia(at url: URL) async throws {
        _ = try await simctl(["addmedia", identifier, url.path])
    }
    func openURL(_ url: URL) async throws {
        _ = try await simctl(["openurl", identifier, url.absoluteString])
    }
    /// Stops PineBoard, an Apple TV's system UI, which launchd restarts.
    func stopSystemUI() async throws {
        _ = try await simctl(["spawn", identifier, "launchctl", "stop", "com.apple.PineBoard"])
    }
    func recordingProcess(to url: URL, mask: ScreenMask, codec: VideoCodec) -> Process {
        let process = Process()
        process.executableURL = simctlURL
        process.arguments = simctlSet + ["io", identifier, "recordVideo", "--codec=\(codec.rawValue)",
                                         "--mask=\(mask.rawValue)", "--force", url.path]
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        return process
    }
    func cancel() { runner.cancel() }
    private var simctlSet: [String] { deviceSetPath.map { ["--set", $0] } ?? [] }
    private func simctl(_ arguments: [String], timeout: Duration = .seconds(30)) async throws -> Data {
        try await runner.run(simctlURL, arguments: simctlSet + arguments, environment: environment, timeout: timeout)
    }
}
