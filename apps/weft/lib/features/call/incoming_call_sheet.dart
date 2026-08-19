import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_call/weft_call.dart';
import 'package:weft_design/weft_design.dart';

import '../../app/call_providers.dart';
import '../../app/providers.dart';
import 'call_controls.dart';
import 'call_labels.dart';
import 'call_screen.dart';

/// A ringing call, in the two shapes a ringing call has.
///
/// [IncomingCallSheet] takes the whole screen, which is what a phone must do —
/// a call that arrived as a card at the top of the inbox is a call that gets
/// missed. [IncomingCallBanner] is the heads-up variant for a window big enough
/// that taking it over would be rude: on a desktop the user is probably in the
/// middle of something and the call is one of several things on screen.
///
/// Both are pure functions of a [CallSession] and a [CallControls]. Neither
/// decides when it appears — [CallOverlay] does that, so there is one place that
/// knows whether a call is being shown and one place that can be wrong about it.
///
/// The caller's name and avatar come from [CallPeer], which was resolved through
/// the merged identity when the call was built: a call from someone the user
/// knows as "Anna" across three networks says Anna, with the same badges the
/// inbox row carries, rather than `@anna:example.org`.
class IncomingCallSheet extends StatelessWidget {
  const IncomingCallSheet({
    super.key,
    required this.session,
    required this.controls,
    this.avatarHeaders,
  });

  final CallSession session;
  final CallControls controls;
  final Map<String, String>? avatarHeaders;

  @override
  Widget build(BuildContext context) {
    final peer = session.peer;

    return Scaffold(
      backgroundColor: context.colors.surface,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(WeftSpace.xl),
          child: Column(
            children: [
              const Spacer(),
              WeftAvatar(
                label: peer.label,
                imageUrl: peer.avatarUrl,
                imageHeaders: avatarHeaders,
                networks: peer.networks,
                size: 132,
              ),
              const SizedBox(height: WeftSpace.xl),
              Text(
                peer.label,
                style: context.text.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: WeftSpace.xs),
              Text(
                session.videoEnabled ? 'Incoming video call' : 'Incoming call',
                style: context.text.bodyMedium?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _Answer(
                    label: 'Decline',
                    icon: Icons.call_end_rounded,
                    colour: context.palette.callDecline,
                    onPressed: controls.decline,
                  ),
                  // Answering a video call on audio only is a first-class
                  // choice, not a fallback: it is how a video call is taken in
                  // a place the user does not want to be seen, and without it
                  // the alternative is declining.
                  if (session.videoEnabled)
                    _Answer(
                      label: 'Voice only',
                      icon: Icons.phone_rounded,
                      colour: context.palette.callAccept,
                      onPressed: () => controls.accept(video: false),
                    ),
                  _Answer(
                    label: session.videoEnabled ? 'Video' : 'Accept',
                    icon: session.videoEnabled
                        ? Icons.videocam_rounded
                        : Icons.call_rounded,
                    colour: context.palette.callAccept,
                    onPressed: controls.accept,
                  ),
                ],
              ),
              const SizedBox(height: WeftSpace.xl),
            ],
          ),
        ),
      ),
    );
  }
}

class _Answer extends StatelessWidget {
  const _Answer({
    required this.label,
    required this.icon,
    required this.colour,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final Color colour;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        CallActionButton(
          tooltip: label,
          icon: icon,
          background: colour,
          foreground: Colors.white,
          size: 68,
          onPressed: onPressed,
        ),
        const SizedBox(height: WeftSpace.sm),
        Text(label, style: context.text.labelMedium),
      ],
    );
  }
}

/// The heads-up variant: a card that does not take the screen.
class IncomingCallBanner extends StatelessWidget {
  const IncomingCallBanner({
    super.key,
    required this.session,
    required this.controls,
    this.avatarHeaders,
    this.onOpen,
  });

  final CallSession session;
  final CallControls controls;
  final Map<String, String>? avatarHeaders;

  /// Opens the full call surface. Tapping the card answers nothing on its own —
  /// a call is not something to accept by brushing against it.
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final peer = session.peer;

    return Material(
      elevation: 8,
      borderRadius: WeftRadius.allLg,
      color: context.colors.surfaceContainerHigh,
      child: InkWell(
        borderRadius: WeftRadius.allLg,
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(WeftSpace.lg),
          child: Row(
            children: [
              WeftAvatar(
                label: peer.label,
                imageUrl: peer.avatarUrl,
                imageHeaders: avatarHeaders,
                networks: peer.networks,
                size: 44,
              ),
              const SizedBox(width: WeftSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      peer.label,
                      style: context.text.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      session.videoEnabled
                          ? 'Incoming video call'
                          : 'Incoming call',
                      style: context.text.bodySmall?.copyWith(
                        color: context.colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: WeftSpace.md),
              CallActionButton(
                tooltip: 'Decline',
                icon: Icons.call_end_rounded,
                background: context.palette.callDecline,
                foreground: Colors.white,
                size: 44,
                onPressed: controls.decline,
              ),
              const SizedBox(width: WeftSpace.sm),
              CallActionButton(
                tooltip: 'Accept',
                icon: session.videoEnabled
                    ? Icons.videocam_rounded
                    : Icons.call_rounded,
                background: context.palette.callAccept,
                foreground: Colors.white,
                size: 44,
                onPressed: controls.accept,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The full-screen incoming call, wired to the service.
///
/// Its own screen rather than a modal sheet: a route cannot be dismissed by a
/// stray tap outside it, and the one interaction that must never happen by
/// accident is dropping a call.
class IncomingCallScreen extends ConsumerWidget {
  const IncomingCallScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(currentCallProvider);
    final session = state.session;

    if (session == null || session.state != CallState.ringing) {
      // The call stopped ringing while this was up — answered on another
      // device, given up on, or expired. Whatever the reason, the screen has
      // nothing left to ask.
      return Scaffold(
        body: Center(
          child: Text(
            callEndLabel(
              session?.endReason,
              isOutgoing: session?.isOutgoing ?? false,
            ),
            style: context.text.titleMedium,
          ),
        ),
      );
    }

    return IncomingCallSheet(
      session: session,
      controls: ref.watch(callControlsProvider),
      avatarHeaders: ref.watch(mediaHeadersProvider),
    );
  }
}
