import AppKit

/// Builds the main menu in Simulator.app's order and routes device commands to
/// the key device window.
@MainActor
final class MenuController: NSObject, NSMenuItemValidation, NSMenuDelegate {
    private weak var application: HostApplication?
    private let openSimulator: OpenSimulatorMenu
    private var activeWindow: DeviceWindowController? {
        NSApp.keyWindow?.windowController as? DeviceWindowController
    }

    init(application: HostApplication?) {
        self.application = application
        openSimulator = OpenSimulatorMenu(application: application)
    }

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
        item("Quit NeoSimulator…", action: #selector(quitAsking(_:)), key: "q", modifiers: [.command, .option],
             in: app).isAlternate = true

        let file = menu("File", in: main)
        item("New Simulator…", action: #selector(showNewSimulator(_:)), in: file)
        let open = NSMenuItem(title: "Open Simulator", action: nil, keyEquivalent: "")
        open.submenu = NSMenu(title: "Open Simulator")
        open.submenu?.delegate = openSimulator
        file.addItem(open)
        file.addItem(.separator())
        commands([.saveScreen, .recordScreen, .stopRecording], in: file)
        file.addItem(.separator())
        commands([.importFiles], in: file)
        file.addItem(.separator())
        item("Close Window", action: #selector(closeWindow(_:)), key: "w", in: file)
        item("Close Window…", action: #selector(closeAsking(_:)), key: "w", modifiers: [.command, .control],
             in: file).isAlternate = true

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

        let debug = menu("Debug", in: main)
        item("Show Parallel Testing Devices", action: #selector(toggleShowTestingDevices(_:)), in: debug)

        let window = menu("Window", in: main)
        item("Minimize", action: #selector(minimizeWindow(_:)), key: "m", in: window)
        item("Enter Full Screen", action: #selector(fullScreen(_:)), key: "f", modifiers: [.command, .control], in: window)
        commands([.showDeviceBezels, .stayOnTop], in: window)
        window.addItem(.separator())
        commands([.fitScreen], in: window)
        window.addItem(.separator())
        // NeoSimulator's own list of devices; Simulator.app has no such window.
        item("Simulators", action: #selector(showBrowser(_:)), in: window)
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
            } else if let submenu = item.submenu, submenu.delegate === self {
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
        if let action = item.action,
           [#selector(showBrowser(_:)), #selector(showNewSimulator(_:)), #selector(showHelp(_:))].contains(action) {
            return true
        }
        if item.action == #selector(quitAsking(_:)) { return application != nil }
        // Asking applies to a connected device window.
        if item.action == #selector(closeAsking(_:)) { return activeWindow?.session.canPerformCommands == true }
        if item.action == #selector(toggleShowTestingDevices(_:)) {
            item.state = application?.showsTestingDevices == true ? .on : .off
            return application != nil
        }
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
    @objc private func showNewSimulator(_ sender: Any?) { application?.showNewSimulator() }
    @objc private func toggleShowTestingDevices(_ sender: Any?) { application?.toggleShowTestingDevices() }
    @objc private func closeWindow(_ sender: Any?) { NSApp.keyWindow?.performClose(sender) }
    @objc private func closeAsking(_ sender: Any?) { activeWindow?.closeAsking() }
    @objc private func quitAsking(_ sender: Any?) { application?.quitAsking() }
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

/// File ▸ Open Simulator, rebuilt each time it opens. Choosing a device boots
/// it when needed and shows its window.
@MainActor
final class OpenSimulatorMenu: NSObject, NSMenuDelegate {
    private weak var application: HostApplication?

    init(application: HostApplication?) { self.application = application }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let application else { return }
        do {
            let devices = try application.availableSimulatorDevices()
            menu.items = Self.items(for: devices, hasWindow: application.hasVisibleWindow(forDevice:),
                                    action: #selector(select(_:)), target: self)
        } catch {
            hostLog(error.localizedDescription)
            menu.items = []
        }
    }

    /// Simulator.app's layout: a submenu per runtime, in the order runtimes
    /// first appear, or the devices directly when they share one runtime.
    /// Holding Option shows each device's descriptive name.
    static func items(for devices: [AvailableDevice], hasWindow: (String) -> Bool,
                      action: Selector, target: AnyObject?) -> [NSMenuItem] {
        func deviceItems(_ device: AvailableDevice) -> [NSMenuItem] {
            // A booting or booted device is on with a window and mixed without.
            let state: NSControl.StateValue =
                device.state == 2 || device.state == 3 ? (hasWindow(device.identifier) ? .on : .mixed) : .off
            return [(device.name, false), (device.descriptiveName, true)].map { title, isAlternate in
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = target
                item.representedObject = device.identifier
                item.state = state
                item.isAlternate = isAlternate
                item.keyEquivalentModifierMask = isAlternate ? .option : []
                return item
            }
        }
        var runtimes: [(identifier: String, name: String, devices: [AvailableDevice])] = []
        for device in devices {
            if let index = runtimes.firstIndex(where: { $0.identifier == device.runtimeIdentifier }) {
                runtimes[index].devices.append(device)
            } else {
                runtimes.append((device.runtimeIdentifier, device.runtimeName, [device]))
            }
        }
        guard runtimes.count > 1 else { return devices.flatMap(deviceItems) }
        return runtimes.map { runtime in
            let item = NSMenuItem(title: runtime.name, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: runtime.name)
            submenu.items = runtime.devices.flatMap(deviceItems)
            item.submenu = submenu
            item.state = submenu.items.contains { $0.state != .off } ? .mixed : .off
            return item
        }
    }

    @objc private func select(_ sender: NSMenuItem) {
        guard let application, let identifier = sender.representedObject as? String else { return }
        Task {
            do { try await application.openSimulator(withIdentifier: identifier) }
            catch is CancellationError {}
            catch { NSAlert(error: error).runModal() }
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
