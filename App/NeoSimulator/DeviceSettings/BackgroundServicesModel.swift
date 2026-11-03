import Foundation
import Observation
@_spi(NeoSimulator) import XcodeSimulatorHost

protocol BackgroundServicesSource: Sendable {
    func backgroundServices(for device: InventoryDevice) async throws -> SimulatorBackgroundServices
    func setBackgroundServices(_ targets: [SimulatorBackgroundServiceTarget], enabled: Bool,
                               for device: InventoryDevice) async throws -> SimulatorBackgroundServicesUpdate
}

extension SimulatorHostController: BackgroundServicesSource {}

/// The selected simulator's background services. The simulator's launchd keeps the only record of them,
/// so the model shows what it last read, with accepted changes on top until each one's readback arrives.
@MainActor @Observable
final class BackgroundServicesModel {
    struct Change {
        fileprivate let id = UUID()
        let targets: [SimulatorBackgroundServiceTarget]
        let enabled: Bool
        let destination: InventoryDevice
    }
    /// What the last change to the inspected device left differently from what it asked for.
    struct Outcome: Equatable {
        /// Services kept on because another enabled category or the platform needs them.
        let stillEnabledLabels: [String]
        /// Services enabled again that start at the simulator's next boot.
        let notStartedLabels: [String]
    }
    private(set) var device: InventoryDevice?
    private(set) var services: SimulatorBackgroundServices?
    private(set) var outcome: Outcome?
    private(set) var issue: String?
    private(set) var isLoading = false
    private var pendingChanges: [Change] = []
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

    func isEnabled(_ category: SimulatorBackgroundServiceCategory) -> Bool {
        if let change = latestChange(touching: { $0 == .category(category.id) }) { return change.enabled }
        return services?.state(of: category) == .enabled
    }

    func isEnabled(_ label: String) -> Bool {
        let categories = SimulatorBackgroundServiceCategory.all.filter { $0.services.contains { $0.label == label } }
        if let change = latestChange(touching: { target in
            target == .service(label) || categories.contains { target == .category($0.id) }
        }), change.enabled || services?.canDisable(label) == true {
            return change.enabled
        }
        return services?.isEnabled(label) == true
    }

    func inspect(_ device: InventoryDevice?) {
        if self.device != device {
            if self.device?.id != device?.id {
                generation += 1
                services = nil
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
        let change = Change(targets: targets, enabled: enabled, destination: destination)
        pendingChanges.append(change)
        if device?.id == destination.id { outcome = nil }
        return change
    }

    /// Called by the manager's operation queue, which owns change ordering and quit draining.
    func apply(_ change: Change) async throws {
        let destination = change.destination
        let wasSuspended = readingSuspended
        readingSuspended = true
        defer {
            pendingChanges.removeAll { $0.id == change.id }
            setReadingSuspended(wasSuspended)
        }
        readTask?.cancel()
        await finishReading()
        generation += 1
        let request = generation
        do {
            let update = try await source.setBackgroundServices(change.targets, enabled: change.enabled, for: destination)
            guard generation == request, device?.id == destination.id else { return }
            services = update.services
            issue = nil
            let outcome = Outcome(stillEnabledLabels: update.stillEnabledLabels, notStartedLabels: update.notStartedLabels)
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

    private func latestChange(touching matches: (SimulatorBackgroundServiceTarget) -> Bool) -> Change? {
        pendingChanges.last { $0.destination.id == device?.id && $0.targets.contains(where: matches) }
    }

    private func beginReadingIfNeeded() {
        guard !stopped, !readingSuspended, readTask == nil, refreshRequested,
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
            while !self.stopped, !self.readingSuspended, !Task.isCancelled,
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
    /// launchd can be read only inside a booted simulator; physical devices and VMs keep their services.
    var canInspectBackgroundServices: Bool {
        guard case .simulator(let device) = self else { return false }
        return device.isAvailable && device.state == "Booted"
    }
}
