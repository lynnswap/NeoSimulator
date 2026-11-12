import Darwin
import Foundation
import NeoSimulatorDeviceIO
import NeoSimulatorKit

/// Receives a CoreDevice screen stream without avconferenced or its restricted entitlement.
@MainActor
final class CoreDeviceNetworkVideo {
    let connection: CoreDeviceScreenConnection
    private var receiver: RemoteScreenMediaReceiver?

    init(connection: CoreDeviceScreenConnection) { self.connection = connection }

    func start(renderer: RemoteScreenCaptureStream, completion: @escaping @Sendable ((any Error)?) -> Void) async throws
    {
        let reserved = try RemoteScreenSocketReservation(tunnelAddress: await connection.tunnelAddress())
        let options = try await connection.negotiatorOptions()
        let negotiator = try await CoreDeviceMediaNegotiator(options: options, runtime: connection.remote.runtime)
        let offer = try await negotiator.offer()
        let stream = try await connection.start(
            offer: offer, options: options, receiverIP: reserved.address, receiverPort: reserved.port)
        let localSSRC = try await negotiator.accept(stream.answer)
        guard let display = try await CoreDeviceDisplayGeometry.primaryDisplay(of: connection.remote) else {
            throw RemoteScreenError.unavailable(
                "remote-screen-display", "The device did not report its primary display size.")
        }
        reserved.release()
        let descriptor = try await connection.socket(for: stream)
        let receiver = RemoteScreenMediaReceiver(
            descriptor: descriptor, localSSRC: localSSRC,
            renderer: renderer, displaySize: display.pixelSize,
            completion: { [connection] error in
                Task { @MainActor in
                    if error == nil { connection.streamEnded() }
                    completion(error)
                }
            })
        self.receiver = receiver
        await receiver.start()
        try Task.checkCancellation()
    }

    func stop() async { await receiver?.stop(); receiver = nil }
}

/// The reserved port names this host's end of the CoreDevice tunnel until CoreDevice shares its connected socket.
private final class RemoteScreenSocketReservation {
    let address: String
    let port: UInt16
    private var descriptor: Int32?

    init(tunnelAddress: String) throws {
        let route = socket(AF_INET6, SOCK_DGRAM, 0)
        guard route >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(route) }
        var destination = sockaddr_in6()
        destination.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        destination.sin6_family = sa_family_t(AF_INET6)
        destination.sin6_port = UInt16(9).bigEndian
        guard inet_pton(AF_INET6, tunnelAddress, &destination.sin6_addr) == 1 else {
            throw RemoteScreenError.io("remote-screen-tunnel-address", "The device returned an invalid tunnel address.")
        }
        let connected = withUnsafePointer(to: &destination) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(route, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard connected == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var local = sockaddr_in6()
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        let found = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(route, $0, &length) }
        }
        guard found == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &local.sin6_addr, &text, socklen_t(text.count)) != nil else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        address = String(cString: text)
        let reserved = socket(AF_INET6, SOCK_DGRAM, 0)
        guard reserved >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            local.sin6_port = 0
            let bound = withUnsafePointer(to: &local) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(reserved, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
            guard bound == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let found = withUnsafeMutablePointer(to: &local) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(reserved, $0, &length) }
            }
            guard found == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            Darwin.close(reserved)
            throw error
        }
        descriptor = reserved
        port = UInt16(bigEndian: local.sin6_port)
    }

    func release() {
        if let descriptor { Darwin.close(descriptor); self.descriptor = nil }
    }

    deinit { if let descriptor { Darwin.close(descriptor) } }
}

/// Silence and keyframe recovery have independent deadlines; a quiet screen does not consume recovery time.
struct RemoteScreenMediaHealth {
    private var lastPacket: ContinuousClock.Instant
    private var recoveryStarted: ContinuousClock.Instant?
    private(set) var hasReceivedFrame = false

    init(at now: ContinuousClock.Instant = .now) {
        lastPacket = now
        recoveryStarted = now
    }

    mutating func receivedPacket(at now: ContinuousClock.Instant = .now) { lastPacket = now }
    mutating func receivedFrame() { hasReceivedFrame = true; recoveryStarted = nil }
    mutating func requireKeyframe(at now: ContinuousClock.Instant = .now) {
        if recoveryStarted == nil { recoveryStarted = now }
    }

    func isTimedOut(at now: ContinuousClock.Instant = .now) -> Bool {
        lastPacket.duration(to: now) > .seconds(15)
            || recoveryStarted.map { $0.duration(to: now) > .seconds(15) } == true
    }
}

/// Socket events, RTP assembly, and synchronous VideoToolbox decoding share this serial executor.
private actor RemoteScreenMediaReceiver {
    private nonisolated let queue = DispatchSerialQueue(
        label: "dev.lynnswap.NeoSimulator.RemoteScreenMedia", qos: .userInteractive)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
    private let descriptor: Int32
    private let localSSRC: UInt32
    private let renderer: RemoteScreenCaptureStream
    private let displaySize: CGSize
    private let completion: @Sendable ((any Error)?) -> Void
    private let packets: RemoteScreenRTPReceiver
    private let decoder = RemoteScreenHEVCDecoder()
    private var reader: (any DispatchSourceRead)?
    private var timer: (any DispatchSourceTimer)?
    private var shutdown: Task<Void, Never>?
    private var stopped = false
    private var failed = false
    private var health = RemoteScreenMediaHealth()
    private var lastReport = ContinuousClock.now
    private var decodeFailure: String?

    init(
        descriptor: Int32, localSSRC: UInt32, renderer: RemoteScreenCaptureStream, displaySize: CGSize,
        completion: @escaping @Sendable ((any Error)?) -> Void
    ) {
        self.descriptor = descriptor
        self.localSSRC = localSSRC
        self.renderer = renderer
        self.displaySize = displaySize
        self.completion = completion
        packets = RemoteScreenRTPReceiver()
    }

    func start() {
        var size: Int32 = 4 * 1_024 * 1_024
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        packets.onAccessUnit = { [weak self] unit in
            self?.assumeIsolated { $0.decoder.decode(unit.nals, timestamp: unit.timestamp) }
        }
        packets.onLoss = { [weak self] in
            self?.assumeIsolated {
                $0.decoder.invalidate(); $0.health.requireKeyframe()
            }
        }
        decoder.onFrame = { [weak self] buffer in
            nonisolated(unsafe) let frame = buffer
            self?.assumeIsolated {
                $0.health.receivedFrame()
                $0.decodeFailure = nil
                $0.renderer.receiveDecoded(frame, displaySize: $0.displaySize)
            }
        }
        decoder.onFailure = { [weak self] message in
            self?.assumeIsolated {
                $0.decodeFailure = message; $0.health.requireKeyframe()
            }
        }
        packets.onEnd = { [weak self] in self?.assumeIsolated { $0.finish(nil) } }
        let reader = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        reader.setEventHandler { [weak self] in self?.assumeIsolated { $0.readPackets() } }
        self.reader = reader
        reader.resume()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.assumeIsolated { $0.tick() } }
        self.timer = timer
        timer.resume()
    }

    private func readPackets() {
        guard !stopped, !failed else { return }
        var bytes = [UInt8](repeating: 0, count: 65_536)
        // Leave room for the report timer and stop when the socket has a large backlog.
        for _ in 0..<256 {
            guard !failed, !stopped else { return }
            let count = recv(descriptor, &bytes, bytes.count, MSG_DONTWAIT)
            if count < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                if errno == EINTR { continue }
                finish(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
                return
            }
            guard count > 0 else { return }
            health.receivedPacket()
            packets.receive(Data(bytes.prefix(count)))
        }
    }

    private func tick() {
        guard !stopped, !failed else { return }
        packets.flushPending()
        if health.isTimedOut() {
            finish(
                RemoteScreenError.io(
                    "remote-screen-stream-timeout",
                    decodeFailure
                        ?? (health.hasReceivedFrame
                            ? "The device stopped sending its screen." : "The device did not send a screen frame.")))
            return
        }
        guard lastReport.duration(to: .now) >= .seconds(1) else { return }
        lastReport = .now
        send(packets.report(receiver: localSSRC, requestKeyframe: decoder.needsKeyframe))
    }

    private func send(_ packet: Data) {
        let result = packet.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, $0.count, MSG_DONTWAIT) }
        if result < 0, errno != EAGAIN, errno != EWOULDBLOCK, errno != EINTR {
            finish(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
        }
    }

    private func finish(_ error: (any Error)?) {
        guard !failed, !stopped else { return }
        failed = true
        Task {
            await stop()
            completion(error)
        }
    }

    func stop() async {
        if let shutdown { await shutdown.value; return }
        stopped = true
        timer?.cancel()
        timer = nil
        // A final receiver report and BYE stop the sender's encoder before the native stop request.
        let bye = packets.report(receiver: localSSRC, bye: true)
        _ = bye.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, $0.count, MSG_DONTWAIT) }
        let reader = self.reader
        self.reader = nil
        let descriptor = self.descriptor
        let task = Task { [self] in
            if let reader {
                await withCheckedContinuation { (closed: CheckedContinuation<Void, Never>) in
                    reader.setCancelHandler {
                        Darwin.close(descriptor)
                        closed.resume()
                    }
                    reader.cancel()
                }
            } else {
                Darwin.close(descriptor)
            }
            decoder.invalidate()
        }
        shutdown = task
        await task.value
    }
}
