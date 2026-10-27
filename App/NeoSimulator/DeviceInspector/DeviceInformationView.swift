import AppKit
import SwiftUI
import XcodeSimulatorHost

@MainActor
struct DeviceInformationView: View {
    let manager: SimulatorManagerModel
    let inspection: DeviceInspectorModel
    let visibility: DeviceInfoVisibility
    let pairingMenu: (SimulatorHostDevice) -> NSMenu
    let unpair: (_ targetWatch: SimulatorHostDevice) -> Void

    @State private var editsVisibility = false
    @State private var selectedPairedSimulator: DeviceInventoryID?

    var body: some View {
        if let device = inspection.device {
            let information = DeviceInformation(device: device, properties: inspection.infoProperties)
            VStack(spacing: 0) {
                Form {
                    if editsVisibility {
                        visibilityEditor(information)
                    } else {
                        informationCards(information)
                        if case .simulator(let simulator) = device,
                           simulator.productFamily == "iPhone" || simulator.productFamily == "Apple Watch" {
                            pairedSimulators(simulator)
                        }
                    }
                }
                .formStyle(.grouped)
                HStack {
                    Spacer()
                    if editsVisibility {
                        Button("Done") { editsVisibility = false }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button("Edit Visibility") { editsVisibility = true }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                    }
                    Spacer()
                }
                .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder
    private func informationCards(_ information: DeviceInformation) -> some View {
        ForEach(DeviceInformation.Group.allCases) { group in
            let fields = information.fields.filter { $0.group == group && visibility.isVisible($0) }
            if !fields.isEmpty {
                Section { informationRows(fields) }
            }
        }
    }

    private func informationRows(_ fields: [DeviceInformation.Field]) -> some View {
        ForEach(fields) { field in
            LabeledContent(field.title) {
                Text(field.value)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    @ViewBuilder
    private func visibilityEditor(_ information: DeviceInformation) -> some View {
        ForEach(DeviceInformation.Group.allCases) { group in
            let fields = information.fields.filter { $0.group == group }
            if !fields.isEmpty {
                Section(group.title) {
                    ForEach(fields) { field in
                        Toggle(field.title, isOn: Binding(
                            get: { visibility.isVisible(field) },
                            set: { visibility.setVisible($0, for: field) }
                        ))
                        .toggleStyle(.checkbox)
                    }
                }
            }
        }
    }

    private func pairedSimulators(_ device: SimulatorHostDevice) -> some View {
        let paired = DeviceInformation.pairedSimulators(for: device, in: manager.inventory)
        let selectedPartner = paired.first { $0.inventoryID == selectedPairedSimulator }
        let targetWatch = selectedPartner.flatMap { DeviceInformation.watchToUnpair(device: device, partner: $0) }
        return Section("Paired Simulators") {
            VStack(alignment: .leading, spacing: 0) {
                if paired.isEmpty {
                    Text(device.productFamily == "Apple Watch" ? "No Paired iPhone Simulators" : "No Paired Watch Simulators")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 128, maxHeight: 128, alignment: .center)
                } else {
                    List(selection: $selectedPairedSimulator) {
                        ForEach(paired, id: \.inventoryID) { partner in
                            HStack(spacing: 8) {
                                Image(systemName: partner.productFamily == "Apple Watch" ? "applewatch" : "iphone")
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(partner.name)
                                    Text(partner.runtimeName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .tag(partner.inventoryID)
                        }
                    }
                    .listStyle(.plain)
                    .frame(height: max(128, CGFloat(min(paired.count, 3)) * 44))
                }
                Divider()
                HStack(spacing: 4) {
                    PairingMenuButton(menu: pairingMenu(device))
                        .disabled(!manager.canAddPairing(for: device) || inspection.isManaging ||
                                  !manager.canManage(.pair, deviceIDs: [device.inventoryID]))
                        .frame(width: 34, height: 24)
                    Button {
                        if let targetWatch { unpair(targetWatch) }
                    } label: {
                        Image(systemName: "minus")
                    }
                    .accessibilityLabel("Remove Paired Simulator")
                    .disabled(targetWatch == nil || inspection.isManaging || manager.isBusy ||
                              targetWatch.map { manager.managingDeviceIDs.contains($0.inventoryID) } == true)
                    Spacer()
                }
                .padding(.top, 4)
            }
        }
    }

    private struct PairingMenuButton: NSViewRepresentable {
        let menu: NSMenu

        func makeNSView(context: Context) -> NSPopUpButton {
            let image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Paired Simulator")!
            let button = NSPopUpButton(image: image, pullDownMenu: menu)
            button.controlSize = .small
            button.isEnabled = context.environment.isEnabled
            button.setAccessibilityLabel("Add Paired Simulator")
            button.toolTip = menu.title
            return button
        }

        func updateNSView(_ button: NSPopUpButton, context: Context) {
            button.menu = menu
            button.isEnabled = context.environment.isEnabled
            button.toolTip = menu.title
        }
    }
}
