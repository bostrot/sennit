/// 1:1 voice and video calling, decided in pure Dart.
///
/// Everything a call gets wrong is in here and none of it needs a device: which
/// of two simultaneous invites survives, whether a candidate that arrived early
/// is applied or silently lost, whether an upgrade to video that fails takes the
/// call down with it, and whether an invite that has been sitting in a sync
/// backlog for two minutes rings the phone. Those are the bugs that otherwise
/// get debugged with two handsets and a stopwatch.
///
/// The seam is [MediaEngine]: WebRTC, the microphone and the camera live behind
/// it, in the app. Above it, [CallStateMachine] takes parsed `m.call.*` events
/// and local actions and answers with state plus a list of intents. It performs
/// no I/O at all, which is what makes the whole of calling's behaviour
/// assertable from a unit test.
///
/// ## Why this is not a wrapper around the SDK's VoIP stack
///
/// The `matrix` package Weft already depends on ships a complete 1:1 VoIP
/// implementation, and the orientation for this phase recommended wrapping it
/// rather than writing this. That recommendation was considered and not taken.
/// The reasons, so that the next person to weigh it has them:
///
///  * **The SDK's 7,200 VoIP lines are mostly not 1:1 calling.** Group calls,
///    the LiveKit and mesh backends and the E2EE key ratchet make up the bulk of
///    it, and Weft ships none of them. The 1:1 signalling core this package
///    replaces is a few hundred lines of decisions, not thousands.
///  * **Every layer above was specified against these types.** The Matrix
///    signalling map, the call service, the call screen and the platform call
///    integrations are all written to `weft_call`'s events and states. Wrapping
///    would have meant a mapping layer of comparable size to this package,
///    with the additional property that Weft's UI would be driven by another
///    project's internal state enum.
///  * **A `matrix` dependency would not have been free.** It is pure Dart, so
///    the package would still run under `dart test`, but the fast, hermetic
///    tests that are this package's entire justification would then depend on
///    the SDK's own lifecycle.
///
/// What is given up by not wrapping, stated plainly rather than discovered
/// later: `m.call.sdp_stream_metadata_changed`, `m.call.replaces` (transfer),
/// `m.call.asserted_identity`, and the SDK's accumulated SDP munging for
/// platform quirks. Hold is modelled here as a state and a renegotiation;
/// transfer is not modelled at all. Where behaviour is observable on the wire —
/// glare resolution, the busy reason, the party-id rules — this package
/// deliberately matches what the SDK does, because the far end is usually
/// Element and being merely self-consistent would not be enough.
library;

// Consumers import this barrel, never src/.
export 'src/call_availability.dart';
export 'src/call_session.dart';
export 'src/call_state.dart';
export 'src/ice_candidate_buffer.dart';
export 'src/media_engine.dart';
export 'src/sdp.dart';
export 'src/signalling.dart';
export 'src/state_machine.dart';
