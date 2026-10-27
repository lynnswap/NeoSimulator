import AppKit

@MainActor
final class SelectedDeviceMenu: NSMenu, NSMenuDelegate {
    private let actions: () -> NSMenu?

    init(actions: @escaping () -> NSMenu?) {
        self.actions = actions
        super.init(title: "Device")
        delegate = self
        autoenablesItems = false
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func menuNeedsUpdate(_ menu: NSMenu) {
        removeAllItems()
        if let source = actions() {
            let items = source.items
            source.removeAllItems()
            for item in items { addItem(item) }
        }
        if items.isEmpty {
            let item = NSMenuItem(title: "Select a Device", action: nil, keyEquivalent: "")
            item.isEnabled = false
            addItem(item)
        }
    }
}
