import ABIBridge
import Foundation

/// One native UniversalHID service. Its owner builds the reports, orders their sends, and tracks what they hold.
@MainActor
package final class CoreDeviceHIDService {
    /// CoreDevice consumes its bundled module; DeviceKit can also load the system module with the same name.
    package nonisolated static let universalHIDURL = URL(fileURLWithPath: "/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/Frameworks/UniversalHID.framework/Versions/A/UniversalHID")

    package nonisolated static let universalHIDFeature = "com.apple.coredevice.feature.remote.universalhidservice"

    private let sendNative: (NativeSwiftValue) throws -> Void
    private let resetNative: () throws -> Void
    private let removeNative: () async throws -> Void
    package private(set) var isRemoved = false

    package init(send: @escaping (NativeSwiftValue) throws -> Void, reset: @escaping () throws -> Void,
         remove: @escaping () async throws -> Void) {
        sendNative = send
        resetNative = reset
        removeNative = remove
    }

    /// Loads CoreDevice's own UniversalHID module, which `universalHIDType` then finds.
    package nonisolated static func loadUniversalHID() async throws {
        try await CoreDeviceRemoteScreenDevice.load(universalHIDURL.path)
    }

    /// Resolves a type from CoreDevice's own UniversalHID module, once ``loadUniversalHID()`` has loaded it.
    package nonisolated static func universalHIDType(_ name: String, runtime: ABIRuntime) throws -> NativeSwiftType {
        try runtime.resolveAndWait(.swift(.type("UniversalHID." + name)), in: .path(universalHIDURL), loading: .loadedOnly)
    }

    /// `HIDReport` wraps the report's `Data`; its exported members pass those two words directly,
    /// while native value witnesses still own and copy the payload.
    package nonisolated static func reportABI(runtime: ABIRuntime) throws -> (type: NativeSwiftType, abi: NativeType) {
        let type = try universalHIDType("HIDReport", runtime: runtime)
        return (type, try .structure(named: type.name, fields: [.uint64, .uint64]))
    }

    /// Creates the service `descriptor` describes. Its reports must come from CoreDevice's UniversalHID module.
    package static func connect(remote: CoreDeviceRemoteScreenDevice, descriptor: NativeSwiftValue) async throws -> CoreDeviceHIDService {
        let runtime = remote.runtime
        let errorType = try await runtime.resolve(.swift(.type("CoreDevice.CoreDeviceError")))
        let readError = try await errorType.resolve(.swift(.staticGetter("ioError", as: (() -> NativeSwiftValue).self,
            valueABIs: [errorType: try .opaque(named: errorType.name)])))
        guard let failure = try unsafe readError.unsafeInvoke().withCopy({ $0 as? any Error }) else {
            throw DeviceIOError.io("remote-hid-service", "The native HID service error type could not be resolved.")
        }
        return try await connect(remote: remote, descriptor: descriptor, failure: failure)
    }

    private static func connect<Failure: Error>(remote: CoreDeviceRemoteScreenDevice, descriptor nativeDescriptor: NativeSwiftValue,
                                               failure: Failure) async throws -> CoreDeviceHIDService {
        let runtime = remote.runtime
        let implementation = try await remote.implementation(capability: "UniversalHIDServiceCapability",
                                                             feature: universalHIDFeature)
        let descriptorType = try await runtime.resolve(.swift(.type("CoreDevice.HIDServiceDescriptor")))
        let serviceIDType = try await runtime.resolve(.swift(.type("CoreDevice.HIDServiceID")))
        try await loadUniversalHID()
        let report = try await runtime.prepare { try reportABI(runtime: $0) }
        let abis: [NativeSwiftType: NativeType] = [
            report.type: report.abi,
            descriptorType: try .opaque(named: descriptorType.name),
            serviceIDType: try .opaque(named: serviceIDType.name),
        ]
        // CoreDevice also declares `Swift.UInt64` service-ID overloads of `send` and `resetGestureState`, which runtime-value
        // arguments cannot tell apart by labels. Every requirement names the `HIDServiceID` declaration that `createService` returns.
        let create = try await implementation.type.resolve(.swift(.method(
            "CoreDevice.UniversalHIDService.createService(descriptor: CoreDevice.HIDServiceDescriptor) async throws(CoreDevice.CoreDeviceError) -> CoreDevice.HIDServiceID",
            as: ((NativeSwiftValue) async throws(Failure) -> NativeSwiftValue).self, valueABIs: abis)))
        let send = try await implementation.type.resolve(.swift(.method(
            "CoreDevice.UniversalHIDService.send(report: UniversalHID.HIDReport, to: CoreDevice.HIDServiceID) throws(CoreDevice.CoreDeviceError) -> ()",
            as: ((NativeSwiftValue, NativeSwiftValue) throws(Failure) -> Void).self, valueABIs: abis)))
        let reset = try await implementation.type.resolve(.swift(.method(
            "CoreDevice.UniversalHIDService.resetGestureState(service: CoreDevice.HIDServiceID) throws(CoreDevice.CoreDeviceError) -> ()",
            as: ((NativeSwiftValue) throws(Failure) -> Void).self, valueABIs: abis)))
        let remove = try await implementation.type.resolve(.swift(.method(
            "CoreDevice.UniversalHIDService.remove(service: CoreDevice.HIDServiceID) async throws(CoreDevice.CoreDeviceError) -> ()",
            as: ((NativeSwiftValue) async throws(Failure) -> Void).self, valueABIs: abis)))
        let serviceID = try await unsafe create.unsafeInvoke(on: implementation, nativeDescriptor)
        // The returned service has an owner before cancellation can abandon it.
        return CoreDeviceHIDService(send: { report in
            try unsafe send.unsafeInvoke(on: implementation, report, serviceID)
        }, reset: { try unsafe reset.unsafeInvoke(on: implementation, serviceID) },
           remove: { try await unsafe remove.unsafeInvoke(on: implementation, serviceID) })
    }

    package static func touchscreenDescriptor(displayID: UInt32, uniqueID: String, runtime: ABIRuntime) async throws -> NativeSwiftValue {
        let serviceType = try await runtime.resolve(.swift(.type("CoreDeviceUtilities.HIDServiceType")))
        let array = try await runtime.resolve(.swift(.type("Swift.Array", genericArguments: [.type((displayID: UInt32, uniqueID: String?).self)])))
        let read = try await array.resolve(.swift(.getter("Swift.Array.subscript.getter : (Swift.Int) -> A",
            as: ((Int) -> NativeSwiftValue).self)))
        let payload = try unsafe read.unsafeInvoke(on: [(displayID: displayID, uniqueID: Optional(uniqueID))], 0)
        let screen = try await serviceType.makeEnumCase(named: "touchscreen", payload: payload)
        return try await descriptor(for: screen, runtime: runtime)
    }

    package static func touchscreenGestureDescriptor(runtime: ABIRuntime) async throws -> NativeSwiftValue {
        let serviceType = try await runtime.resolve(.swift(.type("CoreDeviceUtilities.HIDServiceType")))
        let gesture = try await serviceType.makeEnumCase(named: "touchscreenGesture")
        return try await descriptor(for: gesture, runtime: runtime)
    }

    private static func descriptor(for service: NativeSwiftValue, runtime: ABIRuntime) async throws -> NativeSwiftValue {
        let serviceType = service.type
        let descriptorType = try await runtime.resolve(.swift(.type("CoreDevice.HIDServiceDescriptor")))
        let serviceIDType = try await runtime.resolve(.swift(.type("CoreDevice.HIDServiceID")))
        let abis: [NativeSwiftType: NativeType] = [serviceType: try .opaque(named: serviceType.name),
            descriptorType: try .opaque(named: descriptorType.name), serviceIDType: try .opaque(named: serviceIDType.name)]
        let descriptor = try await serviceType.resolve(.swift(.method("descriptor()", as: (() -> NativeSwiftValue).self,
            valueABIs: abis, receiverABI: abis[serviceType])))
        let serviceID = try await serviceType.resolve(.swift(.getter("serviceID", as: (() -> NativeSwiftValue).self,
            valueABIs: abis, receiverABI: abis[serviceType])))
        let setServiceID = try await descriptorType.resolve(.swift(.setter("serviceID", as: ((NativeSwiftValue) -> Void).self,
            valueABIs: abis, receiverABI: abis[descriptorType])))
        let result = try unsafe descriptor.unsafeInvoke(on: service)
        // descriptor() supplies the service properties; its ID starts unassigned.
        try unsafe setServiceID.unsafeInvoke(on: result, serviceID.unsafeInvoke(on: service))
        return result
    }

    package func send(_ report: NativeSwiftValue) throws {
        guard !isRemoved else { throw DeviceIOError.unavailable("remote-hid-service", "The HID service has ended.") }
        try sendNative(report)
    }

    /// Ends the gestures the service holds on the device, as Device Hub's HID reset does for each of its services.
    package func resetGestures() throws {
        guard !isRemoved else { throw DeviceIOError.unavailable("remote-hid-service", "The HID service has ended.") }
        try resetNative()
    }

    package func stop() async throws {
        guard !isRemoved else { return }
        var failure: (any Error)?
        do { try resetNative() } catch { failure = error }
        do { try await removeNative(); isRemoved = true }
        catch {
            failure = failure.map { DeviceIOError.io("remote-screen-cleanup", "\($0.localizedDescription) Disconnecting the screen also failed: \(error.localizedDescription)") } ?? error
        }
        if let failure { throw failure }
    }
}
