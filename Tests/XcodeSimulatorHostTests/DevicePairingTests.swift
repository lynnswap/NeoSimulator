import Foundation
import Testing
@testable import XcodeSimulatorHost

@Suite @MainActor
struct DevicePairingTests {
    @Test func pinRetriesPreserveLeadingZerosAndClearTheFinishedChallenge() async throws {
        let transport = PairingTransportFixture(attempts: 2)
        let session = DevicePairingSession(transport: transport)
        try await session.start()
        let (challenges, continuation) = AsyncStream<DevicePairingChallenge>.makeStream()
        session.onChange = {
            if let challenge = session.challenge { continuation.yield(challenge) }
        }
        let pairing = Task { try await session.pair(deviceIdentifier: "peer") }
        var iterator = challenges.makeAsyncIterator()
        let first = try #require(await iterator.next())
        #expect(first.deviceIdentifier == "peer" && !first.lastAttemptFailed)
        try session.answerPIN("001234")
        let retry = try #require(await iterator.next())
        #expect(retry.lastAttemptFailed)
        try session.answerPIN("005678")
        try await pairing.value
        #expect(transport.receivedPINs == ["001234", "005678"])
        #expect(!session.isPairing && session.challenge == nil)
        try await session.stop()
    }

    @Test func closingDuringAPINChallengeCancelsTheRequestAndIgnoresLateDiscovery() async throws {
        let transport = PairingTransportFixture()
        let session = DevicePairingSession(transport: transport)
        try await session.start()
        let (challenges, continuation) = AsyncStream<Void>.makeStream()
        session.onChange = { if session.challenge != nil { continuation.yield(()) } }
        let pairing = Task { try await session.pair(deviceIdentifier: "peer") }
        var iterator = challenges.makeAsyncIterator()
        _ = await iterator.next()
        try await session.stop()
        switch await pairing.result {
        case .success: Issue.record("A cancelled PIN request completed successfully.")
        case .failure(let error): #expect(error is CancellationError)
        }
        transport.publishDevices?([PairingTransportFixture.peer])
        #expect(session.devices.isEmpty && session.challenge == nil && !session.isPairing)
        #expect(transport.stopCount == 1 && transport.receivedPINs.isEmpty)
        await #expect(throws: CancellationError.self) { try await session.start() }
    }

    @Test func startupFailureRetainsTheCleanupFailureAndCanRetry() async throws {
        let transport = PairingTransportFixture()
        transport.startFailure = CLIError.io("discovery-fixture", "Discovery failed")
        transport.stopFailure = CLIError.io("cleanup-fixture", "Advertisement could not be stopped")
        let session = DevicePairingSession(transport: transport)
        do {
            try await session.start()
            Issue.record("The failing discovery unexpectedly started.")
        } catch {
            let failure = try #require(error as? DevicePairingCleanupFailure)
            #expect((failure.original as? CLIError)?.identifier == "discovery-fixture")
            #expect((failure.cleanup as? CLIError)?.identifier == "cleanup-fixture")
        }
        #expect(transport.stopCount == 1)
        transport.startFailure = nil
        transport.stopFailure = nil
        try await session.start()
        #expect(session.devices == [PairingTransportFixture.peer] && session.lastIssue == nil)
        try await session.stop()
    }
}

@MainActor
private final class PairingTransportFixture: DevicePairingTransport {
    static let peer = NearbyPairingDevice(identifier: "peer", name: "Nearby Phone", modelName: "iPhone", operatingSystem: "27.0")
    let attempts: Int
    var startFailure: (any Error)?
    var stopFailure: (any Error)?
    var publishDevices: (@MainActor ([NearbyPairingDevice]) -> Void)?
    private(set) var receivedPINs: [String] = []
    private(set) var stopCount = 0

    init(attempts: Int = 1) { self.attempts = attempts }

    func start(devices: @escaping @MainActor ([NearbyPairingDevice]) -> Void,
               advertisement: @escaping @MainActor (String, String?) -> Void,
               issue: @escaping @MainActor (String) -> Void) async throws {
        if let startFailure { throw startFailure }
        publishDevices = devices
        devices([Self.peer])
        advertisement("Test Mac", nil)
    }

    func pair(identifier: String,
              requestPIN: @escaping @MainActor (Bool, Double?) async throws -> String) async throws {
        for attempt in 0..<attempts {
            let pin = try await requestPIN(attempt > 0, nil)
            receivedPINs.append(pin)
        }
    }

    func stop() async throws {
        stopCount += 1
        if let stopFailure { throw stopFailure }
    }
}
