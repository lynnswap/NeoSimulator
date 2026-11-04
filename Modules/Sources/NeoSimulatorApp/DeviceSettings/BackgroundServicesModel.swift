import NeoSimulatorKit
import NeoSimulatorHostSupport
@_spi(NeoSimulator) import XcodeSimulatorHost
import Foundation
import Observation

protocol BackgroundServicesSource: Sendable {
    func backgroundServices(for device: InventoryDevice) async throws -> SimulatorBackgroundServices
    func setBackgroundServices(_ targets: [SimulatorBackgroundServiceTarget], enabled: Bool,
                               for device: InventoryDevice) async throws -> SimulatorBackgroundServicesUpdate
}

extension SimulatorHostController: BackgroundServicesSource {}

/// The selected simulator's observed launchd state, with accepted changes until their readback arrives.
@MainActor @Observable
final class BackgroundServicesModel {
    struct Change {
        enum Operation {
            case services([SimulatorBackgroundServiceTarget], enabled: Bool)
            case configuration(ServiceConfiguration)
        }
        fileprivate let id = UUID()
        let operation: Operation
        let destination: InventoryDevice
    }
    /// What the last change to the inspected device left differently from what it asked for.
    struct Outcome: Equatable {
        /// Services kept on because another enabled category or the platform needs them.
        let stillEnabledLabels: [String]
        /// Services enabled again that start at the simulator's next boot.
        let notStartedLabels: [String]
    }
    private(set) var device: InventoryDevice? { didSet { updateServiceState() } }
    private(set) var selectionCount = 0
    /// Whether the Background Services page shows; launchd is read only while it does.
    private(set) var isVisible = false
    private(set) var services: SimulatorBackgroundServices? {
        didSet {
            if let services {
                pendingRestartLabels.subtract(services.disabledLabels.union(services.loadedLabels))
            }
            updateServiceState()
        }
    }
    private(set) var pendingRestartLabels: Set<String> = []
    private(set) var serviceState: SimulatorBackgroundServices?
    private(set) var outcome: Outcome?
    private(set) var issue: String?
    private(set) var isLoading = false
    private var pendingChanges: [Change] = [] { didSet { updateServiceState() } }
    /// Devices with an accepted change that has not finished.
    var changingDeviceIDs: Set<DeviceInventoryID> { Set(pendingChanges.map(\.destination.id)) }
    var isChanging: Bool { device.map { changingDeviceIDs.contains($0.id) } == true }
    @ObservationIgnored private let source: any BackgroundServicesSource
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var refreshRequested = false
    @ObservationIgnored private var readingSuspended = false
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var readIdentifier: UUID?

    init(source: any BackgroundServicesSource) { self.source = source }

    var configuration: ServiceConfiguration? {
        serviceState.map { ServiceConfiguration(disabledLabels: $0.disabledLabels.intersection(ServiceConfiguration.labels)) }
    }

    func isEnabled(_ category: SimulatorBackgroundServiceCategory) -> Bool {
        category.services.allSatisfy { isEnabled($0.label) }
    }

    func isEnabled(_ label: String) -> Bool { serviceState?.isEnabled(label) == true }

    private func updateServiceState() {
        guard let services, let device else { serviceState = nil; return }
        var configuration = ServiceConfiguration(disabledLabels: services.disabledLabels)
        for change in pendingChanges where change.destination.id == device.id {
            switch change.operation {
            case .configuration(let pending):
                configuration = ServiceConfiguration(disabledLabels: pending.disabledLabels.subtracting(services.platformRequiredLabels))
            case .services(let targets, let enabled):
                configuration.set(targets, enabled: enabled, productFamily: device.serviceProductFamily)
            }
        }
        serviceState = SimulatorBackgroundServices(disabled: configuration.disabledLabels,
            loaded: services.loadedLabels, productFamily: device.serviceProductFamily)
    }

    func inspect(_ device: InventoryDevice?, selectionCount: Int) {
        self.selectionCount = selectionCount
        if self.device != device {
            if self.device?.id != device?.id {
                generation += 1
                services = nil
                pendingRestartLabels.removeAll()
                outcome = nil
                issue = nil
                readTask?.cancel()
            }
            self.device = device
            refreshRequested = true
        }
        if device?.canInspectBackgroundServices != true {
            refreshRequested = false
            outcome = nil
        }
        beginReadingIfNeeded()
    }

    /// Each showing reads the device again, since launchd can change outside NeoSimulator.
    func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
        if visible { requestRefresh() }
    }

    func requestRefresh() {
        guard !stopped else { return }
        refreshRequested = true
        beginReadingIfNeeded()
    }

    func setReadingSuspended(_ suspended: Bool) {
        readingSuspended = suspended
        if !suspended { beginReadingIfNeeded() }
    }

    func stopReading() {
        stopped = true
        readTask?.cancel()
    }

    func resumeReading() {
        stopped = false
        requestRefresh()
    }

    func finishReading() async {
        while let readTask { await readTask.value }
    }

    func accept(_ targets: [SimulatorBackgroundServiceTarget], enabled: Bool, for destination: InventoryDevice) -> Change {
        let change = Change(operation: .services(targets, enabled: enabled), destination: destination)
        pendingChanges.append(change)
        if device?.id == destination.id { outcome = nil }
        return change
    }

    func accept(_ configuration: ServiceConfiguration, for destination: InventoryDevice) -> Change {
        let change = Change(operation: .configuration(configuration), destination: destination)
        pendingChanges.append(change)
        if device?.id == destination.id { outcome = nil }
        return change
    }

    func discard(_ change: Change) {
        pendingChanges.removeAll { $0.id == change.id }
    }

    /// Called by the manager's operation queue, which owns change ordering and quit draining.
    func apply(_ change: Change) async throws {
        let destination = change.destination
        let wasSuspended = readingSuspended
        readingSuspended = true
        defer {
            discard(change)
            setReadingSuspended(wasSuspended)
        }
        readTask?.cancel()
        await finishReading()
        generation += 1
        let request = generation
        do {
            let (updated, outcome) = try await apply(change.operation, to: destination)
            guard generation == request, device?.id == destination.id else { return }
            pendingRestartLabels.formUnion(outcome.notStartedLabels)
            services = updated
            issue = nil
            self.outcome = outcome.stillEnabledLabels.isEmpty && outcome.notStartedLabels.isEmpty ? nil : outcome
        } catch {
            var failure: any Error = error
            var readBack: SimulatorBackgroundServices?
            if let update = error as? SimulatorBackgroundServicesUpdateFailure {
                readBack = update.services
                failure = update.underlyingError
            }
            if device?.id == destination.id {
                if generation == request, let readBack {
                    services = readBack
                    issue = nil
                } else { refreshRequested = true }
            }
            throw failure
        }
    }

    private func apply(_ operation: Change.Operation, to destination: InventoryDevice) async throws -> (SimulatorBackgroundServices, Outcome) {
        switch operation {
        case .services(let targets, let enabled):
            let update = try await source.setBackgroundServices(targets, enabled: enabled, for: destination)
            return (update.services, Outcome(stillEnabledLabels: update.stillEnabledLabels, notStartedLabels: update.notStartedLabels))
        case .configuration(let configuration):
            var current = try await source.backgroundServices(for: destination)
            let labels = ServiceConfiguration.labels
            let disabled = configuration.disabledLabels.intersection(labels).filter { current.canDisable($0) }
            let enabling = current.disabledLabels.intersection(labels).subtracting(disabled)
            let disabling = disabled.subtracting(current.disabledLabels).union(disabled.intersection(current.loadedLabels))
            var notStarted: [String] = []
            if !enabling.isEmpty {
                let update = try await source.setBackgroundServices(enabling.sorted().map { .service($0) }, enabled: true, for: destination)
                current = update.services
                notStarted = update.notStartedLabels
            }
            if !disabling.isEmpty {
                let update = try await source.setBackgroundServices(disabling.sorted().map { .service($0) }, enabled: false, for: destination)
                current = update.services
            }
            return (current, Outcome(stillEnabledLabels: [], notStartedLabels: notStarted))
        }
    }

    private func beginReadingIfNeeded() {
        guard !stopped, isVisible, !readingSuspended, readTask == nil, refreshRequested,
              device?.canInspectBackgroundServices == true else { return }
        let identifier = UUID()
        readIdentifier = identifier
        isLoading = true
        readTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.readIdentifier == identifier {
                    self.readTask = nil
                    self.readIdentifier = nil
                    self.isLoading = false
                    self.beginReadingIfNeeded()
                }
            }
            while !self.stopped, self.isVisible, !self.readingSuspended, !Task.isCancelled,
                  self.refreshRequested, let device = self.device, device.canInspectBackgroundServices {
                self.refreshRequested = false
                let request = self.generation
                do {
                    let services = try await self.source.backgroundServices(for: device)
                    guard !self.stopped, !Task.isCancelled, self.generation == request else { continue }
                    self.services = services
                    self.issue = nil
                } catch {
                    guard !self.stopped, !Task.isCancelled, self.generation == request else { continue }
                    self.issue = error.localizedDescription
                    NSLog("NeoSimulator background services: %@",
                          (error as? SimulatorHostFailure)?.technicalDetails ?? String(describing: error))
                }
            }
        }
    }
}

extension InventoryDevice {
    var serviceProductFamily: String {
        if case .simulator(let device) = self { return device.productFamily }
        return ""
    }

    /// launchd can be read only inside a booted simulator; physical devices and VMs keep their services.
    var canInspectBackgroundServices: Bool {
        guard case .simulator(let device) = self else { return false }
        return device.isAvailable && device.state == "Booted"
    }
}
