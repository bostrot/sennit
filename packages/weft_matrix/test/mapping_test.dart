import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart' as sdk;
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_matrix/weft_matrix.dart';
import 'package:weft_richtext/weft_richtext.dart';

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

    test('a formatted body is surfaced, guarded on the format key', () {
      final rich = map({
        'msgtype': 'm.text',
        'body': 'the summary is ready',
        'format': 'org.matrix.custom.html',
        'formatted_body': 'the <b>summary</b> is ready',
      })!;
      expect(rich.formattedBody, 'the <b>summary</b> is ready');

      // A formatted body in some other format is a document in a language
      // nobody claimed it was written in; handing it to an HTML parser is how
      // a renderer ends up trusting markup it was never promised.
      final foreign = map({
        'msgtype': 'm.text',
        'body': 'the summary is ready',
        'format': 'org.example.markdown',
        'formatted_body': 'the **summary** is ready',
      })!;
      expect(foreign.formattedBody, isNull);

      expect(
        map({'msgtype': 'm.text', 'body': 'plain'})!.formattedBody,
        isNull,
      );
    });

    test('a replacement is a relation, not a second bubble', () {
      // The regression this pins: an `m.replace` is an `m.room.message` with a
      // body of `* the new text`, so a mapper that only filters on type renders
      // every edit twice — once corrected in place, once as a bubble starting
      // with a star.
      expect(
        map({
          'msgtype': 'm.text',
          'body': '* corrected',
          'm.new_content': {'msgtype': 'm.text', 'body': 'corrected'},
          'm.relates_to': {
            'rel_type': 'm.replace',
            'event_id': r'$original:example.org',
          },
        }),
        isNull,
      );
    });

    test('a reply is still a bubble, relation and all', () {
      final reply = map({
        'msgtype': 'm.text',
        'body': '> <@sam:example.org> question\n\nanswer',
        'm.relates_to': {
          'm.in_reply_to': {'event_id': r'$question:example.org'},
        },
      })!;

      expect(reply.replyToEventId, r'$question:example.org');
      // Nothing resolved it yet, and null is how that is told apart from "not
      // a reply" — which is `replyToEventId` being null.
      expect(reply.replyPreview, isNull);
    });
  });

  group('relation extraction', () {
    late sdk.Room room;

    setUpAll(() async {
      final client = sdk.Client(
        'weft-relations-test',
        database: await sdk.MatrixSdkDatabase.init(
          'weft-relations-test',
          database: await openWeftSqfliteDatabase(inMemoryDatabasePath),
        ),
      );
      room = sdk.Room(id: '!room:example.org', client: client);
    });

    sdk.Event event({
      required String type,
      required Map<String, Object?> content,
      required String eventId,
      String senderId = '@sam:example.org',
      DateTime? at,
    }) {
      return sdk.Event(
        type: type,
        content: content,
        eventId: eventId,
        senderId: senderId,
        originServerTs: at ?? DateTime(2026, 8, 17, 9, 30),
        room: room,
      );
    }

    test('an annotation carries its target, key, room and sender', () {
      final mapped = mapReaction(
        event(
          type: sdk.EventTypes.Reaction,
          eventId: r'$reaction:example.org',
          senderId: '@whatsapp_49151:example.org',
          content: {
            'm.relates_to': {
              'rel_type': 'm.annotation',
              'event_id': r'$target:example.org',
              'key': '👍',
            },
          },
        ),
      )!;

      expect(mapped.eventId, r'$reaction:example.org');
      expect(mapped.targetEventId, r'$target:example.org');
      expect(mapped.key, '👍');
      // The room is not decoration: a redaction of this annotation has to be
      // sent to the room it lives in, which in a merged chat is not the chat's
      // send network.
      expect(mapped.roomId, '!room:example.org');
      expect(mapped.senderId, '@whatsapp_49151:example.org');
    });

    test('an annotation with nothing to annotate maps to nothing', () {
      // A redacted reaction is exactly this shape: redaction strips
      // `m.relates_to`, which is why no explicit redaction check is needed.
      expect(
        mapReaction(
          event(
            type: sdk.EventTypes.Reaction,
            eventId: r'$reaction:example.org',
            content: const {},
          ),
        ),
        isNull,
      );

      // A relation with no key, and a plain message that is not one at all.
      expect(
        mapReaction(
          event(
            type: sdk.EventTypes.Reaction,
            eventId: r'$reaction:example.org',
            content: {
              'm.relates_to': {
                'rel_type': 'm.annotation',
                'event_id': r'$target:example.org',
              },
            },
          ),
        ),
        isNull,
      );
      expect(
        mapReaction(
          event(
            type: sdk.EventTypes.Message,
            eventId: r'$msg:example.org',
            content: const {'msgtype': 'm.text', 'body': 'hello'},
          ),
        ),
        isNull,
      );
    });

    test('an edit prefers m.new_content over the starred fallback', () {
      final mapped = mapEdit(
        event(
          type: sdk.EventTypes.Message,
          eventId: r'$edit:example.org',
          at: DateTime(2026, 8, 17, 14, 2),
          content: {
            'msgtype': 'm.text',
            'body': '* Thursday at 14:00',
            'm.new_content': {
              'msgtype': 'm.text',
              'body': 'Thursday at 14:00',
              'format': 'org.matrix.custom.html',
              'formatted_body': 'Thursday at <b>14:00</b>',
            },
            'm.relates_to': {
              'rel_type': 'm.replace',
              'event_id': r'$original:example.org',
            },
          },
        ),
      )!;

      expect(mapped.body, 'Thursday at 14:00');
      expect(mapped.formattedBody, 'Thursday at <b>14:00</b>');
      expect(mapped.targetEventId, r'$original:example.org');
      // The *replacement's* timestamp, which is what an "edited 14:02"
      // indicator shows. The original's would name when the message was first
      // sent, and be wrong by however long the sender took to notice.
      expect(mapped.timestamp, DateTime(2026, 8, 17, 14, 2));
    });

    test('an edit without new content falls back and drops the star', () {
      final mapped = mapEdit(
        event(
          type: sdk.EventTypes.Message,
          eventId: r'$edit:example.org',
          content: {
            'msgtype': 'm.text',
            'body': '* Thursday at 14:00',
            'm.relates_to': {
              'rel_type': 'm.replace',
              'event_id': r'$original:example.org',
            },
          },
        ),
      )!;

      // Without the strip, every version in the history sheet reads as a
      // bullet list.
      expect(mapped.body, 'Thursday at 14:00');
      expect(mapped.formattedBody, isNull);
    });

    test('a body that is only a star is a message about a bullet', () {
      final mapped = mapEdit(
        event(
          type: sdk.EventTypes.Message,
          eventId: r'$edit:example.org',
          content: {
            'msgtype': 'm.text',
            'body': '* ',
            'm.relates_to': {
              'rel_type': 'm.replace',
              'event_id': r'$original:example.org',
            },
          },
        ),
      )!;
      expect(mapped.body, '* ');
    });

    test('a reply relation is not an edit relation', () {
      // Both live under `m.relates_to`, and confusing them turns a quote into a
      // rewrite of the message being quoted.
      const replyContent = {
        'm.relates_to': {
          'm.in_reply_to': {'event_id': r'$question:example.org'},
        },
      };
      expect(editTargetEventId(replyContent), isNull);
      expect(replyTargetEventId(replyContent), r'$question:example.org');

      const editContent = {
        'm.relates_to': {
          'rel_type': 'm.replace',
          'event_id': r'$original:example.org',
        },
      };
      expect(editTargetEventId(editContent), r'$original:example.org');
      expect(replyTargetEventId(editContent), isNull);
    });
  });

  group('mapEvent with a timeline', () {
    late sdk.Room room;

    setUpAll(() async {
      final client = sdk.Client(
        'weft-aggregation-test',
        database: await sdk.MatrixSdkDatabase.init(
          'weft-aggregation-test',
          database: await openWeftSqfliteDatabase(inMemoryDatabasePath),
        ),
      );
      room = sdk.Room(id: '!room:example.org', client: client);
    });

    final original = DateTime(2026, 8, 17, 9, 30);

    sdk.Event message({
      String eventId = r'$original:example.org',
      String senderId = '@sam:example.org',
      String body = 'Thursday at 13:00',
      DateTime? at,
    }) => sdk.Event(
      type: sdk.EventTypes.Message,
      content: {'msgtype': 'm.text', 'body': body},
      eventId: eventId,
      senderId: senderId,
      originServerTs: at ?? original,
      room: room,
    );

    sdk.Event replacement({
      required String eventId,
      required String body,
      required DateTime at,
      String senderId = '@sam:example.org',
      String target = r'$original:example.org',
      String? formattedBody,
    }) => sdk.Event(
      type: sdk.EventTypes.Message,
      content: {
        'msgtype': 'm.text',
        'body': '* $body',
        'm.new_content': {
          'msgtype': 'm.text',
          'body': body,
          if (formattedBody != null) ...{
            'format': 'org.matrix.custom.html',
            'formatted_body': formattedBody,
          },
        },
        'm.relates_to': {'rel_type': 'm.replace', 'event_id': target},
      },
      eventId: eventId,
      senderId: senderId,
      originServerTs: at,
      room: room,
    );

    sdk.Event annotation({
      required String eventId,
      required String senderId,
      String key = '👍',
      String target = r'$original:example.org',
      DateTime? at,
    }) => sdk.Event(
      type: sdk.EventTypes.Reaction,
      content: {
        'm.relates_to': {
          'rel_type': 'm.annotation',
          'event_id': target,
          'key': key,
        },
      },
      eventId: eventId,
      senderId: senderId,
      originServerTs: at ?? DateTime(2026, 8, 17, 10),
      room: room,
    );

    /// A timeline holding [events], with the aggregation tree the SDK builds
    /// for them — which is where relations live, and the only reason mapping a
    /// bubble needs a timeline at all.
    Future<sdk.Timeline> timelineOf(List<sdk.Event> events) async {
      final timeline = await room.getTimeline();
      for (final event in events) {
        timeline.events.add(event);
        timeline.addAggregatedEvent(event);
      }
      return timeline;
    }

    Future<WeftMessage> mapWith(
      sdk.Event event,
      List<sdk.Event> timelineEvents, {
      String? ownUserId = '@me:example.org',
      MergedIdentityResolver resolveSender = senderIsIdentity,
    }) async {
      return mapEvent(
        event,
        network: ChatNetwork.matrix,
        ownUserId: ownUserId,
        timeline: await timelineOf([event, ...timelineEvents]),
        resolveSender: resolveSender,
      )!;
    }

    test('an edited message reads as the newest version', () async {
      final event = message();
      final mapped = await mapWith(event, [
        replacement(
          eventId: r'$edit1:example.org',
          body: 'Thursday at 14:00',
          at: DateTime(2026, 8, 17, 14, 2),
        ),
        replacement(
          eventId: r'$edit2:example.org',
          body: 'Friday at 14:00',
          at: DateTime(2026, 8, 17, 14, 5),
          formattedBody: 'Friday at <b>14:00</b>',
        ),
      ]);

      expect(mapped.body, 'Friday at 14:00');
      expect(mapped.formattedBody, 'Friday at <b>14:00</b>');
      // The bug this fixes: `editedAt` used to be the *original's* timestamp,
      // so a message sent at 09:30 and edited at 14:05 said "edited 09:30".
      expect(mapped.editedAt, DateTime(2026, 8, 17, 14, 5));
      expect(mapped.isEdited, isTrue);

      // Oldest first, original included, ending with what the bubble shows.
      expect(mapped.editHistory.map((e) => e.body), [
        'Thursday at 13:00',
        'Thursday at 14:00',
        'Friday at 14:00',
      ]);
    });

    test('an edit from anyone but the sender changes nothing', () async {
      final event = message();
      final mapped = await mapWith(event, [
        replacement(
          eventId: r'$edit:example.org',
          senderId: '@mallory:example.org',
          body: 'Thursday is cancelled',
          at: DateTime(2026, 8, 17, 14, 2),
        ),
      ]);

      // The homeserver does not enforce this, so the client must: a room where
      // anyone can rewrite anyone's words is a room where a screenshot means
      // nothing.
      expect(mapped.body, 'Thursday at 13:00');
      expect(mapped.editHistory, isEmpty);
      expect(mapped.isEdited, isFalse);
    });

    test('an unedited message stays exactly as it arrived', () async {
      final mapped = await mapWith(message(), [
        // A replacement aimed at some other event must not follow this one.
        replacement(
          eventId: r'$edit:example.org',
          body: 'not about this',
          target: r'$elsewhere:example.org',
          at: DateTime(2026, 8, 17, 14, 2),
        ),
      ]);

      expect(mapped.body, 'Thursday at 13:00');
      expect(mapped.editedAt, isNull);
      expect(mapped.editHistory, isEmpty);
    });

    test('reactions arrive as tallies, in first-reaction order', () async {
      final mapped = await mapWith(message(), [
        annotation(
          eventId: r'$r1:example.org',
          senderId: '@anna:example.org',
          at: DateTime(2026, 8, 17, 10),
        ),
        annotation(
          eventId: r'$r2:example.org',
          senderId: '@konrad:example.org',
          key: '🎉',
          at: DateTime(2026, 8, 17, 10, 1),
        ),
        annotation(
          eventId: r'$r3:example.org',
          senderId: '@me:example.org',
          at: DateTime(2026, 8, 17, 10, 2),
        ),
      ]);

      expect(mapped.reactions.map((r) => r.key), ['👍', '🎉']);
      expect(mapped.reactions.first.count, 2);
      expect(mapped.reactions.first.byLocalUser, isTrue);
      // What `unreact` redacts — and the only place it exists.
      expect(mapped.reactions.first.localEventId, r'$r3:example.org');
      expect(mapped.reactions.last.byLocalUser, isFalse);
    });

    test('one person on two bridge legs is one reaction', () async {
      // Anna reached this conversation down two bridges and pressed the same
      // emoji on each. Counting events renders `👍 2` for one person pressing
      // one button twice — and her single un-react then appears to do nothing.
      String resolve(String senderId) => switch (senderId) {
        '@whatsapp_49151:example.org' || '@signal_abc:example.org' => 'anna',
        _ => senderId,
      };

      final mapped = await mapWith(message(), [
        annotation(
          eventId: r'$r1:example.org',
          senderId: '@whatsapp_49151:example.org',
          at: DateTime(2026, 8, 17, 10),
        ),
        annotation(
          eventId: r'$r2:example.org',
          senderId: '@signal_abc:example.org',
          at: DateTime(2026, 8, 17, 10, 1),
        ),
      ], resolveSender: resolve);

      expect(mapped.reactions.single.count, 1);
      expect(mapped.reactions.single.senderIds, [
        '@whatsapp_49151:example.org',
      ]);
    });

    test('a redacted message carries no tally and no history', () async {
      final event = message();
      event.setRedactionEvent(
        sdk.Event(
          type: sdk.EventTypes.Redaction,
          content: const {},
          eventId: r'$redaction:example.org',
          senderId: '@sam:example.org',
          originServerTs: DateTime(2026, 8, 17, 15),
          room: room,
          redacts: r'$original:example.org',
        ),
      );

      final mapped = await mapWith(event, [
        annotation(eventId: r'$r1:example.org', senderId: '@anna:example.org'),
      ]);

      // The versions and the annotations are gone from the server too; a count
      // over "message deleted" would be a tally of something nobody can read.
      expect(mapped.redacted, isTrue);
      expect(mapped.body, '');
      expect(mapped.reactions, isEmpty);
      expect(mapped.editHistory, isEmpty);
    });

    test('with no timeline, relations are simply absent', () {
      // Every call site that maps outside an open timeline — the inbox
      // preview, a notification — gets the event as sent rather than a guess.
      final mapped = mapEvent(
        message(),
        network: ChatNetwork.matrix,
        ownUserId: '@me:example.org',
      )!;

      expect(mapped.editedAt, isNull);
      expect(mapped.reactions, isEmpty);
      expect(mapped.editHistory, isEmpty);
    });
  });
}
