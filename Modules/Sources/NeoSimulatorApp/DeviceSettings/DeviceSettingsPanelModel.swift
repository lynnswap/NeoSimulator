import Foundation
import Observation
import SwiftUI
import XcodeSimulatorHost

@MainActor @Observable
final class DeviceSettingsPanelModel {
    enum Content { case noSelection, multipleSelection, unavailable, loading, settings }
    enum SlowAnimationsControl { case hidden, unavailable, toggle, button }
    struct Choice: Identifiable {
        let id: String
        let title: String
    }

    let preferences: SimulatorPreferences
    @ObservationIgnored private let manager: SimulatorManagerModel
    @ObservationIgnored private let source: DeviceSettingsModel
    @ObservationIgnored private let screens: DeviceScreens
    @ObservationIgnored private let showCustomLocation: () -> Void

    init(manager: SimulatorManagerModel, screens: DeviceScreens, preferences: SimulatorPreferences,
         customLocation: @escaping () -> Void) {
        self.manager = manager
        source = manager.settings
        self.screens = screens
        self.preferences = preferences
        showCustomLocation = customLocation
    }

    private var device: InventoryDevice? { source.device }
    private var values: SimulatorDeviceSettings? { source.settings }
    private var screen: DeviceScreen? {
        guard let device, case .simulator = device else { return nil }
        return screens.screen(for: device.id)
    }
    var content: Content {
        if source.selectionCount > 1 { return .multipleSelection }
        guard source.selectionCount == 1, let device else { return .noSelection }
        guard device.canInspectSettings else { return .unavailable }
        if values == nil && source.issue == nil { return .loading }
        return hasSettings ? .settings : .unavailable
    }
    private var hasSettings: Bool {
        guard let values else { return screen?.simulatorCapabilities != nil }
        return screen?.simulatorCapabilities != nil || values.appearance != nil || values.liquidGlassOpacity != nil
            || values.colorFilter != nil || textSize != nil || values.boldText != nil || values.displayZoom != nil
            || values.reduceMotion != nil || values.increaseContrast != nil || values.showBorders != nil
            || values.reduceTransparency != nil || values.voiceOver != nil || values.locationAvailable
            || values.volume != nil || (values.audioOutputDevice != nil && !values.audioOutputDevices.isEmpty)
            || (values.audioInputDevice != nil && !values.audioInputDevices.isEmpty)
    }
    var holdsEdits: Bool {
        device.map { !manager.canEditSettings(for: $0.id) } ?? true
    }
    var issue: String { source.issue ?? values?.issues.joined(separator: "\n") ?? "" }
    var message: String? {
        guard let device else { return "Select a device to change its settings." }
        switch device {
        case .simulator(let simulator):
            guard simulator.isAvailable else { return "Install a compatible runtime to use this simulator’s settings." }
            guard simulator.state == "Booted" else { return "Start this simulator to change its settings." }
        case .remote(let remote):
            guard remote.isAvailable else { return "Connect this device to change its settings." }
        }
        if source.issue != nil || values?.issues.isEmpty == false {
            return hasSettings ? "Some settings could not be loaded for this device." : "Settings could not be loaded for this device."
        }
        return nil
    }

    func binding<Value: Hashable>(for keyPath: ReferenceWritableKeyPath<DeviceSettingsPanelModel, Value?>) -> Binding<Value>? {
        guard let device, let value = self[keyPath: keyPath] else { return nil }
        @Bindable var model = self
        return $model[setting: keyPath, on: device.id, fallback: value]
    }

    // SwiftUI can retain a control after its setting disappears. Keep its reads valid and its edits on the original device.
    private subscript<Value>(setting keyPath: ReferenceWritableKeyPath<DeviceSettingsPanelModel, Value?>,
                             on identifier: DeviceInventoryID, fallback value: Value) -> Value {
        get {
            guard device?.id == identifier else { return value }
            return self[keyPath: keyPath] ?? value
        }
        set {
            guard device?.id == identifier, content == .settings, self[keyPath: keyPath] != nil else { return }
            self[keyPath: keyPath] = newValue
        }
    }

    private func apply(_ setting: SimulatorDeviceSetting) {
        guard let device else { return }
        manager.setDeviceSetting(setting, for: device.id)
    }
    var appearance: String? { get { values?.appearance } set { if let newValue { apply(.appearance(newValue)) } } }
    var liquidGlassOpacity: Double? { get { values?.liquidGlassOpacity } set { if let newValue { apply(.liquidGlassOpacity(newValue)) } } }
    var colorFilter: String? {
        get { values?.colorFilter?.rawValue }
        set { if let newValue, let filter = SimulatorColorFilter(rawValue: newValue) { apply(.colorFilter(filter)) } }
    }
    var colorFilterIntensity: Double? {
        get {
            guard let filter = values?.colorFilter, filter != .none && filter != .grayscale else { return nil }
            return values?.colorFilterIntensity
        }
        set { if let newValue, let filter = values?.colorFilter { apply(.colorFilter(filter, intensity: newValue)) } }
    }
    var displayZoom: String? {
        get { values?.displayZoom.map { String($0.rawMode) } }
        set { if let newValue, let mode = UInt64(newValue) { apply(.displayZoom(mode)) } }
    }
    var textSize: Double? {
        get { values?.contentSize.flatMap { SimulatorDeviceSettings.contentSizes.firstIndex(of: $0) }.map(Double.init) }
        set {
            guard let newValue else { return }
            let index = Int(newValue.rounded())
            guard SimulatorDeviceSettings.contentSizes.indices.contains(index) else { return }
            apply(.contentSize(SimulatorDeviceSettings.contentSizes[index]))
        }
    }
    var textSizeDescription: String { values?.contentSize?.split(separator: "-").map { $0.capitalized }.joined(separator: " ") ?? "" }
    var boldText: Bool? { get { values?.boldText } set { if let newValue { apply(.boldText(newValue)) } } }
    var reduceMotion: Bool? { get { values?.reduceMotion } set { if let newValue { apply(.reduceMotion(newValue)) } } }
    var increaseContrast: Bool? { get { values?.increaseContrast } set { if let newValue { apply(.increaseContrast(newValue)) } } }
    var showBorders: Bool? { get { values?.showBorders } set { if let newValue { apply(.showBorders(newValue)) } } }
    var reduceTransparency: Bool? { get { values?.reduceTransparency } set { if let newValue { apply(.reduceTransparency(newValue)) } } }
    var voiceOver: Bool? { get { values?.voiceOver } set { if let newValue { apply(.voiceOver(newValue)) } } }
    var volume: Double? { get { values?.volume.map(Double.init) } set { if let newValue { apply(.volume(Int(newValue.rounded()))) } } }
    var audioOutput: String? { get { values?.audioOutputDevice } set { if let newValue { apply(.audioOutputDevice(newValue)) } } }
    var audioInput: String? { get { values?.audioInputDevice } set { if let newValue { apply(.audioInputDevice(newValue)) } } }

    var appearanceChoices: [Choice] { [.init(id: "light", title: "Light"), .init(id: "dark", title: "Dark")] }
    var colorFilterChoices: [Choice] {
        SimulatorColorFilter.allCases.map { filter in
            let title: String = switch filter {
            case .none: "None"
            case .grayscale: "Grayscale"
            case .protanopia: "Protanopia"
            case .deuteranopia: "Deuteranopia"
            case .tritanopia: "Tritanopia"
            }
            return Choice(id: filter.rawValue, title: title)
        }
    }
    var displayZoomChoices: [Choice] { (values?.supportedDisplayZoomModes ?? []).map { Choice(id: String($0.rawMode), title: $0.nativeName) } }
    var audioOutputChoices: [Choice] { (values?.audioOutputDevices ?? []).map { Choice(id: $0.identifier, title: $0.name) } }
    var audioInputChoices: [Choice] { (values?.audioInputDevices ?? []).map { Choice(id: $0.identifier, title: $0.name) } }
    var locationScenarios: [SimulatorLocationScenario] { values?.locationScenarios ?? [] }
    var locationAvailable: Bool { values?.locationAvailable == true }
    var locationTitle: String {
        switch values?.locationMode {
        case "none": "None"
        case "custom": "Custom"
        case "scenario": locationScenarios.first { $0.name == values?.locationScenario }?.displayName ?? "Unavailable"
        default: "Set Location"
        }
    }
    func clearLocation() { apply(.clearLocation) }
    func setLocationScenario(_ name: String) { apply(.locationScenario(name)) }
    func customLocation() { showCustomLocation() }

    var slowAnimationsControl: SlowAnimationsControl {
        guard case .simulator = device else { return .hidden }
        guard let capabilities = screen?.simulatorCapabilities else { return .unavailable }
        return capabilities.supportsFeature(DeviceCapabilities.slowMotionStateful) ? .toggle : .button
    }
    var canChangeSlowAnimations: Bool { screen?.isEnabled("slowAnimations") == true }
    var slowAnimations: Bool {
        get { preferences.slowAnimations }
        set { toggleSlowAnimations() }
    }
    func toggleSlowAnimations() { screen?.perform("slowAnimations") }
}
