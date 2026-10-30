package com.remotedesk.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import org.json.JSONObject

/**
 * 被控端的常驻服务。
 *
 * Android 10+ 要求在「mediaProjection 类型的前台服务已经运行」之后才能获取
 * MediaProjection，因此屏幕共享必须由本服务托管，而不能直接放在 Activity 里。
 */
class RemoteService : Service() {

    companion object {
        private const val TAG = "RemoteService"

        const val ACTION_START = "com.remotedesk.app.service.START"
        const val ACTION_STOP = "com.remotedesk.app.service.STOP"

        const val EXTRA_RESULT_CODE = "result_code"
        const val EXTRA_RESULT_DATA = "result_data"
        const val EXTRA_SESSION = "session_id"
        const val EXTRA_PEER = "peer_device_id"
        const val EXTRA_NAME = "controller_name"
        const val EXTRA_TURN = "turn"

        private const val CHANNEL_ID = "rd_control"
        private const val NOTIFICATION_ID = 4101
        private const val MAX_WIDTH = 1280

        /** 供 Activity 调用：启动被控会话。 */
        fun start(
            ctx: Context,
            resultCode: Int,
            data: Intent,
            sessionId: String,
            peer: String,
            controllerName: String,
            turn: TurnInfo?
        ) {
            val i = Intent(ctx, RemoteService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_RESULT_CODE, resultCode)
                putExtra(EXTRA_RESULT_DATA, data)
                putExtra(EXTRA_SESSION, sessionId)
                putExtra(EXTRA_PEER, peer)
                putExtra(EXTRA_NAME, controllerName)
                putExtra(EXTRA_TURN, turnToJson(turn))
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                ctx.startForegroundService(i)
            } else {
                ctx.startService(i)
            }
        }

        private fun turnToJson(t: TurnInfo?): String {
            if (t == null) return ""
            return JSONObject().apply {
                put("urls", org.json.JSONArray(t.urls))
                put("username", t.username)
                put("credential", t.credential)
            }.toString()
        }

        private fun jsonToTurn(s: String): TurnInfo? {
            if (s.isBlank()) return null
            return try {
                Api.parseTurn(JSONObject(s))
            } catch (e: Throwable) {
                null
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> begin(intent)
            ACTION_STOP -> {
                SessionHub.end("本机已取消控制")
                stopSelf()
            }

            else -> stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun begin(intent: Intent) {
        val sessionId = intent.getStringExtra(EXTRA_SESSION).orEmpty()
        val peer = intent.getStringExtra(EXTRA_PEER).orEmpty()
        val name = intent.getStringExtra(EXTRA_NAME).orEmpty().ifBlank { "对方设备" }
        val turn = jsonToTurn(intent.getStringExtra(EXTRA_TURN).orEmpty())

        Log.i(TAG, "begin session=$sessionId peer=$peer controller=$name")

        // 必须先进入前台（带 mediaProjection 类型），之后才能拿 MediaProjection
        val notif = buildNotification(name)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ServiceCompat.startForeground(
                this,
                NOTIFICATION_ID,
                notif,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
            )
        } else {
            startForeground(NOTIFICATION_ID, notif)
        }

        val sig = SessionHub.signaling
        if (sig == null) {
            Log.w(TAG, "no signaling, abort")
            stopSelf()
            return
        }

        val client = RtcClient("controlled", sessionId, peer, turn, sig)
        SessionHub.attach(client, "controlled", sessionId, peer, name)
        client.start(this)

        @Suppress("DEPRECATION")
        val data: Intent? = intent.getParcelableExtra(EXTRA_RESULT_DATA)
        if (data == null) {
            Log.w(TAG, "no projection data, abort")
            SessionHub.end("未获得屏幕共享授权")
            stopSelf()
            return
        }

        val dm = resources.displayMetrics
        var w = dm.widthPixels
        var h = dm.heightPixels
        if (w > MAX_WIDTH) {
            val ratio = MAX_WIDTH.toFloat() / w
            w = MAX_WIDTH
            h = (h * ratio).toInt()
        }
        client.startCapture(data, (w / 2) * 2, (h / 2) * 2, 20)
    }

    override fun onDestroy() {
        SessionHub.rtc?.close("服务已停止")
        stopForegroundCompat()
        super.onDestroy()
    }

    private fun stopForegroundCompat() {
        try {
            ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        } catch (_: Throwable) {
        }
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val mgr = getSystemService(NotificationManager::class.java) ?: return
        if (mgr.getNotificationChannel(CHANNEL_ID) != null) return
        val ch = NotificationChannel(
            CHANNEL_ID,
            getString(R.string.notif_channel),
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = getString(R.string.notif_controlling)
            setShowBadge(false)
        }
        mgr.createNotificationChannel(ch)
    }

    private fun buildNotification(name: String): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val stop = PendingIntent.getService(
            this,
            1,
            Intent(this, RemoteService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("正在被 $name 控制")
            .setContentText("屏幕正在共享，点此返回应用或直接取消控制")
            .setSmallIcon(android.R.drawable.ic_menu_view)
            .setOngoing(true)
            .setSilent(true)
            .setContentIntent(open)
            .addAction(0, getString(R.string.btn_cancel_control), stop)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }
}
