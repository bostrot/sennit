import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart' as sdk;
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_matrix/weft_matrix.dart';

void main() {
  group('networkFromUserId', () {
    test('reads the bridge prefix from a ghost id', () {
      expect(
        networkFromUserId('@whatsapp_4915112345678:example.org'),
        ChatNetwork.whatsapp,
      );
      expect(
        networkFromUserId('@telegram_9876:example.org'),
        ChatNetwork.telegram,
      );
      expect(
        networkFromUserId('@signal_abc-def:example.org'),
        ChatNetwork.signal,
      );
    });

    test('handles the underscore-prefixed ghost convention', () {
      // Some bridges prefix with `_` to keep ghosts out of user search.
      expect(
        networkFromUserId('@_discord_12345:example.org'),
        ChatNetwork.discord,
      );
    });

    test('treats a plain localpart as a native Matrix account', () {
      expect(networkFromUserId('@erict:bostrot.com'), ChatNetwork.matrix);
    });

    test('treats an unrecognised prefix as Matrix rather than unknown', () {
      // A real user called `@holiday_photos:hs` is a Matrix user, not a chat
      // on some network Weft has never heard of.
      expect(
        networkFromUserId('@holiday_photos:example.org'),
        ChatNetwork.matrix,
      );
    });

    test('tolerates a missing leading @ and missing domain', () {
      expect(
        networkFromUserId('whatsapp_49151:example.org'),
        ChatNetwork.whatsapp,
      );
      expect(networkFromUserId('@whatsapp_49151'), ChatNetwork.whatsapp);
    });
  });

  group('networkFromBridgeStateContent', () {
    test('reads the MSC2346 protocol object', () {
      expect(
        networkFromBridgeStateContent({
          'protocol': {'id': 'whatsapp', 'displayname': 'WhatsApp'},
        }),
        ChatNetwork.whatsapp,
      );
    });

    test('accepts a bare string protocol', () {
      expect(
        networkFromBridgeStateContent({'protocol': 'telegram'}),
        ChatNetwork.telegram,
      );
    });

    test('normalises a mautrix-prefixed protocol id', () {
      expect(
        networkFromBridgeStateContent({
          'protocol': {'id': 'mautrix-signal'},
        }),
        ChatNetwork.signal,
      );
    });

    test('falls back to the bridgebot localpart', () {
      expect(
        networkFromBridgeStateContent({'bridgebot': '@discordbot:example.org'}),
        ChatNetwork.discord,
      );
    });

    test('resolves the common bridgebot spellings', () {
      expect(
        networkFromBridgeBotId('@whatsappbot:example.org'),
        ChatNetwork.whatsapp,
      );
      expect(
        networkFromBridgeBotId('@whatsapp_bot:example.org'),
        ChatNetwork.whatsapp,
      );
      expect(
        networkFromBridgeBotId('@_telegrambot:example.org'),
        ChatNetwork.telegram,
      );
      expect(networkFromBridgeBotId('@signal:example.org'), ChatNetwork.signal);
      // Says "no idea" rather than defaulting to Matrix.
      expect(networkFromBridgeBotId('@erict:example.org'), ChatNetwork.unknown);
    });

    test('returns unknown for absent or unusable content', () {
      expect(networkFromBridgeStateContent(null), ChatNetwork.unknown);
      expect(networkFromBridgeStateContent({}), ChatNetwork.unknown);
      expect(
        networkFromBridgeStateContent({'protocol': 42}),
        ChatNetwork.unknown,
      );
    });
  });

  group('messageKindFromMsgtype', () {
    test('maps the common types', () {
      expect(messageKindFromMsgtype('m.text'), MessageKind.text);
      expect(messageKindFromMsgtype('m.image'), MessageKind.image);
      expect(messageKindFromMsgtype('m.video'), MessageKind.video);
      expect(messageKindFromMsgtype('m.file'), MessageKind.file);
      expect(messageKindFromMsgtype('m.location'), MessageKind.location);
    });

    test('separates a voice message from a music file', () {
      expect(messageKindFromMsgtype('m.audio'), MessageKind.audio);
      expect(
        messageKindFromMsgtype('m.audio', isVoice: true),
        MessageKind.voice,
      );
    });

    test('renders emote and notice as text', () {
      expect(messageKindFromMsgtype('m.emote'), MessageKind.text);
      expect(messageKindFromMsgtype('m.notice'), MessageKind.text);
    });

    test('defaults unknown and null msgtypes to text', () {
      expect(messageKindFromMsgtype(null), MessageKind.text);
      expect(messageKindFromMsgtype('com.example.custom'), MessageKind.text);
    });
  });

  group('isVoiceMessage', () {
    test('detects the MSC3245 marker', () {
      expect(
        isVoiceMessage({'org.matrix.msc3245.voice': <String, Object?>{}}),
        isTrue,
      );
    });

    test('accepts the audio extension as a secondary signal', () {
      expect(
        isVoiceMessage({
          'org.matrix.msc1767.audio': {'duration': 4200},
        }),
        isTrue,
      );
    });

    test('is false for a plain audio upload', () {
      expect(isVoiceMessage({'msgtype': 'm.audio'}), isFalse);
    });
  });

  group('replyTargetEventId', () {
    test('extracts the nested in_reply_to event id', () {
      expect(
        replyTargetEventId({
          'm.relates_to': {
            'm.in_reply_to': {'event_id': r'$abc:example.org'},
          },
        }),
        r'$abc:example.org',
      );
    });

    test('ignores an edit relation, which is not a reply', () {
      // Edits use rel_type m.replace with no in_reply_to; treating one as a
      // reply would render a quote block that was never there.
      expect(
        replyTargetEventId({
          'm.relates_to': {
            'rel_type': 'm.replace',
            'event_id': r'$abc:example.org',
          },
        }),
        isNull,
      );
    });

    test('returns null when there is no relation at all', () {
      expect(replyTargetEventId({'msgtype': 'm.text'}), isNull);
      expect(replyTargetEventId({'m.relates_to': 'nonsense'}), isNull);
    });
  });

  group('mapEvent', () {
    // One client and one room for the whole group: an `sdk.Event` cannot exist
    // without a room, and a room cannot exist without a client with a database.
    // Nothing here syncs or logs in, so an in-memory database is enough.
    late sdk.Room room;

    setUpAll(() async {
      final client = sdk.Client(
        'weft-mapping-test',
        database: await sdk.MatrixSdkDatabase.init(
          'weft-mapping-test',
          database: await openWeftSqfliteDatabase(inMemoryDatabasePath),
        ),
      );
      room = sdk.Room(id: '!room:example.org', client: client);
      // Without a member event the SDK asks the (absent) homeserver for the
      // sender's profile on every mapped event, which fills the run with
      // stack traces for a lookup no assertion here depends on.
      room.setState(
        sdk.Event(
          type: sdk.EventTypes.RoomMember,
          stateKey: '@sam:example.org',
          content: const {'membership': 'join', 'displayname': 'Sam'},
          eventId: r'$member:example.org',
          senderId: '@sam:example.org',
          originServerTs: DateTime(2026, 8, 17, 9),
          room: room,
        ),
      );
    });

    WeftMessage? map(Map<String, Object?> content, {String? type}) {
      return mapEvent(
        sdk.Event(
          type: type ?? sdk.EventTypes.Message,
          content: content,
          eventId: r'$event:example.org',
          senderId: '@sam:example.org',
          originServerTs: DateTime(2026, 8, 17, 9, 30),
          room: room,
        ),
        network: ChatNetwork.matrix,
        ownUserId: '@me:example.org',
      );
    }

    test('an m.video carries its kind, dimensions and duration', () {
      final message = map({
        'msgtype': 'm.video',
        'body': 'clip.mp4',
        'url': 'mxc://example.org/video',
        'info': {
          'mimetype': 'video/mp4',
          'size': 4900000,
          'w': 1920,
          'h': 1080,
          'duration': 12400,
        },
      })!;

      expect(message.kind, MessageKind.video);
      expect(message.mediaWidth, 1920);
      expect(message.mediaHeight, 1080);
      expect(message.durationMs, 12400);
      // Not a fetchable URL — the flag that says there is something to load.
      expect(message.attachmentUrl, r'$event:example.org');
    });

    test('an m.audio is audio, and stays audio without the voice key', () {
      final message = map({
        'msgtype': 'm.audio',
        'body': 'set.mp3',
        'url': 'mxc://example.org/audio',
        'info': {'mimetype': 'audio/mpeg', 'duration': 214000},
      })!;

      // A music file is not a voice note, and only the latter offers Transcribe.
      expect(message.kind, MessageKind.audio);
      expect(message.durationMs, 214000);
      expect(message.canTranscribe, isTrue);
    });

    test('MSC3245 turns the same msgtype into a voice note', () {
      final message = map({
        'msgtype': 'm.audio',
        'body': 'Voice message',
        'url': 'mxc://example.org/voice',
        'org.matrix.msc3245.voice': <String, Object?>{},
        'org.matrix.msc1767.audio': {'duration': 8400},
      })!;

      expect(message.kind, MessageKind.voice);
      // Read from the MSC1767 extension when `info` carries no duration.
      expect(message.durationMs, 8400);
    });

    test('an m.file is a file rather than falling through to text', () {
      final message = map({
        'msgtype': 'm.file',
        'body': 'contract.pdf',
        'url': 'mxc://example.org/file',
        'info': {'mimetype': 'application/pdf', 'size': 183000},
      })!;

      // The regression this guards: a received PDF rendering as a bare filename
      // in a text bubble, with no indication a file is attached at all.
      expect(message.kind, MessageKind.file);
      expect(message.body, 'contract.pdf');
      expect(message.attachmentUrl, isNotNull);
      expect(message.mediaWidth, isNull);
    });

    test('an encrypted attachment counts even with no top-level url', () {
      final message = map({
        'msgtype': 'm.image',
        'body': 'holiday.jpg',
        'file': {
          'url': 'mxc://example.org/ciphertext',
          'iv': 'aaaa',
          'hashes': {'sha256': 'bbbb'},
          'key': {'k': 'cccc', 'alg': 'A256CTR'},
        },
        'info': {'mimetype': 'image/jpeg', 'w': 1400, 'h': 900},
      })!;

      expect(message.kind, MessageKind.image);
      expect(message.attachmentUrl, isNotNull);
      expect(message.mediaWidth, 1400);
      expect(message.mediaHeight, 900);
    });

    test('a text message has no attachment and no dimensions', () {
      final message = map({'msgtype': 'm.text', 'body': 'hello'})!;

      expect(message.kind, MessageKind.text);
      expect(message.attachmentUrl, isNull);
      expect(message.mediaWidth, isNull);
      expect(message.durationMs, isNull);
    });

    test('unusable dimensions are dropped rather than believed', () {
      // `info` is whatever the sending client wrote. A zero would otherwise
      // become an aspect ratio the bubble cannot divide by, and a string would
      // be a cast exception in the middle of rendering a timeline.
      final zeros = map({
        'msgtype': 'm.image',
        'body': 'photo.jpg',
        'url': 'mxc://example.org/photo',
        'info': {'w': 0, 'h': 0},
      })!;
      expect(zeros.mediaWidth, isNull);
      expect(zeros.mediaHeight, isNull);

      final strings = map({
        'msgtype': 'm.image',
        'body': 'photo.jpg',
        'url': 'mxc://example.org/photo',
        'info': {'w': '1600', 'h': '900'},
      })!;
      expect(strings.mediaWidth, isNull);

      final noInfo = map({
        'msgtype': 'm.image',
        'body': 'photo.jpg',
        'url': 'mxc://example.org/photo',
      })!;
      expect(noInfo.mediaWidth, isNull);

      final floats = map({
        'msgtype': 'm.image',
        'body': 'photo.jpg',
        'url': 'mxc://example.org/photo',
        'info': {'w': 1599.6, 'h': 899.4},
      })!;
      expect(floats.mediaWidth, 1600);
      expect(floats.mediaHeight, 899);
    });

    test('an announced size is carried through for the file bubble', () {
      // The file bubble's second line is `contract.pdf · 2.0 MB`, and there is
      // nowhere else for the number to come from: the bytes are not fetched
      // until the attachment is opened, and an encrypted one cannot be measured
      // without decrypting it.
      final file = map({
        'msgtype': 'm.file',
        'body': 'contract.pdf',
        'url': 'mxc://example.org/file',
        'info': {'mimetype': 'application/pdf', 'size': 2 * 1024 * 1024},
      })!;
      expect(file.mediaSizeBytes, 2 * 1024 * 1024);

      final video = map({
        'msgtype': 'm.video',
        'body': 'clip.mp4',
        'url': 'mxc://example.org/video',
        'info': {'size': 4900000, 'w': 1920, 'h': 1080},
      })!;
      expect(video.mediaSizeBytes, 4900000);
    });

    test('an unusable size is dropped rather than shown as 0 B', () {
      // Same rule as the dimensions, and the same reason: `info` is whatever
      // the sending client wrote. `0 B` under a photo reads as a broken file.
      Map<String, Object?> withSize(Object? size) => {
        'msgtype': 'm.file',
        'body': 'contract.pdf',
        'url': 'mxc://example.org/file',
        if (size != null) 'info': {'size': size},
      };

      expect(map(withSize(0))!.mediaSizeBytes, isNull);
      expect(map(withSize('183000'))!.mediaSizeBytes, isNull);
      expect(map(withSize(-4))!.mediaSizeBytes, isNull);
      expect(map(withSize(null))!.mediaSizeBytes, isNull);
    });

    test('a sticker maps by event type, not by msgtype', () {
      final message = map({
        'body': 'party parrot',
        'url': 'mxc://example.org/sticker',
        'info': {'mimetype': 'image/png', 'w': 128, 'h': 128},
      }, type: sdk.EventTypes.Sticker)!;

      expect(message.kind, MessageKind.sticker);
      expect(message.mediaWidth, 128);
    });

    test('a state change is not conversation content', () {
      expect(map(const {'membership': 'join'}, type: 'm.room.member'), isNull);
    });
  });
}
