import AppKit

/// Builds the main menu in Simulator.app's order and routes device commands to
/// the key device window.
@MainActor
final class MenuController: NSObject, NSMenuItemValidation, NSMenuDelegate {
    private weak var application: HostApplication?
    private var activeWindow: DeviceWindowController? {
        NSApp.keyWindow?.windowController as? DeviceWindowController
    }

    init(application: HostApplication?) { self.application = application }

    func install() {
        let main = NSMenu()
        let app = menu("NeoSimulator", in: main)
        item("About NeoSimulator", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), in: app, target: NSApp)
        app.addItem(.separator())
        item("Hide NeoSimulator", action: #selector(NSApplication.hide(_:)), key: "h", in: app, target: NSApp)
        item("Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), key: "h", modifiers: [.command, .option], in: app, target: NSApp)
        item("Show All", action: #selector(NSApplication.unhideAllApplications(_:)), in: app, target: NSApp)
        app.addItem(.separator())
        item("Quit NeoSimulator", action: #selector(NSApplication.terminate(_:)), key: "q", in: app, target: NSApp)

        let file = menu("File", in: main)
        item("Open Simulator…", action: #selector(showBrowser(_:)), key: "n", in: file)
        file.addItem(.separator())
        commands([.saveScreen, .recordScreen, .stopRecording], in: file)
        file.addItem(.separator())
        commands([.importFiles], in: file)
        file.addItem(.separator())
        item("Close Window", action: #selector(closeWindow(_:)), key: "w", in: file)

        let edit = EditMenu(title: "Edit")
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit
        let editingActions: [(String, Selector, String, NSEvent.ModifierFlags)] = [
            ("Undo", Selector(("undo:")), "z", .command),
            ("Redo", Selector(("redo:")), "z", [.command, .shift]),
            ("Cut", #selector(NSText.cut(_:)), "x", .command),
            ("Copy", #selector(NSText.copy(_:)), "c", .command),
            ("Paste", #selector(NSText.paste(_:)), "v", .command),
            ("Select All", #selector(NSText.selectAll(_:)), "a", .command),
        ]
        for (index, (title, action, key, modifiers)) in editingActions.enumerated() {
            if index == 2 { edit.addItem(.separator()) }
            item(title, action: action, key: key, modifiers: modifiers, in: edit).target = nil
        }

        let device = menu("Device", in: main)
        commands([.restart, .eraseAllContentAndSettings, .shutDown], in: device)
        device.addItem(.separator())
        commands([.rotateLeft, .rotateRight], in: device)
        let orientation = menu("Orientation", in: device)
        commands([.portrait, .landscapeRight, .portraitUpsideDown, .landscapeLeft], in: orientation)
        orientation.addItem(.separator())
        commands([.faceUp, .faceDown], in: orientation)
        commands([.rotateDeviceAutomatically], in: device)
        device.addItem(.separator())
        commands([.home, .lock, .sideButton, .actionButtonSting, .actionButtonStaccato, .siri, .shake, .appSwitcher],
                 in: device)
        device.addItem(.separator())
        commands([.triggerScreenshot], in: device)

        let io = menu("I/O", in: main)
        let keyboard = menu("Keyboard", in: io)
        commands([.toggleSoftwareKeyboard], in: keyboard)
        io.addItem(.separator())
        commands([.increaseVolume, .decreaseVolume], in: io)
        io.addItem(.separator())
        commands([.openURL], in: io)

        let features = menu("Features", in: main)
        commands([.authorizeApplePay], in: features)
        features.addItem(.separator())
        commands([.toggleAppearance], in: features)

        let window = menu("Window", in: main)
        item("Minimize", action: #selector(minimizeWindow(_:)), key: "m", in: window)
        item("Enter Full Screen", action: #selector(fullScreen(_:)), key: "f", modifiers: [.command, .control], in: window)
        commands([.showDeviceBezels, .stayOnTop], in: window)
        window.addItem(.separator())
        commands([.fitScreen], in: window)
        window.addItem(.separator())
        item("Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), in: window, target: NSApp)

        let help = menu("Help", in: main)
        item("NeoSimulator Help", action: #selector(showHelp(_:)), key: "?", in: help)

        NSApp.mainMenu = main
        NSApp.windowsMenu = window
        NSApp.helpMenu = help
    }

    private func menu(_ title: String, in parent: NSMenu) -> NSMenu {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        menu.delegate = self
        item.submenu = menu
        parent.addItem(item)
        return menu
    }

    @discardableResult
    private func item(_ title: String, action: Selector, key: String = "",
                      modifiers: NSEvent.ModifierFlags = .command, in menu: NSMenu,
                      target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target ?? self
        item.keyEquivalentModifierMask = modifiers
        menu.addItem(item)
        return item
    }

    private func commands(_ ids: [DeviceCommand.ID], in menu: NSMenu) {
        for id in ids {
            let command = DeviceCommand.command(id)
            item(command.title, action: #selector(performCommand(_:)), key: command.key,
                 modifiers: command.modifiers, in: menu).representedObject = id.rawValue
        }
    }

    // Simulator.app hides commands the key device does not support. Without a
    // device window, commands stay visible and disabled.
    func menuNeedsUpdate(_ menu: NSMenu) {
        updateVisibility(in: menu, for: activeWindow?.session.capabilities)
    }

    func updateVisibility(in menu: NSMenu, for capabilities: DeviceCapabilities?) {
        var previousVisible: NSMenuItem?
        for item in menu.items {
            if let raw = item.representedObject as? String, let id = DeviceCommand.ID(rawValue: raw) {
                item.isHidden = capabilities.map { !DeviceCommand.command(id).isSupported($0) } ?? false
            } else if let submenu = item.submenu {
                updateVisibility(in: submenu, for: capabilities)
                item.isHidden = submenu.items.allSatisfy { $0.isHidden || $0.isSeparatorItem }
            }
            if item.isSeparatorItem {
                // A separator needs a visible item before it and is hidden again
                // below when nothing visible follows.
                item.isHidden = previousVisible == nil || previousVisible?.isSeparatorItem == true
            }
            if !item.isHidden { previousVisible = item }
        }
        if previousVisible?.isSeparatorItem == true { previousVisible?.isHidden = true }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(showBrowser(_:)) || item.action == #selector(showHelp(_:)) { return true }
        if item.action == #selector(fullScreen(_:)) {
            item.title = NSApp.keyWindow?.styleMask.contains(.fullScreen) == true ? "Exit Full Screen" : "Enter Full Screen"
        }
        guard let raw = item.representedObject as? String, let id = DeviceCommand.ID(rawValue: raw) else {
            return NSApp.keyWindow != nil
        }
        let command = DeviceCommand.command(id)
        guard let window = activeWindow else {
            item.state = .off
            return false
        }
        item.state = command.state?(window) ?? .off
        return command.isEnabled(window)
    }

    @objc private func showBrowser(_ sender: Any?) { application?.showDeviceBrowser() }
    @objc private func closeWindow(_ sender: Any?) { NSApp.keyWindow?.performClose(sender) }
    @objc private func minimizeWindow(_ sender: Any?) { NSApp.keyWindow?.performMiniaturize(sender) }
    @objc private func fullScreen(_ sender: Any?) { NSApp.keyWindow?.toggleFullScreen(sender) }
    @objc private func showHelp(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://github.com/lynnswap/NeoSimulator#readme")!)
    }
    @objc private func performCommand(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let id = DeviceCommand.ID(rawValue: raw) {
            activeWindow?.perform(id)
        }
    }
}

// AppKit consumes a matching key equivalent even when its item is disabled, so
// leave the standard editing shortcuts to the simulator while it has keyboard focus.
private final class EditMenu: NSMenu {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let window = event.window
        let simulatorHasFocus = MainActor.assumeIsolated {
            guard let window, let controller = window.windowController as? DeviceWindowController else { return false }
            return window.firstResponder === controller.session.display.inputView
        }
        return !simulatorHasFocus && super.performKeyEquivalent(with: event)
    }
}
