import Testing

@testable import XcodeSimulatorHost

@MainActor
@Suite
struct ApplicationTests {
    @Test func compactStatusDoesNotRequireXcodeDiscovery() async throws {
        let fixture = try ControllerFixture(initialState: .coreSimulator)
        fixture.runner.selectedDeveloperDirectory = nil
        let application = XcodeSimulatorHostApplication(controller: fixture.controller)

        let result = try await application.run(.status(.compact))

        #expect(result.0 == "Simulator route: CoreSimulator")
        #expect(result.1 == 0)
        #expect(
            !fixture.runner.calls.contains {
                $0.executable.path == "/usr/bin/xcode-select"
            }
        )
    }
}
