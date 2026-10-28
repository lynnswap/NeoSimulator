import Foundation
import XcodeSimulatorHost

/// Presents known device information without replacing the inventory or inspector state.
struct DeviceInformation {
    enum Group: String, CaseIterable, Identifiable {
        case essential, device, hardware, connection, configuration
        var id: Self { self }
        var title: String {
            switch self {
            case .essential: "Essential Properties"
            case .device: "Device Properties"
            case .hardware: "Hardware Properties"
            case .connection: "Connection Properties"
            case .configuration: "Device Configuration"
            }
        }
    }

    struct Field: Identifiable {
        let id: [String]
        let title: String
        let value: String
        let group: Group
    }

    static let defaultFields: Set<[String]> = [
        ["name"], ["operatingSystem"], ["modelName"], ["udid"],
    ]

    static let legacySourcePaths: [[String]: [[String]]] = [
        ["name"]: [["name"], ["state", "name"]],
        ["operatingSystem"]: [["operatingSystem"], ["runtime", "name"], ["runtimeName"], ["software", "osVersionNumber", "stringValue"]],
        ["modelName"]: [["modelName"], ["modelIdentifier"], ["deviceTypeIdentifier"], ["hardware", "marketingName"],
                        ["hardware", "hardwareModel"], ["hardware", "productType"]],
        ["udid"]: [["udid"], ["hardware", "udid"]],
    ]

    let fields: [Field]

    init(device: InventoryDevice, properties: [String: DeviceInspectorValue]) {
        func string(_ path: [String]) -> String? {
            var value: DeviceInspectorValue? = .object(properties)
            for component in path { value = value?[component] }
            guard let result = value?.string, !result.isEmpty else { return nil }
            return result
        }
        var values: [Field] = []
        func append(_ id: String, title: String, value: String?, group: Group) {
            guard let value, !value.isEmpty else { return }
            values.append(Field(id: [id], title: title, value: value, group: group))
        }
        let remote: CoreDeviceDevice?
        if case .remote(let value) = device { remote = value } else { remote = nil }
        let name = string(["name"]) ?? string(["state", "name"]) ?? device.name
        let os: String?
        if let known = string(["operatingSystem"]) ?? string(["runtime", "name"]) ?? string(["runtimeName"]) {
            os = known
        } else if let version = string(["software", "osVersionNumber", "stringValue"]) {
            os = [remote?.platform, version].compactMap { $0 }.joined(separator: " ")
        } else { os = device.operatingSystem }
        let model = string(["modelName"]) ?? string(["hardware", "marketingName"]) ?? remote?.modelName
            ?? string(["modelIdentifier"]) ?? string(["hardware", "hardwareModel"]) ?? device.modelIdentifier
        let udid: String?
        if case .simulator(let simulator) = device {
            udid = string(["udid"]) ?? simulator.identifier
        } else { udid = string(["udid"]) ?? string(["hardware", "udid"]) ?? remote?.udid }
        append("name", title: "Name", value: name, group: .essential)
        append("operatingSystem", title: "OS", value: os, group: .essential)
        append("modelName", title: "Model", value: model, group: .hardware)
        append("udid", title: "UDID", value: udid, group: .hardware)

        func visit(_ value: DeviceInspectorValue, path: [String], title: String) {
            switch value {
            case .object(let children) where !children.isEmpty:
                for key in children.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
                    visit(children[key]!, path: path + [key], title: "\(title) / \(Self.title(for: key))")
                }
            case .array(let children) where !children.isEmpty:
                for (index, child) in children.enumerated() {
                    visit(child, path: path + [String(index)], title: "\(title) — Item \(index + 1)")
                }
            default:
                guard !Self.defaultFields.contains(path) else { return }
                values.append(Field(id: path, title: title, value: Self.display(value),
                                    group: Self.group(for: path)))
            }
        }
        for key in properties.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            visit(properties[key]!, path: [key], title: Self.title(for: key))
        }
        fields = values
    }

    static func pairedSimulators(for device: SimulatorHostDevice,
                                 in inventory: [InventoryDevice]) -> [SimulatorHostDevice] {
        inventory.compactMap { item in
            guard case .simulator(let candidate) = item,
                  candidate.identifier != device.identifier,
                  candidate.deviceSetPath == device.deviceSetPath,
                  !candidate.pairIdentifiers.isDisjoint(with: device.pairIdentifiers) else { return nil }
            return candidate
        }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.identifier < $1.identifier : order == .orderedAscending
        }
    }

    static func watchToUnpair(device: SimulatorHostDevice, partner: SimulatorHostDevice) -> SimulatorHostDevice? {
        if device.productFamily == "Apple Watch" { return device }
        if partner.productFamily == "Apple Watch" { return partner }
        return nil
    }

    private static func group(for path: [String]) -> Group {
        switch path.first {
        case "hardware", "deviceTypeIdentifier", "modelIdentifier": .hardware
        case "connection", "connectionState", "pairingState", "transportType": .connection
        case "software", "runtime", "runtimeIdentifier", "isAvailable", "availabilityError",
             "configuration", "deviceConfiguration": .configuration
        default: .device
        }
    }

    private static func title(for key: String) -> String {
        let names = [
            "udid": "UDID", "uuid": "UUID", "ecid": "ECID", "osVersion": "OS Version",
            "osVersionNumber": "OS Version", "osBuild": "OS Build", "osBuildUpdate": "OS Build",
            "osBuildVersions": "OS Builds", "buildVersion": "Build",
            "cpuType": "CPU Type", "ddiServicesAvailable": "DDI Services",
            "tunnelIPAddressString": "Tunnel IP Address", "rootFileSystemIsWritable": "Writable Root File System",
        ]
        return names[key] ?? key.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2",
                                                     options: .regularExpression).capitalized
    }

    private static func display(_ value: DeviceInspectorValue) -> String {
        switch value {
        case .object(let fields): "\(fields.count) properties"
        case .array(let values): "\(values.count) items"
        case .string(let value): value
        case .integer(let value): String(value)
        case .number(let value): String(value)
        case .boolean(let value): value ? "Yes" : "No"
        case .date(let value): value.formatted()
        case .data(let value): "\(value.count) bytes"
        case .null: "—"
        }
    }
}
