import Foundation
import Observation
import XcodeSimulatorHost

protocol DeviceSettingsSource: Sendable {
    func deviceSettings(for device: InventoryDevice) async throws -> SimulatorDeviceSettings
    func setDeviceSetting(_ setting: SimulatorDeviceSetting, for device: InventoryDevice) async throws
    func setDeviceSetting(_ setting: SimulatorDeviceSetting, for device: InventoryDevice,
                          updating settings: SimulatorDeviceSettings) async throws -> SimulatorDeviceSettings
}

extension SimulatorHostController: DeviceSettingsSource {}

@MainActor @Observable
final class DeviceSettingsModel {
    private(set) var device: InventoryDevice?
    private(set) var selectionCount = 0
    private(set) var settings: SimulatorDeviceSettings?
    private(set) var issue: String?
    private(set) var isLoading = false
    @ObservationIgnored private let source: any DeviceSettingsSource
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var refreshRequested = false
    @ObservationIgnored private var readingSuspended = false
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var readIdentifier: UUID?

    init(source: any DeviceSettingsSource) { self.source = source }

    func inspect(_ device: InventoryDevice?, selectionCount: Int) {
        self.selectionCount = selectionCount
        if self.device != device {
            self.device = device
            generation += 1
            settings = nil
            issue = nil
            refreshRequested = true
            readTask?.cancel()
        }
        if device?.canInspectSettings != true { refreshRequested = false }
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

    /// Called by the manager's operation queue, which owns write ordering and quit draining.
    func apply(_ setting: SimulatorDeviceSetting, to destination: InventoryDevice) async throws {
        let wasSuspended = readingSuspended
        readingSuspended = true
        defer { setReadingSuspended(wasSuspended) }
        let interruptedRead = readTask != nil
        readTask?.cancel()
        await finishReading()
        generation += 1
        let request = generation
        do {
            if device == destination, let settings {
                let updated = try await source.setDeviceSetting(setting, for: destination, updating: settings)
                guard generation == request, device == destination else { return }
                self.settings = updated
                if interruptedRead { refreshRequested = true }
                issue = nil
                logIssues(updated)
            } else {
                try await source.setDeviceSetting(setting, for: destination)
                if device == destination { refreshRequested = true }
            }
        } catch {
            if device == destination {
                generation += 1
                refreshRequested = true
            }
            throw error
        }
    }

    private func beginReadingIfNeeded() {
        guard !stopped, !readingSuspended, readTask == nil, refreshRequested,
              device?.canInspectSettings == true else { return }
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
                  self.refreshRequested, let device = self.device, device.canInspectSettings {
                self.refreshRequested = false
                let request = self.generation
                do {
                    let settings = try await self.source.deviceSettings(for: device)
                    guard !self.stopped, !Task.isCancelled, self.generation == request else { continue }
                    self.settings = settings
                    self.issue = nil
                    self.logIssues(settings)
                } catch {
                    guard !self.stopped, !Task.isCancelled, self.generation == request else { continue }
                    self.issue = error.localizedDescription
                    NSLog("NeoSimulator settings: %@", (error as? SimulatorHostFailure)?.technicalDetails ?? String(describing: error))
                }
            }
        }
    }

    private func logIssues(_ settings: SimulatorDeviceSettings) {
        if !settings.issues.isEmpty { NSLog("NeoSimulator settings: %@", settings.issues.joined(separator: "\n")) }
    }
}

extension InventoryDevice {
    var canInspectSettings: Bool {
        switch self {
        case .simulator(let device): device.isAvailable && device.state == "Booted"
        case .remote(let device): device.isAvailable
        }
    }
}
