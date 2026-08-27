package com.bostrot.weft

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.provider.CalendarContract
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.Calendar
import java.util.TimeZone

/// Opens the system calendar's event editor, prefilled.
///
/// Exists because the plugin route gates on `resolveActivity`, and package
/// visibility makes that return null for calendar apps the `<queries>`
/// declaration happens to miss — Samsung's among them, on some builds. But
/// visibility only restricts *querying*: `startActivity` on an implicit
/// intent works regardless, and `ActivityNotFoundException` is the one
/// honest answer for a device with no calendar at all. So this just starts
/// it and reports which of the two happened.
object CalendarChannel {
    private const val NAME = "com.bostrot.weft/calendar"

    /// The MIME type of a collection of events.
    ///
    /// Used instead of `setData(Events.CONTENT_URI)`, which is the other
    /// documented spelling of the same request and the one that went wrong:
    /// pointed at the events *collection*, some calendar apps — Google's
    /// among them — treat the intent as "open the event this URI names",
    /// find no event id in it, and answer with a toast ("Der Termin kann
    /// nicht gestartet werden") instead of the editor. Declaring the type
    /// says the same thing without naming a URI there is nothing to open at.
    private const val EVENT_DIR_TYPE = "vnd.android.cursor.dir/event"

    fun register(activity: Activity, engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, NAME).setMethodCallHandler { call, result ->
            when (call.method) {
                "insertEvent" -> {
                    val title = call.argument<String>("title")
                    val start = call.argument<Number>("startMs")?.toLong()
                    val rawEnd = call.argument<Number>("endMs")?.toLong()
                    if (title == null || start == null || rawEnd == null) {
                        result.error("bad_args", "title, startMs and endMs are required", null)
                        return@setMethodCallHandler
                    }
                    val allDay = call.argument<Boolean>("allDay") ?: false

                    // An end at or before the start is not a duration a
                    // calendar can draw, and a detector working from prose
                    // ("Thursday", "at 5") can produce one. An hour is the
                    // same default the editor itself would offer.
                    val end = if (rawEnd > start) rawEnd else start + 60 * 60 * 1000

                    val intent = Intent(Intent.ACTION_INSERT)
                        .setType(EVENT_DIR_TYPE)
                        .putExtra(CalendarContract.Events.TITLE, title)
                        .putExtra(CalendarContract.EXTRA_EVENT_ALL_DAY, allDay)

                    if (allDay) {
                        // An all-day event is a *date*, and the calendar reads
                        // its bounds as UTC midnights. Handing it a local
                        // wall-clock time lands the event on the day before or
                        // after for anyone far enough from UTC.
                        intent
                            .putExtra(CalendarContract.EXTRA_EVENT_BEGIN_TIME, utcMidnight(start))
                            .putExtra(CalendarContract.EXTRA_EVENT_END_TIME, utcMidnight(end))
                    } else {
                        intent
                            .putExtra(CalendarContract.EXTRA_EVENT_BEGIN_TIME, start)
                            .putExtra(CalendarContract.EXTRA_EVENT_END_TIME, end)
                            .putExtra(
                                CalendarContract.Events.EVENT_TIMEZONE,
                                TimeZone.getDefault().id,
                            )
                    }

                    try {
                        activity.startActivity(intent)
                        result.success(true)
                    } catch (e: ActivityNotFoundException) {
                        result.success(false)
                    } catch (e: Exception) {
                        result.error("calendar_insert", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /// The UTC midnight of the local day [millis] falls in.
    private fun utcMidnight(millis: Long): Long {
        val local = Calendar.getInstance()
        local.timeInMillis = millis
        val utc = Calendar.getInstance(TimeZone.getTimeZone("UTC"))
        utc.clear()
        utc.set(
            local.get(Calendar.YEAR),
            local.get(Calendar.MONTH),
            local.get(Calendar.DAY_OF_MONTH),
        )
        return utc.timeInMillis
    }
}
