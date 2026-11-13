import ABIBridge
import AppKit
import Darwin
import IOKit.hidsystem
@testable import NeoSimulatorApp
@testable import NeoSimulatorDeviceIO
@testable import NeoSimulatorHostSupport
@testable import NeoSimulatorKit
@testable import NeoSimulatorPresentationAdapters
@testable import NeoSimulatorService
@testable import NeoSimulatorUI
import Observation
import Synchronization
import Testing
import SwiftUI
import Combine
import XCTest
import XPC
@testable import NeoSimulatorManager
@testable import NeoSimulatorInspector
@testable import NeoSimulatorDeviceDisplay
@testable import NeoSimulatorCompactWindow
@testable import NeoSimulatorDeviceScreens

@Suite @MainActor
struct DeviceToolTests {
    @Test func drainsOutputAndReportsToolFailures() async throws {
        let runner = DeviceToolRunner()
        let data = try await runner.run(URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "i=0; while [ $i -lt 10000 ]; do echo stdout; echo stderr >&2; i=$((i+1)); done"])
        #expect(data.count == 70_000)
        await #expect(throws: (any Error).self) {
            try await runner.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo rejected >&2; exit 7"])
        }
    }

    @Test func toolsAddressADeviceOutsideTheDefaultSet() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("arguments"), simctl = directory.appendingPathComponent("simctl")
        try """
            #!/bin/sh
            printf '%s\\n' "$@" > "\(log.path)"
            if [ "$3" = install ]; then cat "$5/Info.plist" >> "\(log.path)"; fi
            """.write(to: simctl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: simctl.path)
        let tools = try DeviceTools(identifier: "test-device", xcodeURL: URL(fileURLWithPath: "/Applications/Xcode.app"),
                                    deviceSetPath: "/tmp/XCTestDevices", simctl: simctl)
        try await tools.boot()
        #expect(try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
                == ["--set", "/tmp/XCTestDevices", "boot", "test-device"])
        let bundle = directory.appendingPathComponent("Contents/Payload/App.app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: bundle.appendingPathComponent("Info.plist"))
        let package = directory.appendingPathComponent("App.ipa")
        _ = try await DeviceToolRunner().run(URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-c", "-k", directory.appendingPathComponent("Contents").path, package.path])
        try await tools.installApplication(at: package)
        let install = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        try #require(install.count == 6)
        #expect(install == ["--set", "/tmp/XCTestDevices", "install", "test-device", install[4], "fixture"]
                && install[4].hasSuffix("/Payload/App.app"))
        #expect(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: install[4]).deletingLastPathComponent().deletingLastPathComponent().path))
        try await tools.screenshot(to: directory.appendingPathComponent("screen.png"), mask: .ignored, displayID: 47)
        #expect(try String(contentsOf: log, encoding: .utf8).split(separator: "\n").contains("--display=47"))
        let recording = tools.recordingProcess(to: URL(fileURLWithPath: "/tmp/video.mov"), mask: .ignored, codec: .h264, displayID: 47)
        #expect(recording.arguments?.prefix(4) == ["--set", "/tmp/XCTestDevices", "io", "test-device"])
        #expect(recording.arguments?.contains("--display=47") == true)
    }

    @Test func createDevicePassesNameTypeAndRuntimeToSimctl() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("arguments"), simctl = directory.appendingPathComponent("simctl")
        try """
            #!/bin/sh
            printf '%s\\n' "$DEVELOPER_DIR" "$@" > "\(log.path)"
            echo 0D6B2C3A-0000-4000-8000-000000000001
            """.write(to: simctl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: simctl.path)
        let xcode = URL(fileURLWithPath: "/Applications/Xcode.app")
        let identifier = try await DeviceTools.createDevice(named: "My Phone", deviceType: "type", runtime: "runtime",
                                                            xcodeURL: xcode, simctl: simctl)
        #expect(identifier == "0D6B2C3A-0000-4000-8000-000000000001")
        #expect(try String(contentsOf: log, encoding: .utf8).split(separator: "\n") == [
            "/Applications/Xcode.app/Contents/Developer", "create", "My Phone", "type", "runtime",
        ])
        try await DeviceTools.pairDevices(watch: "watch", phone: "phone", xcodeURL: xcode,
                                          deviceSetPath: "/tmp/Devices", simctl: simctl)
        #expect(try String(contentsOf: log, encoding: .utf8).split(separator: "\n") == [
            "/Applications/Xcode.app/Contents/Developer", "--set", "/tmp/Devices", "pair", "watch", "phone",
        ])
    }

    /// Each stop ends with the runner free for the next command, which it refuses while one is still running.
    @Test func timeoutAndCancellationReapTheChildProcess() async throws {
        let runner = DeviceToolRunner()
        let timeout = try await #require(throws: CommandFailure.self) {
            try await runner.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"],
                                 policy: CommandPolicy(limit: .milliseconds(30), cancellation: .stopsChild, stopGrace: .seconds(2)))
        }
        #expect(timeout.interruption == .timedOut(.milliseconds(30)))
        let task = Task { try await runner.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"]) }
        task.cancel()
        // Whether its child has started by now is up to the scheduler.
        let stopped = try await #require(throws: (any Error).self) { try await task.value }
        #expect(stopped.isCancellation)
        _ = try await runner.run(URL(fileURLWithPath: "/usr/bin/true"), arguments: [])
    }

    @Test(.timeLimit(.minutes(1))) func cancellingTheToolsStopsTheirRunningCommandAndRefusesASecondMeanwhile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ready = directory.appendingPathComponent("ready")
        try #require(mkfifo(ready.path, 0o600) == 0)
        let child = Task { try await performBlockingIO { try FileHandle(forReadingFrom: ready).readToEnd() ?? Data() } }
        let runner = DeviceToolRunner()
        let running = Task {
            try await runner.run(URL(fileURLWithPath: "/bin/sh"),
                                 arguments: ["-c", "printf '%s\\n' \"$$\" > \"$1\"; exec /bin/sleep 300", "fixture", ready.path])
        }
        let identifier = try #require(Int32(String(decoding: try await child.value, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        await #expect(throws: SimulatorError.self) { try await runner.run(URL(fileURLWithPath: "/usr/bin/true"), arguments: []) }
        runner.cancel()
        let failure = try await #require(throws: CommandFailure.self) { try await running.value }
        #expect(failure.interruption == .cancelled)
        #expect(kill(identifier, 0) == -1 && errno == ESRCH)
    }

    /// Erasing can have removed anything by the time it stops, so the restart reports that with what already finished and goes no further.
    @Test(.timeLimit(.minutes(1))) func stoppingAnEraseReportsItsUnknownOutcomeAndEndsTheRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try toolsHolding("erase", in: directory)
        let restart = Task { try await fixture.tools.restart(erasing: true) }
        _ = try await fixture.started.value
        fixture.tools.cancel()
        let failure = try await #require(throws: DeviceRestartInterruption.self) { try await restart.value }
        #expect((failure.cause as? CommandFailure)?.interruption == .cancelled)
        #expect(failure.errorDescription == "Erase All Content and Settings stopped while erasing: simctl was stopped before it finished, so what it changed is unknown. The device was shut down.")
        #expect(try String(contentsOf: fixture.calls, encoding: .utf8).split(separator: "\n") == ["shutdown", "erase"])
    }

    @Test(.timeLimit(.minutes(1)), arguments: [
        (held: "shutdown", erasing: false, calls: ["shutdown"], description: "Restart stopped while shutting down: simctl was stopped before it finished, so what it changed is unknown."),
        (held: "boot", erasing: false, calls: ["shutdown", "boot"], description: "Restart stopped while booting: simctl was stopped before it finished, so what it changed is unknown. The device was shut down."),
        (held: "boot", erasing: true, calls: ["shutdown", "erase", "boot"], description: "Erase All Content and Settings stopped while booting: simctl was stopped before it finished, so what it changed is unknown. The device was shut down and erased."),
    ])
    func stoppingARestartKeepsItsStageAndWhatItCompleted(_ stage: (held: String, erasing: Bool, calls: [String], description: String)) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try toolsHolding(stage.held, in: directory)
        let restart = Task { try await fixture.tools.restart(erasing: stage.erasing) }
        _ = try await fixture.started.value
        fixture.tools.cancel()
        let failure = try await #require(throws: DeviceRestartInterruption.self) { try await restart.value }
        #expect((failure.cause as? CommandFailure)?.interruption == .cancelled)
        #expect(failure.errorDescription == stage.description)
        #expect(try String(contentsOf: fixture.calls, encoding: .utf8).split(separator: "\n").map(String.init) == stage.calls)
    }

    @Test(.timeLimit(.minutes(1))) func stoppingABootAfterAFailedEraseKeepsBothOutcomes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try toolsHolding("boot", failing: "erase", in: directory)
        let restart = Task { try await fixture.tools.restart(erasing: true) }
        _ = try await fixture.started.value
        fixture.tools.cancel()
        let failure = try await #require(throws: DeviceRestartInterruption.self) { try await restart.value }
        #expect(failure.errorDescription == "Erase All Content and Settings failed while erasing: erase failed Restarting also stopped while booting: simctl was stopped before it finished, so what it changed is unknown. The device was shut down.")
    }

    @Test(.timeLimit(.minutes(1))) func aRestartCancelledBeforeItsShutdownStartedChangedNothing() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try toolsHolding("shutdown", in: directory)
        let restart = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await fixture.tools.restart(erasing: false)
        }
        await #expect(throws: CancellationError.self) { try await restart.value }
        #expect(!FileManager.default.fileExists(atPath: fixture.calls.path))
        // No child will open the pipe, so end the wait for one.
        try Data().write(to: directory.appendingPathComponent("ready"))
        _ = try await fixture.started.value
    }

    /// A boot's callers read the device's state next and a screenshot changes nothing, so neither has an outcome to report.
    @Test(.timeLimit(.minutes(1)), arguments: ["boot", "io"])
    func stoppingABootOrAReadEndsAsPlainCancellation(_ subcommand: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try toolsHolding(subcommand, in: directory)
        let running = Task {
            if subcommand == "boot" { try await fixture.tools.boot() }
            else { try await fixture.tools.screenshot(to: directory.appendingPathComponent("screen.png"), mask: .ignored) }
        }
        _ = try await fixture.started.value
        fixture.tools.cancel()
        await #expect(throws: CancellationError.self) { try await running.value }
    }

    /// Tools whose simctl records each subcommand and holds the named one until it is stopped. `started` ends once it is held.
    private func toolsHolding(_ subcommand: String, failing: String = "", in directory: URL) throws -> (tools: DeviceTools, calls: URL, started: Task<Data, any Error>) {
        let calls = directory.appendingPathComponent("calls"), ready = directory.appendingPathComponent("ready")
        let simctl = directory.appendingPathComponent("simctl")
        try #require(mkfifo(ready.path, 0o600) == 0)
        try """
            #!/bin/sh
            echo "$1" >> "\(calls.path)"
            if [ "$1" = \(subcommand) ]; then printf started > "\(ready.path)"; exec /bin/sleep 300; fi
            if [ "$1" = "\(failing)" ]; then echo "$1 failed" >&2; exit 1; fi
            """.write(to: simctl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: simctl.path)
        let tools = try DeviceTools(identifier: "test-device", xcodeURL: URL(fileURLWithPath: "/Applications/Xcode.app"), simctl: simctl)
        return (tools, calls, Task { try await performBlockingIO { try FileHandle(forReadingFrom: ready).readToEnd() ?? Data() } })
    }
}
