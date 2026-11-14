import CoreVideo
import Darwin
import Foundation
import NeoSimulatorDeviceIO
import NeoSimulatorKit
import Synchronization

/// Receives a CoreDevice screen stream without avconferenced or its restricted entitlement.
@MainActor
final class CoreDeviceNetworkVideo {
    let connection: CoreDeviceScreenConnection
    private var receiver: RemoteScreenMediaReceiver?
    /// The size of the display that the device shows, as the display's observer last reported it. `start`
    /// reads the size itself only while no report has arrived.
    private var displaySize: CGSize?
    private var builtIn: [RemoteScreenBuiltInDisplay] = []
    /// Receives each decoded frame on the receiver's queue, with the part of it that shows a display and, when
    /// the frame shows which, the built-in display that it carries. Set before `start`.
    var decodedFrames: (@Sendable (CVPixelBuffer, _ visible: CGSize, _ display: UInt32?) -> Void)?

    init(connection: CoreDeviceScreenConnection) { self.connection = connection }

    /// - Parameter carriedDisplay: Receives the built-in display whose pixels the video carries each time that
    ///   changes, and nil when its frames stop showing which one.
    func start(
        renderer: RemoteScreenCaptureStream, carriedDisplay: @escaping @MainActor (UInt32?) -> Void,
        completion: @escaping @Sendable ((any Error)?) -> Void
    ) async throws {
        let reserved = try RemoteScreenSocketReservation(tunnelAddress: await connection.tunnelAddress())
        let options = try await connection.negotiatorOptions()
        let negotiator = try await CoreDeviceMediaNegotiator(options: options, runtime: connection.remote.runtime)
        let offer = try await negotiator.offer()
        let stream = try await connection.start(
            offer: offer, options: options, receiverIP: reserved.address, receiverPort: reserved.port)
        let localSSRC = try await negotiator.accept(stream.answer)
        let initial: CGSize
        if let reported = displaySize {
            initial = reported
        } else {
            guard let display = try await CoreDeviceDisplayGeometry.primaryDisplay(of: connection.remote) else {
                throw RemoteScreenError.unavailable(
                    "remote-screen-display", "The device did not report its primary display size.")
            }
            initial = display.pixelSize
        }
        reserved.release()
        let descriptor = try await connection.socket(for: stream)
        // A report that arrived during the read or the socket's preparation is newer than the initial size.
        let receiver = RemoteScreenMediaReceiver(
            descriptor: descriptor, localSSRC: localSSRC,
            renderer: renderer, displaySize: displaySize ?? initial, builtIn: builtIn, decodedFrames: decodedFrames,
            // The latest display is read when the change is taken, so that two changes arrive in order.
            carriedDisplayChanged: { [weak self] in
                Task { @MainActor in
                    guard let receiver = self?.receiver else { return }
                    carriedDisplay(receiver.carriedDisplay)
                }
            },
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

    /// Follows the display that the device shows, whose size places it in each frame, and the built-in
    /// displays among which a frame's own size can show the one it carries.
    func update(displaySize: CGSize, builtIn: [RemoteScreenBuiltInDisplay]) {
        self.displaySize = displaySize
        self.builtIn = builtIn
        receiver?.update(displaySize: displaySize, builtIn: builtIn)
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
    private struct Displays {
        var shown: CGSize
        var builtIn: [RemoteScreenBuiltInDisplay]
        var carried: UInt32?
    }
    /// The next frame reads the latest displays, in whatever order the display's reports and frames arrive.
    private nonisolated let displays: Mutex<Displays>
    private let carriedDisplayChanged: @Sendable () -> Void
    private let decodedFrames: (@Sendable (CVPixelBuffer, CGSize, UInt32?) -> Void)?
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
        builtIn: [RemoteScreenBuiltInDisplay],
        decodedFrames: (@Sendable (CVPixelBuffer, CGSize, UInt32?) -> Void)?,
        carriedDisplayChanged: @escaping @Sendable () -> Void,
        completion: @escaping @Sendable ((any Error)?) -> Void
    ) {
        self.descriptor = descriptor
        self.localSSRC = localSSRC
        self.renderer = renderer
        displays = Mutex(Displays(shown: displaySize, builtIn: builtIn))
        self.carriedDisplayChanged = carriedDisplayChanged
        self.decodedFrames = decodedFrames
        self.completion = completion
        packets = RemoteScreenRTPReceiver()
    }

    /// The built-in display whose pixels the latest frame carried, when the frame showed which one.
    nonisolated var carriedDisplay: UInt32? { displays.withLock { $0.carried } }

    nonisolated func update(displaySize: CGSize, builtIn: [RemoteScreenBuiltInDisplay]) {
        displays.withLock { $0.shown = displaySize; $0.builtIn = builtIn }
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
                // A frame that shows which built-in display it carries is placed by that display's size, ahead
                // of the report that follows from it.
                let encoded = CGSize(width: CVPixelBufferGetWidth(frame), height: CVPixelBufferGetHeight(frame))
                let (size, carried, changed) = $0.displays.withLock { displays in
                    let carried = RemoteScreenCaptureStream.carriedDisplay(in: encoded, among: displays.builtIn)
                    let changed = carried?.identifier != displays.carried
                    displays.carried = carried?.identifier
                    return (carried?.pixelSize ?? displays.shown, carried?.identifier, changed)
                }
                if changed { $0.carriedDisplayChanged() }
                $0.decodedFrames?(frame, RemoteScreenCaptureStream.visibleSize(of: size, in: encoded), carried)
                $0.renderer.receiveDecoded(frame, displaySize: size)
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
