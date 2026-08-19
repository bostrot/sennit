/// One reply, one answer — including the replies where nothing was sent.
///
/// Both watch surfaces show a dictated reply as *sending* until the phone tells
/// them otherwise, and nothing else on the phone will ever tell them. So the
/// property this file exists to pin is not "a reply is sent" but "every accepted
/// reply produces exactly one [WatchReplyResult]": a reply quietly dropped here
/// is a message the user believes they sent.
///
/// The second property is that nothing is ever sent twice. Both transports can
/// deliver the same reply by two roads — `sendMessage` falling back to
/// `transferUserInfo`, `MessageClient` retrying a node that came back — and a
/// duplicate that became a second message would be the failure this whole path
/// exists to make impossible.
library;

import 'package:clock/clock.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/services/snapshot/watch_reply_handler.dart';
import 'package:weft_domain/weft_domain.dart';

import 'support/snapshot_fixtures.dart';

/// The channel name two platforms answer on. Spelled out rather than imported
/// because `WeftWatchBridge` holds it as a literal too.
const String _channelName = 'com.bostrot.weft/watch';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// A reply as the platform would hand it over, stamped off the ambient clock.
  ///
  /// Off the clock rather than off [snapshotNow], because that is what
  /// `WatchReply.fromJson` does and because ageing is measured against it: a
  /// fixture pinned to a fixed instant would arrive already two minutes past
  /// [WatchReplyHandler.pendingFor] in every test that did not install a clock,
  /// and every one of them would pass or fail for the wrong reason. The ageing
  /// tests install one; the rest get the real now and are never expired.
  WatchReply reply({
    String id = 'reply_1',
    String chatId = '!room:example.org',
    String body = 'on my way',
    DateTime? receivedAt,
  }) => WatchReply(
    id: id,
    chatId: chatId,
    body: body,
    receivedAt: receivedAt ?? clock.now(),
  );

  /// The handler, its transport and its sender, wired the way the app wires them.
  ({
    WatchReplyHandler handler,
    RecordingWatchGateway gateway,
    RecordingWatchSender sender,
  })
  harness({
    void Function(String chatId)? onSend,
    Duration pendingFor = const Duration(minutes: 2),
    int maxPending = 16,
  }) {
    final gateway = RecordingWatchGateway();
    final sender = RecordingWatchSender(onSend: onSend);
    final handler = WatchReplyHandler(
      gateway: gateway,
      send: sender.call,
      pendingFor: pendingFor,
      maxPending: maxPending,
    );
    return (handler: handler, gateway: gateway, sender: sender);
  }

  group('WatchReply.fromJson', () {
    test('refuses a reply it would have to guess at', () {
      // Each of these could only be delivered by guessing, and a guess here
      // sends a real message to a real person.
      for (final raw in <Object?>[
        null,
        'a string',
        <String, Object?>{'chatId': '!room:example.org', 'body': 'hi'},
        <String, Object?>{
          'id': '',
          'chatId': '!room:example.org',
          'body': 'hi',
        },
        <String, Object?>{'id': 'r1', 'body': 'hi'},
        <String, Object?>{'id': 'r1', 'chatId': '', 'body': 'hi'},
        <String, Object?>{'id': 'r1', 'chatId': '!room:example.org'},
        <String, Object?>{
          'id': 'r1',
          'chatId': '!room:example.org',
          'body': '',
        },
        <String, Object?>{
          'id': 'r1',
          'chatId': '!room:example.org',
          'body': '   \n ',
        },
        <String, Object?>{'id': 7, 'chatId': '!room:example.org', 'body': 'hi'},
      ]) {
        expect(
          WatchReply.fromJson(raw, receivedAt: snapshotNow),
          isNull,
          reason: 'accepted $raw',
        );
      }
    });

    test('takes a usable one, trimmed', () {
      // The map arrives from a hand-written Swift dictionary and a hand-written
      // Kotlin `DataMap`, and dictation on both platforms ends with a space.
      final parsed = WatchReply.fromJson(<Object?, Object?>{
        'id': 'reply_1',
        'chatId': 'merged:contact_1',
        'body': '  on my way \n',
      }, receivedAt: snapshotNow);

      expect(parsed, isNotNull);
      expect(parsed!.id, 'reply_1');
      expect(parsed.chatId, 'merged:contact_1');
      expect(parsed.body, 'on my way');
      expect(parsed.receivedAt, snapshotNow);
    });

    test('stamps itself off the clock when the platform gave no time', () {
      withClock(Clock.fixed(snapshotNow), () {
        final parsed = WatchReply.fromJson(<Object?, Object?>{
          'id': 'reply_1',
          'chatId': '!room:example.org',
          'body': 'hi',
        });
        expect(parsed!.receivedAt, snapshotNow);
      });
    });
  });

  group('WatchReplyResult.toJson', () {
    test('is the exact shape the two hand-written parsers read', () {
      // Kotlin reads this off a `DataMap` and Swift off a `[String: Any]`, with
      // no compiler between either of them and this map. Absent keys are the
      // contract as much as present ones: the watch renders "sent" from the
      // absence of a failure.
      expect(const WatchReplyResult.sent('reply_1').toJson(), {
        'id': 'reply_1',
        'sent': true,
      });
      expect(
        const WatchReplyResult.sent(
          'reply_1',
          network: ChatNetwork.signal,
        ).toJson(),
        {'id': 'reply_1', 'sent': true, 'network': 'signal'},
      );
      expect(
        const WatchReplyResult.failed(
          'reply_1',
          WatchReplyFailure.unknownChat,
        ).toJson(),
        {'id': 'reply_1', 'sent': false, 'failure': 'unknown_chat'},
      );
    });

    test('the failure ids are the strings both watch apps switch on', () {
      // Spelled identically in `WeftWatchStrings` and in the wear module's
      // `res/values/strings.xml`. Renaming one of these renames a sentence on a
      // watch that updates on its own schedule, which is to say: never rename one.
      expect(
        WatchReplyFailure.values.map((failure) => failure.id),
        containsAll(<String>[
          'unknown_chat',
          'not_signed_in',
          'send_failed',
          'timed_out',
          'overflowed',
          'app_not_running',
        ]),
      );
    });
  });

  group('sending', () {
    test(
      'sends on the chat\'s own network and says so for a merged chat',
      () async {
        // "Sent via Signal" has to name the leg that was actually chosen, which is
        // why the network is resolved here and passed rather than left to the
        // repository to reach again a moment later.
        final h = harness();
        await h.handler.refresh([
          mergedSnapshotChat(
            preferredSendNetwork: ChatNetwork.signal,
            lastMessage: snapshotMessage(),
          ),
        ]);

        h.handler.accept(reply(chatId: 'merged:contact_1'));
        await pumpEventQueue();

        expect(h.sender.sent.single.chatId, 'merged:contact_1');
        expect(h.sender.sent.single.body, 'on my way');
        expect(h.sender.sent.single.via, ChatNetwork.signal);
        expect(h.gateway.reported.single.sent, isTrue);
        expect(h.gateway.reported.single.network, ChatNetwork.signal);
      },
    );

    test('does not name the network for a one-network conversation', () async {
      // A watch spending a line of a very small screen on something the user
      // could not have chosen.
      final h = harness();
      await h.handler.refresh([snapshotChat()]);

      h.handler.accept(reply());
      await pumpEventQueue();

      expect(h.sender.sent.single.via, ChatNetwork.whatsapp);
      expect(h.gateway.reported.single.sent, isTrue);
      expect(h.gateway.reported.single.network, isNull);
    });

    test('an unknown chat id is rejected and nothing is sent', () async {
      // The ordinary cause is not corruption: a merged chat reverts to a bare
      // room id when one of its legs is left, and a watch may hold the row for
      // hours afterwards. The alternative to rejecting is picking some other
      // conversation to send a private message into.
      final h = harness();
      await h.handler.refresh([snapshotChat(id: '!other:example.org')]);

      h.handler.accept(reply(chatId: 'merged:contact_1'));
      await pumpEventQueue();

      expect(h.sender.sent, isEmpty);
      expect(h.gateway.failures, ['unknown_chat']);
    });

    test('a send that throws is reported once and not retried', () async {
      // Every failure mode of a send is one fact to a wrist: it did not go. The
      // conversation shows the failed message when the user opens it.
      final h = harness(
        onSend: (_) => throw StateError('the homeserver said no'),
      );
      await h.handler.refresh([snapshotChat()]);

      h.handler.accept(reply());
      await pumpEventQueue();
      await h.handler.refresh([snapshotChat()]);
      await pumpEventQueue();

      expect(h.gateway.failures, ['send_failed']);
      expect(h.handler.pending, isEmpty);
    });

    test('replies drain serially, in arrival order', () async {
      // A watch's two-tap "yes" then "on my way" is exactly the case where the
      // order is the meaning, and two sends in parallel arrive in whichever
      // order the homeserver accepts them.
      final h = harness();
      await h.handler.refresh([snapshotChat()]);

      h.handler.accept(reply(id: 'reply_1', body: 'yes'));
      h.handler.accept(reply(id: 'reply_2', body: 'on my way'));
      h.handler.accept(reply(id: 'reply_3', body: 'ten minutes'));
      await pumpEventQueue();

      expect(h.sender.bodies, ['yes', 'on my way', 'ten minutes']);
      expect(h.gateway.reported.map((result) => result.replyId), [
        'reply_1',
        'reply_2',
        'reply_3',
      ]);
    });
  });

  group('the queue', () {
    test(
      'a reply with no inbox yet waits, and goes on the next refresh',
      () async {
        // A reply can be what *starts* the app, so `listen` fires before the chat
        // list exists. Answering `unknownChat` there would tell the user their
        // message failed for a conversation that is fine.
        final h = harness();

        h.handler.accept(reply());
        await pumpEventQueue();

        expect(h.sender.sent, isEmpty);
        expect(h.gateway.reported, isEmpty);
        expect(h.handler.pending.single.id, 'reply_1');

        await h.handler.refresh([snapshotChat()]);
        await pumpEventQueue();

        expect(h.sender.bodies, ['on my way']);
        expect(h.gateway.reported.single.sent, isTrue);
        expect(h.handler.pending, isEmpty);
      },
    );

    test('a reply that waits past pendingFor is failed, not dropped', () async {
      // A watch showing "sending…" forever is a message the user believes they
      // sent. Aged on the next arrival rather than on a timer: a wake-up every
      // user pays for so one stalled reply is marked failed sooner is the wrong
      // trade — and a wrist that is still replying is exactly when the queue is
      // worth re-examining.
      final h = harness(pendingFor: const Duration(minutes: 2));
      await withClock(Clock.fixed(snapshotNow), () async {
        h.handler.accept(reply(id: 'reply_1'));
        await pumpEventQueue();
      });

      await withClock(
        Clock.fixed(snapshotNow.add(const Duration(minutes: 1, seconds: 59))),
        () async {
          h.handler.accept(reply(id: 'reply_2'));
          await pumpEventQueue();
        },
      );
      expect(h.gateway.reported, isEmpty, reason: 'failed before the boundary');

      await withClock(
        Clock.fixed(snapshotNow.add(const Duration(minutes: 2))),
        () async {
          h.handler.accept(reply(id: 'reply_3'));
          await pumpEventQueue();
        },
      );

      expect(h.gateway.failures, ['timed_out']);
      expect(h.gateway.reported.single.replyId, 'reply_1');
      // The two younger replies are still waiting on the inbox that never came.
      expect(h.handler.pending.map((r) => r.id), ['reply_2', 'reply_3']);
    });

    test(
      'an inbox arriving after pendingFor does not send the reply late',
      () async {
        // The gap this suite found. Ageing used to happen only on the branch
        // where there was no inbox, so a reply that waited out `pendingFor` and
        // then met a sign-in was *sent* — an hour-old "on my way" arriving in a
        // conversation it no longer describes, to a watch that gave up on it long
        // before. `pendingFor` is a promise about when a reply stops being live,
        // and a late inbox cannot revive one.
        final h = harness(pendingFor: const Duration(minutes: 2));
        await withClock(Clock.fixed(snapshotNow), () async {
          h.handler.accept(reply());
          await pumpEventQueue();
        });

        await withClock(
          Clock.fixed(snapshotNow.add(const Duration(hours: 1))),
          () async {
            await h.handler.refresh([snapshotChat()]);
            await pumpEventQueue();
          },
        );

        expect(h.sender.sent, isEmpty);
        expect(h.gateway.failures, ['timed_out']);
        expect(h.handler.pending, isEmpty);
      },
    );

    test(
      'an empty inbox is an inbox: the reply is rejected, not queued',
      () async {
        // `refresh([])` is a signed-in account with no conversations, which is a
        // different thing from never having refreshed at all.
        final h = harness();
        await h.handler.refresh(const []);

        h.handler.accept(reply());
        await pumpEventQueue();

        expect(h.gateway.failures, ['unknown_chat']);
        expect(h.handler.pending, isEmpty);
      },
    );

    test('a full queue overflows rather than growing', () async {
      // Only reachable by a watch replying faster than the phone can send, which
      // in practice means the phone is not sending at all. This is a queue for
      // the seconds between a tap and a synced inbox, not an outbox.
      final h = harness(maxPending: 2);

      h.handler.accept(reply(id: 'reply_1'));
      h.handler.accept(reply(id: 'reply_2'));
      h.handler.accept(reply(id: 'reply_3'));
      await pumpEventQueue();

      expect(h.handler.pending.map((r) => r.id), ['reply_1', 'reply_2']);
      expect(h.gateway.failures, ['overflowed']);
      expect(h.gateway.reported.single.replyId, 'reply_3');
    });
  });

  group('duplicates', () {
    test('a redelivered id is acknowledged without a second send', () async {
      // `sendMessage` fails when the phone is unreachable and the watch retries
      // through `transferUserInfo`, which is queued and *will* arrive — so a
      // reply sent at the edge of reachability arrives once by each road.
      final h = harness();
      await h.handler.refresh([snapshotChat()]);

      h.handler.accept(reply());
      await pumpEventQueue();
      h.handler.accept(reply());
      await pumpEventQueue();

      expect(h.sender.sent, hasLength(1));
      expect(h.gateway.reported, hasLength(2));
      expect(h.gateway.reported.last.sent, isTrue);
      expect(h.gateway.reported.last.replyId, 'reply_1');
    });

    test('a redelivery is answered rather than ignored', () async {
      // The watch retried because it did not hear the first answer, so silence
      // is the one response guaranteed to make it retry again.
      final h = harness();
      await h.handler.refresh([snapshotChat()]);

      h.handler.accept(reply());
      await pumpEventQueue();
      h.gateway.reported.clear();

      h.handler.accept(reply());
      await pumpEventQueue();

      expect(h.gateway.reported, hasLength(1));
    });

    test('two different replies to one chat are two messages', () async {
      final h = harness();
      await h.handler.refresh([snapshotChat()]);

      h.handler.accept(reply(id: 'reply_1', body: 'yes'));
      h.handler.accept(reply(id: 'reply_2', body: 'yes'));
      await pumpEventQueue();

      expect(h.sender.bodies, ['yes', 'yes']);
    });
  });

  group('sign-out', () {
    test('every pending reply is failed as not signed in', () async {
      // A reply queued against a session that has gone away cannot be sent by
      // the next one — it would go from a different account, into a room this
      // device may no longer be in — and the watch is still showing it as
      // sending.
      final h = harness();
      h.handler.accept(reply(id: 'reply_1'));
      h.handler.accept(reply(id: 'reply_2'));
      await pumpEventQueue();

      await h.handler.clear();

      expect(h.gateway.failures, ['not_signed_in', 'not_signed_in']);
      expect(h.handler.pending, isEmpty);
      expect(h.sender.sent, isEmpty);
      // And the transport is torn down, which is what stops the next reply
      // arriving at a session that is not there.
      expect(h.gateway.stops, 1);
      expect(h.gateway.listening, isFalse);
    });

    test('a reply arriving after a clear waits rather than being sent', () async {
      // The inbox is dropped by `clear`, so the next session's chat list is what
      // resolves it — not the one that has just gone away.
      final h = harness();
      await h.handler.refresh([snapshotChat()]);
      await h.handler.clear();

      h.handler.accept(reply(id: 'reply_2'));
      await pumpEventQueue();

      expect(h.sender.sent, isEmpty);
      expect(h.gateway.reported, isEmpty);
      expect(h.handler.pending, hasLength(1));
    });

    test('start wires the gateway through', () async {
      final h = harness();
      h.handler.start();
      await h.handler.refresh([snapshotChat()]);

      h.gateway.deliver(reply());
      await pumpEventQueue();

      expect(h.gateway.listens, 1);
      expect(h.sender.bodies, ['on my way']);
    });

    test('a report the watch never hears does not surface as an error', () async {
      // A watch out of range, an unpaired device, a platform with no watch at
      // all. The message is already sent by then; throwing here would put it in
      // the chat-list listener that runs on every message.
      final h = harness();
      h.gateway.throwOnReport = true;
      await h.handler.refresh([snapshotChat()]);

      h.handler.accept(reply());
      await pumpEventQueue();

      expect(h.sender.sent, hasLength(1));
      expect(h.handler.pending, isEmpty);
    });
  });

  group('WeftWatchBridge', () {
    late _WatchChannelHarness harness;

    setUp(() => harness = _WatchChannelHarness());
    tearDown(() => harness.dispose());

    test('a reply from the platform reaches the callback', () async {
      final received = <WatchReply>[];
      harness.bridge.listen(received.add);

      await withClock(Clock.fixed(snapshotNow), () async {
        await harness.fromPlatform('onWatchReply', {
          'id': 'reply_1',
          'chatId': 'merged:contact_1',
          'body': 'on my way',
        });
      });

      expect(received.single.id, 'reply_1');
      expect(received.single.chatId, 'merged:contact_1');
      expect(received.single.receivedAt, snapshotNow);
    });

    test('a malformed reply is dropped rather than reported on', () async {
      // The id is one of the things that can be missing, so there is nothing to
      // report *about*. The watch's own timeout is what surfaces it, which is
      // the only mechanism that works for a message the phone never understood.
      final received = <WatchReply>[];
      harness.bridge.listen(received.add);

      await harness.fromPlatform('onWatchReply', {'body': 'on my way'});
      await harness.fromPlatform('somethingElse', const {});

      expect(received, isEmpty);
      expect(harness.methods, isEmpty);
    });

    test(
      'a result crosses as reportReply with the result\'s own keys',
      () async {
        await harness.bridge.report(
          const WatchReplyResult.failed(
            'reply_1',
            WatchReplyFailure.sendFailed,
          ),
        );

        expect(harness.methods, ['reportReply']);
        expect(harness.arguments.single, {
          'id': 'reply_1',
          'sent': false,
          'failure': 'send_failed',
        });
      },
    );

    test('stop tears the handler down and tells the platform', () async {
      final received = <WatchReply>[];
      harness.bridge.listen(received.add);
      harness.bridge.stop();
      await pumpEventQueue();

      await harness.fromPlatform('onWatchReply', {
        'id': 'reply_1',
        'chatId': '!room:example.org',
        'body': 'hi',
      });

      expect(harness.methods, ['stopWatch']);
      expect(received, isEmpty);
    });

    test('a platform with no watch is not an error', () async {
      // macOS, Linux, Windows, and every widget test: `MissingPluginException`,
      // which is the reason the handler can be wired up unconditionally.
      harness.dispose();
      final bridge = WeftWatchBridge(
        channel: const MethodChannel(_channelName),
      );

      await bridge.report(const WatchReplyResult.sent('reply_1'));
      bridge.stop();
      await pumpEventQueue();
    });

    test('a refused call is swallowed too', () async {
      // A `WCSession` with no paired watch, or a Wear node that went out of
      // range between the reply and the answer.
      harness.fail = true;
      await harness.bridge.report(const WatchReplyResult.sent('reply_1'));
      expect(harness.methods, ['reportReply']);
    });
  });
}

/// The real bridge over a mock channel, and everything that crossed it.
class _WatchChannelHarness {
  _WatchChannelHarness() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (fail) {
            throw PlatformException(code: 'no_watch', message: 'not paired');
          }
          return null;
        });
  }

  final MethodChannel channel = const MethodChannel(_channelName);
  final List<MethodCall> calls = [];
  final WeftWatchBridge bridge = WeftWatchBridge(
    channel: const MethodChannel(_channelName),
  );

  /// Refuse every call the way an unpaired watch does.
  bool fail = false;

  List<String> get methods => [for (final call in calls) call.method];

  List<Map<Object?, Object?>> get arguments => [
    for (final call in calls)
      if (call.arguments case final Map<Object?, Object?> map) map,
  ];

  /// One call the other way, as the platform would make it.
  ///
  /// Encoded and pushed through the binary messenger rather than handed to the
  /// handler directly, so the argument decoding — a `Map<Object?, Object?>` from
  /// the standard codec, not the `Map<String, Object?>` a literal produces — is
  /// exercised too. `WatchReply.fromJson` takes `Object?` for precisely that
  /// reason.
  Future<void> fromPlatform(
    String method,
    Map<String, Object?> arguments,
  ) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          _channelName,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall(method, arguments),
          ),
          (_) {},
        );
    await pumpEventQueue();
  }

  void dispose() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }
}
