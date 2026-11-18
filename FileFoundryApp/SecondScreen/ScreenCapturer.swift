import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import ScreenCaptureKit

enum SSCaptureError: LocalizedError {
    case displayNotFound
    var errorDescription: String? { "The virtual display did not show up for capture." }
}

/// SCStream of a single display. Frames go straight to `onFrame` as CVPixelBuffers (no copies).
final class SSScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    typealias FrameHandler = @Sendable (CVPixelBuffer, CMTime) -> Void

    private let queue = DispatchQueue(label: "com.junowoz.filefoundry.secondscreen.capture", qos: .userInteractive)
    private let lock = NSLock()
    private var stream: SCStream?       // guarded by lock
    private var stopped = false         // guarded by lock
    private let onFrame: FrameHandler
    private let onStop: @Sendable (Error?) -> Void

    init(onFrame: @escaping FrameHandler, onStop: @escaping @Sendable (Error?) -> Void) {
        self.onFrame = onFrame
        self.onStop = onStop
    }

    func start(displayID: CGDirectDisplayID, pixelWidth: Int, pixelHeight: Int, fps: Int) async throws {
        // A freshly created display can take a moment to appear in the shareable list.
        var display: SCDisplay?
        for _ in 0..<20 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            display = content.displays.first { $0.displayID == displayID }
            if display != nil { break }
            try await Task.sleep(for: .milliseconds(150))
        }
        guard let display else { throw SSCaptureError.displayNotFound }

        let config = SCStreamConfiguration()
        config.width = pixelWidth
        config.height = pixelHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 3
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = true
        config.capturesAudio = false
        config.colorSpaceName = CGColorSpace.sRGB

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        let keep = lock.withLock { () -> Bool in
            if stopped { return false }
            self.stream = stream
            return true
        }
        if !keep { try? await stream.stopCapture() }
    }

    /// Idempotent; no frame is delivered after this returns.
    func stop() async {
        let s = lock.withLock { () -> SCStream? in
            stopped = true
            let s = stream
            stream = nil
            return s
        }
        if let s { try? await s.stopCapture() }
    }

    private var isStopped: Bool { lock.withLock { stopped } }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !isStopped, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        onFrame(pixelBuffer, sampleBuffer.presentationTimeStamp)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let wasStopped = lock.withLock { () -> Bool in
            let was = stopped
            self.stream = nil
            return was
        }
        if !wasStopped { onStop(error) }
    }
}
