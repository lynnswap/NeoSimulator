import Foundation
@testable import NeoSimulatorDeviceIO
@testable import NeoSimulatorHostSupport
@testable import NeoSimulatorKit
@testable import NeoSimulatorNative
@testable import NeoSimulatorPresentationAdapters
import Testing

@MainActor
struct ModuleBoundaryTests {
    /// The Xcode these tests run with.
    private static func xcodeURL() async throws -> URL {
        let selection = Process()
        let output = Pipe()
        selection.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        selection.arguments = ["-p"]
        selection.standardOutput = output
        try selection.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        selection.waitUntilExit()
        let developerPath = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
            ?? String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: developerPath).deletingLastPathComponent().deletingLastPathComponent()
            .resolvingSymlinksInPath()
    }

    // MARK: Native loading

    /// Each check, load and record of the toolkit is one step, so contexts asking at once cannot end up with two.
    @Test(.timeLimit(.minutes(1)))
    func concurrentContextsKeepOneUIToolkit() async throws {
        let xcode = try await Self.xcodeURL()
        let other = xcode.appendingPathComponent("DifferentXcode.app")
        let results = await withTaskGroup(of: (requested: URL, result: Result<URL, NativeRuntimeError>).self) { group in
            for index in 0..<8 {
                let requested = index.isMultiple(of: 2) ? xcode : other
                group.addTask {
                    do { return (requested, .success(try await NativeFrameworks.loadUIToolkit(requested: requested, context: xcode))) }
                    catch { return (requested, .failure(error as! NativeRuntimeError)) }
                }
            }
            var results: [(requested: URL, result: Result<URL, NativeRuntimeError>)] = []
            for await result in group { results.append(result) }
            return results
        }
        for (requested, result) in results {
            if requested == xcode { #expect(try result.get() == xcode) }
            else { #expect(throws: NativeRuntimeError.self) { try result.get() } }
        }
        await #expect(throws: NativeRuntimeError.toolkitAlreadyLoaded(from: xcode)) {
            try await NativeFrameworks.loadUIToolkit(requested: other, context: xcode)
        }
        // With nothing requested, a context uses what the process already has.
        #expect(try await NativeFrameworks.loadUIToolkit(requested: nil, context: other) == xcode)
        await #expect(throws: NativeRuntimeError.toolkitAlreadyLoaded(from: xcode)) {
            try await NativeFrameworks.loadDeviceKit(from: other)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func aMissingFrameworkIsTheLoadersOwnFailure() async {
        let path = "/nonexistent/Missing.framework"
        await #expect(throws: NativeRuntimeError.frameworkMissing(path: path)) { try await NativeFrameworks.load(path) }
        await #expect {
            try await CoreDeviceRuntime.loading("fixture-runtime") { try await NativeFrameworks.load(path) }
        } throws: {
            let failure = $0 as? DeviceIOError
            return failure?.identifier == "fixture-runtime" && failure?.runtimeFailure == .frameworkMissing(path: path)
        }
    }

    // MARK: Errors across layers

    @Test func hostFailuresReadTheIdentifierOfEveryLayersError() {
        let failures: [any Error] = [
            DeviceIOError.unavailable("unsupported-xcode", "Unsupported"),
            DeviceDomainError.unavailable("unsupported-xcode", "Unsupported"),
            HostOperationError.unavailable("unsupported-xcode", "Unsupported"),
            RemoteScreenError.unavailable("unsupported-xcode", "Unsupported"),
        ]
        for failure in failures {
            let read = SimulatorHostFailure(failure)
            #expect(read.kind == .unavailableXcode)
            #expect(read.technicalDetails == "unsupported-xcode: Unsupported")
        }
        #expect(SimulatorHostFailure(DeviceIOError.runtime("simulator-runtime", .frameworkMissing(path: "/x"))).kind == .launchFailed)
        #expect(SimulatorHostFailure(HostOperationError.temporary("neo-host-launch-partial-success", "Partial")).kind == .partialSuccess)
        let plain = SimulatorHostFailure(CocoaError(.fileNoSuchFile))
        #expect(plain.kind == .operationFailed)
    }

    @Test func hostFailuresKeepTheRecoveryThatTheFailureNamed() {
        let failure = HostOperationError(category: .configuration, identifier: "fixture", message: "Failed",
                                         failureReason: "Because", recoverySuggestion: "Do this")
        let read = SimulatorHostFailure(failure)
        #expect(read.failureReason == "Because" && read.recoverySuggestion == "Do this")
    }

    @Test func thePublicErrorKeepsItsUnderlyingFailureAndUnknownOutcome() throws {
        let lower = DeviceIOError.io("fixture-transport", "The transport failed")
        guard case .failed(let message, let underlying) = SimulatorError(mapping: lower) else {
            Issue.record("A lower layer's failure should stay underneath the public error.")
            return
        }
        #expect(message == "The transport failed")
        #expect((underlying as? DeviceIOError) == lower)

        let unknown = DeviceOperationFailure.outcomeUnknown(operation: "set the device's location", cause: .timedOut(.seconds(1)))
        guard case .outcomeUnknown(_, let cause) = SimulatorError(mapping: unknown) else {
            Issue.record("A request that may yet apply should stay an unknown outcome.")
            return
        }
        #expect(cause is DeviceOperationFailure)

        guard case .conflict("Busy") = SimulatorError(mapping: SimulatorError.conflict("Busy")) else {
            Issue.record("A public error should pass through unchanged.")
            return
        }
    }

    @Test func aPublicCallersCancellationStaysCancellation() async {
        await #expect(throws: CancellationError.self) {
            try await mappingToSimulatorError { () async throws -> Void in throw CancellationError() }
        }
        await #expect(throws: SimulatorError.self) {
            try await mappingToSimulatorError { () async throws -> Void in throw DeviceIOError.io("fixture", "Failed") }
        }
    }

    // MARK: A context's presentation

    private final class Conflicts: HostConflictChecking {
        var conflictingHostName: String?
        var onConflict: (() -> Void)?
        func check() throws {
            if let conflictingHostName { throw SimulatorError.conflict("\(conflictingHostName) is running.") }
        }
    }

    private final class Presenter: DevicePresenter {
        func connectDisplay(_ request: DeviceConnectionRequest) async throws -> ConnectedDeviceDisplay {
            throw SimulatorError.unavailable("This presenter connects nothing.")
        }
        func makePresentation(of session: DeviceSession, offersLifetimeChoice: Bool,
                              events: DevicePresentationEvents) throws -> any DevicePresentation {
            throw SimulatorError.unavailable("This presenter presents nothing.")
        }
        func finishCaptures() -> [any Error] { [] }
        func openLog(_ log: URL) async throws {}
        func hostKeyboardLanguage() -> String? { nil }
    }

    /// Loading a context chooses no presentation; a conflict or failed load leaves it free to take one, and it takes one.
    @Test(.timeLimit(.minutes(1)))
    func aContextTakesOnePresentationOnlyWhenItCanRun() async throws {
        let context = try await SimulatorContext.load(xcodeURL: try await Self.xcodeURL())
        var loads = 0
        let conflicts = Conflicts()
        conflicts.conflictingHostName = "Simulator"
        await #expect(throws: SimulatorError.self) {
            try await context.installPresentation(load: { loads += 1 }, presenter: Presenter(), conflicts: conflicts)
        }
        #expect(loads == 0)
        conflicts.conflictingHostName = nil
        await #expect(throws: DeviceIOError.self) {
            try await context.installPresentation(load: { throw DeviceIOError.unavailable("fixture-load", "Failed") },
                                                  presenter: Presenter(), conflicts: conflicts)
        }
        try await context.installPresentation(load: { loads += 1 }, presenter: Presenter(), conflicts: conflicts)
        #expect(loads == 1 && conflicts.onConflict != nil)
        await #expect(throws: SimulatorError.self) {
            try await context.installPresentation(load: { loads += 1 }, presenter: Presenter(), conflicts: Conflicts())
        }
        #expect(loads == 1)
        try await context.invalidate()
    }
}
