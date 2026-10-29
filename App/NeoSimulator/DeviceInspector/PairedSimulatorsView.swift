import AppKit
import SwiftUI
import XcodeSimulatorHost

@MainActor
struct PairedSimulatorsView: NSViewRepresentable {
    private static let minimumPartnerRowHeight: CGFloat = 40
    let devices: [SimulatorHostDevice]
    @Binding var selection: DeviceInventoryID?
    let emptyLabel: String
    let menu: (SimulatorHostDevice) -> NSMenu

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ScrollView {
        let view = ScrollView()
        view.table.dataSource = context.coordinator
        view.table.delegate = context.coordinator
        context.coordinator.scrollView = view
        NotificationCenter.default.addObserver(context.coordinator,
            selector: #selector(Coordinator.tableFrameChanged(_:)),
            name: NSView.frameDidChangeNotification, object: view.table)
        context.coordinator.update(self, in: view)
        return view
    }

    func updateNSView(_ view: ScrollView, context: Context) {
        context.coordinator.update(self, in: view)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ScrollView, context: Context) -> NSSize? {
        nsView.table.layoutSubtreeIfNeeded()
        return NSSize(width: proposal.width ?? nsView.frame.width,
                      height: nsView.intrinsicContentSize.height)
    }

    static func dismantleNSView(_ view: ScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator,
            name: NSView.frameDidChangeNotification, object: view.table)
        view.table.delegate = nil
        view.table.dataSource = nil
    }

    final class ScrollView: NSScrollView {
        let table = NSTableView()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Partner")))
            table.headerView = nil
            table.style = .plain
            table.rowSizeStyle = .custom
            table.usesAutomaticRowHeights = true
            table.allowsEmptySelection = true
            table.allowsMultipleSelection = false
            table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
            table.backgroundColor = .clear
            table.postsFrameChangedNotifications = true
            table.setAccessibilityLabel("Paired Simulators")
            documentView = table
            hasVerticalScroller = true
            autohidesScrollers = true
            drawsBackground = false
            borderType = .noBorder
            automaticallyAdjustsContentInsets = false
        }

        required init?(coder: NSCoder) { nil }

        override var intrinsicContentSize: NSSize {
            let height = table.numberOfRows == 0 ? 0 : table.rect(ofRow: table.numberOfRows - 1).maxY
            let frame = NSScrollView.frameSize(
                forContentSize: NSSize(width: 0, height: height + contentInsets.top + contentInsets.bottom),
                horizontalScrollerClass: nil,
                verticalScrollerClass: verticalScroller.map { type(of: $0) },
                borderType: borderType,
                controlSize: verticalScroller?.controlSize ?? .regular,
                scrollerStyle: scrollerStyle)
            return NSSize(width: NSView.noIntrinsicMetric, height: frame.height)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private var view: PairedSimulatorsView
        private var updating = false
        weak var scrollView: ScrollView?

        init(_ view: PairedSimulatorsView) { self.view = view }

        func update(_ view: PairedSimulatorsView, in scroll: ScrollView) {
            self.view = view
            updating = true
            defer { updating = false }
            let table = scroll.table
            table.reloadData()
            for row in 0..<table.numberOfRows {
                _ = table.view(atColumn: 0, row: row, makeIfNecessary: true)
            }
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<table.numberOfRows))
            table.layoutSubtreeIfNeeded()
            if let selection = view.selection, let row = view.devices.firstIndex(where: { $0.inventoryID == selection }) {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            } else {
                table.deselectAll(nil)
            }
            scroll.invalidateIntrinsicContentSize()
        }

        func numberOfRows(in tableView: NSTableView) -> Int { max(view.devices.count, 1) }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            if view.devices.isEmpty {
                let identifier = NSUserInterfaceItemIdentifier("Empty")
                let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? EmptyCell ?? EmptyCell()
                cell.identifier = identifier
                cell.textField?.stringValue = view.emptyLabel
                return cell
            }
            let identifier = NSUserInterfaceItemIdentifier("Partner")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? PartnerCell ?? PartnerCell()
            cell.identifier = identifier
            let device = view.devices[row]
            cell.title.stringValue = device.name
            cell.title.toolTip = device.name
            cell.more.menu = view.menu(device)
            cell.more.toolTip = cell.more.menu?.title
            cell.more.setAccessibilityLabel("More Actions for \(device.name)")
            return cell
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            !view.devices.isEmpty
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table = scrollView?.table else { return }
            view.selection = table.selectedRow >= 0 ? view.devices[table.selectedRow].inventoryID : nil
        }

        @objc func tableFrameChanged(_ notification: Notification) {
            scrollView?.invalidateIntrinsicContentSize()
        }
    }

    private final class PartnerCell: NSTableCellView {
        let title = NSTextField(labelWithString: "")
        let more = NSPopUpButton(image: NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "More Actions")!,
                                 pullDownMenu: NSMenu())

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            title.lineBreakMode = .byTruncatingTail
            title.maximumNumberOfLines = 1
            title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            more.isBordered = false
            more.controlSize = .small
            (more.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
            let stack = NSStackView(views: [title, more])
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
                stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
                heightAnchor.constraint(greaterThanOrEqualToConstant: minimumPartnerRowHeight),
            ])
            textField = title
        }

        required init?(coder: NSCoder) { nil }
    }

    private final class EmptyCell: NSTableCellView {
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            let label = NSTextField(labelWithString: "")
            label.alignment = .center
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor),
                label.trailingAnchor.constraint(equalTo: trailingAnchor),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
                heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
            ])
            textField = label
        }

        required init?(coder: NSCoder) { nil }
    }
}
