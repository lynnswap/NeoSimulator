import ArgumentParser
import Darwin
import Foundation
@testable import NeoSimulatorApp
import NeoSimulatorDeviceIO
@testable import NeoSimulatorManager
import Synchronization
import Testing

extension ManagerModelTests {
    /// A path for a socket of a test's own. The system's temporary directory keeps it short enough for a socket.
    private func socketPath() -> String { "/tmp/neosimulator-test-\(UUID().uuidString.prefix(8)).control" }

    @Test func theToolReachesOnlyTheLoginsThatAllowAutomatedUse() async throws {
        let store = LoginStore(keychain: InMemoryLoginKeychain())
        for (application, label, allowsAutomation) in [
            ("com.example.a", "Premium", true), ("com.example.a", "Personal", false), ("com.example.b", "Premium", true),
        ] {
            try await store.save(
                SavedLogin(
                    applicationIdentifier: application, label: label, userName: "person@example.com", origins: [],
                    allowsAutomation: allowsAutomation),
                password: "s3cret")
        }
        var signedIn: [String] = []
        func answer(_ request: ControlRequest, failing failure: (any Error)? = nil) async -> ControlResponse {
            await store.answer(request) { login, device in
                signedIn.append("\(login.applicationIdentifier) \(login.label) on \(device)")
                if let failure { throw failure }
            }
        }

        #expect(await answer(.logins(application: "com.example.a")) == .logins(["Premium"]))
        // A login that a person keeps to themself is as good as none, and a label that two apps have names no login.
        for request in [
            ControlRequest.signIn(device: "D", application: "com.example.a", label: "Personal"),
            .signIn(device: "D", application: nil, label: "Premium"),
        ] {
            guard case .signIn(let outcome) = await answer(request) else { continue }
            #expect(outcome.kind == .refused)
        }
        #expect(signedIn.isEmpty)

        let request = ControlRequest.signIn(device: "D", application: "com.example.b", label: "Premium")
        #expect(await answer(request) == .signIn(SignInOutcome(.signedIn)))
        #expect(signedIn == ["com.example.b Premium on D"])

        // What stopped a sign-in decides which outcome the tool reports.
        func kind(_ failure: any Error) async -> SignInOutcome.Kind? {
            guard case .signIn(let outcome) = await answer(request, failing: failure) else { return nil }
            return outcome.kind
        }
        #expect(await kind(SignInRefusal("The simulator’s screen is not open.")) == .refused)
        #expect(await kind(WebAuthenticationSignIn.Failure.otherApplication("com.example.c")) == .refused)
        #expect(await kind(WebAuthenticationSignIn.Failure.unrecognizedPage(origin: "https://other.example")) == .unrecognized)
        #expect(await kind(WebAuthenticationSignIn.Failure.rejected) == .failed)
        #expect(await kind(NativeFormSignIn.Failure.noButton(named: nil, buttons: [])) == .unrecognized)
        #expect(await kind(NativeFormSignIn.Failure.rejected) == .failed)
        // What a page's script threw, and the origin that a page moved to, are the page's words. They can repeat what
        // was filled into the page, and do not reach the tool.
        for failure: any Error in [
            WebInspectorFailure.scriptThrew("Error: s3cret"),
            WebAuthenticationSignIn.Failure.unrecognizedPage(origin: "https://s3cret.other.example"),
        ] {
            guard case .signIn(let outcome) = await answer(request, failing: failure) else { continue }
            #expect(outcome.reason?.contains("s3cret") == false)
        }
    }

    @Test func theAppAnswersTheToolOnItsSocketAndStopsWhatAToolThatWentAwayAskedFor() async throws {
        let path = socketPath()
        let (cancellations, cancelled) = AsyncStream.makeStream(of: Bool.self)
        let server = try ControlServer(path: path) { request in
            guard case .signIn = request else { return .logins(["Premium"]) }
            // A sign-in takes its time.
            try? await Task.sleep(for: .seconds(30))
            cancelled.yield(Task.isCancelled)
            return .signIn(SignInOutcome(.failed))
        }
        defer { server.stop() }
        let answer = try await performBlockingIO { try ControlSocket.send(.logins(application: "com.example.a"), to: path) }
        #expect(answer == .logins(["Premium"]))
        // A second app does not take the socket from the one that answers.
        #expect(throws: ControlSocket.Failure.inUse) { try ControlServer(path: path) { _ in .logins([]) } }

        // A tool that is interrupted closes its connection without reading the answer, and can do so before the app
        // has taken the connection. The answer that the app then writes to it must not end the app.
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        var line = try JSONEncoder().encode(ControlRequest.signIn(device: "D", application: nil, label: "Premium"))
        line.append(0x0A)
        let interrupted = 8
        for _ in 0..<interrupted {
            let tool = socket(AF_UNIX, SOCK_STREAM, 0)
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(tool, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            try #require(connected == 0)
            try #require(line.withUnsafeBytes { write(tool, $0.baseAddress, $0.count) } == line.count)
            close(tool)
        }
        var cancelledRequests = 0
        for await wasCancelled in cancellations {
            #expect(wasCancelled)
            cancelledRequests += 1
            if cancelledRequests == interrupted { break }
        }

        server.stop()
        await #expect(throws: ControlSocket.Failure.notRunning) {
            try await performBlockingIO { try ControlSocket.send(.logins(application: "com.example.a"), to: path) }
        }
    }

    @Test func theToolsExitStatusTellsHowASignInEnded() async throws {
        let path = socketPath()
        let outcome = Mutex(SignInOutcome(.signedIn))
        let asked = Mutex<[ControlRequest]>([])
        let server = try ControlServer(path: path) { request in
            asked.withLock { $0.append(request) }
            return .signIn(outcome.withLock { $0 })
        }
        /// What the tool exits with for its arguments, or nil when it ends without an error.
        func status(_ arguments: [String]) async -> Int32? {
            do {
                try await performBlockingIO {
                    var command = try NeoSimulatorCommand.parseAsRoot(arguments + ["--socket", path])
                    try command.run()
                }
                return nil
            } catch {
                return NeoSimulatorCommand.exitCode(for: error).rawValue
            }
        }

        let arguments = ["sign-in", "Premium", "--device", "D", "--app", "com.example.a"]
        #expect(await status(arguments) == nil)
        #expect(asked.withLock { $0 } == [.signIn(device: "D", application: "com.example.a", label: "Premium")])
        for (kind, expected) in [(SignInOutcome.Kind.failed, 1), (.refused, 2), (.unrecognized, 3)] as [(SignInOutcome.Kind, Int32)] {
            outcome.withLock { $0 = SignInOutcome(kind, reason: "why") }
            #expect(await status(arguments) == expected)
        }
        // The tool takes a label and a device, and no URL, origin or field.
        #expect(await status(["sign-in", "Premium", "--device", "D", "--origin", "https://login.example.com"]) == 64)
        server.stop()
        #expect(await status(arguments) == 69)
    }
}
