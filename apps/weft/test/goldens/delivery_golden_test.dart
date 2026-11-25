import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/data/demo_repository.dart';
import 'package:weft/data/send_queue_source.dart';
import 'package:weft/features/chat/chat_view.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

import '../support/golden_harness.dart';
import '../support/seeded_repository.dart';

/// All five delivery states, in one column, in three renderings.
///
/// The ticks are the most-read four pixels in a messenger and the entire
/// difference between two of the five states is a *colour*: `delivered` and
/// `read` draw the same double tick and differ only in ink. That is exactly the
/// kind of distinction a string assertion cannot see and a picture can, and it
/// is why this file exists beside `receipts_and_presence_test`, which asserts
/// the icons and the colour values but not whether either survives being drawn.
///
/// **High contrast is the third variant for a specific reason.** The read tick
/// is the one colour in the app that is not derived from the theme's seed —
/// blue, because a decade of WhatsApp taught it — and it is drawn on the own
/// bubble's primary fill. `WeftContrast` corrects it against that fill, and a
/// correction that lands on "close enough to the accent to be indistinguishable"
/// is a read marker nobody can tell from a delivered one. There is no test for
/// that but an image.
void main() {
  setUpAll(loadGoldenFonts);

  /// One own message per state, **oldest furthest along**.
  ///
  /// That ordering is forced rather than chosen. A read receipt names one event
  /// and means everything before it, so a `delivered` message older than the
  /// receipted one is not delivered — it is read, and an image meant to show
  /// five distinct states would quietly show four. Which is also how a real
  /// thread reads: the message from twenty-five minutes ago has been seen and
  /// the one from five is still going.
  List<WeftMessage> everyState() => [
    seededMessage(
      eventId: r'$read',
      body: 'and they opened it',
      isOwn: true,
      minutesAgo: 25,
      deliveryState: DeliveryState.delivered,
    ),
    seededMessage(
      eventId: r'$delivered',
      body: 'it reached their phone',
      isOwn: true,
      minutesAgo: 20,
      deliveryState: DeliveryState.delivered,
    ),
    seededMessage(
      eventId: r'$sent',
      body: 'the server took it',
      isOwn: true,
      minutesAgo: 15,
      deliveryState: DeliveryState.sent,
    ),
    seededMessage(
      eventId: r'$sending',
      body: 'still going',
      isOwn: true,
      minutesAgo: 10,
      deliveryState: DeliveryState.sending,
    ),
    seededMessage(
      eventId: r'$failed',
      body: 'this one never left',
      isOwn: true,
      minutesAgo: 5,
      deliveryState: DeliveryState.failed,
    ),
  ];

  Future<void> expectGolden(
    WidgetTester tester,
    String name, {
    bool readReceipts = true,
    Map<String, SendFailure> sendFailures = const {},
  }) async {
    for (final (mode, variant, suffix) in [
      (WeftThemeMode.dark, weftGoldenBaseline, 'dark'),
      (WeftThemeMode.light, weftGoldenBaseline, 'light'),
      // The variant that matters most here — see the library comment.
      (
        WeftThemeMode.dark,
        const WeftGoldenVariant(name: 'high_contrast', highContrast: true),
        'high_contrast',
      ),
    ]) {
      final demo = DemoChatRepository(uploadTick: Duration.zero);
      addTearDown(demo.dispose);

      await pumpWeft(
        tester,
        const ChatView(chatId: 'seeded:chat'),
        repository: _ReadUpTo(
          demo,
          messages: everyState(),
          readUpTo: r'$read',
          sendFailures: sendFailures,
        ),
        size: const Size(560, 900),
        mode: mode,
        variant: variant,
        readReceipts: readReceipts,
      );

      await expectLater(
        find.byType(ChatView),
        matchesGoldenFile('${name}_$suffix.png'),
      );
    }
  }

  testWidgets('every delivery state, three renderings', (tester) async {
    await expectGolden(tester, 'delivery_states');
  });

  testWidgets('with read receipts switched off', (tester) async {
    // The same fixture and the same receipt, with the switch the other way.
    // The read message must draw two *grey* ticks: the account is not sending
    // public receipts, nearly every bridge stops relaying the other direction
    // in return, and a blue tick would be fabricated from a stale receipt.
    await expectGolden(
      tester,
      'delivery_states_no_receipts',
      readReceipts: false,
    );
  });

  testWidgets('a failed message that is waiting for the connection', (
    tester,
  ) async {
    // The clock it drew while sending, not the red mark: it has not given up,
    // it goes out by itself once the server can be reached.
    await expectGolden(
      tester,
      'delivery_states_waiting',
      sendFailures: const {r'$failed': SendFailure.offline},
    );
  });
}

/// A one-to-one chat whose peer has read up to a stated event.
class _ReadUpTo extends SeededChatRepository implements SendQueueSource {
  _ReadUpTo(
    super.inner, {
    required super.messages,
    required this.readUpTo,
    this.sendFailures = const {},
  });

  final String readUpTo;

  @override
  final Map<String, SendFailure> sendFailures;

  @override
  Stream<Map<String, SendFailure>> get sendFailureChanges =>
      const Stream.empty();

  @override
  List<({String roomId, String userId, String eventId, DateTime at})>
  peerReadUpTo(String chatId) => [
    (
      roomId: '!seeded:example.org',
      userId: '@peer:example.org',
      eventId: readUpTo,
      at: DateTime(2026, 8, 15, 16, 40),
    ),
  ];
}
