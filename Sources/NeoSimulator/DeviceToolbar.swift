import AppKit
import Observation

/// The device window's toolbar, built from the command catalog.
@MainActor
final class DeviceToolbar: NSObject, NSToolbarDelegate {
    let toolbar = NSToolbar(identifier: "DeviceToolbar")
    private weak var controller: DeviceWindowController?
    private let commands: [DeviceCommand.ID]

    init(controller: DeviceWindowController) {
        self.controller = controller
        commands = DeviceCommand.toolbarItems.filter {
            DeviceCommand.command($0).isSupported(controller.session.capabilities)
        }
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        updateItems()
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace] + commands.map { NSToolbarItem.Identifier($0.rawValue) }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let id = DeviceCommand.ID(rawValue: itemIdentifier.rawValue),
              let presentation = DeviceCommand.command(id).toolbar else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = presentation.label
        item.toolTip = presentation.label
        item.image = NSImage(systemSymbolName: presentation.symbol, accessibilityDescription: presentation.label)
        if id == .stopRecording {
            item.image = item.image?.withSymbolConfiguration(.init(paletteColors: [.systemRed]))
        }
        item.target = self
        item.action = #selector(activate(_:))
        item.autovalidates = false
        configure(item, id)
        return item
    }

    private func configure(_ item: NSToolbarItem, _ id: DeviceCommand.ID) {
        guard let controller else { return }
        item.isEnabled = DeviceCommand.command(id).isEnabled(controller)
        if id == .stopRecording { item.isHidden = controller.session.recording == nil }
    }

    private func updateItems() {
        withObservationTracking {
            guard let controller else { return }
            // Read these even before AppKit has asked the delegate to create items.
            _ = controller.session.isBusy
            _ = controller.session.isConnected
            _ = controller.session.recording?.isStopping
            for item in toolbar.items {
                if let id = DeviceCommand.ID(rawValue: item.itemIdentifier.rawValue) { configure(item, id) }
            }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.updateItems() }
        }
    }

    @objc private func activate(_ sender: NSToolbarItem) {
        if let id = DeviceCommand.ID(rawValue: sender.itemIdentifier.rawValue) { controller?.perform(id) }
    }
}
