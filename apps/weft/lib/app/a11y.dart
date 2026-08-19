/// The app's one answer to "how does a screen reader learn that something
/// happened?".
///
/// Two mechanisms, and which one is right depends on whether there is anything
/// on screen to point at:
///
/// - A `Semantics` node with `liveRegion: true` is for something *visible*
///   whose label changes — a warning strip that appears, a status line moving
///   from "Uploading" to "Failed". The reader re-announces the node when its
///   label changes, and the user can still navigate back to it afterwards.
/// - [announce] is for something with no node at all: a message that arrived
///   below the fold, a transcription that finished, an operation that reported
///   itself in a `SnackBar` which will be gone in four seconds.
///
/// [showWeftMessage] exists because that second case was the app's *only* error
/// channel and it was silent. Flutter's `SnackBar` sets no live region and
/// disappears on a timer, so a reader who was elsewhere in the tree when a send
/// failed was never told — and by the time they navigated over, there was
/// nothing to find. Every call site that reaches for `ScaffoldMessenger`
/// directly should reach for this instead: it puts the same words on the screen
/// *and* into the announcement queue.
///
/// The label vocabulary itself — delivery states, message kinds, the sentence
/// joiner — lives in `weft_design`, because an inbox row and a message bubble
/// have to describe the same state with the same words.
library;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

/// Speaks [message] without needing a widget to hang it on.
///
/// The direction is resolved from [context] rather than assumed left-to-right:
/// the platform channel takes one, and an Arabic announcement queued as LTR is
/// spoken in the wrong order by some engines.
///
/// Silent when [message] is blank — an announcement of nothing still interrupts
/// whatever the reader was on.
///
/// `sendAnnouncement` rather than the deprecated `announce`: the latter reaches
/// for `PlatformDispatcher.implicitView` and asserts when there is not exactly
/// one, which on desktop is a real configuration rather than a hypothetical.
/// The view comes from [context], which is the window the user is actually
/// looking at.
void announce(BuildContext context, String message, {Assertiveness? level}) {
  if (message.trim().isEmpty) return;
  SemanticsService.sendAnnouncement(
    View.of(context),
    message,
    Directionality.maybeOf(context) ?? TextDirection.ltr,
    assertiveness: level ?? Assertiveness.polite,
  );
}

/// A `SnackBar` that a screen reader also hears.
///
/// Both, rather than one or the other: a sighted user needs the bar, and a
/// reader needs the words to outlive it.
void showWeftMessage(BuildContext context, String message) {
  ScaffoldMessenger.maybeOf(
    context,
  )?.showSnackBar(SnackBar(content: Text(message)));
  // Assertive on purpose: everything routed through here is the report of
  // something the user asked for having failed or finished. Polite would queue
  // it behind whatever is being read — in practice, behind the bar's own
  // lifetime.
  announce(context, message, level: Assertiveness.assertive);
}
