package com.junowoz.filefoundry.screen

import org.junit.Assert.*
import org.junit.Test

class UpdateLogicTest {
    @Test fun parsesTags() {
        assertEquals(listOf(1, 3, 1), UpdateLogic.parseVersion("v1.3.1"))
        assertEquals(listOf(1, 3, 0), UpdateLogic.parseVersion("1.3"))
        assertEquals(listOf(2, 0, 0), UpdateLogic.parseVersion("V2.0.0-beta.1"))
        assertNull(UpdateLogic.parseVersion("latest"))
        assertNull(UpdateLogic.parseVersion("1.2.3.4"))
        assertNull(UpdateLogic.parseVersion("1.-2.0"))
    }

    @Test fun comparesNumerically() {
        assertTrue(UpdateLogic.isNewer("v1.3.1", "1.3.0"))
        assertTrue(UpdateLogic.isNewer("1.10.0", "1.9.9"))
        assertTrue(UpdateLogic.isNewer("2.0.0", "1.99.99"))
        assertFalse(UpdateLogic.isNewer("1.3.0", "1.3.0"))
        assertFalse(UpdateLogic.isNewer("v1.2.9", "1.3.0"))
        assertFalse(UpdateLogic.isNewer("1.3.0-beta", "1.3.0"))
        assertFalse(UpdateLogic.isNewer("garbage", "1.3.0"))
    }

    @Test fun selectsExactAssetOnAllowedHost() {
        val good = UpdateLogic.Asset("FileFoundry-Android.apk", "https://github.com/junowoz/file-foundry/releases/download/v1.3.1/FileFoundry-Android.apk")
        val assets = listOf(
            UpdateLogic.Asset("FileFoundry.dmg", "https://github.com/x/FileFoundry.dmg"),
            UpdateLogic.Asset("FileFoundry-Android.apk.sha256", "https://github.com/x/a.sha256"),
            good,
        )
        assertSame(good, UpdateLogic.selectAsset(assets))
    }

    @Test fun rejectsBadNamesAndHosts() {
        fun pick(name: String, url: String) = UpdateLogic.selectAsset(listOf(UpdateLogic.Asset(name, url)))
        assertNull(UpdateLogic.selectAsset(emptyList()))
        assertNull(pick("fileFoundry-android.apk", "https://github.com/a.apk"))
        assertNull(pick("FileFoundry-Android.apk", "http://github.com/a.apk"))
        assertNull(pick("FileFoundry-Android.apk", "https://evil.example/a.apk"))
        assertNull(pick("FileFoundry-Android.apk", "https://github.com.evil.example/a.apk"))
        assertNull(pick("FileFoundry-Android.apk", "https://github.com@evil.example/a.apk"))
        assertTrue(UpdateLogic.isAllowedUrl("https://objects.githubusercontent.com/x"))
    }
}
