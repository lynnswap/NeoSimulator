#if DEBUG
import AppKit
import SwiftUI

@MainActor
final class DebugSettingsViewController: NSHostingController<DebugSettingsView> {
    init(model: SimulatorManagerModel, resetOnboarding: @escaping () -> Void) {
        super.init(rootView: DebugSettingsView(model: model, resetOnboarding: resetOnboarding))
        title = "Debug"
        sizingOptions = [.preferredContentSize]
    }

    required init?(coder: NSCoder) { nil }
}

struct DebugSettingsView: View {
    let model: SimulatorManagerModel
    let resetOnboarding: () -> Void

    var body: some View {
        Form {
            Section("Onboarding") {
                Button("Reset Onboarding…", role: .destructive, action: resetOnboarding)
                    .disabled(model.isBusy)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }
}

#Preview("Debug", traits: .sizeThatFitsLayout) {
    DebugSettingsViewController(model: SettingsPreview.manager(), resetOnboarding: {})
}
#endif
