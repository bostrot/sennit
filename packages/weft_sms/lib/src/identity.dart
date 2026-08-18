import 'package:weft_domain/weft_domain.dart';

import 'phone.dart';
import 'thread.dart';

/// The identity-graph evidence that an SMS [address] is a person.
///
/// Returns a [NetworkHandle] to hand to `IdentityGraph.upsertHandle`, or null
/// when [address] is not a number that can identify anybody.
///
/// **There is no new evidence type here, and that is the point.** The merge
/// engine already reasons in `NetworkHandle`s: `MergeScorer.score` normalises
/// `phoneE164 ?? remoteId` on both sides and raises `MergeSignal.phoneExact`
/// when they agree, which alone clears the 0.55 suggestion threshold at 0.95. So
/// an SMS thread from `+441234567890` and a WhatsApp handle for the same number
/// become a suggestion in the existing merge screen, with the existing "Same
/// phone number" explanation, without a line of merge code changing.
///
/// [phoneE164] is set explicitly rather than left for the scorer to recover from
/// [remoteId]. It would match either way — but the merge UI shows the field, and
/// evidence the user can read is evidence they will act on.
///
/// A suggestion is all this produces. `MergeScoringConfig.autoMergeOnIdentitySignal`
/// stays at its `false` default: SMS is the one network where a number is
/// recycled, spoofed, or shared by a household, and a silent auto-merge on a
/// wrong number mixes two people's conversations with nothing on screen to
/// suggest it happened.
///
/// Null is returned for:
///
/// - a short code — `20202` is a bank, an aggregator, or three of each, and is
///   never one person;
/// - an alphanumeric sender id (`Vodafone`), which has no number at all;
/// - a national-format number with no region on the [parser] to anchor it,
///   because the alternative is guessing a country code and merging strangers.
NetworkHandle? linkSmsIdentity(
  String address, {
  PhoneNumberParser parser = const PhoneNumberParser(),
  String? displayName,
  String? threadId,
}) {
  final number = parser.parse(address);
  if (number == null || number.isShortCode) return null;

  return NetworkHandle(
    id: smsHandleId(number),
    network: ChatNetwork.sms,
    remoteId: number.value,
    matrixUserId: smsGhostUserId(number),
    roomId: threadId == null ? null : smsRoomId(threadId),
    displayName: displayName,
    phoneE164: number.value,
  );
}

/// Evidence for every participant in [thread] that resolves to a real number.
///
/// A group MMS contributes one handle per member, each linked to the thread's
/// room — the same shape a bridged group produces, which is what lets a group
/// SMS thread take part in merging rather than sitting outside it. Participants
/// that do not resolve are dropped rather than turned into placeholder handles:
/// a handle with no number is a node the scorer can only ever match on name.
List<NetworkHandle> linkSmsThreadIdentities(
  SmsThread thread, {
  PhoneNumberParser parser = const PhoneNumberParser(),
}) {
  return thread.addresses
      .map(
        (address) => linkSmsIdentity(
          address,
          parser: parser,
          threadId: thread.id,
          // A group thread's title names the group, not the member, so it is
          // deliberately not borrowed here; a 1:1 thread's title is resolved by
          // the caller from contacts, which is the only place a name for this
          // number honestly exists.
          displayName: thread.isGroup ? null : thread.title,
        ),
      )
      .nonNulls
      .toList(growable: false);
}
