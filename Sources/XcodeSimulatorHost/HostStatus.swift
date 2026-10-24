import Foundation
import CoreAudio

enum ReceiptStatus: Equatable {
    case unmanaged
    case managed(original: ManagedPreferenceState)
    case pendingBefore
    case pendingTarget
    case ambiguousIntermediate
    case conflict(expected: ManagedPreferenceState, observed: ManagedPreferenceState)

    var hasConflict: Bool {
        if case .conflict = self {
            return true
        }
        return self == .ambiguousIntermediate
    }
}

struct SimulatorRouteStatus: Equatable {
    let preferences: ManagedPreferenceState
    let receiptStatus: ReceiptStatus

}

struct ModeChangeReport: Equatable {
    let host: ResolvedHost
    let didChangePreferences: Bool
    let xcode: XcodeInstallation
    let receiptURL: URL?
    let terminatedDeviceHubCount: Int
    let terminatedNeoHostCount: Int
}

struct RestoreReport: Equatable {
    let didRestore: Bool
    let restoredState: ManagedPreferenceState?
    let receiptURL: URL
    let terminatedNeoHostCount: Int
}

public enum SimulatorLookAndFeel: String, CaseIterable, Sendable {
    case clear, tinted
}

public enum SimulatorColorFilter: String, CaseIterable, Sendable {
    case none, grayscale, protanopia, deuteranopia, tritanopia
}

public struct SimulatorAudioDevice: Sendable, Equatable {
    public let identifier: String
    public let name: String
}

public struct SimulatorLocationScenario: Sendable, Equatable {
    public let name: String
    public let displayName: String
}

/// A snapshot of the guest settings. Nil means a value is unavailable; query failures are retained in `issues`.
public struct SimulatorDeviceSettings: Sendable {
    public static let contentSizes = ["extra-small", "small", "medium", "large", "extra-large", "extra-extra-large", "extra-extra-extra-large", "accessibility-medium", "accessibility-large", "accessibility-extra-large", "accessibility-extra-extra-large", "accessibility-extra-extra-extra-large"]
    public internal(set) var appearance: String?
    public internal(set) var contentSize: String?
    public internal(set) var increaseContrast: Bool?
    public internal(set) var lookAndFeel: String?
    public internal(set) var supportedLooksAndFeels: [SimulatorLookAndFeel] = []
    public internal(set) var liquidGlassOpacity: Double?
    public internal(set) var colorFilter: SimulatorColorFilter?
    public internal(set) var colorFilterIntensity: Double?
    public internal(set) var reduceMotion: Bool?
    public internal(set) var showBorders: Bool?
    public internal(set) var reduceTransparency: Bool?
    public internal(set) var voiceOver: Bool?
    public internal(set) var volume: Int?
    /// `systemDefault`, or a CoreAudio device UID.
    public internal(set) var audioInputDevice: String?
    public internal(set) var audioOutputDevice: String?
    public internal(set) var audioInputDevices: [SimulatorAudioDevice] = []
    public internal(set) var audioOutputDevices: [SimulatorAudioDevice] = []
    public internal(set) var locationAvailable = false
    public internal(set) var locationScenarios: [SimulatorLocationScenario] = []
    /// The saved desired mode (`none`, `custom`, or `scenario`); external live changes may differ.
    public internal(set) var locationMode: String?
    public internal(set) var locationScenario: String?
    public internal(set) var issues: [String] = []
}

public enum SimulatorDeviceSetting: Sendable {
    case appearance(String)
    case contentSize(String)
    case increaseContrast(Bool)
    case lookAndFeel(SimulatorLookAndFeel)
    case liquidGlassOpacity(Double)
    case colorFilter(SimulatorColorFilter, intensity: Double? = nil)
    case reduceMotion(Bool)
    case showBorders(Bool)
    case reduceTransparency(Bool)
    case voiceOver(Bool)
    case volume(Int)
    case audioInputDevice(String)
    case audioOutputDevice(String)
    case location(latitude: Double, longitude: Double)
    case locationScenario(String)
    case clearLocation
}

extension SimulatorHostController {
    public func deviceSettings(identifier: String) async throws -> SimulatorDeviceSettings {
        try await deviceSettings(for: .simulator(udid: identifier, deviceSetPath: nil))
    }

    public func deviceSettings(for deviceID: DeviceInventoryID) async throws -> SimulatorDeviceSettings {
        do {
            let (device, xcodeURL) = try await settingsDevice(deviceID)
            let identifier = deviceID.preferenceIdentifier
            guard device.state == "Booted" else { return SimulatorDeviceSettings() }
            var settings = await Self.readSettings(device: device, xcodeURL: xcodeURL)
            if let defaults = ToolConstants.managerDefaults {
                if defaults.synchronize() {
                    let record = defaults.dictionary(forKey: "DeviceLocationPreset.\(identifier)")
                    if let mode = record?["mode"] as? String, ["none", "custom", "scenario"].contains(mode) {
                        settings.locationMode = mode
                        if mode == "scenario" { settings.locationScenario = record?["scenario"] as? String }
                    }
                } else { settings.issues.append("location: Could not read the saved simulator location.") }
            } else { settings.issues.append("location: The saved simulator location is unavailable.") }
            return settings
        } catch let error as SimulatorHostFailure { throw error }
        catch { throw SimulatorHostFailure(error) }
    }

    public func setDeviceSetting(_ setting: SimulatorDeviceSetting, identifier: String) async throws {
        try await setDeviceSetting(setting, for: .simulator(udid: identifier, deviceSetPath: nil))
    }

    public func setDeviceSetting(_ setting: SimulatorDeviceSetting, for deviceID: DeviceInventoryID) async throws {
        do {
            let (device, xcodeURL) = try await settingsDevice(deviceID)
            let identifier = deviceID.preferenceIdentifier
            try await Self.writeSetting(setting, device: device, xcodeURL: xcodeURL)
            let audioRoute: (scope: String, route: String)?
            switch setting {
            case .audioInputDevice(let route): audioRoute = ("input", route)
            case .audioOutputDevice(let route): audioRoute = ("output", route)
            default: audioRoute = nil
            }
            if let audioRoute {
                guard let defaults = ToolConstants.managerDefaults else {
                    throw CLIError.io("device-audio-save", "The audio route was applied, but could not be saved for the next connection.")
                }
                defaults.set(audioRoute.route, forKey: "DeviceAudioRoute.\(identifier).\(audioRoute.scope)")
                guard defaults.synchronize() else {
                    throw CLIError.io("device-audio-save", "The audio route was applied, but could not be saved for the next connection.")
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
                guard let defaults = ToolConstants.managerDefaults else {
                    throw CLIError.io("device-location-save", "The location was applied, but could not be saved for the next connection.")
                }
                defaults.set(preset, forKey: "DeviceLocationPreset.\(identifier)")
                guard defaults.synchronize() else {
                    throw CLIError.io("device-location-save", "The location was applied, but could not be saved for the next connection.")
                }
                DistributedNotificationCenter.default().postNotificationName(
                    Notification.Name("dev.lynnswap.NeoSimulator.DeviceLocationChanged"),
                    object: device.identifier, userInfo: device.deviceSetPath.map { ["deviceSetPath": $0] }, deliverImmediately: true)
            }
        } catch let error as SimulatorHostFailure { throw error }
        catch { throw SimulatorHostFailure(error) }
    }

    @concurrent
    private static func readSettings(device: SimulatorHostDevice, xcodeURL: URL) async -> SimulatorDeviceSettings {
        settingsBackend(device: device, xcodeURL: xcodeURL).read(identifier: device.identifier)
    }

    @concurrent
    private static func writeSetting(_ setting: SimulatorDeviceSetting, device: SimulatorHostDevice, xcodeURL: URL) async throws {
        try settingsBackend(device: device, xcodeURL: xcodeURL).set(setting, identifier: device.identifier)
    }

    private static func settingsBackend(device: SimulatorHostDevice, xcodeURL: URL) -> SimulatorSettingsBackend {
        SimulatorSettingsBackend(run: { tool, arguments in
            let runner = SystemCommandRunner()
            let result = try tool == .simctl
                ? runner.runSimctl(xcodeURL: xcodeURL, arguments: arguments, deviceSetPath: device.deviceSetPath)
                : runner.runDevicectl(xcodeURL: xcodeURL, arguments: arguments)
            guard result.terminationStatus == 0 else {
                throw CLIError.io("device-setting", result.stderrText.isEmpty ? result.stdoutText : result.stderrText)
            }
            return result.stdout
        }, audioDevices: SimulatorSettingsBackend.hostAudioDevices)
    }
}

/// Keeps the command transport replaceable while tests exercise the same partial-result and write paths.
struct SimulatorSettingsBackend {
    enum Tool { case simctl, devicectl }
    var run: (Tool, [String]) throws -> Data
    var audioDevices: () throws -> (input: [SimulatorAudioDevice], output: [SimulatorAudioDevice])

    func read(identifier: String) -> SimulatorDeviceSettings {
        var settings = SimulatorDeviceSettings()
        func capture<T>(_ name: String, _ operation: () throws -> T) -> T? {
            do { return try operation() }
            catch { settings.issues.append("\(name): \(error.localizedDescription)"); return nil }
        }
        func ui(_ name: String) -> String? {
            capture(name) { String(decoding: try run(.simctl, ["ui", identifier, name]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        let appearance = ui("appearance")
        settings.appearance = appearance.flatMap { ["light", "dark"].contains($0) ? $0 : nil }
        let size = ui("content_size")
        settings.contentSize = size.flatMap { SimulatorDeviceSettings.contentSizes.contains($0) ? $0 : nil }
        let contrast = ui("increase_contrast")
        settings.increaseContrast = contrast == "enabled" ? true : contrast == "disabled" ? false : nil

        if let appearance = capture("appearance settings", { try query(Appearance.self, ["device", "info", "appearance"], identifier) }) {
            settings.lookAndFeel = appearance.lookAndFeel
            settings.supportedLooksAndFeels = (appearance.supportedLooksAndFeels ?? []).compactMap(Self.lookAndFeel)
            settings.liquidGlassOpacity = appearance.liquidGlassOpacity
            settings.reduceMotion = appearance.reduceMotion?.enabled
            settings.reduceTransparency = appearance.reduceTransparency?.enabled
            settings.showBorders = appearance.showBorders?.enabled
            if settings.appearance == nil { settings.appearance = appearance.userInterfaceStyle.flatMap { ["light", "dark"].contains($0) ? $0 : nil } }
            if settings.contentSize == nil { settings.contentSize = appearance.textSize.flatMap(Self.contentSize) }
            if settings.increaseContrast == nil { settings.increaseContrast = appearance.increaseContrast }
            if let filter = appearance.colorFilter {
                if !filter.enabled { settings.colorFilter = SimulatorColorFilter.none }
                else if let type = filter.filterType.flatMap({ Self.colorFilter($0.name) }) { settings.colorFilter = type }
                else { settings.issues.append("color filter: The device returned an unrecognized enabled color filter.") }
                settings.colorFilterIntensity = filter.intensity
            }
        }
        if let voice = capture("VoiceOver", { try query(VoiceOver.self, ["device", "info", "voiceover"], identifier) }) {
            settings.voiceOver = voice.enabled
        }
        if let audio = capture("audio", { try query(Audio.self, ["device", "info", "audio"], identifier) }) {
            settings.volume = audio.volume
            settings.audioInputDevice = audio.audioInputDevice?.identifier
            settings.audioOutputDevice = audio.audioOutputDevice?.identifier
            if let devices = capture("audio devices", audioDevices) {
                settings.audioInputDevices = devices.input
                settings.audioOutputDevices = devices.output
            }
        }
        if let scenarios = capture("location scenarios", { try query(Scenarios.self, ["device", "simulate", "location", "list"], identifier) }) {
            settings.locationAvailable = true
            settings.locationScenarios = scenarios.availableScenarios.map { SimulatorLocationScenario(name: $0.name, displayName: $0.localizedName ?? $0.name) }
        } else if let text = capture("location", { String(decoding: try run(.simctl, ["location", identifier, "list"]), as: UTF8.self) }) {
            settings.locationAvailable = true
            settings.locationScenarios = Self.locationScenarios(text)
        }
        return settings
    }

    func set(_ setting: SimulatorDeviceSetting, identifier: String) throws {
        func ui(_ name: String, _ value: String) throws { _ = try run(.simctl, ["ui", identifier, name, value]) }
        func appearance(_ option: String, _ value: String) throws {
            _ = try run(.devicectl, command(["device", "settings", "appearance", option, value], identifier))
        }
        func audio(_ option: String, _ value: String) throws {
            _ = try run(.devicectl, command(["device", "settings", "audio", option, value], identifier))
        }
        switch setting {
        case .appearance(let value): try ui("appearance", value)
        case .contentSize(let value): try ui("content_size", value)
        case .increaseContrast(let enabled): try ui("increase_contrast", enabled ? "enabled" : "disabled")
        case .lookAndFeel(let value): try appearance("--look-and-feel", value.rawValue)
        case .liquidGlassOpacity(let value): try appearance("--liquid-glass-opacity", String(value))
        case .colorFilter(let value, let intensity):
            var options = value == .none ? ["--color-filter", "off"] : ["--color-filter", "on", "--color-filter-type", value.rawValue]
            if let intensity { options += ["--color-filter-intensity", String(intensity)] }
            _ = try run(.devicectl, command(["device", "settings", "appearance"] + options, identifier))
        case .reduceMotion(let enabled): try appearance("--reduce-motion", enabled ? "on" : "off")
        case .showBorders(let enabled): try appearance("--show-borders", enabled ? "on" : "off")
        case .reduceTransparency(let enabled): try appearance("--reduce-transparency", enabled ? "on" : "off")
        case .voiceOver(let enabled): _ = try run(.devicectl, command(["device", "settings", "voiceover", enabled ? "--enable" : "--disable"], identifier))
        case .volume(let value): try audio("--volume", String(value))
        case .audioInputDevice(let value): try audio("--input-device", value)
        case .audioOutputDevice(let value): try audio("--output-device", value)
        case .location(let latitude, let longitude): _ = try run(.simctl, ["location", identifier, "set", "\(latitude),\(longitude)"])
        case .locationScenario(let name): _ = try run(.simctl, ["location", identifier, "run", name])
        case .clearLocation: _ = try run(.simctl, ["location", identifier, "clear"])
        }
    }

    private func command(_ arguments: [String], _ identifier: String) -> [String] {
        arguments + ["--device", identifier, "--quiet", "--timeout", "10", "--json-output", "-"]
    }

    private func query<T: Decodable>(_ type: T.Type, _ arguments: [String], _ identifier: String) throws -> T {
        try JSONDecoder().decode(Response<T>.self, from: run(.devicectl, command(arguments, identifier))).result
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
    private static func contentSize(_ name: String) -> String? {
        let normalized = name.lowercased().replacingOccurrences(of: " ", with: "-")
        return SimulatorDeviceSettings.contentSizes.contains(normalized) ? normalized : nil
    }
    private static func locationScenarios(_ output: String) -> [SimulatorLocationScenario] {
        output.split(separator: "\n").dropFirst(2).compactMap { row in
            let columns = String(row).components(separatedBy: "  ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard let name = columns.first else { return nil }
            return SimulatorLocationScenario(name: name, displayName: columns.dropFirst().first ?? name)
        }
    }

    static func hostAudioDevices() throws -> (input: [SimulatorAudioDevice], output: [SimulatorAudioDevice]) {
        func check(_ status: OSStatus) throws {
            guard status == noErr else { throw CLIError.io("host-audio-devices", "Could not read audio devices (CoreAudio status \(status)).") }
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
                guard let value else { throw CLIError.io("host-audio-devices", "An audio device did not provide its name or identifier.") }
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
