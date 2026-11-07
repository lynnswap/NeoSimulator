import Foundation
import NeoSimulatorDeviceIO

/// Settings of the simulator that owns the selected screen, independent of CoreDevice discovery.
@MainActor
package final class SimulatorGuestSettings {
    private let source: SimulatorHostDevice
    private let xcodeURL: URL
    private var deviceSet: SimulatorDeviceSet?
    private var actionPreparation: (device: SimulatorDevice, task: Task<GuestSettingsActions, any Error>)?

    nonisolated package init(device: SimulatorHostDevice, xcodeURL: URL) {
        source = device
        self.xcodeURL = xcodeURL
    }

    /// The set shares the device's connection with its screen, and a failure stays only with those who were waiting for it.
    private func selectedDevice() async throws -> SimulatorDevice {
        let set: SimulatorDeviceSet
        if let deviceSet { set = deviceSet } else {
            set = try await SimulatorDeviceSet.load(xcodeURL: xcodeURL, path: source.deviceSetPath)
            deviceSet = set
        }
        guard let device = try await set.client(withIdentifier: source.identifier) else {
            throw DeviceDomainError.unavailable("simulator-settings-device", "The selected simulator is no longer available.")
        }
        return device
    }

    private func service(device: SimulatorDevice) async throws -> GuestSettingsActions {
        if let actionPreparation, actionPreparation.device === device { return try await actionPreparation.task.value }
        let preparation = Task { [device] in
            try await GuestSettingsActions(guest: SimulatorGuestHID(lookUp: device.lookUp), identifier: device.identifier)
        }
        actionPreparation = (device, preparation)
        do { return try await preparation.value } catch {
            // The next request prepares them again, which waits behind whatever call this one left on the device's worker.
            if actionPreparation?.task == preparation { actionPreparation = nil }
            throw error
        }
    }

    // dtconfigurationd permits color-filter writes only on iOS/tvOS 27 and later. Older guests still report
    // a readable disabled filter, which must not be presented as a setting the user can change.
    private static let colorFilterMinimumVersion: UInt32 = 27 << 16

    package static func colorFilter(runtimeVersion: UInt32,
                                   read: () async throws -> DeviceInspectorValue?) async throws -> SimulatorDeviceSettings {
        var settings = SimulatorDeviceSettings()
        guard runtimeVersion >= colorFilterMinimumVersion else {
            settings.colorFilterRequiredOSVersion = 27
            return settings
        }
        let filter = try await read()?["colorFilter"]
        if filter?["enabled"]?.boolean == false { settings.colorFilter = SimulatorColorFilter.none }
        else if let name = filter?["filterType"]?["name"]?.string { settings.colorFilter = SimulatorColorFilter(rawValue: name.lowercased()) }
        settings.colorFilterIntensity = filter?["intensity"]?.numeric
        return settings
    }

    /// Reads one group. A value that fails names itself and keeps what is known of it; the rest of the group still applies.
    package func read(_ group: DeviceSettingsGroup) async throws -> DeviceSettingsGroupRead {
        let device = try await selectedDevice()
        var failures: [String] = []
        var changes: [@Sendable (inout SimulatorDeviceSettings) -> Void] = []
        func capture<T: Sendable>(_ name: String, _ read: () async throws -> T,
                                  set: @escaping @Sendable (inout SimulatorDeviceSettings, T) -> Void) async {
            guard !Task.isCancelled else { return }
            do {
                let value = try await read()
                changes.append { set(&$0, value) }
            } catch {
                if !Task.isCancelled { failures.append("\(name): \(error.localizedDescription)") }
            }
        }
        func get(_ declaration: String) async throws -> DeviceInspectorValue? {
            try await service(device: device).getIfSupported(declaration, runtimeVersion: device.runtimeVersion)
        }
        switch group {
        case .textSize:
            await capture("content_size", {
                let category = try await device.contentSizeCategory()
                let sizes = DeviceContentSize.allCases
                guard (1...sizes.count).contains(category) else {
                    throw DeviceDomainError.unavailable("content-size", "The simulator returned an unknown text size: \(category).")
                }
                return sizes[category - 1]
            }, set: { $0.contentSize = $1 })
        case .accessibility:
            await capture("look and feel", {
                try await get("GetDeviceLookAndFeelActionDeclaration")?["lookAndFeel"]?["name"]?.string
            }, set: { $0.lookAndFeel = $1 })
            await capture("supported looks and feels", {
                guard let values = try await get("GetSupportedLooksAndFeelsActionDeclaration")?["looksAndFeels"]?.array,
                      !values.isEmpty else { return [SimulatorLookAndFeel]() }
                var supported: [SimulatorLookAndFeel] = []
                for choice in SimulatorLookAndFeel.allCases {
                    let native = try await service(device: device).namedValue("DeviceLookAndFeel", member: choice.nativeMember)
                    if values.contains(try DeviceInspectorValue.propertyList(native)) { supported.append(choice) }
                }
                return supported
            }, set: { $0.supportedLooksAndFeels = $1 })
            await capture("Liquid Glass", {
                try await get("GetLiquidGlassConfigurationActionDeclaration")?["configuration"]?["opacity"]?.numeric
            }, set: { $0.liquidGlassOpacity = $1 })
            await capture("color filter", {
                try await Self.colorFilter(runtimeVersion: device.runtimeVersion) {
                    try await get("GetColorFilterActionDeclaration")
                }
            }, set: { settings, filter in
                settings.colorFilter = filter.colorFilter
                settings.colorFilterIntensity = filter.colorFilterIntensity
                settings.colorFilterRequiredOSVersion = filter.colorFilterRequiredOSVersion
            })
            await capture("Reduce Motion", {
                try await get("GetReduceMotionActionDeclaration")?["reduceMotion"]?["enabled"]?.boolean
            }, set: { $0.reduceMotion = $1 })
            await capture("Show Borders", {
                try await get("GetShowBordersActionDeclaration")?["showBorders"]?["enabled"]?.boolean
            }, set: { $0.showBorders = $1 })
            await capture("Reduce Transparency", {
                try await get("GetReduceTransparencyActionDeclaration")?["reduceTransparency"]?["enabled"]?.boolean
            }, set: { $0.reduceTransparency = $1 })
        case .voiceOver:
            await capture("VoiceOver", {
                try await get("GetVoiceOverActionDeclaration")?["voiceOverConfiguration"]?["enabled"]?.boolean
            }, set: { $0.voiceOver = $1 })
        case .audio:
            await capture("volume", {
                let volume = try await device.notificationState("com.apple.springboard.volumestate")
                guard volume <= 100 else {
                    throw DeviceDomainError.io("audio-volume", "The simulator returned a volume outside 0...100.")
                }
                return Int(volume)
            }, set: { $0.volume = $1 })
            await capture("audio routes", {
                let audio = try await SimulatorAudioInterface.load()
                let connection = try await audio.connect(to: device, changed: { _ in })
                defer { connection.disconnect() }
                return try await connection.state()
            }, set: { $0.updateAudioRoutes($1) })
        case .appearance, .contrast, .displayZoom, .boldText, .location:
            throw DeviceDomainError.configuration("guest-settings-operation", "This group uses the simulator command-line tools.")
        }
        return .values(group, failures: failures) { [changes] settings in changes.forEach { $0(&settings) } }
    }

    package func set(_ setting: DeviceSettingChange) async throws {
        let device = try await selectedDevice()
        func change(_ declaration: String, _ input: [String: Any]) async throws {
            try await service(device: device).set(declaration, input: input)
        }
        switch setting {
        case .contentSize(let value):
            guard let index = DeviceContentSize.allCases.firstIndex(of: value) else {
                throw DeviceDomainError.configuration("guest-settings-operation", "Unknown text size: \(value).")
            }
            try await device.setContentSizeCategory(index + 1)
        case .lookAndFeel(let value):
            let native = try await service(device: device).namedValue("DeviceLookAndFeel",
                member: value.nativeMember)
            try await change("SetDeviceLookAndFeelActionDeclaration", ["lookAndFeel": native])
        case .liquidGlassOpacity(let value):
            try await change("SetLiquidGlassConfigurationActionDeclaration", ["configuration": ["opacity": value]])
        case .colorFilter(let value, let intensity):
            guard device.runtimeVersion >= Self.colorFilterMinimumVersion else {
                throw DeviceDomainError.unavailable("color-filter-unavailable", "This simulator runtime does not support changing color filters.")
            }
            // The provider rejects intensity for grayscale and disabled filters.
            try await service(device: device).setColorFilter(named: value == .none ? nil : value.rawValue,
                                                             takesIntensity: value != .none && value != .grayscale, intensity: intensity)
        case .reduceMotion(let value):
            try await change("SetReduceMotionActionDeclaration", ["reduceMotion": ["enabled": value]])
        case .showBorders(let value):
            try await change("SetShowBordersActionDeclaration", ["showBorders": ["enabled": value]])
        case .reduceTransparency(let value):
            try await change("SetReduceTransparencyActionDeclaration", ["reduceTransparency": ["enabled": value]])
        case .voiceOver(let value):
            try await change("SetVoiceOverActionDeclaration", ["voiceOverConfiguration": ["enabled": value]])
        case .volume(let value):
            guard (0...100).contains(value) else { throw DeviceDomainError.configuration("guest-settings-operation", "Volume must be between 0 and 100.") }
            try await device.sendNotificationState("com.apple.springboard.volumestate", to: UInt64(value))
        case .audioInputDevice(let value), .audioOutputDevice(let value):
            let audio = try await SimulatorAudioInterface.load()
            let connection = try await audio.connect(to: device, changed: { _ in })
            defer { connection.disconnect() }
            let scope: AudioScope = if case .audioInputDevice = setting { .input } else { .output }
            try await route(through: connection, scope, to: value == "systemDefault" ? AudioRouting.systemDefault : value)
        default: throw DeviceDomainError.configuration("guest-settings-operation", "This setting uses the simulator command-line tools.")
        }
    }

    /// Routes and waits for the port's answer, which may never come or come after the request's own failure.
    private func route(through connection: SimulatorAudioConnection, _ scope: AudioScope, to route: String) async throws {
        let (answer, answered) = AsyncThrowingStream.makeStream(of: Void.self)
        try await connection.route(scope, to: route) { error in answered.finish(throwing: error) }
        let limit = DeviceOperationLimit.bridge
        let deadline = Task {
            try? await Task.sleep(for: limit)
            answered.finish(throwing: DeviceOperationFailure.outcomeUnknown(operation: "route the device's audio", cause: .timedOut(limit)))
        }
        defer { deadline.cancel() }
        for try await _ in answer {}
        if Task.isCancelled {
            throw DeviceOperationFailure.outcomeUnknown(operation: "route the device's audio", cause: .cancelled)
        }
    }
}

private extension SimulatorLookAndFeel {
    var nativeMember: String {
        switch self { case .clear: "clearLiquidGlass"; case .tinted: "tintedLiquidGlass" }
    }
}
