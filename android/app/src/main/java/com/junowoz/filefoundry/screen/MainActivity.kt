package com.junowoz.filefoundry.screen

import android.Manifest
import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.text.Editable
import android.text.InputType
import android.text.TextWatcher
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import com.junowoz.filefoundry.screen.proto.PairingCode

class MainActivity : Activity() {
    private lateinit var store: Store
    private var discovery: Discovery? = null
    private lateinit var macList: LinearLayout
    private lateinit var pairedList: LinearLayout
    private lateinit var pairedTitle: TextView
    private lateinit var macHint: TextView
    private lateinit var manual: EditText
    private lateinit var banner: TextView
    private lateinit var updater: Updater
    private lateinit var updateBox: LinearLayout
    private lateinit var updateText: TextView
    private lateinit var updateProgress: ProgressBar
    private lateinit var updateButton: android.widget.Button
    private lateinit var checkButton: android.widget.Button
    private var pendingUpdate: UpdateInfo? = null
    private var busy = false
    private var awaitingInstallPermission = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        store = Store(this)
        updater = Updater(this)
        setContentView(buildUi())
        if (updater.dueForAutoCheck) checkForUpdate(manual = false)
    }

    override fun onStart() {
        super.onStart()
        requestLocalNetworkIfNeeded()
        Updater.installListener = { msg -> if (msg != null) showUpdateError(msg) }
        discovery = Discovery(this) { renderMacs(it) }.also { it.start() }
    }

    override fun onStop() {
        Updater.installListener = null
        discovery?.stop()
        discovery = null
        super.onStop()
    }

    private fun renderPaired() {
        pairedList.removeAllViews()
        val hosts = store.knownHosts()
        pairedTitle.visibility = if (hosts.isEmpty()) View.GONE else View.VISIBLE
        for (h in hosts) {
            pairedList.addView(Ui.button(this, "${h.name}  (${h.host}:${h.port})", false) {
                connect(HostTarget(h.host, h.port, h.name))
            }, matchWrap(8))
        }
    }

    override fun onResume() {
        super.onResume()
        renderPaired()
        if (awaitingInstallPermission) {
            awaitingInstallPermission = false
            pendingUpdate?.let { if (packageManager.canRequestPackageInstalls()) startUpdate(it) }
        }
        Store.takeNotice()?.let { banner.text = it; banner.visibility = View.VISIBLE }
        val r = StreamResult.take()
        if (r != null) {
            banner.text = r.message
            banner.visibility = View.VISIBLE
            r.retryTarget?.let { askCodeThenConnect(it) }
        }
    }

    private fun buildUi(): View {
        val pad = Ui.dp(this, 24)
        val col = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(pad, pad, pad, pad)
        }
        col.addView(Ui.text(this, "File Foundry Screen", 28f, Ui.TEXT, true))
        col.addView(Ui.text(this, "Use this device as an extra display for your Mac.", 15f, Ui.MUTED).apply {
            setPadding(0, Ui.dp(this@MainActivity, 4), 0, Ui.dp(this@MainActivity, 20))
        })
        banner = Ui.text(this, "", 14f, 0xFFFFB454.toInt()).apply {
            visibility = View.GONE
            setPadding(0, 0, 0, Ui.dp(this@MainActivity, 16))
        }
        col.addView(banner)
        col.addView(buildUpdateBox(), matchWrap(0))

        col.addView(Ui.button(this, "Connect Over USB", true) {
            connect(HostTarget("127.0.0.1", 47321, "USB"))
        }, matchWrap(0))
        col.addView(Ui.text(this, "Plug in the cable and start Second Screen in File Foundry on your Mac.", 13f, Ui.MUTED).apply {
            setPadding(0, Ui.dp(this@MainActivity, 6), 0, Ui.dp(this@MainActivity, 24))
        })

        pairedTitle = Ui.text(this, "Paired Macs", 18f, Ui.TEXT, true).apply { visibility = View.GONE }
        col.addView(pairedTitle)
        pairedList = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        col.addView(pairedList)

        col.addView(Ui.text(this, "Wi-Fi", 18f, Ui.TEXT, true).apply {
            setPadding(0, Ui.dp(this@MainActivity, 16), 0, 0)
        })
        macHint = Ui.text(this, "Looking for Macs on this network\u2026", 14f, Ui.MUTED).apply {
            setPadding(0, Ui.dp(this@MainActivity, 8), 0, Ui.dp(this@MainActivity, 8))
        }
        col.addView(macHint)
        macList = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        col.addView(macList)

        manual = EditText(this).apply {
            hint = "Address, e.g. 192.168.1.20:47321"
            setHintTextColor(Ui.MUTED)
            setTextColor(Ui.TEXT)
            textSize = 16f
            setSingleLine()
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI
            imeOptions = EditorInfo.IME_ACTION_GO
            background = Ui.background(this@MainActivity, Ui.SURFACE, 14)
            setPadding(Ui.dp(this@MainActivity, 16), 0, Ui.dp(this@MainActivity, 16), 0)
            setText(store.lastManual)
            setOnEditorActionListener { _, _, _ -> connectManual(); true }
        }
        col.addView(manual, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, Ui.dp(this, 52)).apply {
            topMargin = Ui.dp(this@MainActivity, 8)
        })
        col.addView(Ui.button(this, "Connect", false) { connectManual() }, matchWrap(10))
        col.addView(Ui.button(this, "Forget Saved Pairings", false) {
            store.forgetAll()
            renderPaired()
            Toast.makeText(this, "Saved pairings removed", Toast.LENGTH_SHORT).show()
        }, matchWrap(24))
        checkButton = Ui.button(this, "Check for Updates", false) { checkForUpdate(manual = true) }
        col.addView(checkButton, matchWrap(0))
        col.addView(Ui.text(this, "Version ${BuildConfig.VERSION_NAME}", 13f, Ui.MUTED).apply {
            gravity = Gravity.CENTER
            setPadding(0, Ui.dp(this@MainActivity, 12), 0, 0)
        })

        val scroll = ScrollView(this).apply {
            isFillViewport = true
            addView(FrameLayout(this@MainActivity).apply {
                addView(col, FrameLayout.LayoutParams(Ui.dp(this@MainActivity, 520), ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER_HORIZONTAL))
            })
        }
        scroll.setBackgroundColor(Ui.BG)
        scroll.fitsSystemWindows = true
        return scroll
    }

    private fun buildUpdateBox(): View {
        val p = Ui.dp(this, 16)
        updateText = Ui.text(this, "", 15f, Ui.TEXT, true)
        updateProgress = ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply {
            max = 100
            visibility = View.GONE
            progressTintList = android.content.res.ColorStateList.valueOf(Ui.ACCENT)
        }
        updateButton = Ui.button(this, "Update", true) { pendingUpdate?.let { startUpdate(it) } }
        updateBox = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = Ui.background(this@MainActivity, Ui.SURFACE, 14)
            setPadding(p, p, p, p)
            visibility = View.GONE
            addView(updateText)
            addView(updateProgress, matchWrap(10))
            addView(updateButton, matchWrap(12))
        }
        return updateBox
    }

    private fun showUpdateError(message: String) {
        busy = false
        checkButton.isEnabled = true
        updateProgress.visibility = View.GONE
        updateButton.isEnabled = true
        banner.text = message
        banner.visibility = View.VISIBLE
    }

    private fun checkForUpdate(manual: Boolean) {
        if (busy) return
        busy = true
        if (manual) { checkButton.isEnabled = false; checkButton.text = "Checking\u2026" }
        Thread({
            val result = try { Result.success(updater.check()) } catch (e: Exception) { Result.failure(e) }
            runOnUiThread {
                busy = false
                checkButton.isEnabled = true
                checkButton.text = "Check for Updates"
                result.onSuccess { info ->
                    pendingUpdate = info
                    if (info != null) {
                        updateText.text = "Update available: ${info.version}"
                        updateButton.isEnabled = true
                        updateBox.visibility = View.VISIBLE
                    } else if (manual) {
                        Toast.makeText(this, "You\u2019re up to date", Toast.LENGTH_SHORT).show()
                    }
                }.onFailure { if (manual) showUpdateError(Updater.friendly(it as Exception)) }
            }
        }, "ffscreen-update-check").start()
    }

    private fun startUpdate(info: UpdateInfo) {
        if (busy) return
        if (!packageManager.canRequestPackageInstalls()) {
            awaitingInstallPermission = true
            Toast.makeText(this, "Allow installs from File Foundry Screen, then come back", Toast.LENGTH_LONG).show()
            startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")))
            return
        }
        busy = true
        banner.visibility = View.GONE
        updateButton.isEnabled = false
        updateProgress.visibility = View.VISIBLE
        updateProgress.isIndeterminate = true
        updateText.text = "Downloading ${info.version}\u2026"
        Thread({
            try {
                val file = updater.download(info) { pct ->
                    runOnUiThread {
                        if (pct >= 0) {
                            updateProgress.isIndeterminate = false
                            updateProgress.progress = pct
                            updateText.text = "Downloading ${info.version}\u2026 $pct%"
                        }
                    }
                }
                runOnUiThread { updateText.text = "Installing ${info.version}\u2026"; updateProgress.isIndeterminate = true }
                updater.install(file)
                runOnUiThread { busy = false; updateProgress.visibility = View.GONE; updateButton.isEnabled = true; updateText.text = "Update available: ${info.version}" }
            } catch (e: Exception) {
                runOnUiThread { updateText.text = "Update available: ${info.version}"; showUpdateError(Updater.friendly(e)) }
            }
        }, "ffscreen-update-download").start()
    }

    private fun matchWrap(topDp: Int) =
        LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
            topMargin = Ui.dp(this@MainActivity, topDp)
        }

    private fun renderMacs(macs: List<FoundMac>) {
        macList.removeAllViews()
        macHint.visibility = if (macs.isEmpty()) View.VISIBLE else View.GONE
        for (m in macs) {
            macList.addView(Ui.button(this, "${m.name}  (${m.host})", false) {
                connect(HostTarget(m.host, m.port, m.name))
            }, matchWrap(8))
        }
    }

    private fun connectManual() {
        val raw = manual.text.toString().trim()
        if (raw.isEmpty()) return
        val i = raw.lastIndexOf(':')
        val host = if (i > 0) raw.substring(0, i) else raw
        val port = if (i > 0) raw.substring(i + 1).toIntOrNull() else 47321
        if (host.isEmpty() || port == null || port !in 1..65535) {
            Toast.makeText(this, "Enter an address like 192.168.1.20:47321", Toast.LENGTH_SHORT).show()
            return
        }
        store.lastManual = raw
        connect(HostTarget(host, port, host))
    }

    private fun connect(target: HostTarget) {
        banner.visibility = View.GONE
        start(target, null) // the Mac's CHALLENGE decides whether a code is needed
    }

    private fun askCodeThenConnect(target: HostTarget) {
        val input = EditText(this).apply {
            hint = "XXXX-XXXX-XXXX"
            textSize = 28f
            gravity = Gravity.CENTER
            letterSpacing = 0.15f
            setSingleLine()
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_CHARACTERS or
                InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS or InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD
            filters = arrayOf(android.text.InputFilter.LengthFilter(14))
            addTextChangedListener(object : TextWatcher {
                private var busy = false
                override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
                override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
                override fun afterTextChanged(e: Editable) {
                    if (busy) return
                    busy = true
                    val f = PairingCode.format(e.toString())
                    if (f != e.toString()) e.replace(0, e.length, f)
                    busy = false
                }
            })
        }
        val box = FrameLayout(this).apply {
            val p = Ui.dp(this@MainActivity, 24)
            setPadding(p, p / 2, p, 0)
            addView(input)
        }
        val dialog = AlertDialog.Builder(this, android.R.style.Theme_DeviceDefault_Dialog_Alert)
            .setTitle("Pair with ${target.label}")
            .setMessage("Enter the 12-character code shown in File Foundry on your Mac.")
            .setView(box)
            .setNegativeButton("Cancel", null)
            .setPositiveButton("Pair", null)
            .create()
        dialog.setOnShowListener {
            val ok = dialog.getButton(AlertDialog.BUTTON_POSITIVE)
            ok.isEnabled = false
            input.addTextChangedListener(object : TextWatcher {
                override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
                override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
                override fun afterTextChanged(e: Editable) { ok.isEnabled = PairingCode.isComplete(e.toString()) }
            })
            ok.setOnClickListener {
                dialog.dismiss()
                start(target, PairingCode.normalize(input.text.toString()))
            }
            input.requestFocus()
        }
        dialog.show()
    }

    private fun start(target: HostTarget, code: String?) {
        startActivity(
            Intent(this, StreamActivity::class.java)
                .putExtra(StreamActivity.EXTRA_HOST, target.host)
                .putExtra(StreamActivity.EXTRA_PORT, target.port)
                                .putExtra(StreamActivity.EXTRA_LABEL, target.label)
                .putExtra(StreamActivity.EXTRA_CODE, code),
        )
    }

    private fun requestLocalNetworkIfNeeded() {
        if (Build.VERSION.SDK_INT >= 37) {
            val perms = arrayOf("android.permission.ACCESS_LOCAL_NETWORK")
            if (checkSelfPermission(perms[0]) != PackageManager.PERMISSION_GRANTED) requestPermissions(perms, 1)
        } else if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.NEARBY_WIFI_DEVICES) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(Manifest.permission.NEARBY_WIFI_DEVICES), 1)
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        discovery?.stop()
        discovery = Discovery(this) { renderMacs(it) }.also { it.start() }
    }
}

/** Hand-off from [StreamActivity] to [MainActivity] (no result-API dependency in plain Activities). */
class StreamResult(val message: String, val retryTarget: HostTarget?) {
    companion object {
        @Volatile private var pending: StreamResult? = null
        fun post(r: StreamResult) { pending = r }
        fun take(): StreamResult? = pending.also { pending = null }
    }
}
