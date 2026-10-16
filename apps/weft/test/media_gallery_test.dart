import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/localisation.dart';
import 'package:weft/app/providers.dart';
import 'package:weft/features/chat/attachment_bubble.dart';
import 'package:weft/features/chat/chat_view.dart';
import 'package:weft/features/chat/media_gallery.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

import 'support/attachment_fixtures.dart';

void main() {
  const roomId = '!design_room:example.org';
  final start = DateTime(2026, 8, 11, 18, 45);

  /// The [n]th message of a batch, [n] seconds after [start].
  WeftMessage photo(
    int n, {
    String sender = '@anna:example.org',
    Duration after = Duration.zero,
    String body = 'IMG_0001.jpg',
    String? attachmentName,
    MessageKind kind = MessageKind.image,
    String? replyTo,
    DeliveryState? delivery,
  }) => WeftMessage(
    eventId: '\$photo$n',
    roomId: roomId,
    network: ChatNetwork.matrix,
    senderId: sender,
    senderName: 'Anna',
    timestamp: start.add(Duration(seconds: n)).add(after),
    kind: kind,
    isOwn: false,
    body: body,
    attachmentName: attachmentName,
    attachmentUrl: kind == MessageKind.text ? null : 'mxc://example.org/$n',
    replyToEventId: replyTo,
    deliveryState: delivery,
  );

  /// Newest first, as the timeline hands them to the list.
  List<WeftMessage> newestFirst(List<WeftMessage> readingOrder) =>
      readingOrder.reversed.toList();

  group('galleryLayout', () {
    test('four or more photos in a row become one album', () {
      final batch = [for (var i = 1; i <= 5; i++) photo(i)];
      final layout = galleryLayout(newestFirst(batch));

      expect(layout.runs.keys, [0]);
      final run = layout.runs[0]!;
      expect(run.items.map((m) => m.eventId), batch.map((m) => m.eventId));
      expect(run.oldestIndex, 4);
      expect(layout.hidden, {1, 2, 3, 4});
    });

    test('three photos stay bubbles of their own', () {
      final layout = galleryLayout(
        newestFirst([for (var i = 1; i <= 3; i++) photo(i)]),
      );
      expect(layout.runs, isEmpty);
      expect(layout.hidden, isEmpty);
    });

    test('a captioned photo stands alone and splits the batch', () {
      final layout = galleryLayout(
        newestFirst([
          for (var i = 1; i <= 4; i++) photo(i),
          photo(5, body: 'the receipt', attachmentName: 'IMG_5.jpg'),
          for (var i = 6; i <= 8; i++) photo(i),
        ]),
      );
      // Newest first: 8,7,6 (three, too few), then the caption, then 4..1.
      expect(layout.runs.keys, [4]);
      expect(layout.runs[4]!.items.first.eventId, '\$photo1');
      expect(layout.hidden, {5, 6, 7});
    });

    test('another sender, a long pause or a text breaks the run', () {
      final otherSender = galleryLayout(
        newestFirst([
          photo(1),
          photo(2),
          photo(3, sender: '@ben:example.org'),
          photo(4),
          photo(5),
        ]),
      );
      expect(otherSender.runs, isEmpty);

      final pause = galleryLayout(
        newestFirst([
          photo(1),
          photo(2),
          photo(3, after: const Duration(minutes: 3)),
          photo(4, after: const Duration(minutes: 3)),
        ]),
      );
      expect(pause.runs, isEmpty);

      final text = galleryLayout(
        newestFirst([
          photo(1),
          photo(2),
          photo(3, kind: MessageKind.text, body: 'look'),
          photo(4),
          photo(5),
        ]),
      );
      expect(text.runs, isEmpty);
    });

    test('replies, videos and anything the caller holds back stand alone', () {
      expect(galleryEligible(photo(1, replyTo: '\$earlier')), isFalse);
      expect(galleryEligible(photo(1, kind: MessageKind.video)), isFalse);
      expect(
        galleryEligible(photo(1, delivery: DeliveryState.failed)),
        isFalse,
      );
      expect(
        galleryEligible(photo(1, delivery: DeliveryState.sending)),
        isTrue,
      );
      expect(galleryEligible(photo(1)), isTrue);

      final batch = newestFirst([for (var i = 1; i <= 4; i++) photo(i)]);
      final held = galleryLayout(
        batch,
        standsAlone: (m) => m.eventId == '\$photo2',
      );
      expect(held.runs, isEmpty);
    });
  });

  group('MediaGallery', () {
    Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
      ProviderScope(
        overrides: [
          chatRepositoryProvider.overrideWithValue(
            StubChatRepository(bytes: kPixel),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: weftLocalizationsDelegates,
          theme: WeftTheme.build(),
          home: Scaffold(body: Center(child: child)),
        ),
      ),
    );

    testWidgets('shows four tiles and counts the rest on the last', (
      tester,
    ) async {
      final items = [for (var i = 1; i <= 13; i++) photo(i)];
      await pump(tester, MediaGallery(items: items));
      await tester.pumpAndSettle();

      expect(find.byType(Image), findsNWidgets(4));
      expect(find.text('+9'), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp(r'^Photo 4 of 13, 9 more')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('exactly four photos carry no count', (tester) async {
      await pump(
        tester,
        MediaGallery(items: [for (var i = 1; i <= 4; i++) photo(i)]),
      );
      await tester.pumpAndSettle();

      expect(find.byType(Image), findsNWidgets(4));
      expect(find.textContaining('+'), findsNothing);
    });

    testWidgets('a tap opens that photo and a long press acts on it', (
      tester,
    ) async {
      final items = [for (var i = 1; i <= 6; i++) photo(i)];
      WeftMessage? opened;
      WeftMessage? acted;
      await pump(
        tester,
        MediaGallery(
          items: items,
          onOpen: (m) => opened = m,
          onActions: (m) => acted = m,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(Image).at(1));
      expect(opened?.eventId, '\$photo2');

      await tester.longPress(find.byType(Image).at(3));
      expect(acted?.eventId, '\$photo4');
    });
  });

  testWidgets('a chat draws a batch of photos as one album', (tester) async {
    final repository = StubChatRepository(
      bytes: kPixel,
      history: [
        for (var i = 1; i <= 6; i++) photo(i),
        photo(7, kind: MessageKind.text, body: 'Here are the pictures'),
      ],
    );
    addTearDown(repository.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [chatRepositoryProvider.overrideWithValue(repository)],
        child: MaterialApp(
          localizationsDelegates: weftLocalizationsDelegates,
          theme: WeftTheme.build(),
          home: const ChatView(chatId: roomId),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(MediaGallery), findsOneWidget);
    expect(find.byType(MediaAttachment), findsNothing);
    expect(find.text('+2'), findsOneWidget);
    expect(find.text('Here are the pictures'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
