import NeoSimulatorHostSupport
import NeoSimulatorKit
import SwiftUI

struct ManagerDeviceSettingsView: View {
    let model: DeviceSettingsPanelModel

    var body: some View {
        switch model.content {
        case .noSelection:
            ContentUnavailableView(
                "Select a Device", systemImage: "slider.horizontal.3",
                description: Text("Select one device to adjust its settings."))
        case .multipleSelection:
            ContentUnavailableView(
                "Multiple Devices Selected", systemImage: "slider.horizontal.3",
                description: Text("Select one device to adjust its settings."))
        case .unavailable:
            ContentUnavailableView(
                "Settings Unavailable", systemImage: "slider.horizontal.3",
                description: Text(model.message ?? "No settings are available for this device.")
            )
            .help(model.issue)
        case .settings:
            if let form = model.form {
                ManagerDeviceSettingsForm(model: form)
                    .disabled(model.holdsEdits)
            }
        }
    }
}

private struct ManagerDeviceSettingsForm: View {
    let model: DeviceSettingsFormModel

    var body: some View {
        Form {
            DeviceAppearanceSettingsSection(model: model)
            DeviceLocationSettingsSection(model: model)
            DeviceAudioSettingsSection(model: model)
        }
        .formStyle(.grouped)
        .labelStyle(.titleAndIcon)
        .labelReservedIconWidth(20)
    }
}

private struct DeviceAppearanceSettingsSection: View {
    @Bindable var model: DeviceSettingsFormModel

    var body: some View {
        Section {
            Picker(selection: $model.appearance) {
                if !model.appearanceAvailable {
                    Text("Unavailable").tag(Optional<DeviceAppearance>.none)
                }
                Text("Light").tag(DeviceAppearance.light)
                Text("Dark").tag(DeviceAppearance.dark)
            } label: {
                Label("Appearance", systemImage: "circle.lefthalf.filled")
            }
            .disabled(!model.appearanceAvailable)
            .buttonStyle(.borderless)
            LabeledContent {
                ManagerSettingSlider(
                    value: $model.liquidGlassOpacity,
                    range: 0...1,
                    tickMarks: 0,
                    label: "Liquid Glass"
                )
                .frame(minWidth: 90, maxWidth: .infinity, minHeight: 22)
            } label: {
                Label("Liquid Glass", systemImage: "drop.halffull")
                    .layoutPriority(1)
            }
            .disabled(!model.liquidGlassOpacityAvailable)
            Picker(selection: $model.colorFilter) {
                if !model.colorFilterAvailable {
                    Text("Unavailable").tag(Optional<SimulatorColorFilter>.none)
                }
                Text("None").tag(SimulatorColorFilter.none)
                Text("Grayscale").tag(SimulatorColorFilter.grayscale)
                Text("Protanopia").tag(SimulatorColorFilter.protanopia)
                Text("Deuteranopia").tag(SimulatorColorFilter.deuteranopia)
                Text("Tritanopia").tag(SimulatorColorFilter.tritanopia)
            } label: {
                Label("Color Filter", systemImage: "camera.filters")
            }
            .disabled(!model.colorFilterAvailable)
            .buttonStyle(.borderless)
            .help(Text(verbatim: model.colorFilterRequirement))
            if model.showsColorFilterIntensity {
                LabeledContent {
                    ManagerSettingSlider(
                        value: $model.colorFilterIntensity,
                        range: 0.25...1,
                        tickMarks: 0,
                        label: "Intensity"
                    )
                    .frame(minWidth: 90, maxWidth: .infinity, minHeight: 22)
                } label: {
                    Label("Intensity", systemImage: "slider.horizontal.3")
                        .layoutPriority(1)
                }
            }
            Picker(selection: $model.displayZoom) {
                if !model.displayZoomAvailable {
                    Text("Unavailable").tag(Optional<UInt64>.none)
                } else if model.displayZoom == nil {
                    Text("None").tag(Optional<UInt64>.none)
                }
                ForEach(model.displayZoomModes, id: \.rawMode) { mode in
                    Text(mode.nativeName).tag(mode.rawMode)
                }
            } label: {
                Label("Display Zoom", systemImage: "rectangle.inset.filled")
            }
            .disabled(!model.displayZoomAvailable)
            .buttonStyle(.borderless)
            .help("Applying Display Zoom restarts the device's interface.")
            LabeledContent {
                ManagerSettingSlider(
                    value: $model.textSize,
                    range: 0...11,
                    tickMarks: 12,
                    label: "Text Size"
                )
                .frame(minWidth: 90, maxWidth: .infinity, minHeight: 22)
                .help(model.textSizeDescription)
            } label: {
                Label("Text Size", systemImage: "textformat.size")
                    .layoutPriority(1)
            }
            .disabled(!model.textSizeAvailable)
            Toggle(isOn: $model.boldText) {
                Label("Bold Text", systemImage: "bold")
            }
            .disabled(!model.boldTextAvailable)
            Toggle(isOn: $model.reduceMotion) {
                Label("Reduce Motion", systemImage: "figure.walk.motion")
            }
            .disabled(!model.reduceMotionAvailable)
            DeviceSlowAnimationsSetting(model: model)
            Toggle(isOn: $model.increaseContrast) {
                Label("Increase Contrast", systemImage: "circle.lefthalf.striped.horizontal")
            }
            .disabled(!model.increaseContrastAvailable)
            Toggle(isOn: $model.showBorders) {
                Label("Show Borders", systemImage: "square.dashed")
            }
            .disabled(!model.showBordersAvailable)
            Toggle(isOn: $model.reduceTransparency) {
                Label("Reduce Transparency", systemImage: "square.on.square")
            }
            .disabled(!model.reduceTransparencyAvailable)
            Toggle(isOn: $model.voiceOver) {
                Label("VoiceOver", systemImage: "person.wave.2")
            }
            .disabled(!model.voiceOverAvailable)
        }
        .toggleStyle(.switch)
    }
}

private struct DeviceLocationSettingsSection: View {
    @Bindable var model: DeviceSettingsFormModel

    var body: some View {
        Section {
            Picker(selection: $model.locationSelection) {
                if model.locationSelection == nil {
                    Text("Unavailable")
                        .tag(Optional<LocationSelection>.none)
                        .disabled(true)
                }
                if let name = model.unavailableLocationScenario {
                    Text("Unavailable")
                        .tag(LocationSelection.scenario(name))
                        .disabled(true)
                }
                Section {
                    Text("None").tag(LocationSelection.none)
                    Text("Custom…").tag(LocationSelection.custom)
                }
                ForEach(model.locationScenarios, id: \.name) { scenario in
                    Text(scenario.displayName)
                        .tag(LocationSelection.scenario(scenario.name))
                }
            } label: {
                Label("Location", systemImage: "location")
            }
            .pickerStyle(.menu)
            .buttonStyle(.borderless)
            .disabled(!model.locationAvailable)
        }
    }
}

private struct DeviceAudioSettingsSection: View {
    @Bindable var model: DeviceSettingsFormModel

    var body: some View {
        Section {
            LabeledContent {
                ManagerSettingSlider(
                    value: $model.volume,
                    range: 0...100,
                    tickMarks: 0,
                    label: "Sound"
                )
                .frame(minWidth: 90, maxWidth: .infinity, minHeight: 22)
            } label: {
                Label("Sound", systemImage: "speaker.wave.2")
                    .layoutPriority(1)
            }
            .disabled(!model.volumeAvailable)
            Picker(selection: $model.audioOutput) {
                if !model.audioOutputAvailable {
                    Text("Unavailable").tag(Optional<String>.none)
                } else if model.audioOutput == nil {
                    Text("None").tag(Optional<String>.none)
                }
                ForEach(model.audioOutputDevices, id: \.identifier) { device in
                    Text(device.name).tag(device.identifier)
                }
            } label: {
                Label("Output", systemImage: "speaker")
            }
            .disabled(!model.audioOutputAvailable)
            .buttonStyle(.borderless)
            Picker(selection: $model.audioInput) {
                if !model.audioInputAvailable {
                    Text("Unavailable").tag(Optional<String>.none)
                } else if model.audioInput == nil {
                    Text("None").tag(Optional<String>.none)
                }
                ForEach(model.audioInputDevices, id: \.identifier) { device in
                    Text(device.name).tag(device.identifier)
                }
            } label: {
                Label("Input", systemImage: "mic")
            }
            .disabled(!model.audioInputAvailable)
            .buttonStyle(.borderless)
        }
    }
}

private struct DeviceSlowAnimationsSetting: View {
    @Bindable var model: DeviceSettingsFormModel

    var body: some View {
        switch model.slowAnimationsControl {
        case .hidden:
            EmptyView()
        case .unavailable, .toggle:
            Toggle(isOn: $model.slowAnimations) {
                Label("Slow Animations", systemImage: "tortoise")
            }
            .disabled(!model.canChangeSlowAnimations)
        case .button:
            LabeledContent {
                Button("Toggle", action: model.toggleSlowAnimations)
                    .disabled(!model.canChangeSlowAnimations)
            } label: {
                Label("Slow Animations", systemImage: "tortoise")
            }
            .help("Toggle slow animations in the frontmost app.")
        }
    }
}

#if DEBUG
    #Preview("Device Settings") {
        DeviceSettingsPreview()
            .frame(width: 360, height: 820)
    }

    private struct DeviceSettingsPreview: View {
        private let source: BackgroundServicesPreviewSource
        private let manager: SimulatorManagerModel
        private let panel: DeviceSettingsPanelModel

        init() {
            let source = BackgroundServicesPreviewSource(
                configuration: ServiceConfiguration(),
                stopped: false,
                settings: SimulatorDeviceSettings(
                    appearance: .light, contentSize: .large, boldText: false)
            )
            let store = ServiceProfileStore(
                fileURL: URL.temporaryDirectory.appending(
                    path: "DeviceSettingsPreview-\(UUID()).json"),
                legacyDefaults: nil
            )
            let manager = SimulatorManagerModel(source: source, serviceProfiles: store)
            self.source = source
            self.manager = manager
            panel = DeviceSettingsPanelModel(
                manager: manager,
                screens: DeviceScreens(model: manager),
                preferences: SimulatorPreferences(),
                customLocation: {}
            )
        }

        var body: some View {
            ManagerDeviceSettingsView(model: panel)
                .task {
                    await manager.refresh()
                    manager.inspect(source.device, selectionCount: 1)
                    await manager.registry.finishReading()
                }
        }
    }
#endif
