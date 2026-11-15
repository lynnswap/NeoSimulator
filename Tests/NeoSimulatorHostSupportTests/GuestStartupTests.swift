@testable import NeoSimulatorDeviceIO
import Testing

@Suite
struct GuestStartupTests {
    private let booting: UInt = 2
    private let booted: UInt = 3

    private func status(_ value: UInt32, terminal: Bool = false) -> GuestStartup.BootStatus {
        GuestStartup.BootStatus(
            value: value, isTerminal: terminal, description: "SimDeviceBootInfo { status = \(value) }")
    }

    @Test func aDeviceThatIsNeitherBootingNorBootedHasStopped() {
        #expect(GuestStartup(state: 1, status: nil) == .stopped)
        #expect(GuestStartup(state: 0, status: status(UInt32.max, terminal: true)) == .stopped)
    }

    @Test func aBootWithoutAStatusStartsOnceTheDeviceIsBooted() {
        #expect(GuestStartup(state: booting, status: nil) == .starting("booting"))
        #expect(GuestStartup(state: booted, status: nil) == .started)
    }

    @Test func aFinishedStatusHasStarted() {
        #expect(GuestStartup(state: booted, status: status(UInt32.max, terminal: true)) == .started)
    }

    @Test func aStatusThatIsNotTerminalNamesWhatTheBootWaitsFor() {
        #expect(GuestStartup(state: booting, status: status(0)) == .starting("booting"))
        #expect(GuestStartup(state: booted, status: status(1)) == .starting("waiting for backboardd"))
        #expect(GuestStartup(state: booted, status: status(2)) == .starting("migrating its data"))
        #expect(GuestStartup(state: booted, status: status(4)) == .starting("waiting for its system app"))
    }

    /// iPhone Air and iPhone Duo save their first migration as failed, and report it on every later boot.
    @Test func aFailedDataMigrationStartsOnceTheDeviceIsBooted() {
        #expect(GuestStartup(state: booting, status: status(3, terminal: true)) == .starting("booting"))
        #expect(GuestStartup(state: booted, status: status(3, terminal: true)) == .startedAfterFailedMigration)
    }

    @Test func anotherTerminalStatusEndsTheBootUnfinished() {
        #expect(
            GuestStartup(state: booted, status: status(5, terminal: true))
                == .failed("SimDeviceBootInfo { status = 5 }"))
    }
}
