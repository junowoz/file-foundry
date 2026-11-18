import AppKit
import SwiftUI

/// One file in the queue: what it is, where it stands, and what happened to it.
struct MediaRowView: View {
    var item: MediaItem
    var showDetails: Bool
    var onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                    .resizable().frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.url.lastPathComponent).font(.headline).lineLimit(1).truncationMode(.middle)
                    subtitle.font(.subheadline).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                }
                Spacer(minLength: 8)
                trailing
            }
            if case .running(let progress, _, let eta) = item.state {
                if let progress { ProgressView(value: progress) } else { ProgressView().progressViewStyle(.linear) }
                runningCaption(eta: eta)
            }
            if case .failed(let message) = item.state { InlineMessage(text: message) }
            if case .done(let result) = item.state, let warning = warning(for: result) {
                Label(warning, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showDetails, !details.isEmpty, !item.isFinished { detailGrid }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    // MARK: Pieces

    @ViewBuilder private var subtitle: some View {
        switch item.state {
        case .probing: Text("Reading…")
        case .done(let result): Text("\(ByteFormat.string(result.originalBytes)) → \(ByteFormat.string(result.newBytes))")
        default: Text("\(Self.kindLabel(item)) · \(ByteFormat.string(item.originalBytes))")
        }
    }

    @ViewBuilder private var trailing: some View {
        switch item.state {
        case .probing:
            ProgressView().controlSize(.small)
        case .ready:
            removeButton
        case .queued:
            HStack(spacing: 8) { Text("Queued").font(.callout).foregroundStyle(.secondary); removeButton }
        case .running(let progress, _, _):
            if let progress {
                Text(progress, format: .percent.precision(.fractionLength(0)))
                    .font(.headline).monospacedDigit().contentTransition(.numericText(value: progress))
            }
        case .done(let result):
            HStack(spacing: 8) {
                badge(for: result)
                Button { NSWorkspace.shared.activateFileViewerSelecting([result.outputURL]) } label: {
                    Image(systemName: "magnifyingglass.circle")
                }
                .buttonStyle(.borderless).help("Show in Finder").accessibilityLabel("Show in Finder")
            }
        case .failed:
            removeButton
        }
    }

    private var removeButton: some View {
        Button(action: onRemove) { Image(systemName: "xmark.circle.fill") }
            .buttonStyle(.borderless).foregroundStyle(.tertiary)
            .help("Remove from list").accessibilityLabel("Remove \(item.url.lastPathComponent)")
    }

    private func badge(for result: CompressionResult) -> some View {
        Group {
            if result.percentSmaller > 0 {
                Text("\(result.percentSmaller)% smaller").foregroundStyle(.green)
            } else if result.newBytes > result.originalBytes, result.originalBytes > 0 {
                let more = Int((Double(result.newBytes - result.originalBytes) / Double(result.originalBytes) * 100).rounded())
                Text("\(more)% larger").foregroundStyle(.secondary)
            } else {
                Text("Done").foregroundStyle(.secondary)
            }
        }
        .font(.callout.weight(.medium)).monospacedDigit()
    }

    private func runningCaption(eta: TimeInterval?) -> some View {
        HStack {
            if case .running(_, let label, _) = item.state { Text(label) }
            Spacer()
            if let eta { Text("About \(ByteFormat.duration(eta)) left") }
        }
        .font(.callout).foregroundStyle(.secondary).monospacedDigit()
    }

    private func warning(for result: CompressionResult) -> String? {
        if result.exceededTarget { return "Above the \(ByteFormat.string(result.targetBytes ?? 0)) target. Try a smaller target." }
        if item.kind == .other, result.newBytes >= result.originalBytes { return "Already compressed, so the archive is not smaller." }
        return nil
    }

    // MARK: Details

    private var details: [(label: String, value: String)] {
        let info = item.info
        var rows: [(String, String)] = []
        if info.duration > 0 { rows.append(("Duration", ByteFormat.duration(info.duration))) }
        if let w = info.width, let h = info.height {
            var value = "\(w) × \(h)"
            if item.kind == .video, let fps = info.fps { value += " · \(String(format: "%.0f", fps)) fps" }
            rows.append(("Resolution", value))
        }
        let codecs = [info.videoCodec, info.audioCodec].compactMap { $0 }.joined(separator: " + ")
        if !codecs.isEmpty { rows.append(("Codecs", codecs)) }
        if let b = info.totalBitrate, item.kind == .video || item.kind == .audio { rows.append(("Bitrate", ByteFormat.bitrate(b))) }
        return rows
    }

    private var detailGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            ForEach(details, id: \.label) { row in
                GridRow {
                    Text(row.label).foregroundStyle(.secondary)
                    Text(row.value).monospacedDigit().lineLimit(1).truncationMode(.tail).textSelection(.enabled)
                }
                .font(.callout)
            }
        }
        .padding(.leading, 44)
    }

    static func kindLabel(_ item: MediaItem) -> String {
        switch item.kind {
        case .video: "Video"
        case .audio: "Audio"
        case .image: "Image"
        case .other:
            (try? item.url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true ? "Folder" : (item.url.pathExtension.isEmpty ? "File" : "\(item.url.pathExtension.uppercased()) file")
        }
    }
}
