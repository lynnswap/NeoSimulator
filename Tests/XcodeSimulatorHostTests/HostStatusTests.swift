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
                == "Simulator route: CoreSimulator"
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
                Simulator route: CoreSimulator
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
        #expect(status.rendered.contains("Standalone host: validated"))
        #expect(status.rendered.contains("XcodeSimulatorLegacyHost.app"))
        #expect(status.rendered.contains("Restoration receipt: none"))
        #expect(status.rendered.contains("Running Xcode processes: 2"))
        #expect(status.rendered.contains("Running standalone host processes: 1"))
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
        let legacyHostURL = URL(
            fileURLWithPath: "/usr/local/libexec/xcode-simulator-host/XcodeSimulatorLegacyHost.app"
        )
        return HostStatus(
            xcode: selectedXcode,
            routeStatus: SimulatorRouteStatus(
                preferences: preferences,
                receiptStatus: receiptStatus
            ),
            legacyHost: LegacyHostInstallation(
                applicationURL: legacyHostURL,
                xcode: selectedXcode,
                simulatorKitBinaryURL: URL(
                    fileURLWithPath: "/Applications/Xcode_27.app/Contents/SharedFrameworks/SimulatorKit.framework/Versions/A/SimulatorKit"
                ),
                idePlaygroundSimulatorBinaryURL: URL(
                    fileURLWithPath: "/Applications/Xcode_27.app/Contents/Frameworks/IDEPlaygroundSimulator.framework/Versions/A/IDEPlaygroundSimulator"
                ),
                coreSimulatorBinaryURL: URL(
                    fileURLWithPath: "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/CoreSimulator"
                )
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
                    bundleURL: selectedXcode.applicationURL
                ),
            ],
            runningLegacyHosts: [
                RunningApplication(
                    processIdentifier: 71_204,
                    bundleURL: legacyHostURL,
                    bundleIdentifier: ToolConstants.legacyHostBundleIdentifier
                ),
            ]
        )
    }
}
