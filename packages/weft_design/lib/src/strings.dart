/// The words a design-system component puts on screen, supplied by the app.
///
/// A package cannot hold translations. `weft_design` is shared, it has no ARB
/// files of its own, and pointing it at the app's `AppL10n` would make a
/// library depend on the thing that consumes it — so a `ChatTile` that carried
/// its own English would be a row no locale could ever reach.
///
/// The rule for the whole workspace is that a package answers in *values* and
/// the app turns them into words: a rejection carries a reason and a byte
/// count, a notification carries a [MessageKind]. A widget is the one case
/// where that is not enough, because the widget is what draws — so it takes the
/// words as a parameter instead, through this scope.
///
/// [WeftDesignStrings.english] is the fallback, and it is a real fallback
/// rather than a placeholder: a component with no scope above it renders
/// readable English, which is exactly what a widget test that pumps a bare
/// `MaterialApp` should get. The app installs a scope built from `AppL10n`
/// near its root, and from then on every component follows the app's locale.
///
/// See `docs/architecture/l10n-pipeline.md`, "Packages and their words".
library;

import 'package:flutter/widgets.dart';
import 'package:weft_domain/weft_domain.dart';

/// Every string `weft_design` needs and cannot invent for itself.
///
/// Function-typed for anything that interpolates or counts, so a language with
/// more than two plural forms can express them — the app hands over an ICU
/// message; the English fallback below is the degenerate two-form case.
@immutable
class WeftDesignStrings {
  const WeftDesignStrings({
    required this.selectHint,
    required this.pinned,
    required this.muted,
    required this.typing,
    required this.online,
    required this.merged,
    required this.mergedAcross,
    required this.unreadCount,
    required this.deliveryState,
    required this.noMessagesYet,
    required this.messageDeleted,
    required this.messageKind,
    required this.reply,
  });

  /// Screen-reader hint for the long-press that starts multi-select.
  final String selectHint;

  /// The tooltip on the pin glyph, and the clause in the row's own sentence.
  final String pinned;

  /// The tooltip on the mute glyph, and the clause in the row's sentence.
  final String muted;

  /// Shown in place of the preview while somebody is writing.
  final String typing;

  /// The clause naming a contact as reachable right now.
  final String online;

  /// The badge on a merged row.
  final String merged;

  /// "merged across 3 networks: WhatsApp, Signal" — the clause that names
  /// *which* networks, since a count alone never said.
  final String Function(int count, String networks) mergedAcross;

  /// "3 unread", for the row's screen-reader sentence.
  final String Function(int count) unreadCount;

  /// A message's delivery state in words, or empty when there is nothing worth
  /// saying. Read and delivered are the same double tick in two colours, which
  /// is the one distinction a colour-blind reader cannot make.
  final String Function(DeliveryState? state) deliveryState;

  /// The preview line for a conversation nobody has said anything in.
  final String noMessagesYet;

  /// The preview line for a conversation whose newest message was redacted.
  final String messageDeleted;

  /// The preview line for a message with no words of its own — a photo, a
  /// file, a poll. The emoji in front of it is the component's, not the app's.
  final String Function(MessageKind kind) messageKind;

  /// One word for "this message answers another one".
  ///
  /// Three jobs, which is why it is one string: the tooltip on the inbox row's
  /// reply glyph, the clause naming that glyph in the row's screen-reader
  /// sentence, and the whole preview for a reply that carried no text of its
  /// own — a bridged quote-and-nothing-else, which would otherwise render as a
  /// blank line indistinguishable from an empty conversation.
  final String reply;

  /// Readable English, for a component with no scope above it.
  static const WeftDesignStrings english = WeftDesignStrings(
    selectHint: 'select',
    pinned: 'pinned',
    muted: 'muted',
    typing: 'typing',
    online: 'online',
    merged: 'Merged',
    mergedAcross: _englishMergedAcross,
    unreadCount: _englishUnread,
    deliveryState: _englishDelivery,
    noMessagesYet: 'No messages yet',
    messageDeleted: 'Message deleted',
    messageKind: _englishKind,
    reply: 'Reply',
  );
}

String _englishMergedAcross(int count, String networks) =>
    'merged across $count networks: $networks';

String _englishUnread(int count) => '$count unread';

String _englishDelivery(DeliveryState? state) => switch (state) {
  DeliveryState.sending => 'Sending',
  DeliveryState.sent => 'Sent',
  DeliveryState.delivered => 'Delivered',
  DeliveryState.read => 'Read',
  DeliveryState.failed => 'Not sent',
  null => '',
};

String _englishKind(MessageKind kind) => switch (kind) {
  MessageKind.image => 'Photo',
  MessageKind.video => 'Video',
  MessageKind.voice => 'Voice message',
  MessageKind.audio => 'Audio',
  MessageKind.file => 'File',
  MessageKind.sticker => 'Sticker',
  MessageKind.location => 'Location',
  MessageKind.poll => 'Poll',
  MessageKind.event => 'Event',
  MessageKind.text => 'Message',
};

/// Puts one [WeftDesignStrings] over a subtree.
///
/// Installed once, near the app's root, above anything that draws a component
/// with words in it. Absent, [WeftDesignStrings.english] applies.
class WeftDesignStringsScope extends InheritedWidget {
  const WeftDesignStringsScope({
    required this.strings,
    required super.child,
    super.key,
  });

  final WeftDesignStrings strings;

  static WeftDesignStrings of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<WeftDesignStringsScope>()
          ?.strings ??
      WeftDesignStrings.english;

  @override
  bool updateShouldNotify(WeftDesignStringsScope old) => old.strings != strings;
}
