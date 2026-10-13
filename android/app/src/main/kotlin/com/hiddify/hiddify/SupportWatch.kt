package com.hiddify.hiddify

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.TimeUnit

/**
 * OneRay：App 退到后台后，替界面盯着客服有没有回复（10-14 运营：安卓切后台完全收不到客服回复）。
 *
 * - 只在「他最近 2 小时内给客服发过消息」时盯（Dart 退后台时调 start，回前台调 stop）。
 * - 两条路一起查，谁先到谁算：连着光速雷达时 VPN 前台服务每分钟查一次（BoxService 调 checkFromService）；
 *   没连时靠系统定时任务（WorkManager，最快 15 分钟一次，国产系统可能更晚）。
 * - 查到 id 比上次大的客服消息 → 发一条系统通知「客服回复了」，点一下打开 oneray://support（客服页）。
 *   有通知时安卓 8 以上的桌面图标自己会出小圆点。
 */
object SupportWatch {
    private const val prefs = "oneray_support_watch"
    private const val channelId = "support_reply"
    private const val notificationId = 3
    private const val workName = "oneray_support_watch"

    fun start(ctx: Context, url: String, token: String, lastSeen: Long, until: Long) {
        ctx.getSharedPreferences(prefs, Context.MODE_PRIVATE).edit()
            .putString("url", url).putString("token", token)
            .putLong("lastSeen", lastSeen).putLong("until", until)
            .apply()
        val req = PeriodicWorkRequestBuilder<Worker>(15, TimeUnit.MINUTES)
            .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .build()
        WorkManager.getInstance(ctx).enqueueUniquePeriodicWork(workName, ExistingPeriodicWorkPolicy.UPDATE, req)
    }

    fun stop(ctx: Context) {
        ctx.getSharedPreferences(prefs, Context.MODE_PRIVATE).edit().clear().apply()
        WorkManager.getInstance(ctx).cancelUniqueWork(workName)
    }

    private fun active(ctx: Context): Boolean {
        val p = ctx.getSharedPreferences(prefs, Context.MODE_PRIVATE)
        val until = p.getLong("until", 0)
        if (until <= 0) return false
        if (System.currentTimeMillis() > until) {
            stop(ctx)
            return false
        }
        return true
    }

    /** VPN 前台服务每分钟调一次（它本来就在跑，不额外耗电）。不在盯的时候什么都不做。 */
    fun checkFromService(ctx: Context) {
        if (!active(ctx)) return
        Thread { runCatching { check(ctx) } }.start()
    }

    /** 查一次。同一时间只跑一个，免得服务和定时任务一起查发两条通知。 */
    @Synchronized
    fun check(ctx: Context) {
        if (!active(ctx)) return
        val p = ctx.getSharedPreferences(prefs, Context.MODE_PRIVATE)
        val url = p.getString("url", null) ?: return
        val token = p.getString("token", null) ?: return
        val lastSeen = p.getLong("lastSeen", 0)
        val conn = (URL(url).openConnection() as HttpURLConnection).apply {
            connectTimeout = 15000
            readTimeout = 20000
            setRequestProperty("X-Auth-Token", token)
            setRequestProperty("User-Agent", "OneRay-Android")
        }
        try {
            if (conn.responseCode != 200) return
            val body = conn.inputStream.bufferedReader().use { it.readText() }
            val arr: JSONArray = when (val root = runCatching { JSONObject(body) }.getOrNull()) {
                null -> JSONArray(body)
                else -> root.optJSONArray("payload") ?: JSONArray()
            }
            var maxId = lastSeen
            var preview = ""
            var count = 0
            for (i in 0 until arr.length()) {
                val m = arr.optJSONObject(i) ?: continue
                // message_type：0 = 客户发的，1 = 客服发的，2/3 = 系统消息
                if (m.optInt("message_type", -1) != 1) continue
                val id = m.optLong("id", 0)
                if (id <= lastSeen) continue
                val text = m.optString("content", "").trim()
                val hasImage = (m.optJSONArray("attachments")?.length() ?: 0) > 0
                if (text.isEmpty() && !hasImage) continue
                count++
                if (id > maxId) {
                    maxId = id
                    preview = text.ifEmpty { "[图片]" }
                }
            }
            if (count == 0) return
            p.edit().putLong("lastSeen", maxId).apply()
            notify(ctx, preview, count)
        } finally {
            conn.disconnect()
        }
    }

    private fun notify(ctx: Context, preview: String, count: Int) {
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(channelId, "客服回复", NotificationManager.IMPORTANCE_HIGH)
                    .apply { setShowBadge(true) }
            )
        }
        val open = Intent(Intent.ACTION_VIEW, Uri.parse("oneray://support"))
            .setPackage(ctx.packageName)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        val pi = PendingIntent.getActivity(
            ctx, notificationId, open,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val n = NotificationCompat.Builder(ctx, channelId)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(if (count > 1) "客服回复了 $count 条消息" else "客服回复了")
            .setContentText(preview)
            .setStyle(NotificationCompat.BigTextStyle().bigText(preview))
            .setNumber(count)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setContentIntent(pi)
            .build()
        runCatching { nm.notify(notificationId, n) }
    }

    class Worker(ctx: Context, params: WorkerParameters) : CoroutineWorker(ctx, params) {
        override suspend fun doWork(): Result = withContext(Dispatchers.IO) {
            runCatching { check(applicationContext) }
            Result.success()
        }
    }
}
