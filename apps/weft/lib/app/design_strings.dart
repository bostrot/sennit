/// The app's words, handed to `weft_design`.
///
/// A `ChatTile` draws a preview line, a pin tooltip and an unread count, and
/// none of them can live in the package: it has no ARB files and pointing it at
/// [AppL10n] would make a shared library depend on the app. So the package
/// declares what it needs as [WeftDesignStrings] and this builds one.
///
/// See `docs/architecture/l10n-pipeline.md`, "Packages and their words".
library;

import 'package:weft_design/weft_design.dart';

import 'l10n_labels.dart';
import 'localisation.dart';

/// A [WeftDesignStrings] built from the locale that resolved at this context.
WeftDesignStrings weftDesignStringsFrom(AppL10n l10n) => WeftDesignStrings(
  selectHint: l10n.chatTileSelectHint,
  pinned: l10n.chatTilePinned,
  muted: l10n.chatTileMuted,
  typing: l10n.chatTileTyping,
  online: l10n.chatTileOnline,
  mergedAcross: l10n.chatTileMergedAcross,
  unreadCount: l10n.chatTileUnread,
  deliveryState: l10n.deliveryState,
  noMessagesYet: l10n.chatTileNoMessages,
  messageDeleted: l10n.chatMessageDeleted,
  messageKind: l10n.messageKind,
  reply: l10n.chatTileReply,
  reacted: ({required own, required emoji, message}) => message == null
      ? l10n.chatTileReacted(own ? 'own' : 'other', emoji)
      : l10n.chatTileReactedTo(own ? 'own' : 'other', emoji, message),
  draft: l10n.chatTileDraft,
  messageUndecryptable: l10n.chatMessageUndecryptable,
);
