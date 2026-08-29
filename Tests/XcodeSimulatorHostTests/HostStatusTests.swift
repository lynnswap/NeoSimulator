import Foundation
import Testing

@testable import XcodeSimulatorHost

@Suite
struct HostStatusTests {
    @Test func compactStatusAnswersWhichRouteTheNextRunUses() throws {
        let deviceHub = makeRouteStatus(
            preferences: .deviceHub,
            receiptStatus: .unmanaged
        )
        #expect(deviceHub.rendered == "Simulator route: Device Hub")

        let legacy = makeRouteStatus(
            preferences: .legacy,
            receiptStatus: .managed(original: .deviceHub)
        )
        #expect(
            legacy.rendered
                == "Simulator route: CoreSimulator (Xcode 26 Simulator)"
        )
    }

    @Test func compactStatusAddsOnlyActionableSafetyWarnings() throws {
        let pending = makeRouteStatus(
            preferences: .legacy,
            receiptStatus: .pendingTarget
        )
        #expect(
            pending.rendered
                == """
                Simulator route: CoreSimulator (Xcode 26 Simulator)
                Attention: an interrupted change needs recovery. Run 'xcode-simulator-host status --verbose'.
                """
        )

        let conflict = makeRouteStatus(
            preferences: .deviceHub,
            receiptStatus: .conflict(expected: .legacy, observed: .deviceHub)
        )
        #expect(
            conflict.rendered
                == """
                Simulator route: Device Hub
                Attention: preferences need review. Run 'xcode-simulator-host status --verbose'.
                """
        )
    }

    @Test func verboseStatusStartsWithTheRouteAndKeepsTechnicalDetails() throws {
        let status = try makeVerboseStatus(
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

    private func makeRouteStatus(
        preferences: ManagedPreferenceState,
        receiptStatus: ReceiptStatus
    ) -> SimulatorRouteStatus {
        SimulatorRouteStatus(
            preferences: preferences,
            receiptStatus: receiptStatus
        )
    }

    private func makeVerboseStatus(
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
            routeStatus: SimulatorRouteStatus(
                preferences: preferences,
                receiptStatus: receiptStatus
            ),
            legacySimulator: SimulatorInstallation(
                applicationURL: URL(
                    fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app"
                ),
                xcode: legacyXcode,
                version: "16.0",
                buildVersion: "1063.4"
            ),
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
