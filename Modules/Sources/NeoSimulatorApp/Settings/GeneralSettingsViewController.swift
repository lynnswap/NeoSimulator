import NeoSimulatorKit
import NeoSimulatorHostSupport
import AppKit
import SwiftUI

@MainActor
final class GeneralSettingsViewController: NSHostingController<GeneralSettingsView> {
    let model: GeneralSettingsModel

    init(model: SimulatorManagerModel, preferences: SimulatorPreferences, frameworks: UIFrameworkSettings,
         restart: @escaping () -> Void) {
        self.model = GeneralSettingsModel(manager: model, preferences: preferences, frameworks: frameworks, restart: restart)
        super.init(rootView: GeneralSettingsView(model: self.model))
        title = "General"
        sizingOptions = [.standardBounds, .preferredContentSize]
    }
    required init?(coder: NSCoder) { nil }
}

struct GeneralSettingsView: View {
    @Bindable var model: GeneralSettingsModel

    var body: some View {
        @Bindable var preferences = model.preferences
        let frameworks = model.frameworks
        Form {
            Section("Display") {
                Picker("Preferred Display Host", selection: $model.preferredHost) {
                    Text("NeoSimulator").tag(SimulatorHost.neo)
                    Text("Device Hub").tag(SimulatorHost.deviceHub)
                }
                .disabled(!model.canSelectHost)
                Text("NeoSimulator displays simulators while it is open. Your selected display host is kept after you quit. Choose Device Hub to use it for future Xcode runs.")
                    .foregroundStyle(.secondary)
                if model.offersNeoHost {
                    Button("Use NeoSimulator", action: model.useNeoHost)
                        .disabled(!model.canSelectHost)
                }
                Picker("UI Frameworks", selection: $model.selectedXcodeURL) {
                    Text("Default (xcode-select)").tag(URL?.none)
                    ForEach(frameworks.installations, id: \.url) { xcode in
                        Text("\(xcode.name) (\(xcode.version))").tag(Optional(xcode.url))
                    }
                    if let selected = model.missingXcodeURL {
                        Text(selected.deletingPathExtension().lastPathComponent).tag(Optional(selected))
                    }
                }
                .disabled(!model.canSelectFrameworks)
                Text(model.frameworkMessage)
                    .foregroundStyle(.secondary)
                if frameworks.needsRestart {
                    Button("Restart to Apply", action: model.restart).disabled(!model.canRestart)
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
                Button("Restore Original Settings…", role: .destructive) { model.confirmsRestore = true }
                    .disabled(!model.canRestore)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .confirmationDialog("Restore original settings?", isPresented: $model.confirmsRestore) {
            Button("Restore", role: .destructive) { model.restoreDefaults() }
        } message: {
            Text("Restore the routing settings saved before NeoSimulator first changed them. Your simulator devices are kept.")
        }
    }
}

#if DEBUG
#Preview("General", traits: .sizeThatFitsLayout) {
    GeneralSettingsViewController(model: SettingsPreview.manager(), preferences: SettingsPreview.preferences(),
        frameworks: SettingsPreview.frameworks(), restart: {})
}
#endif
