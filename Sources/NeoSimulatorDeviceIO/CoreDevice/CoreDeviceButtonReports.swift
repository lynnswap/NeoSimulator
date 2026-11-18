import ABIBridge
import Foundation

/// Builds the reports that CoreDevice's main-screen button service consumes.
@MainActor
package struct CoreDeviceButtonReports {
    private let build: (Int, Int, Bool) throws -> NativeSwiftValue

    package init(runtime: ABIRuntime) async throws {
        try await CoreDeviceHIDService.loadUniversalHID()
        let usage = try await runtime.prepare { try CoreDeviceHIDService.universalHIDType("HIDUsage", runtime: $0) }
        let button = try await runtime.resolve(.swift(.type("CoreDeviceUtilities.CustomButtonReport")))
        let report = try await runtime.prepare { try CoreDeviceHIDService.reportABI(runtime: $0) }
        let abis: [NativeSwiftType: NativeType] = [
            usage: try .structure(named: usage.name, fields: [.uint32]),
            button: try .opaque(named: button.name),
            report.type: report.abi,
        ]
        let makeUsage = try await usage.resolve(
            .swift(
                .initializer(
                    "init(page:usage:)",
                    as: ((Int, Int) -> NativeSwiftValue).self, valueABIs: abis)))
        let makeButton = try await button.resolve(
            .swift(
                .initializer(
                    "init(usage:down:)",
                    as: ((NativeSwiftValue, Bool) -> NativeSwiftValue).self, valueABIs: abis)))
        let readReport = try await button.resolve(
            .swift(
                .getter(
                    "report", as: (() -> NativeSwiftValue).self,
                    valueABIs: abis, receiverABI: abis[button])))
        build = { page, code, down in
            try unsafe readReport.unsafeInvoke(on: makeButton.unsafeInvoke(makeUsage.unsafeInvoke(page, code), down))
        }
    }

    package func make(usagePage: Int, usage: Int, state: RemoteDeviceButtonState) throws -> NativeSwiftValue {
        guard UInt16(exactly: usagePage) != nil, UInt16(exactly: usage) != nil else {
            throw DeviceIOError.unavailable(
                "guest-button-usage", "The guest's buttons take 16-bit usage pages and usages.")
        }
        return try build(usagePage, usage, state == .down)
    }
}
