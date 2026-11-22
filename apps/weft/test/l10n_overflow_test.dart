import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:weft/app/localisation.dart';
import 'package:weft/app/stores.dart';
import 'package:weft/data/demo_repository.dart';
import 'package:weft/features/chat/chat_view.dart';
import 'package:weft/features/chat/rich_text_view.dart';
import 'package:weft/features/inbox/inbox_shell.dart';
import 'package:weft/features/search/search_screen.dart';
import 'package:weft/features/settings/delete_account_screen.dart';
import 'package:weft/features/settings/notifications_screen.dart';
import 'package:weft/features/settings/security_screen.dart';
import 'package:weft/features/settings/settings_screen.dart';
import 'package:weft/features/settings/surfaces_screen.dart';

import 'support/golden_harness.dart';
import 'support/session_fakes.dart';

/// Every main screen, in every declared locale, at both ends of the text scale.
///
/// This is the check `locale_golden_test.dart` cannot be. A golden diff shows a
/// `RenderFlex overflowed` as a smear of yellow-and-black hatching in the
/// corner of an image somebody has to look at and recognise — and only for the
/// three locales and six scenes that file captures. This asserts the same thing
/// as a *fact*, across all eight locales and seven screens, and it does not
/// depend on font shaping at all: an overflow is a geometry error raised during
/// layout, and it is raised whether or not the machine has a font for the
/// words.
///
/// **German at 2.0× is the case this exists for.** German is the longest text
/// Sennit ships, the large-text end is where a row runs out of height, and the
/// two compound: a subtitle that fits on two lines in English at 2.0× and on
/// two lines in German at 1.0× can need four in German at 2.0×. Nothing else in
/// the suite pumps that combination.
///
/// Arabic and Hebrew are included even though they have no ARB file. Their
/// words are English, so their strings are the template's — but their *layout*
/// is mirrored, and a `Row` that overflows only when its children are laid out
/// from the other edge is a real failure that only these two can find.
///
/// Errors are collected through [FlutterError.onError] rather than
/// `tester.takeException()`: one pump can report several overflows, and
/// `takeException` yields only the first, so a screen with three broken rows
/// would be reported as having one and fixed once.
void main() {
  setUpAll(loadGoldenFonts);

  /// The two ends of the range the accessibility phase pins.
  ///
  /// 1.0× is the default, and it is here because a German string can overflow
  /// unscaled — the large end is not the only end that fails. 2.0× is the
  /// system maximum Sennit honours.
  const scales = <double>[1.0, 2.0];

  /// A phone, not a desktop window.
  ///
  /// The narrow layout is where the space runs out: the same row that has 1180
  /// logical pixels of inbox to spread into on a Mac has 430 here, and a
  /// two-pane screen at desktop width would never report the overflow a phone
  /// shows every day.
  const phone = Size(430, 932);

  late DemoChatRepository demo;

  setUp(() {
    // The parse cache is global and keyed by `(roomId, eventId)`. Without this
    // every pump after the first renders the first one's words.
    clearMessageDocumentCache();
    demo = DemoChatRepository(uploadTick: Duration.zero);
  });
  tearDown(() => demo.dispose());

  WeftStores freshStores() {
    final stores = WeftStores.inMemory();
    addTearDown(stores.dispose);
    return stores;
  }

  /// The screens a person reaches without doing anything unusual.
  ///
  /// Settings screens outnumber the rest because that is where the prose is:
  /// a switch's subtitle is a full sentence next to a fixed-width control, and
  /// it is the shape that overflows first. Notifications, security and surfaces
  /// specifically — they carry the longest subtitles in the catalogue, and the
  /// budget table in `app_en.arb` says so.
  ///
  /// The security screen needs both account fakes, and not for tidiness: its
  /// providers reach for a live Matrix session, and without them the screen
  /// never leaves its loading state — `pumpAndSettle` then spins until the
  /// suite's timeout rather than failing. The state chosen is the alarming one,
  /// which is also the wordiest: no backup and one login is where the red
  /// notice and its two long sentences are on screen at once.
  final screens = <String, Widget Function()>{
    'inbox': () => const InboxShell(),
    'chat': () => const ChatView(chatId: 'merged:anna'),
    'search': () => const SearchScreen(initialQuery: 'roof'),
    'settings': () => const SettingsScreen(),
    'notifications': () => const NotificationsScreen(),
    'security': () => const SecurityScreen(),
    'surfaces': () => const SurfacesScreen(),
    'delete account': () => const DeleteAccountScreen(),
  };

  for (final locale in weftSupportedLocales) {
    final tag = locale.toLanguageTag();
    group(tag, () {
      for (final scale in scales) {
        for (final entry in screens.entries) {
          testWidgets('${entry.key} at ${scale}x', (tester) async {
            final errors = <FlutterErrorDetails>[];
            final previous = FlutterError.onError;
            FlutterError.onError = errors.add;
            addTearDown(() => FlutterError.onError = previous);

            await pumpWeft(
              tester,
              entry.value(),
              size: phone,
              variant: WeftGoldenVariant(
                name: tag,
                locale: locale,
                textScale: scale,
              ),
              repository: demo,
              stores: freshStores(),
              deviceManager: FakeDeviceManager(const []),
              keyBackup: FakeKeyBackup(),
              // A long one, so the lead sentence and the typed-confirmation
              // label are measured at the width they will actually have to
              // wrap. It also brings Settings' Account section into the run.
              ownUserId: '@alexandra.konstantinopoulou:matrix.example.org',
            );

            // Layout alone does not report an overflow — `RenderFlex` raises it
            // from `paint`, and a pump that never painted would pass every
            // time. `pumpWeft` paints, and this makes the dependency explicit
            // rather than incidental.
            await tester.pump();

            expect(
              errors,
              isEmpty,
              reason:
                  'Rendering ${entry.key} in $tag at ${scale}x reported '
                  '${errors.length} error(s). The first:\n'
                  '${errors.isEmpty ? '' : errors.first.exceptionAsString()}',
            );
          });
        }
      }
    });
  }
}
