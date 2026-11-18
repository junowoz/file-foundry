import CryptoKit
import Network
import XCTest
@testable import FileFoundry

/// Drives the real listener on an ephemeral port with a fake v2 client.
final class SecondScreenLoopbackTests: XCTestCase {
    private func makeServer(store: SSDeviceKeyStore = SSMemoryKeyStore(), port: UInt16 = 0,
                            handlers: SSServer.Handlers = SSServer.Handlers()) async throws -> (SSServer, UInt16) {
        let srv = SSServer(port: port, keyStore: store, handlers: handlers)
        let bound: UInt16? = await withCheckedContinuation { cont in srv.start(advertise: false) { cont.resume(returning: $0) } }
        guard let bound, bound != 0 else { throw XCTSkip("Listening not available in this environment") }
        return (srv, bound)
    }

    private let config = SSConfig(codec: "hevc", width: 2560, height: 1600, fps: 60, bitrate: 40_000_000)

    func testPairAndReceiveConfig() async throws {
        let store = SSMemoryKeyStore()
        let session = SessionBox()
        let server = ServerBox()
        var handlers = SSServer.Handlers()
        handlers.onSession = { info in
            session.info = info
            server.server?.sendConfig(generation: info.generation, SSConfig(codec: "hevc", width: 2560, height: 1600, fps: 60, bitrate: 40_000_000))
        }
        let (srv, port) = try await makeServer(store: store, handlers: handlers)
        server.server = srv
        defer { srv.stop() }

        let client = TestClient(port: port)
        client.start()
        defer { client.cancel() }
        let deviceId = UUID().uuidString
        var hs = try await client.handshake(deviceId: deviceId, secret: Data(srv.currentCode.utf8), expectMode: "pair")
        XCTAssertEqual(hs.challenge.v, 2)
        XCTAssertEqual(hs.challenge.hostId, store.hostId())
        XCTAssertLessThanOrEqual(hs.challenge.hostName.utf8.count, 64)

        let welcomeFrame = try await client.nextFrame()
        XCTAssertEqual(welcomeFrame.type, SSMessageType.welcome.rawValue)
        let welcome = try JSONDecoder().decode(SSWelcome.self, from: hs.opener.open(welcomeFrame.payload, type: welcomeFrame.type))
        let deviceKey = try XCTUnwrap(welcome.deviceKey.flatMap { Data(base64Encoded: $0) })
        XCTAssertEqual(deviceKey.count, 32)
        XCTAssertEqual(store.key(for: deviceId), deviceKey)

        let configFrame = try await client.nextFrame()
        XCTAssertEqual(configFrame.type, SSMessageType.config.rawValue)
        let got = try JSONDecoder().decode(SSConfig.self, from: hs.opener.open(configFrame.payload, type: configFrame.type))
        XCTAssertEqual(got, config)
        XCTAssertEqual(session.info?.hello.name, "Test Tablet")
        XCTAssertTrue(session.info?.viaUSB ?? false, "loopback counts as USB")
        XCTAssertEqual(session.info?.generation, 1)

        // A clear BYE after WELCOME is ignored; the session keeps working.
        client.send(.bye, Data("evil".utf8))
        client.send(.ping, try hs.sealer.seal(Data(repeating: 7, count: 8), type: SSMessageType.ping.rawValue))
        var pong: Data?
        for _ in 0..<5 {
            let f = try await client.nextFrame()
            if f.type == SSMessageType.pong.rawValue { pong = try hs.opener.open(f.payload, type: f.type); break }
            if f.type == SSMessageType.ping.rawValue { _ = try hs.opener.open(f.payload, type: f.type) }
            XCTAssertNotEqual(f.type, SSMessageType.bye.rawValue, "clear BYE must be ignored")
        }
        XCTAssertEqual(pong, Data(repeating: 7, count: 8))
        // The code was single-use.
        XCTAssertNotEqual(srv.currentCode, String(decoding: hs.secret, as: UTF8.self))
    }

    func testKnownDeviceReconnectsWithStoredKey() async throws {
        let store = SSMemoryKeyStore()
        let deviceKey = try SSRandom.bytes(32)
        try store.save(key: deviceKey, deviceId: "dev-known", name: "Pixel")
        var handlers = SSServer.Handlers()
        let server = ServerBox()
        handlers.onSession = { info in server.server?.sendConfig(generation: info.generation, SSConfig(codec: "avc", width: 1280, height: 800, fps: 60, bitrate: 1)) }
        let (srv, port) = try await makeServer(store: store, handlers: handlers)
        server.server = srv
        defer { srv.stop() }
        let client = TestClient(port: port)
        client.start()
        defer { client.cancel() }
        var hs = try await client.handshake(deviceId: "dev-known", secret: deviceKey, expectMode: "known")
        let w = try await client.nextFrame()
        let welcome = try JSONDecoder().decode(SSWelcome.self, from: hs.opener.open(w.payload, type: w.type))
        XCTAssertNil(welcome.deviceKey)
        let c = try await client.nextFrame()
        XCTAssertEqual(c.type, SSMessageType.config.rawValue)
    }

    func testWrongProofIsRefusedAndBacksOff() async throws {
        let (srv, port) = try await makeServer()
        defer { srv.stop() }
        let client = TestClient(port: port)
        client.start()
        defer { client.cancel() }
        _ = try await client.handshake(deviceId: "dev", secret: Data("WRONGCODE234".utf8), expectMode: "pair")
        let reply = try await client.nextFrame()
        XCTAssertEqual(reply.type, SSMessageType.bye.rawValue)
        XCTAssertEqual(String(decoding: reply.payload, as: UTF8.self), "Authentication failed")

        // Right away, even the right code is refused without being evaluated (2 s back-off).
        let again = TestClient(port: port)
        again.start()
        defer { again.cancel() }
        _ = try await again.handshake(deviceId: "dev", secret: Data(srv.currentCode.utf8), expectMode: "pair")
        let wait = try await again.nextFrame()
        XCTAssertEqual(wait.type, SSMessageType.bye.rawValue)
        XCTAssertEqual(String(decoding: wait.payload, as: UTF8.self), "wait")
    }

    func testV1HelloGetsVersionBye() async throws {
        let (srv, port) = try await makeServer()
        defer { srv.stop() }
        let client = TestClient(port: port)
        client.start()
        defer { client.cancel() }
        let nonce = Data(repeating: 3, count: 32).base64EncodedString()
        let v1 = #"{"v":1,"deviceId":"dev","name":"X","width":1280,"height":800,"densityDpi":160,"codecs":["avc"],"maxFps":60,"clientNonce":"\#(nonce)"}"#
        client.send(.hello, Data(v1.utf8))
        let reply = try await client.nextFrame()
        XCTAssertEqual(reply.type, SSMessageType.bye.rawValue)
        XCTAssertEqual(String(decoding: reply.payload, as: UTF8.self), "version")
    }

    func testBadHelloFieldsGetHelloBye() async throws {
        let (srv, port) = try await makeServer()
        defer { srv.stop() }
        let client = TestClient(port: port)
        client.start()
        defer { client.cancel() }
        let hello = client.makeHello(deviceId: "dev", maxFps: 9999)
        client.send(.hello, try JSONEncoder().encode(hello.hello))
        let reply = try await client.nextFrame()
        XCTAssertEqual(String(decoding: reply.payload, as: UTF8.self), "hello")
    }

    func testOversizePreAuthFrameIsRejected() async throws {
        let (srv, port) = try await makeServer()
        defer { srv.stop() }
        let client = TestClient(port: port)
        client.start()
        defer { client.cancel() }
        client.sendRaw(Data([0x00, 0x00, 0x10, 0x01, 0x01]))     // length 4097, body never sent
        let reply = try await client.nextFrame()
        XCTAssertEqual(reply.type, SSMessageType.bye.rawValue)
    }

    func testPreAuthConnectionLimitPerAddress() async throws {
        let (srv, port) = try await makeServer()
        defer { srv.stop() }
        let a = TestClient(port: port), b = TestClient(port: port), c = TestClient(port: port)
        [a, b, c].forEach { $0.start() }
        defer { [a, b, c].forEach { $0.cancel() } }
        try await Task.sleep(for: .milliseconds(300))
        // Two idle handshakes per address are allowed; the third is refused with a clear BYE "busy".
        let refused = try await c.nextFrame()
        XCTAssertEqual(refused.type, SSMessageType.bye.rawValue)
        XCTAssertEqual(String(decoding: refused.payload, as: UTF8.self), "busy")
    }

    func testSecondAuthenticatedClientGetsEncryptedBusy() async throws {
        let store = SSMemoryKeyStore()
        let keyA = try SSRandom.bytes(32), keyB = try SSRandom.bytes(32)
        try store.save(key: keyA, deviceId: "A", name: "A")
        try store.save(key: keyB, deviceId: "B", name: "B")
        let ended = CounterBox()
        var handlers = SSServer.Handlers()
        handlers.onSessionEnd = { _ in ended.increment() }
        let (srv, port) = try await makeServer(store: store, handlers: handlers)
        defer { srv.stop() }

        let a = TestClient(port: port)
        a.start()
        defer { a.cancel() }
        var hsA = try await a.handshake(deviceId: "A", secret: keyA, expectMode: "known")
        _ = try await a.nextFrame()        // WELCOME

        let b = TestClient(port: port)
        b.start()
        defer { b.cancel() }
        var hsB = try await b.handshake(deviceId: "B", secret: keyB, expectMode: "known")
        let w = try await b.nextFrame()
        XCTAssertEqual(w.type, SSMessageType.welcome.rawValue)
        _ = try hsB.opener.open(w.payload, type: w.type)
        let bye = try await b.nextFrame()
        XCTAssertEqual(bye.type, SSMessageType.bye.rawValue)
        XCTAssertEqual(String(decoding: try hsB.opener.open(bye.payload, type: bye.type), as: UTF8.self), "busy")
        XCTAssertEqual(ended.value, 0, "the busy client never became the session")
        _ = hsA
    }

    func testIdleSessionEndsAfterEightSeconds() async throws {
        let store = SSMemoryKeyStore()
        let key = try SSRandom.bytes(32)
        try store.save(key: key, deviceId: "idle", name: "Idle")
        let ended = CounterBox()
        var handlers = SSServer.Handlers()
        handlers.onSessionEnd = { _ in ended.increment() }
        let (srv, port) = try await makeServer(store: store, handlers: handlers)
        defer { srv.stop() }
        let client = TestClient(port: port)
        client.start()
        defer { client.cancel() }
        var hs = try await client.handshake(deviceId: "idle", secret: key, expectMode: "known")
        let started = Date()
        var reason: String?
        while Date().timeIntervalSince(started) < 14 {
            let f = try await client.nextFrame(timeout: 14)
            if f.type == SSMessageType.bye.rawValue {
                reason = String(decoding: try hs.opener.open(f.payload, type: f.type), as: UTF8.self); break
            }
            _ = try hs.opener.open(f.payload, type: f.type)      // WELCOME / PINGs (never answered)
        }
        XCTAssertEqual(reason, "timeout")
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 7.5)
        XCTAssertEqual(ended.value, 1)
    }

    func testStopThenStartOnSamePort() async throws {
        let (first, port) = try await makeServer()
        await first.stopAndWait()
        let (second, port2) = try await makeServer(port: port)
        defer { second.stop() }
        XCTAssertEqual(port, port2)
    }
}

private final class CounterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}

private final class SessionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _info: SSSessionInfo?
    var info: SSSessionInfo? { get { lock.withLock { _info } } set { lock.withLock { _info = newValue } } }
}

private final class ServerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _s: SSServer?
    var server: SSServer? { get { lock.withLock { _s } } set { lock.withLock { _s = newValue } } }
}

private struct Handshake {
    var challenge: SSChallenge
    var secret: Data
    var opener: SSOpener
    var sealer: SSSealer
}

private final class TestClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "test.client")
    private let lock = NSLock()
    private var decoder = SSFrameDecoder(maxLength: SSProtocol.maxFrameLength)
    private var frames: [SSFrame] = []

    init(port: UInt16) {
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    }

    func start() {
        connection.start(queue: queue)
        receive()
    }

    func cancel() { connection.cancel() }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data {
                self.lock.withLock {
                    self.decoder.append(data)
                    while let f = try? self.decoder.next() { self.frames.append(f) }
                }
            }
            if error == nil && !done { self.receive() }
        }
    }

    func send(_ type: SSMessageType, _ payload: Data) {
        connection.send(content: SSFraming.encode(type, payload), completion: .contentProcessed { _ in })
    }

    func sendRaw(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    func nextFrame(timeout: TimeInterval = 5) async throws -> SSFrame {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let f = lock.withLock({ frames.isEmpty ? nil : frames.removeFirst() }) { return f }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw XCTSkip("No frame within \(timeout)s (networking may be restricted)")
    }

    struct HelloBundle {
        var hello: SSHello
        var priv: Curve25519.KeyAgreement.PrivateKey
        var nonce: Data
    }

    func makeHello(deviceId: String, maxFps: Int = 120) -> HelloBundle {
        let priv = Curve25519.KeyAgreement.PrivateKey()
        let nonce = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let hello = SSHello(v: 2, deviceId: deviceId, name: "Test Tablet", width: 2560, height: 1600, densityDpi: 276,
                            codecs: ["hevc", "avc"], maxFps: maxFps, clientNonce: nonce.base64EncodedString(),
                            clientPub: priv.publicKey.rawRepresentation.base64EncodedString())
        return HelloBundle(hello: hello, priv: priv, nonce: nonce)
    }

    /// HELLO → CHALLENGE → AUTH with `secret`. WELCOME (if any) is left in the frame queue.
    func handshake(deviceId: String, secret: Data, expectMode: String) async throws -> Handshake {
        let h = makeHello(deviceId: deviceId)
        send(.hello, try JSONEncoder().encode(h.hello))
        let frame = try await nextFrame()
        XCTAssertEqual(frame.type, SSMessageType.challenge.rawValue)
        let ch = try JSONDecoder().decode(SSChallenge.self, from: frame.payload)
        XCTAssertEqual(ch.mode, expectMode)
        let hostNonce = try XCTUnwrap(Data(base64Encoded: ch.hostNonce))
        let hostPub = try XCTUnwrap(Data(base64Encoded: ch.hostPub))
        let clientPub = h.priv.publicKey.rawRepresentation
        let shared = try SSX25519.sharedSecret(privateKey: h.priv, peerPublic: hostPub)
        let keys = SSSessionKeys(shared: shared, secret: secret, clientNonce: h.nonce, hostNonce: hostNonce,
                                 clientPub: clientPub, hostPub: hostPub)
        let proof = keys.proof(deviceId: deviceId, clientNonce: h.nonce, hostNonce: hostNonce, clientPub: clientPub, hostPub: hostPub)
        send(.auth, try JSONEncoder().encode(SSAuth(proof: proof.base64EncodedString())))
        return Handshake(challenge: ch, secret: secret, opener: SSOpener(key: keys.hostToClient), sealer: SSSealer(key: keys.clientToHost))
    }
}
