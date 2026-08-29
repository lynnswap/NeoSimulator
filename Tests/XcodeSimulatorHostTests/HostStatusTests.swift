import Foundation
import Testing

@testable import XcodeSimulatorHost

@Suite
struct HostStatusTests {
    @Test func compactStatusAnswersWhichRouteTheNextRunUses() throws {
        let deviceHub = try makeStatus(
            preferences: .deviceHub,
            receiptStatus: .unmanaged
        )
        #expect(deviceHub.compactRendered == "Simulator route: Device Hub")

        let legacy = try makeStatus(
            preferences: .legacy,
            receiptStatus: .managed(original: .deviceHub)
        )
        #expect(
            legacy.compactRendered
                == "Simulator route: CoreSimulator (Xcode 26 Simulator)"
        )
    }

    @Test func compactStatusAddsOnlyActionableSafetyWarnings() throws {
        let pending = try makeStatus(
            preferences: .legacy,
            receiptStatus: .pendingTarget
        )
        #expect(
            pending.compactRendered
                == """
                Simulator route: CoreSimulator (Xcode 26 Simulator)
                Attention: an interrupted change needs recovery. Run 'xcode-simulator-host status --verbose'.
                """
        )

        let conflict = try makeStatus(
            preferences: .deviceHub,
            receiptStatus: .conflict(expected: .legacy, observed: .deviceHub)
        )
        #expect(
            conflict.compactRendered
                == """
                Simulator route: Device Hub
                Attention: preferences need review. Run 'xcode-simulator-host status --verbose'.
                """
        )
    }

    @Test func verboseStatusStartsWithTheRouteAndKeepsTechnicalDetails() throws {
        let status = try makeStatus(
            preferences: .deviceHub,
            receiptStatus: .unmanaged
        )

        #expect(status.rendered.hasPrefix("Simulator route: Device Hub\n\n"))
        #expect(status.rendered.contains("Selected Xcode: 27.0 (27A5252f)"))
        #expect(status.rendered.contains("Legacy Simulator: Xcode 26.6"))
        #expect(status.rendered.contains("Restoration receipt: none"))
        #expect(status.rendered.contains("Running Xcode processes: 2"))
        #expect(status.rendered.contains("CoreSimulator session: not set (default)"))
        #expect(status.rendered.contains("Suppress Device Hub auto-start: not set (default)"))
        #expect(!status.rendered.contains("Configured host:"))
    }

    private func makeStatus(
        preferences: ManagedPreferenceState,
        receiptStatus: ReceiptStatus
    ) throws -> HostStatus {
        let selectedXcode = XcodeInstallation(
            applicationURL: URL(fileURLWithPath: "/Applications/Xcode_27.app"),
            version: try ToolVersion("27.0"),
            buildVersion: "27A5252f"
        )
        let legacyXcode = XcodeInstallation(
            applicationURL: URL(fileURLWithPath: "/Applications/Xcode.app"),
            version: try ToolVersion("26.6"),
            buildVersion: "17F109"
        )
        return HostStatus(
            xcode: selectedXcode,
            preferences: preferences,
            legacySimulator: SimulatorInstallation(
                applicationURL: URL(
                    fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app"
                ),
                xcode: legacyXcode,
                version: "16.0",
                buildVersion: "1063.4"
            ),
            receiptStatus: receiptStatus,
            receiptURL: URL(
                fileURLWithPath: "/Users/test/Library/Application Support/xcode-simulator-host/state.plist"
            ),
            runningXcodes: [
                RunningApplication(
                    processIdentifier: 9189,
                    bundleURL: selectedXcode.applicationURL
                ),
                RunningApplication(
                    processIdentifier: 54_923,
                    bundleURL: legacyXcode.applicationURL
                ),
            ]
        )
    }
}
