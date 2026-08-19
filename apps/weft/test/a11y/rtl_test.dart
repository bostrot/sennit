import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart' show DateFormat, Intl;
import 'package:weft_design/weft_design.dart';

import 'package:weft/app/localisation.dart';
import 'package:weft/app/providers.dart';
import 'package:weft/data/chat_repository.dart';
import 'package:weft/data/demo_repository.dart';
import 'package:weft/features/chat/chat_view.dart';
import 'package:weft/features/chat/rich_text_view.dart';
import 'package:weft/features/inbox/inbox_shell.dart';

import '../support/seeded_repository.dart';

/// Weft in Arabic and Hebrew.
///
/// The audit's most consequential finding was **CROSS-1**: with no
/// `supportedLocales` and no delegates, `Directionality` resolved to
/// left-to-right for every locale a device could be set to, so the app could
/// not be *put into* RTL at all and every one of the forty-two RTL findings
/// under it was latent. The first group here is that finding — if it regresses,
/// nothing else in this file is testing what it claims to test, because the
/// whole app would quietly be left-to-right again.
///
/// The rest is the distinction the phase turns on: **chrome follows the locale,
/// content follows itself**. A message's side of the thread, its tail and its
/// row of ticks are the reader's; the words inside it are the sender's.
void main() {
  late DemoChatRepository demo;

  setUp(() {
    clearMessageDocumentCache();
    demo = DemoChatRepository(uploadTick: Duration.zero);
  });
  tearDown(() => demo.dispose());

  const hebrew = 'שלום, מתי נפגשים?';

  /// The app as `main.dart` assembles it — delegates and locales included,
  /// which is the point — showing [home] in [locale].
  Future<void> pumpIn(
    WidgetTester tester,
    Widget home, {
    required Locale locale,
    ChatRepository? repository,
    Size size = const Size(1000, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chatRepositoryProvider.overrideWithValue(repository ?? demo),
        ],
        child: MaterialApp(
          theme: WeftTheme.build(),
          locale: locale,
          localizationsDelegates: weftLocalizationsDelegates,
          supportedLocales: weftSupportedLocales,
          home: home,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('the app can be put into RTL at all', () {
    /// The direction a screen inside the app resolves to under [locale].
    Future<TextDirection> directionUnder(
      WidgetTester tester,
      Locale locale,
    ) async {
      late TextDirection resolved;
      await pumpIn(
        tester,
        Builder(
          builder: (context) {
            resolved = Directionality.of(context);
            return const SizedBox.shrink();
          },
        ),
        locale: locale,
      );
      return resolved;
    }

    testWidgets('Arabic and Hebrew resolve right-to-left', (tester) async {
      expect(
        await directionUnder(tester, const Locale('ar')),
        TextDirection.rtl,
      );
      expect(
        await directionUnder(tester, const Locale('he')),
        TextDirection.rtl,
      );
      expect(
        await directionUnder(tester, const Locale('en')),
        TextDirection.ltr,
      );
    });

    testWidgets('a locale Weft does not declare falls back to English', (
      tester,
    ) async {
      // Weft ships no translated strings, so the honest answer for a device set
      // to French is English text in a left-to-right layout — not English text
      // mirrored. `en` being first in the list is what produces that.
      expect(
        await directionUnder(tester, const Locale('fr')),
        TextDirection.ltr,
      );
      expect(weftSupportedLocales.first.languageCode, 'en');
    });

    test('the formatting locale is only applied when intl has data for it', () {
      // A `DateFormat` built for a locale whose symbols were never loaded
      // throws — inside `build`, on every bubble at once. A widget test does
      // not run `main` and therefore never loads them, so this guard is what
      // lets the tests above put the app into Arabic without their clocks
      // bringing the screen down. `main` awaits `initializeDateFormatting`, and
      // on a device the same call makes the answer here the other one.
      applyFormattingLocale(const Locale('ar'));
      addTearDown(() => Intl.defaultLocale = null);
      expect(
        () => DateFormat.Hm().format(DateTime(2026, 8, 19, 14, 32)),
        returnsNormally,
      );
    });
  });

  group('a message carries its own direction', () {
    /// The direction [text] is laid out with, read off the render object:
    /// `RichText` leaves its own `textDirection` null when it inherits one.
    TextDirection paintedDirection(WidgetTester tester, String text) {
      final paragraph = tester
          .renderObjectList<RenderParagraph>(find.byType(RichText))
          .firstWhere(
            (p) => p.text.toPlainText().contains(text),
            orElse: () => fail('No paragraph carrying "$text"'),
          );
      return paragraph.textDirection;
    }

    testWidgets('Hebrew inside an English conversation reads right-to-left', (
      tester,
    ) async {
      final repository = SeededChatRepository(
        demo,
        messages: [
          seededMessage(eventId: r'$he', body: hebrew),
          seededMessage(
            eventId: r'$en',
            body: 'Where are we meeting?',
            minutesAgo: 1,
          ),
        ],
      );
      await pumpIn(
        tester,
        ChatView(chatId: repository.chatId),
        locale: const Locale('en'),
        repository: repository,
      );

      expect(paintedDirection(tester, hebrew), TextDirection.rtl);
      // The other bubble in the same thread is unaffected: this is per message,
      // not per conversation and not per locale.
      expect(
        paintedDirection(tester, 'Where are we meeting?'),
        TextDirection.ltr,
      );
    });

    testWidgets('and English inside an Arabic UI reads left-to-right', (
      tester,
    ) async {
      final repository = SeededChatRepository(
        demo,
        messages: [seededMessage(eventId: r'$en', body: 'on my way')],
      );
      await pumpIn(
        tester,
        ChatView(chatId: repository.chatId),
        locale: const Locale('ar'),
        repository: repository,
      );

      expect(paintedDirection(tester, 'on my way'), TextDirection.ltr);
    });
  });

  group('the thread itself follows the reader', () {
    /// Where the bubble carrying [text] sits, as a fraction of the window.
    double bubbleCentre(WidgetTester tester, String text) =>
        tester.getCenter(find.text(text, findRichText: true).first).dx /
        tester.view.physicalSize.width;

    /// The bubble's rounding, resolved against [direction].
    BorderRadius bubbleRadius(
      WidgetTester tester,
      String text,
      TextDirection direction,
    ) {
      final containers = tester.widgetList<Container>(
        find.ancestor(
          of: find.text(text, findRichText: true).first,
          matching: find.byType(Container),
        ),
      );
      for (final container in containers) {
        final decoration = container.decoration;
        if (decoration is BoxDecoration && decoration.borderRadius != null) {
          return decoration.borderRadius!.resolve(direction);
        }
      }
      fail('No decorated bubble around "$text"');
    }

    Future<void> pumpThread(WidgetTester tester, Locale locale) async {
      final repository = SeededChatRepository(
        demo,
        messages: [
          seededMessage(eventId: r'$mine', body: 'on my way', isOwn: true),
          seededMessage(
            eventId: r'$theirs',
            body: 'Where are we meeting?',
            minutesAgo: 1,
          ),
        ],
      );
      await pumpIn(
        tester,
        ChatView(chatId: repository.chatId),
        locale: locale,
        repository: repository,
      );
    }

    testWidgets('own messages move to the other side under RTL', (
      tester,
    ) async {
      await pumpThread(tester, const Locale('en'));
      expect(bubbleCentre(tester, 'on my way'), greaterThan(0.5));
      expect(bubbleCentre(tester, 'Where are we meeting?'), lessThan(0.5));

      await pumpThread(tester, const Locale('ar'));
      // Not a fix so much as a thing that must not be broken: the row already
      // uses `MainAxisAlignment.end`, which resolves against the ambient
      // direction. What would break it is somebody "helping" it with a physical
      // alignment.
      expect(bubbleCentre(tester, 'on my way'), lessThan(0.5));
      expect(bubbleCentre(tester, 'Where are we meeting?'), greaterThan(0.5));
    });

    testWidgets('and the tail moves with them', (tester) async {
      await pumpThread(tester, const Locale('en'));
      final ltr = bubbleRadius(tester, 'on my way', TextDirection.ltr);
      // The tail is the one corner that is not fully rounded, and on an own
      // message it points at the side of the thread the message sits on.
      expect(ltr.bottomRight.x, lessThan(ltr.bottomLeft.x));

      await pumpThread(tester, const Locale('ar'));
      final rtl = bubbleRadius(tester, 'on my way', TextDirection.rtl);
      expect(rtl.bottomLeft.x, lessThan(rtl.bottomRight.x));
    });

    testWidgets('the inbox and its rail swap sides', (tester) async {
      await pumpIn(tester, const InboxShell(), locale: const Locale('en'));
      final ltrRail = tester.getCenter(find.byType(NetworkRail)).dx;
      expect(ltrRail / tester.view.physicalSize.width, lessThan(0.5));

      await pumpIn(tester, const InboxShell(), locale: const Locale('ar'));
      final rtlRail = tester.getCenter(find.byType(NetworkRail)).dx;
      expect(rtlRail / tester.view.physicalSize.width, greaterThan(0.5));
    });
  });

  group('the source itself', () {
    /// Every shipped `.dart` file in the app and the packages.
    ///
    /// Read as bytes and decoded permissively for the reason the audit gives:
    /// two files here carry byte sequences BSD `grep` calls binary, and it then
    /// suppresses their matches *silently* — which is how the first sweep of
    /// the audit missed `rich_text_view.dart` entirely, one of the four files
    /// carrying a physical `Border(left:)`.
    List<File> sources() => [
      for (final root in [Directory('lib'), Directory('../../packages')])
        ...root
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))
            .where((f) => !f.path.contains('/test/'))
            .where((f) => !f.path.contains('/.dart_tool/')),
    ];

    /// [file]'s code with line comments stripped, so prose about a banned
    /// pattern — including the comments explaining why it is banned — does not
    /// read as a use of it.
    String code(File file) => utf8
        .decode(file.readAsBytesSync(), allowMalformed: true)
        .split('\n')
        .map((line) {
          final comment = line.indexOf('//');
          return comment == -1 ? line : line.substring(0, comment);
        })
        .join('\n');

    test('carries no physical-edge layout API', () {
      // The audit's RTL register, as a rule rather than as a list of fixes: a
      // new screen written the old way fails here on the day it is written,
      // rather than on the day somebody switches a device to Arabic.
      const banned = <String, String>{
        'EdgeInsets.fromLTRB(': 'EdgeInsetsDirectional.fromSTEB(',
        'EdgeInsets.only(left:': 'EdgeInsetsDirectional.only(start:',
        'EdgeInsets.only(right:': 'EdgeInsetsDirectional.only(end:',
        'alignment: Alignment.centerLeft':
            'alignment: AlignmentDirectional.centerStart',
        'alignment: Alignment.centerRight':
            'alignment: AlignmentDirectional.centerEnd',
        'Border(left:': 'BorderDirectional(start:',
        'Border(right:': 'BorderDirectional(end:',
        'BorderRadius.only(': 'BorderRadiusDirectional.only(',
      };

      final scanned = sources();
      // The sweep is only worth what it reads: a filter that silently matched
      // nothing would pass this test for ever. Weft has ~50 UI files plus the
      // packages behind them.
      expect(scanned, hasLength(greaterThan(100)));

      final offences = <String>[];
      for (final file in scanned) {
        final text = code(file);
        for (final entry in banned.entries) {
          if (text.contains(entry.key)) {
            offences.add('${file.path}: ${entry.key} — use ${entry.value}');
          }
        }
      }
      expect(offences, isEmpty);
    });

    test('anchors nothing to one physical side of a Stack', () {
      // `Positioned(left: 0, right: 0, …)` is a stretch and is direction-safe;
      // `Positioned(right: 6)` is an anchor and is not. The rule is therefore
      // "both or neither", which is exactly the difference between the two.
      final offences = <String>[];
      for (final file in sources()) {
        final lines = code(file).split('\n');
        for (var i = 0; i < lines.length; i++) {
          if (!lines[i].contains('Positioned(')) continue;
          var left = false;
          var right = false;
          for (var j = i + 1; j < lines.length && j < i + 12; j++) {
            if (lines[j].contains('child:')) break;
            if (RegExp(r'^\s*left:').hasMatch(lines[j])) left = true;
            if (RegExp(r'^\s*right:').hasMatch(lines[j])) right = true;
          }
          if (left != right) {
            offences.add('${file.path}:${i + 1} — use PositionedDirectional');
          }
        }
      }
      expect(offences, isEmpty);
    });
  });
}
