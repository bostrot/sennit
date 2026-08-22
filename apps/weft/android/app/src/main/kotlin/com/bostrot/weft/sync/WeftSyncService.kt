package com.bostrot.weft.sync

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

/// The one connection the OS allows, held by Weft itself.
///
/// Android forbids ordinary background work but documents exactly one way for
/// an app whose *purpose* is staying reachable to do so: a foreground service
/// with a visible notification. This service is that — it holds no logic of
/// its own, it exists so the process survives and so [SyncEngineHolder] may
/// run a headless Dart engine with the Matrix sync loop and the notification
/// pipeline inside it. Swiping the app away, rebooting, or the OS reclaiming
/// memory all end with `onStartCommand`/`onTaskRemoved` bringing the daemon
/// engine back.
///
/// `specialUse` rather than `dataSync`, deliberately: Android 15 forbids
/// starting a `dataSync` service from `BOOT_COMPLETED`, and coming back after
/// a reboot is half the point. The subtype property in the manifest names
/// what the special use is.
class WeftSyncService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP || !isEnabled(this)) {
            SyncEngineHolder.stopDaemon()
            stopForegroundCompat()
            stopSelf()
            return START_NOT_STICKY
        }

        ensureChannel()
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    connectionNotification(),
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
                )
            } else {
                startForeground(NOTIFICATION_ID, connectionNotification())
            }
        } catch (e: Exception) {
            // Refused a foreground start (background-start limits). Nothing to
            // do but retry on the next trigger.
            stopSelf()
            return START_NOT_STICKY
        }

        // The daemon only runs while no UI engine does — the holder guards it.
        SyncEngineHolder.startDaemon(applicationContext)
        return START_STICKY
    }

    /// The user swiped the task away: the activity — and with it the UI
    /// engine — is going down, but this process survives. The daemon takes
    /// over listening.
    override fun onTaskRemoved(rootIntent: Intent?) {
        SyncEngineHolder.onUiGone(applicationContext)
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        SyncEngineHolder.stopDaemon()
        super.onDestroy()
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "Connection",
                // MIN keeps it out of the status bar on most launchers; the
                // user can silence or shade-hide it entirely from settings.
                NotificationManager.IMPORTANCE_MIN,
            ).apply {
                description = "Keeps Weft connected so messages arrive while it is closed."
                setShowBadge(false)
            },
        )
    }

    private fun connectionNotification(): Notification {
        val launch = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        } ?: Intent()
        val pending = PendingIntent.getActivity(
            this,
            0,
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle("Listening for messages")
            .setContentText("Weft stays connected in the background.")
            .setSmallIcon(android.R.drawable.stat_notify_sync_noanim)
            .setContentIntent(pending)
            .setOngoing(true)
            .build()
    }

    companion object {
        private const val NOTIFICATION_ID = 7411
        private const val CHANNEL_ID = "weft.connection"
        private const val PREFS = "weft_sync"
        private const val KEY_ENABLED = "enabled"
        const val ACTION_STOP = "com.bostrot.weft.sync.STOP"

        fun isEnabled(context: Context): Boolean =
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getBoolean(KEY_ENABLED, false)

        fun setEnabled(context: Context, enabled: Boolean) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit().putBoolean(KEY_ENABLED, enabled).apply()
            if (enabled) {
                start(context)
            } else {
                context.startService(
                    Intent(context, WeftSyncService::class.java).setAction(ACTION_STOP),
                )
            }
        }

        fun start(context: Context) {
            val intent = Intent(context, WeftSyncService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }
    }
}
