import Foundation
import XcodeSimulatorHost

/// Sort-specific sidebar sections, independent of outline row and selection objects.
struct DeviceBrowserPresentation {
    enum SortOrder: Int, CaseIterable {
        case availability, recent, name, fidelity, platform, operatingSystem

        var title: String {
            switch self {
            case .availability: "Availability"
            case .recent: "Recent"
            case .name: "Name"
            case .fidelity: "Fidelity"
            case .platform: "Platform"
            case .operatingSystem: "Operating System"
            }
        }
    }

    struct Options {
        var sortOrder: SortOrder = .availability
        var showGroups = true

        init() {}

        init(defaults: UserDefaults) {
            if let value = defaults.object(forKey: "SidebarSortOrder") as? Int,
               let order = SortOrder(rawValue: value) { sortOrder = order }
            showGroups = defaults.object(forKey: "SidebarShowsGroups") as? Bool ?? true
        }

        func save(to defaults: UserDefaults) {
            defaults.set(sortOrder.rawValue, forKey: "SidebarSortOrder")
            defaults.set(showGroups, forKey: "SidebarShowsGroups")
        }
    }

    struct Section {
        let id: String
        let title: String
        let devices: [InventoryDevice]
    }

    let sections: [Section]
    var devices: [InventoryDevice] { sections.flatMap(\.devices) }

    init(devices: [InventoryDevice], sortOrder: SortOrder,
         calendar: Calendar = .current, locale: Locale = .current, now: Date = .now) {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.doesRelativeDateFormatting = true

        func key(_ device: InventoryDevice) -> String {
            switch sortOrder {
            case .availability: device.isAvailable ? "available" : "unavailable"
            case .recent: device.lastConnectionDate.map(formatter.string(from:)) ?? "Other"
            case .name: Self.nameGroup(Self.reportedName(device))
            case .fidelity: Self.reality(device)
            case .platform: Self.platform(device)?.raw ?? "unknown"
            case .operatingSystem:
                (Self.platform(device)?.display ?? "Other") + " " + (Self.version(device) ?? "Other")
            }
        }

        let grouped = Dictionary(grouping: devices, by: key)
        var keys = Array(grouped.keys)
        switch sortOrder {
        case .availability: keys.sort { $0 == "available" && $1 != "available" }
        case .recent:
            keys.sort {
                let lhs = grouped[$0]?.first?.lastConnectionDate ?? .distantPast
                let rhs = grouped[$1]?.first?.lastConnectionDate ?? .distantPast
                return lhs > rhs
            }
        case .fidelity: keys.sort { Self.realityTitle($0) < Self.realityTitle($1) }
        case .operatingSystem:
            keys.sort {
                guard let lhs = grouped[$0]?.first, let rhs = grouped[$1]?.first else { return false }
                let a = Self.platform(lhs)?.raw ?? "", b = Self.platform(rhs)?.raw ?? ""
                if a != b { return a < b }
                return Self.compareVersions(Self.version(lhs), Self.version(rhs)) == .orderedDescending
            }
        case .name:
            keys.sort {
                if ($0 == "Other") != ($1 == "Other") { return $0 == "Other" }
                if ($0 == "#") != ($1 == "#") { return $0 != "#" }
                return $0 < $1
            }
        case .platform: keys.sort()
        }
        sections = keys.map { key in
            let members = (grouped[key] ?? []).sorted { Self.precedes($0, $1, order: sortOrder, calendar: calendar, now: now) }
            let title: String = switch sortOrder {
            case .availability: key == "available" ? "Available" : "Unavailable"
            case .fidelity: Self.realityTitle(key)
            case .platform: members.first.flatMap(Self.platform)?.display ?? "Other"
            case .recent, .name, .operatingSystem: key
            }
            return Section(id: key, title: title, devices: members)
        }
    }

    static func nameGroup(_ name: String?) -> String {
        guard let name else { return "Other" }
        guard let first = name.trimmingCharacters(in: .whitespaces).first, first.isLetter else { return "#" }
        return first.uppercased()
    }

    private static func reportedName(_ device: InventoryDevice) -> String? {
        switch device {
        case .simulator(let simulator): simulator.name
        case .remote(let remote): remote.reportedName
        }
    }

    private static func reality(_ device: InventoryDevice) -> String {
        switch device.kind {
        case .physical: "physical"
        case .simulator: "simulated"
        case .virtualMachine: "virtual"
        case .other(let value): value
        }
    }

    private static func realityTitle(_ reality: String) -> String {
        switch reality {
        case "physical": "Physical Devices"
        case "simulated": "Simulators"
        case "virtual": "Virtual Machines"
        default: "Other"
        }
    }

    private static func platform(_ device: InventoryDevice) -> (raw: String, display: String)? {
        let value: String?
        switch device {
        case .simulator(let simulator):
            value = simulator.coreDevice?.platform ?? simulator.runtimeName.split(separator: " ").first.map(String.init)
        case .remote(let remote): value = remote.platform
        }
        return value.map { (raw: $0, display: $0) }
    }

    private static func version(_ device: InventoryDevice) -> String? {
        switch device {
        case .simulator(let simulator):
            simulator.coreDevice?.osVersion
                ?? simulator.runtimeName.split(separator: " ").first { $0.first?.isNumber == true }.map(String.init)
        case .remote(let remote): remote.osVersion
        }
    }

    private static func compareVersions(_ lhs: String?, _ rhs: String?) -> ComparisonResult {
        switch (lhs, rhs) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedAscending
        case (_, nil): return .orderedDescending
        case (.some(let lhs), .some(let rhs)):
            let a = lhs.split(separator: ".", omittingEmptySubsequences: false).map { UInt($0) }
            let b = rhs.split(separator: ".", omittingEmptySubsequences: false).map { UInt($0) }
            if a.allSatisfy({ $0 != nil }), b.allSatisfy({ $0 != nil }) {
                for index in 0..<max(a.count, b.count) {
                    let x = index < a.count ? a[index]! : 0
                    let y = index < b.count ? b[index]! : 0
                    if x != y { return x < y ? .orderedAscending : .orderedDescending }
                }
                return .orderedSame
            }
            return lhs.compare(rhs, options: .numeric)
        }
    }

    private static func precedes(_ lhs: InventoryDevice, _ rhs: InventoryDevice, order: SortOrder,
                                 calendar: Calendar, now: Date) -> Bool {
        let names = (reportedName(lhs) ?? "").localizedCaseInsensitiveCompare(reportedName(rhs) ?? "")
        if order == .name, names != .orderedSame { return names == .orderedAscending }
        // Inventory does not contain DeviceKit's transient presentation-active state.
        if lhs.isAvailable != rhs.isAvailable { return lhs.isAvailable }
        if order != .recent {
            let a = calendar.startOfDay(for: lhs.lastConnectionDate ?? now)
            let b = calendar.startOfDay(for: rhs.lastConnectionDate ?? now)
            if a != b { return a > b }
            let kinds = realityTitle(reality(lhs)).localizedCaseInsensitiveCompare(realityTitle(reality(rhs)))
            if kinds != .orderedSame { return kinds == .orderedAscending }
            let aPlatform = platform(lhs)?.raw ?? "", bPlatform = platform(rhs)?.raw ?? ""
            if aPlatform != bPlatform { return aPlatform < bPlatform }
        }
        if names != .orderedSame { return names == .orderedAscending }
        return stableKey(lhs.id) < stableKey(rhs.id)
    }

    private static func stableKey(_ identifier: DeviceInventoryID) -> String {
        switch identifier {
        case .simulator(let udid, let path): "simulator:\(udid):\(path.map { "set:\($0)" } ?? "default")"
        case .coreDevice(let identifier): "coredevice:\(identifier)"
        }
    }
}
