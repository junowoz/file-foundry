import Foundation
import UniformTypeIdentifiers

struct MediaClassifier: Sendable {
    private let rawExtensions: Set<String> = ["dng", "cr2", "cr3", "nef", "arw", "raf", "rw2", "orf", "pef"]
    private let sidecarExtensions: Set<String> = ["xmp", "aae", "json", "thm"]

    func classify(_ url: URL) -> MediaKind {
        let ext = url.pathExtension.lowercased()
        if rawExtensions.contains(ext) { return .rawPhoto }
        if sidecarExtensions.contains(ext) { return .sidecar }
        guard let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .image) { return .photo }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        return .other
    }
}
