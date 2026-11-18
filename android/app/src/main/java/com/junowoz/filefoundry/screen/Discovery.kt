package com.junowoz.filefoundry.screen

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Handler
import android.os.Looper

class FoundMac(val name: String, val host: String, val port: Int)

/** NSD browse for `_ffscreen._tcp`, resolving one service at a time. */
class Discovery(context: Context, private val onChange: (List<FoundMac>) -> Unit) {
    private val nsd = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val main = Handler(Looper.getMainLooper())
    private val found = LinkedHashMap<String, FoundMac>()
    private val pending = ArrayDeque<NsdServiceInfo>()
    private var resolving = false
    private var listener: NsdManager.DiscoveryListener? = null

    fun start() {
        if (listener != null) return
        val l = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {}
            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) { listener = null }
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
            override fun onServiceFound(info: NsdServiceInfo) {
                main.post { pending.addLast(info); next() }
            }
            override fun onServiceLost(info: NsdServiceInfo) {
                main.post { if (found.remove(info.serviceName) != null) onChange(found.values.toList()) }
            }
        }
        listener = l
        try {
            nsd.discoverServices("_ffscreen._tcp.", NsdManager.PROTOCOL_DNS_SD, l)
        } catch (_: Exception) {
            listener = null
        }
    }

    fun stop() {
        listener?.let { try { nsd.stopServiceDiscovery(it) } catch (_: Exception) {} }
        listener = null
        pending.clear()
        found.clear()
        resolving = false
    }

    @Suppress("DEPRECATION")
    private fun next() {
        if (resolving) return
        val info = pending.removeFirstOrNull() ?: return
        resolving = true
        nsd.resolveService(info, object : NsdManager.ResolveListener {
            override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                main.post { resolving = false; next() }
            }
            override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                main.post {
                    val ip = serviceInfo.host?.hostAddress
                    if (ip != null) {
                        found[serviceInfo.serviceName] = FoundMac(serviceInfo.serviceName, ip, serviceInfo.port)
                        onChange(found.values.toList())
                    }
                    resolving = false
                    next()
                }
            }
        })
    }
}
