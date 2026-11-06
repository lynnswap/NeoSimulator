import Foundation
import NeoSimulatorDeviceIO
import NeoSimulatorKit
import Observation

/// DeviceKit's sidebar Active values for the devices that DeviceKit observes in this process.
package struct DeviceActiveStates: Equatable, Sendable {
    private let values: [UUID: Bool]

    /// No values, so every device is unknown.
    package init() { values = [:] }

    package init(_ values: [UUID: Bool]) { self.values = values }

    /// DeviceKit's value for the device, or nil when DeviceKit reports none or the observation did not request it.
    ///
    /// DeviceKit identifies devices by their CoreDevice identifier. Simulators in a custom device set have no
    /// CoreDevice record, so they have no value even when a default-set simulator shares their UDID.
    package func isActive(_ device: InventoryDevice) -> Bool? {
        let identifier = switch device {
        case .simulator(let simulator): simulator.coreDevice?.identifier
        case .remote(let remote): remote.identifier
        }
        return identifier.flatMap(UUID.init(uuidString:)).flatMap { values[$0] }
    }
}

/// Observes DeviceKit sidebar activity for views in this process.
///
/// Evaluating a device can create its coordinator and native HID services, interfering
/// with SimulatorKit touches and buttons. ``init(limitedTo:)`` restricts evaluation to
/// requested native canvases. Other processes and non-DeviceKit views contribute no activity.
/// DeviceKit's observation and coordinators last for the process; ``stop()`` ends only
/// this object's reads and callbacks.
@MainActor
package final class DeviceActiveStateObservation {
    package var onChange: ((DeviceActiveStates) -> Void)?
    package var onError: ((any Error) -> Void)?

    private let source: any DeviceActiveStateSource
    private let deviceIdentifiers: (@MainActor () -> Set<UUID>)?
    private var startTask: Task<Void, Never>?
    private var stopped = false
    private var delivered: DeviceActiveStates?

    /// Observes the value of every device that DeviceKit observes, creating DeviceKit's coordinator for each of them.
    package convenience init() { self.init(source: DeviceKitActiveStateSource()) }

    /// Observes only the devices whose CoreDevice identifiers `deviceIdentifiers` returns; other devices have no value.
    ///
    /// Each read calls `deviceIdentifiers` under Observation, so a change to the observable state that it reads
    /// reports the values of the new set.
    package convenience init(limitedTo deviceIdentifiers: @escaping @MainActor () -> Set<UUID>) {
        self.init(source: DeviceKitActiveStateSource(), limitedTo: deviceIdentifiers)
    }

    package init(source: any DeviceActiveStateSource, limitedTo deviceIdentifiers: (@MainActor () -> Set<UUID>)? = nil) {
        self.source = source
        self.deviceIdentifiers = deviceIdentifiers
    }

    deinit { startTask?.cancel() }

    /// Prepares DeviceKit, then reports the current values and each later change, or a failure through `onError`.
    package func start() {
        guard !stopped, startTask == nil else { return }
        startTask = Task { [weak self, source] in
            do {
                try await source.prepare()
                guard let self, !self.stopped, !Task.isCancelled else { return }
                self.observe()
            } catch {
                guard let self, !self.stopped, !Task.isCancelled else { return }
                self.onError?(error)
            }
        }
    }

    /// Stops reading and waits until no further callbacks can be delivered.
    package func stop() async {
        stopped = true
        startTask?.cancel()
        await startTask?.value
    }

    private func observe() {
        let result = withObservationTracking {
            Result { try source.read(deviceIdentifiers?()) }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                self.observe()
            }
        }
        switch result {
        case .success(let values):
            let states = DeviceActiveStates(values)
            guard states != delivered else { return }
            delivered = states
            onChange?(states)
        case .failure(let error):
            delivered = nil
            onError?(error)
        }
    }
}

