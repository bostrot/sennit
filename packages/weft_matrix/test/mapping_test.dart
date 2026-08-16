import 'package:flutter_test/flutter_test.dart';
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
}
