import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_matrix/weft_matrix.dart';

import 'app/intents.dart';
import 'app/notification_providers.dart';
import 'app/providers.dart';
import 'app/session_providers.dart';
import 'app/share_providers.dart';
import 'app/stores.dart';
import 'app/settings.dart';
import 'features/auth/auth_gate.dart';
import 'features/call/call_overlay.dart';
import 'features/chat/chat_view.dart';
import 'features/notifications/notification_rationale_sheet.dart';
import 'features/search/search_screen.dart';
import 'features/share/share_target_sheet.dart';
import 'services/notifications/notification_actions.dart';
import 'services/notifications/push_registration.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
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
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _shareTargets?.close();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    _refreshShareTargets();
    // The resume that matters most: the Share Extension runs while Weft is
    // backgrounded, so the share is already staged by the time the user comes
    // back to it — often by tapping Weft immediately afterwards.
    unawaited(_drainStagedShares());
  }

  /// The inbox subscription that keeps the launcher's share targets current.
  ///
  /// Held rather than declared with `ref.listen` in [build] for one reason:
  /// `ref.listen` subscribes on the first frame, and subscribing to
  /// [chatsProvider] builds the repository — which reads the stores and the
  /// session. Neither exists before the auth gate has passed, so the
  /// subscription starts when the session becomes ready and is closed when it
  /// stops being.
  ProviderSubscription<AsyncValue<List<Chat>>>? _shareTargets;

  /// Follows the inbox for as long as there is one.
  ///
  /// Every tick, and deliberately: [ShareShortcutService] is what decides
  /// whether a tick is worth a launcher call, and it says no to nearly all of
  /// them. Idempotent, because the session state stream re-emits `ready` on
  /// every reconnection.
  void _startShareTargets() {
    _shareTargets ??= ref.listenManual(chatsProvider, (_, next) {
      final chats = next.value;
      if (chats == null) return;
      unawaited(ref.read(shareShortcutServiceProvider).refresh(chats));
      // A launch drain almost always arrives before the first chat list does,
      // and a share sheet with no conversations in it is not worth spending a
      // staged share on. This is where the inbox finally exists.
      if (_drainPending) unawaited(_drainStagedShares());
    }, fireImmediately: true);
    unawaited(_drainStagedShares());
  }

  /// Stops following the inbox and takes the names back off the launcher.
  ///
  /// The subscription is closed *first*: a chat list emitted between the
  /// removal and the unsubscribe would republish everything that was just
  /// removed, which is the one ordering that leaks.
  void _stopShareTargets() {
    _shareTargets?.close();
    _shareTargets = null;
    unawaited(ref.read(shareShortcutServiceProvider).clear());
  }

  /// Re-ranks and republishes the device's share targets.
  ///
  /// Cheap to call on any signal: [ShareShortcutService] compares the ranked
  /// slots against what it last published and does nothing at all when they
  /// match, which is the common case.
  void _refreshShareTargets() {
    if (_shareTargets == null) return;
    final chats = ref.read(chatsProvider).value;
    if (chats == null) return;
    unawaited(ref.read(shareShortcutServiceProvider).refresh(chats));
  }

  /// A drain was asked for before there was anywhere to put its result.
  ///
  /// The two gates below are not the same gate. `_shareTargets` says the session
  /// is ready; `chatsProvider.value` says the inbox has actually arrived, which
  /// is a frame or several later and is what [_handleShare] requires. A drain in
  /// between would delete the blob and hand the payload to a sheet that refuses
  /// to open — the share would be gone, silently.
  bool _drainPending = false;

  /// Reads whatever the iOS Share Extension staged while Weft was not running.
  ///
  /// Cheap on every other platform and on an empty container alike: one channel
  /// call that answers with an empty list, or a [MissingPluginException] that
  /// [WeftStagedShares] reads as the same thing. Never throws.
  Future<void> _drainStagedShares() async {
    if (_shareTargets == null || ref.read(chatsProvider).value == null) {
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
  /// the pusher is registered against the account. A logged-out Weft has
  /// nothing to be notified about.
  Future<void> _startNotifications() async {
    if (_notificationsStarted) return;
    _notificationsStarted = true;

    final service = await ref.read(notificationServiceProvider.future);
    if (service == null || !mounted) return;

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
    );
    service.onAction = (activation) => unawaited(actions.handle(activation));

    await service.start();

    await _ensureNotificationPermission();
    // Registration and rule reconciliation both need permission to have been
    // settled first: on iOS the APNs token does not exist until the user has
    // said yes, so registering before the prompt reliably yields `noToken`.
    await ref.read(pushRegistrationProvider.future);
    await reconcilePushRules(
      session: ref.read(matrixSessionProvider),
      policy: ref.read(notificationPolicyProvider),
      chats: ref.read(chatsProvider).value ?? const [],
    );
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

  void _handleLink(WeftLink link) {
    final navigator = _navigatorKey.currentState;
    if (navigator == null) return;

    switch (link) {
      case OpenChatLink(:final chatId):
        navigator.push(
          MaterialPageRoute<void>(builder: (_) => ChatView(chatId: chatId)),
        );
      case OpenSearchLink(:final query):
        navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => SearchScreen(initialQuery: query),
          ),
        );
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
      case OpenInboxLink():
        navigator.popUntil((route) => route.isFirst);
    }
  }

  void _handleShare(SharedPayload payload) {
    final context = _navigatorKey.currentContext;
    if (context == null) return;
    // Guard: sharing into a logged-out app lands on the login screen; the
    // sheet needs the repository, which exists only past the gate.
    final chats = ref.read(chatsProvider);
    if (chats.value == null) return;
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
          _startShareTargets();
        // Both signed-out states take the launcher's copy away. `softLoggedOut`
        // is the server having invalidated the token, and until the user
        // re-auths this device is exactly as signed out as the other one —
        // while the shortcuts it published are long-lived, sitting in every
        // app's share sheet with contact names on them. They come back on the
        // next publish, which costs a re-auth nothing.
        case WeftSessionState.loggedOut || WeftSessionState.softLoggedOut:
          _stopShareTargets();
        case _:
          break;
      }
    });

    return MaterialApp(
      title: 'Weft',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigatorKey,
      theme: appearance.themeFor(
        platformBrightness,
        highContrast: highContrast,
        reduceMotion: reduceMotion,
      ),
      // Above the navigator, so a ringing call appears over whatever route is
      // open — a chat, the settings, a share sheet — and the minimised call bar
      // survives navigating away from the call screen. It takes the navigator
      // key rather than a context because everything above the navigator is
      // outside it.
      builder: (context, child) => CallOverlay(
        navigatorKey: _navigatorKey,
        child: child ?? const SizedBox.shrink(),
      ),
      home: const AuthGate(),
    );
  }
}
