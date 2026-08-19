package com.bostrot.weft.call

import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/// Keeps a call alive while Weft is in the background.
///
/// Without this a call is subject to every power-saving rule Android has: Doze
/// stops the network after a few minutes of a stationary screen-off device,
/// background execution limits stop the process doing work at all, and the peer
/// connection dies quietly with the audio still apparently running. A
/// `FOREGROUND_SERVICE_TYPE_PHONE_CALL` service is the documented exemption, and
/// its notification is the price — which is the right price, because a phone
/// call that is happening should say so.
///
/// The type matters as much as the service. From Android 14 a foreground service
/// must declare a type and hold the matching permission, and the `phoneCall`
/// type additionally requires that a self-managed `ConnectionService` call is in
/// progress — which is exactly what [WeftConnectionService] has just created. A
/// build that started this without one is refused at `startForeground` with a
/// `ForegroundServiceStartNotAllowedException`, so the ordering here is not a
/// style choice: the connection exists first, always.
class CallForegroundService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val name = intent?.getStringExtra(EXTRA_NAME) ?: "Call"
        val video = intent?.getBooleanExtra(EXTRA_VIDEO, false) ?: false

        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
        if (manager != null) CallNotifications.ensureChannel(manager)

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    ongoing(name, video),
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL,
                )
            } else {
                startForeground(NOTIFICATION_ID, ongoing(name, video))
            }
        } catch (e: Exception) {
            // Android 14+ refuses the `phoneCall` type when Telecom has no call
            // — the fallback path where the phone account could not be
            // registered at all. The call carries on in the foreground; what is
            // lost is surviving Doze, which is a degraded call rather than none.
            stopSelf()
            return START_NOT_STICKY
        }
        // Not sticky: a restarted service with no call behind it would show an
        // ongoing-call notification for a call that ended while the process was
        // dead.
        return START_NOT_STICKY
    }

    private fun ongoing(name: String, video: Boolean): Notification {
        val launch = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        } ?: Intent()
        val pending = PendingIntent.getActivity(
            this,
            0,
            launch,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            },
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle(name)
            .setContentText(if (video) "Video call in progress" else "Call in progress")
            .setContentIntent(pending)
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_CALL)
            // No full-screen intent and no sound: this one is a status line, not
            // a summons. The ringing notification is `CallNotifications`.
            .setOnlyAlertOnce(true)
            .build()
    }

    companion object {
        private const val CHANNEL_ID = "weft.calls"
        private const val NOTIFICATION_ID = 0x7CA12
        private const val EXTRA_NAME = "com.bostrot.weft.call.NAME"
        private const val EXTRA_VIDEO = CallBridge.EXTRA_VIDEO

        fun start(context: Context, name: String, video: Boolean) {
            val intent = Intent(context, CallForegroundService::class.java).apply {
                putExtra(EXTRA_NAME, name)
                putExtra(EXTRA_VIDEO, video)
            }
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                // Started from the background on a build that refuses it. Same
                // trade as the `startForeground` failure above.
            }
        }

        fun stop(context: Context) {
            try {
                context.stopService(Intent(context, CallForegroundService::class.java))
            } catch (e: Exception) {
                // Already gone.
            }
        }
    }
}
