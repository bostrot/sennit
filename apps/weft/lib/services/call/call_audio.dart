import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

/// `com.bostrot.weft/call` — the one channel calling uses on every platform.
///
/// Only the proximity sensor crosses it today. It is named here rather than in
/// the service because it is the first thing to need it; the platform call
/// integrations add their answer/decline traffic to this same channel, for the
/// reason the phase gives — all three platforms must drive one state machine,
/// and two channels would be two places for an answer to go missing.
const String kCallChannelName = 'com.bostrot.weft/call';

/// Where a call's audio is going.
///
/// Four values rather than a speaker boolean because a call has always had four
/// answers and the boolean hides two of them: a Bluetooth headset and a wired
/// one are neither "speaker" nor "earpiece", and a UI built on the boolean says
/// the wrong thing the moment either is plugged in.
enum CallAudioRoute {
  /// The handset receiver. The default for a voice call, and the reason the
  /// proximity sensor exists.
  earpiece,

  /// The loudspeaker. The default for a video call, because the phone is not
  /// against an ear.
  speaker,

  /// Anything plugged into the headphone jack or USB-C.
  wiredHeadset,

  /// A paired Bluetooth headset or car kit.
  bluetooth;

  /// Whether this route means the phone is held to the user's face.
  ///
  /// The proximity sensor blanks the screen only for [earpiece]: on speaker or
  /// on a headset the phone is being looked at, and blanking it there turns a
  /// video call black and makes the hang-up button unreachable.
  bool get isAgainstTheEar => this == CallAudioRoute.earpiece;
}

/// Which route a call should be using.
///
/// Pure, and the whole of Weft's audio policy — the platform half of this file
/// only carries out what this decides, so the rules are assertable without a
/// headset to plug in.
///
/// [preferred] is the user's explicit choice, and it wins **only while the
/// route it names still exists**. That single condition is the answer to
/// "headphones unplugged mid-call": the choice is not cleared, it simply stops
/// matching, and the call falls back to the automatic rule rather than
/// continuing to route audio at a socket with nothing in it. Re-plugging the
/// headset restores the user's choice without them touching anything.
CallAudioRoute resolveCallAudioRoute({
  required bool video,
  required Set<CallAudioRoute> available,
  CallAudioRoute? preferred,
}) {
  if (preferred != null && available.contains(preferred)) return preferred;

  // A headset the user has physically attached outranks both defaults: nobody
  // pairs a car kit and then expects the loudspeaker.
  if (available.contains(CallAudioRoute.bluetooth)) {
    return CallAudioRoute.bluetooth;
  }
  if (available.contains(CallAudioRoute.wiredHeadset)) {
    return CallAudioRoute.wiredHeadset;
  }
  if (video && available.contains(CallAudioRoute.speaker)) {
    return CallAudioRoute.speaker;
  }
  if (available.contains(CallAudioRoute.earpiece)) {
    return CallAudioRoute.earpiece;
  }
  // A desktop, or a tablet with no receiver. Speaker is the only thing left and
  // is also the honest answer.
  return CallAudioRoute.speaker;
}

/// Reads a platform audio device into a route, or null when it is not one.
///
/// Matched on the label because that is all `enumerateDevices` gives on the two
/// platforms this runs on, and the labels are stable strings from Android's
/// `AudioDeviceInfo` and iOS's `AVAudioSession` rather than free text. An
/// unrecognised device is null rather than a guess: offering a route that turns
/// out to be a virtual sound card is worse than not offering it.
CallAudioRoute? callAudioRouteForDevice(String label) {
  final value = label.toLowerCase();
  if (value.contains('bluetooth') ||
      value.contains('a2dp') ||
      value.contains('sco') ||
      value.contains('hands-free') ||
      value.contains('headset') && value.contains('bt')) {
    return CallAudioRoute.bluetooth;
  }
  if (value.contains('wired') ||
      value.contains('headphone') ||
      value.contains('headset')) {
    return CallAudioRoute.wiredHeadset;
  }
  if (value.contains('speaker')) return CallAudioRoute.speaker;
  if (value.contains('earpiece') ||
      value.contains('receiver') ||
      value.contains('handset')) {
    return CallAudioRoute.earpiece;
  }
  return null;
}

/// The audio half of a call, as the UI needs to draw it.
@immutable
class CallAudioState {
  const CallAudioState({
    this.route = CallAudioRoute.earpiece,
    this.available = const {CallAudioRoute.earpiece, CallAudioRoute.speaker},
    this.proximityActive = false,
  });

  final CallAudioRoute route;

  /// Every route this device can offer right now. Shrinks when a headset is
  /// unplugged, which is what makes [resolveCallAudioRoute] fall back.
  final Set<CallAudioRoute> available;

  /// Whether the screen is being blanked by the proximity sensor.
  final bool proximityActive;

  bool get isSpeakerOn => route == CallAudioRoute.speaker;

  CallAudioState copyWith({
    CallAudioRoute? route,
    Set<CallAudioRoute>? available,
    bool? proximityActive,
  }) => CallAudioState(
    route: route ?? this.route,
    available: available ?? this.available,
    proximityActive: proximityActive ?? this.proximityActive,
  );

  @override
  bool operator ==(Object other) =>
      other is CallAudioState &&
      other.route == route &&
      other.proximityActive == proximityActive &&
      setEquals(other.available, available);

  @override
  int get hashCode =>
      Object.hash(route, proximityActive, Object.hashAllUnordered(available));

  @override
  String toString() =>
      'CallAudioState(${route.name}'
      '${proximityActive ? ', proximity' : ''})';
}

/// The device side of call audio.
///
/// An interface for the same reason [MediaEngine] is one: routing audio needs a
/// phone, and none of the decisions above need anything. `CallService` holds
/// this, and a test hands it a recorder.
abstract interface class CallAudioController {
  /// Routes this device can offer, and a new set whenever that changes —
  /// a headset plugged in or pulled out mid-call.
  Stream<Set<CallAudioRoute>> get available;

  /// Reads the routes available right now.
  Future<Set<CallAudioRoute>> refresh();

  /// Sends audio to [route].
  Future<void> apply(CallAudioRoute route);

  /// Turns the proximity sensor's screen-off on or off.
  Future<void> setProximityEnabled({required bool enabled});

  /// Ends the audio session: speaker off, proximity released.
  Future<void> stop();

  Future<void> dispose();
}

/// [CallAudioController] over `flutter_webrtc` and the call method channel.
///
/// Two platforms do anything here. On desktop `enumerateDevices` answers with
/// output devices that are all loudspeakers as far as a call is concerned,
/// there is no receiver to route to and no proximity sensor to read, so every
/// method is a cheap no-op — which is the right shape, because a desktop call
/// is not a degraded call.
class PlatformCallAudio implements CallAudioController {
  PlatformCallAudio({
    @visibleForTesting MethodChannel? channel,
    @visibleForTesting TargetPlatform? platform,
  }) : _channel = channel ?? const MethodChannel(kCallChannelName),
       _platform = platform ?? defaultTargetPlatform {
    if (_isMobile) {
      rtc.navigator.mediaDevices.ondevicechange = (_) => unawaited(refresh());
    }
  }

  final MethodChannel _channel;
  final TargetPlatform _platform;

  final StreamController<Set<CallAudioRoute>> _available =
      StreamController<Set<CallAudioRoute>>.broadcast();

  /// Device ids for the routes that have one, so a Bluetooth headset is picked
  /// by identity rather than by asking the platform to guess.
  final Map<CallAudioRoute, String> _deviceIds = {};

  bool get _isMobile =>
      _platform == TargetPlatform.android || _platform == TargetPlatform.iOS;

  @override
  Stream<Set<CallAudioRoute>> get available => _available.stream;

  @override
  Future<Set<CallAudioRoute>> refresh() async {
    if (!_isMobile) {
      const desktop = {CallAudioRoute.speaker};
      if (!_available.isClosed) _available.add(desktop);
      return desktop;
    }

    final routes = <CallAudioRoute>{};
    _deviceIds.clear();
    try {
      for (final device in await rtc.Helper.audiooutputs) {
        final route = callAudioRouteForDevice(device.label);
        if (route == null) continue;
        routes.add(route);
        _deviceIds.putIfAbsent(route, () => device.deviceId);
      }
    } on Object catch (error) {
      // An enumeration that fails is not a call that fails. The two built-in
      // routes below are on every phone ever made.
      debugPrint('weft: could not enumerate audio outputs: $error');
    }

    // Both built-ins are always offered. A phone that reported neither would
    // otherwise leave the user with no way to switch, and the platform honours
    // the speakerphone toggle whether or not it listed a device for it.
    routes.addAll(const {CallAudioRoute.earpiece, CallAudioRoute.speaker});
    if (!_available.isClosed) _available.add(routes);
    return routes;
  }

  @override
  Future<void> apply(CallAudioRoute route) async {
    if (!_isMobile) return;
    try {
      final deviceId = _deviceIds[route];
      if (deviceId != null && route != CallAudioRoute.speaker) {
        await rtc.Helper.selectAudioOutput(deviceId);
        return;
      }
      switch (route) {
        case CallAudioRoute.speaker:
          await rtc.Helper.setSpeakerphoneOn(true);
        case CallAudioRoute.bluetooth:
          await rtc.Helper.setSpeakerphoneOnButPreferBluetooth();
        case CallAudioRoute.earpiece:
        case CallAudioRoute.wiredHeadset:
          // Both mean "not the loudspeaker": with a headset attached the
          // platform routes to it, and without one to the receiver.
          await rtc.Helper.setSpeakerphoneOn(false);
      }
    } on Object catch (error) {
      debugPrint('weft: could not route call audio to ${route.name}: $error');
    }
  }

  @override
  Future<void> setProximityEnabled({required bool enabled}) async {
    if (!_isMobile) return;
    try {
      await _channel.invokeMethod<void>('setProximityEnabled', {
        'enabled': enabled,
      });
    } on MissingPluginException {
      // No native call bridge on this build. A screen that stays on during a
      // voice call is a cheek-dial waiting to happen, not a broken call.
    } on PlatformException catch (error) {
      debugPrint('weft: proximity sensor unavailable: ${error.code}');
    }
  }

  @override
  Future<void> stop() async {
    await setProximityEnabled(enabled: false);
    if (!_isMobile) return;
    try {
      await rtc.Helper.setSpeakerphoneOn(false);
    } on Object catch (error) {
      debugPrint('weft: could not release the audio session: $error');
    }
  }

  @override
  Future<void> dispose() async {
    if (_isMobile) rtc.navigator.mediaDevices.ondevicechange = null;
    await _available.close();
  }
}
