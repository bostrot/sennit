import 'package:collection/collection.dart';
import 'package:meta/meta.dart';
import 'package:weft_attachments/weft_attachments.dart' show messageKindFor;
import 'package:weft_domain/weft_domain.dart';

import 'phone.dart';

/// Synthetic room id for the SMS thread [threadId].
///
/// SMS has no rooms, but every layer above `weft_domain` addresses a
/// conversation by one — the merged timeline, the notification ledger and the
/// search index all key on `roomId`. Minting one here is what lets an SMS thread
/// travel the same path as a bridged chat instead of needing a parallel one.
///
/// The `sms:` scheme is deliberately not a Matrix id: a real room id starts `!`
/// and a real event id `$`, so anything that mixes the two namespaces up is
/// visible on sight rather than after a failed federation call.
String smsRoomId(String threadId) => '$kSmsRoomIdPrefix$threadId';

/// The prefix every [smsRoomId] carries.
const String kSmsRoomIdPrefix = 'sms:thread:';

/// Whether [roomId] names an SMS thread rather than a Matrix room.
///
/// A predicate on the string rather than a lookup in whatever holds the threads,
/// because the question is asked at exactly the moments the answer is not yet
/// known: routing a send before the provider has been read, or opening a
/// timeline for a deep link into a thread that has not synced. A lookup would
/// answer "no" for those and send an SMS to a homeserver.
bool isSmsRoomId(String roomId) => roomId.startsWith(kSmsRoomIdPrefix);

/// Synthetic event id for the SMS provider row [messageId].
String smsEventId(String messageId) => 'sms:msg:$messageId';

/// Stable identity-graph id for an SMS [number].
///
/// Keyed on the normalised number rather than a provider row id, so re-reading
/// the same thread upserts the one handle instead of growing a new one on every
/// sync.
String smsHandleId(PhoneNumber number) => 'sms:${number.value}';

/// Synthetic "ghost user" for an SMS [number].
///
/// [NetworkHandle.matrixUserId] is required and is the identity graph's second
/// key, so a value is needed even though no homeserver has ever heard of this
/// person. The shape mirrors a bridge ghost localpart (`@sms_+44…:local`) on
/// purpose: `normalizePhone` already knows how to read a number back out of that
/// form, so this id degrades to the right answer wherever it is treated like any
/// other handle's.
String smsGhostUserId(PhoneNumber number) => '@sms_${number.value}:local';

/// `Telephony.Sms.Sent.TYPE` values, as the system provider stores them.
///
/// Named here rather than passed around as bare integers because the mapping in
/// [smsDeliveryState] is the interesting part and a magic `5` in the repository
/// would hide it.
abstract final class SmsProviderType {
  static const int inbox = 1;
  static const int sent = 2;
  static const int draft = 3;
  static const int outbox = 4;
  static const int failed = 5;
  static const int queued = 6;
}

/// `Telephony.Sms.STATUS_*` — what the delivery report said, when one was asked
/// for and one came back.
abstract final class SmsProviderStatus {
  /// No delivery report was requested, or none has arrived. The common case:
  /// most carriers charge for reports and most users never turn them on.
  static const int none = -1;
  static const int complete = 0;
  static const int pending = 32;
  static const int failed = 64;
}

/// Maps a provider row's type and status onto Weft's [DeliveryState].
///
/// Two things here are not obvious and are the reason this is a function rather
/// than a switch inlined at the call site:
///
/// - **An incoming message has no delivery state at all.** `null` is the answer
///   for [SmsProviderType.inbox], not [DeliveryState.sent] — the ticks belong to
///   messages the user sent, and painting them on a received bubble is wrong in
///   a way that looks deliberate.
/// - **[DeliveryState.read] is unreachable.** SMS has no read receipts. A thread
///   being read is local state; it never travels, and nothing may claim the
///   other person saw the message. That gap is exactly what the composer's
///   plaintext indicator is about: SMS tells you less than every other network
///   in the inbox, and the UI must not paper over it.
DeliveryState? smsDeliveryState({
  required int type,
  int status = SmsProviderStatus.none,
}) {
  switch (type) {
    case SmsProviderType.inbox:
    case SmsProviderType.draft:
      return null;
    case SmsProviderType.outbox:
    case SmsProviderType.queued:
      return DeliveryState.sending;
    case SmsProviderType.failed:
      return DeliveryState.failed;
    case SmsProviderType.sent:
      return switch (status) {
        SmsProviderStatus.complete => DeliveryState.delivered,
        SmsProviderStatus.failed => DeliveryState.failed,
        // Pending means the report was requested and has not landed; the
        // handset still handed the message to the network, so it is sent.
        _ => DeliveryState.sent,
      };
    default:
      return null;
  }
}

/// One SMS or MMS as the system provider holds it, before it becomes a
/// [WeftMessage].
///
/// A value type rather than a map because the mapping is where the mistakes are,
/// and a mapping that takes a typed input can be tested without a provider.
@immutable
class SmsMessage {
  const SmsMessage({
    required this.id,
    required this.threadId,
    required this.address,
    required this.timestamp,
    required this.isOutgoing,
    this.body = '',
    this.subject,
    this.deliveryState,
    this.attachmentUri,
    this.attachmentMimeType,
    this.attachmentSizeBytes,
  });

  /// The provider row's `_id`.
  final String id;

  /// The provider's `thread_id`.
  final String threadId;

  /// The other party's number **exactly as the provider stored it** — national
  /// format, spaces, short code or alphanumeric sender id. Normalising is
  /// [PhoneNumberParser]'s job and happens at the identity edge, not here: the
  /// raw string is what a user recognises when parsing fails.
  final String address;

  final DateTime timestamp;
  final bool isOutgoing;

  /// Message text. Empty for an MMS that carries only an attachment.
  final String body;

  /// The MMS subject line, when one was set. Rare, and shown above the body.
  final String? subject;

  /// Delivery state for an outgoing message; null for a received one. Build it
  /// with [smsDeliveryState] rather than by hand.
  final DeliveryState? deliveryState;

  /// `content://mms/part/<id>` for the first attachment, when this is an MMS.
  ///
  /// One attachment, not a list, because [WeftMessage] carries one and the
  /// timeline draws one bubble. A multi-part MMS is rare enough — and its extra
  /// parts are usually the SMIL layout and a text part already folded into
  /// [body] — that a list would be structure for a case that does not arrive.
  final String? attachmentUri;

  final String? attachmentMimeType;
  final int? attachmentSizeBytes;

  bool get hasAttachment => attachmentUri != null;

  /// The message as the rest of Weft sees it.
  ///
  /// [senderName] is what the contacts lookup resolved, and falls back to the
  /// raw [address]: a number with no name is still a better label than an empty
  /// one, and it is what every other SMS app shows.
  WeftMessage toWeftMessage({String? senderName}) {
    final mime = attachmentMimeType;
    return WeftMessage(
      eventId: smsEventId(id),
      roomId: smsRoomId(threadId),
      network: ChatNetwork.sms,
      senderId: address,
      senderName: senderName ?? address,
      timestamp: timestamp,
      kind: mime == null ? MessageKind.text : messageKindFor(mime),
      isOwn: isOutgoing,
      body: subject == null || subject!.isEmpty ? body : '$subject\n$body',
      deliveryState: deliveryState,
      attachmentUrl: attachmentUri,
      mediaSizeBytes: attachmentSizeBytes,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SmsMessage &&
      other.id == id &&
      other.body == body &&
      other.deliveryState == deliveryState;

  @override
  int get hashCode => Object.hash(id, body, deliveryState);

  @override
  String toString() =>
      'SmsMessage($id in $threadId @ ${timestamp.toIso8601String()})';
}

/// One conversation in the system SMS provider, before it becomes a [Chat].
@immutable
class SmsThread {
  const SmsThread({
    required this.id,
    required this.addresses,
    this.title,
    this.snippet,
    this.unreadCount = 0,
    this.lastMessageAt,
    this.archived = false,
    this.e164 = const {},
  });

  /// The provider's `thread_id`.
  final String id;

  /// Every participant's address as the provider stored it, self excluded.
  ///
  /// More than one means a group MMS. Empty is possible for a corrupt row and is
  /// not an error worth throwing over — such a thread simply has no handles.
  final List<String> addresses;

  /// A resolved display name for the thread, when contacts supplied one.
  final String? title;

  /// The provider's `snippet` — the last message's text, already truncated.
  final String? snippet;

  final int unreadCount;
  final DateTime? lastMessageAt;
  final bool archived;

  /// Each address the platform could read as a full number, in E.164.
  ///
  /// Android formats these with its own copy of libphonenumber against the
  /// SIM's country, which is the region `0151 1234567` was dialled in. Kept
  /// beside [addresses] rather than replacing them: a reply goes to the number
  /// as the provider stored it, and the provider files it by that spelling.
  final Map<String, String> e164;

  /// [address] in E.164 when the platform knew it, else as stored.
  String normalizedAddress(String address) => e164[address] ?? address;

  bool get isGroup => addresses.length > 1;

  String get roomId => smsRoomId(id);

  /// This thread as one leg of a [Chat].
  ///
  /// [handleId] is the identity-graph handle from [linkSmsIdentity], when the
  /// address parsed; passing it is what lets a merged chat find its SMS leg.
  ChatSource source({String? handleId}) =>
      ChatSource(roomId: roomId, network: ChatNetwork.sms, handleId: handleId);

  /// The thread as an inbox entry.
  ///
  /// Single-source by construction. Folding it together with the WhatsApp chat
  /// for the same number is not done here — that is the merge engine's decision,
  /// reached from the evidence [linkSmsIdentity] contributes, and a chat that
  /// merged itself would bypass the confirmation the user is owed.
  Chat toChat({WeftMessage? lastMessage, String? contactId, String? handleId}) {
    return Chat(
      id: roomId,
      title: title ?? addresses.join(', '),
      sources: [source(handleId: handleId)],
      contactId: contactId,
      lastMessage: lastMessage,
      unreadCount: unreadCount,
      isGroup: isGroup,
      archived: archived,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SmsThread &&
      other.id == id &&
      other.title == title &&
      other.snippet == snippet &&
      other.unreadCount == unreadCount &&
      other.archived == archived &&
      const ListEquality<String>().equals(other.addresses, addresses) &&
      const MapEquality<String, String>().equals(other.e164, e164);

  @override
  int get hashCode => Object.hash(
    id,
    title,
    snippet,
    unreadCount,
    archived,
    const ListEquality<String>().hash(addresses),
  );

  @override
  String toString() => 'SmsThread($id, ${addresses.length} participants)';
}
