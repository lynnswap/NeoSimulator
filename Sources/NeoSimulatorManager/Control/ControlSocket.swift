import Darwin
import Foundation
import NeoSimulatorDeviceIO
import Synchronization

/// The Unix socket that the running app answers the command-line tool on.
package enum ControlSocket {
    /// In the user's own temporary directory, which no other user can enter. The directory is the same whatever a
    /// caller's `TMPDIR` says.
    package static var defaultPath: String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        let directory =
            length > 0
            ? String(decoding: buffer.prefix(length - 1).map(UInt8.init(bitPattern:)), as: UTF8.self)
            : NSTemporaryDirectory()
        return (directory as NSString).appendingPathComponent("dev.lynnswap.NeoSimulator.control")
    }

    package enum Failure: Error, LocalizedError, Equatable {
        /// No app listens on the socket.
        case notRunning
        /// Another app already listens on the socket.
        case inUse
        case tooLong
        case disconnected
        case system(Int32)

        package var errorDescription: String? {
            switch self {
            case .notRunning: "NeoSimulator is not running."
            case .inUse: "Another NeoSimulator already answers the command-line tool."
            case .tooLong: "The control socket’s path is too long."
            case .disconnected: "NeoSimulator closed the connection before it answered."
            case .system(let code): String(cString: strerror(code))
            }
        }
    }

    /// Sends `request` to the app that listens at `path` and waits for its answer, for as long as the app takes.
    package static func send(_ request: ControlRequest, to path: String = defaultPath) throws -> ControlResponse {
        let descriptor = try connected(to: path)
        defer { close(descriptor) }
        try write(try JSONEncoder().encode(request), to: descriptor)
        guard let line = try readLine(from: descriptor) else { throw Failure.disconnected }
        return try JSONDecoder().decode(ControlResponse.self, from: line)
    }

    fileprivate static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw Failure.tooLong }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }

    fileprivate static func connected(to path: String) throws -> Int32 {
        var address = try address(path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure.system(errno) }
        // Before the socket connects: the option is refused on a socket whose other end has closed.
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(descriptor)
            // No socket there, or one that a process left behind.
            throw Failure.notRunning
        }
        return descriptor
    }

    /// Writes `message` as one line.
    fileprivate static func write(_ message: Data, to descriptor: Int32) throws {
        var line = message
        line.append(0x0A)
        try line.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress! + sent, bytes.count - sent)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Failure.disconnected }
                sent += count
            }
        }
    }

    /// The next line, or nil if the other side closed before it sent one.
    fileprivate static func readLine(from descriptor: Int32) throws -> Data? {
        var line = Data()
        var byte: UInt8 = 0
        // A request and an answer are a few hundred bytes.
        while line.count < 1 << 20 {
            let count = read(descriptor, &byte, 1)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return nil }
            if byte == 0x0A { return line }
            line.append(byte)
        }
        throw Failure.disconnected
    }
}

/// Answers the command-line tool's requests on a Unix socket, one request for each connection.
package final class ControlServer: Sendable {
    private let path: String
    private let listener: Int32
    private let isStopped = Mutex(false)

    /// Listens at `path`. Throws ``ControlSocket/Failure/inUse`` when another process already answers there.
    ///
    /// `answer` runs for each request. Its task is cancelled when the tool that asked goes away before the answer.
    package init(
        path: String = ControlSocket.defaultPath, answer: @escaping @Sendable (ControlRequest) async -> ControlResponse
    ) throws {
        if let live = try? ControlSocket.connected(to: path) {
            close(live)
            throw ControlSocket.Failure.inUse
        }
        // What is at the path is a socket that a process left behind.
        unlink(path)
        var address = try ControlSocket.address(path)
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw ControlSocket.Failure.system(errno) }
        // A write to a tool that has gone away fails instead of ending the app. The connections that the listener
        // accepts take the option from it. Set on a connection itself, it is refused once the tool has closed its
        // end, which a tool that is interrupted can do before the connection is accepted.
        var on: Int32 = 1
        guard setsockopt(listener, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            let code = errno
            close(listener)
            throw ControlSocket.Failure.system(code)
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        // Only the user's own processes connect.
        guard bound == 0, chmod(path, 0o600) == 0, listen(listener, 8) == 0 else {
            let code = errno
            close(listener)
            throw ControlSocket.Failure.system(code)
        }
        self.path = path
        self.listener = listener
        Thread.detachNewThread {
            while true {
                let connection = accept(listener, nil, nil)
                if connection < 0 {
                    if errno == EINTR { continue }
                    // The server stopped.
                    return
                }
                Task { await Self.serve(connection, answer: answer) }
            }
        }
    }

    private static func serve(
        _ connection: Int32, answer: @escaping @Sendable (ControlRequest) async -> ControlResponse
    ) async {
        defer { close(connection) }
        guard let line = try? await performBlockingIO({ try ControlSocket.readLine(from: connection) }) else { return }
        let response: ControlResponse
        if let request = try? JSONDecoder().decode(ControlRequest.self, from: line) {
            let answering = Task { await answer(request) }
            // The tool sends nothing after its request, so the connection is readable again only when the tool is gone.
            Thread.detachNewThread {
                var waiting = pollfd(fd: connection, events: Int16(POLLIN), revents: 0)
                while poll(&waiting, 1, -1) < 0, errno == EINTR {}
                answering.cancel()
            }
            response = await answering.value
        } else {
            response = .failure(
                "NeoSimulator could not read the request. The tool and the app may be of different versions.")
        }
        guard let message = try? JSONEncoder().encode(response) else { return }
        _ = try? await performBlockingIO { try ControlSocket.write(message, to: connection) }
        // The tool reads the answer and closes, which also ends the thread that watches the connection.
        shutdown(connection, SHUT_WR)
        _ = try? await performBlockingIO { try ControlSocket.readLine(from: connection) }
    }

    /// Stops listening and removes the socket. A second call does nothing: the descriptor's number may by then name
    /// something else.
    package func stop() {
        let wasStopped = isStopped.withLock { stopped in
            defer { stopped = true }
            return stopped
        }
        guard !wasStopped else { return }
        close(listener)
        unlink(path)
    }
}
