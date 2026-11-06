import Foundation
import NeoSimulatorDeviceIO
import Observation

/// A simulator's observed launchd state, with accepted changes shown until their read-back arrives.
@MainActor @Observable
public final class BackgroundServicesState {
    /// What the last change left differently from what it asked for.
    public struct Outcome: Equatable, Sendable {
        /// Services kept on because another enabled category or the platform needs them.
        public let stillEnabledLabels: [String]
        /// Services enabled again that start at the simulator's next boot.
        public let notStartedLabels: [String]

        package init(stillEnabledLabels: [String], notStartedLabels: [String]) {
            self.stillEnabledLabels = stillEnabledLabels
            self.notStartedLabels = notStartedLabels
        }
    }

    package enum Change {
        case services([SimulatorBackgroundServiceTarget], enabled: Bool)
        case configuration(ServiceConfiguration)
    }

    private struct PendingChange {
        let id = UUID()
        let change: Change
    }

    /// The services as last observed, with what has been accepted since.
    public private(set) var services: SimulatorBackgroundServices?
    public private(set) var pendingRestartLabels: Set<String> = []
    public private(set) var outcome: Outcome?
    /// What the last read answered. Values that remain after a failure are from the read before.
    public private(set) var status = DeviceReadStatus.unread
    public private(set) var isReading = false
    /// Whether an accepted change has not finished.
    public private(set) var isChanging = false

    @ObservationIgnored package weak var owner: DeviceModel?
    @ObservationIgnored private var confirmed: SimulatorBackgroundServices?
    @ObservationIgnored private var pending: [PendingChange] = []
    @ObservationIgnored private var dirty = true
    @ObservationIgnored private var serial = 0
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var readIdentifier: UUID?

    package init() {}

    public var configuration: ServiceConfiguration? {
        services.map { ServiceConfiguration(disabledLabels: $0.disabledLabels.intersection(ServiceConfiguration.labels)) }
    }

    public func isEnabled(_ category: SimulatorBackgroundServiceCategory) -> Bool {
        category.services.allSatisfy { isEnabled($0.label) }
    }

    public func isEnabled(_ label: String) -> Bool { services?.isEnabled(label) == true }

    /// Enables or disables `targets` in the running simulator, and returns when launchd has been changed and read back.
    public func set(_ targets: [SimulatorBackgroundServiceTarget], enabled: Bool) async throws {
        let write = try accept(.services(targets, enabled: enabled))
        try await withTaskCancellationHandler { try await write.task.value } onCancel: { write.task.cancel() }
    }

    /// Makes the services that a configuration covers match it.
    public func apply(_ configuration: ServiceConfiguration) async throws {
        let write = try accept(.configuration(configuration))
        try await withTaskCancellationHandler { try await write.task.value } onCancel: { write.task.cancel() }
    }

    /// `prepare` runs at the change's turn, and throwing from it stops the change with nothing sent.
    package func accept(_ change: Change, after hold: Task<Void, Never>? = nil,
                        prepare: (@MainActor () throws -> Void)? = nil) throws -> DeviceWrite {
        guard let owner else { throw CancellationError() }
        try owner.checkAcceptsChanges()
        let edit = PendingChange(change: change)
        pending.append(edit)
        serial += 1
        outcome = nil
        updateServices()
        return owner.enqueueWrite(after: hold) { [weak self] in
            guard let self else { throw CancellationError() }
            try prepare?()
            try await self.run(change)
        } settle: { [weak self] result in
            self?.settle(edit, result)
        }
    }

    private func settle(_ edit: PendingChange, _ result: DeviceWriteResult) {
        pending.removeAll { $0.id == edit.id }
        switch result {
        case .applied: break
        case .notStarted, .failed: dirty = true
        }
        updateServices()
        scheduleReads()
    }

    private func run(_ change: Change) async throws {
        guard let owner else { throw CancellationError() }
        let device = owner.inventory
        do {
            let (updated, outcome) = try await perform(change, on: device, source: owner.source)
            pendingRestartLabels.formUnion(outcome.notStartedLabels)
            confirm(updated)
            self.outcome = outcome.stillEnabledLabels.isEmpty && outcome.notStartedLabels.isEmpty ? nil : outcome
        } catch let failure as SimulatorBackgroundServicesUpdateFailure {
            if let readBack = failure.services { confirm(readBack) }
            throw failure.underlyingError
        }
    }

    private func perform(_ change: Change, on device: InventoryDevice, source: any DeviceStateSource) async throws
        -> (SimulatorBackgroundServices, Outcome) {
        switch change {
        case .services(let targets, let enabled):
            let update = try await source.setBackgroundServices(targets, enabled: enabled, for: device)
            return (update.services, Outcome(stillEnabledLabels: update.stillEnabledLabels, notStartedLabels: update.notStartedLabels))
        case .configuration(let configuration):
            var current = try await source.backgroundServices(for: device)
            let labels = ServiceConfiguration.labels
            let disabled = configuration.disabledLabels.intersection(labels).filter { current.canDisable($0) }
            let enabling = current.disabledLabels.intersection(labels).subtracting(disabled)
            let disabling = disabled.subtracting(current.disabledLabels).union(disabled.intersection(current.loadedLabels))
            var notStarted: [String] = []
            if !enabling.isEmpty {
                let update = try await source.setBackgroundServices(enabling.sorted().map { .service($0) }, enabled: true, for: device)
                current = update.services
                notStarted = update.notStartedLabels
            }
            if !disabling.isEmpty {
                let update = try await source.setBackgroundServices(disabling.sorted().map { .service($0) }, enabled: false, for: device)
                current = update.services
            }
            return (current, Outcome(stillEnabledLabels: [], notStartedLabels: notStarted))
        }
    }

    // MARK: Reading

    package func markDirty() { dirty = true }

    /// A later read follows any read that is running, and a device with an accepted change reads after its outcome.
    package func scheduleReads() {
        guard let owner, !owner.readsStopped, dirty, readTask == nil, pending.isEmpty, owner.wants(.backgroundServices),
              owner.inventory.canInspectBackgroundServices else { return }
        dirty = false
        isReading = true
        let identifier = UUID()
        readIdentifier = identifier
        let epoch = owner.epoch
        let request = serial
        let source = owner.source
        let device = owner.inventory
        readTask = Task { [weak self] in
            let result: Result<SimulatorBackgroundServices, any Error>
            do { result = .success(try await source.backgroundServices(for: device)) }
            catch { result = .failure(error) }
            self?.receive(result, epoch: epoch, serial: request, identifier: identifier)
        }
    }

    private func receive(_ result: Result<SimulatorBackgroundServices, any Error>, epoch: Int, serial request: Int, identifier: UUID) {
        guard readIdentifier == identifier else { return }
        readTask = nil
        readIdentifier = nil
        isReading = false
        defer { scheduleReads() }
        guard let owner, epoch == owner.epoch, !owner.readsStopped else {
            dirty = true
            return
        }
        guard request == serial else {
            dirty = true
            return
        }
        switch result {
        case .success(let services): confirm(services)
        case .failure(let error):
            if error is CancellationError {
                dirty = true
                return
            }
            NSLog("NeoSimulator background services: %@", (error as? SimulatorHostFailure)?.technicalDetails ?? String(describing: error))
            setStatus(.stale(error.localizedDescription))
        }
    }

    private func confirm(_ services: SimulatorBackgroundServices) {
        pendingRestartLabels.subtract(services.disabledLabels.union(services.loadedLabels))
        confirmed = services
        setStatus(.current)
        updateServices()
    }

    package func discardRunningRead() {
        cancelRead()
        readTask = nil
        readIdentifier = nil
        if isReading { isReading = false }
        dirty = true
    }

    package func cancelRead() { readTask?.cancel() }

    package func finishReading() async {
        while let readTask { await readTask.value }
    }

    /// The device's inventory record changed, which can stop launchd answering for it.
    package func deviceChanged() {
        if owner?.inventory.canInspectBackgroundServices != true, outcome != nil { outcome = nil }
        updateServices()
    }

    private func setStatus(_ status: DeviceReadStatus) {
        if self.status != status { self.status = status }
    }

    private func updateServices() {
        let changing = !pending.isEmpty
        if isChanging != changing { isChanging = changing }
        guard let confirmed, let owner else {
            if services != nil { services = nil }
            return
        }
        let family = owner.inventory.serviceProductFamily
        var configuration = ServiceConfiguration(disabledLabels: confirmed.disabledLabels)
        for edit in pending {
            switch edit.change {
            case .configuration(let pending):
                configuration = ServiceConfiguration(disabledLabels: pending.disabledLabels.subtracting(confirmed.platformRequiredLabels))
            case .services(let targets, let enabled):
                configuration.set(targets, enabled: enabled, productFamily: family)
            }
        }
        let updated = SimulatorBackgroundServices(disabled: configuration.disabledLabels, loaded: confirmed.loadedLabels, productFamily: family)
        if services != updated { services = updated }
    }
}
