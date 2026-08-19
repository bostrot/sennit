package com.bostrot.weft.wear

import android.app.RemoteInput
import android.content.Intent
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.collectAsState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.wear.compose.foundation.lazy.ScalingLazyColumn
import androidx.wear.compose.foundation.lazy.items
import androidx.wear.compose.foundation.lazy.rememberScalingLazyListState
import androidx.wear.compose.material.Chip
import androidx.wear.compose.material.ChipDefaults
import androidx.wear.compose.material.CircularProgressIndicator
import androidx.wear.compose.material.ListHeader
import androidx.wear.compose.material.MaterialTheme
import androidx.wear.compose.material.PositionIndicator
import androidx.wear.compose.material.Scaffold
import androidx.wear.compose.material.Text
import androidx.wear.compose.material.TimeText
import androidx.wear.compose.material.Vignette
import androidx.wear.compose.material.VignettePosition
import androidx.wear.input.RemoteInputIntentHelper
import kotlinx.coroutines.delay

// MARK: - Inbox

/// The conversation list, or the one sentence explaining why there is not one.
///
/// Five states, the same five the Glance widgets and the WidgetKit widget have —
/// case for case, because three hand-written renderers of one payload that
/// disagreed about which states exist would be worse than any of them. None of
/// them is a blank screen.
@Composable
fun WeftWearInboxScreen(state: WeftWearState, onOpen: (WearRow) -> Unit) {
    val listState = rememberScalingLazyListState()
    Scaffold(
        timeText = { TimeText() },
        vignette = { Vignette(vignettePosition = VignettePosition.TopAndBottom) },
        positionIndicator = { PositionIndicator(scalingLazyListState = listState) },
    ) {
        val snapshot = state.snapshot
        if (snapshot == null || snapshot.rows.isEmpty()) {
            WeftWearEmptyState(state)
        } else {
            ScalingLazyColumn(
                modifier = Modifier.fillMaxSize(),
                state = listState,
                contentPadding = PaddingValues(horizontal = 8.dp, vertical = 32.dp),
            ) {
                item { ListHeader { Text(text = stringOf(R.string.inbox_heading)) } }
                // Keyed on the conversation rather than on the position. A
                // snapshot is replaced wholesale whenever the phone publishes and
                // rows move within it constantly; keyed by position, the list
                // animates row three's title into whatever is third *now*, which
                // shows one conversation's name beside another's badge for a
                // frame. The same reason `WeftSnapshotRow` is `Identifiable` on
                // Swift and the Glance rows carry a stable `itemId`.
                items(snapshot.rows, key = { it.chatId }) { row ->
                    WeftWearConversationChip(
                        row = row,
                        palette = snapshot.palette,
                        onClick = { onOpen(row) },
                    )
                }
            }
        }
    }
}

/// One conversation.
///
/// A `Chip` rather than a hand-drawn row: it is the platform's own touch target
/// size, and on a watch that is a safety property rather than a style — the
/// thing being tapped is "open a reply screen for this person".
///
/// Merged conversations are signalled two ways, neither of them colour alone:
/// the *number* of network dots, and the content description. `ChatTile` on the
/// phone manages three; a row this size can carry two, which is the floor the
/// design notes set.
@Composable
private fun WeftWearConversationChip(
    row: WearRow,
    palette: Map<String, Int>,
    onClick: () -> Unit,
) {
    val context = LocalContext.current
    Chip(
        onClick = onClick,
        modifier = Modifier
            .fillMaxWidth()
            // Assembled rather than left to the default, which would read the
            // title, the preview and the badge as three unrelated strings in
            // layout order — so a merged conversation would be indistinguishable
            // from a plain one and the unread count would arrive after the
            // message it belongs to.
            .semantics { contentDescription = rowDescription(context, row) },
        colors = if (row.unreadCount > 0) {
            ChipDefaults.primaryChipColors()
        } else {
            ChipDefaults.secondaryChipColors()
        },
        icon = { WeftWearNetworkDots(row, palette) },
        label = {
            Text(
                text = row.title,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                // Unread is what this surface exists to show, so it is carried
                // by weight as well as by the chip's colour — the same "never one
                // signal alone" rule the merged indicator follows, and the one
                // that survives a wearer who cannot tell the two chip fills
                // apart.
                fontWeight = if (row.unreadCount > 0) FontWeight.Bold else FontWeight.Normal,
            )
        },
        secondaryLabel = row.preview?.let {
            {
                // Already policy-filtered, already rendered per kind by
                // `weft_notify`, already cut at a grapheme boundary. Nothing here
                // re-truncates it: a second cut would be a second rule, measured
                // in the wrong units.
                Text(text = previewLine(row), maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        },
    )
}

/// One dot per network feeding the conversation, in the payload's order.
///
/// Colours come from `InboxSnapshot.palette` — carried once per payload rather
/// than re-tabled here — and fall back to a neutral when the payload names a
/// network this build has never heard of. That fallback is why the *count* of
/// dots rather than their colour is what says "merged": an unknown network still
/// gets a dot.
@Composable
private fun WeftWearNetworkDots(row: WearRow, palette: Map<String, Int>) {
    Column(
        verticalArrangement = Arrangement.spacedBy(2.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier.width(10.dp),
    ) {
        for (network in row.networks.take(WeftWearTokens.MAX_NETWORK_DOTS)) {
            Box(
                modifier = Modifier
                    .size(6.dp)
                    .clip(CircleShape)
                    .background(
                        palette[network]?.let { WeftWearTokens.color(it) }
                            ?: WeftWearTokens.unknownNetwork
                    )
            )
        }
    }
}

/// `Grace: on my way`, or the preview alone when names are withheld.
///
/// The sender is already disambiguated by network for a merged chat
/// (`snapshotSenderName`), so nothing is added here beyond the separator.
private fun previewLine(row: WearRow): String {
    val preview = row.preview.orEmpty()
    val sender = row.senderName
    return if (sender.isNullOrEmpty()) preview else "$sender: $preview"
}

private fun rowDescription(context: android.content.Context, row: WearRow): String {
    val parts = mutableListOf(row.title)
    if (row.isMerged) parts.add(context.getString(R.string.merged))
    if (row.unreadCount > 0) parts.add(WeftWearStrings.unreadCount(context, row.unreadCount))
    row.preview?.let { parts.add(previewLine(row)) }
    return parts.joinToString(", ")
}

/// A state with nothing to show, saying why.
///
/// Every branch that is not a populated `Ready` lands here, and each names its
/// own cause and, where there is one, the thing the wearer would do about it.
/// The stale and switched-off sentences are the phase brief's requirement in
/// literal form: *a clear "open Weft on your phone" state when the snapshot is
/// stale, disabled or absent*.
@Composable
fun WeftWearEmptyState(state: WeftWearState) {
    val context = LocalContext.current
    val (title, body) = WeftWearStrings.emptyState(context, state)
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(
            text = title,
            style = MaterialTheme.typography.title3,
            textAlign = TextAlign.Center,
        )
        Spacer(modifier = Modifier.size(4.dp))
        Text(
            text = body,
            style = MaterialTheme.typography.body2,
            color = WeftWearTokens.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
    }
}

// MARK: - Reply

/// Dictate, or tap one of six sentences.
///
/// **Nothing on this screen sends a message.** It hands a string to
/// [WeftWearOutbox], which asks the phone; the phone resolves the conversation,
/// picks the leg and sends, and answers. Everything below the divider between
/// those two facts is why this app has no `INTERNET` permission.
///
/// Dictation opens the *system's* input picker rather than a recogniser of this
/// app's own, which is what makes the keyboard, the emoji grid and drawn
/// characters available on watches that have them — and what makes this work at
/// all on a watch with no microphone.
@Composable
fun WeftWearReplyScreen(row: WearRow, onSent: () -> Unit) {
    val context = LocalContext.current
    val listState = rememberScalingLazyListState()
    var replyId by remember { mutableStateOf<String?>(null) }
    val replies by WeftWearOutbox.replies.collectAsState()
    val outcome = replyId?.let { replies[it] }

    val dictate = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result ->
        val spoken = RemoteInput.getResultsFromIntent(result.data)
            ?.getCharSequence(REMOTE_INPUT_KEY)
            ?.toString()
            ?.trim()
        // A cancelled dictation and an empty one are the same thing and neither
        // is an error: the wearer changed their mind, and the screen stays where
        // it was.
        if (!spoken.isNullOrEmpty()) {
            replyId = WeftWearOutbox.send(context, row.chatId, spoken)
        }
    }

    // The screen closes itself once the phone has confirmed, and only then. A
    // dismiss on tap would take the one surface that can report a failure away
    // before the failure arrives — which is the silent dropped reply this whole
    // path exists to make impossible.
    LaunchedEffect(outcome) {
        if (outcome is WeftReplyState.Sent) {
            delay(1_200)
            onSent()
        }
    }

    Scaffold(
        timeText = { TimeText() },
        vignette = { Vignette(vignettePosition = VignettePosition.TopAndBottom) },
        positionIndicator = { PositionIndicator(scalingLazyListState = listState) },
    ) {
        if (outcome != null) {
            WeftWearReplyOutcome(outcome)
            return@Scaffold
        }
        ScalingLazyColumn(
            modifier = Modifier.fillMaxSize(),
            state = listState,
            contentPadding = PaddingValues(horizontal = 8.dp, vertical = 32.dp),
        ) {
            item {
                ListHeader {
                    Text(
                        text = row.title,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            item {
                Chip(
                    onClick = {
                        dictate.launch(
                            dictationIntent(context.getString(R.string.reply_dictate_hint, row.title))
                        )
                    },
                    modifier = Modifier.fillMaxWidth(),
                    colors = ChipDefaults.primaryChipColors(),
                    label = { Text(text = stringOf(R.string.reply_dictate)) },
                )
            }
            items(WeftWearStrings.cannedReplies(context)) { canned ->
                Chip(
                    onClick = { replyId = WeftWearOutbox.send(context, row.chatId, canned) },
                    modifier = Modifier.fillMaxWidth(),
                    colors = ChipDefaults.secondaryChipColors(),
                    label = { Text(text = canned, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                )
            }
        }
    }
}

/// Sending, sent, or the sentence for why not.
///
/// A screen of its own rather than a toast, because a failure here is the one
/// thing a wearer must not miss: the message they believe they sent did not go,
/// and the only place that can be said is the surface they are still looking at.
@Composable
private fun WeftWearReplyOutcome(outcome: WeftReplyState) {
    val context = LocalContext.current
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        when (outcome) {
            WeftReplyState.Sending -> {
                CircularProgressIndicator(modifier = Modifier.size(28.dp))
                Spacer(modifier = Modifier.size(8.dp))
                Text(
                    text = stringOf(R.string.reply_sending),
                    style = MaterialTheme.typography.body2,
                    textAlign = TextAlign.Center,
                )
            }
            is WeftReplyState.Sent -> Text(
                // The leg is named only for a merged conversation, where the
                // phone had a choice to make. A one-network chat reporting "via
                // WhatsApp" would spend a line of a very small screen on
                // something the wearer could not have changed.
                text = outcome.network
                    ?.let { context.getString(R.string.reply_sent_via, it) }
                    ?: stringOf(R.string.reply_sent),
                style = MaterialTheme.typography.title3,
                textAlign = TextAlign.Center,
            )
            is WeftReplyState.Failed -> Text(
                text = WeftWearStrings.replyFailure(context, outcome.failure),
                style = MaterialTheme.typography.body2,
                color = WeftWearTokens.error,
                textAlign = TextAlign.Center,
            )
        }
    }
}

/// The key the dictated text comes back under. One constant, used to build the
/// `RemoteInput` and to read the result, because a mismatch between the two is
/// a dictation that succeeds and returns nothing.
private const val REMOTE_INPUT_KEY = "weft_reply"

private fun dictationIntent(label: String): Intent {
    val intent = RemoteInputIntentHelper.createActionRemoteInputIntent()
    RemoteInputIntentHelper.putRemoteInputsExtra(
        intent,
        listOf(RemoteInput.Builder(REMOTE_INPUT_KEY).setLabel(label).build()),
    )
    return intent
}

@Composable
private fun stringOf(id: Int): String = LocalContext.current.getString(id)
