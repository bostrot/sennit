package com.bostrot.weft

import android.app.Activity
import android.os.Build
import android.view.WindowManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/// What the app lock needs from Android that the biometric plugin does not
/// cover: keeping the chats out of the recent-apps preview, and saying whether
/// the system biometric prompt can be shown at all.
object PrivacyChannel {
    private const val NAME = "com.bostrot.weft/privacy"

    fun register(activity: Activity, engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, NAME).setMethodCallHandler { call, result ->
            when (call.method) {
                "setHideInRecents" -> {
                    hideInRecents(activity, call.argument<Boolean>("hide") ?: false)
                    result.success(null)
                }
                // Before Android 9 the biometric library draws its own
                // fingerprint dialog, which needs an AppCompat theme this app
                // does not use; there the lock is PIN only.
                "canUseBiometrics" -> result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.P)
                else -> result.notImplemented()
            }
        }
    }

    /// Android 13 can leave the preview out and still allow screenshots.
    /// Before that the only way is FLAG_SECURE, which blocks both.
    private fun hideInRecents(activity: Activity, hide: Boolean) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            activity.setRecentsScreenshotEnabled(!hide)
        } else if (hide) {
            activity.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        } else {
            activity.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
    }
}
