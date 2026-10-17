import 'package:weft_domain/weft_domain.dart';
import 'package:weft_notify/weft_notify.dart';

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
  String? formattedBody,
  String? transcript,
  bool redacted = false,
  bool isBridgeNotice = false,
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
    formattedBody: formattedBody,
    transcript: transcript,
    redacted: redacted,
    isBridgeNotice: isBridgeNotice,
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
  ChatRequestState? request,
}) {
  return Chat(
    id: id,
    title: title,
    muted: muted,
    isGroup: isGroup,
    avatarUrl: avatarUrl,
    request: request,
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

/// Calls [evaluateNotification] with the fixture user and a default policy, so
/// each test states only the rule it is about.
///
/// Lives here rather than in one test file because `rules_test.dart` and
/// `dedupe_test.dart` both ask questions of the same entry point. A second copy
/// would be a second set of defaults to keep in step, and a rule that fired
/// only in one file's defaults would look like a real difference between the
/// two suites.
NotificationDecision decide({
  WeftMessage? message,
  Chat? forChat,
  NotificationPolicy? policy,
  DateTime? at,
  DateTime? lastReadAt,
  NotificationDedupe? dedupe,
  bool isFirstFromSender = true,
  bool chatOpen = false,
}) {
  return evaluateNotification(
    message: message ?? msg(),
    chat: forChat ?? chat(),
    policy: policy ?? NotificationPolicy(),
    now: at ?? now,
    lastReadAt: lastReadAt,
    ownUserIds: ownUserIds,
    ownDisplayNames: ownDisplayNames,
    dedupe: dedupe,
    isFirstFromSender: isFirstFromSender,
    chatOpen: chatOpen,
  );
}

/// Why [decision] posted nothing, or null when it delivers. Named so an
/// expectation reads as the rule it is about.
NotificationSuppression? reasonFor(NotificationDecision decision) =>
    decision.suppression;

/// A 22:00 → 07:00 window, the default a settings screen would offer.
QuietHours nightly({
  int offsetMinutes = 0,
  bool deliverSilently = false,
  bool allowMentions = true,
}) => QuietHours(
  startMinute: 22 * 60,
  endMinute: 7 * 60,
  offsetMinutes: offsetMinutes,
  allowMentions: allowMentions,
  deliverSilently: deliverSilently,
);

/// An instant inside [nightly]: 23:30 UTC on the fixture evening.
final DateTime midnightish = DateTime.utc(2026, 1, 15, 23, 30);
