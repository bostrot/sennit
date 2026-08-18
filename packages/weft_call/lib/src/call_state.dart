/// Where a call is, as the UI needs to see it.
///
/// Eight states, deliberately fewer than WebRTC's or the Matrix SDK's ten: the
/// distinctions this enum drops — "waiting for local media" vs "creating the
/// offer" vs "invite sent" — are all the same screen with the same spinner, and
/// a state the UI cannot render is a state that can only be got wrong.
///
/// The reason a call ended is *not* a member here, because a Dart enum cannot
/// carry one. It lives on [CallSession.endReason], which is non-null exactly
/// when the state is [ending] or [ended].
enum CallState {
  /// No call. The only state from which an outgoing call may be placed and an
  /// incoming invite may be accepted.
  idle,

  /// An invite arrived and the phone is ringing. Nothing has been sent back.
  ringing,

  /// We placed the call: the offer is being created, or the invite is on the
  /// wire and no answer has come back yet. One state rather than two because
  /// the user sees "Calling…" throughout.
  outgoingRinging,

  /// Both sides have committed — the answer exists — and ICE is still working.
  /// This is the state a call sits in while media has not yet flowed.
  connecting,

  /// Media is flowing. The duration timer starts here.
  connected,

  /// Connected but deliberately suspended by this side.
  onHold,

  /// Teardown has begun: the hangup or reject is on the wire and the media
  /// engine is being disposed. Observable on purpose — "Ending…" is a real
  /// frame of the call screen, and a call that hangs here is a bug worth
  /// seeing rather than one hidden inside a synchronous transition.
  ending,

  /// Terminal. [CallSession.endReason] says why.
  ended;

  /// True while a call exists and the user is in it or being asked about it.
  bool get isLive => switch (this) {
    idle || ending || ended => false,
    ringing || outgoingRinging || connecting || connected || onHold => true,
  };

  /// True once media has been negotiated and the peer connection is expected
  /// to exist, which is what decides whether a remote candidate can be applied
  /// immediately or has to be buffered.
  bool get hasPeerConnection => switch (this) {
    connecting || connected || onHold || ending => true,
    idle || ringing || outgoingRinging || ended => false,
  };

  /// True once no further transition can produce a live call.
  bool get isTerminal => this == ended;
}

/// Why a call ended.
///
/// Split finer than the wire is, because "they hung up" and "I hung up" are the
/// same `m.call.hangup` with the same `user_hangup` reason and are completely
/// different sentences to show a user. [wireReason] folds them back down when
/// the value has to go out as an event.
enum CallEndReason {
  /// This side ended an established or outgoing call.
  userHangup('user_hangup'),

  /// The other side ended it.
  remoteHangup('user_hangup'),

  /// This side declined a ringing call.
  localReject('user_hangup'),

  /// The other side declined before answering.
  remoteReject('user_hangup'),

  /// A call was already in progress, so the new invite was refused. Sent as
  /// `m.call.reject` with this reason, matching what the Matrix SDK does when
  /// its delegate refuses a second call.
  userBusy('user_busy'),

  /// Nobody answered within the invite's lifetime.
  inviteTimeout('invite_timeout'),

  /// Another of this user's devices answered, named by `m.call.select_answer`.
  answeredElsewhere('answered_elsewhere'),

  /// Two invites crossed and this one lost the lexical comparison of call ids.
  ///
  /// MSC2746 defines no reason code for glare, so this goes out as
  /// `unknown_error` — which is also what the Matrix SDK sends, and matching it
  /// is what keeps the loser's hangup from confusing an Element on the far end.
  glareLost('unknown_error'),

  /// ICE never succeeded. Overwhelmingly this means the homeserver offers no
  /// TURN server and the two parties are not on the same network.
  iceFailed('ice_failed'),

  /// The microphone or camera could not be opened.
  mediaFailed('user_media_failed'),

  /// The call was replaced by a transfer.
  replaced('replaced'),

  /// Anything else, including a signalling failure.
  unknownError('unknown_error');

  const CallEndReason(this.wireReason);

  /// The `reason` field of the outgoing `m.call.hangup` or `m.call.reject`.
  final String wireReason;

  /// True when the call failed rather than being ended by a person. The call
  /// screen shows these; it does not announce an ordinary hangup.
  bool get isFailure => switch (this) {
    iceFailed || mediaFailed || unknownError || glareLost => true,
    userHangup ||
    remoteHangup ||
    localReject ||
    remoteReject ||
    userBusy ||
    inviteTimeout ||
    answeredElsewhere ||
    replaced => false,
  };

  /// Interpret the `reason` of an inbound hangup or reject.
  ///
  /// The wire reason is ambiguous by construction — `user_hangup` is sent by
  /// both a hangup and a reject — so the caller must say which event carried
  /// it. Unknown reasons map to [remoteHangup] rather than [unknownError]: a
  /// newer client sending a reason this build has never heard of still ended
  /// the call deliberately, and calling that a failure would be a lie.
  static CallEndReason fromWire(String? reason, {required bool isReject}) {
    switch (reason) {
      case 'user_busy':
        return CallEndReason.userBusy;
      case 'invite_timeout':
        return CallEndReason.inviteTimeout;
      case 'answered_elsewhere':
        return CallEndReason.answeredElsewhere;
      case 'ice_failed':
      case 'ice_timeout':
        return CallEndReason.iceFailed;
      case 'user_media_failed':
        return CallEndReason.mediaFailed;
      case 'replaced':
      case 'transferred':
        return CallEndReason.replaced;
      default:
        return isReject ? CallEndReason.remoteReject : CallEndReason.remoteHangup;
    }
  }
}
