import 'package:weft_domain/weft_domain.dart';
import 'package:weft_snapshot/weft_snapshot.dart';

/// A fixed "now" every test builds against: 2026-04-01 09:00 UTC.
///
/// `buildSnapshot` takes `now` as an argument precisely so the suite can pin
/// it, and staleness is measured against it — a fixture calling
/// `DateTime.now()` would make [InboxSnapshot.isStaleAt] assertions depend on
/// the hour the test happened to run.
final DateTime now = DateTime.utc(2026, 4, 1, 9);

/// [d] before [now]. Reads at the call site as the age the test is about.
DateTime ago(Duration d) => now.subtract(d);

/// A message with only what the snapshot reads; everything else defaulted.
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
  );
}

/// A chat carrying only what the policy and the row builder read.
///
/// [networks] becomes one [ChatSource] per network, which is what makes a
/// multi-network chat *merged* as far as [Chat.isMerged] and [Chat.networks]
/// are concerned. Room ids are derived: nothing in this package reads them, and
/// naming them in every fixture would be sixteen strings that never appear in
/// an assertion.
Chat chat({
  String id = '!room:example.org',
  String title = 'Grace',
  List<ChatNetwork> networks = const [ChatNetwork.whatsapp],
  WeftMessage? lastMessage,
  int unreadCount = 0,
  String? avatarUrl,
  bool isGroup = false,
}) {
  return Chat(
    id: id,
    title: title,
    unreadCount: unreadCount,
    avatarUrl: avatarUrl,
    isGroup: isGroup,
    lastMessage: lastMessage,
    sources: [
      for (final network in networks)
        ChatSource(roomId: '$id/${network.id}', network: network),
    ],
  );
}

/// A merged chat: one contact, two legs, and the `merged:<contactId>` id the
/// repository mints — the id a row must key on rather than re-derive.
Chat mergedChat({
  String contactId = 'contact_1',
  String title = 'Grace',
  List<ChatNetwork> networks = const [ChatNetwork.whatsapp, ChatNetwork.signal],
  WeftMessage? lastMessage,
  int unreadCount = 0,
  String? avatarUrl,
}) {
  return Chat(
    id: 'merged:$contactId',
    title: title,
    contactId: contactId,
    unreadCount: unreadCount,
    avatarUrl: avatarUrl,
    lastMessage: lastMessage,
    sources: [
      for (final network in networks)
        ChatSource(
          roomId: '!${network.id}_$contactId:example.org',
          network: network,
        ),
    ],
  );
}

/// The policy with everything the surfaces screen can turn on, turned on.
///
/// Named rather than repeated because most tests are about one *other* thing —
/// the row cap, an exclusion, a truncation — and want the content flags out of
/// the way. The redaction tests do the opposite and name the flag they clear.
const SnapshotPolicy fullPolicy = SnapshotPolicy(
  enabled: true,
  includePreviews: true,
  includeSenderNames: true,
);

/// [chats] through the real entry point at the fixed [now].
InboxSnapshot build(
  List<Chat> chats, {
  SnapshotPolicy policy = fullPolicy,
  DateTime? at,
}) => buildSnapshot(chats: chats, policy: policy, now: at ?? now);

/// The preview a single chat's row would carry under [policy].
///
/// The shorthand most preview tests want: they are about `renderSnapshotPreview`
/// and `truncatePreview`, but asserting through `buildSnapshot` is what proves
/// the row builder actually calls them.
String? previewOf(WeftMessage? message, {SnapshotPolicy policy = fullPolicy}) =>
    build([chat(lastMessage: message)], policy: policy).rows.single.preview;

/// Whether [text] contains a UTF-16 code unit that is half of a surrogate pair
/// with no other half — the exact damage a `substring` cut through an emoji
/// does, and what a widget renders as `�` until the next message arrives.
///
/// Written out rather than inferred from `runes`, which happily yields a lone
/// surrogate's own value and so cannot tell a broken string from an intact one.
bool hasUnpairedSurrogate(String text) {
  final units = text.codeUnits;
  for (var i = 0; i < units.length; i++) {
    final unit = units[i];
    final isHigh = unit >= 0xD800 && unit <= 0xDBFF;
    final isLow = unit >= 0xDC00 && unit <= 0xDFFF;
    if (isHigh) {
      final next = i + 1 < units.length ? units[i + 1] : 0;
      if (next < 0xDC00 || next > 0xDFFF) return true;
      i++;
    } else if (isLow) {
      return true;
    }
  }
  return false;
}
