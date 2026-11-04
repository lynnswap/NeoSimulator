import NeoSimulatorKit
import NeoSimulatorHostSupport
@_spi(NeoSimulator) import XcodeSimulatorHost
import SwiftUI

struct HostPreferenceAccessView: View {
    let copyCommand: () -> Void
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
            Text("Copy this command and run it in Terminal. Then reopen NeoSimulator to request access again.")
            HStack {
                Spacer()
                Button("Close", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Copy Command", action: copyCommand)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(24)
        .frame(width: 560)
    }
}

#Preview("Device Hub Settings Access") {
    HostPreferenceAccessView(copyCommand: {}, cancel: {})
}
