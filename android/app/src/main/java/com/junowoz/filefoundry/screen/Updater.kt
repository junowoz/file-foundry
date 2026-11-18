package com.junowoz.filefoundry.screen

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

class UpdateInfo(val version: String, val asset: UpdateLogic.Asset)

/** Checks GitHub for a newer release, downloads the APK and hands it to the system installer. */
class Updater(context: Context) {
    private val app = context.applicationContext
    private val prefs = app.getSharedPreferences("ffscreen_updates", Context.MODE_PRIVATE)

    val dueForAutoCheck: Boolean
        get() = System.currentTimeMillis() - prefs.getLong("lastCheck", 0L) >= CHECK_INTERVAL_MS

    /** Blocking; call off the main thread. Returns null when this build is current. */
    fun check(): UpdateInfo? {
        val conn = get(RELEASE_URL, "application/vnd.github+json")
        val body = try {
            conn.inputStream.use { it.readBytes().toString(Charsets.UTF_8) }
        } finally {
            conn.disconnect()
        }
        val json = JSONObject(body)
        val tag = json.getString("tag_name")
        prefs.edit().putLong("lastCheck", System.currentTimeMillis()).apply()
        if (!UpdateLogic.isNewer(tag, BuildConfig.VERSION_NAME)) return null
        val arr = json.optJSONArray("assets")
        val assets = (0 until (arr?.length() ?: 0)).mapNotNull { i ->
            val a = arr?.optJSONObject(i) ?: return@mapNotNull null
            UpdateLogic.Asset(a.optString("name"), a.optString("browser_download_url"))
        }
        val asset = UpdateLogic.selectAsset(assets) ?: throw IOException("This release has no Android app file.")
        return UpdateInfo(UpdateLogic.displayVersion(tag), asset)
    }

    /** Blocking. Reports progress in 0..100, or -1 when the size is unknown. */
    fun download(info: UpdateInfo, onProgress: (Int) -> Unit): File {
        val dir = File(app.cacheDir, "updates").apply { mkdirs() }
        dir.listFiles()?.forEach { it.delete() }
        val part = File(dir, UpdateLogic.ASSET_NAME + ".part")
        val out = File(dir, UpdateLogic.ASSET_NAME)
        val conn = get(info.asset.url, "application/octet-stream")
        try {
            val total = conn.contentLengthLong
            var done = 0L
            var last = -2
            conn.inputStream.use { input ->
                part.outputStream().use { o ->
                    val buf = ByteArray(64 * 1024)
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        o.write(buf, 0, n)
                        done += n
                        val pct = if (total > 0) (done * 100 / total).toInt() else -1
                        if (pct != last) { last = pct; onProgress(pct) }
                    }
                }
            }
            if (done == 0L || (total > 0 && done != total)) throw IOException("The download was incomplete.")
        } catch (e: Exception) {
            part.delete()
            throw e
        } finally {
            conn.disconnect()
        }
        if (!part.renameTo(out)) throw IOException("Could not save the download.")
        return out
    }

    /** Streams [apk] into a PackageInstaller session; [InstallReceiver] reports the outcome. */
    fun install(apk: File) {
        val installer = app.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
        params.setSize(apk.length())
        val id = installer.createSession(params)
        installer.openSession(id).use { session ->
            apk.inputStream().use { input ->
                session.openWrite(UpdateLogic.ASSET_NAME, 0, apk.length()).use { o ->
                    input.copyTo(o)
                    session.fsync(o)
                }
            }
            val intent = Intent(app, InstallReceiver::class.java).setPackage(app.packageName)
            val pending = PendingIntent.getBroadcast(app, id, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE)
            session.commit(pending.intentSender)
        }
    }

    /** GET with manual redirects so every hop stays on an allowed HTTPS host. */
    private fun get(start: String, accept: String): HttpURLConnection {
        var url = start
        repeat(6) {
            val ok = url.startsWith("https://api.github.com/") || UpdateLogic.isAllowedUrl(url)
            if (!ok) throw IOException("Blocked an unexpected download address.")
            val conn = URL(url).openConnection() as HttpURLConnection
            conn.connectTimeout = 10_000
            conn.readTimeout = 20_000
            conn.instanceFollowRedirects = false
            conn.setRequestProperty("Accept", accept)
            conn.setRequestProperty("User-Agent", "FileFoundryScreen/" + BuildConfig.VERSION_NAME)
            val code = conn.responseCode
            if (code in 300..399) {
                val loc = conn.getHeaderField("Location")
                conn.disconnect()
                if (loc == null) throw IOException("Bad redirect from the server.")
                url = URL(URL(url), loc).toString()
            } else if (code == 200) {
                return conn
            } else {
                conn.disconnect()
                throw IOException(if (code == 403 || code == 429) "GitHub is busy. Try again later." else "Server error ($code).")
            }
        }
        throw IOException("Too many redirects.")
    }

    companion object {
        const val RELEASE_URL = "https://api.github.com/repos/junowoz/file-foundry/releases/latest"
        private const val CHECK_INTERVAL_MS = 12L * 60 * 60 * 1000

        /** Set by the visible screen to hear install results; the receiver runs on the main thread. */
        @Volatile var installListener: ((String?) -> Unit)? = null

        fun friendly(e: Exception): String = when (e) {
            is java.net.UnknownHostException, is java.net.SocketTimeoutException, is java.net.ConnectException ->
                "No connection. Check your network and try again."
            is IOException -> e.message ?: "Network error. Try again."
            else -> "Update failed. Try again later."
        }
    }
}

/** Receives PackageInstaller status: opens the system confirmation, or reports a failure. */
class InstallReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                @Suppress("DEPRECATION")
                val confirm = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
                confirm?.let { context.startActivity(it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
            }
            PackageInstaller.STATUS_SUCCESS -> Updater.installListener?.invoke(null)
            PackageInstaller.STATUS_FAILURE_ABORTED -> Updater.installListener?.invoke("Install canceled.")
            PackageInstaller.STATUS_FAILURE_CONFLICT, PackageInstaller.STATUS_FAILURE_INCOMPATIBLE ->
                Updater.installListener?.invoke("Android rejected the update. It was signed with a different key.")
            PackageInstaller.STATUS_FAILURE_STORAGE -> Updater.installListener?.invoke("Not enough storage to install the update.")
            else -> Updater.installListener?.invoke("Install failed. Try again later.")
        }
    }
}
