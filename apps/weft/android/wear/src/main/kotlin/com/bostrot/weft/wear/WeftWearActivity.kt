package com.bostrot.weft.wear

import android.content.SharedPreferences
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.navigation.NavType
import androidx.navigation.navArgument
import androidx.wear.compose.navigation.SwipeDismissableNavHost
import androidx.wear.compose.navigation.composable
import androidx.wear.compose.navigation.rememberSwipeDismissableNavController
import com.bostrot.weft.snapshot.SnapshotRow
import kotlinx.coroutines.delay

/// The watch app.
///
/// A list of conversations and a reply screen, and that is deliberately all of
/// it. There is no timeline here, no history and no search: this device holds no
/// Matrix session, so everything it can show is the handful of rows the phone
/// decided to send it, and building a screen that looked like more would be
/// promising a conversation it cannot open.
///
/// The whole app is one activity, because the whole app is two screens and
/// `SwipeDismissableNavHost` is what makes the back gesture on a watch — a swipe
/// from the left edge — behave the way the platform's own apps do.
class WeftWearActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { WeftWearTheme { WeftWearApp() } }
    }
}

@Composable
fun WeftWearApp() {
    val navController = rememberSwipeDismissableNavController()
    val state = rememberWearState()

    SwipeDismissableNavHost(navController = navController, startDestination = ROUTE_INBOX) {
        composable(ROUTE_INBOX) {
            WeftWearInboxScreen(
                state = state,
                // The chat id is percent-encoded into the route because it is a
                // room id — `!abc:example.org` — and a bare colon and slash in a
                // navigation argument is a route that does not match anything.
                // The same escaping problem `chatDeepLink` solves on the phone,
                // one layer in.
                onOpen = { row -> navController.navigate("$ROUTE_REPLY/${Uri.encode(row.chatId)}") },
            )
        }
        composable(
            "$ROUTE_REPLY/{chatId}",
            arguments = listOf(navArgument("chatId") { type = NavType.StringType }),
        ) { entry ->
            val chatId = entry.arguments?.getString("chatId").orEmpty()
            // Looked up in the *current* state rather than passed through the
            // route. A snapshot can land while the reply screen is open, and a
            // row captured at navigation time would keep showing a title and an
            // unread count that the inbox behind it has already moved on from.
            val row = state.snapshot?.rows?.firstOrNull { it.chatId == chatId }
            if (row == null) {
                // The conversation left the snapshot while this screen was open,
                // or the phone signed out. Popping rather than drawing an empty
                // reply screen: there is nothing here to reply to, and a screen
                // that says so is a screen the wearer has to dismiss.
                LaunchedEffect(chatId) { navController.popBackStack() }
            } else {
                WeftWearReplyScreen(row = row, onSent = { navController.popBackStack() })
            }
        }
    }
}

private const val ROUTE_INBOX = "inbox"
private const val ROUTE_REPLY = "reply"

/// The current state, kept current two ways.
///
/// Both are needed and neither is enough alone:
///
/// * A `SharedPreferences` listener, for content. [WeftWearDataService] writes
///   the cache from a system-started process, and the app may be in the
///   foreground while it happens — a watch showing the inbox while a message
///   arrives on the phone is the normal case, not the exotic one.
/// * A slow tick, for **staleness**. Nothing writes anything when a snapshot
///   crosses `kSnapshotStaleAfter`; the payload simply stops being true, and a
///   watch that only re-read on change would present yesterday's counts
///   indefinitely. A minute is far finer than a twelve-hour boundary needs and
///   is cheap while the screen is on, which is the only time this composition
///   exists.
///
/// The initial [WeftWearStore.sync] is the third case, and the one no event
/// covers: this app installed onto a watch whose phone published before it
/// existed will never receive a change, because nothing changed.
@Composable
private fun rememberWearState(): WeftWearState {
    val context = LocalContext.current
    var state by remember {
        mutableStateOf(WeftWearState.read(context, System.currentTimeMillis()))
    }

    DisposableEffect(context) {
        val prefs = context.applicationContext.getSharedPreferences(
            WeftWearStore.PREFS_NAME, android.content.Context.MODE_PRIVATE)
        val listener = SharedPreferences.OnSharedPreferenceChangeListener { _, _ ->
            state = WeftWearState.read(context, System.currentTimeMillis())
        }
        prefs.registerOnSharedPreferenceChangeListener(listener)
        onDispose { prefs.unregisterOnSharedPreferenceChangeListener(listener) }
    }

    LaunchedEffect(Unit) {
        WeftWearStore.sync(context)
        while (true) {
            state = WeftWearState.read(context, System.currentTimeMillis())
            delay(60_000)
        }
    }

    return state
}

/// One row, as the reply screen needs it. Named so the screens can be read
/// without `com.bostrot.weft.snapshot.` in every signature.
internal typealias WearRow = SnapshotRow
