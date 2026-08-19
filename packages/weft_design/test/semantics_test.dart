import 'dart:ui' show CheckedState;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

/// What the design system's components say to a screen reader.
///
/// The audit's headline finding was that six `Semantics` widgets existed in the
/// whole app and that the ones that did exist were not *exclusive* — the inbox
/// row carried a correct sentence and then announced the title, the pin, the
/// mute glyph, the tick, the preview, the time and the badge again underneath
/// it. So these tests assert two things at once and both matter: that the label
/// is right, and that nothing else is left speaking beside it.
void main() {
  Chat chatWith({
    String title = 'Anna Maven',
    List<ChatNetwork> networks = const [ChatNetwork.signal],
    int unread = 0,
    bool pinned = false,
    bool muted = false,
    WeftMessage? last,
  }) => Chat(
    id: 'chat:anna',
    title: title,
    sources: [
      for (final network in networks)
        ChatSource(roomId: '!${network.name}:example.org', network: network),
    ],
    lastMessage: last,
    unreadCount: unread,
    pinned: pinned,
    muted: muted,
  );

  WeftMessage message({
    String body = 'Are we still on for six?',
    bool isOwn = false,
    DeliveryState? deliveryState,
  }) => WeftMessage(
    eventId: r'$last',
    roomId: '!signal:example.org',
    network: ChatNetwork.signal,
    senderId: '@anna:example.org',
    senderName: 'Anna Maven',
    timestamp: DateTime(2026, 8, 18, 14, 32),
    kind: MessageKind.text,
    isOwn: isOwn,
    body: body,
    deliveryState: deliveryState,
  );

  Future<void> pump(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: WeftTheme.build(),
        home: Scaffold(body: Center(child: child)),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Every label in the tree, so a test can assert what is *not* said as well
  /// as what is.
  List<String> labelsIn(WidgetTester tester) {
    final labels = <String>[];
    void walk(SemanticsNode node) {
      if (node.label.isNotEmpty) labels.add(node.label);
      node.visitChildren((child) {
        walk(child);
        return true;
      });
    }

    walk(tester.getSemantics(find.byType(MaterialApp)));
    return labels;
  }

  group('ChatTile', () {
    testWidgets('is one node saying everything the row shows', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(
        tester,
        ChatTile(
          chat: chatWith(
            networks: [ChatNetwork.signal, ChatNetwork.whatsapp],
            unread: 3,
            pinned: true,
            muted: true,
            last: message(isOwn: true, deliveryState: DeliveryState.read),
          ),
          timeLabel: '14:32',
          onTap: () {},
        ),
      );

      // Everything a sighted user reads off the row, in the order they scan it.
      // The three the old label omitted are the ones that decide whether the
      // row is worth opening: the preview, the time and the delivery state.
      expect(
        tester.getSemantics(find.byType(ChatTile)).label,
        // The network order is [Chat.networks]', not the source list's.
        'Anna Maven, merged across 2 networks: WhatsApp, Signal, pinned, '
        'muted, Read, Are we still on for six?, 14:32, 3 unread',
      );
      handle.dispose();
    });

    testWidgets('leaves nothing else in the row speaking', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(
        tester,
        ChatTile(
          chat: chatWith(unread: 3, last: message()),
          timeLabel: '14:32',
          onTap: () {},
        ),
      );

      // The failure this replaces: the title, the preview, the time and the
      // badge were announced *again* underneath the merged node, so a reader
      // heard the row roughly twice, the second time in fragments.
      expect(labelsIn(tester), hasLength(1));
      handle.dispose();
    });

    testWidgets('opening and selecting survive the exclusion', (tester) async {
      final handle = tester.ensureSemantics();
      var taps = 0;
      var longPresses = 0;
      await pump(
        tester,
        ChatTile(
          chat: chatWith(),
          onTap: () => taps++,
          onLongPress: () => longPresses++,
        ),
      );

      // Excluding the subtree also excludes the `GestureDetector`'s actions.
      // Losing them would make the inbox unopenable by a screen reader, which
      // is worse than the bug being fixed.
      final node = tester.getSemantics(find.byType(ChatTile));
      final data = node.getSemanticsData();
      expect(data.hasAction(SemanticsAction.tap), isTrue);
      expect(data.hasAction(SemanticsAction.longPress), isTrue);
      await tester.tap(find.byType(ChatTile));
      await tester.longPress(find.byType(ChatTile));
      expect(taps, 1);
      expect(longPresses, 1);
      handle.dispose();
    });

    testWidgets('selection mode carries the tick on the row itself', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pump(
        tester,
        ChatTile(
          chat: chatWith(),
          checked: true,
          leading: Checkbox(value: true, onChanged: (_) {}),
          onTap: () {},
        ),
      );

      final node = tester.getSemantics(find.byType(ChatTile));
      // On its own the `Checkbox` announced "checkbox" and never said which
      // conversation, so the state moves to the node that has the name.
      expect(node.flagsCollection.isChecked, CheckedState.isTrue);
      expect(node.label, startsWith('Anna Maven'));
      handle.dispose();
    });

    testWidgets('read and delivered are told apart in words', (tester) async {
      final handle = tester.ensureSemantics();
      for (final (state, word) in const [
        (DeliveryState.read, 'Read'),
        (DeliveryState.delivered, 'Delivered'),
      ]) {
        await pump(
          tester,
          ChatTile(
            chat: chatWith(last: message(isOwn: true, deliveryState: state)),
            onTap: () {},
          ),
        );
        // The two states draw the *same* double tick and differ only in
        // colour — which is the one distinction a colour-blind reader cannot
        // make and a screen reader cannot see at all.
        expect(
          tester.getSemantics(find.byType(ChatTile)).label,
          contains(word),
        );
        expect(find.byTooltip(word), findsOneWidget);
      }
      handle.dispose();
    });
  });

  group('WeftAvatar', () {
    testWidgets('announces the person rather than their initials', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pump(
        tester,
        const WeftAvatar(label: 'Anna Maven', networks: [ChatNetwork.signal]),
      );

      // What a reader actually heard here was "AM": the initials `Text` under
      // the picture is a semantics node like any other and was never excluded.
      expect(labelsIn(tester), ['Anna Maven, on Signal']);
      handle.dispose();
    });

    testWidgets('says the merge the ring only shows', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(
        tester,
        const WeftAvatar(
          label: 'Anna Maven',
          networks: [ChatNetwork.signal, ChatNetwork.whatsapp],
          online: true,
        ),
      );

      expect(labelsIn(tester), [
        'Anna Maven, merged across 2 networks: Signal, WhatsApp, online',
      ]);
      handle.dispose();
    });

    testWidgets('goes quiet when the row beside it already said the name', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pump(
        tester,
        const WeftAvatar(label: 'Anna Maven', semanticsLabel: ''),
      );

      expect(labelsIn(tester), isEmpty);
      handle.dispose();
    });
  });

  group('NetworkGlyph', () {
    testWidgets('names the network instead of spelling the lettermark', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      // Google Chat has no Simple Icons glyph, so it falls back to "Gc" — the
      // visible form of the failure, announced one character at a time.
      await pump(tester, const NetworkGlyph(network: ChatNetwork.googlechat));

      expect(labelsIn(tester), ['Google Chat']);
      handle.dispose();
    });
  });

  group('NetworkRail', () {
    testWidgets('announces each filter once, with its unread count', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pump(
        tester,
        SizedBox(
          height: 600,
          child: NetworkRail(
            networks: const [ChatNetwork.signal],
            selected: const {ChatNetwork.signal},
            unreadByNetwork: const {ChatNetwork.signal: 4},
            onToggle: (_) {},
            onShowAll: () {},
          ),
        ),
      );

      // Twice, previously: a `Tooltip` contributes its message to the semantics
      // tree as well as to the screen, and the node below it says the same
      // thing and more.
      expect(labelsIn(tester).where((l) => l.contains('Signal')), [
        'Signal, 4 unread',
      ]);
      handle.dispose();
    });
  });

  group('semanticsSentence', () {
    test('drops the clauses that are not there', () {
      // A label built by interpolating optional fields is otherwise full of
      // ", , " — and a screen reader announces every one as a real pause.
      expect(
        semanticsSentence(['Anna', null, '', '  ', '3 unread']),
        'Anna, 3 unread',
      );
      expect(semanticsSentence([null, '']), '');
    });
  });

  group('spelledOut', () {
    test('says a code one character at a time, in groups', () {
      // Spaces between characters is what makes an engine spell rather than
      // pronounce; the comma every four is what makes forty-eight spoken
      // letters something a person can keep up with, and gives them somewhere
      // to resume from when they lose their place.
      expect(spelledOut('EsTr7k92'), 'E s T r, 7 k 9 2');
    });

    test('does not read the grouping the string already has', () {
      // A recovery key arrives pre-grouped. "Space" read aloud eleven times is
      // eleven chances to write one down as part of the key.
      expect(spelledOut('EsTr 7k92'), spelledOut('EsTr7k92'));
    });

    test('a partial last group is still said', () {
      expect(spelledOut('abcdef'), 'a b c d, e f');
    });

    test('nothing to spell is nothing said', () {
      // Dropped by `semanticsSentence` rather than announced as a pause.
      expect(spelledOut(''), '');
      expect(spelledOut('   '), '');
    });
  });
}
