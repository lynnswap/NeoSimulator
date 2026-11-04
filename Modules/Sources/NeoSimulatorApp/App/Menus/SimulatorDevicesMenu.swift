import AppKit
@_spi(NeoSimulator) import XcodeSimulatorHost

@MainActor
final class SimulatorDevicesMenu: NSMenu, NSMenuDelegate {
    private let model: SimulatorManagerModel

    init(model: SimulatorManagerModel, title: String) {
        self.model = model
        super.init(title: title)
        delegate = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.items = SimulatorDeviceMenu.items(for: model.devices.map { device in
            let state: UInt = switch device.state {
            case "Booted": 3
            case "Booting": 2
            case "Shutdown": 1
            case "Shutting Down": 4
            default: 0
            }
            return SimulatorMenuDevice(identifier: device.inventoryID, name: device.name,
                descriptiveName: device.descriptiveName, runtimeIdentifier: device.runtimeIdentifier,
                runtimeName: device.runtimeName, state: state)
        }, hasWindow: { identifier in model.devices.first { $0.inventoryID == identifier }?.ownerXcodeURL != nil },
           action: #selector(openDevice(_:)), target: self)
        if menu.items.isEmpty {
            let item = NSMenuItem(title: model.isBusy ? model.activity : "No Simulators", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
    }

    @objc private func openDevice(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? DeviceInventoryID else { return }
        model.openDevice(identifier)
    }
}
