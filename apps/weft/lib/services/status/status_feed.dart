import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_store/weft_store.dart';

import '../../app/providers.dart';
import '../../app/stores.dart';

/// One contact's stack of current statuses.
class StatusEntry {
  const StatusEntry({
    required this.senderId,
    required this.senderName,
    required this.messages,
    this.avatarUrl,
  });

  final String senderId;
  final String senderName;
  final String? avatarUrl;

  /// Newest first.
  final List<WeftMessage> messages;
}

/// How statuses are shown: rings above the inbox, the broadcast group as a
/// normal chat, or not at all.
enum StatusMode { rings, group, off }

final statusModeProvider = Provider<StatusMode>((ref) {
  ref.watch(settingsRevisionProvider);
  final raw = storesOrNull(ref)?.settings.getString(WeftSettings.statusMode);
  return switch (raw) {
    'group' => StatusMode.group,
    'off' => StatusMode.off,
    _ => StatusMode.rings,
  };
});

/// Kept for the code that only asks "rings or not".
final statusRingsEnabledProvider = Provider<bool>(
  (ref) => ref.watch(statusModeProvider) == StatusMode.rings,
);

/// People whose statuses the user asked never to see.
class HiddenStatusSenders extends Notifier<Set<String>> {
  @override
  Set<String> build() {
    final json = storesOrNull(
      ref,
    )?.settings.getJson(WeftSettings.statusHiddenSenders);
    final list = json?['senders'];
    if (list is! List) return const {};
    return {...list.whereType<String>()};
  }

  void hide(String senderId) {
    state = {...state, senderId};
    _persist();
  }

  void reset() {
    state = const {};
    _persist();
  }

  void _persist() {
    storesOrNull(ref)?.settings.setJson(WeftSettings.statusHiddenSenders, {
      'senders': state.toList()..sort(),
    });
  }
}

final hiddenStatusSendersProvider =
    NotifierProvider<HiddenStatusSenders, Set<String>>(HiddenStatusSenders.new);

/// The bridge's status broadcast conversation, when the account has one.
///
/// mautrix-whatsapp names it "WhatsApp Status Broadcast"; matching on the
/// phrase keeps it working if the prefix ever localises. Detected regardless
/// of the toggle — the toggle only decides which *shape* it is shown in.
final statusChatProvider = Provider<Chat?>((ref) {
  final chats = ref.watch(chatsProvider).value ?? const <Chat>[];
  for (final chat in chats) {
    if (chat.title.toLowerCase().contains('status broadcast')) return chat;
  }
  return null;
});

/// The ring row's content: recent statuses, grouped per contact.
final statusFeedProvider = FutureProvider<List<StatusEntry>>((ref) async {
  final chat = ref.watch(statusChatProvider);
  if (chat == null || !ref.watch(statusRingsEnabledProvider)) return const [];
  final hidden = ref.watch(hiddenStatusSendersProvider);

  final repository = ref.watch(chatRepositoryProvider);
  final timeline = await repository.timelineFor(chat.id);
  // One page is plenty: statuses expire after a day on the network itself.
  await timeline.loadMore(count: 60);

  final cutoff = DateTime.now().subtract(const Duration(hours: 48));
  final bySender = <String, List<WeftMessage>>{};
  for (final source in timeline.sources) {
    for (final message in source.loaded) {
      if (message.timestamp.isBefore(cutoff) || message.redacted) continue;
      if (message.isOwn || hidden.contains(message.senderId)) continue;
      bySender.putIfAbsent(message.senderId, () => []).add(message);
    }
  }

  final graph = repository.identityGraph;
  final entries = <StatusEntry>[
    for (final entry in bySender.entries)
      StatusEntry(
        senderId: entry.key,
        senderName: entry.value.first.senderName,
        avatarUrl: graph.handleFor(entry.key)?.avatarUrl,
        messages: entry.value
          ..sort((a, b) => b.timestamp.compareTo(a.timestamp)),
      ),
  ];
  // Freshest story first, like everywhere else stories live.
  entries.sort(
    (a, b) => b.messages.first.timestamp.compareTo(a.messages.first.timestamp),
  );
  return entries;
});
