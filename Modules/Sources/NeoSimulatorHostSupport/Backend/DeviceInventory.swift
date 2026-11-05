import NeoSimulatorKit
import Foundation

package enum InventoryDevice: Equatable, Sendable, Identifiable {
    case simulator(SimulatorHostDevice)
    case remote(CoreDeviceDevice)

    package var id: DeviceInventoryID {
        switch self {
        case .simulator(let device): .simulator(udid: device.identifier, deviceSetPath: device.deviceSetPath)
        case .remote(let device): .coreDevice(device.identifier)
        }
    }

    package var kind: DeviceInventoryKind {
        switch self {
        case .simulator: .simulator
        case .remote(let device): device.kind
        }
    }

    package var name: String {
        switch self {
        case .simulator(let device): device.name
        case .remote(let device): device.name
        }
    }

    package var modelIdentifier: String? {
        switch self {
        case .simulator(let device): device.modelIdentifier
        case .remote(let device): device.modelIdentifier
        }
    }

    package var operatingSystem: String? {
        switch self {
        case .simulator(let device): device.runtimeName
        case .remote(let device):
            [device.platform, device.osVersion].compactMap { $0 }.joined(separator: " ").nilIfEmpty
        }
    }

    package var isAvailable: Bool {
        switch self {
        case .simulator(let device): device.isAvailable
        case .remote(let device): device.isAvailable
        }
    }

    package var capabilities: Set<String> {
        switch self {
        case .simulator(let device): device.capabilities
        case .remote(let device): device.capabilities
        }
    }

    /// Latest known creation, use, or connection time for the device.
    package var lastActivityDate: Date? {
        switch self {
        case .simulator(let device):
            [device.createdAt, device.lastUsedAt, device.coreDevice?.lastConnectedAt].compactMap { $0 }.max()
        case .remote(let device): device.lastConnectedAt
        }
    }

    /// CoreDevice connection time; custom device sets do not borrow default-set metadata.
    package var lastConnectionDate: Date? {
        switch self {
        case .simulator(let device): device.coreDevice?.lastConnectedAt
        case .remote(let device): device.lastConnectedAt
        }
    }
}

package struct DeviceInventoryIssue: Sendable {
    package enum Source: Equatable, Sendable {
        /// A nil Xcode means installation discovery failed before any catalog could be read.
        case simulators(xcodeURL: URL?, deviceSetPath: String?)
        case coreDevice
        case rendererOwnership
    }

    package let source: Source
    package let error: any Error
}

/// Devices from successful sources remain present when another source fails.
package struct DeviceInventorySnapshot: Sendable {
    package let devices: [InventoryDevice]
    package let issues: [DeviceInventoryIssue]

    package init(devices: [InventoryDevice], issues: [DeviceInventoryIssue]) {
        self.devices = devices
        self.issues = issues
    }
}

extension SimulatorHostController {
    /// Reads simulator catalogs and one CoreDevice snapshot without joining the renderer-operation FIFO.
    /// Inventory I/O executes outside this actor; existing renderer registrations remain the ownership source.
    package func inventory() async -> DeviceInventorySnapshot {
        async let snapshot = DeviceInventoryReader(
            readSimulators: { await Self.readSimulatorInventory() },
            readCoreDevices: Self.readCoreDeviceInventory
        ).read()
        let owners: [RendererRegistration]
        var issues: [DeviceInventoryIssue] = []
        do { owners = try await registeredRenderers() }
        catch {
            owners = []
            issues.append(DeviceInventoryIssue(source: .rendererOwnership, error: error))
        }
        let result = await snapshot
        let devices = result.devices.map { item -> InventoryDevice in
            guard case .simulator(let device) = item else { return item }
            return .simulator(device.inventoryCopy(owners: owners))
        }
        return DeviceInventorySnapshot(devices: devices, issues: result.issues + issues)
    }

    @concurrent
    package static func readCoreDeviceInventory() async throws -> Data {
        let result = try SystemCommandRunner().run(
            executable: URL(fileURLWithPath: "/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/Resources/bin/devicectl"),
            arguments: ["list", "devices", "--omit-deprecated-fields-in-json", "--json-output", "-", "--quiet", "--timeout", "10"]
        )
        guard result.terminationStatus == 0 else {
            throw CLIError.io("coredevice-inventory", result.stderrText.isEmpty ? result.stdoutText : result.stderrText)
        }
        return result.stdout
    }

    @concurrent
    private static func readSimulatorInventory() async -> DeviceInventorySnapshot {
        let installations: [XcodeInstallation]
        do { installations = try XcodeInstallationInspector().discoverXcodes() }
        catch { return DeviceInventorySnapshot(devices: [], issues: [.init(source: .simulators(xcodeURL: nil, deviceSetPath: nil), error: error)]) }
        let testingPath = SimulatorDeviceSets.testingPath().flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
        return SimulatorInventoryReader(
            installations: installations.map(\.applicationURL), testingDeviceSetPath: testingPath,
            readCatalog: { xcode, path in
                let output = try SystemCommandRunner().runSimctl(xcodeURL: xcode, arguments: ["list", "--json"], deviceSetPath: path)
                guard output.terminationStatus == 0 else { throw CLIError.io("simulator-inventory", output.stderrText.isEmpty ? output.stdoutText : output.stderrText) }
                return output.stdout
            }
        ).read()
    }
}

/// Uses the production join and partial-result paths with replaceable source I/O.
package struct DeviceInventoryReader: Sendable {
    package var readSimulators: @Sendable () async -> DeviceInventorySnapshot
    package var readCoreDevices: @Sendable () async throws -> Data

    package func read() async -> DeviceInventorySnapshot {
        async let simulators = readSimulators()
        let records: [CoreDeviceDevice]
        var issues: [DeviceInventoryIssue] = []
        do { records = try CoreDeviceInventoryDecoder.decode(await readCoreDevices()) }
        catch {
            records = []
            issues.append(DeviceInventoryIssue(source: .coreDevice, error: error))
        }
        let snapshot = await simulators
        let simulated = Dictionary(records.filter { $0.kind == .simulator }.map { ($0.udid ?? $0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        let devices = snapshot.devices.map { item -> InventoryDevice in
            guard case .simulator(let device) = item, device.deviceSetPath == nil,
                  let record = simulated[device.identifier] else { return item }
            return .simulator(device.inventoryCopy(ownerXcodeURL: device.ownerXcodeURL, coreDevice: record))
        } + records.filter { $0.kind != .simulator }.map(InventoryDevice.remote)
        return DeviceInventorySnapshot(devices: devices, issues: snapshot.issues + issues)
    }
}

package struct SimulatorInventoryReader {
    package var installations: [URL]
    package var testingDeviceSetPath: String?
    package var readCatalog: (URL, String?) throws -> Data

    package func read() -> DeviceInventorySnapshot {
        var devices: [InventoryDevice] = []
        var positions: [DeviceInventoryID: Int] = [:]
        var issues: [DeviceInventoryIssue] = []
        for xcode in installations {
            let paths: [String?] = testingDeviceSetPath.map { [nil, $0] } ?? [nil]
            for path in paths {
                do {
                    for device in try SimulatorDeviceCatalog.decode(readCatalog(xcode, path), deviceSetPath: path,
                                                                    includeUnavailable: true, catalogXcodeURL: xcode) {
                        let item = InventoryDevice.simulator(device)
                        if let position = positions[item.id] {
                            if !devices[position].isAvailable && item.isAvailable { devices[position] = item }
                        } else {
                            positions[item.id] = devices.count
                            devices.append(item)
                        }
                    }
                } catch { issues.append(.init(source: .simulators(xcodeURL: xcode, deviceSetPath: path), error: error)) }
            }
        }
        return DeviceInventorySnapshot(devices: devices, issues: issues)
    }
}

extension SimulatorHostDevice {
    package func inventoryCopy(owners: [RendererRegistration]) -> Self {
        let owner = owners.first { $0.deviceIdentifiers.contains(inventoryID) }
        return inventoryCopy(ownerXcodeURL: owner.map { URL(fileURLWithPath: $0.xcodePath) })
    }

    package func inventoryCopy(ownerXcodeURL: URL?, capabilities: Set<String>? = nil, coreDevice: CoreDeviceDevice? = nil) -> Self {
        Self(identifier: identifier, name: name, descriptiveName: descriptiveName, runtimeIdentifier: runtimeIdentifier,
             runtimeName: runtimeName, productFamily: productFamily, state: state, ownerXcodeURL: ownerXcodeURL,
             catalogXcodeURL: catalogXcodeURL, deviceSetPath: deviceSetPath, modelIdentifier: modelIdentifier, deviceTypeIdentifier: deviceTypeIdentifier,
             isAvailable: isAvailable,
             lastUsedAt: lastUsedAt, createdAt: createdAt, capabilities: capabilities ?? coreDevice?.capabilities ?? self.capabilities, pairIdentifiers: pairIdentifiers,
             activePairedDeviceID: activePairedDeviceID, coreDevice: coreDevice ?? self.coreDevice)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Decodes the current properties schema only; deprecated hardware/device/connection fields are ignored.
package enum CoreDeviceInventoryDecoder {
    private struct Response: Decodable {
        struct Result: Decodable { let devices: [Device] }
        let result: Result
    }

    private struct Device: Decodable {
        struct Capability: Decodable { let featureIdentifier: String }
        let identifier: String
        let properties: Properties
        let capabilities: [Capability]?
        let visibilityClass: String?
    }

    private struct Properties: Decodable {
        struct Hardware: Decodable {
            struct CPU: Decodable { let type: UInt64; let subtype: UInt64 }
            let fidelity: String
            let udid: String?
            let productType: String?
            let marketingName: String?
            let cpuType: CPU?
            let osPlatform: String?

            private enum CodingKeys: String, CodingKey {
                case fidelity, reality, udid, productType, marketingName, cpuType, osPlatform, platform
            }

            init(from decoder: any Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                // The host's CoreDevice installation supplies these names, independently of the selected Xcode.
                fidelity = try values.decodeIfPresent(String.self, forKey: .fidelity)
                    ?? values.decode(String.self, forKey: .reality)
                udid = try values.decodeIfPresent(String.self, forKey: .udid)
                productType = try values.decodeIfPresent(String.self, forKey: .productType)
                marketingName = try values.decodeIfPresent(String.self, forKey: .marketingName)
                cpuType = try values.decodeIfPresent(CPU.self, forKey: .cpuType)
                osPlatform = try values.decodeIfPresent(String.self, forKey: .osPlatform)
                    ?? values.decodeIfPresent(String.self, forKey: .platform)
            }
        }
        struct Software: Decodable {
            struct Version: Decodable { let stringValue: String }
            struct Builds: Decodable {
                struct Build: Decodable { let name: String }
                /// BuildUpdate's compared fields, with CoreDevice's Codable keys and types.
                struct Update: Decodable {
                    struct Revision: Decodable {
                        struct Extra: Decodable { let versionExtraString: String }
                        let components: [UInt]
                        let extraInfo: Extra?
                    }
                    let trainProgram: String?
                    let revisionVersion: Revision?
                    let factoryIdentifier: UInt?
                }
                private enum CodingKeys: String, CodingKey { case buildVersion, supplementalBuildVersion }
                let buildVersion: Build?
                let update: CoreDeviceBuildUpdate?

                init(from decoder: any Decoder) throws {
                    let values = try decoder.container(keyedBy: CodingKeys.self)
                    buildVersion = try values.decodeIfPresent(Build.self, forKey: .buildVersion)
                    // DeviceInfo.osBuildUpdate reads a reported supplemental build without falling back.
                    let key: CodingKeys = (try? values.decodeNil(forKey: .supplementalBuildVersion)) == false
                        ? .supplementalBuildVersion : .buildVersion
                    // Unusable comparison metadata leaves the device and its display build intact.
                    update = (try? values.decodeIfPresent(Update.self, forKey: key)).flatMap { update in
                        update.revisionVersion.flatMap {
                            CoreDeviceBuildUpdate(trainProgram: update.trainProgram, revisionComponents: $0.components,
                                                  revisionExtraString: $0.extraInfo?.versionExtraString,
                                                  factoryIdentifier: update.factoryIdentifier)
                        }
                    }
                }
            }
            let osVersionNumber: Version?
            let osBuildVersions: Builds?
        }
        struct State: Decodable {
            let name: String?
            let bootState: String?
            let preparednessState: Int?
            let visibilityClass: String?
        }
        struct Connection: Decodable {
            let state: String?
            let pairingState: String?
            let transportType: String?
            let lastConnectionDate: Double?
        }
        let hardware: Hardware
        let software: Software?
        let state: State?
        let connection: Connection?
    }

    package static func decode(_ data: Data) throws -> [CoreDeviceDevice] {
        let response = try JSONDecoder().decode(Response.self, from: data)
        return response.result.devices.map { device in
            let properties = device.properties
            let kind: DeviceInventoryKind = switch properties.hardware.fidelity {
            case "simulated": .simulator
            case "physical": .physical
            case "virtual": .virtualMachine
            case let fidelity: .other(fidelity)
            }
            return CoreDeviceDevice(
                identifier: device.identifier, udid: properties.hardware.udid, kind: kind,
                name: properties.state?.name ?? properties.hardware.marketingName ?? properties.hardware.productType ?? device.identifier,
                reportedName: properties.state?.name,
                modelIdentifier: properties.hardware.productType, modelName: properties.hardware.marketingName,
                // CoreDevice can sign-extend Mach CPU identifiers into unsigned 64-bit JSON values.
                cpuType: properties.hardware.cpuType.map {
                    .init(type: Int32(truncatingIfNeeded: $0.type), subtype: Int32(truncatingIfNeeded: $0.subtype))
                },
                platform: properties.hardware.osPlatform, osVersion: properties.software?.osVersionNumber?.stringValue,
                osBuild: properties.software?.osBuildVersions?.buildVersion?.name,
                osBuildUpdate: properties.software?.osBuildVersions?.update,
                connectionState: properties.connection?.state, pairingState: properties.connection?.pairingState,
                transportType: properties.connection?.transportType, bootState: properties.state?.bootState,
                preparednessState: properties.state?.preparednessState,
                capabilities: Set((device.capabilities ?? []).map(\.featureIdentifier)),
                lastConnectedAt: properties.connection?.lastConnectionDate.map(Date.init(timeIntervalSinceReferenceDate:)),
                visibilityClass: properties.state?.visibilityClass ?? device.visibilityClass
            )
        }
    }
}

extension SimulatorHostDevice {
    package var inventoryID: DeviceInventoryID { .simulator(udid: identifier, deviceSetPath: deviceSetPath) }
}
