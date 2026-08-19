import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';

import 'support/support.dart';

/// Two conversations with one person, folded into one and taken apart again.
///
///   ./tooling/scripts/e2e.sh --target integration_test/patrol/merge_test.dart
///
/// Merging is the feature Weft is named for and the one with the worst failure
/// mode: a wrong merge silently mixes two people's conversations, and nobody
/// reads a thread wondering whether half of it is from someone else. So the
/// screen never merges anything on its own — it proposes, with its evidence
/// written out — and every scenario here goes through that proposal rather than
/// through `mergeHandles`.
///
/// **What produces a suggestion on a bare Synapse.** `MergeScorer` has six
/// signals and five of them need a bridge: a phone number in a ghost's
/// localpart, an email, an avatar hash that has been fetched, shared groups. On
/// a homeserver with no bridges the only one available is the name, which is
/// exactly the situation `MergeSignal.nameExact` is weighted at 0.62 for
/// (`merge_scorer.dart:14-23`) — one point above the 0.55 bar, on purpose,
/// because otherwise suggestions were mathematically impossible. Each scenario
/// therefore makes two peers who share a display name, which is a real bridged
/// contact's situation reproduced with the one signal this homeserver can carry.
///
/// **Why the peers are registered rather than seeded.** A decision is recorded
/// against a pair of handle ids, a Matrix handle's id is the peer's user id, and
/// the identity store outlives the app. Reusing `@bob` and `@carol` would mean
/// the unmerge scenario poisons the suggestion scenario on the next run of the
/// file — see [TestAccount.freshPeer].
void main() {
  patrolTest(
    'a suggestion names both handles and shows the evidence behind it',
    ($) async {
      final world = await _MergeWorld.start($);
      await _openMergeScreen($);
      await world.awaitSuggestion($);

      // The evidence, verbatim from the scorer. It is a chip on the card rather
      // than a tooltip precisely so that this is assertable at all.
      expect(
        showing(
          find.descendant(
            of: world.suggestionCard,
            matching: find.text('Identical name'),
          ),
        ),
        isTrue,
        reason:
            'the card has to say why it thinks these two are the same person; '
            'a suggestion the user cannot understand is one they will not trust',
      );

      // Both handles, named, on the same card — and named in the *buttons*,
      // which is the half a screen reader gets. Four suggestions with four
      // buttons reading "Merge" are four ways to merge the wrong two people.
      expect(
        find
            .descendant(
              of: world.suggestionCard,
              matching: find.text(world.sharedName),
            )
            .evaluate()
            .length,
        2,
        reason: 'a proposal is about two handles and shows both',
      );
      expect(
        showing(
          find.bySemanticsLabel(
            'Merge ${world.sharedName} on Matrix with ${world.sharedName} on '
            'Matrix into one conversation',
          ),
        ),
        isTrue,
      );

      // 62% is `nameExact`'s weight, unmixed with anything else: the noisy-OR
      // of one signal is that signal. A different number here means another
      // signal fired, which on this homeserver would be news.
      expect(
        showing(
          find.descendant(of: world.suggestionCard, matching: find.text('62%')),
        ),
        isTrue,
        reason: 'the confidence is shown, and one name signal is 62%',
      );
    },
    config: kWeftPatrolConfig,
    timeout: kScenarioTimeout,
  );

  patrolTest(
    'accepting a suggestion collapses both chats into one ordered thread',
    ($) async {
      final world = await _MergeWorld.start($);

      // Two rows before, so "one row after" is a change rather than a state.
      await _awaitInboxRow($, world.first.room.title);
      await _awaitInboxRow($, world.second.room.title);

      await _openMergeScreen($);
      await world.awaitSuggestion($);
      await world.acceptSuggestion($);
      await leaveSettingsScreen($);

      await pumpUntil(
        $,
        () =>
            showing(find.text(world.sharedName)) &&
            !showing(find.text(world.first.room.title)) &&
            !showing(find.text(world.second.room.title)),
        within: kSyncDeadline,
        reason:
            'the two source conversations to be replaced by one row named '
            'after the contact',
      );

      await openChat($, world.sharedName);
      await awaitBubble($, world.first.body);
      await awaitBubble($, world.second.body);

      // The watermark invariant of `MergedTimeline`, seen from outside: the
      // legs interleave by timestamp rather than concatenating. The chat list is
      // `reverse: true` over a newest-first model, so older is drawn higher —
      // and the first message was sent first.
      expect(
        $.tester.getTopLeft(bubbleFor(world.first.body).first).dy,
        lessThan($.tester.getTopLeft(bubbleFor(world.second.body).first).dy),
        reason:
            'a merged thread is one conversation in time order, not one leg '
            'after the other',
      );
    },
    config: kWeftPatrolConfig,
    timeout: kScenarioTimeout,
  );

  patrolTest(
    'unmerging gives both conversations back',
    ($) async {
      final world = await _MergeWorld.start($);
      await _openMergeScreen($);
      await world.awaitSuggestion($);
      await world.acceptSuggestion($);

      // The Merged section is the same screen, further down: the card that
      // appears there is the proof the accept landed, and the row inside it is
      // what undoes it. One button per leg, each naming its own leg, because a
      // contact with three of them otherwise offers three buttons reading
      // "Unmerge".
      final unmerge = find.bySemanticsLabel(
        'Unmerge ${world.sharedName} on Matrix from ${world.sharedName}',
      );
      await pumpUntil(
        $,
        () => showing(unmerge),
        within: kUiDeadline,
        reason: 'the merged contact to appear in the Merged section',
      );
      await $.tap(unmerge.first);
      await leaveSettingsScreen($);

      await pumpUntil(
        $,
        () =>
            showing(find.text(world.first.room.title)) &&
            showing(find.text(world.second.room.title)) &&
            !showing(find.text(world.sharedName)),
        within: kSyncDeadline,
        reason: 'both source conversations to come back as their own rows',
      );
    },
    config: kWeftPatrolConfig,
    timeout: kScenarioTimeout,
  );

  patrolTest(
    '"Not the same person" retires a suggestion for good',
    ($) async {
      final world = await _MergeWorld.start($);
      await _openMergeScreen($);
      await world.awaitSuggestion($);

      await $.tap(
        find.bySemanticsLabel(
          'Not the same person: keep ${world.sharedName} on Matrix and '
          '${world.sharedName} on Matrix separate',
        ),
      );
      await pumpUntil(
        $,
        () => !showing(find.text(world.sharedName)),
        within: kUiDeadline,
        reason: 'the dismissed suggestion to leave the screen',
      );

      // Sticky is the whole claim. A dismissal that the scorer forgets on its
      // next pass is a dismissal that did nothing, and the next pass is one
      // sync away — so the screen is left and re-entered, which rebuilds the
      // suggestions from the graph rather than from this screen's state.
      await leaveSettingsScreen($);
      await _openMergeScreen($);
      await pumpUntil(
        $,
        () => showing(find.text('Suggestions')),
        within: kUiDeadline,
        reason: 'the merge screen again',
      );
      await $.pump(const Duration(seconds: 2));
      expect(
        showing(find.text(world.sharedName)),
        isFalse,
        reason: 'a rejected pair must not be proposed again',
      );
    },
    config: kWeftPatrolConfig,
    timeout: kScenarioTimeout,
  );
}

// ------------------------------------------------------------------ the world

/// One peer, its conversation with the app, and the message in it.
typedef _Leg = ({TestAccount peer, TestRoom room, String body});

/// The app signed in, and two conversations that ought to be one.
///
/// Not [ChatScenario]: that makes one peer and one room, and every question
/// here is about the second. The order is the same and load-bearing for the same
/// reason — the app signs in before either room exists, so its device keys are
/// published before anything is encrypted to them.
class _MergeWorld {
  _MergeWorld._(this.sharedName, this.first, this.second);

  static Future<_MergeWorld> start(PatrolIntegrationTester $) async {
    final control = await TestAccount.control();
    addTearDown(control.dispose);
    await ensureSignedIn($);

    // Two words, because a bare first name is far too common to be evidence and
    // the scorer says so (`merge_scorer.dart:141-144`). Unique per run, because
    // the homeserver is shared across a matrix and this string is how the
    // merged conversation is found in an inbox.
    final sharedName = 'Robin ${uniqueToken('Mergefield')}';

    final first = await _leg(control, sharedName, 'Merge A');
    final second = await _leg(control, sharedName, 'Merge B');
    return _MergeWorld._(sharedName, first, second);
  }

  static Future<_Leg> _leg(
    TestAccount control,
    String sharedName,
    String title,
  ) async {
    final peer = await TestAccount.freshPeer('merge');
    addTearDown(peer.dispose);
    // Before the join, so the member event carries it — see [setDisplayName].
    await peer.setDisplayName(sharedName);

    final room = await createJoinedRoom(
      creator: control,
      peer: peer,
      title: title,
    );
    addTearDown(room.dispose);

    // The peer speaks, for two reasons that both matter. The obvious one is
    // that a merged thread needs something in each leg to interleave. The other
    // is lazy-loaded members: a room syncs without its member list, and a handle
    // whose `calcDisplayname()` falls back to the localpart is a handle with a
    // one-word name, which the scorer will not treat as evidence at all. A
    // message from the peer is what puts its member event in the sync.
    final body = uniqueBody('from $title');
    await peer.sendText(room.id, body);
    await peer.requireMessage(room.id, body);

    return (peer: peer, room: room, body: body);
  }

  /// What both handles call themselves, and therefore what the merged
  /// conversation is titled: `IdentityGraph._bestName` takes the longest name
  /// among a contact's handles, and these two are the same string.
  final String sharedName;

  final _Leg first;
  final _Leg second;

  /// The proposal card for *this* scenario's pair.
  ///
  /// Scoped to the name rather than taken as "the only card on screen". The
  /// identity store keeps handles from earlier scenarios whose rooms are long
  /// forgotten, and two of those can still score against each other — so the
  /// screen may legitimately be showing proposals this scenario knows nothing
  /// about, and a test that counted cards would fail on the second run for a
  /// reason that is not a bug.
  Finder get suggestionCard => find
      .ancestor(of: find.text(sharedName), matching: find.byType(Card))
      .first;

  Future<void> awaitSuggestion(PatrolIntegrationTester $) => pumpUntil(
    $,
    () => showing(find.text(sharedName)),
    within: kSyncDeadline,
    reason:
        'the merge suggestion for "$sharedName" — which needs both rooms, both '
        'member events and both display names to have reached the app',
  );

  Future<void> acceptSuggestion(PatrolIntegrationTester $) async {
    await $.tap(
      find.bySemanticsLabel(
        'Merge $sharedName on Matrix with $sharedName on Matrix into one '
        'conversation',
      ),
    );
    await pumpUntil(
      $,
      () => showing(
        find.bySemanticsLabel(
          RegExp('^Unmerge ${RegExp.escape(sharedName)} on Matrix from'),
        ),
      ),
      within: kSyncDeadline,
      reason: 'the accepted pair to move into the Merged section',
    );
  }
}

// ----------------------------------------------------------------- the screen

Future<void> _openMergeScreen(PatrolIntegrationTester $) async {
  await openInboxMenu($, 'Merged chats');
  await pumpUntil(
    $,
    () => showing(find.text('Merged chats')),
    within: kUiDeadline,
    reason: 'the merge screen',
  );
}

Future<void> _awaitInboxRow(PatrolIntegrationTester $, String title) =>
    pumpUntil(
      $,
      () => showing(find.text(title)),
      within: kSyncDeadline,
      reason: 'the conversation "$title" to reach the inbox',
    );
