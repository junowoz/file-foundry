package com.junowoz.filefoundry.screen.proto

/**
 * X25519 (RFC 7748) as a Montgomery ladder over GF(2^255-19), ported from TweetNaCl's
 * crypto_scalarmult: 16 limbs of 16 bits in a LongArray, no secret-dependent branches or
 * indices (bit selection is a masked swap). Used on every API level so behaviour is identical.
 */
object X25519 {
    const val SIZE = 32

    private val BASE = ByteArray(32).also { it[0] = 9 }
    private val C121665 = LongArray(16).also { it[0] = 0xDB41; it[1] = 1 }

    /** Public key for [priv] (scalar multiplication of the base point). */
    fun publicKey(priv: ByteArray): ByteArray = scalarMult(priv, BASE)

    /** `X25519(scalar, u)`; both 32 bytes. The caller must reject an all-zero result. */
    fun scalarMult(scalar: ByteArray, u: ByteArray): ByteArray {
        require(scalar.size == SIZE && u.size == SIZE) { "X25519 inputs must be 32 bytes" }
        val z = scalar.copyOf()
        z[31] = ((z[31].toInt() and 127) or 64).toByte()
        z[0] = (z[0].toInt() and 248).toByte()

        val x = LongArray(16); unpack(x, u)
        val a = LongArray(16); val b = x.copyOf(); val c = LongArray(16); val d = LongArray(16)
        val e = LongArray(16); val f = LongArray(16)
        a[0] = 1; d[0] = 1

        for (i in 254 downTo 0) {
            val r = ((z[i ushr 3].toInt() ushr (i and 7)) and 1).toLong()
            sel(a, b, r); sel(c, d, r)
            add(e, a, c); sub(a, a, c); add(c, b, d); sub(b, b, d)
            sqr(d, e); sqr(f, a); mul(a, c, a); mul(c, b, e)
            add(e, a, c); sub(a, a, c); sqr(b, a); sub(c, d, f)
            mul(a, c, C121665); add(a, a, d); mul(c, c, a); mul(a, d, f)
            mul(d, b, x); sqr(b, e)
            sel(a, b, r); sel(c, d, r)
        }
        inv(c, c)
        mul(a, a, c)
        return pack(a)
    }

    fun isAllZero(b: ByteArray): Boolean {
        var acc = 0
        for (v in b) acc = acc or v.toInt()
        return acc == 0
    }

    private fun unpack(o: LongArray, n: ByteArray) {
        for (i in 0 until 16) o[i] = (n[2 * i].toLong() and 0xff) + ((n[2 * i + 1].toLong() and 0xff) shl 8)
        o[15] = o[15] and 0x7fff
    }

    private fun car(o: LongArray) {
        for (i in 0 until 16) {
            o[i] += 1L shl 16
            val c = o[i] shr 16
            if (i < 15) o[i + 1] += c - 1 else o[0] += 38 * (c - 1)
            o[i] -= c shl 16
        }
    }

    private fun sel(p: LongArray, q: LongArray, bit: Long) {
        val c = (bit - 1).inv()
        for (i in 0 until 16) {
            val t = c and (p[i] xor q[i])
            p[i] = p[i] xor t
            q[i] = q[i] xor t
        }
    }

    private fun pack(n: LongArray): ByteArray {
        val t = n.copyOf()
        val m = LongArray(16)
        car(t); car(t); car(t)
        for (j in 0 until 2) {
            m[0] = t[0] - 0xffed
            for (i in 1 until 15) {
                m[i] = t[i] - 0xffff - ((m[i - 1] shr 16) and 1)
                m[i - 1] = m[i - 1] and 0xffff
            }
            m[15] = t[15] - 0x7fff - ((m[14] shr 16) and 1)
            val b = (m[15] shr 16) and 1
            m[14] = m[14] and 0xffff
            sel(t, m, 1 - b)
        }
        val o = ByteArray(32)
        for (i in 0 until 16) {
            o[2 * i] = (t[i] and 0xff).toByte()
            o[2 * i + 1] = (t[i] shr 8).toByte()
        }
        return o
    }

    private fun add(o: LongArray, a: LongArray, b: LongArray) { for (i in 0 until 16) o[i] = a[i] + b[i] }
    private fun sub(o: LongArray, a: LongArray, b: LongArray) { for (i in 0 until 16) o[i] = a[i] - b[i] }

    private fun mul(o: LongArray, a: LongArray, b: LongArray) {
        val t = LongArray(31)
        for (i in 0 until 16) for (j in 0 until 16) t[i + j] += a[i] * b[j]
        for (i in 0 until 15) t[i] += 38 * t[i + 16]
        for (i in 0 until 16) o[i] = t[i]
        car(o); car(o)
    }

    private fun sqr(o: LongArray, a: LongArray) = mul(o, a, a)

    private fun inv(o: LongArray, i: LongArray) {
        val c = i.copyOf()
        for (a in 253 downTo 0) {
            sqr(c, c)
            if (a != 2 && a != 4) mul(c, c, i)
        }
        for (k in 0 until 16) o[k] = c[k]
    }
}
