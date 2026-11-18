package com.junowoz.filefoundry.screen.proto

import java.nio.ByteBuffer
import java.security.MessageDigest
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

class SessionKeys(val auth: ByteArray, val h2c: ByteArray, val c2h: ByteArray)

object Crypto {
    private val INFO = "ffscreen v2".toByteArray(Charsets.UTF_8)

    fun hmac(key: ByteArray, vararg parts: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        // An empty HKDF salt must behave as 32 zero bytes; SecretKeySpec rejects empty keys.
        mac.init(SecretKeySpec(if (key.isEmpty()) ByteArray(32) else key, "HmacSHA256"))
        for (p in parts) mac.update(p)
        return mac.doFinal()
    }

    /** RFC 5869 HKDF-SHA256. */
    fun hkdf(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
        val prk = hmac(salt, ikm)
        val out = ByteArray(length)
        var t = ByteArray(0)
        var pos = 0
        var i = 1
        while (pos < length) {
            t = hmac(prk, t, info, byteArrayOf(i.toByte()))
            val n = minOf(t.size, length - pos)
            System.arraycopy(t, 0, out, pos, n)
            pos += n
            i++
        }
        return out
    }

    /**
     * authKey(32) | h2cKey(32) | c2hKey(32) from
     * HKDF(ikm = shared | secret, salt = clientNonce | hostNonce | clientPub | hostPub, info = "ffscreen v2").
     */
    fun deriveKeys(
        shared: ByteArray, secret: ByteArray,
        clientNonce: ByteArray, hostNonce: ByteArray, clientPub: ByteArray, hostPub: ByteArray,
    ): SessionKeys {
        val okm = hkdf(shared + secret, clientNonce + hostNonce + clientPub + hostPub, INFO, 96)
        return SessionKeys(okm.copyOfRange(0, 32), okm.copyOfRange(32, 64), okm.copyOfRange(64, 96))
    }

    /** HMAC-SHA256(authKey, "auth" | deviceId | clientNonce | hostNonce | clientPub | hostPub). */
    fun proof(
        authKey: ByteArray, deviceId: String,
        clientNonce: ByteArray, hostNonce: ByteArray, clientPub: ByteArray, hostPub: ByteArray,
    ): ByteArray = hmac(
        authKey, "auth".toByteArray(Charsets.UTF_8), deviceId.toByteArray(Charsets.UTF_8),
        clientNonce, hostNonce, clientPub, hostPub,
    )

    fun constantTimeEquals(a: ByteArray, b: ByteArray) = MessageDigest.isEqual(a, b)
}

/** One direction of the encrypted channel: AES-256-GCM, nonce = 4 zero bytes | u64 BE counter, AAD = message type. */
class SecureChannel(key: ByteArray, private var counter: Long = 0) {
    private val keySpec = SecretKeySpec(key, "AES")
    private val cipher = Cipher.getInstance("AES/GCM/NoPadding")

    val nextCounter get() = counter

    @Synchronized
    fun seal(type: Int, plain: ByteArray): ByteArray {
        cipher.init(Cipher.ENCRYPT_MODE, keySpec, GCMParameterSpec(128, nonce(counter)))
        cipher.updateAAD(byteArrayOf(type.toByte()))
        counter++
        return cipher.doFinal(plain)
    }

    /** Throws [javax.crypto.AEADBadTagException] on tamper, wrong key or out-of-order counter. */
    @Synchronized
    fun open(type: Int, sealed: ByteArray): ByteArray {
        cipher.init(Cipher.DECRYPT_MODE, keySpec, GCMParameterSpec(128, nonce(counter)))
        cipher.updateAAD(byteArrayOf(type.toByte()))
        val plain = try {
            cipher.doFinal(sealed)
        } catch (e: java.security.ProviderException) { // some providers throw this for input shorter than the tag
            throw javax.crypto.AEADBadTagException("short or invalid ciphertext")
        }
        counter++
        return plain
    }

    companion object {
        fun nonce(counter: Long): ByteArray = ByteBuffer.allocate(12).putInt(0).putLong(counter).array()
    }
}
