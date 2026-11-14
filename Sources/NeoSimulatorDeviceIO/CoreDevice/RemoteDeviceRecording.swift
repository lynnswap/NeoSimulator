import ABIBridge
import Foundation

/// A completed native recording retained independently of the screen connection.
package struct RemoteDeviceRecording: Sendable {
    package let data: Data
    package let duration: TimeInterval
    /// The codec reported by CoreDevice, without inferring the movie container format.
    package let codec: String
}

package enum RemoteDeviceRecordingState: Equatable, Sendable {
    case idle, starting, recording, stopping, completed, failed
}

@MainActor
package protocol RemoteScreenRecordingHandle: AnyObject {
    func stop() async throws -> RemoteDeviceRecording
}

/// Keeps native ownership through caller cancellation and overlapping screen shutdown.
@MainActor
package final class RemoteScreenRecording {
    package private(set) var state = RemoteDeviceRecordingState.idle
    package private(set) var completed: RemoteDeviceRecording?
    package private(set) var lastError: (any Error)?
    private var beganAt: Date?
    package var startDate: Date? { state == .recording ? beganAt : nil }
    package var onChange: (() -> Void)?
    private var handle: (any RemoteScreenRecordingHandle)?
    private var starting: Task<Void, any Error>?
    private var stopping: Task<RemoteDeviceRecording?, any Error>?
    package var hasUnfinishedRecording: Bool { starting != nil || handle != nil || stopping != nil }

    package init() {}

    package func start(using begin: @escaping @MainActor () async throws -> any RemoteScreenRecordingHandle) async throws {
        try Task.checkCancellation()
        guard starting == nil, stopping == nil, handle == nil, completed == nil else {
            throw DeviceIOError.unavailable("remote-recording-busy", "Finish and save or discard the current recording before starting another.")
        }
        state = .starting
        lastError = nil
        // Cancellation of the caller cannot abandon a handle returned by a late native start.
        let task = Task { [self] in
            do {
                handle = try await begin()
                beganAt = Date()
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
        onChange?()
        defer { starting = nil; onChange?() }
        do {
            try await task.value
            try Task.checkCancellation()
        } catch {
            if error is CancellationError, handle != nil || stopping != nil {
                do { _ = try await stop() }
                catch let cleanup {
                    throw DeviceIOError.io("remote-screen-cleanup", "\(error.localizedDescription) Disconnecting the screen also failed: \(cleanup.localizedDescription)")
                }
            }
            throw error
        }
    }

    @discardableResult
    package func stop() async throws -> RemoteDeviceRecording? {
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

    package func discardCompleted() {
        guard completed != nil else { return }
        completed = nil
        state = .idle
        onChange?()
    }
}

extension CoreDeviceRemoteScreenDevice {
    package func startRecording(displayUniqueID: String?) async throws -> any RemoteScreenRecordingHandle {
        let implementation = try await implementation(capability: "ScreenRecordingCapability",
            feature: "com.apple.coredevice.feature.screenrecording")
        let errorType = try await runtime.resolve(.swift(.type("CoreDevice.CoreDeviceError")))
        let sampleError = try await errorType.resolve(.swift(.staticGetter("ioError", as: (() -> NativeSwiftValue).self,
            valueABIs: [errorType: try .opaque(named: errorType.name)])))
        guard let failure = try unsafe sampleError.unsafeInvoke().withCopy({ $0 as? any Error }) else {
            throw DeviceIOError.unavailable("remote-screen-recording", "The native recording error type could not be resolved.")
        }
        return try await startRecording(displayUniqueID: displayUniqueID, implementation: implementation, failure: failure)
    }

    /// - Parameter failure: A value of the error type that CoreDevice's recording methods throw, which their
    ///   signatures name.
    private func startRecording<Failure: Error>(displayUniqueID: String?, implementation: NativeSwiftValue,
                                                failure: Failure) async throws -> any RemoteScreenRecordingHandle {
        let start = try await implementation.type.resolve(.swift(.method(
            "(extension in CoreDevice):CoreDevice.ScreenRecordingProtocol.recordScreen(displayUniqueID:)",
            as: ((String?) async throws(Failure) -> NativeSwiftValue).self)))
        let handle = try await unsafe start.unsafeInvoke(on: implementation, displayUniqueID)
        return NativeScreenRecordingHandle(remote: self, implementation: implementation, handle: handle) { handle in
            let stop = try await handle.type.resolve(.swift(.method("CoreDevice.ScreenRecordingHandle.stopRecording()",
                as: (() async throws(Failure) -> NativeSwiftValue).self)))
            return try await unsafe stop.unsafeInvoke(on: handle)
        }
    }
}

@MainActor
private final class NativeScreenRecordingHandle: RemoteScreenRecordingHandle {
    private let remote: CoreDeviceRemoteScreenDevice
    private let implementation: NativeSwiftValue
    private let handle: NativeSwiftValue
    private let stopRecording: @MainActor (NativeSwiftValue) async throws -> NativeSwiftValue
    private var output: NativeSwiftValue?

    init(remote: CoreDeviceRemoteScreenDevice, implementation: NativeSwiftValue, handle: NativeSwiftValue,
         stopRecording: @escaping @MainActor (NativeSwiftValue) async throws -> NativeSwiftValue) {
        self.remote = remote
        self.implementation = implementation
        self.handle = handle
        self.stopRecording = stopRecording
    }

    func stop() async throws -> RemoteDeviceRecording {
        let nativeOutput: NativeSwiftValue
        if let output { nativeOutput = output }
        else {
            nativeOutput = try await stopRecording(handle)
            output = nativeOutput
        }
        // Retain the native output if projection fails, so retry never stops the handle twice.
        let dataType = try await remote.runtime.resolve(.swift(.type("Foundation.Data")))
        // Data is @frozen and returned as its two words.
        let data = try await nativeOutput.type.resolve(.swift(.getter("videoData", as: (() -> Data).self,
            valueABIs: [dataType: try .structure(named: dataType.name, fields: [.uint64, .uint64])])))
        let duration = try await nativeOutput.type.resolve(.swift(.getter("duration", as: (() -> Double).self)))
        let codec = try await nativeOutput.type.resolve(.swift(.getter("codec", as: (() -> NativeSwiftValue).self)))
        let nativeCodec = try unsafe codec.unsafeInvoke(on: nativeOutput)
        let codecName = try await nativeCodec.type.resolve(.swift(.getter("rawValue", as: (() -> String).self)))
        return try unsafe RemoteDeviceRecording(data: data.unsafeInvoke(on: nativeOutput),
            duration: duration.unsafeInvoke(on: nativeOutput), codec: codecName.unsafeInvoke(on: nativeCodec))
    }
}
