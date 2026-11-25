import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart' as sdk;
import 'package:weft/data/matrix_chat_repository.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_matrix/weft_matrix.dart';
import 'package:weft_store/weft_store.dart';

/// Messages typed without a connection go out by themselves when it returns,
/// and a message the server refused says why instead of only "Not sent".
class _Session extends WeftMatrixSession {
  _Session(this._client);

  final sdk.Client _client;

  @override
  sdk.Client get client => _client;

  @override
  bool get isInitialized => true;
}

class _SignedInClient extends sdk.Client {
  _SignedInClient(
    super.clientName, {
    required super.database,
    super.httpClient,
    super.sendTimelineEventTimeout,
  });

  @override
  String? get userID => '@me:example.org';
}

/// A homeserver that can be unplugged, or made to refuse.
class _Server {
  bool online = false;
  Map<String, Object?>? refusal;
  final sent = <String>[];

  http.Client get client => MockClient((request) async {
    if (!online) throw http.ClientException('Network is unreachable');
    if (request.method == 'PUT' && request.url.path.contains('/send/')) {
      final refused = refusal;
      if (refused != null) {
        return http.Response(jsonEncode(refused), 403);
      }
      sent.add((jsonDecode(request.body) as Map)['body'] as String);
      return http.Response(
        jsonEncode({'event_id': r'$sent${sent.length}'}),
        200,
      );
    }
    return http.Response('{}', 200);
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const roomId = '!friend:example.org';

  Future<sdk.Client> account(String name, _Server server) async {
    final client =
        _SignedInClient(
            name,
            database: await sdk.MatrixSdkDatabase.init(
              name,
              database: await openWeftSqfliteDatabase(inMemoryDatabasePath),
            ),
            httpClient: server.client,
            sendTimelineEventTimeout: const Duration(milliseconds: 300),
          )
          ..homeserver = Uri.parse('https://example.org')
          ..accessToken = 'token';
    client.rooms.add(
      sdk.Room(
        id: roomId,
        client: client,
        summary: sdk.RoomSummary.fromJson({
          'm.joined_member_count': 2,
          'm.invited_member_count': 0,
          'm.heroes': ['@friend:example.org'],
        }),
      ),
    );
    return client;
  }

  void syncStatus(sdk.Client client, sdk.SyncStatus status) =>
      client.onSyncStatus.add(sdk.SyncStatusUpdate(status));

  test('a message sent offline waits, then goes out on reconnect', () async {
    final db = WeftDatabase.openAt(':memory:');
    addTearDown(db.dispose);
    final settings = SettingsStore(db);
    final server = _Server();
    final client = await account('queue-offline', server);
    final repository = MatrixChatRepository(
      _Session(client),
      settings: settings,
    );
    addTearDown(repository.dispose);
    final chatId = repository.chatForRoom(roomId)!.id;

    syncStatus(client, sdk.SyncStatus.error);
    await repository.send(chatId, 'see you at six');

    expect(repository.sendFailures.values, [SendFailure.offline]);
    expect(settings.getJson(WeftSettings.sendQueue), isNotEmpty);
    expect(server.sent, isEmpty);

    server.online = true;
    syncStatus(client, sdk.SyncStatus.finished);
    await expectLater(repository.sendFailureChanges, emitsThrough(isEmpty));

    expect(server.sent, ['see you at six']);
    expect(settings.getJson(WeftSettings.sendQueue), isNull);
  });

  test('a refused message says why and is not retried', () async {
    final server = _Server()
      ..online = true
      ..refusal = {'errcode': 'M_FORBIDDEN', 'error': 'Not allowed'};
    final client = await account('queue-forbidden', server);
    final repository = MatrixChatRepository(_Session(client));
    addTearDown(repository.dispose);
    final chatId = repository.chatForRoom(roomId)!.id;

    syncStatus(client, sdk.SyncStatus.finished);
    await expectLater(
      repository.send(chatId, 'hello'),
      throwsA(isA<sdk.MatrixException>()),
    );

    expect(repository.sendFailures.values, [SendFailure.notAllowed]);

    server.refusal = null;
    syncStatus(client, sdk.SyncStatus.finished);
    await pumpEventQueue();
    expect(server.sent, isEmpty, reason: 'a refusal is not retried by itself');
  });

  test('the queue outlives a restart', () async {
    final db = WeftDatabase.openAt(':memory:');
    addTearDown(db.dispose);
    final settings = SettingsStore(db);
    final server = _Server();
    final client = await account('queue-restart', server);

    final first = MatrixChatRepository(_Session(client), settings: settings);
    syncStatus(client, sdk.SyncStatus.error);
    await first.send(first.chatForRoom(roomId)!.id, 'still there?');
    final failures = first.sendFailures;
    await first.dispose();

    final second = MatrixChatRepository(_Session(client), settings: settings);
    addTearDown(second.dispose);
    expect(second.sendFailures, failures);

    server.online = true;
    syncStatus(client, sdk.SyncStatus.finished);
    await expectLater(second.sendFailureChanges, emitsThrough(isEmpty));
    expect(server.sent, ['still there?']);
  });

  test('discarding a failed message takes it out of the queue', () async {
    final server = _Server();
    final client = await account('queue-discard', server);
    final repository = MatrixChatRepository(_Session(client));
    addTearDown(repository.dispose);

    syncStatus(client, sdk.SyncStatus.error);
    await repository.send(repository.chatForRoom(roomId)!.id, 'never mind');
    final eventId = repository.sendFailures.keys.single;

    await repository.discardFailedSend(roomId, eventId);

    expect(repository.sendFailures, isEmpty);
  });
}
