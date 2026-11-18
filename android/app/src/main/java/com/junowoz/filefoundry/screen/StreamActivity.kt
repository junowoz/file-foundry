package com.junowoz.filefoundry.screen

import android.app.Activity
import android.content.pm.ActivityInfo
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.DisplayMetrics
import android.view.Gravity
import android.view.MotionEvent
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.ViewConfiguration
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import com.junowoz.filefoundry.screen.proto.InputKind
import com.junowoz.filefoundry.screen.proto.InputMapper
import com.junowoz.filefoundry.screen.proto.StreamRect
import com.junowoz.filefoundry.screen.proto.VideoPacket
import kotlin.math.hypot

class StreamActivity : Activity(), SurfaceHolder.Callback, StreamClient.Listener {
    companion object {
        const val EXTRA_HOST = "host"
        const val EXTRA_PORT = "port"
        const val EXTRA_LABEL = "label"
        const val EXTRA_CODE = "code"
    }

    private val ui = Handler(Looper.getMainLooper())
    private lateinit var store: Store
    private lateinit var target: HostTarget
    private lateinit var root: FrameLayout
    private lateinit var surfaceView: SurfaceView
    private lateinit var overlay: LinearLayout
    private lateinit var statsText: TextView
    private lateinit var lockButton: TextView
    private lateinit var status: TextView

    private val decoder = VideoDecoder { ui.post { restartDecoder() } }
    @Volatile private var client: StreamClient? = null
    @Volatile private var config: StreamConfig? = null
    private var surfaceReady = false
    private var rotationLocked = false
    @Volatile private var stopped = false
    private var lastKeyReq = 0L
    private var pairingCode: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        store = Store(this)
        target = HostTarget(
            intent.getStringExtra(EXTRA_HOST) ?: "127.0.0.1",
            intent.getIntExtra(EXTRA_PORT, 47321),
            intent.getStringExtra(EXTRA_LABEL) ?: "Mac",
        )
        pairingCode = intent.getStringExtra(EXTRA_CODE)

        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        buildUi()
        hideSystemBars()
        Thread({ connectLoop() }, "ffscreen-session").start()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) hideSystemBars()
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        finishStreaming()
    }

    override fun onDestroy() {
        stopped = true
        client?.close()
        decoder.stop()
        super.onDestroy()
    }

    // ---------------------------------------------------------------- UI

    private fun buildUi() {
        root = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }
        surfaceView = SurfaceView(this).also { it.holder.addCallback(this) }
        root.addView(surfaceView, FrameLayout.LayoutParams(-1, -1))

        status = Ui.text(this, "Connecting to ${target.label}\u2026", 16f, Ui.MUTED).apply { gravity = Gravity.CENTER }
        root.addView(status, FrameLayout.LayoutParams(-2, -2, Gravity.CENTER))

        val pad = Ui.dp(this, 12)
        statsText = Ui.text(this, "", 13f, Ui.TEXT)
        lockButton = Ui.button(this, "Lock Rotation", false) { toggleRotationLock() }
        val disconnect = Ui.button(this, "Disconnect", false) { finishStreaming() }
        overlay = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(pad, pad, pad, pad)
            background = Ui.background(this@StreamActivity, 0xCC17171B.toInt(), 16)
            visibility = View.GONE
            addView(statsText)
            addView(lockButton, LinearLayout.LayoutParams(-2, -2).apply { topMargin = pad })
            addView(disconnect, LinearLayout.LayoutParams(-1, -2).apply { topMargin = pad / 2 })
        }
        root.addView(overlay, FrameLayout.LayoutParams(-2, -2, Gravity.TOP or Gravity.START).apply {
            setMargins(pad * 2, pad * 2, 0, 0)
        })
        root.setOnTouchListener(TouchController())
        setContentView(root)
    }

    private fun hideSystemBars() {
        if (Build.VERSION.SDK_INT >= 30) {
            window.insetsController?.let {
                it.hide(WindowInsets.Type.systemBars())
                it.systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
            window.attributes = window.attributes.also {
                it.layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
            }
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or
                View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or View.SYSTEM_UI_FLAG_FULLSCREEN or
                View.SYSTEM_UI_FLAG_LAYOUT_STABLE or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION or
                View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
        }
    }

    private fun toggleRotationLock() {
        rotationLocked = !rotationLocked
        requestedOrientation = if (rotationLocked) ActivityInfo.SCREEN_ORIENTATION_LOCKED
        else ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
        lockButton.text = if (rotationLocked) "Unlock Rotation" else "Lock Rotation"
    }

    private val statsTick = object : Runnable {
        override fun run() {
            if (overlay.visibility != View.VISIBLE) return
            val c = config
            statsText.text = String.format(
                "%.0f fps  |  %d ms  |  %s", decoder.fps, client?.latencyMs ?: 0,
                if (c != null) "${c.width}x${c.height} ${c.codec}" else "no stream",
            )
            ui.postDelayed(this, 500)
        }
    }

    private fun toggleOverlay() {
        overlay.visibility = if (overlay.visibility == View.VISIBLE) View.GONE else View.VISIBLE
        ui.removeCallbacks(statsTick)
        if (overlay.visibility == View.VISIBLE) statsTick.run()
    }

    /** Resizes the SurfaceView to the stream's aspect ratio so letterboxing is explicit. */
    private fun layoutSurface() {
        val c = config ?: return
        val r = InputMapper.fit(root.width.toFloat(), root.height.toFloat(), c.width, c.height)
        surfaceView.layoutParams = FrameLayout.LayoutParams(r.width.toInt(), r.height.toInt(), Gravity.CENTER)
        surfaceView.holder.setFixedSize(c.width, c.height)
    }

    // ---------------------------------------------------------------- Surface

    override fun surfaceCreated(holder: SurfaceHolder) {
        surfaceReady = true
        startDecoderIfReady()
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        surfaceReady = false
        decoder.stop()
    }

    private fun startDecoderIfReady() {
        val c = config ?: return
        if (!surfaceReady) return
        try {
            decoder.start(surfaceView.holder.surface, c)
            requestKeyframe(force = true)
        } catch (e: Exception) {
            status.text = "Video decoder error: ${e.message}"
            status.visibility = View.VISIBLE
        }
    }

    private fun restartDecoder() {
        if (stopped) return
        startDecoderIfReady()
    }

    private fun requestKeyframe(force: Boolean = false) {
        val now = System.nanoTime()
        if (!force && now - lastKeyReq < 500_000_000L) return
        lastKeyReq = now
        client?.requestKeyframe()
    }

    // ---------------------------------------------------------------- Session

    private fun connectLoop() {
        try {
            runConnectLoop()
        } catch (e: Throwable) {
            end("Connection failed: ${e.javaClass.simpleName}", null)
        }
    }

    private fun runConnectLoop() {
        val hello = buildHello()
        while (!stopped) {
            val c = StreamClient(target, hello, pairingCode, this)
            client = c
            ui.post { status.text = "Connecting to ${target.label}\u2026"; status.visibility = View.VISIBLE }
            when (val o = c.run()) {
                is Outcome.Bye -> {
                    if (o.authenticated && o.reason == "busy") {
                        ui.post { status.text = "${target.label} is busy with another device. Retrying..."; status.visibility = View.VISIBLE }
                        decoderStopOnUi()
                        try { Thread.sleep(2000) } catch (_: InterruptedException) { return }
                    } else {
                        return end(
                            if (o.authenticated) "Disconnected: ${o.reason}" else "Host refused: ${o.reason}",
                            null,
                        )
                    }
                }
                is Outcome.NeedCode -> return end(
                    "${o.hostName} needs a pairing code. Enter the 12-character code shown on the Mac.",
                    HostTarget(target.host, target.port, o.hostName),
                )
                Outcome.KeyForgotten -> return end(
                    "The Mac still lists this device but its key is not stored here. Remove the device in File Foundry on the Mac, then pair again.",
                    null,
                )
                Outcome.HostAuthFailed -> return end(
                    "Could not verify the Mac (wrong code or not your Mac). Nothing was saved.",
                    null,
                )
                Outcome.Closed -> return
                is Outcome.Error -> {
                    ui.post { status.text = "Reconnecting... (${o.message})"; status.visibility = View.VISIBLE }
                    decoderStopOnUi()
                    try { Thread.sleep(1500) } catch (_: InterruptedException) { return }
                }
            }
        }
    }

    private fun decoderStopOnUi() {
        config = null
        ui.post { decoder.stop() }
    }

    private fun end(message: String, retry: HostTarget?) {
        StreamResult.post(StreamResult(message, retry))
        ui.post { if (!isFinishing) finish() }
    }

    private fun finishStreaming() {
        stopped = true
        client?.close()
        finish()
    }

    private fun buildHello(): HelloInfo {
        val w: Int
        val h: Int
        if (Build.VERSION.SDK_INT >= 30) {
            val b = windowManager.currentWindowMetrics.bounds
            w = b.width(); h = b.height()
        } else {
            val dm = DisplayMetrics()
            @Suppress("DEPRECATION")
            windowManager.defaultDisplay.getRealMetrics(dm)
            w = dm.widthPixels; h = dm.heightPixels
        }
        @Suppress("DEPRECATION")
        val refresh = (if (Build.VERSION.SDK_INT >= 30) display else windowManager.defaultDisplay)?.refreshRate ?: 60f
        return HelloInfo(
            deviceId = store.deviceId,
            name = Build.MODEL,
            width = maxOf(w, h),
            height = minOf(w, h),
            densityDpi = resources.displayMetrics.densityDpi,
            codecs = Codecs.supported(),
            maxFps = Math.round(refresh),
        )
    }

    // StreamClient.Listener (called on the session / reader thread)

    override fun onHost(hostId: String, hostName: String) {
        store.saveHost(hostId, hostName, target.host, target.port)
        ui.post { status.text = "Connecting to $hostName..." }
    }

    override fun keyFor(hostId: String) = store.key(hostId)

    override fun onPaired(hostId: String, deviceKey: ByteArray) {
        // Replaces any older key for this host only now that the new pairing succeeded.
        store.saveKey(hostId, deviceKey)
        pairingCode = null
    }

    override fun onConfig(config: StreamConfig) {
        this.config = config
        ui.post {
            status.visibility = View.GONE
            layoutSurface()
            startDecoderIfReady()
        }
    }

    override fun onVideo(packet: VideoPacket) {
        if (!decoder.queue(packet)) ui.post { requestKeyframe() }
    }

    override fun decodedFps() = decoder.fps
    override fun dropped() = decoder.dropped

    // ---------------------------------------------------------------- Touch

    private inner class TouchController : View.OnTouchListener {

        private var s = S.IDLE
        private var startX = 0f
        private var startY = 0f
        private var lastCx = 0f
        private var lastCy = 0f
        private val slop = ViewConfiguration.get(this@StreamActivity).scaledTouchSlop
        private val density = resources.displayMetrics.density
        private val longPress = Runnable {
            if (s == S.PENDING) {
                send(InputKind.RIGHT_CLICK, startX, startY, strict = true)
                root.performHapticFeedback(android.view.HapticFeedbackConstants.LONG_PRESS)
                s = S.LONG
            }
        }

        override fun onTouch(v: View, e: MotionEvent): Boolean {
            when (e.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    startX = e.x; startY = e.y
                    val inside = InputMapper.normalize(rect(), e.x, e.y) != null
                    s = if (inside) S.PENDING else S.IGNORE
                    if (inside) ui.postDelayed(longPress, 500)
                }
                MotionEvent.ACTION_POINTER_DOWN -> {
                    ui.removeCallbacks(longPress)
                    if (e.pointerCount >= 3) {
                        if (s != S.IGNORE) toggleOverlay()
                        s = S.IGNORE
                    } else if (s == S.DRAG || s == S.PENDING || s == S.LONG) {
                        if (s == S.DRAG) send(InputKind.CANCEL, e.getX(0), e.getY(0))
                        s = S.SCROLL
                        lastCx = (e.getX(0) + e.getX(1)) / 2f
                        lastCy = (e.getY(0) + e.getY(1)) / 2f
                    }
                }
                MotionEvent.ACTION_MOVE -> when (s) {
                    S.PENDING -> if (hypot(e.x - startX, e.y - startY) > slop) {
                        ui.removeCallbacks(longPress)
                        send(InputKind.DOWN, startX, startY)
                        send(InputKind.MOVE, e.x, e.y)
                        s = S.DRAG
                    }
                    S.DRAG -> send(InputKind.MOVE, e.x, e.y)
                    S.SCROLL -> if (e.pointerCount >= 2) {
                        val cx = (e.getX(0) + e.getX(1)) / 2f
                        val cy = (e.getY(0) + e.getY(1)) / 2f
                        val dx = (cx - lastCx) / density
                        val dy = (cy - lastCy) / density
                        lastCx = cx; lastCy = cy
                        if (dx != 0f || dy != 0f) client?.sendInput(InputKind.SCROLL, 0f, 0f, dx, dy)
                    }
                    else -> Unit
                }
                MotionEvent.ACTION_POINTER_UP -> {
                    if (s == S.SCROLL && e.pointerCount - 1 < 2) s = S.IGNORE
                }
                MotionEvent.ACTION_UP -> {
                    ui.removeCallbacks(longPress)
                    when (s) {
                        S.PENDING -> {
                            send(InputKind.DOWN, startX, startY)
                            send(InputKind.UP, startX, startY)
                        }
                        S.DRAG -> send(InputKind.UP, e.x, e.y)
                        else -> Unit
                    }
                    s = S.IDLE
                }
                MotionEvent.ACTION_CANCEL -> {
                    ui.removeCallbacks(longPress)
                    if (s == S.DRAG) send(InputKind.CANCEL, e.x, e.y)
                    s = S.IDLE
                }
            }
            return true
        }

        private fun rect(): StreamRect {
            val c = config
            return InputMapper.fit(root.width.toFloat(), root.height.toFloat(), c?.width ?: 0, c?.height ?: 0)
        }

        private fun send(kind: Int, x: Float, y: Float, strict: Boolean = false) {
            val n = if (strict) InputMapper.normalize(rect(), x, y) else InputMapper.normalizeClamped(rect(), x, y)
            if (n != null && config != null) client?.sendInput(kind, n.x, n.y)
        }
    }
}

private enum class S { IDLE, PENDING, DRAG, LONG, SCROLL, IGNORE }
