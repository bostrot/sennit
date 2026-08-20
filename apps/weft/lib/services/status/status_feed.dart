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

/// Whether statuses show as rings instead of as the broadcast group.
final statusRingsEnabledProvider = Provider<bool>((ref) {
  ref.watch(settingsRevisionProvider);
  return storesOrNull(
        ref,
      )?.settings.getBool(WeftSettings.statusRings, fallback: true) ??
      false;
});

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

  final repository = ref.watch(chatRepositoryProvider);
  final timeline = await repository.timelineFor(chat.id);
  // One page is plenty: statuses expire after a day on the network itself.
  await timeline.loadMore(count: 60);

  final cutoff = DateTime.now().subtract(const Duration(hours: 48));
  final bySender = <String, List<WeftMessage>>{};
  for (final source in timeline.sources) {
    for (final message in source.loaded) {
      if (message.timestamp.isBefore(cutoff) || message.redacted) continue;
      if (message.isOwn) continue;
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
