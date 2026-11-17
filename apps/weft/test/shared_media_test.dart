import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/localisation.dart';
import 'package:weft/app/providers.dart';
import 'package:weft/features/chat/attachment_bubble.dart';
import 'package:weft/features/chat/chat_view.dart';
import 'package:weft/features/chat/media_gallery.dart';
import 'package:weft/features/chat/media_viewer.dart';
import 'package:weft/features/chat/rich_text_view.dart';
import 'package:weft/features/contact/contact_profile.dart';
import 'package:weft/features/contact/shared_media.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

import 'support/attachment_fixtures.dart';

/// The chat info screen's Media and Links sections, and the header that opens
/// the screen.
void main() {
  const chatId = 'merged:anna';
  const roomId = '!anna:example.org';
  final start = DateTime(2026, 11, 2, 9);

  /// The [n]th message of the conversation, [n] minutes after [start].
  WeftMessage message(
    int n, {
    MessageKind kind = MessageKind.image,
    String? body,
    bool redacted = false,
  }) => WeftMessage(
    eventId: '\$m$n',
    roomId: roomId,
    network: ChatNetwork.matrix,
    senderId: '@anna:example.org',
    senderName: 'Anna',
    timestamp: start.add(Duration(minutes: n)),
    kind: kind,
    isOwn: false,
    body: body ?? 'IMG_$n.jpg',
    attachmentUrl: kind == MessageKind.text ? null : 'mxc://example.org/$n',
    redacted: redacted,
  );

  /// Oldest first, as a conversation is read.
  List<WeftMessage> history() => [
    message(1),
    message(2, kind: MessageKind.text, body: 'see https://example.org/a.'),
    message(3, kind: MessageKind.video, body: 'clip.mp4'),
    message(4, kind: MessageKind.sticker, body: 'sticker.webp'),
    message(
      5,
      kind: MessageKind.text,
      body: 'both https://example.org/a and https://example.org/b',
    ),
    message(6),
    message(7, redacted: true),
  ];

  setUp(clearMessageDocumentCache);

  group('SharedContent.of', () {
    test('keeps photos and videos, oldest first, and no stickers', () {
      final content = SharedContent.of(history().reversed.toList());
      expect(content.media.map((m) => m.eventId), [r'$m1', r'$m3', r'$m6']);
    });

    test('lists each link once, newest first', () {
      final content = SharedContent.of(history().reversed.toList());
      expect(content.links.map((l) => l.url), [
        'https://example.org/a',
        'https://example.org/b',
      ]);
      expect(
        content.links.first.message.eventId,
        r'$m5',
        reason: 'the row belongs to the latest time the link was sent',
      );
    });

    test('a conversation with nothing shared is empty', () {
      final content = SharedContent.of([
        message(1, kind: MessageKind.text, body: 'hello'),
      ]);
      expect(content.isEmpty, isTrue);
    });
  });

  group('ContactProfileScreen', () {
    late StubChatRepository repository;
    late List<String> launched;

    setUp(() {
      repository = StubChatRepository(bytes: kPixel, history: history());
      launched = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/url_launcher'),
            (call) async {
              if (call.method == 'launch') {
                launched.add((call.arguments as Map)['url']! as String);
              }
              return true;
            },
          );
    });

    tearDown(() {
      repository.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/url_launcher'),
            null,
          );
    });

    Future<void> pump(WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [chatRepositoryProvider.overrideWithValue(repository)],
          child: MaterialApp(
            localizationsDelegates: weftLocalizationsDelegates,
            theme: WeftTheme.build(),
            home: const ContactProfileScreen(chatId: chatId),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('shows the shared photos and videos, newest first', (
      tester,
    ) async {
      await pump(tester);

      expect(find.text('Media'), findsOneWidget);
      final strip = find.byType(SharedMediaStrip);
      final tiles = find.descendant(
        of: strip,
        matching: find.byType(MediaTile),
      );
      expect(tiles, findsNWidgets(3));
      expect(
        tester.widgetList<MediaTile>(tiles).map((t) => t.message.eventId),
        [r'$m6', r'$m3', r'$m1'],
      );
      expect(
        find.descendant(of: strip, matching: find.byType(PlayBadge)),
        findsOneWidget,
        reason: 'the video, and only the video, carries a play badge',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a thumbnail opens the viewer on that item', (tester) async {
      await pump(tester);

      final newest = find
          .descendant(
            of: find.byType(SharedMediaStrip),
            matching: find.byType(MediaTile),
          )
          .first;
      await tester.ensureVisible(newest);
      await tester.pumpAndSettle();
      await tester.tap(newest);
      // Pumped rather than settled: the viewer never settles under this
      // fixture, and the route is all this test is about.
      await tester.pump();
      await tester.pump(WeftMotion.normal);

      final viewer = tester.widget<MediaViewer>(find.byType(MediaViewer));
      expect(viewer.items.map((m) => m.eventId), [r'$m1', r'$m3', r'$m6']);
      expect(viewer.items[viewer.initialIndex].eventId, r'$m6');
    });

    testWidgets('See all opens every item as a grid', (tester) async {
      await pump(tester);

      final seeAll = find.bySemanticsLabel('See all 3 photos and videos');
      await tester.ensureVisible(seeAll);
      await tester.pumpAndSettle();
      await tester.tap(seeAll);
      await tester.pumpAndSettle();

      expect(find.byType(SharedMediaScreen), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(GridView),
          matching: find.byType(MediaTile),
        ),
        findsNWidgets(3),
      );
    });

    testWidgets('lists the shared links and opens one on tap', (tester) async {
      await pump(tester);

      final first = find.text('https://example.org/a');
      // The profile's own list, not the strip of thumbnails inside it.
      await tester.dragUntilVisible(
        first,
        find.byType(ListView).first,
        const Offset(0, -200),
      );
      await tester.pumpAndSettle();
      expect(find.text('Links'), findsOneWidget);
      expect(find.byType(SharedLinkTile), findsNWidgets(2));
      expect(
        find.bySemanticsLabel(RegExp('See all .* links')),
        findsNothing,
        reason: 'two links are already all of them',
      );

      await tester.tap(first);
      await tester.pumpAndSettle();
      expect(launched, ['https://example.org/a']);
    });

    testWidgets('a conversation with nothing shared shows neither section', (
      tester,
    ) async {
      repository = StubChatRepository(
        bytes: kPixel,
        history: [message(1, kind: MessageKind.text, body: 'hello')],
      );
      await pump(tester);

      expect(find.text('Media'), findsNothing);
      expect(find.text('Links'), findsNothing);
    });
  });

  group('the chat header', () {
    late StubChatRepository repository;

    setUp(() => repository = StubChatRepository(history: history()));
    tearDown(() => repository.dispose());

    Future<void> pump(
      WidgetTester tester, {
      WeftSurface? surface,
      bool preview = false,
    }) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [chatRepositoryProvider.overrideWithValue(repository)],
          child: MaterialApp(
            localizationsDelegates: weftLocalizationsDelegates,
            theme: surface == null
                ? WeftTheme.build()
                : WeftTheme.build(surface: surface),
            home: ChatView(chatId: chatId, preview: preview),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    /// The conversation's name as the header draws it.
    Finder title(WidgetTester tester) {
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ChatView)),
      );
      final chat = container
          .read(chatsProvider)
          .value!
          .firstWhere((c) => c.id == chatId);
      return find.text(chat.title).first;
    }

    testWidgets('tapping the name opens the contact profile', (tester) async {
      await pump(tester);

      await tester.tap(title(tester));
      await tester.pumpAndSettle();

      expect(find.byType(ContactProfileScreen), findsOneWidget);
    });

    testWidgets('so does tapping the name on the Mac toolbar', (tester) async {
      await pump(tester, surface: WeftSurface.mac);

      await tester.tap(title(tester));
      await tester.pumpAndSettle();

      expect(find.byType(ContactProfileScreen), findsOneWidget);
    });

    testWidgets('the whole title is one heading that says what it opens', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await pump(tester);

      final node = tester.getSemantics(title(tester));
      expect(node.hint, 'Contact details');
      expect(node.flagsCollection.isHeader, isTrue);
      expect(node.flagsCollection.isButton, isTrue);
      semantics.dispose();
    });

    testWidgets('a preview opens nothing', (tester) async {
      await pump(tester, preview: true);

      await tester.tap(title(tester));
      await tester.pumpAndSettle();

      expect(find.byType(ContactProfileScreen), findsNothing);
    });
  });
}
