package com.hiddify.hiddify.bg

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.Build
import android.os.IBinder
import android.os.ParcelFileDescriptor
import android.os.PowerManager
import android.util.Log
import androidx.annotation.RequiresApi
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.MutableLiveData
import com.hiddify.hiddify.Application
import com.hiddify.hiddify.R
import com.hiddify.hiddify.Settings
import com.hiddify.hiddify.constant.Action
import com.hiddify.hiddify.constant.Alert
import com.hiddify.hiddify.constant.Status
import com.hiddify.core.mobile.SetupOptions

import go.Seq
import com.hiddify.core.libbox.Libbox
import com.hiddify.core.mobile.Mobile


import com.hiddify.core.libbox.CommandServer
import com.hiddify.core.libbox.CommandServerHandler
import com.hiddify.core.libbox.Notification
import com.hiddify.core.libbox.PlatformInterface
import com.hiddify.core.libbox.SystemProxyStatus
import com.hiddify.hiddify.BuildConfig
import com.hiddify.hiddify.MainActivity
import com.hiddify.hiddify.constant.Bugs
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.DelicateCoroutinesApi
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.GlobalScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import java.io.File

class BoxService(
        private val service: Service,
        private val platformInterface: PlatformInterface
)  {

    companion object {
        private const val TAG = "A/BoxService"

        private var initializeOnce = false
        private lateinit var workingDir: File
        private fun initialize() {
            System.setProperty("GODEBUG", "efence=1,stacktraceback=2");
            System.setProperty("GOGC", "off");
            if (initializeOnce) return
            val baseDir = Application.application.filesDir

            baseDir.mkdirs()
            workingDir = Application.application.getExternalFilesDir(null) ?: return
            workingDir.mkdirs()
            val tempDir = Application.application.cacheDir
            tempDir.mkdirs()
            Log.d(TAG, "base dir: ${baseDir.path}")
            Log.d(TAG, "working dir: ${workingDir.path}")
            Log.d(TAG, "temp dir: ${tempDir.path}")

//
            //Mobile.setup(baseDir.path, workingDir.path, tempDir.path,  2L ,"127.0.0.1:{Setting}","",false,this)
//            Libbox.setup(baseDir.path, workingDir.path, tempDir.path, false)

//            Libbox.setup(SetupOptions().also {
//                it.basePath = baseDir.path
//                it.workingPath = workingDir.path
//                it.tempPath = tempDir.path
//                it.fixAndroidStack = Bugs.fixAndroidStack
//
//            })
            Libbox.redirectStderr(File(Settings.workingDir, "stderr.log").path)
            initializeOnce = true
            return
        }

        fun start() {
            val intent = runBlocking {
                withContext(Dispatchers.IO) {
                    Intent(Application.application, Settings.serviceClass())
                }
            }
            ContextCompat.startForegroundService(Application.application, intent)
        }

        // OneRay：最近一次是怎么停的，Dart 用来分「他自己停的」和「被系统 / 别的 VPN 断开」。
        // user = 走 SERVICE_CLOSE（App 断开 / 通知栏停止 / 快捷开关）；revoked = 系统收回 VPN；
        // 空 = 没走正常停止（进程被杀 / 崩溃）。每次启动清空。
        @Volatile
        @JvmStatic
        var lastStopReason: String = ""

        @Volatile
        private var pendingStop: CompletableDeferred<Unit>? = null

        // 给停止入口看：状态已经是 Stopped 时，命令服务可能还开着，这时也要等关掉再连。
        @Volatile
        @JvmStatic
        var commandServerOpen: Boolean = false
            private set

        fun stop(): CompletableDeferred<Unit> {
            val gate = CompletableDeferred<Unit>()
            pendingStop = gate
            Application.application.sendBroadcast(
                    Intent(Action.SERVICE_CLOSE).setPackage(
                            Application.application.packageName
                    )
            )
            return gate
        }


    }

    var fileDescriptor: ParcelFileDescriptor? = null

    private val status = MutableLiveData(Status.Stopped)
    private val binder = ServiceBinder(status)
    private val notification = ServiceNotification(status, service)
//    private var boxService: BoxService? = null
    private var commandServer: CommandServer? = null
    private var receiverRegistered = false
    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                Action.SERVICE_CLOSE -> {
                    lastStopReason = "user"
                    stopService()
                }

                PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        serviceUpdateIdleMode()
                    }
                }
            }
        }
    }
    


    private var activeProfileName = ""
    // Mobile.setup 成功后命令服务还在。核心已经停、或状态已是 Stopped，也不能跳过 Mobile.close，
    // 否则下一次 setup 会抛空消息的 CreateService（tun 授权后立刻重连时碰到）。
    private fun releaseCommandServer() {
        if (!commandServerOpen) return
        runCatching { Mobile.close(4L) }
        commandServerOpen = false
    }

    private fun forceReleaseCommandServer() {
        runCatching { Mobile.close(4L) }
        commandServerOpen = false
    }

    private fun setupMobile() {
        Mobile.setup(
            SetupOptions().also {
                it.basePath = Settings.baseDir
                it.workingDir = Settings.workingDir
                it.tempDir = Settings.tempDir
                it.fixAndroidStack = com.hiddify.hiddify.bg.Bugs.fixAndroidStack
                it.mode = 4L
                it.listen = "127.0.0.1:${Settings.grpcServiceModePort}"
                it.secret = ""
                it.debug = Settings.debugMode
            },
            platformInterface,
        )
        commandServerOpen = true
    }

    private suspend fun startService() {
        try {
            status.postValue(Status.Starting)
            Log.d(TAG, "starting service")
            withContext(Dispatchers.Main) {
                notification.show(activeProfileName, R.string.status_starting)
            }

            val selectedConfigPath = Settings.activeConfigPath
            if (selectedConfigPath.isBlank()) {
                stopAndAlert(Alert.EmptyConfiguration)
                return
            }

            if (Settings.startCoreAfterStartingService && RecommendationStartGuard.blocksAutomaticStart(
                    File(selectedConfigPath).readText(), Settings.hasManualLine) {
                    String(android.util.Base64.decode(it, android.util.Base64.URL_SAFE or android.util.Base64.NO_WRAP), Charsets.UTF_8)
                }) {
                stopAndAlert(Alert.StartService, "暂时没有推荐线路，请打开光速雷达手动选择线路")
                return
            }

            activeProfileName = Settings.activeProfileName

            withContext(Dispatchers.Main) {
                notification.show(activeProfileName, R.string.status_starting)
                binder.broadcast {
                    it.onServiceResetLogs(listOf())
                }
            }

            DefaultNetworkMonitor.start()
            Libbox.setMemoryLimit(!Settings.disableMemoryLimit)
            releaseCommandServer()
            try {
                setupMobile()
            } catch (e: Exception) {
                forceReleaseCommandServer()
                try {
                    setupMobile()
                } catch (e2: Exception) {
                    forceReleaseCommandServer()
                    val detail = e2.message?.takeIf { it.isNotBlank() } ?: e2.javaClass.simpleName
                    stopAndAlert(Alert.CreateService, detail)
                    return
                }
            }
            status.postValue(Status.Started)
            // OneRay：连着的时候顺手每分钟看一眼客服回复（只在 App 退后台、刚给客服发过消息时才真去查）。
            supportTicker?.cancel()
            supportTicker = GlobalScope.launch(Dispatchers.IO) {
                while (true) {
                    kotlinx.coroutines.delay(60_000L)
                    com.hiddify.hiddify.SupportWatch.checkFromService(service)
                }
            }

            if (Settings.startCoreAfterStartingService){
                Mobile.start("","")
                }
//            if (delayStart) {
//                delay(1000L)
//            }

//            newService.start()
//            boxService = newService
//            commandServer?.setService(boxService)


            withContext(Dispatchers.Main) {
                notification.show(activeProfileName, R.string.status_started)
            }
            notification.start()
        } catch (e: Exception) {
            stopAndAlert(Alert.StartService, e.message)
            return
        }
    }

    fun serviceReload() {
        runBlocking {
            serviceReload0()
        }
    }

    suspend fun serviceReload0() {
        notification.close()
        status.postValue(Status.Starting)

        val pfd = fileDescriptor
        if (pfd != null) {
            pfd.close()
            fileDescriptor = null
        }
        
//        boxService?.apply {
//            runCatching {
//                close()
//            }.onFailure {
//                writeLog("service: error when closing: $it")
//            }
//            Seq.destroyRef(refnum)
//        }
        Mobile.stop()
//        boxService = null
        
            startService()
        
    }

    fun getSystemProxyStatus(): SystemProxyStatus {
        val status = SystemProxyStatus()
        if (service is VPNService) {
            status.available = service.systemProxyAvailable
            status.enabled = service.systemProxyEnabled
        }
        return status
    }

    fun setSystemProxyEnabled(isEnabled: Boolean) {
        serviceReload()
    }

    @RequiresApi(Build.VERSION_CODES.M)
    private fun serviceUpdateIdleMode() {
        if (Application.powerManager.isDeviceIdleMode) {
//            boxService?.pause()
            //Mobile.pause()
        } else {
            Mobile.wake()
//            boxService?.wake()
        }
    }

    private fun stopService() {
        val gate = pendingStop
        if (status.value == Status.Stopped && !commandServerOpen) {
            gate?.complete(Unit)
            return
        }
        status.value = Status.Stopping
        supportTicker?.cancel()
        supportTicker = null
        if (receiverRegistered) {
            service.unregisterReceiver(receiver)
            receiverRegistered = false
        }
        notification.close()
        GlobalScope.launch(Dispatchers.IO) {
            try {
                val pfd = fileDescriptor
                if (pfd != null) {
                    pfd.close()
                    fileDescriptor = null
                }
                DefaultNetworkMonitor.stop()
                Settings.startedByUser = false
                withContext(Dispatchers.Main) {
                    releaseCommandServer()
                    status.value = Status.Stopped
                    service.stopSelf()
                }
                notification.close()
            } finally {
                gate?.complete(Unit)
            }
        }
    }

    private suspend fun stopAndAlert(type: Alert, message: String? = null) {
        Settings.startedByUser = false
        releaseCommandServer()
        withContext(Dispatchers.Main) {
            if (receiverRegistered) {
                service.unregisterReceiver(receiver)
                receiverRegistered = false
            }
            notification.close()
            binder.broadcast { callback ->
                callback.onServiceAlert(type.ordinal, message)
            }
            status.value = Status.Stopped
        }
    }

    @OptIn(DelicateCoroutinesApi::class)
    @Suppress("SameReturnValue")
    private var supportTicker: kotlinx.coroutines.Job? = null

    internal fun onStartCommand(): Int {
        if (status.value != Status.Stopped) return Service.START_NOT_STICKY
        status.value = Status.Starting
        lastStopReason = ""

        if (!receiverRegistered) {
            ContextCompat.registerReceiver(service, receiver, IntentFilter().apply {
                addAction(Action.SERVICE_CLOSE)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    addAction(PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED)
                }
            }, ContextCompat.RECEIVER_NOT_EXPORTED)
            receiverRegistered = true
        }

        GlobalScope.launch(Dispatchers.IO) {
            Settings.startedByUser = true
            initialize()
//            try {
//                startCommandServer()
//            } catch (e: Exception) {
//                stopAndAlert(Alert.StartCommandServer, e.message)
//                return@launch
//            }
            startService()
        }
        return Service.START_NOT_STICKY
    }

    fun onBind(intent: Intent): IBinder {
        return binder
    }

    fun onDestroy() {
        binder.close()
    }

    fun onRevoke() {
        lastStopReason = "revoked"
        stopService()
    }

    internal fun sendNotification(notification: Notification) {
        return
        val builder =
            NotificationCompat.Builder(service, notification.identifier).setShowWhen(false)
                .setContentTitle(notification.title).setContentText(notification.body)
                .setOnlyAlertOnce(true).setSmallIcon(R.drawable.ic_stat_logo)
                .setCategory(NotificationCompat.CATEGORY_EVENT)
                .setPriority(NotificationCompat.PRIORITY_HIGH).setAutoCancel(true)
        if (!notification.subtitle.isNullOrBlank()) {
            builder.setContentInfo(notification.subtitle)
        }
        if (!notification.openURL.isNullOrBlank()) {
            builder.setContentIntent(
                PendingIntent.getActivity(
                    service,
                    0,
                    Intent(
                        service,
                        MainActivity::class.java,
                    ).apply {
                        setAction(Action.SERVICE).setData(Uri.parse(notification.openURL))
                        setFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
                    },
                    ServiceNotification.flags,
                ),
            )
        }
        GlobalScope.launch(Dispatchers.Main) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Application.notification.createNotificationChannel(
                    NotificationChannel(
                        notification.identifier,
                        notification.typeName,
                        NotificationManager.IMPORTANCE_HIGH,
                    ),
                )
            }
            Application.notification.notify(notification.typeID, builder.build())
        }
    }

     fun writeDebugMessage(message: String?) {
        Log.d("BoxService", message!!)
        binder.broadcast {
            it.onServiceWriteLog(message)
        }
    }

}