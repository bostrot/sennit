## 0.1.1

- Added `callAvailabilityFor(chat, contact:)`, `CallTarget` and
  `CallAvailability` — the conversation-level companion of
  `CallPeer.forContact`. A conversation is callable only when the inbox
  resolved a Matrix-*native* leg for it, which is not the same as having a
  Matrix room id: a bridged WhatsApp chat has one too, and a bridge ghost never
  answers an `m.call.invite`. Groups are refused separately, because
  `weft_call` models 1:1 calls only.

## 0.1.0

- Fixed: an incoming invite arriving after a previous call ended inherited that
  call's state, including its two *closed* [IceCandidateBuffer]s. Every
  candidate arriving before the answer of a session's second incoming call was
  silently discarded, which is the LAN-only failure the buffer exists to
  prevent. `_startIncoming` now always starts from a reset.
- Fixed: `RequestVideoUpgrade` told the media engine to start or stop capturing
  without moving `CallSession.cameraOn`, so the camera button and the local
  preview disagreed with the camera for the length of a renegotiation, and the
  undo on `NegotiationFailed` undid nothing.
- Test suites for the state machine, glare, candidate ordering and
  renegotiation (`test/`, 114 tests), asserting on emitted signalling intents
  as well as states so the wire behaviour is pinned.
- Initial version: `CallState`, `CallEndReason`, `CallSession` / `CallPeer`,
  the `m.call.*` signalling event and intent vocabulary, `CallStateMachine`,
  `IceCandidateBuffer` and the injected `MediaEngine` interface.
- Records the decision not to wrap the Matrix SDK's VoIP stack, and what that
  gives up, in the library doc comment of `lib/weft_call.dart`.
