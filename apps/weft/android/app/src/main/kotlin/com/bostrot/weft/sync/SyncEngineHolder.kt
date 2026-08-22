package com.bostrot.weft.sync

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant

/// One Matrix client at a time.
///
/// The daemon engine and the UI engine both open the same session database,
/// and two sync loops advancing the same token would tear each other's state
/// apart. So the rule is absolute and lives in one place: the headless daemon
/// runs exactly when no UI engine is alive. The activity announces itself on
/// creation (daemon stops, gracefully) and the service announces the task's
/// removal (daemon starts, if the toggle says so).
object SyncEngineHolder {
    private const val DAEMON_CHANNEL = "com.bostrot.weft/daemon"
    private const val STOP_GRACE_MS = 2500L

    private var daemon: FlutterEngine? = null
    private var uiAlive = false
    private val main = Handler(Looper.getMainLooper())

    /// Called from `MainActivity.configureFlutterEngine`: a UI engine — and
    /// with it the real Matrix client — is coming up.
    fun onUiVisible() {
        uiAlive = true
        stopDaemon()
    }

    /// Called when the task is swiped away or the activity dies for good.
    fun onUiGone(context: Context) {
        uiAlive = false
        if (WeftSyncService.isEnabled(context)) {
            main.postDelayed({ if (!uiAlive) startDaemon(context) }, 500)
        }
    }

    fun startDaemon(context: Context) {
        if (daemon != null || uiAlive) return

        val loader = FlutterInjector.instance().flutterLoader()
        if (!loader.initialized()) {
            loader.startInitialization(context)
            loader.ensureInitializationComplete(context, null)
        }

        val engine = FlutterEngine(context)
        daemon = engine
        GeneratedPluginRegistrant.registerWith(engine)
        engine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint.createDefault(),
            listOf("--weft-daemon"),
        )
    }

    /// Asks the Dart side to close its client, then destroys the engine — or
    /// destroys it anyway after a grace period, because a daemon that will
    /// not die must not hold the database against the UI that is starting.
    fun stopDaemon() {
        val engine = daemon ?: return
        daemon = null

        var destroyed = false
        fun destroy() {
            if (destroyed) return
            destroyed = true
            engine.destroy()
        }

        try {
            MethodChannel(engine.dartExecutor.binaryMessenger, DAEMON_CHANNEL)
                .invokeMethod(
                    "stop",
                    null,
                    object : MethodChannel.Result {
                        override fun success(result: Any?) = destroy()
                        override fun error(code: String, msg: String?, details: Any?) = destroy()
                        override fun notImplemented() = destroy()
                    },
                )
        } catch (e: Exception) {
            destroy()
            return
        }
        main.postDelayed({ destroy() }, STOP_GRACE_MS)
    }
}
