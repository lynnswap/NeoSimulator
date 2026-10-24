import ABIBridge
import Darwin
import Foundation

@MainActor
final class CoreDevicePairingBeacon {
    private let bindings: PairingBeaconBindings
    private var session: NativeSwiftValue?
    private var completion: PairingBeaconBindings.Handler?
    private var events: PairingBeaconBindings.Handler?
    private var pendingStart: CheckedContinuation<Void, any Error>?
    private var advertisement: (@MainActor (String, String?) -> Void)?
    private var issue: (@MainActor (String) -> Void)?
    private var stopped = false
    private var cleanupFailure: (any Error)?

    init() throws { bindings = try PairingBeaconBindings() }

    isolated deinit {
        if let failure = stopNow() { bindings.reportCleanup(failure) }
    }

    func start(advertisement: @escaping @MainActor (String, String?) -> Void,
               issue: @escaping @MainActor (String) -> Void) async throws {
        guard !stopped else { throw CancellationError() }
        if session != nil { return }
        guard pendingStart == nil else {
            throw CLIError.temporary("pairing-beacon-starting", "Nearby pairing is already starting.")
        }
        self.advertisement = advertisement
        self.issue = issue
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            do {
                try await withCheckedThrowingContinuation { continuation in
                    pendingStart = continuation
                    do {
                        let completion = try bindings.handler { [weak self, bindings] value in
                            guard let self else {
                                do { try bindings.endSuccess(in: value) }
                                catch { bindings.reportCleanup(error) }
                                return
                            }
                            self.receiveCompletion(value)
                        }
                        let events = try bindings.handler { [weak self] value in self?.receiveEvent(value) }
                        self.completion = completion
                        self.events = events
                        try unsafe bindings.initiate.unsafeInvoke(.main, completion, events)
                    } catch { _ = stopNow(failingStartWith: error) }
                }
                try Task.checkCancellation()
            } catch {
                let priorCleanup = cleanupFailure
                let failure = stopNow()
                throw Self.failure(error, cleanup: failure ?? priorCleanup)
            }
        } onCancel: {
            // stopNow resumes the pending caller with cancellation and any cleanup failure.
            Task { @MainActor [weak self] in _ = self?.stopNow() }
        }
    }

    func stop() async throws {
        if let failure = stopNow() { throw failure }
    }

    private func receiveCompletion(_ value: NativeSwiftValue) {
        guard !stopped, pendingStart != nil else {
            do { try bindings.endSuccess(in: value) }
            catch { bindings.reportCleanup(error) }
            return
        }
        do {
            if let session = try value.resolveEnumPayloadAndWait(forCase: "success") {
                self.session = session
                let continuation = pendingStart
                pendingStart = nil
                continuation?.resume()
            } else if let payload = try value.resolveEnumPayloadAndWait(forCase: "failure") {
                let error = try bindings.error(in: payload)
                _ = stopNow(failingStartWith: error)
            } else {
                throw CLIError.io("pairing-beacon-result", "Nearby pairing returned an unrecognized startup result.")
            }
        } catch { _ = stopNow(failingStartWith: error) }
    }

    private func receiveEvent(_ value: NativeSwiftValue) {
        guard !stopped else { return }
        do {
            if let payload = try value.resolveEnumPayloadAndWait(forCase: "show") {
                guard let values = try payload.withCopy({ $0 as? (String, String?) }) else {
                    throw CLIError.io("pairing-beacon-event", "Nearby pairing returned an unrecognized advertisement event.")
                }
                advertisement?(values.0, values.1)
            } else if let payload = try value.resolveEnumPayloadAndWait(forCase: "failure") {
                let error = try bindings.error(in: payload)
                if pendingStart != nil { _ = stopNow(failingStartWith: error) }
                else { issue?(error.localizedDescription) }
            }
        } catch {
            if pendingStart != nil { _ = stopNow(failingStartWith: error) }
            else { issue?(error.localizedDescription) }
        }
    }

    private func stopNow(failingStartWith error: any Error = CancellationError()) -> (any Error)? {
        stopped = true
        advertisement = nil
        issue = nil
        let continuation = pendingStart
        pendingStart = nil
        var failure: (any Error)?
        if let session {
            do {
                try bindings.end(session)
                self.session = nil
            } catch { failure = error }
        }
        cleanupFailure = failure
        if session == nil {
            completion = nil
            events = nil
        }
        continuation?.resume(throwing: Self.failure(error, cleanup: failure))
        return failure
    }

    private static func failure(_ error: any Error, cleanup: (any Error)?) -> any Error {
        guard let cleanup else { return error }
        return CLIError.io("pairing-beacon-cleanup", "\(error.localizedDescription) Ending nearby pairing also failed: \(cleanup.localizedDescription)")
    }
}

@MainActor
private final class PairingBeaconBindings {
    typealias Handler = NativeSwiftClosure<(NativeSwiftValue) -> Void>
    let initiate: NativeSwiftFunction<(DispatchQueue, Handler, Handler) -> Void>
    private let endSession: NativeSwiftMethod<() -> Void>

    init() throws {
        let path = "/Library/Apple/System/Library/PrivateFrameworks/RemotePairing.framework/Versions/A/RemotePairing"
        guard dlopen(path, RTLD_NOW | RTLD_LOCAL) != nil else {
            throw CLIError.unavailable("pairing-beacon-runtime", "Could not load the nearby pairing framework.")
        }
        let runtime = ABIRuntime.shared
        let session = try runtime.resolveSwiftTypeAndWait(named: "RemotePairing.DeviceInitiatedPairingBeaconingSession")
        let event = try runtime.resolveSwiftTypeAndWait(named: "RemotePairing.DeviceInitiatedPairingBeaconingSessionEvent")
        let result = try runtime.resolveSwiftTypeAndWait(named: "Swift.Result", genericArguments: [.type(session), .type((any Error).self)])
        // Result is @frozen: a class/error reference and an enum tag are direct components on arm64/arm64e.
        let resultABI = try NativeType.structure(named: result.name, fields: [.uint64, .uint8])
        initiate = try session.resolveAndWait(.staticMethod("initiateSession(withQueue:completionHandler:eventHandler:)",
            as: ((DispatchQueue, Handler, Handler) -> Void).self,
            valueABIs: [result: resultABI, event: try .opaque(named: event.name)]))
        endSession = try session.resolveAndWait(.method("endSession()", as: (() -> Void).self))
    }

    func handler(_ body: @escaping @MainActor (NativeSwiftValue) -> Void) throws -> Handler {
        try Handler { value in
            // initiateSession receives .main. This synchronous adapter neither hops queues nor sends the native value.
            dispatchPrecondition(condition: .onQueue(.main))
            nonisolated(unsafe) let mainQueueValue = value
            MainActor.assumeIsolated { body(mainQueueValue) }
        }
    }

    func error(in value: NativeSwiftValue) throws -> any Error {
        guard let error = try value.withCopy({ $0 as? any Error }) else {
            throw CLIError.io("pairing-beacon-error", "Nearby pairing returned an unrecognized error.")
        }
        return error
    }

    func endSuccess(in result: NativeSwiftValue) throws {
        if let session = try result.resolveEnumPayloadAndWait(forCase: "success") { try end(session) }
    }

    func end(_ session: NativeSwiftValue) throws {
        try unsafe endSession.unsafeInvoke(on: session)
    }

    func reportCleanup(_ error: any Error) {
        NSLog("NeoSimulator pairing beacon cleanup failed: %@", String(describing: error))
    }
}
