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

private let deviceSettingsAnimation = Animation.easeInOut(duration: 0.22)

private struct DeviceSettingsOpacity: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content.animation(deviceSettingsAnimation) { view in
            view.opacity(isEnabled ? 1 : 0.5)
        }
    }
}

private extension View {
    func deviceSettingsOpacity() -> some View {
        modifier(DeviceSettingsOpacity())
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
        .animation(deviceSettingsAnimation, value: model.showsColorFilterIntensity)
        .transaction(value: model.device.id) { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .labelStyle(.titleAndIcon)
        .labelReservedIconWidth(20)
    }
}

private struct DeviceAppearanceSettingsSection: View {
    @Bindable var model: DeviceSettingsFormModel

    var body: some View {
        Section {
            Picker(selection: $model.appearance) {
                if model.appearance == nil {
                    Text("Unavailable").tag(Optional<DeviceAppearance>.none).disabled(true)
                }
                Text("Light").tag(DeviceAppearance.light)
                Text("Dark").tag(DeviceAppearance.dark)
            } label: {
                Label("Appearance", systemImage: "circle.lefthalf.filled")
            }
            .deviceSettingsOpacity()
            .disabled(!model.appearanceAvailable)
            .buttonStyle(.borderless)
            LabeledContent {
                ManagerSettingSlider(model: model.liquidGlassOpacitySlider)
                    .frame(minWidth: 90, maxWidth: .infinity, minHeight: 22)
            } label: {
                Label("Liquid Glass", systemImage: "drop.halffull")
                    .layoutPriority(1)
            }
            .deviceSettingsOpacity()
            .disabled(!model.liquidGlassOpacitySlider.isEnabled)
            Picker(selection: $model.colorFilter) {
                if model.colorFilter == nil {
                    Text("Unavailable").tag(Optional<SimulatorColorFilter>.none).disabled(true)
                }
                Text("None").tag(SimulatorColorFilter.none)
                Text("Grayscale").tag(SimulatorColorFilter.grayscale)
                Text("Protanopia").tag(SimulatorColorFilter.protanopia)
                Text("Deuteranopia").tag(SimulatorColorFilter.deuteranopia)
                Text("Tritanopia").tag(SimulatorColorFilter.tritanopia)
            } label: {
                Label("Color Filter", systemImage: "camera.filters")
            }
            .deviceSettingsOpacity()
            .disabled(!model.colorFilterAvailable)
            .buttonStyle(.borderless)
            .help(Text(verbatim: model.colorFilterRequirement))
            if model.showsColorFilterIntensity {
                LabeledContent {
                    ManagerSettingSlider(model: model.colorFilterIntensitySlider)
                        .frame(minWidth: 90, maxWidth: .infinity, minHeight: 22)
                } label: {
                    Label("Intensity", systemImage: "slider.horizontal.3")
                        .layoutPriority(1)
                }
                .deviceSettingsOpacity()
                .disabled(!model.colorFilterIntensitySlider.isEnabled)
            }
            Picker(selection: $model.displayZoom) {
                if model.displayZoom == nil {
                    Text("Unavailable").tag(Optional<UInt64>.none).disabled(true)
                }
                ForEach(model.displayZoomModes, id: \.rawMode) { mode in
                    Text(mode.nativeName).tag(mode.rawMode)
                }
            } label: {
                Label("Display Zoom", systemImage: "rectangle.inset.filled")
            }
            .deviceSettingsOpacity()
            .disabled(!model.displayZoomAvailable)
            .buttonStyle(.borderless)
            .help("Applying Display Zoom restarts the device's interface.")
            LabeledContent {
                ManagerSettingSlider(model: model.textSizeSlider)
                    .frame(minWidth: 90, maxWidth: .infinity, minHeight: 22)
            } label: {
                Label("Text Size", systemImage: "textformat.size")
                    .layoutPriority(1)
            }
            .deviceSettingsOpacity()
            .disabled(!model.textSizeSlider.isEnabled)
            Toggle(isOn: $model.boldText) {
                Label("Bold Text", systemImage: "bold")
            }
            .deviceSettingsOpacity()
            .disabled(!model.boldTextAvailable)
            Toggle(isOn: $model.reduceMotion) {
                Label("Reduce Motion", systemImage: "figure.walk.motion")
            }
            .deviceSettingsOpacity()
            .disabled(!model.reduceMotionAvailable)
            DeviceSlowAnimationsSetting(model: model)
            Toggle(isOn: $model.increaseContrast) {
                Label("Increase Contrast", systemImage: "circle.lefthalf.striped.horizontal")
            }
            .deviceSettingsOpacity()
            .disabled(!model.increaseContrastAvailable)
            Toggle(isOn: $model.showBorders) {
                Label("Show Borders", systemImage: "square.dashed")
            }
            .deviceSettingsOpacity()
            .disabled(!model.showBordersAvailable)
            Toggle(isOn: $model.reduceTransparency) {
                Label("Reduce Transparency", systemImage: "square.on.square")
            }
            .deviceSettingsOpacity()
            .disabled(!model.reduceTransparencyAvailable)
            Toggle(isOn: $model.voiceOver) {
                Label("VoiceOver", systemImage: "person.wave.2")
            }
            .deviceSettingsOpacity()
            .disabled(!model.voiceOverAvailable)
        }
    }
}

private struct DeviceLocationSettingsSection: View {
    @Bindable var model: DeviceSettingsFormModel

    var body: some View {
        Section {
            Picker(selection: $model.locationSelection) {
                if model.locationSelection == nil || model.unavailableLocationScenario != nil {
                    Text("Unavailable")
                        .tag(model.locationSelection)
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
            .deviceSettingsOpacity()
            .disabled(!model.locationAvailable)
        }
    }
}

private struct DeviceAudioSettingsSection: View {
    @Bindable var model: DeviceSettingsFormModel

    var body: some View {
        Section {
            LabeledContent {
                ManagerSettingSlider(model: model.volumeSlider)
                    .frame(minWidth: 90, maxWidth: .infinity, minHeight: 22)
            } label: {
                Label("Sound", systemImage: "speaker.wave.2")
                    .layoutPriority(1)
            }
            .deviceSettingsOpacity()
            .disabled(!model.volumeSlider.isEnabled)
            Picker(selection: $model.audioOutput) {
                if model.audioOutput == nil {
                    Text("Unavailable").tag(Optional<String>.none).disabled(true)
                }
                ForEach(model.audioOutputDevices, id: \.identifier) { device in
                    Text(device.name).tag(device.identifier)
                }
            } label: {
                Label("Output", systemImage: "speaker")
            }
            .deviceSettingsOpacity()
            .disabled(!model.audioOutputAvailable)
            .buttonStyle(.borderless)
            Picker(selection: $model.audioInput) {
                if model.audioInput == nil {
                    Text("Unavailable").tag(Optional<String>.none).disabled(true)
                }
                ForEach(model.audioInputDevices, id: \.identifier) { device in
                    Text(device.name).tag(device.identifier)
                }
            } label: {
                Label("Input", systemImage: "mic")
            }
            .deviceSettingsOpacity()
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
            .deviceSettingsOpacity()
            .disabled(!model.canChangeSlowAnimations)
        case .button:
            LabeledContent {
                Button("Toggle", action: model.toggleSlowAnimations)
            } label: {
                Label("Slow Animations", systemImage: "tortoise")
            }
            .deviceSettingsOpacity()
            .disabled(!model.canChangeSlowAnimations)
            .help("Toggle slow animations in the frontmost app.")
        }
    }
}

#if DEBUG
    #Preview("Device Settings") {
        DeviceSettingsPreview(available: true)
            .frame(width: 360, height: 820)
    }

    #Preview("Unavailable") {
        DeviceSettingsPreview(available: false)
            .frame(width: 360, height: 820)
    }

    private struct DeviceSettingsPreview: View {
        private let source: BackgroundServicesPreviewSource
        private let manager: SimulatorManagerModel
        private let panel: DeviceSettingsPanelModel

        init(available: Bool) {
            var settings = SimulatorDeviceSettings()
            if available {
                settings = SimulatorDeviceSettings(
                    appearance: .light, contentSize: .large, boldText: false,
                    increaseContrast: false, liquidGlassOpacity: 0.5, colorFilter: .protanopia,
                    reduceMotion: false, showBorders: false, reduceTransparency: false,
                    voiceOver: false, volume: 75
                )
                settings.colorFilterIntensity = 0.5
                let zoom = SimulatorDisplayZoomMode(
                    rawMode: 0, nativeName: "Default", width: 402, height: 874)
                settings.displayZoom = zoom
                settings.supportedDisplayZoomModes = [
                    zoom,
                    SimulatorDisplayZoomMode(rawMode: 1, nativeName: "Larger Text", width: 375, height: 812),
                ]
                let audio = SimulatorAudioDevice(identifier: "systemDefault", name: "System Default")
                settings.audioInputDevice = audio.identifier
                settings.audioOutputDevice = audio.identifier
                settings.audioInputDevices = [audio]
                settings.audioOutputDevices = [audio]
                settings.locationAvailable = true
                settings.locationMode = DeviceLocationMode.none
                settings.locationScenarios = [
                    SimulatorLocationScenario(name: "city-bicycle", displayName: "City Bicycle")
                ]
            }
            let source = BackgroundServicesPreviewSource(
                configuration: ServiceConfiguration(),
                stopped: false,
                settings: settings
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
            ZStack {
                if let form = panel.form {
                    ManagerDeviceSettingsForm(model: form)
                        .disabled(panel.holdsEdits)
                }
            }
            .task {
                await manager.refresh()
                manager.inspect(source.device, selectionCount: 1)
                await manager.registry.finishReading()
            }
        }
    }
#endif
