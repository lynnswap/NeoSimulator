// Adapted from simlock, Copyright (c) 2026 Szymon Chmal (MIT). See App/NeoSimulator/Settings/LicensesSettingsModel.swift.
//
// Turns the iPhone's RTP datagrams into whole HEVC access units, and builds the RTCP packets back to
// it. The payload format is RFC 7798 (single NAL, aggregation packet, fragmentation unit, without
// DONL). The receiver is written against what this one stream needs: one source, and a damaged
// picture dropped whole rather than decoded half-assembled.
import Foundation

/// Reorders within a short window and assembles access units. Loss discards the affected unit.
package final class RemoteScreenRTPReceiver {
    package var onAccessUnit: ((nals: [Data], timestamp: UInt32)) -> Void = { _ in }
    /// Called when the pictures already in flight can no longer be trusted, so the decoder can ask
    /// for a fresh key frame instead of painting a torn one.
    var onLoss: () -> Void = {}
    var onEnd: () -> Void = {}
    private var ended = false

    private(set) var source: UInt32?
    private(set) var lossEvents = 0
    private(set) var reorderedPackets = 0
    private(set) var latePackets = 0

    /// A packet that arrives out of order is held this long before the gap below it is accepted as
    /// real. Long enough for ordinary reordering, short enough that a lost packet is noticed inside
    /// one frame period.
    private let reorderWindow: TimeInterval = 0.025
    /// A damaged unit is never handed over, so the byte ceiling is a runaway guard, not a policy.
    private let maxUnitBytes = 8 * 1_024 * 1_024

    private var pending: [UInt16: (data: Data, arrival: TimeInterval)] = [:]
    private var nextExpected: UInt16?
    private var timestamp: UInt32?
    private var fragment = Data()
    private var nals: [Data] = []
    private var unitBytes = 0
    private var damaged = false

    // Receiver-report bookkeeping (RFC 3550 §6.4.1).
    private var receivedPackets: UInt32 = 0
    private var highestSequence: UInt32 = 0
    private var baseSequence: UInt32 = 0
    private var previousExpected: UInt32 = 0
    private var previousReceived: UInt32 = 0
    private var lastSenderReport: UInt32 = 0
    private var lastSenderReportAt: TimeInterval = 0
    private var transit: Double?
    private var jitter = 0.0

    private let clock: () -> TimeInterval

    init(source: UInt32? = nil, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.source = source
        self.clock = clock
    }

    private var now: TimeInterval { clock() }

    func receive(_ datagram: Data) {
        guard !ended else { return }
        let header = Array(datagram.prefix(12))
        guard header.count >= 4, header[0] >> 6 == 2 else { return }
        // RTCP keeps its own sequence space; a standalone BYE may have only eight bytes.
        if (192...223).contains(header[1]) {
            receiveInOrder(datagram)
            return
        }
        guard header.count >= 12, header[1] & 127 == Self.hevcPayloadType else { return }
        let sender = Self.uint32(header, 8)
        guard source == nil || source == sender else { return }
        if source == nil { source = sender }

        let sequence = Self.uint16(header, 2)
        if nextExpected == nil { nextExpected = sequence }
        guard let expected = nextExpected else { return }
        // Signed distance: a sequence number that wrapped is ahead, not behind.
        let distance = Int16(bitPattern: sequence &- expected)
        guard distance >= 0 else {
            latePackets += 1
            return
        }
        guard pending[sequence] == nil else { return }
        if distance > 0 { reorderedPackets += 1 }
        pending[sequence] = (datagram, now)
        flushPending()
    }

    /// Releases anything the reorder window has outlived, so a lost packet stops holding the stream
    /// hostage. Call it on every loop pass: time passing is itself an event here.
    func flushPending() {
        while let expected = nextExpected {
            if let packet = pending.removeValue(forKey: expected) {
                nextExpected = expected &+ 1
                receiveInOrder(packet.data)
                continue
            }
            guard !pending.isEmpty else { return }
            let oldest = pending.values.map(\.arrival).min()!
            guard pending.count >= 256 || now - oldest >= reorderWindow else { return }
            // The gap is real now; `receiveInOrder` will invalidate the unit it lands in.
            nextExpected = pending.keys.min { ($0 &- expected) < ($1 &- expected) }
        }
    }

    // MARK: - Assembling one access unit

    private func receiveInOrder(_ datagram: Data) {
        let bytes = Array(datagram)
        guard bytes.count >= 4, bytes[0] >> 6 == 2 else { return }

        if bytes[1] >= 192, bytes[1] <= 223 {
            noteSenderReports(bytes)
            return
        }
        guard bytes.count >= 12, bytes[1] & 127 == Self.hevcPayloadType else { return }
        let sender = Self.uint32(bytes, 8)
        guard source == nil || source == sender else { return }
        source = sender

        let sequence = Self.uint16(bytes, 2)
        let timestamp = Self.uint32(bytes, 4)
        var offset = 12 + Int(bytes[0] & 15) * 4
        guard offset <= bytes.count else { return }
        if bytes[0] & 16 != 0 {
            guard offset + 4 <= bytes.count else { return }
            offset += 4 + Int(Self.uint16(bytes, offset + 2)) * 4
        }
        var end = bytes.count
        if bytes[0] & 32 != 0 {
            let padding = Int(bytes.last!)
            guard padding > 0, padding <= end - offset else { return }
            end -= padding
        }
        guard offset + 2 <= end else { return }

        var sequenceGap = false
        if let previous = lastSequence {
            let distance = Int16(bitPattern: sequence &- previous)
            guard distance > 0 else { return }
            highestSequence &+= UInt32(distance)
            if distance != 1 { sequenceGap = true }
        } else {
            highestSequence = UInt32(sequence)
            baseSequence = highestSequence
        }
        lastSequence = sequence
        receivedPackets &+= 1
        noteJitter(timestamp)

        if self.timestamp != timestamp {
            // The previous unit ended without its marker bit, so whatever it was is unfinished.
            if self.timestamp != nil, !nals.isEmpty || !fragment.isEmpty {
                lossEvents += 1
                onLoss()
            }
            nals.removeAll(keepingCapacity: true)
            fragment.removeAll(keepingCapacity: true)
            unitBytes = 0
            damaged = false
            self.timestamp = timestamp
        }
        // why: applied after the timestamp reset — a gap may have taken this picture's first slices,
        // and marking the fresh unit damaged is the only way that reaches the decoder.
        if sequenceGap { markDamaged() }

        let payload = Array(bytes[offset..<end])
        let kind = (payload[0] >> 1) & 63
        if !damaged {
            switch kind {
            case 0..<48:
                if !fragment.isEmpty { markDamaged() } else { append(Data(payload)) }
            case 48:
                appendAggregated(payload)
            case 49:
                appendFragmented(payload)
            default:
                markDamaged()
            }
        }

        guard bytes[1] & 128 != 0 else { return }
        if !fragment.isEmpty { markDamaged() }
        // A decodable picture needs its first slice, including when joining mid-stream; a picture of
        // later slices would decode against a reference the viewer never got.
        let slices = nals.filter { ($0[$0.startIndex] >> 1) & 63 < 32 }
        if !slices.isEmpty, !slices.contains(where: { $0.count >= 3 && $0[$0.startIndex + 2] & 128 != 0 }) {
            markDamaged()
        }
        if !damaged, !nals.isEmpty {
            onAccessUnit((nals: nals, timestamp: timestamp))
        }
        nals.removeAll(keepingCapacity: true)
        unitBytes = 0
    }

    private var lastSequence: UInt16?

    /// Aggregation packet: length-prefixed NAL units back to back.
    private func appendAggregated(_ payload: [UInt8]) {
        var index = 2
        while index < payload.count, !damaged {
            guard index + 2 <= payload.count else { markDamaged(); return }
            let length = Int(Self.uint16(payload, index))
            index += 2
            guard length >= 2, index + length <= payload.count else { markDamaged(); return }
            append(Data(payload[index..<index + length]))
            index += length
        }
    }

    /// Fragmentation unit: one NAL split across packets, whose real header lives in the FU indicator
    /// and FU header rather than in the payload's first two bytes.
    private func appendFragmented(_ payload: [Data.Element]) {
        guard payload.count >= 4 else { markDamaged(); return }
        let header = payload[2]
        if header & 128 != 0 {
            guard fragment.isEmpty else { markDamaged(); return }
            fragment = Data([(payload[0] & 129) | ((header & 63) << 1), payload[1]])
        }
        guard !fragment.isEmpty else { markDamaged(); return }
        guard fragment.count + payload.count - 3 <= maxUnitBytes else { markDamaged(); return }
        fragment.append(contentsOf: payload.dropFirst(3))
        if header & 64 != 0 {
            let nal = fragment
            fragment.removeAll(keepingCapacity: true)
            append(nal)
        }
    }

    private func append(_ nal: Data) {
        guard unitBytes + nal.count <= maxUnitBytes else { markDamaged(); return }
        nals.append(nal)
        unitBytes += nal.count
    }

    private func markDamaged() {
        fragment.removeAll(keepingCapacity: true)
        nals.removeAll(keepingCapacity: true)
        unitBytes = 0
        damaged = true
        lossEvents += 1
        onLoss()
    }

    // MARK: - RTCP

    /// One RTCP compound packet: the receiver report, a name, and a key-frame request or a bye when
    /// either is called for.
    func report(
        receiver: UInt32,
        requestKeyframe: Bool = false,
        bye: Bool = false,
        name: String = "NeoSimulator"
    ) -> Data {
        var packet: [UInt8]
        if let source {
            let expected = lastSequence == nil ? 0 : highestSequence &- baseSequence &+ 1
            let interval = expected &- previousExpected
            let received = receivedPackets &- previousReceived
            let lost = max(Int64(expected) - Int64(receivedPackets), 0)
            let fraction =
                interval > 0
                ? min(255, max(0, (Int64(interval) - Int64(received)) * 256 / Int64(interval)))
                : 0
            let total = UInt32(min(lost, 0x7f_ffff))
            let delay =
                lastSenderReport == 0
                ? 0
                : UInt32(min((now - lastSenderReportAt) * 65_536, Double(UInt32.max)))
            packet = [0x81, 201, 0, 7]
            packet.append(contentsOf: Self.word(receiver))
            packet.append(contentsOf: Self.word(source))
            packet.append(UInt8(fraction))
            packet.append(UInt8(truncatingIfNeeded: total >> 16))
            packet.append(UInt8(truncatingIfNeeded: total >> 8))
            packet.append(UInt8(truncatingIfNeeded: total))
            packet.append(contentsOf: Self.word(highestSequence))
            packet.append(contentsOf: Self.word(UInt32(jitter)))
            packet.append(contentsOf: Self.word(lastSenderReport))
            packet.append(contentsOf: Self.word(delay))
            previousExpected = expected
            previousReceived = receivedPackets
        } else {
            packet = [0x80, 201, 0, 1] + Self.word(receiver)
        }

        var nameChunk = Self.word(receiver) + [1, UInt8(name.utf8.count)] + Array(name.utf8) + [0]
        while nameChunk.count % 4 != 0 { nameChunk.append(0) }
        packet += [0x81, 202, 0, UInt8(nameChunk.count / 4)] + nameChunk

        // Picture loss indication (RFC 4585): the iPhone's encoder is the only one who can recover a
        // picture this side dropped.
        if requestKeyframe, let source {
            packet += [0x81, 206, 0, 2] + Self.word(receiver) + Self.word(source)
        }
        if bye {
            packet += [0x81, 203, 0, 1] + Self.word(receiver)
        }
        return Data(packet)
    }

    /// Records the NTP-ish middle of each sender report so the report's own delay field can be
    /// filled in, and ignores everything else they carry.
    private func noteSenderReports(_ bytes: [UInt8]) {
        var offset = 0
        while offset + 4 <= bytes.count {
            let length = (Int(Self.uint16(bytes, offset + 2)) + 1) * 4
            guard length >= 4, offset + length <= bytes.count else { return }
            if bytes[offset + 1] == 200, length >= 28 {
                let sender = Self.uint32(bytes, offset + 4)
                if source == nil || source == sender {
                    lastSenderReport =
                        (Self.uint32(bytes, offset + 8) << 16) | (Self.uint32(bytes, offset + 12) >> 16)
                    lastSenderReportAt = now
                }
            }
            if bytes[offset + 1] == 203, let source {
                let count = Int(bytes[offset] & 31)
                guard length >= 4 + count * 4 else { return }
                if (0..<count).contains(where: { Self.uint32(bytes, offset + 4 + $0 * 4) == source }) {
                    ended = true
                    pending.removeAll()
                    onEnd()
                    return
                }
            }
            offset += length
        }
    }

    /// RFC 3550's inter-arrival jitter, in clock ticks, exponentially averaged. Differences rather
    /// than absolutes, so a long session's timestamp wrap cannot move it.
    private func noteJitter(_ timestamp: UInt32) {
        let current = now * 90_000 - Double(timestamp)
        if let previous = transit {
            let delta = abs(current - previous)
            if delta < 900_000 { jitter += (delta - jitter) / 16 }
        }
        transit = current
    }

    static let hevcPayloadType = 100

    static func uint16(_ bytes: [UInt8], _ at: Int) -> UInt16 {
        UInt16(bytes[at]) << 8 | UInt16(bytes[at + 1])
    }

    static func uint32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(uint16(bytes, at)) << 16 | UInt32(uint16(bytes, at + 2))
    }

    static func word(_ value: UInt32) -> [UInt8] {
        [
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value),
        ]
    }
}
