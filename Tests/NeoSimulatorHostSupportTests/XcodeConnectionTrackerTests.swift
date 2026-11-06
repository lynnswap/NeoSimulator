@testable import NeoSimulatorKit
@testable import NeoSimulatorHostSupport
import Foundation
import Testing


@Suite
struct XcodeConnectionTrackerTests {
    @Test func aDeviceUnderChangeKeepsItsPendingConnectionForTheNextObservation() async throws {
        let device = DeviceInventoryID.simulator(udid: "A", deviceSetPath: nil)
        let connection = XcodeSimulatorConnection(event: .init(processIdentifier: 1, startSeconds: 10, startMicroseconds: 0),
                                                  deviceIdentifier: "A", xcodeURL: URL(fileURLWithPath: "/Xcode.app"))
        let tracker = XcodeConnectionTracker()
        _ = try? await tracker.synchronize(observations: [connection], runningDeviceIdentifiers: [device]) { _ in
            throw CocoaError(.fileReadUnknown)
        }
        var transfers: [XcodeSimulatorConnection] = []
        // A restart passes through a stopped state, which is not the stop that retires a failed handoff.
        #expect(try await !tracker.synchronize(observations: [], runningDeviceIdentifiers: [], changingDeviceIdentifiers: [device]) {
            transfers.append($0)
        })
        #expect(try await !tracker.synchronize(observations: [], runningDeviceIdentifiers: [device], changingDeviceIdentifiers: [device]) {
            transfers.append($0)
        })
        #expect(transfers.isEmpty && tracker.hasPendingConnection(forDevice: device))
        #expect(try await tracker.synchronize(observations: [], runningDeviceIdentifiers: [device]) { transfers.append($0) })
        #expect(transfers == [connection])
    }

    @Test func aConnectionFirstSeenDuringAChangeOutlivesItsProcess() async throws {
        let device = DeviceInventoryID.simulator(udid: "A", deviceSetPath: nil)
        let connection = XcodeSimulatorConnection(event: .init(processIdentifier: 1, startSeconds: 10, startMicroseconds: 0),
                                                  deviceIdentifier: "A", xcodeURL: URL(fileURLWithPath: "/Xcode.app"))
        var transfers: [XcodeSimulatorConnection] = []
        // The change may show the device stopped. Its transfer waits until the change settles, without its process.
        let tracker = XcodeConnectionTracker()
        #expect(try await !tracker.synchronize(observations: [connection], runningDeviceIdentifiers: [], changingDeviceIdentifiers: [device]) {
            transfers.append($0)
        })
        #expect(transfers.isEmpty && tracker.hasPendingConnection(forDevice: device))
        #expect(try await tracker.synchronize(observations: [], runningDeviceIdentifiers: [device]) { transfers.append($0) })
        #expect(transfers == [connection])

        // A change that leaves the device stopped retires the connection, as any stop does.
        let stopped = XcodeConnectionTracker()
        #expect(try await !stopped.synchronize(observations: [connection], runningDeviceIdentifiers: [device], changingDeviceIdentifiers: [device]) {
            transfers.append($0)
        })
        #expect(try await !stopped.synchronize(observations: [], runningDeviceIdentifiers: []) { transfers.append($0) })
        #expect(transfers == [connection] && !stopped.hasPendingConnection(forDevice: device))
    }

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
