package com.junowoz.filefoundry.screen.proto

/** Where the stream is drawn inside a view (letterboxed, centred). */
class StreamRect(val left: Float, val top: Float, val width: Float, val height: Float)

class Norm(val x: Float, val y: Float)

object InputMapper {
    fun fit(viewW: Float, viewH: Float, streamW: Int, streamH: Int): StreamRect {
        if (streamW <= 0 || streamH <= 0 || viewW <= 0f || viewH <= 0f) return StreamRect(0f, 0f, viewW, viewH)
        val scale = minOf(viewW / streamW, viewH / streamH)
        val w = streamW * scale
        val h = streamH * scale
        return StreamRect((viewW - w) / 2f, (viewH - h) / 2f, w, h)
    }

    /** View pixels to 0..1 of the stream, or null when the point lies in the letterbox. */
    fun normalize(rect: StreamRect, x: Float, y: Float): Norm? {
        if (rect.width <= 0f || rect.height <= 0f) return null
        val nx = (x - rect.left) / rect.width
        val ny = (y - rect.top) / rect.height
        return if (nx < 0f || nx > 1f || ny < 0f || ny > 1f) null else Norm(nx, ny)
    }

    /** Like [normalize] but clamps into the stream (for move/up of a gesture that began inside). */
    fun normalizeClamped(rect: StreamRect, x: Float, y: Float): Norm {
        if (rect.width <= 0f || rect.height <= 0f) return Norm(0f, 0f)
        return Norm(
            ((x - rect.left) / rect.width).coerceIn(0f, 1f),
            ((y - rect.top) / rect.height).coerceIn(0f, 1f),
        )
    }
}
