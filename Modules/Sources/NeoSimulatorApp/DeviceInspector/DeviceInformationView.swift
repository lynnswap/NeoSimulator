import NeoSimulatorKit
import NeoSimulatorHostSupport
@_spi(NeoSimulator) import XcodeSimulatorHost
import AppKit
import SwiftUI

@MainActor
struct DeviceInformationView: View {
    @Bindable var model: DeviceInformationModel

    var body: some View {
        if let information = model.information {
            Group {
                if model.editsVisibility {
                    Form { visibilityEditor(information) }
                        .formStyle(.grouped)
                } else {
                    Form {
                        informationCards(information, includesPairing: model.pairingDevice != nil)
                        if model.pairingDevice != nil { pairedSimulators }
                    }
                    .formStyle(InformationFormStyle())
                }
            }
            .safeAreaBar(edge: .bottom, spacing: 0) {
                if model.editsVisibility {
                    Button("Done") { model.editsVisibility = false }
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
        ForEach(model.visibleGroups) { group in
            Section {
                informationRows(group.fields)
            } footer: {
                if !includesPairing && group.id == model.visibleGroups.last?.id { editVisibilityButton }
            }
        }
        if model.visibleGroups.isEmpty && !includesPairing {
            Section {} footer: { editVisibilityButton }
        }
    }

    private var editVisibilityButton: some View {
        HStack {
            Spacer()
            Button { model.editsVisibility = true } label: {
                Text("Edit Visibility")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 10)
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
            .foregroundStyle(Color.secondary)
            .textSelection(.enabled)
            .multilineTextAlignment(.trailing)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(field.value)
    }

    @ViewBuilder
    private func visibilityEditor(_ information: DeviceInformation) -> some View {
        @Bindable var visibility = model.visibility
        ForEach(DeviceInformation.Group.allCases) { group in
            let fields = information.fields.filter { $0.group == group }
            if !fields.isEmpty {
                Section(group.title) {
                    ForEach(fields) { field in
                        LabeledContent {
                            fieldValue(field)
                        } label: {
                            Toggle(field.title, isOn: $visibility[visible: field])
                            .toggleStyle(.checkbox)
                        }
                        .labeledContentStyle(InformationRowStyle())
                    }
                }
            }
        }
    }

    private var pairedSimulators: some View {
        Section {} header: {
            Text("Paired Simulators")
        } footer: {
            GroupBox {
                VStack(spacing: 0) {
                    PairedSimulatorsView(devices: model.pairedSimulators, selection: $model.selectedPairedSimulator,
                        emptyLabel: model.emptyPairingLabel, menu: model.deviceMenu)
                    .frame(maxWidth: .infinity)
                    Divider()
                    HStack(spacing: 0) {
                        DeviceMenuButton(menu: model.pairingMenu(), symbol: "plus", label: "Add Paired Simulator", isBordered: false)
                            .disabled(!model.canAddPairing)
                        Divider()
                            .padding(.vertical, 4)
                        Button(role: .destructive, action: model.removePairing) {
                            PairingAccessoryLabel(symbol: "minus")
                        }
                        .accessibilityLabel("Remove Paired Simulator")
                        .disabled(!model.canRemovePairing)
                        Spacer()
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .buttonStyle(.borderless)
                    .controlSize(.regular)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial)
                }
            }
            .groupBoxStyle(InformationCardStyle())
            editVisibilityButton
        }
    }

    private struct PairingAccessoryLabel: View {
        static let minimumDimension: CGFloat = 24
        let symbol: String

        var body: some View {
            Image(systemName: symbol)
                .font(.system(.subheadline, weight: .semibold))
                .frame(minWidth: Self.minimumDimension, minHeight: Self.minimumDimension)
        }
    }

    private struct InformationFormStyle: FormStyle {
        func makeBody(configuration: Configuration) -> some View {
            ScrollView {
                VStack(alignment: .leading) {
                    ForEach(sections: configuration.content) { section in
                        if !section.header.isEmpty {
                            section.header
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.secondary)
                                .accessibilityAddTraits(.isHeader)
                        }
                        if !section.content.isEmpty {
                            GroupBox {
                                VStack(spacing: 0) {
                                    ForEach(subviews: section.content) { row in
                                        row.padding(10)
                                        if row.id != section.content.last?.id {
                                            Divider().padding(.horizontal, 10)
                                        }
                                    }
                                }
                            }
                            .groupBoxStyle(InformationCardStyle())
                        }
                        section.footer
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }
        }
    }

    private struct InformationCardStyle: GroupBoxStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.content
                .font(.body)
                .foregroundStyle(Color.primary)
                .background(Color(nsColor: .quaternarySystemFill))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .contain)
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
        var isBordered = true

        func makeNSView(context: Context) -> NSPopUpButton {
            let configuration = NSImage.SymbolConfiguration(
                pointSize: NSFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .semibold)
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)!
            let button = NSPopUpButton(image: image, pullDownMenu: menu)
            button.symbolConfiguration = configuration
            button.controlSize = controlSize(context.environment.controlSize)
            button.bezelStyle = .accessoryBarAction
            button.isBordered = isBordered
            (button.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
            button.isEnabled = context.environment.isEnabled
            button.setAccessibilityLabel(label)
            button.toolTip = menu.title
            return button
        }

        func updateNSView(_ button: NSPopUpButton, context: Context) {
            button.menu = menu
            button.controlSize = controlSize(context.environment.controlSize)
            button.isBordered = isBordered
            button.isEnabled = context.environment.isEnabled
            button.setAccessibilityLabel(label)
            button.toolTip = menu.title
        }

        func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> NSSize? {
            let size = nsView.fittingSize
            return NSSize(width: max(size.width, PairingAccessoryLabel.minimumDimension),
                          height: max(size.height, PairingAccessoryLabel.minimumDimension))
        }

        private func controlSize(_ size: SwiftUI.ControlSize) -> NSControl.ControlSize {
            switch size {
            case .mini: .mini
            case .small: .small
            case .regular: .regular
            case .large: .large
            case .extraLarge: .extraLarge
            @unknown default: .regular
            }
        }
    }
}
