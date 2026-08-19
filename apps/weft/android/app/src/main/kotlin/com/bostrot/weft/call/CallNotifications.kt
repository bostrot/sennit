package com.bostrot.weft.call

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build

/// The incoming-call notification, and the actions on it.
///
/// Kotlin rather than `flutter_local_notifications`, which posts every other
/// notification in Weft, and the reason is the same one that made [SmsBridge] a
/// singleton: **this has to be postable with no Flutter engine.** Telecom binds
/// [WeftConnectionService] to deliver an incoming call, and on a phone that has
/// been asleep that bind can be the thing that starts the process. A
/// notification posted from Dart would arrive after the engine had started, the
/// client had synced and the invite had been decrypted — by which time the call
/// has been ringing silently for several seconds it did not have.
///
/// ## The channel is Dart's
///
/// `weft.calls` is declared in `notification_channels.dart` and created on every
/// launch, at `Importance.max`, a whole phase before anything used it — because
/// Android fixes a channel's importance at creation and ignores every later
/// attempt to raise it. This file must therefore **create it with exactly the
/// same importance**, since on a first launch that begins with a call it is this
/// code that gets there first, and a calls channel created at `HIGH` here is a
/// calls channel that can never be `MAX` again. That is the whole reason the
/// constant below is written out rather than taken from
/// `NotificationManager.IMPORTANCE_HIGH`.
object CallNotifications {
    /// Must match `kCallsChannelId` in `notification_channels.dart`.
    private const val CHANNEL_ID = "weft.calls"

    /// Must match `Importance.max` in `notification_channels.dart`, which is
    /// `IMPORTANCE_MAX` and not `IMPORTANCE_HIGH`. Deprecated in the framework
    /// and still exactly what the plugin sends, so matching it is not a choice.
    private const val IMPORTANCE_MAX = 5

    private const val NOTIFICATION_ID = 0x7CA11

    const val ACTION_ANSWER = "com.bostrot.weft.call.ANSWER"
    const val ACTION_DECLINE = "com.bostrot.weft.call.DECLINE"
    const val EXTRA_CALL_ID = CallBridge.EXTRA_CALL_ID

    /// Posts the full-screen incoming-call notification.
    ///
    /// The full-screen intent is what turns a heads-up card into a ringing
    /// phone: on a locked device Android launches the intent instead of showing
    /// the notification, and on an unlocked one it shows the card and keeps the
    /// intent for the tap. Weft's own `CallOverlay` draws the sheet once the
    /// activity is up, so the intent is a plain launch rather than a route — the
    /// ringing call is already in `CallServiceState` and the overlay is watching
    /// it.
    fun showIncoming(context: Context, callId: String, callerName: String, video: Boolean) {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            ?: return
        ensureChannel(manager)

        val full = launchIntent(context, callId)
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }

        builder
            // The launcher icon, which is what `flutter_local_notifications` is
            // initialised with (`AndroidInitializationSettings('@mipmap/ic_launcher')`)
            // and therefore what every other Weft notification already shows.
            // Read off `applicationInfo` rather than through `R` so this file
            // stays independent of the generated resource class.
            .setSmallIcon(context.applicationInfo.icon)
            .setContentTitle(callerName)
            .setContentText(if (video) "Incoming video call" else "Incoming call")
            .setContentIntent(full)
            .setFullScreenIntent(full, true)
            // Ongoing and non-dismissible: a swipe that removed this would leave
            // a call ringing with nothing on screen to answer it.
            .setOngoing(true)
            .setAutoCancel(false)
            // `CATEGORY_CALL` is what lets this through Do Not Disturb's
            // "allow calls" setting, which is the setting a user who wants to be
            // reachable actually turns on.
            .setCategory(Notification.CATEGORY_CALL)
            // Decline first, answer second: on a watch and in a car the actions
            // are read in order and the destructive one being last is how a
            // scroll ends a call.
            .addAction(
                action(context, android.R.drawable.ic_menu_close_clear_cancel, "Decline", ACTION_DECLINE, callId),
            )
            .addAction(
                action(context, android.R.drawable.ic_menu_call, "Answer", ACTION_ANSWER, callId),
            )

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            builder.setVisibility(Notification.VISIBILITY_PUBLIC)
        }

        try {
            manager.notify(NOTIFICATION_ID, builder.build())
        } catch (e: SecurityException) {
            // POST_NOTIFICATIONS not granted on 13+. Nothing to do about it from
            // here, and the call is still ringing inside the app.
        }
    }

    fun dismissIncoming(context: Context) {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
        manager?.cancel(NOTIFICATION_ID)
    }

    /// Creates `weft.calls` when it does not exist yet. See the class comment
    /// for why the importance is written out.
    fun ensureChannel(manager: NotificationManager) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(CHANNEL_ID, "Calls", IMPORTANCE_MAX).apply {
            description = "Incoming calls."
            setShowBadge(true)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        }
        manager.createNotificationChannel(channel)
    }

    /// A launch of the app itself, brought to the front.
    private fun launchIntent(context: Context, callId: String): PendingIntent {
        val intent = context.packageManager
            .getLaunchIntentForPackage(context.packageName)
            ?.apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                putExtra(EXTRA_CALL_ID, callId)
            }
            ?: Intent()
        return PendingIntent.getActivity(context, 0, intent, pendingFlags())
    }

    private fun action(
        context: Context,
        icon: Int,
        title: String,
        action: String,
        callId: String,
    ): Notification.Action {
        val intent = Intent(context, CallActionReceiver::class.java).apply {
            this.action = action
            putExtra(EXTRA_CALL_ID, callId)
            setPackage(context.packageName)
        }
        val pending = PendingIntent.getBroadcast(
            context,
            action.hashCode(),
            intent,
            pendingFlags(),
        )
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            Notification.Action.Builder(
                android.graphics.drawable.Icon.createWithResource(context, icon),
                title,
                pending,
            ).build()
        } else {
            @Suppress("DEPRECATION")
            Notification.Action.Builder(icon, title, pending).build()
        }
    }

    /// `FLAG_IMMUTABLE` from 23, and required from 31. The intents here carry
    /// everything they need, so there is nothing for a recipient to fill in.
    private fun pendingFlags(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
}

/// Answer and decline, from the notification.
///
/// A broadcast receiver rather than an activity, and it deliberately does *not*
/// wake Flutter to decide anything: the answer goes to [CallBridge], which holds
/// it if Dart is not listening and replays it when it is. That replay is the
/// whole reason answering from a locked screen works at all — the tap arrives
/// long before an engine exists.
///
/// Answering also launches the app, because the peer connection lives in the
/// main isolate. That is a property of the architecture rather than a bug to fix
/// here: the same wall that makes every message action `showsUserInterface: true`
/// stands in front of a call, and harder, because there is a camera behind it.
class CallActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val callId = intent.getStringExtra(CallNotifications.EXTRA_CALL_ID)
        CallNotifications.dismissIncoming(context)

        when (intent.action) {
            CallNotifications.ACTION_ANSWER -> {
                CallBridge.onAnswer()
                context.packageManager
                    .getLaunchIntentForPackage(context.packageName)
                    ?.apply {
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                        putExtra(CallNotifications.EXTRA_CALL_ID, callId)
                    }
                    ?.let { context.startActivity(it) }
            }

            CallNotifications.ACTION_DECLINE -> CallBridge.onDecline()
        }
    }
}
