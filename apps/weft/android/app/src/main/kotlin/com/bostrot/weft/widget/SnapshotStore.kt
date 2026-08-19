package com.bostrot.weft.widget

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences

/// Where the inbox snapshot lives on Android, described once.
///
/// Three kinds of process read these keys and only one writes them: the Flutter
/// app writes, through `com.bostrot.weft/snapshot`; the Glance providers read
/// on every widget update; and the Wear OS bridge reads before pushing to the
/// Data Layer. Anything spelled twice — the file name, a key, the byte cap —
/// is a pair that can drift into a snapshot the writer can see and a widget
/// cannot, so it is spelled here.
///
/// A `SharedPreferences` file rather than a file of our own for one reason: a
/// Glance `GlanceAppWidget` is woken by the system with a bare `Context` and no
/// application state, and this is the cheapest durable thing such a process can
/// read. It is *not* a security boundary — `MODE_PRIVATE` keeps other apps out
/// and nothing else does, which is exactly why writing here at all is gated
/// behind an explicit opt-in on the settings screen.
object WeftSnapshotStore {
    /// The preferences file. Named for what it holds rather than for the app,
    /// because the app already has preferences and this is not those.
    const val PREFS_NAME = "weft_snapshot"

    /// The encoded `InboxSnapshot`, exactly as `SnapshotCodec` produced it.
    ///
    /// Stored unparsed. The codec's key names are the cross-language contract,
    /// its decode is documented as total, and a Kotlin-side re-encode here
    /// would be a second description of a shape neither language checks.
    const val KEY_PAYLOAD = "payload"

    /// Whether the home screen widgets may render [KEY_PAYLOAD].
    const val KEY_WIDGETS = "widgets"

    /// Whether the watch companion may.
    ///
    /// Beside the payload rather than inside it because it is not about the
    /// conversations: one file feeds both surfaces, and these two keys are how
    /// a user who wants the watch and not the widget gets that.
    const val KEY_WATCH = "watch"

    /// The same ceiling `kMaxSnapshotBytes` enforces on the Dart side.
    ///
    /// Checked again here because this side is the one that pays: a widget
    /// update crosses a Binder transaction with a ~1 MB budget *shared by every
    /// transaction in flight*, so an oversized payload fails on a busy device
    /// rather than on a big one. A refusal is answered to Dart as `false`,
    /// which the writer reads as "try again next tick" rather than as an error.
    const val MAX_PAYLOAD_BYTES = 64 * 1024

    /// Stores [json] and redraws whatever is on a home screen.
    ///
    /// Returns false only for a payload past [MAX_PAYLOAD_BYTES]. Everything
    /// else about this either succeeds or is not observable from here — a
    /// launcher that ignores the broadcast is a launcher, not a failure.
    fun write(context: Context, json: String, widgets: Boolean, watch: Boolean): Boolean {
        if (json.toByteArray(Charsets.UTF_8).size > MAX_PAYLOAD_BYTES) return false
        // `commit`, not `apply`. The broadcast below wakes a provider that
        // reads this file immediately, and `apply` writes on a background
        // thread — so the widget would render the *previous* snapshot roughly
        // as often as it rendered the new one, which is the kind of bug that
        // looks like a caching problem for a week.
        prefs(context).edit()
            .putString(KEY_PAYLOAD, json)
            .putBoolean(KEY_WIDGETS, widgets)
            .putBoolean(KEY_WATCH, watch)
            .commit()
        notifySurfaces(context)
        return true
    }

    /// Removes the payload entirely, and redraws.
    ///
    /// Deliberately not the same as writing a switched-off one. An absent
    /// payload is how a widget tells "nobody is signed in" — where the honest
    /// thing to draw is a prompt to open Weft — from "signed in and switched
    /// off in Settings", where the honest thing is to say so and point at the
    /// setting. See `InboxSnapshot` for the three states.
    fun clear(context: Context) {
        prefs(context).edit().clear().commit()
        notifySurfaces(context)
    }

    /// The stored snapshot, or null when there is none.
    fun payload(context: Context): String? = prefs(context).getString(KEY_PAYLOAD, null)

    /// Whether the home screen widgets may draw. False unless stored, so a
    /// provider that runs before the app ever has draws its own empty state
    /// rather than assuming consent.
    fun widgetsEnabled(context: Context): Boolean =
        prefs(context).getBoolean(KEY_WIDGETS, false)

    /// Whether the watch companion may. Same fail-closed default.
    fun watchEnabled(context: Context): Boolean =
        prefs(context).getBoolean(KEY_WATCH, false)

    private fun prefs(context: Context): SharedPreferences =
        context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    /// Tells every widget this app has placed to redraw.
    ///
    /// By enumerating our own installed providers rather than naming a class:
    /// this file predates the Glance providers, it must keep working when a
    /// second widget size is added, and a `ComponentName` written out by hand
    /// is a string that silently stops matching after a refactor.
    ///
    /// `installedProviders` is filtered rather than
    /// `installedProvidersForPackage`, which would be more direct and is API
    /// 26. One code path across the whole supported range is worth more than
    /// the handful of entries this filter walks.
    ///
    /// A provider with no placed instances is skipped: `ACTION_APPWIDGET_UPDATE`
    /// with an empty id array is a broadcast that wakes a process to do nothing.
    private fun notifySurfaces(context: Context) {
        val manager = AppWidgetManager.getInstance(context) ?: return
        val ours = manager.installedProviders.filter {
            it.provider.packageName == context.packageName
        }
        for (info in ours) {
            val ids = manager.getAppWidgetIds(info.provider)
            if (ids.isEmpty()) continue
            context.sendBroadcast(
                Intent(AppWidgetManager.ACTION_APPWIDGET_UPDATE)
                    .setComponent(info.provider)
                    .putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, ids)
            )
        }
        // The Wear OS half is the other side of this call and belongs to the
        // module that owns the Data Layer client: a `PutDataRequest` from here
        // would mean this file linking `play-services-wearable`, which is a
        // dependency the phone app does not otherwise need. It reads
        // [KEY_PAYLOAD] and [KEY_WATCH] from the same file.
    }
}
