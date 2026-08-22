package com.bostrot.weft

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.provider.CalendarContract
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
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

    fun register(activity: Activity, engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, NAME).setMethodCallHandler { call, result ->
            when (call.method) {
                "insertEvent" -> {
                    val title = call.argument<String>("title")
                    val start = call.argument<Number>("startMs")?.toLong()
                    val end = call.argument<Number>("endMs")?.toLong()
                    if (title == null || start == null || end == null) {
                        result.error("bad_args", "title, startMs and endMs are required", null)
                        return@setMethodCallHandler
                    }
                    val intent = Intent(Intent.ACTION_INSERT)
                        .setData(CalendarContract.Events.CONTENT_URI)
                        .putExtra(CalendarContract.Events.TITLE, title)
                        .putExtra(CalendarContract.EXTRA_EVENT_BEGIN_TIME, start)
                        .putExtra(CalendarContract.EXTRA_EVENT_END_TIME, end)
                        .putExtra(
                            CalendarContract.EXTRA_EVENT_ALL_DAY,
                            call.argument<Boolean>("allDay") ?: false,
                        )
                        .putExtra(CalendarContract.Events.EVENT_TIMEZONE, TimeZone.getDefault().id)
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
}
