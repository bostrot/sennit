import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_call/weft_call.dart';
import 'package:weft_design/weft_design.dart';

import 'package:flutter/semantics.dart';

import '../../app/a11y.dart';
import '../../app/call_providers.dart';
import '../../app/providers.dart';
import '../../services/call/call_service.dart';
import 'call_controls.dart';
import 'call_labels.dart';
import 'call_screen.dart';
import 'incoming_call_sheet.dart';

/// Above this width an incoming call is a card rather than the whole screen.
///
/// A phone must be taken over — a call that arrived as a banner over the inbox
/// is a call that gets missed. A desktop window must not be: the user is in the
/// middle of something, and Weft is one of the things on their screen rather
/// than the thing.
const double kCallHeadsUpBreakpoint = 700;

/// Everything a call puts on screen that is not the call screen itself.
///
/// Installed once, above the navigator, so it holds for every route: an
/// incoming call must appear over an open chat, over the settings, over a share
/// sheet. It is also the single place that decides *when* a call surface
/// appears — the screens themselves are pure — which is what keeps two of them
/// from being shown at once.
///
/// Three surfaces, one rule each:
///
///  * a ringing incoming call takes the screen, or shows a heads-up card on a
///    window wide enough that taking it over would be rude;
///  * a call that becomes live opens the call screen, whether it started here
///    or was answered from a banner;
///  * a live call whose screen is not up shows the minimised bar, which is how
///    the user gets back to it.
class CallOverlay extends ConsumerStatefulWidget {
  const CallOverlay({super.key, required this.child, this.navigatorKey});

  final Widget child;

  /// The app's navigator, because this widget sits *above* it and
  /// `Navigator.of(context)` would therefore find nothing. Optional so the
  /// overlay can be pumped on its own in a test.
  final GlobalKey<NavigatorState>? navigatorKey;

  @override
  ConsumerState<CallOverlay> createState() => _CallOverlayState();
}

class _CallOverlayState extends ConsumerState<CallOverlay> {
  /// The call the screen has already been opened for, so a rebuild — or the
  /// several state changes a call makes per second while ICE settles — does not
  /// push a second copy.
  String? _opened;

  void _onCallChanged(CallServiceState? previous, CallServiceState next) {
    final before = previous?.session;
    final call = next.session;

    if (call == null || !call.state.isLive) {
      if (call == null || call.callId != _opened) _opened = null;
      return;
    }

    // Ringing is the incoming surface's business, and it is drawn inline —
    // which is the problem worth fixing here rather than there. Nothing pushes
    // a route, so nothing moves the reader's focus: the sheet simply appears
    // over whatever they were reading, and the first they hear of a call is the
    // ringtone with no statement of who it is from. An assertive announcement
    // is what a route change would have given them.
    if (call.state == CallState.ringing) {
      if (call.isIncoming && before?.callId != call.callId) {
        announce(
          context,
          '${call.peer.label} is calling. '
          '${call.videoEnabled ? 'Video call' : 'Voice call'}. '
          'Accept or decline below.',
          level: Assertiveness.assertive,
        );
      }
      return;
    }
    if (_opened == call.callId) return;

    // Either an outgoing call just went out, or a ringing one was answered.
    // Both are the moment the call screen belongs on top.
    if (before?.callId == call.callId &&
        before != null &&
        before.state.isLive &&
        before.state != CallState.ringing) {
      return;
    }

    _opened = call.callId;
    _openCallScreen();
  }

  void _openCallScreen() {
    final navigator =
        widget.navigatorKey?.currentState ?? Navigator.maybeOf(context);
    if (navigator == null) return;
    if (ref.read(callScreenVisibleProvider)) return;
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => const CallScreen(),
        fullscreenDialog: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(currentCallProvider, _onCallChanged);

    final state = ref.watch(currentCallProvider);
    final controls = ref.watch(callControlsProvider);
    final headers = ref.watch(mediaHeadersProvider);
    final session = state.session;

    final ringing =
        session != null &&
        session.state == CallState.ringing &&
        session.isIncoming;
    final wide = MediaQuery.sizeOf(context).width >= kCallHeadsUpBreakpoint;

    final showBar =
        session != null &&
        session.state.isLive &&
        session.state != CallState.ringing &&
        !ref.watch(callScreenVisibleProvider);

    return Stack(
      children: [
        Column(
          children: [
            if (showBar)
              MinimisedCallBar(
                state: state,
                controls: controls,
                onOpen: _openCallScreen,
              ),
            Expanded(child: widget.child),
          ],
        ),
        if (ringing && !wide)
          Positioned.fill(
            child: IncomingCallSheet(
              session: session,
              controls: controls,
              avatarHeaders: headers,
            ),
          ),
        if (ringing && wide)
          Positioned(
            top: WeftSpace.lg,
            right: WeftSpace.lg,
            width: 420,
            child: SafeArea(
              child: IncomingCallBanner(
                session: session,
                controls: controls,
                avatarHeaders: headers,
                onOpen: _openCallScreen,
              ),
            ),
          ),
      ],
    );
  }
}

/// The call, reduced to a strip at the top of whatever the user went off to do.
///
/// The picture-in-picture of a 1:1 call: there is no second video worth keeping
/// on screen while the user reads a message, and a floating window that has to
/// be dragged out of the way is a worse answer than a bar that moves the page
/// down by 44 pixels. Tapping it goes back to the call.
class MinimisedCallBar extends StatefulWidget {
  const MinimisedCallBar({
    super.key,
    required this.state,
    required this.controls,
    required this.onOpen,
  });

  final CallServiceState state;
  final CallControls controls;
  final VoidCallback onOpen;

  @override
  State<MinimisedCallBar> createState() => _MinimisedCallBarState();
}

class _MinimisedCallBarState extends State<MinimisedCallBar> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.state.session;
    if (session == null) return const SizedBox.shrink();

    // The call's own green, not the theme's primary: this is a system-call
    // affordance and it should read as one from the corner of an eye.
    final background = widget.state.reconnecting
        ? context.colors.tertiaryContainer
        : context.palette.callAccept;
    final foreground = widget.state.reconnecting
        ? context.colors.onTertiaryContainer
        : context.palette.onCallAccept;

    return Material(
      color: background,
      child: SafeArea(
        bottom: false,
        // The bar itself opens the call screen, and said so nowhere: a reader
        // found a row of text and a hang-up button, with no sign that the row
        // was the way back into the call.
        child: Semantics(
          button: true,
          label:
              'Open the call with ${session.peer.label}, '
              '${callStatusLabel(widget.state, now: clock.now())}',
          child: InkWell(
            onTap: widget.onOpen,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: WeftSpace.lg,
                vertical: WeftSpace.sm,
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.phone_in_talk_rounded,
                    size: 18,
                    color: foreground,
                  ),
                  const SizedBox(width: WeftSpace.md),
                  Expanded(
                    child: Text(
                      '${session.peer.label} · '
                      '${callStatusLabel(widget.state, now: clock.now())}',
                      style: context.text.labelLarge?.copyWith(
                        color: foreground,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: WeftSpace.md),
                  // Labelled rather than tooltipped: this bar is drawn above the
                  // navigator, where there is no [Overlay] for a tooltip to
                  // appear in.
                  Semantics(
                    button: true,
                    label: 'Hang up',
                    child: InkResponse(
                      onTap: widget.controls.hangUp,
                      child: Padding(
                        padding: const EdgeInsets.all(WeftSpace.xs),
                        child: Icon(
                          Icons.call_end_rounded,
                          size: 20,
                          color: foreground,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
