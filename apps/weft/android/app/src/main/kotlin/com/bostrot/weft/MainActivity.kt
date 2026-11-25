package com.bostrot.weft

import android.content.ContentResolver
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import android.provider.Settings
import com.bostrot.weft.call.CallBridge
import com.bostrot.weft.sms.SmsBridge
import com.bostrot.weft.sync.SyncControlChannel
import com.bostrot.weft.sync.SyncEngineHolder
import com.bostrot.weft.wear.WeftWatchChannel
import com.bostrot.weft.widget.WeftSnapshotChannel
import io.flutter.embedding.android.FlutterFragmentActivity
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
class MainActivity : FlutterFragmentActivity() {
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
        // The UI engine owns the Matrix client from here on; the background
        // daemon, if one is listening, hands over before this engine's client
        // opens the same database.
        SyncEngineHolder.onUiVisible()
        SyncControlChannel.register(this, flutterEngine)
        CalendarChannel.register(this, flutterEngine)
        BrowserAuth.register(this, flutterEngine)
        PrivacyChannel.register(this, flutterEngine)
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
                "publishChatShortcut" -> {
                    val id = call.argument<String>("id")
                    val label = call.argument<String>("label")
                    val link = call.argument<String>("link")
                    if (id == null || label == null || link == null) {
                        result.error("bad_args", "id, label and link are required", null)
                    } else {
                        // A launcher that refuses shortcuts costs the
                        // conversation its bubble, not its notification.
                        result.success(
                            ShareShortcuts.publishOne(
                                activity = this,
                                id = id,
                                chatId = call.argument<String>("chatId"),
                                label = label,
                                link = link,
                                iconPath = call.argument<String>("iconPath"),
                                isGroup = call.argument<Boolean>("isGroup") ?: false,
                            )
                        )
                    }
                }
                "openConversationNotificationSettings" -> {
                    val channelId = call.argument<String>("channelId")
                    if (channelId == null) {
                        result.error("bad_args", "channelId is required", null)
                    } else {
                        result.success(
                            openConversationNotificationSettings(
                                channelId = channelId,
                                shortcutId = call.argument<String>("shortcutId"),
                            )
                        )
                    }
                }
                "publishShareTargets" -> {
                    val slots = call.argument<List<Map<String, Any?>>>("slots")
                    if (slots == null) {
                        result.error("bad_args", "slots is required", null)
                    } else {
                        try {
                            result.success(ShareShortcuts.publish(this, slots))
                        } catch (e: Exception) {
                            // Same trade as above, one surface up: no Direct
                            // Share row is a worse share sheet, not a broken
                            // app, and Dart has nothing useful to do about it.
                            result.success(0)
                        }
                    }
                }
                "clearShareTargets" -> {
                    try {
                        ShareShortcuts.clear(this)
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }
        // SMS gets its own channel rather than another `when` arm here,
        // because the traffic on it does not start at an activity: a received
        // message arrives at a `BroadcastReceiver` that may have started the
        // process. `SmsBridge` is the singleton that outlives this class; all
        // the activity contributes is somewhere to show the role dialog.
        SmsBridge.attach(this, flutterEngine)
        // Calling, for the same reason and one more: a `ConnectionService` is
        // bound *by Telecom*, so an incoming call can reach this process with no
        // activity at all — and answering from the lock screen routinely does.
        // `CallBridge` holds that answer until an engine exists, which is why it
        // is a singleton rather than a `when` arm here.
        CallBridge.attach(this, flutterEngine)
        // The companion-surface snapshot, on a channel of its own for the
        // reason `WeftSnapshotChannel` documents: the same channel name has to
        // exist on iOS and macOS, where `/intents` does not exist at all, and
        // nothing on it touches state anything above shares. No `attach`/`detach`
        // pair because it holds nothing — every call is a `SharedPreferences`
        // write against the application context.
        WeftSnapshotChannel.register(this, flutterEngine)
        // The watch reply path, which travels the other way and therefore *does*
        // hold state: a reply arrives from a `WearableListenerService` the system
        // started, which has no reference to this engine. `WeftWatchChannel`
        // holds the answer to "is there a Dart handler alive to give this to",
        // and answers the watch itself when there is not.
        WeftWatchChannel.register(this, flutterEngine)

        intent?.let { handleIntent(it, replay = true) }
    }

    override fun onDestroy() {
        SmsBridge.detach()
        CallBridge.detach()
        // This engine — and its Matrix client — dies with the activity. When
        // the built-in connection is on, the daemon takes the session back.
        SyncEngineHolder.onUiGone(applicationContext)
        super.onDestroy()
    }

    /// The default-SMS-app dialog's answer.
    ///
    /// The role is the only thing here that asks the system a question and
    /// waits — everything else is a channel call — so an unrecognised request
    /// code goes straight back to the plugins, which is what
    /// `super.onActivityResult` does.
    /// Android's own settings for one conversation, where its sound is
    /// chosen. The conversation page needs Android 11 and a shortcut the
    /// notifications hang off; without either this lands on the channel the
    /// conversation posts to, which is the next best place to pick a sound.
    private fun openConversationNotificationSettings(
        channelId: String,
        shortcutId: String?,
    ): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        val intent = Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS)
            .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
            .putExtra(Settings.EXTRA_CHANNEL_ID, channelId)
        if (shortcutId != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            intent.putExtra(Settings.EXTRA_CONVERSATION_ID, shortcutId)
        }
        return try {
            startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
    }

    @Deprecated("Flutter's FlutterFragmentActivity has not migrated to the Activity Result APIs")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (SmsBridge.onRoleResult(requestCode)) return
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
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
                "targetChatId" to sharedShortcutChatId(intent),
                "uris" to listOfNotNull(
                    @Suppress("DEPRECATION")
                    (intent.getParcelableExtra(Intent.EXTRA_STREAM) as? Uri)?.toString()
                ),
            )
            Intent.ACTION_SEND_MULTIPLE -> mapOf(
                "type" to "share",
                "mimeType" to intent.type,
                "text" to intent.getStringExtra(Intent.EXTRA_TEXT),
                "targetChatId" to sharedShortcutChatId(intent),
                "uris" to (
                    @Suppress("DEPRECATION")
                    intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
                        ?.map { it.toString() } ?: emptyList<String>()
                ),
            )
            Intent.ACTION_VIEW -> intent.data?.let {
                mapOf("type" to "link", "url" to it.toString())
            }
            // "Message this number", from the dialer, a contact card or an
            // `sms:` link on a web page. Sent as a link rather than as a share
            // because that is what it is: `WeftLink.parse` reads the four
            // telephony schemes into a `ComposeSmsLink`, so this arrives at the
            // same router as every other way of opening a conversation.
            Intent.ACTION_SENDTO -> intent.data?.let {
                mapOf(
                    "type" to "link",
                    // The body an ACTION_SENDTO carries lives in EXTRA_TEXT,
                    // not in the URI's `body` parameter, and the two spellings
                    // are both in use. Folding it into the URI here means one
                    // parser on the Dart side rather than two paths that have
                    // to agree.
                    "url" to withBody(it, intent.getStringExtra(Intent.EXTRA_TEXT)),
                )
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

    /// [uri] with [body] as its `body` query parameter, when there is one.
    ///
    /// Returns the URI untouched when the intent carried no text or already
    /// spelled it that way — appending an empty parameter would turn a URI the
    /// Dart side round-trips cleanly into one it has to special-case.
    /// Appended as text rather than through `buildUpon`, which is not a
    /// shortcut: `sms:+441234567890` is an *opaque* URI, and
    /// `appendQueryParameter` on an opaque URI throws rather than returning the
    /// obvious thing. The obvious thing is what the Dart side parses.
    private fun withBody(uri: Uri, body: String?): String {
        val text = uri.toString()
        if (body.isNullOrEmpty() || text.contains('?')) return text
        return "$text?body=${Uri.encode(body)}"
    }

    /// The chat a Direct Share intent was aimed at, or null for a plain share.
    ///
    /// Android puts the shortcut's id on the `SEND` it builds when the user taps
    /// a conversation in another app's share sheet rather than the Weft icon.
    /// That id is sanitised and cannot be turned back into a chat id, so
    /// [ShareShortcuts] keeps the map it was published with — see
    /// `ShareShortcuts.chatIdFor`. Null falls through to the in-app target
    /// picker, which is the same thing a plain share does.
    private fun sharedShortcutChatId(intent: Intent): String? {
        val shortcutId = intent.getStringExtra(Intent.EXTRA_SHORTCUT_ID) ?: return null
        return ShareShortcuts.chatIdFor(this, shortcutId)
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
