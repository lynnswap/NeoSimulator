// Adapted from simlock, Copyright (c) 2026 Szymon Chmal (MIT). See App/NeoSimulator/Settings/LicensesSettingsModel.swift.
//
// HEVCDecoder — turns the receiver's access units into pixel buffers with VideoToolbox. Everything
// here is public Apple API: by the time a packet reaches this file the private part of the path is
// over, and what arrives is an ordinary elementary stream.
import CoreMedia
import CoreVideo
import Foundation
import NeoSimulatorKit
import NeoSimulatorDeviceIO
import VideoToolbox

/// Confined to the receive queue; callback results are consumed after synchronous decoding returns.
final class RemoteScreenHEVCDecoder {
    var onFrame: (CVPixelBuffer) -> Void = { _ in }
    var onFailure: (String) -> Void = { _ in }

    /// No decoder can start mid-picture: until the first random-access point arrives, everything the
    /// receiver hands over is a delta against a reference nobody holds.
    private(set) var needsKeyframe = true
    private var parameterSets: [UInt8: Data] = [:]
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    /// Whether the current GOP was entered at an open-GOP recovery point, whose leading pictures
    /// reference the past that was discarded.
    private var discardingLeadingPictures = false

    deinit {
        if let session { VTDecompressionSessionInvalidate(session) }
    }

    /// Drops the decoder's whole reference picture set and asks for a fresh key frame. Used on
    /// transport loss, on a parameter-set change, and on any decode failure: after any of them the
    /// session's references are no longer something this side can vouch for.
    func invalidate() {
        needsKeyframe = true
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
    }

    func decode(_ nals: [Data], timestamp: UInt32) {
        var picture: [Data] = []
        var randomAccess = false
        var parameterSetsChanged = false
        var sliceTypes: [UInt8] = []

        for nal in nals {
            guard nal.count >= 2 else { continue }
            let type = (nal[nal.startIndex] >> 1) & 63
            if (32...34).contains(type) {
                // VPS, SPS, PPS. A changed set means the stream's shape moved under the session.
                if parameterSets[type] != nal {
                    parameterSets[type] = nal
                    parameterSetsChanged = true
                }
            } else {
                picture.append(nal)
                if type < 32 { sliceTypes.append(type) }
                // 16...21 are the IRAP types: the only pictures safe to start from.
                if (16...21).contains(type) { randomAccess = true }
            }
        }

        if parameterSetsChanged {
            invalidate()
            format = nil
        }
        guard !sliceTypes.isEmpty else { return }
        guard !needsKeyframe || randomAccess else { return }
        // RASL pictures (types 8 and 9) following an open-GOP recovery point may reference the
        // discarded past, so they pass by until the first non-RASL slice says the GOP is
        // self-contained.
        if discardingLeadingPictures, sliceTypes.contains(where: { $0 == 8 || $0 == 9 }) { return }
        if needsKeyframe, randomAccess {
            discardingLeadingPictures = true
        } else if sliceTypes.contains(where: { $0 < 6 }) {
            discardingLeadingPictures = false
        }

        do {
            if session == nil { try configure() }
            guard let session, let format else { return }
            let sample = try compressedSample(
                picture: picture,
                timestamp: timestamp,
                format: format,
                randomAccess: randomAccess
            )
            try decodeSample(sample, with: session)
        } catch {
            invalidate()
            onFailure("\(error)")
        }
    }

    // MARK: - Building a compressed sample

    /// The access unit in the length-prefixed form the format description was built for
    /// (`nalUnitHeaderLength: 4`).
    private func compressedSample(
        picture: [Data],
        timestamp: UInt32,
        format: CMVideoFormatDescription,
        randomAccess: Bool
    ) throws -> CMSampleBuffer {
        var bytes = Data()
        for nal in picture {
            bytes.append(contentsOf: RemoteScreenRTPReceiver.word(UInt32(nal.count)))
            bytes.append(nal)
        }

        var block: CMBlockBuffer?
        try checked(
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: bytes.count,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: bytes.count,
                flags: 0,
                blockBufferOut: &block
            ),
            "block allocation"
        )
        guard let block else { throw RemoteScreenError.io("remote-screen-decoder", "no block buffer") }
        try bytes.withUnsafeBytes { raw in
            try checked(
                CMBlockBufferReplaceDataBytes(
                    with: raw.baseAddress!,
                    blockBuffer: block,
                    offsetIntoDestination: 0,
                    dataLength: bytes.count
                ),
                "block copy"
            )
        }

        // The RTP timestamp is 90 kHz for this stream; VideoToolbox only needs it to increase.
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: Int64(timestamp), timescale: 90_000),
            decodeTimeStamp: .invalid
        )
        var sizes = [bytes.count]
        var sample: CMSampleBuffer?
        try checked(
            CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault,
                dataBuffer: block,
                formatDescription: format,
                sampleCount: 1,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 1,
                sampleSizeArray: &sizes,
                sampleBufferOut: &sample
            ),
            "compressed sample"
        )
        guard let sample else { throw RemoteScreenError.io("remote-screen-decoder", "no sample buffer") }

        // CoreMedia assumes sync samples unless told otherwise. A P or B picture depends on decoded
        // references, and describing it as a random-access point is what makes a viewer show a
        // picture it should have waited for.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let dictionary = unsafeBitCast(
                CFArrayGetValueAtIndex(attachments, 0),
                to: CFMutableDictionary.self
            )
            let dependsOnOthers = randomAccess ? kCFBooleanFalse! : kCFBooleanTrue!
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                Unmanaged.passUnretained(dependsOnOthers).toOpaque()
            )
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DependsOnOthers).toOpaque(),
                Unmanaged.passUnretained(dependsOnOthers).toOpaque()
            )
        }
        return sample
    }

    /// With both asynchronous and temporal flags clear, VideoToolbox calls the output handler before returning.
    private func decodeSample(
        _ sample: CMSampleBuffer,
        with session: VTDecompressionSession
    ) throws {
        nonisolated(unsafe) var outputStatus: OSStatus = noErr
        nonisolated(unsafe) var decoded: CVPixelBuffer?
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sample,
            flags: [],
            infoFlagsOut: nil
        ) { status, _, image, _, _ in
            outputStatus = status
            decoded = image
        }
        try checked(status, "decode submission")
        try checked(outputStatus, "HEVC decode")
        if let decoded {
            needsKeyframe = false
            onFrame(decoded)
        }
    }

    // MARK: - The session

    private func configure() throws {
        guard let vps = parameterSets[32], let sps = parameterSets[33], let pps = parameterSets[34] else {
            throw RemoteScreenError.io("remote-screen-decoder", "no parameter sets yet")
        }
        let status = vps.withUnsafeBytes { v in
            sps.withUnsafeBytes { s in
                pps.withUnsafeBytes { p in
                    let pointers = [
                        v.bindMemory(to: UInt8.self).baseAddress!,
                        s.bindMemory(to: UInt8.self).baseAddress!,
                        p.bindMemory(to: UInt8.self).baseAddress!,
                    ]
                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: 3,
                        parameterSetPointers: pointers,
                        parameterSetSizes: [vps.count, sps.count, pps.count],
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &format
                    )
                }
            }
        }
        try checked(status, "HEVC format")
        guard let format else { throw RemoteScreenError.io("remote-screen-decoder", "no format description") }

        // Hardware is allowed, not required: this Mac may already be encoding several other streams,
        // and VideoToolbox's own choice is the one that knows what the machine has left.
        let specification: [CFString: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true
        ]
        try checked(
            VTDecompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                formatDescription: format,
                decoderSpecification: specification as CFDictionary,
                imageBufferAttributes: [
                    kCVPixelBufferIOSurfacePropertiesKey: [:],
                    kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferMetalCompatibilityKey: true,
                ] as CFDictionary,
                outputCallback: nil,
                decompressionSessionOut: &session
            ),
            "decoder creation"
        )
        guard let session else { throw RemoteScreenError.io("remote-screen-decoder", "no decompression session") }
        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)

    }

    private func checked(_ status: OSStatus, _ operation: String) throws {
        guard status != 0 else { return }
        throw RemoteScreenError.io("remote-screen-decoder", "\(operation): OSStatus \(status)")
    }
}
