import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_matrix/weft_matrix.dart';
import 'package:weft_share/weft_share.dart';
import 'package:weft_store/weft_store.dart' show WeftSettings;

import 'app/auto_reply_providers.dart';
import 'app/billing_providers.dart';
import 'app/intents.dart';
import 'app/design_strings.dart';
import 'app/l10n_labels.dart';
import 'app/localisation.dart';
import 'app/menus.dart';
import 'app/notification_providers.dart';
import 'app/person_memory_providers.dart'
    show memoryHousekeeperProvider, memoryLearnerProvider;
import 'app/providers.dart';
import 'app/reply_reminder_providers.dart';
import 'app/retention_providers.dart';
import 'app/search_providers.dart';
import 'app/session_providers.dart';
import 'app/share_providers.dart';
import 'app/shortcuts.dart';
import 'app/snapshot_providers.dart';
import 'app/stores.dart';
import 'app/sync_providers.dart';
import 'app/text_size.dart';
import 'app/todo_providers.dart';
import 'app/usage_stats_providers.dart';
import 'app/settings.dart';
import 'features/auth/auth_gate.dart';
import 'features/auth/verification_screen.dart';
import 'features/call/call_overlay.dart';
import 'data/chat_repository.dart';
import 'features/chat/chat_view.dart';
import 'features/chat/room_link.dart';
import 'features/lock/lock_screen.dart';
import 'features/notifications/notification_rationale_sheet.dart';
import 'features/notifications/push_explanation_screen.dart';
import 'features/settings/notifications_screen.dart';
import 'features/settings/usage_stats_consent.dart';
import 'features/search/search_screen.dart';
import 'features/share/share_target_sheet.dart';
import 'services/analytics/usage_stats.dart';
import 'services/attachments/local_media_storage.dart';
import 'services/notifications/background_actions.dart';
import 'services/notifications/background_push.dart';
import 'services/notifications/conversation_clearer.dart';
import 'services/notifications/notification_actions.dart';
import 'services/notifications/push_registration.dart';
import 'services/notifications/unified_push.dart';
import 'services/review/review_prompt.dart' show reviewSessionHadError;
import 'services/schedule/scheduled_actions.dart';
import 'services/siri/siri_messaging.dart';

/// Marks the session as one that went wrong at the first framework or
/// uncaught error, so it never ends in a rating prompt; whatever handled
/// errors before still does.
void _noteErrorsForReview() {
  final flutterHandler = FlutterError.onError;
  FlutterError.onError = (details) {
    reviewSessionHadError = true;
    flutterHandler?.call(details);
  };
  final platformHandler = PlatformDispatcher.instance.onError;
  PlatformDispatcher.instance.onError = (error, stack) {
    reviewSessionHadError = true;
    return platformHandler?.call(error, stack) ?? false;
  };
}

void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // A push woke the process with no user in sight: boot the headless push
  // stack and never build a widget. See `background_push.dart` — this is how
  // notifications work while the app is closed without the app *running*.
  if (args.contains('--unifiedpush-bg')) {
    await runBackgroundPush();
    return;
  }
  // The built-in connection's engine: WeftSyncService starts this whenever
  // the toggle is on and no UI is alive. Same headless stack, kept running.
  if (args.contains('--weft-daemon')) {
    await runSyncDaemon();
    return;
  }
  // Loads `intl`'s date symbols for every locale before anything can format a
  // timestamp. Awaited rather than fired off: a `DateFormat` built for a locale
  // whose data has not arrived throws, and the first frame of the inbox formats
  // one per row. It is embedded data rather than I/O, so this costs a
  // microtask, not a round trip.
  await initializeDateFormatting();
  _noteErrorsForReview();
  runApp(const ProviderScope(child: WeftApp()));
}

/// Weft — every conversation, one thread.
class WeftApp extends ConsumerStatefulWidget {
  const WeftApp({super.key});

  @override
  ConsumerState<WeftApp> createState() => _WeftAppState();
}

class _WeftAppState extends ConsumerState<WeftApp> with WidgetsBindingObserver {
  final _navigatorKey = GlobalKey<NavigatorState>();

  /// Counts screens for usage statistics. Each one checks the setting, so
  /// nothing is sent unless the user opted in.
  late final _usageStatsObserver = UsageStatsObserver(
    () => ref.read(usageStatsProvider),
  );
  late final WeftIntents _intents;

  @override
  void initState() {
    super.initState();
    // Read from the provider rather than constructed here: the share sheet
    // stages its files through the same instance, and a second one would take
    // the channel's handler away from this one.
    _intents = ref.read(weftIntentsProvider)
      ..onLink = _handleLink
      ..onShare = _handleShare;
    // The iOS Share Extension's shares arrive through a container rather than an
    // intent, but they arrive at the same place: a share captured while Weft was
    // closed is the same sheet, the same resolver and the same send as one
    // shared into it while it was open.
    ref.read(stagedShareReaderProvider).onShare = _handleShare;
    // Resume is the one refresh the chat stream cannot provide. A phone that
    // sat in a pocket overnight comes back with a ranking whose recency terms
    // have all decayed, and nothing has to have arrived for the order to be
    // stale — the share sheet is often the *first* thing touched after a
    // resume, from the gallery.
    WidgetsBinding.instance.addObserver(this);
    // After the first frame: a cold-start share must find a navigator to
    // present into, and the initial intent is replayed by the platform side.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _intents.deliverInitialIntent();
    });
    // UnifiedPush handlers must exist before its distributor delivers —
    // including a delivery that cold-started this process. No-op off Android.
    unawaited(ref.read(unifiedPushServiceProvider).initialize());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _inboxSurfaces?.close();
    _embeddingBackfill?.close();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    _refreshInboxSurfaces();
    // The resume that matters most: the Share Extension runs while Weft is
    // backgrounded, so the share is already staged by the time the user comes
    // back to it — often by tapping Weft immediately afterwards.
    unawaited(_drainStagedShares());
  }

  /// The inbox subscription that keeps every out-of-app surface current.
  ///
  /// One subscription for both of them — the launcher's share targets and the
  /// companion-surface snapshot — because they are the same signal read two
  /// ways, and a second `listenManual` on [chatsProvider] would be a second
  /// listener on one stream with no second question to ask it.
  ///
  /// Held rather than declared with `ref.listen` in [build] for one reason:
  /// `ref.listen` subscribes on the first frame, and subscribing to
  /// [chatsProvider] builds the repository — which reads the stores and the
  /// session. Neither exists before the auth gate has passed, so the
  /// subscription starts when the session becomes ready and is closed when it
  /// stops being.
  ProviderSubscription<AsyncValue<List<Chat>>>? _inboxSurfaces;

  /// Keeps the search backfill running for as long as there is a session.
  ProviderSubscription<EmbeddingBackfill?>? _embeddingBackfill;

  /// Keeps device sync running — and rebuilt when it is switched on or off —
  /// for as long as a session is ready. Held for the same reason as
  /// [_embeddingBackfill].
  ProviderSubscription<DeviceSyncRunner?>? _deviceSync;

  /// Clears a conversation the user read somewhere else.
  ///
  /// Held here rather than in a provider because it is *stateful in the way
  /// that matters*: what it remembers is which chats were unread on the last
  /// tick, and a rebuilt instance would have an empty set and clear nothing on
  /// the tick after — which is exactly the tick a laptop's receipt lands on.
  late final ReadElsewhereWatcher _readElsewhere = ReadElsewhereWatcher(
    ref.read(conversationClearerProvider),
  );

  /// Follows the inbox for as long as there is one.
  ///
  /// Every tick, and deliberately: [ShareShortcutService] and [SnapshotWriter]
  /// each decide whether a tick is worth a platform call, and both say no to
  /// nearly all of them. Idempotent, because the session state stream re-emits
  /// `ready` on every reconnection.
  ///
  /// The gate is pushed at the writer before the first list arrives, because
  /// `ref.listen` below only fires on *changes*: without this, a launch into an
  /// app where widgets are already switched on would write the switched-off
  /// payload until the user next touched the setting.
  ///
  /// [WatchReplyHandler.start] is called here rather than lazily on the first
  /// reply, and that ordering is load-bearing in the one case that matters: a
  /// watch reply can be what *starts* this process, and a handler installed
  /// after the platform had already tried to deliver would lose it. Starting at
  /// session-ready means the queue exists before the inbox does, which is
  /// exactly the state it was built to sit in.
  void _startInboxSurfaces() {
    unawaited(
      ref
          .read(snapshotWriterProvider)
          .applySettings(ref.read(snapshotSettingsProvider)),
    );
    ref.read(watchReplyHandlerProvider).start();
    _inboxSurfaces ??= ref.listenManual(chatsProvider, (_, next) {
      final chats = next.value;
      if (chats == null) return;
      unawaited(ref.read(shareShortcutServiceProvider).refresh(chats));
      unawaited(ref.read(snapshotWriterProvider).refresh(chats));
      // The same list, read a third way: the writer decides what a watch may
      // see, and this decides whether a reply from one names a conversation
      // that still exists. Cheap on every tick — with an empty queue it assigns
      // a field and returns.
      unawaited(ref.read(watchReplyHandlerProvider).refresh(chats));
      // And a fourth: a chat that has stopped being unread with nothing on
      // *this* device having read it was read on another one. The clearing
      // push covers a phone that is asleep; this covers one that is awake and
      // holding a socket open, which the gateway may skip entirely.
      unawaited(_readElsewhere.onChats(chats));
      // And a fifth: a chat read and not answered is queued a reply reminder,
      // and one answered has its reminders taken back. A no-op until the user
      // switches reminders on.
      unawaited(ref.read(replyReminderServiceProvider).onChats(chats));
      // A launch drain almost always arrives before the first chat list does,
      // and a share sheet with no conversations in it is not worth spending a
      // staged share on. This is where the inbox finally exists.
      if (_drainPending) unawaited(_drainStagedShares());
      // And the same moment for a share that arrived through an intent rather
      // than through the container. Replayed from inside this subscription
      // rather than from a `ref.listen` in `build`, which would subscribe to
      // `chatsProvider` on the first frame and so build the repository — and
      // with it the session — above the auth gate, before either exists.
      final pending = _pendingShare;
      if (pending != null) {
        _pendingShare = null;
        _handleShare(pending);
      }
      // A "send a message to …" that cold-started the app, for the same reason:
      // the name can only be resolved against an inbox that exists.
      final compose = _pendingCompose;
      if (compose != null) {
        _pendingCompose = null;
        _handleLink(compose);
      }
    }, fireImmediately: true);
    unawaited(_drainStagedShares());
  }

  /// Stops following the inbox and takes back everything left outside the app.
  ///
  /// The subscription is closed *first*: a chat list emitted between the
  /// removal and the unsubscribe would republish everything that was just
  /// removed, which is the one ordering that leaks.
  ///
  /// The snapshot is *deleted* rather than rewritten empty. A blank payload
  /// says "switched off in Settings" and would leave a widget pointing at a
  /// setting; an absent one says "nobody is signed in", which is what has
  /// actually happened and what the surfaces render a sign-in prompt for.
  ///
  /// A reply still queued at this point is *failed back* rather than kept. It
  /// was dictated against a session that has gone away, the watch is still
  /// showing it as sending, and the next session is a different account — so
  /// there is no later moment at which sending it would be right.
  void _stopInboxSurfaces() {
    _inboxSurfaces?.close();
    _inboxSurfaces = null;
    unawaited(ref.read(shareShortcutServiceProvider).clear());
    unawaited(ref.read(snapshotWriterProvider).clear());
    unawaited(ref.read(watchReplyHandlerProvider).clear());
    unawaited(ref.read(replyReminderServiceProvider).clear());
  }

  /// Re-ranks the share targets and rewrites the snapshot.
  ///
  /// Cheap to call on any signal: both services compare what they would publish
  /// against what they last published and do nothing at all when they match,
  /// which is the common case.
  void _refreshInboxSurfaces() {
    if (_inboxSurfaces == null) return;
    final chats = ref.read(chatsProvider).value;
    if (chats == null) return;
    unawaited(ref.read(shareShortcutServiceProvider).refresh(chats));
    unawaited(ref.read(snapshotWriterProvider).refresh(chats));
    unawaited(ref.read(watchReplyHandlerProvider).refresh(chats));
  }

  /// A drain was asked for before there was anywhere to put its result.
  ///
  /// The two gates below are not the same gate. `_inboxSurfaces` says the session
  /// is ready; `chatsProvider.value` says the inbox has actually arrived, which
  /// is a frame or several later and is what [_handleShare] requires. A drain in
  /// between would delete the blob and hand the payload to a sheet that refuses
  /// to open — the share would be gone, silently.
  bool _drainPending = false;

  /// Reads whatever the iOS Share Extension staged while Sennit was not running.
  ///
  /// Cheap on every other platform and on an empty container alike: one channel
  /// call that answers with an empty list, or a [MissingPluginException] that
  /// [WeftStagedShares] reads as the same thing. Never throws.
  Future<void> _drainStagedShares() async {
    if (_inboxSurfaces == null || ref.read(chatsProvider).value == null) {
      _drainPending = true;
      return;
    }
    _drainPending = false;
    await ref.read(stagedShareReaderProvider).drain();
  }

  /// Whether the notification service has been started for this session.
  ///
  /// Guarded rather than keyed off the provider alone because the session state
  /// stream re-emits `ready` on reconnections, and starting twice would install
  /// a second subscription on the pipeline — two notifications per message.
  bool _notificationsStarted = false;

  /// Starts notifications once, after sign-in.
  ///
  /// After sign-in and not at launch, because everything below it needs a
  /// client: the pipeline fetches and decrypts events through the session, and
  /// the pusher is registered against the account. A logged-out Sennit has
  /// nothing to be notified about.
  Future<void> _startNotifications() async {
    if (_notificationsStarted) return;
    _notificationsStarted = true;

    _listenForVerificationRequests();

    final service = await ref.read(notificationServiceProvider.future);
    if (service == null || !mounted) {
      // No notification questions to wait for on this platform.
      unawaited(_askUsageStatsOnce());
      return;
    }

    // One router. A notification tap produces the same `weft://chat/<id>` a
    // shared link does, goes through the same `WeftLink.parse`, and lands in
    // the same `_handleLink` — so tapping a merged contact's notification opens
    // the merged conversation rather than one source room.
    service.onOpenLink = (url) {
      final link = WeftLink.parse(url);
      if (link != null) _handleLink(link);
    };

    // Reply, mark read and mute for an hour. Built here rather than in a
    // provider because it needs `service.dismissChat`, and a provider that
    // reached back into the one being built would be a cycle. It holds no
    // state, so constructing it alongside the service costs nothing.
    final actions = NotificationActionHandler(
      repository: ref.read(chatRepositoryProvider),
      muteChat: ref.read(notificationPolicyProvider.notifier).muteChat,
      dismiss: service.dismissChat,
      stopReplyReminder: ref.read(replyReminderServiceProvider).dismiss,
      remindLater: (chatId, {required roomId, required at}) {
        final chats = ref.read(chatsProvider).value ?? const <Chat>[];
        final chat =
            chats.where((c) => c.id == chatId).firstOrNull ??
            ref.read(chatRepositoryProvider).chatForRoom(roomId);
        return ref
            .read(reminderListProvider.notifier)
            .add(
              chatReminder(
                chatId: chatId,
                chatTitle: chat?.title ?? '',
                at: at,
              ),
            );
      },
    );
    service.onAction = (activation) => unawaited(actions.handle(activation));
    // Reply and mark read from the car, a watch or the lock screen arrive in
    // the plugin's own isolate. While this one is alive they are done here,
    // on this client, rather than on a second one opened beside it.
    NotificationActionServer.serve(actions.handle);
    // And pokes from Sennit's gateway that FCM delivers to its own isolate
    // while this one is in the background.
    servePushes(service.handlePush);
    // Siri and CarPlay: "Read my messages", dictated replies, "mark as read".
    // iOS delivers these intents only once the user has allowed Siri for
    // Sennit, which is asked for below, after the notification prompt.
    final siri = NotificationPlatform.isIOS
        ? SiriMessaging(
            repository: ref.read(chatRepositoryProvider),
            chats: () => ref.read(chatsProvider).value ?? const [],
            policy: () => ref.read(notificationPolicyProvider),
            words: () => weftNotifyStringsFrom(weftPlatformL10n()),
          )
        : null;
    if (siri != null) unawaited(siri.start());
    // Opening a conversation has to clear its row in the shade, and the screen
    // that shows the messages cannot reach the service without building the
    // whole notification stack. Handing it the one function it needs keeps
    // that dependency one-way.
    ref.read(notificationDismisserProvider.notifier).use(service.dismissChat);

    await service.start();

    // Started alongside notifications rather than in a step of its own,
    // because they subscribe to the same stream for the same reason: a message
    // has arrived and something has to decide about it. The guard above covers
    // both — a second subscription would answer every message twice, which for
    // this one means sending two messages.
    ref.read(autoReplyServiceProvider)?.start();
    // Same stream, same reason; it reads nothing until the user switches the
    // assistant on in the to-do list's settings.
    ref.read(todoAgentProvider)?.start();

    // Not over the steps after sign-in: a rationale sheet that slid up over
    // the verification screen made it look skipped. The steps include the
    // notification question on a first start, which settles this one.
    await untilSignInStepsDone(ref);
    if (!mounted) return;
    await _ensureNotificationPermission();
    // Siri's own prompt, once: after sign-in and after the notification
    // question has been settled, so the two system sheets never stack and
    // a first launch is never met with a request about cars.
    if (siri != null) unawaited(siri.requestAuthorizationIfUndecided());
    // Registration and rule reconciliation both need permission to have been
    // settled first: on iOS the APNs token does not exist until the user has
    // said yes, so registering before the prompt reliably yields `noToken`.
    await _explainPushOnce();
    // Last of the first-start questions, and the least important.
    unawaited(_askUsageStatsOnce());
    await ref.read(pushRegistrationProvider.future);
    await reconcilePushRules(
      session: ref.read(matrixSessionProvider),
      policy: ref.read(notificationPolicyProvider),
      chats: ref.read(chatsProvider).value ?? const [],
    );
  }

  /// Whether a verification screen for an incoming request is already up,
  /// so a re-sent request does not stack a second one.
  bool _verificationShowing = false;

  /// Answers "verify this session?" started from the user's *other* device.
  ///
  /// Element on the laptop (or any client) sends a to-device verification
  /// request; without this listener it expired silently and Sennit looked
  /// unable to verify. The push lands in the same screen the devices list
  /// and the login flow use — one verification path, three doors.
  void _listenForVerificationRequests() {
    final session = ref.read(matrixSessionProvider);
    if (!session.isInitialized) return;
    session.client.onKeyVerificationRequest.stream.listen((request) {
      if (!mounted || _verificationShowing) return;
      final navigator = _navigatorKey.currentState;
      if (navigator == null) return;
      _verificationShowing = true;
      unawaited(
        navigator
            .push(
              MaterialPageRoute<void>(
                builder: (context) => VerificationScreen(
                  incoming: request,
                  onContinue: () => Navigator.of(context).pop(),
                ),
              ),
            )
            .whenComplete(() => _verificationShowing = false),
      );
    });
  }

  /// Shows the rationale sheet, then spends the one OS prompt.
  ///
  /// Only once ever: [WeftSettings.notifyPermissionAsked] records that the
  /// prompt has been spent, because a second `requestPermission` returns the
  /// first answer without showing anything, and a sheet that leads to no dialog
  /// is a sheet that lies.
  Future<void> _ensureNotificationPermission() async {
    if (!NotificationPlatform.needsPermissionPrompt) return;
    final settings = ref.read(storesProvider).settings;
    if (notificationPermissionAsked(settings)) return;

    final context = _navigatorKey.currentContext;
    if (context == null || !context.mounted) return;

    final wanted = await showNotificationRationale(context);
    if (!wanted || !mounted) return;

    markNotificationPermissionAsked(settings);
    final service = await ref.read(notificationServiceProvider.future);
    await service?.requestPermission();
  }

  /// Asks about anonymous usage statistics, once, once the steps after
  /// sign-in are done — never during sign-in itself. Not in the demo build.
  Future<void> _askUsageStatsOnce() async {
    if (kDemoMode) return;
    await untilSignInStepsDone(ref);
    final context = _navigatorKey.currentContext;
    if (!mounted || context == null || !context.mounted) return;
    await askUsageStatsOnce(
      context,
      ref.read(storesProvider).settings,
      onChanged: ref.read(settingsRevisionProvider.notifier).bump,
    );
  }

  /// Explains Sennit's push gateway, once, before a store build registers
  /// with it; nothing reaches the gateway until the user has answered.
  Future<void> _explainPushOnce() async {
    if (!NotificationPlatform.supportsPush) return;
    if (ref.read(pushModeProvider) != null) return;
    if (await ref.read(pushTransportProvider.future) == null) return;

    final context = _navigatorKey.currentContext;
    if (context == null || !context.mounted) return;
    final useSennit = await showPushExplanation(context);
    if (useSennit == null || !mounted) return;

    final mode = useSennit ? PushGatewayMode.sennit : PushGatewayMode.off;
    final settings = ref.read(storesProvider).settings;
    settings.setString(WeftSettings.notifyPushMode, mode.name);
    ref.read(settingsRevisionProvider.notifier).bump();
    // "Another way" lands where the other ways are.
    final navigator = _navigatorKey.currentState;
    if (!useSennit && navigator != null) {
      final route = MaterialPageRoute<void>(
        builder: (_) => const NotificationsScreen(),
      );
      unawaited(navigator.push(route));
    }
  }

  void _handleLink(WeftLink link) {
    final navigator = _navigatorKey.currentState;
    if (navigator == null) return;

    switch (link) {
      case OpenChatLink(:final chatId):
        _openChat(navigator, chatId);
      case OpenSearchLink(:final query):
        navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => SearchScreen(initialQuery: query),
          ),
        );
      case OpenRoomLink():
        _openRoom(navigator, link);
      case OpenUserLink(:final userId):
        // DM creation from a user link needs the start-chat flow; until then
        // the inbox is the honest landing place.
        debugPrint('weft: user link for $userId — start-chat flow pending');
      case ComposeSmsLink(:final addresses):
        // The filter is declared — it is one of the conditions for the
        // default-SMS role — and the intent is parsed and routed here, but the
        // SMS composer it should open belongs to the repository task that
        // follows. Landing on the inbox is the honest placeholder: the same
        // choice `OpenUserLink` above makes, for the same reason.
        debugPrint('weft: sms compose for $addresses — SMS composer pending');
        navigator.popUntil((route) => route.isFirst);
      case ComposeMessageLink():
        _compose(navigator, link);
      case OpenInboxLink():
        navigator.popUntil((route) => route.isFirst);
    }
  }

  /// A matrix.to or `matrix:` room link from outside the app: opens the
  /// room, or asks before joining one the user is not in.
  void _openRoom(NavigatorState navigator, OpenRoomLink link) {
    final ChatRepository repository;
    try {
      repository = ref.read(chatRepositoryProvider);
    } on Object {
      // Signed out, or no client yet: nothing to open or join with.
      return;
    }
    unawaited(
      openRoomLink(
        navigator.context,
        repository: repository,
        link: link,
        open: (chatId) => _openChat(navigator, chatId),
      ),
    );
  }

  /// A voice assistant's "send a message to … on Sennit", held until the
  /// inbox exists — see [_compose].
  ComposeMessageLink? _pendingCompose;

  /// Opens the conversation an assistant named, with its words in the
  /// composer and nothing sent.
  ///
  /// The name is what the recogniser heard, so it goes through
  /// `resolveMessageRecipient` — the matching Siri uses — and a conversation is
  /// opened only when the name means exactly one. Otherwise the user picks: the
  /// search opens on the name, and the dictated words go to the clipboard so
  /// choosing the chat does not cost them the message.
  void _compose(NavigatorState navigator, ComposeMessageLink link) {
    final chats = ref.read(chatsProvider).value;
    if (chats == null) {
      _pendingCompose = link;
      return;
    }

    switch (resolveMessageRecipient(chats, link.recipient)) {
      case RecipientResolved(:final chat):
        ref.read(composerPrefillProvider).offer(chat.id, link.text);
        _openChat(navigator, chat.id);
      case RecipientAmbiguous() || RecipientNotFound():
        navigator.popUntil((route) => route.isFirst);
        if (link.recipient.isNotEmpty) {
          unawaited(
            navigator.push(
              MaterialPageRoute<void>(
                builder: (_) => SearchScreen(initialQuery: link.recipient),
              ),
            ),
          );
        }
        if (link.text.isNotEmpty) {
          unawaited(Clipboard.setData(ClipboardData(text: link.text)));
        }
        final l10n = navigator.context.l10n;
        final message = switch ((link.recipient.isEmpty, link.text.isEmpty)) {
          (true, _) => l10n.composeRecipientMissing,
          (false, true) => l10n.composeRecipientUnclear(link.recipient),
          (false, false) => l10n.composeRecipientUnclearCopied(link.recipient),
        };
        ScaffoldMessenger.maybeOf(
          navigator.context,
        )?.showSnackBar(SnackBar(content: Text(message)));
    }
  }

  /// Goes to a conversation a notification or a link named.
  ///
  /// *Goes to*, not *adds*. This used to push a new screen on every tap, on
  /// top of whatever was there: a notification for the chat already open put
  /// a second copy over the first, three notifications in an afternoon left
  /// three conversations stacked, and Back had to be pressed once for each
  /// before the inbox came back. Now the conversation is what Back leaves to
  /// the inbox from, however it was reached — and where there is a detail
  /// pane, it opens *in* the pane instead of over the whole window.
  void _openChat(NavigatorState navigator, String chatId) {
    // The inbox may know this room by another name: a merged contact's rooms
    // answer to `merged:<contact>`, and the screen on top was opened as that.
    var id = chatId;
    try {
      id = ref.read(chatRepositoryProvider).chatForRoom(chatId)?.id ?? chatId;
    } on Object {
      // No repository yet — a cold start. The conversation screen waits for
      // the inbox on its own and re-resolves the id when it arrives.
    }

    final twoPane =
        weftSurface == WeftSurface.mac ||
        MediaQuery.sizeOf(navigator.context).width >= kTwoPaneBreakpoint;
    if (twoPane) {
      navigator.popUntil((route) => route.isFirst);
      ref.read(selectedChatProvider.notifier).select(id);
      return;
    }

    final top = topRouteName(navigator);
    if (top == chatRouteName(id) || top == chatRouteName(chatId)) return;
    navigator.popUntil((route) => route.isFirst);
    unawaited(navigator.push(chatRoute(id)));
  }

  /// A share that arrived before the app was ready for it.
  ///
  /// The cold-start case: sharing a photo into a closed Sennit delivers the
  /// intent while the session is still initialising, and the guard below
  /// used to *drop* it — the app opened onto a plain inbox and the user had
  /// to pick their files all over again inside it. Held here instead, and
  /// replayed the moment the chat list exists.
  SharedPayload? _pendingShare;

  void _handleShare(SharedPayload payload) {
    final context = _navigatorKey.currentContext;
    // The sheet needs the repository, which exists only past the auth gate —
    // and on a cold start that is seconds away, not never. Hold the share.
    if (context == null || ref.read(chatsProvider).value == null) {
      _pendingShare = payload;
      return;
    }
    showShareTargetSheet(context, payload);
  }

  @override
  Widget build(BuildContext context) {
    final appearance = ref.watch(appearanceProvider);
    final platformBrightness = MediaQuery.platformBrightnessOf(context);
    // Read once, here, and folded into the theme: every widget below then gets
    // the answer from `context.palette` / `context.motion` rather than each
    // checking `MediaQuery` for itself and half of them forgetting to.
    final highContrast = MediaQuery.highContrastOf(context);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    // Listened to rather than watched: this starts a service, it does not
    // decide what to draw, and a rebuild must not restart it.
    ref.listen(sessionStateProvider, (_, next) {
      switch (next.value) {
        case WeftSessionState.ready:
          unawaited(_startNotifications());
          _startInboxSurfaces();
          // Its own line rather than a step inside `_startNotifications`,
          // which returns early on every platform and mode where there is no
          // notification service to start — and a conversation set to erase
          // itself must not quietly stop doing so because this device does not
          // do notifications.
          ref.read(retentionSweeperProvider)?.start();
          // Downloads past the size limit go, oldest first, once per session.
          unawaited(trimLocalMedia(ref));
          // Counts what arrives from the start of the session, and learns
          // only while personal memory and automatic learning are on.
          ref.read(memoryLearnerProvider)?.start();
          // One memory per direct chat, and temporary facts gone when their
          // day has passed — on the device, whatever learning is set to.
          ref.read(memoryHousekeeperProvider)?.start();
          // Held, not read once: a listener is what makes the backfill rebuild
          // — and so start — the moment a model or an endpoint is switched on,
          // rather than the next time something happens to ask for it.
          _embeddingBackfill ??= ref.listenManual(
            embeddingBackfillProvider,
            (_, _) {},
          );
          if (!kDemoMode) {
            _deviceSync ??= ref.listenManual(
              deviceSyncRunnerProvider,
              (_, _) {},
            );
          }
          // Every launch, so a purchase that finished while the app was
          // closed is acknowledged and a live subscription re-confirmed.
          unawaited(ref.read(proControllerProvider.notifier).start());
        // Both signed-out states take the out-of-app copies away. `softLoggedOut`
        // is the server having invalidated the token, and until the user
        // re-auths this device is exactly as signed out as the other one —
        // while the shortcuts it published and the snapshot it wrote are both
        // long-lived, sitting in every app's share sheet and on a home screen
        // with contact names on them. They come back on the next publish, which
        // costs a re-auth nothing.
        case WeftSessionState.loggedOut || WeftSessionState.softLoggedOut:
          _stopInboxSurfaces();
          _embeddingBackfill?.close();
          _embeddingBackfill = null;
          _deviceSync?.close();
          _deviceSync = null;
        case _:
          break;
      }
    });

    // The gate, pushed at the container the moment it changes rather than on
    // the next inbox tick. The settings screen already tells the writer
    // directly — this covers the other ways a gate can move, and is what makes
    // "the switch and the file agree" a property of the app rather than of one
    // screen remembering to call something.
    ref.listen(snapshotSettingsProvider, (_, next) {
      unawaited(ref.read(snapshotWriterProvider).applySettings(next));
    });

    return MaterialApp(
      // l10n-ignore: the app's own name, never translated.
      title: 'Sennit',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigatorKey,
      navigatorObservers: [_usageStatsObserver],
      // The whole of Weft's right-to-left support hangs off these two lines:
      // `Directionality` has no other source, and until they were here every
      // directional layout API downstream was decoration. English first is the
      // fallback — Sennit's own strings are untranslated, so a device set to a
      // locale Weft does not declare gets English text in a left-to-right
      // layout rather than English text mirrored.
      localizationsDelegates: weftLocalizationsDelegates,
      supportedLocales: weftSupportedLocales,
      theme: appearance.themeFor(
        platformBrightness,
        highContrast: highContrast,
        reduceMotion: reduceMotion,
        surface: weftSurface,
        // The two are not the same question, and Windows and Linux are where
        // they part: the touch layout, driven with a mouse.
        pointer: weftHasPointer,
      ),
      // Both above the navigator, and for the same reason: a ringing call
      // appears over whatever route is open — a chat, the settings, a share
      // sheet — and the minimised call bar survives navigating away from the
      // call screen, while Cmd+F has to reach search from a settings screen as
      // much as from the inbox. Both take the navigator key rather than a
      // context because everything above the navigator is outside it.
      builder: (context, child) {
        // The first place under `Localizations`, and therefore the first place
        // that knows which locale actually resolved. Every `DateFormat` in the
        // app is built without one and reads `Intl.defaultLocale`, so this is
        // what makes a timestamp in an Arabic UI Arabic. Idempotent — it
        // compares before it assigns — which is what makes it safe in a build.
        applyFormattingLocale(Localizations.localeOf(context));
        // And the first place `weft_design` can be handed the app's words:
        // a `ChatTile` draws a preview line and an unread count, and the
        // package has no ARB files of its own to get them from.
        //
        // Text size is the system's times Sennit's own, applied here — under
        // `MediaQuery.fromView`, which would rebuild its data from the view
        // and drop a scaler set above it — so every route, sheet and dialog
        // gets it without asking.
        return AppTextScale(
          child: WeftDesignStringsScope(
            strings: weftDesignStringsFrom(context.l10n),
            // Outermost, so nothing below it shows or takes a key while locked.
            child: AppLockGate(
              child: WeftMenuBar(
                navigatorKey: _navigatorKey,
                child: WeftShortcuts(
                  navigatorKey: _navigatorKey,
                  child: CallOverlay(
                    navigatorKey: _navigatorKey,
                    child: child ?? const SizedBox.shrink(),
                  ),
                ),
              ),
            ),
          ),
        );
      },
      home: const AuthGate(),
    );
  }
}
