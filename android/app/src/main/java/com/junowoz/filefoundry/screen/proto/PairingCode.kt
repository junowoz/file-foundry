package com.junowoz.filefoundry.screen.proto

import java.util.Locale

object PairingCode {
    const val ALPHABET = "23456789ABCDEFGHJKMNPQRSTUVWXYZ"
    const val LENGTH = 12

    /**
     * Uppercase, drop anything outside the alphabet (separators, spaces and 0/1/I/L/O are rejected,
     * never mapped to look-alikes), cap at 12.
     */
    fun normalize(raw: String): String =
        raw.uppercase(Locale.ROOT).filter { it in ALPHABET }.take(LENGTH)

    /** Display form `XXXX-XXXX-XXXX`; [normalize] undoes it. */
    fun format(raw: String): String = normalize(raw).chunked(4).joinToString("-")

    fun isComplete(raw: String) = normalize(raw).length == LENGTH
}
