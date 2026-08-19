import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_call/weft_call.dart';
import 'package:weft_design/weft_design.dart';

import '../../app/call_providers.dart';
import '../../app/providers.dart';
import '../../services/call/call_audio.dart';
import '../../services/call/call_service.dart';
import 'call_controls.dart';
import 'call_labels.dart';
import 'call_video_view.dart';

/// The call, full screen.
///
/// Two widgets rather than one, and the split is the same one the rest of Weft
/// makes: [CallScreen] is the provider-wired shell that knows about the service
/// and the navigator, and [CallScreenBody] is a pure function of a
/// [CallServiceState] and a [CallControls]. Every state a call can be in — and
/// there are eight of them, several of which take a real network failure to
/// reach — is therefore one constructor call away in a test or a golden.
class CallScreen extends ConsumerStatefulWidget {
  const CallScreen({super.key});

  /// How long the ended state stays up before the screen closes itself.
  ///
  /// Not zero: "No answer" and "They declined" are the whole result of the
  /// call, and a screen that vanished the instant the reason appeared would
  /// leave the user with a call that ended for no stated reason.
  static const Duration endedLinger = Duration(seconds: 2);

  @override
  ConsumerState<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends ConsumerState<CallScreen> {
  Timer? _closing;

  @override
  void initState() {
    super.initState();
    // After the frame: a provider cannot be written to while the tree that
    // reads it is building. This is what takes the minimised bar down while the
    // full screen is up.
    scheduleMicrotask(() => _setVisible(true));
  }

  @override
  void dispose() {
    _closing?.cancel();
    _setVisible(false);
    super.dispose();
  }

  void _setVisible(bool visible) {
    if (!mounted && visible) return;
    try {
      ref.read(callScreenVisibleProvider.notifier).set(visible);
    } on Object {
      // The scope is going away with the screen. Nothing left to tell.
    }
  }

  /// Closes once the call is over, after [CallScreen.endedLinger].
  void _closeSoon() {
    if (_closing != null) return;
    _closing = Timer(CallScreen.endedLinger, () {
      if (!mounted) return;
      final navigator = Navigator.of(context);
      if (navigator.canPop()) navigator.pop();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(currentCallProvider);
    final controls = ref.watch(callControlsProvider);

    final session = state.session;
    if (session == null || session.state == CallState.ended) _closeSoon();

    return CallScreenBody(
      state: state,
      controls: controls,
      onClose: () => Navigator.of(context).maybePop(),
      avatarHeaders: ref.watch(mediaHeadersProvider),
    );
  }
}

/// The call screen with nothing behind it.
class CallScreenBody extends StatefulWidget {
  const CallScreenBody({
    super.key,
    required this.state,
    required this.controls,
    this.onClose,
    this.avatarHeaders,
  });

  final CallServiceState state;
  final CallControls controls;

  /// Minimises the call — the screen goes away, the call does not.
  final VoidCallback? onClose;

  /// Sent with the avatar request. Matrix media is authenticated.
  final Map<String, String>? avatarHeaders;

  @override
  State<CallScreenBody> createState() => _CallScreenBodyState();
}

class _CallScreenBodyState extends State<CallScreenBody> {
  Timer? _ticker;

  /// True once this side has asked for video, so the far end turning it on is
  /// distinguishable from our own request coming back.
  bool _videoIsMine = false;

  /// The far end added video and the user has not yet said what to do about it.
  bool _askAboutVideo = false;

  @override
  void initState() {
    super.initState();
    // One timer for the whole screen rather than a ticking widget per label:
    // the duration is the only thing that changes between service states, and
    // it changes once a second.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(CallScreenBody old) {
    super.didUpdateWidget(old);
    final was = old.state.session?.videoEnabled ?? false;
    final now = widget.state.session?.videoEnabled ?? false;

    if (!was && now && !_videoIsMine) _askAboutVideo = true;
    if (!now) {
      _askAboutVideo = false;
      _videoIsMine = false;
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  CallSession? get _session => widget.state.session;

  Future<void> _requestVideo() async {
    // Recorded before the ask, not after: the answer comes back through the
    // same `videoEnabled` flag the far end's request does, and the two are only
    // distinguishable by who moved first.
    setState(() => _videoIsMine = true);
    await widget.controls.requestVideo(video: true);
  }

  Future<void> _keepMyCamera({required bool on}) async {
    setState(() {
      _askAboutVideo = false;
      _videoIsMine = on;
    });
    await widget.controls.setCameraEnabled(enabled: on);
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    final video = session?.videoEnabled ?? false;
    final onVideo = video && widget.state.video != null;

    return Scaffold(
      // Black behind a video call, because everything that is not the picture
      // should disappear; the ordinary surface behind a voice call, because a
      // black screen there is just a black screen.
      backgroundColor: video ? Colors.black : context.colors.surface,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (video)
            CallVideoView(
              source: widget.state.video,
              local: false,
              placeholder: _RemotePlaceholder(session: session),
            ),
          SafeArea(
            child: Column(
              children: [
                _CallHeader(
                  state: widget.state,
                  onMinimise: widget.onClose,
                  overVideo: onVideo,
                ),
                Expanded(
                  child: video
                      ? const SizedBox.shrink()
                      : _VoiceStage(
                          session: session,
                          avatarHeaders: widget.avatarHeaders,
                        ),
                ),
                if (_askAboutVideo && session != null)
                  _VideoRequestPrompt(
                    peer: session.peer.label,
                    onKeep: () => _keepMyCamera(on: true),
                    onRefuse: () => _keepMyCamera(on: false),
                  ),
                _CallControlBar(
                  state: widget.state,
                  controls: widget.controls,
                  onRequestVideo: _requestVideo,
                ),
              ],
            ),
          ),
          if (video && (session?.cameraOn ?? false))
            Positioned(
              right: WeftSpace.lg,
              top: WeftSpace.huge + WeftSpace.xxl,
              width: 108,
              height: 148,
              child: ClipRRect(
                borderRadius: WeftRadius.allMd,
                child: CallVideoView(
                  source: widget.state.video,
                  local: true,
                  mirror: true,
                  placeholder: const _LocalPlaceholder(),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Peer, status and whatever the connection has to say for itself.
class _CallHeader extends StatelessWidget {
  const _CallHeader({
    required this.state,
    required this.onMinimise,
    required this.overVideo,
  });

  final CallServiceState state;
  final VoidCallback? onMinimise;
  final bool overVideo;

  @override
  Widget build(BuildContext context) {
    final session = state.session;
    final onDark = overVideo;
    final titleColour = onDark ? Colors.white : context.colors.onSurface;
    final subtitleColour = onDark
        ? Colors.white70
        : context.colors.onSurfaceVariant;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        WeftSpace.sm,
        WeftSpace.sm,
        WeftSpace.lg,
        0,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          IconButton(
            tooltip: 'Minimise call',
            onPressed: onMinimise,
            icon: Icon(Icons.expand_more_rounded, color: titleColour),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  session?.peer.label ?? 'Call',
                  style: context.text.titleLarge?.copyWith(
                    color: titleColour,
                    fontWeight: FontWeight.w700,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  callStatusLabel(state, now: clock.now()),
                  style: context.text.bodyMedium?.copyWith(
                    color: subtitleColour,
                  ),
                ),
                _ConnectionNote(state: state, onDark: onDark),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// What is known about the connection, and nothing that is not.
///
/// A signal-strength meter would be a guess: a 1:1 call knows whether ICE has
/// dropped and whether the homeserver offered a relay, and both of those change
/// what the user should do. Everything else it could draw would be decoration.
class _ConnectionNote extends StatelessWidget {
  const _ConnectionNote({required this.state, required this.onDark});

  final CallServiceState state;
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final session = state.session;
    final warning = state.warning;

    if (state.reconnecting) {
      return _Note(
        icon: Icons.wifi_tethering_error_rounded,
        text: 'Weak connection — trying to recover',
        colour: context.colors.tertiary,
        onDark: onDark,
      );
    }

    // Only while the call is still trying to connect: once media is flowing,
    // the absence of a relay has stopped mattering, and a warning that stays up
    // for the whole call is a warning nobody reads the next time.
    if (warning != null &&
        session != null &&
        session.state != CallState.connected) {
      return _Note(
        icon: Icons.warning_amber_rounded,
        text: warning,
        colour: context.colors.tertiary,
        onDark: onDark,
      );
    }

    final codecs = session?.codecs;
    if (codecs != null && session?.state == CallState.connected) {
      return _Note(
        icon: Icons.graphic_eq_rounded,
        text: codecs.label,
        colour: onDark ? Colors.white70 : context.colors.onSurfaceVariant,
        onDark: onDark,
      );
    }

    return const SizedBox.shrink();
  }
}

class _Note extends StatelessWidget {
  const _Note({
    required this.icon,
    required this.text,
    required this.colour,
    required this.onDark,
  });

  final IconData icon;
  final String text;
  final Color colour;
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: WeftSpace.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 14, color: colour),
          const SizedBox(width: WeftSpace.xs),
          Expanded(
            child: Text(
              text,
              style: context.text.labelSmall?.copyWith(color: colour),
            ),
          ),
        ],
      ),
    );
  }
}

/// A voice call has no picture, so it shows who is on it.
class _VoiceStage extends StatelessWidget {
  const _VoiceStage({required this.session, required this.avatarHeaders});

  final CallSession? session;
  final Map<String, String>? avatarHeaders;

  @override
  Widget build(BuildContext context) {
    final peer = session?.peer;
    if (peer == null) return const SizedBox.shrink();

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // The same avatar the inbox row drew, with the same merged-identity
          // ring and network badges: a call with someone reached across three
          // networks should look like the conversation it came from.
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
          ),
        ],
      ),
    );
  }
}

/// The far end added video and this side's camera came on with it.
///
/// The gate is on the camera, not on the renegotiation: WebRTC requires a
/// prompt answer to an `m.call.negotiate`, so `weft_call` answers it and the
/// only question left for a person is whether to keep sending a picture. That
/// is stated here because a prompt that appeared *before* the camera opened
/// would be a nicer product and a protocol violation.
class _VideoRequestPrompt extends StatelessWidget {
  const _VideoRequestPrompt({
    required this.peer,
    required this.onKeep,
    required this.onRefuse,
  });

  final String peer;
  final VoidCallback onKeep;
  final VoidCallback onRefuse;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: WeftSpace.lg,
        vertical: WeftSpace.sm,
      ),
      child: Material(
        color: context.colors.surfaceContainerHigh,
        borderRadius: WeftRadius.allLg,
        child: Padding(
          padding: const EdgeInsets.all(WeftSpace.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$peer turned on video',
                style: context.text.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: WeftSpace.xs),
              Text(
                'Your camera is on as well.',
                style: context.text.bodySmall?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: WeftSpace.sm),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: onRefuse,
                    child: const Text('Turn mine off'),
                  ),
                  const SizedBox(width: WeftSpace.sm),
                  FilledButton(onPressed: onKeep, child: const Text('Keep it')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Mute, audio route, camera, hang up.
class _CallControlBar extends StatelessWidget {
  const _CallControlBar({
    required this.state,
    required this.controls,
    required this.onRequestVideo,
  });

  final CallServiceState state;
  final CallControls controls;
  final VoidCallback onRequestVideo;

  @override
  Widget build(BuildContext context) {
    final session = state.session;
    final live = session?.state.isLive ?? false;
    final video = session?.videoEnabled ?? false;
    final established =
        session?.state == CallState.connected ||
        session?.state == CallState.onHold;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        WeftSpace.lg,
        WeftSpace.md,
        WeftSpace.lg,
        WeftSpace.xl,
      ),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: WeftSpace.lg,
        runSpacing: WeftSpace.md,
        children: [
          CallActionButton(
            tooltip: (session?.muted ?? false) ? 'Unmute' : 'Mute',
            icon: (session?.muted ?? false)
                ? Icons.mic_off_rounded
                : Icons.mic_rounded,
            active: session?.muted ?? false,
            onPressed: live
                ? () => controls.setMuted(muted: !(session?.muted ?? false))
                : null,
          ),
          _AudioRouteButton(state: state, controls: controls, enabled: live),
          if (video)
            CallActionButton(
              tooltip: (session?.cameraOn ?? false)
                  ? 'Turn camera off'
                  : 'Turn camera on',
              icon: (session?.cameraOn ?? false)
                  ? Icons.videocam_rounded
                  : Icons.videocam_off_rounded,
              active: !(session?.cameraOn ?? false),
              onPressed: live
                  ? () => controls.setCameraEnabled(
                      enabled: !(session?.cameraOn ?? false),
                    )
                  : null,
            )
          else
            CallActionButton(
              tooltip: 'Add video',
              icon: Icons.video_call_rounded,
              // Only once media is flowing: an upgrade is a renegotiation, and
              // there is nothing to renegotiate until there is a session.
              onPressed: established ? onRequestVideo : null,
            ),
          if (video && (session?.cameraOn ?? false))
            CallActionButton(
              tooltip: 'Switch camera',
              icon: Icons.cameraswitch_rounded,
              onPressed: live ? controls.switchCamera : null,
            ),
          CallActionButton(
            tooltip: 'Hang up',
            icon: Icons.call_end_rounded,
            background: context.palette.callDecline,
            foreground: Colors.white,
            onPressed: live ? controls.hangUp : null,
          ),
        ],
      ),
    );
  }
}

/// Where the sound comes out.
///
/// A menu when the device has more than the two built-in routes, a toggle when
/// it does not — a phone with nothing plugged in should not make the user open
/// a menu to reach the loudspeaker, and a phone with a car kit paired should
/// not pretend the choice is binary.
class _AudioRouteButton extends StatelessWidget {
  const _AudioRouteButton({
    required this.state,
    required this.controls,
    required this.enabled,
  });

  final CallServiceState state;
  final CallControls controls;
  final bool enabled;

  static IconData iconFor(CallAudioRoute route) => switch (route) {
    CallAudioRoute.earpiece => Icons.phone_in_talk_rounded,
    CallAudioRoute.speaker => Icons.volume_up_rounded,
    CallAudioRoute.wiredHeadset => Icons.headset_rounded,
    CallAudioRoute.bluetooth => Icons.bluetooth_audio_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final audio = state.audio;
    final routes = [
      for (final route in CallAudioRoute.values)
        if (audio.available.contains(route)) route,
    ];

    if (routes.length > 2) {
      return PopupMenuButton<CallAudioRoute>(
        enabled: enabled,
        tooltip: 'Audio output — ${callAudioRouteLabel(audio.route)}',
        onSelected: controls.setAudioRoute,
        itemBuilder: (_) => [
          for (final route in routes)
            PopupMenuItem(
              value: route,
              child: Row(
                children: [
                  Icon(iconFor(route), size: 18),
                  const SizedBox(width: WeftSpace.md),
                  Text(callAudioRouteLabel(route)),
                ],
              ),
            ),
        ],
        child: CallActionButton(
          tooltip: null,
          icon: iconFor(audio.route),
          active: audio.isSpeakerOn,
          onPressed: null,
          absorbing: false,
        ),
      );
    }

    return CallActionButton(
      tooltip: audio.isSpeakerOn ? 'Speaker off' : 'Speaker',
      icon: iconFor(audio.route),
      active: audio.isSpeakerOn,
      onPressed: enabled
          ? () => controls.setAudioRoute(
              audio.isSpeakerOn
                  ? CallAudioRoute.earpiece
                  : CallAudioRoute.speaker,
            )
          : null,
    );
  }
}

/// One round control.
///
/// Public because the incoming call surfaces use the same button — an accept
/// and a hang-up that were two different shapes would read as two different
/// products.
class CallActionButton extends StatelessWidget {
  const CallActionButton({
    super.key,
    required this.tooltip,
    required this.icon,
    this.onPressed,
    this.active = false,
    this.background,
    this.foreground,
    this.size = 56,
    this.absorbing = true,
  });

  final String? tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  /// Drawn as engaged — muted, speaker on, camera off.
  final bool active;

  final Color? background;
  final Color? foreground;
  final double size;

  /// False when something above this handles the tap, so the button must not
  /// swallow it.
  final bool absorbing;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null || !absorbing;
    final fill =
        background ??
        (active
            ? context.colors.onSurface
            : context.colors.surfaceContainerHighest);
    final ink =
        foreground ??
        (active ? context.colors.surface : context.colors.onSurface);

    final button = Semantics(
      button: true,
      label: tooltip,
      child: Material(
        color: enabled ? fill : fill.withValues(alpha: 0.4),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: SizedBox(
            width: size,
            height: size,
            child: Icon(
              icon,
              color: enabled ? ink : ink.withValues(alpha: 0.4),
              size: size * 0.42,
            ),
          ),
        ),
      ),
    );

    // A tooltip needs an [Overlay] to float in, and half of these buttons are
    // drawn by [CallOverlay], which sits *above* the navigator and therefore
    // above the only Overlay in the app. The label is on the [Semantics] either
    // way, so what is lost is a hover hint on desktop rather than the name of
    // the button.
    if (tooltip == null || Overlay.maybeOf(context) == null) return button;
    return Tooltip(message: tooltip!, child: button);
  }
}

/// A video call whose picture has not arrived — or a build with no renderer.
class _RemotePlaceholder extends StatelessWidget {
  const _RemotePlaceholder({required this.session});

  final CallSession? session;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: WeftAvatar(
          label: session?.peer.label ?? '?',
          networks: session?.peer.networks ?? const [],
          size: 120,
        ),
      ),
    );
  }
}

class _LocalPlaceholder extends StatelessWidget {
  const _LocalPlaceholder();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: context.colors.surfaceContainerHighest,
      child: Icon(
        Icons.person_rounded,
        color: context.colors.onSurfaceVariant,
        size: 32,
      ),
    );
  }
}
