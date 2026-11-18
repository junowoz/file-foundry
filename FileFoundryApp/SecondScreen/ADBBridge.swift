import Foundation

/// Finds `adb` and keeps `adb reverse tcp:47321 tcp:47321` set up for every authorised device.
/// Polls only between `start()` and `stop()`.
final class SSADBBridge: @unchecked Sendable {
    struct Snapshot: Sendable, Equatable {
        var adbFound: Bool
        var deviceCount: Int
    }

    private let queue = DispatchQueue(label: "com.junowoz.filefoundry.secondscreen.adb", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var known: Set<String> = []
    private var adbPath: String?
    private let onChange: @Sendable (Snapshot) -> Void
    private let port: UInt16

    init(port: UInt16 = SSProtocol.port, onChange: @escaping @Sendable (Snapshot) -> Void) {
        self.port = port
        self.onChange = onChange
    }

    /// Fixed locations only, in this order. `PATH` is never consulted (a hostile directory on it could
    /// get its own `adb` run). `ANDROID_HOME` must be absolute.
    static func locateADB(environment: [String: String] = ProcessInfo.processInfo.environment,
                          home: String = NSHomeDirectory(),
                          isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        var candidates = [home + "/Library/Android/sdk/platform-tools/adb"]
        if let sdk = environment["ANDROID_HOME"], sdk.hasPrefix("/") {
            candidates.append(sdk + "/platform-tools/adb")
        }
        candidates += ["/opt/homebrew/bin/adb", "/usr/local/bin/adb"]
        return candidates.first(where: isExecutable)
    }

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            adbPath = Self.locateADB()
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: 3, leeway: .milliseconds(500))
            t.setEventHandler { [weak self] in self?.poll() }
            timer = t
            t.resume()
        }
    }

    /// Synchronous: the reverses are gone when this returns (also used on app quit).
    func stop() {
        queue.sync {
            timer?.cancel(); timer = nil
            if let adb = adbPath {
                for serial in known { _ = Self.run(adb, ["-s", serial, "reverse", "--remove", "tcp:\(port)"], timeout: 2) }
            }
            known = []
        }
    }

    private func poll() {
        if adbPath == nil { adbPath = Self.locateADB() }
        guard let adb = adbPath else { onChange(Snapshot(adbFound: false, deviceCount: 0)); return }
        guard let out = Self.run(adb, ["devices"]) else { return }
        let current = Self.parseDevices(out)
        known.formIntersection(current)       // unplugged devices lose their reverse with the device
        let spec = "tcp:\(port)"
        for serial in current {
            if known.contains(serial) {
                // Re-apply when the reverse vanished (adb server restart, device reboot between polls).
                if let list = Self.run(adb, ["-s", serial, "reverse", "--list"]), list.contains(spec) { continue }
                known.remove(serial)
            }
            // Only a successful `reverse` counts; a failure is retried on the next poll.
            if Self.run(adb, ["-s", serial, "reverse", spec, spec]) != nil { known.insert(serial) }
        }
        onChange(Snapshot(adbFound: true, deviceCount: current.count))
    }

    /// Serials in state `device` (skips `unauthorized`, `offline`, header and daemon chatter).
    static func parseDevices(_ output: String) -> Set<String> {
        var result: Set<String> = []
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            if parts.count >= 2, parts[1] == "device" { result.insert(String(parts[0])) }
        }
        return result
    }

    /// Runs a tool with an argument vector (no shell). Returns stdout, nil on failure or timeout.
    private static func run(_ path: String, _ args: [String], timeout: TimeInterval = 5) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
