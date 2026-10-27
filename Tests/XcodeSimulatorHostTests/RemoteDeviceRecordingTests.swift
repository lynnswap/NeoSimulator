import AppKit
import Testing
@testable import XcodeSimulatorHost

@MainActor
@Suite struct RemoteDeviceRecordingTests {
    @Test func completedRecordingSurvivesScreenShutdownUntilTheCallerDiscardsIt() async throws {
        let transport = RecordingFixtureTransport()
        let session = try session(transport)
        try await session.start()
        #expect(session.canRecordScreen)
        try await session.startRecording(displayUniqueID: "fixture-display")
        #expect(session.hasUnfinishedRecording)
        #expect(session.recordingStartDate != nil)
        let result = try #require(try await session.stopRecording())
        #expect(result.data == RecordingFixtureHandle.result.data && result.duration == 2.5 && result.codec == "fixture-codec")
        #expect(transport.requestedDisplay == "fixture-display")
        #expect(!session.hasUnfinishedRecording)
        #expect(session.recordingStartDate == nil)
        do { try await session.startRecording(); Issue.record("An unsaved recording was overwritten") }
        catch { #expect(session.completedRecording?.data == result.data) }
        try await session.stop()
        #expect(session.completedRecording?.data == result.data && session.recordingState == .completed)
        session.discardCompletedRecording()
        #expect(session.completedRecording == nil && session.recordingState == .idle)
    }

    @Test func screenShutdownDrainsAPendingStartBeforeStoppingItsTransport() async throws {
        let gate = RecordingFixtureGate()
        let transport = RecordingFixtureTransport(startGate: gate)
        let session = try session(transport)
        try await session.start()
        let stopping = RecordingFixtureSignal()
        var startOwnershipWasReported = false
        session.onStateChange = { [weak session] in
            if session?.recordingState == .starting { startOwnershipWasReported = session?.hasUnfinishedRecording == true }
            if session?.recordingState == .stopping { stopping.signal() }
        }
        let start = Task { try await session.startRecording() }
        await gate.waitUntilEntered()
        #expect(session.hasUnfinishedRecording && startOwnershipWasReported)
        #expect(session.recordingStartDate == nil)
        let shutdown = Task { try await session.stop() }
        await stopping.wait()
        #expect(session.hasUnfinishedRecording)
        gate.finish()
        try await start.value
        try await shutdown.value
        #expect(transport.operations == ["record-start", "record-stop", "screen-stop"])
        #expect(session.completedRecording?.data == RecordingFixtureHandle.result.data)
    }

    @Test func aFailedRecordingStopRetainsItsHandleAndScreenForRetry() async throws {
        let transport = RecordingFixtureTransport()
        let session = try session(transport)
        try await session.start()
        var unfinishedAtLastNotification = false
        session.onStateChange = { [weak session] in
            unfinishedAtLastNotification = session?.hasUnfinishedRecording == true
        }
        transport.failNextStart = true
        do { try await session.startRecording(); Issue.record("Recording start failure was ignored") }
        catch {
            #expect(session.recordingState == .failed && !session.hasUnfinishedRecording)
            #expect(!unfinishedAtLastNotification)
            #expect(session.recordingStartDate == nil)
        }
        try await session.startRecording()
        transport.handle.failNextStop = true
        do { try await session.stop(); Issue.record("Recording failure was ignored") }
        catch {
            #expect(session.recordingState == .failed && session.recordingError != nil)
            #expect(session.hasUnfinishedRecording && unfinishedAtLastNotification)
            #expect(session.recordingStartDate == nil)
            #expect(!transport.operations.contains("screen-stop"))
        }
        try await session.stop()
        #expect(transport.handle.stopAttempts == 2)
        #expect(transport.operations == ["record-start", "record-start", "record-stop", "record-stop", "screen-stop"])
        #expect(!session.hasUnfinishedRecording && !unfinishedAtLastNotification)
        #expect(session.completedRecording?.data == RecordingFixtureHandle.result.data)
    }

    @Test func cancellationOfAStartingCallerStopsItsLateHandleAndRetainsTheMovie() async throws {
        let gate = RecordingFixtureGate()
        let transport = RecordingFixtureTransport(startGate: gate)
        let session = try session(transport)
        try await session.start()
        let start = Task { try await session.startRecording() }
        await gate.waitUntilEntered()
        start.cancel()
        gate.finish()
        do { try await start.value; Issue.record("Caller cancellation was lost") }
        catch { #expect(error is CancellationError) }
        #expect(transport.handle.stopAttempts == 1 && session.recordingState == .completed)
        #expect(session.recordingStartDate == nil)
        #expect(session.completedRecording?.data == RecordingFixtureHandle.result.data)
        try await session.stop()
    }

    private func session(_ transport: RecordingFixtureTransport) throws -> RemoteDeviceScreenSession {
        let json = Data(#"{"result":{"devices":[{"identifier":"recording-command-id","properties":{"hardware":{"reality":"physical"},"state":{"name":"Fixture"}}}]}}"#.utf8)
        let device = try #require(CoreDeviceInventoryDecoder.decode(json).first)
        return RemoteDeviceScreenSession(device: device) { _, _ in transport }
    }
}

@MainActor
private final class RecordingFixtureSignal {
    private var signaled = false
    private var waiter: CheckedContinuation<Void, Never>?
    func signal() { signaled = true; waiter?.resume(); waiter = nil }
    func wait() async {
        if signaled { return }
        await withCheckedContinuation { waiter = $0 }
    }
}

@MainActor
private final class RecordingFixtureGate {
    private var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    func hold() async {
        await withCheckedContinuation {
            release = $0
            entered = true
            waiter?.resume()
            waiter = nil
        }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func finish() { release?.resume(); release = nil }
}

private enum RecordingFixtureError: Error { case start, stop }

@MainActor
private final class RecordingFixtureHandle: RemoteScreenRecordingHandle {
    static let result = RemoteDeviceRecording(data: Data("fixture movie bytes".utf8), duration: 2.5, codec: "fixture-codec")
    var failNextStop = false
    var stopAttempts = 0
    var onStop: (() -> Void)?
    func stop() async throws -> RemoteDeviceRecording {
        stopAttempts += 1
        onStop?()
        if failNextStop { failNextStop = false; throw RecordingFixtureError.stop }
        return Self.result
    }
}

@MainActor
private final class RecordingFixtureTransport: RemoteScreenTransport {
    let inputCapabilities: Set<RemoteDeviceInputKind> = []
    let canRecordScreen = true
    let handle = RecordingFixtureHandle()
    var failNextStart = false
    private let startGate: RecordingFixtureGate?
    private(set) var requestedDisplay: String?
    private(set) var operations: [String] = []
    init(startGate: RecordingFixtureGate? = nil) {
        self.startGate = startGate
        handle.onStop = { [weak self] in self?.operations.append("record-stop") }
    }
    func start(events: @escaping @MainActor (RemoteScreenTransportEvent) -> Void) async throws { events(.connected) }
    func startRecording(displayUniqueID: String?) async throws -> any RemoteScreenRecordingHandle {
        operations.append("record-start")
        if failNextStart { failNextStart = false; throw RecordingFixtureError.start }
        requestedDisplay = displayUniqueID
        await startGate?.hold()
        return handle
    }
    func send(_ input: RemoteScreenInput) async throws {}
    func releaseInputs() async throws {}
    func stop() async throws { operations.append("screen-stop") }
}
