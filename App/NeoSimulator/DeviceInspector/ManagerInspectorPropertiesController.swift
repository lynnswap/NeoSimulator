import AppKit
@_spi(NeoSimulator) import XcodeSimulatorHost

@MainActor
final class ManagerInspectorPropertiesController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private final class Property: NSObject {
        let name: String
        let value: DeviceInspectorValue
        let children: [Property]
        init(name: String, value: DeviceInspectorValue) {
            self.name = name
            self.value = value
            switch value {
            case .object(let fields): children = Self.properties(fields)
            case .array(let values): children = values.enumerated().map { Property(name: "Item \($0.offset + 1)", value: $0.element) }
            default: children = []
            }
        }
        static func properties(_ fields: [String: DeviceInspectorValue]) -> [Property] {
            fields.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { Property(name: $0, value: fields[$0]!) }
        }
        var displayName: String {
            let names = ["CFBundleIdentifier": "Bundle Identifier", "CFBundleDisplayName": "Display Name", "CFBundleName": "Name",
                         "CFBundleShortVersionString": "Version", "CFBundleVersion": "Build", "IsDeveloperApp": "Developer Application",
                         "IsRemovable": "Removable", "udid": "UDID", "uuid": "UUID", "osVersion": "OS Version", "osBuild": "OS Build",
                         "hardware": "Hardware Properties", "software": "Software Properties", "connection": "Connection Properties",
                         "state": children.isEmpty ? "State" : "Device Properties", "ecid": "ECID", "cpuType": "CPU Type",
                         "osVersionNumber": "OS Version", "osBuildVersions": "OS Builds", "ddiServicesAvailable": "DDI Services",
                         "tunnelIPAddressString": "Tunnel IP Address", "rootFileSystemIsWritable": "Writable Root File System"]
            return names[name] ?? name.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).capitalized
        }
        var displayValue: String {
            switch value {
            case .object(let values): "\(values.count) properties"
            case .array(let values): "\(values.count) items"
            case .string(let string): string
            case .integer(let number): String(number)
            case .number(let number): String(number)
            case .boolean(let enabled): enabled ? "Yes" : "No"
            case .date(let date): date.formatted()
            case .data(let data): "\(data.count) bytes"
            case .null: "—"
            }
        }
    }
    private let table = NSOutlineView()
    private var properties: [Property] = []

    override func loadView() {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let name = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Property"))
        name.title = "Property"
        name.width = 130
        name.minWidth = 80
        let value = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Value"))
        value.title = "Value"
        value.width = 150
        value.minWidth = 80
        table.addTableColumn(name)
        table.addTableColumn(value)
        table.outlineTableColumn = name
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.style = .inset
        table.rowHeight = 24
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Properties")
        scroll.documentView = table
        view = scroll
    }

    func setProperties(_ fields: [String: DeviceInspectorValue]) {
        _ = view
        properties = Property.properties(fields)
        table.reloadData()
        for property in properties where !property.children.isEmpty { table.expandItem(property) }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? Property)?.children.count ?? properties.count }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { ((item as? Property)?.children ?? properties)[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { !(item as! Property).children.isEmpty }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let property = item as! Property
        let id = tableColumn!.identifier
        let label = outlineView.makeView(withIdentifier: id, owner: self) as? NSTextField ?? NSTextField(labelWithString: "")
        label.identifier = id
        label.font = .systemFont(ofSize: 11)
        label.isSelectable = true
        label.lineBreakMode = .byTruncatingMiddle
        label.stringValue = id.rawValue == "Property" ? property.displayName : property.displayValue
        label.toolTip = label.stringValue
        return label
    }
}
