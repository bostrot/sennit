import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';

import 'support/support.dart';

/// Finding a message again: by its words, by its meaning, and by words that were
/// never typed at all because they were spoken.
///
///   ./tooling/scripts/e2e.sh --target integration_test/patrol/search_test.dart
///
/// Three things about Weft's search decide what these scenarios can be, and all
/// three are read out of the app rather than assumed:
///
/// 1. **Nothing is indexed until its conversation is opened.** The index is
///    written by `ChatView._indexNewMessages`, off a post-frame callback, and
///    by nothing else — the empty search screen says so in as many words
///    ("Messages become searchable as their chats are opened"). The first
///    scenario asserts the *before* as well as the after, because a search that
///    finds a never-opened chat would mean something else is writing the index.
/// 2. **Embedding follows indexing on its own.** `EmbeddingBackfill` starts
///    with the session and drains a couple of seconds after anything is
///    indexed, so the semantic scenario presses nothing: it waits for the stub
///    to be called, which is also all a user does.
/// 3. **A `uniqueBody` is not searchable.** `toFtsMatchQuery` strips `-` out of
///    every query token while FTS5 tokenised the indexed body *on* it, so the
///    literal string a test just sent comes back with nothing. Every marker here
///    is a [uniqueToken] — one word, letters and digits — for that reason.
///
/// The transcription and embedding endpoints are [LocalStubServer]s in this
/// process. Weft hosts neither and `tooling/docker` runs neither; what is being
/// asserted is the app's whole path to and from one, not the quality of the
/// answer it gets. `support/stubs.dart` is exact about the difference.
void main() {
  patrolTest(
    'a message becomes findable once its conversation has been opened',
    ($) async {
      final scenario = await ChatScenario.start($, title: 'Search');
      // Keyword only, said rather than assumed. The settings database outlives
      // a scenario, and with an embedding endpoint left configured by the third
      // scenario a flat kNN returns the whole index — see the note on that
      // scenario — which would make "1 result" a claim about run order.
      await _configureEndpoints($);

      final needle = uniqueToken('needle');
      await scenario.bob.sendText(
        scenario.room.id,
        'the survey came back $needle and it is fine',
      );

      // Before: the message is on the homeserver and in the app's sync, and the
      // index has never heard of it.
      await _openSearch($);
      await _query($, needle);
      await _awaitSummary($, 'Nothing matched.');
      await _leaveSearch($);

      // Opening the conversation is what indexes it.
      await openChat($, scenario.room.title);
      await awaitBubble($, 'the survey came back $needle and it is fine');
      await $.tap(find.byTooltip('Back'));

      await _openSearch($);
      await _query($, needle);
      await _awaitSummary($, '1 result');
      expect(
        showing(find.textContaining(needle)),
        isTrue,
        reason: 'the result shows the message it found',
      );

      // Tapping a result opens the conversation it came from, at that message.
      await $.tap(find.textContaining(needle).first);
      await pumpUntil(
        $,
        () => showing(composerField),
        within: kUiDeadline,
        reason: 'the conversation the result belongs to',
      );
      await awaitBubble($, 'the survey came back $needle and it is fine');
    },
    config: kWeftPatrolConfig,
    timeout: kScenarioTimeout,
  );

  patrolTest(
    'a voice message is findable by words that were only ever spoken',
    ($) async {
      final spoken = uniqueToken('portcullis');
      final stub = await TranscriptionStub.start(
        transcript: 'we should meet by the $spoken at six',
      );
      addTearDown(stub.close);

      final scenario = await ChatScenario.start($, title: 'Voice search');
      await _configureEndpoints($, transcription: stub.baseUrl);

      await scenario.bob.sendVoiceNote(scenario.room.id);
      await openChat($, scenario.room.title);

      // The affordance is in the bubble, not in the actions sheet: an
      // untranscribed voice message draws its own Transcribe button
      // (`attachment_bubble.dart:610-630`), which is the shorter road and the
      // one a user takes.
      await pumpUntil(
        $,
        () => showing(find.text('Transcribe')),
        within: kSyncDeadline,
        reason: 'the voice message and its Transcribe button',
      );
      await $.tap(find.text('Transcribe'));

      await pumpUntil(
        $,
        () => showing(find.text(stub.transcript)),
        within: kSyncDeadline,
        reason: 'the transcript to be drawn under the waveform',
      );
      expect(
        stub.transcribed,
        1,
        reason:
            'the transcript has to have come off the wire; a cached or invented '
            'one would draw identically',
      );
      expect(
        stub.lastUpload,
        contains('voice.ogg'),
        reason: 'the clip itself was uploaded, filename and all',
      );

      await $.tap(find.byTooltip('Back'));
      await _openSearch($);
      await _query($, spoken);
      await _awaitSummary($, '1 result');
      expect(
        showing(find.textContaining(stub.transcript)),
        isTrue,
        reason:
            'the spoken words are in the index — `plainTextOf` appends the '
            'transcript to the body, which is the column FTS5 reads',
      );
    },
    config: kWeftPatrolConfig,
    timeout: kScenarioTimeout,
  );

  patrolTest(
    'semantic search returns a message containing none of the typed words',
    ($) async {
      final marker = uniqueToken('slate');
      final stub = await EmbeddingStub.start(
        concepts: const [
          ['roof', 'roofing', 'shingles', 'gutters'],
        ],
      );
      addTearDown(stub.close);

      // The premise, stated rather than hoped for: to this endpoint the message
      // and the query are the same point. Everything the scenario then asserts
      // is about what Weft does with that, not about whether it is true.
      expect(
        stub.vectorFor('the shingles need replacing $marker'),
        stub.vectorFor('roofing'),
        reason: 'the stub has to agree these two mean the same thing',
      );

      final scenario = await ChatScenario.start($, title: 'Semantic search');
      await _configureEndpoints($, embedding: stub.baseUrl);

      await scenario.bob.sendText(
        scenario.room.id,
        'the shingles need replacing $marker',
      );
      await openChat($, scenario.room.title);
      await awaitBubble($, 'the shingles need replacing $marker');
      await $.tap(find.byTooltip('Back'));

      // Nothing pressed: opening the chat indexed the message, and indexing is
      // what wakes the backfill.
      await pumpUntil(
        $,
        () => stub.embedded > 0,
        within: kSyncDeadline,
        reason: 'the backfill to reach the embedding endpoint by itself',
      );
      await _openSearch($);

      // Not one word in common with the message.
      //
      // Presence rather than a count, and the reason is a property of the
      // engine rather than of this scenario: `FlatVectorIndex` scores every
      // stored vector and returns the best `candidateDepth` of them with no
      // similarity floor, so a semantic query answers with as much of the index
      // as fits in `SearchQuery.limit` — orthogonal rows included, at a
      // similarity of exactly zero, each labelled "meaning". Asserting "1
      // result" here would be asserting that the index is empty apart from this
      // scenario.
      await _query($, 'roofing');
      await pumpUntil(
        $,
        () => showing(find.textContaining(marker)),
        within: kSyncDeadline,
        reason: 'the semantically matching message to be returned',
      );
      expect(
        showing(find.text('meaning')),
        isTrue,
        reason:
            'a hit that contains none of the typed words has to say so, or it '
            'reads as a bug rather than as the feature',
      );
    },
    config: kWeftPatrolConfig,
    timeout: kScenarioTimeout,
  );
}

// ----------------------------------------------------------------- the screen

/// Opens search from the inbox's own search box.
///
/// It looks like a text field and is not one — an `InputDecorator` with nothing
/// in it, deliberately, so a screen reader is not told to type somewhere that
/// cannot take typing. It is a button, found here by the name it carries for
/// that reason.
Future<void> _openSearch(PatrolIntegrationTester $) async {
  await $.tap(find.bySemanticsLabel('Search all conversations').first);
  await pumpUntil(
    $,
    () => showing(find.text('Search messages…')),
    within: kUiDeadline,
    reason: 'the search screen',
  );
}

Future<void> _leaveSearch(PatrolIntegrationTester $) async {
  await $.tap(find.byTooltip('Back'));
  await pumpUntil(
    $,
    () => showing(inbox),
    within: kUiDeadline,
    reason: 'the inbox after leaving search',
  );
}

/// Types a query and lets the debounce expire.
///
/// The field debounces at 250 ms so that a keystroke does not hit FTS5 and, on a
/// configured install, a metered embedding endpoint. Pumping past it is what
/// makes the query actually run.
Future<void> _query(PatrolIntegrationTester $, String text) async {
  await $.enterText(find.byType(TextField).last, text);
  await $.pump(const Duration(milliseconds: 600));
}

/// Waits for the result count, which is the screen's own answer to every query.
///
/// A live region, and the only thing on screen when nothing matched — the list
/// deliberately draws nothing then, so this is the assertion for the empty case
/// as well as the full one.
Future<void> _awaitSummary(PatrolIntegrationTester $, String summary) =>
    pumpUntil(
      $,
      () => showing(find.text(summary)),
      within: kSyncDeadline,
      reason: 'the search to report "$summary"',
    );

// -------------------------------------------------------------- the endpoints

/// Points Weft's transcription and embedding endpoints somewhere, through the
/// screen a user would use.
///
/// Both switches are set every time, and both *before* either section is
/// filled in. The settings database outlives a scenario and the two sections
/// have identically labelled fields, so a screen with both expanded is a screen
/// where `find.widgetWithText(TextField, 'Base URL')` matches twice and the
/// second scenario silently configures the first one's endpoint. Setting the
/// switches first means at most one section is open when anything is typed.
///
/// Null for either means off, which is also how a scenario undoes what the one
/// before it did — and calling this with neither is a scenario stating that it
/// wants keyword search and no transcription.
Future<void> _configureEndpoints(
  PatrolIntegrationTester $, {
  Uri? transcription,
  Uri? embedding,
}) async {
  assert(
    transcription == null || embedding == null,
    'the two sections have identically labelled fields; open one at a time',
  );

  await openInboxMenu($, 'Search & transcription');
  await pumpUntil(
    $,
    () => showing(find.text('Endpoints')),
    within: kUiDeadline,
    reason: 'the endpoints screen',
  );

  await _setSwitch($, 'Enable embeddings', on: embedding != null);
  await _setSwitch($, 'Enable transcription', on: transcription != null);

  if (embedding != null) {
    await _fill($, 'Base URL', '$embedding');
    await _fill($, 'Model', 'weft-e2e-concepts');
    // Eight, because the stub emits eight. A provider handed a vector of the
    // wrong length refuses the whole batch rather than storing coordinates that
    // cannot be compared with each other.
    await _fill($, 'Dimensions', '8');
  }
  if (transcription != null) {
    await _fill($, 'Base URL', '$transcription');
    await _fill($, 'Model', 'whisper-1');
  }

  // Save writes the settings, bumps the revision — which is what rebuilds the
  // providers holding the old configuration — and pops.
  await $.tap(find.text('Save'));
  await pumpUntil(
    $,
    () => showing(inbox),
    within: kUiDeadline,
    reason: 'the endpoints screen to save and close',
  );
}

Future<void> _setSwitch(
  PatrolIntegrationTester $,
  String title, {
  required bool on,
}) async {
  final row = find.widgetWithText(SwitchListTile, title);
  await pumpUntil(
    $,
    () => showing(row),
    within: kUiDeadline,
    reason: 'the "$title" switch',
  );
  if (($.tester.widget(row.first) as SwitchListTile).value == on) return;
  await $.tap(find.text(title));
  await pumpUntil(
    $,
    () => ($.tester.widget(row.first) as SwitchListTile).value == on,
    within: kUiDeadline,
    reason: 'the "$title" switch to read $on',
  );
}

Future<void> _fill(
  PatrolIntegrationTester $,
  String label,
  String value,
) async {
  final field = find.widgetWithText(TextField, label);
  await pumpUntil(
    $,
    () => showing(field),
    within: kUiDeadline,
    reason: 'the "$label" field',
  );
  await $.enterText(field.first, value);
}
