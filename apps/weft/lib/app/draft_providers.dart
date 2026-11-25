import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_store/weft_store.dart';

import '../services/sync/store_sync_local.dart';
import 'stores.dart';

/// What was typed into each conversation and not sent, by chat id.
///
/// Kept in the settings table under [prefix] rather than a table of its own:
/// a draft is one short string per chat, and the settings table already
/// survives restarts and backups. The prefix is outside every synced settings
/// prefix on purpose — device sync carries drafts under their own key, so a
/// draft deleted on one device is deleted on the others too.
///
/// The state is what the inbox shows, and it moves only when a conversation is
/// left: a draft still being typed is the composer's, and the inbox row of the
/// chat on screen next to it should not flicker with every keystroke. [save]
/// is the quiet half that keeps the text safe meanwhile.
class DraftsNotifier extends Notifier<Map<String, String>> {
  static const String prefix = StoreSyncLocal.draftPrefix;

  SettingsStore? _settings;

  @override
  Map<String, String> build() {
    _settings = storesOrNull(ref)?.settings;
    return _read();
  }

  Map<String, String> _read() {
    final settings = _settings;
    if (settings == null) return const {};
    return {
      for (final MapEntry(:key, :value) in settings.all().entries)
        if (key.startsWith(prefix)) key.substring(prefix.length): value,
    };
  }

  /// The draft for any of [chatIds], first match wins.
  String? draftFor(Iterable<String> chatIds) {
    for (final id in chatIds) {
      final text = _settings?.getString('$prefix$id');
      if (text != null) return text;
    }
    return null;
  }

  /// Stores [text] as [chatId]'s draft without telling the inbox; blank text
  /// removes it.
  void save(String chatId, String text) {
    final settings = _settings;
    if (settings == null) return;
    if (text.trim().isEmpty) {
      settings.remove('$prefix$chatId');
    } else {
      settings.setString('$prefix$chatId', text);
    }
  }

  /// [save], and the inbox shows the result.
  ///
  /// The state moves in a microtask, because this is called from a screen's
  /// `dispose` — inside the frame that unmounts it, where Riverpod does not
  /// allow a provider to change.
  void keep(String chatId, String text) {
    save(chatId, text);
    scheduleMicrotask(reload);
  }

  /// Re-reads every draft — after device sync wrote some.
  void reload() {
    // A screen left as the app shuts down holds a notifier that is gone.
    if (!ref.mounted) return;
    final next = _read();
    if (!_same(next, state)) state = next;
  }

  static bool _same(Map<String, String> a, Map<String, String> b) =>
      a.length == b.length && a.entries.every((e) => b[e.key] == e.value);
}

final draftsProvider = NotifierProvider<DraftsNotifier, Map<String, String>>(
  DraftsNotifier.new,
);
