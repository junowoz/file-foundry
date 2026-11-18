import Foundation

enum CompressionMode: String, CaseIterable, Identifiable, Sendable {
    case targetSize, quality
    var id: String { rawValue }
    var title: String { self == .targetSize ? "Target size" : "Quality" }
}

enum VideoCodecChoice: String, CaseIterable, Identifiable, Sendable {
    case h264, hevc
    var id: String { rawValue }
    var title: String { self == .h264 ? "Most compatible (H.264)" : "Smaller file (HEVC)" }
    var shortName: String { self == .h264 ? "H.264" : "HEVC" }
    var encoder: String { self == .h264 ? "libx264" : "libx265" }
    var hardwareEncoder: String { self == .h264 ? "h264_videotoolbox" : "hevc_videotoolbox" }
}

enum QualityPreset: String, CaseIterable, Identifiable, Sendable {
    case visuallyLossless, balanced, smallest
    var id: String { rawValue }
    var title: String {
        switch self { case .visuallyLossless: "Visually lossless"; case .balanced: "Balanced"; case .smallest: "Smallest" }
    }
    var crf: Int { switch self { case .visuallyLossless: 18; case .balanced: 23; case .smallest: 28 } }
    /// VideoToolbox `-q:v` (0-100, higher is better).
    var hardwareQuality: Int { switch self { case .visuallyLossless: 72; case .balanced: 58; case .smallest: 45 } }
    var audioBitrate: Int { switch self { case .visuallyLossless: 160_000; case .balanced: 128_000; case .smallest: 96_000 } }
    /// Rough share of the original size. Honest ranges, not promises.
    var estimatedFraction: ClosedRange<Double> {
        switch self { case .visuallyLossless: 0.45...0.9; case .balanced: 0.2...0.5; case .smallest: 0.08...0.25 }
    }
}

enum ImageFormat: String, CaseIterable, Identifiable, Sendable {
    case jpeg, webp
    var id: String { rawValue }
    var title: String { self == .jpeg ? "JPEG" : "WebP" }
    var fileExtension: String { self == .jpeg ? "jpg" : "webp" }
}

struct ImageSettings: Equatable, Sendable {
    var format: ImageFormat = .jpeg
    var quality: Int = 82
    var maxDimension: Int?
}

struct VideoBitratePlan: Equatable, Sendable {
    var feasible: Bool
    var videoBitrate: Int
    var audioBitrate: Int
    var copyAudio: Bool
    var scaleHeight: Int?
    var outputWidth: Int
    var outputHeight: Int
    var minimumTargetBytes: Int?
    var problem: String?
    var resolutionLowered: Bool { scaleHeight != nil }
}

enum BitratePlanner {
    static let overhead = 0.03
    static let minVideoBitrate = 100_000
    static let minBitsPerPixel = 0.04
    static let audioLadder = [128_000, 96_000, 64_000, 48_000]
    static let minAudioBitrate = 24_000
    static let maxAudioBitrate = 320_000

    static func validateTarget(targetBytes: Int, originalBytes: Int) -> String? {
        if targetBytes <= 0 { return "Enter a target size." }
        if targetBytes >= originalBytes { return "Target must be smaller than the original (\(ByteFormat.string(originalBytes)))." }
        return nil
    }

    static func even(_ value: Double) -> Int { max(2, Int((value / 2).rounded()) * 2) }

    static func planVideo(
        targetBytes: Int, duration: Double, width: Int, height: Int, fps: Double?,
        hasAudio: Bool, sourceAudioCodec: String?, sourceAudioBitrate: Int?
    ) -> VideoBitratePlan {
        let duration = max(duration, 0.1)
        let total = Double(targetBytes) * 8 * (1 - overhead) / duration
        var audio = 0
        var copy = false
        if hasAudio {
            audio = audioLadder.first { total - Double($0) >= 350_000 } ?? audioLadder.last!
            if sourceAudioCodec == "aac", let source = sourceAudioBitrate, source > 0, source <= audio {
                audio = source
                copy = true
            }
        }
        let video = Int(total) - audio
        let floorBits = Double(minVideoBitrate + (hasAudio ? audioLadder.last! : 0))
        let minimumBytes = Int((floorBits / (1 - overhead) * duration / 8 / 100_000).rounded(.up) * 100_000)
        guard video >= minVideoBitrate else {
            return VideoBitratePlan(
                feasible: false, videoBitrate: max(video, 0), audioBitrate: audio, copyAudio: copy, scaleHeight: nil,
                outputWidth: width, outputHeight: height, minimumTargetBytes: minimumBytes,
                problem: "Too small for this length of video. Try at least \(ByteFormat.string(minimumBytes)).")
        }
        let fps = (fps ?? 30) > 0 ? (fps ?? 30) : 30
        let candidates = [height] + [1080, 720, 540, 360].filter { $0 < height }
        var chosen = candidates.last!
        for candidate in candidates {
            let w = candidate == height ? width : even(Double(width) * Double(candidate) / Double(height))
            let bpp = Double(video) / (Double(w) * Double(candidate) * fps)
            if bpp >= minBitsPerPixel { chosen = candidate; break }
        }
        let scaled = chosen != height
        let outW = scaled ? even(Double(width) * Double(chosen) / Double(height)) : width
        return VideoBitratePlan(
            feasible: true, videoBitrate: video, audioBitrate: audio, copyAudio: copy,
            scaleHeight: scaled ? chosen : nil, outputWidth: outW, outputHeight: chosen,
            minimumTargetBytes: minimumBytes, problem: nil)
    }

    /// Audio-only: bitrate = budget, clamped. Returns nil bitrate when the budget is below the floor.
    static func planAudio(targetBytes: Int, duration: Double) -> (bitrate: Int, minimumBytes: Int, feasible: Bool) {
        let duration = max(duration, 0.1)
        let raw = Double(targetBytes) * 8 * (1 - overhead) / duration
        let minimumBytes = Int((Double(minAudioBitrate) / (1 - overhead) * duration / 8 / 10_000).rounded(.up) * 10_000)
        return (min(max(Int(raw), minAudioBitrate), maxAudioBitrate), minimumBytes, raw >= Double(minAudioBitrate))
    }
}

/// `decode` runs in-process: macOS writes the image as an oriented PNG (arguments: input, output).
enum StepTool: Equatable, Sendable { case ffmpeg, sips, decode }

struct CompressionStep: Equatable, Sendable {
    var label: String
    var arguments: [String]
    var weight: Double
    var tool: StepTool = .ffmpeg
}

struct CompressionRequest: Sendable {
    var info: MediaInfo
    var originalBytes: Int
    var mode: CompressionMode
    var targetBytes: Int
    var codec: VideoCodecChoice
    var preset: QualityPreset
    var image: ImageSettings
    /// Quality mode only: use VideoToolbox instead of libx264/libx265. Target size always stays two-pass software.
    var hardware = false
}

struct CompressionPlan: Equatable, Sendable {
    var kind: ContentKind
    var summary: String
    var outputExtension: String
    var steps: [CompressionStep]
    var notes: [String]
    var problem: String?
    var imageTargetBytes: Int?
    var targetBytes: Int?
    /// Image target-size search settings; nil for every other plan.
    var imageSettings: ImageSettings?
    /// Source duration used for progress; nil when unknown.
    var duration: Double?
    /// PNG decoded by macOS that ffmpeg steps read instead of the original; nil when ffmpeg reads the original.
    var decodedInput: URL?
    var usesZip: Bool { kind == .other }
    var needsFFmpeg: Bool { imageTargetBytes != nil || steps.contains { $0.tool == .ffmpeg } }
}

enum CompressionPlanner {
    static func make(request r: CompressionRequest, input: URL, output: URL, passLog: String) -> CompressionPlan {
        var plan: CompressionPlan
        switch r.info.kind {
        case .video: plan = video(r, input: input, output: output, passLog: passLog)
        case .audio: plan = audio(r, input: input, output: output)
        case .image: plan = image(r, input: input, output: output)
        case .other: return zip()
        }
        plan.duration = r.info.duration > 0 ? r.info.duration : nil
        if plan.imageTargetBytes != nil { plan.imageSettings = r.image }
        return plan
    }

    static func zip() -> CompressionPlan {
        CompressionPlan(kind: .other, summary: "Lossless ZIP archive", outputExtension: "zip", steps: [],
                        notes: ["Savings depend on the content. Photos, video and archives are often already compressed."],
                        problem: nil, imageTargetBytes: nil, targetBytes: nil)
    }

    static let base = FFmpegRunner.baseArguments

    private static func video(_ r: CompressionRequest, input: URL, output: URL, passLog: String) -> CompressionPlan {
        let info = r.info
        let w = info.width ?? 0, h = info.height ?? 0
        var notes: [String] = []
        var problem: String?
        var steps: [CompressionStep] = []
        var summary = ""
        let enc = r.codec.encoder
        let hevcTag = r.codec == .hevc ? ["-tag:v", "hvc1"] : []

        switch r.mode {
        case .targetSize:
            problem = BitratePlanner.validateTarget(targetBytes: r.targetBytes, originalBytes: r.originalBytes)
            let p = BitratePlanner.planVideo(
                targetBytes: r.targetBytes, duration: info.duration, width: w, height: h, fps: info.fps,
                hasAudio: info.hasAudio, sourceAudioCodec: info.audioCodec, sourceAudioBitrate: info.audioBitrate)
            if problem == nil { problem = p.problem }
            if let height = p.scaleHeight { notes.append("Resolution lowered to \(height)p to keep quality") }
            let vb = String(p.videoBitrate)
            let filter = p.scaleHeight.map { ["-vf", "scale=-2:\($0)"] } ?? []
            let common = ["-map", "0:v:0", "-c:v", enc, "-preset", "slow", "-b:v", vb, "-pix_fmt", "yuv420p"] + filter
            let pass1Extra: [String], pass2Extra: [String]
            if r.codec == .h264 {
                pass1Extra = ["-pass", "1", "-passlogfile", passLog]
                pass2Extra = ["-pass", "2", "-passlogfile", passLog]
            } else {
                pass1Extra = ["-x265-params", "pass=1:stats=\(passLog)"]
                pass2Extra = ["-x265-params", "pass=2:stats=\(passLog)"]
            }
            let pass1 = base + ["-y"] + FFmpegRunner.inputArguments(input) + common + pass1Extra + ["-an", "-f", "null", "/dev/null"]
            let pass2 = base + ["-n"] + FFmpegRunner.inputArguments(input) + common + hevcTag + pass2Extra
                + audioArguments(hasAudio: info.hasAudio, copy: p.copyAudio, bitrate: p.audioBitrate)
                + ["-map_metadata", "0", "-movflags", "+faststart", output.path]
            steps = [
                CompressionStep(label: "Step 1 of 2 · Analyzing", arguments: pass1, weight: 0.4),
                CompressionStep(label: "Step 2 of 2 · Encoding", arguments: pass2, weight: 0.6),
            ]
            summary = [r.codec.shortName, "Target size","\(ByteFormat.bitrate(p.videoBitrate)) video",
                       info.hasAudio ? (p.copyAudio ? "audio copied" : "\(ByteFormat.bitrate(p.audioBitrate)) audio") : "no audio",
                       "\(p.outputHeight)p"].joined(separator: " · ")
        case .quality:
            let crf = r.codec == .hevc ? r.preset.crf + 4 : r.preset.crf
            let copy = info.audioCodec == "aac" && (info.audioBitrate ?? Int.max) <= r.preset.audioBitrate
            let videoArgs = r.hardware
                ? ["-c:v", r.codec.hardwareEncoder, "-q:v", String(r.preset.hardwareQuality), "-pix_fmt", "yuv420p"]
                : ["-c:v", enc, "-preset", "slow", "-crf", String(crf), "-pix_fmt", "yuv420p"]
            let args = base + ["-n"] + FFmpegRunner.inputArguments(input) + ["-map", "0:v:0"] + videoArgs
                + hevcTag
                + audioArguments(hasAudio: info.hasAudio, copy: copy, bitrate: r.preset.audioBitrate)
                + ["-map_metadata", "0", "-movflags", "+faststart", output.path]
            steps = [CompressionStep(label: "Encoding", arguments: args, weight: 1)]
            let lo = Int(Double(r.originalBytes) * r.preset.estimatedFraction.lowerBound)
            let hi = Int(Double(r.originalBytes) * r.preset.estimatedFraction.upperBound)
            summary = r.hardware
                ? "\(r.codec.shortName) · hardware · \(r.preset.title)"
                : "\(r.codec.shortName) · \(r.preset.title)"
            if r.hardware { notes.append("Hardware encoding is much faster. Files are usually a little larger than software encoding.") }
            notes.append("Estimate only: roughly \(ByteFormat.string(lo)) to \(ByteFormat.string(hi)). Actual size depends on the content.")
        }
        return CompressionPlan(kind: .video, summary: summary, outputExtension: "mp4", steps: steps, notes: notes,
                               problem: problem, imageTargetBytes: nil, targetBytes: r.mode == .targetSize ? r.targetBytes : nil)
    }

    private static func audioArguments(hasAudio: Bool, copy: Bool, bitrate: Int) -> [String] {
        guard hasAudio else { return ["-map", "0:a:0?", "-an"] }
        return ["-map", "0:a:0"] + (copy ? ["-c:a", "copy"] : ["-c:a", "aac", "-b:a", String(bitrate)])
    }

    private static func audio(_ r: CompressionRequest, input: URL, output: URL) -> CompressionPlan {
        let isMP3 = r.info.audioCodec == "mp3"
        let codec = isMP3 ? "libmp3lame" : "aac"
        var problem: String?
        var notes: [String] = []
        let bitrate: Int
        if r.mode == .targetSize {
            problem = BitratePlanner.validateTarget(targetBytes: r.targetBytes, originalBytes: r.originalBytes)
            let p = BitratePlanner.planAudio(targetBytes: r.targetBytes, duration: r.info.duration)
            if problem == nil, !p.feasible { problem = "Too small for this length of audio. Try at least \(ByteFormat.string(p.minimumBytes))." }
            bitrate = p.bitrate
        } else {
            bitrate = r.preset.audioBitrate
            let lo = Int(Double(r.originalBytes) * r.preset.estimatedFraction.lowerBound)
            let hi = Int(Double(r.originalBytes) * r.preset.estimatedFraction.upperBound)
            notes.append("Estimate only: roughly \(ByteFormat.string(min(lo, hi))) to \(ByteFormat.string(hi)).")
        }
        let args = base + ["-n"] + FFmpegRunner.inputArguments(input)
            + ["-vn", "-map", "0:a:0", "-c:a", codec, "-b:a", String(bitrate), "-map_metadata", "0", output.path]
        return CompressionPlan(
            kind: .audio, summary: "\(isMP3 ? "MP3" : "AAC") · \(ByteFormat.bitrate(bitrate)) audio",
            outputExtension: isMP3 ? "mp3" : "m4a",
            steps: [CompressionStep(label: "Encoding", arguments: args, weight: 1)], notes: notes, problem: problem,
            imageTargetBytes: nil, targetBytes: r.mode == .targetSize ? r.targetBytes : nil)
    }

    static func imageArguments(input: URL, output: URL, settings s: ImageSettings, quality: Int) -> [String] {
        var args = ["-hide_banner", "-loglevel", "error", "-n"] + FFmpegRunner.inputArguments(input) + ["-frames:v", "1"]
        if let m = s.maxDimension, m > 0 {
            args += ["-vf", "scale=w='min(\(m),iw)':h='min(\(m),ih)':force_original_aspect_ratio=decrease"]
        }
        switch s.format {
        case .jpeg:
            let q = max(2, min(31, Int((31 - Double(quality) / 100 * 29).rounded())))
            args += ["-c:v", "mjpeg", "-q:v", String(q), "-pix_fmt", "yuvj420p"]
        case .webp:
            args += ["-c:v", "libwebp", "-quality", String(quality)]
        }
        return args + [output.path]
    }

    private static func image(_ r: CompressionRequest, input: URL, output: URL) -> CompressionPlan {
        let s = r.image
        let decode = SystemDecode.step(info: r.info, input: input, output: output)
        let input = decode?.decoded ?? input
        var problem: String?
        var summary = "\(s.format.title) · quality \(s.quality)"
        if let m = s.maxDimension { summary += " · max \(m) px" }
        if r.mode == .targetSize {
            problem = BitratePlanner.validateTarget(targetBytes: r.targetBytes, originalBytes: r.originalBytes)
            summary = "\(s.format.title) · up to 6 trial encodes to fit \(ByteFormat.string(r.targetBytes))"
        }
        let step = CompressionStep(label: "Encoding", arguments: imageArguments(input: input, output: output, settings: s, quality: s.quality), weight: 1)
        var plan = CompressionPlan(kind: .image, summary: summary, outputExtension: s.format.fileExtension,
                                   steps: (decode.map { [$0.step] } ?? []) + [step],
                                   notes: [], problem: problem,
                                   imageTargetBytes: r.mode == .targetSize ? r.targetBytes : nil,
                                   targetBytes: r.mode == .targetSize ? r.targetBytes : nil)
        plan.decodedInput = decode?.decoded
        return plan
    }
}

enum ByteFormat {
    static func string(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
    static func bitrate(_ bps: Int) -> String {
        bps >= 1_000_000 ? String(format: "%.1f Mbps", Double(bps) / 1_000_000) : "\(Int((Double(bps) / 1_000).rounded())) kbps"
    }
    static func duration(_ seconds: Double) -> String {
        let t = max(Int(seconds.rounded()), 0)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}

enum OutputNaming {
    /// "<name> (compressed).<ext>", then " 2", " 3"… so an existing file is never overwritten.
    static func uniqueURL(
        directory: URL, baseName: String, suffix: String = "compressed", ext: String,
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        let stem = "\(baseName) (\(suffix))"
        var candidate = directory.appendingPathComponent("\(stem).\(ext)")
        var n = 2
        while exists(candidate) {
            candidate = directory.appendingPathComponent("\(stem) \(n).\(ext)")
            n += 1
        }
        return candidate
    }
}

/// The macOS decode step that runs before ffmpeg for images ffmpeg can't read whole (HEIC grids, RAW, AVIF…).
enum SystemDecode {
    static func step(info: MediaInfo, input: URL, output: URL) -> (step: CompressionStep, decoded: URL)? {
        guard info.kind == .image, info.systemDecode else { return nil }
        let decoded = output.deletingLastPathComponent().appendingPathComponent("decoded-source.png")
        return (CompressionStep(label: "Reading image", arguments: [input.path, decoded.path], weight: 0, tool: .decode), decoded)
    }
}
