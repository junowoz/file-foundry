import AVFoundation
import Foundation
import ImageIO

struct MetadataReader: Sendable {
    let filenameParser = FilenameDateParser()

    func captureMoment(for url: URL, kind: MediaKind, filesystemFallback: Bool) async -> CaptureMoment? {
        if kind == .photo || kind == .rawPhoto, let imageDate = imageCaptureDate(url) {
            return imageDate
        }
        if kind == .video || kind == .audio, let assetDate = await assetCaptureDate(url) {
            return assetDate
        }
        if let filenameDate = filenameParser.parse(url.lastPathComponent) { return filenameDate }
        guard filesystemFallback,
              let date = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate else { return nil }
        let components = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return CaptureMoment(components: components, source: .filesystemOptional, confidence: .low)
    }

    private func imageCaptureDate(_ url: URL) -> CaptureMoment? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let candidates: [(String?, DateSource)] = [
            (exif?[kCGImagePropertyExifDateTimeOriginal] as? String, .embeddedOriginal),
            (exif?[kCGImagePropertyExifDateTimeDigitized] as? String, .embeddedDigitized),
            (tiff?[kCGImagePropertyTIFFDateTime] as? String, .embeddedContainer)
        ]
        for (value, source) in candidates {
            if let value, let components = parseEmbeddedDate(value) {
                return CaptureMoment(components: components, source: source, confidence: .high)
            }
        }
        return nil
    }

    private func assetCaptureDate(_ url: URL) async -> CaptureMoment? {
        let asset = AVURLAsset(url: url)
        guard let metadata = try? await asset.load(.commonMetadata) else { return nil }
        for item in metadata where item.commonKey == .commonKeyCreationDate {
            if let value = try? await item.load(.stringValue), let components = parseISODate(value) {
                return CaptureMoment(components: components, source: .embeddedContainer, confidence: .high)
            }
            // Some containers expose only an absolute Date. UTC is deterministic and avoids
            // reorganizing the same library differently when the Mac timezone changes.
            if let date = try? await item.load(.dateValue) {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(secondsFromGMT: 0)!
                let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
                return CaptureMoment(components: components, source: .embeddedContainer, confidence: .medium)
            }
        }
        return nil
    }

    private func parseEmbeddedDate(_ value: String) -> DateComponents? {
        let expression = try? NSRegularExpression(pattern: #"^(\d{4}):(\d{2}):(\d{2})[ T](\d{2}):(\d{2}):(\d{2})"#)
        guard let match = expression?.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        let values = (1...6).compactMap { index -> Int? in
            guard let range = Range(match.range(at: index), in: value) else { return nil }
            return Int(value[range])
        }
        guard values.count == 6 else { return nil }
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.year = values[0]; components.month = values[1]; components.day = values[2]
        components.hour = values[3]; components.minute = values[4]; components.second = values[5]
        guard let calendar = components.calendar, let date = calendar.date(from: components) else { return nil }
        let roundTrip = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard roundTrip.year == components.year, roundTrip.month == components.month, roundTrip.day == components.day,
              roundTrip.hour == components.hour, roundTrip.minute == components.minute, roundTrip.second == components.second else { return nil }
        return components
    }

    func parseISODate(_ value: String) -> DateComponents? {
        // Preserve the wall-clock fields embedded by the camera. Converting the instant to the
        // Mac's current timezone can move a capture across a day, month, or year boundary.
        let expression = try? NSRegularExpression(
            pattern: #"^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})"#
        )
        guard let match = expression?.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else {
            return nil
        }
        let values = (1...6).compactMap { index -> Int? in
            guard let range = Range(match.range(at: index), in: value) else { return nil }
            return Int(value[range])
        }
        guard values.count == 6 else { return nil }
        let normalized = String(
            format: "%04d:%02d:%02d %02d:%02d:%02d",
            values[0], values[1], values[2], values[3], values[4], values[5]
        )
        return parseEmbeddedDate(normalized)
    }
}
