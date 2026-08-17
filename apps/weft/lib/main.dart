import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_matrix/weft_matrix.dart';

import 'app/intents.dart';
import 'app/notification_providers.dart';
import 'app/providers.dart';
import 'app/session_providers.dart';
import 'app/stores.dart';
import 'app/settings.dart';
import 'features/auth/auth_gate.dart';
import 'features/chat/chat_view.dart';
import 'features/notifications/notification_rationale_sheet.dart';
import 'features/search/search_screen.dart';
import 'features/share/share_target_sheet.dart';
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

class _WeftAppState extends ConsumerState<WeftApp> {
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
    // After the first frame: a cold-start share must find a navigator to
    // present into, and the initial intent is replayed by the platform side.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _intents.deliverInitialIntent();
    });
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

    // Listened to rather than watched: this starts a service, it does not
    // decide what to draw, and a rebuild must not restart it.
    ref.listen(sessionStateProvider, (_, next) {
      if (next.value == WeftSessionState.ready) {
        unawaited(_startNotifications());
      }
    });

    return MaterialApp(
      title: 'Weft',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigatorKey,
      theme: appearance.themeFor(platformBrightness),
      home: const AuthGate(),
    );
  }
}
