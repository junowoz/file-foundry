package com.junowoz.filefoundry.screen.proto

import java.io.DataInputStream
import java.io.IOException
import java.io.OutputStream
import java.nio.ByteBuffer

/** Message types, see docs/second-screen-protocol.md. */
object Msg {
    const val HELLO = 0x01
    const val CHALLENGE = 0x02
    const val AUTH = 0x03
    const val WELCOME = 0x04
    const val CONFIG = 0x05
    const val VIDEO = 0x06
    const val INPUT = 0x07
    const val KEYFRAME_REQ = 0x08
    const val PING = 0x09
    const val PONG = 0x0A
    const val STATS = 0x0B
    const val BYE = 0x0F
}

class ProtocolException(message: String) : IOException(message)

class Frame(val type: Int, val payload: ByteArray)

/** `u32 length (big-endian, covers type + payload)` | `u8 type` | payload. */
object Framing {
    const val MAX_LENGTH = 8 * 1024 * 1024
    /** Frames before AUTH succeeds may not exceed this. */
    const val PRE_AUTH_MAX = 4096

    fun encode(type: Int, payload: ByteArray): ByteArray {
        val length = 1 + payload.size
        if (length > MAX_LENGTH) throw ProtocolException("frame too large: $length")
        val buf = ByteBuffer.allocate(4 + length)
        buf.putInt(length).put(type.toByte()).put(payload)
        return buf.array()
    }

    fun write(out: OutputStream, type: Int, payload: ByteArray) {
        out.write(encode(type, payload))
        out.flush()
    }

    fun read(input: DataInputStream, maxLength: Int = MAX_LENGTH): Frame {
        val length = input.readInt()
        if (length < 1 || length > maxLength) throw ProtocolException("bad frame length: $length")
        val type = input.readUnsignedByte()
        val payload = ByteArray(length - 1)
        input.readFully(payload)
        return Frame(type, payload)
    }
}

object InputKind {
    const val DOWN = 0
    const val MOVE = 1
    const val UP = 2
    const val SCROLL = 3
    const val RIGHT_CLICK = 4
    const val CANCEL = 5
}

object InputCodec {
    const val SIZE = 18

    /** `u8 kind, u8 pointerId, f32 x, f32 y, f32 dx, f32 dy`, big-endian. */
    fun encode(kind: Int, pointerId: Int, x: Float, y: Float, dx: Float, dy: Float): ByteArray =
        ByteBuffer.allocate(SIZE)
            .put(kind.toByte()).put(pointerId.toByte())
            .putFloat(x).putFloat(y).putFloat(dx).putFloat(dy)
            .array()
}

/** Plaintext of a VIDEO message: `u64 ptsMicros, u8 flags, Annex-B bytes`. */
class VideoPacket(val ptsMicros: Long, val flags: Int, val data: ByteArray, val offset: Int) {
    val isKeyframe get() = flags and 1 != 0
    val isCodecConfig get() = flags and 2 != 0
    val length get() = data.size - offset

    companion object {
        const val HEADER = 9
        fun parse(plain: ByteArray): VideoPacket {
            if (plain.size < HEADER) throw ProtocolException("short VIDEO payload")
            val b = ByteBuffer.wrap(plain)
            return VideoPacket(b.getLong(0), plain[8].toInt() and 0xFF, plain, HEADER)
        }
    }
}
