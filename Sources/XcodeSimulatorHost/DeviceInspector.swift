import Foundation
import CoreFoundation

/// A JSON or property-list value exposed by the device's command-line tools.
public indirect enum DeviceInspectorValue: Equatable, Sendable, Decodable {
    case object([String: Self]), array([Self]), string(String), integer(Int64), unsignedInteger(UInt64), number(Double), boolean(Bool), data(Data), date(Date), null

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .boolean(value) }
        else if let value = try? container.decode(Int64.self) { self = .integer(value) }
        else if let value = try? container.decode(UInt64.self) { self = .unsignedInteger(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: Self].self) { self = .object(value) }
        else { self = .array(try container.decode([Self].self)) }
    }

    public var string: String? { if case .string(let value) = self { value } else { nil } }
    public var object: [String: Self]? { if case .object(let value) = self { value } else { nil } }
    public var array: [Self]? { if case .array(let value) = self { value } else { nil } }
    public var boolean: Bool? {
        switch self {
        case .boolean(let value): value
        case .integer(0), .unsignedInteger(0), .string("0"): false
        case .integer(1), .unsignedInteger(1), .string("1"): true
        default: nil
        }
    }
    public subscript(_ key: String) -> Self? { object?[key] }

    static func propertyList(_ value: Any) throws -> Self {
        switch value {
        case let dictionary as [String: Any]: return .object(try dictionary.mapValues(propertyList))
        case let array as [Any]: return .array(try array.map(propertyList))
        case let string as String: return .string(string)
        case let data as Data: return .data(data)
        case let date as Date: return .date(date)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .boolean(number.boolValue) }
            let type = String(cString: number.objCType)
            if type == "f" || type == "d" { return .number(number.doubleValue) }
            if type == "Q", number.uint64Value > UInt64(Int64.max) { return .unsignedInteger(number.uint64Value) }
            return .integer(number.int64Value)
        default: throw DeviceInspectorError.invalidResponse("The device returned an unsupported property-list value.")
        }
    }
}

public enum DeviceInspectorPartialCompletion: Equatable, Sendable {
    /// The incomplete download is retained at this URL for recovery.
    case applicationDataDownload(destination: URL)
    case applicationDataReplacement(bundleIdentifier: String, applicationMayBeStopped: Bool, dataMayBeModified: Bool)
    /// The remaining URL is owned staging data. destinationUpdated distinguishes a
    /// completed export with a cleanup failure from an incomplete transfer.
    case reportDownload(destination: URL, remainingURL: URL, destinationUpdated: Bool)
}

public struct DeviceInspectorFailure: Error, LocalizedError, Sendable {
    public enum Source: Equatable, Sendable {
        case simulator(xcodeURL: URL, deviceSetPath: String?)
        case coreDevice
        case file(URL)
    }
    public let deviceID: DeviceInventoryID
    public let operation: String
    public let source: Source
    public let error: any Error
    public let partialCompletion: DeviceInspectorPartialCompletion?
    public var errorDescription: String? { "\(operation): \(error.localizedDescription)" }
}

public enum DeviceInspectorError: Error, LocalizedError, Sendable {
    case unsupported(String)
    case commandFailed(status: Int32, stdout: String, stderr: String)
    case invalidResponse(String)
    case applicationNotFound(String)
    case profileNotFound(String)
    case reportNotFound(String)
    case invalidApplicationData(String)
    case cleanupFailed(directory: URL, operationError: (any Error)?, cleanupError: any Error)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let detail), .invalidResponse(let detail), .invalidApplicationData(let detail): detail
        case .commandFailed(let status, let stdout, let stderr): "Command failed (\(status)): \(stderr.isEmpty ? stdout : stderr)"
        case .applicationNotFound(let identifier): "The application \(identifier) is no longer installed."
        case .profileNotFound(let identifier): "The profile \(identifier) is no longer installed."
        case .reportNotFound(let path): "The report \(path) is no longer available."
        case .cleanupFailed(let directory, let operationError, let cleanupError):
            [operationError?.localizedDescription, "Could not remove \(directory.path): \(cleanupError.localizedDescription)"].compactMap { $0 }.joined(separator: "\n")
        }
    }
}

public struct DeviceInfoSnapshot: Sendable {
    public let deviceID: DeviceInventoryID
    /// The known inventory values remain available when a live query fails.
    public let device: InventoryDevice
    /// CoreDevice property categories, or simctl's device record with runtime and known CoreDevice properties.
    public let fields: [String: DeviceInspectorValue]
    public let issues: [DeviceInspectorFailure]
}

public struct DeviceApplication: Equatable, Sendable, Identifiable {
    public var id: String { bundleIdentifier }
    public let bundleIdentifier: String
    public let name: String
    public let version: String?
    public let build: String?
    /// A path on the destination device, not necessarily a Mac file URL.
    public let bundlePath: String?
    public let dataContainerPath: String?
    public let groupContainerPaths: [String: String]
    public let isContainerAccessible: Bool
    public let isDeveloperApplication: Bool?
    public let isRemovable: Bool?
    public let metadata: [String: DeviceInspectorValue]
}

public enum DeviceProfileKind: String, CaseIterable, Sendable { case configuration, provisioning }

public struct DeviceProfile: Equatable, Sendable, Identifiable {
    /// The payload identifier for configuration profiles, or UUID for provisioning profiles.
    public let identifier: String
    public let kind: DeviceProfileKind
    public var id: String { "\(kind.rawValue):\(identifier)" }
    public let name: String
    public let uuid: String?
    /// Metadata actually returned by devicectl. Installed configuration payload bodies and
    /// provisioning entitlement values are not supplied by its public list operation.
    public let metadata: [String: DeviceInspectorValue]
}

public struct DeviceProfilesSnapshot: Sendable {
    public let deviceID: DeviceInventoryID
    public let profiles: [DeviceProfile]
    /// Partial records returned by devicectl are retained separately rather than discarded.
    public let partialConfigurationProfiles: [DeviceInspectorValue]
    public let partialProvisioningProfiles: [DeviceInspectorValue]
}

/// Info, application, and profile operations for one inventory destination.
/// Create through SimulatorHostController to retain the simulator's Xcode and device set.
public struct DeviceInspector: Sendable {
    public let device: InventoryDevice
    let simulatorXcodeURL: URL?
    let transport: DeviceInspectorTransport

    init(device: InventoryDevice, simulatorXcodeURL: URL?, transport: DeviceInspectorTransport = .live) {
        self.device = device
        self.simulatorXcodeURL = simulatorXcodeURL
        self.transport = transport
    }

    @concurrent public func info() async -> DeviceInfoSnapshot {
        var fields: [String: DeviceInspectorValue] = [:]
        if case .simulator(let simulator) = device, let coreDevice = simulator.coreDevice {
            fields["coreDeviceIdentifier"] = .string(coreDevice.identifier)
            var hardware: [String: DeviceInspectorValue] = ["reality": .string(coreDevice.reality)]
            if let cpu = coreDevice.cpuType {
                hardware["cpuType"] = .object(["type": .integer(Int64(cpu.type)), "subtype": .integer(Int64(cpu.subtype))])
            }
            if let platform = coreDevice.platform { hardware["platform"] = .string(platform) }
            if let product = coreDevice.modelIdentifier { hardware["productType"] = .string(product) }
            fields["hardware"] = .object(hardware)
            if let boot = coreDevice.bootState { fields["bootState"] = .string(boot) }
            if let preparedness = coreDevice.preparednessState { fields["preparednessState"] = .integer(Int64(preparedness)) }
            var connection: [String: DeviceInspectorValue] = [:]
            if let state = coreDevice.connectionState { connection["state"] = .string(state) }
            if let pairing = coreDevice.pairingState { connection["pairingState"] = .string(pairing) }
            if let transport = coreDevice.transportType { connection["transportType"] = .string(transport) }
            if let date = coreDevice.lastConnectedAt { connection["lastConnectionDate"] = .date(date) }
            if !connection.isEmpty { fields["connection"] = .object(connection) }
        }
        do {
            switch device {
            case .simulator(let simulator):
                let data = try await simctl(["list", "--json"], operation: "Read Device Info")
                let response = try JSONDecoder().decode(DeviceInspectorValue.self, from: data)
                let devices = response["devices"]?.object?[simulator.runtimeIdentifier]?.array ?? []
                guard let record = devices.first(where: { $0["udid"]?.string == simulator.identifier })?.object else {
                    throw DeviceInspectorError.invalidResponse("The simulator is absent from its device set.")
                }
                var result = record
                result["runtimeIdentifier"] = .string(simulator.runtimeIdentifier)
                result["runtimeName"] = .string(simulator.runtimeName)
                if let model = simulator.modelIdentifier { result["modelIdentifier"] = .string(model) }
                if let typeIdentifier = record["deviceTypeIdentifier"]?.string,
                   let type = response["devicetypes"]?.array?.first(where: { $0["identifier"]?.string == typeIdentifier }),
                   let modelName = type["name"]?.string {
                    result["modelName"] = .string(modelName)
                }
                if let runtime = response["runtimes"]?.array?.first(where: { $0["identifier"]?.string == simulator.runtimeIdentifier }),
                   let version = runtime["version"]?.string {
                    let platform: String? = switch simulator.productFamily {
                    case "iPhone", "iPad": "iOS"
                    case "Apple Watch": "watchOS"
                    case "Apple TV": "tvOS"
                    case "Apple Vision": "visionOS"
                    default: nil
                    }
                    if let platform { result["operatingSystem"] = .string("\(platform) \(version)") }
                }
                fields.merge(result) { known, _ in known }
            case .remote:
                fields = try await coreDeviceResult(["device", "info", "details"], operation: "Read Device Info")["properties"]?.object
                    ?? { throw DeviceInspectorError.invalidResponse("Device details omitted the properties dictionary.") }()
            }
            return DeviceInfoSnapshot(deviceID: device.id, device: device, fields: fields, issues: [])
        } catch {
            return DeviceInfoSnapshot(deviceID: device.id, device: device, fields: fields, issues: [failure(error, operation: "Read Device Info")])
        }
    }

    @concurrent public func applications() async throws -> [DeviceApplication] {
        try await readApplications(bundleIdentifier: nil)
    }

    @concurrent public func application(bundleIdentifier: String) async throws -> DeviceApplication {
        guard let application = try await readApplications(bundleIdentifier: bundleIdentifier).first else {
            throw failure(DeviceInspectorError.applicationNotFound(bundleIdentifier), operation: "Read Application")
        }
        return application
    }

    @concurrent public func installApplication(at url: URL) async throws {
        try await mutateApplication(simulator: ["install", simulatorID, url.path], remote: ["device", "install", "app", url.path], operation: "Install Application")
    }

    @concurrent public func uninstallApplication(bundleIdentifier: String) async throws {
        try await mutateApplication(simulator: ["uninstall", simulatorID, bundleIdentifier], remote: ["device", "uninstall", "app", bundleIdentifier], operation: "Uninstall Application")
    }

    @concurrent public func launchApplication(bundleIdentifier: String) async throws {
        try await mutateApplication(simulator: ["launch", simulatorID, bundleIdentifier], remote: ["device", "process", "launch", bundleIdentifier], operation: "Launch Application")
    }

    /// Returns a local simulator data container suitable for Finder. Remote device paths
    /// are never converted into Mac file URLs.
    @concurrent public func applicationContainerURL(bundleIdentifier: String) async throws -> URL {
        guard case .simulator = device else {
            throw failure(DeviceInspectorError.unsupported("Remote application containers must be downloaded before opening in Finder."), operation: "Locate Application Container")
        }
        let data = try await simctl(["get_app_container", simulatorID, bundleIdentifier, "data"], operation: "Locate Application Container")
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") else { throw failure(DeviceInspectorError.invalidResponse("simctl did not return an absolute container path."), operation: "Locate Application Container") }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Requests the device-generated PNG. Custom simulator device sets are not exposed
    /// by devicectl, and report this feature as unsupported.
    @concurrent public func applicationIcon(bundleIdentifier: String) async throws -> Data {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NeoSimulator-icon-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let result: Result<Data, any Error>
            do {
                let image = directory.appendingPathComponent("Icon.png")
                _ = try await coreDevice(["device", "info", "appIcon", "--app-bundle-id", bundleIdentifier, "--destination", image.path], operation: "Read Application Icon", timeout: 30)
                result = .success(try Data(contentsOf: image))
            } catch { result = .failure(error) }
            do { try FileManager.default.removeItem(at: directory) }
            catch {
                let operationError: (any Error)?
                if case .failure(let failure) = result { operationError = failure } else { operationError = nil }
                throw DeviceInspectorError.cleanupFailed(directory: directory, operationError: operationError, cleanupError: error)
            }
            return try result.get()
        } catch { throw failure(error, operation: "Read Application Icon") }
    }

    /// Writes AppData/{Documents,Library,tmp}, as documented by Apple's Xcode 27 release
    /// notes. An approved replacement is published only after the download completes.
    /// Download failure preserves the original destination; partialCompletion identifies
    /// the retained staging package.
    @concurrent public func downloadApplicationData(bundleIdentifier: String, to destination: URL,
                                                    replacingExistingFile: Bool = false) async throws {
        let manager = FileManager.default
        var staging: URL?
        do {
            if !replacingExistingFile, manager.fileExists(atPath: destination.path) {
                throw CocoaError(.fileWriteFileExists)
            }
            let container: URL?
            if case .simulator = device {
                let source = try await applicationContainerURL(bundleIdentifier: bundleIdentifier)
                try validateExportDestination(destination, outside: source)
                container = source
            } else { container = nil }
            let package = destination.deletingLastPathComponent().appendingPathComponent(".NeoSimulator-export-\(UUID().uuidString).xcappdata", isDirectory: true)
            try manager.createDirectory(at: package, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            staging = package
            let data = package.appendingPathComponent("AppData", isDirectory: true)
            if let container {
                try manager.copyItem(at: container, to: data)
                let metadata = data.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
                if manager.fileExists(atPath: metadata.path) { try manager.removeItem(at: metadata) }
            } else {
                _ = try await coreDevice(["device", "copy", "from", "--source", ".", "--destination", data.path,
                    "--domain-type", "appDataContainer", "--domain-identifier", bundleIdentifier], operation: "Download Application Data")
            }
            try Task.checkCancellation()
            if replacingExistingFile, manager.fileExists(atPath: destination.path) {
                _ = try manager.replaceItemAt(destination, withItemAt: package)
            } else {
                try manager.moveItem(at: package, to: destination)
            }
        } catch {
            throw failure(error, operation: "Download Application Data", source: .file(destination),
                partialCompletion: staging.map { .applicationDataDownload(destination: $0) })
        }
    }

    private func validateExportDestination(_ destination: URL, outside container: URL) throws {
        let manager = FileManager.default
        let source = container.resolvingSymlinksInPath()
        let parent = destination.deletingLastPathComponent().resolvingSymlinksInPath()
        var relationship: FileManager.URLRelationship = .other
        try manager.getRelationship(&relationship, ofDirectoryAt: source, toItemAt: parent)
        guard relationship == .other else {
            throw DeviceInspectorError.invalidApplicationData("Choose an export location outside the application's data container.")
        }
        if manager.fileExists(atPath: destination.path) {
            let target = destination.resolvingSymlinksInPath()
            try manager.getRelationship(&relationship, ofDirectoryAt: source, toItemAt: target)
            guard relationship == .other else {
                throw DeviceInspectorError.invalidApplicationData("The export cannot replace the application's data container or its contents.")
            }
            if try target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                try manager.getRelationship(&relationship, ofDirectoryAt: target, toItemAt: source)
                guard relationship == .other else {
                    throw DeviceInspectorError.invalidApplicationData("The export cannot replace a directory containing the application's data container.")
                }
            }
        }
    }

    /// Replaces a selected application's data using an xcappdata AppData directory or a
    /// plain container folder. A failed replacement can leave partial destination data.
    @concurrent public func replaceApplicationData(bundleIdentifier: String, from source: URL) async throws {
        var attemptedStop = false
        var startedReplacement = false
        do {
            let manager = FileManager.default
            let package = source.pathExtension.lowercased() == "xcappdata"
            let data = package ? source.appendingPathComponent("AppData", isDirectory: true) : source
            guard try data.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw DeviceInspectorError.invalidApplicationData("Application data must be a directory containing the app's data.")
            }
            // Reading the complete source before touching a destination prevents missing or
            // malformed input from deleting the current data.
            let contents = try manager.contentsOfDirectory(at: data, includingPropertiesForKeys: nil)
            switch device {
            case .simulator:
                let container = try await applicationContainerURL(bundleIdentifier: bundleIdentifier)
                var relationship: FileManager.URLRelationship = .other
                try manager.getRelationship(&relationship, ofDirectoryAt: container, toItemAt: data)
                guard relationship == .other else { throw DeviceInspectorError.invalidApplicationData("The replacement source is inside the destination container.") }
                try manager.getRelationship(&relationship, ofDirectoryAt: data, toItemAt: container)
                guard relationship == .other else { throw DeviceInspectorError.invalidApplicationData("The replacement source contains the destination container.") }
                attemptedStop = true
                try await terminateApplicationIfRunning(bundleIdentifier: bundleIdentifier)
                startedReplacement = true
                for item in try manager.contentsOfDirectory(at: container, includingPropertiesForKeys: nil) where item.lastPathComponent != ".com.apple.mobile_container_manager.metadata.plist" {
                    try manager.removeItem(at: item)
                }
                for item in contents where item.lastPathComponent != ".com.apple.mobile_container_manager.metadata.plist" {
                    try manager.copyItem(at: item, to: container.appendingPathComponent(item.lastPathComponent))
                }
            case .remote:
                attemptedStop = true
                try await terminateApplicationIfRunning(bundleIdentifier: bundleIdentifier)
                startedReplacement = true
                _ = try await coreDevice(["device", "copy", "to", "--source", data.path, "--destination", ".",
                    "--domain-type", "appDataContainer", "--domain-identifier", bundleIdentifier,
                    "--remove-existing-content", "true"], operation: "Replace Application Data")
            }
        } catch {
            throw failure(error, operation: "Replace Application Data", source: .file(source),
                partialCompletion: attemptedStop ? .applicationDataReplacement(bundleIdentifier: bundleIdentifier,
                    applicationMayBeStopped: true, dataMayBeModified: startedReplacement) : nil)
        }
    }

    /// Lists the requested profile kind. When omitted, simulators request configuration
    /// profiles; physical devices and virtual machines request all profile kinds.
    @concurrent public func profiles(kind: DeviceProfileKind? = nil) async throws -> DeviceProfilesSnapshot {
        let requestedKind: DeviceProfileKind?
        if case .simulator = device { requestedKind = kind ?? .configuration }
        else { requestedKind = kind }
        var arguments = ["device", "profile", "list"]
        if let requestedKind { arguments += ["--type", requestedKind.rawValue] }
        let result = try await coreDeviceResult(arguments, operation: "Read Profiles")
        let kinds = requestedKind.map { [$0] } ?? DeviceProfileKind.allCases
        let listKeys = kinds.flatMap { [$0.rawValue + "Profiles", "partial" + $0.rawValue.capitalized + "Profiles"] }
        guard listKeys.contains(where: { result[$0]?.array != nil }) else {
            throw failure(DeviceInspectorError.invalidResponse("devicectl omitted its profile lists."), operation: "Read Profiles")
        }
        var profiles: [DeviceProfile] = []
        for kind in kinds {
            for value in result[kind.rawValue + "Profiles"]?.array ?? [] {
                guard let metadata = value.object,
                      let identifier = metadata[kind == .configuration ? "payloadIdentifier" : "uuid"]?.string ?? metadata["identifier"]?.string else {
                    throw failure(DeviceInspectorError.invalidResponse("A profile record omitted its identifier."), operation: "Read Profiles")
                }
                profiles.append(DeviceProfile(identifier: identifier, kind: kind, name: metadata["name"]?.string ?? identifier,
                    uuid: metadata["uuid"]?.string, metadata: metadata))
            }
        }
        return DeviceProfilesSnapshot(deviceID: device.id, profiles: profiles,
            partialConfigurationProfiles: kinds.contains(.configuration) ? result["partialConfigurationProfiles"]?.array ?? [] : [],
            partialProvisioningProfiles: kinds.contains(.provisioning) ? result["partialProvisioningProfiles"]?.array ?? [] : [])
    }

    /// Returns the metadata supplied by the public CLI, not the installed profile payload.
    @concurrent public func profile(identifier: String, kind: DeviceProfileKind) async throws -> DeviceProfile {
        guard let profile = try await profiles(kind: kind).profiles.first(where: { $0.identifier == identifier }) else {
            throw failure(DeviceInspectorError.profileNotFound(identifier), operation: "Read Profile")
        }
        return profile
    }

    @concurrent public func installProfile(at url: URL, kind: DeviceProfileKind) async throws {
        _ = try await coreDevice(["device", "profile", "install", url.path, "--type", kind.rawValue], operation: "Install Profile")
    }

    @concurrent public func removeProfile(identifier: String, kind: DeviceProfileKind) async throws {
        _ = try await coreDevice(["device", "profile", "remove", identifier, "--type", kind.rawValue], operation: "Remove Profile")
    }

    @concurrent private func readApplications(bundleIdentifier: String?) async throws -> [DeviceApplication] {
        do {
            let records: [[String: DeviceInspectorValue]]
            let simulator: Bool
            switch device {
            case .simulator:
                simulator = true
                let arguments = bundleIdentifier.map { ["appinfo", simulatorID, $0] } ?? ["listapps", simulatorID]
                let data = try await simctl(arguments, operation: "Read Applications")
                let value = try DeviceInspectorValue.propertyList(PropertyListSerialization.propertyList(from: data, format: nil))
                guard let object = value.object else { throw DeviceInspectorError.invalidResponse("simctl did not return an application dictionary.") }
                records = bundleIdentifier == nil ? object.values.compactMap(\.object) : [object]
            case .remote:
                simulator = false
                var arguments = ["device", "info", "apps", "--include-all-apps", "--include-app-group-identifiers", "--include-container-paths"]
                if let bundleIdentifier { arguments += ["--bundle-id", bundleIdentifier] }
                let value = try await coreDeviceResult(arguments, operation: "Read Applications")
                guard let apps = value["apps"]?.array else { throw DeviceInspectorError.invalidResponse("devicectl omitted its application list.") }
                records = apps.compactMap(\.object)
            }
            return try records.map { metadata in
                guard let identifier = metadata[simulator ? "CFBundleIdentifier" : "bundleIdentifier"]?.string else {
                    throw DeviceInspectorError.invalidResponse("An application record omitted its bundle identifier.")
                }
                let container = Self.devicePath(metadata[simulator ? "DataContainer" : "dataContainerPath"]?.string)
                return DeviceApplication(bundleIdentifier: identifier,
                    name: metadata[simulator ? "CFBundleDisplayName" : "name"]?.string ?? metadata["CFBundleName"]?.string ?? identifier,
                    version: metadata[simulator ? "CFBundleShortVersionString" : "version"]?.string,
                    build: metadata[simulator ? "CFBundleVersion" : "bundleVersion"]?.string,
                    bundlePath: Self.devicePath(metadata[simulator ? "Path" : "url"]?.string),
                    dataContainerPath: container,
                    groupContainerPaths: (metadata[simulator ? "GroupContainers" : "groupContainerPaths"]?.object ?? [:]).compactMapValues { Self.devicePath($0.string) },
                    isContainerAccessible: metadata["containerAccessible"]?.boolean ?? (container != nil),
                    isDeveloperApplication: metadata[simulator ? "IsDeveloperApp" : "builtByDeveloper"]?.boolean,
                    isRemovable: metadata[simulator ? "IsRemovable" : "removable"]?.boolean, metadata: metadata)
            }.filter { bundleIdentifier == nil || $0.bundleIdentifier == bundleIdentifier }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch { throw failure(error, operation: "Read Applications") }
    }

    @concurrent private func mutateApplication(simulator: [String], remote: [String], operation: String) async throws {
        switch device {
        case .simulator: _ = try await simctl(simulator, operation: operation)
        case .remote: _ = try await coreDevice(remote, operation: operation)
        }
    }

    @concurrent private func terminateApplicationIfRunning(bundleIdentifier: String) async throws {
        if case .remote = device {
            let application = try await application(bundleIdentifier: bundleIdentifier)
            guard let rawPath = application.bundlePath else { throw failure(DeviceInspectorError.invalidResponse("The application has no executable bundle path."), operation: "Stop Application") }
            let path = rawPath.hasPrefix("file:") ? URL(string: rawPath)?.path ?? rawPath : rawPath
            let processes = try await coreDeviceResult(["device", "info", "processes"], operation: "Read Processes")
            guard let records = processes["runningProcesses"]?.array else { throw failure(DeviceInspectorError.invalidResponse("devicectl omitted its process list."), operation: "Read Processes") }
            for record in records {
                guard let rawExecutable = record["executable"]?.string else { continue }
                let executable = rawExecutable.hasPrefix("file:") ? URL(string: rawExecutable)?.path ?? rawExecutable : rawExecutable
                guard executable.hasPrefix(path.hasSuffix("/") ? path : path + "/"),
                      case .integer(let pid) = record["processIdentifier"] else { continue }
                _ = try await coreDevice(["device", "process", "terminate", "--pid", String(pid), "--kill"], operation: "Stop Application")
            }
            return
        }
        // simctl terminate reports POSIX ESRCH when the app is already stopped. Other
        // failures must not be treated as permission to replace an active container.
        let command = try simulatorCommand(["terminate", simulatorID, bundleIdentifier])
        let output = try await transport.run(command)
        guard output.terminationStatus == 0 || output.terminationStatus == POSIXErrorCode.ESRCH.rawValue else {
            throw failure(DeviceInspectorError.commandFailed(status: output.terminationStatus, stdout: output.stdoutText, stderr: output.stderrText), operation: "Stop Application")
        }
    }

    private static func devicePath(_ value: String?) -> String? {
        guard let value else { return nil }
        return value.hasPrefix("file:") ? URL(string: value)?.path ?? value : value
    }

    var simulatorID: String { if case .simulator(let item) = device { item.identifier } else { "" } }

    func simulatorCommand(_ arguments: [String]) throws -> DeviceInspectorCommand {
        guard case .simulator(let device) = device, let simulatorXcodeURL else {
            throw DeviceInspectorError.unsupported("This operation requires a simulator and its Xcode installation.")
        }
        return DeviceInspectorCommand(source: .simulator(xcodeURL: simulatorXcodeURL, deviceSetPath: device.deviceSetPath), arguments: arguments)
    }

    @concurrent private func simctl(_ arguments: [String], operation: String) async throws -> Data {
        do { return try await run(simulatorCommand(arguments), operation: operation) }
        catch { throw failure(error, operation: operation) }
    }

    @concurrent func coreDeviceResult(_ arguments: [String], operation: String) async throws -> DeviceInspectorValue {
        do {
            let data = try await coreDevice(arguments, operation: operation, timeout: 30)
            let response = try JSONDecoder().decode(DeviceInspectorValue.self, from: data)
            guard let result = response["result"] else { throw DeviceInspectorError.invalidResponse("devicectl omitted the result object.") }
            return result
        } catch { throw failure(error, operation: operation, source: .coreDevice) }
    }

    @concurrent func coreDevice(_ arguments: [String], operation: String, timeout: Int? = nil) async throws -> Data {
        do {
            let identifier: String
            switch device {
            case .remote(let device): identifier = device.identifier
            case .simulator(let device):
                guard device.deviceSetPath == nil else {
                    throw DeviceInspectorError.unsupported("devicectl does not expose simulators in custom device sets for this operation.")
                }
                identifier = device.identifier
            }
            let options = ["--device", identifier, "--omit-deprecated-fields-in-json", "--json-output", "-", "--quiet"]
                + (timeout.map { ["--timeout", String($0)] } ?? [])
            let command = DeviceInspectorCommand(source: .coreDevice, arguments: arguments + options)
            return try await run(command, operation: operation)
        } catch { throw failure(error, operation: operation, source: .coreDevice) }
    }

    @concurrent private func run(_ command: DeviceInspectorCommand, operation: String) async throws -> Data {
        do {
            let result = try await transport.run(command)
            guard result.terminationStatus == 0 else {
                throw DeviceInspectorError.commandFailed(status: result.terminationStatus, stdout: result.stdoutText, stderr: result.stderrText)
            }
            return result.stdout
        } catch { throw failure(error, operation: operation, source: command.source) }
    }

    func failure(_ error: any Error, operation: String, source: DeviceInspectorFailure.Source? = nil,
                 partialCompletion: DeviceInspectorPartialCompletion? = nil) -> DeviceInspectorFailure {
        if let failure = error as? DeviceInspectorFailure {
            guard let partialCompletion else { return failure }
            return DeviceInspectorFailure(deviceID: failure.deviceID, operation: operation, source: failure.source,
                error: failure.error, partialCompletion: partialCompletion)
        }
        let defaultSource: DeviceInspectorFailure.Source
        if case .simulator(let device) = device, let simulatorXcodeURL {
            defaultSource = .simulator(xcodeURL: simulatorXcodeURL, deviceSetPath: device.deviceSetPath)
        } else { defaultSource = .coreDevice }
        return DeviceInspectorFailure(deviceID: device.id, operation: operation, source: source ?? defaultSource, error: error, partialCompletion: partialCompletion)
    }
}

struct DeviceInspectorCommand: Equatable, Sendable {
    let source: DeviceInspectorFailure.Source
    let arguments: [String]
}

struct DeviceInspectorTransport: Sendable {
    var run: @Sendable (DeviceInspectorCommand) async throws -> CommandOutput
    static let live = Self { command in try await execute(command) }

    @concurrent private static func execute(_ command: DeviceInspectorCommand) async throws -> CommandOutput {
        try Task.checkCancellation()
        let runner = SystemCommandRunner()
        switch command.source {
        case .simulator(let xcode, let path): return try runner.runSimctl(xcodeURL: xcode, arguments: command.arguments, deviceSetPath: path)
        case .coreDevice:
            return try runner.run(executable: URL(fileURLWithPath: "/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/Resources/bin/devicectl"), arguments: command.arguments)
        case .file: throw DeviceInspectorError.invalidResponse("A file operation cannot be executed as a device command.")
        }
    }
}

extension SimulatorHostController {
    /// Resolves a destination without acquiring the renderer-operation FIFO.
    public func inspector(for device: InventoryDevice) async throws -> DeviceInspector {
        let preferred: URL?
        if case .simulator(let simulator) = device {
            let owner = try await registeredRenderers().first { $0.deviceIdentifiers.contains(simulator.inventoryID) }
            preferred = owner.map { URL(fileURLWithPath: $0.xcodePath) } ?? simulator.ownerXcodeURL
        } else { preferred = nil }
        return try await makeDeviceInspector(device: device, preferredXcodeURL: preferred, rendererApplicationURL: rendererApplicationURL)
    }
}

@concurrent private func makeDeviceInspector(device: InventoryDevice, preferredXcodeURL: URL?, rendererApplicationURL: URL) async throws -> DeviceInspector {
    guard case .simulator(let simulator) = device else { return DeviceInspector(device: device, simulatorXcodeURL: nil) }
    if let preferredXcodeURL { return DeviceInspector(device: device, simulatorXcodeURL: preferredXcodeURL) }
    let installations = try SimulatorHostController.discoverXcodes(rendererApplicationURL: rendererApplicationURL)
    var failures: [any Error] = []
    for installation in installations {
        do {
            let result = try SystemCommandRunner().runSimctl(xcodeURL: installation.applicationURL,
                arguments: ["list", "--json"], deviceSetPath: simulator.deviceSetPath)
            guard result.terminationStatus == 0 else { throw DeviceInspectorError.commandFailed(status: result.terminationStatus, stdout: result.stdoutText, stderr: result.stderrText) }
            let devices = try SimulatorDeviceCatalog.decode(result.stdout, deviceSetPath: simulator.deviceSetPath, includeUnavailable: true)
            if devices.contains(where: { $0.identifier == simulator.identifier && $0.isAvailable }) {
                return DeviceInspector(device: device, simulatorXcodeURL: installation.applicationURL)
            }
        } catch { failures.append(error) }
    }
    if let failure = failures.first { throw failure }
    throw DeviceInspectorError.unsupported("No installed Xcode can use this simulator's runtime.")
}
