import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/intents.dart';
import 'app/providers.dart';
import 'app/settings.dart';
import 'features/auth/auth_gate.dart';
import 'features/chat/chat_view.dart';
import 'features/search/search_screen.dart';
import 'features/share/share_target_sheet.dart';

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

    return MaterialApp(
      title: 'Weft',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigatorKey,
      theme: appearance.themeFor(platformBrightness),
      home: const AuthGate(),
    );
  }
}
