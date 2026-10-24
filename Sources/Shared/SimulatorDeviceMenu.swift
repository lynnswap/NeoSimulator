import AppKit

enum SimulatorPreferences {
    static func migrateStandalonePreferences(defaults: UserDefaults = .standard,
                                             sourceDomain: String = "dev.lynnswap.NeoSimulator",
                                             targetDomain: String = "dev.lynnswap.NeoSimulator.Renderer") {
        let marker = "MigratedStandalonePreferences"
        var target = defaults.persistentDomain(forName: targetDomain) ?? [:]
        guard target[marker] as? Bool != true else { return }
        for (key, value) in defaults.persistentDomain(forName: sourceDomain) ?? [:] where target[key] == nil {
            target[key] = value
        }
        target[marker] = true
        defaults.setPersistentDomain(target, forName: targetDomain)
    }
}

struct SimulatorMenuDevice {
    let identifier: String
    let name: String
    let descriptiveName: String
    let runtimeIdentifier: String
    let runtimeName: String
    let state: UInt
}

@MainActor
enum SimulatorDeviceMenu {
    static func items(for devices: [SimulatorMenuDevice], hasWindow: (String) -> Bool,
                      action: Selector, target: AnyObject?) -> [NSMenuItem] {
        func deviceItems(_ device: SimulatorMenuDevice) -> [NSMenuItem] {
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
        var runtimes: [(identifier: String, name: String, devices: [SimulatorMenuDevice])] = []
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
