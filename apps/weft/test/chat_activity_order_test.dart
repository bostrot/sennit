import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart' as sdk;
import 'package:weft/data/matrix_chat_repository.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_matrix/weft_matrix.dart';
import 'package:weft_store/weft_store.dart';

/// Only a message or a reaction moves a conversation up the inbox.
///
/// Matrix orders rooms by their newest event, and the SDK's `lastEvent` is
/// replaced by a placeholder stamped with the first event of a limited sync —
/// which, for a bridged contact who just changed their profile picture, is
/// that change. The conversation jumped to the top with nothing new in it.
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
  String? get userID => me;
}

const me = '@me:example.org';
const anna = '@whatsapp_4915100012345:example.org';
const annaSignal = '@signal_4915100012345:example.org';
const ben = '@whatsapp_4915100067890:example.org';
const cleo = '@telegram_42:example.org';

const roomAnna = '!anna:example.org';
const roomAnnaSignal = '!anna-signal:example.org';
const roomBen = '!ben:example.org';
const roomCleo = '!cleo:example.org';

DateTime at(int hour, [int minute = 0]) => DateTime(2026, 11, 20, hour, minute);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late sdk.Client client;
  late MatrixChatRepository repository;
  late WeftDatabase weftDb;
  late SettingsStore settings;

  Future<sdk.Client> account(String name) async => _SignedInClient(
    name,
    database: await sdk.MatrixSdkDatabase.init(
      name,
      // A file of its own: the in-memory path is one database for the whole
      // process, and each test's cache would leak into the next.
      database: await openWeftSqfliteDatabase(
        '${Directory.systemTemp.createTempSync('activity').path}/sdk.sqlite',
      ),
    ),
  );

  sdk.Room dm(sdk.Client client, String roomId, String peer) {
    final room = sdk.Room(
      id: roomId,
      client: client,
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
        content: const {'membership': 'join', 'displayname': 'Someone'},
        eventId: '\$member_$roomId',
        senderId: peer,
        originServerTs: at(8),
        room: room,
      ),
    );
    client.rooms.add(room);
    return room;
  }

  sdk.Event message(
    sdk.Room room,
    String id,
    String body,
    DateTime ts, {
    String? sender,
  }) => sdk.Event(
    type: sdk.EventTypes.Message,
    content: {'msgtype': 'm.text', 'body': body},
    eventId: id,
    senderId: sender ?? room.directChatMatrixID ?? anna,
    originServerTs: ts,
    room: room,
  );

  sdk.Event reaction(
    sdk.Room room,
    String id,
    String target,
    String key,
    DateTime ts, {
    required String sender,
  }) => sdk.Event(
    type: sdk.EventTypes.Reaction,
    content: {
      'm.relates_to': {
        'rel_type': sdk.RelationshipTypes.reaction,
        'event_id': target,
        'key': key,
      },
    },
    eventId: id,
    senderId: sender,
    originServerTs: ts,
    room: room,
  );

  /// The same event through the same doors a sync uses: the database, the
  /// room's own `lastEvent` where the SDK would set it, and the timeline
  /// stream.
  Future<void> arrive(sdk.Event event, {bool asLastEvent = false}) async {
    await client.database.storeEventUpdate(
      event.room.id,
      event,
      sdk.EventUpdateType.timeline,
      client,
    );
    if (asLastEvent) event.room.lastEvent = event;
    client.onTimelineEvent.add(event);
    await settle();
  }

  Future<void> start() async {
    repository = MatrixChatRepository(
      _OfflineSession(client),
      settings: settings,
    );
    await settle();
    repository.debugRebuild();
  }

  List<String> order() {
    repository.debugRebuild();
    final chats = {
      for (final room in client.rooms) ?repository.chatForRoom(room.id),
    }.toList()..sort(Chat.byActivity);
    return [for (final c in chats) c.id];
  }

  setUp(() async {
    weftDb = WeftDatabase.openAt(':memory:');
    settings = SettingsStore(weftDb);
    client = await account('activity-${DateTime.now().microsecondsSinceEpoch}');
  });

  tearDown(() async {
    await repository.dispose();
    weftDb.dispose();
  });

  Future<(sdk.Room, sdk.Room)> twoChats() async {
    final a = dm(client, roomAnna, anna);
    final b = dm(client, roomBen, ben);
    await arrive(
      message(a, r'$a1', 'see you at six', at(10)),
      asLastEvent: true,
    );
    await arrive(message(b, r'$b1', 'on my way', at(11)), asLastEvent: true);
    await start();
    expect(order(), [roomBen, roomAnna]);
    return (a, b);
  }

  test(
    'a profile change after an older message does not move the chat',
    () async {
      final (a, _) = await twoChats();

      // Anna changes her picture at noon. The member event arrives in a
      // limited sync, and the SDK puts a placeholder where the last event was,
      // stamped with that change.
      final change = sdk.Event(
        type: sdk.EventTypes.RoomMember,
        stateKey: anna,
        content: const {
          'membership': 'join',
          'displayname': 'Anna',
          'avatar_url': 'mxc://example.org/new',
        },
        eventId: r'$avatar',
        senderId: anna,
        originServerTs: at(12),
        room: a,
      );
      a.lastEvent = sdk.Event(
        type: sdk.EventTypes.refreshingLastEvent,
        content: const {'body': 'Refreshing last event...'},
        eventId: 'placeholder',
        senderId: me,
        originServerTs: at(12),
        room: a,
      );
      await arrive(change);
      for (final type in [
        sdk.EventTypes.RoomAvatar,
        sdk.EventTypes.RoomName,
        sdk.EventTypes.RoomTopic,
        'm.bridge',
      ]) {
        await arrive(
          sdk.Event(
            type: type,
            stateKey: '',
            content: const {'name': 'x', 'topic': 'y', 'url': 'mxc://x/y'},
            eventId: '\$state_$type',
            senderId: anna,
            originServerTs: at(13),
            room: a,
          ),
        );
      }

      expect(order(), [roomBen, roomAnna]);
      final chat = repository.chatForRoom(roomAnna)!;
      expect(chat.lastActivityAt, at(10));
      expect(chat.lastActivity!.body, 'see you at six');
    },
  );

  test(
    'a reaction from them moves the chat up and is what the row says',
    () async {
      final (a, _) = await twoChats();

      await arrive(reaction(a, r'$r1', r'$a1', '👍', at(12), sender: anna));

      expect(order(), [roomAnna, roomBen]);
      final chat = repository.chatForRoom(roomAnna)!;
      expect(chat.lastActivityAt, at(12));
      expect(chat.lastActivity!.reactionKey, '👍');
      expect(chat.lastActivity!.isOwn, isFalse);
      expect(chat.lastActivity!.body, 'see you at six');
      // Still the message for whatever asks who spoke last.
      expect(chat.lastMessage!.eventId, r'$a1');
    },
  );

  test('a reaction from me moves the chat up too', () async {
    final (a, _) = await twoChats();

    await arrive(reaction(a, r'$r1', r'$a1', '❤️', at(12), sender: me));

    expect(order(), [roomAnna, roomBen]);
    final last = repository.chatForRoom(roomAnna)!.lastActivity!;
    expect(last.reactionKey, '❤️');
    expect(last.isOwn, isTrue);
  });

  test('a withdrawn reaction gives the row back its message', () async {
    final (a, _) = await twoChats();
    await arrive(reaction(a, r'$r1', r'$a1', '👍', at(12), sender: anna));
    expect(order(), [roomAnna, roomBen]);

    // The SDK writes the redacted reaction to its cache before the
    // redaction reaches the timeline stream.
    final withdrawn = reaction(a, r'$r1', r'$a1', '👍', at(12), sender: anna);
    final redaction = sdk.Event(
      type: sdk.EventTypes.Redaction,
      content: const {'redacts': r'$r1'},
      redacts: r'$r1',
      eventId: r'$x1',
      senderId: anna,
      originServerTs: at(12, 5),
      room: a,
    );
    withdrawn.setRedactionEvent(redaction);
    await client.database.storeEventUpdate(
      roomAnna,
      withdrawn,
      sdk.EventUpdateType.timeline,
      client,
    );
    client.onTimelineEvent.add(redaction);
    await settle();

    expect(order(), [roomBen, roomAnna]);
    expect(repository.chatForRoom(roomAnna)!.lastActivity!.eventId, r'$a1');
  });

  test(
    'an edit does not move the chat, and the row reads the new words',
    () async {
      final (a, _) = await twoChats();

      final edit = sdk.Event(
        type: sdk.EventTypes.Message,
        content: {
          'msgtype': 'm.text',
          'body': '* see you at seven',
          'm.new_content': {'msgtype': 'm.text', 'body': 'see you at seven'},
          'm.relates_to': {
            'rel_type': sdk.RelationshipTypes.edit,
            'event_id': r'$a1',
          },
        },
        eventId: r'$e1',
        senderId: anna,
        originServerTs: at(12),
        room: a,
      );
      // What the SDK does with an edit of the last event: makes it the last.
      await arrive(edit, asLastEvent: true);

      expect(order(), [roomBen, roomAnna]);
      final chat = repository.chatForRoom(roomAnna)!;
      expect(chat.lastActivityAt, at(10));
      expect(chat.lastActivity!.body, 'see you at seven');
    },
  );

  test('a deleted message keeps its place', () async {
    final (a, _) = await twoChats();

    final redaction = sdk.Event(
      type: sdk.EventTypes.Redaction,
      content: const {'redacts': r'$a1'},
      redacts: r'$a1',
      eventId: r'$x2',
      senderId: anna,
      originServerTs: at(12),
      room: a,
    );
    a.lastEvent!.setRedactionEvent(redaction);
    client.onTimelineEvent.add(redaction);
    await settle();

    expect(order(), [roomBen, roomAnna]);
    final chat = repository.chatForRoom(roomAnna)!;
    expect(chat.lastActivityAt, at(10));
    expect(chat.lastActivity!.redacted, isTrue);
  });

  test('a merged chat moves for a reaction on any of its legs', () async {
    final a = dm(client, roomAnna, anna);
    final s = dm(client, roomAnnaSignal, annaSignal);
    final c = dm(client, roomCleo, cleo);
    await arrive(
      message(a, r'$a1', 'hi on whatsapp', at(9)),
      asLastEvent: true,
    );
    await arrive(message(s, r'$s1', 'hi on signal', at(10)), asLastEvent: true);
    await arrive(message(c, r'$c1', 'hello', at(11)), asLastEvent: true);
    await start();

    final graph = repository.identityGraph;
    await repository.mergeHandles(
      graph.handleFor(anna)!.id,
      graph.handleFor(annaSignal)!.id,
    );
    final merged = repository.chatForRoom(roomAnna)!;
    expect(merged.isMerged, isTrue);
    expect(order(), [roomCleo, merged.id]);

    // A reaction on the older leg is still the newest thing in the chat.
    await arrive(reaction(a, r'$r1', r'$a1', '😂', at(12), sender: me));

    expect(order(), [merged.id, roomCleo]);
    final chat = repository.chatForRoom(roomAnna)!;
    expect(chat.lastActivityAt, at(12));
    expect(chat.lastActivity!.reactionKey, '😂');
    expect(chat.lastMessage!.eventId, r'$s1');
  });

  test('the first start reads activity from the cached timeline, and a '
      'restart starts from what it stored', () async {
    final a = dm(client, roomAnna, anna);
    final b = dm(client, roomBen, ben);
    // What an install that predates the log has: a cache with Anna's message
    // and her reaction, and a room whose last event is a placeholder from the
    // profile change that came after.
    for (final event in [
      message(a, r'$a1', 'see you at six', at(10)),
      reaction(a, r'$r1', r'$a1', '👍', at(10, 30), sender: anna),
      message(b, r'$b1', 'on my way', at(11)),
    ]) {
      await client.database.storeEventUpdate(
        event.room.id,
        event,
        sdk.EventUpdateType.timeline,
        client,
      );
    }
    b.lastEvent = message(b, r'$b1', 'on my way', at(11));
    a.lastEvent = sdk.Event(
      type: sdk.EventTypes.refreshingLastEvent,
      content: const {'body': 'Refreshing last event...'},
      eventId: 'placeholder',
      senderId: me,
      originServerTs: at(12),
      room: a,
    );

    await start();
    await settle();
    expect(order(), [roomBen, roomAnna]);
    var chat = repository.chatForRoom(roomAnna)!;
    expect(chat.lastActivityAt, at(10, 30));
    expect(chat.lastActivity!.reactionKey, '👍');
    expect(chat.lastActivity!.body, 'see you at six');
    await repository.dispose();

    // A new process over the same settings and cache: nothing is scanned
    // again, and the stored ids are read back for the preview.
    client.rooms.clear();
    final a2 = dm(client, roomAnna, anna);
    dm(client, roomBen, ben).lastEvent = message(
      client.getRoomById(roomBen)!,
      r'$b1',
      'on my way',
      at(11),
    );
    a2.lastEvent = null;
    await start();
    await settle();
    expect(order(), [roomBen, roomAnna]);
    chat = repository.chatForRoom(roomAnna)!;
    expect(chat.lastActivityAt, at(10, 30));
    expect(chat.lastActivity!.body, 'see you at six');
    expect(chat.lastMessage!.eventId, r'$a1');
  });
}

/// Lets the stream listeners and the database reads they start finish.
Future<void> settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
