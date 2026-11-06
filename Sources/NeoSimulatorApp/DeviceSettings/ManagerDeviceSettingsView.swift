import NeoSimulatorKit
import NeoSimulatorHostSupport
import SwiftUI

struct ManagerDeviceSettingsView: View {
    @Bindable var model: DeviceSettingsPanelModel

    var body: some View {
        switch model.content {
        case .noSelection:
            ContentUnavailableView("Select a Device", systemImage: "slider.horizontal.3",
                description: Text("Select one device to adjust its settings."))
        case .multipleSelection:
            ContentUnavailableView("Multiple Devices Selected", systemImage: "slider.horizontal.3",
                description: Text("Select one device to adjust its settings."))
        case .unavailable:
            ContentUnavailableView("Settings Unavailable", systemImage: "slider.horizontal.3",
                description: Text(model.message ?? "No settings are available for this device."))
                .help(model.issue)
        case .loading:
            ProgressView("Loading settings…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .settings:
            settingsForm
        }
    }

    private var settingsForm: some View {
        Form {
            Section {
                picker("Appearance", symbol: "circle.lefthalf.filled", group: .appearance, value: model.binding(for: \.appearance), choices: model.appearanceChoices)
                slider("Liquid Glass", symbol: "drop.halffull", group: .accessibility, value: model.binding(for: \.liquidGlassOpacity), range: 0...1)
                picker("Color Filter", symbol: "camera.filters", group: .accessibility, value: model.binding(for: \.colorFilter), choices: model.colorFilterChoices)
                if model.colorFilterIntensity != nil {
                    slider("Intensity", symbol: "slider.horizontal.3", group: .accessibility, value: model.binding(for: \.colorFilterIntensity), range: 0.25...1)
                }
                picker("Display Zoom", symbol: "rectangle.inset.filled", group: .displayZoom, value: model.binding(for: \.displayZoom), choices: model.displayZoomChoices)
                    .help("Applying Display Zoom restarts the device's interface.")
                slider("Text Size", symbol: "textformat.size", group: .textSize, value: model.binding(for: \.textSize), range: 0...11,
                       tickMarks: 12, help: model.textSizeDescription)
                toggle("Bold Text", symbol: "bold", group: .boldText, value: model.binding(for: \.boldText))
                toggle("Reduce Motion", symbol: "figure.walk.motion", group: .accessibility, value: model.binding(for: \.reduceMotion))
                slowAnimationsRow
                toggle("Increase Contrast", symbol: "circle.lefthalf.striped.horizontal", group: .contrast, value: model.binding(for: \.increaseContrast))
                toggle("Show Borders", symbol: "square.dashed", group: .accessibility, value: model.binding(for: \.showBorders))
                toggle("Reduce Transparency", symbol: "square.on.square", group: .accessibility, value: model.binding(for: \.reduceTransparency))
                toggle("VoiceOver", symbol: "person.wave.2", group: .voiceOver, value: model.binding(for: \.voiceOver))
            }
            Section {
                LabeledContent {
                    Menu(model.locationTitle) {
                        Button("None", action: model.clearLocation)
                        Button("Custom…", action: model.customLocation)
                        if !model.locationScenarios.isEmpty { Divider() }
                        ForEach(model.locationScenarios, id: \.name) { scenario in
                            Button(scenario.displayName) { model.setLocationScenario(scenario.name) }
                        }
                    }
                    .disabled(!model.locationAvailable)
                } label: {
                    Label("Location", systemImage: "location")
                }
            }
            Section {
                slider("Sound", symbol: "speaker.wave.2", group: .audio, value: model.binding(for: \.volume), range: 0...100)
                picker("Output", symbol: "speaker", group: .audio, value: model.binding(for: \.audioOutput), choices: model.audioOutputChoices)
                picker("Input", symbol: "mic", group: .audio, value: model.binding(for: \.audioInput), choices: model.audioInputChoices)
            }
            if let message = model.message {
                Section { Text(message).font(.caption).foregroundStyle(.secondary).help(model.issue) }
            }
            Section { Button("Refresh", action: model.refresh) }
        }
        .formStyle(.grouped)
        .labelStyle(.titleAndIcon)
        .labelReservedIconWidth(20)
        .disabled(model.holdsEdits)
    }

    @ViewBuilder
    private var slowAnimationsRow: some View {
        switch model.slowAnimationsControl {
        case .hidden:
            EmptyView()
        case .unavailable:
            unavailable("Slow Animations", symbol: "tortoise").help("View this simulator's screen to change slow animations.")
        case .toggle:
            Toggle(isOn: $model.slowAnimations) { Label("Slow Animations", systemImage: "tortoise") }
                .toggleStyle(.switch)
                .disabled(!model.canChangeSlowAnimations)
        case .button:
            LabeledContent {
                Button("Toggle", action: model.toggleSlowAnimations).disabled(!model.canChangeSlowAnimations)
            } label: {
                Label("Slow Animations", systemImage: "tortoise")
            }
            .help("Toggle slow animations in the frontmost app.")
        }
    }

    @ViewBuilder
    private func picker(_ title: String, symbol: String, group: DeviceSettingsGroup, value: Binding<String>?, choices: [DeviceSettingsPanelModel.Choice]) -> some View {
        if let value {
            Picker(selection: value) {
                if !choices.contains(where: { $0.id == value.wrappedValue }) { Text("Unavailable").tag(value.wrappedValue) }
                ForEach(choices) { Text($0.title).tag($0.id) }
            } label: { Label(title, systemImage: symbol) }
            .disabled(choices.isEmpty)
            .buttonStyle(.borderless)
        } else {
            placeholder(title, symbol: symbol, group: group)
        }
    }

    @ViewBuilder
    private func toggle(_ title: String, symbol: String, group: DeviceSettingsGroup, value: Binding<Bool>?) -> some View {
        if let value {
            Toggle(isOn: value) { Label(title, systemImage: symbol) }.toggleStyle(.switch)
        } else {
            placeholder(title, symbol: symbol, group: group)
        }
    }

    @ViewBuilder
    private func slider(_ title: String, symbol: String, group: DeviceSettingsGroup, value: Binding<Double>?, range: ClosedRange<Double>,
                        tickMarks: Int = 0, help: String = "") -> some View {
        if let value {
            LabeledContent {
                ManagerSettingSlider(value: value.wrappedValue, range: range, tickMarks: tickMarks, label: title,
                                     changed: { value.wrappedValue = $0 })
                    .frame(minWidth: 90, maxWidth: .infinity, minHeight: 22)
                    .help(help)
            } label: {
                Label(title, systemImage: symbol).layoutPriority(1)
            }
        } else {
            placeholder(title, symbol: symbol, group: group)
        }
    }

    private func placeholder(_ title: String, symbol: String, group: DeviceSettingsGroup) -> some View {
        LabeledContent { Text(model.placeholder(for: group)).foregroundStyle(.secondary) } label: { Label(title, systemImage: symbol) }
    }

    private func unavailable(_ title: String, symbol: String) -> some View {
        LabeledContent { Text("Unavailable").foregroundStyle(.secondary) } label: { Label(title, systemImage: symbol) }
    }
}
