@Tags(['preview'])
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_design/weft_design.dart';

import 'package:weft_matrix/weft_matrix.dart' show DetectedBridge;
import 'package:weft_domain/weft_domain.dart' show ChatNetwork;

import 'package:weft/app/stores.dart';
import 'package:weft/features/bridges/bridges_screen.dart';
import 'package:weft/features/chat/chat_view.dart';
import 'package:weft/features/chat/rich_text_view.dart';
import 'package:weft/features/contact/contact_profile.dart';
import 'package:weft/features/inbox/inbox_shell.dart';
import 'package:weft/features/merge/merge_screen.dart';
import 'package:weft/features/search/search_screen.dart';
import 'package:weft/features/settings/endpoints_screen.dart';
import 'package:weft/features/settings/integrations_screen.dart';
import 'package:weft/features/settings/link_previews_screen.dart';
import 'package:weft/features/settings/mcp_screen.dart';
import 'package:weft/features/settings/models_screen.dart';
import 'package:weft/features/settings/notifications_screen.dart';
import 'package:weft/features/settings/settings_screen.dart';
import 'package:weft/features/settings/sms_screen.dart';
import 'package:weft/features/settings/surfaces_screen.dart';

import '../support/golden_harness.dart';

/// Renders every screen to disk so it can be looked at.
///
/// Not a golden — nothing is compared. This is the working equivalent of
/// running the app and clicking through it, which is the only way to catch the
/// things no assertion sees: a control sized for a thumb, a heading three times
/// too big, a gap where a divider should be. Tagged so it stays out of an
/// ordinary run.
void main() {
  setUpAll(loadGoldenFonts);
  setUp(clearMessageDocumentCache);

  const out =
      '/tmp/braid'
      '/fe50cf4a-2741-4781-85cc-71325a1d67dd/scratchpad/ui';

  /// A homeserver with bridges on it — the state this screen is actually in
  /// for anyone who runs any, and the one it was never drawn in.
  const detected = [
    DetectedBridge(
      network: ChatNetwork.whatsapp,
      botUserId: '@whatsappbot:example.org',
      roomCount: 64,
    ),
    DetectedBridge(
      network: ChatNetwork.signal,
      botUserId: '@signalbot:example.org',
      roomCount: 31,
    ),
    DetectedBridge(
      network: ChatNetwork.telegram,
      botUserId: '@telegrambot:example.org',
      roomCount: 39,
    ),
    DetectedBridge(network: ChatNetwork.discord, roomCount: 7),
  ];

  Future<void> shot(
    WidgetTester tester,
    String name,
    Widget child, {
    Size size = const Size(1280, 800),
    WeftThemeMode mode = WeftThemeMode.dark,
  }) async {
    await pumpWeft(
      tester,
      RepaintBoundary(child: child),
      size: size,
      mode: mode,
      surface: WeftSurface.mac,
      stores: WeftStores.inMemory(),
      detectedBridges: detected,
    );
    await tester.pumpAndSettle();

    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byType(RepaintBoundary).first,
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$out/$name.png')
        ..createSync(recursive: true)
        ..writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  }

  final screens = <String, Widget Function()>{
    '01_inbox': InboxShell.new,
    '02_chat': () => const ChatView(chatId: 'merged:anna'),
    '03_search': SearchScreen.new,
    '04_settings': SettingsScreen.new,
    '05_notifications': NotificationsScreen.new,
    '06_integrations': IntegrationsScreen.new,
    '07_endpoints': EndpointsScreen.new,
    '08_mcp': McpScreen.new,
    '09_models': ModelsScreen.new,
    '10_sms': SmsScreen.new,
    '11_surfaces': SurfacesScreen.new,
    '12_link_previews': LinkPreviewsScreen.new,
    '13_bridges': BridgesScreen.new,
    '14_merge': MergeScreen.new,
    '15_contact': () => const ContactProfileScreen(chatId: 'merged:anna'),
  };

  for (final entry in screens.entries) {
    testWidgets(entry.key, (tester) async {
      await shot(tester, entry.key, entry.value());
    });
  }

  // The preview's own card. The composed overlay cannot be captured here — a
  // route draws above the repaint boundary this harness photographs — so what
  // is checked is the thing inside it: a conversation with no composer.
  testWidgets('16_chat_preview', (tester) async {
    await shot(
      tester,
      '16_chat_preview',
      Center(
        child: SizedBox(
          width: 720,
          height: 520,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: const ChatView(chatId: 'merged:anna', preview: true),
          ),
        ),
      ),
    );
  });

  testWidgets('01_inbox_light', (tester) async {
    await shot(
      tester,
      '01_inbox_light',
      const InboxShell(),
      mode: WeftThemeMode.light,
    );
  });

  testWidgets('04_settings_light', (tester) async {
    await shot(
      tester,
      '04_settings_light',
      const SettingsScreen(),
      mode: WeftThemeMode.light,
    );
  });
}
