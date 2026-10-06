import AVFoundation
import VideoToolbox

struct EncodedFrame {
    let nalUnits: [Data]
    let presentationTime: Double
    let isKeyframe: Bool
    let sps: Data
    let pps: Data
}

final class H264Encoder {
    private var session: VTCompressionSession?
    private let onFrame: (EncodedFrame) -> Void
    private let onError: (String) -> Void

    init(width: Int32, height: Int32, frameRate: Int, onFrame: @escaping (EncodedFrame) -> Void,
         onError: @escaping (String) -> Void) throws {
        self.onFrame = onFrame
        self.onError = onError
        var specification: CFDictionary?
        if #available(iOS 17.4, *) {
            specification = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary
        }
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault, width: width, height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: specification,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: { context, _, status, _, sample in
                guard let context else { return }
                let encoder = Unmanaged<H264Encoder>.fromOpaque(context).takeUnretainedValue()
                guard status == noErr, let sample, CMSampleBufferDataIsReady(sample) else {
                    if status != noErr { encoder.onError("Video encoding failed (\(status)).") }
                    return
                }
                encoder.receive(sample)
            }, refcon: Unmanaged.passUnretained(self).toOpaque(), compressionSessionOut: &session
        )
        guard status == noErr, let session else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        do {
            let properties: [CFString: Any] = [
                kVTCompressionPropertyKey_RealTime: true,
                kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_Baseline_AutoLevel,
                kVTCompressionPropertyKey_AllowFrameReordering: false,
                kVTCompressionPropertyKey_AverageBitRate: 2_000_000,
                kVTCompressionPropertyKey_ExpectedFrameRate: frameRate,
                kVTCompressionPropertyKey_MaxKeyFrameInterval: frameRate,
                kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 1
            ]
            for (key, value) in properties {
                let result = VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
                guard result == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(result)) }
            }
            let prepared = VTCompressionSessionPrepareToEncodeFrames(session)
            guard prepared == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(prepared)) }
        } catch {
            VTCompressionSessionInvalidate(session)
            self.session = nil
            throw error
        }
    }

    func encode(_ buffer: CVPixelBuffer, time: CMTime, forceKeyframe: Bool) {
        guard let session else { return }
        let properties = forceKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: buffer,
                                                     presentationTimeStamp: time, duration: .invalid,
                                                     frameProperties: properties, sourceFrameRefcon: nil,
                                                     infoFlagsOut: nil)
        if status != noErr { onError("Video encoding failed (\(status)).") }
    }

    func stop() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
    }

    deinit { stop() }

    private func receive(_ sample: CMSampleBuffer) {
        guard let format = CMSampleBufferGetFormatDescription(sample),
              let block = CMSampleBufferGetDataBuffer(sample) else { return }
        var headerLength: Int32 = 0
        var parameterCount = 0
        func parameter(_ index: Int) -> Data? {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size, parameterSetCountOut: &parameterCount,
                nalUnitHeaderLengthOut: &headerLength
            )
            guard status == noErr, let pointer else { return nil }
            return Data(bytes: pointer, count: size)
        }
        guard let sps = parameter(0), let pps = parameter(1), headerLength == 4 else { return }
        var bytes = Data(count: CMBlockBufferGetDataLength(block))
        let copied = bytes.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
        }
        guard copied == noErr else { return }
        var units: [Data] = []
        var offset = 0
        while offset + 4 <= bytes.count {
            let size = (0..<4).reduce(0) { ($0 << 8) | Int(bytes[offset + $1]) }
            offset += 4
            guard size > 0, size <= bytes.count - offset else { return }
            units.append(Data(bytes[offset ..< offset + size]))
            offset += size
        }
        guard offset == bytes.count, !units.isEmpty else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]]
        let keyframe = attachments?.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool != true
        onFrame(EncodedFrame(nalUnits: units, presentationTime: CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)),
                             isKeyframe: keyframe, sps: sps, pps: pps))
    }
}