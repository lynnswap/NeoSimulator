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

        let coreSimulator = makeRouteStatus(
            preferences: .coreSimulator,
            receiptStatus: .managed(original: .deviceHub)
        )
        #expect(
            coreSimulator.rendered
                == "Simulator route: CoreSimulator"
        )
    }

    @Test func compactStatusAddsOnlyActionableSafetyWarnings() throws {
        let pending = makeRouteStatus(
            preferences: .coreSimulator,
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
            receiptStatus: .conflict(
                expected: .coreSimulator,
                observed: .deviceHub
            )
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
        #expect(status.rendered.contains("NeoSimulator: validated"))
        #expect(status.rendered.contains("Legacy Simulator: validated"))
        #expect(status.rendered.contains("NeoSimulator.app"))
        #expect(status.rendered.contains("CoreSimulator version: 1171.6"))
        #expect(status.rendered.contains("Contents/Developer/usr/bin/simctl"))
        #expect(status.rendered.contains("Resources/bin/simctl"))
        #expect(status.rendered.contains("CoreDevice version: 642.15"))
        #expect(status.rendered.contains("Contents/Developer/usr/bin/devicectl"))
        #expect(status.rendered.contains("Resources/bin/devicectl"))
        #expect(status.rendered.contains("Simulator CoreDevice plugin (1171.6)"))
        #expect(status.rendered.contains("Restoration receipt: none"))
        #expect(status.rendered.contains("Running Xcode processes: 2"))
        #expect(status.rendered.contains("Running NeoSimulator processes: 1"))
        #expect(status.rendered.contains("Running legacy Simulator processes: 1"))
        #expect(status.rendered.contains("CoreSimulator session: not set (default)"))
        #expect(status.rendered.contains("Suppress Device Hub auto-start: not set (default)"))
        #expect(!status.rendered.contains("Configured host:"))
    }

    @Test func sameRouteHostSwitchIsReportedAsAHostSelection() throws {
        let xcode = XcodeInstallation(
            applicationURL: URL(fileURLWithPath: "/Applications/Xcode_27.app"),
            version: try ToolVersion("27.0"),
            buildVersion: "27A5252f"
        )
        let legacyXcode = XcodeInstallation(
            applicationURL: URL(fileURLWithPath: "/Applications/Xcode_26.app"),
            version: try ToolVersion("26.6"),
            buildVersion: "17F109"
        )
        let report = ModeChangeReport(
            host: .legacy(
                SimulatorInstallation(
                    applicationURL: legacyXcode.applicationURL.appendingPathComponent(
                        ToolConstants.simulatorPath,
                        isDirectory: true
                    ),
                    xcode: legacyXcode,
                    version: "16.0",
                    buildVersion: "1063.4"
                )
            ),
            didChangePreferences: false,
            xcode: xcode,
            receiptURL: nil,
            terminatedDeviceHubCount: 0,
            terminatedNeoHostCount: 1,
            terminatedLegacySimulatorCount: 0
        )

        #expect(report.rendered.hasPrefix("Selected simulator host: legacy\n"))
        #expect(report.rendered.contains("Preference route: already CoreSimulator"))
        #expect(report.rendered.contains("Closed NeoSimulator instances: 1"))
        #expect(!report.rendered.contains("already configured"))
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
        let neoHostURL = URL(
            fileURLWithPath: "/usr/local/libexec/xcode-simulator-host/NeoSimulator.app"
        )
        return HostStatus(
            xcode: selectedXcode,
            routeStatus: SimulatorRouteStatus(
                preferences: preferences,
                receiptStatus: receiptStatus
            ),
            neoHost: NeoHostInstallation(
                applicationURL: neoHostURL,
                xcode: selectedXcode,
                simulatorKitBinaryURL: URL(
                    fileURLWithPath: "/Applications/Xcode_27.app/Contents/SharedFrameworks/SimulatorKit.framework/Versions/A/SimulatorKit"
                ),
                idePlaygroundSimulatorBinaryURL: URL(
                    fileURLWithPath: "/Applications/Xcode_27.app/Contents/Frameworks/IDEPlaygroundSimulator.framework/Versions/A/IDEPlaygroundSimulator"
                ),
                coreSimulatorBinaryURL: URL(
                    fileURLWithPath: "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/CoreSimulator"
                ),
                coreSimulatorVersion: "1171.6",
                simctlWrapperURL: URL(
                    fileURLWithPath: "/Applications/Xcode_27.app/Contents/Developer/usr/bin/simctl"
                ),
                simctlBinaryURL: URL(
                    fileURLWithPath: "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl"
                ),
                coreDeviceBinaryURL: URL(
                    fileURLWithPath: "/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/CoreDevice"
                ),
                coreDeviceVersion: "642.15",
                devicectlWrapperURL: URL(
                    fileURLWithPath: "/Applications/Xcode_27.app/Contents/Developer/usr/bin/devicectl"
                ),
                devicectlBinaryURL: URL(
                    fileURLWithPath: "/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/Resources/bin/devicectl"
                ),
                simulatorCoreDevicePluginBinaryURL: URL(
                    fileURLWithPath: "/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/PlugIns/SimulatorCoreDevicePlugin.coredeviceplugin/Contents/MacOS/SimulatorCoreDevicePlugin"
                )
            ),
            legacySimulator: SimulatorInstallation(
                applicationURL: URL(
                    fileURLWithPath: "/Applications/Xcode_26.app/Contents/Developer/Applications/Simulator.app"
                ),
                xcode: XcodeInstallation(
                    applicationURL: URL(
                        fileURLWithPath: "/Applications/Xcode_26.app"
                    ),
                    version: try ToolVersion("26.6"),
                    buildVersion: "17F109"
                ),
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
                    bundleURL: selectedXcode.applicationURL
                ),
            ],
            runningNeoHosts: [
                RunningApplication(
                    processIdentifier: 71_204,
                    bundleURL: neoHostURL,
                    bundleIdentifier: ToolConstants.neoHostBundleIdentifier
                ),
            ],
            runningLegacySimulators: [
                RunningApplication(
                    processIdentifier: 72_205,
                    bundleURL: URL(
                        fileURLWithPath: "/Applications/Xcode_26.app/Contents/Developer/Applications/Simulator.app"
                    ),
                    bundleIdentifier: ToolConstants.simulatorBundleIdentifier
                ),
            ]
        )
    }
}
