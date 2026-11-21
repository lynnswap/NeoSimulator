import NeoSimulatorKit
import NeoSimulatorPresentationAdapters
import NeoSimulatorHostSupport
import AppKit

@MainActor
final class SelectedDeviceMenu: NSMenu, DeviceKeyEquivalentMenuDelegate {
    enum Command: String, CaseIterable {
        case view = "View Screen", cancelOpening = "Cancel Opening", stopSharing = "Stop Screen Sharing", lock = "Lock"
        case start = "Start", shutdown = "Shut Down", forceShutdown = "Force Shut Down", restart = "Restart"
        case pause = "Pause", resume = "Resume", newTab = "Open in New Tab", newWindow = "Open in New Window"
        case showInFinder = "Show in Finder", rename = "Rename…", clone = "Clone…", pair = "Pair"
        case pairSimulators = "Pair Simulators", pairWatch = "Pair Apple Watch…", pairPhone = "Pair iPhone…"
        case erase = "Reset Content and Settings…", unpair = "Unpair…", remove = "Remove…"
    }

    private static let path = ["Device", "Manage Selected Devices"]
    private let shortcuts: MenuShortcuts
    private let actions: () -> NSMenu?

    init(shortcuts: MenuShortcuts, actions: @escaping () -> NSMenu?) {
        self.shortcuts = shortcuts
        self.actions = actions
        shortcuts.register(titles: Command.allCases.map(\.rawValue), path: Self.path)
        super.init(title: "Device")
        delegate = self
        autoenablesItems = false
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func prepare(_ menu: NSMenu, forKeyEquivalent event: NSEvent) {
        if shortcuts.hasCustomShortcut(for: event, in: Self.path) { menuNeedsUpdate(menu) }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        removeAllItems()
        if let source = actions() {
            let items = source.items
            source.removeAllItems()
            for item in items { addItem(item) }
            shortcuts.register(self, path: Self.path, declaredOnly: true)
        }
        if items.isEmpty {
            let item = NSMenuItem(title: "Select a Device", action: nil, keyEquivalent: "")
            item.isEnabled = false
            addItem(item)
        }
    }
}
