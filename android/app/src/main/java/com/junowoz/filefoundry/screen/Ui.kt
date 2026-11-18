package com.junowoz.filefoundry.screen

import android.content.Context
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.content.res.ColorStateList
import android.view.Gravity
import android.view.View
import android.widget.Button
import android.widget.TextView

/** Tiny view helpers so the screens stay plain Views with no XML or libraries. */
object Ui {
    const val BG = 0xFF0B0B0D.toInt()
    const val SURFACE = 0xFF17171B.toInt()
    const val ACCENT = 0xFF4C8DFF.toInt()
    const val TEXT = 0xFFF2F2F5.toInt()
    const val MUTED = 0xFF8D8D98.toInt()

    fun dp(ctx: Context, v: Int) = (v * ctx.resources.displayMetrics.density + 0.5f).toInt()

    fun background(ctx: Context, fill: Int, radiusDp: Int): RippleDrawable {
        val shape = GradientDrawable().apply {
            setColor(fill)
            cornerRadius = dp(ctx, radiusDp).toFloat()
        }
        return RippleDrawable(ColorStateList.valueOf(0x33FFFFFF), shape, null)
    }

    fun button(ctx: Context, label: String, primary: Boolean, onClick: () -> Unit): Button = Button(ctx).apply {
        text = label
        isAllCaps = false
        textSize = 16f
        setTextColor(if (primary) Color.WHITE else TEXT)
        background = background(ctx, if (primary) ACCENT else SURFACE, 14)
        minHeight = dp(ctx, 52)
        minimumHeight = dp(ctx, 52)
        stateListAnimator = null
        setOnClickListener { onClick() }
    }

    fun text(ctx: Context, s: String, sizeSp: Float, color: Int, bold: Boolean = false): TextView = TextView(ctx).apply {
        text = s
        textSize = sizeSp
        setTextColor(color)
        if (bold) setTypeface(typeface, android.graphics.Typeface.BOLD)
        gravity = Gravity.START
    }

    fun gone(v: View) { v.visibility = View.GONE }
}
