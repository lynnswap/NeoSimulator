import AppKit

/// Builds the main menu and routes device commands to the key window.
@MainActor
final class MenuController: NSObject, NSMenuItemValidation, NSMenuDelegate {
    private weak var application: HostApplication?
    /// File ▸ GPU Selection's policy, or nil when it is unavailable.
    private let gpuPolicy: GPUPolicy?
    /// Edit ▸ Automatically Sync Pasteboard, or nil when it is unavailable.
    private let pasteboardSync: PasteboardSync?
    private let openSimulator: OpenSimulatorMenu
    private let locationMenu = LocationMenu()
    private let audioMenus = [AudioRouteMenu(scope: .input), AudioRouteMenu(scope: .output)]
    private var ioMenu: NSMenu?
    /// Items whose shortcut depends on the key device.
    private var keyedItems: [NSMenuItem] = []
    private var keyWindowObserver: (any NSObjectProtocol)?
    private var activeWindow: DeviceWindowController? { DeviceWindowController.keyDeviceWindow }

    init(application: HostApplication?, gpuPolicy: GPUPolicy? = nil, pasteboardSync: PasteboardSync? = nil) {
        self.application = application
        self.gpuPolicy = gpuPolicy
        self.pasteboardSync = pasteboardSync
        openSimulator = OpenSimulatorMenu(application: application)
    }

    isolated deinit {
        if let keyWindowObserver { NotificationCenter.default.removeObserver(keyWindowObserver) }
    }

    func install() {
        let main = NSMenu()
        let app = menu("NeoSimulator", in: main)
        item("About NeoSimulator", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), in: app, target: NSApp)
        app.addItem(.separator())
        item("Settings…", action: #selector(showManagerSettings(_:)), key: ",", in: app)
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
        commands([.saveScreen, .saveScreenAs, .recordScreen, .recordScreenAs, .stopRecording], in: file)
        file.addItem(.separator())
        let gpu = menu("GPU Selection", in: file)
        for (title, preference) in [("Automatic", GPUPolicy.Preference.automatic),
                                    ("Prefer Integrated GPU", .integrated), ("Prefer Discrete GPU", .discrete)] {
            item(title, action: #selector(preferGPU(_:)), in: gpu).representedObject = preference
        }
        gpu.addItem(.separator())
        item("Use External GPU When Available", action: #selector(togglePrefersExternalGPU(_:)), in: gpu)
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
            if title == "Copy" { commands([.copyScreen], in: edit) }
        }
        edit.addItem(.separator())
        item("Automatically Sync Pasteboard", action: #selector(togglePasteboardSync(_:)), in: edit)
        commands([.getPasteboard, .sendPasteboard], in: edit)

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
        commands([.home], in: device)
        pluginCommands([.recenterOpenApps], in: device)
        commands([.lock, .sideButton, .actionButtonSting, .actionButtonStaccato], in: device)
        commands([.doubleTap, .wristFlick], in: menu("Gestures", in: device))
        commands([.siri, .shake, .appSwitcher], in: device)
        device.addItem(.separator())
        pluginCommands(PluginCommand.viewportModes, in: device)
        device.addItem(.separator())
        pluginCommands([.resetCamera], in: device)
        device.addItem(.separator())
        commands([.triggerScreenshot], in: device)
        device.addItem(.separator())
        pluginCommands([.simulatedScenes], in: device)

        let io = menu("I/O", in: main)
        ioMenu = io
        // Input capture requires an Apple-only HID entitlement; keyboard settings do not.
        commands([.syncKeyboardLanguage, .connectHardwareKeyboard, .toggleSoftwareKeyboard], in: menu("Keyboard", in: io))
        commands([.useTrackpadForce, .shallowPress, .deepPress], in: menu("Touch Pressure", in: io))
        io.addItem(.separator())
        for audio in audioMenus { io.addItem(audio.item) }
        updateAudioMenus(for: nil)
        commands([.increaseVolume, .decreaseVolume], in: io)
        io.addItem(.separator())
        let externalDisplays = menu("External Displays", in: io)
        commands([ExternalDisplayMode.disabled.commandID], in: externalDisplays)
        externalDisplays.addItem(.separator())
        commands(ExternalDisplayMode.sizes.map(\.commandID), in: externalDisplays)
        externalDisplays.addItem(.separator())
        commands([ExternalDisplayMode.carPlay.commandID], in: externalDisplays)
        io.addItem(.separator())
        pluginCommands(PluginCommand.immersionLevels, in: menu("Set Immersion To", in: io))
        io.addItem(.separator())
        commands([.openURL], in: io)

        let features = menu("Features", in: main)
        commands([.touchIDEnrolled, .touchIDMatching, .touchIDNonMatching], in: menu("Touch ID", in: features))
        commands([.faceIDEnrolled, .faceIDMatching, .faceIDNonMatching], in: menu("Face ID", in: features))
        commands([.opticIDEnrolled, .opticIDMatching, .opticIDNonMatching], in: menu("Optic ID", in: features))
        commands([.fallConfirmed, .fallDismissed, .fallRejected, .fallUnresponsive], in: menu("Simulate Fall", in: features))
        commands([.authorizeApplePay], in: features)
        features.addItem(.separator())
        commands([.toggleAppearance, .toggleInCallStatusBar, .toggleStandBy], in: features)
        features.addItem(.separator())
        pluginCommands(PluginCommand.faceTimeSessions, in: menu("FaceTime", in: features))
        features.addItem(.separator())
        commands([.increaseTextSize, .decreaseTextSize, .toggleIncreaseContrast], in: features)
        features.addItem(.separator())
        commands([.triggerCloudSync], in: features)
        features.addItem(.separator())
        let location = NSMenuItem(title: "Location", action: nil, keyEquivalent: "")
        location.submenu = NSMenu(title: "Location")
        location.submenu?.delegate = locationMenu
        features.addItem(location)

        let debug = menu("Debug", in: main)
        commands([.toggleSlowAnimations], in: debug)
        commands([.graphicsQualityDefault, .graphicsQualityLow, .graphicsQualityHigh],
                 in: menu("Graphics Quality Override", in: debug))
        debug.addItem(.separator())
        commands([.colorBlendedLayers, .colorCopiedImages, .colorMisalignedImages, .colorOffscreenRendered], in: debug)
        debug.addItem(.separator())
        commands([.openSystemLog, .simulateMemoryWarning], in: debug)
        debug.addItem(.separator())
        pluginCommands([.showGazeTarget], in: debug)
        debug.addItem(.separator())
        item("Show Parallel Testing Devices", action: #selector(toggleShowTestingDevices(_:)), in: debug)

        let window = menu("Window", in: main)
        item("Minimize", action: #selector(minimizeWindow(_:)), key: "m", in: window)
        item("Enter Full Screen", action: #selector(fullScreen(_:)), key: "f", modifiers: [.command, .control], in: window)
        item("Show Device Bezels", action: #selector(toggleShowDeviceBezels(_:)), in: window)
        commands([.appleTVRemote, .stayOnTop], in: window)
        window.addItem(.separator())
        commands([.physicalSize, .pointAccurate, .pixelAccurate, .fitScreen], in: window)
        window.addItem(.separator())
        item("Simulators", action: #selector(showBrowser(_:)), in: window)
        item("Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), in: window, target: NSApp)

        let help = menu("Help", in: main)
        item("NeoSimulator Help", action: #selector(showHelp(_:)), key: "?", in: help)

        NSApp.mainMenu = main
        NSApp.windowsMenu = window
        NSApp.helpMenu = help
        updateKeyEquivalents(for: nil)
        keyWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateKeyEquivalents(for: self?.activeWindow?.session.capabilities) }
        }
    }

    /// Assigns shared shortcuts to the key device. Hidden items must lose their shortcuts
    /// because AppKit still matches them.
    func updateKeyEquivalents(for capabilities: DeviceCapabilities?) {
        for item in keyedItems {
            guard let raw = item.representedObject as? String, let id = DeviceCommand.ID(rawValue: raw) else { continue }
            let command = DeviceCommand.command(id)
            item.keyEquivalent = command.hasKey?(capabilities) == false ? "" : command.key
        }
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
            let item = item(command.title, action: #selector(performCommand(_:)), key: command.key,
                            modifiers: command.modifiers, in: menu)
            item.representedObject = id.rawValue
            item.isAlternate = command.isAlternate
            if command.hasKey != nil { keyedItems.append(item) }
        }
    }

    /// Adds items that send their action to the first responder, where the
    /// device's user-interface plugin validates and performs them.
    private func pluginCommands(_ commands: [PluginCommand], in menu: NSMenu) {
        for command in commands {
            item(command.title, action: command.action, key: command.key, modifiers: command.modifiers,
                 in: menu).target = nil
        }
    }

    // Without a device window, commands remain visible but disabled.
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === ioMenu { updateAudioMenus(for: activeWindow) }
        updateVisibility(in: menu, for: activeWindow?.session.capabilities)
    }

    /// Attaches audio menus to the key device.
    func updateAudioMenus(for window: DeviceWindowController?) {
        for audio in audioMenus { audio.attach(to: window) }
    }

    func updateVisibility(in menu: NSMenu, for capabilities: DeviceCapabilities?) {
        var previousVisible: NSMenuItem?
        for item in menu.items {
            if let raw = item.representedObject as? String, let id = DeviceCommand.ID(rawValue: raw) {
                item.isHidden = capabilities.map { !DeviceCommand.command(id).isSupported($0) } ?? false
            } else if let action = item.action, let command = PluginCommand.command(for: action) {
                item.isHidden = capabilities.map { !command.isShown($0) } ?? false
            } else if item.action == #selector(toggleShowDeviceBezels(_:)) {
                item.isHidden = capabilities.map { !$0.supportsDeviceBezels } ?? false
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
        if item.action == #selector(showManagerSettings(_:)) {
            return application != nil
        }
        // Asking applies to a connected device window, not to an external display's.
        if item.action == #selector(closeAsking(_:)) {
            return (NSApp.keyWindow?.windowController as? DeviceWindowController)?.session.canPerformCommands == true
        }
        if item.action == #selector(toggleShowTestingDevices(_:)) {
            item.state = application?.showsTestingDevices == true ? .on : .off
            return application != nil
        }
        // App-wide checkmarks remain valid without a device window.
        if item.action == #selector(toggleShowDeviceBezels(_:)) {
            item.state = UserDefaults.standard.showsDeviceBezels ? .on : .off
            return application != nil
        }
        if item.action == #selector(togglePasteboardSync(_:)) {
            item.state = pasteboardSync?.isOn == true ? .on : .off
            return pasteboardSync != nil
        }
        // Skip a leading external GPU when determining the preferred GPU kind.
        if item.action == #selector(preferGPU(_:)) {
            item.state = gpuPolicy?.preference == item.representedObject as? GPUPolicy.Preference ? .on : .off
            return gpuPolicy != nil
        }
        if item.action == #selector(togglePrefersExternalGPU(_:)) {
            item.state = gpuPolicy?.prefersExternal == true ? .on : .off
            return gpuPolicy != nil
        }
        if item.action == #selector(fullScreen(_:)) {
            item.title = NSApp.keyWindow?.styleMask.contains(.fullScreen) == true ? "Exit Full Screen" : "Enter Full Screen"
        }
        guard let raw = item.representedObject as? String, let id = DeviceCommand.ID(rawValue: raw) else {
            return NSApp.keyWindow != nil
        }
        return DeviceCommand.command(id).validate(item, for: activeWindow)
    }

    @objc private func showBrowser(_ sender: Any?) { application?.showDeviceBrowser() }
    @objc private func showNewSimulator(_ sender: Any?) { application?.showNewSimulator() }
    @objc private func toggleShowTestingDevices(_ sender: Any?) { application?.toggleShowTestingDevices() }
    @objc private func toggleShowDeviceBezels(_ sender: Any?) { application?.toggleShowDeviceBezels() }
    @objc private func togglePasteboardSync(_ sender: Any?) { pasteboardSync?.toggle() }
    @objc private func preferGPU(_ sender: NSMenuItem) {
        if let preference = sender.representedObject as? GPUPolicy.Preference { gpuPolicy?.prefer(preference) }
    }
    @objc private func togglePrefersExternalGPU(_ sender: Any?) { gpuPolicy?.togglePrefersExternal() }
    @objc private func closeWindow(_ sender: Any?) { NSApp.keyWindow?.performClose(sender) }
    @objc private func closeAsking(_ sender: Any?) {
        (NSApp.keyWindow?.windowController as? DeviceWindowController)?.closeAsking()
    }
    @objc private func quitAsking(_ sender: Any?) { application?.quitAsking() }
    @objc private func showManagerSettings(_ sender: Any?) { application?.showManagerSettings() }
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

    /// Groups by runtime in catalog order; Option shows descriptive device names.
    static func items(for devices: [AvailableDevice], hasWindow: (SimulatorDeviceIdentifier) -> Bool,
                      action: Selector, target: AnyObject?) -> [NSMenuItem] {
        SimulatorDeviceMenu.items(for: devices.map {
            SimulatorMenuDevice(identifier: $0.identity, name: $0.name, descriptiveName: $0.descriptiveName,
                                runtimeIdentifier: $0.runtimeIdentifier, runtimeName: $0.runtimeName, state: $0.state)
        }, hasWindow: hasWindow, action: action, target: target)
    }

    @objc private func select(_ sender: NSMenuItem) {
        guard let application, let identifier = sender.representedObject as? SimulatorDeviceIdentifier else { return }
        Task {
            do { try await application.openSimulator(withIdentifier: identifier) }
            catch is CancellationError {}
            catch { NSAlert(error: error).runModal() }
        }
    }
}

/// Rebuilds locations from the key device's own runtime when opened.
@MainActor
final class LocationMenu: NSObject, NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        update(menu, for: DeviceWindowController.keyDeviceWindow)
    }

    /// Lists `window`'s choices, checking its selection. They are enabled
    /// while its device is connected and booted.
    func update(_ menu: NSMenu, for window: DeviceWindowController?) {
        let session = window?.session
        let choices = [("None", LocationSelection.none), ("Custom Location…", .custom)]
            + (session?.locationScenarios ?? []).map { ($0.localizedName, .scenario($0.name)) }
        menu.autoenablesItems = false
        menu.items = choices.map { title, selection in
            let item = NSMenuItem(title: title, action: #selector(select(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = selection
            item.state = session?.location == selection ? .on : .off
            item.isEnabled = session?.canPerformCommands == true
            return item
        }
    }

    @objc private func select(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? LocationSelection else { return }
        DeviceWindowController.keyDeviceWindow?.selectLocation(selection)
    }
}

/// Lists the key device's audio routes and the system default.
/// Selections are saved app-wide and apply to every device window.
@MainActor
final class AudioRouteMenu: NSObject, NSMenuDelegate {
    let scope: AudioScope
    /// The I/O menu's item.
    let item: NSMenuItem
    private let menu: NSMenu

    init(scope: AudioScope) {
        self.scope = scope
        let title = scope == .input ? "Audio Input" : "Audio Output"
        item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menu = NSMenu(title: title)
        super.init()
        menu.delegate = self
    }

    /// Attaches audio submenus only for devices with SimFeatureRoutableAudio.
    func attach(to window: DeviceWindowController?) {
        let routes = window?.session.routesAudio == true
        // AppKit leaves the enabling of an item with a submenu to the item.
        item.isEnabled = routes
        item.submenu = routes ? menu : nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        update(menu, for: DeviceWindowController.keyDeviceWindow)
    }

    /// Keeps choices available during restart for application on reconnection.
    /// Before the audio port reports, only an unchecked System item is shown.
    func update(_ menu: NSMenu, for window: DeviceWindowController?) {
        let session = window?.session
        let state = session?.audioRoutes
        let usesSystemDefault = state?.usesSystemDefault(in: scope) == true
        let selected = usesSystemDefault ? nil : state?.selectedDevice(in: scope)?.uid
        let system = (state?.defaultDevice(in: scope)).map { "System (\($0.name))" } ?? "System"
        let routes = [(system, AudioRouting.systemDefault, usesSystemDefault)]
            + (state?.devices(in: scope) ?? []).map { ($0.name, $0.uid, $0.uid == selected) }
        menu.autoenablesItems = false
        menu.items = routes.map { title, route, isChecked in
            let item = NSMenuItem(title: title, action: #selector(select(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = route
            item.state = isChecked ? .on : .off
            item.isEnabled = window != nil
            return item
        }
    }

    @objc private func select(_ sender: NSMenuItem) {
        guard let route = sender.representedObject as? String else { return }
        DeviceWindowController.keyDeviceWindow?.selectAudioRoute(route, in: scope)
    }
}

// AppKit consumes a matching key equivalent even when its item is disabled, so
// leave the standard editing shortcuts to the simulator while it has keyboard focus.
private final class EditMenu: NSMenu {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let window = event.window
        let simulatorHasFocus = MainActor.assumeIsolated {
            switch window?.windowController {
            case let controller as DeviceWindowController: window?.firstResponder === controller.session.display.inputView
            case let controller as ExternalDisplayWindowController: window?.firstResponder === controller.display.inputView
            default: false
            }
        }
        // Copy Screen's Control-Command-C is not an editing shortcut.
        return (!simulatorHasFocus || event.modifierFlags.contains(.control)) && super.performKeyEquivalent(with: event)
    }
}
