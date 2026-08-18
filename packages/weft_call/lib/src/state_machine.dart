import 'package:meta/meta.dart';

import 'call_session.dart';
import 'call_state.dart';
import 'ice_candidate_buffer.dart';
import 'sdp.dart';
import 'signalling.dart';

/// What one input did.
///
/// Returned rather than pushed onto a stream so that a test asserts on the
/// result of a single call instead of collecting from a subscription, and so
/// that the intents are unambiguously the ones caused by *that* input.
@immutable
class CallTransition {
  const CallTransition({
    required this.from,
    required this.to,
    required this.session,
    required this.intents,
  });

  final CallState from;
  final CallState to;

  /// The session after the input, or null when there is no call.
  final CallSession? session;

  /// Everything the caller must now do, in order.
  final List<CallIntent> intents;

  bool get changedState => from != to;

  /// The subset that goes on the Matrix wire. This is what pins the protocol
  /// behaviour, and what the phase's tests assert on.
  List<SignallingIntent> get signalling =>
      intents.whereType<SignallingIntent>().toList(growable: false);

  /// The subset for the media engine.
  List<MediaIntent> get media =>
      intents.whereType<MediaIntent>().toList(growable: false);

  /// True when the input was recognised but deliberately did nothing — a
  /// signal for a call we do not have, an expired invite, an action that makes
  /// no sense in this state. Distinguishing "ignored" from "handled" is what
  /// makes a silent drop assertable.
  bool get isNoOp => !changedState && intents.isEmpty;

  @override
  String toString() =>
      'CallTransition(${from.name} -> ${to.name}, ${intents.length} intent(s))';
}

/// The rules of a 1:1 Matrix call, with no WebRTC and no I/O.
///
/// One machine drives at most one call. Enforcing one-call-at-a-time *inside*
/// the machine rather than above it is what makes "busy" a protocol behaviour —
/// a second invite gets an `m.call.reject` with `user_busy` — instead of a UI
/// state the far end never learns about.
///
/// Time is injected. Every deadline in a call is tens of seconds long, and a
/// machine that read `DateTime.now()` itself would make the invite-timeout test
/// a minute-long sleep, which is the same as not having one.
class CallStateMachine {
  CallStateMachine({
    required this.localUserId,
    required this.localPartyId,
    DateTime Function()? clock,
    this.supportedVersions = const {'0', '1'},
    this.endingGrace = const Duration(seconds: 5),
  }) : _clock = clock ?? DateTime.now;

  /// This user, used to discard invites addressed to somebody else.
  final String localUserId;

  /// This device's `party_id`, stamped on every event we send. Stable for the
  /// lifetime of the session — MSC2746 identifies devices by it, and a party id
  /// that changed mid-call would look to the far end like a second device.
  final String localPartyId;

  /// Call versions this build understands. An invite outside the set is
  /// ignored, per MSC2746, rather than rejected: a client speaking a dialect
  /// from the future may well have sent the same invite in a version we do
  /// understand, and rejecting would cancel that one too.
  final Set<String> supportedVersions;

  /// How long [CallState.ending] may last before the machine gives up waiting
  /// for [MediaDisposed] and moves to [CallState.ended] on the next [Tick].
  ///
  /// Without this, an engine that throws during teardown leaves the call screen
  /// saying "Ending…" forever, which is a worse failure than a slightly early
  /// dismissal.
  final Duration endingGrace;

  final DateTime Function() _clock;

  CallState _state = CallState.idle;
  CallSession? _session;

  /// The far end's offer, held from the invite until it is answered.
  SessionDescription? _remoteOffer;

  final IceCandidateBuffer _remoteCandidates = IceCandidateBuffer();
  final IceCandidateBuffer _localCandidates = IceCandidateBuffer();

  /// True once `m.call.invite` or `m.call.answer` is on the wire, which is when
  /// local candidates may start flowing.
  bool _localDescriptionSent = false;

  /// True once the peer connection has the far end's description and remote
  /// candidates can be applied instead of buffered.
  bool _remoteDescriptionApplied = false;

  DateTime? _inviteSentAt;
  DateTime? _inviteReceivedAt;
  Duration _inviteLifetime = kDefaultInviteLifetime;
  DateTime? _endingSince;

  _Negotiation? _negotiation;

  CallState get state => _state;

  /// The current call, or null when idle. Survives into [CallState.ended] so
  /// the UI can say who the call was with and why it stopped.
  CallSession? get session => _session;

  /// Candidates waiting for a peer connection. Exposed for diagnostics and for
  /// the phase's candidate ordering tests.
  IceCandidateBuffer get bufferedRemoteCandidates => _remoteCandidates;

  /// Feed one input and get back what changed.
  CallTransition handle(CallInput input) {
    final from = _state;
    final intents = <CallIntent>[];
    switch (input) {
      case final CallSignal signal:
        _onSignal(signal, intents);
      case final CallAction action:
        _onAction(action, intents);
    }
    return CallTransition(
      from: from,
      to: _state,
      session: _session,
      intents: List.unmodifiable(intents),
    );
  }

  /// Convenience for [Tick].
  CallTransition tick() => handle(const Tick());

  // -------------------------------------------------------------------------
  // Inbound signalling.
  // -------------------------------------------------------------------------

  void _onSignal(CallSignal signal, List<CallIntent> out) {
    if (signal is CallInviteSignal) {
      _onInvite(signal, out);
      return;
    }

    // Everything other than an invite is about a call we should already know.
    final call = _session;
    if (call == null || call.callId != signal.callId) return;

    // Once a party is latched, signalling from any other device on the far end
    // is not ours to act on — that is what stops a second device's candidates
    // from being fed into a peer connection negotiated with the first. Before
    // it is latched there is nothing to compare against, and the answer is what
    // sets it. `select_answer` is exempt because it is the *caller* telling us
    // which of our own devices won, so it arrives from a party we never latch.
    final latched = call.remotePartyId;
    if (latched != null &&
        signal.partyId != latched &&
        signal is! CallSelectAnswerSignal) {
      return;
    }

    switch (signal) {
      case CallAnswerSignal():
        _onAnswer(signal, out);
      case CallCandidatesSignal():
        _onCandidates(signal, out);
      case CallSelectAnswerSignal():
        _onSelectAnswer(signal, out);
      case CallHangupSignal():
        if (_state.isTerminal) return;
        _endCall(
          CallEndReason.fromWire(signal.reason, isReject: false),
          out,
          notifyRemote: false,
        );
      case CallRejectSignal():
        if (_state.isTerminal) return;
        _endCall(
          CallEndReason.fromWire(signal.reason, isReject: true),
          out,
          notifyRemote: false,
        );
      case CallNegotiateSignal():
        _onNegotiate(signal, out);
      case CallInviteSignal():
        break; // handled above
    }
  }

  void _onInvite(CallInviteSignal invite, List<CallIntent> out) {
    if (!supportedVersions.contains(invite.version)) return;
    if (invite.invitee != null && invite.invitee != localUserId) return;

    // An invite that already timed out must never ring. This is the common case
    // after a period offline: sync delivers every call from the last hour at
    // once, and without this the phone rings for all of them.
    final now = _clock();
    if (now.difference(invite.sentAt) >= invite.lifetime) return;

    final existing = _session;
    if (existing != null && _state.isLive) {
      if (_state == CallState.outgoingRinging &&
          existing.roomId == invite.roomId) {
        _resolveGlare(invite, existing, out);
        return;
      }
      // Busy. Reject rather than ignore, so the caller stops ringing at once
      // instead of waiting out the full invite lifetime.
      out.add(
        SendReject(
          callId: invite.callId,
          partyId: localPartyId,
          reason: CallEndReason.userBusy,
        ),
      );
      return;
    }

    _startIncoming(invite, out);
  }

  /// Both parties dialled at the same moment. Exactly one call may survive, and
  /// both sides have to pick the same one without talking about it.
  ///
  /// The rule is a lexical comparison of call ids, lowest wins — the same rule
  /// the Matrix SDK applies, which is what matters: a rule that is merely
  /// deterministic is not enough if the far end is Element and disagrees.
  void _resolveGlare(
    CallInviteSignal invite,
    CallSession ours,
    List<CallIntent> out,
  ) {
    if (invite.callId.compareTo(ours.callId) > 0) {
      // Ours is lower, so ours survives. Hang up theirs — hangup rather than
      // reject, and `unknown_error` rather than a glare-specific reason,
      // because MSC2746 defines neither and this is what the SDK sends.
      out.add(
        SendHangup(
          callId: invite.callId,
          partyId: localPartyId,
          reason: CallEndReason.glareLost,
        ),
      );
      return;
    }

    // Theirs is lower. Abandon ours and ring for theirs. Both intents go out in
    // this order deliberately: the hangup must precede anything about the new
    // call, or a far end that processes them out of order sees a hangup for the
    // call it just started.
    out.add(
      SendHangup(
        callId: ours.callId,
        partyId: localPartyId,
        reason: CallEndReason.glareLost,
      ),
    );
    out.add(const DisposeMedia());
    _startIncoming(invite, out);
  }

  void _startIncoming(CallInviteSignal invite, List<CallIntent> out) {
    // Always from a clean slate, whatever was here before — the previous call
    // that just ended, or the one this invite has taken the place of after
    // glare. Inheriting its state is not cosmetic: [_endCall] *closes* both
    // candidate buffers, so a second call that reused them would discard every
    // candidate arriving before the answer and connect on a LAN and nowhere
    // else. That is the same silent failure [IceCandidateBuffer] exists to
    // prevent, arriving by the back door.
    _resetCallState();

    _remoteOffer = invite.offer;
    _inviteReceivedAt = invite.sentAt;
    _inviteLifetime = invite.lifetime;
    _session = CallSession(
      callId: invite.callId,
      partyId: localPartyId,
      roomId: invite.roomId,
      peer: CallPeer(matrixUserId: invite.senderId),
      direction: CallDirection.incoming,
      state: CallState.ringing,
      startedAt: _clock(),
      remotePartyId: invite.partyId.isEmpty ? null : invite.partyId,
      videoEnabled: invite.video,
      cameraOn: invite.video,
    );
    _state = CallState.ringing;
    _syncSessionState();
  }

  void _onAnswer(CallAnswerSignal answer, List<CallIntent> out) {
    final call = _session!;
    if (_state != CallState.outgoingRinging) {
      // A second device answering after we already committed. MSC2746 has us
      // ignore it; `m.call.select_answer` has already told it to stop.
      return;
    }

    // Commit to this device before anything else, so any other device that
    // answers learns immediately that it lost.
    out.add(
      SendSelectAnswer(
        callId: call.callId,
        partyId: localPartyId,
        selectedPartyId: answer.partyId,
      ),
    );
    out.add(ApplyRemoteDescription(answer.answer));
    _remoteDescriptionApplied = true;

    _session = call.copyWith(
      remotePartyId: answer.partyId,
      state: CallState.connecting,
    );
    _state = CallState.connecting;

    _flushRemoteCandidates(out);
  }

  void _onCandidates(CallCandidatesSignal signal, List<CallIntent> out) {
    if (_state == CallState.ending || _state.isTerminal) {
      // The buffer is already closed; go through it anyway so the drop is
      // counted and diagnosable.
      _remoteCandidates.addAll(signal.candidates);
      return;
    }
    if (_remoteDescriptionApplied && _state.hasPeerConnection) {
      for (final candidate in signal.candidates) {
        out.add(AddRemoteCandidate(candidate));
      }
      return;
    }
    _remoteCandidates.addAll(signal.candidates);
  }

  void _onSelectAnswer(CallSelectAnswerSignal signal, List<CallIntent> out) {
    // Only meaningful on the answering side: the caller picked a device, and if
    // it was not this one, this one stops. Without it, a call answered on a
    // phone keeps a laptop's microphone open for the whole conversation.
    final call = _session!;
    if (call.isOutgoing) return;
    if (!_localDescriptionSent) return;
    if (signal.selectedPartyId == localPartyId) return;
    _endCall(CallEndReason.answeredElsewhere, out, notifyRemote: false);
  }

  void _onNegotiate(CallNegotiateSignal signal, List<CallIntent> out) {
    if (_state != CallState.connected && _state != CallState.onHold) return;

    switch (signal.description.type) {
      case SdpType.offer:
        // The far end wants to change the session — adding video, typically.
        // Answered automatically: WebRTC requires a prompt answer, and the
        // user-facing "accept video?" gate belongs in the UI, which decides
        // whether to send its own camera rather than whether to renegotiate.
        _negotiation = _Negotiation.remoteOffer(video: signal.video);
        out.add(
          CreateAnswer(remoteOffer: signal.description, video: signal.video),
        );
      case SdpType.answer:
        // The answer to a renegotiation we started.
        final pending = _negotiation;
        out.add(ApplyRemoteDescription(signal.description));
        if (pending != null) {
          _applyNegotiationResult(pending, out);
        }
        _negotiation = null;
    }
  }

  // -------------------------------------------------------------------------
  // Local actions.
  // -------------------------------------------------------------------------

  void _onAction(CallAction action, List<CallIntent> out) {
    switch (action) {
      case PlaceCall():
        _onPlaceCall(action, out);
      case AcceptCall():
        _onAcceptCall(action, out);
      case DeclineCall():
        if (_state != CallState.ringing) return;
        _endCall(CallEndReason.localReject, out, notifyRemote: true);
      case HangUp():
        if (!_state.isLive) return;
        _endCall(action.reason, out, notifyRemote: true);
      case MediaFailed():
        if (!_state.isLive) return;
        _endCall(action.reason, out, notifyRemote: true);
      case SetMuted():
        _onSetMuted(action, out);
      case SetSpeaker():
        final call = _session;
        if (call == null || !_state.isLive) return;
        if (call.speakerOn == action.speakerOn) return;
        _session = call.copyWith(speakerOn: action.speakerOn);
      case SetCameraEnabled():
        _onSetCamera(action, out);
      case SwitchCamera():
        if (_session == null || !_state.hasPeerConnection) return;
        out.add(const ApplySwitchCamera());
      case RequestVideoUpgrade():
        _onRequestVideoUpgrade(action, out);
      case SetHold():
        _onSetHold(action, out);
      case LocalDescriptionReady():
        _onLocalDescription(action, out);
      case LocalCandidate():
        _onLocalCandidate(action, out);
      case MediaConnected():
        _onMediaConnected(action, out);
      case NegotiationFailed():
        _onNegotiationFailed(out);
      case MediaDisposed():
        if (_state != CallState.ending) return;
        _state = CallState.ended;
        _endingSince = null;
        _syncSessionState();
      case Tick():
        _onTick(out);
    }
  }

  void _onPlaceCall(PlaceCall action, List<CallIntent> out) {
    if (_state != CallState.idle && _state != CallState.ended) return;
    _resetCallState();
    _session = CallSession(
      callId: action.callId,
      partyId: localPartyId,
      roomId: action.roomId,
      peer: action.peer,
      direction: CallDirection.outgoing,
      state: CallState.outgoingRinging,
      startedAt: _clock(),
      videoEnabled: action.video,
      cameraOn: action.video,
    );
    _state = CallState.outgoingRinging;
    out.add(CreateOffer(video: action.video));
  }

  void _onAcceptCall(AcceptCall action, List<CallIntent> out) {
    if (_state != CallState.ringing) return;
    final call = _session!;
    final offer = _remoteOffer;
    if (offer == null) return;

    // Answering with audio only is allowed and is not a downgrade of the call:
    // the far end keeps sending video, we simply do not send ours.
    final video = action.video ?? call.videoEnabled;
    _session = call.copyWith(state: CallState.connecting, cameraOn: video);
    _state = CallState.connecting;
    out.add(CreateAnswer(remoteOffer: offer, video: video));

    // createAnswer applies the offer, so the peer connection has the remote
    // description from here and buffered candidates can go in.
    _remoteDescriptionApplied = true;
    _flushRemoteCandidates(out);
  }

  void _onSetMuted(SetMuted action, List<CallIntent> out) {
    final call = _session;
    if (call == null || !_state.isLive) return;
    if (call.muted == action.muted) return;
    _session = call.copyWith(muted: action.muted);
    out.add(ApplyMute(action.muted));
  }

  void _onSetCamera(SetCameraEnabled action, List<CallIntent> out) {
    final call = _session;
    if (call == null || !_state.isLive) return;
    if (call.cameraOn == action.enabled) return;
    _session = call.copyWith(cameraOn: action.enabled);
    out.add(ApplyVideo(action.enabled));
  }

  void _onRequestVideoUpgrade(
    RequestVideoUpgrade action,
    List<CallIntent> out,
  ) {
    final call = _session;
    if (call == null) return;
    if (_state != CallState.connected && _state != CallState.onHold) return;
    if (call.videoEnabled == action.video) return;
    if (_negotiation != null) return; // one renegotiation at a time

    _negotiation = _Negotiation.localVideo(video: action.video);
    // Enable capture before offering, so the offer describes a track that
    // exists. Offering video and then failing to open the camera produces an
    // answer for media that never arrives, which the far end shows as a frozen
    // black rectangle rather than an error.
    //
    // [CallSession.cameraOn] moves with it, because it means "the engine has
    // been told to capture" everywhere else — [SetCameraEnabled] sets the two
    // together — and a flag that disagreed with the engine for the length of a
    // renegotiation would put the local preview and the camera button out of
    // step with the camera. It is also what makes the undo in
    // [_onNegotiationFailed] undo something.
    _session = call.copyWith(cameraOn: action.video);
    out.add(ApplyVideo(action.video));
    out.add(CreateOffer(video: action.video));
  }

  void _onSetHold(SetHold action, List<CallIntent> out) {
    final call = _session;
    if (call == null) return;
    final holding = _state == CallState.onHold;
    if (holding == action.onHold) return;
    if (_state != CallState.connected && _state != CallState.onHold) return;
    if (_negotiation != null) return;

    _negotiation = _Negotiation.hold(onHold: action.onHold);
    _state = action.onHold ? CallState.onHold : CallState.connected;
    _syncSessionState();
    // Hold is signalled by re-offering with the media direction changed, which
    // is the media engine's business; from here it is an ordinary
    // renegotiation.
    out.add(CreateOffer(video: call.videoEnabled));
  }

  void _onLocalDescription(LocalDescriptionReady action, List<CallIntent> out) {
    final call = _session;
    if (call == null) return;
    final description = action.description;

    // A renegotiation in flight takes precedence: mid-call descriptions travel
    // in `m.call.negotiate`, never in a second invite or answer.
    if (_negotiation != null &&
        _state.hasPeerConnection &&
        _localDescriptionSent) {
      out.add(
        SendNegotiate(
          callId: call.callId,
          partyId: localPartyId,
          description: description,
          lifetime: kDefaultCallEventLifetime,
          video: _negotiation!.video ?? call.videoEnabled,
        ),
      );
      if (description.type == SdpType.answer) {
        // We answered the far end's renegotiation, so it is already settled.
        _applyNegotiationResult(_negotiation!, out);
        _negotiation = null;
      }
      return;
    }

    switch (description.type) {
      case SdpType.offer:
        if (_state != CallState.outgoingRinging || _localDescriptionSent) {
          return;
        }
        _inviteSentAt = _clock();
        _inviteLifetime = kDefaultInviteLifetime;
        out.add(
          SendInvite(
            callId: call.callId,
            partyId: localPartyId,
            roomId: call.roomId,
            offer: description,
            lifetime: _inviteLifetime,
            video: call.videoEnabled,
          ),
        );
      case SdpType.answer:
        if (_state != CallState.connecting || call.isOutgoing) return;
        out.add(
          SendAnswer(
            callId: call.callId,
            partyId: localPartyId,
            answer: description,
            video: call.cameraOn && call.videoEnabled,
          ),
        );
    }
    _localDescriptionSent = true;
    _flushLocalCandidates(out);
  }

  void _onLocalCandidate(LocalCandidate action, List<CallIntent> out) {
    final call = _session;
    if (call == null || _state == CallState.ending || _state.isTerminal) return;
    if (!_localDescriptionSent) {
      // The far end does not know this call exists yet. Candidates gathered now
      // are the host ones — the fastest path there is — so holding them is
      // worth more than the alternative of dropping them.
      _localCandidates.add(action.candidate);
      return;
    }
    out.add(
      SendCandidates(
        callId: call.callId,
        partyId: localPartyId,
        candidates: [action.candidate],
      ),
    );
  }

  void _onMediaConnected(MediaConnected action, List<CallIntent> out) {
    if (_state != CallState.connecting) return;
    final call = _session!;
    _session = call.copyWith(
      state: CallState.connected,
      connectedAt: _clock(),
      codecs: action.codecs,
    );
    _state = CallState.connected;
  }

  void _onNegotiationFailed(List<CallIntent> out) {
    final pending = _negotiation;
    _negotiation = null;
    if (pending == null) return;
    final call = _session;
    if (call == null) return;

    // The call itself is unharmed — this is the whole reason renegotiation is
    // separate from the call's lifecycle. Undo the optimistic local change and
    // stay on whatever was already negotiated.
    if (pending.kind == _NegotiationKind.localVideo) {
      out.add(ApplyVideo(call.videoEnabled));
      _session = call.copyWith(cameraOn: call.videoEnabled);
    }
    if (pending.kind == _NegotiationKind.hold) {
      _state = pending.onHold == true ? CallState.connected : CallState.onHold;
      _syncSessionState();
    }
  }

  void _onTick(List<CallIntent> out) {
    final now = _clock();

    if (_state == CallState.ending) {
      final since = _endingSince;
      if (since != null && now.difference(since) >= endingGrace) {
        _state = CallState.ended;
        _endingSince = null;
        _syncSessionState();
      }
      return;
    }

    if (_state == CallState.outgoingRinging) {
      final sentAt = _inviteSentAt;
      if (sentAt != null && now.difference(sentAt) >= _inviteLifetime) {
        _endCall(CallEndReason.inviteTimeout, out, notifyRemote: true);
      }
      return;
    }

    if (_state == CallState.ringing) {
      final receivedAt = _inviteReceivedAt;
      if (receivedAt != null && now.difference(receivedAt) >= _inviteLifetime) {
        // Stop ringing, but say nothing: the caller is running the same timer
        // and is about to hang up. A reject here would race that hangup and
        // land in the room as a second call-ended event.
        _endCall(CallEndReason.inviteTimeout, out, notifyRemote: false);
      }
      return;
    }
  }

  // -------------------------------------------------------------------------
  // Shared endings.
  // -------------------------------------------------------------------------

  void _endCall(
    CallEndReason reason,
    List<CallIntent> out, {
    required bool notifyRemote,
  }) {
    final call = _session;
    if (call == null || _state == CallState.ending || _state.isTerminal) return;

    if (notifyRemote) {
      // Reject before we have answered, hangup after. The distinction is
      // visible to the far end: a rejected call shows as declined, a hung-up
      // one as ended, and getting it backwards is how "I never picked up" turns
      // into a call log entry that says otherwise.
      final rejecting =
          _state == CallState.ringing || reason == CallEndReason.userBusy;
      out.add(
        rejecting
            ? SendReject(
                callId: call.callId,
                partyId: localPartyId,
                reason: reason,
              )
            : SendHangup(
                callId: call.callId,
                partyId: localPartyId,
                reason: reason,
              ),
      );
    }

    out.add(const DisposeMedia());
    _remoteCandidates.close();
    _localCandidates.close();
    _negotiation = null;
    _endingSince = _clock();
    _state = CallState.ending;
    _session = call.copyWith(state: CallState.ending, endReason: reason);
  }

  void _flushRemoteCandidates(List<CallIntent> out) {
    for (final candidate in _remoteCandidates.flush()) {
      out.add(AddRemoteCandidate(candidate));
    }
  }

  void _flushLocalCandidates(List<CallIntent> out) {
    final call = _session;
    final pending = _localCandidates.flush();
    if (call == null || pending.isEmpty) return;
    out.add(
      SendCandidates(
        callId: call.callId,
        partyId: localPartyId,
        candidates: pending,
      ),
    );
  }

  void _applyNegotiationResult(_Negotiation pending, List<CallIntent> out) {
    final call = _session;
    if (call == null) return;
    final video = pending.video;
    if (video != null && call.videoEnabled != video) {
      _session = call.copyWith(videoEnabled: video, cameraOn: video);
    }
  }

  /// Keep [CallSession.state] in step with the machine's own state. They are
  /// two copies of one fact on purpose — a widget holds the session, not the
  /// machine — and this is the single place they are reconciled.
  void _syncSessionState() {
    final call = _session;
    if (call == null || call.state == _state) return;
    _session = call.copyWith(state: _state);
  }

  void _resetCallState() {
    _remoteOffer = null;
    _remoteCandidates.reopen();
    _localCandidates.reopen();
    _localDescriptionSent = false;
    _remoteDescriptionApplied = false;
    _inviteSentAt = null;
    _inviteReceivedAt = null;
    _inviteLifetime = kDefaultInviteLifetime;
    _endingSince = null;
    _negotiation = null;
    _session = null;
    _state = CallState.idle;
  }
}

enum _NegotiationKind { localVideo, remoteOffer, hold }

/// A renegotiation in flight. At most one exists at a time — WebRTC allows
/// exactly one offer/answer exchange to be outstanding, and a second would be
/// rejected by the peer connection with an error the user cannot act on.
@immutable
class _Negotiation {
  const _Negotiation._(this.kind, {this.video, this.onHold});

  factory _Negotiation.localVideo({required bool video}) =>
      _Negotiation._(_NegotiationKind.localVideo, video: video);

  factory _Negotiation.remoteOffer({required bool video}) =>
      _Negotiation._(_NegotiationKind.remoteOffer, video: video);

  factory _Negotiation.hold({required bool onHold}) =>
      _Negotiation._(_NegotiationKind.hold, onHold: onHold);

  final _NegotiationKind kind;

  /// The video state this renegotiation is trying to reach, or null when it is
  /// not about video.
  final bool? video;

  final bool? onHold;
}
