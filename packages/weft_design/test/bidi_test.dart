import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

/// Direction resolved from content rather than from the locale.
///
/// The audit's RTL register is mostly mechanical — physical edges swapped for
/// directional ones — and mechanical fixes are pinned by the goldens task 8
/// generates. This file pins the part that is a *decision*: which direction a
/// given string asks for, and how tightly that answer is allowed to spread.
///
/// The failure these guard against is not "the layout looks wrong in Arabic".
/// It is a Hebrew message rendered left-to-right, where the trailing full stop
/// moves to the wrong end of the sentence and any run of Latin or digits inside
/// it comes out in an order the sender did not write — a phone number that
/// reads back as a different phone number.
void main() {
  const hebrew = 'שלום, מתי נפגשים?';
  const arabic = 'مرحبا، متى نلتقي؟';

  group('textDirectionOf', () {
    test('takes the first strong character, not the majority', () {
      expect(textDirectionOf(hebrew), TextDirection.rtl);
      expect(textDirectionOf(arabic), TextDirection.rtl);
      expect(textDirectionOf('Where are we meeting?'), TextDirection.ltr);

      // The case that separates first-strong from `Bidi.detectRtlDirectionality`,
      // which counts words and takes the majority: this sentence is Hebrew with
      // two English brand names in it, and it is a Hebrew sentence. Under the
      // counting heuristic it flips to left-to-right — and flips back when the
      // sender edits one of the names out, which is worse than being wrong once.
      expect(
        textDirectionOf('שלום, ראית את ה WhatsApp Web thing?'),
        TextDirection.rtl,
      );
      // The mirror image: an English sentence quoting a Hebrew phrase.
      expect(textDirectionOf('she said שלום and left'), TextDirection.ltr);
    });

    test('skips characters with no direction of their own', () {
      // Punctuation, digits and emoji are all skipped rather than counted, so
      // the direction is decided by the first letter that actually has one.
      expect(textDirectionOf('12:30 — שלום'), TextDirection.rtl);
      expect(textDirectionOf('👍 hello'), TextDirection.ltr);
      expect(textDirectionOf('"שלום"'), TextDirection.rtl);
    });

    test('returns null when there is nothing to get wrong', () {
      // Not left-to-right: a bubble holding "👍" inside an Arabic conversation
      // should inherit the conversation's direction, not be pinned away from
      // it. Null is what lets the caller do that.
      expect(textDirectionOf(''), isNull);
      expect(textDirectionOf('👍👍'), isNull);
      expect(textDirectionOf('42'), isNull);
      expect(textDirectionOf(':) ...'), isNull);
    });

    test('isRtlText is the same answer as a bool', () {
      expect(isRtlText(arabic), isTrue);
      expect(isRtlText('hello'), isFalse);
      // Null resolves to "not RTL" here, which is the right reading of a
      // question that only has two answers.
      expect(isRtlText('👍'), isFalse);
    });
  });

  group('WeftDirectionality', () {
    /// The direction [text] is actually laid out with, read off the render
    /// object rather than off the widget that asked for it — `RichText` leaves
    /// its own `textDirection` null when it inherits, so the widget cannot
    /// answer the question at all.
    TextDirection paintedDirection(WidgetTester tester, String text) {
      final paragraph = tester
          .renderObjectList<RenderParagraph>(find.byType(RichText))
          .firstWhere(
            (p) => p.text.toPlainText().contains(text),
            orElse: () => fail('No paragraph carrying "$text"'),
          );
      return paragraph.textDirection;
    }

    testWidgets('flips a right-to-left message inside a left-to-right UI', (
      tester,
    ) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: WeftDirectionality(text: hebrew, child: Text(hebrew)),
        ),
      );

      expect(paintedDirection(tester, hebrew), TextDirection.rtl);
    });

    testWidgets('and a left-to-right message inside a right-to-left UI', (
      tester,
    ) async {
      const english = 'on my way';
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.rtl,
          child: WeftDirectionality(text: english, child: Text(english)),
        ),
      );

      expect(paintedDirection(tester, english), TextDirection.ltr);
    });

    testWidgets('inherits when the content has no direction of its own', (
      tester,
    ) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.rtl,
          child: WeftDirectionality(text: '👍', child: Text('👍')),
        ),
      );

      expect(paintedDirection(tester, '👍'), TextDirection.rtl);
    });

    testWidgets('WeftLtr pins code to left-to-right in an RTL UI', (
      tester,
    ) async {
      const code = 'if (x) { y(); }';
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.rtl,
          child: WeftLtr(child: Text(code)),
        ),
      );

      // Indentation is the meaning of a code block, and a horizontally
      // scrolling view over one takes its axis from this.
      expect(paintedDirection(tester, code), TextDirection.ltr);
    });
  });

  group('WeftMirroredIcon', () {
    /// The horizontal scale applied to the glyph, or 1 when nothing mirrors it.
    double scaleX(WidgetTester tester) {
      final transforms = tester.widgetList<Transform>(
        find.ancestor(of: find.byType(Icon), matching: find.byType(Transform)),
      );
      return transforms.isEmpty ? 1 : transforms.first.transform.getRow(0).x;
    }

    testWidgets('mirrors under RTL and leaves the glyph alone under LTR', (
      tester,
    ) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: WeftMirroredIcon(Icons.login_rounded),
        ),
      );
      expect(scaleX(tester), 1);

      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.rtl,
          child: WeftMirroredIcon(Icons.login_rounded),
        ),
      );
      // `login_rounded` is an arrow through a doorway and carries no
      // `matchTextDirection` in the SDK, which is the whole reason this widget
      // exists — the icons that *do* carry it must never be wrapped, or they
      // mirror twice and point the wrong way.
      expect(scaleX(tester), -1);
    });

    testWidgets('is paint-only: the box and the tap target do not move', (
      tester,
    ) async {
      Future<Rect> boxIn(TextDirection direction) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: direction,
            child: const Center(
              child: WeftMirroredIcon(Icons.logout_rounded, size: 18),
            ),
          ),
        );
        return tester.getRect(find.byType(Icon));
      }

      expect(await boxIn(TextDirection.ltr), await boxIn(TextDirection.rtl));
    });
  });

  group('the inbox row follows its own content', () {
    /// A chat tile carrying [title] and a one-message history saying [body].
    Widget tile(String title, String body) => ChatTile(
      chat: Chat(
        id: 'c',
        title: title,
        sources: const [
          ChatSource(roomId: '!r:example.org', network: ChatNetwork.signal),
        ],
        lastMessage: WeftMessage(
          eventId: r'$1',
          roomId: '!r:example.org',
          senderId: '@anna:example.org',
          senderName: title,
          body: body,
          timestamp: DateTime(2026, 8, 19, 12),
          network: ChatNetwork.signal,
          kind: MessageKind.text,
          isOwn: false,
        ),
      ),
      onTap: () {},
    );

    testWidgets(
      'a Hebrew name and preview read right-to-left in an LTR inbox',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: WeftTheme.build(),
            home: Scaffold(body: tile('אנה מייבן', hebrew)),
          ),
        );

        final directions = tester
            .renderObjectList<RenderParagraph>(find.byType(RichText))
            .where(
              (p) =>
                  p.text.toPlainText().contains('אנה') ||
                  p.text.toPlainText().contains('שלום'),
            )
            .map((p) => p.textDirection)
            .toList();
        expect(directions, isNotEmpty);
        expect(directions, everyElement(TextDirection.rtl));
      },
    );
  });
}
