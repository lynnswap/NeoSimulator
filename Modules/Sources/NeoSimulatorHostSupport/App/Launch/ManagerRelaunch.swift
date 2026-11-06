import NeoSimulatorDeviceIO
import NeoSimulatorKit
import AppKit
import Darwin
import Synchronization

/// The bundled helper waits for the old manager to exit before asking Launch Services to reopen it.
package struct ManagerRelaunch: Codable, Sendable {
    package let processIdentifier: Int32
    package let applicationURL: URL
    package let deviceURLs: [URL]

    package init(processIdentifier: Int32, applicationURL: URL, deviceURLs: [URL]) {
        self.processIdentifier = processIdentifier
        self.applicationURL = applicationURL
        self.deviceURLs = deviceURLs
    }

    /// The helper's acknowledgement arrives when it chooses, so the handshake waits on a blocking-I/O queue.
    @concurrent
    package func schedule(using helperURL: URL) async throws -> Process {
        let request = try JSONEncoder().encode(self)
        return try await performBlockingIO {
            let process = Process()
            process.executableURL = helperURL
            process.arguments = ["--relaunch-manager"]
            let input = Pipe(), ready = Pipe()
            process.standardInput = input
            process.standardOutput = ready
            try process.run()
            do {
                try input.fileHandleForWriting.write(contentsOf: request)
                try input.fileHandleForWriting.close()
                guard try ready.fileHandleForReading.read(upToCount: 1) == Data([1]) else {
                    throw SimulatorError.operation("Could not prepare NeoSimulator to restart.")
                }
                try ready.fileHandleForReading.close()
            } catch {
                if process.isRunning { process.terminate() }
                throw error
            }
            return process
        }
    }

    package static func waitForExit(of pid: Int32, ready: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { continuation in
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
            source.setRegistrationHandler(handler: ready)
            source.setEventHandler {
                source.cancel()
                source.setEventHandler(handler: nil)
                continuation.resume()
            }
            source.activate()
        }
    }

    @MainActor
    package static func runHelper() async -> Never {
        do {
            let data = try await performBlockingIO { try FileHandle.standardInput.readToEnd() ?? Data() }
            let request = try JSONDecoder().decode(Self.self, from: data)
            await waitForExit(of: request.processIdentifier) {
                do { try FileHandle.standardOutput.write(contentsOf: Data([1])) }
                catch { _exit(EX_IOERR) }
            }
            let configuration = NSWorkspace.OpenConfiguration()
            if let developerDirectory = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] {
                configuration.environment = ["DEVELOPER_DIR": developerDirectory]
            }
            configuration.allowsRunningApplicationSubstitution = false
            if request.deviceURLs.isEmpty {
                _ = try await NSWorkspace.shared.openApplication(at: request.applicationURL, configuration: configuration)
            } else {
                _ = try await NSWorkspace.shared.open(request.deviceURLs, withApplicationAt: request.applicationURL, configuration: configuration)
            }
            exit(EXIT_SUCCESS)
        } catch {
            NSApplication.shared.setActivationPolicy(.regular)
            NSAlert(presenting: error).runModal()
            exit(EX_SOFTWARE)
        }
    }
}
