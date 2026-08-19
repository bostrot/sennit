import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/services/call/call_audio.dart';
import 'package:weft/services/call/call_platform.dart';
import 'package:weft/services/call/call_service.dart';
import 'package:weft_call/weft_call.dart';
import 'package:weft_domain/weft_domain.dart';

/// The Dart half of the platform call integration.
///
/// Only the Dart half is testable at all: `CallManager.swift` needs a `CXProvider`
/// and `WeftConnectionService.kt` needs Telecom to bind it, and neither exists in
/// a `flutter test` process. What *can* be pinned here is the part both of them
/// depend on and the part most likely to be got wrong — which of the state
/// stream's many events become a message to the system, and which of the
/// system's messages are allowed to reach the call.
///
/// Both halves matter for the same reason. The bridge sits between two things
/// that each believe they own the call, and every bug in this seam has the same
/// shape: the two disagree about whether a call is happening. A missed
/// `reportCallEnded` is a phone that keeps ringing; a duplicated
/// `reportIncomingCall` is two call screens; an unguarded `onHangUp` ends the
/// wrong call.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('outbound', () {
    test(
      'announces an incoming call once, however often state changes',
      () async {
        final harness = PlatformHarness();
        addTearDown(harness.dispose);

        await harness.sync(session(state: CallState.ringing));
        await harness.sync(session(state: CallState.ringing));
        await harness.sync(session(state: CallState.connecting));

        // Three states, one announcement. The state stream fires on every ICE
        // candidate, and CallKit answers a second `reportNewIncomingCall` with a
        // second call screen rather than an update.
        expect(harness.methods, ['reportIncomingCall']);
        expect(harness.first['handle'], '@anna:example.org');
        expect(harness.first['displayName'], 'Anna');
      },
    );

    test('an outgoing call is announced as one', () async {
      final harness = PlatformHarness();
      addTearDown(harness.dispose);

      await harness.sync(
        session(
          state: CallState.outgoingRinging,
          direction: CallDirection.outgoing,
        ),
      );

      expect(harness.methods, ['reportOutgoingCall']);
    });

    test('connection is reported once, on the transition', () async {
      final harness = PlatformHarness();
      addTearDown(harness.dispose);

      await harness.sync(session(state: CallState.connecting));
      await harness.sync(session(state: CallState.connected));
      await harness.sync(session(state: CallState.connected));

      expect(harness.methods, ['reportIncomingCall', 'reportCallConnected']);
    });

    test('mute and hold round-trip, and settle', () async {
      final harness = PlatformHarness();
      addTearDown(harness.dispose);

      await harness.sync(session(state: CallState.connected));
      await harness.sync(session(state: CallState.connected, muted: true));
      // The same state again: the system has already been told, so nothing more
      // goes out. Without this the platform's own mute action would come back as
      // state, be sent again, come back again.
      await harness.sync(session(state: CallState.connected, muted: true));
      await harness.sync(session(state: CallState.onHold, muted: true));

      expect(harness.methods, [
        'reportIncomingCall',
        'reportCallConnected',
        'updateCall',
        'updateCall',
      ]);
      expect(harness.calls[2].arguments['muted'], isTrue);
      expect(harness.calls[2].arguments['held'], isFalse);
      expect(harness.calls[3].arguments['held'], isTrue);
    });

    test(
      'an ended call is reported with a reason the system understands',
      () async {
        final harness = PlatformHarness();
        addTearDown(harness.dispose);

        await harness.sync(session(state: CallState.ringing));
        await harness.sync(
          session(
            state: CallState.ended,
            endReason: CallEndReason.inviteTimeout,
          ),
        );

        expect(harness.methods.last, 'reportCallEnded');
        expect(harness.calls.last.arguments['reason'], 'missed');
      },
    );

    test('an invite that expired before it was seen is never announced', () async {
      final harness = PlatformHarness();
      addTearDown(harness.dispose);

      // The ordinary case after time offline: a sync backlog delivers an invite
      // the state machine drops on arrival. Announcing and ending it in one
      // frame gives CallKit a call screen that flashes and Telecom a missed-call
      // entry for a call the phone never had a chance at.
      await harness.sync(
        session(state: CallState.ended, endReason: CallEndReason.inviteTimeout),
      );

      expect(harness.methods, isEmpty);
    });

    test('a second call ends the first before it is announced', () async {
      final harness = PlatformHarness();
      addTearDown(harness.dispose);

      await harness.sync(session(state: CallState.connected));
      await harness.sync(session(callId: 'call-2', state: CallState.ringing));

      expect(harness.methods, [
        'reportIncomingCall',
        'reportCallConnected',
        'reportCallEnded',
        'reportIncomingCall',
      ]);
      expect(harness.calls[2].arguments['callId'], 'call-1');
      expect(harness.calls[3].arguments['callId'], 'call-2');
    });

    test('disposal ends a call the system is still holding', () async {
      final harness = PlatformHarness();

      await harness.sync(session(state: CallState.connected));
      await harness.bridge.dispose();

      expect(harness.methods.last, 'reportCallEnded');
      expect(harness.calls.last.arguments['callId'], 'call-1');
    });

    test('a desktop build says nothing at all', () async {
      final harness = PlatformHarness(platform: TargetPlatform.macOS);
      addTearDown(harness.dispose);

      await harness.sync(session(state: CallState.ringing));
      await harness.sync(session(state: CallState.connected));

      // Not an omission: macOS, Linux and Windows have no system call
      // integration by design, and the in-app surfaces are the whole of it.
      expect(harness.methods, isEmpty);
    });

    test('follows a stream without being told to', () async {
      final harness = PlatformHarness();
      addTearDown(harness.dispose);

      final states = StreamController<CallServiceState>();
      addTearDown(states.close);
      harness.bridge.follow(states.stream);

      states.add(CallServiceState(session: session(state: CallState.ringing)));
      await pumpEventQueue();

      expect(harness.methods, ['reportIncomingCall']);
    });
  });

  group('inbound', () {
    test('answer, decline and hang up reach the call', () async {
      final harness = PlatformHarness();
      addTearDown(harness.dispose);
      await harness.sync(session(state: CallState.ringing));

      await harness.fromPlatform('onAnswer', {'callId': 'call-1'});
      await harness.fromPlatform('onSetMuted', {
        'callId': 'call-1',
        'muted': true,
      });
      await harness.fromPlatform('onSetHeld', {
        'callId': 'call-1',
        'held': true,
      });
      await harness.fromPlatform('onHangUp', {'callId': 'call-1'});

      expect(harness.actions.log, [
        'accept',
        'setMuted(true)',
        'setHold(true)',
        'hangUp',
      ]);
    });

    test('an action for another call is dropped', () async {
      final harness = PlatformHarness();
      addTearDown(harness.dispose);
      await harness.sync(session(state: CallState.connected));

      // The race is routine rather than hypothetical: CallKit delivers a
      // `CXEndCallAction` for a call the far end hung up a moment ago, because
      // the user pressed the red button before the system UI caught up. Acting
      // on it would end whatever call replaced it.
      await harness.fromPlatform('onHangUp', {'callId': 'call-0'});

      expect(harness.actions.log, isEmpty);
    });

    test('an action with no call id is accepted', () async {
      final harness = PlatformHarness();
      addTearDown(harness.dispose);
      await harness.sync(session(state: CallState.ringing));

      // Android's `Connection` callbacks carry no identifier of their own — the
      // connection *is* the identity — so the bridge there may send none.
      await harness.fromPlatform('onDecline', const <String, Object?>{});

      expect(harness.actions.log, ['decline']);
    });

    test('a route change is not guarded by call id', () async {
      final harness = PlatformHarness();
      addTearDown(harness.dispose);
      await harness.sync(session(state: CallState.connected));

      await harness.fromPlatform('onAudioRouteChanged', {
        'callId': 'call-0',
        'route': 'bluetooth',
      });

      expect(harness.actions.log, ['setAudioRoute(bluetooth)']);
    });

    test('an unknown route is dropped rather than guessed at', () async {
      final harness = PlatformHarness();
      addTearDown(harness.dispose);
      await harness.sync(session(state: CallState.connected));

      await harness.fromPlatform('onAudioRouteChanged', {'route': 'hdmi'});

      expect(harness.actions.log, isEmpty);
    });

    test('a VoIP token is published rather than swallowed', () async {
      final harness = PlatformHarness();
      addTearDown(harness.dispose);

      final tokens = <String>[];
      harness.bridge.voipTokens.listen(tokens.add);
      await harness.fromPlatform('onVoipToken', {'token': 'abc123'});
      // An invalidation. Dropped, because there is nothing to register and an
      // empty token is not one.
      await harness.fromPlatform('onVoipToken', {'token': ''});
      await pumpEventQueue();

      expect(tokens, ['abc123']);
    });

    test('a VoIP push is published so the client can go and look', () async {
      final harness = PlatformHarness();
      addTearDown(harness.dispose);

      final pushes = <Map<String, Object?>>[];
      harness.bridge.voipPushes.listen(pushes.add);
      await harness.fromPlatform('onVoipPush', {'room_id': '!r:example.org'});
      await pumpEventQueue();

      expect(pushes.single['room_id'], '!r:example.org');
    });
  });

  group('end reasons', () {
    test('the far end declining an outgoing call is a missed call', () {
      // "Declined" in a call log means *this* user declined, and a call the far
      // end refused is one this phone never got an answer to. Every platform's
      // call log draws that distinction and gets it from here.
      expect(
        PlatformCallEnd.forReason(CallEndReason.remoteReject, incoming: false),
        PlatformCallEnd.missed,
      );
      expect(
        PlatformCallEnd.forReason(CallEndReason.localReject, incoming: true),
        PlatformCallEnd.declined,
      );
    });

    test('every failure folds to one reason', () {
      for (final reason in [
        CallEndReason.iceFailed,
        CallEndReason.mediaFailed,
        CallEndReason.glareLost,
        CallEndReason.unknownError,
      ]) {
        expect(
          PlatformCallEnd.forReason(reason, incoming: true),
          PlatformCallEnd.failed,
          reason: '$reason should be a failure',
        );
      }
    });
  });
}

const CallPeer _peer = CallPeer(
  matrixUserId: '@anna:example.org',
  displayName: 'Anna',
  networks: [ChatNetwork.matrix],
);

CallSession session({
  String callId = 'call-1',
  CallState state = CallState.ringing,
  CallDirection direction = CallDirection.incoming,
  bool muted = false,
  CallEndReason? endReason,
}) => CallSession(
  callId: callId,
  partyId: 'DEVICE',
  roomId: '!room:example.org',
  peer: _peer,
  direction: direction,
  state: state,
  startedAt: DateTime.utc(2026, 8, 19, 12),
  muted: muted,
  endReason: endReason,
);

/// The bridge, a recorder for what it sends and a recorder for what it does.
class PlatformHarness {
  PlatformHarness({TargetPlatform platform = TargetPlatform.android}) {
    bridge = CallPlatformBridge(
      actions: actions,
      channel: channel,
      platform: platform,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
  }

  final MethodChannel channel = const MethodChannel(kCallChannelName);
  final RecordingActions actions = RecordingActions();
  final List<MethodCall> calls = [];

  late final CallPlatformBridge bridge;

  List<String> get methods => [for (final call in calls) call.method];

  Map<Object?, Object?> get first =>
      calls.first.arguments as Map<Object?, Object?>;

  Future<void> sync(CallSession session) =>
      bridge.sync(CallServiceState(session: session));

  /// One call the other way, as the platform would make it.
  ///
  /// Encoded and pushed through the binary messenger rather than handed to the
  /// handler directly, so the argument decoding — a `Map<Object?, Object?>` from
  /// the standard codec, not the `Map<String, Object?>` a literal produces — is
  /// exercised too. That distinction has bitten every method channel in this
  /// app at least once.
  Future<void> fromPlatform(
    String method,
    Map<String, Object?> arguments,
  ) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          kCallChannelName,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall(method, arguments),
          ),
          (_) {},
        );
    await pumpEventQueue();
  }

  Future<void> dispose() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await bridge.dispose();
  }
}

class RecordingActions implements CallPlatformActions {
  final List<String> log = [];

  @override
  Future<void> accept() async => log.add('accept');

  @override
  Future<void> decline() async => log.add('decline');

  @override
  Future<void> hangUp() async => log.add('hangUp');

  @override
  Future<void> setMuted({required bool muted}) async =>
      log.add('setMuted($muted)');

  @override
  Future<void> setHold({required bool onHold}) async =>
      log.add('setHold($onHold)');

  @override
  Future<void> setAudioRoute(CallAudioRoute route) async =>
      log.add('setAudioRoute(${route.name})');
}
