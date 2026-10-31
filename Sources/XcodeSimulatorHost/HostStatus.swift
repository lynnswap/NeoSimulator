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

/// The app's saved display choice, without inspecting another app's preferences.
struct SimulatorHostSelectionStatus: Equatable {
    let host: SimulatorHost
    let restorationAvailable: Bool
    let allowsAutomaticHosting: Bool
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

public struct SimulatorDisplayZoomMode: Sendable, Equatable, Decodable {
    public let rawMode: UInt64
    public let nativeName: String
    public let width: Double
    public let height: Double
}

/// A snapshot of the guest settings. Nil means a value is unavailable; query failures are retained in `issues`.
public struct SimulatorDeviceSettings: Sendable {
    public static let contentSizes = ["extra-small", "small", "medium", "large", "extra-large", "extra-extra-large", "extra-extra-extra-large", "accessibility-medium", "accessibility-large", "accessibility-extra-large", "accessibility-extra-extra-large", "accessibility-extra-extra-extra-large"]
    public internal(set) var appearance: String?
    public internal(set) var contentSize: String?
    public internal(set) var boldText: Bool?
    public internal(set) var displayZoom: SimulatorDisplayZoomMode?
    public internal(set) var supportedDisplayZoomModes: [SimulatorDisplayZoomMode] = []
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

/// A failed write with the settings read after that attempt, including any partial changes.
@_spi(NeoSimulator) public struct SimulatorDeviceSettingsUpdateFailure: Error, LocalizedError, Sendable {
    public let settings: SimulatorDeviceSettings
    public let underlyingError: SimulatorHostFailure
    public var errorDescription: String? { underlyingError.errorDescription }
    public var failureReason: String? { underlyingError.failureReason }
    public var recoverySuggestion: String? { underlyingError.recoverySuggestion }
}

public enum SimulatorDeviceSetting: Sendable {
    case appearance(String)
    case contentSize(String)
    case boldText(Bool)
    case displayZoom(UInt64)
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

extension SimulatorDeviceSettings {
    /// Projects an accepted edit until the device confirms its values.
    @_spi(NeoSimulator) public func applying(_ setting: SimulatorDeviceSetting) -> Self {
        var result = self
        switch setting {
        case .appearance(let value): result.appearance = value
        case .contentSize(let value): result.contentSize = value
        case .boldText(let value): result.boldText = value
        case .displayZoom(let value): result.displayZoom = result.supportedDisplayZoomModes.first { $0.rawMode == value }
        case .increaseContrast(let value): result.increaseContrast = value
        case .lookAndFeel(let value): result.lookAndFeel = value.rawValue
        case .liquidGlassOpacity(let value): result.liquidGlassOpacity = value
        case .colorFilter(let value, let intensity):
            result.colorFilter = value
            if let intensity { result.colorFilterIntensity = intensity }
        case .reduceMotion(let value): result.reduceMotion = value
        case .showBorders(let value): result.showBorders = value
        case .reduceTransparency(let value): result.reduceTransparency = value
        case .voiceOver(let value): result.voiceOver = value
        case .volume(let value): result.volume = value
        case .audioInputDevice(let value): result.audioInputDevice = value
        case .audioOutputDevice(let value): result.audioOutputDevice = value
        case .location:
            result.locationMode = "custom"
            result.locationScenario = nil
        case .locationScenario(let value):
            result.locationMode = "scenario"
            result.locationScenario = value
        case .clearLocation:
            result.locationMode = "none"
            result.locationScenario = nil
        }
        return result
    }
}

private enum DeviceSettingsQuery { case appearance, voiceOver, audio, location }

private extension InventoryDevice {
    var settingsIdentifier: String {
        switch self {
        case .simulator(let device): device.identifier
        case .remote(let device): device.identifier
        }
    }

    var settingsPreferenceIdentifier: String {
        switch self {
        case .simulator(let device):
            if let path = device.deviceSetPath { return "set:\(path.utf8.count):\(path):\(device.identifier)" }
            return device.identifier
        case .remote(let device): return "coredevice:\(device.identifier)"
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
        case .simulator(let device): device.deviceSetPath == nil
        case .remote(let device): device.capabilities.contains("com.apple.coredevice.feature." + feature)
        }
    }

    func supportsSettingsQuery(_ query: DeviceSettingsQuery) -> Bool {
        switch query {
        case .appearance:
            supportsSettingsFeature("customizeuistyle") || supportsSettingsFeature("customizeappearancesettings") || supportsSettingsFeature("customizeliquidglass")
        case .voiceOver: supportsSettingsFeature("voiceover")
        case .audio: supportsSettingsFeature("audioinput") || supportsSettingsFeature("audiooutput")
        case .location: supportsSettingsFeature("simulatelocation")
        }
    }

    var supportsIOSDisplaySettings: Bool {
        guard case .simulator(let device) = self else { return false }
        return ["iPhone", "iPad"].contains(device.productFamily)
    }

    func checkSettingsWrite(_ setting: SimulatorDeviceSetting) throws {
        if case .boldText = setting, !supportsIOSDisplaySettings {
            throw CLIError.unavailable("bold-text-unavailable", "Bold Text is available only for iOS simulators.")
        }
        if case .displayZoom = setting, !supportsIOSDisplaySettings {
            throw CLIError.unavailable("display-zoom-unavailable", "Display Zoom is available only for iOS simulators.")
        }
        if case .simulator(let device) = self {
            switch setting {
            case .appearance, .contentSize, .boldText, .displayZoom, .increaseContrast, .location, .locationScenario, .clearLocation: return
            default:
                guard device.deviceSetPath == nil else {
                    throw CLIError.unavailable("custom-set-setting", "This setting is not available for simulators in a custom device set.")
                }
                return
            }
        }
        guard settingsAvailable else {
            throw CLIError.unavailable("device-setting-unavailable", "The selected device is not currently available.")
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
            throw CLIError.unavailable("device-setting-capability", "The selected device does not currently expose this setting.")
        }
    }
}

extension SimulatorHostController {
    /// Reads the supported settings for the selected inventory destination.
    public func deviceSettings(for device: InventoryDevice) async throws -> SimulatorDeviceSettings {
        do {
            let inspector = try await inspector(for: device)
            return await readDeviceSettings(device: device, xcodeURL: inspector.simulatorXcodeURL)
        } catch let error as SimulatorHostFailure { throw error }
        catch { throw SimulatorHostFailure(error) }
    }

    /// Writes one setting to the selected inventory destination; command failures are preserved.
    public func setDeviceSetting(_ setting: SimulatorDeviceSetting, for device: InventoryDevice) async throws {
        do {
            let inspector = try await inspector(for: device)
            try await applyDeviceSetting(setting, device: device, xcodeURL: inspector.simulatorXcodeURL)
        } catch let error as SimulatorHostFailure { throw error }
        catch { throw SimulatorHostFailure(error) }
    }

    /// Writes a setting and refreshes its values in an existing snapshot.
    /// Unrelated values and query issues are preserved. A failed refresh marks its values
    /// unavailable and records an issue. A write or persistence failure includes the
    /// post-attempt settings in `SimulatorDeviceSettingsUpdateFailure`.
    public func setDeviceSetting(_ setting: SimulatorDeviceSetting, for device: InventoryDevice,
                                 updating settings: SimulatorDeviceSettings) async throws -> SimulatorDeviceSettings {
        do {
            let inspector = try await inspector(for: device)
            let outcome = await Self.updateSettings(settings, after: setting, device: device,
                                                    xcodeURL: inspector.simulatorXcodeURL) {
                try await self.applyDeviceSetting(setting, device: device, xcodeURL: inspector.simulatorXcodeURL)
            }
            var updated = outcome.settings
            switch setting {
            case .location, .locationScenario, .clearLocation: readSavedLocation(for: device, settings: &updated)
            default: break
            }
            if let failure = outcome.failure {
                throw SimulatorDeviceSettingsUpdateFailure(settings: updated, underlyingError: failure)
            }
            return updated
        } catch let error as SimulatorDeviceSettingsUpdateFailure { throw error }
        catch let error as SimulatorHostFailure { throw error }
        catch { throw SimulatorHostFailure(error) }
    }

    public func deviceSettings(identifier: String) async throws -> SimulatorDeviceSettings {
        try await deviceSettings(for: .simulator(udid: identifier, deviceSetPath: nil))
    }

    public func deviceSettings(for deviceID: DeviceInventoryID) async throws -> SimulatorDeviceSettings {
        do {
            let (device, xcodeURL) = try await settingsDevice(deviceID)
            return await readDeviceSettings(device: .simulator(device), xcodeURL: xcodeURL)
        } catch let error as SimulatorHostFailure { throw error }
        catch { throw SimulatorHostFailure(error) }
    }

    public func setDeviceSetting(_ setting: SimulatorDeviceSetting, identifier: String) async throws {
        try await setDeviceSetting(setting, for: .simulator(udid: identifier, deviceSetPath: nil))
    }

    public func setDeviceSetting(_ setting: SimulatorDeviceSetting, for deviceID: DeviceInventoryID) async throws {
        do {
            let (device, xcodeURL) = try await settingsDevice(deviceID)
            try await applyDeviceSetting(setting, device: .simulator(device), xcodeURL: xcodeURL)
        } catch let error as SimulatorHostFailure { throw error }
        catch { throw SimulatorHostFailure(error) }
    }

    private func readDeviceSettings(device: InventoryDevice, xcodeURL: URL?) async -> SimulatorDeviceSettings {
        guard device.settingsAvailable else { return SimulatorDeviceSettings() }
        var settings = await Self.readSettings(device: device, xcodeURL: xcodeURL)
        readSavedLocation(for: device, settings: &settings)
        return settings
    }

    private func applyDeviceSetting(_ setting: SimulatorDeviceSetting, device: InventoryDevice, xcodeURL: URL?) async throws {
        try await Self.writeSetting(setting, device: device, xcodeURL: xcodeURL)
        try rememberSetting(setting, for: device)
    }

    private func readSavedLocation(for device: InventoryDevice, settings: inout SimulatorDeviceSettings) {
        settings.locationMode = nil
        settings.locationScenario = nil
        settings.issues.removeAll { $0.hasPrefix("saved location: ") }
        guard let defaults = ToolConstants.managerDefaults else {
            settings.issues.append("saved location: The saved desired location is unavailable.")
            return
        }
        guard defaults.synchronize() else {
            settings.issues.append("saved location: Could not read the saved desired location.")
            return
        }
        let record = defaults.dictionary(forKey: "DeviceLocationPreset.\(device.settingsPreferenceIdentifier)")
        if let mode = record?["mode"] as? String, ["none", "custom", "scenario"].contains(mode) {
            settings.locationMode = mode
            if mode == "scenario" { settings.locationScenario = record?["scenario"] as? String }
        }
    }

    private func rememberSetting(_ setting: SimulatorDeviceSetting, for device: InventoryDevice) throws {
        let identifier = device.settingsPreferenceIdentifier
        let audioRoute: (scope: String, route: String)?
        switch setting {
        case .audioInputDevice(let route): audioRoute = ("input", route)
        case .audioOutputDevice(let route): audioRoute = ("output", route)
        default: audioRoute = nil
        }
        if case .simulator = device, let audioRoute {
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
                throw CLIError.io("device-location-save", "The location was applied, but its saved selection could not be updated.")
            }
            defaults.set(preset, forKey: "DeviceLocationPreset.\(identifier)")
            guard defaults.synchronize() else {
                throw CLIError.io("device-location-save", "The location was applied, but its saved selection could not be updated.")
            }
            if case .simulator(let simulator) = device {
                DistributedNotificationCenter.default().postNotificationName(
                    Notification.Name("dev.lynnswap.NeoSimulator.DeviceLocationChanged"),
                    object: simulator.identifier,
                    userInfo: simulator.deviceSetPath.map { ["deviceSetPath": $0] }, deliverImmediately: true)
            }
        }
    }

    @concurrent
    private static func readSettings(device: InventoryDevice, xcodeURL: URL?) async -> SimulatorDeviceSettings {
        let backend = settingsBackend(device: device, xcodeURL: xcodeURL, readCommand: { tool, arguments in
            let result: CommandOutput
            if tool != .devicectl {
                guard case .simulator(let simulator) = device, let xcodeURL else {
                    throw CLIError.configuration("device-setting-source", "simctl requires a simulator destination and its developer tools.")
                }
                result = try await SystemCommandRunner.runSimctlCancellable(
                    xcodeURL: xcodeURL, arguments: try settingsArguments(tool, arguments), deviceSetPath: simulator.deviceSetPath)
            } else {
                result = try await SystemCommandRunner.runDevicectlCancellable(xcodeURL: xcodeURL, arguments: arguments)
            }
            guard result.terminationStatus == 0 || (tool == .guestSettings && !result.stdout.isEmpty) else {
                throw CLIError.io("device-setting", result.stderrText.isEmpty ? result.stdoutText : result.stderrText)
            }
            return result.stdout
        })
        return await backend.read(device: device)
    }

    @concurrent
    private static func updateSettings(_ settings: SimulatorDeviceSettings, after setting: SimulatorDeviceSetting,
                                       device: InventoryDevice, xcodeURL: URL?,
                                       applying write: @escaping @Sendable () async throws -> Void)
        async -> (settings: SimulatorDeviceSettings, failure: SimulatorHostFailure?) {
        await settingsBackend(device: device, xcodeURL: xcodeURL).update(settings, with: setting, device: device, applying: write)
    }

    @concurrent
    private static func writeSetting(_ setting: SimulatorDeviceSetting, device: InventoryDevice, xcodeURL: URL?) async throws {
        try settingsBackend(device: device, xcodeURL: xcodeURL).set(setting, device: device)
    }

    private static func settingsArguments(_ tool: SimulatorSettingsBackend.Tool, _ arguments: [String]) throws -> [String] {
        guard tool == .guestSettings else { return arguments }
        let helper = Bundle.main.bundleURL.appending(path: "Contents/Helpers/NeoSimulatorGuestSettings")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw CLIError.unavailable("guest-settings-helper", "The app's guest settings helper is unavailable.")
        }
        return ["spawn", arguments[0], helper.path] + arguments.dropFirst()
    }

    private static func settingsBackend(device: InventoryDevice, xcodeURL: URL?,
                                        readCommand: (@Sendable (SimulatorSettingsBackend.Tool, [String]) async throws -> Data)? = nil) -> SimulatorSettingsBackend {
        SimulatorSettingsBackend(run: { tool, arguments in
            let runner = SystemCommandRunner()
            let result: CommandOutput
            if tool != .devicectl {
                guard case .simulator(let simulator) = device, let xcodeURL else {
                    throw CLIError.configuration("device-setting-source", "simctl requires a simulator destination and its developer tools.")
                }
                result = try runner.runSimctl(xcodeURL: xcodeURL, arguments: try settingsArguments(tool, arguments), deviceSetPath: simulator.deviceSetPath)
            } else if let xcodeURL {
                result = try runner.runDevicectl(xcodeURL: xcodeURL, arguments: arguments)
            } else {
                result = try runner.run(executable: URL(fileURLWithPath: "/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/Resources/bin/devicectl"), arguments: arguments)
            }
            guard result.terminationStatus == 0 || (tool == .guestSettings && !result.stdout.isEmpty) else {
                throw CLIError.io("device-setting", result.stderrText.isEmpty ? result.stdoutText : result.stderrText)
            }
            return result.stdout
        }, readCommand: readCommand, audioDevices: SimulatorSettingsBackend.hostAudioDevices)
    }
}

/// Keeps the command transport replaceable while tests exercise the same partial-result and write paths.
struct SimulatorSettingsBackend: Sendable {
    enum Tool { case simctl, devicectl, guestSettings }
    var run: @Sendable (Tool, [String]) throws -> Data
    var readCommand: @Sendable (Tool, [String]) async throws -> Data
    var audioDevices: @Sendable () throws -> (input: [SimulatorAudioDevice], output: [SimulatorAudioDevice])

    init(run: @escaping @Sendable (Tool, [String]) throws -> Data,
         readCommand: (@Sendable (Tool, [String]) async throws -> Data)? = nil,
         audioDevices: @escaping @Sendable () throws -> (input: [SimulatorAudioDevice], output: [SimulatorAudioDevice])) {
        self.run = run
        self.readCommand = readCommand ?? { try run($0, $1) }
        self.audioDevices = audioDevices
    }

    /// Declaration order is the merge order: simctl values take priority over CoreDevice's
    /// appearance values, and issues keep the same order however the commands finish.
    private enum Query: CaseIterable {
        case simulatorAppearance, simulatorContentSize, simulatorContrast, displayZoom, boldText, appearance, voiceOver, audio, location

        var issueNames: [String] {
            switch self {
            case .simulatorAppearance: ["appearance"]
            case .simulatorContentSize: ["content_size"]
            case .simulatorContrast: ["increase_contrast"]
            case .boldText: ["Bold Text"]
            case .displayZoom: ["Display Zoom"]
            case .appearance: ["appearance settings", "color filter"]
            case .voiceOver: ["VoiceOver"]
            case .audio: ["audio"]
            case .location: ["location scenarios", "location"]
            }
        }
    }

    func read(device: InventoryDevice) async -> SimulatorDeviceSettings {
        await read(device: device, updating: SimulatorDeviceSettings(), queries: Set(Query.allCases), refreshAudioDevices: true)
    }

    func update(_ settings: SimulatorDeviceSettings, with setting: SimulatorDeviceSetting, device: InventoryDevice,
                applying write: () async throws -> Void) async -> (settings: SimulatorDeviceSettings, failure: SimulatorHostFailure?) {
        var failure: SimulatorHostFailure?
        do { try await write() }
        catch { failure = error as? SimulatorHostFailure ?? SimulatorHostFailure(error) }
        let updated = await refresh(settings, after: setting, device: device)
        return (updated, failure)
    }

    func refresh(_ settings: SimulatorDeviceSettings, after setting: SimulatorDeviceSetting,
                 device: InventoryDevice) async -> SimulatorDeviceSettings {
        let query: Query
        switch setting {
        case .appearance:
            if case .simulator = device { query = .simulatorAppearance } else { query = .appearance }
        case .contentSize:
            if case .simulator = device { query = .simulatorContentSize } else { query = .appearance }
        case .increaseContrast:
            if case .simulator = device { query = .simulatorContrast } else { query = .appearance }
        case .boldText: query = .boldText
        case .displayZoom: query = .displayZoom
        case .lookAndFeel, .liquidGlassOpacity, .colorFilter, .reduceMotion, .showBorders, .reduceTransparency: query = .appearance
        case .voiceOver: query = .voiceOver
        case .volume, .audioInputDevice, .audioOutputDevice: query = .audio
        case .location, .locationScenario, .clearLocation: return settings
        }
        return await read(device: device, updating: settings, queries: [query], refreshAudioDevices: false)
    }

    private func read(device: InventoryDevice, updating original: SimulatorDeviceSettings, queries: Set<Query>,
                      refreshAudioDevices: Bool) async -> SimulatorDeviceSettings {
        guard device.settingsAvailable else { return SimulatorDeviceSettings() }
        var settings = original
        for query in queries {
            settings.issues.removeAll { issue in query.issueNames.contains { issue.hasPrefix($0 + ": ") } }
            switch query {
            case .simulatorAppearance: settings.appearance = nil
            case .simulatorContentSize: settings.contentSize = nil
            case .simulatorContrast: settings.increaseContrast = nil
            case .boldText: settings.boldText = nil
            case .displayZoom:
                settings.displayZoom = nil
                settings.supportedDisplayZoomModes = []
            case .appearance:
                if case .remote = device {
                    settings.appearance = nil
                    settings.contentSize = nil
                    settings.increaseContrast = nil
                }
                settings.lookAndFeel = nil
                settings.supportedLooksAndFeels = []
                settings.liquidGlassOpacity = nil
                settings.colorFilter = nil
                settings.colorFilterIntensity = nil
                settings.reduceMotion = nil
                settings.reduceTransparency = nil
                settings.showBorders = nil
            case .voiceOver: settings.voiceOver = nil
            case .audio:
                settings.volume = nil
                settings.audioInputDevice = nil
                settings.audioOutputDevice = nil
            case .location:
                if case .remote = device { settings.locationAvailable = device.supportsSettingsFeature("simulatelocation") }
                else { settings.locationAvailable = false }
                settings.locationScenarios = []
            }
        }
        let results = await withTaskGroup(of: (Query, QueryResult).self) { group in
            for query in queries {
                group.addTask { await (query, self.result(of: query, device: device, refreshAudioDevices: refreshAudioDevices)) }
            }
            var finished: [Query: QueryResult] = [:]
            for await (query, result) in group { finished[query] = result }
            return finished
        }
        for query in Query.allCases {
            guard let result = results[query] else { continue }
            settings.issues += result.issues
            result.apply(&settings)
        }
        if case .remote = device {
            if !device.supportsSettingsFeature("customizeuistyle") { settings.appearance = nil }
            if !device.supportsSettingsFeature("customizeappearancesettings") {
                settings.contentSize = nil
                settings.increaseContrast = nil
                settings.lookAndFeel = nil
                settings.supportedLooksAndFeels = []
                settings.colorFilter = nil
                settings.colorFilterIntensity = nil
                settings.reduceMotion = nil
                settings.showBorders = nil
                settings.reduceTransparency = nil
            }
            if !device.supportsSettingsFeature("customizeliquidglass") { settings.liquidGlassOpacity = nil }
            if !device.supportsSettingsFeature("audioinput") {
                settings.audioInputDevice = nil
                settings.audioInputDevices = []
            }
            if !device.supportsSettingsFeature("audiooutput") {
                settings.volume = nil
                settings.audioOutputDevice = nil
                settings.audioOutputDevices = []
            }
        }
        return settings
    }

    /// One query's issues, and the values it applies when merged in `Query` order.
    private struct QueryResult: Sendable {
        var issues: [String] = []
        var apply: @Sendable (inout SimulatorDeviceSettings) -> Void = { _ in }
    }

    private func result(of query: Query, device: InventoryDevice, refreshAudioDevices: Bool) async -> QueryResult {
        var result = QueryResult()
        let identifier = device.settingsIdentifier
        func capture<T>(_ name: String, _ operation: () async throws -> T) async -> T? {
            guard !Task.isCancelled else { return nil }
            do { return try await operation() }
            catch {
                if !Task.isCancelled { result.issues.append("\(name): \(error.localizedDescription)") }
                return nil
            }
        }
        func ui(_ name: String) async -> String? {
            await capture(name) { String(decoding: try await readCommand(.simctl, ["ui", identifier, name]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        switch query {
        case .simulatorAppearance:
            guard case .simulator = device else { break }
            let appearance = await ui("appearance")
            result.apply = { $0.appearance = appearance.flatMap { ["light", "dark"].contains($0) ? $0 : nil } }
        case .simulatorContentSize:
            guard case .simulator = device else { break }
            let size = await ui("content_size")
            result.apply = { $0.contentSize = size.flatMap { SimulatorDeviceSettings.contentSizes.contains($0) ? $0 : nil } }
        case .simulatorContrast:
            guard case .simulator = device else { break }
            let contrast = await ui("increase_contrast")
            result.apply = { $0.increaseContrast = contrast == "enabled" ? true : contrast == "disabled" ? false : nil }
        case .displayZoom:
            guard device.supportsIOSDisplaySettings, let zoom = await capture("Display Zoom", {
                try Self.displayZoomResult(await readCommand(.guestSettings, [identifier, "display-zoom", "read"]))
            }) else { break }
            result.apply = {
                $0.displayZoom = zoom.current
                $0.supportedDisplayZoomModes = zoom.modes
            }
        case .boldText:
            guard device.supportsIOSDisplaySettings else { break }
            let boldText: Bool? = await capture("Bold Text") {
                let data = try await readCommand(.simctl, ["spawn", identifier, "defaults", "export", Self.boldTextDomain, "-"])
                let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
                guard let values else { throw CLIError.io("bold-text-value", "The device returned an invalid accessibility preferences dictionary.") }
                return (values[Self.boldTextKey] as? NSNumber)?.intValue == 1
            }
            result.apply = { $0.boldText = boldText }
        case .appearance:
            guard device.supportsSettingsQuery(.appearance), let appearance = await capture("appearance settings", { try await self.query(Appearance.self, ["device", "info", "appearance"], identifier) }) else { break }
            result.apply = { settings in
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
        case .voiceOver:
            guard device.supportsSettingsQuery(.voiceOver), let voice = await capture("VoiceOver", { try await self.query(VoiceOver.self, ["device", "info", "voiceover"], identifier) }) else { break }
            result.apply = { $0.voiceOver = voice.enabled }
        case .audio:
            guard device.supportsSettingsQuery(.audio), let audio = await capture("audio", { try await self.query(Audio.self, ["device", "info", "audio"], identifier) }) else { break }
            var devices: (input: [SimulatorAudioDevice], output: [SimulatorAudioDevice])?
            if refreshAudioDevices { devices = await capture("audio devices") { try audioDevices() } }
            result.apply = { [devices] settings in
                settings.volume = audio.volume
                settings.audioInputDevice = audio.audioInputDevice?.identifier
                settings.audioOutputDevice = audio.audioOutputDevice?.identifier
                if let devices {
                    settings.audioInputDevices = devices.input
                    settings.audioOutputDevices = devices.output
                }
            }
        case .location:
            if device.supportsSettingsQuery(.location), let scenarios = await capture("location scenarios", { try await self.query(Scenarios.self, ["device", "simulate", "location", "list"], identifier) }) {
                let values = scenarios.availableScenarios.map { SimulatorLocationScenario(name: $0.name, displayName: $0.localizedName ?? $0.name) }
                result.apply = {
                    $0.locationAvailable = true
                    $0.locationScenarios = values
                }
            } else if case .simulator = device, let text = await capture("location", { String(decoding: try await readCommand(.simctl, ["location", identifier, "list"]), as: UTF8.self) }) {
                let values = Self.locationScenarios(text)
                result.apply = {
                    $0.locationAvailable = true
                    $0.locationScenarios = values
                }
            }
        }
        return result
    }

    func set(_ setting: SimulatorDeviceSetting, device: InventoryDevice) throws {
        try device.checkSettingsWrite(setting)
        let identifier = device.settingsIdentifier
        func ui(_ name: String, _ value: String) throws { _ = try run(.simctl, ["ui", identifier, name, value]) }
        func appearance(_ option: String, _ value: String) throws {
            _ = try run(.devicectl, command(["device", "settings", "appearance", option, value], identifier))
        }
        func audio(_ option: String, _ value: String) throws {
            _ = try run(.devicectl, command(["device", "settings", "audio", option, value], identifier))
        }
        switch setting {
        case .appearance(let value):
            if case .simulator = device { try ui("appearance", value) }
            else { try appearance("--mode", value) }
        case .contentSize(let value):
            if case .simulator = device { try ui("content_size", value) }
            else {
                var options = ["--text-size", value]
                if value.hasPrefix("accessibility-") { options += ["--larger-accessibility-sizes", "on"] }
                _ = try run(.devicectl, command(["device", "settings", "appearance"] + options, identifier))
            }
        case .displayZoom(let mode):
            _ = try Self.displayZoomResult(run(.guestSettings, [identifier, "display-zoom", "set", String(mode)]))
        case .boldText(let enabled):
            _ = try run(.simctl, ["spawn", identifier, "defaults", "write", Self.boldTextDomain, Self.boldTextKey, "-int", enabled ? "1" : "0"])
            do {
                _ = try run(.simctl, ["spawn", identifier, "notifyutil", "-p", Self.boldTextNotification])
            } catch {
                throw CLIError.io("bold-text-notification", "Bold Text was saved, but its change notification failed: \(error.localizedDescription)")
            }
        case .increaseContrast(let enabled):
            if case .simulator = device { try ui("increase_contrast", enabled ? "enabled" : "disabled") }
            else { try appearance("--increase-contrast", enabled ? "on" : "off") }
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
        case .location(let latitude, let longitude):
            if case .simulator = device { _ = try run(.simctl, ["location", identifier, "set", "\(latitude),\(longitude)"]) }
            else {
                _ = try run(.devicectl, command(["device", "simulate", "location", "coordinate",
                    "--latitude", String(latitude), "--longitude", String(longitude)], identifier))
            }
        case .locationScenario(let name):
            if case .simulator = device { _ = try run(.simctl, ["location", identifier, "run", name]) }
            else { _ = try run(.devicectl, command(["device", "simulate", "location", "scenario", name], identifier)) }
        case .clearLocation:
            if case .simulator = device { _ = try run(.simctl, ["location", identifier, "clear"]) }
            else { _ = try run(.devicectl, command(["device", "simulate", "location", "clear"], identifier)) }
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
            throw CLIError.io("display-zoom", result.canvasApplied == true
                ? "Display Zoom was applied, but its remaining apply steps failed: \(message)" : message)
        }
        return result
    }

    // libAccessibility's _AXSSetEnhanceTextLegibilityEnabled uses this preference and cache notification.
    private static let boldTextDomain = "com.apple.Accessibility"
    private static let boldTextKey = "EnhancedTextLegibilityEnabled"
    private static let boldTextNotification = "com.apple.accessibility.cache.enhance.text.legibility"

    private func command(_ arguments: [String], _ identifier: String) -> [String] {
        arguments + ["--device", identifier, "--quiet", "--timeout", "10", "--json-output", "-"]
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
