import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';
import 'package:weft/features/chat/chat_view.dart';
import 'package:weft/features/search/search_screen.dart';
import 'package:weft_domain/weft_domain.dart' show chatDeepLink;

import 'support/support.dart';

/// Links fired by the operating system, and where each of them lands.
///
///   ./tooling/scripts/e2e.sh --target integration_test/patrol/deeplink_test.dart
///
/// `apps/weft/test/intents_test.dart` already covers the *parsing* — twenty
/// tests over `WeftLink.parse`, nine of them link shapes, including the
/// percent-encoding trap a merged chat id walks straight into. None of that is
/// repeated here. What this file adds is the half a unit test cannot reach: an
/// `ACTION_VIEW` actually resolved by the system against the manifest's
/// `<data android:scheme="weft"/>` filter, delivered to `MainActivity`, pushed
/// across the `com.bostrot.weft/intents` channel, and turned into a route by
/// `main.dart:245-275`. Every link below is fired with
/// `platformAutomator.mobile.openUrl`, which is a real `Intent.ACTION_VIEW` with
/// `CATEGORY_BROWSABLE` started from the instrumentation's context
/// (`Automator.kt:139-146`) — from outside Weft, by the OS, exactly as a link in
/// another app would be.
///
/// ## Warm start only, and why there is no cold-start scenario
///
/// A Patrol test runs *inside the app under test*: `PatrolJUnitRunner.setUp`
/// launches the activity once, in `@Parameters`, and every Dart test then runs
/// in that process. Killing Weft to make the next link a cold start would kill
/// the Dart isolate the test is running on — the run does not fail, it
/// disappears. So the cold-start path is unreachable from here, on every row of
/// the matrix, and it is recorded as not-executed rather than approximated.
///
/// That path is not untested, only untested *here*: the Dart half of it is
/// `WeftIntents.deliverInitialIntent`, which is a `getInitialIntent` channel
/// call replaying the map `MainActivity.configureFlutterEngine` stashed
/// (`MainActivity.kt:41-44`), and the Kotlin half is one `intent?.let` on the
/// launching intent. What is genuinely uncovered is the join between them.
///
/// ## Two links that deliberately do not navigate
///
/// `weft://user/<id>` and the four telephony schemes both reach `_handleLink`
/// and both stop there: `main.dart:260-263` matches `OpenUserLink` and only
/// `debugPrint`s, because there is no start-chat flow to open, and
/// `ComposeSmsLink` pops to the inbox with the same note. The honest assertion
/// for those is delivery *without* a pushed route, and that is what the third
/// scenario makes. Turning it into a passing navigation assertion would mean
/// asserting a screen the app has never drawn.
void main() {
  patrolTest(
    'weft://chat/<id> fired by the OS opens that conversation',
    ($) async {
      if (!deepLinksAreReachable) {
        markTestSkipped(_unreachable);
        return;
      }

      final scenario = await ChatScenario.start($, title: 'Deep link chat');

      // Something to recognise the conversation by once it is open. Sent before
      // the link is fired so the wait afterwards is for the route, not for the
      // homeserver.
      final marker = await scenario.peerSays('in the linked conversation');
      await pumpUntil(
        $,
        () => showing(find.text(marker.body)),
        within: kSyncDeadline,
        reason: "the message to reach the app's inbox",
      );

      // The chat id *is* the room id for an unmerged conversation, and
      // `chatDeepLink` is the same one-line encoder `weft_notify` uses to build
      // a notification's tap target — so this is the exact string the app has
      // to be able to route, escapes and all. A room id is `!abc:localhost`, and
      // the colon is the character that makes a hand-written link fail.
      await fireLink($, chatDeepLink(scenario.room.id));

      await awaitBubble($, marker.body);
      expect(
        showing(composerField),
        isTrue,
        reason: 'a conversation that opened is one that can be replied to',
      );
    },
    config: kWeftPatrolConfig,
    timeout: kScenarioTimeout,
  );

  patrolTest(
    'weft://search?q= fired by the OS opens search on that query',
    ($) async {
      if (!deepLinksAreReachable) {
        markTestSkipped(_unreachable);
        return;
      }

      final scenario = await ChatScenario.start($, title: 'Deep link search');

      // A word no other run can have indexed, so a hit is this message.
      final needle = 'weftlink${DateTime.now().microsecondsSinceEpoch}';
      final body = uniqueBody('findable $needle');
      await scenario.bob.sendText(scenario.room.id, body);
      await scenario.bob.requireMessage(scenario.room.id, body);
      await pumpUntil(
        $,
        () => showing(find.text(body)),
        within: kSyncDeadline,
        reason: "the message to reach the app's inbox",
      );

      await fireLink($, 'weft://search?q=$needle');

      await pumpUntil(
        $,
        () => showing(find.byType(SearchScreen)),
        within: kUiDeadline,
        reason: 'the search screen',
      );
      expect(
        showing(find.text(needle)),
        isTrue,
        reason:
            'the query arrives as `SearchScreen.initialQuery` and is put into '
            'the field, which is the whole of what the link carries',
      );

      // And a route really was pushed rather than the field merely being
      // filled: the inbox is offstage behind it, which is what `showing`'s
      // default `skipOffstage` reports. What the results *are* is
      // `search_test`'s subject, not this one — the claim here is delivery, and
      // `SearchScreen.initState` runs the query from `initialQuery` on its own.
      expect(
        showing(inbox),
        isFalse,
        reason: 'the search screen is a route over the inbox, not beside it',
      );
    },
    config: kWeftPatrolConfig,
    timeout: kScenarioTimeout,
  );

  patrolTest(
    'weft://user/<id> is delivered and pushes nothing, which is the app today',
    ($) async {
      if (!deepLinksAreReachable) {
        markTestSkipped(_unreachable);
        return;
      }

      await ChatScenario.start($, title: 'Deep link user');
      expect(
        showing(inbox),
        isTrue,
        reason: 'the scenario starts on the inbox',
      );

      await fireLink($, 'weft://user/${matrixUserId(kPeerUser)}');

      // Nothing was pushed, and nothing crashed. `main.dart:260-263` matches
      // `OpenUserLink` and `debugPrint`s: there is no start-chat flow behind it,
      // and nothing in the app reads `Membership.invite` either, so a DM cannot
      // be opened or created from a link today. The inbox is where the app is
      // and where it stays.
      //
      // This is the assertion that will *fail* when the start-chat flow lands,
      // and that is the point of writing it this way rather than not writing it:
      // the day it fails is the day this scenario becomes a navigation
      // assertion.
      await pumpUntil(
        $,
        () => showing(inbox),
        within: kUiDeadline,
        reason: 'the app to still be on the inbox',
      );
      expect(
        showing(find.byType(ChatView)),
        isFalse,
        reason: 'no conversation should have been pushed by a user link',
      );
    },
    config: kWeftPatrolConfig,
    timeout: kScenarioTimeout,
  );

  patrolTest(
    'a link for a conversation this account is not in says so',
    ($) async {
      if (!deepLinksAreReachable) {
        markTestSkipped(_unreachable);
        return;
      }

      await ChatScenario.start($, title: 'Deep link stranger');

      // Links arrive from outside the app's control, which is the reason
      // `WeftLink.parse` is written not to throw — and the reason the route it
      // pushes has to survive an id that resolves to nothing. `ChatView` sets
      // `_unavailable` for a chat that is not in the inbox.
      await fireLink($, chatDeepLink('!nobody-is-in-this:$kServerName'));

      await pumpUntil(
        $,
        () => showing(find.text('That conversation is not in your inbox.')),
        within: kSyncDeadline,
        reason: 'the chat screen to report an unresolvable link',
      );
    },
    config: kWeftPatrolConfig,
    timeout: kScenarioTimeout,
  );
}

/// Whether the OS on this row can be asked to route a `weft://` link.
///
/// Android and iOS through the automator's `openUrl`, and macOS through `open`,
/// which is the one place the test process sharing the machine is an advantage:
/// the link goes out to Launch Services and comes back through the same handler
/// a link clicked in Mail would. Android and iOS resolve it against the
/// manifest's `weft` scheme filter and `Info.plist`'s `CFBundleURLSchemes`.
bool get deepLinksAreReachable =>
    defaultTargetPlatform == TargetPlatform.android ||
    defaultTargetPlatform == TargetPlatform.iOS ||
    defaultTargetPlatform == TargetPlatform.macOS;

const String _unreachable =
    'This platform has no way to fire an OS-routed link at Weft; see the '
    'applicability table in docs/quality/e2e-matrix.md.';

/// Fires [url] at the operating system and waits for Weft to have it.
///
/// Warm start throughout, for the reason in this file's header. The app is *not*
/// backgrounded first: `MainActivity` is `singleTop`, so a `VIEW` intent for a
/// task that is already foreground arrives at `onNewIntent` exactly as it does
/// for one that is behind the launcher — the same handler, the same channel
/// call, the same `_handleLink`. Backgrounding would add a window transition to
/// wait out and prove nothing extra.
///
/// The wait is deliberately not "the route appeared": each scenario asserts its
/// own landing, and one of them asserts that nothing was pushed at all.
Future<void> fireLink(PatrolIntegrationTester $, String url) async {
  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
    case TargetPlatform.iOS:
      await $.platformAutomator.mobile.openUrl(url);
    case TargetPlatform.macOS:
      // No automator on macOS, and none needed: `open` hands the URL to Launch
      // Services, which routes it to the registered handler — this process.
      final result = await Process.run('open', [url]);
      expect(
        result.exitCode,
        0,
        reason: 'macOS refused to open $url: ${result.stderr}',
      );
    case _:
      fail(_unreachable);
  }
  // Only on the platforms that have an automator to ask. On macOS Weft never
  // stopped being the foreground application — `open` hands the URL to the
  // process that is already running — and there is no window server query to
  // make anyway.
  if (defaultTargetPlatform != TargetPlatform.macOS) {
    await awaitWeftForeground($);
  }
  // One settle for the route the platform has just asked for. Not a wait for a
  // particular screen — that is each scenario's own assertion, including the one
  // whose assertion is that no screen changed.
  await $.pumpAndTrySettle();
}
