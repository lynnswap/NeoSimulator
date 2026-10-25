import Foundation
import Testing

@testable import XcodeSimulatorHost

@Suite
struct XcodeConnectionTrackerTests {
    @Test func bootObservedByLaterXcodeRefreshesEarlierSourceBeforeHandlingConnection() async throws {
        let source = URL(fileURLWithPath: "/SourceXcode.app")
        let previousOwner = URL(fileURLWithPath: "/OtherXcode.app")
        func device(_ state: String) -> SimulatorHostDevice {
            SimulatorHostDevice(identifier: "A", name: "Phone", descriptiveName: "Phone",
                runtimeIdentifier: "runtime", runtimeName: "iOS", productFamily: "iPhone", state: state)
        }
        let earlySourceCatalog = [device("Booting")]
        let laterOtherCatalog = [device("Booted")]
        let connection = XcodeSimulatorConnection(
            event: .init(processIdentifier: 1, startSeconds: 10, startMicroseconds: 0),
            deviceIdentifier: "A", xcodeURL: source)
        let tracker = XcodeConnectionTracker()
        var owner = previousOwner

        _ = try await tracker.synchronize(observations: [connection],
            runningDeviceIdentifiers: Set((earlySourceCatalog + laterOtherCatalog).filter { $0.state == "Booted" }.map(\.inventoryID))) { connection in
            let current = try await SimulatorHostController.connectionCatalog(
                for: connection.deviceID, cachedDevices: earlySourceCatalog, readCatalog: { [device("Booted")] })
            guard current.contains(where: { $0.inventoryID == connection.deviceID && $0.state == "Booted" }) else { return }
            owner = connection.xcodeURL
        }

        #expect(owner == source)
    }
}
