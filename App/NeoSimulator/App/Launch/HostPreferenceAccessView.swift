import SwiftUI

struct HostPreferenceAccessView: View {
    let copyCommandAndQuit: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Allow Access to Device Hub Settings")
                .font(.headline)
            Text("macOS couldn’t grant the access NeoSimulator needs to change the simulator display host.")
            Text(HostPreferenceAccess.Failure.recoveryCommand)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            Text("Copy the command and quit. Run it in Terminal, then reopen NeoSimulator and allow access when macOS asks.")
            HStack {
                Spacer()
                Button("Not Now", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Copy Command and Quit", action: copyCommandAndQuit)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(24)
        .frame(width: 560)
    }
}

#Preview("Device Hub Settings Access") {
    HostPreferenceAccessView(copyCommandAndQuit: {}, cancel: {})
}
