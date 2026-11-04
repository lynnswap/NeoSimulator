import AppKit
import SwiftUI

@MainActor
final class CaptureSettingsViewController: NSHostingController<CaptureSettingsView> {
    init(preferences: SimulatorPreferences) {
        super.init(rootView: CaptureSettingsView(preferences: preferences))
        title = "Capture"
        sizingOptions = [.standardBounds, .preferredContentSize]
    }
    required init?(coder: NSCoder) { nil }
}

struct CaptureSettingsView: View {
    @Bindable var preferences: SimulatorPreferences

    var body: some View {
        Form {
            Toggle("Include device mask in screenshots and videos", isOn: $preferences.includeDeviceMask)
            Section("Animated GIFs") {
                Picker("Image Size", selection: $preferences.gifImageSize) {
                    Text("Small (320 px)").tag(320)
                    Text("Medium (640 px)").tag(640)
                    Text("Large (1280 px)").tag(1280)
                }
                Picker("Optimize For", selection: $preferences.gifFrameRate) {
                    Text("Smaller file size").tag(10)
                    Text("Smoother animation").tag(15)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }
}

#if DEBUG
#Preview("Capture", traits: .sizeThatFitsLayout) {
    CaptureSettingsViewController(preferences: SettingsPreview.preferences())
}
#endif
