import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:weft_bridges/weft_bridges.dart';

/// The provisioning API as a real bridgev2 bridge serves it.
///
/// Every payload here is the shape mautrix-go v0.26 writes, taken from the
/// bridges on matrix.aachen.dev (WhatsApp, Signal, Telegram, Google Messages
/// v26.08) and from their sources: the `user_id` the auth middleware insists
/// on, `whoami`'s nested `state`, `complete.user_login_id`, the long-polled
/// `display_and_wait`, and the error codes each connector returns.
void main() {
  final base = Uri.parse('https://matrix.example.org/_sennit/bridges/wa');

  group('authentication', () {
    test('names the Matrix user on every request', () async {
      final seen = <Uri>[];
      final client = BridgeProvisioningClient(
        baseUrl: base,
        accessToken: 'syt',
        userId: '@anna:example.org',
        httpClient: MockClient((r) async {
          seen.add(r.url);
          return http.Response(jsonEncode({'flows': <Object>[]}), 200);
        }),
      );

      await client.loginFlows();
      await client
          .startLogin('qr')
          .catchError(
            (_) => const LoginStep(stepId: '', type: LoginStepType.unsupported),
          );

      // Without it bridgev2 answers M_UNKNOWN_TOKEN, whatever the token.
      for (final uri in seen) {
        expect(uri.queryParameters['user_id'], '@anna:example.org');
      }
      expect(seen.first.path, '/_sennit/bridges/wa/v3/login/flows');
    });

    test('a relogin names the account it replaces', () async {
      late Uri seen;
      final client = BridgeProvisioningClient(
        baseUrl: base,
        accessToken: 'syt',
        userId: '@anna:example.org',
        httpClient: MockClient((r) async {
          seen = r.url;
          return http.Response(
            jsonEncode({
              'login_id': 'p1',
              'step_id': 'fi.mau.whatsapp.login.qr',
              'type': 'display_and_wait',
              'display_and_wait': {'type': 'qr', 'data': '2@abc'},
            }),
            200,
          );
        }),
      );

      await client.startLogin('qr', reloginId: '4915112345678');

      expect(seen.path, endsWith('/v3/login/start/qr'));
      expect(seen.queryParameters['login_id'], '4915112345678');
    });
  });

  group('whoami as bridgev2 writes it', () {
    test('reads the nested state, the bot and the flows', () async {
      final client = BridgeProvisioningClient(
        baseUrl: base,
        accessToken: 'syt',
        httpClient: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'network': {
                'displayname': 'Telegram',
                'network_id': 'telegram',
                'beeper_bridge_type': 'telegram',
              },
              'login_flows': [
                {'name': 'Phone Number', 'id': 'phone'},
                {'name': 'QR Code', 'id': 'qr'},
              ],
              'bridge_bot': '@telegrambot:example.org',
              'logins': [
                {
                  'id': '123456',
                  'name': 'Anna',
                  'state': {
                    'state_event': 'BAD_CREDENTIALS',
                    'message': 'Session revoked from another device',
                  },
                  'profile': {'name': 'Anna M.', 'phone': '+49151'},
                },
              ],
            }),
            200,
          ),
        ),
      );

      final whoami = await client.whoami();

      expect(whoami.networkId, 'telegram');
      expect(whoami.botUserId, '@telegrambot:example.org');
      expect(whoami.flows.map((f) => f.id), ['phone', 'qr']);
      final login = whoami.logins.single;
      expect(login.state, BridgeLoginState.badCredentials);
      expect(login.errorMessage, 'Session revoked from another device');
      expect(login.label, 'Anna M.');
      expect(whoami.hasActiveLogin, isFalse);
    });

    test('a 200 that is not JSON reads as "nothing here"', () async {
      // What a single-page app's catch-all answers for a path nobody routes.
      final client = BridgeProvisioningClient(
        baseUrl: base,
        accessToken: 'syt',
        httpClient: MockClient(
          (_) async =>
              http.Response('<!doctype html><title>Sennit</title>', 200),
        ),
      );

      await expectLater(
        client.whoami(),
        throwsA(
          isA<BridgeException>().having(
            (e) => e.failure,
            'failure',
            BridgeFailure.notFound,
          ),
        ),
      );
    });

    test('a network failure is unreachable, a slow bridge a timeout', () async {
      final offline = BridgeProvisioningClient(
        baseUrl: base,
        accessToken: 'syt',
        httpClient: MockClient((_) async => throw http.ClientException('down')),
      );
      await expectLater(
        offline.whoami(),
        throwsA(
          isA<BridgeException>().having(
            (e) => e.failure,
            'failure',
            BridgeFailure.unreachable,
          ),
        ),
      );

      final slow = BridgeProvisioningClient(
        baseUrl: base,
        accessToken: 'syt',
        timeout: const Duration(milliseconds: 10),
        httpClient: MockClient((_) async {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          return http.Response('{}', 200);
        }),
      );
      await expectLater(
        slow.whoami(),
        throwsA(
          isA<BridgeException>().having(
            (e) => e.failure,
            'failure',
            BridgeFailure.timeout,
          ),
        ),
      );
    });
  });

  group('a session against scripted bridges', () {
    /// Answers each request with the next response for its path kind.
    BridgeProvisioningClient script(
      List<Object> responses, {
      List<String>? paths,
      List<Object?>? bodies,
    }) {
      var index = 0;
      return BridgeProvisioningClient(
        baseUrl: base,
        accessToken: 'syt',
        userId: '@anna:example.org',
        httpClient: MockClient((r) async {
          paths?.add(r.url.path);
          bodies?.add(r.body.isEmpty ? null : jsonDecode(r.body));
          final next =
              responses[index < responses.length
                  ? index
                  : responses.length - 1];
          index++;
          if (next is http.Response) return next;
          if (next is Exception) throw next;
          return http.Response(jsonEncode(next), 200);
        }),
      );
    }

    test('WhatsApp QR: refreshes several times, then completes', () async {
      Map<String, Object?> qr(String data) => {
        'login_id': 'p1',
        'type': 'display_and_wait',
        'step_id': 'fi.mau.whatsapp.login.qr',
        'instructions':
            'Scan the QR code with the WhatsApp mobile app to log in',
        'display_and_wait': {'type': 'qr', 'data': data},
      };
      final session = BridgeLoginSession(
        client: script([
          qr('2@one'),
          qr('2@two'),
          qr('2@three'),
          {
            'login_id': 'p1',
            'type': 'complete',
            'step_id': 'fi.mau.whatsapp.complete',
            'instructions': 'Successfully logged in as +4915112345678',
            'complete': {'user_login_id': '4915112345678'},
          },
        ]),
        flowId: 'qr',
      );
      addTearDown(session.dispose);

      final shown = <String?>[];
      session.updates.listen((s) => shown.add(s.currentStep?.displayData));
      await session.start();

      expect(session.status, BridgeLoginStatus.complete);
      expect(session.refreshes, 2);
      expect(shown, containsAllInOrder(['2@one', '2@two', '2@three']));
      expect(
        session.userLoginId,
        '4915112345678',
        reason: 'logging out later is addressed to the remote account',
      );
    });

    test('a long poll that times out is asked again, not failed', () async {
      final paths = <String>[];
      final session = BridgeLoginSession(
        client: script([
          {
            'login_id': 'p1',
            'type': 'display_and_wait',
            'step_id': 'fi.mau.signal.qr',
            'display_and_wait': {'type': 'qr', 'data': 'sgnl://linkdevice?a'},
          },
          TimeoutException('long poll'),
          {
            'login_id': 'p1',
            'type': 'complete',
            'step_id': 'fi.mau.signal.complete',
            'complete': {'user_login_id': 'aci'},
          },
        ], paths: paths),
        flowId: 'qr',
      );
      addTearDown(session.dispose);

      await session.start();

      expect(session.status, BridgeLoginStatus.complete);
      expect(paths.where((p) => p.endsWith('/display_and_wait')), hasLength(2));
    });

    test('Telegram: phone, wrong code, right code, 2FA password', () async {
      final bodies = <Object?>[];
      Map<String, Object?> input(
        String stepId,
        String type,
        String name, {
        String? instructions,
      }) => {
        'login_id': 'p1',
        'type': 'user_input',
        'step_id': stepId,
        'instructions': ?instructions,
        'user_input': {
          'fields': [
            {
              'type': type,
              'id': type == 'password' ? 'password' : stepId,
              'name': name,
            },
          ],
        },
      };
      final session = BridgeLoginSession(
        client: script([
          input('fi.mau.telegram.phone_number', 'phone_number', 'Phone number'),
          input(
            'fi.mau.telegram.code',
            '2fa_code',
            'Code',
            instructions: 'Enter the login code Telegram sent you',
          ),
          input(
            'fi.mau.telegram.code_incorrect',
            '2fa_code',
            'Code',
            instructions: 'Incorrect code',
          ),
          input(
            'fi.mau.telegram.password',
            'password',
            'Password',
            instructions: 'You have two-factor authentication enabled.',
          ),
          {
            'login_id': 'p1',
            'type': 'complete',
            'step_id': 'fi.mau.telegram.complete',
            'complete': {'user_login_id': '777'},
          },
        ], bodies: bodies),
        flowId: 'phone',
      );
      addTearDown(session.dispose);

      await session.start();
      expect(session.currentStep!.fields.single.type, 'phone_number');

      // Spaces and dashes are the bridge's to strip, and must not fail here.
      await session.submitInput({
        'fi.mau.telegram.phone_number': '+49 151 123-45678',
      });
      expect(bodies.last, {'fi.mau.telegram.phone_number': '+4915112345678'});
      expect(session.currentStep!.stepId, 'fi.mau.telegram.code');

      await session.submitInput({'fi.mau.telegram.code': '11111'});
      expect(session.currentStep!.stepId, 'fi.mau.telegram.code_incorrect');
      expect(session.currentStep!.instructions, 'Incorrect code');
      expect(session.status, BridgeLoginStatus.waitingForUser);

      await session.submitInput({'fi.mau.telegram.code_incorrect': '12345'});
      expect(session.currentStep!.fields.single.isSecret, isTrue);

      await session.submitInput({'password': 'hunter2'});
      expect(session.status, BridgeLoginStatus.complete);
    });

    test('WhatsApp pairing code: phone in, code out, then wait', () async {
      final session = BridgeLoginSession(
        client: script([
          {
            'login_id': 'p1',
            'type': 'user_input',
            'step_id': 'fi.mau.whatsapp.login.phone',
            'user_input': {
              'fields': [
                {
                  'type': 'phone_number',
                  'id': 'phone_number',
                  'name': 'Phone number',
                  'description': 'Include the country code with +',
                },
              ],
            },
          },
          {
            'login_id': 'p1',
            'type': 'display_and_wait',
            'step_id': 'fi.mau.whatsapp.login.code',
            'instructions':
                'Input the pairing code in the WhatsApp mobile app to log in',
            'display_and_wait': {'type': 'code', 'data': 'ABCD-EFGH'},
          },
          http.Response(
            jsonEncode({
              'errcode': 'FI.MAU.WHATSAPP.LOGIN_TIMEOUT',
              'error':
                  'Entering code or scanning QR timed out. Please try again.',
            }),
            400,
          ),
        ]),
        flowId: 'phone',
      );
      addTearDown(session.dispose);

      await session.start();
      final pending = session.submitInput({'phone_number': '+4915112345678'});
      await pending;

      expect(session.status, BridgeLoginStatus.failed);
      expect(session.errorCode, 'FI.MAU.WHATSAPP.LOGIN_TIMEOUT');
      expect(session.problem, BridgeLoginProblem.bridge);
    });

    test(
      'cancelling tells the bridge, so the next attempt is not blocked',
      () async {
        final paths = <String>[];
        final gate = Completer<http.Response>();
        var calls = 0;
        final client = BridgeProvisioningClient(
          baseUrl: base,
          accessToken: 'syt',
          httpClient: MockClient((r) {
            paths.add(r.url.path);
            calls++;
            if (calls == 1) {
              return Future.value(
                http.Response(
                  jsonEncode({
                    'login_id': 'p9',
                    'type': 'display_and_wait',
                    'step_id': 'qr',
                    'display_and_wait': {'type': 'qr', 'data': 'x'},
                  }),
                  200,
                ),
              );
            }
            if (r.url.path.endsWith('/display_and_wait')) return gate.future;
            return Future.value(http.Response('{}', 200));
          }),
        );
        final session = BridgeLoginSession(client: client, flowId: 'qr');
        addTearDown(session.dispose);

        unawaited(session.start());
        await Future<void>.delayed(const Duration(milliseconds: 20));
        session.cancel();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        gate.complete(http.Response('{}', 200));

        expect(session.problem, BridgeLoginProblem.cancelled);
        expect(paths, contains('/_sennit/bridges/wa/v3/login/cancel/p9'));
      },
    );
  });

  group('fields', () {
    test('a select field accepts only its options', () {
      final field = LoginInputField.fromJson({
        'type': 'select',
        'id': 'retry',
        'name': 'Finish signing in',
        'options': ['Retry', 'Cancel'],
      });
      expect(field.isSelect, isTrue);
      expect(field.validate('Retry'), isTrue);
      expect(field.validate('Maybe'), isFalse);
    });

    test('an optional field may stay empty', () {
      final field = LoginInputField.fromJson({
        'type': 'text',
        'id': 'x',
        'name': 'X',
        'optional': true,
      });
      expect(field.validate(''), isTrue);
    });
  });

  group('well-known discovery', () {
    final homeserver = Uri.parse('https://matrix.example.org');

    test('reads absolute, relative and object entries', () {
      final found = parseBridgeWellKnown({
        'm.homeserver': {'base_url': 'https://matrix.example.org'},
        kBridgesWellKnownKey: {
          'whatsapp': 'https://matrix.example.org/_sennit/bridges/whatsapp',
          'Signal': {'provisioning_url': '/_sennit/bridges/signal'},
          'telegram': 42,
          'evil': 'javascript:alert(1)',
        },
      }, homeserver: homeserver);

      expect(found.keys, unorderedEquals(['whatsapp', 'signal']));
      expect(
        found['signal'].toString(),
        'https://matrix.example.org/_sennit/bridges/signal',
      );
    });

    test('no section is no bridges', () {
      expect(parseBridgeWellKnown({}, homeserver: homeserver), isEmpty);
    });
  });
}
