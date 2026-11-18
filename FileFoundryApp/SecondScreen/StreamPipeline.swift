import CoreGraphics
import Foundation

/// Virtual display → capture → encoder for one client session. Everything is released in `stop()`.
///
/// The parts are installed during `start` and read from other threads (network queue, capture queue),
/// so they live behind one lock together with a `stopped` flag: nothing is installed or used after stop.
final class SSStreamPipeline: @unchecked Sendable {
    let config: SSConfig
    let geometry: SSStreamGeometry

    private struct Parts {
        var display: SSVirtualDisplay?
        var capturer: SSScreenCapturer?
        var encoder: SSVideoEncoder?
        var injector: SSInputInjector?
    }

    private let lock = NSLock()
    private var parts = Parts()
    private var stopped = false

    private init(config: SSConfig, geometry: SSStreamGeometry) {
        self.config = config
        self.geometry = geometry
    }

    /// Installs a part unless the pipeline was already stopped. Returns false when it was (caller releases the part).
    private func install(_ update: (inout Parts) -> Void) -> Bool {
        lock.withLock {
            guard !stopped else { return false }
            update(&parts)
            return true
        }
    }

    /// Builds the display, encoder and capture. `sendConfig` is called before the first frame can flow.
    /// On any failure everything created so far is torn down before the error is rethrown.
    static func start(hello: SSHello, settings: SSStreamSettings, name: String,
                      sendConfig: @Sendable (SSConfig) -> Void,
                      sendVideo: @escaping @Sendable (SSEncodedFrame) -> Void,
                      onFailure: @escaping @Sendable (String) -> Void) async throws -> SSStreamPipeline {
        let geometry = SSStreamGeometry.make(clientWidth: hello.width, clientHeight: hello.height,
                                             densityDpi: hello.densityDpi, preset: settings.resolution)
        let fps = min(settings.frameRate.rawValue, max(hello.maxFps, 30))
        let codec = settings.codec.resolve(clientSupportsHEVC: hello.supportsHEVC)
        let config = SSConfig(codec: codec, width: geometry.pixelWidth, height: geometry.pixelHeight,
                              fps: fps, bitrate: settings.bitrate)
        let pipeline = SSStreamPipeline(config: config, geometry: geometry)

        do {
            let display = try SSVirtualDisplay(geometry: geometry, refreshRate: fps, name: name)
            guard pipeline.install({ $0.display = display }) else { throw CancellationError() }
            display.arrangeRightOfMain()

            let encoder = try SSVideoEncoder(width: geometry.pixelWidth, height: geometry.pixelHeight,
                                             hevc: codec == "hevc", fps: fps, bitrate: config.bitrate,
                                             output: sendVideo)
            guard pipeline.install({ $0.encoder = encoder }) else { throw CancellationError() }
            let injector = SSInputInjector(displayBounds: { [weak display] in display?.bounds ?? .zero })
            guard pipeline.install({ $0.injector = injector }) else { throw CancellationError() }

            sendConfig(config)

            let capturer = SSScreenCapturer(
                onFrame: { [weak encoder] buffer, pts in encoder?.encode(buffer, pts: pts) },
                onStop: { error in if let error { onFailure(error.localizedDescription) } })
            guard pipeline.install({ $0.capturer = capturer }) else { throw CancellationError() }
            try await capturer.start(displayID: display.displayID, pixelWidth: geometry.pixelWidth,
                                     pixelHeight: geometry.pixelHeight, fps: fps)
        } catch {
            await pipeline.stop()
            throw error
        }
        return pipeline
    }

    func requestKeyframe() {
        lock.withLock { stopped ? nil : parts.encoder }?.requestKeyframe()
    }

    func handle(_ input: SSInputEvent) {
        lock.withLock { stopped ? nil : parts.injector }?.handle(input)
    }

    private func takeParts() -> Parts {
        lock.withLock {
            stopped = true
            let p = parts
            parts = Parts()
            return p
        }
    }

    /// Synchronous teardown for app quit (the virtual display must not outlive the process).
    func destroyNow() {
        let p = takeParts()
        p.injector?.releaseAll()
        p.encoder?.invalidate()
        p.display?.destroy()
        if let c = p.capturer { Task { await c.stop() } }
    }

    /// Idempotent.
    func stop() async {
        let p = takeParts()
        await p.capturer?.stop()
        p.injector?.releaseAll()
        p.encoder?.invalidate()
        p.display?.destroy()
    }
}
