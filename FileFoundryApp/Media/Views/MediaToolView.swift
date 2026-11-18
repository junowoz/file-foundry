import SwiftUI

/// Convert & Compress: drop files, then decide what to do with them, by type.
struct MediaToolView: View {
    @State private var model = MediaModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var spring: Animation? { reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 1) }

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: 920)
                .padding(24)
                .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { statusBar }
        .navigationTitle("Convert & Compress")
        .animation(spring, value: model.queue.items.map(\.id))
        .animation(spring, value: model.queue.kinds)
        .onDisappear { model.cancel() }
    }

    /// Queue status at the bottom: what is happening now, and how many files are done.
    private var statusBar: some View {
        RackStatusBar(status: statusText, symbol: nil) {
            if model.queue.doneCount > 0 {
                Text("\(model.queue.doneCount) done")
            }
        }
    }

    private var statusText: String {
        if model.queue.isBusy { return "Working…" }
        if model.queue.isProbing { return "Reading files…" }
        let count = model.queue.items.count
        if count == 0 { return "No files" }
        return "\(count) \(count == 1 ? "file" : "files")"
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Convert & Compress").font(.largeTitle.weight(.semibold))
            Text("Drop files, then choose what to do with them. Everything runs on this Mac.").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var content: some View {
        if model.queue.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                header
                DropZone(title: "Drop Files Here",
                         subtitle: "Video, audio, images or folders. Everything runs on this Mac.") { model.add($0) }
                if model.ffmpegMissing { InlineMessage(text: ToolError.toolMissing("FFmpeg").localizedDescription) }
            }
            .transition(.opacity)
        } else {
            VStack(alignment: .leading, spacing: 16) {
                header
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 24) {
                        filesColumn.frame(minWidth: 320, idealWidth: 400, maxWidth: 440)
                        optionsColumn.frame(minWidth: 360, maxWidth: .infinity)
                    }
                    VStack(alignment: .leading, spacing: 16) { filesColumn; optionsColumn }
                }
                if model.ffmpegMissing { InlineMessage(text: ToolError.toolMissing("FFmpeg").localizedDescription) }
            }
            .transition(.opacity)
        }
    }

    // MARK: Files

    private var filesColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 0) {
                ForEach(Array(model.queue.items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider() }
                    MediaRowView(item: item, showDetails: model.queue.items.count == 1) { model.remove(item.id) }
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))

            DropZone(title: "Add More Files", subtitle: "or drop them here", compact: true) { model.add($0) }

            HStack {
                if model.queue.hasFinished {
                    Button("Clear finished") { model.clearFinished() }.controlSize(.small)
                }
                Spacer()
                if !model.queue.isBusy {
                    Button("Remove all") { model.removeAll() }.controlSize(.small)
                }
            }
        }
    }

    // MARK: Options

    private var optionsColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(model.queue.kinds, id: \.self) { kind in
                MediaSettingsSection(
                    kind: kind, count: model.queue.items(of: kind).count, settings: model.binding(for: kind),
                    presets: model.convertPresets(for: kind), webpAvailable: model.webpAvailable,
                    hardwareAvailable: model.hardwareAvailable(codec: model.binding(for: kind).wrappedValue.codec),
                    preview: model.preview(for: kind), isLocked: model.queue.isBusy)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
            }
            if model.queue.isProbing { Text("Reading files…").foregroundStyle(.secondary) }
            outputRow
            actionRow
        }
    }

    private var outputRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder").foregroundStyle(.secondary)
            Text(model.outputDirectory?.path ?? "Next to each original")
                .lineLimit(1).truncationMode(.middle).font(.callout)
            Spacer()
            if model.outputDirectory != nil { Button("Reset") { model.outputDirectory = nil }.controlSize(.small) }
            Button("Change…") { model.chooseOutputDirectory() }.controlSize(.small)
        }
        .disabled(model.queue.isBusy)
        .foundryCard()
    }

    private var actionRow: some View {
        HStack {
            if model.queue.doneCount > 0, !model.queue.isBusy {
                Text("\(model.queue.doneCount) done").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    .contentTransition(.numericText(value: Double(model.queue.doneCount)))
            }
            Spacer()
            if model.queue.isBusy {
                Button("Cancel", role: .cancel) { model.cancel() }.keyboardShortcut(.cancelAction).controlSize(.large)
            } else {
                Button(startTitle) { model.start() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!model.canStart)
            }
        }
    }

    private var startTitle: String {
        let n = model.queue.startableCount
        let kinds = model.queue.kinds
        if n > 1 { return "Start \(n) files" }
        if kinds.count == 1, let action = model.settings[kinds[0]]?.action { return action.buttonTitle }
        return "Start"
    }
}
