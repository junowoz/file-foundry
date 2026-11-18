package com.junowoz.filefoundry.screen

import com.junowoz.filefoundry.screen.proto.*
import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.DataInputStream
import java.nio.ByteBuffer
import javax.crypto.AEADBadTagException

private fun hex(s: String) = s.replace(" ", "").chunked(2).map { it.toInt(16).toByte() }.toByteArray()
private fun ByteArray.hex() = joinToString("") { "%02x".format(it) }

class FramingTest {
    @Test fun encodeLayout() {
        val b = Framing.encode(Msg.PING, byteArrayOf(1, 2, 3))
        assertEquals("00000004" + "09" + "010203", b.hex())
    }

    @Test fun roundTrip() {
        val payload = ByteArray(1000) { it.toByte() }
        val f = Framing.read(DataInputStream(ByteArrayInputStream(Framing.encode(Msg.VIDEO, payload))))
        assertEquals(Msg.VIDEO, f.type)
        assertArrayEquals(payload, f.payload)
    }

    @Test fun emptyPayload() {
        val f = Framing.read(DataInputStream(ByteArrayInputStream(Framing.encode(Msg.KEYFRAME_REQ, ByteArray(0)))))
        assertEquals(Msg.KEYFRAME_REQ, f.type)
        assertEquals(0, f.payload.size)
    }

    @Test fun rejectsOversizeAndZero() {
        assertThrows(ProtocolException::class.java) {
            Framing.read(DataInputStream(ByteArrayInputStream(hex("00800001 09"))))
        }
        assertThrows(ProtocolException::class.java) {
            Framing.read(DataInputStream(ByteArrayInputStream(hex("00000000"))))
        }
        assertThrows(ProtocolException::class.java) { Framing.encode(1, ByteArray(Framing.MAX_LENGTH)) }
    }

    @Test fun inputEncoding() {
        val b = InputCodec.encode(InputKind.DOWN, 0, 0.5f, 0.25f, 0f, 0f)
        assertEquals(InputCodec.SIZE, b.size)
        val bb = ByteBuffer.wrap(b)
        assertEquals(0, bb.get().toInt()); assertEquals(0, bb.get().toInt())
        assertEquals(0.5f, bb.float, 0f); assertEquals(0.25f, bb.float, 0f)
    }

    @Test fun videoPacket() {
        val plain = ByteBuffer.allocate(9 + 4).putLong(123456789L).put(3).put(byteArrayOf(0, 0, 0, 1)).array()
        val p = VideoPacket.parse(plain)
        assertEquals(123456789L, p.ptsMicros)
        assertTrue(p.isKeyframe); assertTrue(p.isCodecConfig)
        assertEquals(4, p.length)
    }
}

class CryptoTest {
    @Test fun hmacRfc4231Case2() {
        val mac = Crypto.hmac("Jefe".toByteArray(), "what do ya want for nothing?".toByteArray())
        assertEquals("5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843", mac.hex())
    }

    @Test fun hkdfRfc5869Case1() {
        val okm = Crypto.hkdf(
            ByteArray(22) { 0x0b }, hex("000102030405060708090a0b0c"), hex("f0f1f2f3f4f5f6f7f8f9"), 42,
        )
        assertEquals("3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865", okm.hex())
    }

    @Test fun hkdfMultiBlockLength() {
        val a = Crypto.hkdf(ByteArray(44) { if (it < 32) 1 else 5 }, ByteArray(32) { 2 } + ByteArray(32) { 3 } + ByteArray(32) { 4 } + ByteArray(32) { 6 }, "ffscreen v2".toByteArray(), 96)
        assertEquals(96, a.size)
        val k = Crypto.deriveKeys(ByteArray(32) { 1 }, ByteArray(12) { 5 }, ByteArray(32) { 2 }, ByteArray(32) { 3 }, ByteArray(32) { 4 }, ByteArray(32) { 6 })
        assertArrayEquals(a.copyOfRange(32, 64), k.h2c)
        assertArrayEquals(a.copyOfRange(64, 96), k.c2h)
        assertFalse(k.h2c.contentEquals(k.c2h))
    }

    @Test fun proofDependsOnEveryInput() {
        val k = ByteArray(32) { 7 }
        val cn = ByteArray(32) { 1 }; val hn = ByteArray(32) { 2 }
        val cp = ByteArray(32) { 3 }; val hp = ByteArray(32) { 4 }
        val base = Crypto.proof(k, "dev", cn, hn, cp, hp)
        assertEquals(32, base.size)
        assertTrue(Crypto.constantTimeEquals(base, Crypto.proof(k, "dev", cn, hn, cp, hp)))
        assertFalse(Crypto.constantTimeEquals(base, Crypto.proof(k, "dev2", cn, hn, cp, hp)))
        assertFalse(Crypto.constantTimeEquals(base, Crypto.proof(k, "dev", hn, cn, cp, hp)))
        assertFalse(Crypto.constantTimeEquals(base, Crypto.proof(k, "dev", cn, hn, hp, cp)))
        assertFalse(Crypto.constantTimeEquals(base, Crypto.proof(ByteArray(32), "dev", cn, hn, cp, hp)))
    }

    @Test fun nonceLayout() {
        assertEquals("000000000000000000000000", SecureChannel.nonce(0).hex())
        assertEquals("000000000000000000000102", SecureChannel.nonce(0x102).hex())
    }

    @Test fun aadIsMessageType() {
        val key = ByteArray(32) { it.toByte() }
        val sealed = SecureChannel(key).seal(Msg.PING, "x".toByteArray())
        assertEquals("x", String(SecureChannel(key).open(Msg.PING, sealed)))
        assertThrows(AEADBadTagException::class.java) { SecureChannel(key).open(Msg.PONG, sealed) }
    }

    @Test fun countersAdvanceAndMustMatch() {
        val key = ByteArray(32) { it.toByte() }
        val tx = SecureChannel(key); val rx = SecureChannel(key)
        val m1 = tx.seal(1, "one".toByteArray()); val m2 = tx.seal(1, "two".toByteArray())
        assertFalse(m1.contentEquals(tx.seal(1, "one".toByteArray()))) // same plaintext, new counter
        assertEquals("one", String(rx.open(1, m1)))
        assertEquals("two", String(rx.open(1, m2)))
        assertThrows(AEADBadTagException::class.java) { rx.open(1, m1) }
        assertEquals(2L, rx.nextCounter) // failed open must not advance
    }

    @Test fun skippedMessageFails() {
        val key = ByteArray(32) { 9 }
        val tx = SecureChannel(key); val rx = SecureChannel(key)
        tx.seal(1, ByteArray(1)); val second = tx.seal(1, ByteArray(1))
        assertThrows(AEADBadTagException::class.java) { rx.open(1, second) }
    }

    @Test fun tamperAndWrongKeyFail() {
        val tx = SecureChannel(ByteArray(32) { 1 })
        val sealed = tx.seal(4, "hello".toByteArray())
        assertEquals(5 + 16, sealed.size)
        val bad = sealed.copyOf().also { it[0] = (it[0].toInt() xor 1).toByte() }
        assertThrows(AEADBadTagException::class.java) { SecureChannel(ByteArray(32) { 1 }).open(4, bad) }
        assertThrows(AEADBadTagException::class.java) { SecureChannel(ByteArray(32) { 2 }).open(4, sealed) }
    }

    @Test fun clearByeDoesNotDecrypt() {
        assertThrows(java.security.GeneralSecurityException::class.java) {
            SecureChannel(ByteArray(32) { 1 }).open(Msg.BYE, "busy".toByteArray())
        }
    }

    @Test fun endToEndHandshakeSymmetry() {
        val cn = ByteArray(32) { 3 }; val hn = ByteArray(32) { 4 }
        val cpriv = ByteArray(32) { 1 }; val hpriv = ByteArray(32) { 2 }
        val cpub = X25519.publicKey(cpriv); val hpub = X25519.publicKey(hpriv)
        val sc = X25519.scalarMult(cpriv, hpub); val sh = X25519.scalarMult(hpriv, cpub)
        assertArrayEquals(sc, sh)
        val code = "ABCD2345EFGH".toByteArray()
        val client = Crypto.deriveKeys(sc, code, cn, hn, cpub, hpub)
        val host = Crypto.deriveKeys(sh, code, cn, hn, cpub, hpub)
        assertTrue(Crypto.constantTimeEquals(Crypto.proof(client.auth, "id", cn, hn, cpub, hpub), Crypto.proof(host.auth, "id", cn, hn, cpub, hpub)))
        val msg = SecureChannel(host.h2c).seal(Msg.WELCOME, "{}".toByteArray())
        assertEquals("{}", String(SecureChannel(client.h2c).open(Msg.WELCOME, msg)))
        val wrong = Crypto.deriveKeys(sc, "ABCD2345EFGJ".toByteArray(), cn, hn, cpub, hpub)
        assertFalse(Crypto.constantTimeEquals(client.auth, wrong.auth))
    }
}

class X25519Test {
    private fun mult(k: String, u: String) = X25519.scalarMult(hex(k), hex(u)).hex()

    @Test fun rfc7748Section52Vector1() {
        assertEquals(
            "c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552",
            mult("a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4",
                "e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c"),
        )
    }

    @Test fun rfc7748Section52Vector2() {
        assertEquals(
            "95cbde9476e8907d7aade45cb4b873f88b595a68799fa152e6f8f7647aac7957",
            mult("4b66e9d4d1b4673c5ad22691957d6af5c11b6421e0ea01d42ca4169e7918ba0d",
                "e5210f12786811d3f4b7959d0538ae2c31dbe7106fc03c3efc4cd549c715a493"),
        )
    }

    @Test fun rfc7748Section61AliceBob() {
        val aPriv = hex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
        val bPriv = hex("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")
        val aPub = X25519.publicKey(aPriv); val bPub = X25519.publicKey(bPriv)
        assertEquals("8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a", aPub.hex())
        assertEquals("de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f", bPub.hex())
        val shared = "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742"
        assertEquals(shared, X25519.scalarMult(aPriv, bPub).hex())
        assertEquals(shared, X25519.scalarMult(bPriv, aPub).hex())
    }

    @Test fun lowOrderPointGivesAllZero() {
        assertTrue(X25519.isAllZero(X25519.scalarMult(ByteArray(32) { 5 }, ByteArray(32))))
        assertFalse(X25519.isAllZero(X25519.publicKey(ByteArray(32) { 5 })))
    }
}

class PairingCodeTest {
    @Test fun normalizes() {
        assertEquals("ABCD2345EFGH", PairingCode.normalize("abcd-2345-efgh"))
        assertEquals("ABCD2345", PairingCode.normalize(" a b c d 2 3 4 5 "))
        assertEquals("ABCD", PairingCode.normalize("AB0C1ID")) // 0, 1, I are not in the alphabet
        assertEquals("ABCDEFGHJKMN", PairingCode.normalize("ABCDEFGHJKMNPQ"))
        assertEquals("", PairingCode.normalize("0O1Il"))
    }

    @Test fun formatsForDisplay() {
        assertEquals("ABC", PairingCode.format("abc"))
        assertEquals("ABCD", PairingCode.format("abcd"))
        assertEquals("ABCD-E", PairingCode.format("abcde"))
        assertEquals("ABCD-EFGH-JKMN", PairingCode.format("abcdefghjkmnpq"))
        assertEquals("ABCD-EFGH-JKMN", PairingCode.format("ABCD-EFGH-JKMN"))
    }

    @Test fun completeness() {
        assertTrue(PairingCode.isComplete("abcd-efgh-jkmn"))
        assertFalse(PairingCode.isComplete("abcd-efgh-jkm"))
        assertEquals(31, PairingCode.ALPHABET.length)
    }
}

class HelloClampTest {
    @Test fun clampsToDocLimits() {
        val h = HelloInfo("id", "é".repeat(100), 100, 99999, 5, listOf("hevc", "x", "avc", "hevc"), 500).clamped()
        assertTrue(h.name.toByteArray().size <= 64)
        assertEquals(320, h.width); assertEquals(8192, h.height); assertEquals(72, h.densityDpi)
        assertEquals(listOf("hevc", "avc"), h.codecs); assertEquals(240, h.maxFps)
    }
}

class InputMapperTest {
    @Test fun fitPillarboxedInWideView() {
        // 1600x1000 view, 16:9 stream => letterbox top/bottom? 16:9 = 1.78 > 1.6 so bars top/bottom
        val r = InputMapper.fit(1600f, 1000f, 1920, 1080)
        assertEquals(0f, r.left, 0.01f); assertEquals(1600f, r.width, 0.01f)
        assertEquals(900f, r.height, 0.01f); assertEquals(50f, r.top, 0.01f)
    }

    @Test fun fitPillarboxLeftRight() {
        val r = InputMapper.fit(2000f, 1000f, 1000, 1000)
        assertEquals(500f, r.left, 0.01f); assertEquals(1000f, r.width, 0.01f); assertEquals(0f, r.top, 0.01f)
    }

    @Test fun normalizeInside() {
        val r = InputMapper.fit(2000f, 1000f, 1000, 1000)
        val c = InputMapper.normalize(r, 1000f, 500f)!!
        assertEquals(0.5f, c.x, 1e-4f); assertEquals(0.5f, c.y, 1e-4f)
        val tl = InputMapper.normalize(r, 500f, 0f)!!
        assertEquals(0f, tl.x, 1e-4f); assertEquals(0f, tl.y, 1e-4f)
        val br = InputMapper.normalize(r, 1500f, 1000f)!!
        assertEquals(1f, br.x, 1e-4f); assertEquals(1f, br.y, 1e-4f)
    }

    @Test fun letterboxIsExcluded() {
        val r = InputMapper.fit(2000f, 1000f, 1000, 1000)
        assertNull(InputMapper.normalize(r, 100f, 500f))
        assertNull(InputMapper.normalize(r, 1900f, 500f))
        val tall = InputMapper.fit(1000f, 2000f, 2000, 1000)
        assertNull(InputMapper.normalize(tall, 500f, 100f))
        assertNotNull(InputMapper.normalize(tall, 500f, 1000f))
    }

    @Test fun clampedKeepsDragInsideStream() {
        val r = InputMapper.fit(2000f, 1000f, 1000, 1000)
        val c = InputMapper.normalizeClamped(r, 50f, 2000f)
        assertEquals(0f, c.x, 0f); assertEquals(1f, c.y, 0f)
    }

    @Test fun identityWhenAspectMatches() {
        val r = InputMapper.fit(2560f, 1600f, 1280, 800)
        assertEquals(0f, r.left, 0.01f); assertEquals(0f, r.top, 0.01f)
        val c = InputMapper.normalize(r, 640f, 400f)!!
        assertEquals(0.25f, c.x, 1e-4f); assertEquals(0.25f, c.y, 1e-4f)
    }
}

/** Shared v2 vector from docs/second-screen-protocol.md, produced by the Mac host (CryptoKit). */
class HostVectorV2Test {
    private val clientNonce = ByteArray(32) { it.toByte() }
    private val hostNonce = ByteArray(32) { (0x20 + it).toByte() }
    private val clientPriv = ByteArray(32) { 0x01 }
    private val hostPriv = ByteArray(32) { 0x02 }

    @Test fun matchesMacHost() {
        val clientPub = X25519.publicKey(clientPriv)
        val hostPub = X25519.publicKey(hostPriv)
        assertEquals("a4e09292b651c278b9772c569f5fa9bb13d906b46ab68c9df9dc2b4409f8a209", clientPub.hex())
        assertEquals("ce8d3ad1ccb633ec7b70c17814a5c76ecd029685050d344745ba05870e587d59", hostPub.hex())
        val shared = X25519.scalarMult(clientPriv, hostPub)
        assertEquals("2ed76ab549b1e73c031eb49c9448f0798aea81b698279a0c3dc3e49fbfc4b953", shared.hex())
        val keys = Crypto.deriveKeys(shared, "ABCD2345EFGH".toByteArray(Charsets.UTF_8), clientNonce, hostNonce, clientPub, hostPub)
        assertEquals("703ec539264404eaf80ed3b2c5b009a012e7ea336e79fdb7806e11606f5cb93c", keys.auth.hex())
        assertEquals("822c5aa09d804fc6305cd53f97219d3acc6f78da2e2bbbd899cd58d834fa4a7d", keys.h2c.hex())
        assertEquals("425aefb1080c777a1f470049655664636ac3cb726112904f6688327c9fd05f1e", keys.c2h.hex())
        val proof = Crypto.proof(keys.auth, "00000000-0000-4000-8000-000000000001", clientNonce, hostNonce, clientPub, hostPub)
        assertEquals("66c5310a6cbef2a3b3506d5596ea229d0e0f5241e56fa3832401bf959c497b7c", proof.hex())
        val channel = SecureChannel(keys.h2c)
        assertEquals("9c7473a61b41ab14fc5a770634f2124c7b48a1a5b1", channel.seal(0x05, "hello".toByteArray()).hex())
        assertEquals("c1c0af1522757cbd3f4e96b758cb75fac1713b3c98", channel.seal(0x05, "hello".toByteArray()).hex())
    }
}
