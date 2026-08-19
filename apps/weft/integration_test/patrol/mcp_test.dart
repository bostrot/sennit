import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:patrol/patrol.dart';

import 'support/support.dart';

/// The MCP server, started from settings and then actually called.
///
///   ./tooling/scripts/e2e.sh --target integration_test/patrol/mcp_test.dart
///
/// This is the one screen in Weft whose subject is a socket, and the only way to
/// test it is to open that socket and speak to it. The test process *is* the
/// app's process, so `127.0.0.1:<port>` from here is the same loopback the
/// server bound — which is the whole security claim of the feature
/// (`WeftMcpHttpServer.start` binds `InternetAddress.loopbackIPv4`, and the
/// tunnel is the only way in from outside).
///
/// **"Both appear in the audit view" is not true, and these scenarios say so
/// rather than working around it.** Auth is checked in the transport and the
/// audit log is written by the registry: `WeftMcpHttpServer.handler` returns 401
/// before `WeftToolRegistry.call` is ever reached, so a request with no key —
/// or with a revoked one — leaves no trace anywhere in the app. What *is*
/// recorded as a denial is a call from a key the server recognises and then
/// refuses: wrong scope, unknown tool, rate limited. That is the "Recent
/// activity" list's red half, and it is what the second scenario produces.
///
/// The gap matters beyond a test. The screen's own copy says every call "is
/// scope-checked, rate-limited and logged", and the audit log's doc comment
/// calls itself what "the user checks after a key leaks" — but the one thing a
/// leak looks like from outside, somebody trying keys that do not work, is
/// exactly what it cannot show. Recorded, not fixed: it is a change to the
/// server's auth path rather than to its tests.
void main() {
  patrolTest(
    'the server answers a key it knows, refuses one it does not, and logs one',
    ($) async {
      await ensureSignedIn($);
      await _openMcpScreen($);

      final key = await _createKey($, label: uniqueToken('reader'));
      final port = await _startServer($);

      // The tunnel is off and Weft has not tried to start it — `start()` only
      // reaches `CloudflaredSupervisor` when the setting says so, and it does
      // not by default. Asserted rather than assumed because the row *is* drawn
      // on every platform, with an enabled Start button, including the ones
      // where `Process.start('cloudflared', …)` cannot work at all: iOS forbids
      // spawning a subprocess and Android has no such binary. Offering it there
      // is a product question, and skip reason ⑦ in the matrix now says so.
      expect(
        showing(find.text('Off. Requires cloudflared on this machine.')),
        isTrue,
      );

      final answered = await _call(port, token: key, tool: 'list_chats');
      expect(answered.statusCode, 200);
      final result = (jsonDecode(answered.body) as Map)['result'];
      expect(
        result,
        isA<Map>().having((r) => r['isError'], 'isError', isFalse),
        reason: 'a scoped key calling a tool it holds gets an answer',
      );
      expect(
        (result! as Map)['content'],
        isA<List>(),
        reason: 'MCP answers with content blocks, whatever the tool returned',
      );

      final refused = await _call(port, token: null, tool: 'list_chats');
      expect(refused.statusCode, 401);
      expect(
        refused.headers['www-authenticate'],
        'Bearer',
        reason: 'a 401 has to say how to authenticate',
      );

      // Re-entered rather than pumped: the screen reads the audit log in
      // `build` and nothing tells it a request arrived, so a user checking what
      // an agent did comes back to the screen — which is what this does.
      await _reopenMcpScreen($);

      expect(
        showing(find.textContaining('ok list_chats')),
        isTrue,
        reason: 'the answered call is in Recent activity',
      );
      expect(
        _auditLines($),
        1,
        reason:
            'the unauthenticated request is *not* logged: 401 is returned by '
            'the transport, and only the registry writes audit entries. See '
            "this file's header — it is a real gap, asserted rather than "
            'wished away',
      );

      await _stopServer($);
    },
    config: kWeftPatrolConfig,
    timeout: kScenarioTimeout,
  );

  patrolTest(
    'a key is refused by scope, logged as denied, and dead once revoked',
    ($) async {
      await ensureSignedIn($);
      await _openMcpScreen($);

      final label = uniqueToken('reader');
      final key = await _createKey($, label: label);
      final port = await _startServer($);

      // `send_message` needs the send scope; the key has read. The refusal is a
      // *result* with `isError`, not a protocol error, because that is what the
      // MCP spec asks for — the model has to be able to read the reason and try
      // something else.
      final refused = await _call(
        port,
        token: key,
        tool: 'send_message',
        arguments: const {'chat_id': 'nowhere', 'body': 'hello'},
      );
      expect(refused.statusCode, 200);
      final result = (jsonDecode(refused.body) as Map)['result'] as Map;
      expect(result['isError'], isTrue);
      expect(
        '${(result['content'] as List).first}',
        contains('send'),
        reason: 'the refusal names the scope the key is missing',
      );

      await _reopenMcpScreen($);
      expect(
        showing(find.textContaining('DENIED send_message')),
        isTrue,
        reason:
            'a key the server recognised and then refused is the denial the '
            'audit view exists to show',
      );

      // Revoking is a settings write, and the server re-reads the key ring per
      // request precisely so it takes effect without a restart.
      await $.tap(find.bySemanticsLabel('Revoke the key named $label'));
      await pumpUntil(
        $,
        () => !showing(find.text(label)),
        within: kUiDeadline,
        reason: 'the revoked key to leave the list',
      );

      final afterRevoke = await _call(port, token: key, tool: 'list_chats');
      expect(
        afterRevoke.statusCode,
        401,
        reason:
            'a revoked key stops working on the next request, not on the '
            'next restart',
      );

      await _stopServer($);
    },
    config: kWeftPatrolConfig,
    timeout: kScenarioTimeout,
  );
}

// ----------------------------------------------------------------- the screen

Future<void> _openMcpScreen(PatrolIntegrationTester $) async {
  await openInboxMenu($, 'MCP server');
  await pumpUntil(
    $,
    () => showing(find.text('Run the MCP server')),
    within: kUiDeadline,
    reason: 'the MCP screen',
  );
}

Future<void> _reopenMcpScreen(PatrolIntegrationTester $) async {
  await leaveSettingsScreen($);
  await _openMcpScreen($);
}

/// Mints a key through the dialog and returns the secret.
///
/// The secret is read off the screen because that is the only place it exists:
/// Weft stores a salted hash and the dialog says so — "this is the only time the
/// key is shown". A test that could get it any other way would be testing
/// something Weft does not do.
///
/// Scopes are left at the dialog's default of `read`, which is also what makes
/// the second scenario's refusal meaningful.
Future<String> _createKey(
  PatrolIntegrationTester $, {
  required String label,
}) async {
  await $.tap(find.text('New key'));
  await pumpUntil(
    $,
    () => showing(find.text('New API key')),
    within: kUiDeadline,
    reason: 'the new-key dialog',
  );
  await $.enterText(
    find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    ),
    label,
  );
  await $.tap(find.widgetWithText(FilledButton, 'Create'));

  await pumpUntil(
    $,
    () => showing(find.text('Copy this key now')),
    within: kUiDeadline,
    reason: 'the one and only showing of the key',
  );
  final secret = $.tester
      .widget<SelectableText>(find.byType(SelectableText))
      .data!;

  await $.tap(find.widgetWithText(FilledButton, 'Done'));
  await pumpUntil(
    $,
    () => showing(find.text(label)),
    within: kUiDeadline,
    reason: 'the new key to appear in the list',
  );
  return secret;
}

/// Turns the server on and reads the port off the screen.
///
/// The port is the screen's own report of it — `boundPort`, printed in the
/// subtitle — rather than anything the test chose. The setting defaults to zero
/// so the OS picks, and the bound port is written back into settings, which is
/// worth knowing about: a second run reuses the *previous* run's ephemeral port
/// and `start()` throws if something else has taken it in the meantime. Each
/// scenario therefore stops the server it started.
Future<int> _startServer(PatrolIntegrationTester $) async {
  await $.tap(find.text('Run the MCP server'));
  await pumpUntil(
    $,
    () => showing(find.textContaining('Listening on 127.0.0.1:')),
    within: kUiDeadline,
    reason: 'the server to bind and say where',
  );

  final subtitle = $.tester
      .widget<Text>(find.textContaining('Listening on 127.0.0.1:').first)
      .data!;
  final port = RegExp(r'127\.0\.0\.1:(\d+)').firstMatch(subtitle)?.group(1);
  if (port == null) fail('Could not read a port out of "$subtitle"');
  return int.parse(port);
}

Future<void> _stopServer(PatrolIntegrationTester $) async {
  await $.tap(find.text('Run the MCP server'));
  await pumpUntil(
    $,
    () => showing(find.text('Stopped')),
    within: kUiDeadline,
    reason: 'the server to release the port',
  );
}

/// How many lines the audit view is currently showing.
///
/// Every entry is `McpAuditEntry.toString()`, which begins with a bracketed
/// timestamp — the one shape on this screen that nothing else has.
int _auditLines(PatrolIntegrationTester $) => find
    .byWidgetPredicate(
      (widget) => widget is Text && (widget.data ?? '').startsWith('['),
    )
    .evaluate()
    .length;

// ------------------------------------------------------------------ the wire

/// One `tools/call`, as an MCP client makes it.
///
/// Streamable HTTP with no SSE: a POST of JSON-RPC, which is the whole transport
/// Weft offers and is enough for an agent. [token] null omits the header
/// entirely, which is the unauthenticated case rather than a malformed one.
Future<http.Response> _call(
  int port, {
  required String? token,
  required String tool,
  Map<String, Object?> arguments = const {},
}) {
  return http.post(
    Uri.parse('http://127.0.0.1:$port/'),
    headers: {
      'content-type': 'application/json',
      if (token != null) 'authorization': 'Bearer $token',
    },
    body: jsonEncode({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'tools/call',
      'params': {'name': tool, 'arguments': arguments},
    }),
  );
}
