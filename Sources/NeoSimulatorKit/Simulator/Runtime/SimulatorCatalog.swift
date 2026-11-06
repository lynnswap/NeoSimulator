import Foundation

/// Creation catalog in CoreSimulator order.
package struct SimulatorCatalog {
    package struct DeviceType: Codable, Equatable, Sendable {
        package let identifier: String
        package let name: String
        package let productFamily: Int

        package init(identifier: String, name: String, productFamily: Int) {
            self.identifier = identifier
            self.name = name
            self.productFamily = productFamily
        }
    }

    package struct Runtime: Codable, Equatable, Sendable {
        package let identifier: String
        package let name: String
        package let buildVersion: String?

        package init(identifier: String, name: String, buildVersion: String? = nil) {
            self.identifier = identifier
            self.name = name
            self.buildVersion = buildVersion
        }
    }

    package struct RuntimeNames: Decodable, Sendable {
        package struct Downloadable: Decodable, Sendable {
            package struct Version: Decodable, Sendable {
                package let buildUpdate: String
            }
            package let name: String
            package let simulatorVersion: Version?
        }

        package let downloadables: [Downloadable]
        package let otherDownloadables: [Downloadable]

        @concurrent
        package static func decode(_ data: Data) async throws -> [String: String] {
            let index = try PropertyListDecoder().decode(Self.self, from: data)
            var names: [String: String] = [:]
            let suffix = " Simulator Runtime"
            for item in index.downloadables + index.otherDownloadables {
                guard let version = item.simulatorVersion else { continue }
                names[version.buildUpdate] = item.name.hasSuffix(suffix)
                    ? String(item.name.dropLast(suffix.count)) : item.name
            }
            return names
        }
    }

    package let deviceTypes: [DeviceType]
    package let runtimes: [Runtime]
    /// Supported device-type identifiers keyed by runtime.
    package let supportedDeviceTypes: [String: Set<String>]
    /// Watch-first pairing validation, which CoreSimulator already answered for this catalog.
    package let canPair: @MainActor (_ watchType: String, _ watchRuntime: String,
                             _ phoneType: String, _ phoneRuntime: String) -> Bool

    package init(deviceTypes: [DeviceType], runtimes: [Runtime], supportedDeviceTypes: [String: Set<String>],
                 canPair: @escaping @MainActor (String, String, String, String) -> Bool) {
        self.deviceTypes = deviceTypes
        self.runtimes = runtimes
        self.supportedDeviceTypes = supportedDeviceTypes
        self.canPair = canPair
    }

    package func runtime(_ runtime: String, supports deviceType: String) -> Bool {
        supportedDeviceTypes[runtime]?.contains(deviceType) == true
    }

    package func deviceType(_ identifier: String) -> DeviceType? { deviceTypes.first { $0.identifier == identifier } }
}

extension SimulatorCatalog {
    /// The read-only catalog as values, with the pairing answers that CoreSimulator gave on the device set's worker. This
    /// also crosses the Xcode-isolated utility process.
    package struct Snapshot: Codable, Sendable {
        package struct Pairing: Codable, Hashable, Sendable {
            package let watchType: String
            package let watchRuntime: String
            package let phoneType: String
            package let phoneRuntime: String
        }

        package let deviceTypes: [DeviceType]
        package let runtimes: [Runtime]
        package let supportedDeviceTypes: [String: Set<String>]
        package let pairings: Set<Pairing>

        @concurrent
        package static func decode(_ data: Data) async throws -> Self {
            try JSONDecoder().decode(Self.self, from: data)
        }

        /// Asks `canPair`, watch first, about every pair of a watch and a phone on runtimes that support them.
        package init(deviceTypes: [DeviceType], runtimes: [Runtime], supportedDeviceTypes: [String: Set<String>],
                     canPair: (_ watchType: String, _ watchRuntime: String,
                               _ phoneType: String, _ phoneRuntime: String) -> Bool) {
            self.deviceTypes = deviceTypes
            self.runtimes = runtimes
            self.supportedDeviceTypes = supportedDeviceTypes
            func supports(_ runtime: Runtime, _ type: DeviceType) -> Bool {
                supportedDeviceTypes[runtime.identifier]?.contains(type.identifier) == true
            }
            var pairings: Set<Pairing> = []
            let phones = deviceTypes.filter { $0.productFamily == 1 }
            let watches = deviceTypes.filter { $0.productFamily == 4 }
            for watchRuntime in runtimes {
                for watch in watches where supports(watchRuntime, watch) {
                    for phoneRuntime in runtimes {
                        for phone in phones where supports(phoneRuntime, phone) {
                            if canPair(watch.identifier, watchRuntime.identifier, phone.identifier, phoneRuntime.identifier) {
                                pairings.insert(Pairing(watchType: watch.identifier, watchRuntime: watchRuntime.identifier,
                                                        phoneType: phone.identifier, phoneRuntime: phoneRuntime.identifier))
                            }
                        }
                    }
                }
            }
            self.pairings = pairings
        }

        @MainActor
        package func catalog() -> SimulatorCatalog {
            let pairings = pairings
            return SimulatorCatalog(deviceTypes: deviceTypes, runtimes: runtimes, supportedDeviceTypes: supportedDeviceTypes) {
                pairings.contains(Pairing(watchType: $0, watchRuntime: $1, phoneType: $2, phoneRuntime: $3))
            }
        }
    }
}
