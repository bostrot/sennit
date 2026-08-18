## 0.1.0

- Initial version: `CallState`, `CallEndReason`, `CallSession` / `CallPeer`,
  the `m.call.*` signalling event and intent vocabulary, `CallStateMachine`,
  `IceCandidateBuffer` and the injected `MediaEngine` interface.
- Records the decision not to wrap the Matrix SDK's VoIP stack, and what that
  gives up, in the library doc comment of `lib/weft_call.dart`.
