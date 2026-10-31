import Foundation

/// CoreDevice identifiers are command destinations; simulator UDIDs also retain their device-set identity.
public enum DeviceInventoryID: Hashable, Sendable, Codable {
    case simulator(udid: String, deviceSetPath: String?)
    case coreDevice(String)

    private enum CodingKeys: String, CodingKey { case identifier, deviceSetPath, coreDeviceIdentifier }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let identifier = try values.decodeIfPresent(String.self, forKey: .coreDeviceIdentifier) {
            self = .coreDevice(identifier)
        } else {
            self = .simulator(udid: try values.decode(String.self, forKey: .identifier),
                              deviceSetPath: try values.decodeIfPresent(String.self, forKey: .deviceSetPath))
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .simulator(let identifier, let path):
            try values.encode(identifier, forKey: .identifier)
            try values.encodeIfPresent(path, forKey: .deviceSetPath)
        case .coreDevice(let identifier): try values.encode(identifier, forKey: .coreDeviceIdentifier)
        }
    }

    var sortKey: String {
        switch self {
        case .simulator(let identifier, let path): "simulator:\(identifier):\(path ?? "")"
        case .coreDevice(let identifier): "coredevice:\(identifier)"
        }
    }

    var simulatorAddress: (identifier: String, deviceSetPath: String?) {
        get throws {
            guard case .simulator(let identifier, let path) = self else {
                throw CLIError.configuration("simulator-device", "Choose a simulator for this operation.")
            }
            return (identifier, path)
        }
    }

    var preferenceIdentifier: String {
        switch self {
        case .simulator(let identifier, nil): identifier
        case .simulator(let identifier, let path?): "set:\(path.utf8.count):\(path):\(identifier)"
        case .coreDevice(let identifier): identifier
        }
    }
}

public enum DeviceInventoryKind: Equatable, Sendable {
    case simulator, physical, virtualMachine
    /// An observed CoreDevice reality that this client does not classify yet.
    case other(String)
}

/// The fields of CoreDevice's typed `BuildUpdate` that its native ordering compares.
///
/// Inventory retains a value only when those fields have types and values CoreDevice can compare:
/// a known train program and at least the five revision components that the comparison reads.
/// A missing revision is not reconstructed from the build name, so such a build has no value here
/// although CoreDevice derives one when decoding. Fields the comparison does not read are not checked.
public struct CoreDeviceBuildUpdate: Comparable, Sendable {
    /// `TrainProgram` raw values in Xcode 27.2's CoreDeviceUtilities, which rejects any other value.
    private static let trainPrograms: Set = ["iOS", "macOS", "tvOS", "watchOS", "xrOS", "developerTools", "rtKit"]

    let trainProgram: String?
    let revisionComponents: [UInt]
    let revisionExtraString: String?
    let factoryIdentifier: UInt?

    init?(trainProgram: String?, revisionComponents: [UInt], revisionExtraString: String?, factoryIdentifier: UInt?) {
        // CoreDevice decodes a shorter revision unchanged, and its VersionNumber.< then traps reading components 0...4.
        guard revisionComponents.count >= 5, trainProgram.map(Self.trainPrograms.contains) ?? true else { return nil }
        self.trainProgram = trainProgram
        self.revisionComponents = Array(revisionComponents.prefix(5))
        self.revisionExtraString = revisionExtraString
        self.factoryIdentifier = factoryIdentifier
    }

    /// Orders builds by train program, the first five revision components, the revision's extra
    /// version string, then factory identifier, with an absent value first, as `BuildUpdate.<` does.
    ///
    /// `BuildUpdate.<` compares factory identifiers only when entire revisions are equal, so builds whose
    /// revisions differ only in human-readable text or later components are unordered, and another
    /// criterion can then order them in a cycle. This order compares their factory identifiers instead.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.trainProgram != rhs.trainProgram { return precedes(lhs.trainProgram, rhs.trainProgram) }
        if lhs.revisionComponents != rhs.revisionComponents {
            return lhs.revisionComponents.lexicographicallyPrecedes(rhs.revisionComponents)
        }
        if lhs.revisionExtraString != rhs.revisionExtraString {
            return precedes(lhs.revisionExtraString, rhs.revisionExtraString)
        }
        return precedes(lhs.factoryIdentifier, rhs.factoryIdentifier)
    }

    private static func precedes<Value: Comparable>(_ lhs: Value?, _ rhs: Value?) -> Bool {
        switch (lhs, rhs) {
        case (nil, .some): true
        case (.some(let lhs), .some(let rhs)): lhs < rhs
        default: false
        }
    }
}

/// A CoreDevice record from `properties`, without the deprecated parallel JSON fields.
public struct CoreDeviceDevice: Equatable, Sendable {
    /// The Mach CPU identifiers reported by the device's hardware properties.
    public struct CPUType: Equatable, Sendable {
        public let type: Int32
        public let subtype: Int32
    }

    /// The CoreDevice identifier passed to devicectl, which can differ from `udid`.
    public let identifier: String
    public let udid: String?
    public let kind: DeviceInventoryKind
    public let name: String
    /// The device-reported name before applying display fallbacks.
    public let reportedName: String?
    public let modelIdentifier: String?
    public let modelName: String?
    public let cpuType: CPUType?
    public let platform: String?
    public let osVersion: String?
    public let osBuild: String?
    /// DeviceInfo.osBuildUpdate: the supplemental build when one is reported, otherwise the base build.
    /// Nil when that build has no usable typed comparison fields; see ``CoreDeviceBuildUpdate``.
    public let osBuildUpdate: CoreDeviceBuildUpdate?
    public let connectionState: String?
    public let pairingState: String?
    public let transportType: String?
    public let bootState: String?
    /// CoreDevice's raw preparedness bitset, when supplied by the inventory.
    public let preparednessState: Int?
    public let capabilities: Set<String>
    public let lastConnectedAt: Date?
    public let visibilityClass: String?

    /// The hardware reality represented by the classification, including unrecognized raw values.
    public var reality: String {
        switch kind {
        case .simulator: "simulated"
        case .physical: "physical"
        case .virtualMachine: "virtual"
        case .other(let raw): raw
        }
    }

    /// A disconnected but discoverable device can expose the explicit connect operation.
    public var isAvailable: Bool { connectionState == "connected" || connectionState == "disconnected" }
}

public enum InventoryDevice: Equatable, Sendable, Identifiable {
    case simulator(SimulatorHostDevice)
    case remote(CoreDeviceDevice)

    public var id: DeviceInventoryID {
        switch self {
        case .simulator(let device): .simulator(udid: device.identifier, deviceSetPath: device.deviceSetPath)
        case .remote(let device): .coreDevice(device.identifier)
        }
    }

    public var kind: DeviceInventoryKind {
        switch self {
        case .simulator: .simulator
        case .remote(let device): device.kind
        }
    }

    public var name: String {
        switch self {
        case .simulator(let device): device.name
        case .remote(let device): device.name
        }
    }

    public var modelIdentifier: String? {
        switch self {
        case .simulator(let device): device.modelIdentifier
        case .remote(let device): device.modelIdentifier
        }
    }

    public var operatingSystem: String? {
        switch self {
        case .simulator(let device): device.runtimeName
        case .remote(let device):
            [device.platform, device.osVersion].compactMap { $0 }.joined(separator: " ").nilIfEmpty
        }
    }

    public var isAvailable: Bool {
        switch self {
        case .simulator(let device): device.isAvailable
        case .remote(let device): device.isAvailable
        }
    }

    public var capabilities: Set<String> {
        switch self {
        case .simulator(let device): device.capabilities
        case .remote(let device): device.capabilities
        }
    }

    /// CoreDevice connection time; custom device sets do not borrow default-set metadata.
    public var lastConnectionDate: Date? {
        switch self {
        case .simulator(let device): device.coreDevice?.lastConnectedAt
        case .remote(let device): device.lastConnectedAt
        }
    }
}

public struct DeviceInventoryIssue: Sendable {
    public enum Source: Equatable, Sendable {
        /// A nil Xcode means installation discovery failed before any catalog could be read.
        case simulators(xcodeURL: URL?, deviceSetPath: String?)
        case coreDevice
        case rendererOwnership
    }

    public let source: Source
    public let error: any Error
}

/// Devices from successful sources remain present when another source fails.
public struct DeviceInventorySnapshot: Sendable {
    public let devices: [InventoryDevice]
    public let issues: [DeviceInventoryIssue]
}

extension SimulatorHostController {
    /// Reads simulator catalogs and one CoreDevice snapshot without joining the renderer-operation FIFO.
    /// Inventory I/O executes outside this actor; existing renderer registrations remain the ownership source.
    public func inventory() async -> DeviceInventorySnapshot {
        async let snapshot = DeviceInventoryReader(
            readSimulators: { await Self.readSimulatorInventory(rendererApplicationURL: self.rendererApplicationURL) },
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
    private static func readCoreDeviceInventory() async throws -> Data {
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
    private static func readSimulatorInventory(rendererApplicationURL: URL) async -> DeviceInventorySnapshot {
        let installations: [XcodeInstallation]
        do { installations = try discoverXcodes(rendererApplicationURL: rendererApplicationURL) }
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
struct DeviceInventoryReader: Sendable {
    var readSimulators: @Sendable () async -> DeviceInventorySnapshot
    var readCoreDevices: @Sendable () async throws -> Data

    func read() async -> DeviceInventorySnapshot {
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

struct SimulatorInventoryReader {
    var installations: [URL]
    var testingDeviceSetPath: String?
    var readCatalog: (URL, String?) throws -> Data

    func read() -> DeviceInventorySnapshot {
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
    func inventoryCopy(owners: [RendererRegistration]) -> Self {
        let owner = owners.first { $0.deviceIdentifiers.contains(inventoryID) }
        return inventoryCopy(ownerXcodeURL: owner.map { URL(fileURLWithPath: $0.xcodePath) })
    }

    func inventoryCopy(ownerXcodeURL: URL?, capabilities: Set<String>? = nil, coreDevice: CoreDeviceDevice? = nil) -> Self {
        Self(identifier: identifier, name: name, descriptiveName: descriptiveName, runtimeIdentifier: runtimeIdentifier,
             runtimeName: runtimeName, productFamily: productFamily, state: state, ownerXcodeURL: ownerXcodeURL,
             catalogXcodeURL: catalogXcodeURL, deviceSetPath: deviceSetPath, modelIdentifier: modelIdentifier, deviceTypeIdentifier: deviceTypeIdentifier,
             isAvailable: isAvailable,
             lastUsedAt: lastUsedAt, capabilities: capabilities ?? coreDevice?.capabilities ?? self.capabilities, pairIdentifiers: pairIdentifiers,
             activePairedDeviceID: activePairedDeviceID, coreDevice: coreDevice ?? self.coreDevice)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Decodes the current properties schema only; deprecated hardware/device/connection fields are ignored.
enum CoreDeviceInventoryDecoder {
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
            let reality: String
            let udid: String?
            let productType: String?
            let marketingName: String?
            let cpuType: CPU?
            let platform: String?
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

    static func decode(_ data: Data) throws -> [CoreDeviceDevice] {
        let response = try JSONDecoder().decode(Response.self, from: data)
        return response.result.devices.map { device in
            let properties = device.properties
            let kind: DeviceInventoryKind = switch properties.hardware.reality {
            case "simulated": .simulator
            case "physical": .physical
            case "virtual": .virtualMachine
            case let reality: .other(reality)
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
                platform: properties.hardware.platform, osVersion: properties.software?.osVersionNumber?.stringValue,
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
    public var inventoryID: DeviceInventoryID { .simulator(udid: identifier, deviceSetPath: deviceSetPath) }
}
