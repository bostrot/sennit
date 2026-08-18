import 'package:test/test.dart';
import 'package:weft_domain/weft_domain.dart';

void main() {
  WeftMessage msg({
    ChatNetwork network = ChatNetwork.whatsapp,
    bool isOwn = false,
    String body = 'x',
    String? transcript,
    MessageKind kind = MessageKind.text,
  }) {
    return WeftMessage(
      eventId: r'$e',
      roomId: '!r',
      network: network,
      senderId: '@p:hs',
      senderName: 'P',
      timestamp: DateTime.utc(2026, 8, 16),
      kind: kind,
      isOwn: isOwn,
      body: body,
      transcript: transcript,
    );
  }

  Chat chat({
    List<ChatNetwork> networks = const [ChatNetwork.whatsapp],
    WeftMessage? last,
    ChatNetwork? preferred,
  }) {
    return Chat(
      id: 'c',
      title: 'C',
      sources: [
        for (final n in networks) ChatSource(roomId: '!${n.id}', network: n),
      ],
      lastMessage: last,
      preferredSendNetwork: preferred,
    );
  }

  group('Chat.sendNetwork', () {
    test('an explicit user choice always wins', () {
      final c = chat(
        networks: [ChatNetwork.whatsapp, ChatNetwork.signal],
        last: msg(network: ChatNetwork.whatsapp),
        preferred: ChatNetwork.signal,
      );
      expect(c.sendNetwork, ChatNetwork.signal);
      expect(c.hasExplicitSendNetwork, isTrue);
    });

    test('defaults to the network of the last inbound message', () {
      final c = chat(
        networks: [ChatNetwork.whatsapp, ChatNetwork.signal],
        last: msg(network: ChatNetwork.signal),
      );
      expect(
        c.sendNetwork,
        ChatNetwork.signal,
        reason: 'replying where they actually wrote is the sane default',
      );
      expect(c.hasExplicitSendNetwork, isFalse);
    });

    test('an own outgoing message does not flip the default', () {
      // Sending on Signal must not re-anchor the default away from where the
      // peer last wrote — the inference is about *their* choice, not ours.
      final c = chat(
        networks: [ChatNetwork.whatsapp, ChatNetwork.signal],
        last: msg(network: ChatNetwork.signal, isOwn: true),
      );
      expect(
        c.sendNetwork,
        ChatNetwork.whatsapp,
        reason: 'falls back to the first source, not the own-message leg',
      );
    });

    test('a preference for a network the chat no longer spans is ignored', () {
      final c = chat(
        networks: [ChatNetwork.whatsapp],
        preferred: ChatNetwork.telegram,
      );
      expect(c.sendNetwork, ChatNetwork.whatsapp);
      expect(
        c.hasExplicitSendNetwork,
        isFalse,
        reason: 'a stale pin must not render as active',
      );
    });

    test('networks lists in stable enum order regardless of source order', () {
      final c = chat(networks: [ChatNetwork.telegram, ChatNetwork.whatsapp]);
      expect(c.networks, [ChatNetwork.whatsapp, ChatNetwork.telegram]);
    });
  });

  group('ChatNetwork.fromBridgeProtocol', () {
    test('normalises the spellings bridges actually emit', () {
      for (final raw in [
        'whatsapp',
        'WhatsApp',
        'mautrix-whatsapp',
        'sh.puppet.whatsapp',
        'whatsapp_go',
      ]) {
        expect(
          ChatNetwork.fromBridgeProtocol(raw),
          ChatNetwork.whatsapp,
          reason: raw,
        );
      }
    });

    test('unknown protocols still surface rather than throwing', () {
      expect(
        ChatNetwork.fromBridgeProtocol('fancynewapp'),
        ChatNetwork.unknown,
      );
      expect(ChatNetwork.fromBridgeProtocol(null), ChatNetwork.unknown);
    });
  });

  group('WeftMessage.searchableText', () {
    test('joins body and transcript so both are findable', () {
      expect(
        msg(body: 'note', transcript: 'spoken words').searchableText,
        'note\nspoken words',
      );
      expect(
        msg(body: '', transcript: 'only spoken').searchableText,
        'only spoken',
      );
      expect(msg(body: 'only typed').searchableText, 'only typed');
    });

    test('canTranscribe covers voice and audio, never redacted', () {
      expect(msg(kind: MessageKind.voice).canTranscribe, isTrue);
      expect(msg(kind: MessageKind.audio).canTranscribe, isTrue);
      expect(msg(kind: MessageKind.text).canTranscribe, isFalse);
      expect(
        msg(kind: MessageKind.voice).copyWith(redacted: true).canTranscribe,
        isFalse,
      );
    });
  });

  group('WeftMessage media dimensions', () {
    WeftMessage sized(int? width, int? height) => WeftMessage(
      eventId: r'$e',
      roomId: '!r',
      network: ChatNetwork.matrix,
      senderId: '@p:hs',
      senderName: 'P',
      timestamp: DateTime.utc(2026, 8, 16),
      kind: MessageKind.image,
      isOwn: false,
      mediaWidth: width,
      mediaHeight: height,
    );

    test('an aspect ratio is only offered when both edges are known', () {
      expect(sized(1600, 900).mediaAspectRatio, closeTo(16 / 9, 1e-9));
      expect(sized(1600, null).mediaAspectRatio, isNull);
      expect(sized(null, null).mediaAspectRatio, isNull);
      // A sender that fills in `w`/`h` whether or not it knows them must not
      // become a division by zero in the middle of a layout pass.
      expect(sized(0, 0).mediaAspectRatio, isNull);
    });

    test('copyWith carries the dimensions through', () {
      // They describe the attachment, not the message's mutable state, so an
      // edit or a redaction must not silently reshape the bubble.
      final edited = sized(1400, 900).copyWith(body: 'caption');
      expect(edited.mediaWidth, 1400);
      expect(edited.mediaHeight, 900);
    });
  });

  group('WeftMessage relations', () {
    final reacted = ReactionTally(
      key: '👍',
      senderIds: const ['@anna:hs'],
      firstReactedAt: DateTime.utc(2026, 8, 16, 10),
    );

    test('copyWith carries the relation fields it is not given', () {
      // The failure this guards is silent: `copyWith` re-lists every field by
      // hand, so a field left out of the constructor call disappears on the
      // first copy — and the copies are ordinary, a finished transcription
      // being one of them.
      final message = msg().copyWith(
        reactions: [reacted],
        editHistory: [
          EditRecord(
            eventId: r'$e',
            body: 'x',
            timestamp: DateTime.utc(2026, 8, 16),
          ),
        ],
        replyPreview: const ReplyPreview.stub(r'$question'),
        formattedBody: '<b>x</b>',
      );

      final copied = message.copyWith(transcript: 'spoken');
      expect(copied.reactions, [reacted]);
      expect(copied.editHistory, hasLength(1));
      expect(copied.replyPreview?.eventId, r'$question');
      expect(copied.formattedBody, '<b>x</b>');
    });

    test('copyWith can clear a formatted body, and does not by accident', () {
      final rich = msg().copyWith(formattedBody: '<b>x</b>');

      // An edit that drops formatting has to clear the old HTML, or the bubble
      // renders the previous version's markup around the new words.
      expect(
        rich.copyWith(body: 'plain', formattedBody: null).formattedBody,
        isNull,
      );
      // Not passing it at all leaves it alone, which is the common case.
      expect(rich.copyWith(body: 'plain').formattedBody, '<b>x</b>');
    });

    test('a message that gained a reaction is not the message without it', () {
      // Identity is still (eventId, roomId) — but a list diff or a `select`
      // that saw these two as equal would leave the reaction in the model and
      // off the screen, which looks like nothing is wrong at all.
      final before = msg();
      expect(before.copyWith(reactions: [reacted]) == before, isFalse);
      expect(before.copyWith(body: 'edited') == before, isFalse);
      expect(before.copyWith(transcript: 'spoken') == before, isFalse);
      expect(before.copyWith(body: 'x') == before, isTrue);
    });

    test('two different events never compare equal on content alone', () {
      final a = msg(body: 'same');
      final b = WeftMessage(
        eventId: r'$other',
        roomId: '!r',
        network: ChatNetwork.whatsapp,
        senderId: '@p:hs',
        senderName: 'P',
        timestamp: DateTime.utc(2026, 8, 16),
        kind: MessageKind.text,
        isOwn: false,
        body: 'same',
      );
      expect(a == b, isFalse);
    });
  });

  group('UnifiedContact', () {
    test('handleFor and roomIds resolve per network', () {
      const contact = UnifiedContact(
        id: 'c1',
        displayName: 'Anna',
        handles: [
          NetworkHandle(
            id: 'a',
            network: ChatNetwork.whatsapp,
            remoteId: '1',
            matrixUserId: '@w:hs',
            roomId: '!wa',
          ),
          NetworkHandle(
            id: 'b',
            network: ChatNetwork.signal,
            remoteId: '1',
            matrixUserId: '@s:hs',
            roomId: '!sg',
          ),
        ],
      );

      expect(contact.isMerged, isTrue);
      expect(contact.handleFor(ChatNetwork.signal)?.id, 'b');
      expect(contact.handleFor(ChatNetwork.telegram), isNull);
      expect(contact.roomIds, ['!wa', '!sg']);
    });
  });
}
