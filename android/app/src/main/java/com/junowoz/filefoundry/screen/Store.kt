package com.junowoz.filefoundry.screen

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import java.security.KeyStore
import java.util.Base64
import java.util.UUID
import javax.crypto.Cipher

class KnownHost(val id: String, val name: String, val host: String, val port: Int)

/**
 * deviceId, per-`hostId` deviceKeys and each host's last address, in Keystore-backed
 * EncryptedSharedPreferences. A transient Keystore failure never wipes data: it is retried, and if
 * the master key still works the store falls back to memory for this run. Only a confirmed-unusable
 * master key resets the file, and then [takeNotice] tells the UI.
 */
class Store(context: Context) {
    private val kv: Kv = open(context.applicationContext)

    val deviceId: String
        get() = kv.get("deviceId") ?: UUID.randomUUID().toString().also { kv.put("deviceId", it) }

    fun key(hostId: String): ByteArray? = try {
        kv.get("key:$hostId")?.let { Base64.getDecoder().decode(it) }?.takeIf { it.size == 32 }
    } catch (_: IllegalArgumentException) {
        null
    }

    fun saveKey(hostId: String, key: ByteArray) = kv.put("key:$hostId", Base64.getEncoder().encodeToString(key))

    fun saveHost(hostId: String, name: String, host: String, port: Int) {
        kv.put("name:$hostId", name)
        kv.put("addr:$hostId", "$host:$port")
    }

    /** Paired hosts (those with a stored key), with their last known address. */
    fun knownHosts(): List<KnownHost> = kv.keys().filter { it.startsWith("key:") }.mapNotNull { k ->
        val id = k.removePrefix("key:")
        val addr = kv.get("addr:$id") ?: return@mapNotNull null
        val i = addr.lastIndexOf(':')
        val port = addr.substring(i + 1).toIntOrNull() ?: return@mapNotNull null
        if (i <= 0) return@mapNotNull null
        KnownHost(id, kv.get("name:$id") ?: addr.substring(0, i), addr.substring(0, i), port)
    }

    fun forgetAll() {
        kv.keys().filter { it.startsWith("key:") || it.startsWith("name:") || it.startsWith("addr:") }
            .forEach { kv.remove(it) }
    }

    var lastManual: String
        get() = kv.get("lastManual") ?: ""
        set(v) = kv.put("lastManual", v)

    interface Kv {
        fun get(k: String): String?
        fun put(k: String, v: String)
        fun remove(k: String)
        fun keys(): Set<String>
    }

    private class PrefsKv(private val p: SharedPreferences) : Kv {
        override fun get(k: String) = p.getString(k, null)
        override fun put(k: String, v: String) { p.edit().putString(k, v).apply() }
        override fun remove(k: String) { p.edit().remove(k).apply() }
        override fun keys(): Set<String> = p.all.keys.toSet()
    }

    private class MemKv : Kv {
        private val m = HashMap<String, String>()
        @Synchronized override fun get(k: String) = m[k]
        @Synchronized override fun put(k: String, v: String) { m[k] = v }
        @Synchronized override fun remove(k: String) { m.remove(k) }
        @Synchronized override fun keys(): Set<String> = m.keys.toSet()
    }

    companion object {
        private const val FILE = "ffscreen_secure"
        @Volatile private var notice: String? = null

        /** One-shot message for the UI about secure-storage trouble. */
        fun takeNotice(): String? = notice.also { notice = null }

        private fun create(ctx: Context): SharedPreferences = EncryptedSharedPreferences.create(
            ctx, FILE,
            MasterKey.Builder(ctx).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )

        /** True only when the Keystore master key is missing or cannot encrypt. A Keystore error means unknown. */
        private fun masterKeyUnusable(): Boolean = try {
            val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            val key = ks.getKey(MasterKey.DEFAULT_MASTER_KEY_ALIAS, null)
            if (key == null) {
                true
            } else {
                Cipher.getInstance("AES/GCM/NoPadding").init(Cipher.ENCRYPT_MODE, key)
                false
            }
        } catch (e: java.security.GeneralSecurityException) {
            e is java.security.UnrecoverableKeyException || e is java.security.InvalidKeyException
        } catch (_: Exception) {
            false
        }

        private fun open(ctx: Context): Kv {
            try {
                return PrefsKv(create(ctx))
            } catch (_: Exception) {
            }
            try { Thread.sleep(300) } catch (_: InterruptedException) {}
            try {
                return PrefsKv(create(ctx))
            } catch (_: Exception) {
            }
            if (!masterKeyUnusable()) {
                notice = "Secure storage is temporarily unavailable. Pairings are not saved this time; your stored keys were kept."
                return MemKv()
            }
            return try {
                ctx.deleteSharedPreferences(FILE)
                try { KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.deleteEntry(MasterKey.DEFAULT_MASTER_KEY_ALIAS) } catch (_: Exception) {}
                PrefsKv(create(ctx)).also {
                    notice = "Secure storage key was lost, so saved pairings were reset. Pair your Macs again."
                }
            } catch (_: Exception) {
                notice = "Secure storage is unavailable. Pairings are not saved this time."
                MemKv()
            }
        }
    }
}
