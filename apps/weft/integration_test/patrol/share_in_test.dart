import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart' as sdk;
import 'package:patrol/patrol.dart';

import 'support/support.dart';

/// Sharing *into* Weft: an `ACTION_SEND` routed by the OS, the share-target
/// sheet, a conversation chosen, and the file on the peer's timeline.
///
///   ./tooling/scripts/e2e.sh --target integration_test/patrol/share_in_test.dart
///
/// **Android rows only.** The iOS Share Extension is not built — the repository
/// README's status table says so, and ADR-002 holds the App Group and bundle
/// ids it needs — so there is no `ACTION_SEND` on iOS and nothing here for a
/// test to fire. macOS has no share target either. See the applicability table
/// in `docs/quality/e2e-matrix.md`.
///
/// ## Who fires the intent, and why it is Weft
///
/// A test process running *on the device* cannot start an arbitrary activity.
/// `am start` wants a shell this binary does not have, and Patrol's automator
/// exposes `openUrl`, which is `ACTION_VIEW`. What it can do is ask the platform
/// to begin a share — the same `SharePlus` call `PlatformMediaExporter.share`
/// makes when the viewer's Share button is tapped — and then choose Weft out of
/// the system chooser with the native automator.
///
/// So the originating application is Weft rather than a third party, and that is
/// the single seam in this file. It is worth being exact about what it does and
/// does not weaken. Not exercised: another app's own share affordance. Exercised
/// in full, by the OS and not by the test: resolving the intent against the
/// manifest's `ACTION_SEND` / `ACTION_SEND_MULTIPLE` filters and their seven mime
/// types, the `content://` grant the app cannot read without being given it,
/// starting `MainActivity`, `onNewIntent` on a `singleTop` activity, the platform
/// side's copy out of the grant, and the sheet Dart draws over the result. That
/// is the delivery path the scenario is about, and none of it cares who asked.
///
/// Both scenarios assert on the peer's event. A share that reached the sheet and
/// failed at the upload looks identical from the sending screen — the sheet pops
/// and says "Sent to …" either way.
void main() {
  patrolTest(
    'a file shared from outside arrives on the peer as an image',
    ($) async {
      final scenario = await ChatScenario.start($, title: 'Share in');
      final files = await stageSharedPhotos();

      raiseSystemShareSheet(files);
      await awaitForeignWindow($, reason: 'the system chooser');
      await chooseWeftInChooser($);

      await awaitShareTargetSheet($);
      await shareToChat($, scenario.room.title);

      // The sheet reports itself and pops; the report is the only sign a share
      // went anywhere, because a share is a fire-and-forget gesture with no
      // screen left afterwards to check.
      await pumpUntil(
        $,
        () => showing(find.text('Sent to ${scenario.room.title}')),
        within: kSyncDeadline,
        reason: 'the share to report where it went',
      );

      final received = await scenario.bob.requireAttachment(scenario.room.id);
      expect(received.senderId, matrixUserId(kAppUser));
      expect(
        received.body,
        endsWith('.png'),
        reason: 'the shared file keeps its name across the content grant',
      );
      expect(
        received.isAttachmentEncrypted,
        isTrue,
        reason:
            'a share takes the same send path as the composer, which means the '
            'same megolm session — a file that arrived in clear would mean the '
            'share route went around the encryption the room asked for',
      );
    },
    config: kWeftPatrolConfig,
    timeout: kScenarioTimeout,
  );

  patrolTest(
    'SEND_MULTIPLE arrives as one event per file, in the order shared',
    ($) async {
      final scenario = await ChatScenario.start($, title: 'Share in multiple');
      final files = await stageSharedPhotos(count: 2);
      final names = [for (final file in files) file.uri.pathSegments.last];

      // Two files is what turns `ACTION_SEND` into `ACTION_SEND_MULTIPLE`, which
      // is a different filter in the manifest with a different mime list. One
      // extra file is the whole difference between the two scenarios, and it is
      // enough: the platform side either reads a list of grants or it does not.
      raiseSystemShareSheet(files);
      await awaitForeignWindow($, reason: 'the system chooser');
      await chooseWeftInChooser($);

      await awaitShareTargetSheet($);
      expect(
        showing(find.textContaining('2 files')),
        isTrue,
        reason:
            'the sheet says what is about to be sent before a conversation is '
            'chosen, which is the point of resolving the files up front',
      );

      await shareToChat($, scenario.room.title);
      await pumpUntil(
        $,
        () => showing(find.text('Sent to ${scenario.room.title}')),
        within: kSyncDeadline,
        reason: 'the share to report where it went',
      );

      // Both, not "at least one": a batch that drops its tail is the failure
      // this scenario exists for, and it is invisible from the sending screen.
      await pollUntilAsync(
        () async =>
            (await scenario.bob.attachments(scenario.room.id)).length >= 2,
        reason: 'both shared files to reach the peer',
      );
      final images = await scenario.bob.attachments(scenario.room.id);
      expect(images, hasLength(2));
      expect(
        images.map((event) => event.body).toSet(),
        names.toSet(),
        reason: 'each file arrived under its own name',
      );

      // Enqueued in series on purpose — `sendAttachment` returns on acceptance,
      // so a batch is a sequence of enqueues rather than a sequence of uploads,
      // and that is what puts them into the room in the order they were shared.
      final ordered = [...images]
        ..sort((a, b) => a.originServerTs.compareTo(b.originServerTs));
      expect(
        [for (final event in ordered) event.body],
        names,
        reason: 'the room holds the files in the order the share listed them',
      );
    },
    config: kWeftPatrolConfig,
    timeout: kScenarioTimeout,
  );

  patrolTest(
    'a shared file can be sent with a caption typed on the way',
    ($) async {
      final scenario = await ChatScenario.start($, title: 'Share in caption');
      final files = await stageSharedPhotos();
      final caption = uniqueBody('shared with a note');

      raiseSystemShareSheet(files);
      await awaitForeignWindow($, reason: 'the system chooser');
      await chooseWeftInChooser($);
      await awaitShareTargetSheet($);

      await pumpUntil(
        $,
        () => showing(find.text(scenario.room.title)),
        within: kSyncDeadline,
        reason: 'the conversation to be offered as a share target',
      );
      await $.tap(find.text(scenario.room.title).first);

      // The caption field belongs to the confirmation step, which is the reason
      // the sheet has two steps at all: a list row is not somewhere to type.
      final send = find.widgetWithText(
        FilledButton,
        'Send to ${scenario.room.title}',
      );
      await pumpUntil(
        $,
        () => showing(send),
        within: kUiDeadline,
        reason: 'the share confirmation step',
      );
      await $.enterText(find.byType(TextField).last, caption);
      await $.tap(send);

      // Text first, then the file: a photo shared with a caption reads the
      // wrong way round when the sentence lands after the picture, and the
      // sheet sends them in that order deliberately.
      final note = await scenario.bob.requireMessage(scenario.room.id, caption);
      final image = await scenario.bob.requireAttachment(scenario.room.id);
      expect(
        note.originServerTs.isAfter(image.originServerTs),
        isFalse,
        reason: 'the caption is meant to arrive before the file it is about',
      );
      expect(note.messageType, sdk.MessageTypes.Text);
    },
    config: kWeftPatrolConfig,
    timeout: kScenarioTimeout,
  );
}
