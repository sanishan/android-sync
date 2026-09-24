package dev.androidsync

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import java.net.Inet4Address
import java.util.concurrent.ConcurrentHashMap

/** Bonjour discovery with the Android 12 resolver and Android 14 callback APIs. */
class Discovery(private val context: Context, private val update: () -> Unit) {
    private val manager = context.getSystemService(NsdManager::class.java)
    val endpoints = ConcurrentHashMap<String, Pair<String, Int>>()
    private val callbacks = ConcurrentHashMap<String, NsdManager.ServiceInfoCallback>()
    private val resolving = ConcurrentHashMap.newKeySet<String>()
    private var started = false

    private val listener = object : NsdManager.DiscoveryListener {
        override fun onDiscoveryStarted(type: String) = Unit
        override fun onDiscoveryStopped(type: String) = Unit
        override fun onStartDiscoveryFailed(type: String, error: Int) { started = false }
        override fun onStopDiscoveryFailed(type: String, error: Int) = Unit
        override fun onServiceLost(service: NsdServiceInfo) {
            endpoints.remove(service.serviceName)
            resolving.remove(service.serviceName)
            if (Build.VERSION.SDK_INT >= 34) callbacks.remove(service.serviceName)?.let { callback ->
                runCatching { manager.unregisterServiceInfoCallback(callback) }
            }
            update()
        }
        override fun onServiceFound(service: NsdServiceInfo) {
            if (!service.serviceType.startsWith("_androidsync._tcp")) return
            if (Build.VERSION.SDK_INT >= 34) registerModern(service) else resolveLegacy(service)
        }
    }

    @androidx.annotation.RequiresApi(34)
    private fun registerModern(service: NsdServiceInfo) {
        if (callbacks.containsKey(service.serviceName)) return
        val callback = object : NsdManager.ServiceInfoCallback {
            override fun onServiceInfoCallbackRegistrationFailed(error: Int) { callbacks.remove(service.serviceName) }
            override fun onServiceInfoCallbackUnregistered() = Unit
            override fun onServiceLost() { endpoints.remove(service.serviceName); update() }
            override fun onServiceUpdated(info: NsdServiceInfo) {
                val address = info.hostAddresses.firstOrNull { it is Inet4Address && it.isSiteLocalAddress }
                    ?: info.hostAddresses.firstOrNull { it.isLinkLocalAddress || it.isSiteLocalAddress } ?: return
                endpoints[service.serviceName] = (address.hostAddress ?: return) to info.port
                update()
            }
        }
        callbacks[service.serviceName] = callback
        runCatching { manager.registerServiceInfoCallback(service, context.mainExecutor, callback) }
            .onFailure { callbacks.remove(service.serviceName) }
    }

    @Suppress("DEPRECATION")
    private fun resolveLegacy(service: NsdServiceInfo) {
        if (!resolving.add(service.serviceName)) return
        manager.resolveService(service, object : NsdManager.ResolveListener {
            override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) { resolving.remove(service.serviceName) }
            override fun onServiceResolved(info: NsdServiceInfo) {
                resolving.remove(service.serviceName)
                val address = info.host ?: return
                endpoints[service.serviceName] = (address.hostAddress ?: return) to info.port
                update()
            }
        })
    }

    @Synchronized fun start() {
        if (started) return
        started = true
        runCatching { manager.discoverServices("_androidsync._tcp.", NsdManager.PROTOCOL_DNS_SD, listener) }
            .onFailure { started = false }
    }

    @Synchronized fun stop() {
        if (started) runCatching { manager.stopServiceDiscovery(listener) }
        if (Build.VERSION.SDK_INT >= 34) callbacks.values.forEach { callback ->
            runCatching { manager.unregisterServiceInfoCallback(callback) }
        }
        callbacks.clear(); resolving.clear(); endpoints.clear(); started = false
    }
}
