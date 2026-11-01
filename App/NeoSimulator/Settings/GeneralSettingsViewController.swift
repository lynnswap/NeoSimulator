import AppKit
import SwiftUI
@_spi(NeoSimulator) import XcodeSimulatorHost

@MainActor
final class GeneralSettingsViewController: SettingsHostingController<GeneralSettingsView> {
    init(model: SimulatorManagerModel, preferences: SimulatorPreferences, frameworks: UIFrameworkSettings,
         restart: @escaping () -> Void) {
        super.init(rootView: GeneralSettingsView(model: model, preferences: preferences, frameworks: frameworks, restart: restart))
        title = "General"
        sizingOptions = [.standardBounds, .preferredContentSize]
    }
    required init?(coder: NSCoder) { nil }
}

struct GeneralSettingsView: View {
    let model: SimulatorManagerModel
    @Bindable var preferences: SimulatorPreferences
    let frameworks: UIFrameworkSettings
    let restart: () -> Void
    @State private var confirmsRestore = false

    var body: some View {
        Form {
            Section("Display") {
                Picker("Display Host", selection: Binding(
                    get: { model.status?.host ?? .neo }, set: { model.select($0) }
                )) {
                    Text("NeoSimulator").tag(SimulatorHost.neo)
                    Text("Device Hub").tag(SimulatorHost.deviceHub)
                }
                .disabled(model.isBusy || model.status == nil)
                Picker("UI Frameworks", selection: Binding(
                    get: { frameworks.selectedXcodeURL }, set: { frameworks.select($0) }
                )) {
                    Text("Default (xcode-select)").tag(URL?.none)
                    ForEach(frameworks.installations, id: \.url) { xcode in
                        Text("\(xcode.name) (\(xcode.version))").tag(Optional(xcode.url))
                    }
                    if let selected = frameworks.selectedXcodeURL,
                       !frameworks.installations.contains(where: { $0.url == selected }) {
                        Text(selected.deletingPathExtension().lastPathComponent).tag(Optional(selected))
                    }
                }
                .disabled(frameworks.isLoading || model.isBusy)
                Text(frameworkMessage)
                    .foregroundStyle(.secondary)
                if frameworks.needsRestart {
                    Button("Restart to Apply", action: restart).disabled(model.isBusy)
                }
            }
            Section("Startup and Windows") {
                Toggle("Start the last used simulator on launch", isOn: $preferences.startLastDevice)
                Toggle("Keep simulators running when closing a window", isOn: $preferences.keepRunningOnWindowClose)
                Toggle("Keep simulators running when quitting NeoSimulator", isOn: $preferences.keepRunningOnQuit)
            }
            Section("Touch Indicators") {
                Toggle("Show single touches", isOn: $preferences.showSingleTouches)
                Toggle("Show pinch gestures", isOn: $preferences.showPinches)
            }
            Section {
                Button("Restore Original Settings…") { confirmsRestore = true }
                    .disabled(model.isBusy || model.status?.restorationAvailable != true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .confirmationDialog("Restore original settings?", isPresented: $confirmsRestore) {
            Button("Restore", role: .destructive) { model.restoreDefaults() }
        } message: {
            Text("Restore the routing settings saved before NeoSimulator first changed them. Your simulator devices are kept.")
        }
    }

    private var frameworkMessage: String {
        if let issue = frameworks.issue { return issue }
        return frameworks.needsRestart
            ? String(localized: "Restart NeoSimulator to apply this change. Simulators will keep running.")
            : String(localized: "Uses the selected Xcode's display frameworks. Simulator runtimes are selected independently.")
    }
}

#if DEBUG
#Preview("General", traits: .sizeThatFitsLayout) {
    GeneralSettingsViewController(model: SettingsPreview.manager(), preferences: SettingsPreview.preferences(),
        frameworks: SettingsPreview.frameworks(), restart: {})
}
#endif
