import 'package:meta/meta.dart';
import 'package:weft_domain/weft_domain.dart';

import 'call_session.dart';

/// Where a call placed from a conversation would go.
///
/// Both halves are needed and neither is derivable from the other: the room is
/// where the `m.call.*` events are sent, and the peer is who `invitee` names.
/// A conversation that can produce one of these can be called; one that cannot
/// is a [CallBlocked] with a sentence saying why.
@immutable
class CallTarget {
  const CallTarget({required this.roomId, required this.peer});

  /// The Matrix-native room. Deliberately taken from the chat's own source
  /// rather than from the peer's handle: a merged conversation's Matrix leg is
  /// the room the inbox already resolved, and the two must not be able to
  /// disagree.
  final String roomId;

  final CallPeer peer;

  @override
  bool operator ==(Object other) =>
      other is CallTarget && other.roomId == roomId && other.peer == peer;

  @override
  int get hashCode => Object.hash(roomId, peer);

  @override
  String toString() => 'CallTarget($roomId, ${peer.label})';
}

/// Whether a conversation can carry a call.
///
/// The companion of [CallPeer.forContact] and deliberately defined beside it:
/// that answers "is this *person* reachable by a call", this answers "is this
/// *conversation*", and the two are different questions with different failure
/// modes. A merged contact with a Matrix handle whose Matrix leg the user has
/// since left is callable as a person and not as a conversation.
///
/// [message] is user-facing in both cases, because the disabled call button
/// keeps its tooltip — a button that is greyed out with no explanation is
/// indistinguishable from one that is broken.
@immutable
sealed class CallAvailability {
  const CallAvailability();

  /// Non-null exactly when the call can be placed.
  CallTarget? get target;

  bool get isAvailable => target != null;

  /// The tooltip, whichever answer this is.
  String get message;
}

/// The conversation can carry a call, to [target].
final class CallReady extends CallAvailability {
  const CallReady(this.target);

  @override
  final CallTarget target;

  /// English, and a fallback: the app words [CallAvailability] itself from
  /// [target] and [CallBlocked.reason] — see
  /// `docs/architecture/l10n-pipeline.md`, "Packages and their words".
  @override
  String get message => 'Call ${target.peer.label}';
}

/// The conversation cannot carry a call, and [message] says why.
final class CallBlocked extends CallAvailability {
  const CallBlocked(this.reason, this.message, {this.networks = const []});

  final CallBlocker reason;

  /// The messengers named in the sentence, for the app to write its own.
  /// Empty for every reason but [CallBlocker.bridged].
  final List<ChatNetwork> networks;

  @override
  final String message;

  @override
  CallTarget? get target => null;
}

/// Why a conversation cannot carry a call.
///
/// Three reasons rather than one boolean because they are three different
/// sentences and only one of them is about bridging. Tests assert on these
/// rather than on the wording, so the sentences can be reworded without
/// breaking the rule they express.
enum CallBlocker {
  /// Every leg of the conversation is bridged. The remote party is a ghost
  /// user that will never answer an `m.call.invite`.
  bridged,

  /// More than two people. `weft_call` models 1:1 calls only.
  group,

  /// A Matrix room with nobody identifiable on the other end — a conversation
  /// the identity graph has not caught up with yet.
  unknownPeer,
}

/// Whether [chat] can carry a call, and where it would go.
///
/// [contact] is the merged identity behind the conversation, when the app has
/// resolved one. It is what puts the inbox's display name and avatar on the
/// call screen, and it is where the peer's Matrix user id comes from — a
/// [Chat] carries rooms, not people.
///
/// The order of the checks is the order the reasons matter in: a bridged group
/// is refused as a group, because "Braid calls one person at a time" stays true
/// however the room got there.
CallAvailability callAvailabilityFor(Chat chat, {UnifiedContact? contact}) {
  if (chat.isGroup) {
    return const CallBlocked(
      CallBlocker.group,
      'Braid calls one person at a time.',
    );
  }

  // Not "has a Matrix room id": a bridged WhatsApp conversation is a room on
  // the user's own homeserver and has one too. What decides it is whether the
  // inbox resolved a leg as Matrix-*native*, which `networkForRoom` does only
  // when no bridge state event and no ghost-localpart heuristic claims it.
  final source = chat.sourceFor(ChatNetwork.matrix);
  if (source == null) {
    return CallBlocked(
      CallBlocker.bridged,
      '${_networkNames(chat.networks)} '
      "can't carry calls — Braid calls over Matrix.",
      networks: chat.networks,
    );
  }

  final peer = contact == null ? null : CallPeer.forContact(contact);
  if (peer == null) {
    return const CallBlocked(
      CallBlocker.unknownPeer,
      "Braid doesn't know a Matrix address for this conversation yet.",
    );
  }

  return CallReady(CallTarget(roomId: source.roomId, peer: peer));
}

/// "WhatsApp", "WhatsApp and Signal", "WhatsApp, Signal and Telegram".
String _networkNames(List<ChatNetwork> networks) {
  final names = networks.map((n) => n.label).toList(growable: false);
  if (names.isEmpty) return 'This conversation';
  if (names.length == 1) return names.single;
  return '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
}
