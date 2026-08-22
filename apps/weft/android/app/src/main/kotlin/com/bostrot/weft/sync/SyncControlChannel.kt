package com.bostrot.weft.sync

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/// The settings screen's handle on the built-in connection.
///
/// Four verbs: read the state, flip the toggle, and ask for the battery
/// exemption that keeps Doze from cutting the connection's network. The
/// exemption matters more than it looks: a foreground service survives Doze,
/// but its *sockets* do not — that whitelist is the documented way a
/// messaging app keeps them, and it is the same thing ntfy asks its users
/// for.
object SyncControlChannel {
    private const val NAME = "com.bostrot.weft/sync_control"

    fun register(activity: Activity, engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, NAME).setMethodCallHandler { call, result ->
            when (call.method) {
                "status" -> result.success(
                    mapOf(
                        "enabled" to WeftSyncService.isEnabled(activity),
                        "batteryExempt" to isBatteryExempt(activity),
                    ),
                )
                "setEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled")
                    if (enabled == null) {
                        result.error("bad_args", "enabled is required", null)
                    } else {
                        try {
                            WeftSyncService.setEnabled(activity, enabled)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("sync_toggle", e.message, null)
                        }
                    }
                }
                "openNotificationSettings" -> {
                    try {
                        activity.startActivity(
                            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(
                                Settings.EXTRA_APP_PACKAGE,
                                activity.packageName,
                            ),
                        )
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("notification_settings", e.message, null)
                    }
                }
                "requestBatteryExemption" -> {
                    try {
                        if (isBatteryExempt(activity)) {
                            result.success(true)
                        } else {
                            activity.startActivity(
                                Intent(
                                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                                    Uri.parse("package:${activity.packageName}"),
                                ),
                            )
                            // The dialog's answer arrives whenever it arrives;
                            // the screen re-reads `status` on resume.
                            result.success(false)
                        }
                    } catch (e: Exception) {
                        result.error("battery_exemption", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun isBatteryExempt(context: Context): Boolean {
        val power = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
        return power?.isIgnoringBatteryOptimizations(context.packageName) ?: false
    }
}
