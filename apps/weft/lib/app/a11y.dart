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

/// A control renamed to say what it acts on, and still operable.
///
/// Six suggestion cards give six buttons reading "Merge"; a contact with three
/// legs gives three reading "Unmerge"; five model cards give five reading
/// "Download", one of which is a 1.5 GB file. The word on the button is right
/// for someone who can see which row it is in and useless to everyone else.
///
/// A bare `Semantics(label:)` around a button does **not** reliably replace its
/// name: a Material button forms its own semantics node from its own child, so
/// depending on the button an annotation above it is either dropped or left
/// speaking beside the label it was meant to replace — which is a control that
/// announces itself twice, in two different words. Owning the node means
/// excluding the subtree, and excluding the subtree takes the button's tap
/// action with it. Restating that action is the part every hand-written copy of
/// this would eventually forget, so it lives here once.
class NamedButton extends StatelessWidget {
  const NamedButton({
    super.key,
    required this.label,
    required this.onPressed,
    required this.child,
  });

  /// What the button does, and to what.
  final String label;

  /// The child's own callback, restated on the node that replaces it. Null
  /// renders the node disabled, matching a button with no callback.
  final VoidCallback? onPressed;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      button: true,
      enabled: onPressed != null,
      label: label,
      excludeSemantics: true,
      onTap: onPressed,
      child: child,
    );
  }
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
