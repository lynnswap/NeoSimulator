import CoreAudio
import Foundation
import NeoSimulatorDeviceIO

/// Where a registry's device state comes from. Inventory, settings, and services each read independently; only the
/// source knows how a device answers.
package protocol DeviceStateSource: Sendable {
    /// Only cancellation throws: a stopped read observed nothing to publish.
    func inventory() async throws -> DeviceInventorySnapshot
    /// Publishes each group as it finishes and returns when all have, or when cancelled.
    func readSettings(_ groups: Set<DeviceSettingsGroup>, of device: InventoryDevice,
                      publish: @escaping @Sendable (DeviceSettingsGroupRead) async -> Void) async
    func write(_ change: DeviceSettingChange, to device: InventoryDevice) async throws
    func backgroundServices(for device: InventoryDevice) async throws -> SimulatorBackgroundServices
    func setBackgroundServices(_ targets: [SimulatorBackgroundServiceTarget], enabled: Bool,
                               for device: InventoryDevice) async throws -> SimulatorBackgroundServicesUpdate
    /// What runs a device's inspection commands. Making one reads nothing of the device.
    func inspector(for device: InventoryDevice) async throws -> DeviceInspector
    /// Stops the reads running now and refuses new ones until ``resumeReads()``, without stopping any change.
    nonisolated func stopReads()
    nonisolated func resumeReads()
}

/// Reads and changes real devices through CoreSimulator, CoreDevice, and their command-line tools.
package struct LiveDeviceStateSource: DeviceStateSource {
    private let reads: CommandReads
    private let readInventory: @Sendable () async throws -> DeviceInventorySnapshot
    private let xcodeURL: @Sendable (InventoryDevice) async throws -> URL?

    /// `readInventory` and `xcodeURL` default to discovery of what is installed; a host that knows more can overlay them.
    package init(reads: CommandReads = CommandReads(),
                 readInventory: (@Sendable () async throws -> DeviceInventorySnapshot)? = nil,
                 xcodeURL: (@Sendable (InventoryDevice) async throws -> URL?)? = nil) {
        self.reads = reads
        self.readInventory = readInventory ?? { try await LiveDeviceInventory.read(using: reads) }
        self.xcodeURL = xcodeURL ?? { device in
            guard case .simulator(let simulator) = device else { return nil }
            return try await LiveDeviceInventory.xcodeURL(for: simulator, preferring: simulator.ownerXcodeURL ?? simulator.catalogXcodeURL, using: reads)
        }
    }

    package func inventory() async throws -> DeviceInventorySnapshot { try await readInventory() }
    package nonisolated func stopReads() { reads.stop() }
    package nonisolated func resumeReads() { reads.resume() }

    package func readSettings(_ groups: Set<DeviceSettingsGroup>, of device: InventoryDevice,
                              publish: @escaping @Sendable (DeviceSettingsGroupRead) async -> Void) async {
        let url: URL?
        do { url = try await xcodeURL(device) }
        catch {
            guard !Task.isCancelled else { return }
            for group in groups { await publish(.failed(group, error.localizedDescription)) }
            return
        }
        await Self.backend(device: device, xcodeURL: url).read(groups, of: device) { read in
            guard read.group == .location else { return await publish(read) }
            await publish(read.addingSavedLocation(of: device))
        }
    }

    /// A channel's own failure says whether the change was sent; it stays typed so that the model can be honest about it.
    package func write(_ change: DeviceSettingChange, to device: InventoryDevice) async throws {
        do {
            let url = try await xcodeURL(device)
            try await Self.backend(device: device, xcodeURL: url).set(change, device: device)
            try Self.remember(change, for: device)
        } catch let error as DeviceOperationFailure { throw error }
        catch is CancellationError { throw CancellationError() }
        catch let error as SimulatorHostFailure { throw error }
        catch { throw SimulatorHostFailure(error) }
    }

    package func backgroundServices(for device: InventoryDevice) async throws -> SimulatorBackgroundServices {
        do { return try await serviceBackend(for: device).read() }
        catch is CancellationError { throw CancellationError() }
        catch let error as SimulatorHostFailure { throw error }
        catch { throw SimulatorHostFailure(error) }
    }

    /// Enables or disables services in a booted simulator without rebooting it.
    /// The disable overrides persist, so the change also applies to later boots. Once launchctl may have run,
    /// a failure is a `SimulatorBackgroundServicesUpdateFailure` with the state read after the attempt.
    package func setBackgroundServices(_ targets: [SimulatorBackgroundServiceTarget], enabled: Bool,
                                       for device: InventoryDevice) async throws -> SimulatorBackgroundServicesUpdate {
        let backend: SimulatorBackgroundServiceBackend
        do { backend = try await serviceBackend(for: device) }
        catch is CancellationError { throw CancellationError() }
        catch let error as SimulatorHostFailure { throw error }
        catch { throw SimulatorHostFailure(error) }
        return try await backend.update(targets, enabled: enabled)
    }

    package func inspector(for device: InventoryDevice) async throws -> DeviceInspector {
        DeviceInspector(device: device, simulatorXcodeURL: try await xcodeURL(device))
    }

    private func serviceBackend(for device: InventoryDevice) async throws -> SimulatorBackgroundServiceBackend {
        guard case .simulator(let simulator) = device, simulator.state == "Booted" else {
            throw DeviceDomainError.unavailable("background-services-unavailable",
                                       "Background services are available only on a booted simulator.")
        }
        guard let url = try await xcodeURL(device) else {
            throw DeviceDomainError.configuration("background-services-source", "simctl requires the simulator's developer tools.")
        }
        return .live(device: simulator, xcodeURL: url)
    }

    private static func settingsArguments(_ tool: SimulatorSettingsBackend.Tool, _ arguments: [String]) throws -> [String] {
        guard tool == .guestSettings else { return arguments }
        guard let helper = Bundle.main.url(forResource: "NeoSimulatorGuestSettings", withExtension: nil),
              FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw DeviceDomainError.unavailable("guest-settings-helper", "The app's guest settings helper is unavailable.")
        }
        return ["spawn", arguments[0], helper.path] + arguments.dropFirst()
    }

    private static func backend(device: InventoryDevice, xcodeURL: URL?) -> SimulatorSettingsBackend {
        let guest: SimulatorGuestSettings?
        if case .simulator(let simulator) = device, let xcodeURL {
            guest = SimulatorGuestSettings(device: simulator, xcodeURL: xcodeURL)
        } else { guest = nil }
        return SimulatorSettingsBackend(run: { tool, arguments in
            let result: CommandOutput
            if tool != .devicectl {
                guard case .simulator(let simulator) = device, let xcodeURL else {
                    throw DeviceDomainError.configuration("device-setting-source", "simctl requires a simulator destination and its developer tools.")
                }
                result = try await SystemCommandRunner().run(.simctl(
                    xcodeURL: xcodeURL, arguments: try settingsArguments(tool, arguments), deviceSetPath: simulator.deviceSetPath, policy: .cancellable))
            } else {
                result = try await SystemCommandRunner().run(.devicectl(xcodeURL: xcodeURL, arguments: arguments, policy: .cancellable))
            }
            guard result.terminationStatus == 0 || (tool == .guestSettings && !result.stdout.isEmpty) else {
                throw DeviceDomainError.io("device-setting", result.stderrText.isEmpty ? result.stdoutText : result.stderrText)
            }
            return result.stdout
        }, readGuest: { group in
            guard let guest else { throw SimulatorSettingsBackend.noGuest }
            return try await guest.read(group)
        }, writeGuest: { change in
            guard let guest else { throw SimulatorSettingsBackend.noGuest }
            try await guest.set(change)
        }, audioDevices: SimulatorSettingsBackend.hostAudioDevices)
    }

    private static func remember(_ setting: DeviceSettingChange, for device: InventoryDevice) throws {
        let identifier = device.settingsPreferenceIdentifier
        let audioRoute: (scope: String, route: String)?
        switch setting {
        case .audioInputDevice(let route): audioRoute = ("input", route)
        case .audioOutputDevice(let route): audioRoute = ("output", route)
        default: audioRoute = nil
        }
        if case .simulator = device, let audioRoute {
            guard let defaults = HostPreferences.deviceSettingsDefaults else {
                throw DeviceDomainError.io("device-audio-save", "The audio route was applied, but could not be saved for the next connection.")
            }
            defaults.set(audioRoute.route, forKey: "DeviceAudioRoute.\(identifier).\(audioRoute.scope)")
            guard defaults.synchronize() else {
                throw DeviceDomainError.io("device-audio-save", "The audio route was applied, but could not be saved for the next connection.")
            }
        }
        let preset: [String: Any]?
        switch setting {
        case .location(let latitude, let longitude): preset = ["mode": "custom", "latitude": latitude, "longitude": longitude]
        case .locationScenario(let name): preset = ["mode": "scenario", "scenario": name]
        case .clearLocation: preset = ["mode": "none"]
        default: preset = nil
        }
        if let preset {
            guard let defaults = HostPreferences.deviceSettingsDefaults else {
                throw DeviceDomainError.io("device-location-save", "The location was applied, but its saved selection could not be updated.")
            }
            defaults.set(preset, forKey: "DeviceLocationPreset.\(identifier)")
            guard defaults.synchronize() else {
                throw DeviceDomainError.io("device-location-save", "The location was applied, but its saved selection could not be updated.")
            }
            if case .simulator(let simulator) = device {
                DistributedNotificationCenter.default().postNotificationName(
                    Notification.Name("dev.lynnswap.NeoSimulator.DeviceLocationChanged"),
                    object: simulator.identifier,
                    userInfo: simulator.deviceSetPath.map { ["deviceSetPath": $0] }, deliverImmediately: true)
            }
        }
    }
}

private extension DeviceSettingsGroupRead {
    /// The device reports no location it was given, so what was last chosen for it comes from the saved selection.
    func addingSavedLocation(of device: InventoryDevice) -> Self {
        guard case .values = outcome else { return self }
        var read = self
        let apply = self.apply
        guard let defaults = HostPreferences.deviceSettingsDefaults else {
            read.failures.append("saved location: The saved desired location is unavailable.")
            return read
        }
        guard defaults.synchronize() else {
            read.failures.append("saved location: Could not read the saved desired location.")
            return read
        }
        let record = defaults.dictionary(forKey: "DeviceLocationPreset.\(device.settingsPreferenceIdentifier)")
        let mode = (record?["mode"] as? String).flatMap(DeviceLocationMode.init(rawValue:))
        let scenario = mode == .scenario ? record?["scenario"] as? String : nil
        read.apply = { settings in
            apply(&settings)
            // With no saved choice, what a session restored from the app-wide choice remains what is known.
            guard let mode else { return }
            settings.locationMode = mode
            settings.locationScenario = scenario
        }
        return read
    }
}
