import ABIBridge
import Foundation
import NeoSimulatorDeviceIO
import NeoSimulatorKit

@MainActor
package final class NativeDevicePostureTransport: DevicePostureTransport {
    private let remote: CoreDeviceRemoteScreenDevice
    private let config: NativeSwiftValue
    private let monitor: @MainActor (NativeSwiftValue) async throws -> NativeSwiftValue
    private let prepareVendorSend: @MainActor (NativeSwiftValue) async throws -> (@MainActor (Data) throws -> Void)
    private let isValid: NativeSwiftMethod<() -> Bool>
    private let readAngle: NativeSwiftMethod<() -> Measurement<UnitAngle>>

    package static func make(_ identifier: DeviceInventoryID) async throws -> (any DevicePostureTransport)? {
        let commandID: String
        switch identifier.destination {
        case .coreDevice(let id): commandID = id
        case .simulator(let udid, nil):
            guard let id = try await CoreDeviceRemoteScreenDevice.simulatorIdentifier(udid: udid) else { return nil }
            commandID = id
        case .simulator(_, .some):
            // DeviceInfo's UDID cannot distinguish duplicate UDIDs in different device sets.
            return nil
        }
        let remote = try await CoreDeviceRemoteScreenDevice(identifier: commandID)
        let deviceInfo = try await remote.type.resolve(.swift(.getter("deviceInfo", as: (() -> NativeSwiftValue).self)))
        let info = try unsafe deviceInfo.unsafeInvoke(on: remote.object)
        let hardware = try await info.type.resolve(.swift(.getter("hardwareModel", as: (() -> String?).self)))
        let model = try unsafe hardware.unsafeInvoke(on: info)
        let features = try Set(DevicePosturePayload.features.filter { try remote.supports($0) })
        guard DevicePosturePayload.supports(hardwareModel: model, features: features) else { return nil }
        let implementation = try await remote.implementation(capability: "MonitorMotionCapability", feature: "com.apple.coredevice.feature.monitormotion")
        let errorType = try await remote.runtime.resolve(.swift(.type("CoreDevice.CoreDeviceError")))
        let sampleError = try await errorType.resolve(.swift(.staticGetter("ioError", as: (() -> NativeSwiftValue).self,
            valueABIs: [errorType: try .opaque(named: errorType.name)])))
        let owner = try unsafe sampleError.unsafeInvoke()
        // Open the framework's actual Error representation instead of mirroring its resilient layout.
        guard let failure = try owner.withCopy({ $0 as? any Error }) else {
            throw RemoteScreenError.unavailable("device-posture-error-type", "The native posture error type could not be resolved.")
        }
        return try await make(remote: remote, implementation: implementation, failure: failure)
    }

    private static func make<Failure: Error>(remote: CoreDeviceRemoteScreenDevice, implementation: NativeSwiftValue,
                                            failure: Failure) async throws -> (any DevicePostureTransport)? {
        let getMotion = try await implementation.type.resolve(.swift(.method("CoreDevice.MonitorMotionProtocol.motionManager()",
            as: (() async throws(Failure) -> NativeSwiftValue).self)))
        let motion = try await unsafe getMotion.unsafeInvoke(on: implementation)
        let supportsHinge = try await motion.type.resolve(.swift(.getter("supportsHingeAngle", as: (() -> Bool).self)))
        guard try unsafe supportsHinge.unsafeInvoke(on: motion) else { return nil }
        return try await remote.runtime.prepare { _ in
            try await NativeDevicePostureTransport(remote: remote, motion: motion, failure: failure)
        }
    }

    private init<Failure: Error>(remote: CoreDeviceRemoteScreenDevice, motion: NativeSwiftValue, failure: Failure) async throws {
        self.remote = remote
        let runtime = remote.runtime
        let snapshot = try await runtime.resolve(.swift(.type("CoreDeviceUtilities.DeviceHingeAngleSnapshot")))
        let configuration = try await runtime.resolve(.swift(.type("CoreDeviceUtilities.HingeAngleStreamConfig")))
        let array = try await runtime.resolve(.swift(.type("Swift.Array", genericArguments: [.type(snapshot)])))
        let arguments: [NativeSwiftGenericArgument] = [.type(array), .type((any Error).self)]
        let sequence = try await runtime.resolve(.swift(.type("Swift.AsyncThrowingStream", genericArguments: arguments)))
        let measurement = try await runtime.resolve(.swift(.type("Foundation.Measurement", genericArguments: [.type(UnitAngle.self)])))
        let abis = try Dictionary(uniqueKeysWithValues: [snapshot, configuration, sequence, measurement]
            .map { ($0, try NativeType.opaque(named: $0.name)) })
        let makeConfig = try await configuration.resolve(.swift(.initializer("init(changeThreshold:updateInterval:)",
            as: ((Measurement<UnitAngle>, Duration) -> NativeSwiftValue).self, valueABIs: abis)))
        config = try unsafe makeConfig.unsafeInvoke(Measurement(value: 0.01, unit: .degrees), .milliseconds(50))
        let monitor = try await motion.type.resolve(.swift(.method("monitorHingeAngle(config:)",
            as: ((NativeSwiftValue) async throws(Failure) -> NativeSwiftValue).self, valueABIs: abis)))
        self.monitor = { config in try await unsafe monitor.unsafeInvoke(on: motion, config) }
        let data = try await runtime.resolve(.swift(.type("Foundation.Data")))
        // Data is @frozen; Device Hub passes its two words in integer registers.
        let dataABI = try NativeType.structure(named: data.name, fields: [.uint64, .uint64])
        prepareVendorSend = { implementation in
            let send = try await implementation.type.resolve(.swift(.method("CoreDevice.HIDVendorDefined.send(usagePage:usage:version:data:)",
                as: ((UInt16, UInt16, UInt32, Data) throws(Failure) -> Void).self, valueABIs: [data: dataABI])))
            return { data in try unsafe send.unsafeInvoke(on: implementation, 0xFF61, 0x5B, 0, data) }
        }
        isValid = try await snapshot.resolve(.swift(.getter("isAngleValid", as: (() -> Bool).self, valueABIs: abis)))
        readAngle = try await snapshot.resolve(.swift(.getter("angle", as: (() -> Measurement<UnitAngle>).self, valueABIs: abis)))
    }

    package func observe(_ update: @escaping @MainActor (Double?) -> Void) async throws {
        let owner = try await monitor(config)
        defer { withExtendedLifetime(owner) {} }
        guard let sequence = try owner.withCopy({ $0 as? any AsyncSequence }) else {
            throw RemoteScreenError.unavailable("device-posture-observation", "The device's hinge-angle changes could not be observed.")
        }
        try await observe(sequence, update: update)
    }

    private func observe<S: AsyncSequence>(_ sequence: S, update: @MainActor (Double?) -> Void) async throws {
        var iterator = sequence.makeAsyncIterator()
        while let batch = try await iterator.next(isolation: #isolation) {
            try Task.checkCancellation()
            guard let snapshots = batch as? [Any] else {
                throw RemoteScreenError.io("device-posture-snapshot", "The device supplied an unexpected hinge-angle snapshot.")
            }
            guard let snapshot = snapshots.last, try unsafe isValid.unsafeInvoke(on: snapshot) else { update(nil); continue }
            let angle = try unsafe readAngle.unsafeInvoke(on: snapshot).converted(to: .degrees).value
            update(angle.isFinite ? angle : nil)
        }
    }

    package func send(_ posture: DevicePosture) async throws {
        try validateCapabilities()
        let implementation = try await remote.implementation(capability: "VendorDefinedHIDCapability",
            feature: "com.apple.coredevice.feature.remote.hid.vendordefined")
        let send = try await prepareVendorSend(implementation)
        try Task.checkCancellation()
        try validateCapabilities()
        try send(DevicePosturePayload.serialize(posture))
    }

    private func validateCapabilities() throws {
        guard try DevicePosturePayload.features.allSatisfy({ try remote.supports($0) }) else {
            throw RemoteScreenError.unavailable("device-posture-capability", "The device no longer exposes posture controls.")
        }
    }
}
