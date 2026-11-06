import NeoSimulatorDeviceIO
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
    package enum Source: Hashable, Sendable {
        /// A nil Xcode means installation discovery failed before any catalog could be read.
        case simulators(xcodeURL: URL?, deviceSetPath: String?)
        case coreDevice
        case rendererOwnership
    }

    package let source: Source
    package let error: any Error

    package init(source: Source, error: any Error) {
        self.source = source
        self.error = error
    }
}

/// Devices from successful sources remain present when another source fails. A device absent from a snapshot has gone
/// only if no source that listed it failed, which ``retains(_:)`` decides for the registry.
package struct DeviceInventorySnapshot: Sendable {
    package let devices: [InventoryDevice]
    package let issues: [DeviceInventoryIssue]
    /// The catalogs that listed each device. A simulator can be listed by several Xcodes.
    package let sources: [DeviceInventoryID: Set<DeviceInventoryIssue.Source>]

    package init(devices: [InventoryDevice], issues: [DeviceInventoryIssue],
                 sources: [DeviceInventoryID: Set<DeviceInventoryIssue.Source>] = [:]) {
        self.devices = devices
        self.issues = issues
        self.sources = sources
    }

    package func sources(of device: InventoryDevice) -> Set<DeviceInventoryIssue.Source> {
        sources[device.id] ?? [device.defaultInventorySource]
    }

    /// Whether a device that these sources listed, and this snapshot does not, may still exist. A nil Xcode means that
    /// discovery failed before any simulator catalog could be read.
    package func retains(_ sources: Set<DeviceInventoryIssue.Source>) -> Bool {
        issues.contains { issue in
            switch issue.source {
            case .simulators(nil, _):
                sources.contains { if case .simulators = $0 { true } else { false } }
            case .simulators, .coreDevice:
                sources.contains(issue.source)
            case .rendererOwnership:
                false
            }
        }
    }

    package func didRead(_ source: DeviceInventoryIssue.Source) -> Bool { !issues.contains { $0.source == source } }
}

extension InventoryDevice {
    fileprivate var defaultInventorySource: DeviceInventoryIssue.Source {
        switch self {
        case .simulator(let device): .simulators(xcodeURL: device.catalogXcodeURL, deviceSetPath: device.deviceSetPath)
        case .remote: .coreDevice
        }
    }
}

package enum LiveDeviceInventory {
    /// Reads simulator catalogs and one CoreDevice snapshot. Only cancellation throws: a stopped read observed nothing,
    /// so it has no devices or issues to publish.
    @concurrent
    package static func read(using reads: CommandReads) async throws -> DeviceInventorySnapshot {
        try await DeviceInventoryReader(
            readSimulators: { try await readSimulators(using: reads) },
            readCoreDevices: { try await readCoreDevices(using: reads) }
        ).read()
    }

    @concurrent
    package static func readCoreDevices(using runner: any CommandRunning & Sendable = SystemCommandRunner()) async throws -> Data {
        let result = try await runner.runCancellable(.devicectl(
            arguments: ["list", "devices", "--json-output", "-", "--quiet", "--timeout", String(DeviceOperationLimit.devicectlQuery)],
            policy: .cancellable))
        guard result.terminationStatus == 0 else {
            throw DeviceDomainError.io("coredevice-inventory", result.stderrText.isEmpty ? result.stdoutText : result.stderrText)
        }
        return result.stdout
    }

    /// A simulator uses the preferred Xcode; installed Xcodes are searched only when there is none.
    @concurrent
    package static func xcodeURL(for simulator: SimulatorHostDevice, preferring preferred: URL?, using reads: CommandReads) async throws -> URL {
        if let preferred { return preferred }
        let installations = try await XcodeInstallationInspector(runner: reads).discoverXcodes()
        var failures: [any Error] = []
        for installation in installations {
            do {
                let result = try await reads.run(.simctl(xcodeURL: installation.applicationURL,
                    arguments: ["list", "--json"], deviceSetPath: simulator.deviceSetPath, policy: .cancellable))
                guard result.terminationStatus == 0 else { throw DeviceInspectorError.commandFailed(status: result.terminationStatus, stdout: result.stdoutText, stderr: result.stderrText) }
                let devices = try SimulatorDeviceCatalog.decode(result.stdout, deviceSetPath: simulator.deviceSetPath, includeUnavailable: true)
                if devices.contains(where: { $0.identifier == simulator.identifier && $0.isAvailable }) { return installation.applicationURL }
            } catch is CancellationError { throw CancellationError() }
            catch { failures.append(error) }
        }
        if let failure = failures.first { throw failure }
        throw DeviceInspectorError.unsupported("No installed Xcode can use this simulator's runtime.")
    }

    @concurrent
    private static func readSimulators(using reads: CommandReads) async throws -> DeviceInventorySnapshot {
        let installations: [XcodeInstallation]
        do { installations = try await XcodeInstallationInspector(runner: reads).discoverXcodes() }
        catch is CancellationError { throw CancellationError() }
        catch { return DeviceInventorySnapshot(devices: [], issues: [.init(source: .simulators(xcodeURL: nil, deviceSetPath: nil), error: error)]) }
        let testingPath = SimulatorDeviceSets.testingPath().flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
        return try await SimulatorInventoryReader(
            installations: installations.map(\.applicationURL), testingDeviceSetPath: testingPath,
            readCatalog: { xcode, path in
                let output = try await reads.run(.simctl(xcodeURL: xcode, arguments: ["list", "--json"], deviceSetPath: path, policy: .cancellable))
                guard output.terminationStatus == 0 else { throw DeviceDomainError.io("simulator-inventory", output.stderrText.isEmpty ? output.stdoutText : output.stderrText) }
                return output.stdout
            }
        ).read()
    }
}

/// Uses the production join and partial-result paths with replaceable source I/O.
/// A failed source becomes an issue beside the other's devices. Cancellation ends the whole read instead,
/// because a source that was stopped would otherwise look like devices that went away.
package struct DeviceInventoryReader: Sendable {
    package var readSimulators: @Sendable () async throws -> DeviceInventorySnapshot
    package var readCoreDevices: @Sendable () async throws -> Data

    package func read() async throws -> DeviceInventorySnapshot {
        async let simulators = readSimulators()
        let records: [CoreDeviceDevice]
        var issues: [DeviceInventoryIssue] = []
        do { records = try CoreDeviceInventoryDecoder.decode(await readCoreDevices()) }
        catch is CancellationError { throw CancellationError() }
        catch {
            records = []
            issues.append(DeviceInventoryIssue(source: .coreDevice, error: error))
        }
        let snapshot = try await simulators
        let simulated = Dictionary(records.filter { $0.kind == .simulator }.map { ($0.udid ?? $0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        let devices = snapshot.devices.map { item -> InventoryDevice in
            guard case .simulator(let device) = item, device.deviceSetPath == nil,
                  let record = simulated[device.identifier] else { return item }
            return .simulator(device.inventoryCopy(ownerXcodeURL: device.ownerXcodeURL, coreDevice: record))
        } + records.filter { $0.kind != .simulator }.map(InventoryDevice.remote)
        return DeviceInventorySnapshot(devices: devices, issues: snapshot.issues + issues, sources: snapshot.sources)
    }
}

package struct SimulatorInventoryReader {
    package var installations: [URL]
    package var testingDeviceSetPath: String?
    package var readCatalog: (URL, String?) async throws -> Data

    package nonisolated(nonsending) func read() async throws -> DeviceInventorySnapshot {
        var devices: [InventoryDevice] = []
        var positions: [DeviceInventoryID: Int] = [:]
        var issues: [DeviceInventoryIssue] = []
        var sources: [DeviceInventoryID: Set<DeviceInventoryIssue.Source>] = [:]
        for xcode in installations {
            let paths: [String?] = testingDeviceSetPath.map { [nil, $0] } ?? [nil]
            for path in paths {
                do {
                    for device in try await SimulatorDeviceCatalog.decode(readCatalog(xcode, path), deviceSetPath: path,
                                                                    includeUnavailable: true, catalogXcodeURL: xcode) {
                        let item = InventoryDevice.simulator(device)
                        sources[item.id, default: []].insert(.simulators(xcodeURL: xcode, deviceSetPath: path))
                        if let position = positions[item.id] {
                            if !devices[position].isAvailable && item.isAvailable { devices[position] = item }
                        } else {
                            positions[item.id] = devices.count
                            devices.append(item)
                        }
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { issues.append(.init(source: .simulators(xcodeURL: xcode, deviceSetPath: path), error: error)) }
            }
        }
        return DeviceInventorySnapshot(devices: devices, issues: issues, sources: sources)
    }
}

extension SimulatorHostDevice {
    package func inventoryCopy(ownerXcodeURL: URL?, capabilities: Set<String>? = nil, coreDevice: CoreDeviceDevice? = nil, state: String? = nil) -> Self {
        Self(identifier: identifier, name: name, descriptiveName: descriptiveName, runtimeIdentifier: runtimeIdentifier,
             runtimeName: runtimeName, productFamily: productFamily, state: state ?? self.state, ownerXcodeURL: ownerXcodeURL,
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

package struct SimulatorHostDevice: Sendable, Equatable {
    package let identifier: String
    package let name: String
    package let descriptiveName: String
    package let runtimeIdentifier: String
    package let runtimeName: String
    package let productFamily: String
    package let state: String
    package let ownerXcodeURL: URL?
    /// The Xcode whose catalog listed this entry as available during an inventory read, if any.
    /// It records where the entry came from; `ownerXcodeURL` remains the renderer that owns the device.
    package let catalogXcodeURL: URL?
    package let deviceSetPath: String?
    package let modelIdentifier: String?
    /// CoreSimulator's device-type identifier, used with a runtime to validate companion creation.
    package let deviceTypeIdentifier: String?
    package let isAvailable: Bool
    package let lastUsedAt: Date?
    /// Creation date of the simulator's device directory, when available.
    package let createdAt: Date?
    package let capabilities: Set<String>
    package let pairIdentifiers: Set<String>
    /// The active companion in the same simulator device set, when the catalog identifies one.
    package let activePairedDeviceID: DeviceInventoryID?
    /// CoreDevice's matching default-set record, including host connection information.
    package let coreDevice: CoreDeviceDevice?

    package init(identifier: String, name: String, descriptiveName: String, runtimeIdentifier: String, runtimeName: String, productFamily: String, state: String, ownerXcodeURL: URL? = nil, catalogXcodeURL: URL? = nil, deviceSetPath: String? = nil, modelIdentifier: String? = nil, deviceTypeIdentifier: String? = nil, isAvailable: Bool = true, lastUsedAt: Date? = nil, createdAt: Date? = nil, capabilities: Set<String> = [], pairIdentifiers: Set<String> = [], activePairedDeviceID: DeviceInventoryID? = nil, coreDevice: CoreDeviceDevice? = nil) {
        self.identifier = identifier
        self.name = name
        self.descriptiveName = descriptiveName
        self.runtimeIdentifier = runtimeIdentifier
        self.runtimeName = runtimeName
        self.productFamily = productFamily
        self.state = state
        self.ownerXcodeURL = ownerXcodeURL
        self.catalogXcodeURL = catalogXcodeURL
        self.deviceSetPath = deviceSetPath
        self.modelIdentifier = modelIdentifier
        self.deviceTypeIdentifier = deviceTypeIdentifier
        self.isAvailable = isAvailable
        self.lastUsedAt = lastUsedAt
        self.createdAt = createdAt
        self.capabilities = capabilities
        self.pairIdentifiers = pairIdentifiers
        self.activePairedDeviceID = activePairedDeviceID
        self.coreDevice = coreDevice
    }
}

package struct SimulatorHostFailure: Error, LocalizedError, Sendable {
    package enum Kind: Sendable, Equatable { case preferencesChanged, unavailableXcode, launchFailed, partialSuccess, operationFailed }
    package let kind: Kind
    package let technicalDetails: String
    package let failureReason: String?
    private let underlyingRecoverySuggestion: String?

    package var errorDescription: String? {
        switch kind {
        case .preferencesChanged: "Xcode’s simulator settings changed outside NeoSimulator."
        case .unavailableXcode: "Xcode cannot be used with NeoSimulator."
        case .launchFailed: "The simulator display could not be opened."
        case .partialSuccess: "Simulator settings changed, but the display could not be opened."
        case .operationFailed: "The simulator operation could not be completed."
        }
    }
    package var recoverySuggestion: String? {
        if let underlyingRecoverySuggestion { return underlyingRecoverySuggestion }
        return switch kind {
        case .preferencesChanged: "Review your Xcode settings. To use the saved values, choose Restore Original Settings…, then Restore Saved Values…."
        case .unavailableXcode: "Open Xcode 27 or later and finish installing its developer tools, then try again."
        case .launchFailed: "Try View Screen again, or select the display app in Settings."
        case .partialSuccess: "Try View Screen again, or select the display app in Settings."
        case .operationFailed: "Try again and review the diagnostic details if the problem continues."
        }
    }
    package init(_ error: any Error) {
        failureReason = (error as? any LocalizedError)?.failureReason
        underlyingRecoverySuggestion = (error as? any LocalizedError)?.recoverySuggestion
        let identifier = (error as? any IdentifiedFailure)?.identifier ?? ""
        technicalDetails = identifier.isEmpty ? error.localizedDescription : "\(identifier): \(error.localizedDescription)"
        if ["preference-conflict", "ambiguous-intermediate", "inconsistent-preferences"].contains(identifier) || identifier.hasSuffix("-host-invalidated") {
            kind = .preferencesChanged
        } else if identifier.hasSuffix("-partial-success") {
            kind = .partialSuccess
        } else if identifier == "unsupported-xcode" || identifier == "xcode-bundle" {
            kind = .unavailableXcode
        } else if identifier.contains("launch") || identifier.contains("runtime") || identifier.contains("startup") {
            kind = .launchFailed
        } else {
            kind = .operationFailed
        }
    }
}

package enum SimulatorDeviceCatalog {
    private struct Catalog: Decodable {
        struct Runtime: Decodable {
            let identifier: String
            let name: String
            let isAvailable: Bool
        }
        struct Device: Decodable {
            let udid: String
            let deviceTypeIdentifier: String
            let name: String
            let state: String
            let isAvailable: Bool
            let lastUsedAt: String?
            let dataPath: String?
        }
        struct DeviceType: Decodable {
            let identifier: String
            let productFamily: String
            let modelIdentifier: String?
        }
        let devicetypes: [DeviceType]
        let runtimes: [Runtime]
        let devices: [String: [Device]]
        struct Pair: Decodable {
            struct Member: Decodable { let udid: String }
            let watch: Member
            let phone: Member
            let state: String?

            var isActive: Bool { state == "(active, connected)" || state == "(active, disconnected)" }
        }
        let pairs: [String: Pair]?
    }

    /// A failed testing catalog leaves the normal devices available. Cancellation ends the read instead,
    /// because the testing devices did not go away.
    package nonisolated(nonsending) static func appendingTestingDevices(
        to devices: [SimulatorHostDevice], readTesting: () async throws -> [SimulatorHostDevice], onFailure: (any Error) -> Void
    ) async throws -> [SimulatorHostDevice] {
        do { return devices + (try await readTesting()) }
        catch is CancellationError { throw CancellationError() }
        catch { onFailure(error); return devices }
    }

    package static func decode(_ data: Data, deviceSetPath: String? = nil, includeUnavailable: Bool = false,
                       catalogXcodeURL: URL? = nil) throws -> [SimulatorHostDevice] {
        let catalog = try JSONDecoder().decode(Catalog.self, from: data)
        let supportedFamilies: Set<String> = ["iPhone", "iPad", "Apple TV", "Apple Watch", "Apple Vision"]
        let supportedTypes = Dictionary(uniqueKeysWithValues: catalog.devicetypes.filter { supportedFamilies.contains($0.productFamily) }.map { ($0.identifier, $0) })
        // Multiple installed builds can share a runtime identifier.
        let runtimes = Dictionary(catalog.runtimes.map { ($0.identifier, $0) }, uniquingKeysWith: { first, next in
            !first.isAvailable && next.isAvailable ? next : first
        })
        return catalog.devices.flatMap { runtimeIdentifier, devices in
            let runtime = runtimes[runtimeIdentifier]
            return devices.compactMap { device -> SimulatorHostDevice? in
                let available = device.isAvailable && runtime?.isAvailable == true
                let type = supportedTypes[device.deviceTypeIdentifier]
                guard includeUnavailable || (available && type != nil) else { return nil }
                let runtimeName = runtime?.name ?? runtimeIdentifier
                let lastUsedAt = device.lastUsedAt.flatMap { value in
                    (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value))
                        ?? (try? Date.ISO8601FormatStyle().parse(value))
                }
                return SimulatorHostDevice(
                    identifier: device.udid,
                    name: device.name,
                    descriptiveName: "\(device.name) — \(runtimeName)",
                    runtimeIdentifier: runtimeIdentifier,
                    runtimeName: runtimeName,
                    productFamily: type?.productFamily ?? "",
                    state: device.state,
                    catalogXcodeURL: available ? catalogXcodeURL : nil,
                    deviceSetPath: deviceSetPath,
                    modelIdentifier: type?.modelIdentifier,
                    deviceTypeIdentifier: device.deviceTypeIdentifier,
                    isAvailable: available,
                    lastUsedAt: lastUsedAt,
                    createdAt: device.dataPath.flatMap { path in
                        try? URL(filePath: path).deletingLastPathComponent()
                            .resourceValues(forKeys: [.creationDateKey]).creationDate
                    },
                    pairIdentifiers: Set((catalog.pairs ?? [:]).compactMap { pairID, pair in
                        pair.watch.udid == device.udid || pair.phone.udid == device.udid ? pairID : nil
                    }),
                    activePairedDeviceID: (catalog.pairs ?? [:]).values.first(where: {
                        $0.isActive && ($0.watch.udid == device.udid || $0.phone.udid == device.udid)
                    }).map { pair in
                        .simulator(udid: pair.watch.udid == device.udid ? pair.phone.udid : pair.watch.udid,
                                   deviceSetPath: deviceSetPath)
                    }
                )
            }
        }.sorted {
            let order = $0.runtimeName.compare($1.runtimeName, options: .numeric)
            return order == .orderedSame
                ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                : order == .orderedDescending
        }
    }
}

package enum SimulatorDeviceSets {
    package static func testingPath() -> String? {
        let renderer = UserDefaults(suiteName: ToolConstants.neoHostBundleIdentifier)
        let manager = ToolConstants.managerDefaults
        return testingPath(showTesting: renderer?.object(forKey: "ShowTestingDevices") as? Bool ?? manager?.object(forKey: "ShowTestingDevices") as? Bool ?? true,
                           customPath: renderer?.string(forKey: "TestingDeviceSetPath") ?? manager?.string(forKey: "TestingDeviceSetPath"))
    }

    package static func testingPath(showTesting: Bool, customPath: String?, homeURL: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        guard showTesting else { return nil }
        let path = customPath.map { NSString(string: $0).expandingTildeInPath }
            ?? homeURL.appendingPathComponent("Library/Developer/XCTestDevices").path
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        guard url != homeURL.appendingPathComponent("Library/Developer/CoreSimulator/Devices").resolvingSymlinksInPath().standardizedFileURL else { return nil }
        return url.path
    }
}

extension InventoryDevice {
    package var canInspectSettings: Bool {
        switch self {
        case .simulator(let device): device.isAvailable && device.state == "Booted"
        case .remote(let device): device.isAvailable
        }
    }

    package var serviceProductFamily: String {
        if case .simulator(let device) = self { return device.productFamily }
        return ""
    }

    /// launchd can be read only inside a booted simulator; physical devices and VMs keep their services.
    package var canInspectBackgroundServices: Bool {
        guard case .simulator(let device) = self else { return false }
        return device.isAvailable && device.state == "Booted"
    }
}
