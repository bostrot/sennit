import 'dart:async';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_matrix/weft_matrix.dart';
import 'package:weft_notify/weft_notify.dart';
import 'package:weft_store/weft_store.dart';

import '../services/billing/entitlements.dart';
import '../services/notifications/notification_actions.dart'
    show NotificationDismisser;
import '../services/status/status_feed.dart' show isStatusBroadcastChat;
import '../services/notifications/conversation_clearer.dart';
import '../services/notifications/notification_service.dart';
import '../services/notifications/open_chats.dart';
import '../services/notifications/push_registration.dart';
import '../services/notifications/reply_suggester.dart';
import 'l10n_labels.dart';
import 'localisation.dart';
import 'person_memory_providers.dart';
import 'providers.dart';
import 'snapshot_providers.dart';
import 'session_providers.dart';
import 'billing_providers.dart';
import 'stores.dart';
import 'calendar_providers.dart';

/// The user's notification policy.
///
/// One JSON blob in [WeftSettings.notifyPolicy], read as a unit because
/// [evaluateNotification] reads it as a unit — every message consults the whole
/// policy, and a dozen separate keys would be a dozen reads per message plus a
/// dozen ways to be half-written. `NotificationPolicy.fromJson` never throws, so
/// a blob from a newer build degrades field by field rather than leaving the
/// user silently un-notified.
class NotificationPolicyNotifier extends Notifier<NotificationPolicy> {
  @override
  NotificationPolicy build() {
    try {
      return NotificationPolicy.fromJson(
        ref.read(storesProvider).settings.getJson(WeftSettings.notifyPolicy),
      );
    } on StateError {
      // Stores not bootstrapped — a widget test pumping a screen directly.
      // Defaults are "notify normally", which is the safe direction to fail in.
      return NotificationPolicy();
    }
  }

  /// Replaces the policy and persists it.
  ///
  /// Writes first and publishes second so a rebuild triggered by the new state
  /// cannot read the old blob back out of the database.
  void update(NotificationPolicy policy) {
    try {
      ref
          .read(storesProvider)
          .settings
          .setJson(WeftSettings.notifyPolicy, policy.toJson());
      ref.read(settingsRevisionProvider.notifier).bump();
    } on StateError {
      // Same as above: in-memory only.
    }
    state = policy;
  }

  /// Mutes [chatId] until [until], or indefinitely when it is null.
  void muteChat(String chatId, {DateTime? until}) =>
      update(state.muteChat(chatId, until: until));

  void unmuteChat(String chatId) => update(state.unmuteChat(chatId));

  /// Drops timed mutes whose hour is up.
  ///
  /// Nothing else removes them: a "mute for 1 hour" stops suppressing at the
  /// boundary but its entry stays in the blob forever, and the settings screen
  /// would have to filter a list that only grows. Writes only when something
  /// actually lapsed — [NotificationPolicy.pruneExpiredMutes] returns the same
  /// instance otherwise — so opening the screen is not a settings write.
  ///
  /// The clock is `package:clock`'s, not `DateTime.now()`, because the settings
  /// screen decides what to *list* from the same one. Two clocks would let a
  /// mute be pruned from the blob and still drawn on the screen that pruned it.
  void pruneLapsed({DateTime? now}) {
    final pruned = state.pruneExpiredMutes(now ?? clock.now());
    if (!identical(pruned, state)) update(pruned);
  }
}

final notificationPolicyProvider =
    NotifierProvider<NotificationPolicyNotifier, NotificationPolicy>(
      NotificationPolicyNotifier.new,
    );

/// Where notifications are posted. Overridden by a widget test with a fake.
final notificationSinkProvider = Provider<NotificationSink>(
  (ref) => LocalNotificationSink(),
);

/// Clears the shade for one chat, once the service that can do it exists.
///
/// A hole punched deliberately rather than a reach into
/// [notificationServiceProvider]: opening a conversation has to clear its
/// notifications, and a screen that awaited the service future would build the
/// whole notification stack — a live Matrix session included — just to read a
/// chat. Null until `main` fills it in, which is also what makes every widget
/// test a silent no-op instead of a session error.
class NotificationDismisserNotifier extends Notifier<NotificationDismisser?> {
  @override
  NotificationDismisser? build() => null;

  /// Called once, when the notification service comes up.
  void use(NotificationDismisser dismiss) => state = dismiss;
}

final notificationDismisserProvider =
    NotifierProvider<NotificationDismisserNotifier, NotificationDismisser?>(
      NotificationDismisserNotifier.new,
    );

/// Everything a read conversation has left outside the app, in one call.
///
/// Assembled here rather than at each call site because the three surfaces do
/// not clear the same way — the shade is cancelled, the watch and the widget are
/// *republished* — and four call sites each remembering both halves is four
/// places for one of them to be forgotten. See [ConversationClearer].
///
/// Reads rather than watches its two dependencies: the dismisser is filled in
/// once by `main` and the writer is a singleton by design, so a `watch` would
/// only make this rebuild for no gain.
final conversationClearerProvider = Provider<ConversationClearer>((ref) {
  return ConversationClearer(
    // Read at call time, like the list below. Watching it rebuilt this
    // provider when `main` filled the dismisser in, and [ReadElsewhereWatcher]
    // was left holding the disposed instance — whose every republish threw.
    dismissChat: (chatId) async =>
        ref.read(notificationDismisserProvider)?.call(chatId),
    republish: () async {
      // The list as it is *now*, deliberately re-read at call time. A snapshot
      // captured earlier is one taken before the read was recorded, and
      // republishing it would put back the unread count this was meant to
      // remove.
      final chats = ref.read(chatsProvider).value;
      if (chats == null) return;
      await ref.read(snapshotWriterProvider).refresh(chats);
    },
  );
});

/// Which conversations are on screen, for the notification path to ask.
///
/// Its own provider rather than a field on the service for the reason
/// [notificationDismisserProvider] is one: the chat screen has to report here,
/// and a screen that reached for the service would build the whole
/// notification stack to say it had opened.
final openChatsProvider = Provider<OpenChats>((ref) => OpenChats());

/// The push gateway the user configured, or null.
final pushGatewayProvider = Provider<Uri?>((ref) {
  ref.watch(settingsRevisionProvider);
  try {
    return resolvePushGateway(
      ref
          .read(storesProvider)
          .settings
          .getString(WeftSettings.notifyPushGateway),
    );
  } on StateError {
    return resolvePushGateway(null);
  }
});

/// [PushKeyStore] over the settings table.
class SettingsPushKeyStore implements PushKeyStore {
  const SettingsPushKeyStore(this._settings);

  final SettingsStore _settings;

  @override
  String? readPushKey() => _settings.getString(WeftSettings.notifyPushKey);

  @override
  void writePushKey(String? value) {
    if (value == null || value.isEmpty) {
      _settings.remove(WeftSettings.notifyPushKey);
      return;
    }
    _settings.setString(WeftSettings.notifyPushKey, value);
  }
}

/// The push transport, once Firebase has had its chance to initialise.
///
/// Null on desktop, and null in a build with no Firebase configuration — see
/// [FirebasePushTransport.initialize]. Neither is an error: both mean "this
/// device is notified from sync while Sennit is running", which is the whole of
/// what desktop Weft has ever done.
final pushTransportProvider = FutureProvider<PushTransport?>((ref) async {
  if (kDemoMode) return null;
  return FirebasePushTransport.initialize();
});

/// Everything the notification path needs, assembled.
///
/// Null in demo mode: there is no Matrix client to fetch an event through, and
/// a demo notification would be a notification about a fixture.
final notificationServiceProvider = FutureProvider<WeftNotificationService?>((
  ref,
) async {
  if (kDemoMode) return null;

  final session = ref.watch(matrixSessionProvider);
  if (!session.isInitialized) return null;

  final repository = ref.watch(chatRepositoryProvider);
  // Statuses are ambient: a story must never buzz, whatever mode the ring
  // row is in. Resolving the broadcast room to "no chat" is how the pipeline
  // drops its messages without a special case inside it.
  Chat? chatForRoom(String roomId) {
    final chat = repository.chatForRoom(roomId);
    if (chat == null || isStatusBroadcastChat(chat)) return null;
    return chat;
  }

  final matrixSession = MatrixNotificationSession.forClient(session.client);

  final pipeline = MatrixNotificationPipeline(
    words: () => weftNotifyStringsFrom(weftPlatformL10n()),
    session: matrixSession,
    // Injected, never derived: the merge fold lives in the repository and a
    // second answer here would split a merged contact into two threads.
    chatForRoom: chatForRoom,
    // A function rather than a value — a mute applied from the notification
    // shade must affect the next message, not the next launch.
    policy: () => ref.read(notificationPolicyProvider),
    // A message landing in the conversation on screen has been seen already.
    isChatOpen: ref.watch(openChatsProvider).isOpen,
  );

  final service = WeftNotificationService(
    sink: ref.watch(notificationSinkProvider),
    pipeline: pipeline,
    chatForRoom: chatForRoom,
    avatarLoader: await ref.watch(avatarFileLoaderProvider.future),
    push: await ref.watch(pushTransportProvider.future),
    // The conversation the reply chips are suggested from. The same stream the
    // pipeline decides on and the auto-reply service writes from, and it is
    // *every* message rather than the ones that buzzed: the user's own
    // replies, and the ones a mute or a read on the laptop kept out of the
    // shade, are the half of a conversation a suggestion needs most.
    conversations: matrixSession.incomingMessages,
  );

  // AI answer chips on message notifications.
  service.suggestReplies = notificationReplySuggester(
    settings: () => ref.read(storesProvider).settings,
    apiKey: () => ref.read(storesProvider).llmApiKey,
    proUnlocked: () => proUnlockedNow(ref, ProFeature.aiReplies),
    serviceChatIds: () => repository.serviceChatIds,
    // The same calendar section, under the same gate, as the auto-reply —
    // so "Friday works!" is not offered for a Friday that does not. Two
    // seconds at most: the chips are worth most while the notification is
    // still being looked at.
    calendar: (transcript) {
      const wait = Duration(seconds: 2);
      return aiCalendarContext(ref, transcript, timeout: wait);
    },
    // What the user noted about this chat and the people writing in it,
    // under the same switch as every other AI feature's.
    memory: (content, thread) {
      final chat = repository.chatForRoom(content.roomId);
      if (chat == null) return null;
      return ref.read(aiMemoryForPromptProvider)(chat, thread);
    },
  );

  ref.onDispose(() {
    unawaited(service.dispose());
    unawaited(pipeline.dispose());
  });
  return service;
});

/// Registers this device's pusher, and says why it did not when it did not.
///
/// A `FutureProvider` because the settings screen shows the outcome and because
/// re-running it is how the user retries after supplying a gateway URL —
/// `ref.invalidate` is the whole retry button.
final pushRegistrationProvider = FutureProvider<PushRegistrationOutcome>((
  ref,
) async {
  if (kDemoMode) {
    return const PushRegistrationOutcome(
      PushRegistrationStatus.unsupportedPlatform,
    );
  }

  final session = ref.watch(matrixSessionProvider);
  if (!session.isInitialized) {
    return const PushRegistrationOutcome(PushRegistrationStatus.noToken);
  }

  final registration = WeftPushRegistration(
    registry: MatrixPusherRegistry.forClient(session.client),
    keyStore: SettingsPushKeyStore(ref.watch(storesProvider).settings),
    tokens: await ref.watch(pushTransportProvider.future),
    gatewayUrl: ref.watch(pushGatewayProvider),
  );
  ref.onDispose(() => unawaited(registration.dispose()));
  return registration.ensureRegistered();
});

/// Brings the homeserver's per-room push rules in line with [policy].
///
/// The division of labour `push_rules.dart` sets out: the server's rules stop
/// the *push*, the policy stops the *display*. Only unconditional, durable
/// suppression is pushed down — which is why this writes a small list of rooms
/// rather than mirroring the whole policy.
///
/// Takes its inputs rather than a `Ref` because `Ref` and `WidgetRef` are
/// different types and this is called from a widget: a function over the three
/// values it actually reads works from either, and is testable from neither's
/// container.
///
/// Failures are per room and non-fatal, and the plan is recomputed from server
/// state every pass, so a refused write is retried next time rather than
/// remembered.
Future<List<PushRuleChange>> reconcilePushRules({
  required WeftMatrixSession session,
  required NotificationPolicy policy,
  required List<Chat> chats,
  DateTime? now,
}) async {
  if (kDemoMode || !session.isInitialized || chats.isEmpty) return const [];

  return MatrixPushRuleSync(
    MatrixPushRuleTarget.forClient(session.client),
  ).reconcile(policy: policy, chats: chats, now: now ?? DateTime.now());
}

/// Whether the OS permission prompt has already been spent.
///
/// Nullable store, because a widget test pumps screens without bootstrapping
/// one and "never asked" is the honest answer there.
bool notificationPermissionAsked(SettingsStore? settings) =>
    settings?.getBool(WeftSettings.notifyPermissionAsked) ?? false;

void markNotificationPermissionAsked(SettingsStore? settings) =>
    settings?.setBool(WeftSettings.notifyPermissionAsked, value: true);

/// Resolves an avatar URL to a file the platform can draw, cached on disk.
///
/// Shared by the two surfaces that hand a *path* to a platform rather than
/// drawing pixels themselves: a notification's `MessagingStyle` face and a
/// conversation shortcut's adaptive icon. One provider because they are one
/// cache — the same eight faces back both, the fetch is authenticated, and two
/// loaders would mean two directories, two sets of downloads and a face that
/// appears in the shade before it appears in the share sheet.
///
/// Null when there is no cache directory to write into, which is not an error:
/// both surfaces fall back to generated initials.
///
/// The directory keeps its notification-era name so an upgrade does not strand
/// every face already downloaded.
final avatarFileLoaderProvider = FutureProvider<NotificationAvatarLoader?>((
  ref,
) async {
  final Directory directory;
  try {
    directory = Directory(
      '${(await getApplicationCacheDirectory()).path}/notification-avatars',
    );
  } on Object catch (error) {
    // No cache directory means no faces, not no notifications.
    debugPrint('weft: no cache directory for avatars: $error');
    return null;
  }

  final avatars = MatrixNotificationAvatars(
    cacheDirectory: directory,
    // The same headers the inbox's avatars are fetched with. Matrix v1.11 put
    // media behind `Authorization: Bearer`, so without them every face is a 401
    // — which looks exactly like having no avatar.
    headers: ref.read(mediaHeadersProvider),
  );
  ref.onDispose(avatars.dispose);
  return avatars.load;
});
