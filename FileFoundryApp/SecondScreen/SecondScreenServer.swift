import CryptoKit
import Foundation
import Network

struct SSSessionInfo: Sendable {
    var hello: SSHello
    var viaUSB: Bool
    /// Increases with every streaming session; late callbacks of an older session are ignored by comparing it.
    var generation: UInt64
}

struct SSHostStats: Sendable, Equatable {
    var sentFps: Double = 0
    var bitrate: Double = 0       // bits per second
    var rttMs: Double = 0         // PING/PONG round trip
    var clientFps: Double = 0
    var clientDropped: Int = 0
    var clientLatencyMs: Double = 0
    var droppedFrames: Int = 0
}

/// NWListener + per-connection protocol state machines (v2). All state lives on `queue`.
///
/// Up to `maxPreAuthConnections` connections may sit in the handshake at once (max 2 per remote address),
/// each with its own 5 s deadline. Only one connection streams; an authenticated second client gets an
/// encrypted `BYE "busy"`.
final class SSServer: @unchecked Sendable {
    struct Handlers: Sendable {
        var onListening: @Sendable (Bool, String?) -> Void = { _, _ in }
        var onPairingCode: @Sendable (String, Date) -> Void = { _, _ in }
        /// Authenticated client; the handler must call `sendConfig(generation:_:)`.
        var onSession: @Sendable (SSSessionInfo) -> Void = { _ in }
        var onSessionEnd: @Sendable (UInt64) -> Void = { _ in }
        var onKeyframeRequest: @Sendable (UInt64) -> Void = { _ in }
        var onInput: @Sendable (UInt64, SSInputEvent) -> Void = { _, _ in }
        var onStats: @Sendable (UInt64, SSHostStats) -> Void = { _, _ in }
        var onPaired: @Sendable () -> Void = {}
    }

    private struct Pending {
        var hello: SSHello
        var clientNonce: Data
        var hostNonce: Data
        var clientPub: Data
        var hostPub: Data
        var shared: Data
        var pairing: Bool
        var codeAtChallenge: String
    }

    private enum Phase {
        case awaitingHello
        case awaitingAuth(Pending)
        case streaming
    }

    private final class Conn: @unchecked Sendable {
        let connection: NWConnection
        let remote: String
        let viaUSB: Bool
        var phase: Phase = .awaitingHello
        var decoder = SSFrameDecoder()
        var sealer: SSSealer?
        var opener: SSOpener?
        var deadline: DispatchSourceTimer?
        var tick: DispatchSourceTimer?
        var closed = false
        var lastInbound = ProcessInfo.processInfo.systemUptime
        var hello: SSHello?
        var generation: UInt64 = 0
        // back-pressure + stats (active session only)
        var inflight = 0
        var waitingForKeyframe = false
        var framesSent = 0
        var bytesSent = 0
        var droppedTotal = 0
        var lastTick = Date()
        var stats = SSHostStats()
        var lastKeyRequest = Date.distantPast
        var pendingKeyRequest = false

        init(_ c: NWConnection, remote: String, viaUSB: Bool) {
            connection = c; self.remote = remote; self.viaUSB = viaUSB
        }

        var isStreaming: Bool { if case .streaming = phase { true } else { false } }
    }

    static let keyframeRequestInterval: TimeInterval = 0.5   // 2 per second

    private let queue = DispatchQueue(label: "com.junowoz.filefoundry.secondscreen.net", qos: .userInteractive)
    private let keyStore: SSDeviceKeyStore
    private let port: UInt16
    private var handlers: Handlers

    private var listener: NWListener?
    private var conns: [ObjectIdentifier: Conn] = [:]
    private var active: Conn?
    private var generationCounter: UInt64 = 0
    private var pairing = SSPairingState()
    private var pairingTimer: DispatchSourceTimer?
    private var hostId = ""
    private var hostName = "Mac"

    init(port: UInt16 = SSProtocol.port, keyStore: SSDeviceKeyStore, handlers: Handlers) {
        self.port = port
        self.keyStore = keyStore
        self.handlers = handlers
    }

    // MARK: Lifecycle

    /// `port` 0 asks the system for an ephemeral port (tests).
    func start(advertise: Bool = true, completion: (@Sendable (UInt16?) -> Void)? = nil) {
        queue.async { [self] in
            guard listener == nil else { completion?(listener?.port?.rawValue); return }
            hostId = keyStore.hostId()
            hostName = (Host.current().localizedName ?? "Mac").truncatedUTF8(maxBytes: SSProtocol.maxNameBytes)
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 10
            let params = NWParameters(tls: nil, tcp: tcp)
            params.allowLocalEndpointReuse = true
            do {
                let l = try NWListener(using: params, on: port == 0 ? .any : NWEndpoint.Port(rawValue: port)!)
                if advertise {
                    var txt = NWTXTRecord()
                    txt["v"] = "\(SSProtocol.version)"
                    txt["name"] = hostName
                    txt["id"] = hostId
                    l.service = NWListener.Service(name: hostName, type: SSProtocol.bonjourType, txtRecord: txt)
                }
                l.newConnectionHandler = { [weak self] c in self?.accept(c) }
                l.stateUpdateHandler = { [weak self, weak l] state in
                    guard let self, let l, self.listener === l else { return }
                    switch state {
                    case .ready:
                        self.handlers.onListening(true, nil)
                        completion?(l.port?.rawValue)
                    case .failed(let error):
                        self.handlers.onListening(false, "Port \(self.port == 0 ? SSProtocol.port : self.port) unavailable: \(error)")
                        completion?(nil)
                        self.stopLocked(completion: nil)
                    default: break
                    }
                }
                listener = l
                rotatePairing()
                l.start(queue: queue)
            } catch {
                handlers.onListening(false, "Could not listen: \(error)")
                completion?(nil)
            }
        }
    }

    /// Closes every connection and the listener. `completion` runs once the listener is really cancelled,
    /// so a following `start` on the same port can bind.
    func stop(completion: (@Sendable () -> Void)? = nil) {
        queue.async { [self] in stopLocked(completion: completion) }
    }

    func stopAndWait() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in stop { cont.resume() } }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        private let body: @Sendable () -> Void
        init(_ body: @escaping @Sendable () -> Void) { self.body = body }
        func fire() {
            let go = lock.withLock { () -> Bool in if fired { return false }; fired = true; return true }
            if go { body() }
        }
    }

    private func stopLocked(completion: (@Sendable () -> Void)?) {
        for conn in Array(conns.values) { close(conn, reason: "Host stopped") }
        pairingTimer?.cancel(); pairingTimer = nil
        guard let l = listener else { completion?(); return }
        listener = nil
        let once = Once { completion?() }
        l.stateUpdateHandler = { state in if case .cancelled = state { once.fire() } }
        l.newConnectionHandler = { $0.cancel() }
        l.cancel()
        queue.asyncAfter(deadline: .now() + 2) { once.fire() }
    }

    func regenerateCode() { queue.async { [self] in rotatePairing() } }

    private func rotatePairing() {
        pairing.regenerate()
        handlers.onPairingCode(pairing.code, pairing.expiresAt)
        pairingTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + SSPairingCode.lifetime)
        t.setEventHandler { [weak self] in self?.rotatePairing() }
        pairingTimer = t
        t.resume()
    }

    /// Test hook: current code.
    var currentCode: String { queue.sync { pairing.code } }

    // MARK: Accept

    private static func remoteKey(_ endpoint: NWEndpoint) -> String {
        if case .hostPort(let host, _) = endpoint {
            let text = "\(host)"
            return String(text.split(separator: "%").first ?? Substring(text))
        }
        return "\(endpoint)"
    }

    private func accept(_ c: NWConnection) {
        let remote = Self.remoteKey(c.endpoint)
        let preAuth = conns.values.filter { !$0.isStreaming }
        if preAuth.count >= SSProtocol.maxPreAuthConnections
            || preAuth.filter({ $0.remote == remote }).count >= SSProtocol.maxPreAuthPerAddress {
            c.start(queue: queue)
            c.send(content: SSFraming.encode(.bye, Data("busy".utf8)), completion: .contentProcessed { _ in c.cancel() })
            return
        }
        let conn = Conn(c, remote: remote, viaUSB: Self.isLoopback(c.endpoint))
        conn.decoder = SSFrameDecoder()      // pre-auth cap
        conns[ObjectIdentifier(conn)] = conn

        c.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed, .cancelled: self.close(conn, reason: nil)
            default: break
            }
        }
        c.start(queue: queue)
        receive(conn)

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + SSProtocol.authTimeout)
        t.setEventHandler { [weak self] in
            guard let self, !conn.isStreaming else { return }
            self.close(conn, reason: "Authentication timed out")
        }
        conn.deadline = t
        t.resume()
    }

    static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        if case .hostPort(let host, _) = endpoint {
            switch host {
            case .ipv4(let a): return a.isLoopback
            case .ipv6(let a): return a.isLoopback
            default: return false
            }
        }
        return false
    }

    private func receive(_ conn: Conn) {
        // Before AUTH nothing larger than a handshake frame is read at once.
        let maxRead = conn.isStreaming ? 256 * 1024 : 8 * 1024
        conn.connection.receive(minimumIncompleteLength: 1, maximumLength: maxRead) { [weak self] data, _, isComplete, error in
            guard let self, !conn.closed else { return }
            if let data, !data.isEmpty {
                conn.lastInbound = ProcessInfo.processInfo.systemUptime
                conn.decoder.append(data)
                do {
                    while let frame = try conn.decoder.next() {
                        self.handle(conn, frame)
                        if conn.closed { return }
                    }
                } catch {
                    self.close(conn, reason: "Protocol error")
                    return
                }
            }
            if error != nil || isComplete {
                self.close(conn, reason: nil)
            } else {
                self.receive(conn)
            }
        }
    }

    // MARK: State machine

    private func handle(_ conn: Conn, _ frame: SSFrame) {
        switch conn.phase {
        case .awaitingHello:
            handleHello(conn, frame)
        case .awaitingAuth(let pending):
            handleAuth(conn, frame, pending)
        case .streaming:
            guard var opener = conn.opener else { close(conn, reason: nil); return }
            let plain: Data
            do { plain = try opener.open(frame.payload, type: frame.type) } catch {
                // A clear (or forged) BYE is ignored once WELCOME was sent; anything else must decrypt.
                if frame.type == SSMessageType.bye.rawValue { return }
                close(conn, reason: "Decryption failed"); return
            }
            conn.opener = opener
            if frame.type == SSMessageType.bye.rawValue { close(conn, reason: nil); return }
            handleDecrypted(conn, type: frame.type, plain: plain)
        }
    }

    private func handleHello(_ conn: Conn, _ frame: SSFrame) {
        guard frame.type == SSMessageType.hello.rawValue,
              let version = try? JSONDecoder().decode(SSHelloVersion.self, from: frame.payload) else {
            close(conn, reason: "hello"); return
        }
        guard version.v == SSProtocol.version else { close(conn, reason: "version"); return }
        guard let decoded = try? JSONDecoder().decode(SSHello.self, from: frame.payload), decoded.isValid,
              let clientNonce = decoded.clientNonceData, let clientPub = decoded.clientPubData else {
            close(conn, reason: "hello"); return
        }
        let hello = decoded.normalized()
        let hostNonce: Data
        let shared: Data
        let hostPriv = Curve25519.KeyAgreement.PrivateKey()
        do {
            hostNonce = try SSRandom.bytes(32)
            shared = try SSX25519.sharedSecret(privateKey: hostPriv, peerPublic: clientPub)
        } catch SSCryptoError.randomFailed {
            close(conn, reason: "error"); return
        } catch {
            close(conn, reason: "hello"); return
        }
        let pairingMode = keyStore.key(for: hello.deviceId) == nil
        if pairingMode, pairing.isExpired() { rotatePairing() }
        let hostPub = hostPriv.publicKey.rawRepresentation
        conn.hello = hello
        conn.phase = .awaitingAuth(Pending(hello: hello, clientNonce: clientNonce, hostNonce: hostNonce,
                                           clientPub: clientPub, hostPub: hostPub, shared: shared,
                                           pairing: pairingMode, codeAtChallenge: pairing.code))
        sendClear(conn, .challenge, json: SSChallenge(v: SSProtocol.version, hostNonce: hostNonce.base64EncodedString(),
                                                      hostPub: hostPub.base64EncodedString(), hostId: hostId,
                                                      hostName: hostName, mode: pairingMode ? "pair" : "known"))
    }

    private func handleAuth(_ conn: Conn, _ frame: SSFrame, _ p: Pending) {
        guard frame.type == SSMessageType.auth.rawValue,
              let auth = try? JSONDecoder().decode(SSAuth.self, from: frame.payload),
              let proof = Data(base64Encoded: auth.proof) else {
            close(conn, reason: "Bad AUTH"); return
        }
        // The secret is read now, from the live code / stored key, never from a snapshot taken at HELLO.
        let secret: Data
        if p.pairing {
            if pairing.isBlocked() { close(conn, reason: "wait"); return }
            if pairing.isExpired() { rotatePairing(); close(conn, reason: "expired"); return }
            guard pairing.code == p.codeAtChallenge else { close(conn, reason: "expired"); return }
            secret = Data(pairing.code.utf8)
        } else {
            guard let key = keyStore.key(for: p.hello.deviceId) else { close(conn, reason: "Authentication failed"); return }
            secret = key
        }
        let keys = SSSessionKeys(shared: p.shared, secret: secret, clientNonce: p.clientNonce, hostNonce: p.hostNonce,
                                 clientPub: p.clientPub, hostPub: p.hostPub)
        guard keys.verify(proof: proof, deviceId: p.hello.deviceId, clientNonce: p.clientNonce, hostNonce: p.hostNonce,
                          clientPub: p.clientPub, hostPub: p.hostPub) else {
            if p.pairing, pairing.registerFailure() { rotatePairing() }
            close(conn, reason: "Authentication failed"); return
        }

        var welcome = SSWelcome(deviceKey: nil)
        if p.pairing {
            do {
                let key = try SSRandom.bytes(32)
                try keyStore.save(key: key, deviceId: p.hello.deviceId, name: p.hello.name)
                welcome.deviceKey = key.base64EncodedString()
            } catch {
                close(conn, reason: "Could not store pairing key"); return
            }
            pairing.registerSuccess()
            rotatePairing()    // codes are single-use
            handlers.onPaired()
        }

        conn.sealer = SSSealer(key: keys.hostToClient)
        conn.opener = SSOpener(key: keys.clientToHost)
        conn.deadline?.cancel(); conn.deadline = nil
        conn.decoder.maxLength = SSProtocol.maxFrameLength
        sendEncrypted(conn, .welcome, json: welcome)
        conn.phase = .streaming
        conn.lastInbound = ProcessInfo.processInfo.systemUptime

        if active != nil {
            close(conn, reason: "busy"); return
        }
        generationCounter += 1
        conn.generation = generationCounter
        active = conn
        startTick(conn)
        handlers.onSession(SSSessionInfo(hello: p.hello, viaUSB: conn.viaUSB, generation: conn.generation))
    }

    private func handleDecrypted(_ conn: Conn, type: UInt8, plain: Data) {
        guard conn === active else { return }
        switch SSMessageType(rawValue: type) {
        case .input:
            if let e = SSInputEvent(decoding: plain) { handlers.onInput(conn.generation, e) }
        case .keyframeRequest:
            requestKeyframe(conn)
        case .ping:
            sendEncryptedRaw(conn, .pong, plain)
        case .pong:
            if plain.count == 8 {
                let sent = plain.readU64BE(at: plain.startIndex)
                let now = Self.nowMicros()
                if now >= sent { conn.stats.rttMs = Double(now - sent) / 1000 }
            }
        case .stats:
            if let s = try? JSONDecoder().decode(SSClientStats.self, from: plain) {
                conn.stats.clientFps = s.decodedFps; conn.stats.clientDropped = s.dropped; conn.stats.clientLatencyMs = s.latencyMs
            }
        default: break
        }
    }

    /// At most 2 per second; a request inside the window is remembered and honoured on the next tick.
    private func requestKeyframe(_ conn: Conn) {
        let now = Date()
        guard now.timeIntervalSince(conn.lastKeyRequest) >= Self.keyframeRequestInterval else {
            conn.pendingKeyRequest = true
            return
        }
        conn.lastKeyRequest = now
        conn.pendingKeyRequest = false
        handlers.onKeyframeRequest(conn.generation)
    }

    // MARK: Sending

    /// Called after the pipeline is ready. Must precede the first video frame.
    func sendConfig(generation: UInt64, _ config: SSConfig) {
        queue.async { [self] in
            guard let conn = active, conn.generation == generation else { return }
            conn.waitingForKeyframe = true     // first VIDEO must be a keyframe
            sendEncrypted(conn, .config, json: config)
        }
    }

    /// Entry point for encoder output (any thread). Frames of a finished session are dropped.
    func sendVideo(generation: UInt64, _ frame: SSEncodedFrame) {
        queue.async { [self] in
            guard let conn = active, conn.generation == generation, conn.sealer != nil else { return }
            if !frame.isKeyframe {
                if conn.waitingForKeyframe || conn.inflight > 3 {
                    conn.droppedTotal += 1
                    conn.waitingForKeyframe = true
                    requestKeyframe(conn)
                    return
                }
            } else {
                conn.waitingForKeyframe = false
            }
            var flags: SSVideoFlags = []
            if frame.isKeyframe { flags.insert(.keyframe) }
            if frame.hasCodecConfig { flags.insert(.codecConfig) }
            let plain = SSVideoPacket.encode(ptsMicros: frame.ptsMicros, flags: flags, annexB: frame.annexB)
            guard let sealed = try? conn.sealer?.seal(plain, type: SSMessageType.video.rawValue) else { return }
            conn.inflight += 1
            conn.framesSent += 1
            conn.bytesSent += sealed.count
            conn.connection.send(content: SSFraming.encode(.video, sealed), completion: .contentProcessed { [weak self] _ in
                guard let self else { return }
                self.queue.async { conn.inflight -= 1 }
            })
        }
    }

    private func sendClear<T: Encodable>(_ conn: Conn, _ type: SSMessageType, json: T) {
        guard let data = try? JSONEncoder().encode(json) else { return }
        conn.connection.send(content: SSFraming.encode(type, data), completion: .contentProcessed { _ in })
    }

    private func sendEncrypted<T: Encodable>(_ conn: Conn, _ type: SSMessageType, json: T) {
        guard let data = try? JSONEncoder().encode(json) else { return }
        sendEncryptedRaw(conn, type, data)
    }

    private func sendEncryptedRaw(_ conn: Conn, _ type: SSMessageType, _ plain: Data) {
        guard let sealed = try? conn.sealer?.seal(plain, type: type.rawValue) else { return }
        conn.connection.send(content: SSFraming.encode(type, sealed), completion: .contentProcessed { _ in })
    }

    static func nowMicros() -> UInt64 { UInt64(DispatchTime.now().uptimeNanoseconds / 1000) }

    // MARK: Per-second tick (active session only): watchdog, PING, stats

    private func startTick(_ conn: Conn) {
        conn.lastTick = Date()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in
            guard let self, !conn.closed, conn === self.active else { return }
            if ProcessInfo.processInfo.systemUptime - conn.lastInbound > SSProtocol.idleTimeout {
                self.close(conn, reason: "timeout"); return
            }
            let now = Date(); let dt = max(now.timeIntervalSince(conn.lastTick), 0.001)
            conn.stats.sentFps = Double(conn.framesSent) / dt
            conn.stats.bitrate = Double(conn.bytesSent) * 8 / dt
            conn.stats.droppedFrames = conn.droppedTotal
            conn.framesSent = 0; conn.bytesSent = 0; conn.lastTick = now
            var ping = Data(); ping.appendBE(Self.nowMicros())
            self.sendEncryptedRaw(conn, .ping, ping)
            if conn.pendingKeyRequest { self.requestKeyframe(conn) }
            self.handlers.onStats(conn.generation, conn.stats)
        }
        conn.tick = t
        t.resume()
    }

    // MARK: Teardown

    /// `reason` nil: just cancel. Otherwise a BYE (encrypted once WELCOME was sent) goes out first.
    private func close(_ conn: Conn, reason: String?) {
        guard !conn.closed else { return }
        conn.closed = true
        conns[ObjectIdentifier(conn)] = nil
        conn.deadline?.cancel(); conn.deadline = nil
        conn.tick?.cancel(); conn.tick = nil
        let c = conn.connection
        if let reason {
            let payload = Data(reason.utf8)
            if conn.isStreaming, let sealed = try? conn.sealer?.seal(payload, type: SSMessageType.bye.rawValue) {
                c.send(content: SSFraming.encode(.bye, sealed), completion: .contentProcessed { _ in c.cancel() })
            } else {
                c.send(content: SSFraming.encode(.bye, payload), completion: .contentProcessed { _ in c.cancel() })
            }
        } else {
            c.cancel()
        }
        conn.sealer = nil; conn.opener = nil
        if active === conn {
            active = nil
            handlers.onSessionEnd(conn.generation)
        }
    }
}
