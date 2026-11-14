import Foundation
import IOKit
import NeoSimulatorDeviceIO
import Observation

package enum DevicePosture: String, CaseIterable, Sendable {
    case closed, partiallyOpen, open

    package var title: String {
        switch self {
        case .closed: "Closed"
        case .partiallyOpen: "Partially Open"
        case .open: "Open"
        }
    }

    package var degrees: Double {
        switch self {
        case .closed: 0
        case .partiallyOpen: 130
        case .open: 180
        }
    }

    package static func confirmed(angle: Double?) -> Self? {
        guard let angle, angle.isFinite else { return nil }
        if angle < 15 { return .closed }
        if angle > 175 { return .open }
        return .partiallyOpen
    }
}

@MainActor
package protocol DevicePostureTransport: AnyObject {
    func observe(_ update: @escaping @MainActor (Double?) -> Void) async throws
    func send(_ posture: DevicePosture) async throws
}

/// A button request never becomes the selected posture until hinge feedback confirms it.
@Observable @MainActor
package final class DevicePostureModel {
    package enum State: Equatable, Sendable { case idle, connecting, connected, unsupported, stopped, failed }

    package let deviceID: DeviceInventoryID
    package private(set) var state = State.idle
    package private(set) var angle: Double?
    package var confirmedPosture: DevicePosture? { DevicePosture.confirmed(angle: angle) }
    package private(set) var isSending = false
    package private(set) var isSupported = false
    package private(set) var lastError: (any Error)?
    package var canSelect: Bool { state == .connected && !isSending }

    package static func canInspect(capabilities: Set<String>) -> Bool { DevicePosturePayload.features.isSubset(of: capabilities) }
    @ObservationIgnored private let makeTransport: @MainActor (DeviceInventoryID) async throws -> (any DevicePostureTransport)?
    @ObservationIgnored private var transport: (any DevicePostureTransport)?
    @ObservationIgnored private var starting: Task<Void, any Error>?
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private var command: Task<Void, any Error>?
    @ObservationIgnored private var stopping: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    package init(deviceID: DeviceInventoryID,
         makeTransport: @escaping @MainActor (DeviceInventoryID) async throws -> (any DevicePostureTransport)?) {
        self.deviceID = deviceID
        self.makeTransport = makeTransport
    }

    isolated deinit { starting?.cancel(); observation?.cancel(); command?.cancel() }

    package func start() async throws {
        if let stopping { await stopping.value }
        if let starting { try await starting.value; return }
        guard state != .connected else { return }
        if transport != nil { await stop() }
        generation += 1
        let token = generation
        state = .connecting
        angle = nil
        lastError = nil
        let task = Task { [weak self, makeTransport, deviceID] in
            let transport = try await makeTransport(deviceID)
            try Task.checkCancellation()
            guard let self, self.generation == token else { throw CancellationError() }
            guard let transport else { self.state = .unsupported; return }
            self.transport = transport
            self.isSupported = true
            self.state = .connected
            self.observation = Task { [weak self, transport] in
                do {
                    try await transport.observe { [weak self] angle in
                        guard let self, self.generation == token, !Task.isCancelled else { return }
                        self.angle = angle
                    }
                    if !Task.isCancelled {
                        self?.observationFailed(DeviceDomainError.unavailable("device-posture-observation", "The device's hinge observation ended."), generation: token)
                    }
                } catch {
                    if !Task.isCancelled { self?.observationFailed(error, generation: token) }
                }
            }
        }
        starting = task
        defer { if generation == token { starting = nil } }
        do {
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        } catch {
            if generation == token {
                state = error is CancellationError ? .stopped : .failed
                lastError = error is CancellationError ? nil : error
            }
            throw error
        }
    }

    package func select(_ posture: DevicePosture) async throws {
        guard canSelect, let transport else {
            throw DeviceDomainError.unavailable("device-posture-unavailable", "The device's posture controls are unavailable.")
        }
        let token = generation
        isSending = true
        lastError = nil
        let task = Task { try await transport.send(posture) }
        command = task
        defer {
            if generation == token { command = nil; isSending = false }
        }
        do {
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
        } catch {
            if generation == token, !(error is CancellationError) { lastError = error }
            throw error
        }
    }

    package func stop() async {
        if let stopping { await stopping.value; return }
        generation += 1
        let starting = self.starting, observation = self.observation, command = self.command
        self.starting = nil
        self.observation = nil
        self.command = nil
        state = .stopped
        angle = nil
        starting?.cancel()
        observation?.cancel()
        command?.cancel()
        let task = Task {
            _ = await starting?.result
            await observation?.value
            _ = await command?.result
        }
        stopping = task
        await task.value
        transport = nil
        isSending = false
        stopping = nil
    }

    private func observationFailed(_ error: any Error, generation token: Int) {
        guard generation == token else { return }
        state = .failed
        angle = nil
        lastError = error
        command?.cancel()
    }
}

package enum DevicePosturePayload {
    package static let features: Set<String> = ["com.apple.coredevice.feature.remote.hid.vendordefined",
        "com.apple.coredevice.feature.monitormotion", "com.apple.coredevice.feature.remote.universalhidservice"]

    package static func supports(hardwareModel: String?, features: Set<String>) -> Bool {
        isFoldingModel(hardwareModel) && Self.features.isSubset(of: features)
    }

    /// Whether a hardware model is a folding iPhone, which DeviceKit draws as a model that folds.
    package static func isFoldingModel(_ hardwareModel: String?) -> Bool {
        ["v68", "v68ap", "v68dev"].contains(hardwareModel?.lowercased() ?? "")
    }

    package static func serialize(_ posture: DevicePosture) throws -> Data {
        let dictionary: [String: Any] = ["provider": "com.apple.Virtualization.VirtualMachines",
            "source": "hinge-slider-control", "type": "range", "value": posture.degrees]
        guard let data = IOCFSerialize(dictionary as CFDictionary, CFOptionFlags(kIOCFSerializeToBinary)) else {
            throw DeviceDomainError.io("device-posture-payload", "The hinge command could not be serialized.")
        }
        return data as Data
    }
}
