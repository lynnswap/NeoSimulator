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
            let pairingDevice: SimulatorHostDevice? = if case .simulator(let simulator) = device,
                simulator.productFamily == "iPhone" || simulator.productFamily == "Apple Watch" {
                simulator
            } else { nil }
            Form {
                if editsVisibility {
                    visibilityEditor(information)
                } else {
                    informationCards(information, includesPairing: pairingDevice != nil)
                    if let simulator = pairingDevice {
                        pairedSimulators(simulator)
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
    private func informationCards(_ information: DeviceInformation, includesPairing: Bool) -> some View {
        let visibleFields = information.fields.filter { visibility.isVisible($0) }
        let groups = DeviceInformation.Group.allCases.filter { group in visibleFields.contains { $0.group == group } }
        ForEach(groups) { group in
            Section {
                informationRows(visibleFields.filter { $0.group == group })
            } footer: {
                if !includesPairing && group == groups.last { editVisibilityButton }
            }
        }
        if groups.isEmpty && !includesPairing {
            Section {} footer: { editVisibilityButton }
        }
    }

    private var editVisibilityButton: some View {
        HStack {
            Spacer()
            Button { editsVisibility = true } label: {
                Text("Edit Visibility")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .background(.quaternary, in: Capsule())
            Spacer()
        }
        .padding(.vertical)
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
            .foregroundStyle(.secondary)
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
        return Section {
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
                VStack(spacing: 0) {
                    Divider()
                    HStack {
                        DeviceMenuButton(menu: pairingMenu(device), symbol: "plus", label: "Add Paired Simulator")
                            .disabled(!manager.canAddPairing(for: device) || inspection.isManaging ||
                                      !manager.canManage(.pair, deviceIDs: [device.inventoryID]))
                        Divider()
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
                    .fixedSize(horizontal: false, vertical: true)
                    .buttonStyle(.accessoryBar)
                    .controlSize(.small)
                }
                .background(.bar)
            }
        } header: {
            Text("Paired Simulators")
        } footer: {
            editVisibilityButton
        }
    }

    private struct InformationRowStyle: LabeledContentStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(alignment: .firstTextBaseline) {
                configuration.label
                    .lineLimit(1)
                    .layoutPriority(1)
                configuration.content
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
