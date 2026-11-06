import Foundation
import NeoSimulatorDeviceIO
import Observation

/// What is known about a simulator's guest, which everything that presents the device shares. It holds what the device
/// last answered, so reading it asks the device nothing, and nil means that the device has not said. Sessions fill it
/// through their requests, and the device's channel keeps its health current.
@MainActor @Observable
public final class SimulatorDeviceModel {
    /// Whether biometrics are enrolled. Touch ID, Face ID, and Optic ID share this guest state.
    public private(set) var isBiometricEnrolled: Bool?
    public private(set) var showsStandBy: Bool?
    /// The Core Animation debug options as the device last reported them.
    public private(set) var debugOptions: [CADebugOption: Bool] = [:]
    /// The native call that has outlived its deadline, while one has. Requests are not sent until it returns.
    public private(set) var unresponsiveOperation: String?
    /// Why the last read or reapplied setting failed, until a later read succeeds.
    public private(set) var lastIssue: String?

    @ObservationIgnored private var health: Task<Void, Never>?
    @ObservationIgnored private var recoveryObservers: [UUID: AsyncStream<Void>.Continuation] = [:]

    package init() {}

    isolated deinit { health?.cancel() }

    /// Keeps `unresponsiveOperation` as `channel` reports it.
    package func follow(_ channel: SimulatorDeviceChannel) {
        let changes = channel.healthChanges()
        health = Task { [weak self] in
            for await health in changes {
                guard let self else { return }
                self.apply(health)
            }
        }
    }

    private func apply(_ health: DeviceChannelHealth) {
        switch health {
        case .unresponsive(let call, _):
            unresponsiveOperation = call
        case .ready:
            guard unresponsiveOperation != nil else { return }
            unresponsiveOperation = nil
            for observer in recoveryObservers.values { observer.yield() }
        }
    }

    /// An element each time a call that outlived its deadline returns, which is the only thing that recovers a device.
    package func recoveries() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let identifier = UUID()
        recoveryObservers[identifier] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.recoveryObservers[identifier] = nil }
        }
        return stream
    }

    /// Holds a reading, and returns whether it changed what is held.
    package func update(biometricEnrolled: Bool?, showsStandBy: Bool?, debugOptions: [CADebugOption: Bool]) -> Bool {
        lastIssue = nil
        guard biometricEnrolled != isBiometricEnrolled || showsStandBy != self.showsStandBy
                || debugOptions != self.debugOptions else { return false }
        isBiometricEnrolled = biometricEnrolled
        self.showsStandBy = showsStandBy
        self.debugOptions = debugOptions
        return true
    }

    package func note(issue: String) { lastIssue = issue }

    /// What a session read stops being known when the session ends.
    package func forgetGuestState() {
        isBiometricEnrolled = nil
        showsStandBy = nil
        debugOptions = [:]
    }
}

/// The model of each device this process has presented. Like a channel, a model lives as long as the process, so that
/// a session made again for the same device finds what the first knew of its health.
@MainActor
package final class SimulatorDeviceRegistry {
    package static let shared = SimulatorDeviceRegistry()

    private var models: [SimulatorDeviceIdentifier: SimulatorDeviceModel] = [:]

    package init() {}

    package func model(for identifier: SimulatorDeviceIdentifier, channel: SimulatorDeviceChannel) -> SimulatorDeviceModel {
        if let model = models[identifier] { return model }
        let model = SimulatorDeviceModel()
        model.follow(channel)
        models[identifier] = model
        return model
    }
}
