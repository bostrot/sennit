import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/call_providers.dart';
import 'package:weft/app/providers.dart';
import 'package:weft/data/demo_repository.dart';
import 'package:weft/features/chat/chat_view.dart';
import 'package:weft/services/call/call_service.dart';
import 'package:weft_call/weft_call.dart';
import 'package:weft_design/weft_design.dart';

import 'support/call_fixtures.dart';

/// Which conversations offer a call, as the app resolves it.
///
/// The predicate itself lives in `weft_call` and has its own suite; nothing here
/// re-tests the rule. What this file covers is the two things that only exist in
/// the app: the **identity graph** behind a conversation, which is what turns a
/// room into a person the `invitee` field can name, and the **button**, which
/// has to say why it is greyed out.
///
/// Disabled rather than hidden is the whole design. A call button that quietly
/// disappeared for bridged chats would read as Weft having lost the feature,
/// and the honest sentence — "WhatsApp, Signal and Telegram can't carry calls" —
/// is the only place a user learns why.
void main() {
  group('the button in a conversation', () {
    testWidgets('is disabled with a reason for a bridged conversation', (
      tester,
    ) async {
      // Anna is reachable on WhatsApp, Signal and Telegram — three rooms on the
      // user's own homeserver, none of them Matrix-native, and a bridge ghost on
      // the far end of each that will never answer an `m.call.invite`.
      await pumpChat(tester);

      final button = callButton(tester);
      expect(button.onPressed, isNull);
      expect(button.tooltip, contains("can't carry calls"));
      expect(button.tooltip, contains('WhatsApp'));
      expect(button.tooltip, contains('Matrix'));
    });

    testWidgets('is enabled for a Matrix-native one, and names the peer', (
      tester,
    ) async {
      await pumpChat(
        tester,
        availability: const CallReady(CallTarget(roomId: room, peer: annaPeer)),
      );

      final button = callButton(tester);
      expect(button.onPressed, isNotNull);
      expect(button.tooltip, 'Call Anna');
    });

    testWidgets('is disabled for a group, as a group', (tester) async {
      // "Weft calls one person at a time" stays true however the room got
      // there, so it outranks the bridging answer.
      await pumpChat(
        tester,
        availability: const CallBlocked(
          CallBlocker.group,
          'Weft calls one person at a time.',
        ),
      );

      final button = callButton(tester);
      expect(button.onPressed, isNull);
      expect(button.tooltip, 'Weft calls one person at a time.');
    });

    testWidgets('says so when there is no account behind it', (tester) async {
      // The one failure the button itself has to explain rather than swallow:
      // demo mode, or the frame before the auth gate has a session.
      await pumpChat(
        tester,
        availability: const CallReady(CallTarget(roomId: room, peer: annaPeer)),
      );

      await tester.tap(find.byIcon(Icons.call_rounded));
      await tester.pump();

      expect(
        find.text('Calling needs a signed-in Matrix account.'),
        findsOneWidget,
      );
    });

    testWidgets('places the call it offers, in the room it named', (
      tester,
    ) async {
      final harness = CallHarness();
      addTearDown(() => disposeAfterWidgetTest(harness));

      await pumpChat(
        tester,
        availability: const CallReady(CallTarget(roomId: room, peer: annaPeer)),
        service: harness.service,
      );

      await tester.tap(find.byIcon(Icons.call_rounded));
      await tester.pump();
      await tester.pump();

      final invite = harness.sink.sent.single;
      expect(invite.type, 'm.call.invite');
      expect(invite.roomId, room);
      expect(invite.content['invitee'], annaPeer.matrixUserId);
      // The button does not open the call screen — [CallOverlay] does, so a call
      // placed here and a call answered from a notification reach the same
      // screen by the same path.
      expect(find.byType(ChatView), findsOneWidget);
    });

    testWidgets('a second call is refused with a sentence, not silence', (
      tester,
    ) async {
      final harness = CallHarness();
      addTearDown(() => disposeAfterWidgetTest(harness));

      await pumpChat(
        tester,
        availability: const CallReady(CallTarget(roomId: room, peer: annaPeer)),
        service: harness.service,
      );

      await tester.tap(find.byIcon(Icons.call_rounded));
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byIcon(Icons.call_rounded));
      await tester.pump();
      await tester.pump();

      expect(find.text('You are already on a call.'), findsOneWidget);
      expect(harness.sink.types, ['m.call.invite']);
    });
  });

  group('availability, as the app resolves it', () {
    test('a Matrix DM resolves a target through the identity graph', () async {
      final container = ProviderContainer(
        overrides: [
          chatRepositoryProvider.overrideWithValue(MatrixNativeRepository()),
        ],
      );
      addTearDown(container.dispose);

      // The inbox is a stream, so before its first value every conversation is
      // "still loading" rather than callable — which is the honest answer for
      // the frame before a chat exists, and is why this is awaited. Held open
      // while it is: providers are auto-disposing, and an inbox nobody is
      // listening to is torn down before its first value.
      container.listen(chatsProvider, (_, _) {});
      await container.read(chatsProvider.future);

      final availability = container.read(
        callAvailabilityProvider(MatrixNativeRepository.chatId),
      );
      expect(availability.isAvailable, isTrue);
      expect(availability.target?.roomId, MatrixNativeRepository.chatId);
      expect(availability.target?.peer.matrixUserId, '@anna:example.org');
      expect(availability.message, 'Call Anna');
    });

    test('a group with a Matrix leg is refused as a group', () async {
      final container = ProviderContainer(
        overrides: [
          chatRepositoryProvider.overrideWithValue(MatrixNativeRepository()),
        ],
      );
      addTearDown(container.dispose);
      container.listen(chatsProvider, (_, _) {});
      await container.read(chatsProvider.future);

      final availability = container.read(
        callAvailabilityProvider(MatrixNativeRepository.groupChatId),
      );
      expect(availability.isAvailable, isFalse);
      expect((availability as CallBlocked).reason, CallBlocker.group);
    });

    test('a bridged conversation is blocked, with its networks named', () async {
      final container = ProviderContainer(
        overrides: [
          chatRepositoryProvider.overrideWithValue(DemoChatRepository()),
        ],
      );
      addTearDown(container.dispose);
      container.listen(chatsProvider, (_, _) {});
      await container.read(chatsProvider.future);

      final availability = container.read(
        callAvailabilityProvider('merged:anna'),
      );
      expect(availability.isAvailable, isFalse);
      expect((availability as CallBlocked).reason, CallBlocker.bridged);
      // Not "has a Matrix room id": every one of these bridged rooms is a room
      // on the user's own homeserver and has one.
      expect(availability.message, contains('WhatsApp'));
    });

    test(
      'a conversation the inbox has never heard of is still loading',
      () async {
        final container = ProviderContainer(
          overrides: [
            chatRepositoryProvider.overrideWithValue(DemoChatRepository()),
          ],
        );
        addTearDown(container.dispose);
        container.listen(chatsProvider, (_, _) {});
        await container.read(chatsProvider.future);

        final availability = container.read(
          callAvailabilityProvider('!nothing:example.org'),
        );
        expect((availability as CallBlocked).reason, CallBlocker.unknownPeer);
        expect(availability.message, contains('still loading'));
      },
    );
  });
}

/// The one call button in the chat view's action bar.
IconButton callButton(WidgetTester tester) => tester.widget<IconButton>(
  find.ancestor(
    of: find.byIcon(Icons.call_rounded),
    matching: find.byType(IconButton),
  ),
);

/// The chat view over the demo fixtures, which are all bridged.
///
/// [availability] and [service] are named rather than passed as an overrides
/// list because Riverpod's `Override` type is not exported from either barrel,
/// so a `List<Override>` parameter cannot be written at all — the same
/// constraint `golden_harness.dart` records.
Future<void> pumpChat(
  WidgetTester tester, {
  CallAvailability? availability,
  CallService? service,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        chatRepositoryProvider.overrideWithValue(DemoChatRepository()),
        callServiceProvider.overrideWithValue(service),
        if (availability != null)
          callAvailabilityProvider(
            'merged:anna',
          ).overrideWithValue(availability),
      ],
      child: MaterialApp(
        theme: WeftTheme.build(),
        home: const ChatView(chatId: 'merged:anna'),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
