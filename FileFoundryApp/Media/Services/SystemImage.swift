import AppKit
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
        if isSVG(url) { return svgInfo(url) }
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

    static func isSVG(_ url: URL) -> Bool { url.pathExtension.lowercased() == "svg" }

    /// Longest side, in pixels, of a rasterised SVG: vectors have no pixel size, so small ones are enlarged to stay sharp.
    private static let svgMinSide: CGFloat = 2048, svgMaxSide: CGFloat = 8192

    private static func svgPixelSize(_ image: NSImage) -> (width: Int, height: Int)? {
        var size = image.size
        if let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        guard size.width > 0, size.height > 0 else { return nil }
        let longest = max(size.width, size.height)
        let scale = longest < svgMinSide ? svgMinSide / longest : min(1, svgMaxSide / longest)
        return (max(1, Int((size.width * scale).rounded())), max(1, Int((size.height * scale).rounded())))
    }

    private static func svgInfo(_ url: URL) -> MediaInfo? {
        guard let image = NSImage(contentsOf: url), let size = svgPixelSize(image) else { return nil }
        var info = MediaInfo()
        info.kind = .image
        info.width = size.width
        info.height = size.height
        info.videoCodec = "svg"
        return info
    }

    /// Draws an SVG into a transparent bitmap with macOS's own renderer.
    private static func rasterizeSVG(input: URL, output: URL) throws {
        guard let image = NSImage(contentsOf: input), let size = svgPixelSize(image),
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: size.width, pixelsHigh: size.height, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep)
        else { throw ToolError.failed("macOS can't read this SVG.") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: size.width, height: size.height),
                   from: .zero, operation: .sourceOver, fraction: 1)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw ToolError.failed("Couldn't render this SVG.")
        }
        try png.write(to: output)
    }

    /// Writes the primary image as PNG with its orientation applied, for ffmpeg to encode. Blocking.
    static func decodeToPNG(input: URL, output: URL) throws {
        if isSVG(input) { return try rasterizeSVG(input: input, output: output) }
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
