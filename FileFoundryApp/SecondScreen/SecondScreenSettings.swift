import Foundation

enum SSResolutionPreset: String, CaseIterable, Identifiable, Sendable {
    case matchTablet, p1080, p1440, p2160
    var id: String { rawValue }
    var title: String {
        switch self {
        case .matchTablet: "Match tablet"
        case .p1080: "1080p"
        case .p1440: "1440p"
        case .p2160: "4K"
        }
    }
    /// Cap for the long edge in pixels.
    var longEdgeCap: Int {
        switch self {
        case .matchTablet: 3840
        case .p1080: 1920
        case .p1440: 2560
        case .p2160: 3840
        }
    }
}

enum SSFrameRate: Int, CaseIterable, Identifiable, Sendable {
    case fps30 = 30, fps60 = 60, fps90 = 90, fps120 = 120
    var id: Int { rawValue }
    var title: String { "\(rawValue) fps" }
}

enum SSQualityPreset: String, CaseIterable, Identifiable, Sendable {
    case battery, balanced, quality, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .battery: "Battery"
        case .balanced: "Balanced"
        case .quality: "Quality"
        case .custom: "Custom"
        }
    }

    static let customRangeMbps = 2...200

    /// Average bitrate in bits per second.
    func bitrate(customMbps: Int) -> Int {
        switch self {
        case .battery: 15_000_000
        case .balanced: 40_000_000
        case .quality: 80_000_000
        case .custom: min(max(customMbps, Self.customRangeMbps.lowerBound), Self.customRangeMbps.upperBound) * 1_000_000
        }
    }
}

enum SSCodecPreference: String, CaseIterable, Identifiable, Sendable {
    case auto, hevc, h264
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: "Auto"
        case .hevc: "HEVC"
        case .h264: "H.264"
        }
    }

    /// Wire codec name: "hevc" or "avc". HEVC only when the client lists it.
    func resolve(clientSupportsHEVC: Bool) -> String {
        switch self {
        case .auto, .hevc: clientSupportsHEVC ? "hevc" : "avc"
        case .h264: "avc"
        }
    }
}

struct SSStreamSettings: Equatable, Sendable {
    var resolution: SSResolutionPreset = .matchTablet
    var frameRate: SSFrameRate = .fps60
    var quality: SSQualityPreset = .balanced
    var customMbps: Int = 40
    var codec: SSCodecPreference = .auto

    var bitrate: Int { quality.bitrate(customMbps: customMbps) }
}

/// Pixel size and HiDPI decision for the virtual display.
struct SSStreamGeometry: Equatable, Sendable {
    var pixelWidth: Int
    var pixelHeight: Int
    var hiDPI: Bool

    /// Logical size in points as macOS sees the display.
    var pointWidth: Int { hiDPI ? pixelWidth / 2 : pixelWidth }
    var pointHeight: Int { hiDPI ? pixelHeight / 2 : pixelHeight }

    /// Tablets at 240 dpi or more get a 2x display (UI stays a sensible size).
    static let hiDPIThreshold = 240

    static func make(clientWidth: Int, clientHeight: Int, densityDpi: Int, preset: SSResolutionPreset) -> SSStreamGeometry {
        let w = Double(max(clientWidth, 1)), h = Double(max(clientHeight, 1))
        let scale = min(1, Double(preset.longEdgeCap) / max(w, h))
        // Multiples of 8 keep encoder blocks and the HiDPI halving clean.
        func snap(_ v: Double) -> Int { max(Int((v / 8).rounded()) * 8, 320) }
        return SSStreamGeometry(pixelWidth: snap(w * scale), pixelHeight: snap(h * scale),
                                hiDPI: densityDpi >= hiDPIThreshold)
    }
}
