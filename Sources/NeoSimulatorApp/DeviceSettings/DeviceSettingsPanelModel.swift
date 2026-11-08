import Foundation
import NeoSimulatorHostSupport
import NeoSimulatorKit
import Observation
import SwiftUI

@MainActor @Observable
final class DeviceSettingsPanelModel {
    enum Content { case noSelection, multipleSelection, unavailable, settings }
    enum SlowAnimationsControl { case hidden, unavailable, toggle, button }
    let preferences: SimulatorPreferences
    @ObservationIgnored private let manager: SimulatorManagerModel
    @ObservationIgnored private let selection: ManagerSelection
    @ObservationIgnored private let screens: DeviceScreens
    @ObservationIgnored private let showCustomLocation: () -> Void
    @ObservationIgnored private var settingsForm: DeviceSettingsFormModel?

    init(
        manager: SimulatorManagerModel, screens: DeviceScreens, preferences: SimulatorPreferences,
        customLocation: @escaping () -> Void
    ) {
        self.manager = manager
        selection = manager.selection
        self.screens = screens
        self.preferences = preferences
        showCustomLocation = customLocation
    }

    private var device: DeviceModel? { selection.device }
    private var values: DeviceSettingsState? { selection.device?.settings }
    private var screen: DeviceScreen? {
        guard let device, device.id.isSimulator else { return nil }
        return screens.screen(for: device.id)
    }
    var content: Content {
        if selection.count > 1 { return .multipleSelection }
        guard selection.count == 1, let device else { return .noSelection }
        guard device.canInspectSettings else { return .unavailable }
        return hasSettings ? .settings : .unavailable
    }
    private var hasSettings: Bool {
        guard let values else { return screen?.simulatorCapabilities != nil }
        return screen?.simulatorCapabilities != nil || values.appearance != nil
            || values.liquidGlassOpacity != nil
            || values.colorFilter != nil || values.contentSize != nil || values.boldText != nil
            || values.displayZoom != nil
            || values.reduceMotion != nil || values.increaseContrast != nil
            || values.showBorders != nil
            || values.reduceTransparency != nil || values.voiceOver != nil
            || values.locationAvailable
            || values.volume != nil
            || (values.audioOutputDevice != nil && !values.audioOutputDevices.isEmpty)
            || (values.audioInputDevice != nil && !values.audioInputDevices.isEmpty)
            || DeviceSettingsGroup.allCases.contains { values.status(of: $0) == .unread }
    }
    var holdsEdits: Bool {
        device.map { !manager.canEditSettings(for: $0.id) } ?? true
    }
    var issue: String { values?.failures.joined(separator: "\n") ?? "" }
    var message: String? {
        guard let device else { return "Select a device to change its settings." }
        switch device.inventory {
        case .simulator(let simulator):
            guard simulator.isAvailable else {
                return "Install a compatible runtime to use this simulator’s settings."
            }
            guard simulator.state == "Booted" else {
                return "Start this simulator to change its settings."
            }
        case .remote(let remote):
            guard remote.isAvailable else { return "Connect this device to change its settings." }
        }
        if values?.failures.isEmpty == false {
            return hasSettings
                ? "Some settings could not be read for this device, and may be out of date."
                : "Settings could not be loaded for this device."
        }
        return nil
    }

    var form: DeviceSettingsFormModel? {
        guard let device else { return nil }
        if settingsForm?.device !== device {
            settingsForm = DeviceSettingsFormModel(
                device: device,
                manager: manager,
                screens: screens,
                preferences: preferences,
                customLocation: showCustomLocation
            )
        }
        return settingsForm
    }
}

@MainActor @Observable
final class DeviceSettingsFormModel {
    let device: DeviceModel
    @ObservationIgnored lazy var liquidGlassOpacitySlider = DeviceSettingSliderModel(form: self, setting: .liquidGlassOpacity)
    @ObservationIgnored lazy var colorFilterIntensitySlider = DeviceSettingSliderModel(form: self, setting: .colorFilterIntensity)
    @ObservationIgnored lazy var textSizeSlider = DeviceSettingSliderModel(form: self, setting: .textSize)
    @ObservationIgnored lazy var volumeSlider = DeviceSettingSliderModel(form: self, setting: .volume)
    private let manager: SimulatorManagerModel
    private let screens: DeviceScreens
    private let preferences: SimulatorPreferences
    private let showCustomLocation: () -> Void

    init(
        device: DeviceModel,
        manager: SimulatorManagerModel,
        screens: DeviceScreens,
        preferences: SimulatorPreferences,
        customLocation: @escaping () -> Void
    ) {
        self.device = device
        self.manager = manager
        self.screens = screens
        self.preferences = preferences
        showCustomLocation = customLocation
    }

    private var values: DeviceSettingsState { device.settings }
    private var screen: DeviceScreen? { screens.screen(for: device.id) }
    fileprivate var acceptsEdits: Bool {
        manager.selection.device === device && manager.selection.count == 1
            && device.canInspectSettings && manager.canEditSettings(for: device.id)
    }

    private func apply(_ setting: DeviceSettingChange) {
        guard acceptsEdits else { return }
        manager.setDeviceSetting(setting, for: device.id)
    }

    var appearanceAvailable: Bool { values.appearance != nil }
    var appearance: DeviceAppearance? {
        get { values.appearance }
        set {
            guard appearanceAvailable, let newValue else { return }
            apply(.appearance(newValue))
        }
    }

    var liquidGlassOpacityAvailable: Bool { values.liquidGlassOpacity != nil }
    var liquidGlassOpacity: Double {
        get { values.liquidGlassOpacity ?? 0 }
        set {
            guard liquidGlassOpacityAvailable else { return }
            apply(.liquidGlassOpacity(newValue))
        }
    }

    var colorFilterAvailable: Bool { values.colorFilter != nil }
    var colorFilter: SimulatorColorFilter? {
        get { values.colorFilter }
        set {
            guard colorFilterAvailable, let newValue else { return }
            apply(.colorFilter(newValue))
        }
    }
    var colorFilterRequirement: String {
        values.colorFilterRequiredOSVersion.map { "OS \($0)+" } ?? ""
    }
    var showsColorFilterIntensity: Bool {
        guard let filter = values.colorFilter, filter != .none, filter != .grayscale else {
            return false
        }
        return values.colorFilterIntensity != nil
    }
    var colorFilterIntensity: Double {
        get { values.colorFilterIntensity ?? 0.25 }
        set {
            guard showsColorFilterIntensity, let filter = values.colorFilter else { return }
            apply(.colorFilter(filter, intensity: newValue))
        }
    }

    var displayZoomModes: [SimulatorDisplayZoomMode] { values.supportedDisplayZoomModes }
    var displayZoomAvailable: Bool { values.displayZoom != nil && !displayZoomModes.isEmpty }
    var displayZoom: UInt64? {
        get {
            guard let mode = values.displayZoom,
                displayZoomModes.contains(where: { $0.rawMode == mode.rawMode })
            else { return nil }
            return mode.rawMode
        }
        set {
            guard displayZoomAvailable, let newValue else { return }
            apply(.displayZoom(newValue))
        }
    }

    var textSizeAvailable: Bool { values.contentSize != nil }
    var textSize: Double {
        get {
            values.contentSize.flatMap { DeviceContentSize.allCases.firstIndex(of: $0) }.map(
                Double.init) ?? 0
        }
        set {
            guard textSizeAvailable else { return }
            let index = Int(newValue.rounded())
            guard DeviceContentSize.allCases.indices.contains(index) else { return }
            apply(.contentSize(DeviceContentSize.allCases[index]))
        }
    }
    var textSizeDescription: String {
        values.contentSize?.rawValue.split(separator: "-").map { $0.capitalized }.joined(
            separator: " ") ?? ""
    }

    var boldTextAvailable: Bool { values.boldText != nil }
    var boldText: Bool {
        get { values.boldText ?? false }
        set {
            guard boldTextAvailable else { return }
            apply(.boldText(newValue))
        }
    }

    var reduceMotionAvailable: Bool { values.reduceMotion != nil }
    var reduceMotion: Bool {
        get { values.reduceMotion ?? false }
        set {
            guard reduceMotionAvailable else { return }
            apply(.reduceMotion(newValue))
        }
    }

    var increaseContrastAvailable: Bool { values.increaseContrast != nil }
    var increaseContrast: Bool {
        get { values.increaseContrast ?? false }
        set {
            guard increaseContrastAvailable else { return }
            apply(.increaseContrast(newValue))
        }
    }

    var showBordersAvailable: Bool { values.showBorders != nil }
    var showBorders: Bool {
        get { values.showBorders ?? false }
        set {
            guard showBordersAvailable else { return }
            apply(.showBorders(newValue))
        }
    }

    var reduceTransparencyAvailable: Bool { values.reduceTransparency != nil }
    var reduceTransparency: Bool {
        get { values.reduceTransparency ?? false }
        set {
            guard reduceTransparencyAvailable else { return }
            apply(.reduceTransparency(newValue))
        }
    }

    var voiceOverAvailable: Bool { values.voiceOver != nil }
    var voiceOver: Bool {
        get { values.voiceOver ?? false }
        set {
            guard voiceOverAvailable else { return }
            apply(.voiceOver(newValue))
        }
    }

    var volumeAvailable: Bool { values.volume != nil }
    var volume: Double {
        get { values.volume.map(Double.init) ?? 0 }
        set {
            guard volumeAvailable else { return }
            apply(.volume(Int(newValue.rounded())))
        }
    }

    var audioOutputDevices: [SimulatorAudioDevice] { values.audioOutputDevices }
    var audioOutputAvailable: Bool { values.audioOutputDevice != nil && !audioOutputDevices.isEmpty }
    var audioOutput: String? {
        get {
            guard let identifier = values.audioOutputDevice,
                audioOutputDevices.contains(where: { $0.identifier == identifier })
            else { return nil }
            return identifier
        }
        set {
            guard audioOutputAvailable, let newValue else { return }
            apply(.audioOutputDevice(newValue))
        }
    }

    var audioInputDevices: [SimulatorAudioDevice] { values.audioInputDevices }
    var audioInputAvailable: Bool { values.audioInputDevice != nil && !audioInputDevices.isEmpty }
    var audioInput: String? {
        get {
            guard let identifier = values.audioInputDevice,
                audioInputDevices.contains(where: { $0.identifier == identifier })
            else { return nil }
            return identifier
        }
        set {
            guard audioInputAvailable, let newValue else { return }
            apply(.audioInputDevice(newValue))
        }
    }

    var locationScenarios: [SimulatorLocationScenario] { values.locationScenarios }
    var locationAvailable: Bool { values.locationAvailable }
    var unavailableLocationScenario: String? {
        guard case .some(.scenario(let name)) = locationSelection,
            !locationScenarios.contains(where: { $0.name == name })
        else { return nil }
        return name
    }
    var locationSelection: LocationSelection? {
        get {
            guard locationAvailable else { return nil }
            switch values.locationMode {
            case .some(.custom):
                return .custom
            case .some(.scenario):
                return values.locationScenario.map(LocationSelection.scenario)
            case .some(.none):
                return .some(.none)
            case nil:
                return nil
            }
        }
        set {
            guard acceptsEdits, locationAvailable, let newValue else { return }
            switch newValue {
            case .none:
                apply(.clearLocation)
            case .custom:
                showCustomLocation()
            case .scenario(let name):
                apply(.locationScenario(name))
            }
        }
    }

    var slowAnimationsControl: DeviceSettingsPanelModel.SlowAnimationsControl {
        guard device.id.isSimulator else { return .hidden }
        guard let capabilities = screen?.simulatorCapabilities else { return .unavailable }
        return capabilities.supportsFeature(DeviceCapabilities.slowMotionStateful)
            ? .toggle : .button
    }
    var canChangeSlowAnimations: Bool {
        acceptsEdits && screen?.isEnabled("slowAnimations") == true
    }
    var slowAnimations: Bool {
        get { preferences.slowAnimations }
        set { toggleSlowAnimations() }
    }
    func toggleSlowAnimations() {
        guard canChangeSlowAnimations else { return }
        screen?.perform("slowAnimations")
    }
}

@MainActor @Observable
final class DeviceSettingSliderModel {
    enum Setting { case liquidGlassOpacity, colorFilterIntensity, textSize, volume }
    @ObservationIgnored private weak var form: DeviceSettingsFormModel?
    private let setting: Setting

    init(form: DeviceSettingsFormModel, setting: Setting) {
        self.form = form
        self.setting = setting
    }

    var label: LocalizedStringResource {
        switch setting {
        case .liquidGlassOpacity: "Liquid Glass"
        case .colorFilterIntensity: "Intensity"
        case .textSize: "Text Size"
        case .volume: "Sound"
        }
    }
    var range: ClosedRange<Double> {
        switch setting {
        case .liquidGlassOpacity: 0...1
        case .colorFilterIntensity: 0.25...1
        case .textSize: 0...11
        case .volume: 0...100
        }
    }
    var tickMarks: Int { setting == .textSize ? 12 : 0 }
    var help: String? { setting == .textSize ? form?.textSizeDescription : nil }
    var isAvailable: Bool {
        guard let form else { return false }
        switch setting {
        case .liquidGlassOpacity: return form.liquidGlassOpacityAvailable
        case .colorFilterIntensity: return form.showsColorFilterIntensity
        case .textSize: return form.textSizeAvailable
        case .volume: return form.volumeAvailable
        }
    }
    var isEnabled: Bool { isAvailable && form?.acceptsEdits == true }
    var value: Double {
        get {
            guard let form else { return range.lowerBound }
            switch setting {
            case .liquidGlassOpacity: return form.liquidGlassOpacity
            case .colorFilterIntensity: return form.colorFilterIntensity
            case .textSize: return form.textSize
            case .volume: return form.volume
            }
        }
        set {
            guard isEnabled, let form else { return }
            switch setting {
            case .liquidGlassOpacity: form.liquidGlassOpacity = newValue
            case .colorFilterIntensity: form.colorFilterIntensity = newValue
            case .textSize: form.textSize = newValue
            case .volume: form.volume = newValue
            }
        }
    }
}
