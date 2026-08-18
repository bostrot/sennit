import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/services/sms/sms_platform.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_sms/weft_sms.dart';

/// Android's telephony stack, as a map.
///
/// There is no version of `flutter test` with a SIM in it, and none of what is
/// worth testing here needs one. What the platform side does is read cursors;
/// what *this* side does is decide what a row means — which rows are messages
/// at all, which are unplaceable, what a type and a status say about delivery,
/// and what happens when the role is handed to another app underneath a call.
/// Every one of those is a decision, and each is wrong in a way that reaches
/// the user as a missing or mislabelled message.
class _FakeSmsChannel {
  _FakeSmsChannel() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, _handle);
  }

  static const Map<String, Object?> _defaultStatus = {
    'supported': true,
    'isDefault': true,
    'canRequestRole': false,
    'hasPermissions': true,
    'defaultPackage': 'com.bostrot.weft',
  };

  final MethodChannel channel = const MethodChannel('weft-test/sms');

  /// What `getStatus` answers — the role held, by default.
  Map<String, Object?>? status = _defaultStatus;

  /// Rows `getThreads` answers with.
  List<Map<String, Object?>> threads = const [];

  /// Rows `getMessages` answers with.
  List<Map<String, Object?>> messages = const [];

  /// Events queued before Dart attached, as `SmsBridge` tags them.
  List<Map<String, Object?>> pending = const [];

  /// What `sendMessage` writes back, or null for a platform that refused.
  Map<String, Object?>? sentRow;

  /// The user's answer to the role dialog.
  bool roleGranted = false;

  /// Methods that fail, and the code they fail with — a role handed away
  /// mid-call, a permission revoked in Settings.
  Map<String, String> failures = const {};

  /// Every method invoked, in order.
  final List<String> calls = [];

  /// Arguments of the last call to each method.
  final Map<String, Object?> arguments = {};

  Future<Object?> _handle(MethodCall call) async {
    calls.add(call.method);
    arguments[call.method] = call.arguments;

    final failure = failures[call.method];
    if (failure != null) {
      throw PlatformException(code: failure, message: 'test failure');
    }

    switch (call.method) {
      case 'getStatus':
        return status;
      case 'requestRole':
        return roleGranted;
      case 'getThreads':
        return threads;
      case 'getMessages':
        return messages;
      case 'getPending':
        return pending;
      case 'sendMessage':
        return sentRow;
      case 'markThreadRead':
        return 3;
      default:
        throw MissingPluginException(call.method);
    }
  }

  /// Pushes an event the way the platform does when Dart *is* listening.
  Future<void> emit(String event, Map<String, Object?> payload) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          channel.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall(event, payload),
          ),
          (_) {},
        );
  }

  void dispose() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }
}

/// A provider row, with the fields a test cares about overridden.
Map<String, Object?> row({
  String id = '11',
  String threadId = '7',
  String address = '+441234567890',
  String body = 'hello',
  int timestamp = 1700000000000,
  int type = SmsProviderType.inbox,
  int status = SmsProviderStatus.none,
  Object? subject,
  Object? attachmentUri,
  Object? attachmentMimeType,
  Object? attachmentSizeBytes,
}) => {
  'id': id,
  'threadId': threadId,
  'address': address,
  'body': body,
  'timestamp': timestamp,
  'type': type,
  'status': status,
  'subject': subject,
  'attachmentUri': attachmentUri,
  'attachmentMimeType': attachmentMimeType,
  'attachmentSizeBytes': attachmentSizeBytes,
};

void main() {
  // The channel needs a binding: a mock handler is registered on the test
  // binary messenger, which does not exist until this call.
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeSmsChannel platform;
  late SmsPlatform sms;

  setUp(() {
    platform = _FakeSmsChannel();
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
        expect(await absent.requestRole(), isFalse);
        expect(await absent.markThreadRead('7'), 0);
      },
    );

    test('a declined role is an answer, not an error', () async {
      platform.roleGranted = false;

      expect(await sms.requestRole(), isFalse);
      // And nothing else broke: the app goes on working with the SMS network
      // simply absent, which is the whole promise of the decline path.
      expect(await sms.threads(), isEmpty);
    });

    test('an accepted role resolves true', () async {
      platform.roleGranted = true;

      expect(await sms.requestRole(), isTrue);
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
      platform.messages = [row(body: 'hello')];

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
        row(id: ''),
        {'threadId': '7', 'body': 'orphan'},
        row(threadId: ''),
        row(id: '12'),
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
      platform.messages = [row(type: SmsProviderType.inbox)];

      // Not `sent`: ticks belong to messages the user sent, and painting them
      // on a received bubble is wrong in a way that looks deliberate.
      expect((await sms.messages('7')).single.deliveryState, isNull);
    });

    test('the outbox is sending, and a report makes it delivered', () async {
      platform.messages = [
        row(id: '1', type: SmsProviderType.outbox),
        row(
          id: '2',
          type: SmsProviderType.sent,
          status: SmsProviderStatus.complete,
        ),
        row(id: '3', type: SmsProviderType.failed),
        row(
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
      platform.sentRow = row(
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

      await platform.emit('onSmsReceived', row(id: '40', body: 'ping'));
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
          row(
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
          {'event': 'onSmsReceived', 'payload': row(id: '50', body: 'first')},
          {
            'event': 'onMmsPush',
            'payload': {'receivedAt': 1700000000001, 'sizeBytes': 12},
          },
          {'event': 'onSmsReceived', 'payload': row(id: '51', body: 'second')},
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
        {'payload': row(id: '60')},
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
