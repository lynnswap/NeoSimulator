import Foundation

public struct NearbyPairingDevice: Equatable, Sendable {
    public let identifier: String
    public let name: String
    public let modelName: String?
    public let operatingSystem: String?
}

public struct DevicePairingChallenge: Equatable, Sendable {
    public let deviceIdentifier: String?
    public let deviceName: String?
    public let lastAttemptFailed: Bool
    public internal(set) var throttledBy: Double?
}

@MainActor
protocol DevicePairingTransport: AnyObject {
    func start(devices: @escaping @MainActor ([NearbyPairingDevice]) -> Void,
               advertisement: @escaping @MainActor (String, String?) -> Void,
               issue: @escaping @MainActor (String) -> Void) async throws
    func pair(identifier: String,
              requestPIN: @escaping @MainActor (Bool, Double?) async throws -> String) async throws
    func stop() async throws
}

/// Owns discovery, advertising, and an outstanding PIN challenge until the pairing window closes.
@MainActor
public final class DevicePairingSession {
    public private(set) var devices: [NearbyPairingDevice] = []
    public private(set) var advertisedName: String?
    public private(set) var advertisementDetail: String?
    public private(set) var challenge: DevicePairingChallenge?
    public private(set) var isPairing = false
    public private(set) var lastIssue: String?
    public var onChange: (() -> Void)?

    private let transport: any DevicePairingTransport
    private var startTask: Task<Void, any Error>?
    private var pairTask: Task<Void, any Error>?
    private var throttleTask: Task<Void, Never>?
    private var pendingPIN: CheckedContinuation<String, any Error>?
    private var challengeGeneration = 0
    private var stopping = false
    private var started = false

    public convenience init() throws {
        do { self.init(transport: try CoreDevicePairingTransport()) }
        catch {
            NSLog("NeoSimulator nearby pairing: %@", String(describing: error))
            throw CLIError.unavailable("nearby-pairing-runtime", "Nearby pairing is unavailable with this version of macOS.")
        }
    }

    init(transport: any DevicePairingTransport) { self.transport = transport }

    public func start() async throws {
        guard !stopping else { throw CancellationError() }
        if let startTask { try await startTask.value; return }
        guard !started else { return }
        lastIssue = nil
        let task = Task { [self] in
            try await self.transport.start(devices: { [weak self] devices in
                guard let self, !self.stopping else { return }
                self.devices = devices
                self.onChange?()
            }, advertisement: { [weak self] name, detail in
                guard let self, !self.stopping else { return }
                self.advertisedName = name
                self.advertisementDetail = detail
                self.onChange?()
            }, issue: { [weak self] issue in
                guard let self, !self.stopping else { return }
                self.lastIssue = issue
                self.onChange?()
            })
        }
        startTask = task
        defer { startTask = nil; onChange?() }
        do {
            try await task.value
            guard !stopping else { throw CancellationError() }
            started = true
        } catch {
            let failure: any Error
            do { try await transport.stop(); failure = error }
            catch let cleanup { failure = DevicePairingCleanupFailure(original: error, cleanup: cleanup) }
            if !stopping, !(failure is CancellationError) { lastIssue = failure.localizedDescription }
            throw failure
        }
    }

    public func pair(deviceIdentifier: String) async throws {
        guard !stopping, started else { throw CancellationError() }
        guard !isPairing else {
            throw CLIError.temporary("pairing-in-progress", "Finish or cancel the current pairing request first.")
        }
        guard let device = devices.first(where: { $0.identifier == deviceIdentifier }) else {
            throw CLIError.unavailable("pairing-device", "The selected nearby device is no longer available.")
        }
        isPairing = true
        lastIssue = nil
        onChange?()
        let task = Task { [self] in
            try await self.transport.pair(identifier: deviceIdentifier) { [weak self] failed, throttle in
                guard let self else { throw CancellationError() }
                return try await self.requestPIN(for: device, failed: failed, throttle: throttle)
            }
        }
        pairTask = task
        defer {
            pairTask = nil
            isPairing = false
            clearChallenge()
            onChange?()
        }
        do { try await task.value }
        catch {
            if !stopping, !(error is CancellationError) { lastIssue = error.localizedDescription }
            throw error
        }
    }

    public func answerPIN(_ value: String) throws {
        guard !stopping, let pendingPIN else { return }
        guard challenge?.throttledBy == nil else {
            throw CLIError.temporary("pairing-throttled", "Wait before entering the PIN again.")
        }
        self.pendingPIN = nil
        throttleTask?.cancel()
        challenge = nil
        pendingPIN.resume(returning: value)
        onChange?()
    }

    public func cancelChallenge() {
        pairTask?.cancel()
        clearChallenge()
        onChange?()
    }

    public func stop() async throws {
        stopping = true
        startTask?.cancel()
        pairTask?.cancel()
        clearChallenge()
        var cleanupError: (any Error)?
        do { try await transport.stop() }
        catch { cleanupError = error }
        _ = try? await startTask?.value
        _ = try? await pairTask?.value
        started = false
        advertisedName = nil
        advertisementDetail = nil
        devices = []
        if let cleanupError { lastIssue = cleanupError.localizedDescription }
        onChange?()
        if let cleanupError { throw cleanupError }
    }

    private func requestPIN(for device: NearbyPairingDevice, failed: Bool, throttle: Double?) async throws -> String {
        guard !stopping else { throw CancellationError() }
        try Task.checkCancellation()
        clearChallenge()
        let wait = throttle.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        challenge = DevicePairingChallenge(deviceIdentifier: device.identifier, deviceName: device.name,
                                          lastAttemptFailed: failed, throttledBy: wait)
        let generation = challengeGeneration
        if let wait {
            throttleTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(wait)) }
                catch { return }
                guard let self, !self.stopping, self.challengeGeneration == generation else { return }
                self.challenge?.throttledBy = nil
                self.onChange?()
            }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingPIN = continuation
                onChange?()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.challengeGeneration == generation else { return }
                self.clearChallenge()
                self.onChange?()
            }
        }
    }

    private func clearChallenge() {
        challengeGeneration += 1
        throttleTask?.cancel()
        throttleTask = nil
        challenge = nil
        let pending = pendingPIN
        pendingPIN = nil
        pending?.resume(throwing: CancellationError())
    }
}

struct DevicePairingCleanupFailure: LocalizedError {
    let original: any Error
    let cleanup: any Error

    var errorDescription: String? {
        "\(original.localizedDescription)\nPairing cleanup also failed: \(cleanup.localizedDescription)"
    }
}
