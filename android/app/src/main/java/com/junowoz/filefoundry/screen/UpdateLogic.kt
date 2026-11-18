package com.junowoz.filefoundry.screen

import java.net.URI

/** Pure update rules (no Android types) so they can be unit tested. */
object UpdateLogic {
    const val ASSET_NAME = "FileFoundry-Android.apk"
    val ALLOWED_HOSTS = setOf("github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com")

    class Asset(val name: String, val url: String)

    /** Parses "v1.3.1", "1.3" or "1.3.1-beta" into [major, minor, patch]; null if not a version. */
    fun parseVersion(raw: String): List<Int>? {
        val core = raw.trim().removePrefix("v").removePrefix("V").substringBefore('-').substringBefore('+')
        val parts = core.split('.')
        if (parts.size > 3) return null
        val nums = parts.map { it.toIntOrNull()?.takeIf { n -> n >= 0 } ?: return null }
        return nums + List(3 - nums.size) { 0 }
    }

    /** True when [remote] is a strictly newer release than [local]. A pre-release never beats the same number. */
    fun isNewer(remote: String, local: String): Boolean {
        val r = parseVersion(remote) ?: return false
        val l = parseVersion(local) ?: return false
        for (i in 0..2) if (r[i] != l[i]) return r[i] > l[i]
        return false
    }

    fun displayVersion(tag: String): String = tag.trim().removePrefix("v").removePrefix("V")

    fun isAllowedUrl(url: String): Boolean = try {
        val u = URI(url)
        u.scheme == "https" && u.host != null && u.host.lowercase() in ALLOWED_HOSTS && u.userInfo == null
    } catch (_: Exception) {
        false
    }

    /** The asset named exactly [ASSET_NAME] whose URL passes [isAllowedUrl]; null otherwise. */
    fun selectAsset(assets: List<Asset>): Asset? = assets.firstOrNull { it.name == ASSET_NAME && isAllowedUrl(it.url) }
}
