import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Still images read by macOS itself (ImageIO): HEIC/HEIF, AVIF, RAW, TIFF, JPEG 2000 and everything ffprobe also knows.
/// ffprobe reports an iPhone HEIC as a set of HEVC tiles in an MP4 container, so photos are recognised here instead.
enum SystemImage {
    /// ffmpeg decodes these codecs as one complete frame. Anything else is decoded by macOS first.
    static let ffmpegReadableCodecs: Set<String> = ["png", "mjpeg", "webp", "tiff", "bmp"]

    /// True for still-image file types. GIF is left to ffprobe, since an animated GIF behaves like a video.
    static func isStillImageType(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .image) && !type.conforms(to: .gif)
    }

    /// Kind, size and codec of a still image, or nil when macOS can't read it as one.
    static func info(_ url: URL) -> MediaInfo? {
        guard isStillImageType(url),
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), nil)
                as? [CFString: Any]
        else { return nil }
        var info = MediaInfo()
        info.kind = .image
        info.width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
        info.height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        info.videoCodec = codec(for: CGImageSourceGetType(source) as String?)
        return info
    }

    /// Prefers the macOS reading for still images unless ffprobe already sees a single frame ffmpeg decodes well.
    static func merge(probed: MediaInfo, system: MediaInfo?) -> MediaInfo {
        guard var system else { return probed }
        if probed.kind == .image, let codec = probed.videoCodec, ffmpegReadableCodecs.contains(codec) { return probed }
        system.systemDecode = true
        return system
    }

    /// Writes the primary image as PNG with its orientation applied, for ffmpeg to encode. Blocking.
    static func decodeToPNG(input: URL, output: URL) throws {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw ToolError.failed("macOS can't read this image.")
        }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height, 1),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary),
              let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw ToolError.failed("macOS can't decode this image.") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ToolError.failed("Couldn't write the decoded image.") }
    }

    private static func codec(for typeIdentifier: String?) -> String? {
        guard let typeIdentifier, let type = UTType(typeIdentifier) else { return nil }
        if type.conforms(to: .jpeg) { return "mjpeg" }
        if type.conforms(to: .png) { return "png" }
        if type.conforms(to: .heic) || type.conforms(to: .heif) { return "heic" }
        if type.conforms(to: .tiff) { return "tiff" }
        if type.conforms(to: .webP) { return "webp" }
        if type.conforms(to: .bmp) { return "bmp" }
        if type.conforms(to: .rawImage) { return "raw" }
        return type.preferredFilenameExtension
    }
}
