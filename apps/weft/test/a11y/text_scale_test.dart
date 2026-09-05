import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

import 'package:weft/app/stores.dart';
import 'package:weft/features/auth/verification_screen.dart';
import 'package:weft/features/chat/chat_view.dart';
import 'package:weft/features/chat/rich_text_view.dart';

import '../support/a11y_harness.dart';
import '../support/attachment_fixtures.dart';
import 'package:weft/app/localisation.dart';
import '../support/golden_harness.dart' show loadGoldenFonts;

/// The three text-scale findings no golden scene reaches.
///
/// Task 8 generated 2.0× images of the inbox, a chat, the composer, search and
/// settings, and twelve of the register's fifteen entries are visible in one of
/// them. Three are not: the voice bubble's duration (SCALE-8), the SAS emoji
/// cell (SCALE-11) and the list marker in a formatted body (SCALE-16). None is
/// a golden question either — each is "does this box still hold its text at
/// 2.0×", which is a rect, and a rect is a cheaper and far more legible
/// assertion than a fifth, sixth and seventh scene whose diff a reviewer would
/// have to read pixel by pixel.
///
/// The shape is `packages/weft_design/test/text_scale_test.dart`'s, which
/// answers the same question for SCALE-1, 4 and 5. It could not be written
/// *there*: all three boxes below live in `apps/weft/lib/features/`, and
/// `weft_design` cannot see them.
///
/// **Real fonts, always.** `flutter_test` otherwise substitutes a face that
/// draws every glyph as a fixed-width box, which makes every width here a
/// measurement of the placeholder rather than of the text — under it a marker
/// reading `8.` needs 28.5dp where Roboto needs 11, so the suite would report a
/// clip no device has and stay silent about the one it does.
void main() {
  setUpAll(loadGoldenFonts);

  /// The range the phase names, plus the 1.3× a device lands on with one notch
  /// of "larger text" — the setting people actually use.
  const scales = [0.85, 1.0, 1.3, 2.0];

  /// Whether [text] was laid out at the width it asked for, on one line.
  ///
  /// Two questions, because a box too small fails them separately: a `Text`
  /// with an `overflow` drops characters and reports [didExceedMaxLines], and
  /// one without soft-wraps instead and reports nothing while quietly becoming
  /// twice as tall inside a box that did not grow.
  void expectUncramped(
    WidgetTester tester,
    Finder text, {
    required double scale,
    int maxLines = 1,
  }) {
    final paragraph = tester.renderObject<RenderParagraph>(text);
    final rect = tester.getRect(text);
    final oneLine = paragraph.getMaxIntrinsicHeight(double.infinity);

    expect(
      paragraph.didExceedMaxLines,
      isFalse,
      reason: 'truncated at ${scale}x: ${tester.widget<Text>(text).data}',
    );
    expect(
      rect.height,
      lessThanOrEqualTo(oneLine * maxLines + 0.5),
      reason:
          'wrapped past $maxLines line(s) at ${scale}x '
          '(${rect.height} tall, one line is $oneLine): '
          '${tester.widget<Text>(text).data}',
    );
  }

  group('SCALE-8 — the voice bubble keeps its duration', () {
    // The register read `chat_view.dart`'s `(constraints.maxWidth - 60)` as a
    // fixed allowance for a label that grows, and the diagnosis is wrong in a
    // way only a measurement shows: the waveform is `Flexible` and the duration
    // is not, so the `Row` gives the label its full natural width *first* and
    // the bars absorb whatever is left. The 60 is slack subtracted from a width
    // the label had already been taken out of. It makes the bubble slightly
    // narrower than it needs to be; it does not clip.
    //
    // So this is a pin rather than a fix, and it is worth having because the
    // thing that would break it is exactly the tidy-up that makes the label
    // `Flexible` or gives the bars a `SizedBox` — and the failure would be a
    // duration reading `1:1…` on a phone in large type.
    const roomId = '!design_room:example.org';

    /// `70:10` — four characters wider than the `0:09` a fixture normally
    /// carries, and the widest string short of a three-digit minute count.
    const label = '70:10';

    /// A wide window and a phone, because the bars are what absorb the label's
    /// growth and a narrow bubble is where they run out of room to do it.
    for (final scale in scales) {
      for (final window in const [Size(1000, 900), Size(360, 740)]) {
        testWidgets('${scale}x in a ${window.width.toInt()}dp window', (
          tester,
        ) async {
          final stores = WeftStores.inMemory();
          addTearDown(stores.dispose);
          final repository = StubChatRepository(
            history: [
              WeftMessage(
                eventId: r'$voice',
                roomId: roomId,
                network: ChatNetwork.matrix,
                senderId: '@priya:example.org',
                senderName: 'Priya',
                timestamp: DateTime(2026, 8, 18, 14),
                kind: MessageKind.voice,
                isOwn: false,
                body: 'voice message',
                attachmentUrl: 'mxc://example.org/voice',
                durationMs: 4210000,
              ),
            ],
            // Not null: `DemoChatRepository` otherwise drives its own upload
            // simulation on a zero-duration tick and `pumpAndSettle` never
            // returns.
            uploads: const [],
          );
          addTearDown(repository.dispose);

          await pumpScreen(
            tester,
            const ChatView(chatId: roomId),
            repository: repository,
            stores: stores,
            textScale: scale,
            size: window,
          );

          final duration = find.text(label);
          expect(duration, findsOneWidget);
          expectUncramped(tester, duration, scale: scale);

          // `takeException` is what catches the `RenderFlex overflowed` a
          // waveform with nowhere left to shrink would raise.
          expect(tester.takeException(), isNull);
        });
      }
    }
  });

  group('SCALE-11 — the SAS emoji cell holds the name being compared', () {
    // The cell was 74dp with 4dp of padding either side, so the caption had
    // 66dp for two lines. At 2.0× `labelSmall` is 22dp type and the longest
    // names in the SAS table no longer fit — and the user is being asked to
    // compare *these words* against another device, so a name ending in an
    // ellipsis is the verification step failing, not a cosmetic clip.
    //
    // The four longest strings in the table rather than a sample: the failure
    // is per-string, and a test that checked "Dog" would pass at every scale
    // and prove nothing.
    const longest = ['Strawberry', 'Light Bulb', 'Headphones', 'Thumbs Up'];

    for (final scale in scales) {
      testWidgets('the longest names at ${scale}x', (tester) async {
        await tester.pumpWidget(
          MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: MaterialApp(
              localizationsDelegates: weftLocalizationsDelegates,
              theme: WeftTheme.build(),
              home: Scaffold(
                body: Center(
                  child: Wrap(
                    spacing: WeftSpace.md,
                    runSpacing: WeftSpace.md,
                    children: [
                      for (final (index, name) in longest.indexed)
                        SasEmojiCell(
                          emoji: '🍓',
                          name: name,
                          index: index,
                          total: longest.length,
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );

        for (final name in longest) {
          // Two lines is the design: the caption is `maxLines: 2`, and a name
          // reading over two lines is legible where one reading `Strawb…` is
          // not.
          expectUncramped(tester, find.text(name), scale: scale, maxLines: 2);
        }
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('and the cell is unchanged at 1.0×', (tester) async {
      // The scaler is applied at 1.0× too, so this asserts the arithmetic is
      // the identity there — the same claim `WeftUnreadBadge` makes, and what
      // keeps the box the design specified when nobody has touched the setting.
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: weftLocalizationsDelegates,
          theme: WeftTheme.build(),
          home: const Scaffold(
            body: Center(
              child: SasEmojiCell(
                emoji: '🍓',
                name: 'Strawberry',
                index: 0,
                total: 7,
              ),
            ),
          ),
        ),
      );
      expect(
        tester.getSize(find.byType(SasEmojiCell)).width,
        SasEmojiCell.extent,
      );
    });
  });

  group('SCALE-16 — the list marker fits its own gutter', () {
    // The only one of the three that was a real clip, and it needed a
    // two-digit item to show: `9.` fits 26dp at 2.0× and `10.` needs 40, so a
    // list wrapped its own numbers onto a second line — `10` over `.` — from
    // the tenth item down, inside a box that had not grown.
    //
    // A nine-item list starting at 9, so both the one- and two-digit widths are
    // measured in the same layout, and a bullet list beside it, because the
    // bullet has its own narrower gutter and the fix has to move both.
    final markers = [for (var i = 9; i <= 17; i++) '$i.'];

    for (final scale in scales) {
      testWidgets('ordered and bullet markers at ${scale}x', (tester) async {
        clearMessageDocumentCache();
        final document = parseMessageBody(
          body: 'a list',
          formattedBody:
              '<ol start="9">'
              '${List.filled(markers.length, '<li>an item</li>').join()}'
              '</ol>'
              '<ul><li>and a bullet</li></ul>',
        );

        await tester.pumpWidget(
          MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: MaterialApp(
              localizationsDelegates: weftLocalizationsDelegates,
              theme: WeftTheme.build(),
              home: Scaffold(
                body: Center(
                  // 520 is the bubble's own `maxWidth`, so the item text has
                  // the room it has in a conversation and the only box under
                  // test is the gutter.
                  child: SizedBox(
                    width: 520,
                    child: RichTextView(
                      document: document,
                      baseStyle: const TextStyle(fontSize: 14),
                      accent: const Color(0xFF7C5CFF),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );

        for (final marker in [...markers, '•']) {
          expectUncramped(tester, find.text(marker), scale: scale);
        }
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('and the gutter is unchanged at 1.0×', (tester) async {
      // Same identity claim as the emoji cell: the goldens taken before the
      // gutter scaled must not move, and `rich_formatted_{dark,light}` contain
      // a list.
      clearMessageDocumentCache();
      final document = parseMessageBody(
        body: 'a list',
        formattedBody: '<ol><li>an item</li></ol><ul><li>a bullet</li></ul>',
      );

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: weftLocalizationsDelegates,
          theme: WeftTheme.build(),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 520,
                child: RichTextView(
                  document: document,
                  baseStyle: const TextStyle(fontSize: 14),
                  accent: const Color(0xFF7C5CFF),
                ),
              ),
            ),
          ),
        ),
      );

      for (final (marker, width) in [('1.', 26.0), ('•', 16.0)]) {
        expect(
          tester
              .widget<SizedBox>(
                find
                    .ancestor(
                      of: find.text(marker),
                      matching: find.byType(SizedBox),
                    )
                    .first,
              )
              .width,
          width,
          reason: 'the $marker gutter moved at 1.0×',
        );
      }
    });
  });
}
