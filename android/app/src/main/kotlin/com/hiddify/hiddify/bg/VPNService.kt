package com.hiddify.hiddify.bg
import android.util.Log

import com.hiddify.hiddify.Settings
import android.content.Intent
import android.content.pm.PackageManager.NameNotFoundException
import android.net.ProxyInfo
import android.net.VpnService
import android.os.Build
import android.os.IBinder
import android.os.ParcelFileDescriptor
import com.hiddify.core.libbox.Notification
import com.hiddify.hiddify.constant.PerAppProxyMode
import com.hiddify.hiddify.ktx.toIpPrefix
import com.hiddify.core.libbox.TunOptions
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext

class VPNService : VpnService(), PlatformInterfaceWrapper {

    companion object {
        private const val TAG = "A/VPNService"
    }

    private val service = BoxService(this, this)

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int) =
        service.onStartCommand()

    override fun onBind(intent: Intent): IBinder {
        val binder = super.onBind(intent)
        if (binder != null) {
            return binder
        }
        return service.onBind(intent)
    }

    override fun onDestroy() {
        service.onDestroy()
    }

    override fun onRevoke() {
        runBlocking {
            withContext(Dispatchers.Main) {
                service.onRevoke()
            }
        }
    }

    override fun autoDetectInterfaceControl(fd: Int) {
        protect(fd)
    }

    var systemProxyAvailable = false
    var systemProxyEnabled = false
    fun addIncludePackage(builder: Builder, packageName: String) {
        if (packageName == this.packageName) { 
            Log.d("VpnService","Cannot include myself: $packageName")
            return
        }
        try {     
            Log.d("VpnService","Including $packageName")
            builder.addAllowedApplication(packageName)
        } catch (e: NameNotFoundException) {
        }
    }

    // Downloaders never enter the tunnel, so they use the phone's own network.
    // Two lists (VPN repo docs/计划/智能分流-自己改网站.md 三.2); when adding a
    // downloader, decide which one it belongs to first:
    //  - btPackages: BitTorrent / Xunlei. Always excluded; the smart-split page
    //    shows them as locked ("下载软件，只能走本地"). Proxying them risks
    //    copyright complaints and burns traffic.
    //  - plainDownloaderPackages: plain downloaders. Excluded by default; the user
    //    can switch one to "智能分流" (Settings.gslSplitDownloaders), then it is
    //    routed per site like any other app.
    // Browsers are not listed. Missing packages throw NameNotFoundException and
    // are ignored. PikPak (com.pikcloud.pikpak) stays in the tunnel: its share
    // pages reject mainland IPs.
    private val btPackages = listOf(
        "com.xunlei.downloadprovider",
        "com.bittorrent.client",
        "com.utorrent.client",
        "org.proninyaroslav.libretorrent",
        "com.frostwire.android",
        "com.biglybt.android.client",
    )
    private val plainDownloaderPackages = listOf(
        "com.dv.adm",
        "com.dv.adm.pay",
        "idm.internet.download.manager",
        "idm.internet.download.manager.plus",
        "com.gopeed.gopeed",
    )

    // Everything kept out of the tunnel for smart split: BT apps, plain
    // downloaders the user did not switch, and apps the user (or the server
    // default) set to "整个走本地". Never our own package.
    private fun excludedForSplit(): List<String> =
        (btPackages + (plainDownloaderPackages - Settings.gslSplitDownloaders.toSet()) + Settings.gslDirectApps)
            .distinct()
            .filter { it != packageName }

    private fun excludeDownloaders(builder: Builder) {
        excludedForSplit().forEach { pkg ->
            Log.d("VpnService", "Excluding for split $pkg")
            addExcludePackage(builder, pkg)
        }
    }

    fun addExcludePackage(builder: Builder, packageName: String) {
        try {     
            Log.d("VpnService","Excluding $packageName")
            builder.addDisallowedApplication(packageName)
        } catch (e: NameNotFoundException) {
        }
    }

    override fun openTun(options: TunOptions): Int {
        var hasPermission = false
        for (i in 0 until 20) {
            if (prepare(this) != null) {
                Log.w("VPN", "android: missing vpn permission")
            } else {
                hasPermission = true
                break
            }
            Thread.sleep(50)
        }

        if (!hasPermission) {
             error("android: missing vpn permission")
    }
//        service.fileDescriptor?.close()

        val builder = Builder()
            .setSession("hiddify")
            .setMtu(options.mtu)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            builder.setMetered(false)
        }

        val inet4Address = options.inet4Address
        while (inet4Address.hasNext()) {
            val address = inet4Address.next()
            builder.addAddress(address.address(), address.prefix())
        }

        val inet6Address = options.inet6Address
        while (inet6Address.hasNext()) {
            val address = inet6Address.next()
            builder.addAddress(address.address(), address.prefix())
        }

        if (options.autoRoute) {
            builder.addDnsServer(options.dnsServerAddress.value)

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val inet4RouteAddress = options.inet4RouteAddress
                if (inet4RouteAddress.hasNext()) {
                    while (inet4RouteAddress.hasNext()) {
                        builder.addRoute(inet4RouteAddress.next().toIpPrefix())
                    }
                } else {
                    builder.addRoute("0.0.0.0", 0)
                }

                val inet6RouteAddress = options.inet6RouteAddress
                if (inet6RouteAddress.hasNext()) {
                    while (inet6RouteAddress.hasNext()) {
                        builder.addRoute(inet6RouteAddress.next().toIpPrefix())
                    }
                } else {
                    builder.addRoute("::", 0)
                }

                val inet4RouteExcludeAddress = options.inet4RouteExcludeAddress
                while (inet4RouteExcludeAddress.hasNext()) {
                    builder.excludeRoute(inet4RouteExcludeAddress.next().toIpPrefix())
                }

                val inet6RouteExcludeAddress = options.inet6RouteExcludeAddress
                while (inet6RouteExcludeAddress.hasNext()) {
                    builder.excludeRoute(inet6RouteExcludeAddress.next().toIpPrefix())
                }
            } else {
                val inet4RouteAddress = options.inet4RouteRange
                if (inet4RouteAddress.hasNext()) {
                    while (inet4RouteAddress.hasNext()) {
                        val address = inet4RouteAddress.next()
                        builder.addRoute(address.address(), address.prefix())
                    }
                }

                val inet6RouteAddress = options.inet6RouteRange
                if (inet6RouteAddress.hasNext()) {
                    while (inet6RouteAddress.hasNext()) {
                        val address = inet6RouteAddress.next()
                        builder.addRoute(address.address(), address.prefix())
                    }
                }
            }

            if (Settings.perAppProxyEnabled) {
                val appList = Settings.perAppProxyList
                if (Settings.perAppProxyMode == PerAppProxyMode.INCLUDE) {
                    // Cannot mix allow and disallow. Drop downloaders from the
                    // allow-list instead of calling addDisallowedApplication.
                    val excluded = excludedForSplit().toSet()
                    appList.filter { it !in excluded }.forEach {
                        addIncludePackage(builder,it)
                    }
//                    addIncludePackage(builder,packageName)
                } else {
                    appList.forEach {
                        addExcludePackage(builder,it)
                    }
                    excludeDownloaders(builder)
                    addExcludePackage(builder,packageName)
                }
            } else {
                val includePackage = options.includePackage
                if (includePackage.hasNext()) {
                    val excluded = excludedForSplit().toSet()
                    while (includePackage.hasNext()) {
                        val pkg = includePackage.next()
                        if (pkg !in excluded) {
                            addIncludePackage(builder, pkg)
                        }
                    }
                    //                    addIncludePackage(builder,packageName)
                }else {
                    val excludePackage = options.excludePackage
                    if (excludePackage.hasNext()) {
                        while (excludePackage.hasNext()) {
                            addExcludePackage(builder, excludePackage.next())
                        }
                    }

                    excludeDownloaders(builder)
                    addExcludePackage(builder, packageName)
                }
                
            }
        }

        if (options.isHTTPProxyEnabled && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            systemProxyAvailable = true
            systemProxyEnabled = Settings.systemProxyEnabled
            if (systemProxyEnabled) builder.setHttpProxy(
                ProxyInfo.buildDirectProxy(
                    options.httpProxyServer, options.httpProxyServerPort
                )
            )
        } else {
            systemProxyAvailable = false
            systemProxyEnabled = false
        }

        val pfd = builder.establish() ?: error("android: the application is not prepared or is revoked")
        service.fileDescriptor = pfd
        return pfd.fd
    }

//    override fun writeLog(message: String) = service.writeLog(message)

    override fun sendNotification(notification: Notification) {
//        service.sendNotification(notification)
    }
}