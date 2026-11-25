import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

import 'package:weft/app/design_strings.dart';
import 'package:weft/app/localisation.dart';
import 'package:weft/data/demo_repository.dart';

import '../support/golden_harness.dart';

/// The inbox row of a conversation with unsent text, as a picture: the label
/// in its warning colour, the draft after it, and no delivery tick — in both
/// directions, since the label leads the line.
void main() {
  setUpAll(loadGoldenFonts);

  Chat chat(String title) => Chat(
    id: 'chat:anna',
    title: title,
    sources: const [
      ChatSource(roomId: '!signal:example.org', network: ChatNetwork.signal),
    ],
    lastMessage: WeftMessage(
      eventId: r'$last',
      roomId: '!signal:example.org',
      network: ChatNetwork.signal,
      senderId: '@me:example.org',
      senderName: 'Me',
      timestamp: DemoChatRepository.fixtureNow,
      kind: MessageKind.text,
      isOwn: true,
      body: 'sent earlier',
      deliveryState: DeliveryState.read,
    ),
  );

  Widget scene(Chat chat, String draft) => Builder(
    builder: (context) => WeftDesignStringsScope(
      strings: weftDesignStringsFrom(context.l10n),
      child: Scaffold(
        body: Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: 420,
            child: ChatTile(
              chat: chat,
              onTap: () {},
              timeLabel: '14:32',
              draft: draft,
            ),
          ),
        ),
      ),
    ),
  );

  testWidgets('a draft row, left to right', (tester) async {
    await pumpWeft(
      tester,
      scene(chat('Anna Maven'), 'are we still on for six? I can bring'),
      size: const Size(460, 140),
    );
    await expectLater(
      find.byType(ChatTile),
      matchesGoldenFile('draft_preview_ltr.png'),
    );
  });

  testWidgets('a draft row, right to left', (tester) async {
    await pumpWeft(
      tester,
      scene(chat('آنا مافن'), 'هل ما زلنا على موعد الساعة السادسة؟'),
      size: const Size(460, 140),
      variant: const WeftGoldenVariant(name: 'rtl', locale: Locale('ar')),
    );
    await expectLater(
      find.byType(ChatTile),
      matchesGoldenFile('draft_preview_rtl.png'),
    );
  });
}
