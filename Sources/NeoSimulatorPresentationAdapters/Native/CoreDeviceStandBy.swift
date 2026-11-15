import ABIBridge
import Foundation
import NeoSimulatorDeviceIO
import NeoSimulatorKit

/// Presents a device's StandBy through CoreDevice, as `devicectl device settings standby --duration` does.
///
/// A folding iPhone's guest does not present StandBy for the notification that other devices take. It presents StandBy
/// while CoreDevice holds it presented, and then only with its lock screen showing and in a pose that stands on its own:
/// closed in landscape right, partially open in either portrait, or open flat in portrait (iOS 27.2). CoreDevice refuses
/// a presentation in any other state with an error that says so.
@MainActor
package final class CoreDeviceStandBy: DeviceStandBy {
    package static let feature = "com.apple.coredevice.feature.standby"

    /// What needs no device: the presentation that CoreDevice returns.
    package struct Bindings {
        let invalidate: NativeSwiftMethod<() -> Void>

        package init(runtime: ABIRuntime) async throws {
            let session = try await runtime.resolve(.swift(.type("CoreDevice.StandBySession")))
            invalidate = try await session.resolve(.swift(.method("invalidate()", as: (() -> Void).self)))
        }
    }

    /// The device's record once CoreDevice is connected to it, or nil when that record lists no StandBy.
    private let remote: @MainActor () async throws -> CoreDeviceRemoteScreenDevice?
    /// CoreDevice's presentation, which lasts until it is invalidated or released.
    private var presentation: (session: NativeSwiftValue, invalidate: NativeSwiftMethod<() -> Void>)?
    private var stopped = false

    package var isPresented: Bool { presentation != nil }

    package init(remote: @escaping @MainActor () async throws -> CoreDeviceRemoteScreenDevice?) {
        self.remote = remote
    }

    package func present() async throws {
        guard presentation == nil, !stopped else { return }
        guard let remote = try await remote() else {
            throw RemoteScreenError.unavailable("standby-capability", "CoreDevice offers no StandBy for this device.")
        }
        let implementation = try await remote.implementation(capability: "StandByCapability", feature: Self.feature)
        let bindings = try await remote.runtime.prepare { try await Bindings(runtime: $0) }
        let present = try await implementation.type.resolve(.swift(.method("CoreDevice.StandByProtocol.presentStandBy()",
            as: (() async throws -> NativeSwiftValue).self)))
        let session = try await unsafe present.unsafeInvoke(on: implementation)
        // The display ended meanwhile, so nothing would let go of what CoreDevice now holds.
        guard !stopped else {
            try unsafe bindings.invalidate.unsafeInvoke(on: session)
            throw CancellationError()
        }
        presentation = (session, bindings.invalidate)
    }

    package func dismiss() throws {
        guard let presentation else { return }
        self.presentation = nil
        try unsafe presentation.invalidate.unsafeInvoke(on: presentation.session)
    }

    /// Lets go of StandBy with the display this belongs to, and of a presentation that answers later.
    package func stop() {
        stopped = true
        do { try dismiss() } catch { hostLog("Could not let go of the device's StandBy: \(error.localizedDescription)") }
    }
}
