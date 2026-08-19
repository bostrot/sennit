import 'package:test/test.dart';
import 'package:weft_call/weft_call.dart';
import 'package:weft_domain/weft_domain.dart';

import 'support/fixtures.dart';

/// Which conversations offer a call button, and what the disabled one says.
///
/// The rule this pins is the one the orientation for this phase warned about:
/// a bridged WhatsApp conversation *is* a room on the user's own homeserver and
/// *does* have a Matrix room id, so "has a room id" is not the test. The test
/// is whether the inbox resolved a leg as Matrix-native.
void main() {
  const matrixHandle = NetworkHandle(
    id: 'h-matrix',
    network: ChatNetwork.matrix,
    remoteId: peerUserId,
    matrixUserId: peerUserId,
    roomId: roomId,
  );

  const whatsappHandle = NetworkHandle(
    id: 'h-whatsapp',
    network: ChatNetwork.whatsapp,
    remoteId: '4915112345678',
    matrixUserId: '@whatsapp_4915112345678:example.org',
    roomId: '!wa:example.org',
  );

  UnifiedContact contact(List<NetworkHandle> handles) =>
      UnifiedContact(id: 'c1', displayName: 'Anna', handles: handles);

  Chat chat({
    required List<ChatSource> sources,
    bool isGroup = false,
    String title = 'Anna',
  }) => Chat(
    id: sources.isEmpty ? 'empty' : sources.first.roomId,
    title: title,
    sources: sources,
    isGroup: isGroup,
  );

  group('available', () {
    test('a Matrix DM is callable, in its own room', () {
      final availability = callAvailabilityFor(
        chat(
          sources: const [
            ChatSource(roomId: roomId, network: ChatNetwork.matrix),
          ],
        ),
        contact: contact(const [matrixHandle]),
      );

      expect(availability.isAvailable, isTrue);
      expect(availability.target?.roomId, roomId);
      expect(availability.target?.peer.matrixUserId, peerUserId);
      expect(availability.message, 'Call Anna');
    });

    test('a merged chat calls over its Matrix leg, not its first', () {
      // The bridged leg comes first in the source list on purpose: a call must
      // go to the room the Matrix source names, and the peer must be the
      // Matrix handle rather than the WhatsApp ghost, whatever order the inbox
      // folded them in.
      final availability = callAvailabilityFor(
        chat(
          sources: const [
            ChatSource(
              roomId: '!wa:example.org',
              network: ChatNetwork.whatsapp,
            ),
            ChatSource(roomId: roomId, network: ChatNetwork.matrix),
          ],
        ),
        contact: contact(const [matrixHandle, whatsappHandle]),
      );

      expect(availability.target?.roomId, roomId);
      expect(availability.target?.peer.matrixUserId, peerUserId);
      // The merged identity survives to the call screen: the badges the inbox
      // row showed are the badges the call shows.
      expect(availability.target?.peer.networks, [
        ChatNetwork.matrix,
        ChatNetwork.whatsapp,
      ]);
    });
  });

  group('blocked', () {
    test('a bridged-only conversation names the networks it is on', () {
      final availability = callAvailabilityFor(
        chat(
          sources: const [
            ChatSource(
              roomId: '!wa:example.org',
              network: ChatNetwork.whatsapp,
            ),
          ],
        ),
        contact: contact(const [whatsappHandle]),
      );

      expect(availability.isAvailable, isFalse);
      expect((availability as CallBlocked).reason, CallBlocker.bridged);
      expect(availability.message, contains('WhatsApp'));
      expect(availability.message, contains('Matrix'));
    });

    test('two bridged networks are listed, not counted', () {
      final availability = callAvailabilityFor(
        chat(
          sources: const [
            ChatSource(
              roomId: '!wa:example.org',
              network: ChatNetwork.whatsapp,
            ),
            ChatSource(roomId: '!sg:example.org', network: ChatNetwork.signal),
          ],
        ),
        contact: contact(const [whatsappHandle]),
      );

      expect(availability.message, contains('WhatsApp and Signal'));
    });

    test('a group is refused as a group even with a Matrix leg', () {
      final availability = callAvailabilityFor(
        chat(
          sources: const [
            ChatSource(roomId: roomId, network: ChatNetwork.matrix),
          ],
          isGroup: true,
          title: 'Weekend plans',
        ),
        contact: contact(const [matrixHandle]),
      );

      expect((availability as CallBlocked).reason, CallBlocker.group);
      expect(availability.message, contains('one person at a time'));
    });

    test('a Matrix room with no resolved contact says so', () {
      // First sync, or a DM the identity graph has not caught up with. There is
      // a room to call in and nobody to name as the invitee, and inventing one
      // would ring whoever else is in the room.
      final availability = callAvailabilityFor(
        chat(
          sources: const [
            ChatSource(roomId: roomId, network: ChatNetwork.matrix),
          ],
        ),
      );

      expect((availability as CallBlocked).reason, CallBlocker.unknownPeer);
      expect(availability.message, contains('Matrix address'));
    });

    test('a contact whose Matrix leg is missing is not callable', () {
      // The chat has a Matrix source; the contact does not have a Matrix
      // handle. Both halves are required, which is why the target carries both.
      final availability = callAvailabilityFor(
        chat(
          sources: const [
            ChatSource(roomId: roomId, network: ChatNetwork.matrix),
          ],
        ),
        contact: contact(const [whatsappHandle]),
      );

      expect((availability as CallBlocked).reason, CallBlocker.unknownPeer);
    });
  });

  group('CallTarget', () {
    test('compares by value, so a rebuild is not a new target', () {
      const a = CallTarget(roomId: roomId, peer: peer);
      const b = CallTarget(roomId: roomId, peer: peer);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(
        a,
        isNot(const CallTarget(roomId: '!other:example.org', peer: peer)),
      );
    });
  });
}
