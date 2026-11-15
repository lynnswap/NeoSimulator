import Darwin
import Foundation
@testable import NeoSimulatorDeviceIO
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(1)))
struct SimulatorWebInspectorTests {
    /// Stands for a simulator's Web Inspector service on a socket of its own, answering one connection at a time.
    private final class Service: Sendable {
        typealias Reply = (_ selector: String, _ arguments: [String: Any]) throws -> Void

        let socketPath: String
        private let listener: Int32
        /// The selectors that a connection sent, in order, which end when its client closes it.
        private let arrivals: AsyncStream<String?>

        /// `answer` gets each message of a connection and sends what the service answers.
        ///
        /// With `closingFirstConnectionOn`, the service closes its first connection when that selector arrives on it,
        /// instead of answering, as a service does that is ending.
        init(
            closingFirstConnectionOn closing: String? = nil,
            answer: @escaping @Sendable (WebInspectorConnection.Message, Reply) throws -> Void
        ) throws {
            let directory = FileManager.default.temporaryDirectory.appending(path: "wi-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let socketPath = directory.appending(path: "s").path
            let listener = socket(AF_UNIX, SOCK_STREAM, 0)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(socketPath.utf8)) }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            try #require(bound == 0 && listen(listener, 4) == 0)
            let (arrivals, arrived) = AsyncStream.makeStream(of: String?.self)
            self.socketPath = socketPath
            self.listener = listener
            self.arrivals = arrivals
            Thread.detachNewThread {
                var closing = closing
                while true {
                    let accepted = accept(listener, nil, nil)
                    guard accepted >= 0 else { return }
                    let connection = WebInspectorConnection(descriptor: accepted)
                    // The connection ends when its client closes it.
                    while let message = try? connection.receive(until: .now + .seconds(30)) {
                        arrived.yield(message.selector)
                        if message.selector == closing {
                            closing = nil
                            break
                        }
                        try? answer(message) { try connection.send($0, $1) }
                    }
                    arrived.yield(nil)
                }
            }
        }

        /// What the next connection sent, once its client has closed it.
        func received() async -> [String] {
            var selectors: [String] = []
            for await selector in arrivals {
                guard let selector else { break }
                selectors.append(selector)
            }
            return selectors
        }

        deinit {
            close(listener)
            try? FileManager.default.removeItem(atPath: (socketPath as NSString).deletingLastPathComponent)
        }
    }

    /// The processes that a service knows, by its name for each, with their bundle identifiers.
    private final class Processes: Sendable {
        let known: Mutex<[String: String]>

        init(_ known: [String: String]) { self.known = Mutex(known) }
    }

    private static func debuggerData(_ message: [String: Any]) throws -> [String: Any] {
        ["WIRMessageDataKey": try JSONSerialization.data(withJSONObject: message)]
    }

    private static func applicationList(_ processes: [String: String]) -> [String: Any] {
        let applications = processes.reduce(into: [String: Any]()) { list, process in
            list[process.key] = [
                "WIRApplicationIdentifierKey": process.key, "WIRApplicationBundleIdentifierKey": process.value,
            ]
        }
        return ["WIRApplicationDictionaryKey": applications]
    }

    private let page = InspectablePage(
        application: "PID:2", bundleIdentifier: "com.apple.SafariViewService", identifier: 1,
        url: "https://login.example.com/", title: "")

    /// A service that knows `processes`, of which `PID:2` shows one page and the others none. A process outside
    /// `listing` does not answer for its pages.
    private func service(
        closingFirstConnectionOn closing: String? = nil, processes: Processes,
        listing: Set<String> = ["PID:1", "PID:2"], inspected: Bool = false, evaluatingTo result: [String: Any] = [:]
    ) throws -> Service {
        // Property lists and JSON objects are not Sendable; the closure only reads this one.
        nonisolated(unsafe) let result = result
        return try Service(closingFirstConnectionOn: closing) { message, reply in
            switch message.selector {
            case "_rpc_reportIdentifier:": try reply("_rpc_reportCurrentState:", [:])
            case "_rpc_getConnectedApplications:":
                try reply("_rpc_reportConnectedApplicationList:", Self.applicationList(processes.known.withLock { $0 }))
            case "_rpc_forwardGetListing:":
                let application = try #require(message.arguments["WIRApplicationIdentifierKey"] as? String)
                guard listing.contains(application) else { break }
                var shown: [String: Any] = ["WIRPageIdentifierKey": 1, "WIRURLKey": "https://login.example.com/"]
                if inspected { shown["WIRConnectionIdentifierKey"] = "another-client" }
                try reply(
                    "_rpc_applicationSentListing:",
                    [
                        "WIRApplicationIdentifierKey": application,
                        "WIRListingKey": application == "PID:2" ? ["1": shown] : [:],
                    ])
            case "_rpc_forwardSocketSetup:":
                let created: [String: Any] = [
                    "method": "Target.targetCreated",
                    "params": ["targetInfo": ["targetId": "page-7", "type": "page"]],
                ]
                try reply("_rpc_applicationSentData:", try Self.debuggerData(created))
            case "_rpc_forwardSocketData:":
                let data = try #require(message.arguments["WIRSocketDataKey"] as? Data)
                let forwarded = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
                let parameters = try #require(forwarded["params"] as? [String: Any])
                #expect(parameters["targetId"] as? String == "page-7")
                let text = try #require(parameters["message"] as? String)
                let request = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
                #expect((request["params"] as? [String: Any])?["expression"] as? String == "location.origin")
                func answer(_ message: [String: Any]) throws -> [String: Any] {
                    let text = String(decoding: try JSONSerialization.data(withJSONObject: message), as: UTF8.self)
                    return try Self.debuggerData([
                        "method": "Target.dispatchMessageFromTarget",
                        "params": ["targetId": "page-7", "message": text],
                    ])
                }
                // The answer to what another client sent for the page comes first, under that client's number.
                let other: [String: Any] = ["result": ["type": "string", "value": "another client's"]]
                try reply("_rpc_applicationSentData:", try answer(["id": 1, "result": ["result": other]]))
                try reply("_rpc_applicationSentData:", try answer(["id": request["id"] ?? 0, "result": result]))
            default: break
            }
        }
    }

    private let viewService = ["PID:2": "com.apple.SafariViewService"]

    @Test func pagesAreAskedForEachTimeAndComeFromEveryProcessTheServiceKnows() async throws {
        let processes = Processes(["PID:1": "com.apple.mobilesafari"])
        let service = try service(processes: processes, listing: ["PID:1", "PID:2"])
        let inspector = SimulatorWebInspector(
            socketPath: service.socketPath, startLimit: .seconds(5), answerLimit: .milliseconds(300))
        #expect(try await inspector.pages().isEmpty)
        // The process that shows a web authentication sheet starts with the sheet.
        processes.known.withLock { $0["PID:2"] = "com.apple.SafariViewService" }
        #expect(try await inspector.pages() == [page])

        // A process that the service knows and that does not list its pages leaves the pages unknown.
        processes.known.withLock { $0["PID:3"] = "com.example.app" }
        await #expect(throws: DeviceOperationFailure.self) { try await inspector.pages() }
    }

    @Test func aPageEvaluatesExpressionsOverOneConnectionAndIsLetGoAfterEach() async throws {
        let service = try service(
            processes: Processes(viewService),
            evaluatingTo: ["result": ["type": "string", "value": "https://login.example.com"], "wasThrown": false])
        do {
            let inspector = SimulatorWebInspector(socketPath: service.socketPath)
            for _ in 1...2 {
                let origin = try await inspector.evaluate("location.origin", in: page, as: String.self)
                #expect(origin == "https://login.example.com")
            }
        }
        // The connection closes with the inspector.
        let received = await service.received()
        #expect(received.count { $0 == "_rpc_reportIdentifier:" } == 1)
        #expect(received.count { $0 == "_rpc_forwardSocketSetup:" } == 2 && received.last == "_rpc_forwardDidClose:")
    }

    @Test func aScriptThatThrowsFailsWithWhatItThrew() async throws {
        let service = try service(
            processes: Processes(viewService),
            evaluatingTo: [
                "result": ["type": "object", "subtype": "error", "description": "Error: boom"], "wasThrown": true,
            ])
        let inspector = SimulatorWebInspector(socketPath: service.socketPath)
        await #expect(throws: WebInspectorFailure.scriptThrew("Error: boom")) {
            try await inspector.evaluate("location.origin", in: page, as: String.self)
        }
    }

    @Test func aPageThatAnotherClientInspectsIsRefused() async throws {
        let service = try service(processes: Processes(viewService), inspected: true)
        do {
            let inspector = SimulatorWebInspector(socketPath: service.socketPath)
            await #expect(throws: WebInspectorFailure.pageInUse) {
                try await inspector.evaluate("location.origin", in: page, as: String.self)
            }
        }
        #expect(await service.received().contains("_rpc_forwardSocketSetup:") == false)
    }

    @Test func aRequestIsMadeAgainWhenAnEndingServiceClosesTheConnectionOpenedForIt() async throws {
        // The service answered the connection's first message before it closed it.
        let service = try service(
            closingFirstConnectionOn: "_rpc_getConnectedApplications:", processes: Processes(viewService))
        let inspector = SimulatorWebInspector(
            socketPath: service.socketPath, startLimit: .seconds(5), answerLimit: .milliseconds(300))
        #expect(try await inspector.pages() == [page])
    }

    @Test func aScriptIsNotSentAgainWhenItsConnectionCloses() async throws {
        let service = try service(
            closingFirstConnectionOn: "_rpc_forwardSocketData:", processes: Processes(viewService),
            evaluatingTo: ["result": ["type": "string", "value": "https://login.example.com"], "wasThrown": false])
        let inspector = SimulatorWebInspector(socketPath: service.socketPath)
        await #expect(throws: WebInspectorFailure.disconnected) {
            try await inspector.evaluate("location.origin", in: page, as: String.self)
        }
    }
}
