package com.hiddify.hiddify

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Build
import android.util.Base64
import com.google.gson.Gson
import com.google.gson.annotations.SerializedName
import com.hiddify.hiddify.Application.Companion.packageManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import io.flutter.plugin.common.StandardMethodCodec
import kotlinx.coroutines.GlobalScope
import kotlinx.coroutines.launch
import java.io.ByteArrayOutputStream


class PlatformSettingsHandler : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware,
    PluginRegistry.ActivityResultListener {
    private var channel: MethodChannel? = null
    private var activity: Activity? = null
    private lateinit var ignoreRequestResult: MethodChannel.Result

    companion object {
        const val channelName = "com.hiddify.app/platform"

        const val REQUEST_IGNORE_BATTERY_OPTIMIZATIONS = 44
        val gson = Gson()

        enum class Trigger(val method: String) {
            IsIgnoringBatteryOptimizations("is_ignoring_battery_optimizations"),
            RequestIgnoreBatteryOptimizations("request_ignore_battery_optimizations"),
            GetInstalledPackages("get_installed_packages"),
            GetPackagesIcon("get_package_icon"),
            // 只要这一个 App 的名字和图标。不要 getInstalledApplications：那一下会扫整机应用，
            // ColorOS / MIUI 就弹「读取应用列表」。
            AppLabel("app_label"),
            // OneRay：新用户打开 App 时看手机上是不是开着别家 VPN（我们自己的没连时才问）。
            OtherVpnActive("other_vpn_active"),
            OpenVpnSettings("open_vpn_settings"),
            // OneRay：这台手机有没有允许过光速雷达建 VPN（没允许过，第一次连接前先弹说明卡）。
            VpnPermissionGranted("vpn_permission_granted"),
            // OneRay：App 退后台后盯客服回复（见 SupportWatch），回前台停。
            SupportWatchStart("support_watch_start"),
            SupportWatchStop("support_watch_stop"),
            // OneRay：用着用着断了 / 线路不通被断开 —— 发一条系统通知（App 在后台也看得到）。
            ShowDropNotice("show_drop_notice"),
            // OneRay：核心最近一次是怎么停的（见 BoxService.lastStopReason）。
            LastStopReason("last_stop_reason"),
            // OneRay：连接失败「请允许光速雷达发通知」那个按钮。
            OpenNotificationSettings("open_notification_settings"),
        }
        private const val dropChannel = "connection_drop"
        private const val dropNotificationId = 2
    }

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        val taskQueue = flutterPluginBinding.binaryMessenger.makeBackgroundTaskQueue()
        channel = MethodChannel(
            flutterPluginBinding.binaryMessenger,
            channelName,
            StandardMethodCodec.INSTANCE,
            taskQueue
        )
        channel!!.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode == REQUEST_IGNORE_BATTERY_OPTIMIZATIONS) {
            ignoreRequestResult.success(resultCode == Activity.RESULT_OK)
            return true
        }
        return false
    }

    data class AppItem(
        @SerializedName("package-name") val packageName: String,
        @SerializedName("name") val name: String,
        @SerializedName("is-system-app") val isSystemApp: Boolean
    )

    @SuppressLint("BatteryLife")
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            Trigger.IsIgnoringBatteryOptimizations.method -> {
                result.runCatching {
                    success(
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                            Application.powerManager.isIgnoringBatteryOptimizations(Application.application.packageName)
                        } else {
                            true
                        }
                    )
                }
            }

            Trigger.RequestIgnoreBatteryOptimizations.method -> {
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
                    return result.success(true)
                }
                val intent = Intent(
                    android.provider.Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    Uri.parse("package:${Application.application.packageName}")
                )
                ignoreRequestResult = result
                activity?.startActivityForResult(intent, REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
            }

            Trigger.GetInstalledPackages.method -> {
                GlobalScope.launch {
                    result.runCatching {
                        val flag = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                            PackageManager.GET_PERMISSIONS or PackageManager.MATCH_UNINSTALLED_PACKAGES
                        } else {
                            @Suppress("DEPRECATION")
                            PackageManager.GET_PERMISSIONS or PackageManager.GET_UNINSTALLED_PACKAGES
                        }
                        val installedPackages =
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                                packageManager.getInstalledPackages(
                                    PackageManager.PackageInfoFlags.of(
                                        flag.toLong()
                                    )
                                )
                            } else {
                                @Suppress("DEPRECATION")
                                packageManager.getInstalledPackages(flag)
                            }
                        val list = mutableListOf<AppItem>()
                        installedPackages.forEach {
                            if (it.packageName != Application.application.packageName &&
                                (it.requestedPermissions?.contains(Manifest.permission.INTERNET) == true
                                        || it.packageName == "android")
                            ) {
                                list.add(
                                    AppItem(
                                        it.packageName,
                                        it.applicationInfo?.loadLabel(packageManager).toString(),
                                        (it.applicationInfo?.flags?.and(ApplicationInfo.FLAG_SYSTEM) == 1)
                                    )
                                )
                            }
                        }
                        list.sortBy { it.name }
                        success(gson.toJson(list))
                    }
                }
            }

            Trigger.GetPackagesIcon.method -> {
                result.runCatching {
                    val args = call.arguments as Map<*, *>
                    val packageName =
                        args["packageName"] as String
                    val drawable = packageManager.getApplicationIcon(packageName)
                    val bitmap = Bitmap.createBitmap(
                        drawable.intrinsicWidth,
                        drawable.intrinsicHeight,
                        Bitmap.Config.ARGB_8888
                    )
                    val canvas = Canvas(bitmap)
                    drawable.setBounds(0, 0, canvas.width, canvas.height)
                    drawable.draw(canvas)
                    val byteArrayOutputStream = ByteArrayOutputStream()
                    bitmap.compress(Bitmap.CompressFormat.PNG, 100, byteArrayOutputStream)
                    val base64: String =
                        Base64.encodeToString(byteArrayOutputStream.toByteArray(), Base64.NO_WRAP)
                    success(base64)
                }
            }

            Trigger.AppLabel.method -> {
                val packageName = (call.arguments as? Map<*, *>)?.get("packageName") as? String
                if (packageName.isNullOrEmpty()) {
                    result.success(null)
                } else {
                    result.runCatching {
                        val info = packageManager.getApplicationInfo(packageName, 0)
                        val name = info.loadLabel(packageManager).toString()
                        val drawable = packageManager.getApplicationIcon(packageName)
                        val bitmap = Bitmap.createBitmap(
                            drawable.intrinsicWidth.coerceAtLeast(1),
                            drawable.intrinsicHeight.coerceAtLeast(1),
                            Bitmap.Config.ARGB_8888
                        )
                        val canvas = Canvas(bitmap)
                        drawable.setBounds(0, 0, canvas.width, canvas.height)
                        drawable.draw(canvas)
                        val bytes = ByteArrayOutputStream()
                        bitmap.compress(Bitmap.CompressFormat.PNG, 100, bytes)
                        success(mapOf("name" to name, "icon" to bytes.toByteArray()))
                    }.onFailure { result.success(null) }
                }
            }

            Trigger.OtherVpnActive.method -> {
                result.runCatching {
                    val cm = Application.connectivity
                    @Suppress("DEPRECATION")
                    val active = cm.allNetworks.any { n ->
                        cm.getNetworkCapabilities(n)?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true
                    }
                    success(active)
                }.onFailure { result.success(false) }
            }

            Trigger.OpenNotificationSettings.method -> {
                result.runCatching {
                    val ctx = activity ?: Application.application
                    val pkg = Application.application.packageName
                    val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        Intent(android.provider.Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                            .putExtra(android.provider.Settings.EXTRA_APP_PACKAGE, pkg)
                    } else {
                        Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$pkg"))
                    }
                    if (activity == null) intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    ctx.startActivity(intent)
                    success(true)
                }.onFailure { result.success(false) }
            }

            Trigger.LastStopReason.method -> {
                result.success(com.hiddify.hiddify.bg.BoxService.lastStopReason)
            }

            Trigger.ShowDropNotice.method -> {
                result.runCatching {
                    val args = call.arguments as? Map<*, *>
                    val title = args?.get("title") as? String ?: "光速雷达已断开"
                    val text = args?.get("text") as? String ?: ""
                    val ctx = Application.application
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        Application.notification.createNotificationChannel(
                            android.app.NotificationChannel(
                                dropChannel, "连接断开提醒", android.app.NotificationManager.IMPORTANCE_DEFAULT
                            )
                        )
                    }
                    val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
                        android.app.PendingIntent.FLAG_IMMUTABLE else 0
                    val open = android.app.PendingIntent.getActivity(
                        ctx, 1,
                        Intent(ctx, MainActivity::class.java).setFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT),
                        flags
                    )
                    val n = androidx.core.app.NotificationCompat.Builder(ctx, dropChannel)
                        .setSmallIcon(R.drawable.ic_stat_logo)
                        .setContentTitle(title)
                        .setContentText(text)
                        .setStyle(androidx.core.app.NotificationCompat.BigTextStyle().bigText(text))
                        .setAutoCancel(true)
                        .setContentIntent(open)
                        .build()
                    // 没通知权限时 notify 什么都不做，不会崩。
                    Application.notification.notify(dropNotificationId, n)
                    success(true)
                }.onFailure { result.success(false) }
            }

            Trigger.SupportWatchStart.method -> {
                result.runCatching {
                    val args = call.arguments as Map<*, *>
                    SupportWatch.start(
                        Application.application,
                        args["url"] as String,
                        args["token"] as String,
                        (args["lastSeen"] as Number).toLong(),
                        (args["until"] as Number).toLong(),
                    )
                    success(true)
                }.onFailure { result.success(false) }
            }

            Trigger.SupportWatchStop.method -> {
                result.runCatching {
                    SupportWatch.stop(Application.application)
                    success(true)
                }.onFailure { result.success(false) }
            }

            Trigger.VpnPermissionGranted.method -> {
                result.runCatching {
                    success(android.net.VpnService.prepare(activity ?: Application.application) == null)
                }.onFailure { result.success(true) }
            }

            Trigger.OpenVpnSettings.method -> {
                result.runCatching {
                    val ctx = activity ?: Application.application
                    val intent = Intent(android.provider.Settings.ACTION_VPN_SETTINGS)
                    if (activity == null) intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    try {
                        ctx.startActivity(intent)
                    } catch (e: Exception) {
                        // 少数系统没有单独的 VPN 设置页：退到「无线和网络」总设置
                        val fallback = Intent(android.provider.Settings.ACTION_WIRELESS_SETTINGS)
                        if (activity == null) fallback.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        ctx.startActivity(fallback)
                    }
                    success(true)
                }.onFailure { result.success(false) }
            }

            else -> result.notImplemented()
        }
    }
}