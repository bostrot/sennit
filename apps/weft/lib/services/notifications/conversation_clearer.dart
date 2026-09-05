import 'package:flutter/foundation.dart';
import 'package:weft_domain/weft_domain.dart';

/// Takes down everything a conversation has left outside the app.
///
/// Three surfaces, one verb, and the reason they are one is that "read" is a
/// fact about the conversation rather than about any of them. The shade, the
/// watch and the home screen widget each showed the same message; a user who
/// has read it expects all three to stop saying so, and clearing one and not
/// the others is worse than clearing none — the phone looks caught up while the
/// wrist keeps buzzing.
///
/// The three do **not** clear the same way, which is why this exists rather than
/// three calls at each of the four call sites:
///
/// - **The shade** is cancelled directly, by group key. It is the only one with
///   rows that persist independently of the inbox.
/// - **The watch and the widget** read the snapshot, which is derived from the
///   chat list — so they clear by the list being *republished* with the chat's
///   unread count at zero. Cancelling them is not a thing that can be done; the
///   only honest action is to publish the truth again, immediately, rather than
///   waiting for whatever tick would have done it minutes later.
///
/// That asymmetry is the whole content of this class.
class ConversationClearer {
  const ConversationClearer({
    required this.dismissChat,
    required this.republish,
  });

  /// Cancels the shade rows for a chat id. Null before the notification
  /// service exists, which is most of a cold start and every widget test that
  /// does not care about notifications.
  final Future<void> Function(String chatId)? dismissChat;

  /// Rewrites the companion payload from the current chat list.
  ///
  /// Takes no argument on purpose. The list this should publish is whatever the
  /// repository holds *now*, and a snapshot passed in from a caller is one
  /// captured before the read was recorded — which republishes the unread count
  /// the clear was supposed to remove.
  final Future<void> Function()? republish;

  /// Clears [chatId] everywhere it is still showing.
  ///
  /// Both halves are attempted even if the first throws. A watch that fails to
  /// be told must not leave the shade row standing, and a shade row that fails
  /// to cancel must not leave the widget claiming three unread — each failure
  /// is one surface out of date, and letting it become two is the thing worth
  /// avoiding.
  Future<void> clear(String chatId) async {
    final dismiss = dismissChat;
    if (dismiss != null) {
      try {
        await dismiss(chatId);
      } on Object catch (error) {
        debugPrint('weft: could not clear notifications for $chatId: $error');
      }
    }

    final publish = republish;
    if (publish != null) {
      try {
        await publish();
      } on Object catch (error) {
        debugPrint('weft: could not refresh companion surfaces: $error');
      }
    }
  }
}

/// Notices conversations that have become read and clears them.
///
/// The multi-device half, and the one a `markRead` call from this device cannot
/// cover. Reading a chat on a laptop moves the account's `m.read` receipt, the
/// receipt syncs to the phone, and the phone's unread count for that chat drops
/// to zero — with nothing on the phone having *done* anything. The shade row is
/// still there, and the widget still says one unread.
///
/// A clearing push from the gateway covers the case where the phone is asleep.
/// This covers the case where it is awake and holding a socket open, which the
/// gateway may skip entirely.
///
/// Watches the *chat list* rather than raw receipts on purpose. The receipt is a
/// room fact and the notification is a conversation fact, and turning one into
/// the other is the merge fold — which the repository has already performed by
/// the time a chat reaches here. A watcher over receipts would have to redo it
/// and would get a merged contact wrong in exactly the way `dismissRoom`'s doc
/// describes.
class ReadElsewhereWatcher {
  ReadElsewhereWatcher(this._clearer);

  final ConversationClearer _clearer;

  /// Chats that were unread the last time a list arrived.
  ///
  /// The transition is what matters, not the state: a chat that has been read
  /// for a week must not be cleared on every tick, because a *new* notification
  /// for it can legitimately be posted between two ticks and would be wiped by
  /// the next one.
  final Set<String> _wereUnread = <String>{};

  /// Feeds a fresh chat list in. Safe on every inbox tick — with nothing having
  /// changed it compares a set and returns.
  Future<void> onChats(List<Chat> chats) async {
    final nowUnread = <String>{
      for (final chat in chats)
        if (chat.unreadCount > 0) chat.id,
    };

    // Only the ones that were unread and no longer are. A chat that has left
    // the list entirely is deliberately not cleared: it was archived, deleted
    // or the account signed out, and `_stopInboxSurfaces` owns that.
    final becameRead = _wereUnread.where((id) => !nowUnread.contains(id));
    final present = {for (final chat in chats) chat.id};
    for (final id in becameRead.toList()) {
      if (present.contains(id)) await _clearer.clear(id);
    }

    _wereUnread
      ..clear()
      ..addAll(nowUnread);
  }
}
