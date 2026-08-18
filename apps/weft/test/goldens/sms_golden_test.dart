import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_sms/weft_sms.dart';

import 'package:weft/data/demo_repository.dart';
import 'package:weft/features/chat/chat_view.dart';

import '../support/golden_harness.dart';
import '../support/seeded_repository.dart';

/// Goldens for the SMS conversation built in Phase 06.
///
/// The whole reason SMS needs a picture and the other networks do not is that
/// it is the one conversation in Weft that is *not* encrypted and the one that
/// *costs money*, and both facts are carried by a strip of small text above the
/// text field. An assertion can prove the words are in the tree; only an image
/// can show whether they read as a warning or as chrome — and whether they
/// still do once a two-line composer, a network chip and a keyboard-height
/// safe area are competing for the same edge.
///
/// Captured inside [ChatView] rather than on a bare Scaffold, for the reason
/// the attachment goldens state: the bar takes its surface and its divider from
/// the composer around it, and an image of it alone would pass unchanged
/// through exactly the regression it exists to catch.
void main() {
  setUpAll(loadGoldenFonts);

  late DemoChatRepository demo;

  setUp(() => demo = DemoChatRepository(uploadTick: Duration.zero));
  tearDown(() => demo.dispose());

  const threadId = 'sms:thread:7';
  const number = '+441234567890';
  final parsed = const PhoneNumberParser().parse(number)!;
  final sentAt = DateTime(2026, 8, 18, 14);

  /// One row of the system SMS provider, as the repository hands it on.
  ///
  /// Ids are minted with `weft_sms`'s own helpers rather than written out, so
  /// an image here goes stale the moment the synthetic-id scheme changes
  /// instead of quietly drawing a shape the app no longer produces.
  WeftMessage sms({
    required String id,
    required String body,
    required int minutesAgo,
    bool isOwn = false,
    DeliveryState? delivery,
  }) => WeftMessage(
    eventId: smsEventId(id),
    roomId: smsRoomId('7'),
    network: ChatNetwork.sms,
    senderId: isOwn ? '@me:local' : smsGhostUserId(parsed),
    senderName: isOwn ? 'You' : number,
    timestamp: sentAt.subtract(Duration(minutes: minutesAgo)),
    kind: MessageKind.text,
    isOwn: isOwn,
    body: body,
    deliveryState: delivery,
  );

  final history = [
    sms(id: '11', body: 'landed, waiting on the bags', minutesAgo: 24),
    sms(
      id: '12',
      body: 'no rush — I am parked in the short stay',
      minutesAgo: 21,
      isOwn: true,
      delivery: DeliveryState.delivered,
    ),
    sms(id: '13', body: 'see you at six then', minutesAgo: 8),
    // A message the radio never acknowledged. SMS has no read receipts at all,
    // so `failed` and `sending` are the only two ticks that can ever differ
    // from `sent` here, and the failed one has to be findable at a glance.
    sms(
      id: '14',
      body: 'on my way',
      minutesAgo: 2,
      isOwn: true,
      delivery: DeliveryState.failed,
    ),
  ];

  /// Pumps the SMS thread and captures it under [name] in both themes.
  ///
  /// [typed] is entered into the composer before the shot, because the bar's
  /// resting state and its counting state are different sentences: "160 left"
  /// is reassurance and "2 messages · UCS-2" is a bill, and they have to be
  /// legible in the same strip.
  Future<void> expectSmsGolden(
    WidgetTester tester,
    String name, {
    String? typed,
    // Phone-height rather than the 820 the other chat goldens take: a
    // four-message thread anchors to the bottom, so the extra 200 pixels are
    // empty surface above "Beginning of the conversation" — and the whole
    // subject of these two images is the strip at the *other* end.
    Size size = const Size(560, 620),
  }) async {
    for (final (mode, suffix) in const [
      (WeftThemeMode.dark, 'dark'),
      (WeftThemeMode.light, 'light'),
    ]) {
      final repository = SeededChatRepository(
        demo,
        messages: history,
        chatId: threadId,
        title: number,
      );

      await pumpWeft(
        tester,
        // Keyed by the theme so the second pump builds a new [ChatView] state
        // rather than reusing the first one's composer text.
        ChatView(key: ValueKey(suffix), chatId: threadId),
        size: size,
        mode: mode,
        repository: repository,
      );

      if (typed != null) {
        await tester.enterText(find.byType(TextField), typed);
        await tester.pumpAndSettle();
      }

      await expectLater(
        find.byType(ChatView),
        matchesGoldenFile('${name}_$suffix.png'),
      );
    }
  }

  testWidgets('an SMS thread says it is not encrypted, both themes', (
    tester,
  ) async {
    // The resting state, which is the one most users will ever see: nothing
    // typed, and the bar already saying the two things that are true before a
    // character exists.
    await expectSmsGolden(tester, 'sms_conversation');
  });

  testWidgets('the segment warning, both themes', (tester) async {
    // One curly quote past a hundred characters — the single most common way a
    // message someone thought was free becomes billable ones — so the strip is
    // carrying a count, an encoding name and the plaintext warning at once.
    // That is the crowded case, and the only one where the row can overflow.
    await expectSmsGolden(
      tester,
      'sms_segments',
      typed:
          'we should be able to get everyone in one car if Ravi doesn’t '
          'bring the big bag again',
    );
  });
}
