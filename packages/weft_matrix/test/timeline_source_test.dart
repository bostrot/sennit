import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart' as sdk;
// Not exported from `matrix.dart`, and `Timeline` requires one: the SDK's own
// public way to a timeline is `Room.getTimeline()`, which wants a synced client
// and a homeserver. A chunk of hand-built events is the whole point here.
// ignore: implementation_imports
import 'package:matrix/src/models/timeline_chunk.dart' as sdk_chunk;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_matrix/weft_matrix.dart';

/// What the timeline hands the rest of the app, and what it withholds.
///
/// The tombstone filter is the whole of "a deleted message stays deleted" for a
/// message Braid cannot redact. Removing the event from the SDK's database is
/// not enough on its own — the homeserver still has it and the next backfill
/// serves it straight back — so this is the check that the filter is applied at
/// the mapper, before anything downstream can index, notify on, or quote it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late sdk.Room room;

  setUpAll(() async {
    final client = sdk.Client(
      'weft-timeline-test',
      database: await sdk.MatrixSdkDatabase.init(
        'weft-timeline-test',
        database: await openWeftSqfliteDatabase(inMemoryDatabasePath),
      ),
    );
    room = sdk.Room(id: '!room:example.org', client: client);
    room.setState(
      sdk.Event(
        type: sdk.EventTypes.RoomMember,
        stateKey: '@sam:example.org',
        content: const {'membership': 'join', 'displayname': 'Sam'},
        eventId: r'$member:example.org',
        senderId: '@sam:example.org',
        originServerTs: DateTime(2026, 5, 1, 9),
        room: room,
      ),
    );
  });

  sdk.Event message(String eventId, String body) => sdk.Event(
    type: sdk.EventTypes.Message,
    content: {'msgtype': 'm.text', 'body': body},
    eventId: eventId,
    senderId: '@sam:example.org',
    originServerTs: DateTime(2026, 5, 1, 10),
    room: room,
  );

  MatrixTimelineSource sourceOver(
    List<sdk.Event> events, {
    Set<String> purged = const {},
  }) {
    return MatrixTimelineSource(
      timeline: sdk.Timeline(
        room: room,
        chunk: sdk_chunk.TimelineChunk(events: events),
      ),
      network: ChatNetwork.matrix,
      ownUserId: '@me:example.org',
      purgedEventIds: purged,
    );
  }

  test('every message is mapped when nothing has been purged', () {
    final source = sourceOver([
      message(r'$b:example.org', 'second'),
      message(r'$a:example.org', 'first'),
    ]);

    expect(source.loaded.map((m) => m.body), ['second', 'first']);
  });

  test('a purged event never becomes a message', () {
    final source = sourceOver(
      [
        message(r'$b:example.org', 'second'),
        message(r'$a:example.org', 'first'),
      ],
      purged: {r'$a:example.org'},
    );

    expect(source.loaded.map((m) => m.body), ['second']);
    expect(
      source.loaded.map((m) => m.eventId),
      isNot(contains(r'$a:example.org')),
      reason: 'the homeserver still holds it; this is what keeps it gone',
    );
  });

  test('a tombstone for another room does not hide anything here', () {
    // Event ids are only unique within a room, and the store answers per room
    // for exactly that reason.
    final source = sourceOver(
      [message(r'$a:example.org', 'first')],
      purged: {r'$somewhere-else:example.org'},
    );

    expect(source.loaded, hasLength(1));
  });
}
