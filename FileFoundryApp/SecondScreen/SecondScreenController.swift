import AppKit
import ApplicationServices
import Foundation
import Observation

@MainActor
@Observable
final class SecondScreenController {
    static let shared = SecondScreenController()

    enum Phase: Equatable {
        case idle
        case waiting
        case connecting(String)
        case streaming(name: String, viaUSB: Bool)
        case failed(String)
    }

    enum Permission: Equatable { case granted, missing, unknown }

    // MARK: Observable state

    private(set) var phase: Phase = .idle
    private(set) var pairingCode: String = ""
    private(set) var pairingExpiresAt: Date = .distantPast
    private(set) var stats = SSHostStats()
    private(set) var streamInfo: SSConfig?
    private(set) var usbDevices = 0
    private(set) var adbFound = true
    private(set) var pairedDevices: [SSPairedDevice] = []
    private(set) var screenRecording: Permission = .unknown
    private(set) var accessibility: Permission = .unknown
    private(set) var localNetworkReady = false
    private(set) var justPaired = false

    var settings: SSStreamSettings { didSet { saveSettings() } }

    var isActive: Bool { phase != .idle && !isFailed }
    var isStreaming: Bool { if case .streaming = phase { true } else { false } }
    private var isFailed: Bool { if case .failed = phase { true } else { false } }

    // MARK: Private

    /// Everything the network/ADB queues report, delivered in order through one stream so the UI
    /// never applies an older value after a newer one (e.g. a stale pairing code).
    private enum UIEvent: Sendable {
        case listening(Bool, String?)
        case pairingCode(String, Date)
        case paired
        case session(SSSessionInfo)
        case sessionEnd(UInt64)
        case stats(UInt64, SSHostStats)
        case usb(SSADBBridge.Snapshot)
        case failure(UInt64, String)
    }

    private let keyStore: SSDeviceKeyStore = SSKeychainKeyStore()
    @ObservationIgnored private var server: SSServer?
    @ObservationIgnored private var adb: SSADBBridge?
    @ObservationIgnored private let pipelineBox = SSPipelineBox()
    @ObservationIgnored private var sessionTask: Task<Void, Never>?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var launchTask: Task<Void, Never>?
    /// Completes when the previous server's listener is really cancelled (stop → start on the same port).
    @ObservationIgnored private var stopGate: Task<Void, Never>?
    @ObservationIgnored private var terminateObserver: NSObjectProtocol?
    /// Bumped by every start and stop; events of an older run are ignored.
    @ObservationIgnored private var runId: UInt64 = 0
    @ObservationIgnored private var currentGeneration: UInt64 = 0

    private init() {
        let d = UserDefaults.standard
        var s = SSStreamSettings()
        if let v = d.string(forKey: "secondscreen.resolution"), let r = SSResolutionPreset(rawValue: v) { s.resolution = r }
        if let v = d.object(forKey: "secondscreen.fps") as? Int, let f = SSFrameRate(rawValue: v) { s.frameRate = f }
        if let v = d.string(forKey: "secondscreen.quality"), let q = SSQualityPreset(rawValue: v) { s.quality = q }
        if let v = d.object(forKey: "secondscreen.customMbps") as? Int { s.customMbps = v }
        if let v = d.string(forKey: "secondscreen.codec"), let c = SSCodecPreference(rawValue: v) { s.codec = c }
        settings = s
        pairedDevices = keyStore.devices()
    }

    private func saveSettings() {
        let d = UserDefaults.standard
        d.set(settings.resolution.rawValue, forKey: "secondscreen.resolution")
        d.set(settings.frameRate.rawValue, forKey: "secondscreen.fps")
        d.set(settings.quality.rawValue, forKey: "secondscreen.quality")
        d.set(settings.customMbps, forKey: "secondscreen.customMbps")
        d.set(settings.codec.rawValue, forKey: "secondscreen.codec")
    }

    // MARK: Start / stop

    func start() {
        guard !isActive else { return }
        refreshPermissions()
        phase = .waiting
        localNetworkReady = false
        justPaired = false
        pairingCode = ""
        currentGeneration = 0

        runId &+= 1
        let run = runId
        let (events, continuation) = AsyncStream<UIEvent>.makeStream()
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self, !Task.isCancelled, self.runId == run else { return }
                self.apply(event)
            }
        }

        terminateObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdownSynchronously() }
        }

        // A previous stop must have released the port before we bind it again.
        let gate = stopGate
        stopGate = nil
        launchTask = Task { [weak self] in
            await gate?.value
            guard let self, !Task.isCancelled, self.runId == run else { return }
            self.launch(continuation: continuation)
        }
    }

    private func launch(continuation: AsyncStream<UIEvent>.Continuation) {
        let box = pipelineBox
        var handlers = SSServer.Handlers()
        handlers.onListening = { ok, message in continuation.yield(.listening(ok, message)) }
        handlers.onPairingCode = { code, expiry in continuation.yield(.pairingCode(code, expiry)) }
        handlers.onPaired = { continuation.yield(.paired) }
        handlers.onSession = { continuation.yield(.session($0)) }
        handlers.onSessionEnd = { continuation.yield(.sessionEnd($0)) }
        handlers.onKeyframeRequest = { gen in box.pipeline(for: gen)?.requestKeyframe() }
        handlers.onInput = { gen, event in box.pipeline(for: gen)?.handle(event) }
        handlers.onStats = { gen, s in continuation.yield(.stats(gen, s)) }

        let server = SSServer(keyStore: keyStore, handlers: handlers)
        self.server = server
        server.start()

        let adb = SSADBBridge { snap in continuation.yield(.usb(snap)) }
        self.adb = adb
        adb.start()
    }

    private func apply(_ event: UIEvent) {
        switch event {
        case .listening(let ok, let message):
            if ok { localNetworkReady = true } else { fail(message ?? "Could not listen") }
        case .pairingCode(let code, let expiry):
            pairingCode = code; pairingExpiresAt = expiry
        case .paired:
            justPaired = true; pairedDevices = keyStore.devices()
        case .session(let info):
            beginSession(info)
        case .sessionEnd(let gen):
            if gen == currentGeneration { endSession() }
        case .stats(let gen, let s):
            if gen == currentGeneration { stats = s }
        case .usb(let snap):
            usbDevices = snap.deviceCount; adbFound = snap.adbFound
        case .failure(let gen, let message):
            if gen == currentGeneration { fail(message) }
        }
    }

    func stop() {
        runId &+= 1
        launchTask?.cancel(); launchTask = nil
        eventTask?.cancel(); eventTask = nil
        sessionTask?.cancel(); sessionTask = nil
        currentGeneration = 0
        adb?.stop(); adb = nil           // removes the adb reverses before returning
        let old = server
        server = nil
        let pipeline = pipelineBox.take()
        let previousGate = stopGate
        stopGate = Task {
            await previousGate?.value
            await pipeline?.stop()
            await old?.stopAndWait()
        }
        if let o = terminateObserver { NotificationCenter.default.removeObserver(o); terminateObserver = nil }
        phase = .idle
        streamInfo = nil
        stats = SSHostStats()
        usbDevices = 0
        pairingCode = ""
    }

    private func shutdownSynchronously() {
        adb?.stop()
        server?.stop()
        pipelineBox.take()?.destroyNow()
    }

    private func fail(_ message: String) {
        stop()
        phase = .failed(message)
    }

    func regenerateCode() { server?.regenerateCode() }

    func forget(_ device: SSPairedDevice) {
        keyStore.forget(deviceId: device.id)
        pairedDevices = keyStore.devices()
    }

    // MARK: Session

    private func beginSession(_ info: SSSessionInfo) {
        let generation = info.generation
        currentGeneration = generation
        phase = .connecting(info.hello.name)
        justPaired = false
        pairedDevices = keyStore.devices()
        stats = SSHostStats()
        streamInfo = nil
        let settings = self.settings
        let box = pipelineBox
        let server = self.server
        let run = runId
        // Tear the previous pipeline down (and let a half-started one finish) before building the next display.
        let old = box.take()
        let previous = sessionTask
        previous?.cancel()
        sessionTask = Task { [weak self] in
            await previous?.value
            await old?.stop()
            guard !Task.isCancelled else { return }
            do {
                let pipeline = try await SSStreamPipeline.start(
                    hello: info.hello, settings: settings, name: "File Foundry – \(info.hello.name)",
                    sendConfig: { server?.sendConfig(generation: generation, $0) },
                    sendVideo: { server?.sendVideo(generation: generation, $0) },
                    onFailure: { [weak self] msg in
                        Task { @MainActor in
                            guard let self, self.runId == run, self.currentGeneration == generation else { return }
                            self.fail(msg)
                        }
                    })
                guard let self, !Task.isCancelled, self.runId == run, self.currentGeneration == generation else {
                    await pipeline.stop(); return
                }
                box.set(pipeline, generation: generation)
                self.streamInfo = pipeline.config
                self.phase = .streaming(name: info.hello.name, viaUSB: info.viaUSB)
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.runId == run, self.currentGeneration == generation else { return }
                self.fail(error.localizedDescription)
            }
        }
    }

    private func endSession() {
        sessionTask?.cancel(); sessionTask = nil
        currentGeneration = 0
        if let p = pipelineBox.take() { Task { await p.stop() } }
        streamInfo = nil
        stats = SSHostStats()
        if isActive { phase = .waiting }
    }

    // MARK: Permissions

    func refreshPermissions() {
        screenRecording = CGPreflightScreenCaptureAccess() ? .granted : .missing
        accessibility = AXIsProcessTrusted() ? .granted : .missing
    }

    func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
        refreshPermissions()
    }

    func requestAccessibility() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        refreshPermissions()
    }

    func openSettings(_ pane: SettingsPane) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)") {
            NSWorkspace.shared.open(url)
        }
    }

    enum SettingsPane: String {
        case screenRecording = "Privacy_ScreenCapture"
        case accessibility = "Privacy_Accessibility"
        case localNetwork = "Privacy_LocalNetwork"
    }
}

/// Lets network-queue callbacks reach the running pipeline without hopping to the main actor.
/// A pipeline is only handed out for the generation it was started for.
final class SSPipelineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _pipeline: SSStreamPipeline?
    private var _generation: UInt64 = 0
    func pipeline(for generation: UInt64) -> SSStreamPipeline? {
        lock.withLock { _generation == generation ? _pipeline : nil }
    }
    func set(_ p: SSStreamPipeline, generation: UInt64) { lock.withLock { _pipeline = p; _generation = generation } }
    func take() -> SSStreamPipeline? { lock.withLock { let p = _pipeline; _pipeline = nil; _generation = 0; return p } }
}
