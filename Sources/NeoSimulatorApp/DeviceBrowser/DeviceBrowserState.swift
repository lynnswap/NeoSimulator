import NeoSimulatorKit
import NeoSimulatorHostSupport
import Foundation
import Observation

@MainActor @Observable
final class DeviceBrowserState {
    @ObservationIgnored private let defaults: UserDefaults

    var selectedDeviceIDs: Set<DeviceInventoryID> {
        didSet {
            guard selectedDeviceIDs != oldValue,
                  let data = try? PropertyListEncoder().encode(selectedDeviceIDs) else { return }
            defaults.set(data, forKey: "SidebarSelectedDevices")
        }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        selectedDeviceIDs = defaults.data(forKey: "SidebarSelectedDevices")
            .flatMap { try? PropertyListDecoder().decode(Set<DeviceInventoryID>.self, from: $0) } ?? []
    }
}
