import AppKit
import XcodeSimulatorHost

@MainActor
enum SimulatorPairingMenu {
    enum Action {
        case pair(Set<DeviceInventoryID>)
        case newCompanion(DeviceInventoryID)
    }

    static func make(for device: SimulatorHostDevice, model: SimulatorManagerModel,
                     target: AnyObject, action: Selector) -> NSMenu {
        let pairsWatch = device.productFamily == "iPhone"
        let menu = NSMenu(title: pairsWatch ? "Pair Apple Watch" : "Pair iPhone")
        menu.autoenablesItems = false
        menu.addItem(.sectionHeader(title: "Simulators"))
        for candidate in model.pairingCandidates(for: device) {
            let identifiers: Set<DeviceInventoryID> = [device.inventoryID, candidate.inventoryID]
            let item = NSMenuItem(title: candidate.name, action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = Action.pair(identifiers)
            item.isEnabled = model.canManage(.pair, deviceIDs: identifiers)
            menu.addItem(item)
        }
        if menu.items.count > 1 { menu.addItem(.separator()) }
        let create = NSMenuItem(title: pairsWatch ? "New Watch Simulator…" : "New iPhone Simulator…", action: action, keyEquivalent: "")
        create.target = target
        create.representedObject = Action.newCompanion(device.inventoryID)
        create.isEnabled = model.canAddPairing(for: device) && device.deviceTypeIdentifier != nil
            && model.canManage(.pair, deviceIDs: [device.inventoryID])
        menu.addItem(create)
        return menu
    }
}
