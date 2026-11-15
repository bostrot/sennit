import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart' as sdk;
import 'package:weft/data/matrix_chat_repository.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_matrix/weft_matrix.dart';
import 'package:weft_store/weft_store.dart';

/// An accepted message request stays accepted.
///
/// Accepting an invitation joins a room, and the homeserver remembers that.
/// Accepting a stranger's conversation on a bridged network changes nothing
/// about the room — it was joined all along — so the answer used to live only
/// in the repository's memory: accept, restart, and the request was back.
class _OfflineSession extends WeftMatrixSession {
  _OfflineSession(this._client);

  final sdk.Client _client;

  @override
  sdk.Client get client => _client;

  @override
  bool get isInitialized => true;
}

/// A client that knows who it is without ever having signed in.
class _SignedInClient extends sdk.Client {
  _SignedInClient(super.clientName, {required super.database});

  @override
  String? get userID => '@me:example.org';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const roomId = '!stranger:example.org';
  const peer = '@whatsapp_4915100012345:example.org';

  /// One joined bridged room, written to by someone the user has never
  /// answered, read or merged.
  Future<sdk.Client> account(String name) async {
    final client = _SignedInClient(
      name,
      database: await sdk.MatrixSdkDatabase.init(
        name,
        database: await openWeftSqfliteDatabase(inMemoryDatabasePath),
      ),
    );
    final room = sdk.Room(
      id: roomId,
      client: client,
      notificationCount: 1,
      summary: sdk.RoomSummary.fromJson({
        'm.joined_member_count': 2,
        'm.invited_member_count': 0,
        'm.heroes': [peer],
      }),
    );
    room.setState(
      sdk.Event(
        type: sdk.EventTypes.RoomMember,
        stateKey: peer,
        content: const {'membership': 'join', 'displayname': 'Unknown'},
        eventId: r'$member',
        senderId: peer,
        originServerTs: DateTime(2026, 5, 1, 9),
        room: room,
      ),
    );
    room.lastEvent = sdk.Event(
      type: sdk.EventTypes.Message,
      content: const {'msgtype': 'm.text', 'body': 'Hello, is this Eric?'},
      eventId: r'$hello',
      senderId: peer,
      originServerTs: DateTime(2026, 5, 2),
      room: room,
    );
    client.rooms.add(room);
    return client;
  }

  test('accepting a bridged request survives a restart', () async {
    final db = WeftDatabase.openAt(':memory:');
    addTearDown(db.dispose);
    final settings = SettingsStore(db);

    final first = MatrixChatRepository(
      _OfflineSession(await account('request-run-1')),
      settings: settings,
    );
    expect(first.chatForRoom(roomId)!.isPendingRequest, isTrue);

    final state = await first.answerChatRequest(
      roomId,
      ChatRequestAction.accept,
    );
    expect(state, ChatRequestState.accepted);
    expect(first.chatForRoom(roomId)!.isPendingRequest, isFalse);
    await first.dispose();

    // A new process: a fresh client and repository over the same settings.
    final second = MatrixChatRepository(
      _OfflineSession(await account('request-run-2')),
      settings: settings,
    );
    addTearDown(second.dispose);
    expect(
      second.chatForRoom(roomId)!.isPendingRequest,
      isFalse,
      reason: 'the accepted request came back after a restart',
    );
  });

  test('an acceptance made on another device is honoured here', () async {
    final client = await account('request-other-device');
    client
        .getRoomById(roomId)!
        .roomAccountData[kRequestAcceptedType] = sdk.BasicEvent(
      type: kRequestAcceptedType,
      content: const {'accepted': true},
    );
    final repository = MatrixChatRepository(_OfflineSession(client));
    addTearDown(repository.dispose);

    expect(repository.chatForRoom(roomId)!.isPendingRequest, isFalse);
  });

  test('a request nobody has answered is still a request', () async {
    final repository = MatrixChatRepository(
      _OfflineSession(await account('request-untouched')),
    );
    addTearDown(repository.dispose);

    expect(repository.chatForRoom(roomId)!.isPendingRequest, isTrue);
  });
}
