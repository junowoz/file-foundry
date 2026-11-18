import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

struct SSEncodedFrame: Sendable {
    var annexB: Data
    var ptsMicros: UInt64
    var isKeyframe: Bool
    var hasCodecConfig: Bool
}

enum SSEncoderError: LocalizedError {
    case sessionFailed(OSStatus)
    var errorDescription: String? {
        switch self { case .sessionFailed(let s): "Video encoder could not start (\(s))." }
    }
}

/// Real-time VTCompressionSession producing Annex-B with parameter sets on keyframes.
///
/// Thread-safety: `session`, `stopped` and the retained last buffer are guarded by `lock`. All encodes run
/// on `queue` (serial), so frames are submitted in order and synthetic keyframe re-encodes never race
/// captured frames. After `invalidate()` nothing touches the session.
final class SSVideoEncoder: @unchecked Sendable {
    typealias Output = @Sendable (SSEncodedFrame) -> Void

    private let queue = DispatchQueue(label: "com.junowoz.filefoundry.secondscreen.encode", qos: .userInteractive)
    private let lock = NSLock()
    private var session: VTCompressionSession?      // guarded by lock
    private var stopped = false                     // guarded by lock
    private var forceKey = false                    // guarded by lock
    private var pending = 0                         // frames queued but not yet submitted (lock)
    private var lastPixelBuffer: CVPixelBuffer?     // queue-confined (written under lock for visibility)
    private var lastSubmittedPTS: CMTime = .invalid // monotonic pts bookkeeping (lock)
    private var lastCaptureUptime: TimeInterval = 0 // when a real frame last arrived (lock)
    private let output: Output
    private let isHEVC: Bool

    init(width: Int, height: Int, hevc: Bool, fps: Int, bitrate: Int, output: @escaping Output) throws {
        self.isHEVC = hevc
        self.output = output

        let codec: CMVideoCodecType = hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        func create(lowLatency: Bool) -> (OSStatus, VTCompressionSession?) {
            var spec: [CFString: Any] = [:]
            if lowLatency { spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
            var s: VTCompressionSession?
            let status = VTCompressionSessionCreate(
                allocator: nil, width: Int32(width), height: Int32(height), codecType: codec,
                encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil,
                compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &s)
            return (status, s)
        }
        var (status, created) = create(lowLatency: true)
        if created == nil { (status, created) = create(lowLatency: false) }
        guard let session = created else { throw SSEncoderError.sessionFailed(status) }
        self.session = session

        func set(_ key: CFString, _ value: CFTypeRef) { VTSessionSetProperty(session, key: key, value: value) }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_ProfileLevel, hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel)
        set(kVTCompressionPropertyKey_AverageBitRate, bitrate as CFNumber)
        // [bytes, seconds]: allow short bursts (keyframes) up to 1.5x the average.
        set(kVTCompressionPropertyKey_DataRateLimits, [Int(Double(bitrate) * 1.5 / 8), 1] as CFArray)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 2 as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, (fps * 2) as CFNumber)
        set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_MaxFrameDelayCount, 1 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    deinit { invalidate() }

    /// Force a keyframe. The flag is consumed by the next captured frame; if the screen is idle
    /// (no frame within ~100 ms) the retained last buffer is re-encoded on the encode queue.
    func requestKeyframe() {
        lock.lock()
        if stopped { lock.unlock(); return }
        forceKey = true
        lock.unlock()
        queue.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in self?.reencodeIfIdle() }
    }

    /// Queue a captured frame. Frames are dropped when the encoder falls more than 2 frames behind.
    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        lock.lock()
        if stopped || pending >= 4 { lock.unlock(); return }
        pending += 1
        lastCaptureUptime = ProcessInfo.processInfo.systemUptime
        lock.unlock()
        queue.async { [self] in
            lock.lock(); pending -= 1; lock.unlock()
            submit(pixelBuffer, pts: pts)
        }
    }

    /// On `queue`: the flag is still set, so no captured frame consumed it.
    private func reencodeIfIdle() {
        lock.lock()
        let idle = ProcessInfo.processInfo.systemUptime - lastCaptureUptime >= 0.1
        let wanted = forceKey && !stopped && idle
        let buffer = lastPixelBuffer
        let base = lastSubmittedPTS
        lock.unlock()
        guard wanted, let buffer else { return }
        submit(buffer, pts: base.isValid ? base : .zero)
    }

    /// On `queue`. Presentation timestamps are forced to be strictly increasing.
    private func submit(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        lock.lock()
        guard !stopped, let session else { lock.unlock(); return }
        let key = forceKey
        forceKey = false
        var effective = pts
        if lastSubmittedPTS.isValid, effective <= lastSubmittedPTS {
            effective = CMTimeAdd(lastSubmittedPTS, CMTime(value: 1, timescale: 1000))
        }
        lastSubmittedPTS = effective
        lastPixelBuffer = pixelBuffer
        let props: CFDictionary? = key ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
        let isHEVC = self.isHEVC
        let output = self.output
        VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: effective, duration: .invalid,
            frameProperties: props, infoFlagsOut: nil
        ) { status, _, sample in
            guard status == noErr, let sample, let frame = Self.annexB(from: sample, hevc: isHEVC) else { return }
            output(frame)
        }
        lock.unlock()
    }

    func invalidate() {
        lock.lock()
        stopped = true
        let s = session
        session = nil
        lastPixelBuffer = nil
        lock.unlock()
        if let s {
            VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(s)
        }
    }

    // MARK: Annex-B

    private static let startCode: [UInt8] = [0, 0, 0, 1]

    static func annexB(from sample: CMSampleBuffer, hevc: Bool) -> SSEncodedFrame? {
        guard let block = sample.dataBuffer, let format = sample.formatDescription else { return nil }
        let notSync = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]])?
            .first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        let isKey = !notSync

        var out = Data()
        var hasConfig = false
        if isKey {
            var nalHeaderLength: Int32 = 4
            var count = 0
            if hevc {
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalHeaderLength)
            } else {
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalHeaderLength)
            }
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                let status = hevc
                    ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                    : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                if status == noErr, let ptr {
                    out.append(contentsOf: startCode)
                    out.append(ptr, count: size)
                    hasConfig = true
                }
            }
        }

        var nalLen: Int32 = 4
        var dummyCount = 0
        if hevc {
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &dummyCount, nalUnitHeaderLengthOut: &nalLen)
        } else {
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &dummyCount, nalUnitHeaderLengthOut: &nalLen)
        }
        var total = 0
        var dataPtr: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &total, dataPointerOut: &dataPtr) == noErr,
              let dataPtr else { return nil }
        out.reserveCapacity(out.count + total + 16)
        let base = UnsafeRawPointer(dataPtr)
        var offset = 0
        let lenBytes = Int(nalLen)
        while offset + lenBytes <= total {
            var n = 0
            for k in 0..<lenBytes { n = (n << 8) | Int(base.load(fromByteOffset: offset + k, as: UInt8.self)) }
            offset += lenBytes
            guard n > 0, offset + n <= total else { break }
            out.append(contentsOf: startCode)
            out.append(base.advanced(by: offset).assumingMemoryBound(to: UInt8.self), count: n)
            offset += n
        }

        let pts = sample.presentationTimeStamp
        let micros = pts.isValid ? UInt64(max(0, CMTimeConvertScale(pts, timescale: 1_000_000, method: .default).value)) : 0
        return SSEncodedFrame(annexB: out, ptsMicros: micros, isKeyframe: isKey, hasCodecConfig: hasConfig)
    }
}
