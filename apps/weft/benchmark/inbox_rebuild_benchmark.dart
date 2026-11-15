// A benchmark is a test in everything but its directory.
// ignore_for_file: invalid_use_of_visible_for_testing_member

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart' as sdk;
import 'package:weft/data/matrix_chat_repository.dart';
import 'package:weft_matrix/weft_matrix.dart';
import 'package:weft_store/weft_store.dart';

/// What one sync costs the inbox, before anything is drawn.
///
///   cd apps/weft
///   flutter test benchmark/inbox_rebuild_benchmark.dart
///
/// `MatrixChatRepository` refolds every room into the inbox after each sync,
/// on the UI isolate. This builds an account of [_rooms] bridged direct chats
/// over a client that never touches a network and times that refold when
/// nothing has changed — which is what nearly every sync is.
const int _rooms = 2000;

class _OfflineSession extends WeftMatrixSession {
  _OfflineSession(this._client);

  final sdk.Client _client;

  @override
  sdk.Client get client => _client;

  @override
  bool get isInitialized => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('refolding $_rooms rooms after a sync that changed nothing', () async {
    final client = sdk.Client(
      'weft-rebuild-bench',
      database: await sdk.MatrixSdkDatabase.init(
        'weft-rebuild-bench',
        database: await openWeftSqfliteDatabase(inMemoryDatabasePath),
      ),
    );

    const networks = ['whatsapp', 'signal', 'telegram'];
    for (var i = 0; i < _rooms; i++) {
      final network = networks[i % networks.length];
      final peer = '@${network}_4915100${10000 + i}:example.org';
      final room = sdk.Room(
        id: '!room$i:example.org',
        client: client,
        notificationCount: i % 9 == 0 ? 2 : 0,
        summary: sdk.RoomSummary.fromJson({
          'm.joined_member_count': 3,
          'm.invited_member_count': 0,
          'm.heroes': [peer, '@${network}bot:example.org'],
        }),
      );
      room.setState(
        sdk.Event(
          type: sdk.EventTypes.RoomMember,
          stateKey: peer,
          content: {
            'membership': 'join',
            'displayname':
                'Contact $i (${network == 'whatsapp' ? 'WA' : network})',
            'avatar_url': 'mxc://example.org/avatar$i',
          },
          eventId: '\$member$i',
          senderId: peer,
          originServerTs: DateTime(2026, 5, 1, 9),
          room: room,
        ),
      );
      room.setState(
        sdk.Event(
          type: 'm.bridge',
          stateKey: 'net.maunium.$network',
          content: {
            'bridgebot': '@${network}bot:example.org',
            'protocol': {'id': network},
          },
          eventId: '\$bridge$i',
          senderId: '@${network}bot:example.org',
          originServerTs: DateTime(2026, 5, 1, 9),
          room: room,
        ),
      );
      room.lastEvent = sdk.Event(
        type: sdk.EventTypes.Message,
        content: {'msgtype': 'm.text', 'body': 'Message $i, see you Thursday'},
        eventId: '\$last$i',
        senderId: peer,
        originServerTs: DateTime(2026, 5, 2).add(Duration(minutes: i)),
        room: room,
      );
      client.rooms.add(room);
    }

    final db = WeftDatabase.openAt(':memory:');
    addTearDown(db.dispose);
    final repository = MatrixChatRepository(
      _OfflineSession(client),
      store: IdentityStore(db),
    );
    addTearDown(repository.dispose);

    // The first passes settle handles, merges and caches; a real session is
    // long past them by the time anyone scrolls.
    for (var i = 0; i < 3; i++) {
      repository.debugRebuild();
    }

    final runs = <double>[];
    for (var i = 0; i < 15; i++) {
      final clock = Stopwatch()..start();
      repository.debugRebuild();
      runs.add(clock.elapsedMicroseconds / 1000);
    }
    runs.sort();

    final chats = await repository.watchChats().first;
    // ignore: avoid_print
    print(
      'BENCH inbox_rebuild $_rooms rooms -> ${chats.length} chats: '
      'median ${runs[runs.length ~/ 2].toStringAsFixed(2)}ms, '
      'min ${runs.first.toStringAsFixed(2)}ms, '
      'max ${runs.last.toStringAsFixed(2)}ms',
    );
    expect(chats, isNotEmpty);
  });
}
