import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:weft_store/weft_store.dart';

import '../services/ai/quick_messages.dart';
import 'stores.dart';

/// The quick messages the composer's attach menu offers, in order.
///
/// One JSON blob in [WeftSettings.quickMessages], as the auto-reply rules are
/// kept. No blob means the built-in list; an emptied list is stored as an
/// empty one, so deleting every default does not bring them back on the next
/// launch — only "Restore defaults" does.
class QuickMessages extends Notifier<List<QuickMessage>> {
  @override
  List<QuickMessage> build() {
    try {
      return QuickMessage.listFromJson(
        ref.read(storesProvider).settings.getJson(WeftSettings.quickMessages),
      );
    } on Object {
      // Stores not bootstrapped: a widget test, or a launch still starting.
      return QuickMessage.defaults;
    }
  }

  /// Replaces the list and persists it.
  void replaceAll(List<QuickMessage> messages) {
    final next = List<QuickMessage>.unmodifiable(messages);
    try {
      ref
          .read(storesProvider)
          .settings
          .setJson(WeftSettings.quickMessages, QuickMessage.listToJson(next));
      ref.read(settingsRevisionProvider.notifier).bump();
    } on Object {
      // In memory only, as above.
    }
    state = next;
  }

  /// Adds [message], or replaces the one with the same id.
  void save(QuickMessage message) {
    final index = state.indexWhere((m) => m.id == message.id);
    replaceAll([
      if (index < 0) ...[
        ...state,
        message,
      ] else
        for (var i = 0; i < state.length; i++)
          if (i == index) message else state[i],
    ]);
  }

  void remove(String id) => replaceAll([
    for (final m in state)
      if (m.id != id) m,
  ]);

  /// Moves the entry at [oldIndex] to [newIndex], counted in the list with
  /// the moved entry already taken out — `onReorderItem`'s convention.
  void reorder(int oldIndex, int newIndex) {
    final next = [...state];
    final moved = next.removeAt(oldIndex);
    next.insert(newIndex.clamp(0, next.length), moved);
    replaceAll(next);
  }

  /// Back to the shipped list, following the app language again.
  void restoreDefaults() {
    try {
      ref.read(storesProvider).settings.remove(WeftSettings.quickMessages);
      ref.read(settingsRevisionProvider.notifier).bump();
    } on Object {
      // In memory only.
    }
    state = QuickMessage.defaults;
  }
}

final quickMessagesProvider =
    NotifierProvider<QuickMessages, List<QuickMessage>>(QuickMessages.new);

/// The HTTP client quick messages are written through; null for a fresh one
/// per request. A seam for tests, which answer for the model.
final quickMessageClientProvider = Provider<http.Client?>((ref) => null);
