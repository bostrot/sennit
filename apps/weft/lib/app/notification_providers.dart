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

import '../services/ai/smart_replies.dart';
import '../services/notifications/notification_service.dart';
import '../services/notifications/push_registration.dart';
import 'providers.dart';
import 'session_providers.dart';
import 'stores.dart';

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
/// device is notified from sync while Weft is running", which is the whole of
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
  final pipeline = MatrixNotificationPipeline(
    session: MatrixNotificationSession.forClient(session.client),
    // Injected, never derived: the merge fold lives in the repository and a
    // second answer here would split a merged contact into two threads.
    chatForRoom: repository.chatForRoom,
    // A function rather than a value — a mute applied from the notification
    // shade must affect the next message, not the next launch.
    policy: () => ref.read(notificationPolicyProvider),
  );

  final service = WeftNotificationService(
    sink: ref.watch(notificationSinkProvider),
    pipeline: pipeline,
    chatForRoom: repository.chatForRoom,
    avatarLoader: await ref.watch(avatarFileLoaderProvider.future),
    push: await ref.watch(pushTransportProvider.future),
  );

  // AI answer chips on message notifications. Settings are read per message
  // rather than captured, so flipping the toggle needs no restart; every
  // failure path is an empty list, because the notification must never wait
  // on an error.
  service.suggestReplies = (content, thread) async {
    final WeftStores stores;
    try {
      stores = ref.read(storesProvider);
    } on Object {
      return const [];
    }
    final settings = stores.settings;
    if (!settings.getBool(WeftSettings.notifySmartReplies)) {
      debugPrint('weft: smart replies: the setting is off');
      return const [];
    }
    final baseUrl = settings.getString(WeftSettings.llmBaseUrl) ?? '';
    final model = settings.getString(WeftSettings.llmModel) ?? '';
    if (baseUrl.trim().isEmpty || model.trim().isEmpty) {
      debugPrint('weft: smart replies: no LLM endpoint is configured');
      return const [];
    }
    return suggestSmartReplies(
      baseUrl: baseUrl,
      model: model,
      apiKey: stores.llmApiKey,
      chatTitle: content.title,
      transcript: [
        for (final message
            in thread.length <= 6 ? thread : thread.sublist(thread.length - 6))
          '${message.senderName}: ${message.body}',
      ],
    );
  };

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
