import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_design/weft_design.dart';

import 'package:weft/app/stores.dart';
import 'package:weft/data/demo_repository.dart';
import 'package:weft/features/chat/chat_view.dart';
import 'package:weft/features/chat/rich_text_view.dart';
import 'package:weft/features/inbox/inbox_shell.dart';
import 'package:weft/features/settings/settings_screen.dart';

import '../support/golden_harness.dart';

/// Braid drawn in the three languages that break a layout differently.
///
/// `a11y_golden_test.dart` next door varies the *conditions* a screen is drawn
/// under — text scale, contrast, direction — over English words. This file
/// varies the words. They are separate failures: a row that survives 2.0×
/// English can still clip at 1.0× German, because the German is longer before
/// anything scales it.
///
/// Three locales, chosen because each stresses a different axis:
///
/// * **`de`** — the long one. German compounds are the longest strings Braid
///   ships in any language, and this is where a fixed-width chip, a tab label
///   or a two-line subtitle budgeted for English runs out of room.
/// * **`zh`** — the short one. Simplified Chinese says the same thing in a
///   third of the characters, which is the opposite failure: a row sized by
///   its text collapses, and a layout that only ever looked right because the
///   English happened to fill it stops looking deliberate.
/// * **`ar`** — the honest half-state. Arabic has no ARB file and is not going
///   to get one here; it is declared so the layout mirrors and Material's own
///   Arabic is used, and Braid's own words fall back to English. That mixture
///   is what an Arabic device actually shows today, so it is what the image
///   should show. See the library comment in `app/localisation.dart`.
///
/// **On glyphs.** The SDK's Roboto covers neither Arabic nor CJK, and
/// [loadGoldenFonts] deliberately vendors no fonts — the images would then
/// depend on which machine took them. So Arabic and Chinese *words* draw as
/// placeholder boxes here, exactly as they do in `a11y_golden_test.dart`, and
/// for the same reason. What the images still assert is everything around the
/// words: which side the chrome sits on, how many lines a row grew to, where
/// something wrapped, and what got clipped. Reading the words is the device
/// pass in the phase's manual step, and `l10n_overflow_test.dart` is the check
/// that does not depend on shaping at all.
///
/// The `ar` scenes here do not repeat the accessibility suite's `rtl` variant:
/// that one covers the inbox, a mixed-direction thread, the composer, search
/// and the *endpoints* screen. This one covers the demo chat and the main
/// settings screen, which nothing else captures in a mirrored layout.
void main() {
  setUpAll(loadGoldenFonts);

  /// The locale dimension, in the same shape the accessibility variants use.
  ///
  /// `zh` carries its script subtag because that is how `weftSupportedLocales`
  /// declares it, and a golden should ask for the locale the app declares
  /// rather than the one the ARB filename happens to spell.
  const localeVariants = <WeftGoldenVariant>[
    WeftGoldenVariant(name: 'de', locale: Locale('de')),
    WeftGoldenVariant(
      name: 'zh',
      locale: Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
    ),
    WeftGoldenVariant(name: 'ar', locale: Locale('ar')),
  ];

  // One window per scene, held constant across locales: the locale has to be
  // the only thing that differs between two images, or the diff is unreadable.
  // The same three sizes the accessibility suite uses, for the same reason.
  const inboxWindow = Size(1180, 900);
  const chatWindow = Size(600, 900);
  const settingsWindow = Size(940, 900);

  late DemoChatRepository demo;

  setUp(() {
    // The parse cache is global and keyed by `(roomId, eventId)`. Without this
    // every pump after the first renders the first one's words.
    clearMessageDocumentCache();
    demo = DemoChatRepository(uploadTick: Duration.zero);
  });
  tearDown(() => demo.dispose());

  /// A store, torn down with the test that made it.
  ///
  /// Every settings screen reads its switches in `initState` through the
  /// synchronous `storesProvider`, which throws while the bootstrap future is
  /// pending — so a golden of one has to bring a store rather than let the real
  /// one be reached for.
  WeftStores freshStores() {
    final stores = WeftStores.inMemory();
    addTearDown(stores.dispose);
    return stores;
  }

  /// One screen and the finder that frames it.
  ///
  /// Each scene takes a [Key] and hangs it on the widget it pumps, for the
  /// reason the accessibility suite gives: two images are captured per test and
  /// without a key the second `pumpWidget` reuses the first run's `State`.
  final scenes =
      <
        ({
          String name,
          Finder target,
          Future<void> Function(
            WidgetTester,
            WeftThemeMode,
            WeftGoldenVariant,
            Key,
          )
          pump,
        })
      >[
        (
          name: 'inbox',
          target: find.byType(InboxShell),
          pump: (tester, mode, variant, key) async {
            await pumpWeft(
              tester,
              InboxShell(key: key),
              size: inboxWindow,
              mode: mode,
              variant: variant,
              repository: demo,
            );
          },
        ),
        (
          name: 'chat',
          target: find.byType(ChatView),
          pump: (tester, mode, variant, key) async {
            await pumpWeft(
              tester,
              ChatView(key: key, chatId: 'merged:anna'),
              size: chatWindow,
              mode: mode,
              variant: variant,
              repository: demo,
            );
          },
        ),
        (
          name: 'settings',
          target: find.byType(SettingsScreen),
          pump: (tester, mode, variant, key) async {
            await pumpWeft(
              tester,
              SettingsScreen(key: key),
              size: settingsWindow,
              mode: mode,
              variant: variant,
              repository: demo,
              stores: freshStores(),
            );
          },
        ),
      ];

  for (final scene in scenes) {
    group(scene.name, () {
      for (final variant in localeVariants) {
        testWidgets(variant.name, (tester) async {
          for (final (mode, suffix) in const [
            (WeftThemeMode.dark, 'dark'),
            (WeftThemeMode.light, 'light'),
          ]) {
            clearMessageDocumentCache();
            await scene.pump(
              tester,
              mode,
              variant,
              ValueKey('${variant.name}_$suffix'),
            );
            await expectLater(
              scene.target,
              matchesGoldenFile(
                'locale_${scene.name}_${variant.name}_$suffix.png',
              ),
            );
          }
        });
      }
    });
  }
}
