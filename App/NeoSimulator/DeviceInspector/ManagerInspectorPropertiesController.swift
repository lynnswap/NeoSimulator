import AppKit
@_spi(NeoSimulator) import XcodeSimulatorHost

@MainActor
final class ManagerInspectorPropertiesController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    private final class Property: NSObject {
        let name: String
        let value: DeviceInspectorValue
        let path: [String]
        let children: [Property]
        init(name: String, value: DeviceInspectorValue, path: [String]) {
            self.name = name
            self.value = value
            self.path = path
            switch value {
            case .object(let fields): children = Self.properties(fields, parentPath: path)
            case .array(let values): children = values.enumerated().map { Property(name: "Item \($0.offset + 1)", value: $0.element, path: path + [String($0.offset)]) }
            default: children = []
            }
        }
        private init(name: String, value: DeviceInspectorValue, path: [String], children: [Property]) {
            self.name = name
            self.value = value
            self.path = path
            self.children = children
        }
        static func properties(_ fields: [String: DeviceInspectorValue], parentPath: [String] = []) -> [Property] {
            fields.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { Property(name: $0, value: fields[$0]!, path: parentPath + [$0]) }
        }
        func visible(hiding paths: Set<[String]>) -> Property? {
            guard !paths.contains(path) else { return nil }
            let visibleChildren = children.compactMap { $0.visible(hiding: paths) }
            guard children.isEmpty || !visibleChildren.isEmpty else { return nil }
            return Property(name: name, value: value, path: path, children: visibleChildren)
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
    private let visibleFields = NSPopUpButton(frame: .zero, pullsDown: true)
    private let hiddenNotice = NSTextField(wrappingLabelWithString: "All fields are hidden. Choose Visible Fields to show them.")
    private let visibilityPreferenceKey: String?
    private let defaults: UserDefaults
    private var hiddenPaths: Set<[String]>
    private var allProperties: [Property] = []
    private var properties: [Property] = []

    init(visibilityPreferenceKey: String? = nil, defaults: UserDefaults = .standard) {
        self.visibilityPreferenceKey = visibilityPreferenceKey
        self.defaults = defaults
        hiddenPaths = Set(visibilityPreferenceKey.flatMap { defaults.array(forKey: $0) as? [[String]] } ?? [])
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }

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
        if visibilityPreferenceKey != nil {
            visibleFields.addItem(withTitle: "Visible Fields")
            visibleFields.menu?.delegate = self
            visibleFields.setAccessibilityLabel("Visible Info Fields")
            hiddenNotice.font = .systemFont(ofSize: 11)
            hiddenNotice.textColor = .secondaryLabelColor
            let stack = NSStackView(views: [visibleFields, hiddenNotice, scroll])
            stack.orientation = .vertical
            stack.distribution = .fill
            stack.alignment = .leading
            stack.spacing = 8
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            hiddenNotice.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            view = stack
        } else { view = scroll }
        updateVisibleProperties()
    }
    func setProperties(_ fields: [String: DeviceInspectorValue]) {
        _ = view
        allProperties = Property.properties(fields)
        updateVisibleProperties()
    }
    private func updateVisibleProperties() {
        properties = allProperties.compactMap { $0.visible(hiding: hiddenPaths) }
        table.reloadData()
        for property in properties where !property.children.isEmpty { table.expandItem(property) }
        visibleFields.isEnabled = !allProperties.isEmpty
        hiddenNotice.isHidden = allProperties.isEmpty || !properties.isEmpty
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        menu.addItem(NSMenuItem(title: "Visible Fields", action: nil, keyEquivalent: ""))
        let showAll = NSMenuItem(title: "Show All Fields", action: #selector(showAllFields(_:)), keyEquivalent: "")
        showAll.target = self
        menu.addItem(showAll)
        menu.addItem(.separator())
        addFieldItems(allProperties, to: menu)
    }
    private func addFieldItems(_ fields: [Property], to menu: NSMenu) {
        menu.autoenablesItems = false
        for field in fields {
            let item = NSMenuItem(title: field.displayName, action: #selector(toggleField(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = field.path
            let hiddenByAncestor = hiddenPaths.contains { field.path.starts(with: $0) }
            if hiddenByAncestor || field.visible(hiding: hiddenPaths) == nil { item.state = .off }
            else if hiddenPaths.contains(where: { $0.starts(with: field.path) }) { item.state = .mixed }
            else { item.state = .on }
            if !field.children.isEmpty {
                let submenu = NSMenu(title: field.displayName)
                let showGroup = NSMenuItem(title: "Show \(field.displayName)", action: #selector(toggleField(_:)), keyEquivalent: "")
                showGroup.target = self
                showGroup.representedObject = field.path
                showGroup.state = item.state
                submenu.addItem(showGroup)
                submenu.addItem(.separator())
                addFieldItems(field.children, to: submenu)
                item.action = nil
                item.submenu = submenu
            }
            menu.addItem(item)
        }
    }
    @objc private func toggleField(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? [String] else { return }
        if sender.state == .off {
            hiddenPaths = hiddenPaths.filter { !$0.starts(with: path) && !path.starts(with: $0) }
        } else { hiddenPaths.insert(path) }
        saveVisibility()
    }
    @objc private func showAllFields(_ sender: Any?) {
        hiddenPaths = []
        saveVisibility()
    }
    private func saveVisibility() {
        if let visibilityPreferenceKey {
            defaults.set(hiddenPaths.sorted { $0.lexicographicallyPrecedes($1) }, forKey: visibilityPreferenceKey)
        }
        updateVisibleProperties()
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
