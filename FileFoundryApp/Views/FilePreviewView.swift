import AppKit
import FileFoundryCore
import ImageIO
import SwiftUI

/// Decodes and caches downsampled thumbnails so selecting a row never blocks the main thread.
private enum ThumbnailCache {
    nonisolated(unsafe) static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 64
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    static func cached(for key: String) -> NSImage? { cache.object(forKey: key as NSString) }

    static func load(url: URL, key: String, maxPixel: Int = 800) async -> NSImage? {
        if let hit = cached(for: key) { return hit }
        let image: NSImage? = await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
        if let image {
            cache.setObject(image, forKey: key as NSString, cost: Int(image.size.width * image.size.height * 4))
        }
        return image
    }
}

struct FilePreviewView: View {
    @ObservedObject var viewModel: MainViewModel
    @State private var image: NSImage?
    @State private var snippet: String?

    private var file: ScannedFile? { viewModel.selectedFile }
    private var group: DuplicateGroup? { viewModel.selectedGroup }

    var body: some View {
        Group {
            if let file {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        preview(for: file)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(file.filename)
                                .font(.title3.weight(.semibold))
                                .lineLimit(3)
                                .textSelection(.enabled)
                            Text(file.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }

                        actions(for: file)

                        Divider()

                        VStack(alignment: .leading, spacing: 8) {
                            metadata(label: "Size", value: AppFormatters.fileSize(file.size))
                            if let duration = file.mediaDurationSeconds {
                                metadata(label: "Duration", value: AppFormatters.duration(duration))
                            }
                            metadata(label: "Verification", value: group?.verificationLevel.label ?? "Not available")
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                RackEmptyState(
                    symbol: "doc.viewfinder",
                    title: "No Selection",
                    message: "Select a file to preview it. Review before moving anything to Trash."
                )
            }
        }
        .task(id: file?.id) { await loadPreview() }
    }

    private func actions(for file: ScannedFile) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { actionButtons(for: file) }
            VStack(alignment: .leading, spacing: 8) { actionButtons(for: file) }
        }
        .controlSize(.regular)
    }

    @ViewBuilder
    private func actionButtons(for file: ScannedFile) -> some View {
        if let group {
            Button {
                viewModel.markFileToKeep(file, in: group)
            } label: {
                Label("Keep This Copy", systemImage: "checkmark.circle")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!group.allowsRemoval || viewModel.reviewState(for: file, in: group) == .keep)
        }
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([file.url])
        } label: {
            Label("Reveal", systemImage: "finder")
        }
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(file.path, forType: .string)
        } label: {
            Label("Copy Path", systemImage: "doc.on.doc")
        }
    }

    private func loadPreview() async {
        guard let file else { image = nil; snippet = nil; return }
        let key = "\(file.path)|\(file.size)|\(file.modificationDate?.timeIntervalSince1970 ?? 0)"
        image = ThumbnailCache.cached(for: key)
        snippet = nil
        if file.fileKind == .image {
            let loaded = await ThumbnailCache.load(url: file.url, key: key)
            guard !Task.isCancelled else { return }
            image = loaded
        } else {
            image = nil
            let text = await Task.detached(priority: .userInitiated) {
                PreviewService().preview(for: file).textSnippet
            }.value
            guard !Task.isCancelled else { return }
            snippet = text
        }
    }

    @ViewBuilder
    private func preview(for file: ScannedFile) -> some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 260)
            } else if let snippet, !snippet.isEmpty {
                Text(snippet)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, maxHeight: 200, alignment: .topLeading)
                    .padding(8)
                    .clipped()
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "doc")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text(file.fileKind.rawValue.capitalized)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func metadata(label: String, value: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(mono ? .system(.caption, design: .monospaced) : .callout)
                .monospacedDigit()
                .textSelection(.enabled)
                .lineLimit(mono ? 3 : nil)
        }
    }
}
