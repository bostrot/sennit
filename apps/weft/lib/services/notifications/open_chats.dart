import 'package:flutter/widgets.dart';

/// Which conversations are on screen right now.
///
/// The one thing the notification path could not know: a message that arrives
/// in the conversation the user is reading was being announced over the top of
/// itself — a banner, a sound and a row in the shade for a line that had just
/// been drawn in front of them.
///
/// Counted rather than held as a set, because one conversation can be on
/// screen twice — a thread is the same chat pushed over itself — and leaving
/// the thread must not make the conversation underneath stop counting.
///
/// "On screen" needs both halves. A chat left open in a backgrounded app, or
/// in a desktop window behind another one, is not being read, and that is
/// exactly when the notification is wanted.
class OpenChats {
  OpenChats({bool Function()? isForeground})
    : _isForeground = isForeground ?? _appIsResumed;

  final bool Function() _isForeground;
  final Map<String, int> _open = {};

  /// A screen showing [chatId] came up.
  void enter(String chatId) => _open[chatId] = (_open[chatId] ?? 0) + 1;

  /// A screen showing [chatId] went away. Leaving a chat that was never
  /// entered does nothing.
  void leave(String chatId) {
    final count = _open[chatId];
    if (count == null) return;
    if (count <= 1) {
      _open.remove(chatId);
    } else {
      _open[chatId] = count - 1;
    }
  }

  /// Whether the user is looking at [chatId].
  bool isOpen(String chatId) => _open.containsKey(chatId) && _isForeground();

  // Only `resumed`: `inactive` is a desktop window that lost focus and a phone
  // with the shade pulled down over it, and an unknown state is not evidence
  // of anyone looking. Erring towards a notification is the safe direction.
  static bool _appIsResumed() =>
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
}
