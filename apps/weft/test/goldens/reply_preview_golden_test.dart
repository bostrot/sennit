import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

import 'package:weft/app/design_strings.dart';
import 'package:weft/app/localisation.dart';
import 'package:weft/data/demo_repository.dart';

import '../support/golden_harness.dart';

/// The inbox row for a reply, as a picture.
///
/// The behavioural half of this — that the mxid never reaches the row, that the
/// marker follows the relation rather than the body — is
/// `packages/weft_design/test/reply_preview_test.dart`, which asserts strings
/// and a glyph. What a string assertion cannot see is the thing that made the
/// bug so easy to miss in review: the fallback is *longer than the row*, so a
/// preview showing `> <@signal_1234:beeper.local> …` was a full, plausible line
/// of text that simply happened to be somebody else's. These images are where
/// that is obvious.
///
/// Two directions, because the marker leads the preview line and "leading" is a
/// different side in each. An Arabic golden with the arrow still pinned to the
/// physical left is a row nobody would draw on purpose and a test that would
/// otherwise pass.
void main() {
  setUpAll(loadGoldenFonts);

  Chat replyChat({required String body, required String title}) => Chat(
    id: 'chat:anna',
    title: title,
    sources: const [
      ChatSource(roomId: '!signal:example.org', network: ChatNetwork.signal),
    ],
    unreadCount: 2,
    lastMessage: WeftMessage(
      eventId: r'$last',
      roomId: '!signal:example.org',
      network: ChatNetwork.signal,
      senderId: '@anna:example.org',
      senderName: 'Anna Maven',
      timestamp: DemoChatRepository.fixtureNow,
      kind: MessageKind.text,
      isOwn: false,
      body: body,
      replyToEventId: r'$quoted',
    ),
  );

  /// The row under the app's own words, which is how it is drawn in the app —
  /// `main.dart` installs the scope near the root. Without it the tile would
  /// fall back to English inside an Arabic image.
  Widget scene(Chat chat) => Builder(
    builder: (context) => WeftDesignStringsScope(
      strings: weftDesignStringsFrom(context.l10n),
      child: Scaffold(
        body: Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: 420,
            child: ChatTile(chat: chat, onTap: () {}, timeLabel: '14:32'),
          ),
        ),
      ),
    ),
  );

  testWidgets('a reply row, left to right', (tester) async {
    await pumpWeft(
      tester,
      scene(
        replyChat(
          title: 'Anna Maven',
          body:
              '> <@signal_1234:beeper.local> are we still on for six?\n'
              '\n'
              'yes, see you then',
        ),
      ),
      size: const Size(460, 140),
    );

    await expectLater(
      find.byType(ChatTile),
      matchesGoldenFile('reply_preview_ltr.png'),
    );
  });

  testWidgets('a reply row, right to left', (tester) async {
    await pumpWeft(
      tester,
      scene(
        replyChat(
          title: 'آنا مافن',
          body:
              '> <@signal_1234:beeper.local> هل ما زلنا على موعد الساعة السادسة؟\n'
              '\n'
              'نعم، أراك حينها',
        ),
      ),
      size: const Size(460, 140),
      variant: const WeftGoldenVariant(name: 'rtl', locale: Locale('ar')),
    );

    await expectLater(
      find.byType(ChatTile),
      matchesGoldenFile('reply_preview_rtl.png'),
    );
  });

  testWidgets('a reply that quoted and said nothing of its own', (
    tester,
  ) async {
    // The edge case with no text to fall back on. It has to read as a message
    // rather than as an empty conversation, and it must not read as the mxid.
    await pumpWeft(
      tester,
      scene(
        replyChat(
          title: 'Anna Maven',
          body: '> <@signal_1234:beeper.local> are we still on for six?\n',
        ),
      ),
      size: const Size(460, 140),
    );

    await expectLater(
      find.byType(ChatTile),
      matchesGoldenFile('reply_preview_empty.png'),
    );
  });
}
