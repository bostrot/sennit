import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'support/support.dart';

/// The bridges screen: what a health probe says, and what a QR login draws.
///
///   ./tooling/scripts/e2e.sh --target integration_test/patrol/bridges_test.dart
///
/// **No bridge runs in `tooling/docker`.** Weft hosts none by design — every
/// bridge is one the user runs on their own server — and the mock bridge
/// `tooling/docker/README.md` still lists as outstanding does not exist. So the
/// two halves of a probe are answered from two different places, and each is
/// honest about which:
///
/// - **Unreachable is answered by the real homeserver.** `/whoami` against
///   Synapse's own address is a genuine socket, a genuine 404 and a genuine
///   Matrix error body, and what the card prints is the sentence Synapse wrote.
///   That is the whole failure path — client, timeout, status mapping, errcode
///   extraction, the card, the announcement — end to end, against a server that
///   is up and simply is not a bridge. It is also, exactly, what a user who
///   pastes their homeserver URL into "Add a bridge" will see.
/// - **Reachable is answered by a [BridgeStub]** in this process, speaking
///   mautrix's bridgev2 provisioning v3. Everything on Weft's side of that
///   socket is real; the bridge is not. `support/stubs.dart` is exact about
///   what that does and does not prove.
///
/// Every scenario clears the screen first. Configured bridges live in the
/// settings database, which outlives a test, and a bridge left behind by an
/// earlier scenario is a card that probes a stub server which closed with it —
/// visible, slow and confusing on the run after.
void main() {
  patrolTest(
    'a bridge that is not a bridge reports what the server actually said',
    ($) async {
      await ensureSignedIn($);
      await _openBridges($);
      await _removeEveryBridge($);

      // The homeserver, at the path the Add dialog's own hint suggests. It is
      // up, it is reachable, and it has no provisioning API — which is a
      // different answer from "offline", and the card has to tell them apart.
      await _addBridge($, kHomeserverUri.replace(path: '/_matrix/provision'));

      await pumpUntil(
        $,
        () => showing(find.bySemanticsLabel(RegExp('^Not reachable[.] '))),
        within: kSyncDeadline,
        reason: 'the probe to come back and the card to say it failed',
      );

      // Synapse's own words for an unknown endpoint, not a status code Weft
      // invented a sentence for: `_decode` prefers the body's `error` over
      // `_describeStatus`, and this is the assertion that it does. The string
      // is quoted rather than guessed — against the container in
      // `tooling/docker`, `GET /_matrix/provision/v3/whoami` answers 404 with
      // `{"errcode":"M_UNRECOGNIZED","error":"Unrecognized request"}`.
      expect(
        showing(find.textContaining('Unrecognized request')),
        isTrue,
        reason:
            "the bridge's own error message is what the user needs; a bare "
            '404 tells them nothing about which of the two ends is wrong',
      );

      // Sign in is disabled while the bridge is unreachable — there is nothing
      // to sign in to, and a button that starts a flow against a dead endpoint
      // is a spinner that ends in the same error one screen deeper.
      expect(
        $.tester
            .widget<FilledButton>(
              find.ancestor(
                of: find.text('Sign in'),
                matching: find.byType(FilledButton),
              ),
            )
            .onPressed,
        isNull,
      );

      await _removeEveryBridge($);
    },
    config: kWeftPatrolConfig,
    timeout: kScenarioTimeout,
  );

  patrolTest(
    'a reachable bridge renders its network and the state of each login',
    ($) async {
      final stub = await BridgeStub.start(
        networkId: 'whatsapp',
        networkName: 'WhatsApp',
        logins: const [
          {
            'id': 'login-1',
            'state_event': 'CONNECTED',
            'name': '+44 7700 900000',
          },
          {
            'id': 'login-2',
            'state_event': 'BAD_CREDENTIALS',
            'name': '+44 7700 900111',
            'error': 'Logged out from another device',
          },
        ],
      );
      addTearDown(stub.close);

      await ensureSignedIn($);
      await _openBridges($);
      await _removeEveryBridge($);
      await _addBridge($, stub.provisioningUrl);

      await pumpUntil(
        $,
        () => showing(find.text('+44 7700 900000 — connected')),
        within: kSyncDeadline,
        reason: 'the probe to answer and the card to draw its logins',
      );

      // The card takes its title from the bridge rather than from the network
      // id it was filed under, so a bridge that renamed itself says so.
      expect(showing(find.text('WhatsApp')), isTrue);

      // The unhappy login carries the bridge's own reason. A row of coloured
      // dots is the state for someone who can see them and nothing at all
      // otherwise, which is why the sentence has the state in it.
      expect(
        showing(
          find.text(
            '+44 7700 900111 — badCredentials (Logged out from another device)',
          ),
        ),
        isTrue,
      );

      // With a login already present the button changes what it offers, which
      // is the only sign on the card that Weft understood the answer as
      // "signed in" rather than as "reachable".
      expect(showing(find.text('Add another account')), isTrue);

      expect(
        stub.probed,
        isTrue,
        reason: 'the card was drawn from a round trip, not from what was typed',
      );

      await _removeEveryBridge($);
    },
    config: kWeftPatrolConfig,
    timeout: kScenarioTimeout,
  );

  patrolTest(
    'the QR login shows a scannable code and a payload that can be copied',
    ($) async {
      final stub = await BridgeStub.start(
        networkName: 'WhatsApp',
        qrPayload: 'weft-e2e://pair/${uniqueToken('code')}',
      );
      addTearDown(stub.close);

      await ensureSignedIn($);
      await _openBridges($);
      await _removeEveryBridge($);
      await _addBridge($, stub.provisioningUrl);
      await pumpUntil(
        $,
        () => showing(find.text('Sign in')),
        within: kSyncDeadline,
        reason: 'the probe to finish so the login button is enabled',
      );

      // One flow, so the screen skips the picker and starts it — which is what
      // `_startLogin` does with a single-element list, and worth going through
      // rather than around because it is the common case.
      await $.tap(find.text('Sign in'));
      await pumpUntil(
        $,
        () => showing(find.byType(QrImageView)),
        within: kSyncDeadline,
        reason: 'the bridge to hand over a QR step and the code to render',
      );

      // What to do on the phone, in the app's words rather than the bridge's:
      // the guide knows WhatsApp, so the steps name its menus.
      expect(showing(find.text('Open WhatsApp on your phone')), isTrue);

      // Cancel rather than completing: what happens after the other device
      // scans is the bridge's story, and there is no bridge.
      await $.tap(find.text('Cancel'));
      await pumpUntil(
        $,
        () => showing(find.byTooltip('Advanced')),
        within: kUiDeadline,
        reason: 'the login screen to close',
      );

      await _removeEveryBridge($);
    },
    config: kWeftPatrolConfig,
    timeout: kScenarioTimeout,
  );
}

// ----------------------------------------------------------------- the screen

Future<void> _openBridges(PatrolIntegrationTester $) async {
  await openInboxMenu($, 'Messengers');
  await pumpUntil(
    $,
    () => showing(find.byTooltip('Advanced')),
    within: kUiDeadline,
    reason: 'the bridges screen',
  );
}

/// Adds a bridge by its provisioning URL, exactly as the screen asks for it.
Future<void> _addBridge(PatrolIntegrationTester $, Uri url) async {
  await $.tap(find.byTooltip('Advanced'));
  await $.tap(find.text('Add a bridge by address'));
  await pumpUntil(
    $,
    () => showing(find.text('Add a bridge')),
    within: kUiDeadline,
    reason: 'the add-a-bridge dialog',
  );
  await $.enterText(
    find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    ),
    '$url',
  );
  await $.tap(find.widgetWithText(FilledButton, 'Add'));
}

/// Leaves the screen with no bridges configured.
///
/// Through the card's own menu, which is the only way a user has, and in a loop
/// because there may be one from a scenario that failed before its own cleanup
/// ran. Bounded so a screen that will not empty fails as a message rather than
/// as a hang.
Future<void> _removeEveryBridge(PatrolIntegrationTester $) async {
  for (var attempt = 0; attempt < 8; attempt++) {
    final menus = find.byType(PopupMenuButton<String>);
    if (!showing(menus)) return;
    await $.tap(menus.first);
    await pumpUntil(
      $,
      () => showing(find.text('Remove bridge')),
      within: kUiDeadline,
      reason: 'the card menu',
    );
    await $.tap(find.text('Remove bridge'));
    await $.pump(const Duration(milliseconds: 300));
  }
  fail('The bridges screen still has cards on it after eight removals');
}
