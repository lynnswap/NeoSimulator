import AppKit

@MainActor
final class MenuController: NSObject, NSMenuItemValidation {
    private weak var application: HostApplication?
    private var activeSession: DeviceWindowController? { NSApp.keyWindow?.windowController as? DeviceWindowController }

    init(application: HostApplication) { self.application = application }

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
        command("Save Screen…", .screenshot, key: "s", in: file)
        command("Record Video…", .recording, key: "r", in: file)
        file.addItem(.separator())
        command("Install App or Import Media…", .importFiles, key: "i", modifiers: [.command, .shift], in: file)
        file.addItem(.separator())
        item("Close Window", action: #selector(closeWindow(_:)), key: "w", in: file)

        let device = menu("Device", in: main)
        command("Rotate Left", .rotateLeft, key: String(UnicodeScalar(NSLeftArrowFunctionKey)!), in: device)
        command("Rotate Right", .rotateRight, key: String(UnicodeScalar(NSRightArrowFunctionKey)!), in: device)
        device.addItem(.separator())
        command("Home", .home, key: "h", modifiers: [.command, .shift], in: device)
        command("Lock", .lock, key: "l", in: device)
        command("Shake", .shake, key: "z", modifiers: [.command, .control], in: device)
        device.addItem(.separator())
        command("Shut Down", .shutdown, in: device)

        let io = menu("I/O", in: main)
        command("Toggle Software Keyboard", .keyboard, key: "k", in: io)
        command("Open URL…", .openURL, key: "u", modifiers: [.command, .shift], in: io)
        let features = menu("Features", in: main)
        command("Toggle Appearance", .appearance, key: "a", modifiers: [.command, .shift], in: features)

        let window = menu("Window", in: main)
        item("Minimize", action: #selector(minimizeWindow(_:)), key: "m", in: window)
        item("Zoom", action: #selector(zoomWindow(_:)), in: window)
        item("Enter Full Screen", action: #selector(fullScreen(_:)), key: "f", modifiers: [.command, .control], in: window)
        command("Show Device Bezels", .bezel, in: window)
        command("Stay On Top", .stayOnTop, in: window)
        window.addItem(.separator())
        command("Fit Screen", .fit, key: "4", in: window)
        window.addItem(.separator())
        item("Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), in: window, target: NSApp)
        NSApp.mainMenu = main
        NSApp.windowsMenu = window
    }

    private func menu(_ title: String, in parent: NSMenu) -> NSMenu {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
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

    private func command(_ title: String, _ command: DeviceCommand, key: String = "",
                         modifiers: NSEvent.ModifierFlags = .command, in menu: NSMenu) {
        item(title, action: #selector(performCommand(_:)), key: key, modifiers: modifiers, in: menu)
            .representedObject = command.rawValue
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(showBrowser(_:)) { return true }
        if item.action == #selector(fullScreen(_:)) {
            item.title = NSApp.keyWindow?.styleMask.contains(.fullScreen) == true ? "Exit Full Screen" : "Enter Full Screen"
        }
        guard let value = item.representedObject as? String, let command = DeviceCommand(rawValue: value) else {
            return NSApp.keyWindow != nil
        }
        guard let session = activeSession else { item.state = .off; return false }
        switch command {
        case .screenshot, .rotateLeft, .rotateRight, .importFiles, .openURL: return session.canPerformToolOperation
        case .shutdown: return session.canPerformToolOperation && session.toolbarState.recording == nil
        case .recording:
            item.title = session.toolbarState.recording == nil ? "Record Video…" : "Stop Recording"
            return session.toolbarState.recording.map { !$0.isStopping } ?? session.canPerformToolOperation
        case .bezel: item.state = session.showsDeviceBezel ? .on : .off
        case .stayOnTop: item.state = session.staysOnTop ? .on : .off
        case .fit: return session.canPerformCommands && session.window?.inLiveResize == false
            && session.window?.styleMask.contains(.fullScreen) == false
        default: break
        }
        return session.canPerformCommands
    }

    @objc private func showBrowser(_ sender: Any?) { application?.showDeviceBrowser() }
    @objc private func closeWindow(_ sender: Any?) { NSApp.keyWindow?.performClose(sender) }
    @objc private func minimizeWindow(_ sender: Any?) { NSApp.keyWindow?.performMiniaturize(sender) }
    @objc private func zoomWindow(_ sender: Any?) { NSApp.keyWindow?.performZoom(sender) }
    @objc private func fullScreen(_ sender: Any?) { NSApp.keyWindow?.toggleFullScreen(sender) }
    @objc private func performCommand(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let command = DeviceCommand(rawValue: raw) {
            activeSession?.perform(command)
        }
    }
}
