import AppKit
import SwiftUI
import XcodeSimulatorHost

@MainActor
struct DeviceInformationView: View {
    let manager: SimulatorManagerModel
    let inspection: DeviceInspectorModel
    let visibility: DeviceInfoVisibility
    let pairingMenu: (SimulatorHostDevice) -> NSMenu
    let deviceMenu: (SimulatorHostDevice) -> NSMenu
    let unpair: (_ targetWatch: SimulatorHostDevice) -> Void

    @State private var editsVisibility = false
    @State private var selectedPairedSimulator: DeviceInventoryID?

    var body: some View {
        if let device = inspection.device {
            let information = DeviceInformation(device: device, properties: inspection.infoProperties)
            Form {
                if editsVisibility {
                    visibilityEditor(information)
                } else {
                    informationCards(information)
                    if case .simulator(let simulator) = device,
                       simulator.productFamily == "iPhone" || simulator.productFamily == "Apple Watch" {
                        pairedSimulators(simulator)
                    }
                    HStack {
                        Spacer()
                        Button("Edit Visibility") { editsVisibility = true }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                        Spacer()
                    }
                }
            }
            .formStyle(.grouped)
            .safeAreaBar(edge: .bottom, spacing: 0) {
                if editsVisibility {
                    Button("Done") { editsVisibility = false }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .buttonSizing(.flexible)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .padding()
                }
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
                fieldValue(field)
            }
            .labeledContentStyle(InformationRowStyle())
        }
    }

    private func fieldValue(_ field: DeviceInformation.Field) -> some View {
        Text(field.value)
            .textSelection(.enabled)
            .multilineTextAlignment(.trailing)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(field.value)
    }

    @ViewBuilder
    private func visibilityEditor(_ information: DeviceInformation) -> some View {
        ForEach(DeviceInformation.Group.allCases) { group in
            let fields = information.fields.filter { $0.group == group }
            if !fields.isEmpty {
                Section(group.title) {
                    ForEach(fields) { field in
                        LabeledContent {
                            fieldValue(field)
                        } label: {
                            Toggle(field.title, isOn: Binding(
                                get: { visibility.isVisible(field) },
                                set: { visibility.setVisible($0, for: field) }
                            ))
                            .toggleStyle(.checkbox)
                        }
                        .labeledContentStyle(InformationRowStyle())
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
            Group {
                if paired.isEmpty {
                    Text(device.productFamily == "Apple Watch" ? "No Paired iPhone Simulators" : "No Paired Watch Simulators")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 120)
                } else {
                    List(selection: $selectedPairedSimulator) {
                        ForEach(paired, id: \.inventoryID) { partner in
                            LabeledContent {
                                DeviceMenuButton(menu: deviceMenu(partner), symbol: "ellipsis",
                                                 label: "More Actions for \(partner.name)")
                            } label: {
                                Text(partner.name)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(partner.name)
                            }
                            .tag(partner.inventoryID)
                        }
                    }
                    .listStyle(.plain)
                    .frame(maxWidth: .infinity)
                }
            }
            .safeAreaBar(edge: .bottom, spacing: 0) {
                HStack {
                    DeviceMenuButton(menu: pairingMenu(device), symbol: "plus", label: "Add Paired Simulator")
                        .disabled(!manager.canAddPairing(for: device) || inspection.isManaging ||
                                  !manager.canManage(.pair, deviceIDs: [device.inventoryID]))
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
                .buttonStyle(.accessoryBar)
                .controlSize(.small)
            }
        }
    }

    private struct InformationRowStyle: LabeledContentStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(alignment: .firstTextBaseline) {
                configuration.label
                    .lineLimit(1)
                    .layoutPriority(1)
                configuration.content
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private struct DeviceMenuButton: NSViewRepresentable {
        let menu: NSMenu
        let symbol: String
        let label: String

        func makeNSView(context: Context) -> NSPopUpButton {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)!
            let button = NSPopUpButton(image: image, pullDownMenu: menu)
            button.controlSize = .small
            button.bezelStyle = .accessoryBarAction
            button.isBordered = false
            (button.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
            button.isEnabled = context.environment.isEnabled
            button.setAccessibilityLabel(label)
            button.toolTip = menu.title
            return button
        }

        func updateNSView(_ button: NSPopUpButton, context: Context) {
            button.menu = menu
            button.isEnabled = context.environment.isEnabled
            button.setAccessibilityLabel(label)
            button.toolTip = menu.title
        }

        func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> NSSize? {
            nsView.fittingSize
        }
    }
}
