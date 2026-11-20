import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:weft_bridges/weft_bridges.dart';

/// Serves a scripted sequence of step responses, one per request.
class _ScriptedBridge {
  _ScriptedBridge(this.responses);

  final List<Map<String, Object?>> responses;
  int calls = 0;
  final List<String> paths = [];
  final List<Object?> bodies = [];

  BridgeProvisioningClient get client => BridgeProvisioningClient(
    baseUrl: Uri.parse('https://bridge.example.org/_matrix/provision'),
    accessToken: 't',
    httpClient: MockClient((r) async {
      paths.add(r.url.path);
      bodies.add(r.body.isEmpty ? null : jsonDecode(r.body));
      // The last entry repeats, which models a bridge still waiting.
      final index = calls < responses.length ? calls : responses.length - 1;
      calls++;
      return http.Response(jsonEncode(responses[index]), 200);
    }),
  );
}

void main() {
  group('user input flow', () {
    test('collects input then completes', () async {
      final bridge = _ScriptedBridge([
        {
          'step_id': 'phone',
          'type': 'user_input',
          'login_id': 'lg1',
          'user_input': {
            'fields': [
              {'id': 'phone', 'type': 'phone_number', 'name': 'Phone'},
            ],
          },
        },
        {
          'step_id': 'done',
          'type': 'complete',
          'complete': {'login_id': 'lg1'},
        },
      ]);

      final session = BridgeLoginSession(
        client: bridge.client,
        flowId: 'phone',
      );
      addTearDown(session.dispose);

      await session.start();
      expect(session.status, BridgeLoginStatus.waitingForUser);
      expect(session.currentStep!.fields.single.name, 'Phone');

      await session.submitInput({'phone': '+4915112345678'});

      expect(session.status, BridgeLoginStatus.complete);
      expect(session.isComplete, isTrue);
      expect(session.loginId, 'lg1');
      expect(bridge.paths.last, contains('/login/step/lg1/phone/user_input'));
    });

    test('rejects invalid input locally, without a round trip', () async {
      final bridge = _ScriptedBridge([
        {
          'step_id': 'phone',
          'type': 'user_input',
          'login_id': 'lg1',
          'user_input': {
            'fields': [
              {
                'id': 'phone',
                'type': 'phone_number',
                'name': 'Phone',
                'pattern': r'^\+[0-9]{8,15}$',
              },
            ],
          },
        },
      ]);

      final session = BridgeLoginSession(
        client: bridge.client,
        flowId: 'phone',
      );
      addTearDown(session.dispose);

      await session.start();
      final callsAfterStart = bridge.calls;

      await session.submitInput({'phone': 'nonsense'});

      expect(session.status, BridgeLoginStatus.waitingForUser);
      expect(session.error, contains('Phone'));
      expect(
        bridge.calls,
        callsAfterStart,
        reason: 'a local validation failure must not hit the network',
      );
    });
  });

  group('display and wait', () {
    test('polls until the remote side responds, then completes', () async {
      final bridge = _ScriptedBridge([
        {
          'step_id': 'qr',
          'type': 'display_and_wait',
          'login_id': 'lg1',
          'display_and_wait': {'type': 'qr', 'data': 'code-1'},
        },
        {
          'step_id': 'qr',
          'type': 'display_and_wait',
          'display_and_wait': {'type': 'qr', 'data': 'code-1'},
        },
        {
          'step_id': 'done',
          'type': 'complete',
          'complete': {'login_id': 'lg1'},
        },
      ]);

      final session = BridgeLoginSession(
        client: bridge.client,
        flowId: 'qr',
        pollInterval: const Duration(milliseconds: 1),
      );
      addTearDown(session.dispose);

      await session.start();

      expect(session.isComplete, isTrue);
      expect(bridge.calls, greaterThan(1), reason: 'it should have polled');
    });

    test(
      'surfaces a refreshed QR payload rather than showing a stale code',
      () async {
        final bridge = _ScriptedBridge([
          {
            'step_id': 'qr',
            'type': 'display_and_wait',
            'login_id': 'lg1',
            'display_and_wait': {'type': 'qr', 'data': 'code-1'},
          },
          {
            'step_id': 'qr',
            'type': 'display_and_wait',
            'display_and_wait': {'type': 'qr', 'data': 'code-2'},
          },
          {
            'step_id': 'done',
            'type': 'complete',
            'complete': {'login_id': 'lg1'},
          },
        ]);

        final seen = <String>[];
        final session = BridgeLoginSession(
          client: bridge.client,
          flowId: 'qr',
          pollInterval: const Duration(milliseconds: 1),
        );
        addTearDown(session.dispose);
        session.updates.listen((s) {
          final data = s.currentStep?.displayData;
          if (data != null && !seen.contains(data)) seen.add(data);
        });

        await session.start();
        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(
          seen,
          containsAllInOrder(['code-1', 'code-2']),
          reason: 'an expired code must be replaced, not left on screen',
        );
      },
    );

    test('gives up rather than hanging forever on a dead code', () async {
      final bridge = _ScriptedBridge([
        {
          'step_id': 'qr',
          'type': 'display_and_wait',
          'login_id': 'lg1',
          'display_and_wait': {'type': 'qr', 'data': 'code-1'},
        },
      ]);

      final session = BridgeLoginSession(
        client: bridge.client,
        flowId: 'qr',
        pollInterval: const Duration(milliseconds: 1),
        maxWait: const Duration(milliseconds: 30),
      );
      addTearDown(session.dispose);

      await session.start();

      expect(session.status, BridgeLoginStatus.failed);
      expect(session.error, contains('expired'));
    });
  });

  group('failure handling', () {
    test('an unsupported step type explains the way out', () async {
      final bridge = _ScriptedBridge([
        {'step_id': 's', 'type': 'holographic_handshake'},
      ]);

      final session = BridgeLoginSession(client: bridge.client, flowId: 'x');
      addTearDown(session.dispose);

      await session.start();

      expect(session.status, BridgeLoginStatus.failed);
      // The route forward is the screen's to word; what the session owes it
      // is a reason it can tell apart from a bridge error.
      expect(
        session.problem,
        BridgeLoginProblem.unsupportedStep,
        reason: 'the user needs a route forward, not just an error',
      );
      expect(session.error, contains('holographic_handshake'));
    });

    test('a bridge error fails the session with its message', () async {
      final session = BridgeLoginSession(
        client: BridgeProvisioningClient(
          baseUrl: Uri.parse('https://bridge.example.org/_matrix/provision'),
          accessToken: 't',
          httpClient: MockClient(
            (_) async => http.Response(
              jsonEncode({'error': 'WhatsApp rejected the pairing'}),
              400,
            ),
          ),
        ),
        flowId: 'qr',
      );
      addTearDown(session.dispose);

      await session.start();

      expect(session.status, BridgeLoginStatus.failed);
      expect(session.error, 'WhatsApp rejected the pairing');
    });

    test('cancelling stops the session', () async {
      final bridge = _ScriptedBridge([
        {
          'step_id': 'phone',
          'type': 'user_input',
          'login_id': 'lg1',
          'user_input': {
            'fields': [
              {'id': 'phone', 'type': 'text', 'name': 'Phone'},
            ],
          },
        },
      ]);

      final session = BridgeLoginSession(client: bridge.client, flowId: 'p');
      addTearDown(session.dispose);

      await session.start();
      session.cancel();

      expect(session.status, BridgeLoginStatus.failed);
      expect(session.error, 'Cancelled');
    });
  });
}
