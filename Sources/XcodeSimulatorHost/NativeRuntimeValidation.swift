import ABIBridge
import Foundation

/// Object-free declaration preparation. A prepared surface does not establish device support or working I/O.
@_spi(NeoSimulator)
public struct NativeRuntimeValidationReport: Codable, Equatable, Sendable {
    public struct Preparation: Codable, Equatable, Sendable {
        public enum Status: String, Codable, Sendable { case prepared, unavailable, failed }
        public enum Stage: String, Codable, Sendable { case loadingFramework, preparingBindings }
        public let surface: String
        public let stage: Stage
        public let status: Status
        public let detail: String?
        public let unverified: [String]

        @MainActor
        static func check(_ surface: String, unverified: [String],
                          load: () async throws -> Void, prepare: () async throws -> Void) async -> Self {
            var stage = Stage.loadingFramework
            do {
                try await load()
                stage = .preparingBindings
                try await prepare()
                return Self(surface: surface, stage: stage, status: .prepared, detail: nil, unverified: unverified)
            } catch {
                let unavailable: Bool
                switch error as? ABIResolutionError {
                case .imageUnavailable?, .imageNotLoaded?, .declarationNotFound?: unavailable = true
                default: unavailable = false
                }
                return Self(surface: surface, stage: stage, status: unavailable ? .unavailable : .failed,
                    detail: String(reflecting: error), unverified: unverified)
            }
        }
    }

    public let optionalBindings: [Preparation]

    /// Runs only from the explicit validator, after the required Simulator bindings have succeeded.
    /// Ordinary feature connections prepare their own bindings at their existing lazy boundaries.
    @MainActor
    public static func prepareOptionalBindings() async -> Self {
        let canvas = await Preparation.check("nativeCanvas", unverified: [
            "Device capability and button implementation", "DeviceView construction and rendering",
            "Active capture display and display-info access",
        ], load: { try await CoreDeviceDisplayGeometry.loadRuntime() }, prepare: {
            _ = try await NativeDeviceCanvas.Bindings(runtime: .shared)
        })
        let poses = await Preparation.check("nativePoseControls", unverified: [
            "PluginManager singleton and provider discovery", "Provider witness and controls(deviceID:onError:)",
            "Returned SwiftUI controls and observation",
        ], load: { try await CoreDeviceDisplayGeometry.loadRuntime() }, prepare: {
            _ = try await NativeDevicePoseControls.Bindings(runtime: .shared)
        })
        let resize = await Preparation.check("appResize", unverified: [
            "Device capability and implementation witnesses", "Native error value and typed-throws invocation",
            "Resizability streams and assertion lifecycle", "Dedicated video, geometry and input routing",
        ], load: {
            try CoreDeviceRemoteScreenDevice.load("/Library/Developer/PrivateFrameworks/CoreDeviceUtilities.framework/Versions/A/CoreDeviceUtilities")
        }, prepare: {
            let bindings = try CoreDeviceAppResizeTransport.Bindings(runtime: .shared)
            _ = try CoreDeviceAppResizeTransport.GeometryBindings(type: bindings.sceneType, abis: bindings.abis)
        })
        let hid = await Preparation.check("displayHIDValues", unverified: [
            "UniversalHID capability and implementation witnesses", "Service creation, reset and removal",
            "Report delivery to an actual display",
        ], load: {
            try CoreDeviceRemoteScreenDevice.load("/Library/Developer/PrivateFrameworks/CoreDeviceUtilities.framework/Versions/A/CoreDeviceUtilities")
        }, prepare: {
            _ = try CoreDeviceDigitizerReports(runtime: .shared)
            // This constructs an SDK value only; it never registers the illustrative display identity.
            _ = try await CoreDeviceHIDService.touchscreenDescriptor(displayID: 0, uniqueID: "runtime-validation", runtime: .shared)
        })
        let keyboard = await Preparation.check("nativeKeyboard", unverified: [
            "Device capability and UniversalHID implementation witnesses", "Guest keyboard service creation and removal",
            "Mac keyboard service properties and report delivery to an actual device",
        ], load: {
            try CoreDeviceRemoteScreenDevice.load(NativeKeyboardBindings.coreDeviceUtilitiesPath)
            try CoreDeviceRemoteScreenDevice.load(CoreDeviceEventReports.universalHIDKitURL.path)
        }, prepare: {
            // This translates a synthesized key without a device; it never creates a service.
            _ = try await NativeKeyboardBindings(runtime: .shared)
        })
        let geometry = await Preparation.check("remoteDisplayGeometry", unverified: [
            "RemoteDevice display-info reads", "Display selection and normalized orientation and size values",
            "Display-info observation",
        ], load: { try await CoreDeviceDisplayGeometry.loadRuntime() }, prepare: {
            _ = try CoreDeviceDisplayGeometry.Bindings(runtime: .shared)
        })
        return Self(optionalBindings: [canvas, poses, resize, hid, keyboard, geometry])
    }
}
