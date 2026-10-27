import AppKit
import XcodeSimulatorHost

@MainActor
enum SimulatorPairingMenu {
    enum Action {
        case pair(Set<DeviceInventoryID>)
        case newWatch(DeviceInventoryID)
    }

    static func make(for phone: SimulatorHostDevice, model: SimulatorManagerModel,
                     target: AnyObject, action: Selector) -> NSMenu {
        let menu = NSMenu(title: "Pair Apple Watch")
        menu.autoenablesItems = false
        menu.addItem(.sectionHeader(title: "Simulators"))
        for watch in model.pairingWatches(for: phone) {
            let identifiers: Set<DeviceInventoryID> = [phone.inventoryID, watch.inventoryID]
            let item = NSMenuItem(title: watch.name, action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = Action.pair(identifiers)
            item.isEnabled = model.canManage(.pair, deviceIDs: identifiers)
            menu.addItem(item)
        }
        if menu.items.count > 1 { menu.addItem(.separator()) }
        let create = NSMenuItem(title: "New Watch Simulator…", action: action, keyEquivalent: "")
        create.target = target
        create.representedObject = Action.newWatch(phone.inventoryID)
        create.isEnabled = phone.isAvailable && phone.deviceTypeIdentifier != nil
            && model.canManage(.pair, deviceIDs: [phone.inventoryID])
        menu.addItem(create)
        return menu
    }
}
