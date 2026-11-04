import AppKit
import LicenseList
import ObservationBridge
import SwiftUI

@MainActor
final class LicensesSettingsViewController: NSSplitViewController, NSTableViewDataSource, NSTableViewDelegate {
    let model: LicensesSettingsModel
    private let table = NSTableView()
    private var observation: PortableObservationTracking.Token?

    init(model: LicensesSettingsModel = LicensesSettingsModel()) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        title = "Licenses"
        preferredContentSize = NSSize(width: 720, height: 520)
    }
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        super.loadView()
        view.frame = NSRect(origin: .zero, size: preferredContentSize)
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        table.addTableColumn(NSTableColumn(identifier: .init("Library")))
        table.headerView = nil
        table.style = .inset
        table.backgroundColor = .clear
        table.rowHeight = 32
        table.dataSource = self
        table.delegate = self
        table.allowsEmptySelection = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.setAccessibilityLabel("Libraries")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let sidebar = NSViewController()
        sidebar.view = LicenseSettingsPane()
        sidebar.view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: sidebar.view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: sidebar.view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: sidebar.view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: sidebar.view.bottomAnchor),
        ])
        let sidebarItem = NSSplitViewItem(viewController: sidebar)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 300
        sidebarItem.preferredThicknessFraction = 0.28
        addSplitViewItem(sidebarItem)
        let detail = NSHostingController(rootView: LicenseDetails(model: model))
        detail.sizingOptions = []
        addSplitViewItem(NSSplitViewItem(viewController: detail))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        table.reloadData()
        observation = withPortableContinuousObservation { [weak self] _ in
            guard let self, let selected = model.selectedLibrary,
                  let row = model.libraries.firstIndex(where: { $0.id == selected.id }),
                  table.selectedRow != row else { return }
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { model.libraries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("LibraryCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
        if cell.textField == nil {
            cell.identifier = identifier
            let label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingTail
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        cell.textField?.stringValue = model.libraries[row].name
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard model.libraries.indices.contains(table.selectedRow) else { return }
        model.selectedLibrary = model.libraries[table.selectedRow]
    }
}

private struct LicenseDetails: View {
    let model: LicensesSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let issue = model.issue {
                Text("Unable to load the simslim license: " + issue)
                    .foregroundStyle(.secondary)
                    .padding()
            }
            if let library = model.selectedLibrary {
                if let url = library.url {
                    Link(url.absoluteString, destination: url)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding()
                    Divider()
                }
                LicenseView(library: library)
                    .licenseViewStyle(.plain)
                    .textSelection(.enabled)
                    .id(library.id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private final class LicenseSettingsPane: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

#if DEBUG
private struct LicensePreview: NSViewControllerRepresentable {
    let makeController: () -> LicensesSettingsViewController
    func makeNSViewController(context: Context) -> LicensesSettingsViewController { makeController() }
    func updateNSViewController(_ controller: LicensesSettingsViewController, context: Context) {}
}

#Preview("Licenses") {
    LicensePreview { LicensesSettingsViewController() }
        .frame(width: 720, height: 520)
}
#endif
