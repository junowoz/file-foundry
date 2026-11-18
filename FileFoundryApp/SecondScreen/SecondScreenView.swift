import SwiftUI

/// Entry view of the Second Screen module.
struct SecondScreenView: View {
    @State private var controller = SecondScreenController.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StatusCard(controller: controller)
                if controller.isActive && !controller.isStreaming {
                    PairingCard(controller: controller)
                }
                if controller.isStreaming {
                    StatsCard(controller: controller)
                }
                SettingsCard(controller: controller)
                PermissionsCard(controller: controller)
                PairedDevicesCard(controller: controller)
            }
            .padding(24)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Second Screen")
        .onAppear { controller.refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            controller.refreshPermissions()
        }
    }
}

// MARK: - Cards

private struct Card<Content: View>: View {
    let title: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title).font(.headline)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct StatusCard: View {
    let controller: SecondScreenController

    var body: some View {
        Card {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(tint)
                    .frame(width: 40)
                    .symbolRenderingMode(.hierarchical)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title3.weight(.semibold))
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button(action: toggle) {
                    Text(controller.isActive ? "Stop" : "Start")
                        .frame(minWidth: 72)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(controller.isActive ? .red : .accentColor)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func toggle() {
        if controller.isActive { controller.stop() } else { controller.start() }
    }

    private var icon: String {
        switch controller.phase {
        case .idle: "ipad.landscape"
        case .waiting: "antenna.radiowaves.left.and.right"
        case .connecting: "arrow.triangle.2.circlepath"
        case .streaming: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch controller.phase {
        case .streaming: .green
        case .failed: .orange
        case .idle: .secondary
        default: .accentColor
        }
    }

    private var title: String {
        switch controller.phase {
        case .idle: "Second Screen is off"
        case .waiting: "Waiting for your tablet"
        case .connecting(let n): "Connecting to \u{201C}\(n)\u{201D}"
        case .streaming(let n, _): "Connected to \u{201C}\(n)\u{201D}"
        case .failed: "Could not start"
        }
    }

    private var subtitle: String {
        switch controller.phase {
        case .idle: "Turn an Android tablet into an extra display for this Mac."
        case .waiting:
            controller.usbDevices > 0
                ? "USB: \(controller.usbDevices) device\(controller.usbDevices == 1 ? "" : "s") ready. Open File Foundry Screen on the tablet."
                : "Open File Foundry Screen on the tablet, over USB or the same Wi-Fi."
        case .connecting: "Preparing the display"
        case .streaming(_, let usb):
            "\(usb ? "USB" : "Wi-Fi")" + (controller.streamInfo.map { " \u{00B7} \($0.width)\u{00D7}\($0.height) \u{00B7} \($0.codec == "hevc" ? "HEVC" : "H.264")" } ?? "")
        case .failed(let m): m
        }
    }
}

private struct PairingCard: View {
    let controller: SecondScreenController

    var body: some View {
        Card("Pairing code") {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(SSPairingCode.display(controller.pairingCode))
                    .font(.system(size: 28, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .textSelection(.enabled)
                    .contentTransition(.numericText())
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let left = max(0, Int(controller.pairingExpiresAt.timeIntervalSince(ctx.date)))
                    Text(String(format: "%d:%02d", left / 60, left % 60))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Button {
                    controller.regenerateCode()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("New code")
                .accessibilityLabel("New code")
            }
            Text("Enter this code on the tablet the first time. After pairing, the tablet reconnects on its own.")
                .font(.callout).foregroundStyle(.secondary)
            if controller.justPaired {
                Label("Paired", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
    }
}

private struct StatsCard: View {
    let controller: SecondScreenController

    var body: some View {
        let s = controller.stats
        Card("Live") {
            HStack(spacing: 0) {
                stat("Frame rate", String(format: "%.0f", s.sentFps), "fps")
                stat("Bitrate", String(format: "%.1f", s.bitrate / 1_000_000), "Mbps")
                stat("Latency", String(format: "%.0f", s.rttMs), "ms")
                stat("Dropped", "\(s.droppedFrames)", "")
            }
        }
    }

    private func stat(_ label: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.title2.weight(.semibold).monospacedDigit())
                    .contentTransition(.numericText())
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsCard: View {
    @Bindable var controller: SecondScreenController

    var body: some View {
        Card("Display") {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 10) {
                row("Resolution") {
                    Picker("Resolution", selection: $controller.settings.resolution) {
                        ForEach(SSResolutionPreset.allCases) { Text($0.title).tag($0) }
                    }
                }
                row("Frame rate") {
                    Picker("Frame rate", selection: $controller.settings.frameRate) {
                        ForEach(SSFrameRate.allCases) { Text($0.title).tag($0) }
                    }
                }
                row("Quality") {
                    Picker("Quality", selection: $controller.settings.quality) {
                        ForEach(SSQualityPreset.allCases) { Text($0.title).tag($0) }
                    }
                }
                if controller.settings.quality == .custom {
                    row("Bitrate") {
                        Stepper(value: $controller.settings.customMbps, in: SSQualityPreset.customRangeMbps, step: 5) {
                            Text("\(controller.settings.customMbps) Mbps").monospacedDigit()
                        }
                    }
                } else {
                    row("Bitrate") {
                        Text("\(controller.settings.bitrate / 1_000_000) Mbps")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                row("Codec") {
                    Picker("Codec", selection: $controller.settings.codec) {
                        ForEach(SSCodecPreference.allCases) { Text($0.title).tag($0) }
                    }
                }
            }
            if controller.isStreaming {
                Text("Changes apply the next time the tablet connects.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
    }

    private func row<V: View>(_ label: String, @ViewBuilder _ control: () -> V) -> some View {
        GridRow {
            Text(label).gridColumnAlignment(.leading).frame(width: 96, alignment: .leading)
            control().frame(maxWidth: 220, alignment: .leading)
        }
    }
}

private struct PermissionsCard: View {
    let controller: SecondScreenController

    var body: some View {
        Card("Permissions") {
            permission("Screen Recording", "Captures the virtual display.", controller.screenRecording == .granted,
                       action: "Grant") { controller.requestScreenRecording(); controller.openSettings(.screenRecording) }
            Divider()
            permission("Accessibility", "Lets touches on the tablet move the Mac pointer.", controller.accessibility == .granted,
                       action: "Open Settings") { controller.requestAccessibility(); controller.openSettings(.accessibility) }
            Divider()
            permission("Local Network", "Lets the tablet find this Mac over Wi-Fi. macOS asks on first start.",
                       controller.localNetworkReady, action: "Open Settings") { controller.openSettings(.localNetwork) }
        }
    }

    private func permission(_ title: String, _ detail: String, _ ok: Bool, action: String, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ok ? Color.green : Color.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !ok { Button(action, action: perform) }
        }
    }
}

private struct PairedDevicesCard: View {
    let controller: SecondScreenController

    var body: some View {
        Card("Paired tablets") {
            if controller.pairedDevices.isEmpty {
                Text("None yet. Install File Foundry Screen on the tablet, then pair it with the code above.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Link(destination: URL(string: "https://github.com/junowoz/file-foundry/releases/latest/download/FileFoundryScreen.apk")!) {
                    Label("Download the Android app (APK)", systemImage: "arrow.down.circle")
                }
            } else {
                ForEach(controller.pairedDevices) { device in
                    HStack {
                        Image(systemName: "ipad.landscape").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(device.name)
                            if device.pairedAt != .distantPast {
                                Text(device.pairedAt.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Forget", role: .destructive) { controller.forget(device) }
                    }
                    if device.id != controller.pairedDevices.last?.id { Divider() }
                }
            }
        }
    }
}
