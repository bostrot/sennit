import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_call/weft_call.dart';
import 'package:weft_design/weft_design.dart';

import 'package:weft/features/call/call_screen.dart';
import 'package:weft/features/call/incoming_call_sheet.dart';

import '../support/call_fixtures.dart';
import '../support/golden_harness.dart';

/// Goldens for the call surfaces built in Phase 07.
///
/// A call is the one screen in Weft that is never seen next to anything else,
/// and the one whose controls are pressed without being read — a hang-up found
/// by muscle memory, an accept found while the phone is coming out of a pocket.
/// So the things worth pinning here are proportions rather than strings: the
/// round controls all the same size and evenly spaced at a phone's width, the
/// hang-up red distinguishable from the accept green in both themes, the
/// self-view floating clear of the header, and the incoming sheet's answer row
/// still a row when a video call puts three buttons in it. None of that is
/// assertable, and all of it breaks silently.
///
/// Every scene is a [CallServiceState] and a [CallControls] and nothing else —
/// no homeserver, no peer connection, no audio session — which is what
/// `CallScreenBody` and `IncomingCallSheet` were split out of their wired shells
/// for. The fixtures are the ones the widget suites use, so an image here and an
/// assertion there describe the same call.
void main() {
  setUpAll(loadGoldenFonts);

  /// A phone. The call screen is laid out for the narrowest thing it runs on —
  /// on a desktop window the same controls sit in the middle of a wider surface,
  /// which is the case that cannot overflow.
  const phone = Size(420, 900);

  /// Pumps [child] under the fixed call clock and captures it in both themes.
  ///
  /// The clock matters more here than on any other golden: the header redraws
  /// the call's duration once a second from `clock.now()`, so an image taken
  /// against the wall clock disagrees with itself on the next run and fails a
  /// suite that changed nothing. [t0] is the same instant every call fixture
  /// starts from, so `connectedAt` differences are exact.
  ///
  /// Both themes from one fixture, for the reason the other golden suites state:
  /// the failure mode is a control that reads as engaged on one surface and
  /// invisible on the other, and only an identical scene in both shows it.
  Future<void> expectCallGolden(
    WidgetTester tester,
    String name,
    Widget Function() child, {
    Size size = phone,
  }) async {
    for (final (mode, suffix) in const [
      (WeftThemeMode.dark, 'dark'),
      (WeftThemeMode.light, 'light'),
    ]) {
      await withClock(Clock.fixed(t0), () async {
        await pumpWeft(tester, child(), size: size, mode: mode);

        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('${name}_$suffix.png'),
        );
      });
    }
  }

  testWidgets('a connected voice call, both themes', (tester) async {
    // The ordinary call, and the one the design has to get right: nothing but a
    // face, a name, a running duration and four controls. Anna is the merged
    // contact, so the avatar carries the same identity ring and network badges
    // the inbox row drew — a call placed from a conversation reached across
    // three networks should not suddenly look like a stranger.
    //
    // The codec line under the status is the only detail on screen, and it is
    // there because a call that connected on the wrong codec is otherwise
    // indistinguishable from one that did not connect at all.
    await expectCallGolden(
      tester,
      'call_voice_connected',
      () => CallScreenBody(
        state: serviceState(
          callSession(
            state: CallState.connected,
            peer: mergedAnnaPeer,
            connectedAt: t0.subtract(const Duration(minutes: 1, seconds: 5)),
            codecs: const CodecSummary(audio: 'opus'),
          ),
          ice: turnAvailable,
        ),
        controls: RecordingControls(),
        onClose: () {},
      ),
    );
  });

  testWidgets('a connected voice call with no relay, both themes', (
    tester,
  ) async {
    // A self-hosted Synapse with no `turn_uris` is the common case, not an
    // exotic one, and the SDK's behaviour is to say nothing and give the user a
    // call that works at home and nowhere else. Weft's answer is this sentence,
    // and a sentence of that length under a name is exactly the thing that
    // pushes a layout around — which is why it is an image rather than only an
    // assertion that the string is present.
    //
    // Still connecting, deliberately: the warning is only shown while the call
    // is trying, because once media is flowing the missing relay has stopped
    // mattering and a warning that stays up all call is one nobody reads next
    // time.
    await expectCallGolden(
      tester,
      'call_voice_no_relay',
      () => CallScreenBody(
        state: serviceState(
          callSession(state: CallState.connecting, peer: mergedAnnaPeer),
          ice: turnMissing,
        ),
        controls: RecordingControls(),
        onClose: () {},
      ),
    );
  });

  testWidgets('a connected video call, both themes', (tester) async {
    // The remote picture fills the screen and everything else floats over it, so
    // this is the scene where contrast is the whole problem: white-on-black
    // header text over a picture that could be any colour, and a self-view that
    // has to clear the header without covering the far end's face.
    //
    // Both video surfaces draw their placeholder rather than a texture — a
    // widget test has no platform behind an `RTCVideoRenderer`, and
    // [CallVideoView] declines to create one when there is no stream to point it
    // at. That is not a compromise: it is also precisely what a real video call
    // shows in the second between answering and the first frame.
    //
    // The control bar differs from the voice one in two places, and both are
    // visible here: "Add video" has become the camera toggle, and the camera
    // switch has appeared beside it.
    await expectCallGolden(
      tester,
      'call_video_connected',
      () => CallScreenBody(
        state: serviceState(
          callSession(
            state: CallState.connected,
            peer: mergedAnnaPeer,
            video: true,
            connectedAt: t0.subtract(const Duration(seconds: 12)),
            codecs: const CodecSummary(audio: 'opus', video: 'VP8'),
          ),
          video: const NoPictures(),
          ice: turnAvailable,
        ),
        controls: RecordingControls(),
        onClose: () {},
      ),
    );
  });

  testWidgets('an incoming voice call, both themes', (tester) async {
    // The full-screen sheet, which is what a phone must show — a call that
    // arrived as a card at the top of the inbox is a call that gets missed. Two
    // buttons, as far apart as the row allows, in the two colours that exist for
    // nothing else. The name is the merged one for the same reason the inbox is:
    // the person calling is Anna, not `@anna:example.org`.
    await expectCallGolden(
      tester,
      'call_incoming_voice',
      () => IncomingCallSheet(
        session: ringingSession(peer: mergedAnnaPeer),
        controls: RecordingControls(),
      ),
    );
  });

  testWidgets('an incoming video call, both themes', (tester) async {
    // The same sheet with a third answer in it, because taking a video call on
    // audio only is a first-class choice rather than a fallback — without it the
    // alternative to being seen is declining. Three labelled buttons is the
    // narrowest thing this row ever has to hold, and the case where it would
    // overflow a small phone without anyone noticing until it did.
    await expectCallGolden(
      tester,
      'call_incoming_video',
      () => IncomingCallSheet(
        session: ringingSession(peer: mergedAnnaPeer, video: true),
        controls: RecordingControls(),
      ),
    );
  });
}
