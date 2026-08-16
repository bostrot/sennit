package com.bostrot.weft

import android.content.Intent
import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/// Hands system intents — share-in and deep links — across to Dart.
///
/// Content URIs are passed as strings; Dart resolves them through the same
/// channel (`readSharedFile`) because a content:// grant is only valid in this
/// process and cannot be turned into a file path.
class MainActivity : FlutterActivity() {
    private val channelName = "com.bostrot.weft/intents"
    private var channel: MethodChannel? = null

    /// The intent that launched the app, replayed when Dart asks for it —
    /// a cold start via share sheet arrives before Dart is listening.
    private var pendingIntent: Map<String, Any?>? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitialIntent" -> {
                    result.success(pendingIntent)
                    pendingIntent = null
                }
                "readSharedFile" -> {
                    val uri = call.argument<String>("uri")
                    if (uri == null) {
                        result.error("bad_args", "uri is required", null)
                    } else {
                        try {
                            val bytes = contentResolver.openInputStream(Uri.parse(uri))?.use {
                                it.readBytes()
                            }
                            result.success(bytes)
                        } catch (e: Exception) {
                            result.error("read_failed", e.message, null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
        intent?.let { handleIntent(it, replay = true) }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent, replay = false)
    }

    private fun handleIntent(intent: Intent, replay: Boolean) {
        val payload: Map<String, Any?>? = when (intent.action) {
            Intent.ACTION_SEND -> mapOf(
                "type" to "share",
                "mimeType" to intent.type,
                "text" to intent.getStringExtra(Intent.EXTRA_TEXT),
                "uris" to listOfNotNull(
                    @Suppress("DEPRECATION")
                    (intent.getParcelableExtra(Intent.EXTRA_STREAM) as? Uri)?.toString()
                ),
            )
            Intent.ACTION_SEND_MULTIPLE -> mapOf(
                "type" to "share",
                "mimeType" to intent.type,
                "text" to intent.getStringExtra(Intent.EXTRA_TEXT),
                "uris" to (
                    @Suppress("DEPRECATION")
                    intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
                        ?.map { it.toString() } ?: emptyList<String>()
                ),
            )
            Intent.ACTION_VIEW -> intent.data?.let {
                mapOf("type" to "link", "url" to it.toString())
            }
            else -> null
        } ?: return

        if (replay) {
            // Cold start: Dart isn't listening yet; it will ask.
            pendingIntent = payload
        } else {
            channel?.invokeMethod("onIntent", payload) ?: run { pendingIntent = payload }
        }
    }
}
