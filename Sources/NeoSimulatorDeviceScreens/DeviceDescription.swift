import Foundation
import NeoSimulatorHostSupport
import NeoSimulatorKit
import NeoSimulatorManager

/// How the window's panes name a device and its family.
extension InventoryDevice {
    package var modelName: String? {
        if case .remote(let remote) = self { return remote.modelName }
        return nil
    }

    package var family: String {
        if case .simulator(let simulator) = self { return simulator.productFamily }
        let identifier = modelIdentifier ?? ""
        if identifier.hasPrefix("iPad") { return "iPad" }
        if identifier.hasPrefix("iPhone") { return "iPhone" }
        if identifier.hasPrefix("Watch") { return "Apple Watch" }
        if identifier.hasPrefix("AppleTV") { return "Apple TV" }
        if identifier.hasPrefix("Reality") { return "Apple Vision" }
        if platformName.localizedCaseInsensitiveContains("mac") { return "Mac" }
        return platformName.isEmpty ? "Other" : platformName
    }

    /// Divides the native family for the filter only; artwork keeps using `family`.
    package var filterCategory: String { isIPhoneDuo ? "iPhone Duo" : family }

    package var platformName: String {
        switch self {
        case .simulator(let simulator): simulator.runtimeName.split(separator: " ").first.map(String.init) ?? ""
        case .remote(let remote): remote.platform ?? ""
        }
    }

    package var versionTitle: String {
        switch self {
        case .simulator(let simulator):
            simulator.runtimeName.split(separator: " ").first { $0.first?.isNumber == true }.map(String.init) ?? ""
        case .remote(let remote): remote.osVersion ?? ""
        }
    }

    package var kindTitle: String {
        switch kind {
        case .simulator: "Simulator"
        case .physical: "Physical"
        case .virtualMachine: "Virtual Machine"
        case .other: "Other"
        }
    }
}

extension DeviceArtworkCache {
    /// Artwork drawn from the Xcode that shows screens, or else the simulator's own Xcode.
    package func artwork(for device: InventoryDevice, screens: DeviceScreens,
                         manager: SimulatorManagerModel) -> DeviceArtworkModel {
        let xcodeURL: URL?
        if let preferred = screens.displayXcodeURL { xcodeURL = preferred }
        else if case .simulator(let simulator) = device { xcodeURL = simulator.ownerXcodeURL }
        else { xcodeURL = nil }
        return artwork(modelIdentifier: device.modelIdentifier, family: device.family, xcodeURL: xcodeURL,
                       resolveXcodeURLs: { [weak manager] in await manager?.artworkXcodeURLs(for: device) ?? [] })
    }
}
