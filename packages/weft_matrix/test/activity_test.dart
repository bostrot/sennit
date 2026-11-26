import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart' as sdk;
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_matrix/weft_matrix.dart';

/// Which events move a conversation up the inbox.
void main() {
  late sdk.Room room;

  setUpAll(() async {
    final client = sdk.Client(
      'weft-activity-test',
      database: await sdk.MatrixSdkDatabase.init(
        'weft-activity-test',
        database: await openWeftSqfliteDatabase(inMemoryDatabasePath),
      ),
    );
    room = sdk.Room(id: '!room:example.org', client: client);
  });

  sdk.Event event(
    String type,
    Map<String, Object?> content, {
    String sender = '@whatsapp_1:example.org',
    String? stateKey,
  }) => sdk.Event(
    type: type,
    content: content,
    eventId: r'$e',
    senderId: sender,
    stateKey: stateKey,
    originServerTs: DateTime(2026, 11, 20),
    room: room,
  );

  Map<String, Object?> rel(String type, [String? key]) => {
    'm.relates_to': {'rel_type': type, 'event_id': r'$target', 'key': ?key},
  };

  test('messages, stickers, polls and calls are messages', () {
    for (final e in [
      event(sdk.EventTypes.Message, {'msgtype': 'm.text', 'body': 'hi'}),
      event(sdk.EventTypes.Message, {'msgtype': 'm.image', 'body': 'x.jpg'}),
      event(sdk.EventTypes.Message, {'msgtype': 'm.file', 'body': 'x.pdf'}),
      event(sdk.EventTypes.Message, {
        'msgtype': 'm.location',
        'body': 'here',
        'geo_uri': 'geo:1,2',
      }),
      event(sdk.EventTypes.Sticker, {'body': 'cat'}),
      event('org.matrix.msc3381.poll.start', {}),
      event('m.poll.start', {}),
      event(sdk.EventTypes.CallInvite, {}),
      event(sdk.EventTypes.CallHangup, {}),
      // A thread reply is a message in its own right.
      event(sdk.EventTypes.Message, {
        'msgtype': 'm.text',
        'body': 'in a thread',
        ...rel(sdk.RelationshipTypes.thread),
      }),
      event(sdk.EventTypes.Encrypted, {'algorithm': 'm.megolm.v1.aes-sha2'}),
    ]) {
      expect(roomActivityOf(e), RoomActivityKind.message, reason: e.type);
    }
  });

  test('reactions are reactions, encrypted or not', () {
    expect(
      roomActivityOf(
        event(
          sdk.EventTypes.Reaction,
          rel(sdk.RelationshipTypes.reaction, '👍'),
        ),
      ),
      RoomActivityKind.reaction,
    );
    expect(
      roomActivityOf(
        event(sdk.EventTypes.Encrypted, {
          'algorithm': 'm.megolm.v1.aes-sha2',
          ...rel(sdk.RelationshipTypes.reaction),
        }),
      ),
      RoomActivityKind.reaction,
    );
  });

  test('state, edits, votes and bridge chatter are not activity', () {
    for (final e in [
      event(sdk.EventTypes.RoomMember, {
        'membership': 'join',
        'avatar_url': 'mxc://x/new',
      }, stateKey: '@whatsapp_1:example.org'),
      event(sdk.EventTypes.RoomAvatar, {'url': 'mxc://x/y'}, stateKey: ''),
      event(sdk.EventTypes.RoomName, {'name': 'Anna'}, stateKey: ''),
      event(sdk.EventTypes.RoomTopic, {'topic': 't'}, stateKey: ''),
      event(sdk.EventTypes.RoomPowerLevels, {}, stateKey: ''),
      event('m.bridge', {}, stateKey: 'whatsapp'),
      event(sdk.EventTypes.Redaction, {'redacts': r'$x'}),
      event(sdk.EventTypes.CallAnswer, {}),
      event(sdk.EventTypes.GroupCallMember, {}, stateKey: '@a:x'),
      event('org.matrix.msc3381.poll.response', rel('m.reference')),
      event(sdk.EventTypes.Message, {
        'msgtype': 'm.text',
        'body': '* fixed',
        'm.new_content': {'msgtype': 'm.text', 'body': 'fixed'},
        ...rel(sdk.RelationshipTypes.edit),
      }),
      event(sdk.EventTypes.Encrypted, {
        'algorithm': 'm.megolm.v1.aes-sha2',
        ...rel(sdk.RelationshipTypes.edit),
      }),
      event(sdk.EventTypes.Message, {
        'msgtype': 'm.notice',
        'body': 'Connected to WhatsApp',
      }, sender: '@whatsappbot:example.org'),
      event(sdk.EventTypes.Message, {
        'msgtype': 'm.server_notice',
        'body': 'Server maintenance',
      }, sender: '@notices:example.org'),
      // A withdrawn reaction: redaction strips its relation.
      event(sdk.EventTypes.Reaction, {}),
      event('com.example.unknown', {'body': 'x'}),
    ]) {
      expect(roomActivityOf(e), isNull, reason: '${e.type} ${e.content}');
    }
  });

  test('a notice a person sent through a bridge is still a message', () {
    expect(
      roomActivityOf(
        event(sdk.EventTypes.Message, {'msgtype': 'm.notice', 'body': 'hi'}),
      ),
      RoomActivityKind.message,
    );
  });

  test('the preview of an edited message reads its new words', () {
    final original = sdk.Event(
      type: sdk.EventTypes.Message,
      content: const {'msgtype': 'm.text', 'body': 'see you at six'},
      eventId: r'$target',
      senderId: '@whatsapp_1:example.org',
      originServerTs: DateTime(2026, 11, 20, 10),
      room: room,
    );
    final edit = sdk.Event(
      type: sdk.EventTypes.Message,
      content: {
        'msgtype': 'm.text',
        'body': '* see you at seven',
        'm.new_content': {'msgtype': 'm.text', 'body': 'see you at seven'},
        ...rel(sdk.RelationshipTypes.edit),
      },
      eventId: r'$edit',
      senderId: '@whatsapp_1:example.org',
      originServerTs: DateTime(2026, 11, 20, 12),
      room: room,
    );
    final preview = mapPreview(
      original,
      network: ChatNetwork.whatsapp,
      ownUserId: '@me:example.org',
      edit: edit,
    )!;
    expect(preview.body, 'see you at seven');
    expect(preview.timestamp, DateTime(2026, 11, 20, 10));
  });
}
