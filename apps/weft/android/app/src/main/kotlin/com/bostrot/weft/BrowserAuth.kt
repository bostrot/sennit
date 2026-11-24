package com.bostrot.weft

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.result.ActivityResultLauncher
import androidx.browser.auth.AuthTabIntent
import androidx.browser.customtabs.CustomTabsClient
import androidx.browser.customtabs.CustomTabsIntent
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/// Signs in on a web page in the person's own browser, and brings back the
/// address that page finishes on.
///
/// For the sign-ins an in-app web view cannot do well: a company's SSO that
/// refuses embedded browsers (Google does), or one the person is already
/// signed in to in their browser. The page ends by sending the browser to a
/// custom scheme — Mattermost's mobile SSO lands on `mmauth://callback?…`
/// with the session in the query — and that address is the whole result.
///
/// Two ways of catching it, best first:
///
/// - An Auth Tab (Chrome 137 and later): the tab itself watches for the
///   scheme and returns the address to the activity that opened it. No
///   other app can be handed it, which matters for `mmauth://`: the
///   official Mattermost app registers the same scheme.
/// - A Custom Tab, for every other browser, and [BrowserAuthCallbackActivity]
///   to receive the redirect. Its intent filter is disabled in the manifest
///   and enabled only while a sign-in is waiting, so Sennit never offers to
///   open the official app's sign-ins, and is never offered one it did not
///   start.
object BrowserAuth {
    private const val NAME = "com.bostrot.weft/browser_auth"

    private var pending: MethodChannel.Result? = null

    fun register(activity: Activity, engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, NAME).setMethodCallHandler { call, result ->
            when (call.method) {
                "authenticate" -> {
                    val url = call.argument<String>("url")
                    val scheme = call.argument<String>("callbackScheme")
                    if (url == null || scheme == null) {
                        result.error("bad_args", "url and callbackScheme are required", null)
                        return@setMethodCallHandler
                    }
                    // A second tap while the first page is still open: the
                    // first one is abandoned, not left waiting forever.
                    finish(null)
                    pending = result
                    activity.startActivity(
                        Intent(activity, BrowserAuthActivity::class.java)
                            .putExtra(BrowserAuthActivity.EXTRA_URL, url)
                            .putExtra(BrowserAuthActivity.EXTRA_SCHEME, scheme)
                    )
                }
                else -> result.notImplemented()
            }
        }
    }

    /// Answers the waiting call: the address the page finished on, or null
    /// when the person closed it first.
    ///
    /// Without a waiting call — the process was killed while the browser was
    /// open, and this is a fresh one — the address is dropped: the screen
    /// that asked for it is gone, and the person starts the sign-in again.
    fun finish(uri: Uri?) {
        val result = pending ?: return
        pending = null
        result.success(uri?.toString())
    }

    fun fail(code: String, message: String?) {
        val result = pending ?: return
        pending = null
        result.error(code, message, null)
    }

    /// Turns the redirect receiver on or off.
    fun setCallbackEnabled(context: Context, enabled: Boolean) {
        context.packageManager.setComponentEnabledSetting(
            ComponentName(context, BrowserAuthCallbackActivity::class.java),
            if (enabled) {
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED
            } else {
                PackageManager.COMPONENT_ENABLED_STATE_DISABLED
            },
            PackageManager.DONT_KILL_APP,
        )
    }
}

/// Opens the page and waits for it, invisibly, on top of Sennit.
///
/// A separate activity rather than [MainActivity] because the Auth Tab
/// answers through an activity result, which needs a `ComponentActivity`,
/// and because coming back to this one with nothing in hand is how a closed
/// Custom Tab is told apart from a finished one.
class BrowserAuthActivity : ComponentActivity() {
    companion object {
        const val EXTRA_URL = "url"
        const val EXTRA_SCHEME = "callbackScheme"

        /// The redirect was answered; this activity only has to close.
        const val EXTRA_RETURNED = "returned"
        private const val STATE_LAUNCHED = "launched"
        private const val STATE_AUTH_TAB = "authTab"
        private const val STATE_AWAY = "away"
    }

    private lateinit var authTab: ActivityResultLauncher<Intent>

    /// Whether the page is open, so the next resume means it was closed.
    private var launched = false

    /// Whether that page is an Auth Tab, which reports its own closing
    /// through the result; a resume before that result is not a cancel.
    private var viaAuthTab = false

    /// Whether the page has covered this activity since it was launched.
    /// The resume straight after [onCreate] comes before the tab is up, and
    /// is not the person coming back.
    private var away = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Registered on every create, as activity results require: after a
        // configuration change the result is delivered to the new instance.
        authTab = AuthTabIntent.registerActivityResultLauncher(this) { result ->
            launched = false
            BrowserAuth.finish(
                if (result.resultCode == AuthTabIntent.RESULT_OK) result.resultUri else null
            )
            finish()
        }
        launched = savedInstanceState?.getBoolean(STATE_LAUNCHED) ?: false
        viaAuthTab = savedInstanceState?.getBoolean(STATE_AUTH_TAB) ?: false
        away = savedInstanceState?.getBoolean(STATE_AWAY) ?: false
        // The redirect receiver bringing Sennit back, into a process that
        // no longer has the activity that started the sign-in.
        if (intent.getBooleanExtra(EXTRA_RETURNED, false)) {
            finish()
            return
        }
        if (launched) return
        val url = intent.getStringExtra(EXTRA_URL)?.let(Uri::parse)
        val scheme = intent.getStringExtra(EXTRA_SCHEME)
        if (url == null || scheme == null) {
            BrowserAuth.finish(null)
            finish()
            return
        }
        launch(url, scheme)
    }

    private fun launch(url: Uri, scheme: String) {
        val browser = CustomTabsClient.getPackageName(this, null)
        try {
            viaAuthTab = browser != null && CustomTabsClient.isAuthTabSupported(this, browser)
            if (viaAuthTab) {
                AuthTabIntent.Builder().build().launch(authTab, url, scheme)
            } else {
                BrowserAuth.setCallbackEnabled(this, true)
                val tab = CustomTabsIntent.Builder().build()
                // Without a Custom Tabs browser this is a plain browser
                // window; the redirect reaches the receiver all the same.
                tab.launchUrl(this, url)
            }
            launched = true
        } catch (e: ActivityNotFoundException) {
            BrowserAuth.setCallbackEnabled(this, false)
            BrowserAuth.fail("no_browser", e.message)
            finish()
        } catch (e: SecurityException) {
            BrowserAuth.setCallbackEnabled(this, false)
            BrowserAuth.fail("no_browser", e.message)
            finish()
        }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putBoolean(STATE_LAUNCHED, launched)
        outState.putBoolean(STATE_AUTH_TAB, viaAuthTab)
        outState.putBoolean(STATE_AWAY, away)
    }

    /// Back from [BrowserAuthCallbackActivity], which has answered already.
    /// Arrives before [onResume], so it is not read as "closed".
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (!intent.getBooleanExtra(EXTRA_RETURNED, false)) return
        launched = false
        finish()
    }

    override fun onPause() {
        super.onPause()
        if (launched) away = true
    }

    override fun onResume() {
        super.onResume()
        // Back here with no redirect: the Custom Tab was closed. (The Auth
        // Tab reports that itself, through the result above.)
        if (launched && away && !viaAuthTab && !isFinishing) {
            launched = false
            BrowserAuth.setCallbackEnabled(this, false)
            BrowserAuth.finish(null)
            finish()
        }
    }
}

/// Receives the redirect from a Custom Tab, answers the waiting call, and
/// brings Sennit back with the tab closed.
///
/// Disabled in the manifest; [BrowserAuth.setCallbackEnabled] turns it on
/// only while a sign-in waits.
///
/// The browser starts this in a task of its own, so the answer is given
/// here rather than by [BrowserAuthActivity]: an intent sent on from this
/// task could reach a new copy of that activity instead of the one under
/// the tab. Starting it afterwards only brings Sennit's task forward — it is
/// `singleTask` in that task — which clears the tab above it.
class BrowserAuthCallbackActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        BrowserAuth.setCallbackEnabled(this, false)
        BrowserAuth.finish(intent.data)
        startActivity(
            Intent(this, BrowserAuthActivity::class.java)
                .putExtra(BrowserAuthActivity.EXTRA_RETURNED, true)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        )
        finish()
    }
}
