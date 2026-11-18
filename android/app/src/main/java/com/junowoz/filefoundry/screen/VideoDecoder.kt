package com.junowoz.filefoundry.screen

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.view.Surface
import com.junowoz.filefoundry.screen.proto.VideoPacket
import java.util.concurrent.atomic.AtomicInteger

object Codecs {
    fun mime(codec: String) = if (codec == "hevc") MediaFormat.MIMETYPE_VIDEO_HEVC else MediaFormat.MIMETYPE_VIDEO_AVC

    private fun hardwareDecoder(mime: String): MediaCodecInfo? =
        MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.firstOrNull { info ->
            !info.isEncoder && info.supportedTypes.any { it.equals(mime, true) } && isHardware(info)
        }

    private fun isHardware(info: MediaCodecInfo): Boolean =
        if (Build.VERSION.SDK_INT >= 29) info.isHardwareAccelerated && !info.isSoftwareOnly
        else !info.name.startsWith("OMX.google.") && !info.name.startsWith("c2.android.")

    /** Wire names ("hevc", "avc") with a hardware decoder, best first. Falls back to avc. */
    fun supported(): List<String> {
        val list = listOf("hevc", "avc").filter { hardwareDecoder(mime(it)) != null }
        return list.ifEmpty { listOf("avc") }
    }

    fun create(codec: String): MediaCodec {
        val mime = mime(codec)
        val info = hardwareDecoder(mime)
        return if (info != null) MediaCodec.createByCodecName(info.name) else MediaCodec.createDecoderByType(mime)
    }
}

/** Low-latency MediaCodec wrapper: Annex-B in, render on release. Thread-safe enough for one feeder. */
class VideoDecoder(private val onError: () -> Unit) {
    @Volatile private var codec: MediaCodec? = null
    @Volatile private var running = false
    private var drainThread: Thread? = null
    private val frames = AtomicInteger()
    private val droppedCount = AtomicInteger()
    @Volatile private var needKey = true

    @Volatile var fps = 0f
        private set
    val dropped get() = droppedCount.get()

    @Synchronized
    fun start(surface: Surface, cfg: StreamConfig) {
        stop()
        val format = MediaFormat.createVideoFormat(Codecs.mime(cfg.codec), cfg.width, cfg.height).apply {
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 2 * 1024 * 1024)
            setInteger(MediaFormat.KEY_PRIORITY, 0)
            setInteger(MediaFormat.KEY_OPERATING_RATE, cfg.fps.coerceAtLeast(30))
            if (Build.VERSION.SDK_INT >= 30) setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            // Vendor hints; unknown keys are ignored by other decoders.
            setInteger("vendor.qti-ext-dec-low-latency.enable", 1)
            setInteger("vendor.low-latency.enable", 1)
            setInteger("vendor.hisi-ext-low-latency-video-dec.video-scene-for-low-latency-req", 1)
        }
        val c = Codecs.create(cfg.codec)
        try {
            c.configure(format, surface, null, 0)
            c.start()
        } catch (e: Exception) {
            c.release()
            throw e
        }
        needKey = true
        running = true
        codec = c
        drainThread = Thread({ drain(c) }, "ffscreen-decoder-out").also { it.start() }
    }

    @Synchronized
    fun stop() {
        running = false
        val c = codec
        codec = null
        drainThread?.interrupt()
        drainThread = null
        if (c != null) {
            try { c.stop() } catch (_: Exception) {}
            try { c.release() } catch (_: Exception) {}
        }
    }

    val isRunning get() = codec != null

    /** Feeds one access unit. Returns false if it was dropped (caller should ask for a keyframe). */
    fun queue(p: VideoPacket): Boolean {
        val c = codec ?: return false
        if (needKey) {
            if (!p.isKeyframe && !p.isCodecConfig) return true // waiting for a clean start, not an error
            needKey = false
        }
        return try {
            val idx = c.dequeueInputBuffer(8_000)
            if (idx < 0) {
                droppedCount.incrementAndGet()
                false
            } else {
                val buf = c.getInputBuffer(idx)!!
                buf.clear()
                buf.put(p.data, p.offset, p.length)
                c.queueInputBuffer(idx, 0, p.length, p.ptsMicros, if (p.isKeyframe) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0)
                true
            }
        } catch (e: Exception) {
            if (running) onError()
            false
        }
    }

    private fun drain(c: MediaCodec) {
        val info = MediaCodec.BufferInfo()
        var windowStart = System.nanoTime()
        try {
            while (running) {
                val idx = c.dequeueOutputBuffer(info, 10_000)
                if (idx >= 0) {
                    c.releaseOutputBuffer(idx, true) // render immediately
                    frames.incrementAndGet()
                }
                val now = System.nanoTime()
                if (now - windowStart >= 1_000_000_000L) {
                    fps = frames.getAndSet(0) * 1e9f / (now - windowStart)
                    windowStart = now
                }
            }
        } catch (e: Exception) {
            if (running) onError()
        }
    }
}
