import SwiftUI

enum DeviceCommand: String {
    case home, lock, keyboard, screenshot, rotateLeft, rotateRight
    case shake, appearance, bezel, stayOnTop, fit, shutdown
}

@MainActor @Observable
final class DeviceToolbarState {
    var isBusy = false
    var isConnected = true
}

struct DeviceToolbar: View {
    let title: String
    let state: DeviceToolbarState
    let perform: (DeviceCommand) -> Void

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, 80)
                .padding(.trailing, 16)
                .frame(maxWidth: .infinity)
                .gesture(WindowDragGesture())
                .allowsWindowActivationEvents()
            HStack(spacing: 4) {
                control("Home", symbol: "house", command: .home)
                control("Save Screen", symbol: "camera.on.rectangle", command: .screenshot, usesTool: true)
                control("Rotate Right", symbol: "rotate.right", command: .rotateRight, usesTool: true)
                control("Software Keyboard", symbol: "keyboard", command: .keyboard)
                Menu {
                    Button("Lock") { perform(.lock) }
                    Button("Shake") { perform(.shake) }
                    Button("Toggle Appearance") { perform(.appearance) }
                    Divider()
                    Button("Show or Hide Device Bezels") { perform(.bezel) }
                    Button("Stay On Top") { perform(.stayOnTop) }
                    Button("Fit Screen") { perform(.fit) }
                    Divider()
                    Button("Shut Down") { perform(.shutdown) }.disabled(state.isBusy)
                } label: {
                    Image(systemName: "ellipsis").frame(width: 28, height: 24)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More Device Controls")
            }
            .buttonStyle(.borderless)
            .controlSize(.large)
            .disabled(!state.isConnected)
        }
        .padding(.top, 9)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func control(_ title: String, symbol: String, command: DeviceCommand, usesTool: Bool = false) -> some View {
        Button { perform(command) } label: {
            Image(systemName: symbol).frame(width: 32, height: 26)
        }
        .help(title)
        .accessibilityLabel(title)
        .disabled(usesTool && state.isBusy)
    }
}

#Preview("Device Controls") {
    DeviceToolbar(title: "iPhone 17 Pro – iOS 27.0", state: DeviceToolbarState(), perform: { _ in })
        .frame(width: 360, height: 74)
}

#Preview("Busy Device") {
    let state = DeviceToolbarState()
    state.isBusy = true
    return DeviceToolbar(title: "iPad Pro – iPadOS 27.0", state: state, perform: { _ in })
        .frame(width: 360, height: 74)
}
