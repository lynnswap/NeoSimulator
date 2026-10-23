import AppKit
import Observation

/// The device window's toolbar, built from the command catalog.
@MainActor
final class DeviceToolbar: NSObject, NSToolbarDelegate {
    let toolbar = NSToolbar(identifier: "DeviceToolbar")
    private weak var controller: DeviceWindowController?
    private let commands: [DeviceCommand.ID]
    /// The modifier keys held now, which the buttons follow.
    var modifierFlags: () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }
    /// The toolbar's view, whose tracking area reports the pointer over it.
    private var pointerTracking: (view: NSView, area: NSTrackingArea)?
    /// Watches the modifier keys while the pointer is over the toolbar.
    private var modifierMonitor: Any?
    /// Whether the buttons show their Option alternates.
    private var showsOptionAlternates = false

    init(controller: DeviceWindowController) {
        self.controller = controller
        commands = DeviceCommand.toolbarItems.filter {
            DeviceCommand.command($0).isSupported(controller.session.capabilities)
        }
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        // Private AppKit API lets the title truncate before buttons overflow.
        if toolbar.responds(to: NSSelectorFromString("setMinimumInlineWindowTitleWidth:")) {
            toolbar.setValue(0.0, forKey: "minimumInlineWindowTitleWidth")
        }
        updateItems()
    }

    isolated deinit {
        if let modifierMonitor { NSEvent.removeMonitor(modifierMonitor) }
        if let pointerTracking { pointerTracking.view.removeTrackingArea(pointerTracking.area) }
    }

    /// Tracks Option while the pointer is over the toolbar, including inactive windows.
    /// The toolbar view is private AppKit API; without it, buttons keep their default faces.
    func attach(to window: NSWindow) {
        window.toolbar = toolbar
        guard toolbar.responds(to: NSSelectorFromString("_toolbarView")),
              let view = toolbar.value(forKey: "_toolbarView") as? NSView else { return }
        let area = NSTrackingArea(rect: view.bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        view.addTrackingArea(area)
        pointerTracking = (view, area)
    }

    /// Read physical modifier state so synthetic releases sent to devices do not
    /// clear an Option alternate while the user still holds Option.
    @objc(mouseEntered:) func mouseEntered(with event: NSEvent) {
        if modifierMonitor == nil {
            modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                self?.followOption()
                return event
            }
        }
        followOption()
    }

    @objc(mouseExited:) func mouseExited(with event: NSEvent) {
        if let modifierMonitor { NSEvent.removeMonitor(modifierMonitor) }
        modifierMonitor = nil
        showOptionAlternates(false)
    }

    private func followOption() { showOptionAlternates(modifierFlags().contains(.option)) }

    private func showOptionAlternates(_ shows: Bool) {
        guard shows != showsOptionAlternates else { return }
        showsOptionAlternates = shows
        configureItems()
    }

    /// Like Simulator.app's toolbar nibs, the buttons sit between two flexible
    /// spaces; `apply(_:to:)` hides the last one.
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace] + commands.map { NSToolbarItem.Identifier($0.rawValue) } + [.flexibleSpace]
    }

    /// Simulator.app toolbar threshold: each present button's nib width plus four points.
    private var buttonsWidth: CGFloat {
        commands.compactMap { DeviceCommand.command($0).toolbar?.buttonWidth }.reduce(0) { $0 + $1 + 4 }
    }

    /// Unified width includes buttons, the wider title/subtitle, and 130 points of spacing.
    private func unifiedWidth(title: String, subtitle: String) -> CGFloat {
        func width(_ text: String, _ style: NSFont.TextStyle) -> CGFloat {
            let font = NSFont.preferredFont(forTextStyle: style, options: [:])
            return NSAttributedString(string: text, attributes: [.font: font]).size().width
        }
        return buttonsWidth + max(width(title, .headline), width(subtitle, .subheadline)) + 130
    }

    /// Chooses compact, unified, or expanded style from preferences and available width.
    func style(forWidth width: CGFloat, title: String, subtitle: String,
               preferences: any PreferenceStore) -> NSWindow.ToolbarStyle {
        if preferences.usesCompactTitleBar { return .unifiedCompact }
        return preferences.usesMonobar && unifiedWidth(title: title, subtitle: subtitle) <= width ? .unified : .expanded
    }

    /// Hides the trailing flexible space in unified styles so buttons follow the title.
    /// Applies equally to built-in and plugin toolbars.
    func apply(_ style: NSWindow.ToolbarStyle, to window: NSWindow) {
        window.toolbarStyle = style
        if let last = window.toolbar?.items.last, last.itemIdentifier == .flexibleSpace {
            last.isHidden = style != .expanded
        }
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
        // Stateful commands use toggle buttons.
        if DeviceCommand.command(id).state != nil {
            let button = NSButton()
            button.bezelStyle = .toolbar
            button.setButtonType(.pushOnPushOff)
            button.identifier = NSUserInterfaceItemIdentifier(id.rawValue)
            item.view = button
        }
        item.target = self
        item.action = #selector(activate(_:))
        item.autovalidates = false
        configure(item, id)
        return item
    }

    /// Prefers an enabled alternate, then the Option alternate, then the base command.
    private func shown(_ id: DeviceCommand.ID, for controller: DeviceWindowController) -> DeviceCommand.Toolbar.Face? {
        guard let presentation = DeviceCommand.command(id).toolbar else { return nil }
        if let alternate = presentation.alternate, DeviceCommand.command(alternate.id).isEnabled(controller) {
            return alternate
        }
        if showsOptionAlternates, let alternate = presentation.optionAlternate { return alternate }
        return .init(id: id, symbol: presentation.symbol, imageDescription: presentation.imageDescription)
    }

    /// Keeps the item label stable while updating the button's action, tooltip, and image.
    private func configure(_ item: NSToolbarItem, _ id: DeviceCommand.ID) {
        guard let controller, let shown = shown(id, for: controller) else { return }
        let command = DeviceCommand.command(shown.id)
        item.toolTip = shown.toolTip ?? command.toolbar?.toolTip ?? item.label
        item.image = NSImage(systemSymbolName: shown.symbol, accessibilityDescription: shown.imageDescription)
        item.isEnabled = command.isEnabled(controller)
        guard let button = item.view as? NSButton else { return }
        button.image = item.image
        button.toolTip = item.toolTip
        button.isEnabled = item.isEnabled
        button.state = command.state?(controller) ?? .off
    }

    private func updateItems() {
        withObservationTracking {
            guard let controller else { return }
            // Read these even before AppKit has asked the delegate to create items.
            _ = controller.session.isBusy
            _ = controller.session.isConnected
            _ = controller.session.recording?.isStopping
            _ = controller.session.showsAlwaysOn
            configureItems()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.updateItems() }
        }
    }

    private func configureItems() {
        for item in toolbar.items {
            if let id = DeviceCommand.ID(rawValue: item.itemIdentifier.rawValue) { configure(item, id) }
        }
    }

    /// Performs what the item's button shows. A button that shows a state
    /// then shows the command's state again, which a click changed.
    @objc private func activate(_ sender: Any) {
        let identifier = (sender as? NSToolbarItem)?.itemIdentifier.rawValue ?? (sender as? NSButton)?.identifier?.rawValue
        guard let controller, let id = identifier.flatMap(DeviceCommand.ID.init(rawValue:)),
              let shown = shown(id, for: controller) else { return }
        controller.perform(shown.id)
        configureItems()
    }
}
