import AppKit
import NeoSimulatorCompactWindow
import NeoSimulatorDeviceScreens
import NeoSimulatorDeviceIO
import NeoSimulatorHostSupport
import NeoSimulatorKit
import NeoSimulatorManager
import NeoSimulatorPresentationAdapters

/// Fills the window's menus with device commands, and asks in sheets on the window for what a command needs.
@MainActor
final class DeviceActions: NSObject {
    private struct ManagementRequest {
        let action: DeviceManagementAction
        let identifiers: Set<DeviceInventoryID>
        weak var window: NSWindow? = nil
    }

    private let model: SimulatorManagerModel
    private weak var window: NSWindow?
    /// The screen that the window shows, which takes a remote device's Lock command.
    private let liveScreen: () -> DeviceScreen?
    var onNewCompanion: ((SimulatorHostDevice) -> Void)?
    var openDeviceWindow: ((InventoryDevice, NSWindow?, Bool) -> Void)?
    var showDeviceInFinder: (InventoryDevice) async throws -> Void = { device in
        switch device {
        case .simulator(let simulator):
            let root: URL
            if let path = simulator.deviceSetPath {
                root = URL(fileURLWithPath: path, isDirectory: true)
            } else {
                let xcode: URL
                if let known = simulator.catalogXcodeURL ?? simulator.ownerXcodeURL {
                    xcode = known
                } else {
                    xcode = try await CoreDeviceRuntime.uiXcodeURL()
                }
                let set = try await SimulatorDeviceSet.load(xcodeURL: xcode)
                root = URL(fileURLWithPath: try await set.resolvedPath(), isDirectory: true)
            }
            let directory = root.appending(path: simulator.identifier, directoryHint: .isDirectory)
            _ = try FileManager.default.attributesOfItem(atPath: directory.path)
            NSWorkspace.shared.activateFileViewerSelecting([directory])
        case .remote(let remote):
            guard let identifier = UUID(uuidString: remote.identifier) else {
                throw DeviceIOError.unavailable("device-finder", "The device has no CoreDevice UUID.")
            }
            try await DeviceKitFinder.showDevice(identifier: identifier)
        }
    }

    private struct NavigationRequest {
        let identifier: DeviceInventoryID
        weak var window: NSWindow?
    }

    init(model: SimulatorManagerModel, window: NSWindow?, liveScreen: @escaping () -> DeviceScreen?) {
        self.model = model
        self.window = window
        self.liveScreen = liveScreen
    }

    func populate(_ menu: NSMenu, devices: [InventoryDevice], includesViewScreen: Bool = true, window: NSWindow? = nil)
    {
        menu.removeAllItems()
        let identifiers = Set(devices.map(\.id))
        if devices.count == 1, model.canStopScreenSharing(devices[0]) {
            let item = NSMenuItem(
                title: "Stop Screen Sharing", action: #selector(stopScreenSharing(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = devices[0].id
            menu.addItem(item)
        } else if includesViewScreen, devices.count == 1, model.canViewScreen(devices[0]) {
            let title = model.openingDeviceIDs.contains(devices[0].id) ? "Cancel Opening" : "View Screen"
            let item = NSMenuItem(title: title, action: #selector(openDeviceFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NavigationRequest(identifier: devices[0].id, window: window)
            item.isEnabled = true
            menu.addItem(item)
        }
        if devices.count == 1, case .remote = devices[0], let screen = liveScreen(), screen.id == devices[0].id,
           let controller = screen.commandTarget as? RemoteDeviceWindowController {
            let item = NSMenuItem(title: "Lock", action: #selector(lockDeviceFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = devices[0].id
            item.isEnabled = controller.isScreenActionEnabled("lock")
            menu.addItem(item)
        }
        let name = devices.first?.name ?? ""
        func addManagement(_ section: [(String, DeviceManagementAction)], separated: Bool = true) {
            let operations = section.filter { model.supports($0.1, devices: devices) }
            guard !operations.isEmpty else { return }
            if separated && !menu.items.isEmpty { menu.addItem(.separator()) }
            for (title, action) in operations {
                let item = NSMenuItem(title: title, action: #selector(performManagement(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = ManagementRequest(action: action, identifiers: identifiers, window: window)
                item.isEnabled = model.canManage(action, deviceIDs: identifiers)
                menu.addItem(item)
            }
        }
        addManagement([
            ("Start", .start), ("Shut Down", .shutdown), ("Force Shut Down", .forceShutdown),
            ("Restart", .restart), ("Pause", .pause), ("Resume", .resume),
        ])
        var hasFinder = false
        if devices.count == 1 {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            for (title, action) in [
                ("Open in New Tab", #selector(openInNewTab(_:))),
                ("Open in New Window", #selector(openInNewWindow(_:))),
            ] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                item.representedObject = NavigationRequest(identifier: devices[0].id, window: window)
                item.isEnabled = openDeviceWindow != nil
                menu.addItem(item)
            }
            hasFinder =
                switch devices[0] {
                case .simulator: true
                case .remote(let remote): remote.pairingState == "paired"
                }
            if hasFinder {
                menu.addItem(.separator())
                let item = NSMenuItem(title: "Show in Finder", action: #selector(showInFinder(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = devices[0].id
                menu.addItem(item)
            }
        }
        addManagement([("Rename…", .rename(name)), ("Clone…", .clone("\(name) Copy"))], separated: !hasFinder)
        let unpairTitle = devices.contains { if case .remote = $0 { true } else { false } } ? "Unpair…" : "Unpair"
        addManagement([("Pair Simulators", .pair), (unpairTitle, .unpair)])
        addManagement([("Reset Content and Settings…", .erase)])
        addManagement([("Remove…", .remove)])
        if menu.items.isEmpty {
            let item = NSMenuItem(title: devices.isEmpty ? "No Devices Selected" : "No Actions Available", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
    }

    /// The commands beside the device's screen, with symbols, for the toolbar's pull-down menu.
    func populateScreenMenu(_ menu: NSMenu, for device: InventoryDevice) {
        menu.removeAllItems()
        // NSMenuToolbarItem's pull-down cell hides the first item as its button title.
        defer { menu.insertItem(NSMenuItem(title: "", action: nil, keyEquivalent: ""), at: 0) }
        if case .remote = device {
            populate(menu, devices: [device], includesViewScreen: false)
            return
        }
        func add(_ title: String, symbol: String, action: DeviceManagementAction, alternate: Bool = false) {
            guard device.supports(action) else { return }
            let item = NSMenuItem(title: title, action: #selector(performManagement(_:)), keyEquivalent: "")
            item.target = self
            item.image = NSImage.deviceControlSymbol(named: symbol, accessibilityDescription: title)
            item.representedObject = ManagementRequest(action: action, identifiers: [device.id])
            item.isEnabled = model.canManage(action, deviceIDs: [device.id])
            item.keyEquivalentModifierMask = []
            item.isAlternate = alternate
            if alternate { item.keyEquivalentModifierMask = .option }
            menu.addItem(item)
        }
        func separate() { if !menu.items.isEmpty { menu.addItem(.separator()) } }
        add("Start", symbol: "play", action: .start)
        add("Shut Down", symbol: "power", action: .shutdown)
        add("Force Shut Down", symbol: "power", action: .forceShutdown, alternate: device.supports(.shutdown))
        if device.supports(.restart) {
            separate()
            add("Restart", symbol: "restart", action: .restart)
        }
        if device.supports(.rename(device.name)) {
            separate()
            add("Rename…", symbol: "pencil", action: .rename(device.name))
        }
        if device.supports(.erase) {
            separate()
            add("Reset Content and Settings…", symbol: "eraser", action: .erase)
        }
        if case .simulator(let phone) = device, phone.productFamily == "iPhone", device.supports(.pair) {
            separate()
            let pairing = NSMenuItem(title: "Pair Apple Watch", action: nil, keyEquivalent: "")
            pairing.image = NSImage.deviceControlSymbol(named: "iphone.and.applewatch", accessibilityDescription: pairing.title)
            let submenu = pairingMenu(for: phone)
            pairing.submenu = submenu
            pairing.isEnabled = submenu.items.contains { $0.action != nil && $0.isEnabled }
            menu.addItem(pairing)
        }
        if device.supports(.remove) {
            separate()
            add("Remove…", symbol: "trash", action: .remove)
        }
    }

    func pairingMenu(for device: SimulatorHostDevice) -> NSMenu {
        SimulatorPairingMenu.make(for: device, model: model, target: self, action: #selector(performPairingMenuAction(_:)))
    }

    @objc func performPairingMenuAction(_ sender: NSMenuItem) {
        switch sender.representedObject as? SimulatorPairingMenu.Action {
        case .pair(let identifiers):
            let devices = model.inventory.filter { identifiers.contains($0.id) }
            guard model.supports(.pair, devices: devices),
                  let phone = devices.compactMap({ if case .simulator(let device) = $0, device.productFamily == "iPhone" { device } else { nil } }).first,
                  model.pairingCandidates(for: phone).contains(where: { identifiers.contains($0.inventoryID) }),
                  model.canManage(.pair, deviceIDs: identifiers) else { return }
            model.manage(.pair, devices: devices)
        case .newCompanion(let identifier):
            guard let device = model.inventory.first(where: { $0.id == identifier }),
                  case .simulator(let simulator) = device, model.canAddPairing(for: simulator),
                  model.canManage(.pair, deviceIDs: [identifier]) else { return }
            onNewCompanion?(simulator)
        case nil: break
        }
    }

    @objc private func openInNewTab(_ sender: NSMenuItem) { openDeviceWindow(from: sender, asTab: true) }
    @objc private func openInNewWindow(_ sender: NSMenuItem) { openDeviceWindow(from: sender, asTab: false) }

    private func openDeviceWindow(from sender: NSMenuItem, asTab: Bool) {
        guard let request = sender.representedObject as? NavigationRequest,
            let device = model.inventory.first(where: { $0.id == request.identifier })
        else { return }
        openDeviceWindow?(device, request.window ?? window, asTab)
    }

    @objc private func showInFinder(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? DeviceInventoryID,
            let device = model.inventory.first(where: { $0.id == identifier })
        else { return }
        Task {
            do { try await showDeviceInFinder(device) } catch { model.onError?(error) }
        }
    }

    @objc private func openDeviceFromMenu(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? NavigationRequest,
            let device = model.inventory.first(where: { $0.id == request.identifier })
        else { return }
        model.toggleScreen(for: device, revealingInMainWindow: request.window == nil || request.window === window)
    }

    @objc private func stopScreenSharing(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? DeviceInventoryID,
            let device = model.inventory.first(where: { $0.id == identifier })
        else { return }
        model.stopScreenSharing(for: device)
    }

    @objc private func lockDeviceFromMenu(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? DeviceInventoryID,
              let screen = liveScreen(), screen.id == identifier else { return }
        screen.perform("lock")
    }

    @objc private func performManagement(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? ManagementRequest else { return }
        let devices = model.inventory.filter { request.identifiers.contains($0.id) }
        guard devices.count == request.identifiers.count, model.supports(request.action, devices: devices),
              model.canManage(request.action, deviceIDs: request.identifiers) else { return }
        switch request.action {
        case .rename: presentNameEditor(for: devices[0], cloning: false, in: request.window)
        case .clone: presentNameEditor(for: devices[0], cloning: true, in: request.window)
        case .erase, .remove: confirmManagement(request.action, devices: devices, in: request.window)
        case .unpair where devices.contains(where: { if case .remote = $0 { true } else { false } }):
            confirmManagement(request.action, devices: devices, in: request.window)
        case .start:
            // A simulator starts as its screen opens, as Start on a stopped simulator's screen does.
            for device in devices where device.id.isSimulator { model.openScreen(for: device) }
            let others = devices.filter { !$0.id.isSimulator }
            if !others.isEmpty { model.manage(.start, devices: others) }
        default: model.manage(request.action, devices: devices)
        }
    }

    func presentLocationEditor(for identifier: DeviceInventoryID, latitude: String = "0", longitude: String = "0") {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Set Location"
        alert.informativeText = "Enter a latitude and longitude for the selected device."
        alert.addButton(withTitle: "Set Location")
        alert.addButton(withTitle: "Cancel")
        let latitudeField = NSTextField(string: latitude)
        let longitudeField = NSTextField(string: longitude)
        for field in [latitudeField, longitudeField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 190).isActive = true
        }
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Latitude:"), latitudeField],
            [NSTextField(labelWithString: "Longitude:"), longitudeField],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing
        grid.frame.size = grid.fittingSize
        alert.accessoryView = grid
        alert.window.initialFirstResponder = latitudeField
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            guard let latitude = Double(latitudeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let longitude = Double(longitudeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
                  (-90...90).contains(latitude), (-180...180).contains(longitude) else {
                let invalid = NSAlert()
                invalid.messageText = "Enter valid coordinates."
                invalid.informativeText = "Latitude must be between −90 and 90. Longitude must be between −180 and 180."
                invalid.runModal()
                self.presentLocationEditor(for: identifier, latitude: latitudeField.stringValue, longitude: longitudeField.stringValue)
                return
            }
            self.model.setLocation(latitude: latitude, longitude: longitude, for: identifier)
        }
    }

    private func presentNameEditor(for device: InventoryDevice, cloning: Bool, in presentingWindow: NSWindow?) {
        guard let window = presentingWindow ?? window else { return }
        let alert = NSAlert()
        alert.messageText = cloning ? "Clone \(device.name)" : "Rename \(device.name)"
        alert.informativeText = cloning ? "Enter a name for the new simulator." : "Enter a new device name."
        alert.addButton(withTitle: cloning ? "Clone" : "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: cloning ? "\(device.name) Copy" : device.name)
        field.frame.size = NSSize(width: 300, height: field.fittingSize.height)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let submit = alert.buttons[0]
        let observer = NotificationCenter.default.addObserver(forName: NSControl.textDidChangeNotification,
            object: field, queue: .main) { _ in
                MainActor.assumeIsolated { submit.isEnabled = !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            }
        alert.beginSheetModal(for: window) { [weak self] response in
            NotificationCenter.default.removeObserver(observer)
            guard response == .alertFirstButtonReturn, let self else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, let current = self.model.inventory.first(where: { $0.id == device.id }) else { return }
            self.model.manage(cloning ? .clone(name) : .rename(name), devices: [current])
        }
    }

    private func confirmManagement(
        _ action: DeviceManagementAction, devices: [InventoryDevice], in presentingWindow: NSWindow?
    ) {
        guard let window = presentingWindow ?? window else { return }
        let removing: Bool
        if case .remove = action { removing = true } else { removing = false }
        let subject = devices.count == 1 ? "“\(devices[0].name)”" : "\(devices.count) devices"
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText =
            action == .unpair ? "Unpair \(subject)?" : removing ? "Remove \(subject)?" : "Erase \(subject)?"
        if action == .unpair {
            alert.informativeText =
                "The selected pairing relationships will be removed. Physical devices will need to pair with this Mac again before sharing their screens."
        } else if removing {
            alert.informativeText = devices.contains { $0.kind == .virtualMachine }
                ? "The selected devices and their stored data will be permanently removed. Removing a virtual machine also deletes its associated assets. This cannot be undone."
                : "The selected devices and their data will be permanently removed. This cannot be undone."
        } else {
            alert.informativeText = "All content and settings on the selected devices will be permanently erased. This cannot be undone."
        }
        alert.addButton(withTitle: action == .unpair ? "Unpair" : removing ? "Remove" : "Erase")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let identifiers = Set(devices.map(\.id))
            let current = self.model.inventory.filter { identifiers.contains($0.id) }
            guard current.count == identifiers.count else { return }
            self.model.manage(action, devices: current)
        }
    }
}
