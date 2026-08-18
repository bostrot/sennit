import 'package:test/test.dart';
import 'package:weft_call/weft_call.dart';
import 'package:weft_domain/weft_domain.dart';

import 'support/fixtures.dart';

/// Who a call is with, and who it cannot be with.
///
/// The Matrix-native-only constraint is expressed as a missing value rather
/// than a boolean checked somewhere else: [CallPeer.forContact] returns null
/// for a contact with no Matrix leg, so a call to a bridged-only person cannot
/// be constructed at all. Everything else here is the merged identity reaching
/// the call screen intact, so the name and badges on a call match the row the
/// user tapped.
void main() {
  UnifiedContact contact({
    String id = 'c1',
    String displayName = 'Anna',
    String? avatarUrl,
    required List<NetworkHandle> handles,
  }) {
    return UnifiedContact(
      id: id,
      displayName: displayName,
      avatarUrl: avatarUrl,
      handles: handles,
    );
  }

  const matrixHandle = NetworkHandle(
    id: 'h-matrix',
    network: ChatNetwork.matrix,
    remoteId: peerUserId,
    matrixUserId: peerUserId,
    roomId: roomId,
    avatarUrl: 'mxc://example.org/handle',
  );

  const whatsappHandle = NetworkHandle(
    id: 'h-whatsapp',
    network: ChatNetwork.whatsapp,
    remoteId: '4915112345678',
    matrixUserId: '@whatsapp_4915112345678:example.org',
    roomId: '!wa:example.org',
  );

  group('forContact', () {
    test('a bridged-only contact cannot be called', () {
      // The ghost user has a Matrix id and even a room, and will never answer
      // an `m.call.invite`. Having a Matrix user id is not the test.
      final bea = contact(
        id: 'c2',
        displayName: 'Bea',
        handles: const [whatsappHandle],
      );
      expect(CallPeer.forContact(bea), isNull);
    });

    test('a contact with no handles at all cannot be called', () {
      expect(CallPeer.forContact(contact(handles: const [])), isNull);
    });

    test('a Matrix contact resolves to its Matrix user id', () {
      final peer = CallPeer.forContact(contact(handles: const [matrixHandle]))!;
      expect(peer.matrixUserId, peerUserId);
      expect(peer.displayName, 'Anna');
      expect(peer.networks, [ChatNetwork.matrix]);
    });

    test('a merged contact calls the Matrix leg and keeps every badge', () {
      // The call screen shows the same merged-identity glyphs as the inbox, so
      // the networks travel with the peer even though only one of them can
      // carry the call.
      final anna = contact(handles: const [matrixHandle, whatsappHandle]);
      final peer = CallPeer.forContact(anna)!;

      expect(peer.matrixUserId, peerUserId, reason: 'not the ghost');
      expect(peer.networks, [ChatNetwork.matrix, ChatNetwork.whatsapp]);
    });

    test('the contact avatar wins over the handle avatar', () {
      // The merged contact's picture is the one the inbox row shows.
      final withOwn = contact(
        avatarUrl: 'mxc://example.org/contact',
        handles: const [matrixHandle],
      );
      expect(CallPeer.forContact(withOwn)!.avatarUrl, 'mxc://example.org/contact');

      final withoutOwn = contact(handles: const [matrixHandle]);
      expect(
        CallPeer.forContact(withoutOwn)!.avatarUrl,
        'mxc://example.org/handle',
        reason: 'falling back rather than showing an initial',
      );
    });
  });

  group('label', () {
    test('falls back to the user id when there is no name', () {
      expect(const CallPeer(matrixUserId: peerUserId).label, peerUserId);
      expect(
        const CallPeer(matrixUserId: peerUserId, displayName: '').label,
        peerUserId,
        reason: 'an empty name is no name',
      );
      expect(
        const CallPeer(matrixUserId: peerUserId, displayName: 'Anna').label,
        'Anna',
      );
    });
  });

  group('value semantics', () {
    test('two peers built the same way are the same peer', () {
      // The session is rebuilt on every transition, so a peer that compared by
      // identity would make every `CallSession ==` false and repaint the call
      // screen several times a second while ICE settles.
      expect(
        const CallPeer(matrixUserId: peerUserId, displayName: 'Anna'),
        const CallPeer(matrixUserId: peerUserId, displayName: 'Anna'),
      );
      expect(
        const CallPeer(matrixUserId: peerUserId, displayName: 'Anna').hashCode,
        const CallPeer(matrixUserId: peerUserId, displayName: 'Anna').hashCode,
      );
      expect(
        const CallPeer(matrixUserId: peerUserId),
        isNot(const CallPeer(matrixUserId: '@other:example.org')),
      );
      expect(
        const CallPeer(matrixUserId: peerUserId),
        isNot(const CallPeer(
          matrixUserId: peerUserId,
          networks: [ChatNetwork.matrix, ChatNetwork.whatsapp],
        )),
      );
    });

    test('an unchanged session compares equal to itself rebuilt', () {
      final session = CallSession(
        callId: 'out-1',
        partyId: localParty,
        roomId: roomId,
        peer: peer,
        direction: CallDirection.outgoing,
        state: CallState.connected,
        startedAt: t0,
      );
      expect(session.copyWith(), session);
      expect(session.copyWith(muted: true), isNot(session));
      expect(session.copyWith(muted: true).muted, isTrue);
    });

    test('a codec summary reads as one line whatever it holds', () {
      expect(const CodecSummary(audio: 'opus').label, 'opus');
      expect(const CodecSummary(video: 'VP8').label, 'VP8');
      expect(
        const CodecSummary(audio: 'opus', video: 'VP8').label,
        'opus / VP8',
      );
      expect(const CodecSummary().label, 'unknown');
      expect(const CodecSummary().isEmpty, isTrue);
    });

    test('an SDP type survives the round trip to the wire and back', () {
      for (final type in SdpType.values) {
        expect(SdpType.fromWire(type.wireType), type);
      }
      expect(SdpType.fromWire('pranswer'), isNull, reason: 'no event carries it');
    });
  });
}
