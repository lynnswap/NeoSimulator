import AppKit

@MainActor
enum SimulatorDeviceMenu {
    static func items<ID: Hashable>(for devices: [SimulatorMenuDevice<ID>], hasWindow: (ID) -> Bool,
                      action: Selector, target: AnyObject?) -> [NSMenuItem] {
        func deviceItems(_ device: SimulatorMenuDevice<ID>) -> [NSMenuItem] {
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
        var runtimes: [(identifier: String, name: String, devices: [SimulatorMenuDevice<ID>])] = []
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
}
