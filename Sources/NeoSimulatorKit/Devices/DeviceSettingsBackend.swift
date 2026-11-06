import CoreAudio
import Foundation
import NeoSimulatorDeviceIO

extension InventoryDevice {
    var settingsIdentifier: String {
        switch self {
        case .simulator(let device): device.identifier
        case .remote(let device): device.identifier
        }
    }

    var settingsPreferenceIdentifier: String {
        switch self {
        case .simulator(let device): SimulatorDeviceIdentifier(device.identifier, deviceSetPath: device.deviceSetPath).preferenceIdentifier
        case .remote(let device): "coredevice:\(device.identifier)"
        }
    }

    var settingsAvailable: Bool {
        switch self {
        case .simulator(let device): device.state == "Booted"
        case .remote(let device): device.isAvailable
        }
    }

    func supportsSettingsFeature(_ feature: String) -> Bool {
        switch self {
        case .simulator: true
        case .remote(let device): device.capabilities.contains("com.apple.coredevice.feature." + feature)
        }
    }

    var supportsAppearanceSettings: Bool {
        supportsSettingsFeature("customizeuistyle") || supportsSettingsFeature("customizeappearancesettings") || supportsSettingsFeature("customizeliquidglass")
    }

    var supportsIOSDisplaySettings: Bool {
        guard case .simulator(let device) = self else { return false }
        return ["iPhone", "iPad"].contains(device.productFamily)
    }

    func checkSettingsWrite(_ setting: DeviceSettingChange) throws {
        if case .boldText = setting, !supportsIOSDisplaySettings {
            throw DeviceDomainError.unavailable("bold-text-unavailable", "Bold Text is available only for iOS simulators.")
        }
        if case .displayZoom = setting, !supportsIOSDisplaySettings {
            throw DeviceDomainError.unavailable("display-zoom-unavailable", "Display Zoom is available only for iOS simulators.")
        }
        if case .simulator = self { return }
        guard settingsAvailable else {
            throw DeviceDomainError.unavailable("device-setting-unavailable", "The selected device is not currently available.")
        }
        let feature: String? = switch setting {
        case .appearance: "customizeuistyle"
        case .boldText, .displayZoom: nil
        case .liquidGlassOpacity: "customizeliquidglass"
        case .contentSize, .increaseContrast, .lookAndFeel, .colorFilter, .reduceMotion, .showBorders, .reduceTransparency: "customizeappearancesettings"
        case .voiceOver: "voiceover"
        case .volume, .audioOutputDevice: "audiooutput"
        case .audioInputDevice: "audioinput"
        case .location, .locationScenario, .clearLocation: "simulatelocation"
        }
        guard let feature, supportsSettingsFeature(feature) else {
            throw DeviceDomainError.unavailable("device-setting-capability", "The selected device does not currently expose this setting.")
        }
    }
}

/// Keeps the command and guest transports replaceable while tests exercise the same partial-result and write paths.
package struct SimulatorSettingsBackend: Sendable {
    package enum Tool { case simctl, devicectl, guestSettings }
    package var run: @Sendable (Tool, [String]) async throws -> Data
    package var readCommand: @Sendable (Tool, [String]) async throws -> Data
    /// Reads what the simulator's own services answer, as ``SimulatorGuestSettings`` does.
    package var readGuest: @Sendable (DeviceSettingsGroup) async throws -> DeviceSettingsGroupRead
    package var writeGuest: @Sendable (DeviceSettingChange) async throws -> Void
    package var audioDevices: @Sendable () throws -> (input: [SimulatorAudioDevice], output: [SimulatorAudioDevice])

    package init(run: @escaping @Sendable (Tool, [String]) async throws -> Data,
         readCommand: (@Sendable (Tool, [String]) async throws -> Data)? = nil,
         readGuest: @escaping @Sendable (DeviceSettingsGroup) async throws -> DeviceSettingsGroupRead = { _ in throw Self.noGuest },
         writeGuest: @escaping @Sendable (DeviceSettingChange) async throws -> Void = { _ in throw Self.noGuest },
         audioDevices: @escaping @Sendable () throws -> (input: [SimulatorAudioDevice], output: [SimulatorAudioDevice])) {
        self.run = run
        self.readCommand = readCommand ?? { try await run($0, $1) }
        self.readGuest = readGuest
        self.writeGuest = writeGuest
        self.audioDevices = audioDevices
    }

    package static var noGuest: DeviceDomainError {
        DeviceDomainError.configuration("device-setting-source", "Guest settings require a simulator and its developer tools.")
    }

    /// Reads each group independently and publishes it as it finishes, so that one slow or failed read holds nothing else.
    /// A cancelled read publishes nothing. CoreDevice answers the appearance groups of a remote device with one query.
    package func read(_ groups: Set<DeviceSettingsGroup>, of device: InventoryDevice,
                      publish: @escaping @Sendable (DeviceSettingsGroupRead) async -> Void) async {
        guard device.settingsAvailable else {
            for group in groups { await publish(.failed(group, "The device is not currently available.")) }
            return
        }
        let shared = groups.isDisjoint(with: [.appearance, .textSize, .contrast, .accessibility])
            ? nil : remoteAppearance(of: device)
        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { tasks in
                for group in groups {
                    tasks.addTask {
                        let read = await result(of: group, device: device, remoteAppearance: shared)
                        if !Task.isCancelled { await publish(read) }
                    }
                }
            }
        } onCancel: { shared?.cancel() }
    }

    private func remoteAppearance(of device: InventoryDevice) -> Task<Appearance, any Error>? {
        guard case .remote = device, device.supportsAppearanceSettings else { return nil }
        let identifier = device.settingsIdentifier
        return Task { try await query(Appearance.self, ["device", "info", "appearance"], identifier) }
    }

    private func result(of group: DeviceSettingsGroup, device: InventoryDevice,
                        remoteAppearance: Task<Appearance, any Error>?) async -> DeviceSettingsGroupRead {
        func values(_ name: String, _ read: () async throws -> @Sendable (inout SimulatorDeviceSettings) -> Void) async -> DeviceSettingsGroupRead {
            do { return .values(group, apply: try await read()) }
            catch { return .failed(group, "\(name): \(error.localizedDescription)") }
        }
        let identifier = device.settingsIdentifier
        func ui(_ name: String) async throws -> String {
            String(decoding: try await readCommand(.simctl, ["ui", identifier, name]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func guest(_ name: String) async -> DeviceSettingsGroupRead {
            do { return try await readGuest(group) }
            catch { return .failed(group, "\(name): \(error.localizedDescription)") }
        }
        /// One value of the query that a remote device answers its appearance settings with.
        func remote(_ name: String, feature: String, _ apply: @escaping @Sendable (inout SimulatorDeviceSettings, Appearance) -> Void) async -> DeviceSettingsGroupRead {
            guard let remoteAppearance, device.supportsSettingsFeature(feature) else { return .unsupported(group) }
            return await values(name) {
                let appearance = try await remoteAppearance.value
                return { apply(&$0, appearance) }
            }
        }
        let simulated = if case .simulator = device { true } else { false }
        switch group {
        case .appearance:
            guard simulated else {
                return await remote("appearance settings", feature: "customizeuistyle") { settings, appearance in
                    settings.appearance = appearance.userInterfaceStyle.flatMap(DeviceAppearance.init(rawValue:))
                }
            }
            return await values("appearance") {
                let value = try await ui("appearance")
                return { $0.appearance = DeviceAppearance(rawValue: value) }
            }
        case .textSize:
            guard simulated else {
                return await remote("appearance settings", feature: "customizeappearancesettings") { settings, appearance in
                    settings.contentSize = appearance.textSize.flatMap(Self.contentSize)
                }
            }
            return await guest("content_size")
        case .contrast:
            guard simulated else {
                return await remote("appearance settings", feature: "customizeappearancesettings") { settings, appearance in
                    settings.increaseContrast = appearance.increaseContrast
                }
            }
            return await values("increase_contrast") {
                let contrast = try await ui("increase_contrast")
                return { $0.increaseContrast = contrast == "enabled" ? true : contrast == "disabled" ? false : nil }
            }
        case .displayZoom:
            guard device.supportsIOSDisplaySettings else { return .unsupported(group) }
            return await values("Display Zoom") {
                let zoom = try Self.displayZoomResult(await readCommand(.guestSettings, [identifier, "display-zoom", "read"]))
                return {
                    $0.displayZoom = zoom.current
                    $0.supportedDisplayZoomModes = zoom.modes
                }
            }
        case .boldText:
            guard device.supportsIOSDisplaySettings else { return .unsupported(group) }
            return await values("Bold Text") {
                let data = try await readCommand(.simctl, ["spawn", identifier, "defaults", "export", Self.boldTextDomain, "-"])
                let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
                guard let values else { throw DeviceDomainError.io("bold-text-value", "The device returned an invalid accessibility preferences dictionary.") }
                let enabled = (values[Self.boldTextKey] as? NSNumber)?.intValue == 1
                return { $0.boldText = enabled }
            }
        case .accessibility:
            guard simulated else { return await remoteAccessibility(device, remoteAppearance) }
            return await guest("appearance settings")
        case .voiceOver:
            guard simulated else {
                guard device.supportsSettingsFeature("voiceover") else { return .unsupported(group) }
                return await values("VoiceOver") {
                    let voice = try await query(VoiceOver.self, ["device", "info", "voiceover"], identifier)
                    return { $0.voiceOver = voice.enabled }
                }
            }
            return await guest("VoiceOver")
        case .audio:
            guard simulated else { return await remoteAudio(device) }
            return await guest("audio")
        case .location:
            guard simulated else {
                guard device.supportsSettingsFeature("simulatelocation") else { return .unsupported(group) }
                do {
                    let scenarios = try await query(Scenarios.self, ["device", "simulate", "location", "list"], identifier)
                    let names = scenarios.availableScenarios.map { SimulatorLocationScenario(name: $0.name, displayName: $0.localizedName ?? $0.name) }
                    return .values(group) {
                        $0.locationAvailable = true
                        $0.locationScenarios = names
                    }
                } catch {
                    // The device simulates locations, though it did not list its scenarios.
                    return .values(group, failures: ["location scenarios: \(error.localizedDescription)"]) { $0.locationAvailable = true }
                }
            }
            return await values("location") {
                let text = String(decoding: try await readCommand(.simctl, ["location", identifier, "list"]), as: UTF8.self)
                let names = Self.locationScenarios(text)
                return {
                    $0.locationAvailable = true
                    $0.locationScenarios = names
                }
            }
        }
    }

    private func remoteAccessibility(_ device: InventoryDevice, _ shared: Task<Appearance, any Error>?) async -> DeviceSettingsGroupRead {
        guard let shared else { return .unsupported(.accessibility) }
        let appearance: Appearance
        do { appearance = try await shared.value }
        catch { return .failed(.accessibility, "appearance settings: \(error.localizedDescription)") }
        let general = device.supportsSettingsFeature("customizeappearancesettings")
        let glass = device.supportsSettingsFeature("customizeliquidglass")
        var failures: [String] = []
        var filter: SimulatorColorFilter?
        if general, let reported = appearance.colorFilter {
            if !reported.enabled { filter = SimulatorColorFilter.none }
            else if let type = reported.filterType.flatMap({ Self.colorFilter($0.name) }) { filter = type }
            else { failures.append("color filter: The device returned an unrecognized enabled color filter.") }
        }
        return .values(.accessibility, failures: failures) { [filter] settings in
            settings.lookAndFeel = general ? appearance.lookAndFeel : nil
            settings.supportedLooksAndFeels = general ? (appearance.supportedLooksAndFeels ?? []).compactMap(Self.lookAndFeel) : []
            settings.liquidGlassOpacity = glass ? appearance.liquidGlassOpacity : nil
            settings.reduceMotion = general ? appearance.reduceMotion?.enabled : nil
            settings.reduceTransparency = general ? appearance.reduceTransparency?.enabled : nil
            settings.showBorders = general ? appearance.showBorders?.enabled : nil
            settings.colorFilter = filter
            settings.colorFilterIntensity = general ? appearance.colorFilter?.intensity : nil
        }
    }

    private func remoteAudio(_ device: InventoryDevice) async -> DeviceSettingsGroupRead {
        let input = device.supportsSettingsFeature("audioinput"), output = device.supportsSettingsFeature("audiooutput")
        guard input || output else { return .unsupported(.audio) }
        let audio: Audio
        do { audio = try await query(Audio.self, ["device", "info", "audio"], device.settingsIdentifier) }
        catch { return .failed(.audio, "audio: \(error.localizedDescription)") }
        var failures: [String] = []
        var devices: (input: [SimulatorAudioDevice], output: [SimulatorAudioDevice])?
        do { devices = try audioDevices() }
        catch { failures.append("audio devices: \(error.localizedDescription)") }
        return .values(.audio, failures: failures) { [devices] settings in
            settings.volume = output ? audio.volume : nil
            settings.audioInputDevice = input ? audio.audioInputDevice?.identifier : nil
            settings.audioOutputDevice = output ? audio.audioOutputDevice?.identifier : nil
            if let devices {
                settings.audioInputDevices = input ? devices.input : []
                settings.audioOutputDevices = output ? devices.output : []
            }
        }
    }

    package func set(_ setting: DeviceSettingChange, device: InventoryDevice) async throws {
        try device.checkSettingsWrite(setting)
        let identifier = device.settingsIdentifier
        if case .simulator = device {
            switch setting {
            case .contentSize, .lookAndFeel, .liquidGlassOpacity, .colorFilter, .reduceMotion, .showBorders,
                 .reduceTransparency, .voiceOver, .volume, .audioInputDevice, .audioOutputDevice:
                try await writeGuest(setting)
                return
            default: break
            }
        }
        func ui(_ name: String, _ value: String) async throws { _ = try await run(.simctl, ["ui", identifier, name, value]) }
        func appearance(_ option: String, _ value: String) async throws {
            _ = try await run(.devicectl, command(["device", "settings", "appearance", option, value], identifier))
        }
        func audio(_ option: String, _ value: String) async throws {
            _ = try await run(.devicectl, command(["device", "settings", "audio", option, value], identifier))
        }
        switch setting {
        case .appearance(let value):
            if case .simulator = device { try await ui("appearance", value.rawValue) }
            else { try await appearance("--mode", value.rawValue) }
        case .contentSize(let value):
            var options = ["--text-size", value.rawValue]
            if value.rawValue.hasPrefix("accessibility-") { options += ["--larger-accessibility-sizes", "on"] }
            _ = try await run(.devicectl, command(["device", "settings", "appearance"] + options, identifier))
        case .displayZoom(let mode):
            _ = try Self.displayZoomResult(await run(.guestSettings, [identifier, "display-zoom", "set", String(mode)]))
        case .boldText(let enabled):
            _ = try await run(.simctl, ["spawn", identifier, "defaults", "write", Self.boldTextDomain, Self.boldTextKey, "-int", enabled ? "1" : "0"])
            do {
                _ = try await run(.simctl, ["spawn", identifier, "notifyutil", "-p", Self.boldTextNotification])
            } catch {
                throw DeviceDomainError.io("bold-text-notification", "Bold Text was saved, but its change notification failed: \(error.localizedDescription)")
            }
        case .increaseContrast(let enabled):
            if case .simulator = device { try await ui("increase_contrast", enabled ? "enabled" : "disabled") }
            else { try await appearance("--increase-contrast", enabled ? "on" : "off") }
        case .lookAndFeel(let value): try await appearance("--look-and-feel", value.rawValue)
        case .liquidGlassOpacity(let value): try await appearance("--liquid-glass-opacity", String(value))
        case .colorFilter(let value, let intensity):
            var options = value == .none ? ["--color-filter", "off"] : ["--color-filter", "on", "--color-filter-type", value.rawValue]
            if let intensity { options += ["--color-filter-intensity", String(intensity)] }
            _ = try await run(.devicectl, command(["device", "settings", "appearance"] + options, identifier))
        case .reduceMotion(let enabled): try await appearance("--reduce-motion", enabled ? "on" : "off")
        case .showBorders(let enabled): try await appearance("--show-borders", enabled ? "on" : "off")
        case .reduceTransparency(let enabled): try await appearance("--reduce-transparency", enabled ? "on" : "off")
        case .voiceOver(let enabled): _ = try await run(.devicectl, command(["device", "settings", "voiceover", enabled ? "--enable" : "--disable"], identifier))
        case .volume(let value): try await audio("--volume", String(value))
        case .audioInputDevice(let value): try await audio("--input-device", value)
        case .audioOutputDevice(let value): try await audio("--output-device", value)
        case .location(let latitude, let longitude):
            if case .simulator = device { _ = try await run(.simctl, ["location", identifier, "set", "\(latitude),\(longitude)"]) }
            else {
                _ = try await run(.devicectl, command(["device", "simulate", "location", "coordinate",
                    "--latitude", String(latitude), "--longitude", String(longitude)], identifier))
            }
        case .locationScenario(let name):
            if case .simulator = device { _ = try await run(.simctl, ["location", identifier, "run", name]) }
            else { _ = try await run(.devicectl, command(["device", "simulate", "location", "scenario", name], identifier)) }
        case .clearLocation:
            if case .simulator = device { _ = try await run(.simctl, ["location", identifier, "clear"]) }
            else { _ = try await run(.devicectl, command(["device", "simulate", "location", "clear"], identifier)) }
        }
    }

    private struct DisplayZoomResult: Decodable {
        struct Failure: Decodable { let description: String }
        let success: Bool
        let modes: [SimulatorDisplayZoomMode]
        let current: SimulatorDisplayZoomMode?
        let canvasApplied: Bool?
        let error: Failure?
    }

    private static func displayZoomResult(_ data: Data) throws -> DisplayZoomResult {
        let result = try JSONDecoder().decode(DisplayZoomResult.self, from: data)
        guard result.success else {
            let message = result.error?.description ?? "The device did not return a Display Zoom result."
            throw DeviceDomainError.io("display-zoom", result.canvasApplied == true
                ? "Display Zoom was applied, but its remaining apply steps failed: \(message)" : message)
        }
        return result
    }

    // libAccessibility's _AXSSetEnhanceTextLegibilityEnabled uses this preference and cache notification.
    private static let boldTextDomain = "com.apple.Accessibility"
    private static let boldTextKey = "EnhancedTextLegibilityEnabled"
    private static let boldTextNotification = "com.apple.accessibility.cache.enhance.text.legibility"

    private func command(_ arguments: [String], _ identifier: String) -> [String] {
        arguments + ["--device", identifier, "--quiet", "--timeout", String(DeviceOperationLimit.devicectlQuery), "--json-output", "-"]
    }

    private func query<T: Decodable>(_ type: T.Type, _ arguments: [String], _ identifier: String) async throws -> T {
        try JSONDecoder().decode(Response<T>.self, from: await readCommand(.devicectl, command(arguments, identifier))).result
    }

    private struct Response<T: Decodable>: Decodable { let result: T }
    private struct Toggle: Decodable { let enabled: Bool }
    private struct ColorFilter: Decodable {
        struct FilterType: Decodable { let name: String }
        let enabled: Bool
        let filterType: FilterType?
        let intensity: Double?
    }
    private struct Appearance: Decodable {
        let userInterfaceStyle: String?
        let textSize: String?
        let increaseContrast: Bool?
        let lookAndFeel: String?
        let supportedLooksAndFeels: [String]?
        let liquidGlassOpacity: Double?
        let colorFilter: ColorFilter?
        let reduceMotion: Toggle?
        let reduceTransparency: Toggle?
        let showBorders: Toggle?
    }
    private struct VoiceOver: Decodable { let enabled: Bool }
    private struct Audio: Decodable {
        let volume: Int?
        let audioInputDevice: AudioSelection?
        let audioOutputDevice: AudioSelection?
    }
    private struct AudioSelection: Decodable {
        let systemDefault: Empty?
        let device: Device?
        struct Empty: Decodable {}
        struct Device: Decodable { let _0: String }
        var identifier: String? { systemDefault != nil ? "systemDefault" : device?._0 }
    }
    private struct Scenarios: Decodable {
        struct Scenario: Decodable { let name: String; let localizedName: String? }
        let availableScenarios: [Scenario]
    }

    private static func lookAndFeel(_ name: String) -> SimulatorLookAndFeel? {
        switch name.lowercased() {
        case "clear", "clear liquid glass": .clear
        case "tinted", "tinted liquid glass": .tinted
        default: nil
        }
    }
    private static func colorFilter(_ name: String) -> SimulatorColorFilter? {
        SimulatorColorFilter(rawValue: name.lowercased())
    }
    private static func contentSize(_ name: String) -> DeviceContentSize? {
        DeviceContentSize(rawValue: name.lowercased().replacingOccurrences(of: " ", with: "-"))
    }
    private static func locationScenarios(_ output: String) -> [SimulatorLocationScenario] {
        output.split(separator: "\n").dropFirst(2).compactMap { row in
            let columns = String(row).components(separatedBy: "  ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard let name = columns.first else { return nil }
            return SimulatorLocationScenario(name: name, displayName: columns.dropFirst().first ?? name)
        }
    }

    package static func hostAudioDevices() throws -> (input: [SimulatorAudioDevice], output: [SimulatorAudioDevice]) {
        func check(_ status: OSStatus) throws {
            guard status == noErr else { throw DeviceDomainError.io("host-audio-devices", "Could not read audio devices (CoreAudio status \(status)).") }
        }
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size))
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        if !devices.isEmpty {
            try devices.withUnsafeMutableBytes { try check(AudioObjectGetPropertyData(system, &address, 0, nil, &size, $0.baseAddress!)) }
        }
        let systemDefault = SimulatorAudioDevice(identifier: "systemDefault", name: "System Default")
        var input = [systemDefault], output = [systemDefault]
        for device in devices {
            func string(_ selector: AudioObjectPropertySelector) throws -> String {
                var property = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                var value: Unmanaged<CFString>?
                var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
                try check(AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value))
                guard let value else { throw DeviceDomainError.io("host-audio-devices", "An audio device did not provide its name or identifier.") }
                return value.takeRetainedValue() as String
            }
            let candidate = SimulatorAudioDevice(identifier: try string(kAudioDevicePropertyDeviceUID), name: try string(kAudioObjectPropertyName))
            func supports(_ scope: AudioObjectPropertyScope) throws -> Bool {
                var property = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope, mElement: kAudioObjectPropertyElementMain)
                var bytes: UInt32 = 0
                try check(AudioObjectGetPropertyDataSize(device, &property, 0, nil, &bytes))
                return bytes > 0
            }
            if try supports(kAudioDevicePropertyScopeInput) { input.append(candidate) }
            if try supports(kAudioDevicePropertyScopeOutput) { output.append(candidate) }
        }
        return (input, output)
    }
}
