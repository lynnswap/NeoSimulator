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
    let environment: [String: String]
    private let simctlURL: URL
    private let devicectlURL: URL
    private let runner = DeviceToolRunner()

    /// - Parameters:
    ///   - simctl: The `simctl` executable; tests substitute a stand-in.
    ///   - devicectl: The `devicectl` executable; tests substitute a stand-in.
    init(identifier: String, xcodeURL: URL, simctl: URL = DeviceTools.simctl,
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
        environment = ["DEVELOPER_DIR": developerDirectory]
    }

    // Booting can migrate data first, and erasing removes the whole device.
    func boot() async throws { _ = try await simctl(["boot", identifier], timeout: .seconds(300)) }
    func shutdown() async throws { _ = try await simctl(["shutdown", identifier], timeout: .seconds(300)) }
    func erase() async throws { _ = try await simctl(["erase", identifier], timeout: .seconds(300)) }
    func screenshot(to url: URL) async throws {
        _ = try await simctl(["io", identifier, "screenshot", "--type=png", "--mask=alpha", url.path])
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
    func installApplication(at url: URL) async throws {
        _ = try await simctl(["install", identifier, url.path])
    }
    func importMedia(at url: URL) async throws {
        _ = try await simctl(["addmedia", identifier, url.path])
    }
    func openURL(_ url: URL) async throws {
        _ = try await simctl(["openurl", identifier, url.absoluteString])
    }
    func recordingProcess(to url: URL) -> Process {
        let process = Process()
        process.executableURL = simctlURL
        process.arguments = ["io", identifier, "recordVideo", "--codec=h264", "--mask=black", "--force", url.path]
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        return process
    }
    func cancel() { runner.cancel() }
    private func simctl(_ arguments: [String], timeout: Duration = .seconds(30)) async throws -> Data {
        try await runner.run(simctlURL, arguments: arguments, environment: environment, timeout: timeout)
    }
}
