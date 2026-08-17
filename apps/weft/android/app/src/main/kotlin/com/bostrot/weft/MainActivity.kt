package com.bostrot.weft

import android.content.ContentResolver
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/// Hands system intents — share-in and deep links — across to Dart.
///
/// Content URIs are passed as strings; Dart resolves them through the same
/// channel because a content:// grant is only valid in this process and cannot
/// be turned into a file path. It asks two things of a URI, in this order:
/// `readSharedFileMeta` for a name and a size, so a file too large to send is
/// turned away before it is touched, and `stageSharedFile` for a copy it can
/// open later.
class MainActivity : FlutterActivity() {
    private val channelName = "com.bostrot.weft/intents"
    private var channel: MethodChannel? = null

    /// The intent that launched the app, replayed when Dart asks for it —
    /// a cold start via share sheet arrives before Dart is listening. Carries
    /// the same map as a warm share, file URIs included: a photo shared into a
    /// closed Weft must not arrive as an empty sheet.
    private var pendingIntent: Map<String, Any?>? = null

    /// Distinguishes two files shared in the same millisecond, which a batch
    /// from the gallery routinely is.
    private var stageCounter = 0

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitialIntent" -> {
                    result.success(pendingIntent)
                    pendingIntent = null
                }
                "readSharedFileMeta" -> {
                    val uri = call.argument<String>("uri")
                    if (uri == null) {
                        result.error("bad_args", "uri is required", null)
                    } else {
                        try {
                            result.success(sharedFileMeta(Uri.parse(uri)))
                        } catch (e: Exception) {
                            // A provider that refuses to be queried is not an
                            // error worth failing the share over — Dart falls
                            // back to what the URI itself says.
                            result.success(null)
                        }
                    }
                }
                "stageSharedFile" -> {
                    val uri = call.argument<String>("uri")
                    if (uri == null) {
                        result.error("bad_args", "uri is required", null)
                    } else {
                        try {
                            result.success(stageSharedFile(Uri.parse(uri)))
                        } catch (e: Exception) {
                            result.error("stage_failed", e.message, null)
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

    /// Display name, size and type for [uri], read without opening it.
    ///
    /// The size is what lets Dart refuse a 200 MB video with a sentence instead
    /// of a copy. It is omitted rather than sent as zero when the provider does
    /// not report one — a stream with no backing file is a normal thing to be
    /// shared, and "unknown" and "empty" lead to opposite decisions.
    private fun sharedFileMeta(uri: Uri): Map<String, Any?> {
        var name: String? = null
        var size: Long? = null

        if (uri.scheme == ContentResolver.SCHEME_CONTENT) {
            contentResolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
                null,
                null,
                null,
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val nameColumn = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (nameColumn >= 0 && !cursor.isNull(nameColumn)) {
                        name = cursor.getString(nameColumn)
                    }
                    val sizeColumn = cursor.getColumnIndex(OpenableColumns.SIZE)
                    if (sizeColumn >= 0 && !cursor.isNull(sizeColumn)) {
                        size = cursor.getLong(sizeColumn)
                    }
                }
            }
        } else if (uri.scheme == ContentResolver.SCHEME_FILE) {
            uri.path?.let { path ->
                val file = File(path)
                name = file.name
                if (file.exists()) size = file.length()
            }
        }

        return mapOf(
            "name" to safeFileName(name ?: uri.lastPathSegment),
            // Flutter's codec has no Long; a size past 2 GB would overflow an
            // Int, and everything that large is refused anyway.
            "size" to size?.coerceAtMost(Int.MAX_VALUE.toLong())?.toInt(),
            "mimeType" to contentResolver.getType(uri),
        )
    }

    /// Copies [uri] into the app cache and returns the path.
    ///
    /// Streamed through a buffer rather than read into a byte array and handed
    /// over the channel: the array would exist twice at once, once in Kotlin and
    /// once in Dart, and a 200 MB video is not survivable that way on a phone.
    /// The copy is what makes the share durable, too — the grant on [uri] dies
    /// with this activity, while an upload may still be retrying long after.
    ///
    /// Each file gets its own directory so that two people sending `IMG_0001.jpg`
    /// in one batch do not overwrite each other.
    private fun stageSharedFile(uri: Uri): String? {
        pruneStagedShares()

        val name = safeFileName(sharedFileMeta(uri)["name"] as? String)
        val directory = File(cacheDir, "$SHARE_CACHE_DIR/${System.currentTimeMillis()}-${stageCounter++}")
        if (!directory.mkdirs() && !directory.isDirectory) return null

        val target = File(directory, name)
        val copied = contentResolver.openInputStream(uri)?.use { input ->
            target.outputStream().use { output -> input.copyTo(output, COPY_BUFFER_BYTES) }
        }
        if (copied == null) {
            directory.deleteRecursively()
            return null
        }
        return target.absolutePath
    }

    /// Drops staged copies older than a day.
    ///
    /// Not the ones from this share: an upload reads its file once per attempt,
    /// so deleting eagerly would break exactly the retry the copy exists to make
    /// possible. A day is past every plausible retry and well inside how long
    /// the OS would have left the cache alone anyway.
    private fun pruneStagedShares() {
        val root = File(cacheDir, SHARE_CACHE_DIR)
        val cutoff = System.currentTimeMillis() - STAGED_SHARE_TTL_MS
        root.listFiles()?.forEach { entry ->
            if (entry.lastModified() < cutoff) entry.deleteRecursively()
        }
    }

    /// A filename with no path in it.
    ///
    /// A content provider supplies the display name and nothing stops it
    /// containing separators, so `../../databases/weft.db` is a name this would
    /// otherwise write through. The name is also all Matrix will carry as the
    /// event's `body`.
    private fun safeFileName(raw: String?): String {
        val name = raw?.substringAfterLast('/')?.substringAfterLast('\\')?.trim()
        if (name.isNullOrEmpty() || name == "." || name == "..") return "shared-file"
        return name.take(MAX_FILE_NAME_CHARS)
    }

    private companion object {
        const val SHARE_CACHE_DIR = "weft-share"
        const val COPY_BUFFER_BYTES = 64 * 1024
        const val STAGED_SHARE_TTL_MS = 24L * 60 * 60 * 1000
        const val MAX_FILE_NAME_CHARS = 200
    }
}
