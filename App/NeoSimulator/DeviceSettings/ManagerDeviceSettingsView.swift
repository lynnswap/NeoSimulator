import SwiftUI
@_spi(NeoSimulator) import XcodeSimulatorHost

@MainActor
struct ManagerDeviceSettingsView: View {
    let manager: SimulatorManagerModel
    let model: DeviceSettingsModel
    let customLocation: () -> Void
    private var device: InventoryDevice? { model.device }
    private var settings: SimulatorDeviceSettings? { model.settings }
    private var issue: String? { model.issue }
    private var isBusy: Bool { manager.isBusy || device.map { manager.managingDeviceIDs.contains($0.id) } == true }
    private func apply(_ setting: SimulatorDeviceSetting) {
        guard let identifier = device?.id else { return }
        manager.setDeviceSetting(setting, for: identifier)
    }

    private struct Choice: Identifiable {
        let id: String
        let title: String
    }

    var body: some View {
        if model.selectionCount != 1 || device == nil {
            ContentUnavailableView(model.selectionCount > 1 ? "Multiple Devices Selected" : "Select a Device",
                                   systemImage: "slider.horizontal.3",
                                   description: Text("Select one device to adjust its settings."))
        } else if device?.canInspectSettings != true {
            unavailableSettings
        } else if settings == nil, issue == nil {
            ProgressView("Loading settings…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if hasAvailableSettings {
            settingsForm
        } else {
            unavailableSettings
        }
    }

    private var unavailableSettings: some View {
        ContentUnavailableView("Settings Unavailable", systemImage: "slider.horizontal.3",
                               description: Text(message ?? "No settings are available for this device."))
            .help(issue ?? settings?.issues.joined(separator: "\n") ?? "")
    }

    private var hasAvailableSettings: Bool {
        guard let settings else { return false }
        return settings.appearance != nil || settings.liquidGlassOpacity != nil || settings.colorFilter != nil
            || textSizeIndex != nil || settings.reduceMotion != nil || settings.increaseContrast != nil
            || settings.showBorders != nil || settings.reduceTransparency != nil || settings.voiceOver != nil
            || settings.locationAvailable || settings.volume != nil
            || (settings.audioOutputDevice != nil && !settings.audioOutputDevices.isEmpty)
            || (settings.audioInputDevice != nil && !settings.audioInputDevices.isEmpty)
    }

    private var settingsForm: some View {
        Form {
            Section {
                appearanceRows
                accessibilityRows
            }
            locationSection
            soundSection
            if let message {
                Section {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(issue ?? settings?.issues.joined(separator: "\n") ?? "")
                }
            }
        }
        .formStyle(.grouped)
        .labelStyle(.titleAndIcon)
        .disabled(isBusy)
    }

    private var appearanceRows: some View {
        Group {
            picker("Appearance", symbol: "circle.lefthalf.filled",
                   value: binding(get: { $0.appearance }, setting: SimulatorDeviceSetting.appearance),
                   choices: [Choice(id: "light", title: "Light"), Choice(id: "dark", title: "Dark")])
            slider("Liquid Glass", symbol: "drop.halffull",
                   value: binding(get: { $0.liquidGlassOpacity }, setting: SimulatorDeviceSetting.liquidGlassOpacity), range: 0...1)
            picker("Color Filter", symbol: "camera.filters",
                   value: binding(get: { $0.colorFilter?.rawValue }, setting: { SimulatorColorFilter(rawValue: $0).map { .colorFilter($0) } }),
                   choices: SimulatorColorFilter.allCases.map { Choice(id: $0.rawValue, title: filterTitle($0)) })
            if let filter = settings?.colorFilter, filter != .none, filter != .grayscale {
                slider("Intensity", symbol: "slider.horizontal.3",
                       value: binding(get: { $0.colorFilterIntensity }, setting: { .colorFilter(filter, intensity: $0) }), range: 0.25...1)
            }
            slider("Text Size", symbol: "textformat.size",
                   value: binding(get: { $0.contentSize.flatMap { SimulatorDeviceSettings.contentSizes.firstIndex(of: $0) }.map(Double.init) },
                                  setting: {
                                      let index = Int($0.rounded())
                                      guard SimulatorDeviceSettings.contentSizes.indices.contains(index) else { return nil }
                                      return .contentSize(SimulatorDeviceSettings.contentSizes[index])
                                  }),
                   range: 0...11, tickMarks: SimulatorDeviceSettings.contentSizes.count, help: textSizeDescription)
        }
    }

    private var accessibilityRows: some View {
        Group {
            toggle("Reduce Motion", symbol: "figure.walk.motion", keyPath: \.reduceMotion, setting: SimulatorDeviceSetting.reduceMotion)
            toggle("Increase Contrast", symbol: "circle.lefthalf.striped.horizontal", keyPath: \.increaseContrast, setting: SimulatorDeviceSetting.increaseContrast)
            toggle("Show Borders", symbol: "square.dashed", keyPath: \.showBorders, setting: SimulatorDeviceSetting.showBorders)
            toggle("Reduce Transparency", symbol: "square.on.square", keyPath: \.reduceTransparency, setting: SimulatorDeviceSetting.reduceTransparency)
            toggle("VoiceOver", symbol: "person.wave.2", keyPath: \.voiceOver, setting: SimulatorDeviceSetting.voiceOver)
        }
    }

    private var locationSection: some View {
        Section {
            LabeledContent {
                Menu(locationTitle) {
                    Button("None") { apply(.clearLocation) }
                    Button("Custom…", action: customLocation)
                    if settings?.locationScenarios.isEmpty == false { Divider() }
                    ForEach(settings?.locationScenarios ?? [], id: \.name) { scenario in
                        Button(scenario.displayName) { apply(.locationScenario(scenario.name)) }
                    }
                }
                .disabled(settings?.locationAvailable != true)
            } label: {
                Label("Location", systemImage: "location")
            }
        }
    }

    private var soundSection: some View {
        Section {
            slider("Sound", symbol: "speaker.wave.2",
                   value: binding(get: { $0.volume.map(Double.init) }, setting: { .volume(Int($0.rounded())) }), range: 0...100)
            picker("Output", symbol: "speaker", value: binding(get: { $0.audioOutputDevice }, setting: SimulatorDeviceSetting.audioOutputDevice),
                   choices: (settings?.audioOutputDevices ?? []).map { Choice(id: $0.identifier, title: $0.name) })
            picker("Input", symbol: "mic", value: binding(get: { $0.audioInputDevice }, setting: SimulatorDeviceSetting.audioInputDevice),
                   choices: (settings?.audioInputDevices ?? []).map { Choice(id: $0.identifier, title: $0.name) })
        }
    }

    private func binding<Value>(get: @escaping (SimulatorDeviceSettings) -> Value?,
                                setting: @escaping (Value) -> SimulatorDeviceSetting?) -> Binding<Value>? {
        guard let settings, let initial = get(settings), let identifier = device?.id else { return nil }
        return Binding(get: {
            model.settings.flatMap(get) ?? initial
        }, set: {
            if let edit = setting($0) { manager.setDeviceSetting(edit, for: identifier) }
        })
    }

    @ViewBuilder
    private func picker(_ title: String, symbol: String, value: Binding<String>?, choices: [Choice]) -> some View {
        if let value {
            Picker(selection: value) {
                if !choices.contains(where: { $0.id == value.wrappedValue }) { Text("Unavailable").tag(value.wrappedValue) }
                ForEach(choices) { Text($0.title).tag($0.id) }
            } label: {
                Label(title, systemImage: symbol)
            }
            .disabled(choices.isEmpty)
            .buttonStyle(.borderless)
        } else {
            unavailable(title, symbol: symbol)
        }
    }

    @ViewBuilder
    private func toggle(_ title: String, symbol: String, keyPath: KeyPath<SimulatorDeviceSettings, Bool?>,
                        setting: @escaping (Bool) -> SimulatorDeviceSetting) -> some View {
        if let value = binding(get: { $0[keyPath: keyPath] }, setting: setting) {
            Toggle(isOn: value) {
                Label(title, systemImage: symbol)
            }
            .toggleStyle(.switch)
        } else {
            unavailable(title, symbol: symbol)
        }
    }

    @ViewBuilder
    private func slider(_ title: String, symbol: String, value: Binding<Double>?, range: ClosedRange<Double>, tickMarks: Int = 0,
                        help: String = "") -> some View {
        if let value {
            LabeledContent {
                ManagerSettingSlider(value: value.wrappedValue, range: range, tickMarks: tickMarks, label: title,
                                     changed: { value.wrappedValue = $0 })
                    .frame(minWidth: 90, maxWidth: .infinity, minHeight: 22)
                    .help(help)
            } label: {
                Label(title, systemImage: symbol)
                    .layoutPriority(1)
            }
        } else {
            unavailable(title, symbol: symbol)
        }
    }

    private func unavailable(_ title: String, symbol: String) -> some View {
        LabeledContent {
            Text("Unavailable").foregroundStyle(.secondary)
        } label: {
            Label(title, systemImage: symbol)
        }
    }

    private var textSizeIndex: Double? {
        settings?.contentSize.flatMap { SimulatorDeviceSettings.contentSizes.firstIndex(of: $0) }.map(Double.init)
    }

    private var textSizeDescription: String {
        settings?.contentSize?.split(separator: "-").map { $0.capitalized }.joined(separator: " ") ?? ""
    }

    private var locationTitle: String {
        switch settings?.locationMode {
        case "none": "None"
        case "custom": "Custom"
        case "scenario": settings?.locationScenarios.first { $0.name == settings?.locationScenario }?.displayName ?? "Unavailable"
        default: "Set Location"
        }
    }

    private var message: String? {
        guard let device else { return "Select a device to change its settings." }
        switch device {
        case .simulator(let simulator):
            guard simulator.isAvailable else { return "Install a compatible runtime to use this simulator’s settings." }
            guard simulator.state == "Booted" else { return "Start this simulator to change its settings." }
        case .remote(let remote):
            guard remote.isAvailable else { return "Connect this device to change its settings." }
        }
        if issue != nil || settings?.issues.isEmpty == false {
            return hasAvailableSettings ? "Some settings could not be loaded for this device."
                : "Settings could not be loaded for this device."
        }
        return nil
    }

    private func filterTitle(_ filter: SimulatorColorFilter) -> String {
        switch filter {
        case .none: "None"
        case .grayscale: "Grayscale"
        case .protanopia: "Protanopia"
        case .deuteranopia: "Deuteranopia"
        case .tritanopia: "Tritanopia"
        }
    }
}
