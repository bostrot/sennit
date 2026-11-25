import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/intents.dart';
import 'package:weft/app/localisation.dart';
import 'package:weft/data/chat_repository.dart';
import 'package:weft/data/demo_repository.dart';
import 'package:weft/data/room_joiner.dart';
import 'package:weft/features/chat/room_link.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

/// Tapping a matrix.to or `matrix:` link to a room opens it, or offers to
/// join it.
void main() {
  group('parsing', () {
    test('matrix.to aliases and ids, with their via servers', () {
      expect(
        WeftLink.parse('https://matrix.to/#/#sennit:example.org'),
        const OpenRoomLink('#sennit:example.org'),
      );
      expect(
        WeftLink.parse(
          'https://matrix.to/#/%21abc%3Aexample.org?via=example.org&via=other.net',
        ),
        const OpenRoomLink(
          '!abc:example.org',
          via: ['example.org', 'other.net'],
        ),
      );
      // An event permalink still lands in its room.
      expect(
        WeftLink.parse(
          'https://matrix.to/#/!abc:example.org/\$event?via=hs.io',
        ),
        const OpenRoomLink('!abc:example.org', via: ['hs.io']),
      );
    });

    test('matrix: uris', () {
      expect(
        WeftLink.parse('matrix:r/sennit:example.org'),
        const OpenRoomLink('#sennit:example.org'),
      );
      expect(
        WeftLink.parse('matrix:roomid/abc:example.org?via=example.org'),
        const OpenRoomLink('!abc:example.org', via: ['example.org']),
      );
    });

    test('users and other links are not room links', () {
      expect(
        OpenRoomLink.tryParse('https://matrix.to/#/@ada:example.org'),
        isNull,
      );
      expect(OpenRoomLink.tryParse('matrix:u/ada:example.org'), isNull);
      expect(OpenRoomLink.tryParse('https://example.org/#/#room:x'), isNull);
      expect(OpenRoomLink.tryParse('https://matrix.to/#/'), isNull);
    });
  });

  group('opening', () {
    late List<String> opened;

    setUp(() => opened = []);

    Future<void> pump(
      WidgetTester tester,
      ChatRepository repository,
      OpenRoomLink link,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: weftLocalizationsDelegates,
          supportedLocales: weftSupportedLocales,
          theme: WeftTheme.build(brightness: Brightness.light),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => openRoomLink(
                  context,
                  repository: repository,
                  link: link,
                  open: opened.add,
                ),
                child: const Text('link'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('link'));
      await tester.pumpAndSettle();
    }

    testWidgets('a room already in the inbox opens without asking', (
      tester,
    ) async {
      final repository = _JoiningRepository()
        ..known['#here:example.org'] = 'chat-here';
      await pump(tester, repository, const OpenRoomLink('#here:example.org'));

      expect(opened, ['chat-here']);
      expect(find.byType(AlertDialog), findsNothing);
      expect(repository.joined, isEmpty);
    });

    testWidgets('a new room asks first, then joins through the via servers', (
      tester,
    ) async {
      final repository = _JoiningRepository();
      await pump(
        tester,
        repository,
        const OpenRoomLink('!new:example.org', via: ['hs.io']),
      );

      expect(find.text('Join this room?'), findsOneWidget);
      expect(find.text('!new:example.org'), findsOneWidget);
      expect(repository.joined, isEmpty);

      await tester.tap(find.text('Join'));
      await tester.pumpAndSettle();

      expect(repository.joined, ['!new:example.org via hs.io']);
      expect(opened, ['joined:!new:example.org']);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('cancel joins nothing', (tester) async {
      final repository = _JoiningRepository();
      await pump(tester, repository, const OpenRoomLink('#new:example.org'));
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(repository.joined, isEmpty);
      expect(opened, isEmpty);
    });

    testWidgets('a refused join says so and can be tried again', (
      tester,
    ) async {
      final repository = _JoiningRepository()..refuse = true;
      await pump(tester, repository, const OpenRoomLink('#closed:example.org'));
      await tester.tap(find.text('Join'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Couldn’t join'), findsOneWidget);
      expect(opened, isEmpty);

      repository.refuse = false;
      await tester.tap(find.text('Join'));
      await tester.pumpAndSettle();
      expect(opened, ['joined:#closed:example.org']);
    });

    testWidgets(
      'without an account to join with, it says the room is not here',
      (tester) async {
        final repository = DemoChatRepository(uploadTick: Duration.zero);
        addTearDown(repository.dispose);
        await pump(tester, repository, const OpenRoomLink('#new:example.org'));

        expect(find.byType(AlertDialog), findsNothing);
        expect(
          find.text('That conversation is not in your inbox.'),
          findsOneWidget,
        );
      },
    );
  });
}

class _JoiningRepository extends DemoChatRepository implements RoomJoiner {
  _JoiningRepository() : super(uploadTick: Duration.zero);

  final Map<String, String> known = {};
  final List<String> joined = [];
  bool refuse = false;

  @override
  Chat? chatForRoomLink(String roomIdOrAlias) {
    final id = known[roomIdOrAlias];
    return id == null ? null : Chat(id: id, title: id, sources: const []);
  }

  @override
  Future<String> joinRoom(
    String roomIdOrAlias, {
    List<String> via = const [],
  }) async {
    if (refuse) throw Exception('M_FORBIDDEN');
    joined.add(
      [roomIdOrAlias, if (via.isNotEmpty) 'via ${via.join(',')}'].join(' '),
    );
    return 'joined:$roomIdOrAlias';
  }
}
