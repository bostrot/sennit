import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_domain/weft_domain.dart';

import '../services/attachments/media_store.dart';
import '../services/retention/retention_sweeper.dart';
import 'providers.dart';
import 'session_providers.dart';
import 'stores.dart';

/// Which chats erase themselves, as the settings blob currently says.
///
/// A notifier rather than a plain read so the picker, the chat's own subtitle
/// and the sweeper all move together: setting a policy has to redraw the row
/// that shows it, and the row is not the widget that set it.
class RetentionPolicies extends Notifier<RetentionSettings> {
  @override
  RetentionSettings build() =>
      storesOrNull(ref)?.retention.load() ?? RetentionSettings.empty;

  /// Sets — or, with [RetentionPolicy.off], clears — one chat's policy.
  ///
  /// The sweep that follows is deliberate and immediate. A user who has just
  /// said "delete everything older than a day" means the messages already older
  /// than a day, not the ones that become so tomorrow, and waiting for the next
  /// tick would leave them on screen for a minute after the sheet closed.
  void setFor(String chatId, RetentionPolicy policy) {
    final store = storesOrNull(ref)?.retention;
    if (store == null) return;
    final next = state.withChat(chatId, policy);
    store.save(next);
    state = next;
    if (policy.isActive) {
      final sweep = ref.read(retentionSweeperProvider)?.sweepChat(chatId);
      // Nothing here waits for it, and nothing should: the sheet stays
      // responsive while a long history drains. `unawaited` rather than a bare
      // call so a failure inside it is an error on the zone rather than an
      // uncaught one that takes the isolate with it.
      if (sweep != null) unawaited(sweep);
    }
  }
}

final retentionPoliciesProvider =
    NotifierProvider<RetentionPolicies, RetentionSettings>(
      RetentionPolicies.new,
    );

/// The sweeper, or null before the database is open.
///
/// Null rather than a dormant instance because everything it needs — the
/// store to read policies from, the index to delete rows out of — arrives with
/// the database, and a sweeper built without them could only pretend.
final retentionSweeperProvider = Provider<RetentionSweeper?>((ref) {
  final stores = storesOrNull(ref);
  if (stores == null) return null;

  final session = kNoMatrix ? null : ref.watch(matrixSessionProvider);

  final sweeper = RetentionSweeper(
    retention: stores.retention,
    search: stores.search,
    repository: ref.watch(chatRepositoryProvider),
    // Whose messages may be redacted rather than only dropped from this
    // device. Null in demo mode and before the session has restored — and null
    // is the safe answer for both: a sweep that cannot tell whose message it is
    // looking at forgets it locally rather than redacting somebody else's.
    ownUserId: session == null || !session.isInitialized
        ? null
        : session.client.userID,
    purgeMedia: ref.watch(mediaFileStoreProvider).purge,
  );
  ref.onDispose(sweeper.dispose);
  return sweeper;
});
