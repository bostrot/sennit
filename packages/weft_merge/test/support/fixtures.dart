import 'package:weft_domain/weft_domain.dart';

/// Builds a message with only the fields the merge logic cares about.
WeftMessage msg(
  String roomId,
  ChatNetwork network,
  int epochSeconds, {
  String? eventId,
  String body = '',
}) {
  return WeftMessage(
    eventId: eventId ?? '\$${roomId}_$epochSeconds',
    roomId: roomId,
    network: network,
    senderId: '@peer:example.org',
    senderName: 'Peer',
    timestamp: DateTime.fromMillisecondsSinceEpoch(
      epochSeconds * 1000,
      isUtc: true,
    ),
    kind: MessageKind.text,
    isOwn: false,
    body: body,
  );
}

/// Builds a handle with sensible defaults so each test states only what it
/// actually exercises.
NetworkHandle handle(
  String id,
  ChatNetwork network, {
  String? displayName,
  String? phone,
  String? email,
  int? avatarDHash,
  String? remoteId,
  String? roomId,
  String? contactId,
}) {
  return NetworkHandle(
    id: id,
    network: network,
    remoteId: remoteId ?? id,
    matrixUserId: '@${network.id}_$id:example.org',
    roomId: roomId ?? '!room_$id:example.org',
    displayName: displayName,
    phoneE164: phone,
    email: email,
    avatarDHash: avatarDHash,
    unifiedContactId: contactId,
  );
}
