import Foundation

/// The fields of CoreDevice's typed `BuildUpdate` that its native ordering compares.
///
/// Inventory retains a value only when those fields have types and values CoreDevice can compare:
/// a known train program and at least the five revision components that the comparison reads.
/// A missing revision is not reconstructed from the build name, so such a build has no value here
/// although CoreDevice derives one when decoding. Fields the comparison does not read are not checked.
package struct CoreDeviceBuildUpdate: Comparable, Sendable {
    /// `TrainProgram` raw values in Xcode 27.2's CoreDeviceUtilities, which rejects any other value.
    private static let trainPrograms: Set = ["iOS", "macOS", "tvOS", "watchOS", "xrOS", "developerTools", "rtKit"]

    package let trainProgram: String?
    package let revisionComponents: [UInt]
    package let revisionExtraString: String?
    package let factoryIdentifier: UInt?

    package init?(trainProgram: String?, revisionComponents: [UInt], revisionExtraString: String?, factoryIdentifier: UInt?) {
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
    package static func < (lhs: Self, rhs: Self) -> Bool {
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
package struct CoreDeviceDevice: Equatable, Sendable {
    /// The Mach CPU identifiers reported by the device's hardware properties.
    package struct CPUType: Equatable, Sendable {
        package let type: Int32
        package let subtype: Int32

        package init(type: Int32, subtype: Int32) { self.type = type; self.subtype = subtype }
    }

    /// The CoreDevice identifier passed to devicectl, which can differ from `udid`.
    package let identifier: String
    package let udid: String?
    package let kind: DeviceInventoryKind
    package let name: String
    /// The device-reported name before applying display fallbacks.
    package let reportedName: String?
    package let modelIdentifier: String?
    package let modelName: String?
    package let cpuType: CPUType?
    package let platform: String?
    package let osVersion: String?
    package let osBuild: String?
    /// DeviceInfo.osBuildUpdate: the supplemental build when one is reported, otherwise the base build.
    /// Nil when that build has no usable typed comparison fields; see ``CoreDeviceBuildUpdate``.
    package let osBuildUpdate: CoreDeviceBuildUpdate?
    package let connectionState: String?
    package let pairingState: String?
    package let transportType: String?
    package let bootState: String?
    /// CoreDevice's raw preparedness bitset, when supplied by the inventory.
    package let preparednessState: Int?
    package let capabilities: Set<String>
    package let lastConnectedAt: Date?
    package let visibilityClass: String?

    /// The hardware reality represented by the classification, including unrecognized raw values.
    package init(identifier: String, udid: String?, kind: DeviceInventoryKind, name: String, reportedName: String?,
         modelIdentifier: String?, modelName: String?, cpuType: CPUType?, platform: String?, osVersion: String?,
         osBuild: String?, osBuildUpdate: CoreDeviceBuildUpdate?, connectionState: String?, pairingState: String?,
         transportType: String?, bootState: String?, preparednessState: Int?, capabilities: Set<String>,
         lastConnectedAt: Date?, visibilityClass: String?) {
        self.identifier = identifier
        self.udid = udid
        self.kind = kind
        self.name = name
        self.reportedName = reportedName
        self.modelIdentifier = modelIdentifier
        self.modelName = modelName
        self.cpuType = cpuType
        self.platform = platform
        self.osVersion = osVersion
        self.osBuild = osBuild
        self.osBuildUpdate = osBuildUpdate
        self.connectionState = connectionState
        self.pairingState = pairingState
        self.transportType = transportType
        self.bootState = bootState
        self.preparednessState = preparednessState
        self.capabilities = capabilities
        self.lastConnectedAt = lastConnectedAt
        self.visibilityClass = visibilityClass
    }

    package var reality: String {
        switch kind {
        case .simulator: "simulated"
        case .physical: "physical"
        case .virtualMachine: "virtual"
        case .other(let raw): raw
        }
    }

    /// CoreDevice also exposes this capability before an unpaired device reports its hardware classification.
    package var needsHostPairing: Bool {
        pairingState != "paired" && capabilities.contains("com.apple.coredevice.feature.inititatepairing")
    }

    /// A disconnected but discoverable device can expose the explicit connect operation.
    package var isAvailable: Bool { connectionState == "connected" || connectionState == "disconnected" }
}

