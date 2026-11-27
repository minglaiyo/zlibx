package com.minglaiyo.zlibx

import android.content.Context
import android.net.ConnectivityManager
import android.os.Build
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/// Network facts for the Web service address picker
/// (`zlibx/network_state` channel). Dart does the selection; this
/// only reports facts.
///
/// Best-effort by design: every sub-query keeps its own catch and
/// the answer degrades to partial data (empty interface list, no
/// hotspot) rather than failing the whole call. Only an unexpected
/// throw reaches the runner, which answers `result.error`
/// ("lan_address_failed"); Dart maps that to null and falls back
/// to its interface-name list, as before.
class NetworkStateHandler(
    private val context: Context,
    private val runner: ChannelRunner,
) {

    /// Dispatches the network_state methods this handler owns.
    /// Returns true when [call] was handled; false otherwise.
    fun handleMethod(call: MethodCall, result: MethodChannel.Result): Boolean {
        if (call.method != "lanAddressInfo") return false
        runner.runAsync(result, runner.lightExecutor, "lan_address_failed") {
            lanAddressInfo()
        }
        return true
    }

    /// Facts for the Dart address picker (see lan_share.dart):
    /// `hotspotOn`, `wifiConnected` and one entry per IPv4 interface with
    /// a `kind` of hotspot / wifi / cellular / other. Hotspot interface
    /// names come from, in order: TetheringManager (API 30+) →
    /// ConnectivityManager.tetheredInterfaces (API 24+) → DhcpInfo's
    /// server address, which only counts when it is non-zero AND Wi-Fi
    /// is not enabled (otherwise it is the upstream router, not us).
    fun lanAddressInfo(): Map<String, Any?> {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE)
            as? ConnectivityManager

        val wifiNames = HashSet<String>()
        val cellularNames = HashSet<String>()
        try {
            @Suppress("DEPRECATION")
            val networks = cm?.allNetworks ?: emptyArray()
            for (network in networks) {
                val caps = cm?.getNetworkCapabilities(network) ?: continue
                val name = cm?.getLinkProperties(network)?.interfaceName ?: continue
                if (caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_WIFI)) {
                    wifiNames.add(name)
                } else if (caps.hasTransport(
                        android.net.NetworkCapabilities.TRANSPORT_CELLULAR,
                    )
                ) {
                    cellularNames.add(name)
                }
            }
        } catch (e: Exception) {
            Log.w(NATIVE_TAG, "network classification failed", e)
        }

        val hotspotNames = tetheredInterfaceNames(cm)

        // DhcpInfo fallback: usable as the hotspot address only when
        // Wi-Fi is NOT enabled and the server address is non-zero.
        var dhcpHotspotAddress: String? = null
        try {
            @Suppress("DEPRECATION")
            val wifi = context.applicationContext.getSystemService(
                Context.WIFI_SERVICE,
            ) as? android.net.wifi.WifiManager
            @Suppress("DEPRECATION")
            val server = wifi?.dhcpInfo?.serverAddress ?: 0
            if (wifi != null && !wifi.isWifiEnabled && server != 0) {
                dhcpHotspotAddress = String.format(
                    java.util.Locale.US,
                    "%d.%d.%d.%d",
                    server and 0xff,
                    (server shr 8) and 0xff,
                    (server shr 16) and 0xff,
                    (server shr 24) and 0xff,
                )
            }
        } catch (e: Exception) {
            Log.w(NATIVE_TAG, "dhcp info failed", e)
        }

        val interfaces = ArrayList<Map<String, Any?>>()
        var hotspotSeen = false
        try {
            val all = java.net.NetworkInterface.getNetworkInterfaces()
            while (all != null && all.hasMoreElements()) {
                val iface = all.nextElement()
                if (!iface.isUp || iface.isLoopback) continue
                val kind = when {
                    hotspotNames.contains(iface.name) -> "hotspot"
                    wifiNames.contains(iface.name) -> "wifi"
                    cellularNames.contains(iface.name) -> "cellular"
                    else -> "other"
                }
                for (addr in iface.inetAddresses.toList()) {
                    if (addr !is java.net.Inet4Address || addr.isLoopbackAddress) continue
                    val text = addr.hostAddress ?: continue
                    if (kind == "hotspot") hotspotSeen = true
                    interfaces.add(
                        mapOf("name" to iface.name, "address" to text, "kind" to kind),
                    )
                }
            }
        } catch (e: Exception) {
            Log.w(NATIVE_TAG, "interface listing failed", e)
        }

        // Neither tethering API named an interface: DhcpInfo's address
        // is the hotspot address. Re-label the interface that owns it
        // (or report it by itself if none does).
        if (!hotspotSeen && dhcpHotspotAddress != null) {
            val index = interfaces.indexOfFirst { it["address"] == dhcpHotspotAddress }
            if (index >= 0) {
                interfaces[index] = interfaces[index] + ("kind" to "hotspot")
            } else {
                interfaces.add(
                    mapOf(
                        "name" to "dhcp",
                        "address" to dhcpHotspotAddress,
                        "kind" to "hotspot",
                    ),
                )
            }
            hotspotSeen = true
        }

        return mapOf(
            "hotspotOn" to hotspotSeen,
            "wifiConnected" to wifiNames.isNotEmpty(),
            "interfaces" to interfaces,
        )
    }

    /// Tethered (hotspot / USB / BT) interface names. Both public-looking
    /// APIs are hidden / permission-gated on many releases, so each is
    /// called reflectively and any failure just falls through to the
    /// next source — an empty set is a normal answer here.
    private fun tetheredInterfaceNames(
        cm: ConnectivityManager?,
    ): Set<String> {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            try {
                val tm = context.getSystemService("tethering")
                if (tm != null) {
                    val method = tm.javaClass.getMethod("getTetheredInterfaces")
                    @Suppress("UNCHECKED_CAST")
                    val names = method.invoke(tm) as? Collection<String>
                    if (!names.isNullOrEmpty()) return names.toSet()
                }
            } catch (e: Exception) {
                Log.i(NATIVE_TAG, "TetheringManager unavailable: ${e.javaClass.simpleName}")
            }
        }
        try {
            val method = ConnectivityManager::class.java
                .getMethod("getTetheredIfaces")
            @Suppress("UNCHECKED_CAST")
            val names = method.invoke(cm) as? Array<String>
            if (!names.isNullOrEmpty()) return names.toSet()
        } catch (e: Exception) {
            Log.i(NATIVE_TAG, "tetheredInterfaces unavailable: ${e.javaClass.simpleName}")
        }
        return emptySet()
    }
}
