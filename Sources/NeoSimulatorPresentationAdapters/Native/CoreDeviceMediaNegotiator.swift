import ABIBridge
import Foundation
import NeoSimulatorDeviceIO
import ObjectiveC

/// Builds the same offer as Device Hub without asking avconferenced to receive the video.
@MainActor
final class CoreDeviceMediaNegotiator {
    private let object: AnyObject
    private let runtime: ABIRuntime
    private static var hooksInstalled = false

    init(options: [String: Any], runtime: ABIRuntime) async throws {
        try await CoreDeviceRemoteScreenDevice.load(
            "/System/Library/PrivateFrameworks/AVConference.framework/AVConference")
        try Self.installDecoderFeatures()
        guard let type = NSClassFromString("AVCMediaStreamNegotiator") else {
            throw RemoteScreenError.unavailable(
                "remote-screen-negotiator", "This version of macOS does not provide device screen negotiation.")
        }
        let make = try await runtime.resolve(
            .objc(
                .method(
                    "initWithMode:options:error:",
                    as: ((Int, [String: Any]) throws -> AnyObject).self)), on: type)
        guard let instance = (type as? NSObject.Type)?.perform(NSSelectorFromString("alloc"))?.takeRetainedValue()
        else {
            throw RemoteScreenError.software(
                "remote-screen-negotiator", "Could not allocate the device screen negotiator.")
        }
        object = try unsafe make.unsafeInvoke(on: instance, 5, options)
        self.runtime = runtime
    }

    func offer() async throws -> Data {
        let read = try await runtime.resolve(.objc(.method("offer", as: (() -> Data?).self)), on: type(of: object))
        guard let data = try unsafe read.unsafeInvoke(on: object) else {
            throw RemoteScreenError.io("remote-screen-offer", "The device screen negotiator did not create an offer.")
        }
        return data
    }

    func accept(_ answer: Data) async throws -> UInt32 {
        let apply = try await runtime.resolve(
            .objc(
                .method(
                    "setAnswer:withError:",
                    as: ((Data) throws -> Void).self)), on: type(of: object))
        try unsafe apply.unsafeInvoke(on: object, answer)
        let configure = try await runtime.resolve(
            .objc(
                .method(
                    "generateMediaStreamConfigurationWithError:",
                    as: (() throws -> AnyObject).self)), on: type(of: object))
        let configuration = try unsafe configure.unsafeInvoke(on: object)
        let read = try await runtime.resolve(
            .objc(.method("dictionary", as: (() -> [String: Any]).self)), on: type(of: configuration))
        let values = try unsafe read.unsafeInvoke(on: configuration)
        guard (values["vcMediaStreamSRTPCipherSuite"] as? NSNumber)?.intValue == 0 else {
            throw RemoteScreenError.unavailable(
                "remote-screen-encryption",
                "The device offered an encrypted screen stream that this build cannot receive.")
        }
        guard let ssrc = values["vcMediaStreamLocalSSRC"] as? NSNumber else {
            throw RemoteScreenError.io(
                "remote-screen-receiver", "The device screen negotiator did not identify its receiver.")
        }
        return ssrc.uint32Value
    }

    /// Apple's receiver supports adaptive HEVC references that a standalone VideoToolbox decoder does not.
    /// These overrides affect this process only and are installed before the negotiator builds its offer.
    private static func installDecoderFeatures() throws {
        guard !hooksInstalled else { return }
        guard let type = NSClassFromString("AVCMediaStreamNegotiatorSettingsCoreDeviceScreenSharing"),
            let method = class_getInstanceMethod(type, NSSelectorFromString("featureListString"))
        else {
            throw RemoteScreenError.unavailable(
                "remote-screen-codec-negotiation",
                "This version of macOS cannot negotiate a standalone device screen decoder.")
        }
        typealias Getter = @convention(c) (AnyObject, Selector) -> AnyObject?
        let original = unsafeBitCast(method_getImplementation(method), to: Getter.self)
        let replacement: @convention(block) (AnyObject) -> AnyObject? = { object in
            let selector = NSSelectorFromString("featureListString")
            guard let features = original(object, selector) as? [AnyHashable: Any] else {
                return original(object, selector)
            }
            var result = features
            // idevice's standalone HEVC capability string (MIT, Copyright 2026 Jackson Coxson).
            result[100] = "FLS;MS:-1;LF:-1;LTR;CABAC;POS:0;EOD:1;HTS:2;RR:3;AR:16/9,5/8;XR:16/9,5/8;"
            return result as NSDictionary
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
        for name in ["AVCMediaStreamNegotiatorSettings", "VCMediaNegotiatorLocalConfiguration"] {
            if let type = NSClassFromString(name),
                let getter = class_getInstanceMethod(type, NSSelectorFromString("ltrpEnabled"))
            {
                let disable: @convention(block) (AnyObject) -> Bool = { _ in false }
                method_setImplementation(getter, imp_implementationWithBlock(disable))
            }
        }
        hooksInstalled = true
    }
}
