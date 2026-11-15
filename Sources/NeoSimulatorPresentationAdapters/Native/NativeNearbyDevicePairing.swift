import ABIBridge
import NeoSimulatorDeviceIO
import SwiftUI

/// DeviceKit's sheet that pairs a nearby device, which Device Hub presents from its Add button. While the sheet is
/// shown this Mac advertises itself, and the device starts pairing from its Developer Mode settings.
@MainActor
package enum NativeNearbyDevicePairing {
    package struct Bindings {
        let make: NativeSwiftFunction<() -> NativeSwiftValue>

        package init(runtime: ABIRuntime) async throws {
            let type = try await runtime.resolve(.swift(.type("DeviceKit.PairNearbyWirelessDeviceSheet")))
            make = try await type.resolve(.swift(.initializer("init()", as: (() -> NativeSwiftValue).self,
                valueABIs: [type: try .opaque(named: type.name)])))
        }
    }

    /// Loads DeviceKit and makes the sheet's content, which dismisses itself.
    package static func makeSheet() async throws -> AnyView {
        try await CoreDeviceRuntime.loadDeviceKit()
        let bindings = try await ABIRuntime.shared.prepare { try await Bindings(runtime: $0) }
        return try unsafe bindings.make.unsafeInvoke().withCopy { raw in
            guard let content = raw as? any View else {
                throw RemoteScreenError.unavailable("nearby-device-pairing", "DeviceKit returned a value that is not a SwiftUI view.")
            }
            return AnyView(content)
        }
    }
}
