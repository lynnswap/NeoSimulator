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

    /// Like Simulator.app's toolbar nibs, the buttons sit between two flexible
    /// spaces; `apply(_:to:)` hides the last one.
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace] + commands.map { NSToolbarItem.Identifier($0.rawValue) } + [.flexibleSpace]
    }

    /// What Simulator.app's toolbar style threshold counts for the toolbar's
    /// buttons (`_toolbarItemWidth`): the width of each button in its toolbar
    /// nib plus 4 points, for the commands this toolbar has.
    private var buttonsWidth: CGFloat {
        commands.compactMap { DeviceCommand.command($0).toolbar?.buttonWidth }.reduce(0) { $0 + $1 + 4 }
    }

    /// The narrowest display with which Simulator.app keeps the unified style
    /// (`_minWidth`): the buttons, the wider of `title` in the headline font
    /// and `subtitle` in the subheadline font, and 130 points.
    private func unifiedWidth(title: String, subtitle: String) -> CGFloat {
        func width(_ text: String, _ style: NSFont.TextStyle) -> CGFloat {
            let font = NSFont.preferredFont(forTextStyle: style, options: [:])
            return NSAttributedString(string: text, attributes: [.font: font]).size().width
        }
        return buttonsWidth + max(width(title, .headline), width(subtitle, .subheadline)) + 130
    }

    /// The style Simulator.app's geometry update gives the toolbar of a window
    /// whose display is `width` points wide: compact with `UseCompactTitleBar`,
    /// otherwise unified while `UseMonobar` is on and the display is at least
    /// `unifiedWidth(title:subtitle:)` wide, and expanded below that.
    func style(forWidth width: CGFloat, title: String, subtitle: String,
               preferences: any PreferenceStore) -> NSWindow.ToolbarStyle {
        if preferences.usesCompactTitleBar { return .unifiedCompact }
        return preferences.usesMonobar && unifiedWidth(title: title, subtitle: subtitle) <= width ? .unified : .expanded
    }

    /// Gives `window` `style` and, as Simulator.app does on macOS 26, hides
    /// the last flexible space unless the style is expanded, so that the
    /// buttons follow the title in a unified title bar and are centered in the
    /// row below it in an expanded one.
    func apply(_ style: NSWindow.ToolbarStyle, to window: NSWindow) {
        window.toolbarStyle = style
        if let last = toolbar.items.last, last.itemIdentifier == .flexibleSpace { last.isHidden = style != .expanded }
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
