import Foundation

/// Creation catalog in CoreSimulator order.
struct SimulatorCatalog {
    struct DeviceType: Codable, Equatable, Sendable {
        let identifier: String
        let name: String
        let productFamily: Int
    }

    struct Runtime: Codable, Equatable, Sendable {
        let identifier: String
        let name: String
    }

    let deviceTypes: [DeviceType]
    let runtimes: [Runtime]
    /// Supported device-type identifiers keyed by runtime.
    let supportedDeviceTypes: [String: Set<String>]
    /// Watch-first CoreSimulator pairing validation.
    let canPair: @MainActor (_ watchType: String, _ watchRuntime: String,
                             _ phoneType: String, _ phoneRuntime: String) -> Bool

    func runtime(_ runtime: String, supports deviceType: String) -> Bool {
        supportedDeviceTypes[runtime]?.contains(deviceType) == true
    }

    func deviceType(_ identifier: String) -> DeviceType? { deviceTypes.first { $0.identifier == identifier } }
}

extension SimulatorCatalog {
    /// Transfers the read-only catalog across the Xcode-isolated utility process.
    struct Snapshot: Codable, Sendable {
        struct Pairing: Codable, Hashable, Sendable {
            let watchType: String
            let watchRuntime: String
            let phoneType: String
            let phoneRuntime: String
        }

        let deviceTypes: [DeviceType]
        let runtimes: [Runtime]
        let supportedDeviceTypes: [String: Set<String>]
        let pairings: Set<Pairing>

        @concurrent
        static func decode(_ data: Data) async throws -> Self {
            try JSONDecoder().decode(Self.self, from: data)
        }

        @MainActor
        init(catalog: SimulatorCatalog) {
            deviceTypes = catalog.deviceTypes
            runtimes = catalog.runtimes
            supportedDeviceTypes = catalog.supportedDeviceTypes
            var pairings: Set<Pairing> = []
            let phones = catalog.deviceTypes.filter { $0.productFamily == 1 }
            let watches = catalog.deviceTypes.filter { $0.productFamily == 4 }
            for watchRuntime in runtimes {
                for watch in watches where catalog.runtime(watchRuntime.identifier, supports: watch.identifier) {
                    for phoneRuntime in runtimes {
                        for phone in phones where catalog.runtime(phoneRuntime.identifier, supports: phone.identifier) {
                            if catalog.canPair(watch.identifier, watchRuntime.identifier, phone.identifier, phoneRuntime.identifier) {
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
        func catalog() -> SimulatorCatalog {
            let pairings = pairings
            return SimulatorCatalog(deviceTypes: deviceTypes, runtimes: runtimes, supportedDeviceTypes: supportedDeviceTypes) {
                pairings.contains(Pairing(watchType: $0, watchRuntime: $1, phoneType: $2, phoneRuntime: $3))
            }
        }
    }
}
