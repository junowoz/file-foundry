import Foundation

/// Output formats for "Convert". Arguments are passed to ffmpeg as an array, never through a shell.
enum ConverterPreset: String, CaseIterable, Identifiable, Sendable {
    case videoH264, videoHEVC, videoWebM, videoGIF
    case audioMP3, audioAAC, audioWAV, audioFLAC, audioOpus
    case imageJPEG, imagePNG, imageWebP, imageHEIC, imageTIFF, imageGIF, imageBMP

    enum Group: String, CaseIterable, Sendable { case video = "Video", audio = "Audio", image = "Image" }

    var id: String { rawValue }

    var group: Group {
        switch self {
        case .videoH264, .videoHEVC, .videoWebM, .videoGIF: .video
        case .audioMP3, .audioAAC, .audioWAV, .audioFLAC, .audioOpus: .audio
        case .imageJPEG, .imagePNG, .imageWebP, .imageHEIC, .imageTIFF, .imageGIF, .imageBMP: .image
        }
    }

    var shortTitle: String {
        switch self {
        case .videoH264: "H.264 MP4"
        case .videoHEVC: "HEVC MP4"
        case .videoWebM: "VP9 WebM"
        case .videoGIF: "Animated GIF"
        case .audioMP3: "MP3"
        case .audioAAC: "AAC M4A"
        case .audioWAV: "WAV"
        case .audioFLAC: "FLAC"
        case .audioOpus: "Opus"
        case .imageJPEG: "JPEG"
        case .imagePNG: "PNG"
        case .imageWebP: "WebP"
        case .imageHEIC: "HEIC"
        case .imageTIFF: "TIFF"
        case .imageGIF: "GIF"
        case .imageBMP: "BMP"
        }
    }

    var title: String { "\(group.rawValue) — \(shortTitle)" }

    var fileExtension: String {
        switch self {
        case .videoH264, .videoHEVC: "mp4"
        case .videoWebM: "webm"
        case .videoGIF: "gif"
        case .audioMP3: "mp3"
        case .audioAAC: "m4a"
        case .audioWAV: "wav"
        case .audioFLAC: "flac"
        case .audioOpus: "opus"
        case .imageJPEG: "jpg"
        case .imagePNG: "png"
        case .imageWebP: "webp"
        case .imageHEIC: "heic"
        case .imageTIFF: "tiff"
        case .imageGIF: "gif"
        case .imageBMP: "bmp"
        }
    }

    var detail: String {
        switch self {
        case .videoH264: "Plays everywhere"
        case .videoHEVC: "Smaller files, newer devices"
        case .videoWebM: "For the web"
        case .videoGIF: "480 px wide, 12 fps, no sound"
        case .audioMP3: "320 kbps, plays everywhere"
        case .audioAAC: "256 kbps, Apple friendly"
        case .audioWAV: "Uncompressed"
        case .audioFLAC: "Lossless, smaller than WAV"
        case .audioOpus: "160 kbps, efficient"
        case .imageJPEG: "High quality, plays everywhere"
        case .imagePNG: "Lossless"
        case .imageWebP: "Small files for the web"
        case .imageHEIC: "Small files, Apple devices"
        case .imageTIFF: "Lossless, for print and editing"
        case .imageGIF: "Still image, 256 colours"
        case .imageBMP: "Uncompressed bitmap"
        }
    }

    /// ffmpeg encoder this preset needs. nil for presets that use the system `sips` tool.
    var requiredEncoder: String? {
        switch self {
        case .videoH264: "libx264"
        case .videoHEVC: "libx265"
        case .videoWebM: "libvpx-vp9"
        case .videoGIF: "gif"
        case .audioMP3: "libmp3lame"
        case .audioAAC: "aac"
        case .audioWAV: "pcm_s16le"
        case .audioFLAC: "flac"
        case .audioOpus: "libopus"
        case .imageWebP: "libwebp"
        case .imageJPEG, .imagePNG, .imageHEIC, .imageTIFF, .imageGIF, .imageBMP: nil
        }
    }

    /// Still images (except WebP, which macOS can't write) go through macOS ImageIO via `sips`: it reads HEIC grids,
    /// RAW and AVIF, keeps colour profiles and metadata, and applies orientation where the format has no EXIF.
    var usesSips: Bool { group == .image && self != .imageWebP }

    /// ffmpeg output arguments (between `-i <input>` and the output path). Never contains `-y`.
    var arguments: [String] {
        let video = ["-map", "0:v:0", "-map", "0:a:0?"]
        switch self {
        case .videoH264: return video + ["-c:v", "libx264", "-crf", "20", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"]
        case .videoHEVC: return video + ["-c:v", "libx265", "-crf", "24", "-pix_fmt", "yuv420p", "-tag:v", "hvc1", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"]
        case .videoWebM: return video + ["-c:v", "libvpx-vp9", "-crf", "30", "-b:v", "0", "-row-mt", "1", "-c:a", "libopus"]
        case .videoGIF:
            return ["-an", "-filter_complex", "[0:v]fps=12,scale=480:-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse", "-loop", "0"]
        case .audioMP3: return ["-vn", "-c:a", "libmp3lame", "-b:a", "320k"]
        case .audioAAC: return ["-vn", "-c:a", "aac", "-b:a", "256k"]
        case .audioWAV: return ["-vn", "-c:a", "pcm_s16le"]
        case .audioFLAC: return ["-vn", "-c:a", "flac"]
        case .audioOpus: return ["-vn", "-c:a", "libopus", "-b:a", "160k"]
        case .imageJPEG: return ["-s", "format", "jpeg", "-s", "formatOptions", "90"]
        case .imagePNG: return ["-s", "format", "png"]
        case .imageWebP: return ["-frames:v", "1", "-c:v", "libwebp", "-quality", "90"]
        case .imageHEIC: return ["-s", "format", "heic", "-s", "formatOptions", "85"]
        case .imageTIFF: return ["-s", "format", "tiff"]
        case .imageGIF: return ["-s", "format", "gif"]
        case .imageBMP: return ["-s", "format", "bmp"]
        }
    }

    /// Formats offered for a source kind, hiding anything this ffmpeg build cannot encode.
    static func available(for kind: ContentKind, capabilities: EncoderCapabilities) -> [ConverterPreset] {
        let all: [ConverterPreset]
        switch kind {
        case .video: all = [.videoH264, .videoHEVC, .videoWebM, .videoGIF, .audioMP3, .audioAAC, .audioWAV, .audioFLAC]
        case .audio: all = [.audioMP3, .audioAAC, .audioWAV, .audioFLAC, .audioOpus]
        case .image: all = [.imageJPEG, .imagePNG, .imageHEIC, .imageWebP, .imageTIFF, .imageGIF, .imageBMP]
        case .other: all = []
        }
        return all.filter { preset in preset.requiredEncoder.map(capabilities.has) ?? true }
    }

    static func defaultPreset(for info: MediaInfo) -> ConverterPreset {
        switch info.kind {
        case .video, .other: .videoH264
        case .audio: .audioMP3
        case .image: info.videoCodec == "mjpeg" ? .imagePNG : .imageJPEG
        }
    }
}

enum ConversionPlanner {
    static func make(preset: ConverterPreset, info: MediaInfo, input: URL, output: URL) -> CompressionPlan {
        var steps: [CompressionStep] = []
        var decodedInput: URL?
        if preset.usesSips {
            steps = [CompressionStep(label: "Converting to \(preset.shortTitle)",
                                     arguments: preset.arguments + [input.path, "--out", output.path], weight: 1, tool: .sips)]
        } else {
            var source = input
            if preset.group == .image, let decode = SystemDecode.step(info: info, input: input, output: output) {
                steps.append(decode.step)
                source = decode.decoded
                decodedInput = decode.decoded
            }
            steps.append(CompressionStep(
                label: "Converting to \(preset.shortTitle)",
                arguments: FFmpegRunner.baseArguments + ["-n"] + FFmpegRunner.inputArguments(source) + preset.arguments + [output.path], weight: 1))
        }
        var problem: String?
        if preset.group == .audio, info.kind == .video, !info.hasAudio { problem = "This video has no audio track." }
        if preset.usesSips, info.kind != .image { problem = "Image formats need an image as the source." }
        return CompressionPlan(
            kind: info.kind, summary: "\(preset.shortTitle) · \(preset.detail)", outputExtension: preset.fileExtension,
            steps: steps, notes: [], problem: problem, imageTargetBytes: nil, targetBytes: nil, imageSettings: nil,
            duration: info.duration > 0 ? info.duration : nil, decodedInput: decodedInput)
    }
}

/// Used by the app launch probe and tests.
enum ConverterExecutable {
    static func locate(environment: [String: String] = ProcessInfo.processInfo.environment, fileManager: FileManager = .default) -> URL? {
        ToolLocator.locate("ffmpeg", environment: environment, fileManager: fileManager)
    }

    static func probe() -> Bool {
        guard let executable = locate() else { return false }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-version"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
