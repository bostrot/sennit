import 'package:weft_domain/weft_domain.dart';

/// A fixed "now" every test can reason against: 2026-01-15 21:00 UTC.
///
/// Wall-clock times matter here — quiet hours are a time of day — so the
/// fixtures pin an instant rather than calling `DateTime.now()`, which would
/// make the suite pass or fail depending on when it runs.
final DateTime now = DateTime.utc(2026, 1, 15, 21);

/// A message with only what the rules care about; everything else defaulted.
WeftMessage msg({
  String eventId = r'$event_1',
  String roomId = '!room:example.org',
  ChatNetwork network = ChatNetwork.whatsapp,
  String senderId = '@whatsapp_grace:example.org',
  String senderName = 'Grace',
  DateTime? timestamp,
  MessageKind kind = MessageKind.text,
  bool isOwn = false,
  String body = 'hello',
  String? transcript,
  bool redacted = false,
}) {
  return WeftMessage(
    eventId: eventId,
    roomId: roomId,
    network: network,
    senderId: senderId,
    senderName: senderName,
    timestamp: timestamp ?? now,
    kind: kind,
    isOwn: isOwn,
    body: body,
    transcript: transcript,
    redacted: redacted,
  );
}

/// A single-source chat.
Chat chat({
  String id = '!room:example.org',
  String title = 'Grace',
  ChatNetwork network = ChatNetwork.whatsapp,
  bool muted = false,
  bool sourceMuted = false,
  bool isGroup = false,
  String? avatarUrl,
}) {
  return Chat(
    id: id,
    title: title,
    muted: muted,
    isGroup: isGroup,
    avatarUrl: avatarUrl,
    sources: [ChatSource(roomId: id, network: network, muted: sourceMuted)],
  );
}

/// A merged chat: one contact, two legs, the `merged:` id the repository
/// produces.
Chat mergedChat({
  String contactId = 'contact_1',
  String title = 'Grace',
  String whatsappRoomId = '!wa:example.org',
  String signalRoomId = '!sg:example.org',
  bool muted = false,
  bool whatsappMuted = false,
  bool signalMuted = false,
  String? avatarUrl,
}) {
  return Chat(
    id: 'merged:$contactId',
    title: title,
    contactId: contactId,
    muted: muted,
    avatarUrl: avatarUrl,
    sources: [
      ChatSource(
        roomId: whatsappRoomId,
        network: ChatNetwork.whatsapp,
        muted: whatsappMuted,
      ),
      ChatSource(
        roomId: signalRoomId,
        network: ChatNetwork.signal,
        muted: signalMuted,
      ),
    ],
  );
}

/// The user, as the rules see them.
const Set<String> ownUserIds = {'@ada:example.org', '@whatsapp_me:example.org'};
const Set<String> ownDisplayNames = {'Ada Lovelace', 'Ada'};
