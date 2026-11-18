import SwiftUI

/// Settings for every queued file of one kind: pick Compress or Convert, then tune it.
struct MediaSettingsSection: View {
    var kind: ContentKind
    var count: Int
    @Binding var settings: KindSettings
    var presets: [ConverterPreset]
    var webpAvailable: Bool
    var hardwareAvailable: Bool
    var preview: (plan: CompressionPlan, command: String)?
    var isLocked: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if MediaActions.available(for: kind).count > 1 {
                Picker("Action", selection: $settings.action) {
                    ForEach(MediaActions.available(for: kind)) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            Group {
                switch settings.action {
                case .compress: compressControls
                case .convert: convertControls
                case .zip: Text("Packs everything into one lossless ZIP archive.").foregroundStyle(.secondary)
                }
            }
            summary
        }
        .disabled(isLocked)
        .foundryCard()
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: Self.symbol(kind)).foregroundStyle(.secondary)
            Text(Self.title(kind)).font(.headline)
            Spacer()
            Text("\(count) \(count == 1 ? "file" : "files")").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                .contentTransition(.numericText(value: Double(count)))
        }
    }

    static func symbol(_ kind: ContentKind) -> String {
        switch kind { case .video: "film"; case .audio: "waveform"; case .image: "photo"; case .other: "doc.zipper" }
    }

    static func title(_ kind: ContentKind) -> String {
        switch kind { case .video: "Video"; case .audio: "Audio"; case .image: "Images"; case .other: "Files and folders" }
    }

    // MARK: Compress

    @ViewBuilder private var compressControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Mode", selection: $settings.mode) {
                ForEach(CompressionMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            if settings.mode == .targetSize { targetControls } else { qualityControls }
            if kind == .video { Picker("Codec", selection: $settings.codec) { ForEach(VideoCodecChoice.allCases) { Text($0.title).tag($0) } } }
            if kind == .image { imageControls }
        }
    }

    private var targetControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Target size")
                TextField("25", text: Binding(
                    get: { settings.targetFraction == nil ? settings.targetText : "" },
                    set: { settings.targetFraction = nil; settings.targetText = $0 }))
                    .textFieldStyle(.roundedBorder).frame(width: 88).multilineTextAlignment(.trailing).monospacedDigit()
                Text("MB").foregroundStyle(.secondary)
                if count > 1 { Text("per file").font(.callout).foregroundStyle(.secondary) }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { chips }
                VStack(alignment: .leading, spacing: 8) { HStack(spacing: 8) { chips } }
            }
        }
    }

    @ViewBuilder private var chips: some View {
        ForEach([8, 25, 50], id: \.self) { mb in
            chip("\(mb) MB", selected: settings.targetFraction == nil && settings.targetText == String(mb)) { settings.setTarget(megabytes: mb) }
        }
        chip("Half", selected: settings.targetFraction == 0.5) { settings.targetFraction = 0.5 }
        chip("Quarter", selected: settings.targetFraction == 0.25) { settings.targetFraction = 0.25 }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.bordered).controlSize(.small)
            .tint(selected ? .accentColor : nil)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var qualityControls: some View {
        if kind == .image {
            HStack(spacing: 8) {
                Text("Quality")
                Slider(value: $settings.imageQuality, in: 10...100, step: 1)
                Text("\(Int(settings.imageQuality))").monospacedDigit().frame(width: 32, alignment: .trailing)
                    .contentTransition(.numericText(value: settings.imageQuality))
            }
        } else {
            Picker("Quality", selection: $settings.preset) { ForEach(QualityPreset.allCases) { Text($0.title).tag($0) } }
                .pickerStyle(.segmented).labelsHidden()
            if kind == .video, hardwareAvailable {
                Toggle(isOn: $settings.hardware) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Fast (hardware)")
                        Text("Uses this Mac's video engine. Much quicker, slightly larger files.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var imageControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            if webpAvailable {
                Picker("Format", selection: $settings.imageFormat) { ForEach(ImageFormat.allCases) { Text($0.title).tag($0) } }
            }
            HStack(spacing: 8) {
                Text("Max dimension")
                TextField("Original", text: $settings.maxDimensionText)
                    .textFieldStyle(.roundedBorder).frame(width: 88).multilineTextAlignment(.trailing).monospacedDigit()
                Text("px").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Convert

    @ViewBuilder private var convertControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Convert to", selection: $settings.convertPreset) {
                ForEach(ConverterPreset.Group.allCases, id: \.self) { group in
                    let options = presets.filter { $0.group == group }
                    if !options.isEmpty {
                        Section(group == .audio && kind == .video ? "Extract audio" : group.rawValue) {
                            ForEach(options) { Text($0.shortTitle).tag($0) }
                        }
                    }
                }
            }
            Text(".\(settings.convertPreset.fileExtension) · \(settings.convertPreset.detail)")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: Summary

    @ViewBuilder private var summary: some View {
        if let preview {
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                if let problem = preview.plan.problem {
                    InlineMessage(text: problem)
                } else {
                    Label(preview.plan.summary, systemImage: "slider.horizontal.3").font(.callout.weight(.medium))
                    ForEach(preview.plan.notes, id: \.self) { InlineMessage(text: $0, isError: false) }
                    if !preview.command.isEmpty {
                        DisclosureGroup("Show command") {
                            Text(preview.command)
                                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                        }.font(.callout)
                    }
                }
            }
        }
    }
}
