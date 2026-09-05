import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/services/sms/sms_platform.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_sms/weft_sms.dart';

import 'support/sms_fixtures.dart';

void main() {
  // The channel needs a binding: a mock handler is registered on the test
  // binary messenger, which does not exist until this call.
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeSmsChannel platform;
  late SmsPlatform sms;

  setUp(() {
    platform = FakeSmsChannel();
    sms = SmsPlatform(channel: platform.channel);
  });

  tearDown(() async {
    await sms.dispose();
    platform.dispose();
  });

  group('availability', () {
    test('reports ready when Weft holds the role', () async {
      final status = await sms.status();

      expect(status.availability, SmsAvailability.ready);
      expect(status.isReady, isTrue);
      expect(status.hasPermissions, isTrue);
    });

    test(
      'a device with no telephony is unsupported, not merely not-default',
      () async {
        // The distinction the enum exists for. A tablet must not be offered a
        // role dialog it cannot complete, and `canRequestRole` is what a button
        // is wired to.
        platform.status = const {
          'supported': false,
          'isDefault': false,
          'canRequestRole': false,
          'hasPermissions': false,
        };

        final status = await sms.status();

        expect(status.availability, SmsAvailability.unsupported);
        expect(status.canRequestRole, isFalse);
      },
    );

    test(
      'another app holding the role is notDefault, with its package',
      () async {
        platform.status = const {
          'supported': true,
          'isDefault': false,
          'canRequestRole': true,
          'hasPermissions': false,
          'defaultPackage': 'com.google.android.apps.messaging',
        };

        final status = await sms.status();

        expect(status.availability, SmsAvailability.notDefault);
        expect(status.canRequestRole, isTrue);
        expect(status.defaultPackage, 'com.google.android.apps.messaging');
      },
    );

    test(
      'a platform with no SMS channel is unsupported rather than a crash',
      () async {
        // Every desktop build, and iOS. `MissingPluginException` is the normal
        // state of four of Weft's five platforms — an app that threw here would
        // fail to start on all of them.
        final absent = SmsPlatform(
          channel: const MethodChannel('weft-test/absent'),
        );
        addTearDown(absent.dispose);

        expect(await absent.status(), SmsPlatformStatus.unsupported);
        expect(await absent.threads(), isEmpty);
        expect(await absent.messages('7'), isEmpty);
        expect(await absent.send(address: '+44', body: 'hi'), isNull);
        expect(await absent.requestRole(), SmsRoleOutcome.unavailable);
        expect(await absent.markThreadRead('7'), 0);
      },
    );

    test('a declined role is an answer, not an error', () async {
      platform.roleOutcome = 'denied';

      expect(await sms.requestRole(), SmsRoleOutcome.denied);
      // And nothing else broke: the app goes on working with the SMS network
      // simply absent, which is the whole promise of the decline path.
      expect(await sms.threads(), isEmpty);
    });

    test('an accepted role resolves granted', () async {
      platform.roleOutcome = 'granted';

      expect(await sms.requestRole(), SmsRoleOutcome.granted);
    });

    test('a system refusal is not a decline', () async {
      // No dialog was shown — no telephony, or a ROM with the role stripped
      // out. The user was never asked, so reporting a refusal is the one thing
      // the old boolean could not do.
      platform.roleOutcome = 'unavailable';

      expect(await sms.requestRole(), SmsRoleOutcome.unavailable);
    });

    test('an interrupted request is not a decline either', () async {
      // The activity was destroyed while Android's dialog was up. The answer
      // exists on the phone; it just did not come back through this call.
      platform.roleOutcome = 'interrupted';

      expect(await sms.requestRole(), SmsRoleOutcome.interrupted);
    });

    test('an outcome this build has never heard of reads as interrupted', () {
      // A Kotlin side newer than this Dart, which a hot restart produces. The
      // safe default is "go and ask the system", never "the user said no".
      expect(SmsRoleOutcome.fromWire('teleported'), SmsRoleOutcome.interrupted);
      expect(SmsRoleOutcome.fromWire(null), SmsRoleOutcome.interrupted);
      expect(SmsRoleOutcome.fromWire(true), SmsRoleOutcome.interrupted);
    });
  });

  group('reading', () {
    test('threads decode into SmsThread with their unread counts', () async {
      platform.threads = [
        {
          'id': '7',
          'addresses': ['+441234567890'],
          'snippet': 'see you at six',
          'unreadCount': 2,
          'lastMessageAt': 1700000000000,
          'archived': false,
        },
      ];

      final threads = await sms.threads();

      expect(threads, hasLength(1));
      expect(threads.single.id, '7');
      expect(threads.single.addresses, ['+441234567890']);
      expect(threads.single.unreadCount, 2);
      expect(threads.single.isGroup, isFalse);
      expect(threads.single.roomId, 'sms:thread:7');
    });

    test('a group thread keeps every participant', () async {
      platform.threads = [
        {
          'id': '9',
          'addresses': ['+441234567890', '+441234567891', '  '],
        },
      ];

      final thread = (await sms.threads()).single;

      // The blank address is dropped rather than kept as an empty
      // participant: a corrupt row must not turn a pair into a "group".
      expect(thread.addresses, hasLength(2));
      expect(thread.isGroup, isTrue);
    });

    test('messages become WeftMessages on the SMS network', () async {
      platform.messages = [smsRow(body: 'hello')];

      final message = (await sms.messages('7')).single.toWeftMessage();

      expect(message.network, ChatNetwork.sms);
      expect(message.roomId, 'sms:thread:7');
      expect(message.eventId, 'sms:msg:11');
      expect(message.body, 'hello');
      expect(message.isOwn, isFalse);
    });

    test('the limit reaches the platform', () async {
      await sms.messages('7', limit: 25);

      expect(
        (platform.arguments['getMessages']! as Map)['limit'],
        25,
        reason:
            'a thread with ten years of messages must not cross the channel whole',
      );
    });

    test('a row with no id or no thread is dropped, not guessed at', () async {
      // Both are the provider's own keys, and a row missing either cannot be
      // addressed, updated or merged. Minting an id would produce a bubble
      // that reappears on every single read.
      platform.messages = [
        smsRow(id: ''),
        {'threadId': '7', 'body': 'orphan'},
        smsRow(threadId: ''),
        smsRow(id: '12'),
      ];

      final messages = await sms.messages('7');

      expect(messages, hasLength(1));
      expect(messages.single.id, '12');
    });

    test('a permission revoked mid-call is an empty read, not a throw', () async {
      // The user handed the role to another app while the inbox was refreshing.
      // Every other network in that inbox is still working.
      platform.failures = {
        'getThreads': 'not_default',
        'getMessages': 'no_permission',
      };

      expect(await sms.threads(), isEmpty);
      expect(await sms.messages('7'), isEmpty);
    });

    test('marking a thread read returns how many rows changed', () async {
      expect(await sms.markThreadRead('7'), 3);
      expect((platform.arguments['markThreadRead']! as Map)['threadId'], '7');
    });
  });

  group('delivery state', () {
    test('an inbox row has none at all', () async {
      platform.messages = [smsRow(type: SmsProviderType.inbox)];

      // Not `sent`: ticks belong to messages the user sent, and painting them
      // on a received bubble is wrong in a way that looks deliberate.
      expect((await sms.messages('7')).single.deliveryState, isNull);
    });

    test('the outbox is sending, and a report makes it delivered', () async {
      platform.messages = [
        smsRow(id: '1', type: SmsProviderType.outbox),
        smsRow(
          id: '2',
          type: SmsProviderType.sent,
          status: SmsProviderStatus.complete,
        ),
        smsRow(id: '3', type: SmsProviderType.failed),
        smsRow(
          id: '4',
          type: SmsProviderType.sent,
          status: SmsProviderStatus.pending,
        ),
      ];

      final states = [
        for (final message in await sms.messages('7')) message.deliveryState,
      ];

      expect(states, [
        DeliveryState.sending,
        DeliveryState.delivered,
        DeliveryState.failed,
        // Requested and not yet answered: the handset still handed it over.
        DeliveryState.sent,
      ]);
    });

    test('a missing status column does not become a tick', () async {
      // The trap this guards: `STATUS_NONE` is -1 and `STATUS_COMPLETE` is 0,
      // so a column defaulted to zero claims delivery nobody reported.
      platform.messages = [
        {
          'id': '1',
          'threadId': '7',
          'address': '+441234567890',
          'body': 'hi',
          'timestamp': 1700000000000,
          'type': SmsProviderType.sent,
        },
      ];

      expect(
        (await sms.messages('7')).single.deliveryState,
        DeliveryState.sent,
      );
    });
  });

  group('sending', () {
    test('a sent message comes back as the stored row', () async {
      platform.sentRow = smsRow(
        id: '30',
        type: SmsProviderType.outbox,
        body: 'on my way',
      );

      final sent = await sms.send(address: '+441234567890', body: 'on my way');

      expect(sent, isNotNull);
      expect(sent!.isOutgoing, isTrue);
      expect(sent.deliveryState, DeliveryState.sending);
      expect(
        (platform.arguments['sendMessage']! as Map)['address'],
        '+441234567890',
      );
    });

    test('a refusal is null rather than an exception', () async {
      platform.failures = {'sendMessage': 'not_default'};

      expect(await sms.send(address: '+441234567890', body: 'hi'), isNull);
    });
  });

  group('incoming', () {
    test('a received message reaches the stream', () async {
      final received = <SmsMessage>[];
      final subscription = sms.incoming.listen(received.add);
      addTearDown(subscription.cancel);

      await platform.emit('onSmsReceived', smsRow(id: '40', body: 'ping'));
      await pumpEventQueue();

      expect(received, hasLength(1));
      expect(received.single.body, 'ping');
      expect(received.single.isOutgoing, isFalse);
    });

    test(
      'a delivery report arrives on statusUpdates, not on incoming',
      () async {
        // Two streams because they are two different things to a timeline: one
        // appends a bubble, the other changes one that is already drawn. A
        // status delivered as an arrival would duplicate every sent message.
        final received = <SmsMessage>[];
        final statuses = <SmsMessage>[];
        final subscriptions = [
          sms.incoming.listen(received.add),
          sms.statusUpdates.listen(statuses.add),
        ];
        addTearDown(() => Future.wait(subscriptions.map((s) => s.cancel())));

        await platform.emit(
          'onSmsStatus',
          smsRow(
            id: '41',
            type: SmsProviderType.sent,
            status: SmsProviderStatus.complete,
          ),
        );
        await pumpEventQueue();

        expect(received, isEmpty);
        expect(statuses.single.deliveryState, DeliveryState.delivered);
      },
    );

    test('an MMS push is surfaced rather than silently dropped', () async {
      // Weft cannot download MMS yet. A push nobody is told about is a message
      // the sender watched leave their phone and the recipient never hears of.
      final pushes = <SmsMmsPush>[];
      final subscription = sms.mmsPushes.listen(pushes.add);
      addTearDown(subscription.cancel);

      await platform.emit('onMmsPush', {
        'receivedAt': 1700000000000,
        'sizeBytes': 180,
      });
      await pumpEventQueue();

      expect(pushes, hasLength(1));
      expect(pushes.single.sizeBytes, 180);
    });

    test('an unknown event is ignored, not thrown on', () async {
      await platform.emit('onSomethingNewer', {'id': '1'});
      await pumpEventQueue();
      // Reaching here without an exception is the assertion; a newer platform
      // side than this Dart survives a hot restart.
      expect(true, isTrue);
    });

    test(
      'a message that arrived before Dart was listening is replayed',
      () async {
        // The cold-start case: an SMS can *start* the process, arriving at a
        // broadcast receiver long before a Flutter engine exists.
        platform.pending = [
          {
            'event': 'onSmsReceived',
            'payload': smsRow(id: '50', body: 'first'),
          },
          {
            'event': 'onMmsPush',
            'payload': {'receivedAt': 1700000000001, 'sizeBytes': 12},
          },
          {
            'event': 'onSmsReceived',
            'payload': smsRow(id: '51', body: 'second'),
          },
        ];

        final received = <SmsMessage>[];
        final pushes = <SmsMmsPush>[];
        final subscriptions = [
          sms.incoming.listen(received.add),
          sms.mmsPushes.listen(pushes.add),
        ];
        addTearDown(() => Future.wait(subscriptions.map((s) => s.cancel())));

        await sms.drainPending();
        await pumpEventQueue();

        expect(received.map((m) => m.body), ['first', 'second']);
        expect(pushes, hasLength(1));
      },
    );

    test('a replayed event with no tag is dropped', () async {
      // The queue tags each entry with the method it would have been sent as.
      // An untagged entry cannot be told from an MMS push with no body, and
      // guessing turns a notification into a text message.
      platform.pending = [
        {'payload': smsRow(id: '60')},
        {'event': 'onSmsReceived'},
      ];

      final received = <SmsMessage>[];
      final subscription = sms.incoming.listen(received.add);
      addTearDown(subscription.cancel);

      await sms.drainPending();
      await pumpEventQueue();

      expect(received, isEmpty);
    });
  });
}
