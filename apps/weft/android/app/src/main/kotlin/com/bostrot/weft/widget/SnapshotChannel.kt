package com.bostrot.weft.widget

import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/// Android's end of `com.bostrot.weft/snapshot`.
///
/// The counterpart of `WeftSnapshotChannel` in `ios/Runner/SnapshotChannel.swift`
/// — same channel name, same two methods, different container. The Dart side
/// (`WeftSnapshotContainer`) does not branch on platform at all, which is the
/// point of them agreeing this precisely.
///
/// ## Why not an arm on `com.bostrot.weft/intents`
///
/// Phase 03 and Phase 04 both put Android's shortcut calls on the existing
/// `/intents` channel, because "a second channel would be a second front door
/// onto the same activity" — two publishers racing on one shortcut set. That
/// argument does not reach here: nothing on this channel touches state anything
/// else writes, the methods are disjoint, and the same channel has to exist on
/// iOS and macOS where `/intents` does not exist at all. `WeftShareChannel`
/// made the same distinction for the same reason.
///
/// ## Why it takes a `Context` rather than the `Activity`
///
/// Nothing here needs a window, and the store is written from a chat-list
/// listener that keeps running while the activity is being recreated. The
/// application context is the one that outlives that.
object WeftSnapshotChannel {
    const val CHANNEL = "com.bostrot.weft/snapshot"

    fun register(context: Context, engine: FlutterEngine) {
        val application = context.applicationContext
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler {
            call, result ->
            when (call.method) {
                "writeSnapshot" -> {
                    val json = call.argument<String>("json")
                    if (json == null) {
                        result.error("bad_args", "json is required", null)
                    } else {
                        // Answered rather than thrown, all the way down. This
                        // runs on every inbox tick, and a home screen that
                        // could not be redrawn must not surface as an exception
                        // in a stream listener.
                        result.success(
                            try {
                                WeftSnapshotStore.write(
                                    context = application,
                                    json = json,
                                    widgets = call.argument<Boolean>("widgets") ?: false,
                                    watch = call.argument<Boolean>("watch") ?: false,
                                )
                            } catch (e: Exception) {
                                false
                            }
                        )
                    }
                }
                "clearSnapshot" -> {
                    try {
                        WeftSnapshotStore.clear(application)
                    } catch (e: Exception) {
                        // Nothing useful for Dart to do about it, and the one
                        // caller is a sign-out that must complete either way.
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}
