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
