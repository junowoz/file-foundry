import AppKit
import SwiftUI

struct CompressorView: View {
    @State private var model = CompressorModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: 920)
                .padding(24)
                .frame(maxWidth: .infinity)
        }
        .navigationTitle("Compressor")
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 1), value: phaseKey)
        .onDisappear { model.cancel() }
    }

    private var phaseKey: String {
        switch model.phase {
        case .empty: "empty"; case .probing: "probing"; case .ready: "ready"
        case .running: "running"; case .done: "done"; case .failed: "failed"
        }
    }

    private var enter: AnyTransition { reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)) }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .empty:
            VStack(alignment: .leading, spacing: 16) {
                header
                DropZone(title: "Drop a file to compress", subtitle: "Video, audio, images or any other file · or click to choose") { model.load($0) }
                if model.ffmpegMissing { InlineMessage(text: ToolError.toolMissing("FFmpeg").localizedDescription) }
            }.transition(enter)
        case .probing, .ready:
            workspace.transition(enter)
        case .running:
            VStack(alignment: .leading, spacing: 16) {
                if let input = model.input { FileCard(url: input, kind: model.kindLabel, size: ByteFormat.string(model.originalBytes)) }
                ProgressPanel(label: model.progressLabel, fraction: model.progress, elapsed: model.elapsed) { model.cancel() }
            }.frame(maxWidth: 560).transition(enter)
        case .done(let result):
            ResultPanel(
                outputURL: result.outputURL, originalBytes: result.originalBytes, newBytes: result.newBytes,
                percentSmaller: result.percentSmaller,
                warning: result.exceededTarget ? "Result is above the \(ByteFormat.string(result.targetBytes ?? 0)) target. Try a smaller target or enable the lower resolution." : (result.newBytes >= result.originalBytes ? "This content is already compressed, so the archive is not smaller." : nil),
                againTitle: "Compress another") { model.reset() }
                .frame(maxWidth: 480).transition(enter)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 14) {
                InlineMessage(text: message)
                Button("Try again") { if let input = model.input { model.load(input) } else { model.reset() } }
                Button("Choose another file") { model.reset() }
            }.frame(maxWidth: 560).transition(enter)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Compressor").font(.largeTitle.weight(.semibold))
            Text("Shrink a file to a size you choose. Everything runs on this Mac.").foregroundStyle(.secondary)
        }
    }

    private var workspace: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 20) {
                    fileColumn.frame(minWidth: 280, idealWidth: 320, maxWidth: 360)
                    optionsColumn.frame(minWidth: 360, maxWidth: .infinity)
                }
                .fixedSize(horizontal: false, vertical: false)
                VStack(alignment: .leading, spacing: 16) { fileColumn; optionsColumn }
            }
        }
    }

    private var fileColumn: some View {
        Group {
            if let input = model.input {
                FileCard(url: input, kind: model.kindLabel, size: ByteFormat.string(model.originalBytes),
                         details: model.details, isLoading: model.phase == .probing) { model.reset() }
            }
        }
    }

    private var optionsColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.phase == .ready {
                settings
                planSection
                outputRow
                HStack {
                    Spacer()
                    Button("Compress") { model.start() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(model.plan?.problem != nil || model.targetBlocked)
                }
            } else {
                Text("Reading file…").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var settings: some View {
        switch model.kind {
        case .video, .audio, .image:
            VStack(alignment: .leading, spacing: 14) {
                Picker("Mode", selection: $model.mode) {
                    ForEach(CompressionMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                if model.mode == .targetSize { targetControls } else { qualityControls }
                if model.kind == .video { codecPicker }
                if model.kind == .image { imageControls }
            }
            .foundryCard()
        case .other:
            Label("Lossless ZIP archive", systemImage: "doc.zipper").font(.headline).foundryCard()
        }
    }

    private var targetControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Target size")
                TextField("25", text: $model.targetText).textFieldStyle(.roundedBorder).frame(width: 90).multilineTextAlignment(.trailing)
                Text("MB").foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack { chips }
                VStack(alignment: .leading) { HStack { chips } }
            }
            if let problem = model.plan?.problem { InlineMessage(text: problem) }
        }
    }

    @ViewBuilder private var chips: some View {
        ForEach(model.quickTargets, id: \.title) { item in
            Button(item.title) { model.setTarget(bytes: item.bytes) }
                .buttonStyle(.bordered).controlSize(.small)
        }
    }

    private var qualityControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.kind == .image {
                Text("Use the quality slider below.").foregroundStyle(.secondary)
            } else {
                Picker("Quality", selection: $model.preset) {
                    ForEach(QualityPreset.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
        }
    }

    private var codecPicker: some View {
        Picker("Codec", selection: $model.codec) {
            ForEach(VideoCodecChoice.allCases) { Text($0.title).tag($0) }
        }
    }

    private var imageControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.webpAvailable {
                Picker("Format", selection: $model.imageFormat) { ForEach(ImageFormat.allCases) { Text($0.title).tag($0) } }
            }
            if model.mode == .quality {
                HStack {
                    Text("Quality")
                    Slider(value: $model.imageQuality, in: 10...100, step: 1)
                    Text("\(Int(model.imageQuality))").monospacedDigit().frame(width: 30, alignment: .trailing)
                }
            }
            HStack {
                Text("Max dimension")
                TextField("Original", text: $model.maxDimensionText).textFieldStyle(.roundedBorder).frame(width: 90).multilineTextAlignment(.trailing)
                Text("px").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var planSection: some View {
        if let plan = model.plan, plan.problem == nil {
            VStack(alignment: .leading, spacing: 8) {
                Label(plan.summary, systemImage: "slider.horizontal.3").font(.callout.weight(.medium))
                ForEach(plan.notes, id: \.self) { InlineMessage(text: $0, isError: false) }
                if plan.usesZip == false {
                    DisclosureGroup("Show FFmpeg command") {
                        Text(model.commandPreview)
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                    }.font(.callout)
                }
            }
            .foundryCard()
        }
    }

    private var outputRow: some View {
        HStack {
            Image(systemName: "folder").foregroundStyle(.secondary)
            Text(model.outputURL?.path ?? "").lineLimit(1).truncationMode(.middle).font(.callout)
            Spacer()
            Button("Change…") { model.chooseOutput() }.controlSize(.small)
        }
        .foundryCard()
    }
}

extension CompressorModel {
    var targetBlocked: Bool { mode == .targetSize && targetBytes == 0 }
}
