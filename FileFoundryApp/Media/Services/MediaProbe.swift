import Foundation

enum ContentKind: String, CaseIterable, Sendable {
    case video, audio, image, other

    /// Stable display order for grouped sections.
    var sortOrder: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

struct FFProbeOutput: Codable, Sendable {
    struct Stream: Codable, Sendable {
        var codecType: String?
        var codecName: String?
        var width: Int?
        var height: Int?
        var duration: String?
        var bitRate: String?
        var avgFrameRate: String?
        var rFrameRate: String?
        var disposition: [String: Int]?
        enum CodingKeys: String, CodingKey {
            case codecType = "codec_type", codecName = "codec_name", width, height, duration
            case bitRate = "bit_rate", avgFrameRate = "avg_frame_rate", rFrameRate = "r_frame_rate", disposition
        }
    }
    struct Format: Codable, Sendable {
        var formatName: String?
        var duration: String?
        var bitRate: String?
        enum CodingKeys: String, CodingKey { case formatName = "format_name", duration, bitRate = "bit_rate" }
    }
    var streams: [Stream]?
    var format: Format?
}

struct MediaInfo: Equatable, Sendable {
    var kind: ContentKind = .other
    var duration: Double = 0
    var width: Int?
    var height: Int?
    var fps: Double?
    var videoCodec: String?
    var audioCodec: String?
    var audioBitrate: Int?
    var totalBitrate: Int?
    var hasAudio: Bool { audioCodec != nil }

    static let other = MediaInfo()
}

enum MediaProbe {
    static let imageCodecs: Set<String> = ["png", "mjpeg", "webp", "tiff", "heic", "bmp", "jpeg2000", "jpegls", "avif"]

    static func parseFrameRate(_ text: String?) -> Double? {
        guard let text else { return nil }
        let parts = text.split(separator: "/")
        if parts.count == 2, let n = Double(parts[0]), let d = Double(parts[1]), d > 0, n > 0 { return n / d }
        if let v = Double(text), v > 0 { return v }
        return nil
    }

    static func parse(_ data: Data) throws -> MediaInfo {
        let output = try JSONDecoder().decode(FFProbeOutput.self, from: data)
        let streams = output.streams ?? []
        let formatDuration = output.format?.duration.flatMap(Double.init) ?? 0
        let formatName = output.format?.formatName ?? ""
        let video = streams.first { $0.codecType == "video" && ($0.disposition?["attached_pic"] ?? 0) == 0 }
        let audio = streams.first { $0.codecType == "audio" }

        var info = MediaInfo()
        info.duration = formatDuration > 0 ? formatDuration : (video?.duration ?? audio?.duration).flatMap(Double.init) ?? 0
        info.totalBitrate = output.format?.bitRate.flatMap(Int.init)
        info.audioCodec = audio?.codecName
        info.audioBitrate = audio?.bitRate.flatMap(Int.init)
        if let video {
            info.width = video.width
            info.height = video.height
            info.videoCodec = video.codecName
            info.fps = parseFrameRate(video.avgFrameRate) ?? parseFrameRate(video.rFrameRate)
        }

        if let video {
            let isImageCodec = imageCodecs.contains(video.codecName ?? "")
            let looksLikeStill = formatName.contains("_pipe") || formatName.contains("image2") || formatName == "tiff_pipe"
                || formatName == "webp_pipe" || info.duration <= 0
            if isImageCodec && looksLikeStill { info.kind = .image }
            else if info.duration > 0 { info.kind = .video }
            else { info.kind = isImageCodec ? .image : .other }
        } else if audio != nil, info.duration > 0 {
            info.kind = .audio
        } else {
            info.kind = .other
        }
        return info
    }

    static func probeArguments(for url: URL) -> [String] {
        ["-v", "error", "-protocol_whitelist", "file,pipe", "-print_format", "json", "-show_format", "-show_streams",
         "--", FFmpegRunner.absolutePath(url)]
    }

    /// Runs ffprobe off the main thread. Unreadable or non-media files come back as `.other`.
    static func probe(_ url: URL) async -> MediaInfo {
        guard let ffprobe = ToolLocator.locate("ffprobe") else { return .other }
        let sink = LineTail(limit: 100_000)
        let outcome = try? await ProcessRunner.run(ffprobe, probeArguments(for: url)) { sink.append($0) }
        guard outcome?.succeeded == true, let data = sink.text.data(using: .utf8),
              let info = try? parse(data) else { return .other }
        return info
    }
}

/// Encoders reported by `ffmpeg -encoders`, read once. An empty set means "unknown" (ffmpeg missing or unreadable),
/// in which case nothing is filtered out and the run reports the real error.
struct EncoderCapabilities: Equatable, Sendable {
    var encoders: Set<String> = []

    func has(_ name: String) -> Bool { encoders.isEmpty || encoders.contains(name) }
    /// Strict check for optional accelerators: only true when ffmpeg listed the encoder.
    func hasStrict(_ name: String) -> Bool { encoders.contains(name) }
    var hardwareH264: Bool { hasStrict("h264_videotoolbox") }
    var hardwareHEVC: Bool { hasStrict("hevc_videotoolbox") }

    static func parse(_ text: String) -> EncoderCapabilities {
        var names = Set<String>()
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, parts[0].count == 6, let first = parts[0].first, "VAS".contains(first) else { continue }
            names.insert(String(parts[1]))
        }
        return EncoderCapabilities(encoders: names)
    }

    static func load() async -> EncoderCapabilities {
        guard let ffmpeg = ToolLocator.locate("ffmpeg") else { return EncoderCapabilities() }
        let sink = LineTail(limit: 4_000)
        _ = try? await ProcessRunner.run(ffmpeg, ["-hide_banner", "-encoders"]) { sink.append($0) }
        return parse(sink.text)
    }
}
