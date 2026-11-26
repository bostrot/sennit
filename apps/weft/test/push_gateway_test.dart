import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:weft/app/localisation.dart';
import 'package:weft/features/notifications/push_explanation_screen.dart';
import 'package:weft/services/notifications/background_push.dart';
import 'package:weft/services/notifications/push_registration.dart';
import 'package:weft_matrix/weft_matrix.dart';

void main() {
  group('which gateway', () {
    test('a store build asks before using Sennit\'s gateway', () {
      expect(
        effectivePushMode(stored: null, customUrl: null, offerSennit: true),
        isNull,
      );
    });

    test('a URL from before the choice existed keeps working', () {
      expect(
        effectivePushMode(
          stored: null,
          customUrl: 'https://sygnal.example.org/_matrix/push/v1/notify',
          offerSennit: true,
        ),
        PushGatewayMode.custom,
      );
    });

    test('other builds default to their own gateway', () {
      expect(
        effectivePushMode(stored: null, customUrl: null, offerSennit: false),
        PushGatewayMode.custom,
      );
    });

    test('a stored answer wins', () {
      for (final mode in PushGatewayMode.values) {
        expect(
          effectivePushMode(
            stored: mode.name,
            customUrl: 'https://sygnal.example.org/notify',
            offerSennit: true,
          ),
          mode,
        );
      }
    });

    test('each mode maps to its gateway', () {
      expect(
        gatewayForMode(PushGatewayMode.sennit, null),
        Uri.parse(kSennitPushGateway),
      );
      expect(
        gatewayForMode(PushGatewayMode.custom, 'https://a.example/notify'),
        Uri.parse('https://a.example/notify'),
      );
      expect(gatewayForMode(PushGatewayMode.custom, ''), isNull);
      expect(gatewayForMode(PushGatewayMode.off, 'https://a.example'), isNull);
      expect(gatewayForMode(null, 'https://a.example'), isNull);
    });
  });

  group('registration', () {
    late _Homeserver server;

    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      server = _Homeserver();
    });
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    WeftPushRegistration registration(
      _Transport transport,
      _Keys keys, {
      PushGatewayMode? mode = PushGatewayMode.sennit,
    }) => WeftPushRegistration(
      registry: MatrixPusherRegistry(session: server),
      keyStore: keys,
      tokens: transport,
      gatewayUrl: gatewayForMode(mode, null),
      mode: mode,
    );

    test('Sennit\'s gateway gets an event-id-only pusher', () async {
      final keys = _Keys();
      final outcome = await registration(
        _Transport('tok-1'),
        keys,
      ).ensureRegistered();

      expect(outcome.status, PushRegistrationStatus.registered);
      final set = server.sets.single;
      expect(set['app_id'], kAndroidPushAppId);
      expect(set['pushkey'], 'tok-1');
      final data = set['data']! as Map;
      expect(data['url'], kSennitPushGateway);
      expect(data['format'], kEventIdOnlyFormat);
      expect(keys.value, 'tok-1');
    });

    test(
      'the transport names the app id, so sandbox iOS gets its own',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        await registration(
          _Transport('apns', appId: kIosSandboxPushAppId),
          _Keys(),
        ).ensureRegistered();

        expect(server.sets.single['app_id'], kIosSandboxPushAppId);
      },
    );

    test('nothing reaches the homeserver before the user has chosen', () async {
      final outcome = await registration(
        _Transport('tok-1'),
        _Keys(),
        mode: null,
      ).ensureRegistered();

      expect(outcome.status, PushRegistrationStatus.undecided);
      expect(server.requests, isEmpty);
    });

    test(
      'off removes this device\'s pusher and gives the token back',
      () async {
        final transport = _Transport('tok-1');
        final keys = _Keys()..value = 'tok-1';

        final outcome = await registration(
          transport,
          keys,
          mode: PushGatewayMode.off,
        ).ensureRegistered();

        expect(outcome.status, PushRegistrationStatus.off);
        final removal = server.sets.single;
        expect(removal['pushkey'], 'tok-1');
        expect(removal['kind'], isNull);
        expect(keys.value, isNull);
        expect(transport.released, isTrue);
      },
    );

    test('a rotated token replaces the old pusher', () async {
      final transport = _Transport('tok-1');
      final keys = _Keys();
      final push = registration(transport, keys);
      addTearDown(push.dispose);
      await push.ensureRegistered();

      transport.current = 'tok-2';
      transport.refreshes.add('tok-2');
      await pumpEventQueue();

      final keysSent = [for (final set in server.sets) set['pushkey']];
      expect(keysSent, ['tok-1', 'tok-1', 'tok-2']);
      // The middle one is the old pusher being deleted.
      expect(server.sets[1]['kind'], isNull);
      expect(keys.value, 'tok-2');
    });
  });

  group('forwarding', () {
    test('a poke reaches the isolate that serves pushes', () async {
      final received = Completer<Map<String, Object?>>();
      final port = servePushes(
        (data) async => received.complete(data),
        name: 'weft.push.test',
      );
      addTearDown(port.close);

      final taken = await forwardPush({
        'event_id': r'$e',
        'room_id': '!r:example.org',
        'unread': '2',
      }, name: 'weft.push.test');

      expect(taken, isTrue);
      expect((await received.future)['event_id'], r'$e');
    });

    test('nobody serving means the caller boots its own', () async {
      expect(
        await forwardPush({'event_id': r'$e'}, name: 'weft.push.none'),
        isFalse,
      );
    });
  });

  group('explanation', () {
    Future<Future<bool?>> open(WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: weftLocalizationsDelegates,
          home: Builder(
            builder: (c) {
              context = c;
              return const SizedBox();
            },
          ),
        ),
      );
      final result = showPushExplanation(context);
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets('says what is sent and to whom, then asks', (tester) async {
      final result = await open(tester);

      expect(find.textContaining('push token'), findsOneWidget);
      expect(find.textContaining('Never the message text'), findsOneWidget);
      expect(find.textContaining('Apple (APNs)'), findsOneWidget);

      await tester.tap(find.text('Use Sennit’s gateway'));
      await tester.pumpAndSettle();
      expect(await result, isTrue);
    });

    testWidgets('another way is an answer too', (tester) async {
      final result = await open(tester);
      await tester.tap(find.text('Choose another way'));
      await tester.pumpAndSettle();
      expect(await result, isFalse);
    });
  });
}

class _Transport implements PushTransport {
  _Transport(this.current, {this.appId = kAndroidPushAppId});

  String? current;
  bool released = false;
  // ignore: close_sinks
  final refreshes = StreamController<String>.broadcast();

  @override
  final String appId;

  @override
  Future<String?> token() async => current;

  @override
  Stream<String> get tokenRefreshes => refreshes.stream;

  @override
  Stream<Map<String, Object?>> get pushes => const Stream.empty();

  @override
  Future<void> release() async => released = true;
}

class _Keys implements PushKeyStore {
  String? value;

  @override
  String? readPushKey() => value;

  @override
  void writePushKey(String? v) => value = v;
}

/// A homeserver that lists no pushers and records every `pushers/set`.
class _Homeserver implements MatrixApiSession {
  final requests = <http.Request>[];
  final sets = <Map<String, Object?>>[];

  @override
  Uri? get baseUrl => Uri.parse('https://hs.example.org');

  @override
  String? get accessToken => 'token';

  @override
  late final http.Client httpClient = MockClient((request) async {
    requests.add(request);
    if (request.url.path.endsWith('/pushers/set')) {
      sets.add((jsonDecode(request.body) as Map).cast<String, Object?>());
      return http.Response('{}', 200);
    }
    return http.Response('{"pushers": []}', 200);
  });
}
