import CryptoKit
import XCTest
@testable import FileFoundry

final class SecondScreenFramingTests: XCTestCase {
    func testEncodeLayout() {
        let d = SSFraming.encode(.keyframeRequest)
        XCTAssertEqual(d.hexString, "000000010" + "8")
        let d2 = SSFraming.encode(type: 0x05, payload: Data([1, 2, 3]))
        XCTAssertEqual(d2.hexString, "00000004" + "05" + "010203")
    }

    func testDecodeAcrossArbitraryChunks() throws {
        let a = SSFraming.encode(.ping, Data(repeating: 7, count: 8))
        let b = SSFraming.encode(.bye, Data("x".utf8))
        let all = a + b
        var dec = SSFrameDecoder()
        var frames: [SSFrame] = []
        for byte in all {
            dec.append(Data([byte]))
            while let f = try dec.next() { frames.append(f) }
        }
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0], SSFrame(type: 0x09, payload: Data(repeating: 7, count: 8)))
        XCTAssertEqual(frames[1].type, 0x0F)
        XCTAssertEqual(dec.bufferedByteCount, 0)
    }

    func testRejectsOversizeAndZeroLength() {
        var big = SSFrameDecoder(maxLength: SSProtocol.maxFrameLength)
        big.append(Data([0x00, 0x80, 0x00, 0x01, 0x06]))   // 8 MiB + 1
        XCTAssertThrowsError(try big.next())
        var zero = SSFrameDecoder(maxLength: SSProtocol.maxFrameLength)
        zero.append(Data([0, 0, 0, 0]))
        XCTAssertThrowsError(try zero.next())
        var max = SSFrameDecoder(maxLength: SSProtocol.maxFrameLength)
        max.append(Data([0x00, 0x80, 0x00, 0x00, 0x06]))   // exactly 8 MiB: accepted, waits for body
        XCTAssertNil(try max.next())
    }

    func testVideoPacketRoundTrip() throws {
        let p = SSVideoPacket.encode(ptsMicros: 0x0102030405060708, flags: [.keyframe, .codecConfig], annexB: Data([0, 0, 0, 1, 0x65]))
        XCTAssertEqual(p.prefix(9).hexString, "0102030405060708" + "03")
        let d = try XCTUnwrap(SSVideoPacket.decode(p))
        XCTAssertEqual(d.ptsMicros, 0x0102030405060708)
        XCTAssertEqual(d.flags, [.keyframe, .codecConfig])
        XCTAssertEqual(d.annexB, Data([0, 0, 0, 1, 0x65]))
        XCTAssertNil(SSVideoPacket.decode(Data(count: 8)))
    }

    func testHelloValidationAndJSON() throws {
        let nonce = Data(repeating: 1, count: 32).base64EncodedString()
        let pub = Data(repeating: 2, count: 32).base64EncodedString()
        let json = #"{"v":2,"deviceId":"abc","name":"Pixel Tablet","width":2560,"height":1600,"densityDpi":276,"codecs":["hevc","avc"],"maxFps":120,"clientNonce":"\#(nonce)","clientPub":"\#(pub)"}"#
        let hello = try JSONDecoder().decode(SSHello.self, from: Data(json.utf8))
        XCTAssertTrue(hello.isValid)
        XCTAssertTrue(hello.supportsHEVC)
        func mutated(_ f: (inout SSHello) -> Void) -> SSHello { var h = hello; f(&h); return h }
        XCTAssertFalse(mutated { $0.clientNonce = "AAAA" }.isValid)
        XCTAssertFalse(mutated { $0.clientPub = "AAAA" }.isValid)
        XCTAssertFalse(mutated { $0.v = 1 }.isValid)
        XCTAssertFalse(mutated { $0.codecs = ["vp9"] }.isValid)
        XCTAssertFalse(mutated { $0.codecs = Array(repeating: "avc", count: 9) }.isValid)
        XCTAssertFalse(mutated { $0.maxFps = 0 }.isValid)
        XCTAssertFalse(mutated { $0.maxFps = 241 }.isValid)
        XCTAssertFalse(mutated { $0.width = 319 }.isValid)
        XCTAssertFalse(mutated { $0.height = 8193 }.isValid)
        XCTAssertFalse(mutated { $0.densityDpi = 71 }.isValid)
        XCTAssertFalse(mutated { $0.densityDpi = 1001 }.isValid)
        XCTAssertFalse(mutated { $0.deviceId = "host-id" }.isValid)
        XCTAssertTrue(mutated { $0.name = String(repeating: "x", count: 500) }.isValid, "long names are truncated, not rejected")
        let long = mutated { $0.name = String(repeating: "é", count: 100) }.normalized()
        XCTAssertLessThanOrEqual(long.name.utf8.count, 64)
        XCTAssertEqual(long.name.utf8.count, 64)
    }

    func testPreAuthFrameCapIsEnforcedBeforeAllocation() throws {
        var dec = SSFrameDecoder()
        dec.append(Data([0x00, 0x00, 0x10, 0x01, 0x01]))     // 4097 > 4 KiB: rejected from the header alone
        XCTAssertThrowsError(try dec.next())
        var ok = SSFrameDecoder()
        ok.append(Data([0x00, 0x00, 0x10, 0x00, 0x01]))      // exactly 4096: waits for the body
        XCTAssertNil(try ok.next())
        ok.maxLength = SSProtocol.maxFrameLength
        var big = SSFrameDecoder(maxLength: SSProtocol.maxFrameLength)
        big.append(Data([0x00, 0x00, 0x10, 0x01, 0x06]))
        XCTAssertNil(try big.next())
    }

    func testTruncatedUTF8() {
        XCTAssertEqual("abc".truncatedUTF8(maxBytes: 2), "ab")
        XCTAssertEqual("aé".truncatedUTF8(maxBytes: 2), "a")
        XCTAssertEqual("aé".truncatedUTF8(maxBytes: 3), "aé")
    }
}

final class SecondScreenInputTests: XCTestCase {
    func testRoundTripBigEndian() throws {
        let e = SSInputEvent(kind: .scroll, pointerId: 2, x: 0.25, y: 0.5, dx: -3, dy: 12)
        let data = e.encoded()
        XCTAssertEqual(data.count, 18)
        XCTAssertEqual(data.prefix(6).hexString, "0302" + "3e800000")
        XCTAssertEqual(SSInputEvent(decoding: data), e)
        XCTAssertNil(SSInputEvent(decoding: data.dropLast()))
        var badKind = data; badKind[badKind.startIndex] = 9
        XCTAssertNil(SSInputEvent(decoding: badKind))
    }

    func testClampingStaysInsideBounds() {
        let b = CGRect(x: 1512, y: 0, width: 1280, height: 800)
        XCTAssertEqual(SSInputMapper.point(x: -5, y: 9, in: b), CGPoint(x: 1512, y: 799))
        XCTAssertEqual(SSInputMapper.point(x: 2, y: -1, in: b), CGPoint(x: 1512 + 1279, y: 0))
        XCTAssertEqual(SSInputMapper.point(x: .nan, y: .infinity, in: b), CGPoint(x: 1512, y: 799))
        XCTAssertEqual(SSInputMapper.point(x: 0.5, y: 0.5, in: b).x, 1512 + 639.5, accuracy: 0.001)
        XCTAssertEqual(SSInputMapper.scroll(.nan), 0)
        XCTAssertEqual(SSInputMapper.scroll(1e9), 2000)
        XCTAssertEqual(SSInputMapper.scroll(-5.9), -5)
    }
}

final class SecondScreenSettingsTests: XCTestCase {
    func testBitratePresets() {
        XCTAssertEqual(SSQualityPreset.battery.bitrate(customMbps: 99), 15_000_000)
        XCTAssertEqual(SSQualityPreset.balanced.bitrate(customMbps: 99), 40_000_000)
        XCTAssertEqual(SSQualityPreset.quality.bitrate(customMbps: 99), 80_000_000)
        XCTAssertEqual(SSQualityPreset.custom.bitrate(customMbps: 25), 25_000_000)
        XCTAssertEqual(SSQualityPreset.custom.bitrate(customMbps: 0), 2_000_000)
        XCTAssertEqual(SSQualityPreset.custom.bitrate(customMbps: 5000), 200_000_000)
    }

    func testCodecResolution() {
        XCTAssertEqual(SSCodecPreference.auto.resolve(clientSupportsHEVC: true), "hevc")
        XCTAssertEqual(SSCodecPreference.auto.resolve(clientSupportsHEVC: false), "avc")
        XCTAssertEqual(SSCodecPreference.hevc.resolve(clientSupportsHEVC: false), "avc")
        XCTAssertEqual(SSCodecPreference.h264.resolve(clientSupportsHEVC: true), "avc")
    }

    func testGeometry() {
        let tablet = SSStreamGeometry.make(clientWidth: 2560, clientHeight: 1600, densityDpi: 276, preset: .matchTablet)
        XCTAssertEqual(tablet, SSStreamGeometry(pixelWidth: 2560, pixelHeight: 1600, hiDPI: true))
        XCTAssertEqual(tablet.pointWidth, 1280)
        let hd = SSStreamGeometry.make(clientWidth: 2560, clientHeight: 1600, densityDpi: 276, preset: .p1080)
        XCTAssertEqual(hd.pixelWidth, 1920)
        XCTAssertEqual(hd.pixelHeight, 1200)
        let portrait = SSStreamGeometry.make(clientWidth: 1200, clientHeight: 1920, densityDpi: 160, preset: .p1440)
        XCTAssertEqual(portrait.pixelWidth, 1200)           // below cap: unchanged
        XCTAssertFalse(portrait.hiDPI)
        let huge = SSStreamGeometry.make(clientWidth: 7680, clientHeight: 4320, densityDpi: 300, preset: .p2160)
        XCTAssertEqual(huge.pixelWidth, 3840)
        XCTAssertEqual(huge.pixelHeight % 8, 0)
    }
}

final class SecondScreenPairingTests: XCTestCase {
    func testAlphabetAndLength() {
        XCTAssertEqual(SSPairingCode.alphabet.count, 31)
        XCTAssertEqual(String(SSPairingCode.alphabet), "23456789ABCDEFGHJKMNPQRSTUVWXYZ")
        for _ in 0..<500 {
            let c = SSPairingCode.generate()
            XCTAssertEqual(c.count, 12)
            XCTAssertTrue(SSPairingCode.isValid(c), c)
        }
        XCTAssertFalse(SSPairingCode.isValid("ABCD2345EFGO"))   // O is not in the alphabet
        XCTAssertFalse(SSPairingCode.isValid("ABCD2345"))       // v1 length
        XCTAssertEqual(SSPairingCode.display("ABCD2345EFGH"), "ABCD-2345-EFGH")
    }

    func testCodesDiffer() {
        XCTAssertEqual(Set((0..<50).map { _ in SSPairingCode.generate() }).count, 50)
    }

    func testAttemptsAndExpiry() {
        let t0 = Date(timeIntervalSince1970: 1000)
        var s = SSPairingState(code: "ABCD2345EFGH", now: t0)
        XCTAssertFalse(s.isExpired(now: t0.addingTimeInterval(119)))
        XCTAssertTrue(s.isExpired(now: t0.addingTimeInterval(120)))
        for _ in 0..<4 { XCTAssertFalse(s.registerFailure(now: t0)) }
        XCTAssertTrue(s.registerFailure(now: t0))
        s.regenerate(now: t0)
        XCTAssertEqual(s.failedAttempts, 0)
        XCTAssertEqual(s.consecutiveFailures, 5, "rotating the code must not reset the back-off")
    }

    func testBackoffDoublesAndCapsAtSixtySeconds() {
        XCTAssertEqual((1...8).map { SSPairingState.backoff(afterFailures: $0) }, [2, 4, 8, 16, 32, 60, 60, 60])
        let t0 = Date(timeIntervalSince1970: 5000)
        var s = SSPairingState(code: "ABCD2345EFGH", now: t0)
        XCTAssertFalse(s.isBlocked(now: t0))
        _ = s.registerFailure(now: t0)
        XCTAssertTrue(s.isBlocked(now: t0.addingTimeInterval(1.9)))
        XCTAssertFalse(s.isBlocked(now: t0.addingTimeInterval(2)))
        _ = s.registerFailure(now: t0)
        XCTAssertTrue(s.isBlocked(now: t0.addingTimeInterval(3.9)))
        s.registerSuccess()
        XCTAssertFalse(s.isBlocked(now: t0))
        XCTAssertEqual(s.consecutiveFailures, 0)
    }

    func testMemoryStore() throws {
        let store = SSMemoryKeyStore()
        try store.save(key: Data([1, 2, 3]), deviceId: "d1", name: "Pixel")
        XCTAssertEqual(store.key(for: "d1"), Data([1, 2, 3]))
        XCTAssertEqual(store.devices().map(\.name), ["Pixel"])
        store.forget(deviceId: "d1")
        XCTAssertNil(store.key(for: "d1"))
    }

    func testAdbLocationOrderIgnoresPath() {
        let home = "/Users/x"
        let all: (String) -> Bool = { _ in true }
        XCTAssertEqual(SSADBBridge.locateADB(environment: ["ANDROID_HOME": "/sdk", "PATH": "/evil"], home: home, isExecutable: all),
                       "/Users/x/Library/Android/sdk/platform-tools/adb")
        XCTAssertEqual(SSADBBridge.locateADB(environment: ["ANDROID_HOME": "/sdk"], home: home,
                                             isExecutable: { $0 == "/sdk/platform-tools/adb" || $0 == "/opt/homebrew/bin/adb" }),
                       "/sdk/platform-tools/adb")
        XCTAssertEqual(SSADBBridge.locateADB(environment: ["ANDROID_HOME": "relative/sdk"], home: home,
                                             isExecutable: { $0 == "/usr/local/bin/adb" || $0 == "relative/sdk/platform-tools/adb" }),
                       "/usr/local/bin/adb")
        XCTAssertEqual(SSADBBridge.locateADB(environment: [:], home: home, isExecutable: { $0 == "/opt/homebrew/bin/adb" }), "/opt/homebrew/bin/adb")
        XCTAssertNil(SSADBBridge.locateADB(environment: ["PATH": "/evil"], home: home, isExecutable: { $0 == "/evil/adb" }))
    }

    func testAdbParsing() {
        let out = """
        List of devices attached
        * daemon started successfully
        R52T1234ABC\tdevice
        emulator-5554\toffline
        ZX1\tunauthorized
        192.168.1.5:5555\tdevice

        """
        XCTAssertEqual(SSADBBridge.parseDevices(out), ["R52T1234ABC", "192.168.1.5:5555"])
    }
}

final class SecondScreenCryptoTests: XCTestCase {
    // Mirrors the "Test vector (v2)" subsection of docs/second-screen-protocol.md.
    let secret = Data("ABCD2345EFGH".utf8)
    let deviceId = "00000000-0000-4000-8000-000000000001"
    let clientNonce = Data(0..<32)
    let hostNonce = Data(32..<64)
    let clientPriv = Data(repeating: 0x01, count: 32)
    let hostPriv = Data(repeating: 0x02, count: 32)

    private func hex(_ k: SymmetricKey) -> String { k.withUnsafeBytes { Data($0).hexString } }

    private func fixture() throws -> (cpub: Data, hpub: Data, shared: Data, keys: SSSessionKeys) {
        let c = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: clientPriv)
        let h = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: hostPriv)
        let cpub = c.publicKey.rawRepresentation, hpub = h.publicKey.rawRepresentation
        let shared = try SSX25519.sharedSecret(privateKey: h, peerPublic: cpub)
        XCTAssertEqual(shared, try SSX25519.sharedSecret(privateKey: c, peerPublic: hpub))
        let keys = SSSessionKeys(shared: shared, secret: secret, clientNonce: clientNonce, hostNonce: hostNonce, clientPub: cpub, hostPub: hpub)
        return (cpub, hpub, shared, keys)
    }

    func testFixedVectorV2() throws {
        let f = try fixture()
        XCTAssertEqual(f.cpub.hexString, "a4e09292b651c278b9772c569f5fa9bb13d906b46ab68c9df9dc2b4409f8a209")
        XCTAssertEqual(f.hpub.hexString, "ce8d3ad1ccb633ec7b70c17814a5c76ecd029685050d344745ba05870e587d59")
        XCTAssertEqual(f.shared.hexString, "2ed76ab549b1e73c031eb49c9448f0798aea81b698279a0c3dc3e49fbfc4b953")
        XCTAssertEqual(hex(f.keys.authKey), "703ec539264404eaf80ed3b2c5b009a012e7ea336e79fdb7806e11606f5cb93c")
        XCTAssertEqual(hex(f.keys.hostToClient), "822c5aa09d804fc6305cd53f97219d3acc6f78da2e2bbbd899cd58d834fa4a7d")
        XCTAssertEqual(hex(f.keys.clientToHost), "425aefb1080c777a1f470049655664636ac3cb726112904f6688327c9fd05f1e")
        let proof = f.keys.proof(deviceId: deviceId, clientNonce: clientNonce, hostNonce: hostNonce, clientPub: f.cpub, hostPub: f.hpub)
        XCTAssertEqual(proof.hexString, "66c5310a6cbef2a3b3506d5596ea229d0e0f5241e56fa3832401bf959c497b7c")
        XCTAssertTrue(f.keys.verify(proof: proof, deviceId: deviceId, clientNonce: clientNonce, hostNonce: hostNonce, clientPub: f.cpub, hostPub: f.hpub))
        var wrong = proof; wrong[wrong.startIndex] ^= 1
        XCTAssertFalse(f.keys.verify(proof: wrong, deviceId: deviceId, clientNonce: clientNonce, hostNonce: hostNonce, clientPub: f.cpub, hostPub: f.hpub))
        XCTAssertFalse(f.keys.verify(proof: proof.dropLast(), deviceId: deviceId, clientNonce: clientNonce, hostNonce: hostNonce, clientPub: f.cpub, hostPub: f.hpub))
        // The public keys are bound into the proof: swapping them must not verify.
        XCTAssertFalse(f.keys.verify(proof: proof, deviceId: deviceId, clientNonce: clientNonce, hostNonce: hostNonce, clientPub: f.hpub, hostPub: f.cpub))
    }

    func testSealVectorAndCounters() throws {
        let k = try fixture().keys
        XCTAssertEqual(SSNonce.make(counter: 1).hexString, "000000000000000000000001")
        var sealer = SSSealer(key: k.hostToClient)
        let c0 = try sealer.seal(Data("hello".utf8), type: 0x05)
        let c1 = try sealer.seal(Data("hello".utf8), type: 0x05)
        XCTAssertEqual(c0.hexString, "9c7473a61b41ab14fc5a770634f2124c7b48a1a5b1")
        XCTAssertEqual(c1.hexString, "c1c0af1522757cbd3f4e96b758cb75fac1713b3c98")
        XCTAssertEqual(sealer.counter, 2)

        var opener = SSOpener(key: k.hostToClient)
        XCTAssertEqual(try opener.open(c0, type: 0x05), Data("hello".utf8))
        XCTAssertEqual(try opener.open(c1, type: 0x05), Data("hello".utf8))
        // Replay of c0 (counter 2 expected) must fail and must not advance the counter.
        XCTAssertThrowsError(try opener.open(c0, type: 0x05))
        XCTAssertEqual(opener.counter, 2)
    }

    func testAADBindsMessageType() throws {
        let k = try fixture().keys
        var sealer = SSSealer(key: k.hostToClient)
        let sealed = try sealer.seal(Data("x".utf8), type: SSMessageType.video.rawValue)
        var opener = SSOpener(key: k.hostToClient)
        XCTAssertThrowsError(try opener.open(sealed, type: SSMessageType.bye.rawValue), "type is authenticated")
        XCTAssertEqual(opener.counter, 0)
        XCTAssertEqual(try opener.open(sealed, type: SSMessageType.video.rawValue), Data("x".utf8))
    }

    func testOutOfOrderAndTamperRejected() throws {
        let k = try fixture().keys
        var sealer = SSSealer(key: k.clientToHost)
        _ = try sealer.seal(Data([1]), type: 0x07)
        let second = try sealer.seal(Data([2]), type: 0x07)
        var opener = SSOpener(key: k.clientToHost)
        XCTAssertThrowsError(try opener.open(second, type: 0x07))     // skipped counter 0
        var fresh = SSSealer(key: k.clientToHost)
        var tampered = try fresh.seal(Data([9]), type: 0x07)
        tampered[tampered.startIndex] ^= 0xFF
        XCTAssertThrowsError(try opener.open(tampered, type: 0x07))
        XCTAssertThrowsError(try opener.open(Data(count: 15), type: 0x07))
    }

    func testZeroSharedSecretRejected() throws {
        let priv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: hostPriv)
        // u = 0 is a low-order point: the shared secret is all zero.
        XCTAssertThrowsError(try SSX25519.sharedSecret(privateKey: priv, peerPublic: Data(count: 32)))
    }

    func testRandomBytes() throws {
        let a = try SSRandom.bytes(32), b = try SSRandom.bytes(32)
        XCTAssertEqual(a.count, 32)
        XCTAssertNotEqual(a, b)
    }

    func testConstantTimeEqual() {
        XCTAssertTrue(SSConstantTime.equal(Data([1, 2]), Data([1, 2])))
        XCTAssertFalse(SSConstantTime.equal(Data([1, 2]), Data([1, 3])))
        XCTAssertFalse(SSConstantTime.equal(Data([1]), Data([1, 2])))
    }
}
