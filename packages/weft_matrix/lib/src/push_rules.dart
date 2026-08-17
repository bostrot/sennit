import 'package:matrix/matrix.dart' as sdk;
import 'package:meta/meta.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_notify/weft_notify.dart';

/// One room whose server-side push rule disagrees with Weft's policy.
@immutable
class PushRuleChange {
  const PushRuleChange({required this.roomId, required this.muted});

  final String roomId;

  /// True to install the `dont_notify` override, false to remove it.
  final bool muted;

  @override
  bool operator ==(Object other) =>
      other is PushRuleChange && other.roomId == roomId && other.muted == muted;

  @override
  int get hashCode => Object.hash(roomId, muted);

  @override
  String toString() =>
      'PushRuleChange($roomId → ${muted ? 'dont_notify' : 'notify'})';
}

/// Reads and writes the account's per-room push rules.
///
/// A seam for the same reason the upload path has one: `Room.setPushRuleState`
/// needs a `Room`, which needs a `Client`, which needs a database — none of
/// which is required to test *which* rooms should be muted.
abstract class MatrixPushRuleTarget {
  /// Reads through to a live client.
  const factory MatrixPushRuleTarget.forClient(sdk.Client client) =
      _ClientPushRuleTarget;

  /// Whether the homeserver currently suppresses notifications for [roomId].
  ///
  /// Null for a room the client has not synced, which is not the same as
  /// "not muted": writing a rule for a room in that state would be writing
  /// against state we have not read.
  bool? isMuted(String roomId);

  Future<void> setMuted(String roomId, {required bool muted});
}

class _ClientPushRuleTarget implements MatrixPushRuleTarget {
  const _ClientPushRuleTarget(this._client);

  final sdk.Client _client;

  @override
  bool? isMuted(String roomId) {
    final room = _client.getRoomById(roomId);
    if (room == null) return null;
    return room.pushRuleState != sdk.PushRuleState.notify;
  }

  @override
  Future<void> setMuted(String roomId, {required bool muted}) async {
    final room = _client.getRoomById(roomId);
    if (room == null) return;
    // The same call `ChatRepository.setMuted` makes. It installs an *override*
    // rule whose id is the room id with an empty action list, which is Matrix's
    // way of spelling "never push for this room".
    await room.setPushRuleState(
      muted ? sdk.PushRuleState.dontNotify : sdk.PushRuleState.notify,
    );
  }
}

/// Which rooms' server-side push rules should change so the homeserver stops
/// pushing for things Weft would only throw away.
///
/// The division of labour this implements: **the homeserver's push rules
/// suppress the push; [NotificationPolicy] suppresses the display.** They are
/// not the same thing and must not be conflated. A push that arrives and is
/// then dropped locally costs a radio wake-up and nothing else; a push that is
/// never sent cannot be un-dropped when the user changes their mind an hour
/// later. So only suppression that is *unconditional and durable* is pushed
/// down to the server, and everything else is left to the local evaluation.
///
/// Three consequences, each of which is a rule below:
///
/// - **A mute a mention can break through is never sent to the server.** With
///   [NotificationPolicy.mentionsBypassMute] on — the default — a mention in a
///   muted chat is supposed to reach the user. If the homeserver has been told
///   not to push for that room, the phone is asleep and the mention arrives
///   whenever the app next syncs, which may be hours. The mute is applied
///   locally instead, where the body is in hand and the mention can be seen.
/// - **A disabled network is sent**, because [NotificationPolicy.disabledNetworks]
///   is not bypassable by anything. That is the distinction that makes
///   `disabledNetworks` and `mutedNetworks` two fields rather than one.
/// - **Global disable and quiet hours are never sent.** Push rules live in the
///   *account's* data and every client the user runs obeys them. Writing quiet
///   hours into them would silence their laptop's Element at 23:00 because Weft
///   is installed on their phone, and switching Weft's master toggle off would
///   stop their other clients notifying at all. Both are this app's display
///   preference and stay on this app's side of the line.
///
/// Unmuting is deliberately narrow. Weft cannot tell a rule it wrote from one
/// another client wrote — they are the same rule, keyed by room id — so it only
/// lifts a mute whose *own* record has lapsed: a timed mute (Weft-only, since
/// Matrix push rules have no expiry) whose expiry has passed, with nothing else
/// in the policy still asking for silence. Anything else is left alone, because
/// clearing someone's Element mute is a worse failure than leaving a stale rule
/// that the settings screen can show them.
List<PushRuleChange> planPushRuleSync({
  required NotificationPolicy policy,
  required Iterable<Chat> chats,
  required DateTime now,
  required bool? Function(String roomId) isServerMuted,
}) {
  final changes = <PushRuleChange>[];

  for (final chat in chats) {
    final override = policy.overrideFor(chat.id);

    for (final source in chat.sources) {
      final serverMuted = isServerMuted(source.roomId);
      // Unsynced room: no readable state to reconcile against.
      if (serverMuted == null) continue;

      final wanted = _shouldServerMute(
        policy: policy,
        override: override,
        network: source.network,
        now: now,
      );

      if (wanted && !serverMuted) {
        changes.add(PushRuleChange(roomId: source.roomId, muted: true));
        continue;
      }
      if (!wanted &&
          serverMuted &&
          _hasLapsedTimedMute(override, now) &&
          !override.muted) {
        changes.add(PushRuleChange(roomId: source.roomId, muted: false));
      }
    }
  }

  return changes;
}

/// Whether the homeserver should be told to stop pushing for a room on
/// [network] belonging to a chat with [override].
bool _shouldServerMute({
  required NotificationPolicy policy,
  required ChatNotificationOverride override,
  required ChatNetwork network,
  required DateTime now,
}) {
  // Off is off: nothing bypasses a disabled network, so the push is pure waste.
  if (!policy.isNetworkEnabled(network)) return true;

  // Everything below here is a *mute*, which a mention may be entitled to break
  // through. When it is, the decision has to be made where the body is
  // readable — which is not the homeserver.
  if (policy.mentionsBypassMute) return false;

  return policy.isNetworkMuted(network) || override.isMutedAt(now);
}

/// Whether the only mute this chat ever had was a timed one that has run out.
bool _hasLapsedTimedMute(ChatNotificationOverride override, DateTime now) {
  final until = override.mutedUntil;
  return until != null && !now.isBefore(until);
}

/// Applies [planPushRuleSync] against a live account.
///
/// Kept apart from the planner so the interesting half — which rooms, and why —
/// is testable without a homeserver, and this half is a loop.
class MatrixPushRuleSync {
  const MatrixPushRuleSync(this._target);

  final MatrixPushRuleTarget _target;

  /// Brings the homeserver's rules in line with [policy] and returns what it
  /// changed.
  ///
  /// Failures are per room and non-fatal: one room whose rule write is refused
  /// must not stop the other nineteen, and the next reconcile will try it
  /// again because the plan is recomputed from server state rather than
  /// remembered.
  Future<List<PushRuleChange>> reconcile({
    required NotificationPolicy policy,
    required Iterable<Chat> chats,
    required DateTime now,
  }) async {
    final planned = planPushRuleSync(
      policy: policy,
      chats: chats,
      now: now,
      isServerMuted: _target.isMuted,
    );

    final applied = <PushRuleChange>[];
    for (final change in planned) {
      try {
        await _target.setMuted(change.roomId, muted: change.muted);
        applied.add(change);
      } on Exception {
        // Left for the next pass.
      }
    }
    return applied;
  }
}
