import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart' as sdk;
import 'package:weft_call/weft_call.dart';
import 'package:weft_matrix/weft_matrix.dart';

/// A minimal audio offer. Long enough to be a plausible SDP and short enough to
/// read; the mapping never parses beyond the media sections.
const String _audioSdp =
    'v=0\r\n'
    'o=- 4611731400430051336 2 IN IP4 127.0.0.1\r\n'
    's=-\r\n'
    'm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n'
    'a=rtpmap:111 opus/48000/2\r\n';

const String _videoSdp =
    '$_audioSdp'
    'm=video 9 UDP/TLS/RTP/SAVPF 96\r\n'
    'a=rtpmap:96 VP8/90000\r\n';

/// A video call downgraded to audio: the section is present with port 0, which
/// is how WebRTC says "rejected".
const String _rejectedVideoSdp =
    '$_audioSdp'
    'm=video 0 UDP/TLS/RTP/SAVPF 96\r\n';

const String _us = '@me:example.org';
const String _ourDevice = 'DEVICEAAA';
const String _them = '@anna:example.org';
final DateTime _now = DateTime.utc(2026, 8, 19, 12);

MatrixCallEvent _event(
  String type,
  Map<String, Object?> content, {
  String senderId = _them,
  String? roomId = '!room:example.org',
  DateTime? sentAt,
}) {
  return MatrixCallEvent(
    type: type,
    senderId: senderId,
    content: content,
    roomId: roomId,
    sentAt: sentAt ?? _now,
  );
}

CallSignal? _parse(MatrixCallEvent event) =>
    parseCallSignal(event, localUserId: _us, localPartyId: _ourDevice);

Map<String, Object?> _inviteContent({
  String sdp = _audioSdp,
  String callId = 'call-1',
  String? partyId = 'THEIRDEVICE',
  Object? version = '1',
  Object? lifetime = 60000,
  String? invitee,
}) => {
  'call_id': callId,
  'party_id': ?partyId,
  'version': version,
  'lifetime': lifetime,
  'offer': {'type': 'offer', 'sdp': sdp},
  'invitee': ?invitee,
};

void main() {
  group('parseCallSignal — invite', () {
    test('reads every field MSC2746 puts on an invite', () {
      final signal =
          _parse(
                _event(
                  'm.call.invite',
                  _inviteContent(invitee: _us),
                  sentAt: _now,
                ),
              )
              as CallInviteSignal;

      expect(signal.callId, 'call-1');
      expect(signal.partyId, 'THEIRDEVICE');
      expect(signal.senderId, _them);
      expect(signal.roomId, '!room:example.org');
      expect(signal.offer, const SessionDescription.offer(_audioSdp));
      expect(signal.sentAt, _now);
      expect(signal.lifetime, const Duration(seconds: 60));
      expect(signal.invitee, _us);
      expect(signal.version, '1');
      expect(signal.video, isFalse);
    });

    test('a video call is recognised from the SDP, not from a flag', () {
      // MSC2746 has no video field at all: an m=video section is the only
      // signal, which is why the call screen's camera button depends on it.
      final signal =
          _parse(_event('m.call.invite', _inviteContent(sdp: _videoSdp)))
              as CallInviteSignal;

      expect(signal.video, isTrue);
    });

    test('a rejected video section is not a video call', () {
      final signal =
          _parse(
                _event('m.call.invite', _inviteContent(sdp: _rejectedVideoSdp)),
              )
              as CallInviteSignal;

      expect(signal.video, isFalse);
    });

    test('a version-0 invite keeps its integer version and empty party', () {
      // The pre-MSC dialect sent `version: 0` as an integer and had no
      // party_id. Both still arrive, and the state machine's supportedVersions
      // set is written in strings.
      final signal =
          _parse(
                _event(
                  'm.call.invite',
                  _inviteContent(version: 0, partyId: null),
                ),
              )
              as CallInviteSignal;

      expect(signal.version, '0');
      expect(signal.partyId, isEmpty);
    });

    test('an absent version reads as 0, not as the current one', () {
      final content = _inviteContent()..remove('version');
      final signal =
          _parse(_event('m.call.invite', content)) as CallInviteSignal;

      expect(signal.version, '0');
    });

    test('an absent lifetime falls back to the 60-second default', () {
      final signal =
          _parse(_event('m.call.invite', _inviteContent(lifetime: null)))
              as CallInviteSignal;

      expect(signal.lifetime, kDefaultInviteLifetime);
    });

    test('an invite for somebody else is passed through, not dropped', () {
      // Deliberate: the state machine drops it. Filtering here as well would
      // put the same rule in two places, where the two can disagree.
      final signal =
          _parse(
                _event(
                  'm.call.invite',
                  _inviteContent(invitee: '@someone:example.org'),
                ),
              )
              as CallInviteSignal;

      expect(signal.invitee, '@someone:example.org');
    });

    test('an invite with no room, no offer or no timestamp is unusable', () {
      expect(
        _parse(_event('m.call.invite', _inviteContent(), roomId: null)),
        isNull,
      );
      expect(
        _parse(
          MatrixCallEvent(
            type: 'm.call.invite',
            senderId: _them,
            content: _inviteContent(),
            roomId: '!room:example.org',
          ),
        ),
        isNull,
      );

      final noOffer = _inviteContent()..remove('offer');
      expect(_parse(_event('m.call.invite', noOffer)), isNull);

      final emptySdp = _inviteContent();
      emptySdp['offer'] = {'type': 'offer', 'sdp': ''};
      expect(_parse(_event('m.call.invite', emptySdp)), isNull);
    });

    test('an offer that omits its type is still an offer', () {
      final content = _inviteContent();
      content['offer'] = {'sdp': _audioSdp};

      final signal =
          _parse(_event('m.call.invite', content)) as CallInviteSignal;
      expect(signal.offer.type, SdpType.offer);
    });
  });

  group('parseCallSignal — the rest of a call', () {
    test('reads an answer and its video state', () {
      final signal =
          _parse(
                _event('m.call.answer', {
                  'call_id': 'call-1',
                  'party_id': 'THEIRDEVICE',
                  'version': '1',
                  'answer': {'type': 'answer', 'sdp': _videoSdp},
                }),
              )
              as CallAnswerSignal;

      expect(signal.answer.type, SdpType.answer);
      expect(signal.video, isTrue);
    });

    test('reads candidates in order, keeping the end-of-candidates marker', () {
      final signal =
          _parse(
                _event('m.call.candidates', {
                  'call_id': 'call-1',
                  'party_id': 'THEIRDEVICE',
                  'candidates': [
                    {
                      'candidate':
                          'candidate:1 1 udp 2122260223 10.0.0.1 4 typ host',
                      'sdpMid': 'audio',
                      'sdpMLineIndex': 0,
                    },
                    {'candidate': '', 'sdpMid': 'audio', 'sdpMLineIndex': 0},
                  ],
                }),
              )
              as CallCandidatesSignal;

      expect(signal.candidates, hasLength(2));
      expect(signal.candidates.first.sdpMid, 'audio');
      expect(signal.candidates.first.sdpMLineIndex, 0);
      // Forwarding this is required: a peer that never learns gathering has
      // finished waits out its own ICE timeout instead of failing over.
      expect(signal.candidates.last.isEndOfCandidates, isTrue);
    });

    test('a malformed candidate is dropped and the rest survive', () {
      final signal =
          _parse(
                _event('m.call.candidates', {
                  'call_id': 'call-1',
                  'candidates': [
                    'not-a-map',
                    {'sdpMid': 'audio'},
                    {'candidate': 'candidate:2 1 udp 1 10.0.0.2 5 typ host'},
                  ],
                }),
              )
              as CallCandidatesSignal;

      expect(signal.candidates, hasLength(1));
      expect(signal.candidates.single.sdpMid, isNull);
      expect(signal.candidates.single.sdpMLineIndex, isNull);
    });

    test('an empty candidate batch is nothing to act on', () {
      expect(
        _parse(
          _event('m.call.candidates', {
            'call_id': 'call-1',
            'candidates': <Object?>[],
          }),
        ),
        isNull,
      );
    });

    test(
      'reads select_answer, which is how a second device learns it lost',
      () {
        final signal =
            _parse(
                  _event('m.call.select_answer', {
                    'call_id': 'call-1',
                    'party_id': 'THEIRDEVICE',
                    'selected_party_id': 'OTHERDEVICE',
                  }),
                )
                as CallSelectAnswerSignal;

        expect(signal.selectedPartyId, 'OTHERDEVICE');
      },
    );

    test('a select_answer naming nobody is unusable', () {
      expect(
        _parse(_event('m.call.select_answer', {'call_id': 'call-1'})),
        isNull,
      );
    });

    test('hangup and reject keep their raw reason', () {
      final hangup =
          _parse(
                _event('m.call.hangup', {
                  'call_id': 'call-1',
                  'reason': 'ice_failed',
                }),
              )
              as CallHangupSignal;
      expect(hangup.reason, 'ice_failed');
      expect(
        CallEndReason.fromWire(hangup.reason, isReject: false),
        CallEndReason.iceFailed,
      );

      final reject =
          _parse(
                _event('m.call.reject', {
                  'call_id': 'call-1',
                  'reason': 'user_busy',
                }),
              )
              as CallRejectSignal;
      expect(reject.reason, 'user_busy');
      expect(
        CallEndReason.fromWire(reject.reason, isReject: true),
        CallEndReason.userBusy,
      );
    });

    test('a hangup with no reason is still a hangup', () {
      final hangup =
          _parse(_event('m.call.hangup', {'call_id': 'call-1'}))
              as CallHangupSignal;

      expect(hangup.reason, isNull);
      expect(
        CallEndReason.fromWire(hangup.reason, isReject: false),
        CallEndReason.remoteHangup,
      );
    });

    test('a negotiate carries whichever half of the exchange it is', () {
      final offer =
          _parse(
                _event('m.call.negotiate', {
                  'call_id': 'call-1',
                  'description': {'type': 'offer', 'sdp': _videoSdp},
                }),
              )
              as CallNegotiateSignal;
      expect(offer.description.type, SdpType.offer);
      expect(offer.video, isTrue);

      final answer =
          _parse(
                _event('m.call.negotiate', {
                  'call_id': 'call-1',
                  'description': {'type': 'answer', 'sdp': _audioSdp},
                }),
              )
              as CallNegotiateSignal;
      expect(answer.description.type, SdpType.answer);
      expect(answer.video, isFalse);
    });

    test('a negotiate whose description has no type is dropped', () {
      // Unlike an invite there is no safe default here: guessing offer when it
      // was an answer turns a renegotiation into a dropped call.
      expect(
        _parse(
          _event('m.call.negotiate', {
            'call_id': 'call-1',
            'description': {'sdp': _audioSdp},
          }),
        ),
        isNull,
      );
    });
  });

  group('parseCallSignal — what is deliberately ignored', () {
    test('our own events, echoed back by sync, are not incoming calls', () {
      expect(
        _parse(
          _event(
            'm.call.invite',
            _inviteContent(partyId: _ourDevice),
            senderId: _us,
          ),
        ),
        isNull,
      );
      expect(
        _parse(
          _event('m.call.hangup', {
            'call_id': 'call-1',
            'party_id': _ourDevice,
          }, senderId: _us),
        ),
        isNull,
      );
    });

    test('another device of ours is a genuine second party', () {
      // MSC2746 identifies devices, not users, and the whole select_answer
      // dance exists because our other phone can answer a call we can see.
      final signal = _parse(
        _event('m.call.answer', {
          'call_id': 'call-1',
          'party_id': 'OUROTHERDEVICE',
          'answer': {'type': 'answer', 'sdp': _audioSdp},
        }, senderId: _us),
      );

      expect(signal, isA<CallAnswerSignal>());
    });

    test('an event with no call id is not about a call we can hold', () {
      expect(_parse(_event('m.call.hangup', const {})), isNull);
    });

    test(
      'the event types Weft does not implement are ignored, not crashed on',
      () {
        // `Client.onCallEvents` is fed by a regexp that also matches redactions
        // and group-call traffic, so these arrive routinely.
        for (final type in const [
          'm.call.replaces',
          'm.call.asserted_identity',
          'org.matrix.call.asserted_identity',
          'm.call.sdp_stream_metadata_changed',
          'org.matrix.call.sdp_stream_metadata_changed',
          'com.famedly.call.member',
          'm.room.redaction',
          'm.room.message',
        ]) {
          expect(
            _parse(_event(type, {'call_id': 'call-1'})),
            isNull,
            reason: '$type should not map to a 1:1 call signal',
          );
        }
      },
    );
  });

  group('MatrixCallEvent.fromSdk', () {
    test('reads a to-device invite, taking the room from the content', () {
      // Encrypted 1:1 invites travel to-device, so this path is the encrypted
      // room's ordinary case rather than an exotic one.
      final event = MatrixCallEvent.fromSdk(
        sdk.ToDeviceEvent(
          sender: _them,
          type: 'm.call.invite',
          content: {..._inviteContent(), 'room_id': '!room:example.org'},
        ),
        receivedAt: _now,
      );

      expect(event, isNotNull);
      expect(event!.roomId, '!room:example.org');
      // A to-device event carries no origin timestamp, so arrival stands in.
      expect(event.sentAt, _now);

      final signal = _parse(event) as CallInviteSignal;
      expect(signal.callId, 'call-1');
    });

    test('a to-device event with no room id cannot be answered', () {
      final event = MatrixCallEvent.fromSdk(
        sdk.ToDeviceEvent(
          sender: _them,
          type: 'm.call.invite',
          content: _inviteContent(),
        ),
        receivedAt: _now,
      );

      expect(event!.roomId, isNull);
      expect(_parse(event), isNull);
    });

    test('an event that never decrypted carries nothing readable', () {
      // Its `content` is the *encrypted* content. Reading a call_id out of it
      // would invent a call, so both shapes are dropped: an
      // undecryptable to-device event and a timeline event still typed
      // `m.room.encrypted`.
      expect(
        MatrixCallEvent.fromSdk(
          sdk.ToDeviceEventDecryptionError(
            toDeviceEvent: sdk.ToDeviceEvent(
              sender: _them,
              type: 'm.call.invite',
              content: {'call_id': 'call-1'},
            ),
            exception: Exception('no session'),
          ),
        ),
        isNull,
      );

      expect(
        MatrixCallEvent.fromSdk(
          sdk.ToDeviceEvent(
            sender: _them,
            type: 'm.room.encrypted',
            content: const {'algorithm': 'm.megolm.v1.aes-sha2'},
          ),
        ),
        isNull,
      );
    });
  });

  group('outbound intents', () {
    const partyId = _ourDevice;

    test('an invite carries the offer, the lifetime and a named invitee', () {
      const intent = SendInvite(
        callId: 'call-1',
        partyId: partyId,
        roomId: '!room:example.org',
        offer: SessionDescription.offer(_audioSdp),
        lifetime: Duration(seconds: 60),
        video: false,
      );

      expect(callEventType(intent), 'm.call.invite');
      expect(callEventContent(intent, invitee: _them), {
        'call_id': 'call-1',
        'party_id': partyId,
        'version': '1',
        'lifetime': 60000,
        'offer': {'type': 'offer', 'sdp': _audioSdp},
        'invitee': _them,
      });
    });

    test(
      'an invite with no invitee omits the key rather than sending null',
      () {
        // Its absence means "any member of the room other than the sender",
        // which in a room with a bridge bot means ringing the bot too.
        const intent = SendInvite(
          callId: 'call-1',
          partyId: partyId,
          roomId: '!room:example.org',
          offer: SessionDescription.offer(_audioSdp),
          lifetime: Duration(seconds: 60),
          video: false,
        );

        expect(callEventContent(intent).containsKey('invitee'), isFalse);
      },
    );

    test('an answer is an answer', () {
      const intent = SendAnswer(
        callId: 'call-1',
        partyId: partyId,
        answer: SessionDescription.answer(_audioSdp),
        video: false,
      );

      expect(callEventType(intent), 'm.call.answer');
      expect(callEventContent(intent)['answer'], {
        'type': 'answer',
        'sdp': _audioSdp,
      });
    });

    test('candidates keep their order and drop absent optional fields', () {
      const intent = SendCandidates(
        callId: 'call-1',
        partyId: partyId,
        candidates: [
          IceCandidate(candidate: 'a', sdpMid: 'audio', sdpMLineIndex: 0),
          IceCandidate(candidate: 'b'),
          IceCandidate(candidate: ''),
        ],
      );

      expect(callEventType(intent), 'm.call.candidates');
      expect(callEventContent(intent)['candidates'], [
        {'candidate': 'a', 'sdpMid': 'audio', 'sdpMLineIndex': 0},
        {'candidate': 'b'},
        {'candidate': ''},
      ]);
    });

    test('select_answer names the party that won', () {
      const intent = SendSelectAnswer(
        callId: 'call-1',
        partyId: partyId,
        selectedPartyId: 'THEIRDEVICE',
      );

      expect(callEventType(intent), 'm.call.select_answer');
      expect(callEventContent(intent)['selected_party_id'], 'THEIRDEVICE');
    });

    test('a glare hangup goes out as unknown_error, matching the SDK', () {
      // MSC2746 defines no glare reason. Sending anything else would confuse an
      // Element on the far end, which is the client this loses to most often.
      const intent = SendHangup(
        callId: 'call-1',
        partyId: partyId,
        reason: CallEndReason.glareLost,
      );

      expect(callEventType(intent), 'm.call.hangup');
      expect(callEventContent(intent)['reason'], 'unknown_error');
    });

    test('a reject carries its reason, which the SDK omits', () {
      // Weft sends it anyway: "they were on another call" and "they declined"
      // are different sentences and nothing else distinguishes them.
      const intent = SendReject(
        callId: 'call-1',
        partyId: partyId,
        reason: CallEndReason.userBusy,
      );

      expect(callEventType(intent), 'm.call.reject');
      expect(callEventContent(intent)['reason'], 'user_busy');
    });

    test('a negotiate carries a lifetime and its description', () {
      const intent = SendNegotiate(
        callId: 'call-1',
        partyId: partyId,
        description: SessionDescription.offer(_videoSdp),
        lifetime: kDefaultCallEventLifetime,
        video: true,
      );

      expect(callEventType(intent), 'm.call.negotiate');
      final content = callEventContent(intent);
      expect(content['lifetime'], 10000);
      expect(content['description'], {'type': 'offer', 'sdp': _videoSdp});
    });

    test('every intent stamps the call id, our party id and the version', () {
      const intents = <SignallingIntent>[
        SendInvite(
          callId: 'call-1',
          partyId: partyId,
          roomId: '!room:example.org',
          offer: SessionDescription.offer(_audioSdp),
          lifetime: Duration(seconds: 60),
          video: false,
        ),
        SendAnswer(
          callId: 'call-1',
          partyId: partyId,
          answer: SessionDescription.answer(_audioSdp),
          video: false,
        ),
        SendCandidates(
          callId: 'call-1',
          partyId: partyId,
          candidates: [IceCandidate(candidate: 'a')],
        ),
        SendSelectAnswer(
          callId: 'call-1',
          partyId: partyId,
          selectedPartyId: 'x',
        ),
        SendHangup(
          callId: 'call-1',
          partyId: partyId,
          reason: CallEndReason.userHangup,
        ),
        SendReject(
          callId: 'call-1',
          partyId: partyId,
          reason: CallEndReason.localReject,
        ),
        SendNegotiate(
          callId: 'call-1',
          partyId: partyId,
          description: SessionDescription.offer(_audioSdp),
          lifetime: kDefaultCallEventLifetime,
          video: false,
        ),
      ];

      for (final intent in intents) {
        final content = callEventContent(intent);
        expect(content['call_id'], 'call-1', reason: '${intent.runtimeType}');
        expect(content['party_id'], partyId, reason: '${intent.runtimeType}');
        expect(content['version'], '1', reason: '${intent.runtimeType}');
        expect(callEventType(intent), startsWith('m.call.'));
      }
    });
  });

  group('MatrixCallSignalling', () {
    late _RecordingSink sink;
    late MatrixCallSignalling signalling;

    setUp(() {
      sink = _RecordingSink();
      signalling = MatrixCallSignalling(
        localUserId: _us,
        localPartyId: _ourDevice,
        sink: sink,
        clock: () => _now,
      );
    });

    test(
      'sends an intent to the room it is told, not the one on the intent',
      () async {
        await signalling.send(
          const SendHangup(
            callId: 'call-1',
            partyId: _ourDevice,
            reason: CallEndReason.userHangup,
          ),
          roomId: '!room:example.org',
          invitee: _them,
        );

        expect(sink.sent, hasLength(1));
        expect(sink.sent.single.roomId, '!room:example.org');
        expect(sink.sent.single.type, 'm.call.hangup');
        expect(sink.sent.single.content['reason'], 'user_hangup');
      },
    );

    test(
      'a batch of events becomes signals in the order they arrived',
      () async {
        final controller = StreamController<List<sdk.BasicEventWithSender>>();
        addTearDown(controller.close);

        final signals = signalling.signalsFrom(controller.stream).toList();

        controller.add([
          // Ours, echoed back: must not become an incoming call.
          sdk.ToDeviceEvent(
            sender: _us,
            type: 'm.call.invite',
            content: {
              ..._inviteContent(partyId: _ourDevice),
              'room_id': '!room:example.org',
            },
          ),
          sdk.ToDeviceEvent(
            sender: _them,
            type: 'm.call.invite',
            content: {..._inviteContent(), 'room_id': '!room:example.org'},
          ),
          sdk.ToDeviceEvent(
            sender: _them,
            type: 'm.call.candidates',
            content: {
              'call_id': 'call-1',
              'party_id': 'THEIRDEVICE',
              'room_id': '!room:example.org',
              'candidates': [
                {'candidate': 'first'},
                {'candidate': 'second'},
              ],
            },
          ),
          // Group-call traffic on the same stream.
          sdk.ToDeviceEvent(
            sender: _them,
            type: 'com.famedly.call.encryption_keys',
            content: const {'call_id': 'call-1'},
          ),
        ]);
        await controller.close();

        final received = await signals;
        expect(received, hasLength(2));
        expect(received.first, isA<CallInviteSignal>());
        final candidates = received.last as CallCandidatesSignal;
        expect(candidates.candidates.map((c) => c.candidate), [
          'first',
          'second',
        ]);
      },
    );

    test(
      'a whole incoming call maps end to end into the state machine',
      () async {
        // The point of this one is that the two packages agree: nothing in
        // between reshapes the signals.
        final machine = CallStateMachine(
          localUserId: _us,
          localPartyId: _ourDevice,
          clock: () => _now,
        );

        final invite = signalling.read(
          sdk.ToDeviceEvent(
            sender: _them,
            type: 'm.call.invite',
            content: {..._inviteContent(), 'room_id': '!room:example.org'},
          ),
        );
        machine.handle(invite!);
        expect(machine.state, CallState.ringing);
        expect(machine.session!.peer.matrixUserId, _them);

        final accept = machine.handle(const AcceptCall());
        expect(accept.media.whereType<CreateAnswer>(), hasLength(1));

        // ...and back out again: the machine's intents go on the wire unchanged.
        final answered = machine.handle(
          const LocalDescriptionReady(SessionDescription.answer(_audioSdp)),
        );
        for (final intent in answered.signalling) {
          await signalling.send(
            intent,
            roomId: machine.session!.roomId,
            invitee: _them,
          );
        }

        expect(sink.sent.single.type, 'm.call.answer');
        expect(sink.sent.single.roomId, '!room:example.org');
        expect(sink.sent.single.content['party_id'], _ourDevice);
        expect(sink.sent.single.content['answer'], {
          'type': 'answer',
          'sdp': _audioSdp,
        });

        final hangup = signalling.read(
          sdk.ToDeviceEvent(
            sender: _them,
            type: 'm.call.hangup',
            content: const {
              'call_id': 'call-1',
              'party_id': 'THEIRDEVICE',
              'room_id': '!room:example.org',
              'reason': 'user_hangup',
            },
          ),
        );
        machine.handle(hangup!);
        expect(machine.session!.endReason, CallEndReason.remoteHangup);
      },
    );
  });

  group('sdpOffersVideo', () {
    test('finds an active video section and ignores a rejected one', () {
      expect(sdpOffersVideo(_videoSdp), isTrue);
      expect(sdpOffersVideo(_rejectedVideoSdp), isFalse);
      expect(sdpOffersVideo(_audioSdp), isFalse);
      expect(sdpOffersVideo(''), isFalse);
    });

    test('a line mentioning video elsewhere is not a media section', () {
      expect(sdpOffersVideo('a=rtpmap:96 VP8/90000\r\n'), isFalse);
    });
  });
}

class _RecordingSink implements MatrixCallEventSink {
  final List<({String roomId, String type, Map<String, Object?> content})>
  sent = [];

  @override
  Future<void> send({
    required String roomId,
    required String type,
    required Map<String, Object?> content,
  }) async {
    sent.add((roomId: roomId, type: type, content: content));
  }
}
