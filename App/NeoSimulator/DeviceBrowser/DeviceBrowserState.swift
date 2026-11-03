import Foundation
import Observation
import XcodeSimulatorHost

@MainActor @Observable
final class DeviceBrowserState {
    @ObservationIgnored private let defaults: UserDefaults

    var sidebarIsCollapsed: Bool {
        didSet { if sidebarIsCollapsed != oldValue { defaults.set(sidebarIsCollapsed, forKey: "SidebarIsCollapsed") } }
    }
    var inspectorIsCollapsed: Bool {
        didSet { if inspectorIsCollapsed != oldValue { defaults.set(inspectorIsCollapsed, forKey: "InspectorIsCollapsed") } }
    }
    var inspectorTab: Int {
        didSet { if inspectorTab != oldValue { defaults.set(inspectorTab, forKey: "InspectorTab") } }
    }
    var inspectorContent: DeviceInspectorModel.Content {
        didSet { if inspectorContent != oldValue { defaults.set(inspectorContent.rawValue, forKey: "InspectorContent") } }
    }
    var selectedDeviceIDs: Set<DeviceInventoryID> {
        didSet {
            guard selectedDeviceIDs != oldValue,
                  let data = try? PropertyListEncoder().encode(selectedDeviceIDs) else { return }
            defaults.set(data, forKey: "SidebarSelectedDevices")
        }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        sidebarIsCollapsed = defaults.bool(forKey: "SidebarIsCollapsed")
        inspectorIsCollapsed = defaults.bool(forKey: "InspectorIsCollapsed")
        let tab = defaults.integer(forKey: "InspectorTab")
        inspectorTab = (0..<4).contains(tab) ? tab : 0
        inspectorContent = DeviceInspectorModel.Content(rawValue: defaults.integer(forKey: "InspectorContent")) ?? .info
        selectedDeviceIDs = defaults.data(forKey: "SidebarSelectedDevices")
            .flatMap { try? PropertyListDecoder().decode(Set<DeviceInventoryID>.self, from: $0) } ?? []
    }
}
