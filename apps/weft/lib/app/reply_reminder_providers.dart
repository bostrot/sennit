import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_notify/weft_notify.dart';
import 'package:weft_store/weft_store.dart';

import '../services/notifications/reply_reminders.dart';
import '../services/status/status_feed.dart' show isStatusBroadcastChat;
import 'localisation.dart';
import 'notification_providers.dart';
import 'providers.dart';
import 'stores.dart';

/// What the user chose about reply reminders, read from and written to
/// [WeftSettings.notifyReplyReminders].
///
/// Free in every edition: reminding someone to answer a message involves no
/// model and no integration, which is what ADR-004 sells.
class ReplyReminderSettingsNotifier extends Notifier<ReplyReminderSettings> {
  @override
  ReplyReminderSettings build() => ReplyReminderSettings.fromJson(
    storesOrNull(ref)?.settings.getJson(WeftSettings.notifyReplyReminders),
  );

  /// Replaces the settings, persists them, and replans at once — switching
  /// reminders off has to cancel the queued ones now, not at the next sync.
  void update(ReplyReminderSettings settings) {
    storesOrNull(
      ref,
    )?.settings.setJson(WeftSettings.notifyReplyReminders, settings.toJson());
    state = settings;
    unawaited(ref.read(replyReminderServiceProvider).replan());
  }

  /// Applies [change] to the settings as they are *now*, so two edits made
  /// before the screen rebuilds do not overwrite each other.
  void edit(ReplyReminderSettings Function(ReplyReminderSettings) change) =>
      update(change(state));

  void setChatExcluded(String chatId, {required bool excluded}) =>
      edit((s) => s.withChatExcluded(chatId, excluded: excluded));
}

final replyReminderSettingsProvider =
    NotifierProvider<ReplyReminderSettingsNotifier, ReplyReminderSettings>(
      ReplyReminderSettingsNotifier.new,
    );

/// Where reminders are queued. Overridden by a test with a fake.
final replyReminderPosterProvider = Provider<ReplyReminderPoster>(
  (ref) => LocalReplyReminderPoster(),
);

/// Keeps the queued reminders in line with the inbox. `main` feeds it every
/// chat list; the settings above poke it when they change.
final replyReminderServiceProvider = Provider<ReplyReminderService>((ref) {
  return ReplyReminderService(
    poster: ref.watch(replyReminderPosterProvider),
    store: storesOrNull(ref)?.settings,
    settings: () => ref.read(replyReminderSettingsProvider),
    policy: () => ref.read(notificationPolicyProvider),
    words: () {
      final l10n = weftPlatformL10n();
      return (
        title: l10n.replyReminderTitle,
        hiddenTitle: l10n.replyReminderTitleHidden,
        body: l10n.replyReminderBody,
      );
    },
    isServiceChat: (chat) {
      if (isStatusBroadcastChat(chat)) return true;
      try {
        return ref
            .read(chatRepositoryProvider)
            .serviceChatIds
            .contains(chat.id);
      } on Object {
        return false;
      }
    },
  );
});
