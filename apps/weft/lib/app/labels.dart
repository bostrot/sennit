import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'stores.dart';

const String _labelsKey = 'labels.by_chat';

/// User-made labels on chats — "Work", "Family", "Verein" — and the filter
/// built on them.
///
/// Stored as one JSON blob under settings rather than a table: the whole map
/// is read at startup, written on every change, and it is inbox metadata a
/// few hundred entries large at the very most.
class ChatLabels extends Notifier<Map<String, Set<String>>> {
  @override
  Map<String, Set<String>> build() {
    final json = storesOrNull(ref)?.settings.getJson(_labelsKey);
    final byChat = json?['chats'];
    if (byChat is! Map) return const {};
    return {
      for (final entry in byChat.entries)
        if (entry.value is List)
          entry.key as String: {
            for (final label in entry.value as List)
              if (label is String && label.isNotEmpty) label,
          },
    };
  }

  /// Every label anywhere, sorted — what the filter row offers.
  List<String> get all {
    final labels = <String>{for (final set in state.values) ...set};
    return labels.toList()..sort();
  }

  Set<String> ofChat(String chatId) => state[chatId] ?? const {};

  void toggle(Iterable<String> chatIds, String label) {
    final trimmed = label.trim();
    if (trimmed.isEmpty) return;

    final next = {
      for (final entry in state.entries) entry.key: {...entry.value},
    };
    // Bulk semantics: if *any* selected chat lacks the label, this adds it
    // everywhere; only when all carry it does the tap remove it. Matches what
    // "label these five" means when three already have it.
    final adding = chatIds.any((id) => !(next[id]?.contains(trimmed) ?? false));
    for (final id in chatIds) {
      final labels = next.putIfAbsent(id, () => {});
      if (adding) {
        labels.add(trimmed);
      } else {
        labels.remove(trimmed);
      }
      if (labels.isEmpty) next.remove(id);
    }
    state = next;
    _persist();
  }

  void _persist() {
    storesOrNull(ref)?.settings.setJson(_labelsKey, {
      'chats': {
        for (final entry in state.entries)
          entry.key: entry.value.toList()..sort(),
      },
    });
  }
}

final chatLabelsProvider =
    NotifierProvider<ChatLabels, Map<String, Set<String>>>(ChatLabels.new);

/// The label the inbox is filtered to, or null for all conversations.
class LabelFilter extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String? label) => state = state == label ? null : label;
}

final labelFilterProvider = NotifierProvider<LabelFilter, String?>(
  LabelFilter.new,
);
