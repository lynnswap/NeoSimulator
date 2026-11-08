import Foundation
import NeoSimulatorDeviceScreens
import NeoSimulatorHostSupport
import NeoSimulatorKit
import NeoSimulatorManager
import Observation

/// Which devices the sidebar lists and which of them the user selects. The devices belong to the manager.
@MainActor @Observable
package final class DeviceSidebarModel {
    enum KindFilter: Int, CaseIterable {
        case all, simulators, physical, virtualMachines

        var title: String {
            switch self {
            case .all: "All Devices"
            case .simulators: "Simulators"
            case .physical: "Physical Devices"
            case .virtualMachines: "Virtual Machines"
            }
        }

        func includes(_ device: InventoryDevice) -> Bool {
            switch self {
            case .all: true
            case .simulators: device.kind == .simulator
            case .physical: device.kind == .physical
            case .virtualMachines: device.kind == .virtualMachine
            }
        }
    }

    enum AvailabilityFilter: Int, CaseIterable {
        case all, available, unavailable

        var title: String {
            switch self {
            case .all: "All Availability"
            case .available: "Available"
            case .unavailable: "Unavailable"
            }
        }

        func includes(_ device: InventoryDevice) -> Bool {
            switch self {
            case .all: true
            case .available: DeviceBrowserPresentation.isAvailable(device)
            case .unavailable: !DeviceBrowserPresentation.isAvailable(device)
            }
        }
    }

    /// What the sidebar shows when it lists no device.
    enum Status: Equatable {
        case loading, empty, noMatches(String), failure(String)
    }

    private static let selectionKey = "SidebarSelectedDevices"
    private static let collapsedGroupsKey = "SidebarCollapsedSectionIDs"

    var kindFilter = KindFilter.all
    var availabilityFilter = AvailabilityFilter.all
    var familyFilter: String?
    var query = ""
    var options: DeviceBrowserPresentation.Options {
        didSet { options.save(to: defaults) }
    }
    private(set) var collapsedGroups: Set<String> {
        didSet { if collapsedGroups != oldValue { defaults.set(collapsedGroups.sorted(), forKey: Self.collapsedGroupsKey) } }
    }
    /// The selection as the user left it, which can name devices that are gone.
    package private(set) var savedSelection: Set<DeviceInventoryID> {
        didSet {
            guard savedSelection != oldValue,
                  let data = try? PropertyListEncoder().encode(savedSelection) else { return }
            defaults.set(data, forKey: Self.selectionKey)
        }
    }
    @ObservationIgnored let manager: SimulatorManagerModel
    @ObservationIgnored private let defaults: UserDefaults

    package init(manager: SimulatorManagerModel, defaults: UserDefaults) {
        self.manager = manager
        self.defaults = defaults
        options = DeviceBrowserPresentation.Options(defaults: defaults)
        collapsedGroups = Set(defaults.stringArray(forKey: Self.collapsedGroupsKey) ?? [])
        savedSelection = defaults.data(forKey: Self.selectionKey)
            .flatMap { try? PropertyListDecoder().decode(Set<DeviceInventoryID>.self, from: $0) } ?? []
    }

    /// The selected devices that the inventory still has.
    package var selectedIdentifiers: Set<DeviceInventoryID> {
        savedSelection.intersection(manager.inventory.map(\.id))
    }

    /// The selected devices in the sidebar's order.
    package var selectedDevices: [InventoryDevice] {
        let selected = selectedIdentifiers
        return DeviceBrowserPresentation(devices: manager.inventory.filter { selected.contains($0.id) },
                                         sortOrder: options.sortOrder, activeStates: manager.activeStates).devices
    }

    /// The device that the window describes, when one alone is selected.
    package var selectedDevice: InventoryDevice? {
        let devices = selectedDevices
        return devices.count == 1 ? devices.first : nil
    }

    var isFiltering: Bool { kindFilter != .all || availabilityFilter != .all || familyFilter != nil }

    var filteredDevices: [InventoryDevice] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return manager.inventory.filter {
            kindFilter.includes($0) && availabilityFilter.includes($0)
                && (familyFilter == nil || $0.filterCategory == familyFilter)
                && (query.isEmpty || $0.name.localizedStandardContains(query)
                    || ($0.operatingSystem?.localizedStandardContains(query) ?? false)
                    || ($0.modelName?.localizedStandardContains(query) ?? false))
        }
    }

    /// The families the filter offers, which are those of every device.
    var families: [String] { Set(manager.inventory.map(\.filterCategory)).sorted() }

    var status: Status {
        guard manager.inventory.isEmpty else { return .noMatches(query) }
        if manager.isRefreshingInventory || manager.isBusy { return .loading }
        if let issue = manager.backgroundIssue { return .failure(issue) }
        return .empty
    }

    package func select(_ identifiers: Set<DeviceInventoryID>) {
        savedSelection = identifiers
    }

    func setCollapsed(_ collapsed: Bool, group: String) {
        if collapsed { collapsedGroups.insert(group) } else { collapsedGroups.remove(group) }
    }

    /// Opens the screen of the one device given, or stops opening it.
    package func open(_ devices: [InventoryDevice]) {
        guard devices.count == 1, let device = devices.first else { return }
        manager.toggleScreen(for: device)
    }

    func retryInventory() {
        Task { [manager] in await manager.retryInventory() }
    }
}
