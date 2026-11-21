// ignore_for_file: invalid_use_of_visible_for_testing_member

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart' as sdk;
import 'package:weft/data/matrix_chat_repository.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_matrix/weft_matrix.dart';
import 'package:weft_store/weft_store.dart';

/// What a sync that changed nothing writes to the identity store: nothing.
///
/// Every handle write marks the handles dirty, and a dirty rebuild scores
/// every pair of handles for a merge — over half a second on the UI thread on
/// an account of a few hundred contacts. A person who is the peer of two
/// rooms (an old DM beside the bridge's portal, say) used to be written once
/// per room, naming each room in turn, so every rebuild "changed" them and
/// paid for the whole merge pass after every sync.
class _OfflineSession extends WeftMatrixSession {
  _OfflineSession(this._client);

  final sdk.Client _client;

  @override
  sdk.Client get client => _client;

  @override
  bool get isInitialized => true;
}

class _SignedInClient extends sdk.Client {
  _SignedInClient(super.clientName, {required super.database});

  @override
  String? get userID => '@me:example.org';
}

class _CountingStore extends IdentityStore {
  _CountingStore(super.db);

  final List<NetworkHandle> writes = [];

  @override
  void upsertHandle(NetworkHandle handle) {
    writes.add(handle);
    super.upsertHandle(handle);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const peer = '@whatsapp_4915100012345:example.org';

  sdk.Room dm(sdk.Client client, String roomId, String name) {
    final room = sdk.Room(
      id: roomId,
      client: client,
      summary: sdk.RoomSummary.fromJson({
        'm.joined_member_count': 2,
        'm.invited_member_count': 0,
        'm.heroes': [peer],
      }),
    );
    // A different name in each room, as a bridge's per-room member events
    // often give.
    room.setState(
      sdk.Event(
        type: sdk.EventTypes.RoomMember,
        stateKey: peer,
        content: {'membership': 'join', 'displayname': name},
        eventId: '\$member_$roomId',
        senderId: peer,
        originServerTs: DateTime(2026, 5, 1, 9),
        room: room,
      ),
    );
    return room;
  }

  test('a peer of two rooms is written once, and not again by a quiet '
      'rebuild', () async {
    final client = _SignedInClient(
      'identity-refresh',
      database: await sdk.MatrixSdkDatabase.init(
        'identity-refresh',
        database: await openWeftSqfliteDatabase(inMemoryDatabasePath),
      ),
    );
    client.rooms
      ..add(dm(client, '!old:example.org', 'Anna'))
      ..add(dm(client, '!portal:example.org', 'Anna Maven'));

    final db = WeftDatabase.openAt(':memory:');
    addTearDown(db.dispose);
    final store = _CountingStore(db);
    final repository = MatrixChatRepository(
      _OfflineSession(client),
      store: store,
    );
    addTearDown(repository.dispose);

    // The first rebuild stores the person once, naming the last room listed
    // for them — the room the handle has always ended up naming.
    expect(store.writes.where((h) => h.id == peer), hasLength(1));
    expect(store.writes.last.roomId, '!portal:example.org');

    store.writes.clear();
    repository.debugRebuild();
    repository.debugRebuild();
    expect(store.writes, isEmpty);
  });

  test('a room is muted exactly when the SDK says its push rules silence '
      'it', () async {
    // The inbox reads the account's push rules once per rebuild instead of
    // asking each room, which parsed every rule again per room. Same answer
    // either way, for every shape of rule a client writes.
    final client = _SignedInClient(
      'mute-rules',
      database: await sdk.MatrixSdkDatabase.init(
        'mute-rules',
        database: await openWeftSqfliteDatabase(inMemoryDatabasePath),
      ),
    );
    const rooms = {
      '!override_mute:example.org',
      '!override_loud:example.org',
      '!room_mute:example.org',
      '!room_coalesce:example.org',
      '!room_loud:example.org',
      '!override_loud_room_mute:example.org',
      '!no_rule:example.org',
    };
    for (final id in rooms) {
      client.rooms.add(dm(client, id, 'Anna'));
    }
    Map<String, Object?> rule(String id, List<Object?> actions) => {
      'rule_id': id,
      'default': false,
      'enabled': true,
      'actions': actions,
      'conditions': [
        {'kind': 'event_match', 'key': 'room_id', 'pattern': id},
      ],
    };
    client.accountData[sdk.EventTypes.PushRules] = sdk.BasicEvent(
      type: sdk.EventTypes.PushRules,
      content: {
        'global': {
          'override': [
            rule('!override_mute:example.org', []),
            rule('!override_loud:example.org', ['notify']),
            rule('!override_loud_room_mute:example.org', ['notify']),
          ],
          'room': [
            {
              ...rule('!room_mute:example.org', ['dont_notify']),
            }..remove('conditions'),
            {
              ...rule('!room_coalesce:example.org', ['coalesce']),
            }..remove('conditions'),
            {
              ...rule('!room_loud:example.org', [
                'notify',
                {'set_tweak': 'sound', 'value': 'default'},
              ]),
            }..remove('conditions'),
            {...rule('!override_loud_room_mute:example.org', [])}
              ..remove('conditions'),
          ],
        },
      },
    );

    final repository = MatrixChatRepository(_OfflineSession(client));
    addTearDown(repository.dispose);

    final muted = {
      for (final id in rooms) id: repository.chatForRoom(id)!.muted,
    };
    expect(muted, {
      for (final id in rooms)
        id: client.getRoomById(id)!.pushRuleState != sdk.PushRuleState.notify,
    });
    expect(muted.values.where((m) => m), hasLength(4));
  });
}
