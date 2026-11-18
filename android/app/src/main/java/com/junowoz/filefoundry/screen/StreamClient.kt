package com.junowoz.filefoundry.screen

import com.junowoz.filefoundry.screen.proto.Crypto
import com.junowoz.filefoundry.screen.proto.Framing
import com.junowoz.filefoundry.screen.proto.InputCodec
import com.junowoz.filefoundry.screen.proto.Msg
import com.junowoz.filefoundry.screen.proto.ProtocolException
import com.junowoz.filefoundry.screen.proto.SecureChannel
import com.junowoz.filefoundry.screen.proto.VideoPacket
import com.junowoz.filefoundry.screen.proto.X25519
import java.security.GeneralSecurityException
import org.json.JSONArray
import org.json.JSONObject
import java.io.DataInputStream
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.security.SecureRandom
import java.util.Base64
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

class HostTarget(val host: String, val port: Int, val label: String)

/** Field limits from docs/second-screen-protocol.md (v2); [clamped] enforces them. */
class HelloInfo(
    val deviceId: String,
    val name: String,
    val width: Int,
    val height: Int,
    val densityDpi: Int,
    val codecs: List<String>,
    val maxFps: Int,
) {
    fun clamped() = HelloInfo(
        deviceId,
        truncateUtf8(name, 64),
        width.coerceIn(320, 8192),
        height.coerceIn(320, 8192),
        densityDpi.coerceIn(72, 1000),
        codecs.filter { it == "hevc" || it == "avc" }.distinct().take(8),
        maxFps.coerceIn(1, 240),
    )

    companion object {
        fun truncateUtf8(s: String, maxBytes: Int): String {
            var bytes = 0
            val sb = StringBuilder()
            var i = 0
            while (i < s.length) {
                val cp = s.codePointAt(i)
                val n = String(Character.toChars(cp)).toByteArray(Charsets.UTF_8).size
                if (bytes + n > maxBytes) break
                bytes += n
                sb.appendCodePoint(cp)
                i += Character.charCount(cp)
            }
            return sb.toString()
        }
    }
}

class StreamConfig(val codec: String, val width: Int, val height: Int, val fps: Int, val bitrate: Long)

sealed class Outcome {
    /** Host (or we) said goodbye. [authenticated] false means it was refused during the handshake. */
    class Bye(val reason: String, val authenticated: Boolean) : Outcome()
    /** Host wants a pairing code (no code given). Any stored key is kept until a new pairing succeeds. */
    class NeedCode(val hostId: String, val hostName: String) : Outcome()
    /** Host believes it knows this device but we hold no key for it. */
    object KeyForgotten : Outcome()
    /** WELCOME did not decrypt: the host did not prove it knew the secret. */
    object HostAuthFailed : Outcome()
    class Error(val message: String) : Outcome()
    object Closed : Outcome()
}

/**
 * One connection attempt. [run] blocks on the calling thread until the session ends; a writer thread
 * serialises all outgoing (encrypted) messages so counters stay in order.
 */
class StreamClient(
    private val target: HostTarget,
    helloInfo: HelloInfo,
    private val pairingCode: String?,
    private val listener: Listener,
) {
    interface Listener {
        /** Called once the CHALLENGE is validated; the Mac's identity, never its address. */
        fun onHost(hostId: String, hostName: String)
        /** Stored deviceKey for [hostId], or null. */
        fun keyFor(hostId: String): ByteArray?
        fun onPaired(hostId: String, deviceKey: ByteArray)
        fun onConfig(config: StreamConfig)
        fun onVideo(packet: VideoPacket)
        fun decodedFps(): Float
        fun dropped(): Int
    }

    private val hello = helloInfo.clamped()

    @Volatile var latencyMs = 0
        private set

    @Volatile private var socket: Socket? = null
    @Volatile private var closing = false
    private val outbox = LinkedBlockingQueue<Pair<Int, ByteArray>>()

    fun sendInput(kind: Int, x: Float, y: Float, dx: Float = 0f, dy: Float = 0f) {
        outbox.offer(Msg.INPUT to InputCodec.encode(kind, 0, x, y, dx, dy))
    }

    fun requestKeyframe() {
        outbox.offer(Msg.KEYFRAME_REQ to ByteArray(0))
    }

    /** Sends BYE (best effort), then the writer closes the socket. */
    fun close() {
        closing = true
        outbox.offer(Msg.BYE to "client closed".toByteArray())
        // If the writer is not running yet (handshake) or stuck, force it.
        Thread {
            try { Thread.sleep(500) } catch (_: InterruptedException) {}
            try { socket?.close() } catch (_: IOException) {}
        }.start()
    }

    private fun b64(j: JSONObject, name: String, len: Int): ByteArray {
        val bytes = try {
            Base64.getDecoder().decode(j.getString(name))
        } catch (e: IllegalArgumentException) {
            throw ProtocolException("bad base64 in $name")
        }
        if (bytes.size != len) throw ProtocolException("$name must be $len bytes")
        return bytes
    }

    private fun clean(s: String) = s.filter { it.code in 32..126 }.take(40)

    fun run(): Outcome {
        val s = Socket()
        socket = s
        try {
            s.tcpNoDelay = true
            s.connect(InetSocketAddress(target.host, target.port), 4000)
            s.soTimeout = 6000
            val input = DataInputStream(s.getInputStream().buffered(64 * 1024))
            val out = s.getOutputStream()

            val rnd = SecureRandom()
            val clientNonce = ByteArray(32).also(rnd::nextBytes)
            val clientPriv = ByteArray(32).also(rnd::nextBytes)
            val clientPub = X25519.publicKey(clientPriv)
            Framing.write(out, Msg.HELLO, helloJson(clientNonce, clientPub).toByteArray(Charsets.UTF_8))

            val challenge = Framing.read(input, Framing.PRE_AUTH_MAX)
            if (challenge.type == Msg.BYE) return Outcome.Bye(clean(String(challenge.payload, Charsets.UTF_8)), false)
            if (challenge.type != Msg.CHALLENGE) throw ProtocolException("expected CHALLENGE, got ${challenge.type}")
            val cj = JSONObject(String(challenge.payload, Charsets.UTF_8))
            if (cj.optInt("v", 0) != 2) throw ProtocolException("host does not speak v2")
            val hostNonce = b64(cj, "hostNonce", 32)
            val hostPub = b64(cj, "hostPub", 32)
            val hostId = cj.getString("hostId").trim()
            if (hostId.isEmpty() || hostId.length > 64) throw ProtocolException("bad hostId")
            val hostName = clean(cj.optString("hostName", "")).ifBlank { target.label }
            val mode = cj.getString("mode")
            if (mode != "pair" && mode != "known") throw ProtocolException("bad mode")
            listener.onHost(hostId, hostName)

            val secret = if (mode == "pair") {
                pairingCode?.toByteArray(Charsets.UTF_8) ?: return Outcome.NeedCode(hostId, hostName)
            } else {
                listener.keyFor(hostId) ?: return Outcome.KeyForgotten
            }
            val shared = X25519.scalarMult(clientPriv, hostPub)
            if (X25519.isAllZero(shared)) throw ProtocolException("bad host public key")
            val keys = Crypto.deriveKeys(shared, secret, clientNonce, hostNonce, clientPub, hostPub)
            val proof = Crypto.proof(keys.auth, hello.deviceId, clientNonce, hostNonce, clientPub, hostPub)
            val auth = JSONObject().put("proof", Base64.getEncoder().encodeToString(proof))
            Framing.write(out, Msg.AUTH, auth.toString().toByteArray(Charsets.UTF_8))

            val send = SecureChannel(keys.c2h)
            val recv = SecureChannel(keys.h2c)

            val welcome = Framing.read(input, Framing.PRE_AUTH_MAX)
            if (welcome.type == Msg.BYE) {
                // An authenticated host (e.g. "busy") sends an encrypted BYE; a refusal is clear.
                return try {
                    Outcome.Bye(clean(String(recv.open(Msg.BYE, welcome.payload), Charsets.UTF_8)), true)
                } catch (_: GeneralSecurityException) {
                    Outcome.Bye(clean(String(welcome.payload, Charsets.UTF_8)), false)
                }
            }
            if (welcome.type != Msg.WELCOME) throw ProtocolException("expected WELCOME, got ${welcome.type}")
            val welcomePlain = try {
                recv.open(Msg.WELCOME, welcome.payload)
            } catch (_: GeneralSecurityException) {
                return Outcome.HostAuthFailed
            }
            val wj = JSONObject(String(welcomePlain, Charsets.UTF_8))
            if (wj.has("deviceKey")) listener.onPaired(hostId, b64(wj, "deviceKey", 32))

            s.soTimeout = 8000 // both sides ping every second; silence means a dead link
            val writer = Thread({ writerLoop(out, send) }, "ffscreen-writer").also { it.start() }
            try {
                return readLoop(input, recv)
            } finally {
                writer.interrupt()
            }
        } catch (e: IOException) {
            return if (closing) Outcome.Closed else Outcome.Error(e.message ?: e.javaClass.simpleName)
        } catch (e: GeneralSecurityException) {
            return Outcome.Error("authentication or counter mismatch")
        } catch (e: org.json.JSONException) {
            return Outcome.Error("bad JSON from host")
        } catch (e: Exception) {
            return if (closing) Outcome.Closed else Outcome.Error("unexpected: ${e.javaClass.simpleName}")
        } finally {
            try { s.close() } catch (_: IOException) {}
        }
    }

    private fun readLoop(input: DataInputStream, recv: SecureChannel): Outcome {
        while (true) {
            val f = Framing.read(input)
            val plain = if (f.type == Msg.BYE) {
                // After WELCOME a clear BYE is ignored; only an authenticated one counts.
                try { recv.open(f.type, f.payload) } catch (_: GeneralSecurityException) { continue }
            } else {
                recv.open(f.type, f.payload)
            }
            when (f.type) {
                Msg.CONFIG -> {
                    val j = JSONObject(String(plain, Charsets.UTF_8))
                    if (j.getInt("width") !in 1..16384 || j.getInt("height") !in 1..16384) throw ProtocolException("bad CONFIG size")
                    listener.onConfig(
                        StreamConfig(
                            j.getString("codec"), j.getInt("width"), j.getInt("height"),
                            j.optInt("fps", 60), j.optLong("bitrate", 0),
                        ),
                    )
                }
                Msg.VIDEO -> listener.onVideo(VideoPacket.parse(plain))
                Msg.PING -> outbox.offer(Msg.PONG to plain)
                Msg.PONG -> if (plain.size >= 8) {
                    val rttMs = ((nowMicros() - ByteBuffer.wrap(plain).getLong(0)) / 1000).toInt()
                    latencyMs = (rttMs / 2).coerceAtLeast(0)
                }
                Msg.BYE -> return if (closing) Outcome.Closed else Outcome.Bye(String(plain, Charsets.UTF_8), true)
                else -> Unit // unknown types are ignored for forward compatibility
            }
        }
    }

    private fun writerLoop(out: java.io.OutputStream, send: SecureChannel) {
        var nextTick = System.nanoTime()
        try {
            while (true) {
                val wait = ((nextTick - System.nanoTime()) / 1_000_000).coerceAtLeast(0)
                val m = outbox.poll(wait, TimeUnit.MILLISECONDS)
                if (m != null) {
                    Framing.write(out, m.first, send.seal(m.first, m.second))
                    if (m.first == Msg.BYE) {
                        socket?.close()
                        return
                    }
                }
                if (System.nanoTime() >= nextTick) {
                    nextTick += 1_000_000_000L
                    val ping = ByteBuffer.allocate(8).putLong(nowMicros()).array()
                    Framing.write(out, Msg.PING, send.seal(Msg.PING, ping))
                    val stats = JSONObject()
                        .put("decodedFps", Math.round(listener.decodedFps() * 10) / 10.0)
                        .put("dropped", listener.dropped())
                        .put("latencyMs", latencyMs)
                    Framing.write(out, Msg.STATS, send.seal(Msg.STATS, stats.toString().toByteArray(Charsets.UTF_8)))
                }
            }
        } catch (_: InterruptedException) {
        } catch (_: IOException) {
            try { socket?.close() } catch (_: IOException) {}
        }
    }

    private fun helloJson(clientNonce: ByteArray, clientPub: ByteArray): String = JSONObject()
        .put("v", 2)
        .put("deviceId", hello.deviceId)
        .put("name", hello.name)
        .put("width", hello.width)
        .put("height", hello.height)
        .put("densityDpi", hello.densityDpi)
        .put("codecs", JSONArray(hello.codecs))
        .put("maxFps", hello.maxFps)
        .put("clientNonce", Base64.getEncoder().encodeToString(clientNonce))
        .put("clientPub", Base64.getEncoder().encodeToString(clientPub))
        .toString()

    private fun nowMicros() = System.nanoTime() / 1000
}
