import Darwin
import Foundation
import Synchronization

/// A web page that a simulator's Web Inspector service lists.
package struct InspectablePage: Equatable, Sendable {
    /// The service's name for the process that shows the page, such as `PID:123`.
    package var application: String
    /// That process's bundle identifier, which is `com.apple.SafariViewService` for a web authentication sheet.
    package var bundleIdentifier: String?
    /// The page's number within its process.
    package var identifier: Int
    package var url: String
    package var title: String
    /// Whether another client inspects the page. The page answers only that client until it lets go.
    package var isInspected: Bool

    package init(
        application: String, bundleIdentifier: String?, identifier: Int, url: String, title: String,
        isInspected: Bool = false
    ) {
        self.application = application
        self.bundleIdentifier = bundleIdentifier
        self.identifier = identifier
        self.url = url
        self.title = title
        self.isInspected = isInspected
    }
}

package enum WebInspectorFailure: LocalizedError, Equatable {
    /// The service closed the connection.
    case disconnected
    /// The service no longer lists the page.
    case pageGone
    /// Another client, such as Safari's Web Inspector, inspects the page.
    case pageInUse
    /// The script threw, with the page's description of what it threw.
    case scriptThrew(String)
    /// The page answered with what this build does not read.
    case unreadableAnswer(String)

    package var errorDescription: String? {
        switch self {
        case .disconnected: "The simulator’s Web Inspector closed the connection."
        case .pageGone: "The web page is no longer open."
        case .pageInUse: "Another Web Inspector is inspecting the web page. Close it and try again."
        case .scriptThrew(let description): "The web page’s script failed: \(description)"
        case .unreadableAnswer(let detail): "The web page answered with what NeoSimulator can’t read: \(detail)"
        }
    }
}

/// A connection to a simulator's Web Inspector service, which lists the web pages that the device's apps show and runs
/// script in them.
///
/// The service is a Unix socket that any process of the user can connect to. A page takes one inspecting client at a
/// time, but that does not keep others out: script that a client sends for a page that another one inspects still runs
/// there, and only its answer goes to the inspecting client.
///
/// Keep one of these for as long as the pages are needed. The service can end with its last connection, and launchd
/// then holds back its next start until ten seconds after the last one, so a connection made right after another
/// closed can wait that long for its first answer.
package final class SimulatorWebInspector: @unchecked Sendable {
    package let socketPath: String
    /// Everything below is read and written on this queue, which also waits for the service's messages.
    private let queue = DispatchQueue(label: "dev.lynnswap.NeoSimulator.web-inspector")
    private var connection: WebInspectorConnection?
    /// The bundle identifier of each process that reported itself, by the service's name for it.
    private var applications: [String: String?] = [:]
    private var listings: [String: [InspectablePage]] = [:]
    /// Whether the service has listed its processes since the last request for them.
    private var hasApplications = false

    /// How long the service has for its first answer, and how long it then has for the answers to one request.
    private let startLimit: Duration
    private let answerLimit: Duration

    package init(
        socketPath: String, startLimit: Duration = DeviceOperationLimit.webInspectorStart,
        answerLimit: Duration = DeviceOperationLimit.webInspector
    ) {
        self.socketPath = socketPath
        self.startLimit = startLimit
        self.answerLimit = answerLimit
    }

    /// The pages that the device's apps show now: those of every process that the service knows.
    ///
    /// Each call asks the service, so the answer does not depend on what the service has reported unasked. Right after
    /// the service starts, processes have yet to report to it, and a caller that waits for a page asks again.
    package func pages() async throws -> [InspectablePage] {
        try await onQueue { inspector, _ in
            let connection = try inspector.connected()
            let deadline = ContinuousClock.now + inspector.answerLimit
            inspector.hasApplications = false
            try connection.send("_rpc_getConnectedApplications:", [:])
            while !inspector.hasApplications
                || inspector.applications.keys.contains(where: { inspector.listings[$0] == nil })
            {
                // Messages that keep arriving do not extend the request's time.
                guard ContinuousClock.now < deadline, try inspector.next(from: connection, before: deadline) != nil
                else { throw Self.noAnswer(inspector.answerLimit) }
            }
            return inspector.listings.values.flatMap(\.self).sorted {
                ($0.application, $0.identifier) < ($1.application, $1.identifier)
            }
        }
    }

    /// Evaluates `expression` in `page` and returns its value, which the page passes as JSON.
    package func evaluate<Value: Decodable & Sendable>(
        _ expression: String, in page: InspectablePage, as type: Value.Type = Value.self
    ) async throws -> Value {
        let value = try await onQueue { try $0.evaluate(expression, in: page, checkCancellation: $1) }
        return try JSONDecoder().decode(Value.self, from: value)
    }

    private func onQueue<Value: Sendable>(
        _ work: @escaping @Sendable (SimulatorWebInspector, _ checkCancellation: () throws -> Void) throws -> Value
    ) async throws -> Value {
        // A request whose caller gave up does not start, and does not go on to send its script.
        let isCancelled = Mutex(false)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        func checkCancellation() throws {
                            if isCancelled.withLock({ $0 }) { throw CancellationError() }
                        }
                        try checkCancellation()
                        continuation.resume(returning: try work(self, checkCancellation))
                    } catch {
                        // The next request starts over with a new connection.
                        if error as? WebInspectorFailure == .disconnected { self.forgetConnection() }
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            isCancelled.withLock { $0 = true }
        }
    }

    private func forgetConnection() {
        connection = nil
        applications = [:]
        listings = [:]
        hasApplications = false
    }

    private static func noAnswer(_ limit: Duration) -> DeviceOperationFailure {
        .noAnswer(operation: "ask the device's Web Inspector", limit: limit)
    }

    /// The connection, opened if it is not.
    private func connected() throws -> WebInspectorConnection {
        if let connection { return connection }
        let connection = try open(until: .now + startLimit)
        self.connection = connection
        return connection
    }

    /// Connects and waits for the service's first answer.
    private func open(until deadline: ContinuousClock.Instant) throws -> WebInspectorConnection {
        while true {
            guard ContinuousClock.now < deadline else { throw Self.noAnswer(startLimit) }
            let attempt = try WebInspectorConnection(socketPath: socketPath)
            do {
                try attempt.send("_rpc_reportIdentifier:", [:])
                guard let first = try attempt.receive(until: deadline) else { throw Self.noAnswer(startLimit) }
                try take(first, from: attempt)
                return attempt
            } catch WebInspectorFailure.disconnected {
                // A service that was ending with its last connection took this one. The next reaches its successor,
                // which knows nothing of what this one reported.
                forgetConnection()
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
    }

    /// The next message before `limit`, with what it says about processes and pages taken in.
    private func next(
        from connection: WebInspectorConnection, before limit: ContinuousClock.Instant
    ) throws -> WebInspectorConnection.Message? {
        guard let message = try connection.receive(until: limit) else { return nil }
        try take(message, from: connection)
        return message
    }

    private func take(_ message: WebInspectorConnection.Message, from connection: WebInspectorConnection) throws {
        let arguments = message.arguments
        switch message.selector {
        case "_rpc_reportConnectedApplicationList:":
            // The list is every process that the service knows, so what an earlier one named is gone.
            applications = [:]
            listings = [:]
            hasApplications = true
            for (_, application) in arguments["WIRApplicationDictionaryKey"] as? [String: [String: Any]] ?? [:] {
                try add(application, on: connection)
            }
        case "_rpc_applicationConnected:": try add(arguments, on: connection)
        case "_rpc_applicationDisconnected:":
            if let application = arguments["WIRApplicationIdentifierKey"] as? String {
                applications[application] = nil
                listings[application] = nil
            }
        case "_rpc_applicationSentListing:":
            guard let application = arguments["WIRApplicationIdentifierKey"] as? String else { break }
            let bundleIdentifier = applications[application] ?? nil
            listings[application] = (arguments["WIRListingKey"] as? [String: [String: Any]] ?? [:]).values.compactMap {
                guard let identifier = $0["WIRPageIdentifierKey"] as? Int else { return nil }
                let inspector = $0["WIRConnectionIdentifierKey"] as? String
                return InspectablePage(
                    application: application, bundleIdentifier: bundleIdentifier, identifier: identifier,
                    url: $0["WIRURLKey"] as? String ?? "", title: $0["WIRTitleKey"] as? String ?? "",
                    isInspected: inspector != nil && inspector != connection.identifier)
            }
        default: break
        }
    }

    /// Takes in a process that reports itself, and asks for its pages.
    private func add(_ application: [String: Any], on connection: WebInspectorConnection) throws {
        guard let name = application["WIRApplicationIdentifierKey"] as? String else { return }
        applications[name] = .some(application["WIRApplicationBundleIdentifierKey"] as? String)
        try connection.send("_rpc_forwardGetListing:", ["WIRApplicationIdentifierKey": name])
    }

    /// What the page's debugger sent to `sender`, from a message that carries it.
    private func debuggerMessage(_ message: WebInspectorConnection.Message, for sender: String) -> [String: Any]? {
        guard message.selector == "_rpc_applicationSentData:",
            message.arguments["WIRDestinationKey"] as? String ?? sender == sender,
            let data = message.arguments["WIRMessageDataKey"] as? Data
        else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Evaluates `expression` in `page` and returns its value as JSON.
    private func evaluate(
        _ expression: String, in page: InspectablePage, checkCancellation: () throws -> Void
    ) throws -> Data {
        let connection = try connected()
        let deadline = ContinuousClock.now + answerLimit
        // Messages that keep arriving do not extend the request's time.
        func awaited() throws -> WebInspectorConnection.Message {
            guard ContinuousClock.now < deadline, let message = try next(from: connection, before: deadline) else {
                throw Self.noAnswer(answerLimit)
            }
            return message
        }
        // The page's process says whether the page is still there and whether another client inspects it.
        listings[page.application] = nil
        try connection.send("_rpc_forwardGetListing:", ["WIRApplicationIdentifierKey": page.application])
        while listings[page.application] == nil {
            guard ContinuousClock.now < deadline, try next(from: connection, before: deadline) != nil else {
                throw WebInspectorFailure.pageGone
            }
        }
        guard let listed = listings[page.application]?.first(where: { $0.identifier == page.identifier }) else {
            throw WebInspectorFailure.pageGone
        }
        guard !listed.isInspected else { throw WebInspectorFailure.pageInUse }

        let sender = UUID().uuidString
        let route: [String: Any] = [
            "WIRApplicationIdentifierKey": page.application, "WIRPageIdentifierKey": page.identifier,
            "WIRSenderKey": sender,
        ]
        try connection.send("_rpc_forwardSocketSetup:", route.merging(["WIRAutomaticallyPause": false]) { $1 })
        // The page takes another client once this one lets go. A connection that fails here is forgotten with the page.
        defer { try? connection.send("_rpc_forwardDidClose:", route) }

        var target: String?
        while target == nil {
            guard let sent = debuggerMessage(try awaited(), for: sender),
                sent["method"] as? String == "Target.targetCreated",
                let information = (sent["params"] as? [String: Any])?["targetInfo"] as? [String: Any],
                information["type"] as? String == "page"
            else { continue }
            target = information["targetId"] as? String
        }

        // Answers to what other clients send for the page arrive here too, under their own numbers.
        let number = Int.random(in: 1_000_000...999_999_999)
        let request: [String: Any] = [
            "id": number, "method": "Runtime.evaluate",
            "params": ["expression": expression, "returnByValue": true],
        ]
        let forwarded: [String: Any] = [
            "id": number, "method": "Target.sendMessageToTarget",
            "params": [
                "targetId": target ?? "",
                "message": String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self),
            ],
        ]
        // Up to here the page is unchanged. A caller that gave up while the service started does not get its script run.
        try checkCancellation()
        try connection.send(
            "_rpc_forwardSocketData:",
            route.merging(["WIRSocketDataKey": try JSONSerialization.data(withJSONObject: forwarded)]) { $1 })

        while true {
            guard let sent = debuggerMessage(try awaited(), for: sender),
                sent["method"] as? String == "Target.dispatchMessageFromTarget",
                let text = (sent["params"] as? [String: Any])?["message"] as? String,
                let answer = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                answer["id"] as? Int == number
            else { continue }
            if let error = answer["error"] as? [String: Any] {
                throw WebInspectorFailure.unreadableAnswer(error["message"] as? String ?? "")
            }
            guard let outcome = answer["result"] as? [String: Any], let result = outcome["result"] as? [String: Any]
            else { throw WebInspectorFailure.unreadableAnswer(text) }
            if outcome["wasThrown"] as? Bool == true {
                throw WebInspectorFailure.scriptThrew(result["description"] as? String ?? "")
            }
            // A script that evaluates to undefined has no value.
            return try JSONSerialization.data(withJSONObject: result["value"] ?? NSNull(), options: .fragmentsAllowed)
        }
    }
}

/// The service's messages over its socket: a four-byte big-endian length, then a binary property list of a selector
/// and its argument.
final class WebInspectorConnection {
    struct Message {
        var selector: String
        var arguments: [String: Any]
    }

    private let descriptor: Int32
    /// What the service knows this connection by, which a page that it inspects reports.
    let identifier = UUID().uuidString
    private var received = Data()

    /// Takes a connected socket, which the connection closes.
    init(descriptor: Int32) {
        self.descriptor = descriptor
        var on: Int32 = 1
        // A write to a service that has gone away fails instead of ending the process.
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        // A service that stops reading is gone too: a write that it does not take in this time fails.
        var limit = timeval(tv_sec: Int(DeviceOperationLimit.webInspector.components.seconds), tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
    }

    convenience init(socketPath: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.count < capacity else {
            throw DeviceIOError.unavailable("simulator-web-inspector", "The Web Inspector socket's path is too long.")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let code = errno
            close(descriptor)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        self.init(descriptor: descriptor)
    }

    deinit { close(descriptor) }

    func send(_ selector: String, _ arguments: [String: Any]) throws {
        let message: [String: Any] = [
            "__selector": selector,
            "__argument": arguments.merging(["WIRConnectionIdentifierKey": identifier]) { current, _ in current },
        ]
        let body = try PropertyListSerialization.data(fromPropertyList: message, format: .binary, options: 0)
        var frame = withUnsafeBytes(of: UInt32(body.count).bigEndian) { Data($0) }
        frame.append(body)
        try frame.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                let count = write(descriptor, bytes.baseAddress! + sent, bytes.count - sent)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw WebInspectorFailure.disconnected }
                sent += count
            }
        }
    }

    /// The next message, or nil if none arrives before `deadline`.
    func receive(until deadline: ContinuousClock.Instant) throws -> Message? {
        while true {
            if received.count >= 4 {
                let length = Int(received.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
                if received.count >= 4 + length {
                    let body = received.dropFirst(4).prefix(length)
                    received = Data(received.dropFirst(4 + length))
                    let list = try PropertyListSerialization.propertyList(from: Data(body), format: nil)
                    guard let message = list as? [String: Any], let selector = message["__selector"] as? String else {
                        continue
                    }
                    return Message(selector: selector, arguments: message["__argument"] as? [String: Any] ?? [:])
                }
            }
            // A deadline that has passed still takes what has already arrived, however many reads that is: a message
            // can be larger than one read, and the socket of a service that sends whole messages runs empty.
            let remaining = deadline - .now
            let (seconds, attoseconds) = remaining.components
            let milliseconds = remaining > .zero ? max(1, seconds * 1000 + attoseconds / 1_000_000_000_000_000) : 0
            var waiting = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&waiting, 1, Int32(clamping: milliseconds))
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else {
                if remaining > .zero { continue }
                return nil
            }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let count = read(descriptor, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw WebInspectorFailure.disconnected }
            received.append(contentsOf: chunk[..<count])
        }
    }
}
