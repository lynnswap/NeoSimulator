import ABIBridge
import Foundation
import Network
import XPC

/// Holds developer services while a physical device's screen and input are in use.
@MainActor
package final class CoreDeviceScreenConnection {
    package struct Endpoint: Decodable, Sendable {
        package let ipv6Address: String
        package let port: UInt16
    }

    package struct Stream: Sendable {
        package let receiver: Endpoint
        package let sender: Endpoint
        package let answer: Data
    }

    private struct ConnectionInfo: Decodable {
        let receiver: Endpoint
        let sender: Endpoint
    }

    package let remote: CoreDeviceRemoteScreenDevice
    package private(set) var supportsPrimaryStream = false
    private var assertion: NativeSwiftValue?
    private var identifier: UInt32?
    private var preparing: Task<Void, any Error>?
    private var starting: Task<Void, any Error>?
    private var stopping: Task<Void, any Error>?
    private var stream: Stream?

    private init(remote: CoreDeviceRemoteScreenDevice) { self.remote = remote }

    package static func prepare(remote: CoreDeviceRemoteScreenDevice) async throws -> CoreDeviceScreenConnection {
        let connection = CoreDeviceScreenConnection(remote: remote)
        let preparing = Task { try await connection.prepare() }
        connection.preparing = preparing
        do {
            try await CoreDeviceRuntime.preparedValue(of: preparing)
            try Task.checkCancellation()
            return connection
        } catch {
            do { try await connection.stop() } catch let cleanup {
                throw DeviceIOError.io(
                    "remote-screen-preparation",
                    "\(error.localizedDescription) Releasing the device also failed: \(cleanup.localizedDescription)")
            }
            throw error
        }
    }

    private func prepare() async throws {
        let runtime = remote.runtime
        let state = try await runtime.resolve(.swift(.type("CoreDevice.AssertableDeviceState")))
        let requirements = try await runtime.resolve(.swift(.type("CoreDevice.UsageAssertionRequirements")))
        let abis = try Dictionary(
            uniqueKeysWithValues: [state, requirements].map { ($0, try NativeType.opaque(named: $0.name)) })
        var states: [NativeSwiftValue] = []
        for name in [
            "developerModeEnabledIfRequired", "coreDeviceServicesLoaded", "extendedDeviceInfoLoaded",
            "remoteServiceDiscoveryTrustedConnectivityAvailable", "secureNetworkingAvailable",
        ] {
            let read = try await state.resolve(
                .swift(.staticGetter(name, as: (() -> NativeSwiftValue).self, valueABIs: abis)))
            states.append(try unsafe read.unsafeInvoke())
        }
        let make = try await requirements.resolve(
            .swift(
                .initializer(
                    "init(deviceStates:capabilities:)",
                    as: (([NativeSwiftValue], [NativeSwiftValue]) -> NativeSwiftValue).self, valueABIs: abis)))
        let required = try unsafe make.unsafeInvoke(states, [])
        let acquire = try await remote.type.resolve(
            .swift(
                .method(
                    "CoreDevice.RemoteDevice.acquireDeviceUsageAssertion(withReason: Swift.String, requirements: CoreDevice.UsageAssertionRequirements) async throws -> CoreDevice.DeviceUsageAssertion",
                    as: ((String, NativeSwiftValue) async throws -> NativeSwiftValue).self, valueABIs: abis)))
        assertion = try await unsafe acquire.unsafeInvoke(on: remote.object, "NeoSimulator device screen", required)

        let read = try await remote.type.resolve(
            .swift(
                .getter(
                    "mediaStreamSupportInfo",
                    as: (() async throws -> NativeSwiftValue).self)))
        let support = try await unsafe read.unsafeInvoke(on: remote.object)
        let common = try await support.type.resolve(.swift(.getter("common", as: (() -> NativeSwiftValue).self)))
        let commonValue = try unsafe common.unsafeInvoke(on: support)
        let features = try await commonValue.type.resolve(.swift(.getter("supportedFeatures", as: (() -> UInt64).self)))
        let supported = try unsafe features.unsafeInvoke(on: commonValue)
        let featureType = try await runtime.resolve(.swift(.type("CoreDevice.MediaStreamSupportedFeatures")))
        let featureABI: [NativeSwiftType: NativeType] = [featureType: try .opaque(named: featureType.name)]
        let primary = try await featureType.resolve(
            .swift(
                .staticGetter(
                    "primaryDisplayMirroredOutput",
                    as: (() -> NativeSwiftValue).self, valueABIs: featureABI)))
        let raw = try await featureType.resolve(
            .swift(
                .getter(
                    "rawValue", as: (() -> UInt64).self,
                    valueABIs: featureABI, receiverABI: featureABI[featureType])))
        let mask = try unsafe raw.unsafeInvoke(on: primary.unsafeInvoke())
        supportsPrimaryStream = supported & mask == mask
    }

    package func negotiatorOptions() async throws -> [String: Any] {
        let info = try await deviceInfo()
        let helper = try await remote.runtime.resolve(.swift(.type("CoreDevice.MediaStreamHelper")))
        let read = try await helper.resolve(
            .swift(
                .staticMethod(
                    "getNegotiatorOptions(for:)",
                    as: ((NativeSwiftValue) -> [String: Any]).self)))
        var options = try unsafe read.unsafeInvoke(info)
        let media = try await remote.runtime.resolve(.swift(.type("CoreDevice.DeviceMediaStream")))
        for (name, value) in [
            ("kAVCMediaStreamOptionClientName", "CoreDeviceScreenSharing" as Any),
            ("kAVCMediaStreamOptionClientSessionID", UUID() as Any),
        ] {
            let key = try await media.resolve(.swift(.staticGetter(name, as: (() -> String).self)))
            let name = try unsafe key.unsafeInvoke()
            options[name] = value
        }
        options["avcMediaStreamOptionCallID"] = UUID().uuidString
        return options
    }

    package func tunnelAddress() async throws -> String {
        let info = try await deviceInfo()
        let read = try await info.type.resolve(.swift(.getter("tunnelIPAddressString", as: (() -> String?).self)))
        guard let address = try unsafe read.unsafeInvoke(on: info) else {
            throw DeviceIOError.unavailable("remote-screen-tunnel", "The device has no paired connection to this Mac.")
        }
        return address
    }

    private func deviceInfo() async throws -> NativeSwiftValue {
        let read = try await remote.type.resolve(.swift(.getter("deviceInfo", as: (() -> NativeSwiftValue).self)))
        return try unsafe read.unsafeInvoke(on: remote.object)
    }

    /// A cancelled consumer stops waiting; the native start remains owned until stop can end it.
    package func start(offer: Data, options: [String: Any], receiverIP: String, receiverPort: UInt16) async throws
        -> Stream
    {
        let task = Task { [self] in
            let runtime = remote.runtime
            let valueType = try await runtime.resolve(.swift(.type("CoreDevice.CodableValue")))
            let requestType = try await runtime.resolve(.swift(.type("CoreDevice.DeviceMediaStream.StartRequest")))
            let directionType = try await runtime.resolve(.swift(.type("CoreDevice.DeviceMediaStream.Direction")))
            let streamType = try await runtime.resolve(.swift(.type("CoreDevice.DeviceMediaStream.StreamType")))
            let dataType = try await runtime.resolve(.swift(.type("Foundation.Data")))
            var abis = try Dictionary(
                uniqueKeysWithValues: [valueType, requestType, directionType, streamType].map {
                    ($0, try NativeType.opaque(named: $0.name))
                })
            abis[dataType] = try .structure(named: dataType.name, fields: [.uint64, .uint64])
            let makeValue = try await valueType.resolve(
                .swift(
                    .initializer(
                        "init(_:)",
                        as: ((Any) -> NativeSwiftValue?).self, valueABIs: abis)))
            let coded = try options.compactMapValues { try unsafe makeValue.unsafeInvoke($0) }
            let make = try await requestType.resolve(
                .swift(
                    .initializer(
                        "init(timeout:type:direction:negotiatorOffer:clientSupportedFeatures:receiverIP:receiverPort:options:)",
                        as: ((
                            UInt, NativeSwiftValue, NativeSwiftValue, Data, UInt64, String?, UInt16?,
                            [String: NativeSwiftValue]
                        ) -> NativeSwiftValue).self,
                        valueABIs: abis)))
            let featureType = try await runtime.resolve(.swift(.type("CoreDevice.MediaStreamSupportedFeatures")))
            let featureABI: [NativeSwiftType: NativeType] = [featureType: try .opaque(named: featureType.name)]
            let current = try await featureType.resolve(
                .swift(.staticGetter("current", as: (() -> NativeSwiftValue).self, valueABIs: featureABI)))
            let raw = try await featureType.resolve(
                .swift(
                    .getter(
                        "rawValue", as: (() -> UInt64).self,
                        valueABIs: featureABI, receiverABI: featureABI[featureType])))
            let supported = try unsafe raw.unsafeInvoke(on: current.unsafeInvoke())
            let request = try unsafe make.unsafeInvoke(
                15, streamType.makeEnumCase(named: "video"),
                directionType.makeEnumCase(named: "output"), offer, supported, receiverIP, receiverPort, coded)
            let start = try await remote.type.resolve(
                .swift(
                    .method(
                        "startMediaStream(with:)",
                        as: ((NativeSwiftValue) async throws -> NativeSwiftValue).self, valueABIs: abis)))
            let response = try await unsafe start.unsafeInvoke(on: remote.object, request)
            let readConnection = try await response.type.resolve(
                .swift(.getter("connection", as: (() -> NativeSwiftValue).self)))
            let connection = try unsafe readConnection.unsafeInvoke(on: response)
            let readConfiguration = try await connection.type.resolve(
                .swift(.getter("streamConfig", as: (() -> NativeSwiftValue).self)))
            let configuration = try unsafe readConfiguration.unsafeInvoke(on: connection)
            let readID = try await configuration.type.resolve(.swift(.getter("StreamInputID", as: (() -> Int).self)))
            let nativeID = try unsafe readID.unsafeInvoke(on: configuration)
            guard let id = UInt32(exactly: nativeID) else {
                throw DeviceIOError.io(
                    "remote-screen-stream-id", "The device returned an invalid screen stream identifier.")
            }
            identifier = id
            let data = try connection.withCopy { value -> Data in
                guard let value = value as? any Encodable else {
                    throw DeviceIOError.io(
                        "remote-screen-stream-info", "The device's screen connection could not be read.")
                }
                return try JSONEncoder().encode(value)
            }
            let info = try JSONDecoder().decode(ConnectionInfo.self, from: data)
            let readAnswer = try await response.type.resolve(
                .swift(.getter("negotiatorAnswer", as: (() -> Data).self, valueABIs: abis)))
            stream = Stream(
                receiver: info.receiver, sender: info.sender,
                answer: try unsafe readAnswer.unsafeInvoke(on: response))
        }
        starting = task
        try await CoreDeviceRuntime.preparedValue(of: task)
        guard let stream else {
            throw DeviceIOError.io("remote-screen-stream", "The device did not return its screen connection.")
        }
        return stream
    }

    /// Duplicates the tunnel's connected socket; the caller owns the descriptor.
    package func socket(for stream: Stream) async throws -> Int32 {
        guard let source = IPv6Address(stream.receiver.ipv6Address),
            let destination = IPv6Address(stream.sender.ipv6Address)
        else {
            throw DeviceIOError.io(
                "remote-screen-stream-address", "The device returned an invalid screen stream address.")
        }
        let utility = try await remote.runtime.resolve(.swift(.type("CoreDevice.NetworkUtils")))
        let addressType = try await remote.runtime.resolve(.swift(.type("Network.IPv6Address")))
        let abis: [NativeSwiftType: NativeType] = [addressType: try .opaque(named: addressType.name)]
        let share = try await utility.resolve(
            .swift(
                .staticMethod(
                    "withSharedSocketDictionary(sourceAddress:port:remoteAddress:remotePort:body:)",
                    as: ((IPv6Address, UInt16, IPv6Address, UInt16, NativeSwiftClosure<(xpc_object_t) throws -> Int32>)
                        throws -> Int32).self,
                    genericArguments: [.type(Int32.self)], valueABIs: abis)))
        let duplicate = try NativeSwiftClosure<(xpc_object_t) throws -> Int32> { dictionary in
            var descriptor: Int32 = -1
            xpc_dictionary_apply(dictionary) { _, value in
                guard xpc_get_type(value) == XPC_TYPE_FD else { return true }
                descriptor = xpc_fd_dup(value)
                return false
            }
            return descriptor
        }
        let descriptor = try unsafe share.unsafeInvoke(
            source, stream.receiver.port, destination, stream.sender.port, duplicate)
        guard descriptor >= 0 else {
            throw DeviceIOError.io(
                "remote-screen-stream-socket", "CoreDevice did not share a socket for the device screen.")
        }
        return descriptor
    }

    package func stop() async throws {
        if let stopping {
            guard await stopping.ends(before: .now + DeviceOperationLimit.captureStreamStop) else {
                throw DeviceIOError.io(
                    "remote-screen-stop",
                    "The device screen is still stopping. Its connection stays open until the native operation finishes."
                )
            }
            defer { self.stopping = nil }
            try await stopping.value
            return
        }
        let task = Task { [self] in
            _ = await preparing?.result
            _ = await starting?.result
            if let identifier {
                let type = try await remote.runtime.resolve(.swift(.type("CoreDevice.DeviceMediaStream.StopRequest")))
                let abis: [NativeSwiftType: NativeType] = [type: try .opaque(named: type.name)]
                let make = try await type.resolve(
                    .swift(
                        .initializer(
                            "init(stopAll:identifiers:)",
                            as: ((Bool, [UInt32]?) -> NativeSwiftValue).self, valueABIs: abis)))
                let stop = try await remote.type.resolve(
                    .swift(
                        .method(
                            "stopMediaStream(with:)",
                            as: ((NativeSwiftValue) async throws -> NativeSwiftValue).self, valueABIs: abis)))
                let request = try unsafe make.unsafeInvoke(false, [identifier])
                _ = try await unsafe stop.unsafeInvoke(on: remote.object, request)
                self.identifier = nil
                stream = nil
            }
            if let assertion {
                let release = try await assertion.type.resolve(
                    .swift(.method("releaseAssertion()", as: (() -> Void).self)))
                try unsafe release.unsafeInvoke(on: assertion)
                self.assertion = nil
            }
        }
        stopping = task
        guard await task.ends(before: .now + DeviceOperationLimit.captureStreamStop) else {
            throw DeviceIOError.io(
                "remote-screen-stop",
                "The device screen is still stopping. Its connection stays open until the native operation finishes.")
        }
        defer { stopping = nil }
        try await task.value
    }
}
