import Foundation

/// What can be done with a file, decided by its type.
enum MediaAction: String, CaseIterable, Identifiable, Sendable {
    case compress, convert, zip
    var id: String { rawValue }
    var title: String {
        switch self { case .compress: "Compress"; case .convert: "Convert"; case .zip: "ZIP" }
    }
    var buttonTitle: String {
        switch self { case .compress: "Compress"; case .convert: "Convert"; case .zip: "Create ZIP" }
    }
}

enum MediaActions {
    /// Video, audio and images can be compressed or converted. Anything else (files, folders) can only be zipped.
    static func available(for kind: ContentKind) -> [MediaAction] {
        switch kind {
        case .video, .audio, .image: [.compress, .convert]
        case .other: [.zip]
        }
    }

    /// Video and audio mostly arrive too big, so they start on Compress. Images start on Convert (HEIC, PNG and WebP
    /// are usually dropped to get a JPEG) unless they are already JPEG, where shrinking is the useful move.
    static func defaultAction(for info: MediaInfo) -> MediaAction {
        switch info.kind {
        case .video, .audio: .compress
        case .image: info.videoCodec == "mjpeg" ? .compress : .convert
        case .other: .zip
        }
    }
}

/// Settings shared by every queued file of one kind.
struct KindSettings: Equatable, Sendable {
    var action: MediaAction
    // Compress
    var mode: CompressionMode = .targetSize
    var targetText = "25"
    /// When set (for example "half"), the target is this share of each file's own size and `targetText` is ignored.
    var targetFraction: Double?
    var codec: VideoCodecChoice = .h264
    var preset: QualityPreset = .balanced
    var hardware = false
    var imageFormat: ImageFormat = .jpeg
    var imageQuality = 82.0
    var maxDimensionText = ""
    // Convert
    var convertPreset: ConverterPreset

    init(info: MediaInfo, originalBytes: Int) {
        action = MediaActions.defaultAction(for: info)
        convertPreset = ConverterPreset.defaultPreset(for: info)
        if info.kind == .image { mode = .quality }
        if originalBytes > 30_000_000 { targetText = "25" } else { targetFraction = 0.5 }
    }

    var maxDimension: Int? {
        guard let v = Int(maxDimensionText), v >= 16 else { return nil }
        return v
    }

    func targetBytes(original: Int) -> Int {
        if let targetFraction { return Int(Double(original) * targetFraction) }
        let normalized = targetText.replacingOccurrences(of: ",", with: ".")
        guard let mb = Double(normalized), mb > 0 else { return 0 }
        return Int(mb * 1_000_000)
    }

    mutating func setTarget(megabytes: Int) { targetFraction = nil; targetText = String(megabytes) }

    var needsTarget: Bool { action == .compress && mode == .targetSize }
    var targetIsBlank: Bool { needsTarget && targetFraction == nil && targetBytes(original: 0) == 0 }
}

enum MediaJobPlanner {
    /// One plan for any action: compress, convert or ZIP.
    static func plan(
        settings s: KindSettings, info: MediaInfo, originalBytes: Int, input: URL, output: URL, passLog: String,
        capabilities: EncoderCapabilities
    ) -> CompressionPlan {
        switch (info.kind, s.action) {
        case (.other, _), (_, .zip):
            return CompressionPlanner.zip()
        case (_, .convert):
            return ConversionPlanner.make(preset: s.convertPreset, info: info, input: input, output: output)
        case (_, .compress):
            let hardware = s.hardware && s.mode == .quality && info.kind == .video
                && (s.codec == .h264 ? capabilities.hardwareH264 : capabilities.hardwareHEVC)
            let request = CompressionRequest(
                info: info, originalBytes: originalBytes, mode: s.mode, targetBytes: s.targetBytes(original: originalBytes),
                codec: s.codec, preset: s.preset,
                image: ImageSettings(format: s.imageFormat, quality: Int(s.imageQuality), maxDimension: s.maxDimension),
                hardware: hardware)
            return CompressionPlanner.make(request: request, input: input, output: output, passLog: passLog)
        }
    }

    /// Output next to the original (or in `directory`), named so nothing is ever overwritten.
    static func outputURL(for input: URL, plan: CompressionPlan, action: MediaAction, directory: URL?) -> URL {
        let isZip = plan.usesZip
        return OutputNaming.uniqueURL(
            directory: directory ?? input.deletingLastPathComponent(),
            baseName: isZip ? input.lastPathComponent : input.deletingPathExtension().lastPathComponent,
            suffix: action == .convert ? "converted" : "compressed", ext: plan.outputExtension)
    }
}
