import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:weft_bridges/weft_bridges.dart';

void main() {
  final base = Uri.parse('https://bridge.example.org/_matrix/provision');

  BridgeProvisioningClient clientReturning(
    Map<String, Object?> Function(http.Request request) handler, {
    int status = 200,
  }) {
    return BridgeProvisioningClient(
      baseUrl: base,
      accessToken: 'syt_token',
      httpClient: MockClient(
        (r) async => http.Response(jsonEncode(handler(r)), status),
      ),
    );
  }

  group('whoami', () {
    test('parses the bridge and its logins', () async {
      final client = clientReturning((r) {
        expect(r.url.path, '/_matrix/provision/v3/whoami');
        expect(r.headers['authorization'], 'Bearer syt_token');
        return {
          'network': {
            'displayname': 'WhatsApp',
            'beeper_bridge_type': 'whatsapp',
          },
          'logins': [
            {
              'id': 'login1',
              'name': '+4915112345678',
              'state_event': 'CONNECTED',
              'profile': {'name': 'Anna Maven'},
            },
          ],
        };
      });

      final result = await client.whoami();

      expect(result.networkId, 'whatsapp');
      expect(result.networkName, 'WhatsApp');
      expect(result.logins.single.state, BridgeLoginState.connected);
      expect(result.logins.single.label, 'Anna Maven');
      expect(result.logins.single.isActive, isTrue);
    });

    test('flags a login needing re-authentication', () async {
      final client = clientReturning(
        (_) => {
          'logins': [
            {
              'id': 'l',
              'state_event': 'BAD_CREDENTIALS',
              'error': 'logged out',
            },
          ],
        },
      );

      final login = (await client.whoami()).logins.single;
      expect(login.state, BridgeLoginState.badCredentials);
      expect(login.needsAttentionForTest, isTrue);
      expect(login.isActive, isFalse);
    });

    test('survives a bridge that omits optional fields', () async {
      final client = clientReturning((_) => {});
      final result = await client.whoami();
      expect(result.logins, isEmpty);
      expect(result.networkId, isNull);
    });
  });

  group('login flows', () {
    test('lists what the bridge offers', () async {
      final client = clientReturning(
        (_) => {
          'flows': [
            {'id': 'qr', 'name': 'Scan QR code'},
            {'id': 'phone', 'name': 'Phone number', 'description': 'SMS code'},
          ],
        },
      );

      final flows = await client.loginFlows();
      expect(flows.map((f) => f.id), ['qr', 'phone']);
      expect(flows.last.description, 'SMS code');
    });

    test(
      'drops entries with no id rather than offering a dead button',
      () async {
        final client = clientReturning(
          (_) => {
            'flows': [
              {'name': 'Broken'},
              {'id': 'ok', 'name': 'Fine'},
            ],
          },
        );
        expect((await client.loginFlows()).map((f) => f.id), ['ok']);
      },
    );
  });

  group('errors', () {
    test('surfaces the bridge error message over the status code', () async {
      final client = BridgeProvisioningClient(
        baseUrl: base,
        accessToken: 't',
        httpClient: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'errcode': 'M_FORBIDDEN',
              'error': 'This bridge does not serve your homeserver',
            }),
            403,
          ),
        ),
      );

      try {
        await client.whoami();
        fail('expected a BridgeException');
      } on BridgeException catch (e) {
        expect(e.message, 'This bridge does not serve your homeserver');
        expect(e.errorCode, 'M_FORBIDDEN');
        expect(e.statusCode, 403);
      }
    });

    test('explains a 404 as a wrong provisioning URL', () async {
      final client = BridgeProvisioningClient(
        baseUrl: base,
        accessToken: 't',
        httpClient: MockClient((_) async => http.Response('', 404)),
      );

      expect(
        () => client.whoami(),
        throwsA(
          isA<BridgeException>().having(
            (e) => e.message,
            'message',
            contains('_matrix/provision'),
          ),
        ),
      );
    });

    test('an unreachable bridge is an exception, not a hang', () async {
      final client = BridgeProvisioningClient(
        baseUrl: base,
        accessToken: 't',
        httpClient: MockClient((_) async => throw const _Down()),
      );

      expect(() => client.whoami(), throwsA(isA<BridgeException>()));
    });
  });

  group('LoginStep parsing', () {
    test('reads a user_input step with its fields', () {
      final step = LoginStep.fromJson({
        'step_id': 'phone',
        'type': 'user_input',
        'instructions': 'Enter your number',
        'login_id': 'lg1',
        'user_input': {
          'fields': [
            {
              'id': 'phone',
              'type': 'phone_number',
              'name': 'Phone number',
              'pattern': r'^\+[0-9]{8,15}$',
            },
          ],
        },
      });

      expect(step.type, LoginStepType.userInput);
      expect(step.loginId, 'lg1');
      expect(step.fields.single.keyboardHint, 'phone');
      expect(step.fields.single.validate('+4915112345678'), isTrue);
      expect(step.fields.single.validate('nope'), isFalse);
    });

    test('reads a display_and_wait QR step', () {
      final step = LoginStep.fromJson({
        'step_id': 'qr',
        'type': 'display_and_wait',
        'display_and_wait': {'type': 'qr', 'data': 'wa://pair?x=1'},
      });

      expect(step.type, LoginStepType.displayAndWait);
      expect(step.displayType, 'qr');
      expect(step.displayData, 'wa://pair?x=1');
    });

    test('marks an unknown step type unsupported instead of crashing', () {
      final step = LoginStep.fromJson({
        'step_id': 's',
        'type': 'holographic_handshake',
      });

      expect(step.type, LoginStepType.unsupported);
      expect(step.raw['type'], 'holographic_handshake');
    });

    test('a secret field is flagged so the UI can obscure it', () {
      final step = LoginStep.fromJson({
        'step_id': 's',
        'type': 'user_input',
        'user_input': {
          'fields': [
            {'id': 'p', 'type': 'password', 'name': 'Password'},
            {'id': 'u', 'type': 'username', 'name': 'Username'},
          ],
        },
      });

      expect(step.fields.first.isSecret, isTrue);
      expect(step.fields.last.isSecret, isFalse);
    });

    test('a field with an uncompilable pattern still accepts input', () {
      final field = LoginStep.fromJson({
        'step_id': 's',
        'type': 'user_input',
        'user_input': {
          'fields': [
            {'id': 'x', 'type': 'text', 'name': 'X', 'pattern': '([unclosed'},
          ],
        },
      }).fields.single;

      // A bridge shipping a bad regex must not make its login impossible.
      expect(field.validate('anything'), isTrue);
      expect(field.validate(''), isFalse);
    });
  });
}

class _Down implements Exception {
  const _Down();
}

/// `needsAttention` lives on the state enum; this keeps the test readable.
extension on BridgeLogin {
  bool get needsAttentionForTest => state.needsAttention;
}
