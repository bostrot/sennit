import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_design/weft_design.dart';
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

import 'support/golden_harness.dart';

/// Every screen, laid out at desktop sizes, checked for the failures that only
/// show up as pixels.
///
/// A golden pins one scene against one image and says nothing about the others;
/// a semantics test can read a label off a widget that is drawn three pixels
/// outside its parent. What this catches is the class of bug that a person
/// notices immediately and no other test in the suite can see: a row wider than
/// the box it is in, a column taller than the window, a label clipped by a
/// container sized for different text.
///
/// Flutter reports every one of those as a `FlutterError` during layout, which
/// a widget test collects — so the whole check is "pump it and see whether
/// anything was thrown". Two window sizes, because the failures live at the
/// ends: a wide window is where a `Row` of eight controls fits and a narrow one
/// is where it does not, and the narrow size here is the smallest the window is
/// allowed to be.
void main() {
  setUpAll(loadGoldenFonts);

  setUp(clearMessageDocumentCache);

  /// The two windows worth checking: a comfortable one, and the minimum
  /// `MainFlutterWindow` allows anyone to drag to.
  const windows = <String, Size>{
    'roomy': Size(1280, 800),
    'minimum': Size(720, 480),
  };

  /// Pumps [build] on the desktop surface and fails on anything thrown.
  ///
  /// `takeException` rather than an expectation about the tree: an overflow is
  /// not a widget that can be found, it is an error raised during layout, and
  /// the only place it surfaces is here.
  Future<void> check(
    WidgetTester tester,
    String name,
    Size size,
    Widget Function() build, {
    WeftStores? stores,
    WeftThemeMode mode = WeftThemeMode.dark,
  }) async {
    await pumpWeft(
      tester,
      build(),
      size: size,
      mode: mode,
      surface: WeftSurface.mac,
      stores: stores,
    );
    expect(
      tester.takeException(),
      isNull,
      reason: '$name overflowed or threw at ${size.width}×${size.height}',
    );
  }

  /// Screens that need nothing but a repository.
  final plain = <String, Widget Function()>{
    'inbox': InboxShell.new,
    'chat': () => const ChatView(chatId: 'merged:anna'),
    'chat (single network)': () =>
        const ChatView(chatId: '!konrad_wa_room:example.org'),
    'search': SearchScreen.new,
    'settings': SettingsScreen.new,
    'notifications': NotificationsScreen.new,
    'integrations': IntegrationsScreen.new,
    'endpoints': EndpointsScreen.new,
    'mcp': McpScreen.new,
    'models': ModelsScreen.new,
    'sms': SmsScreen.new,
    'surfaces': SurfacesScreen.new,
    'link previews': LinkPreviewsScreen.new,
    'bridges': BridgesScreen.new,
    'merge': MergeScreen.new,
    'contact profile': () => const ContactProfileScreen(chatId: 'merged:anna'),
  };

  for (final entry in plain.entries) {
    for (final window in windows.entries) {
      testWidgets('${entry.key} lays out in a ${window.key} window', (
        tester,
      ) async {
        await check(
          tester,
          entry.key,
          window.value,
          entry.value,
          stores: WeftStores.inMemory(),
        );
      });
    }
  }

  // Light as well as dark for the two screens that are looked at all day. A
  // palette does not change a layout, but a *theme* carries the type scale and
  // the density, and those do.
  for (final entry in {
    'inbox': InboxShell.new,
    'settings': SettingsScreen.new,
  }.entries) {
    testWidgets('${entry.key} lays out in light', (tester) async {
      await check(
        tester,
        entry.key,
        const Size(1280, 800),
        entry.value,
        stores: WeftStores.inMemory(),
        mode: WeftThemeMode.light,
      );
    });
  }
}
