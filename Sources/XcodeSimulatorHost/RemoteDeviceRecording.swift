import ABIBridge
import Foundation

/// A completed native recording retained independently of the screen connection.
public struct RemoteDeviceRecording: Sendable {
    public let data: Data
    public let duration: TimeInterval
    /// The codec reported by CoreDevice, without inferring the movie container format.
    public let codec: String
}

public enum RemoteDeviceRecordingState: Equatable, Sendable {
    case idle, starting, recording, stopping, completed, failed
}

@MainActor
protocol RemoteScreenRecordingHandle: AnyObject {
    func stop() async throws -> RemoteDeviceRecording
}

/// Keeps native ownership through caller cancellation and overlapping screen shutdown.
@MainActor
final class RemoteScreenRecording {
    private(set) var state = RemoteDeviceRecordingState.idle
    private(set) var completed: RemoteDeviceRecording?
    private(set) var lastError: (any Error)?
    var onChange: (() -> Void)?
    private var handle: (any RemoteScreenRecordingHandle)?
    private var starting: Task<Void, any Error>?
    private var stopping: Task<RemoteDeviceRecording?, any Error>?
    var hasUnfinishedRecording: Bool { starting != nil || handle != nil || stopping != nil }

    func start(using begin: @escaping @MainActor () async throws -> any RemoteScreenRecordingHandle) async throws {
        try Task.checkCancellation()
        guard starting == nil, stopping == nil, handle == nil, completed == nil else {
            throw CLIError.unavailable("remote-recording-busy", "Finish and save or discard the current recording before starting another.")
        }
        state = .starting
        lastError = nil
        onChange?()
        // Cancellation of the caller cannot abandon a handle returned by a late native start.
        let task = Task { [self] in
            do {
                handle = try await begin()
                if stopping == nil { state = .recording }
                onChange?()
            } catch {
                lastError = error
                state = .failed
                onChange?()
                throw error
            }
        }
        starting = task
        defer { starting = nil; onChange?() }
        do {
            try await task.value
            try Task.checkCancellation()
        } catch {
            if error is CancellationError, handle != nil || stopping != nil {
                do { _ = try await stop() }
                catch let cleanup { throw RemoteDeviceScreenSession.combining(error, cleanup: cleanup) }
            }
            throw error
        }
    }

    @discardableResult
    func stop() async throws -> RemoteDeviceRecording? {
        if let stopping { return try await stopping.value }
        guard starting != nil || handle != nil else { return completed }
        state = .stopping
        onChange?()
        let start = starting
        let task = Task { [self] () async throws -> RemoteDeviceRecording? in
            try await start?.value
            guard let handle else { return completed }
            let result = try await handle.stop()
            self.handle = nil
            completed = result
            lastError = nil
            state = .completed
            onChange?()
            return result
        }
        stopping = task
        defer { stopping = nil; onChange?() }
        do { return try await task.value }
        catch {
            lastError = error
            state = .failed
            onChange?()
            throw error
        }
    }

    func discardCompleted() {
        guard completed != nil else { return }
        completed = nil
        state = .idle
        onChange?()
    }
}

extension CoreDeviceRemoteScreenDevice {
    func startRecording(displayUniqueID: String?) async throws -> any RemoteScreenRecordingHandle {
        let implementation = try await implementation(capability: "ScreenRecordingCapability",
            feature: "com.apple.coredevice.feature.screenrecording")
        let start = try await implementation.type.resolve(.method(
            "(extension in CoreDevice):CoreDevice.ScreenRecordingProtocol.recordScreen(displayUniqueID:)",
            as: ((String?) async throws -> NativeSwiftValue).self))
        let handle = try await unsafe start.unsafeInvoke(on: implementation, displayUniqueID).copyUnderlyingValue()
        return NativeScreenRecordingHandle(remote: self, implementation: implementation, handle: handle)
    }
}

@MainActor
private final class NativeScreenRecordingHandle: RemoteScreenRecordingHandle {
    private let remote: CoreDeviceRemoteScreenDevice
    private let implementation: NativeSwiftValue
    private let handle: NativeSwiftValue
    private var output: NativeSwiftValue?

    init(remote: CoreDeviceRemoteScreenDevice, implementation: NativeSwiftValue, handle: NativeSwiftValue) {
        self.remote = remote
        self.implementation = implementation
        self.handle = handle
    }

    func stop() async throws -> RemoteDeviceRecording {
        let nativeOutput: NativeSwiftValue
        if let output { nativeOutput = output }
        else {
            let stop = try await handle.type.resolve(.method("CoreDevice.ScreenRecordingHandle.stopRecording()",
                as: (() async throws -> NativeSwiftValue).self))
            nativeOutput = try await unsafe stop.unsafeInvoke(on: handle).copyUnderlyingValue()
            output = nativeOutput
        }
        // Retain the native output if projection fails, so retry never stops the handle twice.
        let data = try await nativeOutput.type.resolve(.getter("videoData", as: (() -> Data).self))
        let duration = try await nativeOutput.type.resolve(.getter("duration", as: (() -> Double).self))
        let codec = try await nativeOutput.type.resolve(.getter("codec", as: (() -> NativeSwiftValue).self))
        let nativeCodec = try unsafe codec.unsafeInvoke(on: nativeOutput)
        let codecName = try await nativeCodec.type.resolve(.getter("rawValue", as: (() -> String).self))
        return try unsafe RemoteDeviceRecording(data: data.unsafeInvoke(on: nativeOutput),
            duration: duration.unsafeInvoke(on: nativeOutput), codec: codecName.unsafeInvoke(on: nativeCodec))
    }
}
